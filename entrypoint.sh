#!/usr/bin/env bash
# Container entrypoint.
# Runs as root to perform privileged setup (WireGuard, Tailscale), then drops to the
# unprivileged `agent` user for the interactive shell / command.
set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*"; }

# ---------------------------------------------------------------------------
# WireGuard
# ---------------------------------------------------------------------------
# WIREGUARD_PROFILE=<P>  -> bring up /etc/wireguard/<P>.conf, and ONLY that file.
#                           If it does not exist, no tunnel at all (never fall
#                           back to another project's config).
# WIREGUARD_PROFILE=none -> explicit opt-out.
# WIREGUARD_PROFILE empty/unset -> legacy fallback: wg0.conf, then any *.conf.
# Requires NET_ADMIN + /dev/net/tun.
WG_CONF=""
case "${WIREGUARD_PROFILE:-}" in
    none|NONE|None)
        log "WIREGUARD_PROFILE=none; skipping tunnel setup."
        ;;
    "")
        if [[ -f /etc/wireguard/wg0.conf ]]; then
            WG_CONF="wg0"
        elif compgen -G "/etc/wireguard/*.conf" > /dev/null; then
            f=$(ls /etc/wireguard/*.conf 2>/dev/null | head -n1)
            WG_CONF="$(basename "$f" .conf)"
        else
            log "No WireGuard config found in /etc/wireguard; skipping tunnel setup."
        fi
        ;;
    *)
        if [[ -f "/etc/wireguard/${WIREGUARD_PROFILE}.conf" ]]; then
            WG_CONF="${WIREGUARD_PROFILE}"
        else
            log "WIREGUARD_PROFILE=${WIREGUARD_PROFILE} but /etc/wireguard/${WIREGUARD_PROFILE}.conf does not exist; bringing up NO tunnel."
        fi
        ;;
esac

if [[ -n "${WG_CONF}" ]]; then
    if ip link show "${WG_CONF}" >/dev/null 2>&1; then
        log "WireGuard interface '${WG_CONF}' is already up"
    else
        log "Bringing up WireGuard interface '${WG_CONF}'..."
        if wg-quick up "${WG_CONF}"; then
            log "WireGuard up."
        else
            log "WARNING: wg-quick up ${WG_CONF} failed; continuing without the tunnel."
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Tailscale (kernel mode, via /dev/net/tun + NET_ADMIN)
# ---------------------------------------------------------------------------
# Started only when TAILSCALE_ENABLE=1 or a saved node state already exists in
# /var/lib/tailscale (bind-mounted from configs/tailscale/<PROFILE>). With
# TS_AUTHKEY set it logs in unattended; otherwise it reuses saved state, or
# logs how to log in once interactively. Never fails container start.
TS_STATE_DIR=/var/lib/tailscale
TS_SOCK=/var/run/tailscale/tailscaled.sock

start_tailscale() {
    local profile hostname state i
    profile="${TAILSCALE_PROFILE:-${WORKSPACE_PROFILE:-MI}}"
    hostname="${TAILSCALE_HOSTNAME:-$(printf '%s' "${profile}" | tr '[:upper:]' '[:lower:]')-agent}"
    # Flags shared by every `tailscale up` (login and re-login must match).
    local -a up_args=(--hostname="${hostname}" --accept-routes)
    # shellcheck disable=SC2206  # intentional word splitting of extra flags
    [[ -n "${TAILSCALE_EXTRA_ARGS:-}" ]] && up_args+=(${TAILSCALE_EXTRA_ARGS})

    mkdir -p "${TS_STATE_DIR}" "$(dirname "${TS_SOCK}")"
    if pgrep -x tailscaled >/dev/null 2>&1; then
        log "tailscaled already running."
    else
        log "Starting tailscaled (state in ${TS_STATE_DIR}, log /var/log/tailscaled.log)..."
        nohup tailscaled --statedir="${TS_STATE_DIR}" --socket="${TS_SOCK}" \
            >/var/log/tailscaled.log 2>&1 &
    fi
    for i in $(seq 1 30); do
        [[ -S "${TS_SOCK}" ]] && break
        sleep 0.5
    done
    if [[ ! -S "${TS_SOCK}" ]]; then
        log "WARNING: tailscaled did not come up; see /var/log/tailscaled.log."
        return 1
    fi

    if [[ -n "${TS_AUTHKEY:-}" ]]; then
        log "tailscale up --hostname=${hostname} (auth key)..."
        timeout 60 tailscale up --authkey="${TS_AUTHKEY}" "${up_args[@]}" \
            || { log "WARNING: tailscale up with TS_AUTHKEY failed."; return 1; }
    else
        state="$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' 2>/dev/null || true)"
        if [[ "${state}" == "NeedsLogin" || -z "${state}" ]]; then
            log "Tailscale is not logged in (state: ${state:-unknown}). Log in once with:"
            log "  docker exec -it <container> tailscale up ${up_args[*]}"
            log "(or set TS_AUTHKEY in .env). Node state persists in configs/tailscale/${profile}."
            return 0
        fi
    fi
    log "Tailscale: $(tailscale status --json 2>/dev/null | jq -r '"\(.BackendState) as \(.Self.HostName) \(.Self.TailscaleIPs // [] | join(" "))"' 2>/dev/null || echo unknown)"
}

if [[ "${TAILSCALE_ENABLE:-0}" == "1" || -s "${TS_STATE_DIR}/tailscaled.state" ]]; then
    start_tailscale || log "WARNING: Tailscale setup failed; continuing without it."
else
    log "Tailscale disabled (TAILSCALE_ENABLE!=1 and no saved state); skipping."
fi

# ---------------------------------------------------------------------------
# GitHub: authenticate `gh` + `git` from a classic PAT (GH_TOKEN/GITHUB_TOKEN).
# `gh` reads GH_TOKEN from the env automatically; for `git` over HTTPS we write
# a credential-store entry so clone/push to private repos works unattended.
# ---------------------------------------------------------------------------
GH_TOKEN_VAL="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [[ -n "${GH_TOKEN_VAL}" ]]; then
    log "Configuring GitHub credentials from token..."
    gosu agent bash -c '
        set -e
        git config --global credential.helper store
        umask 077
        printf "https://x-access-token:%s@github.com\n" "$GH_TOKEN" > "$HOME/.git-credentials"
    ' || log "WARNING: GitHub credential setup failed."
else
    log "No GH_TOKEN set; skipping GitHub auth."
fi

# ---------------------------------------------------------------------------
# Best-effort ownership fixups on bind-mounted config (read-only safe).
# On macOS Docker Desktop these mounts are usually fine regardless of uid.
# ---------------------------------------------------------------------------
if [[ -d /home/agent/.config/opencode ]]; then
    mkdir -p /home/agent/.config/opencode 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# opencode persisted data: ~/.local/share/opencode is a symlink into the
# mounted ~/.config/opencode (=> configs/opencode/data on the host). Make sure
# the target dir exists so sessions survive container recreation.
# ---------------------------------------------------------------------------
gosu agent mkdir -p /home/agent/.config/opencode/data 2>/dev/null || true

# ---------------------------------------------------------------------------
# Drop privileges and exec the command (default: bash).
# ---------------------------------------------------------------------------
log "Dropping to user 'agent'; running: $*"
exec gosu agent "$@"
