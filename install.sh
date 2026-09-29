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
cp -f "$REPO/dist/." "$DEST/dist/"

# sshd: static config, per-machine host key (kept if it already exists)
install -m600 "$REPO/sshd/sshd_config" "$DEST/sshd/sshd_config"
if [ ! -f "$DEST/sshd/host_ed25519" ]; then
  ssh-keygen -q -t ed25519 -N '' -f "$DEST/sshd/host_ed25519"
fi
chmod 600 "$DEST/sshd/host_ed25519"

for unit in omp-sshd omp-iroh-ssh omp-collab-relay omp-tmux; do
  install -m644 "$REPO/units/$unit.service" "$UNITDIR/$unit.service"
done

systemctl --user daemon-reload
systemctl --user enable --now omp-sshd.service omp-iroh-ssh.service omp-collab-relay.service
# oneshot guard: recreates the tmux session only when it is missing
systemctl --user enable omp-tmux.service
systemctl --user restart omp-tmux.service

echo "deployed to $DEST"
