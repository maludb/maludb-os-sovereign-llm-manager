-- Phase 0 proof of the schema (docs/sovereign-llm-manager-design.md §10). One transaction, ROLLED BACK: fixtures written as the
-- application's role, reads as the two read roles, acting members set through app.member_id exactly as PHP and the MCP servers set it.
-- Fixtures are synthetic (example.invalid). Run as postgres on a SCRATCH database (tests/phase0/schema.sh or run.sh):
--   sudo -n -u postgres psql -v ON_ERROR_STOP=1 -d sl_proof -f db/proof/phase0_proof.sql; echo "exit $?"
\set QUIET on
\o /dev/null
BEGIN;
CREATE TEMP TABLE proof (n serial, ok boolean, label text);
GRANT ALL ON proof TO PUBLIC; GRANT ALL ON SEQUENCE proof_n_seq TO PUBLIC;
CREATE OR REPLACE FUNCTION pg_temp.check(b boolean, l text) RETURNS void LANGUAGE sql AS $$ INSERT INTO proof (ok, label) VALUES (COALESCE(b, false), l) $$;
CREATE OR REPLACE FUNCTION pg_temp.refused(p_sql text, p_like text, l text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
        INSERT INTO proof (ok, label) VALUES (false, l || ' (was NOT refused)');
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO proof (ok, label) VALUES (SQLERRM ILIKE '%' || p_like || '%', l || CASE WHEN SQLERRM ILIKE '%' || p_like || '%' THEN '' ELSE ' (said: ' || SQLERRM || ')' END);
    END;
END$$;
CREATE OR REPLACE FUNCTION pg_temp.as_member(p bigint) RETURNS void LANGUAGE sql AS $$ SELECT set_config('app.member_id', COALESCE(p::text, ''), true) $$;
CREATE TEMP TABLE uids (k text PRIMARY KEY, u uuid); GRANT ALL ON uids TO PUBLIC;
CREATE OR REPLACE FUNCTION pg_temp.u(k text) RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT u FROM uids WHERE uids.k = $1 $$;
CREATE OR REPLACE FUNCTION pg_temp.keep(k text, v uuid) RETURNS uuid LANGUAGE sql AS $$ INSERT INTO uids (k, u) VALUES ($1, $2) ON CONFLICT (k) DO UPDATE SET u = EXCLUDED.u RETURNING u $$;
GRANT EXECUTE ON FUNCTION pg_temp.check(boolean, text), pg_temp.refused(text, text, text), pg_temp.as_member(bigint), pg_temp.u(text), pg_temp.keep(text, uuid) TO PUBLIC;

-- ================================================================ fixtures: the actors of §2
SET ROLE sovereign_llm_manager_rw;
INSERT INTO members (id, member_kind, display_name, email, business_role, is_external, status, capability, roles) VALUES
 (1,  'human', 'SMOKE Owner',    'owner@example.invalid', 'super_admin', false, 'active', 'admin', '{admin}'),   -- the super-admin
 (26, 'human', 'SMOKE Priya',    'priya@example.invalid', 'user',        false, 'active', 'write', '{user}'),    -- an Operator
 (27, 'human', 'SMOKE Marco',    'marco@example.invalid', 'user',        false, 'active', 'admin', '{admin}'),   -- an LLM admin (not super)
 (30, 'human', 'SMOKE Dana',     'dana@example.invalid',  'user',        false, 'active', 'read',  '{viewer}'),  -- a Viewer
 (31, 'human', 'SMOKE Lee',      'lee@example.invalid',   'user',        false, 'active', 'write', '{}'),        -- write, no roles → Operator
 (32, 'human', 'SMOKE Sam',      'sam@example.invalid',   'user',        false, 'active', NULL,    '{}'),        -- no grant
 (40, 'agent', 'SMOKE LLM Ops Expert', NULL,               'user',        false, 'active', 'write', '{user}'),
 (41, 'agent', 'SMOKE Fleet Watcher',  NULL,               'user',        false, 'active', 'read',  '{viewer}');
INSERT INTO departments (id, name) VALUES (7, 'IT');
INSERT INTO department_members (member_id, department_id, is_primary) VALUES (26, 7, true);

-- ================================================================ 1. roles and rights (D2)
SELECT pg_temp.check((SELECT string_agg(role_key, ',' ORDER BY sort_order) FROM mcp_app_roles) = 'viewer,user,admin', 'three roles, in order');
SELECT pg_temp.check((SELECT string_agg(role_key || ':' || cardinality(rights), ',' ORDER BY sort_order) FROM mcp_app_roles) = 'viewer:6,user:10,admin:15', 'Viewer 6 rights, Operator 10, LLM admin 15');
SELECT pg_temp.check(sl_member_has_right(26, 'queue.act') AND NOT sl_member_has_right(30, 'queue.act'), 'an Operator acts on the queue; a Viewer does not');
SELECT pg_temp.check(sl_member_has_right(27, 'payloads.read') AND NOT sl_member_has_right(26, 'payloads.read'), 'payloads.read is the admin''s');
SELECT pg_temp.check(sl_member_roles(31) = '{user}' AND sl_member_roles(32) = '{}' AND 'admin' = ANY (sl_member_roles(1)), 'write with no roles → Operator; no grant → nothing; the super-admin → admin');

-- ================================================================ 2. nodes and the pull lifecycle (D10, D12)
SELECT pg_temp.as_member(27);
INSERT INTO sl_nodes (name, base_url, node_key_ciphertext, node_key_last4, created_by) VALUES ('Mac Mini', 'http://10.0.0.5:11435', '\x00'::bytea, 'ab12', 27);
INSERT INTO sl_nodes (name, base_url, created_by) VALUES ('GPU box', 'http://10.0.0.6:11435', 27);                      -- registered later (no key yet)
SELECT pg_temp.refused($$INSERT INTO sl_nodes (name, base_url) VALUES ('bad', 'http://10.0.0.7:11435/openai')$$, 'check', 'a base_url carries no path');
SELECT pg_temp.refused($$INSERT INTO sl_nodes (name, base_url) VALUES ('mac mini', 'http://x:1')$$, 'duplicate', 'a node''s name is unique, case-insensitively');
SELECT pg_temp.check((SELECT array_agg(d ORDER BY d) FROM sl_nodes_due() d) = ARRAY[(SELECT id FROM sl_nodes WHERE name = 'Mac Mini')], 'only a registered node is due (the one with a key)');
CREATE TEMP TABLE ids AS SELECT (SELECT id FROM sl_nodes WHERE name = 'Mac Mini') AS mac, (SELECT id FROM sl_nodes WHERE name = 'GPU box') AS gpu;
GRANT ALL ON ids TO PUBLIC;
SELECT sl_node_pull_close(sl_node_pull_open((SELECT mac FROM ids), 'scheduled'), 'ok', NULL, '{"runs_seen": 3, "seq_to": 40}');
SELECT pg_temp.check((SELECT status = 'online' AND last_seq = 40 AND consecutive_failures = 0 AND last_ok_at IS NOT NULL FROM sl_nodes WHERE id = (SELECT mac FROM ids)), 'an ok pull: online, the cursor advanced');
SELECT pg_temp.check(NOT EXISTS (SELECT 1 FROM sl_nodes_due()), '…and not due again within its cadence');
SELECT sl_node_pull_close(sl_node_pull_open((SELECT mac FROM ids), 'scheduled'), 'failed', 'connection refused');
SELECT pg_temp.check((SELECT status = 'degraded' AND consecutive_failures = 1 AND backoff_until > now() FROM sl_nodes WHERE id = (SELECT mac FROM ids)), 'one failure: degraded with a backoff');
SELECT sl_node_pull_close(sl_node_pull_open((SELECT mac FROM ids), 'scheduled'), 'failed', 'x');
SELECT sl_node_pull_close(sl_node_pull_open((SELECT mac FROM ids), 'scheduled'), 'failed', 'x');
SELECT pg_temp.check((SELECT status = 'offline' AND consecutive_failures = 3 FROM sl_nodes WHERE id = (SELECT mac FROM ids)), 'three failures in a row: offline (D10)');
SELECT pg_temp.check((SELECT seq_from = 40 FROM sl_node_pulls ORDER BY id DESC LIMIT 1), 'a pull records the cursor it started from');
SELECT sl_node_pull_close(sl_node_pull_open((SELECT mac FROM ids), 'manual'), 'ok', NULL, '{"seq_to": 30}');
SELECT pg_temp.check((SELECT status = 'online' AND last_seq = 40 FROM sl_nodes WHERE id = (SELECT mac FROM ids)), 'recovery: online again; the cursor never moves backwards');
SELECT pg_temp.refused($$SELECT sl_node_pull_open(999, 'scheduled')$$, 'no such node', 'a pull of an unknown node is refused');

-- the queue snapshot, rewritten whole
SELECT pg_temp.check(sl_queue_snapshot_replace((SELECT mac FROM ids), '[{"job_id":"11111111-1111-1111-1111-111111111111","lane":"local","status":"running","served_model":"qwen3:8b","key_name":"ide","priority":5,"mode":"sync","face":"openai","position":null,"expected_wait_ms":0,"queued_at":"2026-10-17T10:00:00Z","started_at":"2026-10-17T10:00:01Z","tags":["app:x"]},
  {"job_id":"22222222-2222-2222-2222-222222222222","lane":"local","status":"queued","served_model":"qwen3:8b","key_name":"kernel","priority":7,"mode":"async","face":"anthropic","position":1,"expected_wait_ms":4200,"queued_at":"2026-10-17T10:00:02Z","tags":[]}]'::jsonb) = 2, 'two queue rows taken');
SELECT sl_queue_snapshot_replace((SELECT mac FROM ids), '[{"job_id":"22222222-2222-2222-2222-222222222222","lane":"local","status":"running","served_model":"qwen3:8b","key_name":"kernel","priority":7,"mode":"async","face":"anthropic","queued_at":"2026-10-17T10:00:02Z","started_at":"2026-10-17T10:00:05Z"}]'::jsonb);
SELECT pg_temp.check((SELECT count(*) FROM sl_queue_snapshot WHERE node_id = (SELECT mac FROM ids)) = 1, '…the next snapshot replaces it whole');
SELECT pg_temp.check((SELECT tags = '{app:x}' FROM sl_queue_snapshot WHERE node_job_id = '11111111-1111-1111-1111-111111111111') IS NULL, 'the finished job left the snapshot');

-- ================================================================ 3. keys (D8) and the run mirror
INSERT INTO sl_caller_keys (node_id, node_key_id, name, prefix, owner_member_id, minted_by, payload_retention) VALUES ((SELECT mac FROM ids), gen_random_uuid(), 'ide', 'sllm_ab12', 26, 27, 'full');
INSERT INTO sl_caller_keys (node_id, node_key_id, name, prefix, application_key, minted_by, cloud_allowed, fallback_allowed) VALUES ((SELECT mac FROM ids), gen_random_uuid(), 'kernel', 'sllm_cd34', 'kernel', 1, true, true);
SELECT pg_temp.refused($$INSERT INTO sl_caller_keys (node_id, name) VALUES ((SELECT mac FROM ids), 'orphan')$$, 'check', 'every key has an owner — a person or an application (D8)');
SELECT pg_temp.refused($$INSERT INTO sl_caller_keys (node_id, name, owner_member_id) VALUES ((SELECT mac FROM ids), 'IDE', 26)$$, 'duplicate', 'a key''s name is unique per node among the live ones');
SELECT pg_temp.check(NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'sl_caller_keys' AND column_name IN ('key', 'hash', 'secret')), 'no key and no hash live here (§3)');

SELECT pg_temp.keep('r1', sl_run_mirror((SELECT mac FROM ids), '{"id":"33333333-3333-3333-3333-333333333333","seq":41,"face":"openai","mode":"sync","kind":"chat","key_name":"ide","tags":["app:x"],
  "client_ip":"10.0.0.9","requested_model":"fast","served_model":"qwen3:8b","lane_requested":"local","lane_served":"local","priority":5,"stream":true,"status":"done",
  "accepted_at":"2026-10-17T10:00:00Z","started_at":"2026-10-17T10:00:01Z","first_token_at":"2026-10-17T10:00:01.400Z","finished_at":"2026-10-17T10:00:04Z",
  "queue_wait_ms":1000,"time_to_first_token_ms":400,"run_ms":3000,"total_ms":4000,"load_ms":350,"prompt_tokens":120,"prompt_eval_ms":200,"output_tokens":300,"eval_ms":2400,
  "total_backend_ms":2950,"prompt_tokens_per_second":600,"output_tokens_per_second":125,"model_was_loaded":false,"request_bytes":900,"response_bytes":1400,"messages_count":2,
  "images_count":0,"tools_count":0,"context_length":32768,"context_used":420,"stop_reason":"stop","http_status":200,"memory_free_at_start_bytes":8000000000,
  "loaded_models_at_start":[],"cpu_load_1m":1.5}'::jsonb));
SELECT pg_temp.check((SELECT key_name = 'ide' AND caller_key_id = (SELECT id FROM sl_caller_keys WHERE name = 'ide') AND tags = '{app:x}' AND client_ip = '10.0.0.9'::inet
                        AND output_tokens_per_second = 125 AND loaded_models_at_start = '{}' AND NOT model_was_loaded AND node_seq = 41 FROM sl_runs WHERE id = pg_temp.u('r1')),
                     'a node run mirrored: the key joined by name, every number kept');
SELECT pg_temp.check((SELECT notional_cost = 0 FROM sl_runs WHERE id = pg_temp.u('r1')), 'a local model costs nothing until a price is entered (D6)');
INSERT INTO sl_model_prices (model_name, price_input_per_mtok, price_output_per_mtok, set_by) VALUES ('gpt-oss:120b-cloud', 0.5, 2.0, 27);
SELECT pg_temp.keep('r2', sl_run_mirror((SELECT mac FROM ids), '{"id":"44444444-4444-4444-4444-444444444444","seq":42,"face":"anthropic","mode":"async","kind":"chat","key_name":"kernel","tags":[],
  "requested_model":"qwen3:8b","served_model":"gpt-oss:120b-cloud","lane_requested":"local","lane_served":"cloud","fallback_reason":"local_wait","fallback_model":"gpt-oss:120b-cloud",
  "priority":7,"status":"done","accepted_at":"2026-10-17T10:00:02Z","started_at":"2026-10-17T10:00:03Z","finished_at":"2026-10-17T10:00:06Z","queue_wait_ms":1000,"run_ms":3000,"total_ms":4000,
  "prompt_tokens":1000000,"output_tokens":1000000,"eval_ms":3000,"output_tokens_per_second":333333,"model_was_loaded":true,"stop_reason":"stop","http_status":200}'::jsonb));
SELECT pg_temp.check((SELECT notional_cost = 2.5 AND fallback_reason = 'local_wait' FROM sl_runs WHERE id = pg_temp.u('r2')), 'a cloud fallback priced by the notional price: 1M in at 0.5 + 1M out at 2.0');
SELECT pg_temp.keep('r2b', sl_run_mirror((SELECT mac FROM ids), '{"id":"44444444-4444-4444-4444-444444444444","seq":43,"face":"anthropic","mode":"async","kind":"chat","key_name":"kernel","status":"done",
  "accepted_at":"2026-10-17T10:00:02Z","served_model":"gpt-oss:120b-cloud","lane_served":"cloud","fallback_reason":"local_wait","prompt_tokens":1000000,"output_tokens":1000000,"error_text":"late note"}'::jsonb));
SELECT pg_temp.check(pg_temp.u('r2b') = pg_temp.u('r2') AND (SELECT node_seq = 43 AND error_text = 'late note' FROM sl_runs WHERE id = pg_temp.u('r2')), 'the same node run mirrored again updates in place (since_seq re-sync)');
SELECT pg_temp.keep('r3', sl_run_mirror((SELECT mac FROM ids), '{"id":"55555555-5555-5555-5555-555555555555","seq":44,"face":"openai","mode":"sync","kind":"chat","key_name":"ide","status":"failed","error_code":"model_missing",
  "accepted_at":"2026-10-17T10:01:00Z","requested_model":"llama4","served_model":"llama4","lane_requested":"local","lane_served":"local"}'::jsonb));
INSERT INTO sl_run_events (run_id, node_event_id, at, kind, detail) VALUES (pg_temp.u('r1'), 1, '2026-10-17T10:00:00Z', 'queued', '{"lane":"local"}'), (pg_temp.u('r1'), 2, '2026-10-17T10:00:01Z', 'started', '{}');
SELECT pg_temp.refused($$INSERT INTO sl_run_events (run_id, node_event_id, at, kind) VALUES (pg_temp.u('r1'), 2, now(), 'started')$$, 'duplicate', 'an event mirrors once');

-- ================================================================ 4. models, intent and drift (D11)
SELECT pg_temp.check(sl_model_mirror((SELECT mac FROM ids), '{"name":"qwen3:8b","seq":10,"lane":"local","family":"qwen3","parameter_size":"8B","quantization":"Q4_K_M","context_length":32768,"capabilities":["chat","tools"],
  "size_bytes":5000000000,"on_disk":true,"loaded":true,"status":"available","keep_alive":"5m","allowed":true}'::jsonb) > 0, 'a model mirrored');
SELECT sl_model_mirror((SELECT mac FROM ids), '{"name":"gpt-oss:120b-cloud","seq":11,"lane":"cloud","on_disk":true,"status":"available"}'::jsonb);
SELECT pg_temp.check((SELECT sl_model_drift(id) = '{}'::jsonb FROM sl_models WHERE name = 'qwen3:8b'), 'no intent, no drift');
UPDATE sl_models SET wanted_keep_alive = '-1', wanted_fallback_model = 'gpt-oss:120b-cloud', wanted_set_by = 27, wanted_set_at = now() WHERE name = 'qwen3:8b';
SELECT pg_temp.check((SELECT sl_model_drift(id) = '{"keep_alive":{"node":"5m","wanted":"-1"},"fallback_model":{"wanted":"gpt-oss:120b-cloud"}}'::jsonb FROM sl_models WHERE name = 'qwen3:8b'), 'drift names what the node does not yet report');
SELECT sl_model_mirror((SELECT mac FROM ids), '{"name":"qwen3:8b","seq":12,"lane":"local","on_disk":true,"loaded":true,"status":"available","keep_alive":"-1","fallback_model":"gpt-oss:120b-cloud","allowed":true}'::jsonb);
SELECT pg_temp.check((SELECT sl_model_drift(id) = '{}'::jsonb AND wanted_keep_alive = '-1' FROM sl_models WHERE name = 'qwen3:8b'), 'the node reporting the intent: no drift; the mirror never touches wanted_*');
SELECT pg_temp.check((SELECT lane = 'cloud' FROM mcp_models WHERE name = 'gpt-oss:120b-cloud'), 'the view''s lane is the override or the detected one');

-- ================================================================ 5. usage (D6) and the K7 share's function
SELECT pg_temp.check(sl_usage_rollup('2026-10-17') = 3, 'the day rolled up: three groups (ide/qwen local done, kernel/cloud, ide/llama4 failed)');
SELECT pg_temp.check((SELECT runs = 1 AND fallbacks = 1 AND tokens_total = 2000000 AND notional_cost = 2.5 FROM mcp_usage_daily WHERE key_name = 'kernel'), 'the kernel key''s day: one run, one fallback, 2M tokens, 2.50');
SELECT pg_temp.check((SELECT failures = 1 FROM mcp_usage_daily WHERE served_model = 'llama4'), 'a failure counted');
SELECT pg_temp.check((SELECT sum(tokens_total) FROM sl_usage_by_period('2026-10-17', '2026-10-18', 'lane')) = 2000420, 'usage_by_period by lane sums every token');
SELECT pg_temp.check((SELECT grp FROM sl_usage_by_period('2026-10-17', '2026-10-18', 'node') LIMIT 1) = 'Mac Mini', 'by node: the node''s name');
SELECT sl_usage_rollup('2026-10-17');
SELECT pg_temp.check((SELECT count(*) FROM sl_usage_daily) = 3, 'a rollup is idempotent');
SELECT pg_temp.check((SELECT tps_p50 = 125 AND load_ms_p50 = 350 FROM sl_runs_stats('2026-10-17', '2026-10-18', 'model') WHERE grp = 'qwen3:8b'), 'runs_stats: percentiles by model');

-- ================================================================ 6. notices (D10): one open row per streak
SELECT pg_temp.check(sl_notice_raise('node_down', (SELECT mac FROM ids), '', 'Mac Mini is not answering') = sl_notice_raise('node_down', (SELECT mac FROM ids), '', 'Mac Mini is not answering'), 'raising twice bumps the same open notice');
SELECT pg_temp.check((SELECT occurrences = 2 AND resolved_at IS NULL FROM sl_notices WHERE kind = 'node_down'), '…its occurrences counted');
SELECT pg_temp.check(sl_notice_resolve('node_down', (SELECT mac FROM ids), '') = 1, 'resolved');
SELECT pg_temp.check(sl_notice_resolve('node_down', (SELECT mac FROM ids), '') = 0, '…once');
SELECT sl_notice_raise('node_down', (SELECT mac FROM ids), '', 'again');
SELECT pg_temp.check((SELECT count(*) FROM sl_notices WHERE kind = 'node_down') = 2 AND (SELECT count(*) FROM sl_notices WHERE kind = 'node_down' AND resolved_at IS NULL) = 1, 'a new streak after a resolve is a new row');
SELECT pg_temp.refused($$INSERT INTO sl_notices (kind, streak_key, title) VALUES ('bogus', 'x', 'x')$$, 'check', 'a notice kind is one of the list');

-- ================================================================ 7. the walls (§3)
SELECT pg_temp.as_member(30);
SELECT pg_temp.check((SELECT count(*) FROM mcp_nodes) = 2 AND (SELECT count(*) FROM mcp_runs) = 3 AND (SELECT count(*) FROM mcp_queue) = 1, 'a Viewer sees every node, run and queue row');
SELECT pg_temp.check(NOT sl_can_read_payload(pg_temp.u('r1')), '…but no payload');
SELECT pg_temp.check((SELECT count(*) FROM mcp_caller_keys) = 0, '…and no key they do not own');
SELECT pg_temp.as_member(26);
SELECT pg_temp.check(sl_can_read_payload(pg_temp.u('r1')) AND NOT sl_can_read_payload(pg_temp.u('r2')), 'the key''s owner reads its run''s payload and no other');
SELECT pg_temp.check((SELECT string_agg(name, ',') FROM mcp_caller_keys) = 'ide', 'a key''s owner sees their own key');
SELECT pg_temp.as_member(27);
SELECT pg_temp.check(sl_can_read_payload(pg_temp.u('r2')) AND (SELECT count(*) FROM mcp_caller_keys) = 2, 'an LLM admin reads every payload and sees every key');
SELECT pg_temp.as_member(32);
SELECT pg_temp.check((SELECT count(*) FROM mcp_nodes) = 0 AND NOT sl_can_read_payload(pg_temp.u('r1')), 'no grant, nothing');
SELECT pg_temp.as_member(40);
SELECT pg_temp.check((SELECT count(*) FROM mcp_runs) = 3 AND NOT sl_can_read_payload(pg_temp.u('r1')), 'an agent sees the runs and never a payload');
SELECT pg_temp.check(NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'mcp_nodes' AND column_name LIKE '%ciphertext%'), 'the nodes view carries no credential');
RESET ROLE;

-- the records role: views and functions only, no base table
SET ROLE sovereign_llm_manager_records_ro;
SELECT pg_temp.as_member(27);
SELECT pg_temp.check((SELECT count(*) FROM mcp_runs) = 3, 'the records role reads the runs view');
SELECT pg_temp.refused($$SELECT count(*) FROM sl_runs$$, 'permission denied', 'the records role has no SELECT on sl_runs');
SELECT pg_temp.refused($$SELECT count(*) FROM sl_run_payloads$$, 'permission denied', 'the records role has no SELECT on the payloads');
SELECT pg_temp.refused($$SELECT count(*) FROM sl_nodes$$, 'permission denied', 'the records role has no SELECT on sl_nodes');
SELECT pg_temp.check((SELECT count(*) FROM sl_runs_stats('2026-10-17', '2026-10-18')) = 3, 'the records role runs the stats function');
RESET ROLE;
SET ROLE sovereign_llm_manager_activity_ro;
SELECT pg_temp.as_member(27);
SELECT pg_temp.refused($$SELECT count(*) FROM mcp_runs$$, 'permission denied', 'the activity role reads no run');
SELECT pg_temp.check((SELECT count(*) FROM mcp_activity_log) = 0, 'the activity role reads the trail');
RESET ROLE;

\o
SELECT CASE WHEN ok THEN 'ok   ' ELSE 'FAIL ' END || label FROM proof ORDER BY n;
SELECT ' ' || count(*) FILTER (WHERE ok) || ' ok, ' || count(*) FILTER (WHERE NOT ok) || ' failed' FROM proof;
DO $$ BEGIN IF EXISTS (SELECT 1 FROM proof WHERE NOT ok) THEN RAISE EXCEPTION 'the schema proof failed'; END IF; END $$;
ROLLBACK;
