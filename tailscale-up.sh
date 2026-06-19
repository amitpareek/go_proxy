#!/bin/sh
# Tailscale layer: bring up a real tailscaled (TUN) as a Fly 6PN subnet
# router + exit node. ALL Tailscale logic lives here; the pgproxy Go
# binary has no Tailscale code. Defaults and their rationale are in
# project.md. Run by entrypoint.sh before exec'ing pgproxy.
set -e

: "${TS_AUTHKEY:?TS_AUTHKEY must be set (use an ephemeral+reusable+tagged key)}"

# --- Defaults (see project.md for the "why") ---
TS_STATE_DIR="${TS_STATE_DIR:-/tmp/tailscale}"
TS_ADVERTISE_EXIT_NODE="${TS_ADVERTISE_EXIT_NODE:-true}"
TS_ACCEPT_DNS="${TS_ACCEPT_DNS:-false}"
TS_ACCEPT_ROUTES="${TS_ACCEPT_ROUTES:-false}"
TS_SNAT_SUBNET_ROUTES="${TS_SNAT_SUBNET_ROUTES:-true}"
TS_SOCKET="${TS_SOCKET:-/var/run/tailscale/tailscaled.sock}"

# Hostname: machineid-region-appname — the machine id keeps every
# ephemeral node uniquely named across restarts/regions.
DEFAULT_HOSTNAME="${FLY_MACHINE_ID:-pgproxy}-${FLY_REGION:-local}-${FLY_APP_NAME:-pgproxy}"
TS_HOSTNAME="${TS_HOSTNAME:-$DEFAULT_HOSTNAME}"

# Routes: if unset, derive the org's exact 6PN /48 from fly-local-6pn.
# (Use `TS_ADVERTISE_ROUTES=` to advertise none, or set an explicit CIDR.)
if [ -z "${TS_ADVERTISE_ROUTES+x}" ]; then
  sixpn="$(grep -m1 fly-local-6pn /etc/hosts 2>/dev/null | awk '{print $1}')"
  if [ -n "$sixpn" ]; then
    prefix="$(echo "$sixpn" | cut -d: -f1-3)"
    TS_ADVERTISE_ROUTES="${prefix}::/48"
  else
    TS_ADVERTISE_ROUTES=""
  fi
fi

# --- Kernel forwarding (required for a real subnet router / exit node) ---
sysctl -w net.ipv4.ip_forward=1 || echo "warn: could not set ipv4 ip_forward"
sysctl -w net.ipv6.conf.all.forwarding=1 || echo "warn: could not set ipv6 forwarding"

# --- TUN device (create the node if the platform didn't) ---
if [ ! -c /dev/net/tun ]; then
  mkdir -p /dev/net
  mknod /dev/net/tun c 10 200 || echo "warn: could not create /dev/net/tun"
fi

mkdir -p "$TS_STATE_DIR" "$(dirname "$TS_SOCKET")"

# --- Start the daemon (real TUN; userspace-networking would NOT forward) ---
tailscaled \
  --state="$TS_STATE_DIR/tailscaled.state" \
  --socket="$TS_SOCKET" \
  --tun=tailscale0 &

# Wait for the daemon socket before `tailscale up`.
i=0
while [ ! -S "$TS_SOCKET" ] && [ "$i" -lt 50 ]; do i=$((i + 1)); sleep 0.1; done

# --- Build `tailscale up` args ---
set -- --authkey="$TS_AUTHKEY" \
       --hostname="$TS_HOSTNAME" \
       --accept-dns="$TS_ACCEPT_DNS" \
       --accept-routes="$TS_ACCEPT_ROUTES" \
       --snat-subnet-routes="$TS_SNAT_SUBNET_ROUTES"
[ -n "$TS_ADVERTISE_ROUTES" ] && set -- "$@" --advertise-routes="$TS_ADVERTISE_ROUTES"
[ "$TS_ADVERTISE_EXIT_NODE" = "true" ] && set -- "$@" --advertise-exit-node
[ -n "${TS_CONTROL_URL:-}" ] && set -- "$@" --login-server="$TS_CONTROL_URL"

echo "tailscale: hostname=$TS_HOSTNAME routes=${TS_ADVERTISE_ROUTES:-none} exit-node=$TS_ADVERTISE_EXIT_NODE"
# shellcheck disable=SC2086  # TS_EXTRA_ARGS is an intentional word-split escape hatch
tailscale --socket="$TS_SOCKET" up "$@" ${TS_EXTRA_ARGS:-}
