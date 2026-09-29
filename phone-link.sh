#!/usr/bin/env bash
# Print a phone-usable omp collab guest link.
#
# The PC hosts the collab room on its own relay at 127.0.0.1:7466. The phone reaches
# that relay through an iroh-ssh -L forward, so the link must be rewritten to the
# phone's own localhost:<forward-port> (127.0.0.1 is in the SPA's LOCAL_HOSTNAMES, so
# a plain ws:// link is accepted there and no TLS is needed).
#
# Usage: phone-link.sh [forward-port]   (default 8443)
set -euo pipefail

OMP=/home/kir/.bun/bin/omp
PORT="${1:-8443}"

instanceId=$("$OMP" collab list --json 2>/dev/null | grep -oE '"instanceId": *"[^"]+"' | head -1 | cut -d'"' -f4)
if [ -z "$instanceId" ]; then
  echo "no running collab host (start omp in tmux with the overlay first)" >&2
  exit 1
fi

url=$("$OMP" collab link "$instanceId" --json 2>/dev/null | grep -oE '"url": *"[^"]+"' | cut -d'"' -f4)
if [ -z "$url" ]; then
  echo "collab link unavailable for $instanceId (stale generation? re-run omp collab list)" >&2
  exit 1
fi

printf '%s\n' "${url//127.0.0.1:7466/127.0.0.1:$PORT}"
