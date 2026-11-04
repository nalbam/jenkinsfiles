# jenkinsfiles

A Jenkins shared library for the `nalbam/sample-*` repositories:
GitHub -> Jenkins -> SonarQube -> Nexus -> Harbor or Amazon ECR -> GitOps deploy.

Each repository `Jenkinsfile` has two lines:

```groovy
@Library('jenkinsfiles') _
samplePipeline()
```

| Path | Contents |
| --- | --- |
| `vars/samplePipeline.groovy` | The declarative pipeline. |
| `resources/jenkinsfiles/jenkins.sh` | Jenkins-only steps: `sonar`, `nexus`, `image`. |

The repository provides the rest: the `Dockerfile` (stages `build`, `artifact` and the runtime image),
`scripts/smoke.sh` and `scripts/release.sh` (`tag`, `artifact`, `deploy`).
The stages and the GitHub Actions path are in `docs/pipeline.md` of each sample repository.

## Stages

| Stage | Runs when | Result |
| --- | --- | --- |
| Prepare | always | `APP_NAME` from the Git remote, `VERSION` from the tag or `v0.0.0-ci.<commit>`. Checks the tag. |
| Build and test | always | `docker buildx build`; the Dockerfile `build` stage runs the tests. |
| Smoke test | always | `scripts/smoke.sh`. |
| Artifact | always | `dist/<repo>-<version>.tar.gz` and `.sha256`, archived in Jenkins. |
| SonarQube | `SONAR_HOST_URL` is set, on `main` and tags | Analyzes project `<repo>` and waits for the quality gate. A failed gate fails the build. |
| Nexus | `NEXUS_URL` is set, on tags | Uploads the artifact. Skips the upload when Nexus already has the same sha256, so a tag build can run again. |
| Image | `REGISTRY` is set, on tags | Pushes `<REGISTRY>/<repo>:<version>`, and `latest` for the highest stable tag. A re-run does not push an existing version again, so Harbor tag immutability works. Logs out of the registry at the end. |
| Deploy alpha | `REGISTRY` and `GITOPS_REPO` are set, on tags | Sends the GitOps event for phase `alpha`. |
| Approve prod | as Deploy alpha, stable tags only | Waits up to 7 days for an approval. It holds no executor. |
| Deploy prod | after the approval | Sends phase `prod` with `auto_merge: true`. |

An address that is not set skips its stage, and the build still succeeds.
The build stages share one executor with a 60-minute timeout.

## Set up Jenkins

1. Install the plugins: Pipeline, Git, Credentials Binding, Pipeline: Multibranch,
   and Basic Branch Build Strategies (to build tags).
2. **Manage Jenkins > System > Global Trusted Pipeline Libraries**: add a library.
   - Name: `jenkinsfiles`
   - Default version: `main`, or a tag of this repository to pin it.
   - Retrieval method: Modern SCM, Git, `https://github.com/nalbam/jenkinsfiles.git`.
3. Create a **Multibranch Pipeline** job for each repository with the GitHub or Git branch source:
   - Behaviours: **Discover branches** and **Discover tags**. With **Discover tags**, the checkout fetches all tags.
     The `Prepare` stage needs them to decide whether a tag moves `latest`, and fails when the tag is missing.
     Do not add a clone behaviour that disables tags.
   - Build strategies: **Regular branches** and **Tags**. Leave the tag age limits empty, or longer than
     the time between a commit and its tag. Jenkins discovers older tags but does not build them.
4. Set the environment variables and the credentials below.

### Agent prerequisites

- `docker` with Buildx, and access to the Docker daemon for the agent user.
- `git`, `bash`, `curl`, `jq`, `tar`, `gzip`, `sha256sum`.
- `aws` CLI and AWS credentials for an ECR `REGISTRY`: `ecr:GetAuthorizationToken`,
  `ecr:DescribeRepositories`, `ecr:CreateRepository` and the image push actions.
- Outbound HTTPS during the build, for base images and packages (and CDN checks in `sample-web`).
- Multi-platform push (`linux/amd64,linux/arm64`): a daemon that uses the containerd image store,
  or a `docker-container` Buildx builder selected by the agent user. With a `docker-container` builder,
  the registry host must also resolve inside the BuildKit container.

  ```bash
  docker run --privileged --rm tonistiigi/binfmt --install arm64,amd64
  docker buildx create --name multiarch --driver docker-container --use   # run as the agent user
  ```

### Environment variables

Set them as global or folder properties.

| Name | Value |
| --- | --- |
| `SONAR_HOST_URL` | SonarQube URL, for example `https://sonarqube.example.com`. Empty: no analysis. |
| `NEXUS_URL` | Nexus base URL, for example `https://nexus.example.com`. Empty: no upload. |
| `NEXUS_REPOSITORY` | Raw hosted repository. Default `raw-releases`. |
| `REGISTRY` | Harbor `harbor.example.com/<project>` or ECR `<account>.dkr.ecr.<region>.amazonaws.com`. Empty: no image push and no deploy. |
| `PLATFORMS` | Image platforms. Default `linux/amd64,linux/arm64`. |
| `GITOPS_REPO` | `owner/repo` that receives the deploy event, for example `opspresso/argocd-env-apps`. Empty: no deploy. |
| `PROD_APPROVERS` | Comma-separated users or groups that may approve prod. Empty: any user with Build permission. |
| `SONAR_SCANNER_IMAGE` | Scanner image. Default `sonarsource/sonar-scanner-cli:12.3.1.4302_8.3.1`. |

### Credentials

| ID | Kind | Used for |
| --- | --- | --- |
| `sonar-token` | Secret text | SonarQube token that can create and analyze projects. |
| `nexus` | Username with password | Nexus user with the `add` and `read` privileges of the raw repository. |
| `registry` | Username with password | Harbor robot account with push permission. Not used for ECR. |
| `gitops-token` | Secret text | GitHub token that can send `repository_dispatch` to `GITOPS_REPO` (Contents read and write). |

## Notes

- SonarQube: the scanner runs in Docker and reads the tracked files of `HEAD` from stdin, so it needs no bind mount
  and works on an agent that uses the host Docker daemon. `SONAR_HOST_URL` must be reachable from the default
  bridge network of that daemon. The scanner image is `linux/amd64` only and runs emulated on arm64 agents.
  The sources have no `.git`, so the analysis has no blame data (`sonar.scm.disabled=true`).
  The Community Build keeps one branch per project, so the pipeline analyzes `main` and tags only.
  Java projects send the classes from the release jar or war.
- Nexus 3 Community Edition rejects every upload with HTTP 403 until an administrator accepts the EULA.
- Docker stores registry logins in `~/.docker/config.json` of the agent user. The image step logs out at the end;
  use a credential helper on shared agents.

## Develop

```bash
shellcheck resources/jenkinsfiles/jenkins.sh
```

The Jenkins declarative linter does not load `@Library`. To check the syntax, send the `pipeline { ... }` block of
`vars/samplePipeline.groovy` to `<JENKINS_URL>/pipeline-model-converter/validate`.
