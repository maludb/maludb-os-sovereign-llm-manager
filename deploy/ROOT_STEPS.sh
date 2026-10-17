#!/usr/bin/env bash
# Sovereign LLM Manager — what root or the owner does to install it beside the kernel, in order. Forked from the estate kit (2026-10-17);
# later phases ADD steps and mark them. NOTHING HERE HAS BEEN RUN: the proofs use a scratch database, php -S, a user-level Apache
# and fixtures, and never touch an installed application, Apache, systemd or the MaluDB API.
#   bash deploy/ROOT_STEPS.sh              prints this plan (the default)
#   sudo bash deploy/ROOT_STEPS.sh apply   runs the steps with no decision in them: 0 and 0b (the ports, Apache's modules)
# Steps 1, 2 and 3 are printed and never run: they are the installer's or the owner's.
set -euo pipefail
APP=/srv/apps/sovereign_llm_manager
KERNEL=/var/www
MODE=${1:-plan}
run() { echo "+ $*"; if [ "$MODE" = apply ]; then "$@"; fi; }

# ------------------------------------------------------------------------------------------------------------------
# 0. PIN THE PORTS before the installer's first apply (Help Desk's lesson of 2026-10-02). The installer assigns a port to APP_INTERNAL_PORT
#    and the endpoints' port_env; pinning them here keeps them where the design §14 put them. A config/.env holding ONLY these: the
#    installer reads them, fills every other required key itself, and sets fresh role passwords because DB_PASSWORD is absent.
echo "== 0. Pin the ports (ROOT) -- only if $APP/config/.env does not exist yet"
if [ ! -f "$APP/config/.env" ]; then
  run bash -c "install -d -m 755 '$APP/config' && printf 'APP_INTERNAL_PORT=8202\nMCP_RECORDS_PORT=8860\nMCP_ACTIVITY_PORT=8861\n' > '$APP/config/.env' && chgrp www-data '$APP/config/.env' && chmod 640 '$APP/config/.env'"
else
  echo "   (config/.env exists -- leaving it alone; check it holds APP_INTERNAL_PORT, MCP_RECORDS_PORT and MCP_ACTIVITY_PORT)"
fi
#    See that it worked:  php $KERNEL/bin/app_install.php plan $APP --domain subello.com | grep -E '^(todo|done) +(ports|vhost|services)'   -> no {{...}} unfilled

# 0b. APACHE'S MODULES (ROOT; idempotent). rewrite, proxy, proxy_http (the MCP servers), headers
#     (this host had it disabled — Sales CRM's finding; the vhost guards its Header lines so a missing module never fails the config test).
echo "== 0b. Apache's modules (ROOT): rewrite, proxy, proxy_http, headers"
run a2enmod -q rewrite proxy proxy_http headers

# ------------------------------------------------------------------------------------------------------------------
# 1. Look (read-only, any user): what the installer would do.
echo "== 1. The installer's plan (read-only)"
echo "   php $KERNEL/bin/app_install.php plan $APP --by <super-admin email> --domain subello.com"

# ------------------------------------------------------------------------------------------------------------------
# 2. The installer's apply (ROOT) -- not before the manifest (maludb-os.json) exists: database and roles, config/.env, the vhost, the units
#    the registration (catalog kind ours — the row K57 seeded, kernel db/184 —, /sso and /sso/logout, scope_kind
#    none), the application token, skills imported, approval policies, the installing super-admin's admin grant. --grant-standing-departments
#    gives every standing department the Member role (key user); --hire-agents hires the Sovereign LLM Manager Expert and the Watcher. Run it twice:
#    the roles are read from app_roles only once the records MCP answers (Phase 4).
echo "== 2. apply (ROOT) — from Phase 2"
echo "   sudo php $KERNEL/bin/app_install.php apply $APP --by <super-admin email> --domain subello.com --grant-standing-departments --hire-agents"

# ------------------------------------------------------------------------------------------------------------------
# 3. The owner's (any time after 2):
echo "== 3. The owner's"
echo "   - DNS and TLS for llm.subello.com (until then /etc/hosts maps it to this host)"
echo "   - MaluMail: MALUMAIL_API_KEY, MAIL_FROM, MAIL_FROM_NAME into $APP/config/.env (notices) — the installer's mail step writes them from ~/.malumail when present"
echo "   - the timers are rendered and enabled by apply; by hand:  sudo systemctl enable --now sovereign_llm_manager-worker.timer sovereign_llm_manager-directory-sync.timer sovereign_llm_manager-activity-ingest.timer"
