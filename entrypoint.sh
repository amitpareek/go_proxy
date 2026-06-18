#!/bin/sh
# Map Fly env vars / secrets to pgproxy flags.
#
# pgproxy is a Fly 6PN-only service. Reach it from other Fly apps over
# 6PN (e.g. postgres://pgproxy.internal:5432/mydb), or from a Tailscale
# tailnet via a separate subnet router (e.g. fly-apps/tailscale-router)
# that bridges the tailnet to Fly 6PN.
#
# Optional:
#   DESTINATION_PG_DBS    JSON array of Postgres databases. Example:
#                           [
#                             {"name":"rw","listen":5432,
#                              "target":"ep-xxx.aws.neon.tech:5432",
#                              "dbname":"main","user":"app_user",
#                              "password":"..."},
#                             {"name":"admin","listen":5439,
#                              "target":"ep-xxx.aws.neon.tech:5432"}
#                           ]
#                         With user+password the entry is "managed":
#                         the proxy logs in upstream itself and clients
#                         connect credential-less. Without them it is a
#                         passthrough (client needs real credentials).
#                         May be empty on first launch; configure later
#                         via `fly secrets set DESTINATION_PG_DBS='...'`.
#   UPSTREAM_CA_FILE      CA bundle. Default: /etc/ssl/certs/ca-certificates.crt
set -e

UPSTREAM_CA_FILE="${UPSTREAM_CA_FILE:-/etc/ssl/certs/ca-certificates.crt}"

exec /pgproxy \
  --upstream-ca-file="$UPSTREAM_CA_FILE" \
  --destination-pg-dbs="${DESTINATION_PG_DBS:-}"
