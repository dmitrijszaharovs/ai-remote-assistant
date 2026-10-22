#!/usr/bin/env bash
# Helper wrapper for a remote Linux server.
# Connection details and the sudo password are taken from a local config file,
# so no secrets appear in the command line or in the process list.

set -euo pipefail

CONFIG_FILE="${MY_LINUX_PAL_CONFIG:-$HOME/.config/my-linux-pal/config.env}"

if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

MY_LINUX_PAL_HOST="${MY_LINUX_PAL_HOST:-}"
MY_LINUX_PAL_USER="${MY_LINUX_PAL_USER:-}"
MY_LINUX_PAL_PORT="${MY_LINUX_PAL_PORT:-22}"
MY_LINUX_PAL_KEY="${MY_LINUX_PAL_KEY:-$HOME/.ssh/id_ed25519}"
MY_LINUX_PAL_SUDO_PASS="${MY_LINUX_PAL_SUDO_PASS:-}"

usage() {
    cat <<'EOF'
Usage:
  my-linux-pal.sh info                      Show basic server status
  my-linux-pal.sh run   "<command>"         Run a command as the normal user
  my-linux-pal.sh sudo  "<command>"         Run a command as root
  my-linux-pal.sh put   <local> <remote>    Upload a file
  my-linux-pal.sh get   <remote> <local>    Download a file
  my-linux-pal.sh check                     Test SSH connection and sudo access

Configuration file: ~/.config/my-linux-pal/config.env
  MY_LINUX_PAL_HOST, MY_LINUX_PAL_USER, MY_LINUX_PAL_PORT,
  MY_LINUX_PAL_KEY, MY_LINUX_PAL_SUDO_PASS
EOF
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# Validate the minimal configuration before any remote call.
check_config() {
    [[ -n "$MY_LINUX_PAL_HOST" ]] || die "MY_LINUX_PAL_HOST is not set. Check $CONFIG_FILE"
    [[ -n "$MY_LINUX_PAL_USER" ]] || die "MY_LINUX_PAL_USER is not set. Check $CONFIG_FILE"
    [[ -f "$MY_LINUX_PAL_KEY" ]] || die "SSH key not found: $MY_LINUX_PAL_KEY"
}

TARGET=""
SSH_OPTS=()

init_ssh() {
    check_config
    TARGET="${MY_LINUX_PAL_USER}@${MY_LINUX_PAL_HOST}"
    SSH_OPTS=(
        -i "$MY_LINUX_PAL_KEY"
        -p "$MY_LINUX_PAL_PORT"
        -o BatchMode=yes
        -o ConnectTimeout=10
        -o StrictHostKeyChecking=accept-new
    )
}

# Quote a string so it can be passed safely to the remote shell.
quote() {
    printf '%q' "$1"
}

remote_run() {
    local cmd="$*"
    [[ -n "$cmd" ]] || die "Empty command"
    ssh "${SSH_OPTS[@]}" "$TARGET" "bash -lc $(quote "$cmd")"
}

remote_sudo() {
    local cmd="$*"
    [[ -n "$cmd" ]] || die "Empty command"

    if [[ -n "$MY_LINUX_PAL_SUDO_PASS" ]]; then
        # Password is sent through stdin, not through the command line.
        printf '%s\n' "$MY_LINUX_PAL_SUDO_PASS" |
            ssh "${SSH_OPTS[@]}" "$TARGET" "sudo -S -p '' bash -lc $(quote "$cmd")"
    else
        # No password configured, expect passwordless sudo.
        ssh "${SSH_OPTS[@]}" "$TARGET" "sudo -n bash -lc $(quote "$cmd")"
    fi
}

server_info() {
    remote_run '
        echo "=== Host ==="
        hostname
        uname -a
        echo
        echo "=== Uptime / load ==="
        uptime
        echo
        echo "=== Memory ==="
        free -h
        echo
        echo "=== Disk ==="
        df -h -x tmpfs -x devtmpfs
        echo
        echo "=== Top processes by memory ==="
        ps -eo pid,comm,%cpu,%mem --sort=-%mem | head -n 8
    '
}

connection_check() {
    echo "Checking SSH connection..."
    remote_run 'echo "SSH OK: $(whoami)@$(hostname)"'
    echo "Checking sudo access..."
    remote_sudo 'echo "SUDO OK: $(whoami)"'
}

main() {
    local action="${1:-}"
    shift || true

    case "$action" in
        info)
            init_ssh
            server_info
            ;;
        check)
            init_ssh
            connection_check
            ;;
        run)
            init_ssh
            remote_run "$@"
            ;;
        sudo)
            init_ssh
            remote_sudo "$@"
            ;;
        put)
            init_ssh
            [[ $# -eq 2 ]] || die "Usage: my-linux-pal.sh put <local> <remote>"
            scp -i "$MY_LINUX_PAL_KEY" -P "$MY_LINUX_PAL_PORT" -o BatchMode=yes \
                -o StrictHostKeyChecking=accept-new "$1" "${TARGET}:$2"
            ;;
        get)
            init_ssh
            [[ $# -eq 2 ]] || die "Usage: my-linux-pal.sh get <remote> <local>"
            scp -i "$MY_LINUX_PAL_KEY" -P "$MY_LINUX_PAL_PORT" -o BatchMode=yes \
                -o StrictHostKeyChecking=accept-new "${TARGET}:$1" "$2"
            ;;
        ""|-h|--help|help)
            usage
            ;;
        *)
            die "Unknown action: $action"
            ;;
    esac
}

main "$@"
