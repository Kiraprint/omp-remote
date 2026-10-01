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
# Overridable: OMP_ENDPOINT OMP_USER WEB_PORT WEB2_PORT GATEWAY_PORT SSH_FWD_PORT OMP_MAX_WAIT
#   OMP_ENDPOINT  = the PC's iroh endpoint id (not in this repo). Read from
#                   ~/.config/omp-remote/endpoint unless set here.
#   OMP_MAX_WAIT  = seconds to wait for you to authorize the key on the PC (default 900).

set -u

# The PC's iroh endpoint id is this deployment's public identity — it is deliberately NOT
# committed. Provide it via $OMP_ENDPOINT, or write it once to the endpoint file
# (the PC prints it: `iroh-ssh info`, or the omp-iroh-ssh.service journal).
ENDPOINT_FILE="${OMP_ENDPOINT_FILE:-$HOME/.config/omp-remote/endpoint}"
OMP_ENDPOINT="${OMP_ENDPOINT:-$(cat "$ENDPOINT_FILE" 2>/dev/null | tr -d '[:space:]')}"
OMP_USER="${OMP_USER:-kir}"
WEB_PORT="${WEB_PORT:-8443}"          # phone port -> PC collab SPA (127.0.0.1:7466)
WEB2_PORT="${WEB2_PORT:-8444}"         # phone port -> Harness Remote PWA (127.0.0.1:5173)
GATEWAY_PORT="${GATEWAY_PORT:-4900}"   # phone port -> Harness Remote gateway API (127.0.0.1:4900)
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

require_endpoint() {
  [ -n "$OMP_ENDPOINT" ] || die "no endpoint id. Pass it once, e.g.:
    mkdir -p ~/.config/omp-remote && echo <endpoint-id> > ~/.config/omp-remote/endpoint
  or set OMP_ENDPOINT=<64-hex-endpoint-id> (the PC prints it with 'iroh-ssh info')."
}

# z-base-32 of a hex string — the encoding iroh uses for pkarr names.
z32_of_hex() {
  local hex alpha=ybndrfg8ejkmcpqxot1uwisza345h769 bits="" out="" i b n chunk
  hex=$(printf '%s' "$1" | tr 'A-F' 'a-f')
  for ((i = 0; i < ${#hex}; i += 2)); do
    n=$((16#${hex:i:2}))
    for ((b = 7; b >= 0; b--)); do bits+=$(((n >> b) & 1)); done
  done
  while ((${#bits} % 5 != 0)); do bits+="0"; done
  for ((i = 0; i < ${#bits}; i += 5)); do
    chunk=$((2#${bits:i:5}))
    out+=${alpha:chunk:1}
  done
  printf '%s' "$out"
}

TUNNEL_ARGS=( -N
  -L "$WEB_PORT:127.0.0.1:7466"
  -L "$WEB2_PORT:127.0.0.1:5173"
  -L "$GATEWAY_PORT:127.0.0.1:4900"
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
    # Patched fork: the stock client can only find the peer through iroh discovery, which on
    # Android runs over plain UDP/53 (Termux has no /etc/resolv.conf, so iroh falls back to
    # hardcoded public resolvers). When that traffic is blocked or intercepted the client dies
    # with 'Discovery produced no results'. The fork dials the peer through its home relay URL
    # (EndpointAddr::with_relay_url), which needs no discovery at all.
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
  require_endpoint
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
  require_endpoint
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
  require_endpoint
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
  require_endpoint
  echo "== iroh-ssh version =="; iroh-ssh version 2>&1 | head -1
  echo "== endpoint id in use =="; echo "${OMP_ENDPOINT:-<unset>}"
  echo "== full tunnel log ($LOG) =="
  cat "$LOG" 2>/dev/null | tail -40
  echo "== relay reachability from phone =="
  for r in https://dns.iroh.link https://use1-1.relay.iroh.network https://euw1-1.relay.iroh.network; do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$r" 2>/dev/null || echo 000)
    echo "$r -> $code"
  done
  if [ -n "$OMP_ENDPOINT" ]; then
    local z32 name
    z32=$(z32_of_hex "$OMP_ENDPOINT")
    # iroh resolves `_iroh.<z32>.<origin>` (IROH_TXT_NAME). Quoting matters: the wire format
    # is a length-prefixed label, so reading raw bytes as text yields a bogus "_iroh4" name.
    name="_iroh.$z32.dns.iroh.link"
    echo "== pkarr HTTPS record (what a browser/wasm client uses; want 200) =="
    curl -sS "https://dns.iroh.link/pkarr/$z32" -o /dev/null -w 'pkarr GET -> HTTP %{http_code}, %{size_download} bytes\n' --max-time 10 2>/dev/null || echo "pkarr GET -> FAILED"
    echo "== DNS TXT record (what a native client uses; NOERROR + a TXT line = healthy) =="
    curl -sS "https://dns.iroh.link/dns-query?name=$name&type=TXT" -H "accept: application/dns-json" --max-time 10 2>/dev/null | head -c 300; echo
    echo "  (if this fails but HTTPS to dns.iroh.link works, plain UDP/53 is blocked on this network —"
    echo "   that is the case the relay-dial build exists for)"
  fi
  echo "== live iroh client processes =="
  pgrep -af iroh-ssh | head -5
  echo "== local forward listeners =="
  # netstat is not in Termux; parse /proc/net/tcp directly (port hex, st 0A = LISTEN)
  found=$(awk 'NR>1 && $4=="0A" {print $2}' /proc/net/tcp /proc/net/tcp6 2>/dev/null | cut -d: -f2 | sort -u)
  hits=$(printf '%s\n' "$found" | while read -r p; do
    [ -n "$p" ] && d=$((16#$p)); [ "$d" = "$WEB_PORT" ] || [ "$d" = "$WEB2_PORT" ] || [ "$d" = "${GATEWAY_PORT:-4900}" ] || [ "$d" = "$SSH_FWD_PORT" ] && echo x
  done | wc -l)
  [ "$hits" -gt 0 ] && echo "forward listeners bound: $hits/4" || echo "none bound"
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
