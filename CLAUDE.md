# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Infrastructure for a data-analytics course: a self-managed kubeadm Kubernetes cluster on GCP (1 master + 2 workers in different regions), running Apache Airflow (KubernetesExecutor), JupyterHub, and a Prometheus/Grafana/Loki/OTel monitoring stack, for 16 analyst accounts (`analityk01`–`analityk16`). Comments, log messages, and docs are in Polish. Match that when editing.

There is no application build or test suite. Changes are checked with the linters below and by deploying to a real GCP project through CI.

## Rules

- **Infrastructure changes go only through GitHub Actions.** Never apply changes from a local machine. That rules out `terraform apply` and `terraform destroy`, `scripts/deploy.sh` and `scripts/destroy.sh`, `helm install`, `helm upgrade` and `helm uninstall`, `kubectl apply`, `patch`, `scale` and `delete`, and `green-blue-switch.sh deploy`, `switch` and `rollback`. Your job is to change code in the repo, run lint and read-only commands, and open a PR; the workflow applies the change. `.claude/settings.json` enforces this (see below).
- **Commits follow [Conventional Commits](https://www.conventionalcommits.org/):** `<type>(<scope>): <description>`.
  - Types: `feat`, `fix`, `docs`, `refactor`, `chore`, `ci`, `perf`, `test`, `build`, `style`, `revert`.
  - Suggested scopes: `terraform`, `airflow`, `jupyterhub`, `monitoring`, `dags`, `scripts`, `green-blue`.
  - Mark a breaking change with `!` (e.g. `feat(terraform)!: ...`) or a `BREAKING CHANGE:` footer.

### Permission guardrails (`.claude/settings.json`)

`permissions.deny` blocks the following. A denied call fails immediately; don't look for a workaround (`env`, `eval`, `xargs`, another wrapper). Ask the user instead.

| Area | Blocked | Still allowed |
|---|---|---|
| Terraform | `apply`, `destroy`, `import`, `refresh`, `taint`/`untaint`, `force-unlock`, `state rm/mv/push/replace-provider`, `workspace new/delete`, `init -migrate-state`/`-force-copy` | `init`, `fmt`, `validate`, `plan`, `output`, `show`, `state list/show` |
| gcloud | `create`, `delete`, `update`, `patch`, `set`, `start`/`stop`, `deploy`, `enable`/`disable`, `cp`/`mv`/`rm`/`rsync`/`scp` and other mutating verbs, plus every `add-*`, `remove-*`, `set-*`, `attach-*`, `detach-*` | `list`, `describe`, `--help`, `config list`, `ssh` |
| gsutil | `cp`, `mv`, `rm`, `rsync`, `mb`, `rb`, `compose`, `setmeta`, `defacl`, `retention`, `kms`, and the `set`/`ch`/`create`/`delete` subcommands (`acl set`, `iam ch`, `notification create` …) | `ls`, `cat`, `du`, `stat`, `version`, `acl get`, `iam get` |
| kubectl | `apply` (including `--dry-run`), `create`, `delete`, `edit`, `patch`, `replace`, `scale`, `set`, `label`, `annotate`, `drain`/`cordon`, `run`, `exec`, `cp`, `attach`, `debug`, `rollout restart/undo/pause/resume` … | `get`, `describe`, `logs`, `top`, `rollout status`, `port-forward` |
| Helm | `install`, `upgrade`, `uninstall`/`delete`/`del`/`un`, `rollback`, `test` | `list`, `status`, `history`, `get`, `lint`, `template` |
| Scripts | `deploy.sh`, `destroy.sh`; `green-blue-switch.sh deploy/switch/rollback` | `green-blue-switch.sh status`, reading the scripts (`cat`, Read), `bash -n` on a glob |
| Secrets | Reading `.env` (Read tool, `cat`/`source`/`grep` etc. on `.env`) | `.env.example` |

How the rules match:
- Each verb rule exists in two forms: bare (`terraform apply`) and with trailing arguments (`terraform apply *`).
- It also exists with anything between the tool and the verb (`terraform * apply`, `terraform * apply *`), which covers `-chdir=...`, `kubectl -n ns`, `gsutil -m` and `gcloud <group>`.
- Script rules cover `./scripts/x.sh`, `scripts/x.sh`, `./x.sh`, absolute paths, and `bash`/`sh`/`source`/`.`.
- Commands joined with `&&`, `;` or `|` are checked part by part, so `cd terraform && terraform apply` is denied too.

A few read-only commands are also caught because they contain a mutating verb as a word: `kubectl auth can-i delete …`, `kubectl get pods -L label`, `bash -n scripts/deploy.sh`, and any command whose text has ` .env` as a separate word, such as `git commit -m "… .env …"`. Use another form, such as `bash -n scripts/*.sh` or `git commit -F <file>`.

These rules are a guardrail, not a security boundary: they can't catch every shell form, and `ssh` to the master is not blocked. The real control is that only GitHub Actions holds deploy credentials. To change the list, edit `.claude/settings.json` in a PR. Keep `!.claude/settings.json` in `.gitignore`, because `*.json` is ignored globally.

## Commands

### Lint

CI (`.github/workflows/lint.yml`) runs on every PR to `main` and can be reused through `workflow_call`. It runs terraform fmt/validate, TFLint, ShellCheck and Ruff. The workflow uses no secrets: tools are downloaded from public release URLs and checked against SHA-256 sums. The tool versions and checksums live in its `env:` block.

When bumping the Google ruleset, update `TFLINT_GOOGLE_VERSION` and its checksum in the workflow together with `.tflint.hcl`; CI fails if they differ. Ruff config is in `ruff.toml`: py311, rules `E W F I UP`, `E501` ignored.

Only `terraform` is installed locally by default. Install the other tools as needed. To run the same checks locally:

```bash
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform init -backend=false && terraform -chdir=terraform validate
tflint --init && tflint --chdir=terraform --config="$PWD/.tflint.hcl"

shellcheck scripts/*.sh
bash -n scripts/*.sh                       # syntax only, needs no extra tools

ruff check .                               # ruff check --fix . sorts imports
python3 -m py_compile dags/*.py notebooks/airflow_helper.py

# Not in CI yet:
yamllint helm/ k8s/
helm lint helm/airflow -f helm/airflow/values-green.yaml   # values files only; there is no Chart.yaml in the repo
kubeconform -summary -ignore-missing-schemas k8s/   # `kubectl apply --dry-run` is blocked by the deny rules
```

### Deploy (GitHub Actions only)

`.github/workflows/deploy.yml` is started by hand (`workflow_dispatch`).
- **Order:** lint (through `workflow_call`) → `terraform plan` → optionally `apply` → optionally a smoke test.
- **Inputs:** `run_apply` and `run_smoke_test` are both off by default, so a plain run only lints and plans.
- **Apply** runs only from `main`, in the `production` environment, and re-plans before applying, because the plan file contains passwords and is never passed between jobs as an artifact.
- **Smoke test** reads the master IP from state and polls Airflow `/health`, JupyterHub `/hub/health` and Grafana `/api/health`. It can run without apply, to check the current deployment.

Configuration:
- **GCP auth:** Workload Identity Federation (`vars.GCP_WORKLOAD_IDENTITY_PROVIDER`, `vars.GCP_SERVICE_ACCOUNT`); there are no JSON keys.
- **Inputs passed as `TF_VAR_*`:** `vars.GCP_PROJECT_ID`, `vars.SSH_PUBLIC_KEY`, and the five `*_PASSWORD` secrets.
- **Region and zone** use the defaults in `variables.tf`.

State lives in GCS: `backend "gcs" {}` in `terraform/main.tf`, with bucket and prefix passed at init from `vars.TF_STATE_BUCKET` and `vars.TF_STATE_PREFIX`. The state bucket is created outside this Terraform. An administrator migrates any old local state once:

```bash
terraform -chdir=terraform init -migrate-state -backend-config="bucket=..." -backend-config="prefix=..."
```

The state holds the passwords (VM metadata), so the bucket must stay private.

SSH key: `var.ssh_pub_key` holds the key contents; CI sets it from `vars.SSH_PUBLIC_KEY`. When it's empty (local development), Terraform reads the file at `var.ssh_pub_key_path` (`~/.ssh/id_ed25519.pub`).

### Read-only

These are safe to run locally. `terraform init` now needs the backend config (or `-backend=false` for validate only), plus GCP credentials with read access to the state bucket.

```bash
terraform -chdir=terraform init -backend-config="bucket=$TF_STATE_BUCKET" -backend-config="prefix=$TF_STATE_PREFIX"
terraform -chdir=terraform plan    # needs TF_VAR_project_id and every TF_VAR_*_password (no defaults)
terraform -chdir=terraform output
terraform -chdir=terraform show

# On the cluster (ssh ubuntu@<MASTER_IP>):
./scripts/green-blue-switch.sh status
kubectl get nodes -o wide
kubectl get pods -A
kubectl get svc airflow-active -n airflow -o jsonpath='{.spec.selector.slot}'
helm list -A
helm status airflow-green -n airflow
kubectl logs -n airflow -l component=scheduler --tail=100
kubectl logs -n jupyterhub -l component=hub --tail=100
kubectl logs -n monitoring -l app.kubernetes.io/name=opentelemetry-collector
tail -f /var/log/master-init.log           # bootstrap progress and errors
```

Secrets come from `.env` (gitignored; `.env.example` is referenced but not committed; Claude is denied reading `.env`). Required: `REGION`, `ZONE`, `AIRFLOW_ADMIN_PASSWORD`, `AIRFLOW_ANALYST_PASSWORD`, `JUPYTERHUB_ADMIN_PASSWORD`, `JUPYTERHUB_ANALYST_PASSWORD`, `GRAFANA_ADMIN_PASSWORD`.

## Architecture: how the pieces connect

**Bootstrap runs from GCE metadata, not from the repo.** Terraform (`terraform/vms.tf`) passes `scripts/master-init.sh` and `scripts/worker-join.sh` as VM `startup-script`s. It also passes config and passwords as `tf_*` metadata keys, which the scripts read from the metadata server. Editing these scripts only affects newly created or recreated VMs.

**`master-init.sh` is the source of truth for what gets deployed.** It is a single ~800-line script. It runs kubeadm init, installs Calico and local-path-provisioner, deploys a Postgres StatefulSet in `airflow`, runs `helm install airflow-green` (chart 1.15.0), creates the `airflow-active` NodePort Service, creates analyst users, roles, and DAGs, and installs JupyterHub plus the monitoring charts. **Helm values are written inline as heredocs inside this script.** The files under `helm/` and `k8s/` are *not* read during bootstrap:
- `helm/airflow/values-{green,blue}.yaml` are used only by `green-blue-switch.sh deploy`.
- `helm/jupyterhub/`, `helm/monitoring/`, and `k8s/` are reference copies.

They have already drifted from the inline versions. For example:
- `values-green.yaml` lacks the master `nodeSelector` and uses `admin/admin`.
- JupyterHub's `AIRFLOW_HOST` points at `airflow-webserver` in the file but at `airflow-green-webserver` in the script.

When changing a deployed component, update the heredoc in `master-init.sh` and keep the matching `helm/` file in sync.

**Master/worker join:** the master writes `join-command.sh` and `admin.conf` to the bootstrap bucket (`{project_id}-{course_name}-bootstrap`). `worker-join.sh` polls that bucket and joins. Workers have no public IP and reach the internet through Cloud NAT. Only the master is public, and the firewall in `network.tf` opens a fixed list of ports to `allowed_cidr`.

**DAGs live on the master's disk, not in GCS or git-sync.** `/opt/airflow/dags` on the master is mounted via `hostPath` into every Airflow component and into JupyterHub user pods (as `~/airflow-dags`, with `~/dags` symlinked to the user's own subdirectory). That's why every Airflow pod, including KubernetesExecutor task pods, is pinned to the master with `nodeSelector`. Removing that pin breaks DAG loading.

**Analyst isolation and the GCS script runner:**
- For each analyst, `master-init.sh` creates an Airflow user (role `User`) and a dedicated role named after the user. It also generates `/opt/airflow/dags/{user}/run_script_{user}.py` from an inline `DAG_TEMPLATE`, using the `__ANALITYK__` placeholder, with `access_control` scoped to that role. These per-user DAGs are not in the repo.
- Each DAG downloads `gs://{dag_bucket}/dags/{user}/{script_name}`, using the VM service-account token from the metadata server rather than a GCS client library. It then runs the file with `python3` and cleans up.
- `dags/analityk_gcs_runner.py` is the admin-only variant (`admin_run_script`, which takes `analityk_id` as a param). It reads the bucket from the Airflow Variable `dag_bucket`.
- `notebooks/airflow_helper.py` is the JupyterHub-side client: it uploads to GCS, then triggers the DAG through the Airflow REST API.

**Green-blue deployment:** the two slots are separate Helm releases, `airflow-green` and `airflow-blue`, labeled `slot=<color>`. The `airflow-active` Service (NodePort 30080) selects `component=webserver,slot=<active>`. `switch` does four things in order:
1. Checks that the target webserver is ready.
2. Scales the target scheduler to 1.
3. Patches the Service selector.
4. Scales the old scheduler to 0.

Only one scheduler may run against the shared Postgres metadata DB at a time, so the blue slot ships with `scheduler.replicas: 0`.

## Known inconsistencies (don't trust blindly)

- `notebooks/airflow_helper.py` triggers DAG `analityk_run_script` and derives the password as `<user>Pass123!`. Neither matches what `master-init.sh` creates: the generated DAGs are `run_script_{user}`, and the password comes from `AIRFLOW_ANALYST_PASSWORD`.
- Actual bucket names are `{project_id}-airflow-spark-course-{dags,bootstrap}`. The README says `{project}-airflow-spark-*`.
- The "Spark" parts (`stress_test.py` using Spark Connect on `:15002`, the `spark_master_ui` output, the firewall ports 7077/8181/4040) are leftovers. Nothing in the bootstrap deploys Spark.
- `terraform output airflow_ui` prints port 8080, but the UI is served on NodePort 30080.
- IAM project roles for the VM service account are commented out in `vms.tf` and are assigned manually with gcloud. Only the bucket-level IAM is in Terraform.
- `scripts/deploy.sh` and `scripts/destroy.sh` run a bare `terraform init` and don't pass the GCS backend config, so they would prompt for the bucket. They predate the CI-only rule and are kept for reference; deploy through `deploy.yml`.
