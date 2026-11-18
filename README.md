# GCP Airflow + Kubernetes — Kurs Analityki Danych

Zautomatyzowana infrastruktura kursu Apache Airflow na Kubernetes w Google Cloud Platform. Projekt zawiera kompletny stos techniczny: orkestrację DAGów, jupyter notebooks dla analityków, monitoring i zero-downtime deployment.

---

## 📋 Spis treści

- [Architektura](#architektura)
- [Wymagania](#wymagania)
- [Konfiguracja sekretów](#konfiguracja-sekretów)
- [Quickstart](#quickstart)
- [Struktura projektu](#struktura-projektu)
- [Zarządzanie infrastrukturą](#zarządzanie-infrastrukturą)
- [Użytkownicy i dostępy](#użytkownicy-i-dostępy)
- [Green-Blue Deployment](#green-blue-deployment)
- [Monitoring](#monitoring)
- [Skrypty pomocnicze](#skrypty-pomocnicze)

---

## 🏗️ Architektura

```
┌─────────────────────────────────────────────────────────────┐
│                    GCP (Terraform)                          │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Master Node (europe-west1-b)          Worker Nodes        │
│  ├─ Kubernetes Control Plane           ├─ europe-west4-a   │
│  ├─ Apache Airflow 2.9.1               ├─ europe-central2-a│
│  │  ├─ Webserver (port 8080)           └─ (local-path-    │
│  │  ├─ Scheduler                           provisioner)    │
│  │  ├─ Triggerer                                          │
│  │  └─ Workers (KubernetesExecutor)   │                    │
│  ├─ JupyterHub (port 8888)            │                    │
│  ├─ PostgreSQL 15 (metadata)          │                    │
│  └─ Monitoring Stack                  │                    │
│     ├─ Prometheus (port 9090)         │                    │
│     ├─ Grafana (port 3000)            │                    │
│     ├─ Loki (logs)                    │                    │
│     └─ OpenTelemetry Collector        │                    │
│                                                             │
│  GCS Buckets:                                              │
│  ├─ {project}-airflow-spark-dags      (DAG files)         │
│  └─ {project}-airflow-spark-bootstrap (join tokens)       │
└─────────────────────────────────────────────────────────────┘
```

### Komponenty

| Komponent | Port (K8s) | NodePort | Namespace | Opis |
|-----------|-----------|----------|-----------|------|
| **Airflow UI** | 8080 | 30080 | `airflow` | DAG orchestration |
| **JupyterHub** | 8888 | 30088 | `jupyterhub` | Interactive notebooks |
| **Grafana** | 3000 | 30300 | `monitoring` | Dashboards & alerts |
| **Prometheus** | 9090 | 30090 | `monitoring` | Metrics storage |
| **Loki** | 3100 | — | `monitoring` | Log aggregation |
| **PostgreSQL** | 5432 | — | `airflow` | Airflow metadata DB |

---

## 📦 Wymagania

- **GCP Account** z włączonymi API:
  - Compute Engine
  - Cloud Storage
  - Cloud Resource Manager
  - IAM

- **Narzędzia lokalnie:**
  - `terraform` >= 1.5
  - `kubectl` >= 1.29
  - `helm` >= 3.x
  - `gcloud` CLI
  - SSH key (`~/.ssh/id_ed25519.pub`)

---

## 🔐 Konfiguracja sekretów

### ⚠️ Nigdy nie commituj rzeczywistych haseł do repozytorium!

Wszystkie hasła i dane wrażliwe przechowuj w pliku `.env`, który jest dodany do `.gitignore`.

### Konfiguracja

```bash
# 1. Skopiuj plik szablonowy
cp .env.example .env

# 2. Edytuj .env i wstaw rzeczywiste hasła
vim .env

# 3. Załaduj zmienne do bieżącej sesji
source .env

# 4. Weryfikacja
echo $AIRFLOW_ADMIN_PASSWORD
```

### Zawartość `.env`

| Zmienna | Opis | Przykład |
|---------|------|---------|
| `PROJECT_ID` | GCP Project ID | `my-gcp-project` |
| `REGION` | Region GCP | `europe-west1` |
| `ZONE` | Strefa GCP | `europe-west1-b` |
| `AIRFLOW_ADMIN_PASSWORD` | Hasło admina Airflow | Silne hasło min. 12 znaków |
| `AIRFLOW_ANALYST_PASSWORD` | Hasło dla analityków | Silne hasło min. 12 znaków |
| `JUPYTERHUB_ADMIN_PASSWORD` | Hasło admina JupyterHub | Silne hasło min. 12 znaków |
| `JUPYTERHUB_ANALYST_PASSWORD` | Hasło dla analityków w JupyterHub | Silne hasło min. 12 znaków |
| `GRAFANA_ADMIN_PASSWORD` | Hasło admina Grafana | Silne hasło min. 12 znaków |

### Bezpieczeństwo

✅ **Dobrze:**
- Hasła w `.env` (lokalnie)
- `.env` w `.gitignore`
- Różne hasła dla każdej roli
- Silne hasła min. 12 znaków

❌ **Źle:**
- Hasła w kodzie
- Hasła w README
- Hasła w commitach Git
- Wspólne hasła dla wszystkich

---

## 🚀 Quickstart

### 1. Konfiguracja zmiennych środowiskowych

```bash
# Skopiuj plik z konfiguracją
cp .env.example .env

# Edytuj .env i wstaw rzeczywiste hasła
vim .env
```

Wymagane zmienne w `.env`:
- `PROJECT_ID` — GCP Project ID
- `REGION` — region GCP
- `AIRFLOW_ADMIN_PASSWORD` — hasło do admina Airflow
- `AIRFLOW_ANALYST_PASSWORD` — hasło dla kont analityków
- `JUPYTERHUB_ADMIN_PASSWORD` — hasło admin JupyterHub
- `GRAFANA_ADMIN_PASSWORD` — hasło admin Grafana

```bash
# Załaduj zmienne
source .env
```

### 2. Deploy infrastruktury

```bash
./scripts/deploy.sh $PROJECT_ID
```

Czeka na inicjalizację klastra (~8-12 minut).

### 3. Pobierz dostępy

```bash
cd terraform
terraform output
```

Otrzymasz:
- **Airflow UI**: `http://<MASTER_IP>:30080` (admin / hasło z `$AIRFLOW_ADMIN_PASSWORD`)
- **JupyterHub**: `http://<MASTER_IP>:30088` (analityk01-16 / hasło z `$JUPYTERHUB_ANALYST_PASSWORD`)
- **Grafana**: `http://<MASTER_IP>:30300` (admin / hasło z `$GRAFANA_ADMIN_PASSWORD`)
- **SSH**: `ssh ubuntu@<MASTER_IP>`

### 4. Upload DAGów

DAGi każdego analityka trafiają do `gs://{project}-airflow-spark-dags/dags/{analityk_username}/`

```bash
gsutil -m cp scripts/*.py gs://{project}-airflow-spark-dags/dags/admin/
```

---

## 📁 Struktura projektu

```
.
├── terraform/
│   ├── main.tf                 # Provider + APIs
│   ├── variables.tf            # Zmienne (project_id, region, machine types)
│   ├── vms.tf                  # GCE instances (master, workers)
│   ├── network.tf              # VPC, subnets, firewall
│   ├── gcs.tf                  # Cloud Storage buckets
│   ├── outputs.tf              # IPs, URLs, SSH commands
│   └── terraform.tfstate       # State (nie commitować!)
│
├── scripts/
│   ├── deploy.sh               # Główny skrypt deploy (invoke terraform)
│   ├── destroy.sh              # Usuń całą infrastrukturę
│   ├── master-init.sh          # Startup script dla mastera
│   ├── worker-join.sh          # Startup script dla workerów
│   └── green-blue-switch.sh    # Zero-downtime deployment tool
│
├── helm/
│   ├── airflow/
│   │   ├── values-green.yaml   # Konfiguracja slotu GREEN
│   │   └── values-blue.yaml    # Konfiguracja slotu BLUE
│   ├── jupyterhub/
│   │   └── values.yaml         # JupyterHub config
│   └── monitoring/
│       ├── kube-prometheus-values.yaml
│       ├── loki-values.yaml
│       └── otel-collector-values.yaml
│
├── k8s/
│   ├── airflow/
│   │   └── service-active.yaml # Switching Service (green-blue)
│   └── monitoring/
│       └── airflow-alerts.yaml # PrometheusRules
│
├── dags/
│   ├── hello_world.py          # Przykładowy DAG
│   └── analityk_gcs_runner.py  # Template DAG dla GCS
│
├── notebooks/
│   └── airflow_helper.py       # Helper do integracji Airflow + Jupyter
│
├── stress_test.py              # Test obciążenia
└── Datasets/
    └── login_credentials.csv   # Dane do testów
```

---

## ⚙️ Zarządzanie infrastrukturą

### Terraform Workflow

```bash
cd terraform

# Inicjalizacja
terraform init

# Plan zmian
terraform plan -var="project_id=$PROJECT_ID"

# Apply (automatycznie w deploy.sh)
terraform apply -var="project_id=$PROJECT_ID" -auto-approve

# Wyświetl outputy
terraform output

# Zniszcz wszystko
terraform destroy -var="project_id=$PROJECT_ID"
```

### Zmienne Terraform

Domyślne wartości w `terraform/variables.tf`:

| Zmienna | Default | Opis |
|---------|---------|------|
| `project_id` | — | GCP Project ID (wymagane) |
| `region` | `europe-west1` | Główny region (master) |
| `zone` | `europe-west1-b` | Strefa dla mastera |
| `course_name` | `airflow-spark-course` | Prefix dla zasobów |
| `master_machine_type` | `e2-standard-2` | 2 vCPU, 8 GB RAM |
| `worker_machine_type` | `e2-standard-2` | 2 vCPU, 8 GB RAM × 2 nodes (limit CPU projektu: 8 vCPU) |
| `allowed_cidr` | `0.0.0.0/0` | CIDR dla dostępu SSH |
| `ssh_pub_key_path` | `~/.ssh/id_ed25519.pub` | Publiczny klucz SSH |

---

## 👥 Użytkownicy i dostępy

### Konta Airflow (automatycznie tworzone)

16 kont analityków: `analityk01` — `analityk16`

- **Hasło**: Ustaw w zmiennej `$AIRFLOW_ANALYST_PASSWORD` (w pliku `.env`)
- **Rola**: `User` (dostęp do UI + DAGów w przydzielonym katalogu)
- **Izolacja**: Każdy analityk widzi tylko swoje DAGi (RBAC przez `access_control`)

### Dedykowana rola analityka

Każdy użytkownik ma własną rolę o nazwie jak username (np. `analityk01`), która daje uprawnienia do edycji/usuwania DAGów przydzielonych użytkownikowi.

### JupyterHub

- **Użytkownicy**: admin + analityk01-16
- **Hasło**: Ustaw w zmiennej `$JUPYTERHUB_ADMIN_PASSWORD` i `$JUPYTERHUB_ANALYST_PASSWORD` (w pliku `.env`)
- **Authenticator**: DummyAuthenticator
- **Home**: `/home/jovyan/` (storage: 2 Gi, local-path)
- **Integracja**: Symlink do `/home/jovyan/airflow-dags/{username}`

### Admin

- **Airflow admin**: `admin` / `$AIRFLOW_ADMIN_PASSWORD` (zmienna w `.env`)
- **Grafana admin**: `admin` / `$GRAFANA_ADMIN_PASSWORD` (zmienna w `.env`)

---

## 🔄 Green-Blue Deployment

Zero-downtime deployment strategia dla Airflow.

### Koncepcja

- **GREEN**: Aktywny slot (obsługuje ruch)
- **BLUE**: Standby slot (gotowy do switchowania)
- **Service**: `airflow-active` (NodePort 30080) wskazuje na aktywny slot

### Użycie

```bash
# Status (aktualny slot, wersje, gotowość)
./scripts/green-blue-switch.sh status

# Deploy nowej wersji do standby slotu
./scripts/green-blue-switch.sh deploy blue

# Przełącz ruch (< 1 sekunda)
./scripts/green-blue-switch.sh switch blue

# Rollback na poprzedni slot
./scripts/green-blue-switch.sh rollback

# Lub jawne przełączenie
./scripts/green-blue-switch.sh switch green
```

### Proces switchowania

1. ✅ Sprawdź gotowość webservera (musi być ready)
2. ⚡ Uruchom scheduler w docelowym slocie
3. 🔀 Patch Service na nowy slot (< 1 sec downtime)
4. 🛑 Wyłącz scheduler starego slotu

---

## 📊 Monitoring

### Stack

- **Prometheus** (metrics) — 15d retention
- **Grafana** (dashboards)
- **Loki** (logs) — 7d retention
- **OpenTelemetry Collector** (scraping + forwarding)

### Dashboards (preloadowane)

- Kubernetes Cluster (gnetId: 7249)
- Node Exporter (gnetId: 1860)
- Airflow (gnetId: 19492)

### Alerty

Reguły w `k8s/monitoring/airflow-alerts.yaml`:

**Critical:**
- `AirflowSchedulerDown` — Scheduler brak heartbeat > 2 min
- `AirflowWebserverDown` — Webserver offline > 2 min

**Warning:**
- `AirflowQueuedTasksTooHigh` — > 20 tasków w queue
- `NodeHighMemory` — RAM > 85%

### ServiceMonitor + PodMonitor

OTel Collector scrape'uje Airflow/JupyterHub co 15-30 sekund, forward'uje metryki do Prometheusa i logi do Loki.

---

## 🔧 Skrypty pomocnicze

### `scripts/master-init.sh`

Startup script dla mastera (wywoływany przez Terraform metadata):

1. System dependencies (containerd, kubeadm, kubectl)
2. Kubernetes cluster init (kubeadm init)
3. CNI: Calico
4. StorageClass: local-path-provisioner
5. PostgreSQL 15 (StatefulSet)
6. **Airflow via Helm** (1.15.0, GREEN slot)
7. **JupyterHub via Helm** (3.3.7)
8. **Monitoring stack** (Prometheus, Grafana, Loki, OTel)
9. User setup (16 analityków + dedicated roles)

⏱️ Czas wykonania: ~10-12 minut

### `scripts/worker-join.sh`

Startup script dla workerów:

1. System deps
2. containerd
3. kubeadm
4. Fetch join-command z GCS
5. Join do klastra
6. Label node (role=worker, zone-awareness)

### `scripts/deploy.sh`

Warpper wokół Terraform:

```bash
./scripts/deploy.sh $PROJECT_ID
```

1. `terraform init` + `terraform apply`
2. Czeka na gotowość mastera (polling log file na SSH)
3. Wypisuje finalne outputy + dostępy

### `scripts/destroy.sh`

Usuwa całą infrastrukturę:

```bash
./scripts/destroy.sh $PROJECT_ID
```

---

## 📝 DAG Template

Każdy analityk dostaje dedykowany DAG w `dags/{username}/run_script_{username}.py`.

**Funkcjonalność:**
- Download skryptu Python z GCS
- Uruchomienie
- Cleanup

**Parametry:**
- `script_name` — nazwa pliku w `gs://{bucket}/dags/{username}/`

**RBAC:**
- Tylko analityk właściciela DAGu może go edytować/uruchamiać
- Admin widzi wszystkie DAGi

---

## 🐳 Obrazy Docker

- **Airflow**: `apache/airflow:2.9.1-python3.11`
- **JupyterHub**: `quay.io/jupyter/scipy-notebook:latest`
- **Prometheus**: Community charts (built-in)
- **OTel Collector**: `otel/opentelemetry-collector-contrib:0.102.0`

---

## 🔐 Bezpieczeństwo

### GCP IAM

Service Account (`{course_name}-vm`) ma role:
- `roles/storage.objectAdmin` — dostęp do GCS buckets
- `roles/logging.logWriter` — wysyłanie logów do Cloud Logging
- `roles/monitoring.metricWriter` — wysyłanie metryk do Cloud Monitoring

### Network

- **Master**: Public IP (SSH open na `allowed_cidr`)
- **Workers**: Private IPs (NAT outbound)
- **Internal communication**: Kubernetes Service DNS

### Kubernetes

- RBAC: Dedykowane role dla każdego analityka
- NetworkPolicy: (opcjonalnie, można dodać)
- Pod Security Standards: (baseline)

---

## 🐛 Troubleshooting

### Master nie startuje

```bash
ssh ubuntu@<MASTER_IP>
tail -f /var/log/master-init.log
```

### Workerzy nie dolączają

```bash
# Z mastera
kubectl get nodes -o wide

# Z workera
tail -f /var/log/messages | grep kubeadm
```

### Airflow scheduler down

```bash
kubectl logs -n airflow -l component=scheduler --tail=100
```

### JupyterHub spawn fails

```bash
kubectl logs -n jupyterhub -l component=hub --tail=100
```

### Brak metryk w Grafana

```bash
# Check OTel Collector
kubectl logs -n monitoring -l app.kubernetes.io/name=opentelemetry-collector

# Prometheus targets
kubectl port-forward -n monitoring svc/kube-prom-kube-prometheus-stack-prometheus 9090:9090
# http://localhost:9090/targets
```

---

## 🗑️ Cleanup

```bash
# Usuń całą infrastrukturę
./scripts/destroy.sh $PROJECT_ID

# Lub ręcznie
cd terraform
terraform destroy -var="project_id=$PROJECT_ID"
```

---

## 📞 Kontakt

- Email: marcin119a@gmail.com
- Instruktor: Marcin Wierzbinski

---

**Ostatnia aktualizacja**: 2026-06-03  
**Wersja**: 1.0
