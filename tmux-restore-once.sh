#!/usr/bin/env bash
# Auto-restore the last resurrect save once per tmux server lifetime.
# Invoked by the `client-attached` tmux hook in ~/.tmux.conf.
restore_script="$HOME/.tmux/plugins/tmux-resurrect/scripts/restore.sh"
[ -f "$restore_script" ] || exit 0

restored="$(tmux show -gv @restored 2>/dev/null || true)"
if [ -z "$restored" ]; then
    tmux set -g @restored 1
    "$restore_script" >/tmp/tmux-restore.log 2>&1 || true
fi
