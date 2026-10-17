-- 010: THE WALLS and the mcp_* views (design §3): every holder sees every node, queue and run's metadata; a PAYLOAD is an LLM admin's
-- or the key's owner's; a credential is nobody's. The records role reads views and SECURITY DEFINER functions only.
BEGIN;

-- The payload wall (§3), one query: an admin, or the owner of the key the run was made with.
CREATE OR REPLACE FUNCTION sl_can_read_payload(p_run uuid) RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_me bigint := app_current_member_id();
BEGIN
    IF v_me IS NULL OR NOT sl_is_member_here() THEN RETURN false; END IF;
    IF sl_has_right('payloads.read') THEN RETURN true; END IF;
    RETURN EXISTS (SELECT 1 FROM sl_runs r JOIN sl_caller_keys k ON k.id = r.caller_key_id WHERE r.id = p_run AND k.owner_member_id = v_me);
END$$;

-- Who sees which key: an LLM admin (keys.admin) every key — name, owner, limits, nothing secret in them —; everyone else the keys
-- they own (keys.read_own, a Viewer's right too).
CREATE OR REPLACE FUNCTION sl_can_see_key(p_key bigint) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT sl_is_member_here() AND (sl_has_right('keys.admin') OR EXISTS (SELECT 1 FROM sl_caller_keys k WHERE k.id = p_key AND k.owner_member_id = app_current_member_id()));
$$;

-- The directory, the kit's shape (Boards db/012)
CREATE OR REPLACE VIEW mcp_members WITH (security_barrier = true) AS
SELECT m.id AS member_id, m.display_name, m.member_kind, m.is_agent, m.business_role, m.is_external, m.status, m.capability, m.roles,
       sl_member_roles(m.id) AS roles_resolved, m.job_title, m.timezone,
       CASE WHEN NOT (SELECT m2.is_external FROM members m2 WHERE m2.id = app_current_member_id()) THEN m.email::text END AS email,
       (SELECT array_agg(dm.department_id) FROM department_members dm WHERE dm.member_id = m.id AND dm.left_at IS NULL) AS department_ids
  FROM members m
 WHERE m.status = 'active' AND m.capability IS NOT NULL AND (SELECT sl_is_member_here())
   AND (NOT (SELECT m2.is_external FROM members m2 WHERE m2.id = app_current_member_id()) OR m.id = app_current_member_id());

CREATE OR REPLACE VIEW mcp_departments WITH (security_barrier = true) AS
SELECT d.id AS department_id, d.name, d.description, d.parent_id, d.manager_member_id, d.is_system, d.system_key, d.archived_at
  FROM departments d WHERE (SELECT sl_is_member_here());

-- Nodes: every holder; no credential column, ever.
CREATE OR REPLACE VIEW mcp_nodes WITH (security_barrier = true) AS
SELECT n.id AS node_id, n.name, n.base_url, n.node_uuid, n.status, n.backend_kind, n.backend_version, n.node_version, n.machine, n.lanes,
       n.loaded_models, n.location_id, n.payload_mirror, n.last_seen_at, n.last_seq, n.policy_version, n.clock_skew_ms, n.schedule_seconds,
       n.last_ok_at, n.consecutive_failures, n.backoff_until, n.paused_at, n.paused_reason, n.active, n.node_key_last4, (n.node_key_ciphertext IS NOT NULL) AS registered,
       n.created_at, n.updated_at
  FROM sl_nodes n WHERE (SELECT sl_is_member_here());

CREATE OR REPLACE VIEW mcp_node_pulls WITH (security_barrier = true) AS
SELECT p.id AS pull_id, p.node_id, p.kind, p.started_at, p.finished_at, p.status, p.runs_seen, p.runs_new, p.runs_changed, p.models_changed,
       p.policies_pushed, p.http_requests, p.bytes, p.error, p.seq_from, p.seq_to, p.started_by
  FROM sl_node_pulls p WHERE (SELECT sl_is_member_here());

CREATE OR REPLACE VIEW mcp_queue WITH (security_barrier = true) AS
SELECT q.node_id, n.name AS node_name, q.node_job_id, q.lane, q.status, q.kind, q.requested_model, q.served_model, q.key_name, q.priority, q.mode, q.face,
       q.position, q.expected_wait_ms, q.queued_at, q.started_at, q.tokens_so_far, q.fallback_model, q.tags, q.taken_at
  FROM sl_queue_snapshot q JOIN sl_nodes n ON n.id = q.node_id WHERE (SELECT sl_is_member_here());

-- Runs: metadata for every holder; never the payload (that is sl_run_payloads behind sl_can_read_payload, read by PHP alone).
CREATE OR REPLACE VIEW mcp_runs WITH (security_barrier = true) AS
SELECT r.id AS run_id, r.node_id, n.name AS node_name, r.node_run_id, r.face, r.mode, r.kind, r.key_name, r.caller_key_id, r.tags, r.requested_model,
       r.served_model, r.lane_requested, r.lane_served, r.fallback_reason, r.fallback_model, r.priority, r.stream, r.status, r.accepted_at, r.started_at,
       r.first_token_at, r.finished_at, r.queue_wait_ms, r.time_to_first_token_ms, r.run_ms, r.total_ms, r.load_ms, r.prompt_tokens, r.prompt_eval_ms,
       r.output_tokens, r.eval_ms, r.total_backend_ms, r.prompt_tokens_per_second, r.output_tokens_per_second, r.model_was_loaded, r.request_bytes,
       r.response_bytes, r.messages_count, r.images_count, r.tools_count, r.context_length, r.context_used, r.stop_reason, r.error_code, r.error_text,
       r.http_status, r.memory_free_at_start_bytes, r.loaded_models_at_start, r.cpu_load_1m, r.kernel_ledger_id, r.notional_cost, r.mirrored_at
  FROM sl_runs r JOIN sl_nodes n ON n.id = r.node_id WHERE (SELECT sl_is_member_here());

CREATE OR REPLACE VIEW mcp_run_events WITH (security_barrier = true) AS
SELECT e.run_id, e.node_event_id, e.at, e.kind, e.detail FROM sl_run_events e WHERE (SELECT sl_is_member_here());

CREATE OR REPLACE VIEW mcp_models WITH (security_barrier = true) AS
SELECT m.id AS model_id, m.node_id, n.name AS node_name, m.name, COALESCE(m.lane_override, m.lane) AS lane, m.lane AS lane_detected, m.lane_override, m.family,
       m.parameter_size, m.quantization, m.context_length, m.capabilities, m.size_bytes, m.digest, m.on_disk, m.loaded, m.loaded_size_bytes, m.expires_at,
       m.status, m.keep_alive, m.warm_schedule, m.fallback_model, m.fallback_after_seconds, m.allowed, m.alias, m.pull_error,
       m.wanted_keep_alive, m.wanted_warm_schedule, m.wanted_fallback_model, m.wanted_fallback_after_seconds, m.wanted_allowed, m.wanted_alias, m.wanted_lane_override,
       sl_model_drift(m.id) AS drift, m.applied_at, m.first_seen_at, m.updated_at
  FROM sl_models m JOIN sl_nodes n ON n.id = m.node_id WHERE (SELECT sl_is_member_here());

CREATE OR REPLACE VIEW mcp_model_prices WITH (security_barrier = true) AS
SELECT p.id AS price_id, p.model_name, p.price_input_per_mtok, p.price_output_per_mtok, p.currency, p.note, p.updated_at
  FROM sl_model_prices p WHERE (SELECT sl_is_member_here());

-- Keys: the name, owner, limits and status; never a key, never a hash (none is here).
CREATE OR REPLACE VIEW mcp_caller_keys WITH (security_barrier = true) AS
SELECT k.id AS key_id, k.node_id, n.name AS node_name, k.name, k.prefix, k.owner_member_id, o.display_name AS owner_name, k.application_key, k.max_priority,
       k.max_concurrent, k.cloud_allowed, k.fallback_allowed, k.payload_retention, k.allowed_models, k.daily_token_cap, k.status, k.minted_by, k.minted_at,
       k.last_used_at, k.revoked_at
  FROM sl_caller_keys k JOIN sl_nodes n ON n.id = k.node_id LEFT JOIN members o ON o.id = k.owner_member_id
 WHERE sl_can_see_key(k.id);

CREATE OR REPLACE VIEW mcp_usage_daily WITH (security_barrier = true) AS
SELECT u.day, u.node_id, n.name AS node_name, u.caller_key_id, u.key_name, u.served_model, u.lane, u.runs, u.failures, u.fallbacks, u.tokens_in, u.tokens_out,
       u.tokens_in + u.tokens_out AS tokens_total, u.queue_wait_ms_p50, u.queue_wait_ms_p95, u.duration_ms_p50, u.duration_ms_p95, u.tps_p50, u.notional_cost, u.computed_at
  FROM sl_usage_daily u JOIN sl_nodes n ON n.id = u.node_id WHERE (SELECT sl_is_member_here());

CREATE OR REPLACE VIEW mcp_notices WITH (security_barrier = true) AS
SELECT x.id AS notice_id, x.kind, x.severity, x.node_id, n.name AS node_name, x.subject, x.title, x.body, x.detail, x.opened_at, x.last_seen_at, x.occurrences,
       x.resolved_at, x.resolved_by, x.acknowledged_by, x.acknowledged_at
  FROM sl_notices x LEFT JOIN sl_nodes n ON n.id = x.node_id WHERE (SELECT sl_is_member_here());

CREATE OR REPLACE VIEW mcp_settings WITH (security_barrier = true) AS
SELECT s.business_name, s.timezone, s.queue_depth_threshold, s.queue_wait_threshold_s, s.fallback_rate_threshold, s.node_silent_threshold_s,
       s.health_interval_s, s.sync_interval_s, s.usage_check_interval_s, s.payload_mirror_default, s.notional_currency, s.updated_at
  FROM sl_settings s WHERE (SELECT sl_is_member_here());

-- The activity trail for the activity MCP (the kit's shape)
CREATE OR REPLACE VIEW mcp_activity_log WITH (security_barrier = true) AS
SELECT a.id, a.occurred_at, a.actor_member_id, m.display_name AS actor_name, a.source, a.action, a.screen, a.route, a.entity_type, a.entity_id,
       a.before, a.after, a.request_id, a.agent_run_id, a.department_id, a.kernel_request_id
  FROM activity_log a LEFT JOIN members m ON m.id = a.actor_member_id WHERE (SELECT sl_is_member_here());

-- Stats over runs for the expert: percentiles by model / node / key over a window (one query).
CREATE OR REPLACE FUNCTION sl_runs_stats(p_from timestamptz, p_to timestamptz, p_group text DEFAULT 'model', p_node bigint DEFAULT NULL)
    RETURNS TABLE (grp text, runs bigint, done bigint, failed bigint, fallbacks bigint, tokens_in bigint, tokens_out bigint,
                   queue_wait_ms_p50 numeric, queue_wait_ms_p95 numeric, ttft_ms_p50 numeric, duration_ms_p50 numeric, duration_ms_p95 numeric,
                   tps_p50 numeric, load_ms_p50 numeric, notional_cost numeric)
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT CASE p_group WHEN 'node' THEN n.name WHEN 'key' THEN r.key_name WHEN 'lane' THEN r.lane_served WHEN 'day' THEN (r.accepted_at AT TIME ZONE 'UTC')::date::text ELSE r.served_model END,
           count(*), count(*) FILTER (WHERE r.status = 'done'), count(*) FILTER (WHERE r.status = 'failed'), count(*) FILTER (WHERE r.fallback_reason IS NOT NULL),
           COALESCE(sum(r.prompt_tokens), 0), COALESCE(sum(r.output_tokens), 0),
           percentile_cont(0.5) WITHIN GROUP (ORDER BY r.queue_wait_ms) FILTER (WHERE r.status = 'done'),
           percentile_cont(0.95) WITHIN GROUP (ORDER BY r.queue_wait_ms) FILTER (WHERE r.status = 'done'),
           percentile_cont(0.5) WITHIN GROUP (ORDER BY r.time_to_first_token_ms) FILTER (WHERE r.status = 'done'),
           percentile_cont(0.5) WITHIN GROUP (ORDER BY r.total_ms) FILTER (WHERE r.status = 'done'),
           percentile_cont(0.95) WITHIN GROUP (ORDER BY r.total_ms) FILTER (WHERE r.status = 'done'),
           percentile_cont(0.5) WITHIN GROUP (ORDER BY r.output_tokens_per_second) FILTER (WHERE r.status = 'done'),
           percentile_cont(0.5) WITHIN GROUP (ORDER BY r.load_ms) FILTER (WHERE r.status = 'done' AND NOT r.model_was_loaded),
           COALESCE(sum(r.notional_cost), 0)
      FROM sl_runs r JOIN sl_nodes n ON n.id = r.node_id
     WHERE sl_is_member_here() AND r.kind IN ('chat', 'embed') AND r.accepted_at >= p_from AND r.accepted_at < p_to AND (p_node IS NULL OR r.node_id = p_node)
     GROUP BY 1 ORDER BY 1;
$$;

GRANT SELECT ON mcp_members, mcp_departments, mcp_nodes, mcp_node_pulls, mcp_queue, mcp_runs, mcp_run_events, mcp_models, mcp_model_prices, mcp_caller_keys,
                mcp_usage_daily, mcp_notices, mcp_settings TO sovereign_llm_manager_rw, sovereign_llm_manager_records_ro;
GRANT SELECT ON mcp_activity_log, mcp_members, mcp_departments TO sovereign_llm_manager_activity_ro;
GRANT EXECUTE ON FUNCTION sl_can_read_payload(uuid), sl_can_see_key(bigint), sl_runs_stats(timestamptz, timestamptz, text, bigint)
    TO sovereign_llm_manager_rw, sovereign_llm_manager_records_ro;

COMMIT;
