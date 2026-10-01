# omp remote access — self-hosted, no VPS, no Cloudflare

Two control surfaces over one censorship-resistant transport:

| Leg | What | Port on PC |
|---|---|---|
| Browser | omp collab guest SPA (transcript, prompt, interrupt, subagents) | 7466 |
| Browser | Harness Remote PWA (separate pre-existing control plane) | 5173 |
| Terminal | user-mode sshd -> `tmux attach -t omp` | 2222 |

Phone -> PC transport: **iroh-ssh** (QUIC/UDP with HTTPS-443 relay fallback, E2E encrypted).
The PC's endpoint id is derived from `~/.ssh/irohssh_ed25519` and is stable across reboots.

## Source of truth

`~/Code/omp-remote` is a git repo holding every file needed to rebuild the runtime dir,
including the vendored SPA bundles and both control-plane legs (omp collab + Harness Remote).
The runtime dir `~/.local/share/omp-remote/` is
disposable and has been deleted once already (2026-09-29 18:18-18:21, by a parallel agent's
"orphan cleanup" that also killed the tmux server), which broke the deployment silently.

```bash
~/Code/omp-remote/install.sh      # rebuild/repair the runtime dir and the units
```

## Files on the PC

| Path | Role |
|---|---|
| `~/.local/share/omp-remote/collab-serve.ts` | self-hosted collab relay + SPA, single origin (127.0.0.1:7466) |
| `~/.local/share/omp-remote/dist/` | collab-web SPA (production bundle) |
| `~/.local/share/omp-remote/harness-web/` | Harness Remote PWA bundle + its static server (`serve.ts`) |
| `~/.local/share/omp-remote/collab-overlay.yml` | omp overlay: `collab.autoStart=control`, `relayUrl=ws://127.0.0.1:7466` |
| `~/.local/share/omp-remote/sshd/sshd_config` | root-free sshd, loopback 2222, key-only |
| `~/.local/share/omp-remote/iroh-serve.sh` | iroh-ssh server launcher (needs an `unshare -rm` mount namespace) |
| `~/.local/share/omp-remote/phone-link.sh` | prints the guest link rewritten for the phone's forward port |

## Services (all `systemd --user`, enabled; `loginctl enable-linger kir` is also set)

- `omp-sshd.service` — user-mode sshd on 127.0.0.1:2222
- `omp-iroh-ssh.service` — iroh-ssh server (endpoint id below)
- `omp-collab-relay.service` — relay + SPA on 127.0.0.1:7466
- `harness-remote.service` — Harness Remote gateway on 127.0.0.1:4900 (Basic Auth; lists and
  resumes *native* omp sessions across Projects — a different surface from the collab room,
  which mirrors one live session). Needs `harness-remote` on PATH (`npm i -g harness-remote`).
- `harness-remote-web.service` — Harness Remote PWA on 127.0.0.1:5173 (phone-forwarded as 8444)
- `omp-tmux.service` — ensures the `omp` tmux session exists at boot. It starts a *dedicated*
  session (no `--continue`): resuming "the most recently written session" was observed attaching
  to a session that two other live omp processes were already writing. Continue an older
  conversation from inside the session (`/resume`) or over the SSH leg. `KillMode=process` keeps
  a unit restart from killing the tmux server.

`unshare -rm` is required for iroh-ssh because this host blackholes IPv6 loopback: `/etc/hosts`
and `/etc/gai.conf` are bind-mounted inside the namespace with `::1` removed and IPv4 precedence
added, so `is_ssh_server_available("localhost:2222")` can resolve. No sudo is needed.

## PC side

```bash
tmux new -As omp                                    # persistent session (linger is on)
omp --config ~/.local/share/omp-remote/collab-overlay.yml
# then, from anywhere:
omp collab list --json                              # instanceId / participants / relayConnected
~/.local/share/omp-remote/phone-link.sh 8443        # link to open on the phone
```

## Phone side (Android / Termux)

```bash
pkg update && pkg install -y rust git openssh
./omp-phone.sh prepare                              # builds the patched iroh-ssh (10-20 min on a phone)
./omp-phone.sh key                                  # prints the PUBLIC key to authorize on the PC
cat ~/.ssh/id_ed25519_omp.pub                       # append this to the PC's ~/.ssh/authorized_keys
```

Daily use — one process gives every surface (the endpoint id is *not* in this repo; see below):

```bash
mkdir -p ~/.config/omp-remote
echo '<your-endpoint-id>' > ~/.config/omp-remote/endpoint   # once, from 'iroh-ssh info' on the PC

./omp-phone.sh test      # end-to-end check
./omp-phone.sh connect   # persistent tunnel, auto-reconnects

# browser:  http://127.0.0.1:8443/  <- link printed by phone-link.sh
# PWA:      http://127.0.0.1:8444/ (add machine 127.0.0.1:4900, creds from harness-remote.env)
# terminal: ssh -i ~/.ssh/id_ed25519_omp -p 2222 kir@127.0.0.1 -t 'tmux attach -t omp'
```

Equivalent by hand:

```bash
iroh-ssh -N \
  -o IdentityFile=~/.ssh/id_ed25519_omp -o IdentitiesOnly=yes \
  -L 8443:127.0.0.1:7466 -L 8444:127.0.0.1:5173 -L 4900:127.0.0.1:4900 -L 2222:127.0.0.1:2222 \
  kir@<your-endpoint-id> &
```

## Notes

- The guest link's room id/key changes per session; only the `127.0.0.1:7466` part is rewritten.
- `127.0.0.1` is a secure context, so the SPA gets WebCrypto over plain HTTP — no certificates.
- The iroh relay fallback rides n0's shared public relays (stateless, E2E encrypted) only when a
  direct QUIC path cannot be established; nothing is hosted by a third party besides that relay.
- Key-only auth: the endpoint id is the only secret needed to reach port 2222, so keep it private.
- The PWA needs the gateway's Basic Auth once per device: add a machine with host `127.0.0.1`,
  port `4900` (the forward target, not 8444) and the credentials from
  `~/.config/omp-remote/harness-remote.env` (username `harness`). The browser then remembers it.
- The gateway only accepts browser calls from origins listed with `--cors`. The tunnel maps the
  PWA to a *different port* than the API, which makes every call cross-origin, so both
  `http://127.0.0.1:8444` and `http://localhost:8444` are allow-listed in the unit. Open the PWA
  on one of those two origins (not the LAN IP) or the machine shows as unreachable.
- Termux has no `netstat`; `omp-phone.sh diag` reads `/proc/net/tcp` instead.

## Patched iroh-ssh

The phone builds a patched `iroh-ssh` (`cargo install --git https://github.com/Kiraprint/iroh-ssh`).
The change that matters on mobile:

**Dial the peer through its home relay URL** — `EndpointAddr::new(id).with_relay_url(..)` instead of
a bare endpoint id — so a connection never depends on iroh discovery.

Why: stock `iroh-ssh` can only find a peer through iroh's discovery, which resolves the record
`_iroh.<z32-endpoint-id>.dns.iroh.link` over the system resolver. On Android there is no
`/etc/resolv.conf` for Termux to read, so iroh falls back to hardcoded public resolvers over plain
UDP/53 — the first thing carrier networks block, intercept or answer from a stale cache. The client
then dies with:

```
Error: No addressing information available
    1: Discovery produced no results for <endpoint id>
```

Dialling the peer's relay directly removes discovery from the path entirely.

> Correction, worth knowing if you read the earlier version of this note: an earlier analysis here
> claimed n0's DNS zone was stale, based on `NXDOMAIN` for `_iroh4.<z32>.dns.iroh.link`. That name
> does not exist — `_iroh4` is a misreading of the DNS wire format, where `\x05_iroh` (label)
> followed by `\x34` (52 = the length of the z32 label, and ASCII `4`) looks like the text `_iroh4`.
> The real record (`_iroh.<z32>.dns.iroh.link`) resolves normally:

```bash
dig TXT _iroh.57mr4k9n….dns.iroh.link @1.1.1.1
# status: NOERROR   TXT "relay=https://use1-1.relay.n0.iroh-canary.iroh.link./"
```

> Use `./omp-phone.sh diag` to see both lookups for the endpoint this deployment uses.

## Attribution

Bundles under `dist/` and `harness-web/` are vendored verbatim from their upstream projects and
remain under their own licenses:

| Path | Upstream | License |
|---|---|---|
| `dist/` | `@oh-my-pi/collab-web` (can1357/oh-my-pi) | MIT |
| `harness-web/` | giuliastro/harness-remote | Apache-2.0 |

`collab-serve.ts`, `iroh-serve.sh`, `phone-link.sh`, `omp-phone.sh`, `install.sh`, the systemd
units and this document are this repo's own code (MIT).
