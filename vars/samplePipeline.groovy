// GitHub -> Jenkins -> SonarQube -> Nexus -> Harbor or Amazon ECR -> GitOps deploy.
//
// Usage in a repository Jenkinsfile:
//
//   @Library('jenkinsfiles') _
//   samplePipeline()
//
// The repository provides the contract of the sample-* repositories:
// Dockerfile (stages build, artifact, runtime), scripts/smoke.sh and
// scripts/release.sh (tag, artifact, deploy). See README.md.
//
// Each external step runs only when its address is set in the Jenkins
// environment; otherwise the stage is skipped:
//   SONAR_HOST_URL  SonarQube analysis and quality gate (main branch and tags)
//   NEXUS_URL       artifact upload (tags)
//   REGISTRY        image push to Harbor or ECR (tags)
//   GITOPS_REPO     deploy event (tags, needs REGISTRY)

def call(Map config = [:]) {
  pipeline {
    // Stages take an agent only while they run, so the prod approval holds no executor.
    agent none

    options {
      buildDiscarder(logRotator(numToKeepStr: '30'))
      disableConcurrentBuilds()
    }

    stages {
      stage('Build') {
        agent any
        options {
          timeout(time: 60, unit: 'MINUTES')
        }
        stages {
          stage('Prepare') {
            steps {
              script {
                env.APP_NAME = sh(returnStdout: true, script: 'basename -s .git "$(git config --get remote.origin.url)"').trim()
                env.VERSION = env.TAG_NAME ?: "v0.0.0-ci.${env.GIT_COMMIT}"
                env.PRERELEASE = ''
                env.LATEST = 'false'
                if (env.TAG_NAME) {
                  def tag = sh(returnStdout: true, script: 'scripts/release.sh tag "$TAG_NAME"').trim()
                  env.PRERELEASE = tag.contains('prerelease=true') ? 'true' : 'false'
                  env.LATEST = tag.contains('latest=true') ? 'true' : 'false'
                }
                currentBuild.displayName = "#${env.BUILD_NUMBER} ${env.VERSION}"
              }
            }
          }

          // The Dockerfile build stage runs the tests.
          stage('Build and test') {
            steps {
              sh 'docker buildx build --pull --load --build-arg VERSION="$VERSION" --tag "$APP_NAME:ci-$BUILD_NUMBER" .'
            }
          }

          stage('Smoke test') {
            steps {
              sh 'scripts/smoke.sh "$APP_NAME:ci-$BUILD_NUMBER" "$VERSION"'
            }
          }

          stage('Artifact') {
            steps {
              sh 'scripts/release.sh artifact "$APP_NAME" "$VERSION" dist'
              archiveArtifacts artifacts: "dist/${env.APP_NAME}-${env.VERSION}.tar.gz*", fingerprint: true
            }
          }

          stage('SonarQube') {
            when {
              expression { env.SONAR_HOST_URL }
              anyOf {
                branch 'main'
                buildingTag()
              }
            }
            steps {
              withCredentials([string(credentialsId: 'sonar-token', variable: 'SONAR_TOKEN')]) {
                sh "bash '${jenkinsScript()}' sonar \"\$APP_NAME\" \"\$VERSION\" dist"
              }
            }
          }

          stage('Nexus') {
            when {
              buildingTag()
              expression { env.NEXUS_URL }
            }
            steps {
              withCredentials([usernamePassword(credentialsId: 'nexus', usernameVariable: 'NEXUS_USER', passwordVariable: 'NEXUS_PASSWORD')]) {
                sh "bash '${jenkinsScript()}' nexus \"\$APP_NAME\" \"\$VERSION\" dist"
              }
            }
          }

          stage('Image') {
            when {
              buildingTag()
              expression { env.REGISTRY }
            }
            steps {
              script {
                def push = "bash '${jenkinsScript()}' image \"\$REGISTRY\" \"\$APP_NAME\" \"\$VERSION\" \"\$LATEST\""
                if (env.REGISTRY ==~ /^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com(\/.*)?$/) {
                  sh push
                } else {
                  withCredentials([usernamePassword(credentialsId: 'registry', usernameVariable: 'REGISTRY_USER', passwordVariable: 'REGISTRY_PASSWORD')]) {
                    sh push
                  }
                }
              }
            }
          }

          stage('Deploy alpha') {
            when {
              buildingTag()
              expression { env.REGISTRY && env.GITOPS_REPO }
            }
            steps {
              withCredentials([string(credentialsId: 'gitops-token', variable: 'GITOPS_TOKEN')]) {
                sh 'scripts/release.sh deploy alpha'
              }
            }
          }
        }
        post {
          always {
            sh 'docker image rm "$APP_NAME:ci-$BUILD_NUMBER" > /dev/null 2>&1 || true'
          }
        }
      }

      // Stable tags only. PROD_APPROVERS (comma-separated users or groups) limits who may approve.
      stage('Approve prod') {
        when {
          buildingTag()
          expression { env.REGISTRY && env.GITOPS_REPO && env.PRERELEASE == 'false' }
        }
        steps {
          timeout(time: 7, unit: 'DAYS') {
            input(message: "Deploy ${env.VERSION} to prod?", ok: 'Deploy', submitter: env.PROD_APPROVERS ?: null)
          }
        }
      }

      stage('Deploy prod') {
        agent any
        when {
          beforeAgent true
          buildingTag()
          expression { env.REGISTRY && env.GITOPS_REPO && env.PRERELEASE == 'false' }
        }
        options {
          timeout(time: 10, unit: 'MINUTES')
        }
        steps {
          withCredentials([string(credentialsId: 'gitops-token', variable: 'GITOPS_TOKEN')]) {
            sh 'AUTO_MERGE=true scripts/release.sh deploy prod'
          }
        }
      }
    }
  }
}

// jenkinsScript writes resources/jenkinsfiles/jenkins.sh to the workspace temp
// directory and returns its path.
def jenkinsScript() {
  def path = "${env.WORKSPACE_TMP}/jenkinsfiles/jenkins.sh"
  writeFile(file: path, text: libraryResource('jenkinsfiles/jenkins.sh'))
  return path
}
