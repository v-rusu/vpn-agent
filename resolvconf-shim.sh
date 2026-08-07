#!/bin/sh
# Minimal resolvconf shim for containers (no systemd / systemd-resolved).
#
# Implements ONLY the subset of resolvconf(8) that wg-quick invokes:
#   resolvconf -a IFACE -m 0 -x     # stdin: nameserver/search lines
#   resolvconf -d IFACE             # remove them
#
# The Debian `resolvconf` package needs systemd-resolved (sd_bus), which does
# not exist in a container, so wg-quick aborts at the DNS step. This shim
# edits /etc/resolv.conf directly using a marked block per interface.
#
# Note: /etc/resolv.conf is bind-mounted by Docker, so we overwrite it in
# place (via `cat >`) rather than renaming over it (which fails with EBUSY).
set -eu

CONF=/etc/resolv.conf
op=${1:-}
[ "$op" = "-a" ] || [ "$op" = "-d" ] || exit 0
shift 2>/dev/null || true
iface=${1:-}
[ -n "$iface" ] || exit 0

B="# resolvconf:$iface begin"
E="# resolvconf:$iface end"

remove_block() {
    awk -v b="$B" -v e="$E" '$0==b{f=1} !f{print} $0==e{f=0}' "$CONF" > "$CONF.tmp" 2>/dev/null \
        && cat "$CONF.tmp" > "$CONF" 2>/dev/null
    rm -f "$CONF.tmp"
}

case "$op" in
    -a)
        remove_block 2>/dev/null || true
        { echo "$B"; cat; echo "$E"; } >> "$CONF"
        ;;
    -d)
        remove_block 2>/dev/null || true
        ;;
esac
exit 0
