#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   sudo bash install.sh /path/to/id_ed25519_codex.pub [/extra/read/path ...]

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PUBLIC_KEY_FILE="${1:-}"
shift || true
EXTRA_READ_PATHS=("$@")
DIAG_USER="codexdiag"
KUBECONFIG_PATH="/home/$DIAG_USER/.kube/config"

if [[ "$EUID" -ne 0 ]]; then
  echo "Run this script as root." >&2
  exit 1
fi

if [[ -z "$PUBLIC_KEY_FILE" || ! -f "$PUBLIC_KEY_FILE" ]]; then
  echo "Usage: sudo bash install.sh /path/to/id_ed25519_codex.pub [/extra/read/path ...]" >&2
  exit 1
fi

if ! command -v setfacl >/dev/null 2>&1; then
  apt-get update
  apt-get install -y acl
fi

if ! id "$DIAG_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$DIAG_USER"
fi

usermod -aG systemd-journal "$DIAG_USER"

install -d -o "$DIAG_USER" -g "$DIAG_USER" -m 0700 "/home/$DIAG_USER/.ssh"
install -d -o "$DIAG_USER" -g "$DIAG_USER" -m 0700 "/home/$DIAG_USER/.kube"
install -o root -g root -m 0755 "$SCRIPT_DIR/codexdiag-dispatch" /usr/local/sbin/codexdiag-dispatch

PUBLIC_KEY="$(tr -d '\r\n' < "$PUBLIC_KEY_FILE")"
printf 'restrict,command="/usr/local/sbin/codexdiag-dispatch" %s\n' "$PUBLIC_KEY" \
  > "/home/$DIAG_USER/.ssh/authorized_keys"
chown "$DIAG_USER:$DIAG_USER" "/home/$DIAG_USER/.ssh/authorized_keys"
chmod 0600 "/home/$DIAG_USER/.ssh/authorized_keys"

/usr/local/bin/k3s kubectl apply -f "$SCRIPT_DIR/rbac.yaml"

for _ in $(seq 1 30); do
  TOKEN_B64="$(/usr/local/bin/k3s kubectl get secret codex-diagnostics-token \
    -n kube-system -o jsonpath='{.data.token}' 2>/dev/null || true)"
  CA_B64="$(/usr/local/bin/k3s kubectl get secret codex-diagnostics-token \
    -n kube-system -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)"
  [[ -n "$TOKEN_B64" && -n "$CA_B64" ]] && break
  sleep 1
done

if [[ -z "${TOKEN_B64:-}" || -z "${CA_B64:-}" ]]; then
  echo "ServiceAccount token was not populated." >&2
  exit 1
fi

TOKEN="$(printf '%s' "$TOKEN_B64" | base64 -d)"
cat > "$KUBECONFIG_PATH" <<KUBECONFIG
apiVersion: v1
kind: Config
clusters:
  - name: local-k3s
    cluster:
      server: https://127.0.0.1:6443
      certificate-authority-data: $CA_B64
users:
  - name: codex-diagnostics
    user:
      token: $TOKEN
contexts:
  - name: codex-diagnostics@local-k3s
    context:
      cluster: local-k3s
      user: codex-diagnostics
current-context: codex-diagnostics@local-k3s
KUBECONFIG
chown "$DIAG_USER:$DIAG_USER" "$KUBECONFIG_PATH"
chmod 0600 "$KUBECONFIG_PATH"

add_file_acl() {
  local path="$1"
  [[ -f "$path" ]] || return 0
  setfacl -m "u:$DIAG_USER:r--" "$path"
}

add_tree_acl() {
  local path="$1"
  [[ -d "$path" ]] || return 0

  find "$path" -type d -exec setfacl -m "u:$DIAG_USER:r-x" {} +
  find "$path" -type f -exec setfacl -m "u:$DIAG_USER:r--" {} +

  # New files and directories inherit read-only access for the diagnostics user.
  find "$path" -type d -exec setfacl -m "d:u:$DIAG_USER:r-x" {} +
}

add_file_acl /etc/rancher/k3s/config.yaml
add_file_acl /var/lib/rancher/k3s/server/audit-policy.yaml
add_tree_acl /var/lib/rancher/k3s/server/manifests
add_tree_acl /opt/k3s-audit
add_tree_acl /opt/install/mywebs_install

for path in "${EXTRA_READ_PATHS[@]}"; do
  if [[ -f "$path" ]]; then
    add_file_acl "$path"
  elif [[ -d "$path" ]]; then
    add_tree_acl "$path"
  else
    echo "Warning: skipped missing path: $path" >&2
  fi
done

runuser -u "$DIAG_USER" -- env KUBECONFIG="$KUBECONFIG_PATH" \
  /usr/local/bin/k3s kubectl get namespaces >/dev/null

cat <<'DONE'
Installed read-only Codex diagnostics access.

Next steps on Windows:
1. Add an SSH alias using windows/ssh-config.example.
2. Test: ssh myk3s-ro help
3. Test: ssh myk3s-ro kube get pods -A -o wide
4. Copy .agents/skills/k3s-remote-diagnostics into the repository.
DONE
