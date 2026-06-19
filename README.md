# pgproxy

A Postgres wire-protocol proxy for Fly.io that also acts as a Tailscale subnet
router + exit node, so your tailnet can reach Fly 6PN apps (`*.internal`) and use
the machine for region-specific egress.

Two things run in one container:

- **`pgproxy`** (Go) — the proxy: strict upstream TLS, optional credential
  injection ("managed" mode), `application_name` attribution, an HTTPS `CONNECT`
  forward proxy, and a `.internal` DNS forwarder.
- **`fly-router.sh`** — a real `tailscaled` (TUN) that advertises the org's 6PN
  subnet + exit node; the kernel forwards. Modeled on
  [fly-apps/tailscale-router](https://github.com/fly-apps/tailscale-router).

See [project.md](project.md) for architecture and the full config reference;
[CLAUDE.md](CLAUDE.md) for the code layout. This is a fork of upstream
[`tailscale.com/cmd/pgproxy`](https://github.com/tailscale/tailscale/tree/main/cmd/pgproxy).

## Quickstart

Only one secret is required — **`TS_AUTHKEY`**. Everything else has a sensible
default.

```sh
fly apps create pgproxy
fly secrets set TS_AUTHKEY="tskey-auth-..."   # ephemeral + reusable + tagged
fly deploy
```

Then, **once**, in the Tailscale admin console:

1. **Approve the advertised route** (the org `/48`) — or grant an `autoApprovers`
   ACL to the key's tag (recommended; ephemeral nodes re-register each restart).
2. **Split DNS**: add a nameserver for the `internal` domain pointing at the
   node's Tailscale IP (so `*.internal` resolves over the tailnet).

Add databases whenever you're ready (secret; holds passwords):

```sh
fly secrets set DESTINATION_PG_DBS='[
  {"name":"rw","listen":5432,"target":"ep-xxx.aws.neon.tech:5432",
   "dbname":"main","user":"app_user","password":"..."},
  {"name":"admin","listen":5439,"target":"ep-xxx.aws.neon.tech:5432"}
]'
fly deploy
```

## What's on by default

With just `TS_AUTHKEY` set, every feature below is already enabled — set the env
var only to change it. Non-secrets go in `fly.toml [env]`; secrets via
`fly secrets set`.

| Feature | Env var | Default | Notes |
|---|---|---|---|
| **Subnet route** | `TS_ADVERTISE_ROUTES` | auto-derive org `/48` | from `fly-local-6pn`; or set a CIDR, or empty to disable |
| **Exit node** | `TS_ADVERTISE_EXIT_NODE` | `true` | each machine is a region-specific exit node |
| **`.internal` DNS** | `FLY_DNS_RESOLVER` | `[fdaa::3]:53` | forwards `*.internal` to Fly's resolver; empty disables |
| **DNS self-exclude** | `FLY_DNS_EXCLUDE_SELF` | `true` | NXDOMAIN for *this app's* own `*.internal`, so tailnet users reach pgproxy by its Tailscale name (see Identity) |
| **Hostname** | `TS_HOSTNAME` | `<machineid>-<region>-<app>` | e.g. `148e21-sin-pgproxy`. Dashes, not dots — Tailscale MagicDNS converts dots to dashes anyway. The machine id keeps every ephemeral node uniquely named. |

Required: `TS_AUTHKEY` (secret). Optional: `DESTINATION_PG_DBS` (secret). Advanced
knobs (`TS_ACCEPT_DNS`, `TS_SNAT_SUBNET_ROUTES`, `TS_STATE_DIR`, `TS_SOCKET`,
`UPSTREAM_CA_FILE`, `FLY_LISTEN_HOST`, `HTTP_PROXY_LISTEN`, `DEBUG_PORT`, …) are
listed with rationale in [project.md](project.md).

## Connecting

- **From a Fly app (6PN):** `postgres://pgproxy.internal:5432/mydb`
- **From the tailnet:** `postgres://<machineid>-<region>-<app>:5432/mydb` — i.e.
  pgproxy's **Tailscale name**, not `pgproxy.internal` (which is intentionally
  NXDOMAIN'd for tailnet clients; see Identity).
- **Reaching other Fly apps from the tailnet:** `some-app.internal` — these resolve
  and route normally through this node.

Managed entries (with `user`+`password`) let clients connect credential-less, e.g.
`postgres://pgproxy.internal:5432/mydb` with no password — the proxy authenticates
upstream itself.

## Identity / `application_name`

The proxy stamps `application_name` so you can attribute traffic in
`pg_stat_activity`:

- **Fly 6PN clients** → `<region>.<app>` (reverse PTR + `vms.<app>.internal` TXT).
- **Tailscale clients** → their tailnet login (or tags), resolved via the local
  `tailscaled` socket. This is why `FLY_DNS_EXCLUDE_SELF` forces tailnet users onto
  the Tailscale name: that path preserves their real source IP so they can be
  identified (the `.internal` path is SNAT'd and would attribute everyone to the
  router).

## Runtime requirements

The machine needs a TUN device (`/dev/net/tun`) and a writable `ip_forward`
sysctl for the subnet router. `tailscaled` runs as a daemon alongside the proxy;
the proxy itself has no `tailscale.com` dependency (it only queries the local
`tailscaled` API socket over raw HTTP for WhoIs).

## Development

```sh
go build ./...
go vet ./...
go test ./...
```
