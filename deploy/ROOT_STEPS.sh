#!/usr/bin/env bash
# Sovereign LLM Manager — what root or the owner does to install it beside the kernel, in order. Written at the end of Phase 0
# (2026-10-17). NOTHING HERE HAS BEEN RUN: the proofs use a scratch database, php -S and a fake node.
#   bash deploy/ROOT_STEPS.sh              prints this plan (the default)
#   sudo bash deploy/ROOT_STEPS.sh apply   runs the steps with no decision in them: 0 and 0b (the ports and the sealing key, Apache's modules)
# Steps 1, 2, 3 and 4 are printed and never run: they are the installer's or the owner's.
set -euo pipefail
APP=/srv/apps/sovereign_llm_manager
KERNEL=/var/www
MODE=${1:-plan}
run() { echo "+ $*"; if [ "$MODE" = apply ]; then "$@"; fi; }

# 0. PIN THE PORTS AND MINT THE SEALING KEY before the installer's first apply. The installer assigns a port only to APP_INTERNAL_PORT and
#    the endpoints' port_env; pinning all three keeps them where the design says. SL_SECRETS_KEY seals the nodes' keys (libsodium); it never
#    leaves this file, and a rotation ADDS a version — never replace it once a node is registered.
echo "== 0. Pin the ports and mint SL_SECRETS_KEY (ROOT) — only if $APP/config/.env does not exist yet"
if [ ! -f "$APP/config/.env" ]; then
  run bash -c "install -d -m 755 '$APP/config' && printf 'APP_INTERNAL_PORT=8202\nMCP_RECORDS_PORT=8860\nMCP_ACTIVITY_PORT=8861\nSL_SECRETS_KEY=%s\n' \"\$(openssl rand -hex 32)\" > '$APP/config/.env' && chgrp www-data '$APP/config/.env' && chmod 640 '$APP/config/.env'"
else
  echo "   (config/.env exists — leaving it alone; check it holds the three ports and SL_SECRETS_KEY)"
fi

# 0b. APACHE'S MODULES (ROOT; idempotent): rewrite, proxy, proxy_http (the MCP servers), headers.
echo "== 0b. Apache's modules (ROOT): rewrite, proxy, proxy_http, headers"
run a2enmod -q rewrite proxy proxy_http headers

# 1. Look (read-only, any user).
echo "== 1. The installer's plan (read-only)"
echo "   php $KERNEL/bin/app_install.php plan $APP --by <super-admin email> --domain subello.com"

# 2. The installer's apply (ROOT) — from Phase 2. Run it twice: the roles are read from app_roles once the records MCP answers (Phase 4).
echo "== 2. apply (ROOT)"
echo "   sudo php $KERNEL/bin/app_install.php apply $APP --by <super-admin email> --domain subello.com --grant-standing-departments"

# 3. The hires (after apply; the worker, directory-sync and ingest timers are rendered and enabled by apply).
echo "== 3. The hires"
echo "   php $KERNEL/bin/hire_application_agent.php --app sovereign_llm_manager --agent expert"
echo "   php $KERNEL/bin/hire_application_agent.php --app sovereign_llm_manager --agent fleet_watcher"
echo "   by hand if needed:  sudo systemctl enable --now sovereign_llm_manager-worker.timer sovereign_llm_manager-directory-sync.timer sovereign_llm_manager-activity-ingest.timer"

# 4. The owner's.
echo "== 4. The owner's"
echo "   - DNS and TLS for llm.subello.com (until then /etc/hosts maps it to this host; the kernel's app_roles read needs the loopback line)"
echo "   - Register the first node: Nodes -> Register, with the node's URL (http://<mac>:11435) and the key 'sllm init' printed on the machine"
echo "   - Prices (Usage -> Prices) if you want a notional cost; local models are 0"
echo "   - MaluMail: MALUMAIL_API_KEY, MAIL_FROM, MAIL_FROM_NAME (the installer's mail step writes them from ~/.malumail when present)"
echo "   - the connections a super-admin approves (bin/app_connection.php) for siblings reading usage_by_period, nodes_status, models_available"
