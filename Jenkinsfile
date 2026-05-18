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
    string(name: 'APPLICATION_NAME', defaultValue: 'secure-vault',
           description: 'Logical app name; prefixes every container.')
    string(name: 'CLUSTER_NAMES',    defaultValue: 'dev-a,dev-b,test,stage,prod',
           description: 'Comma-delimited cluster list. APPEND only — removing names triggers prevent_destroy.')
    string(name: 'DOMAIN',           defaultValue: 'cntrlflix.com',
           description: 'Public DNS apex; per-cluster subdomain is <app>-<cluster>.<domain>.')
    booleanParam(name: 'LE_STAGING', defaultValue: false,
           description: "Issue against Let's Encrypt staging (untrusted certs) while iterating.")
  }

  environment {
    // Surface the secret-text creds as environment variables. Jenkins masks
    // them automatically in log output.
    LXD_TRUST_PASSWORD = credentials('lxd-trust-password')
    LETSENCRYPT_EMAIL  = credentials('letsencrypt-email')

    // terraform-lxd talks to the local LXD socket via this host. Bound to
    // 127.0.0.1 by bootstrap-host.sh's ufw rules.
    LXD_HOST = '127.0.0.1'

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
      steps {
        sh '''
          set -euo pipefail
          echo "==> versions"
          terraform version
          sudo lxc version | head -5
          echo "==> sudo without password works"
          sudo -n true
          echo "==> snap bin on PATH under sudo"
          sudo bash -c 'command -v lxc'
        '''
      }
    }

    stage('Bootstrap host (idempotent)') {
      steps {
        // Re-runs every build; each step in the script probes state and
        // skips work already done. Cheap to invoke, catches drift.
        sh '''
          set -euo pipefail
          sudo LXD_TRUST_PASSWORD="$LXD_TRUST_PASSWORD" \\
               bash scripts/bootstrap-host.sh
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
      when {
        // Auto-apply only on the develop branch — feature branches stop at plan.
        // Remove this guard if you want every push to apply.
        branch 'develop'
      }
      steps {
        dir('infra/terraform') {
          sh 'sudo -E terraform apply tfplan'
        }
      }
    }

    stage('Smoke') {
      when { branch 'develop' }
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
