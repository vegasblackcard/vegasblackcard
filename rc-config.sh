#!/usr/bin/env bash
# rc-config.sh - Remote access configuration manager
# Usage: source rc-config.sh && rc <command> [args]

set -euo pipefail

RC_CONFIG_FILE="${RC_CONFIG_FILE:-.remoterc}"
RC_VERSION="1.0.0"

# Load config
_rc_load() {
    if [[ -f "$RC_CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$RC_CONFIG_FILE"
    else
        echo "Error: Config file '$RC_CONFIG_FILE' not found." >&2
        return 1
    fi
}

# Start SSH agent if configured
_rc_agent() {
    if [[ "${RC_SSH_AGENT_AUTOSTART:-false}" == "true" ]]; then
        if [[ -z "${SSH_AGENT_PID:-}" ]]; then
            eval "$(ssh-agent -s)" > /dev/null
            ssh-add "${RC_SSH_KEY:-$HOME/.ssh/id_ed25519}" 2>/dev/null
        fi
    fi
}

# Parse host definition "user@host:port"
_rc_parse_host() {
    local def="$1"
    RC_PARSED_USER="${def%%@*}"
    local rest="${def#*@}"
    RC_PARSED_HOST="${rest%%:*}"
    RC_PARSED_PORT="${rest##*:}"
}

# Connect to a named remote host
_rc_connect() {
    local name="${1:?Usage: rc connect <host_name>}"
    local var="RC_HOST_$(echo "$name" | tr '[:lower:]' '[:upper:]')"
    local host_def="${!var:-}"

    if [[ -z "$host_def" ]]; then
        echo "Error: Host '$name' not defined. Check .remoterc" >&2
        return 1
    fi

    _rc_parse_host "$host_def"
    _rc_agent

    local attempt=0
    while (( attempt < ${RC_RETRY_COUNT:-3} )); do
        echo "Connecting to $name ($RC_PARSED_USER@$RC_PARSED_HOST:$RC_PARSED_PORT)..."
        if ssh ${RC_SSH_OPTS:-} -p "$RC_PARSED_PORT" -i "${RC_SSH_KEY:-$HOME/.ssh/id_ed25519}" \
            "$RC_PARSED_USER@$RC_PARSED_HOST" "${@:2}"; then
            return 0
        fi
        attempt=$((attempt + 1))
        if (( attempt < ${RC_RETRY_COUNT:-3} )); then
            echo "Connection failed. Retrying in ${RC_RETRY_DELAY:-2}s... (attempt $((attempt+1))/${RC_RETRY_COUNT:-3})"
            sleep "${RC_RETRY_DELAY:-2}"
        fi
    done
    echo "Error: Failed to connect after ${RC_RETRY_COUNT:-3} attempts." >&2
    return 1
}

# Open an SSH tunnel
_rc_tunnel() {
    local name="${1:?Usage: rc tunnel <tunnel_name> <host_name>}"
    local host="${2:?Usage: rc tunnel <tunnel_name> <host_name>}"
    local var="RC_TUNNEL_$(echo "$name" | tr '[:lower:]' '[:upper:]')"
    local tunnel_def="${!var:-}"

    if [[ -z "$tunnel_def" ]]; then
        echo "Error: Tunnel '$name' not defined. Check .remoterc" >&2
        return 1
    fi

    local host_var="RC_HOST_$(echo "$host" | tr '[:lower:]' '[:upper:]')"
    local host_def="${!host_var:-}"

    if [[ -z "$host_def" ]]; then
        echo "Error: Host '$host' not defined. Check .remoterc" >&2
        return 1
    fi

    _rc_parse_host "$host_def"

    local local_port="${tunnel_def%%:*}"
    local remote_part="${tunnel_def#*:}"

    echo "Opening tunnel: localhost:$local_port -> $remote_part via $RC_PARSED_HOST..."
    ssh ${RC_SSH_OPTS:-} -N -f -L "$tunnel_def" \
        -p "$RC_PARSED_PORT" -i "${RC_SSH_KEY:-$HOME/.ssh/id_ed25519}" \
        "$RC_PARSED_USER@$RC_PARSED_HOST"
    echo "Tunnel established on localhost:$local_port"
}

# Sync files to a remote host
_rc_sync() {
    local host="${1:?Usage: rc sync <host_name> <local_path> <remote_path>}"
    local local_path="${2:?Usage: rc sync <host_name> <local_path> <remote_path>}"
    local remote_path="${3:?Usage: rc sync <host_name> <local_path> <remote_path>}"

    local host_var="RC_HOST_$(echo "$host" | tr '[:lower:]' '[:upper:]')"
    local host_def="${!host_var:-}"

    if [[ -z "$host_def" ]]; then
        echo "Error: Host '$host' not defined." >&2
        return 1
    fi

    _rc_parse_host "$host_def"

    local exclude_args=""
    for pattern in ${RC_SYNC_EXCLUDE:-}; do
        exclude_args="$exclude_args --exclude=$pattern"
    done

    local dry_run_flag=""
    if [[ "${RC_SYNC_DRY_RUN:-false}" == "true" ]]; then
        dry_run_flag="--dry-run"
    fi

    echo "Syncing $local_path -> $RC_PARSED_USER@$RC_PARSED_HOST:$remote_path..."
    rsync ${RC_SYNC_OPTS:--avz --progress} $dry_run_flag $exclude_args \
        -e "ssh -p $RC_PARSED_PORT -i ${RC_SSH_KEY:-$HOME/.ssh/id_ed25519} ${RC_SSH_OPTS:-}" \
        "$local_path" "$RC_PARSED_USER@$RC_PARSED_HOST:$remote_path"
}

# List all configured hosts
_rc_hosts() {
    echo "Configured hosts:"
    while IFS= read -r line; do
        local name="${line#RC_HOST_}"
        name="${name%%=*}"
        local value="${line#*=}"
        value="${value//\"/}"
        echo "  $(echo "$name" | tr '[:upper:]' '[:lower:]') -> $value"
    done < <(grep -E '^RC_HOST_' "$RC_CONFIG_FILE" | grep -v '^#')
}

# List all configured tunnels
_rc_tunnels() {
    echo "Configured tunnels:"
    while IFS= read -r line; do
        local name="${line#RC_TUNNEL_}"
        name="${name%%=*}"
        local value="${line#*=}"
        value="${value//\"/}"
        echo "  $(echo "$name" | tr '[:upper:]' '[:lower:]') -> $value"
    done < <(grep -E '^RC_TUNNEL_' "$RC_CONFIG_FILE" | grep -v '^#')
}

# Log connection
_rc_log() {
    if [[ "${RC_LOG_CONNECTIONS:-false}" == "true" ]]; then
        local log_dir="${RC_LOG_DIR:-$HOME/.remoterc/logs}"
        mkdir -p "$log_dir"
        echo "$(date -Iseconds) $*" >> "$log_dir/connections.log"

        # Cleanup old logs
        if [[ "${RC_LOG_RETENTION_DAYS:-30}" -gt 0 ]]; then
            find "$log_dir" -name "*.log" -mtime "+${RC_LOG_RETENTION_DAYS:-30}" -delete 2>/dev/null || true
        fi
    fi
}

# Main entry point
rc() {
    _rc_load || return 1

    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        connect|c)  _rc_log "connect $*"; _rc_connect "$@" ;;
        tunnel|t)   _rc_log "tunnel $*"; _rc_tunnel "$@" ;;
        sync|s)     _rc_log "sync $*"; _rc_sync "$@" ;;
        hosts|h)    _rc_hosts ;;
        tunnels)    _rc_tunnels ;;
        version|v)  echo "rc-config v$RC_VERSION" ;;
        help|*)
            cat <<'HELP'
rc - Remote access configuration manager

Commands:
  connect, c  <host> [cmd]                Connect to a remote host (optionally run a command)
  tunnel,  t  <tunnel_name> <host>        Open an SSH tunnel through a host
  sync,    s  <host> <local> <remote>     Rsync files to a remote host
  hosts,   h                              List configured hosts
  tunnels                                 List configured tunnels
  version, v                              Show version

Configuration:
  Edit .remoterc to define hosts, tunnels, and settings.

Examples:
  rc connect dev                 # SSH into the dev server
  rc connect dev "ls -la"       # Run a command on dev
  rc tunnel db dev               # Forward local:5433 -> dev:5432
  rc sync staging ./app /opt/app # Rsync ./app to staging:/opt/app
HELP
            ;;
    esac
}
