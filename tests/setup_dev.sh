#!/usr/bin/env bash
# Builds the SCRATCH database the proofs run against — never the installed application's database.
#   tests/setup_dev.sh            (needs `sudo -n -u postgres` — the owner's standing exception for sl_* databases and the three sovereign_llm_manager_*
#                                  roles only, 2026-10-10; recreates $SL_DEV_DB, default sl_dev0)
# 1. drops and creates the scratch database; 2. applies db/[0-9]*.sql in order as postgres (the same files the installer applies) --
#    SL_MIGRATIONS_UPTO=005 (or SL_DEV_UPTO) stops after the kit's db/001-005 while the schema's later files are being written;
#    3. leaves the cluster roles' passwords ALONE when the app is installed (reads them from config/.env); else gives them a scratch
#    password (the kernel's installer sets fresh ones at `apply`); 4. writes the proofs' environment to $SL_DEV_ENV (default
#    /tmp/sl-dev0.env, mode 600) -- app/bootstrap.php reads that file instead of config/.env when SL_DEV_ENV is set (never in
#    production). Nothing here is committed or installed. Ports 9501 (the app), 9502 (the fake kernel), 9503 (the fake MaluDB + MaluMail),
#    9504-9505 (the MCP servers, Phase 4), 9507 (a user-level Apache).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DB=${SL_DEV_DB:-sl_dev0}
case "$DB" in sl_*) ;; *) echo "refused: the scratch database must be named sl_* (got $DB)"; exit 2 ;; esac
ENVF=${SL_DEV_ENV:-/tmp/sl-dev0.env}
PW=$(openssl rand -hex 16)
PSQL="sudo -n -u postgres psql -v ON_ERROR_STOP=1 -q"
$PSQL -c "DROP DATABASE IF EXISTS $DB" -c "CREATE DATABASE $DB"
UPTO=${SL_MIGRATIONS_UPTO:-${SL_DEV_UPTO:-999}}
for f in "$ROOT"/db/[0-9]*.sql; do n=$(basename "$f" | cut -c1-3); [ "$((10#$n))" -le "$((10#$UPTO))" ] 2>/dev/null || continue; $PSQL -d "$DB" -f "$f" >/dev/null || { echo "FAILED: $f"; exit 1; }; done
LIVEENV="$ROOT/config/.env"
lv() { grep -m1 "^$1=" "$LIVEENV" | cut -d= -f2-; }
if [ -f "$LIVEENV" ] && [ -n "$(lv DB_PASSWORD)" ] && [ -n "$(lv MCP_RECORDS_DB_PASSWORD)" ] && [ -n "$(lv MCP_ACTIVITY_DB_PASSWORD)" ]; then
  PW_RW=$(lv DB_PASSWORD); PW_REC=$(lv MCP_RECORDS_DB_PASSWORD); PW_ACT=$(lv MCP_ACTIVITY_DB_PASSWORD)
else
  PW_RW=$PW; PW_REC=$PW; PW_ACT=$PW
  for r in sovereign_llm_manager_rw sovereign_llm_manager_records_ro sovereign_llm_manager_activity_ro; do $PSQL -c "ALTER ROLE $r WITH LOGIN PASSWORD '$PW'"; done
fi
umask 077
cat > "$ENVF" <<ENV
APP_ENV=dev
APP_DEBUG=1
APP_NAME="Sovereign LLM Manager"
APP_KEY=sovereign_llm_manager
APP_URL=http://127.0.0.1:9501
DB_HOST=127.0.0.1
DB_PORT=5432
DB_NAME=$DB
DB_USER=sovereign_llm_manager_rw
DB_PASSWORD=$PW_RW
MCP_RECORDS_DB_USER=sovereign_llm_manager_records_ro
MCP_RECORDS_DB_PASSWORD=$PW_REC
MCP_ACTIVITY_DB_USER=sovereign_llm_manager_activity_ro
MCP_ACTIVITY_DB_PASSWORD=$PW_ACT
APP_INTERNAL_PORT=9501
MCP_RECORDS_PORT=9504
MCP_ACTIVITY_PORT=9505
ACTION_TOKEN_KEY=$(openssl rand -hex 32)
ACTIONS_RELAY_KEY=$(openssl rand -hex 32)
OS_LAUNCHER_URL=https://app.example.invalid/
OS_INTERNAL_URL=http://127.0.0.1:9502
OS_APPLICATION_TOKEN=osapp_dev_$(openssl rand -hex 12)
MALUDB_API_URL=http://127.0.0.1:9503
MALUDB_API_TOKEN=dev-maludb-$(openssl rand -hex 8)
MALUMAIL_API_URL=http://127.0.0.1:9503
MALUMAIL_API_KEY=dev-malumail-$(openssl rand -hex 8)
MAIL_FROM=sovereign_llm_manager@example.invalid
MAIL_FROM_NAME="Sovereign LLM Manager"
ENV
echo "scratch database $DB ready; environment in $ENVF"
