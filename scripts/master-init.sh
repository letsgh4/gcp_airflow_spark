#!/bin/bash
set -euo pipefail
exec > /var/log/master-init.log 2>&1

META="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
H="Metadata-Flavor: Google"
# shellcheck disable=SC2034  # TODO: nieużywane — usunąć albo wykorzystać
PROJECT_ID=$(curl -sf "$META/tf_project_id" -H "$H")
JOIN_BUCKET=$(curl -sf "$META/tf_join_bucket" -H "$H")
# shellcheck disable=SC2034  # TODO: przekazać do JupyterHub jako DAG_BUCKET (wymaga go notebooks/airflow_helper.py)
DAG_BUCKET=$(curl -sf  "$META/tf_dag_bucket"  -H "$H")
ANALITYCY=$(curl -sf    "$META/tf_analitycy"     -H "$H")
AIRFLOW_ADMIN_PASSWORD=$(curl -sf "$META/tf_airflow_admin_password" -H "$H")
AIRFLOW_ANALYST_PASSWORD=$(curl -sf "$META/tf_airflow_analyst_password" -H "$H")
# shellcheck disable=SC2034  # TODO: hasło admina JupyterHub nie jest nigdzie ustawiane
JUPYTERHUB_ADMIN_PASSWORD=$(curl -sf "$META/tf_jupyterhub_admin_password" -H "$H")
JUPYTERHUB_ANALYST_PASSWORD=$(curl -sf "$META/tf_jupyterhub_analyst_password" -H "$H")
GRAFANA_ADMIN_PASSWORD=$(curl -sf "$META/tf_grafana_admin_password" -H "$H")

K8S_VERSION="1.29"
POD_CIDR="192.168.0.0/16"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ── 1. System deps ─────────────────────────────────────────────────────────────
log "Aktualizacja systemu..."
apt-get update -qq
apt-get install -y -qq curl wget gnupg2 apt-transport-https ca-certificates \
  software-properties-common python3-pip python3-venv git

# ── 2. containerd ──────────────────────────────────────────────────────────────
log "Instalacja containerd..."
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq containerd.io

containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# ── 3. kubeadm / kubelet / kubectl ────────────────────────────────────────────
log "Instalacja kubeadm..."
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

# ── 4. kubeadm init ────────────────────────────────────────────────────────────
log "Inicjalizacja klastra K8s..."
INTERNAL_IP=$(curl -sf "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip" \
  -H "Metadata-Flavor: Google")
EXTERNAL_IP=$(curl -sf "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip" \
  -H "Metadata-Flavor: Google" || echo "")

kubeadm init \
  --apiserver-advertise-address="$INTERNAL_IP" \
  --apiserver-cert-extra-sans="$EXTERNAL_IP,$INTERNAL_IP" \
  --pod-network-cidr="$POD_CIDR" \
  --kubernetes-version="v${K8S_VERSION}.0"

mkdir -p /root/.kube /home/ubuntu/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
chown ubuntu:ubuntu /home/ubuntu/.kube/config

export KUBECONFIG=/root/.kube/config

# ── 5. CNI: Calico ─────────────────────────────────────────────────────────────
log "Instalacja Calico CNI..."
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml

# ── 6. Zapisz join-command do GCS ─────────────────────────────────────────────
log "Zapis join-command do GCS..."
JOIN_CMD=$(kubeadm token create --print-join-command)
echo "$JOIN_CMD" | gsutil cp - "gs://$JOIN_BUCKET/join-command.sh"
gsutil cp /etc/kubernetes/admin.conf "gs://$JOIN_BUCKET/admin.conf"

# ── 7. Helm ────────────────────────────────────────────────────────────────────
log "Instalacja Helm..."
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# ── 8. StorageClass (local-path-provisioner) ──────────────────────────────────
log "Instalacja local-path-provisioner (StorageClass)..."
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.28/deploy/local-path-storage.yaml
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
kubectl rollout status deployment/local-path-provisioner -n local-path-storage --timeout=60s

# ── 10. Postgres (oficjalny obraz, bundled bitnami ma broken tagi) ─────────────
log "Stawianie Postgres..."
kubectl create namespace airflow

kubectl apply -n airflow -f - <<'EOF'
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
spec:
  selector:
    matchLabels:
      app: postgres
  serviceName: postgres
  replicas: 1
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
      - name: postgres
        image: postgres:15-alpine
        env:
        - name: POSTGRES_USER
          value: airflow
        - name: POSTGRES_PASSWORD
          value: airflow
        - name: POSTGRES_DB
          value: airflow
        ports:
        - containerPort: 5432
        volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: [ReadWriteOnce]
      resources:
        requests:
          storage: 5Gi
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
spec:
  selector:
    app: postgres
  ports:
  - port: 5432
EOF

log "Czekam na Postgres..."
until kubectl wait pod -n airflow -l app=postgres --for=condition=Ready --timeout=120s 2>/dev/null; do sleep 5; done
POSTGRES_IP=$(kubectl get svc postgres -n airflow -o jsonpath='{.spec.clusterIP}')
log "Postgres gotowy: $POSTGRES_IP"

# ── 10. Katalog DAGów na masterze ─────────────────────────────────────────────
log "Tworzenie struktury katalogów DAGów..."
MASTER_HOSTNAME=$(hostname)
mkdir -p /opt/airflow/dags/admin
ANALITYCY_LIST=$(echo "$ANALITYCY" | python3 -c "import sys,json; [print(s) for s in json.load(sys.stdin)]")
for analityk in $ANALITYCY_LIST; do
  mkdir -p "/opt/airflow/dags/$analityk"
done
chmod -R 777 /opt/airflow/dags

cat <<'EOF' > /opt/airflow/dags/.airflowignore
\.ipynb_checkpoints
__pycache__
.*\.pyc$
EOF

# ── 11. Airflow via Helm (1.15.0 + zewnętrzny postgres) ───────────────────────
log "Instalacja Apache Airflow via Helm..."
helm repo add apache-airflow https://airflow.apache.org
helm repo update

# hostPath — katalog DAGów z mastera montowany bezpośrednio do podów.
# Wszystkie komponenty Airflow (w tym KubernetesExecutor worker pods) pinowane
# do mastera przez nodeSelector, bo katalog /opt/airflow/dags istnieje tylko tam.
cat <<EOF > /tmp/airflow-values.yaml
dags:
  persistence:
    enabled: false
  gitSync:
    enabled: false

scheduler:
  nodeSelector:
    kubernetes.io/hostname: "$MASTER_HOSTNAME"
  extraVolumes:
    - name: dags
      hostPath:
        path: /opt/airflow/dags
        type: Directory
  extraVolumeMounts:
    - name: dags
      mountPath: /opt/airflow/dags

webserver:
  nodeSelector:
    kubernetes.io/hostname: "$MASTER_HOSTNAME"
  extraVolumes:
    - name: dags
      hostPath:
        path: /opt/airflow/dags
        type: Directory
  extraVolumeMounts:
    - name: dags
      mountPath: /opt/airflow/dags

triggerer:
  nodeSelector:
    kubernetes.io/hostname: "$MASTER_HOSTNAME"
  extraVolumes:
    - name: dags
      hostPath:
        path: /opt/airflow/dags
        type: Directory
  extraVolumeMounts:
    - name: dags
      mountPath: /opt/airflow/dags

workers:
  nodeSelector:
    kubernetes.io/hostname: "$MASTER_HOSTNAME"
  extraVolumes:
    - name: dags
      hostPath:
        path: /opt/airflow/dags
        type: Directory
  extraVolumeMounts:
    - name: dags
      mountPath: /opt/airflow/dags
EOF

helm install airflow-green apache-airflow/airflow \
  --namespace airflow \
  --version "1.15.0" \
  --values /tmp/airflow-values.yaml \
  --set "executor=KubernetesExecutor" \
  --set "postgresql.enabled=false" \
  --set "redis.enabled=false" \
  --set "data.metadataConnection.user=airflow" \
  --set "data.metadataConnection.pass=airflow" \
  --set "data.metadataConnection.host=$POSTGRES_IP" \
  --set "data.metadataConnection.port=5432" \
  --set "data.metadataConnection.db=airflow" \
  --set "data.metadataConnection.protocol=postgresql" \
  --set "env[0].name=AIRFLOW__CORE__LOAD_EXAMPLES" \
  --set-string "env[0].value=False" \
  --set "webserver.service.type=ClusterIP" \
  --set "webserver.defaultUser.enabled=true" \
  --set "webserver.defaultUser.role=Admin" \
  --set "webserver.defaultUser.username=admin" \
  --set "webserver.defaultUser.password=$AIRFLOW_ADMIN_PASSWORD" \
  --set "webserver.defaultUser.email=admin@course.local" \
  --set "webserver.defaultUser.firstName=Admin" \
  --set "webserver.defaultUser.lastName=Instructor" \
  --set "labels.slot=green" \
  --timeout 12m \
  --wait

# ── 11. NodePort — Green-Blue switching Service na porcie 30080 ───────────────
log "Tworzenie switching Service (green-blue) na porcie :30080..."
kubectl apply -n airflow -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: airflow-active
  labels:
    app: airflow
    managed-by: green-blue
spec:
  type: NodePort
  selector:
    component: webserver
    slot: green
  ports:
  - name: http
    port: 8080
    targetPort: 8080
    nodePort: 30080
EOF

# ── 12. Konta analityków + izolacja DAGów przez RBAC ──────────────────────────
log "Tworzenie kont analityków i izolowanych DAGów w Airflow..."
AIRFLOW_POD=$(kubectl get pod -n airflow -l component=webserver -o jsonpath='{.items[0].metadata.name}')

cat <<'PYEOF' > /tmp/setup_analitycy.py
import json, os, subprocess

analitycy = json.loads(os.environ["ANALITYCY"])
airflow_pod = os.environ["AIRFLOW_POD"]
analyst_password = os.environ.get("AIRFLOW_ANALYST_PASSWORD", "defaultPass123!")

def kexec(*cmd):
    return subprocess.run(
        ["kubectl", "exec", "-n", "airflow", airflow_pod, "--"] + list(cmd),
        check=False
    )

# Używamy __ANALITYK__ jako placeholder żeby uniknąć konfliktów z {} w f-stringach
DAG_TEMPLATE = """\
from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.operators.python import PythonOperator
from airflow.models.param import Param
from datetime import datetime
import json, os, urllib.request

ANALITYK = "__ANALITYK__"


def _download_from_gcs(bucket, script_name, run_dir):
    os.makedirs(run_dir, exist_ok=True)
    req = urllib.request.Request(
        "http://metadata.google.internal/computeMetadata/v1"
        "/instance/service-accounts/default/token",
        headers={"Metadata-Flavor": "Google"},
    )
    token = json.loads(urllib.request.urlopen(req).read())["access_token"]
    blob = f"dags/{ANALITYK}/{script_name}".replace("/", "%2F")
    url = f"https://storage.googleapis.com/download/storage/v1/b/{bucket}/o/{blob}?alt=media"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    data = urllib.request.urlopen(req).read()
    open(f"{run_dir}/{script_name}", "wb").write(data)
    print(f"Pobrano {len(data):,} B")


with DAG(
    dag_id="run_script___ANALITYK__",
    schedule=None,
    start_date=datetime(2024, 1, 1),
    catchup=False,
    params={
        "script_name": Param("script.py", type="string", description="Nazwa pliku w GCS"),
    },
    tags=["analitycy", "__ANALITYK__"],
    access_control={
        "__ANALITYK__": {"can_read", "can_edit", "can_delete"},
    },
) as dag:

    download = PythonOperator(
        task_id="download_from_gcs",
        python_callable=_download_from_gcs,
        op_kwargs={
            "bucket": "{{ var.value.get('dag_bucket', '') }}",
            "script_name": "{{ params.script_name }}",
            "run_dir": "/tmp/__ANALITYK___run_{{ ts_nodash }}",
        },
    )

    run = BashOperator(
        task_id="run_script",
        env={
            "SCRIPT": "{{ params.script_name }}",
            "RUN_DIR": "/tmp/__ANALITYK___run_{{ ts_nodash }}",
        },
        append_env=True,
        bash_command="cd $RUN_DIR && python3 $SCRIPT",
    )

    cleanup = BashOperator(
        task_id="cleanup",
        env={"RUN_DIR": "/tmp/__ANALITYK___run_{{ ts_nodash }}"},
        append_env=True,
        bash_command="rm -rf $RUN_DIR",
        trigger_rule="all_done",
    )

    download >> run >> cleanup
"""

for s in analitycy:
    # Konto użytkownika (rola User = dostęp do UI)
    kexec("airflow", "users", "create",
          "--username", s, "--password", analyst_password,
          "--role", "User",
          "--email", s + "@course.local",
          "--firstname", s, "--lastname", "Analityk")

    # Dedykowana rola analityka (wymagana przez access_control na DAGu)
    kexec("airflow", "roles", "create", s)
    kexec("airflow", "users", "add-role", "--username", s, "--role", s)

    # Plik DAG ze scope'owanym access_control
    dag_path = f"/opt/airflow/dags/{s}/run_script_{s}.py"
    with open(dag_path, "w") as f:
        f.write(DAG_TEMPLATE.replace("__ANALITYK__", s))
    print(f"[OK] {s}: rola + DAG run_script_{s}")

print(f"Skonfigurowano {len(analitycy)} analityków z izolowanymi DAGami")
PYEOF

ANALITYCY="$ANALITYCY" AIRFLOW_POD="$AIRFLOW_POD" AIRFLOW_ANALYST_PASSWORD="$AIRFLOW_ANALYST_PASSWORD" python3 /tmp/setup_analitycy.py

# ── 13. JupyterHub via Helm ───────────────────────────────────────────────────
log "Instalacja JupyterHub..."
helm repo add jupyterhub https://hub.jupyter.org/helm-chart/
helm repo update

kubectl create namespace jupyterhub

JUPYTERHUB_VALUES=$(cat <<JHVALUES
hub:
  config:
    DummyAuthenticator:
      password: "$JUPYTERHUB_ANALYST_PASSWORD"
    JupyterHub:
      authenticator_class: dummy
  extraConfig:
    allowlist: |
      c.Authenticator.allowed_users = {
        'analityk01','analityk02','analityk03','analityk04',
        'analityk05','analityk06','analityk07','analityk08',
        'analityk09','analityk10','analityk11','analityk12',
        'analityk13','analityk14','analityk15','analityk16',
        'admin'
      }

proxy:
  service:
    type: NodePort
    nodePorts:
      http: 30088

singleuser:
  image:
    name: quay.io/jupyter/scipy-notebook
    tag: "latest"
    pullPolicy: IfNotPresent
  extraEnv:
    AIRFLOW_HOST: "http://airflow-green-webserver.airflow.svc.cluster.local:8080"
    AIRFLOW_USER: "admin"
  storage:
    capacity: 2Gi
    dynamic:
      storageClass: local-path
    extraVolumes:
      - name: airflow-dags
        hostPath:
          path: /opt/airflow/dags
          type: Directory
    extraVolumeMounts:
      - name: airflow-dags
        mountPath: /home/jovyan/airflow-dags
  nodeSelector:
    kubernetes.io/hostname: "$MASTER_HOSTNAME"
  lifecycleHooks:
    postStart:
      exec:
        command:
          - "sh"
          - "-c"
          - |
            pip install -q apache-airflow-client requests 2>&1 | tail -2
            mkdir -p /home/jovyan/airflow-dags/\${JUPYTERHUB_USER}
            ln -sfn /home/jovyan/airflow-dags/\${JUPYTERHUB_USER} /home/jovyan/dags
  cpu:
    limit: 1
    guarantee: 0.25
  memory:
    limit: 2G
    guarantee: 512M
  startTimeout: 120

scheduling:
  userScheduler:
    enabled: false

prePuller:
  hook:
    enabled: false
  continuous:
    enabled: false

cull:
  enabled: true
  timeout: 3600
  every: 300
JHVALUES
)

echo "$JUPYTERHUB_VALUES" | helm install jupyterhub jupyterhub/jupyterhub \
  --namespace jupyterhub \
  --version "3.3.7" \
  --values /dev/stdin \
  --timeout 10m \
  --wait

log "JupyterHub gotowy na porcie :30088"

# ── Monitoring: Prometheus + Grafana + OTel Collector + Loki ───────────────────
log "Instalacja stosu monitoringu (Prometheus + Grafana + OTel + Loki)..."

kubectl create namespace monitoring

cat <<EOF > /tmp/kube-prometheus-values.yaml
grafana:
  adminPassword: "$GRAFANA_ADMIN_PASSWORD"
  service:
    type: NodePort
    nodePort: 30300
  dashboardProviders:
    dashboardproviders.yaml:
      apiVersion: 1
      providers:
        - name: default
          orgId: 1
          folder: ""
          type: file
          disableDeletion: false
          editable: true
          options:
            path: /var/lib/grafana/dashboards/default
  dashboards:
    default:
      kubernetes-cluster:
        gnetId: 7249
        revision: 1
        datasource: Prometheus
      node-exporter:
        gnetId: 1860
        revision: 37
        datasource: Prometheus
      airflow:
        gnetId: 19492
        revision: 4
        datasource: Prometheus
  additionalDataSources:
    - name: Loki
      type: loki
      url: http://loki.monitoring:3100
      access: proxy
      isDefault: false
prometheus:
  service:
    type: NodePort
    nodePort: 30090
  prometheusSpec:
    ruleNamespaceSelector: {}
    ruleSelector: {}
    serviceMonitorNamespaceSelector: {}
    serviceMonitorSelector: {}
    podMonitorNamespaceSelector: {}
    podMonitorSelector: {}
    retention: 15d
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: local-path
          accessModes: [ReadWriteOnce]
          resources:
            requests:
              storage: 10Gi
alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: local-path
          accessModes: [ReadWriteOnce]
          resources:
            requests:
              storage: 1Gi
nodeExporter:
  enabled: true
kubeStateMetrics:
  enabled: true
EOF

cat <<'EOF' > /tmp/loki-values.yaml
loki:
  enabled: true
  persistence:
    enabled: true
    storageClassName: local-path
    size: 5Gi
  config:
    auth_enabled: false
    limits_config:
      retention_period: 168h
    schema_config:
      configs:
        - from: "2024-01-01"
          store: boltdb-shipper
          object_store: filesystem
          schema: v11
          index:
            prefix: index_
            period: 24h
promtail:
  enabled: true
  config:
    clients:
      - url: http://loki:3100/loki/api/v1/push
    scrape_configs:
      - job_name: kubernetes-pods
        kubernetes_sd_configs:
          - role: pod
        pipeline_stages:
          - docker: {}
        relabel_configs:
          - source_labels: [__meta_kubernetes_namespace]
            target_label: namespace
          - source_labels: [__meta_kubernetes_pod_name]
            target_label: pod
          - source_labels: [__meta_kubernetes_pod_container_name]
            target_label: container
grafana:
  enabled: false
EOF

cat <<'EOF' > /tmp/otel-collector-values.yaml
mode: daemonset
image:
  repository: otel/opentelemetry-collector-contrib
  tag: "0.102.0"
config:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318
    prometheus:
      config:
        scrape_configs:
          - job_name: airflow
            scrape_interval: 15s
            metrics_path: /metrics
            static_configs:
              - targets:
                  - airflow-green-webserver.airflow.svc.cluster.local:8080
          - job_name: jupyterhub
            scrape_interval: 30s
            metrics_path: /hub/metrics
            static_configs:
              - targets:
                  - hub.jupyterhub.svc.cluster.local:8081
    kubeletstats:
      collection_interval: 20s
      auth_type: serviceAccount
      endpoint: "${env:K8S_NODE_IP}:10250"
      insecure_skip_verify: true
      metric_groups: [node, pod, container]
  processors:
    batch:
      timeout: 10s
      send_batch_size: 1000
    memory_limiter:
      limit_mib: 256
      spike_limit_mib: 64
      check_interval: 5s
    k8sattributes:
      auth_type: serviceAccount
      passthrough: false
      extract:
        metadata:
          - k8s.pod.name
          - k8s.namespace.name
          - k8s.node.name
          - k8s.deployment.name
  exporters:
    prometheusremotewrite:
      endpoint: http://kube-prom-kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090/api/v1/write
      tls:
        insecure: true
    loki:
      endpoint: http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push
      tls:
        insecure: true
  service:
    pipelines:
      metrics:
        receivers: [otlp, prometheus, kubeletstats]
        processors: [memory_limiter, k8sattributes, batch]
        exporters: [prometheusremotewrite]
      logs:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [loki]
clusterRole:
  create: true
  rules:
    - apiGroups: [""]
      resources: [nodes, nodes/metrics, nodes/proxy, services, endpoints, pods]
      verbs: [get, list, watch]
    - nonResourceURLs: [/metrics, /metrics/cadvisor]
      verbs: [get]
env:
  - name: K8S_NODE_IP
    valueFrom:
      fieldRef:
        fieldPath: status.hostIP
EOF

cat <<'EOF' > /tmp/airflow-alerts.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: airflow-alerts
  namespace: monitoring
  labels:
    release: kube-prom
spec:
  groups:
    - name: airflow.critical
      interval: 30s
      rules:
        - alert: AirflowSchedulerDown
          expr: absent(airflow_scheduler_heartbeat) or airflow_scheduler_heartbeat == 0
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "Airflow Scheduler nie odpowiada"
            description: "Scheduler nie wysłał heartbeat od ponad 2 minut."
        - alert: AirflowWebserverDown
          expr: absent(up{job="airflow"})
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "Airflow Webserver niedostępny"
            description: "Brak metryk z Airflow Webservera od ponad 2 minut."
    - name: airflow.warning
      interval: 60s
      rules:
        - alert: AirflowQueuedTasksTooHigh
          expr: airflow_executor_queued_tasks > 20
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Dużo zadań w kolejce ({{ $value }})"
            description: "Ponad 20 zadań czeka na wykonanie — możliwe przeciążenie."
        - alert: NodeHighMemory
          expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > 85
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Wysokie użycie RAM ({{ $labels.instance }}: {{ $value | printf \"%.0f\" }}%)"
            description: "Zużycie RAM powyżej 85% — ryzyko OOMKill."
EOF

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana             https://grafana.github.io/helm-charts
helm repo add open-telemetry      https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

# 1. kube-prometheus-stack (Prometheus + Grafana + AlertManager + node-exporter)
log "Instalacja kube-prometheus-stack..."
helm install kube-prom prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --version "61.3.0" \
  --values /tmp/kube-prometheus-values.yaml \
  --timeout 8m \
  --wait

# 2. Loki + Promtail (agregacja logów)
log "Instalacja Loki + Promtail..."
helm install loki grafana/loki-stack \
  --namespace monitoring \
  --version "2.10.2" \
  --values /tmp/loki-values.yaml \
  --timeout 5m \
  --wait

# 3. OpenTelemetry Collector (DaemonSet — scrape Airflow + JupyterHub)
log "Instalacja OpenTelemetry Collector..."
helm install otel-collector open-telemetry/opentelemetry-collector \
  --namespace monitoring \
  --version "0.97.1" \
  --values /tmp/otel-collector-values.yaml \
  --timeout 5m \
  --wait

# 4. Reguły alertów dla Airflow
log "Wgrywanie reguł alertów Airflow..."
kubectl apply -f /tmp/airflow-alerts.yaml

log "Monitoring gotowy:"
log "  Grafana:    http://$EXTERNAL_IP:30300  (admin / hasło z GRAFANA_ADMIN_PASSWORD)"
log "  Prometheus: http://$EXTERNAL_IP:30090"

# ── Gotowe ─────────────────────────────────────────────────────────────────────
EXTERNAL_IP=$(curl -sf "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip" \
  -H "Metadata-Flavor: Google" || echo "BRAK-IP")

log "========================================"
log "SETUP ZAKOŃCZONY"
log "Airflow UI:    http://$EXTERNAL_IP:30080  (admin / hasło z AIRFLOW_ADMIN_PASSWORD)"
log "JupyterHub:    http://$EXTERNAL_IP:30088  (analityk01..16 / hasło z JUPYTERHUB_ANALYST_PASSWORD)"
log "Grafana:       http://$EXTERNAL_IP:30300  (admin / hasło z GRAFANA_ADMIN_PASSWORD)"
log "Prometheus:    http://$EXTERNAL_IP:30090"
log "========================================"
