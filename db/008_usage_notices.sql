-- 008: USAGE BY PERIOD and the NOTICES (design §6.1, §7; D6 money, D10 thresholds).
--
--   sl_usage_daily   a rollup by day × node × caller key × model × lane, recomputed from sl_runs by the worker for the days a pass
--                    touched (sl_usage_rollup(day)); the K7 share usage_by_period reads it — the kernel's ai_usage_postings shape in
--                    words (tokens and a notional cost; the kernel keeps money)
--   sl_notices       Inventory's streak-keyed notice: one open row per (kind, node, subject) at a time, resolved on recovery
BEGIN;

CREATE TABLE sl_usage_daily (
    day                 date NOT NULL,
    node_id             bigint NOT NULL REFERENCES sl_nodes(id) ON DELETE CASCADE,
    caller_key_id       bigint REFERENCES sl_caller_keys(id) ON DELETE SET NULL,
    key_name            text NOT NULL DEFAULT '',
    served_model        text NOT NULL DEFAULT '',
    lane                text NOT NULL DEFAULT '',
    runs                integer NOT NULL DEFAULT 0,
    failures            integer NOT NULL DEFAULT 0,
    fallbacks           integer NOT NULL DEFAULT 0,
    tokens_in           bigint NOT NULL DEFAULT 0,
    tokens_out          bigint NOT NULL DEFAULT 0,
    queue_wait_ms_p50   integer, queue_wait_ms_p95 integer,
    duration_ms_p50     integer, duration_ms_p95 integer,
    tps_p50             numeric(10,2),
    notional_cost       numeric(14,6) NOT NULL DEFAULT 0,
    computed_at         timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (day, node_id, key_name, served_model, lane)
);
CREATE INDEX sl_usage_daily_key_idx ON sl_usage_daily (caller_key_id, day);
CREATE INDEX sl_usage_daily_model_idx ON sl_usage_daily (served_model, day);

CREATE OR REPLACE FUNCTION sl_usage_rollup(p_day date) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n integer;
BEGIN
    DELETE FROM sl_usage_daily WHERE day = p_day;
    INSERT INTO sl_usage_daily (day, node_id, caller_key_id, key_name, served_model, lane, runs, failures, fallbacks, tokens_in, tokens_out,
                                queue_wait_ms_p50, queue_wait_ms_p95, duration_ms_p50, duration_ms_p95, tps_p50, notional_cost)
    SELECT p_day, r.node_id, max(r.caller_key_id), COALESCE(r.key_name, ''), COALESCE(r.served_model, ''), COALESCE(r.lane_served, ''),
           count(*), count(*) FILTER (WHERE r.status = 'failed'), count(*) FILTER (WHERE r.fallback_reason IS NOT NULL),
           COALESCE(sum(r.prompt_tokens), 0), COALESCE(sum(r.output_tokens), 0),
           percentile_cont(0.5) WITHIN GROUP (ORDER BY r.queue_wait_ms) FILTER (WHERE r.status = 'done'),
           percentile_cont(0.95) WITHIN GROUP (ORDER BY r.queue_wait_ms) FILTER (WHERE r.status = 'done'),
           percentile_cont(0.5) WITHIN GROUP (ORDER BY r.total_ms) FILTER (WHERE r.status = 'done'),
           percentile_cont(0.95) WITHIN GROUP (ORDER BY r.total_ms) FILTER (WHERE r.status = 'done'),
           percentile_cont(0.5) WITHIN GROUP (ORDER BY r.output_tokens_per_second) FILTER (WHERE r.status = 'done'),
           COALESCE(sum(r.notional_cost), 0)
      FROM sl_runs r
     WHERE r.kind IN ('chat', 'embed') AND r.status NOT IN ('queued', 'running')
       AND (r.accepted_at AT TIME ZONE 'UTC')::date = p_day
     GROUP BY r.node_id, r.key_name, r.served_model, r.lane_served;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END$$;

-- Usage for a period, grouped (the share usage_by_period and the Usage screen read this): tokens, runs, failures, fallbacks, cost.
CREATE OR REPLACE FUNCTION sl_usage_by_period(p_from date, p_to date, p_group text DEFAULT 'key')
    RETURNS TABLE (grp text, runs bigint, failures bigint, fallbacks bigint, tokens_in bigint, tokens_out bigint, tokens_total bigint, notional_cost numeric)
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT CASE p_group WHEN 'node' THEN (SELECT n.name FROM sl_nodes n WHERE n.id = u.node_id) WHEN 'model' THEN u.served_model WHEN 'lane' THEN u.lane
                        WHEN 'day' THEN u.day::text ELSE u.key_name END AS grp,
           sum(u.runs)::bigint, sum(u.failures)::bigint, sum(u.fallbacks)::bigint, sum(u.tokens_in)::bigint, sum(u.tokens_out)::bigint,
           (sum(u.tokens_in) + sum(u.tokens_out))::bigint, sum(u.notional_cost)
      FROM sl_usage_daily u WHERE u.day >= p_from AND u.day < p_to
     GROUP BY 1 ORDER BY 1;
$$;

CREATE TABLE sl_notices (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind          text NOT NULL CHECK (kind IN ('node_down', 'node_recovered', 'queue_depth', 'queue_wait', 'fallback_rate', 'model_missing', 'pull_failed',
                                                'clock_skew', 'policy_drift', 'key_cap', 'backend_down')),
    severity      text NOT NULL DEFAULT 'warning' CHECK (severity IN ('info', 'warning', 'critical')),
    node_id       bigint REFERENCES sl_nodes(id) ON DELETE CASCADE,
    subject       text NOT NULL DEFAULT '',                                 -- the model, the key, the lane the notice is about
    streak_key    text NOT NULL,                                            -- kind:node:subject — one OPEN row per key at a time
    title         text NOT NULL,
    body          text,
    detail        jsonb NOT NULL DEFAULT '{}'::jsonb,
    opened_at     timestamptz NOT NULL DEFAULT now(),
    last_seen_at  timestamptz NOT NULL DEFAULT now(),
    occurrences   integer NOT NULL DEFAULT 1,
    resolved_at   timestamptz,
    resolved_by   bigint REFERENCES members(id) ON DELETE SET NULL,          -- NULL = the worker, on recovery
    acknowledged_by bigint REFERENCES members(id) ON DELETE SET NULL,
    acknowledged_at timestamptz
);
CREATE UNIQUE INDEX sl_notices_open_idx ON sl_notices (streak_key) WHERE resolved_at IS NULL;
CREATE INDEX sl_notices_node_idx ON sl_notices (node_id, opened_at DESC);
CREATE INDEX sl_notices_open_time_idx ON sl_notices (opened_at DESC) WHERE resolved_at IS NULL;

-- Open or bump a notice (one open row per streak key); the worker and the handlers call these.
CREATE OR REPLACE FUNCTION sl_notice_raise(p_kind text, p_node bigint, p_subject text, p_title text, p_body text DEFAULT NULL, p_severity text DEFAULT 'warning', p_detail jsonb DEFAULT '{}'::jsonb)
    RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_key text := p_kind || ':' || COALESCE(p_node::text, '-') || ':' || COALESCE(p_subject, ''); v_id bigint;
BEGIN
    UPDATE sl_notices SET last_seen_at = now(), occurrences = occurrences + 1, body = COALESCE(p_body, body), detail = p_detail
     WHERE streak_key = v_key AND resolved_at IS NULL RETURNING id INTO v_id;
    IF v_id IS NULL THEN
        INSERT INTO sl_notices (kind, severity, node_id, subject, streak_key, title, body, detail)
        VALUES (p_kind, p_severity, p_node, COALESCE(p_subject, ''), v_key, p_title, p_body, p_detail) RETURNING id INTO v_id;
    END IF;
    RETURN v_id;
END$$;

CREATE OR REPLACE FUNCTION sl_notice_resolve(p_kind text, p_node bigint, p_subject text DEFAULT '', p_by bigint DEFAULT NULL) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n integer;
BEGIN
    UPDATE sl_notices SET resolved_at = now(), resolved_by = p_by
     WHERE streak_key = p_kind || ':' || COALESCE(p_node::text, '-') || ':' || COALESCE(p_subject, '') AND resolved_at IS NULL;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END$$;

-- The thresholds (D10) live in sl_settings: appended columns.
ALTER TABLE sl_settings
    ADD COLUMN queue_depth_threshold     integer NOT NULL DEFAULT 20 CHECK (queue_depth_threshold >= 1),
    ADD COLUMN queue_wait_threshold_s    integer NOT NULL DEFAULT 300 CHECK (queue_wait_threshold_s >= 1),
    ADD COLUMN fallback_rate_threshold   numeric(5,2) NOT NULL DEFAULT 25 CHECK (fallback_rate_threshold BETWEEN 0 AND 100),
    ADD COLUMN node_silent_threshold_s   integer NOT NULL DEFAULT 120 CHECK (node_silent_threshold_s >= 15),
    ADD COLUMN health_interval_s         integer NOT NULL DEFAULT 15 CHECK (health_interval_s BETWEEN 5 AND 300),
    ADD COLUMN sync_interval_s           integer NOT NULL DEFAULT 60 CHECK (sync_interval_s BETWEEN 15 AND 3600),
    ADD COLUMN usage_check_interval_s    integer NOT NULL DEFAULT 300 CHECK (usage_check_interval_s BETWEEN 60 AND 86400),
    ADD COLUMN payload_mirror_default    text NOT NULL DEFAULT 'none' CHECK (payload_mirror_default IN ('none', 'full')),
    ADD COLUMN notional_currency         char(3) NOT NULL DEFAULT 'USD';

GRANT SELECT, INSERT, UPDATE, DELETE ON sl_usage_daily, sl_notices TO sovereign_llm_manager_rw;
GRANT EXECUTE ON FUNCTION sl_usage_rollup(date), sl_notice_raise(text, bigint, text, text, text, text, jsonb), sl_notice_resolve(text, bigint, text, bigint) TO sovereign_llm_manager_rw;
GRANT EXECUTE ON FUNCTION sl_usage_by_period(date, date, text) TO sovereign_llm_manager_rw, sovereign_llm_manager_records_ro;

COMMIT;
