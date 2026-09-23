#!/usr/bin/env bash
# Genera inventory/hosts.ini de forma interactiva para un clúster de
# 1 master + N workers (N a elegir) y ajusta las variables relacionadas en
# inventory/group_vars/all.yml. Correr desde la raíz de k8s-ansible, ANTES de
# "ansible-playbook reset.yml" / "ansible-playbook site.yml".
#
# Nota: solo soporta 1 master (control-plane único, sin HA). Ver README/
# docs si en algún momento necesitas múltiples masters.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

ask() {
  local prompt="$1" default="$2" var
  read -rp "$prompt${default:+ [$default]}: " var
  echo "${var:-$default}"
}

require_ip() {
  local label="$1" value="$2"
  if [ -z "$value" ]; then
    echo "Error: la IP de $label es obligatoria." >&2
    exit 1
  fi
}

echo "=== Configuración del inventario (1 master + N workers) ==="
echo ""

ssh_user=$(ask "Usuario SSH con sudo en todos los nodos" "ansible")

master_host=$(ask "Hostname del master" "k8s.master01")
master_ip=$(ask "IP del master" "")
require_ip "master" "$master_ip"

n_workers=$(ask "¿Cuántos workers?" "2")
if ! [[ "$n_workers" =~ ^[0-9]+$ ]] || [ "$n_workers" -lt 1 ]; then
  echo "Error: el número de workers debe ser un entero >= 1." >&2
  exit 1
fi

workers_block=""
for i in $(seq 1 "$n_workers"); do
  default_host="k8s.worker$(printf '%02d' "$i")"
  wh=$(ask "Hostname del worker $i" "$default_host")
  wi=$(ask "IP del worker $i" "")
  require_ip "worker $i" "$wi"
  workers_block+="${wh} ansible_host=${wi}"$'\n'
done

cat > inventory/hosts.ini <<EOF
[masters]
${master_host} ansible_host=${master_ip}

[workers]
${workers_block}
[k8s:children]
masters
workers
EOF

sed -i "s/^ansible_user:.*/ansible_user: ${ssh_user}/" inventory/group_vars/all.yml
sed -i "s/^control_plane_endpoint:.*/control_plane_endpoint: ${master_host}/" inventory/group_vars/all.yml

echo ""
echo "== inventory/hosts.ini =="
cat inventory/hosts.ini
echo ""
echo "== inventory/group_vars/all.yml (relevante) =="
grep -E "^ansible_user|^control_plane_endpoint" inventory/group_vars/all.yml

echo ""
echo "Prerrequisito: el usuario '${ssh_user}' debe existir en TODOS los nodos"
echo "(1 master + ${n_workers} worker(s)), con tu llave SSH autorizada y sudo sin"
echo "contraseña (NOPASSWD) - ver Instrucciones.md / README.md. Verifícalo con:"
echo "  ansible k8s -m ping"
echo ""
echo "Siguiente paso:"
echo "  ansible-playbook reset.yml   # limpia un clúster previo, si lo hay"
echo "  ansible-playbook site.yml    # provisiona el clúster completo con Cilium + Hubble"
