// Jenkins pipeline that mirrors what bitbucket-pipelines.yml used to do:
// preflight -> bootstrap host (idempotent) -> terraform apply.
//
// Runs on the built-in 'master' node because Jenkins is installed on the
// same VPS as LXD. All terraform/lxc commands here are local-exec; no SSH.
//
// Trigger model:
//   - 'develop' branch  -> automatic apply on push (CI deploy)
//   - any other branch  -> plan only, no apply (safety)
//   - manual button     -> 'Build with Parameters' lets you override
//                          APPLICATION_NAME / CLUSTER_NAMES.

pipeline {
  agent any

  parameters {
    string(name: 'APPLICATION_NAME', defaultValue: '',
           description: 'Logical app name; prefixes every container. Required (e.g. secure-vault).')
    string(name: 'CLUSTER_NAMES',    defaultValue: '',
           description: 'Comma-delimited cluster list (e.g. dev,test,prod). Required. APPEND only — removing names triggers prevent_destroy.')
    string(name: 'DOMAIN',           defaultValue: '',
           description: 'Public DNS apex (e.g. cntrlflix.com); per-cluster subdomain is <app>-<cluster>.<domain>. Required.')
    booleanParam(name: 'LE_STAGING', defaultValue: false,
           description: "Issue against Let's Encrypt staging (untrusted certs) while iterating.")
  }

  environment {
    // Surface the secret-text creds as environment variables. Jenkins masks
    // them automatically in log output.
    LXD_TRUST_PASSWORD = credentials('lxd-trust-password')
    LETSENCRYPT_EMAIL  = credentials('letsencrypt-email')

    // LXD_HOST is NOT hardcoded here. It comes from a Jenkins-configured
    // environment variable (Manage Jenkins -> System -> Global properties ->
    // Environment variables, or a node/folder-level env var). terraform runs
    // on the LXD host itself, so this is typically '127.0.0.1', but keeping
    // it external means a different host/port can be set without editing code.
    // Preflight fails the build if it's unset.

    TF_IN_AUTOMATION   = 'true'
    TF_INPUT           = '0'
    TF_CLI_ARGS_apply  = '-auto-approve'
  }

  options {
    timestamps()
    timeout(time: 90, unit: 'MINUTES')
    disableConcurrentBuilds()    // serialize: terraform state is not concurrent-safe
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
      }
    }

    stage('Preflight') {
      // Minimal checks that must pass before we even attempt bootstrap.
      // Terraform/lxc version checks moved to the post-bootstrap stage
      // because bootstrap-host.sh is what installs them.
      steps {
        // No defaults are pre-filled for APPLICATION_NAME / CLUSTER_NAMES /
        // DOMAIN — the operator must supply them on every "Build with
        // Parameters" run. Fail loud here if any are blank instead of letting
        // empty `-var` values reach terraform and surface as a cryptic
        // validation error mid-plan.
        script {
          ['APPLICATION_NAME', 'CLUSTER_NAMES', 'DOMAIN'].each { p ->
            if (!params[p]?.trim()) {
              error "Required parameter ${p} is empty. Use 'Build with Parameters' and provide a value."
            }
          }
          // LXD_HOST is supplied via a Jenkins environment variable, not a
          // build parameter. Fail loud if it wasn't configured.
          if (!env.LXD_HOST?.trim()) {
            error "LXD_HOST is not set. Configure it as a Jenkins environment variable (Manage Jenkins -> System -> Global properties -> Environment variables)."
          }
        }
        sh '''
          set -euo pipefail
          echo "==> sudo without password works"
          sudo -n true
        '''
      }
    }

    stage('Bootstrap host (idempotent)') {
      steps {
        // Re-runs every build; each step in the script probes state and
        // skips work already done. Installs terraform + lxd if missing.
        sh '''
          set -euo pipefail
          sudo LXD_TRUST_PASSWORD="$LXD_TRUST_PASSWORD" \\
               bash scripts/bootstrap-host.sh
        '''
      }
    }

    stage('Verify tooling') {
      steps {
        sh '''
          set -euo pipefail
          echo "==> versions"
          terraform version
          sudo lxc version | head -5
          echo "==> snap bin on PATH under sudo"
          sudo bash -c 'command -v lxc'
        '''
      }
    }

    stage('Terraform init') {
      steps {
        dir('infra/terraform') {
          sh 'sudo -E terraform init -upgrade'
        }
      }
    }

    stage('Terraform plan') {
      steps {
        dir('infra/terraform') {
          sh """
            sudo -E terraform plan -out=tfplan \\
              -var lxd_host=\$LXD_HOST \\
              -var lxd_trust_password=\$LXD_TRUST_PASSWORD \\
              -var application_name=${params.APPLICATION_NAME} \\
              -var cluster_names=${params.CLUSTER_NAMES} \\
              -var domain=${params.DOMAIN} \\
              -var letsencrypt_email=\$LETSENCRYPT_EMAIL \\
              -var letsencrypt_staging=${params.LE_STAGING}
          """
        }
        archiveArtifacts artifacts: 'infra/terraform/tfplan', fingerprint: true
      }
    }

    stage('Terraform apply') {
      // Single-branch Pipeline job pointed at develop, so no branch guard
      // needed. Switch to a Multibranch Pipeline and re-add
      //   when { branch 'develop' }
      // if you ever want feature branches to plan-only.
      steps {
        dir('infra/terraform') {
          sh 'sudo -E terraform apply tfplan'
        }
      }
    }

    stage('Smoke') {
      steps {
        sh '''
          set -euo pipefail
          echo "==> Containers:"
          sudo lxc list
          echo "==> Per-cluster Postgres reachability:"
          for c in $(sudo lxc list -c n --format csv); do
            ip=$(sudo lxc list "$c" -c 4 --format csv | awk '{print $1}')
            [ -z "$ip" ] && continue
            (echo > /dev/tcp/"$ip"/5432) >/dev/null 2>&1 \\
              && echo "    OK   $c ($ip:5432)" \\
              || echo "    FAIL $c ($ip:5432)"
          done
        '''
      }
    }
  }

  post {
    always {
      // Clean up the plan artifact reference but keep terraform's own .terraform
      // dir cached on the agent (faster init next run). Wrapped in node{} so
      // this still runs when an early failure (e.g. missing credential in the
      // environment{} block) prevented the agent from being allocated.
      node('built-in') {
        sh 'rm -f infra/terraform/tfplan || true'
      }
    }
    failure {
      echo 'Pipeline failed. Inspect the stage logs above; terraform state is left intact for the next run to resume.'
    }
  }
}
