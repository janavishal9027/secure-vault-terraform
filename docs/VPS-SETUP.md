# VPS setup prerequisites (one-time, before the first Jenkins build)

The Jenkins pipeline ([Jenkinsfile](../Jenkinsfile)) runs entirely on the VPS
via `local-exec` (`sudo terraform`, `sudo lxc`, `sudo nginx`, ...). A few host
prerequisites must be in place **before the first build can pass** — they
can't be automated by the pipeline itself because the pipeline depends on them
to even start.

Do these once, in order, on a fresh VPS.

## 1. Install Jenkins on the host

```bash
sudo JENKINS_DOMAIN='jenkins.cntrlflix.com' \
     LETSENCRYPT_EMAIL='you@example.com' \
     bash scripts/install-jenkins.sh
```

See [scripts/install-jenkins.sh](../scripts/install-jenkins.sh) for env vars
and staging options.

## 2. Install git on the host

Jenkins needs the `git` CLI to check out the repo — and it needs it *before*
the pipeline runs, so the pipeline (which installs git via `bootstrap-host.sh`)
can't bootstrap its own checkout tool. Install it manually:

```bash
apt-get update
apt-get install -y git
git --version            # confirm it's on PATH
```

Without this the build fails at SCM checkout with
`Cannot run program "git" ... No such file or directory`.

## 3. Grant the `jenkins` user passwordless sudo

The pipeline's **Preflight** stage runs `sudo -n true` and aborts if sudo
would prompt for a password. Every later stage uses `sudo`. So the `jenkins`
service user needs passwordless sudo:

```bash
echo 'jenkins ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/jenkins
chmod 0440 /etc/sudoers.d/jenkins
visudo -c -f /etc/sudoers.d/jenkins        # must print "... parsed OK"
```

Verify it works *as the jenkins user* (this reproduces the Preflight check):

```bash
sudo -u jenkins sudo -n true && echo "OK: passwordless sudo works"
```

Gotchas if it still prompts for a password:
- File must be `0440`; sudo ignores group/world-writable drop-ins.
- Filename must not contain a `.` or end in `~` — `jenkins` is fine,
  `jenkins.conf` is silently **ignored**.
- `/etc/sudoers` must contain `@includedir /etc/sudoers.d` (it does by
  default on Ubuntu).
- The rule must name whatever user Jenkins actually runs as
  (`ps -o user= -p "$(pgrep -f jenkins.war | head -1)"`).

> **Security note:** `NOPASSWD:ALL` gives the `jenkins` user full root. That's
> acceptable here because this is a single-purpose CI box whose entire job is
> to run privileged infra commands. Don't add unrelated/untrusted jobs to this
> Jenkins.

## 4. Add the two Jenkins credentials

The `environment {}` block resolves these with `credentials('<id>')` before any
stage runs; a missing one aborts the build immediately with
`ERROR: <credential-id>`.

**Manage Jenkins → Credentials → System → Global credentials → Add Credentials**

| Kind        | ID                   | Secret value |
|-------------|----------------------|--------------|
| Secret text | `letsencrypt-email`  | Your Let's Encrypt contact email |
| Secret text | `lxd-trust-password` | The LXD trust password — **must match** `core.trust_password` on the host |

The IDs are case-sensitive and must match the Jenkinsfile exactly.

The trust password is verified later (the `lxd` Terraform provider uses it to
register as a trusted client), so it must match what's set on the host. It's
write-only and can't be read back — if unsure, re-assert it to a known value
and store that same string in the credential:

```bash
lxc config set core.trust_password 'YOUR_CHOSEN_PASSWORD'
```

## 5. DNS

Point an `A` record for each cluster subdomain (and the Jenkins hostname) at
the VPS public IP before expecting real Let's Encrypt certs. If DNS isn't live
yet, the run still succeeds — it leaves HTTP-only vhosts and the next build
promotes them to HTTPS once the certs issue.

---

## Failure → cause quick reference

| Build error | Cause | Fix |
|-------------|-------|-----|
| `Cannot run program "git"` (SCM checkout) | git not installed on host | Step 2 |
| `sudo: a password is required` (Preflight) | `jenkins` lacks passwordless sudo | Step 3 |
| `ERROR: letsencrypt-email` | Missing Jenkins credential | Step 4 |
| `ERROR: lxd-trust-password` | Missing Jenkins credential | Step 4 |
