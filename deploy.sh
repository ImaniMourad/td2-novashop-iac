#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

: "${OS_AUTH_URL:?Charger le fichier OpenRC avant de lancer le script}"

for tool in terraform ansible ansible-playbook ssh kubectl helm python3; do
  command -v "$tool" >/dev/null || {
    echo "Outil manquant : $tool"
    exit 1
  }
done

if [[ ! -f terraform/terraform.tfvars ]]; then
  echo "Créer terraform/terraform.tfvars à partir de example.tfvars."
  exit 1
fi

echo "=== Provisionnement Terraform ==="
terraform -chdir=terraform init -input=false
terraform -chdir=terraform validate
terraform -chdir=terraform apply

terraform -chdir=terraform output -raw ansible_inventory \
  > ansible/inventory.ini
chmod 600 ansible/inventory.ini

FIP="$(terraform -chdir=terraform output -raw floating_ip)"

echo "=== Attente de SSH ==="
(
  cd ansible
  ansible all -m ansible.builtin.wait_for_connection \
    -a "timeout=300 sleep=5" --ask-pass \
    --ssh-common-args="-o PreferredAuthentications=password -o PubkeyAuthentication=no -o StrictHostKeyChecking=accept-new"
)

echo "=== Attente de cloud-init ==="
ssh -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    "ubuntu@$FIP" 'sudo cloud-init status --wait'

echo "=== Configuration Ansible ==="
(
  cd ansible
  ansible-playbook playbook.yml --ask-pass
)

echo "=== Tunnel Kubernetes temporaire ==="
RUN_DIR="$(mktemp -d)"
CONTROL_SOCKET="$RUN_DIR/ssh-control"

cleanup() {
  ssh -S "$CONTROL_SOCKET" -O exit "ubuntu@$FIP" \
    >/dev/null 2>&1 || true
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT

# Port distinct du tunnel interactif habituel sur 6443.
ssh -fN -M -S "$CONTROL_SOCKET" \
  -L 127.0.0.1:16443:127.0.0.1:6443 \
  -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  "ubuntu@$FIP"

python3 - "$PROJECT_DIR/ansible/kubeconfig" "$RUN_DIR/kubeconfig" <<'PY'
import os
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()
old = "https://127.0.0.1:6443"
if old not in source:
    raise SystemExit("Adresse inattendue dans le kubeconfig")
destination = Path(sys.argv[2])
destination.touch(mode=0o600)
os.chmod(destination, 0o600)
destination.write_text(source.replace(old, "https://127.0.0.1:16443"))
PY

export KUBECONFIG="$RUN_DIR/kubeconfig"
kubectl --request-timeout=20s get nodes

echo "=== Déploiement PostgreSQL ==="
helm upgrade --install postgres ./helm/postgres \
  -n td2 --create-namespace --wait --timeout 5m

kubectl --request-timeout=120s -n td2 exec postgres-0 -- \
  sh -c 'for i in $(seq 1 30); do pg_isready -U app -d appdb && exit 0; sleep 2; done; exit 1'

kubectl -n td2 exec -i postgres-0 -- \
  psql -v ON_ERROR_STOP=1 -U app -d appdb \
  < sql/001-create-visits.sql

echo "=== Déploiement backend et frontend ==="
helm upgrade --install backend ./helm/backend \
  -n td2 --wait --timeout 5m
helm upgrade --install frontend ./helm/frontend \
  -n td2 --wait --timeout 5m

echo "=== Vérification finale ==="
helm list -n td2
kubectl -n td2 get pods,svc,ingress,pvc
echo "NovaShop : http://$FIP"
