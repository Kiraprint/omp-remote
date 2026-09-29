#!/usr/bin/env bash
# iroh-ssh server bootstrap. Run inside `unshare -rm` (private mount + user namespace)
# so /etc/gai.conf can be overridden without root: ::1 is blackholed on this host and
# iroh-ssh probes the name "localhost" at startup, which otherwise hangs for 10s and aborts.
set -eu

GAI=/tmp/omp-remote-gai.conf
cp /etc/gai.conf "$GAI"
if ! grep -qE '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100' "$GAI"; then
	echo 'precedence ::ffff:0:0/96  100' >>"$GAI"
fi
mount --bind "$GAI" /etc/gai.conf

# Drop the ::1 mapping for localhost: ::1 is blackholed here, so any resolver that
# reads this file would hand back ::1 first and the startup probe would hang.
HOSTS=/tmp/omp-remote-hosts
awk '$1 != "::1"' /etc/hosts >"$HOSTS"
mount --bind "$HOSTS" /etc/hosts

exec /home/kir/.local/bin/iroh-ssh server --persist --ssh-port 2222
