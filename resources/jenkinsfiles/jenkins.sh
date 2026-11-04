#!/usr/bin/env bash
#
# Jenkins-only release steps of samplePipeline (vars/samplePipeline.groovy).
# The pipeline writes this file to the workspace temp directory and runs it
# from the repository root.
#
# Usage:
#   jenkins.sh sonar NAME VERSION DIR
#       Analyze the tracked files of HEAD with SonarQube and wait for the
#       quality gate. Java projects (pom.xml) also send the classes from the
#       jar or war in DIR. Runs SONAR_SCANNER_IMAGE in Docker without volumes.
#       Env: SONAR_HOST_URL, SONAR_TOKEN.
#   jenkins.sh nexus NAME VERSION DIR
#       Upload DIR/NAME-VERSION.tar.gz and its .sha256 to a Nexus raw repository.
#       Skips the upload when Nexus already has the same sha256.
#       Env: NEXUS_URL, NEXUS_USER, NEXUS_PASSWORD, NEXUS_REPOSITORY (default raw-releases).
#   jenkins.sh image REGISTRY NAME VERSION LATEST
#       Log in to REGISTRY (Harbor or Amazon ECR), build and push
#       REGISTRY/NAME:VERSION for PLATFORMS (default linux/amd64,linux/arm64),
#       and REGISTRY/NAME:latest when LATEST is true. Logs out at exit.
#       Env: REGISTRY_USER and REGISTRY_PASSWORD for Harbor; AWS credentials for ECR.

set -euo pipefail

SONAR_SCANNER_IMAGE="${SONAR_SCANNER_IMAGE:-sonarsource/sonar-scanner-cli:12.3.1.4302_8.3.1}"

usage() {
  sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

die() {
  echo "error: $*" >&2
  exit 1
}

# curl_config NAME VALUE prints a curl config line. curl reads the secret from
# stdin, so it never appears on a command line.
curl_config() {
  local value="${2//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s = "%s"\n' "$1" "$value"
}

cmd_sonar() {
  local name="$1" version="$2" dir="$3"
  : "${SONAR_HOST_URL:?SONAR_HOST_URL is required}"
  : "${SONAR_TOKEN:?SONAR_TOKEN is required}"
  local work
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' RETURN

  # The sources go to the scanner on stdin, so the scan works on an agent that
  # uses the host Docker daemon (no bind mount of the workspace).
  git archive --format=tar --prefix=src/ HEAD > "$work/scan.tar"
  if [ -f pom.xml ]; then
    local artifact="$dir/$name-$version.tar.gz"
    [ -f "$artifact" ] || die "$artifact not found; run the artifact command first"
    mkdir -p "$work/artifact"
    tar -xzf "$artifact" -C "$work/artifact"
    tar -rf "$work/scan.tar" -C "$work" artifact
  fi

  # SonarQube Community Build analyzes one branch; every scan updates the project NAME.
  docker run -i --rm -e SONAR_HOST_URL -e SONAR_TOKEN \
    -e NAME="$name" -e VERSION="$version" --entrypoint bash "$SONAR_SCANNER_IMAGE" -c '
      set -euo pipefail
      mkdir -p /tmp/scan && cd /tmp/scan && tar -xf -
      args=()
      if [ -d artifact ]; then
        mkdir classes
        for archive in artifact/*.jar artifact/*.war; do
          [ -f "$archive" ] && (cd classes && jar xf "../$archive")
        done
        binaries="$(find classes -type d \( -path "*/BOOT-INF/classes" -o -path "*/WEB-INF/classes" \) | paste -sd, -)"
        [ -n "$binaries" ] || { echo "error: no classes in the artifact" >&2; exit 1; }
        args+=("-Dsonar.java.binaries=$binaries")
        libraries="$(find classes -name "*.jar" -path "*/lib/*" | paste -sd, -)"
        [ -z "$libraries" ] || args+=("-Dsonar.java.libraries=$libraries")
      fi
      cd src
      sonar-scanner \
        -Dsonar.projectKey="$NAME" \
        -Dsonar.projectName="$NAME" \
        -Dsonar.projectVersion="$VERSION" \
        -Dsonar.sources=. \
        -Dsonar.exclusions="**/node_modules/**,**/dist/**,**/target/**,**/*_pb2*.py" \
        -Dsonar.qualitygate.wait=true \
        -Dsonar.working.directory=/tmp/scannerwork \
        ${args[@]+"${args[@]}"}
    ' < "$work/scan.tar"
}

cmd_nexus() {
  local name="$1" version="$2" dir="$3"
  : "${NEXUS_URL:?NEXUS_URL is required}"
  : "${NEXUS_USER:?NEXUS_USER is required}"
  : "${NEXUS_PASSWORD:?NEXUS_PASSWORD is required}"
  local base="${NEXUS_URL%/}/repository/${NEXUS_REPOSITORY:-raw-releases}/$name/$version"
  local file sum="$dir/$name-$version.tar.gz.sha256"
  [ -f "$sum" ] || die "$sum not found; run the artifact command first"
  # A re-run of a tag build must not fail on a repository that disallows redeploy.
  if curl_config user "$NEXUS_USER:$NEXUS_PASSWORD" |
    curl -fsS --config - "$base/$(basename "$sum")" 2> /dev/null | cmp -s - "$sum"; then
    echo "already uploaded to $base/ with the same sha256"
    return 0
  fi
  for file in "$dir/$name-$version.tar.gz" "$sum"; do
    [ -f "$file" ] || die "$file not found; run the artifact command first"
    curl_config user "$NEXUS_USER:$NEXUS_PASSWORD" |
      curl -sS --fail-with-body --config - --upload-file "$file" "$base/$(basename "$file")"
    echo "uploaded $base/$(basename "$file")"
  done
}

cmd_image() {
  local registry="${1%/}" name="$2" version="$3" latest="$4"
  local image="$registry/$name"
  local host="${registry%%/*}"
  [[ "$latest" == true || "$latest" == false ]] || die "LATEST must be true or false"

  # Log out at exit, so the credential does not stay on a shared agent.
  trap 'docker logout "$host" > /dev/null' EXIT
  if [[ "$host" =~ ^[0-9]{12}\.dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com$ ]]; then
    local region="${BASH_REMATCH[1]}"
    local repository="${image#"$host"/}"
    aws ecr get-login-password --region "$region" |
      docker login --username AWS --password-stdin "$host"
    if ! aws ecr describe-repositories --region "$region" --repository-names "$repository" > /dev/null 2>&1; then
      aws ecr create-repository --region "$region" --repository-name "$repository" \
        --image-scanning-configuration scanOnPush=true > /dev/null
      echo "created ECR repository $repository"
    fi
  else
    : "${REGISTRY_USER:?REGISTRY_USER is required for $host}"
    : "${REGISTRY_PASSWORD:?REGISTRY_PASSWORD is required for $host}"
    printf '%s' "$REGISTRY_PASSWORD" | docker login --username "$REGISTRY_USER" --password-stdin "$host"
  fi

  local tags=(--tag "$image:$version")
  if [ "$latest" = true ]; then
    tags+=(--tag "$image:latest")
  fi
  docker buildx build --platform "${PLATFORMS:-linux/amd64,linux/arm64}" --push \
    --build-arg "VERSION=$version" \
    --label "org.opencontainers.image.version=$version" \
    --label "org.opencontainers.image.revision=$(git rev-parse HEAD)" \
    "${tags[@]}" .
  docker buildx imagetools inspect "$image:$version"
}

case "${1:-}" in
  sonar) [ $# -eq 4 ] || usage; cmd_sonar "$2" "$3" "$4" ;;
  nexus) [ $# -eq 4 ] || usage; cmd_nexus "$2" "$3" "$4" ;;
  image) [ $# -eq 5 ] || usage; cmd_image "$2" "$3" "$4" "$5" ;;
  *) usage ;;
esac
