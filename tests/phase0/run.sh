#!/usr/bin/env bash
# Phase 0 proof, repeatable: the schema (db/proof/phase0_proof.sql, the schema's checks -- skipped with a line when the file is
# not there yet) and the kit without a kernel (testing-without-a-kernel.md §4) -- the directory fixture applied, the roles from
# access[], a hand-off minted the kernel's way and presented, its replay / expiry / another audience / an unknown member / a
# tampered signature / a member with no grant refused, every refusal logged, health answering, CSRF, the activity funnel, a person's
# key and the rate rule, the sign-out notice ending sessions, a grant the kernel revoked shutting the door, the worker's pass, the
# ingest bridge against a fake MaluDB. Scratch database only (sl_dev0); the installed application (if any) is never touched.
# Ports 9501 (the app), 9502 (the fake kernel), 9503 (the fake MaluDB + MaluMail); 9504-9505 are the MCP servers' (Phase 4), 9507 a
# user-level Apache's. Prints ok/FAIL per check and a count; exits non-zero on any failure. Needs `sudo -n -u postgres` (the owner's
# standing exception for sl_* databases and the sovereign_llm_manager_* roles), php 8.3, curl, openssl, and for the ingest check a python
# with asyncpg + httpx (/var/www/mcp/venv/bin/python, else $SL_PY). SL_MIGRATIONS_UPTO=005 runs the kit alone.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
export SL_DEV_DB=${SL_DEV_DB:-sl_dev0}
export SL_DEV_ENV=${SL_DEV_ENV:-/tmp/sl-dev0.env}
PY=${SL_PY:-/var/www/mcp/venv/bin/python}
PORT=9501; P_KERNEL=9502; P_FAKE=9503
TMP=$(mktemp -d /tmp/sl-kit.XXXXXX)
pass=0; fail=0; PIDS=()
ok()   { echo "ok   $1"; pass=$((pass+1)); }
bad()  { echo "FAIL $1"; fail=$((fail+1)); }
check(){ if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: $1, wanted: $2)"; fi; }
has()  { if grep -q -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi; }
hasnt(){ if grep -q -- "$2" <<<"$1"; then bad "$3 (found: $2)"; else ok "$3"; fi; }
sql()  { sudo -n -u postgres psql -d "$SL_DEV_DB" -Atc "$1"; }
as()   { sql "select set_config('app.member_id', '$1', false); select $2" | tail -1; }
cleanup() { local rc=$?; for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; rm -rf "$TMP"; exit $rc; }
trap cleanup EXIT INT TERM
for port in $PORT $P_KERNEL $P_FAKE; do (exec 3<>/dev/tcp/127.0.0.1/$port) 2>/dev/null && { echo "ABORT: port $port is taken"; exit 2; }; done

bash "$ROOT/tests/setup_dev.sh" >/dev/null || { echo "scratch database failed"; exit 1; }
set -a; . "$SL_DEV_ENV"; set +a
export APP_URL="http://127.0.0.1:$PORT" OS_INTERNAL_URL="http://127.0.0.1:$P_KERNEL" MALUDB_API_URL="http://127.0.0.1:$P_FAKE" MALUMAIL_API_URL="http://127.0.0.1:$P_FAKE"
export FAKE_KERNEL_STATE="$TMP/kernel.json" FAKE_MALUDB_LOG="$TMP/maludb.log" FAKE_MALUMAIL_LOG="$TMP/malumail.log"
cd "$ROOT"
APP="http://127.0.0.1:$PORT"

echo "== the schema (db/proof/phase0_proof.sql)"
if [ -n "${SL_MIGRATIONS_UPTO:-}${SL_DEV_UPTO:-}" ]; then
  echo "skip db/proof/phase0_proof.sql — the migrations stop at ${SL_MIGRATIONS_UPTO:-$SL_DEV_UPTO} (the kit alone)"
elif [ -f "$ROOT/db/proof/phase0_proof.sql" ]; then
  out=$(sudo -n -u postgres psql -v ON_ERROR_STOP=1 -d "$SL_DEV_DB" -f "$ROOT/db/proof/phase0_proof.sql" 2>&1)
  echo "$out" | grep -E '^ ?FAIL' || true
  summary=$(echo "$out" | grep -E '[0-9]+ ok, [0-9]+ failed' | head -1 | sed 's/^ *//')
  failed=$(echo "$summary" | sed -E 's/.* ([0-9]+) failed.*/\1/')
  check "$failed" "0" "schema proof: $summary"
else
  echo "skip db/proof/phase0_proof.sql is not written yet (the schema builder's) — the kit's checks below run on whatever db/*.sql applies"
fi

echo "== the contract tables (db/001–005)"
check "$(sql "select string_agg(role_key, ',' order by sort_order) from mcp_app_roles")" "viewer,user,admin" "the three roles, in order (os.app-roles/1; design §2, D2)"
check "$(sql "select string_agg(role_key, ',') from sl_roles where is_admin")" "admin" "exactly one admin role"
check "$(sql "select string_agg(role_key || '=' || capability, ',' order by sort_order) from sl_roles")" "viewer=read,user=write,admin=admin" "each role's capability (the base role keyed user, so the installer's standing grant makes an Operator)"
check "$(sql "select count(*) from sl_rights")" "15" "fifteen rights"
check "$(sql "select string_agg(role_key || ':' || cardinality(rights), ',' order by sort_order) from mcp_app_roles")" "viewer:6,user:10,admin:15" "Viewer 6 rights, Operator 10, LLM admin every one"
check "$(sql "select count(*) from sl_role_rights rr join sl_role_rights base on base.right_key = rr.right_key and base.role_key = 'viewer' where rr.role_key in ('user','admin')")" "12" "each higher role holds every Viewer right (cumulative)"
check "$(sql "select string_agg(right_key, ',' order by right_key) from sl_role_rights where role_key = 'user' and right_key not in (select right_key from sl_role_rights where role_key = 'viewer')")" "keys.mint_own,models.operate,notes.write,queue.act" "what an Operator holds beyond a Viewer: acting on the queue, operating models, minting their own keys, writing notes"
check "$(sudo -n -u postgres psql -d "$SL_DEV_DB" -v ON_ERROR_STOP=1 -qAt -c "begin; insert into activity_log (source, action, after) values ('system', 'worker.pass', '{\"pruned\":3}'); select source from activity_log; rollback;" 2>&1 | head -1)" "system" "activity_log admits source system (the worker's own passes)"
check "$(sudo -n -u postgres psql -d "$SL_DEV_DB" -v ON_ERROR_STOP=1 -qAt -c "insert into activity_log (source, action) values ('portal2', 'x.y')" 2>&1 | grep -c 'violates check constraint')" "1" "...and refuses a source outside the list"
check "$(sql "select string_agg(column_name || ':' || data_type, ',' order by ordinal_position) from information_schema.columns where table_name = 'activity_log' and column_name in ('token_id')")" "token_id:bigint" "the audit key appended to activity_log (token_id)"
check "$(sql "select key_rate_per_minute || '/' || key_rate_per_day || '/' || key_rotation_overlap_hours from sl_settings")" "60/5000/24" "the key rates seeded (60 a minute, 5,000 a day, a 24-hour rotation overlap)"
check "$(sudo -n -u postgres psql -d "$SL_DEV_DB" -qAt -c "update sl_settings set key_rate_per_minute = 0" 2>&1 | grep -c 'violates check constraint')" "1" "a key rate of zero is refused"
check "$(sql "select count(*) from information_schema.role_table_grants where grantee in ('sovereign_llm_manager_records_ro','sovereign_llm_manager_activity_ro') and table_name in ('activity_log','mcp_access_tokens','members','key_usage','sl_settings')")" "0" "the read roles hold no grant on the contract tables (the mcp_* views are their window)"

echo "== the mirror (the fixture through directory_sync --from-file)"
php bin/directory_sync.php --from-file bin/dev_directory.json >/dev/null 2>&1; check "$?" "0" "the directory fixture applies"
check "$(sql "select count(*) || ' of ' || count(*) filter (where capability is not null) from members")" "10 of 9" "ten members mirrored, nine admitted (the Watcher holds no grant)"
check "$(sql "select roles::text from members where id = 27")" "{admin,user}" "roles map from the feed's access[]: Marco holds LLM admin and Operator"
check "$(sql "select is_agent::int || ',' || roles::text || ',' || display_name from members where id = 42")" "1,{user},SMOKE Router" "the Router is an agent (is_agent generated) holding Operator"
check "$(sql "select is_external::int || ',' || capability || ',' || roles::text from members where id = 29")" "1,read,{viewer}" "Ann is external, holds read, and Viewer"
check "$(sql "select sl_member_roles(28)::text || ' ' || sl_member_roles(31)::text || ' ' || sl_member_roles(1)::text || ' ' || sl_member_roles(41)::text")" "{user} {viewer} {admin} {}" "sl_member_roles: write with no roles yet is Operator, read is Viewer (a read grant never draws); the super-admin admin; an unadmitted agent nothing"

echo "== roles and rights (sl_has_right, sl_member_has_right, sl_is_admin)"
check "$(as 1 "sl_is_admin() and sl_has_right('nodes.admin') and sl_has_right('payloads.read') and sl_has_right('settings.admin')")" "t" "the super-admin runs the application: every right"
check "$(as 27 "sl_is_admin() and sl_has_right('policies.admin') and sl_has_right('keys.admin') and sl_has_right('payloads.read') and not app_is_super_admin()")" "t" "an LLM admin who is not a super-admin runs it too"
check "$(as 26 "sl_has_right('queue.act') and sl_has_right('models.operate') and sl_has_right('keys.mint_own') and sl_has_right('notes.write') and sl_has_right('fleet.read') and not sl_has_right('nodes.admin') and not sl_has_right('payloads.read') and not sl_is_admin()")" "t" "an Operator acts on the queue and the models and keeps their own keys; administers nothing and reads no payload"
check "$(as 29 "sl_has_right('fleet.read') and sl_has_right('usage.read') and sl_has_right('keys.read_own') and not sl_has_right('queue.act') and not sl_has_right('keys.mint_own') and sl_is_member_here()")" "t" "an external Viewer reads and changes nothing"
check "$(as 30 "sl_has_right('runs.read') and not sl_has_right('models.operate') and not sl_has_right('notes.write')")" "t" "an internal Viewer is the same"
check "$(as 28 "sl_has_right('queue.act') and not sl_has_right('nodes.admin')")" "t" "a member whose roles have not arrived is read from the capability (write = Operator)"
check "$(as 31 "sl_has_right('fleet.read') and not sl_has_right('queue.act')")" "t" "...and a read capability with no roles is a Viewer"
check "$(as 40 "sl_has_right('models.operate') and app_member_kind() = 'agent' and sl_is_member_here() and not sl_is_admin()")" "t" "an agent granted Operator has an Operator's rights and belongs here"
check "$(as 41 "not app_is_active_member() and not sl_has_right('fleet.read')")" "t" "an agent not yet admitted holds nothing (fail closed)"
check "$(as '' "sl_has_right('fleet.read') or sl_is_member_here()")" "f" "nobody (no app.member_id) holds nothing"
check "$(sql "select sl_member_has_right(26, 'queue.act')::text || ',' || sl_member_has_right(29, 'queue.act')::text || ',' || sl_member_has_right(41, 'fleet.read')::text")" "true,false,false" "sl_member_has_right answers for a given person"

echo "== sign-on"
php -r '$f = json_decode(file_get_contents("bin/dev_directory.json"), true); file_put_contents(getenv("FAKE_KERNEL_STATE"), json_encode(["feed" => $f["feed"]]));'
php -S 127.0.0.1:$P_KERNEL tests/fake_kernel.php >"$TMP/kernel.log" 2>&1 & PIDS+=($!)
php -S 127.0.0.1:$P_FAKE tests/fake_maludb.php >"$TMP/fake.log" 2>&1 & PIDS+=($!)
PHP_CLI_SERVER_WORKERS=4 php -S 127.0.0.1:$PORT -t html tests/dev_router.php >"$TMP/app.log" 2>&1 & PIDS+=($!)
sleep 1.2
check "$(curl -s -o /dev/null -w '%{http_code}' $APP/api/v1/health)" "200" "health answers 200"
check "$(curl -s $APP/api/v1/health | php -r '$h = json_decode(stream_get_contents(STDIN), true); echo ($h["application"] ?? "?") . ":" . ($h["database"] ?? "?");')" "sovereign_llm_manager:ok" "...naming the application sovereign_llm_manager and its database ok"
url27=$(php bin/dev_handoff.php 27)
check "$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -c "$TMP/jar27" "$url27")" "302 $APP/" "a signed hand-off token opens a session (302 to /)"
home27=$(curl -s -b "$TMP/jar27" "$APP/")
has "$home27" 'id="header-user-name">SMOKE Marco<' "the home (the shell since Phase 2) names the signed-in member"
has "$home27" 'id="header-role-badge">LLM admin<' "…and the highest role the kernel sent, as the header's badge"
check "$(curl -s -o /dev/null -w '%{http_code}' "$url27")" "403" "the same token a second time is refused (replay)"
check "$(curl -s -o /dev/null -w '%{http_code}' "$(HANDOFF_TTL=-120 php bin/dev_handoff.php 26)")" "403" "an expired token is refused"
bad_url=$(APP_KEY=other php bin/dev_handoff.php 26 | sed "s#$APP##")
check "$(curl -s -o /dev/null -w '%{http_code}' "$APP$bad_url")" "403" "a token minted for another application is refused (audience)"
check "$(curl -s -o /dev/null -w '%{http_code}' "$(php bin/dev_handoff.php 999)")" "403" "an unknown member is refused"
check "$(sql "select count(*) from members where id = 999")" "0" "…and is never created in the mirror"
check "$(curl -s -o /dev/null -w '%{http_code}' "$(HANDOFF_NO_GRANT=1 php bin/dev_handoff.php 30)")" "403" "a hand-off whose claims carry no grant is refused (capability)"
pyld=$(echo "$url27" | sed -E 's/.*token=([^.]+\.[^.]+\.[^.]+\.[^.]+)\.[a-f0-9]+.*/\1/')
check "$(curl -s -o /dev/null -w '%{http_code}' "$APP/sso?token=$pyld.$(printf '0%.0s' $(seq 1 64))&claims=x.y")" "403" "a tampered signature is refused"
check "$(sql "select string_agg(after->>'reason', ',' order by id) from activity_log where action = 'member.sign_on.refused'")" "replay,token,token,capability,capability,token" "every refusal is logged with its reason (an unknown member's claims carry no grant: capability); none is told to the visitor"
check "$(curl -s -o /dev/null -w '%{http_code}' "$APP/")" "302" "an anonymous visit to / is sent to the launcher (never a login form)"
check "$(sql "select count(*) from member_sessions where member_id = 27 and ended_at is null")" "1" "the session is listed for the kernel's sign-out notice"
check "$(sql "select (after->'roles')::text from activity_log where action = 'member.sign_on' and entity_id = 27")" '["admin", "user"]' "member.sign_on logged with the roles"
code29=$(curl -s -o /dev/null -w '%{http_code}' -c "$TMP/jar29" "$(php bin/dev_handoff.php 29)"); check "$code29" "302" "an external Viewer holding read is let in"
check "$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -c "$TMP/jarn" "$(php bin/dev_handoff.php 26)&next=/settings/")" "302 $APP/settings/" "the hand-off lands on the launcher's next path when it is local"
check "$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -c "$TMP/jarx" "$(php bin/dev_handoff.php 26)&next=https://evil.example/")" "302 $APP/" "…and on / when it is not"

echo "== CSRF"
tok=$(curl -s -b "$TMP/jar27" "$APP/" | sed -n 's/.*name="csrf_token" value="\([a-f0-9]*\)".*/\1/p' | head -1)
check "$(curl -s -o /dev/null -w '%{http_code}' -b "$TMP/jar27" -X POST "$APP/logout.php")" "403" "a POST without a CSRF token is refused"
check "$(curl -s -o /dev/null -w '%{http_code}' -b "$TMP/jar27" -X POST -d 'csrf_token=deadbeef' "$APP/logout.php")" "403" "a POST with a bad CSRF token is refused"
check "$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -X POST -d 'csrf_token=x' "$APP/")" "302 https://app.example.invalid/launcher?app=sovereign_llm_manager" "an anonymous POST to a screen goes to the launcher (there is no login form here)"
check "$(curl -s -o /dev/null -w '%{http_code}' -H 'Accept: application/json' -X POST "$APP/")" "401" "…and answers a JSON caller 401, never a bare 403"

echo "== the activity funnel"
out=$(php tests/phase0/probe.php log 2>/dev/null)
check "$(sql "select entity_id || ':' || entity_type || ':' || source from activity_log where action = 'probe.event'")" "7:node:cron" "log_activity writes a numeric entity id (source cron under the CLI)"
check "$(sql "select coalesce(entity_id::text, '-') || ':' || entity_type from activity_log where action = 'probe.uuid_entity'")" "-:run" "...and keeps the row, entity_id NULL, for an entity named by a uuid"
check "$(echo "$out" | tr '\n' ' ')" "logged survived " "log_activity never throws on a bad actor, an unencodable payload or a bad key"

echo "== keys: a person's own, rate-limited"
RAW="mcp_$(openssl rand -hex 24)"; HASH=$(printf '%s' "$RAW" | openssl dgst -sha256 | sed 's/.* //')
sql "insert into mcp_access_tokens (member_id, label, token_hash, scope) values (26, 'SMOKE key', '$HASH', 'api')" >/dev/null
TOK=$(sql "select id from mcp_access_tokens where token_hash = '$HASH'")
check "$(sql "select rate_per_minute || '/' || rate_per_day from mcp_access_tokens where id = $TOK")" "60/5000" "a key's limits default from the settings (the trigger: 60/min, 5,000/day)"
check "$(sql "select member_id || ':' || label || ':' || rate_per_minute from sl_resolve_key('$HASH')")" "26:SMOKE key:60" "a key resolves to its person, label and limits (sl_resolve_key)"
check "$(sudo -n -u postgres psql -d "$SL_DEV_DB" -qAt -c "insert into mcp_access_tokens (member_id, label, token_hash, scope, rate_per_minute) values (26, 'SMOKE bad', 'x$(openssl rand -hex 8)', 'mcp', 5)" 2>&1 | grep -c 'violates check constraint')" "1" "a person's mcp token can never carry a key's limits"
r1=$(php tests/phase0/probe.php apikey "$RAW" 2>&1 | tr '\n' ' ')
has "$r1" "authenticated:26:key=yes:label=SMOKE key" "the token API authenticates a key as its person"
check "$(sql "select token_id || ':' || source || ':' || (after->>'label') from activity_log where action = 'probe.api'")" "$TOK:api:SMOKE key" "…every row under a key carries token_id, source api and the key's label, never the key"
MCP="mcp_$(openssl rand -hex 24)"; MH=$(printf '%s' "$MCP" | openssl dgst -sha256 | sed 's/.* //')
sql "insert into mcp_access_tokens (member_id, label, token_hash, scope) values (26, 'SMOKE mcp', '$MH', 'mcp')" >/dev/null
has "$(php tests/phase0/probe.php apikey "$MCP" 2>&1 | tr '\n' ' ')" '"code":"unauthorized"' "a person's mcp token is not a door to the token API"
# 61 calls in one statement: the key's API call above counts when it fell in this same minute (then 59 more pass and 2 are refused), not when the
# minute turned since (then 60 pass and 1 is refused) — either way the 61st call of a minute is refused. (A run crossing the minute failed the old form.)
rl=$(sql "select string_agg(ok::text, ',' order by n) from (select n, (sl_rate_ok($TOK)).ok from generate_series(1, 61) n) s" | tr ',' '\n' | sort | uniq -c | tr -s ' ' | tr '\n' ';')
case "$rl" in " 2 false; 59 true;"|" 1 false; 60 true;") ok "the rate rule counts 60 calls a minute and refuses the 61st (sl_rate_ok) — $rl" ;; *) bad "the rate rule (got: $rl, wanted 60 a minute with the earlier call counted or not)" ;; esac
NEW=$(sql "select sl_key_rotate($TOK, '$(openssl rand -hex 32)')"); check "$(sql "select rotated_from = $TOK and rate_per_minute = 60 from mcp_access_tokens where id = $NEW") $(sql "select expires_at <= now() + interval '25 hours' from mcp_access_tokens where id = $TOK")" "t t" "rotation mints a key of the same person and limits and gives the old one 24 hours"

echo "== the kernel's word shuts the doors"
notice="27.$(date +%s).sovereign_llm_manager"; sig=$(printf 'sso-logout:%s' "$notice" | openssl dgst -sha256 -hmac "$ACTION_TOKEN_KEY" | sed 's/.* //')
check "$(curl -s -o /dev/null -w '%{http_code}' -X POST --data-urlencode "notice=$notice.$sig" "$APP/sso/logout")" "204" "the kernel's sign-out notice answers 204"
check "$(sql "select ended_by from member_sessions where member_id = 27 order by created_at desc limit 1")" "kernel" "…and ends the member's session"
check "$(curl -s -o /dev/null -w '%{http_code}' -b "$TMP/jar27" "$APP/")" "302" "…so the next request goes to the launcher"
check "$(curl -s -o /dev/null -w '%{http_code}' -X POST --data-urlencode "notice=27.1.sovereign_llm_manager.deadbeef" "$APP/sso/logout")" "204" "a bad notice also answers 204 and changes nothing"
check "$(curl -s -o /dev/null -w '%{http_code}' -b "$TMP/jar29" "$APP/")" "200" "Ann, signed on earlier, is let in while her grant stands"
php -r '$s = json_decode(file_get_contents(getenv("FAKE_KERNEL_STATE")), true); $s["incremental"] = ["schema" => "os.directory-changes/1", "since" => "2026-01-01T00:00:00.000000Z", "next" => "2026-01-02T00:00:00.000000Z", "full" => false, "members" => [], "departments" => [], "memberships" => [], "deleted_departments" => [], "scopes" => [], "access" => [["member_id" => 29, "capability" => null, "roles" => [], "scopes" => []]]]; file_put_contents(getenv("FAKE_KERNEL_STATE"), json_encode($s));'
php bin/directory_sync.php >/dev/null 2>&1; check "$?" "0" "the change feed applies through the kernel's internal API (the fake kernel)"
check "$(curl -s -o /dev/null -w '%{http_code}' -b "$TMP/jar29" "$APP/")" "302" "a grant the kernel revoked shuts the door within one sync"
check "$(sql "select ended_by from member_sessions where member_id = 29 order by created_at desc limit 1") $(sql "select capability is null from members where id = 29")" "directory t" "…the session ended by the directory and the mirror holds no grant"
check "$(curl -s -o /dev/null -w '%{http_code}' "$(HANDOFF_NO_GRANT=1 php bin/dev_handoff.php 29)")" "403" "…and a hand-off whose claims now carry no grant is refused (the kernel's claims are the authority)"
tok26=$(curl -s -c "$TMP/jar26" -b "$TMP/jar26" -o /dev/null "$(php bin/dev_handoff.php 26)"; curl -s -b "$TMP/jar26" "$APP/" | sed -n 's/.*name="csrf_token" value="\([a-f0-9]*\)".*/\1/p' | head -1)
check "$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' -b "$TMP/jar26" -X POST -d "csrf_token=$tok26" "$APP/logout.php")" "302 https://app.example.invalid/launcher" "Sovereign LLM Manager's own sign-out (POST + CSRF) goes back to the launcher"
check "$(curl -s -o /dev/null -w '%{http_code}' -b "$TMP/jar26" "$APP/")" "302" "…and the session is over"

echo "== the worker, the ingest bridge, mail"
php bin/worker.php >"$TMP/worker.out" 2>&1; check "$?:$(sql "select count(*) from activity_log where action = 'worker.pass' and source = 'cron'")" "0:1" "the worker runs its empty pass, logs worker.pass (source cron) and exits 0"
check "$(php -r '$r = json_decode(file_get_contents($argv[1]), true); echo count($r["ran"] ?? []) . ":" . (isset($r["ran"]["key_usage_prune"]["pruned"]) ? "pruned" : "?");' "$TMP/worker.out")" "1:pruned" "...one pass in the kit: the key-usage prune (a slice adds its own)"
if [ -x "$PY" ] && "$PY" -c 'import asyncpg, httpx' 2>/dev/null; then
  "$PY" mcp/activity_ingest.py >"$TMP/ingest.out" 2>&1; check "$?" "0" "the ingest bridge ships the log to MaluDB (fake) and advances its checkpoint"
  check "$(php -r '$first = json_decode(file(getenv("FAKE_MALUDB_LOG"))[0], true); echo array_key_first($first["payload"]) . "=" . $first["payload"]["application"] . ":" . $first["kind"];')" "application=sovereign_llm_manager:activity" "the payload names the application first (memory.md)"
  check "$(php -r 'foreach (file(getenv("FAKE_MALUDB_LOG")) as $l) { $b = json_decode($l, true); if (($b["payload"]["action"] ?? "") === "probe.event") echo $b["payload"]["entity_id"] ?? "-"; }')" "7" "...and carries the entity id"
  check "$(sql "select last_id = (select max(id) from activity_log) from activity_ingest_state")" "t" "…the checkpoint stands at the last row"
else
  bad "the ingest bridge needs a python with asyncpg and httpx (SL_PY)"; bad "the payload names the application first"; bad "payload carries the audit keys"; bad "the checkpoint"
fi
check "$(php tests/phase0/probe.php mail 2>&1)" "sent:200" "MaluMail sends through the (fake) API when a key is set"
check "$(MALUMAIL_API_KEY= php tests/phase0/probe.php mail 2>&1 | cut -d: -f1)" "mail-threw" "with no key the send raises a catchable error (mail is optional)"

echo "== $pass ok, $fail failed"
[ "$fail" -eq 0 ]
