#!/bin/bash
set -euo pipefail
exec > /var/log/worker-init.log 2>&1

META="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
H="Metadata-Flavor: Google"
JOIN_BUCKET=$(curl -sf "$META/tf_join_bucket" -H "$H")
WORKER_ID=$(curl -sf   "$META/tf_worker_id"   -H "$H")
K8S_VERSION="1.29"

log() { echo "[$(date '+%H:%M:%S')] worker-$WORKER_ID: $*"; }

# Startup script uruchamia się przy każdym starcie VM (np. po zmianie typu maszyny).
# Węzeł już dołączony → kubelet wstaje sam z systemd, a ponowny kubeadm join by się nie udał.
if [[ -f /etc/kubernetes/kubelet.conf ]]; then
  swapoff -a
  log "Węzeł już jest w klastrze (/etc/kubernetes/kubelet.conf istnieje) — pomijam instalację i join."
  exit 0
fi

# ── 1. System deps ─────────────────────────────────────────────────────────────
log "Aktualizacja systemu..."
apt-get update -qq
apt-get install -y -qq curl wget gnupg2 apt-transport-https ca-certificates \
  software-properties-common

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

# ── 4. Czekaj na join-command od mastera (max 10 min) ─────────────────────────
log "Oczekiwanie na join-command z GCS..."
for i in $(seq 1 60); do
  if gsutil -q stat "gs://$JOIN_BUCKET/join-command.sh" 2>/dev/null; then
    break
  fi
  log "Próba $i/60 — plik jeszcze nie gotowy, czekam 10s..."
  sleep 10
done

gsutil cp "gs://$JOIN_BUCKET/join-command.sh" /tmp/join-command.sh
chmod +x /tmp/join-command.sh

log "Dołączanie do klastra K8s..."
bash /tmp/join-command.sh

log "Worker $WORKER_ID gotowy. K8s worker uruchomiony."
