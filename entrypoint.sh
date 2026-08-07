#!/usr/bin/env bash
# Container entrypoint.
# Runs as root to perform privileged setup (WireGuard), then drops to the
# unprivileged `agent` user for the interactive shell / command.
set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*"; }

# ---------------------------------------------------------------------------
# WireGuard
# ---------------------------------------------------------------------------
# Bring up the selected profile: WIREGUARD_PROFILE=<P> -> /etc/wireguard/<P>.conf
# (falls back to wg0.conf, then any *.conf). Requires NET_ADMIN + /dev/net/tun.
WG_CONF=""
if [[ -n "${WIREGUARD_PROFILE:-}" && -f "/etc/wireguard/${WIREGUARD_PROFILE}.conf" ]]; then
    # Profile selected via env var, e.g. WIREGUARD_PROFILE=GO -> /etc/wireguard/GO.conf
    WG_CONF="${WIREGUARD_PROFILE}"
elif [[ -f /etc/wireguard/wg0.conf ]]; then
    WG_CONF="wg0"
elif compgen -G "/etc/wireguard/*.conf" > /dev/null; then
    # Fall back to the first *.conf present (e.g. MI.conf).
    f=$(ls /etc/wireguard/*.conf 2>/dev/null | head -n1)
    WG_CONF="$(basename "$f" .conf)"
fi

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
else
    log "No WireGuard config found in /etc/wireguard; skipping tunnel setup."
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
# Drop privileges and exec the command (default: bash).
# ---------------------------------------------------------------------------
log "Dropping to user 'agent'; running: $*"
exec gosu agent "$@"
