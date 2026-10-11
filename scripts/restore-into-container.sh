#!/bin/bash
# Restore what a pre-rebuild container had installed by hand into its recreated
# successor. Run as root inside the NEW container with the backup dir mounted or
# copied in:   scripts/restore-into-container.sh /tmp/restore/<P>-<date>
# Claude Code state is NOT handled here: it lives in configs/claude/<P> (mounted).
set -uo pipefail
B=${1:?usage: restore-into-container.sh <backup dir>}
log() { echo "[restore] $*"; }

# 1. apt packages the old container had beyond the image. Skip what cannot work
#    or is already provided: tmux (the image builds 3.7b), snap/udev/apparmor
#    plumbing (no systemd in the container), and chromium-browser (a snap stub).
skip='^(tmux|snapd|apparmor|udev|systemd-hwe-hwdb|session-migration|squashfs-tools|chromium-browser|dbus-user-session)$'
if [ -s "$B/dpkg.txt" ]; then
  dpkg-query -W -f='${Package}\n' | sort > /tmp/restore-have.txt
  comm -23 "$B/dpkg.txt" /tmp/restore-have.txt | grep -Ev "$skip" > /tmp/restore-apt.txt
  if [ -s /tmp/restore-apt.txt ]; then
    log "apt: installing $(wc -l < /tmp/restore-apt.txt) packages"
    apt-get update -qq
    if ! DEBIAN_FRONTEND=noninteractive xargs -a /tmp/restore-apt.txt apt-get install -y -qq --no-install-recommends >/tmp/restore-apt.log 2>&1; then
      log "apt: batch install failed; retrying one by one"
      while read -r p; do
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$p" >>/tmp/restore-apt.log 2>&1 || log "apt: could not install $p"
      done < /tmp/restore-apt.txt
    fi
  fi
fi

# 2. pip packages beyond the image (system interpreter, as the old ones were).
if [ -s "$B/pip-freeze.txt" ]; then
  pip3 freeze 2>/dev/null | sort > /tmp/restore-pip-have.txt
  sort "$B/pip-freeze.txt" | comm -23 - /tmp/restore-pip-have.txt | grep -v '^-e ' > /tmp/restore-pip.txt
  if [ -s /tmp/restore-pip.txt ]; then
    log "pip: installing $(wc -l < /tmp/restore-pip.txt) packages"
    pip3 install -q --break-system-packages -r /tmp/restore-pip.txt >/tmp/restore-pip.log 2>&1 \
      || { log "pip: pinned install failed; retrying unpinned"; sed 's/==.*//' /tmp/restore-pip.txt > /tmp/restore-pip-unpinned.txt; pip3 install -q --break-system-packages -r /tmp/restore-pip-unpinned.txt >>/tmp/restore-pip.log 2>&1 || log "pip: see /tmp/restore-pip.log"; }
  fi
fi

# 3. Extra binaries in /usr/local/bin (mi: helm, crane).
if [ -s "$B/usr-local-bin.tgz" ]; then
  tar -C /usr/local/bin -xzf "$B/usr-local-bin.tgz" && log "bin: restored $(tar tzf "$B/usr-local-bin.tgz" | tr '\n' ' ')"
fi

# 4. Home: dotfiles and tools, minus what the new image provides itself.
if [ -s "$B/home.tgz" ]; then
  su agent -c "tar -C /home/agent -xzf '$B/home.tgz' --exclude=./.bashrc --exclude=./.profile --exclude=./.tmux.conf --exclude=./.tmux-restore-once.sh --exclude='./.claude.json*'" \
    && log "home: restored"
fi

# 5. Test browsers (Playwright, Puppeteer, Chrome for Testing, Prisma engines).
if [ -s "$B/cache-browsers.tgz" ]; then
  su agent -c "mkdir -p /home/agent/.cache && tar -C /home/agent/.cache -xzf '$B/cache-browsers.tgz'" && log "cache: browsers restored"
fi
log "done"
