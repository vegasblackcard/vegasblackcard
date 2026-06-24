#!/usr/bin/env bash
# rc-config.sh - Remote access configuration manager
# Usage: source rc-config.sh && rc <command> [args]
#
# NOTE: This file is meant to be sourced into an interactive shell, so it does
# NOT enable `set -euo pipefail`. Shell options set here are not function-scoped
# in bash, so enabling `-e`/`-u` would leak into the user's session and a single
# failed command (e.g. an unset host) could terminate their shell. Error
# handling is instead done explicitly via `${var:?msg}` guards and `return 1`.

RC_CONFIG_FILE="${RC_CONFIG_FILE:-.remoterc}"
RC_VERSION="1.1.0"

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

# Parse host definition "user@host[:port]"
# Falls back to RC_DEFAULT_USER / RC_DEFAULT_PORT when a part is omitted.
_rc_parse_host() {
    local def="$1"

    if [[ "$def" == *"@"* ]]; then
        RC_PARSED_USER="${def%%@*}"
        def="${def#*@}"
    else
        RC_PARSED_USER="${RC_DEFAULT_USER:-$USER}"
    fi

    if [[ "$def" == *":"* ]]; then
        RC_PARSED_HOST="${def%%:*}"
        RC_PARSED_PORT="${def##*:}"
    else
        RC_PARSED_HOST="$def"
        RC_PARSED_PORT="${RC_DEFAULT_PORT:-22}"
    fi
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

    local attempt=0 ssh_exit=0
    while (( attempt < ${RC_RETRY_COUNT:-3} )); do
        echo "Connecting to $name ($RC_PARSED_USER@$RC_PARSED_HOST:$RC_PARSED_PORT)..."
        ssh ${RC_SSH_OPTS:-} -p "$RC_PARSED_PORT" -i "${RC_SSH_KEY:-$HOME/.ssh/id_ed25519}" \
            "$RC_PARSED_USER@$RC_PARSED_HOST" "${@:2}"
        ssh_exit=$?

        # Exit 0 = success. Any non-255 code is the remote command's own exit
        # status (the connection worked), so don't retry that either.
        if (( ssh_exit != 255 )); then
            return "$ssh_exit"
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

# Validate the config file and environment without connecting anywhere
_rc_check() {
    local problems=0

    if [[ ! -f "$RC_CONFIG_FILE" ]]; then
        echo "FAIL: config file '$RC_CONFIG_FILE' not found." >&2
        return 1
    fi
    echo "OK: config file '$RC_CONFIG_FILE' found."

    local key="${RC_SSH_KEY:-$HOME/.ssh/id_ed25519}"
    if [[ -f "$key" ]]; then
        echo "OK: SSH key '$key' present."
    else
        echo "WARN: SSH key '$key' not found."
        problems=$((problems + 1))
    fi

    local found_host=0
    while IFS= read -r line; do
        found_host=1
        local name="${line#RC_HOST_}"; name="${name%%=*}"
        local value="${line#*=}"; value="${value//\"/}"
        if [[ "$value" == *"@"*  ]]; then
            echo "OK: host '$(echo "$name" | tr '[:upper:]' '[:lower:]')' = $value"
        else
            echo "WARN: host '$name' = '$value' has no user@ part (will use RC_DEFAULT_USER)."
            problems=$((problems + 1))
        fi
    done < <(grep -E '^RC_HOST_' "$RC_CONFIG_FILE" | grep -v '^#')

    if (( found_host == 0 )); then
        echo "WARN: no RC_HOST_* entries defined."
        problems=$((problems + 1))
    fi

    if (( problems == 0 )); then
        echo "Config check passed."
        return 0
    fi
    echo "Config check finished with $problems warning(s)."
    return 1
}

# Print usage
_rc_help() {
    cat <<'HELP'
rc - Remote access configuration manager

Commands:
  connect, c  <host> [cmd]                Connect to a remote host (optionally run a command)
  tunnel,  t  <tunnel_name> <host>        Open an SSH tunnel through a host
  sync,    s  <host> <local> <remote>     Rsync files to a remote host
  hosts,   h                              List configured hosts
  tunnels                                 List configured tunnels
  check                                   Validate config file, SSH key, and hosts
  version, v                              Show version
  help                                    Show this help

Configuration:
  Edit .remoterc to define hosts, tunnels, and settings.

Examples:
  rc connect dev                 # SSH into the dev server
  rc connect dev "ls -la"       # Run a command on dev
  rc tunnel db dev               # Forward local:5433 -> dev:5432
  rc sync staging ./app /opt/app # Rsync ./app to staging:/opt/app
  rc check                       # Sanity-check your .remoterc
HELP
}

# Main entry point
rc() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    # These commands must work even without a config file present.
    case "$cmd" in
        version|v)  echo "rc-config v$RC_VERSION"; return 0 ;;
        help|-h|--help) _rc_help; return 0 ;;
        check)      _rc_check; return $? ;;
    esac

    # Everything below needs the config loaded.
    _rc_load || return 1

    case "$cmd" in
        connect|c)  _rc_log "connect $*"; _rc_connect "$@" ;;
        tunnel|t)   _rc_log "tunnel $*"; _rc_tunnel "$@" ;;
        sync|s)     _rc_log "sync $*"; _rc_sync "$@" ;;
        hosts|h)    _rc_hosts ;;
        tunnels)    _rc_tunnels ;;
        *)          echo "Unknown command: $cmd" >&2; _rc_help; return 1 ;;
    esac
}
