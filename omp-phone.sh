#!/usr/bin/env bash
# omp-phone.sh — prepare, install, and test remote OMP access from Termux (Android).
# Companion to the PC-side repo ~/Code/omp-remote. Run inside Termux (bash).
#
#   ./omp-phone.sh prepare   install packages and build iroh-ssh (once; 10-20 min on a phone)
#   ./omp-phone.sh key       create an SSH keypair and print the PUBLIC key to authorize on the PC
#   ./omp-phone.sh test      end-to-end test: tunnel up, collab SPA reachable, SSH + tmux works
#   ./omp-phone.sh connect   run the tunnel persistently (auto-reconnects on network changes)
#   ./omp-phone.sh status    show tunnel state
#   ./omp-phone.sh stop      stop the tunnel
#
# Overridable: OMP_ENDPOINT OMP_USER WEB_PORT SSH_FWD_PORT OMP_MAX_WAIT
#   OMP_MAX_WAIT = seconds to wait for you to authorize the key on the PC (default 900).

set -u

OMP_ENDPOINT="${OMP_ENDPOINT:-df564d2be2f44686a13c77e67a8ce475af201206d129118f5324f35e9ba24323}"
OMP_USER="${OMP_USER:-kir}"
WEB_PORT="${WEB_PORT:-8443}"          # phone port -> PC collab SPA (127.0.0.1:7466)
WEB2_PORT="${WEB2_PORT:-8444}"         # phone port -> Harness Remote PWA (127.0.0.1:5173)
SSH_FWD_PORT="${SSH_FWD_PORT:-2222}"   # phone port -> PC user-mode sshd (127.0.0.1:2222)
OMP_MAX_WAIT="${OMP_MAX_WAIT:-900}"

KEY="$HOME/.ssh/id_ed25519_omp"
PUB="$KEY.pub"
KNOWN_HOSTS="$HOME/.ssh/known_hosts_omp"
PIDFILE="$HOME/.omp-phone-tunnel.pid"
LOG="$HOME/.omp-phone-tunnel.log"
CARGO_BIN="$HOME/.cargo/bin"

export PATH="$CARGO_BIN:$PATH"

die() { echo "ERROR: $*" >&2; exit 1; }

TUNNEL_ARGS=( -N
  -L "$WEB_PORT:127.0.0.1:7466"
  -L "$WEB2_PORT:127.0.0.1:5173"
  -L "$SSH_FWD_PORT:127.0.0.1:2222"
  -o IdentityFile="$KEY" -o IdentitiesOnly=yes -o IdentityAgent=none
  -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KNOWN_HOSTS"
  -o ExitOnForwardFailure=yes -o ServerAliveInterval=25 -o ServerAliveCountMax=4
  "$OMP_USER@$OMP_ENDPOINT" )

stop_tunnel() {
  [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null
  pkill -f "iroh-ssh $OMP_USER@$OMP_ENDPOINT" 2>/dev/null
  sleep 1
  rm -f "$PIDFILE"
}

cmd_prepare() {
  command -v pkg >/dev/null || die "not Termux (no pkg). This script must run inside Termux."
  echo "==> updating package index"
  pkg update -y || true
  echo "==> installing packages (rust toolchain is large, needs ~3-4 GB free)"
  pkg install -y rust binutils git openssh tmux curl termux-api procps || die "pkg install failed"
  if ! command -v iroh-ssh >/dev/null || iroh-ssh version 2>/dev/null | grep -q '0.2.12'; then
    echo "==> building patched iroh-ssh (10-20 min). Keep the screen on — taking a wake lock."
    termux-wake-lock 2>/dev/null || true
    df -h "$HOME" | tail -1
    # relay-dial fork: bypasses n0 DNS discovery (its TXT zone returns NXDOMAIN for long
    # windows, which killed the tunnel with 'Discovery produced no results').
    cargo install --git https://github.com/Kiraprint/iroh-ssh --locked \
      || die "cargo install failed (see above; if crates.io is slow/blocked, retry with a mirror, e.g. --config 'source.crates-io.replace-with=\"rsproxy\"' --config 'source.rsproxy.registry=\"sparse+https://rsproxy.cn/index/\"')"
    termux-wake-unlock 2>/dev/null || true
  else
    echo "==> iroh-ssh already installed"
  fi
  grep -q '.cargo/bin' "$HOME/.bashrc" 2>/dev/null || echo 'export PATH="$HOME/.cargo/bin:$PATH"' >> "$HOME/.bashrc"
  iroh-ssh version
  echo "==> prepare done. Next: ./omp-phone.sh key"
}

cmd_key() {
  if [ ! -f "$KEY" ]; then
    echo "==> creating SSH keypair at $KEY"
    ssh-keygen -t ed25519 -N "" -f "$KEY" -C "omp-remote-phone"
  fi
  cp "$PUB" "$HOME/omp_remote_phone.pub"
  echo "===================================================================="
  echo "PUBLIC KEY — send this to the PC side to authorize (one line):"
  echo "--------------------------------------------------------------------"
  cat "$PUB"
  echo "===================================================================="
  echo "It is also saved at ~/omp_remote_phone.pub. After authorization on the PC,"
  echo "run ./omp-phone.sh test"
}

launch_tunnel() {
  RUST_LOG="${RUST_LOG:-iroh=debug,iroh_ssh=info}" iroh-ssh "${TUNNEL_ARGS[@]}" >>"$LOG" 2>&1 &
  TL_PID=$!
}

cmd_test() {
  command -v iroh-ssh >/dev/null || die "iroh-ssh missing — run ./omp-phone.sh prepare first"
  [ -f "$KEY" ] || die "no key yet — run ./omp-phone.sh key first"
  echo "==> starting test tunnel to $OMP_USER@$OMP_ENDPOINT"
  stop_tunnel
  : >"$LOG"
  launch_tunnel
  # wait for the tunnel to stay alive (first connect includes iroh relay handshake)
  alive=0
  for _ in $(seq 1 12); do
    if kill -0 "$TL_PID" 2>/dev/null; then alive=1; break; fi
    sleep 2
  done
  if [ "$alive" = 0 ]; then
    if grep -q 'Permission denied' "$LOG"; then
      echo "==> SSH key not authorized on the PC yet. Authorize it, then this test resumes automatically."
      echo "    Public key: $(cat "$PUB")"
      waited=0
      until kill -0 "$TL_PID" 2>/dev/null; do
        if [ "$waited" -ge "$OMP_MAX_WAIT" ]; then
          echo "---- tunnel log ----"; tail -15 "$LOG"; die "still not authorized after ${OMP_MAX_WAIT}s. Authorize the key on the PC and rerun."
        fi
        sleep 20; waited=$((waited + 20))
        grep -q 'Permission denied' "$LOG" && : >"$LOG"
        launch_tunnel   # previous instance died; try again
      done
    else
      echo "---- tunnel log ----"; tail -15 "$LOG"
      die "tunnel exited before connecting — check the log above (network/relay error?)"
    fi
  fi
  echo "==> tunnel is up (pid $TL_PID)"
  # The iroh relay dial + SSH handshake complete in the background (10-20s on mobile);
  # forward listeners only bind after the session is fully up. Poll for readiness.
  code=000
  for _ in $(seq 1 15); do
    sleep 2
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:$WEB_PORT/" 2>/dev/null || echo 000)
    [ "$code" = "200" ] && break
    kill -0 "$TL_PID" 2>/dev/null || break
  done
  if [ "$code" = 200 ]; then echo "PASS  collab SPA via tunnel:  http://127.0.0.1:$WEB_PORT/ -> HTTP 200"
  else echo "FAIL  collab SPA via tunnel: HTTP $code"; fi
  sshout=$(ssh -i "$KEY" -p "$SSH_FWD_PORT" -o IdentitiesOnly=yes -o IdentityAgent=none \
    -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KNOWN_HOSTS" \
    "$OMP_USER@127.0.0.1" 'printf AUTH_OK; tmux ls 2>/dev/null | grep -q omp && printf "; tmux-omp-present"' 2>/dev/null || echo "ssh-failed")
  echo "PASS  SSH+tmux via tunnel:  $sshout"
  echo
  echo "==> results: browser leg $([ "$code" = 200 ] && echo OK || echo FAILED), terminal leg $(echo "$sshout" | grep -q AUTH_OK && echo OK || echo FAILED)"
  echo "    Tunnel is still running (pid $TL_PID)."
  echo "    To keep it resilient (auto-reconnect on network changes): ./omp-phone.sh stop && ./omp-phone.sh connect"
}

cmd_connect() {
  command -v iroh-ssh >/dev/null || die "iroh-ssh missing — run ./omp-phone.sh prepare first"
  [ -f "$KEY" ] || die "no key yet — run ./omp-phone.sh key first"
  stop_tunnel
  : >"$LOG"
  echo "==> starting resilient tunnel (auto-reconnect loop)"
  ( while true; do
      echo "$(date +%H:%M:%S) starting tunnel"; 
      iroh-ssh "${TUNNEL_ARGS[@]}"; 
      echo "$(date +%H:%M:%S) tunnel exited ($?) — reconnecting in 4s"; 
      sleep 4; 
    done ) >>"$LOG" 2>&1 &
  echo $! >"$PIDFILE"
  termux-wake-lock 2>/dev/null || true
  sleep 6
  cmd_status
  echo "    Open in the phone browser: http://127.0.0.1:$WEB_PORT/  (use the link that"
  echo "    'phone-link.sh $WEB_PORT' prints on the PC — it carries the per-session room key)."
  echo "    Terminal: ssh -i $KEY -p $SSH_FWD_PORT $OMP_USER@127.0.0.1 -t 'tmux attach -t omp'"
  echo "    Keep Termux running (screen on; wake lock is held). For full power-off persistence:"
  echo "    pkg install termux-services; sv-enable iroh" 
}

cmd_status() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "tunnel loop: running (pid $(cat "$PIDFILE"))"
  else
    echo "tunnel loop: not running"
  fi
  pgrep -af "iroh-ssh $OMP_USER@" | cut -c1-90
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$WEB_PORT/" 2>/dev/null || echo 000)
  echo "collab SPA on :$WEB_PORT -> HTTP $code"
  echo "---- last log lines ----"; tail -3 "$LOG" 2>/dev/null
}

cmd_diag() {
  echo "== iroh-ssh version =="; iroh-ssh version 2>&1 | head -1
  echo "== full tunnel log ($LOG) =="
  cat "$LOG" 2>/dev/null | tail -40
  echo "== relay reachability from phone =="
  for r in https://dns.iroh.link https://use1-1.relay.iroh.network https://euw1-1.relay.iroh.network; do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$r" 2>/dev/null || echo 000)
    echo "$r -> $code"
  done
  echo "== pkarr record for the PC endpoint (must be 200/208) =="
  curl -sS "https://dns.iroh.link/pkarr/57mr4k9n6tdepejhq9u8id8rqsz1yrog4rwtdd4uru3i7g7necto" -o /dev/null -w 'pkarr GET -> HTTP %{http_code}, %{size_download} bytes\n' --max-time 10 2>/dev/null || echo "pkarr GET -> FAILED"
  echo "== DoH TXT probe (iroh resolves via DNS/DoH) =="
  curl -sS "https://dns.iroh.link/dns-query?name=57mr4k9n6tdepejhq9u8id8rqsz1yrog4rwtdd4uru3i7g7necto.dns.iroh.link&type=TXT" -H "accept: application/dns-json" --max-time 10 2>/dev/null | head -c 300; echo
  echo "== live iroh client processes =="
  pgrep -af iroh-ssh | head -5
  echo "== local forward listeners =="
  # netstat is not in Termux; parse /proc/net/tcp directly (port hex, st 0A = LISTEN)
  found=$(awk 'NR>1 && $4=="0A" {print $2}' /proc/net/tcp /proc/net/tcp6 2>/dev/null | cut -d: -f2 | sort -u)
  hits=$(printf '%s\n' "$found" | while read -r p; do
    [ -n "$p" ] && d=$((16#$p)); [ "$d" = "$WEB_PORT" ] || [ "$d" = "$WEB2_PORT" ] || [ "$d" = "$SSH_FWD_PORT" ] && echo x
  done | wc -l)
  [ "$hits" -gt 0 ] && echo "forward listeners bound: $hits/3" || echo "none bound"
}

cmd_stop() {
  stop_tunnel
  termux-wake-unlock 2>/dev/null || true
  echo "tunnel stopped"
}

case "${1:-}" in
  prepare) cmd_prepare ;;
  key)     cmd_key ;;
  test)    cmd_test ;;
  connect) cmd_connect ;;
  status)  cmd_status ;;
  diag)    cmd_diag ;;
  stop)    cmd_stop ;;
  *) echo "usage: ./omp-phone.sh prepare|key|test|connect|status|diag|stop" >&2; exit 1 ;;
esac
