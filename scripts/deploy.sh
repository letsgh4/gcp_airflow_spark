#!/bin/bash
set -euo pipefail

# Skrypt do odpalenia całego kursu
# Użycie: ./scripts/deploy.sh <project_id>

PROJECT_ID=${1:-""}
if [[ -z "$PROJECT_ID" ]]; then
  echo "Użycie: $0 <gcp-project-id>"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."
TF_DIR="$PROJECT_ROOT/terraform"

# Wczytaj zmienne z .env
if [[ ! -f "$PROJECT_ROOT/.env" ]]; then
  echo "❌ Błąd: Plik .env nie istnieje"
  echo "📝 Skopiuj plik szablonowy: cp .env.example .env"
  exit 1
fi

# shellcheck source=/dev/null  # .env jest lokalny i nie ma go w repo
source "$PROJECT_ROOT/.env"

# Weryfikuj wymagane zmienne
required_vars=(
  "AIRFLOW_ADMIN_PASSWORD"
  "AIRFLOW_ANALYST_PASSWORD"
  "JUPYTERHUB_ADMIN_PASSWORD"
  "JUPYTERHUB_ANALYST_PASSWORD"
  "GRAFANA_ADMIN_PASSWORD"
  "REGION"
  "ZONE"
)

for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "❌ Błąd: Zmienna '$var' nie jest ustawiona w .env"
    exit 1
  fi
done

echo "==> Deploy dla projektu: $PROJECT_ID"

cd "$TF_DIR"
terraform init
terraform apply \
  -var="project_id=$PROJECT_ID" \
  -var="airflow_admin_password=$AIRFLOW_ADMIN_PASSWORD" \
  -var="airflow_analyst_password=$AIRFLOW_ANALYST_PASSWORD" \
  -var="jupyterhub_admin_password=$JUPYTERHUB_ADMIN_PASSWORD" \
  -var="jupyterhub_analyst_password=$JUPYTERHUB_ANALYST_PASSWORD" \
  -var="grafana_admin_password=$GRAFANA_ADMIN_PASSWORD" \
  -var="region=$REGION" \
  -var="zone=$ZONE" \
  -auto-approve

echo ""
echo "==> Czekam na zakończenie inicjalizacji (~8-12 min)..."
MASTER_IP=$(terraform output -raw master_external_ip)

for i in $(seq 1 40); do
  if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@"$MASTER_IP" \
    "grep -q 'SETUP ZAKOŃCZONY' /var/log/master-init.log" 2>/dev/null; then
    break
  fi
  echo "  Czekam... ($i/40)"
  sleep 20
done

echo ""
echo "===================================="
echo "Klaster gotowy!"
terraform output
echo "===================================="
echo "📋 Dane dostępu:"
echo "  Airflow admin: admin / $AIRFLOW_ADMIN_PASSWORD"
echo "  Airflow analitycy: analityk01-16 / $AIRFLOW_ANALYST_PASSWORD"
echo "  JupyterHub admin: admin / $JUPYTERHUB_ADMIN_PASSWORD"
echo "  JupyterHub analitycy: analityk01-16 / $JUPYTERHUB_ANALYST_PASSWORD"
echo "  Grafana admin: admin / $GRAFANA_ADMIN_PASSWORD"
