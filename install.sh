#!/usr/bin/env bash
# Materialize (or repair) the omp remote-access deployment on this machine.
#
# Everything lives in this repo so a wiped runtime dir is one command away from
# being back:  ~/Code/omp-remote/install.sh
#
# Runtime dir (disposable, may be cleaned by other agents):
#   ~/.local/share/omp-remote/
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${OMP_REMOTE_DIR:-$HOME/.local/share/omp-remote}"
UNITDIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

mkdir -p "$DEST/dist" "$DEST/sshd" "$UNITDIR"

install -m755 "$REPO/collab-serve.ts"   "$DEST/collab-serve.ts"
install -m755 "$REPO/iroh-serve.sh"     "$DEST/iroh-serve.sh"
install -m755 "$REPO/phone-link.sh"     "$DEST/phone-link.sh"
install -m644 "$REPO/README.md"         "$DEST/README.md"
install -m644 "$REPO/collab-overlay.yml" "$DEST/collab-overlay.yml"
cp -fR "$REPO/dist/." "$DEST/dist/"

# harness-remote leg: native-session gateway + its browser/phone client bundle
mkdir -p "$DEST/harness-web"
install -m755 "$REPO/harness-web/serve.ts" "$DEST/harness-web/serve.ts"
cp -fR "$REPO/harness-web/dist/." "$DEST/harness-web/dist/"

# sshd: static config, per-machine host key (kept if it already exists)
install -m600 "$REPO/sshd/sshd_config" "$DEST/sshd/sshd_config"
if [ ! -f "$DEST/sshd/host_ed25519" ]; then
  ssh-keygen -q -t ed25519 -N '' -f "$DEST/sshd/host_ed25519"
fi
chmod 600 "$DEST/sshd/host_ed25519"

for unit in omp-sshd omp-iroh-ssh omp-collab-relay omp-tmux harness-remote harness-remote-web; do
  install -m644 "$REPO/units/$unit.service" "$UNITDIR/$unit.service"
done

systemctl --user daemon-reload
systemctl --user enable --now omp-sshd.service omp-iroh-ssh.service omp-collab-relay.service

# harness-remote leg needs its launcher on PATH (`npm i -g harness-remote`) and bun.
if command -v harness-remote >/dev/null 2>&1 && command -v bun >/dev/null 2>&1; then
  systemctl --user enable --now harness-remote.service harness-remote-web.service
else
  echo "WARNING: harness-remote and/or bun not on PATH; skipping harness leg." >&2
  echo "         install it with: npm i -g harness-remote" >&2
fi
# oneshot guard: recreate the tmux session only when it is actually missing, never kill a live one
systemctl --user enable omp-tmux.service
if tmux has-session -t omp 2>/dev/null; then
  systemctl --user start omp-tmux.service
else
  systemctl --user restart omp-tmux.service
fi

echo "deployed to $DEST"
