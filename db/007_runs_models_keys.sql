-- 007: THE RUN RECORD, its timeline and payloads; the models on each node with the manager's intent; notional prices; the caller
-- keys (design §6.1, §7 of the server design; D3, D6, D8).
--
-- THE ESTATE'S DATA MODEL:
--   sl_runs           NEW CANONICAL — the LLM run record: the server design §7's columns + node_id, node_run_id (unique per node),
--                     caller_key_id, kernel_ledger_id (K58). A sibling that keeps model runs of its own takes these columns.
--   sl_run_events     the timeline mirrored (the node's events table)
--   sl_run_payloads   the request/response when mirrored (payload_mirror = full) — behind sl_can_read_payload()
--   sl_models         the node's catalogue + wanted_* (the manager's intent; drift = wanted ≠ reported)
--   sl_model_prices   notional price per model name (D6)
--   sl_caller_keys    Knowledge `api_keys` shape (shown once, hash kept THERE — here no key and no hash; D8 every key has an owner)
BEGIN;

CREATE TABLE sl_runs (
    id                         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    node_id                    bigint NOT NULL REFERENCES sl_nodes(id) ON DELETE CASCADE,
    node_run_id                uuid NOT NULL,
    node_seq                   bigint NOT NULL,
    face                       text NOT NULL CHECK (face IN ('openai', 'anthropic', 'node')),
    mode                       text NOT NULL CHECK (mode IN ('sync', 'async')),
    kind                       text NOT NULL CHECK (kind IN ('chat', 'embed', 'load', 'pull', 'delete')),
    key_name                   text,
    caller_key_id              bigint,                                                                 -- FK below
    tags                       text[] NOT NULL DEFAULT '{}',
    idempotency_key            text,
    client_ip                  inet,
    user_agent                 text,
    requested_model            text,
    served_model               text,
    lane_requested             text,
    lane_served                text,
    fallback_reason            text CHECK (fallback_reason IS NULL OR fallback_reason IN ('local_wait', 'local_unavailable', 'forced')),
    fallback_model             text,
    priority                   integer,
    stream                     boolean NOT NULL DEFAULT false,
    status                     text NOT NULL CHECK (status IN ('queued', 'running', 'done', 'failed', 'cancelled', 'expired')),
    accepted_at                timestamptz NOT NULL,
    started_at                 timestamptz,
    first_token_at             timestamptz,
    finished_at                timestamptz,
    queue_wait_ms              integer,
    time_to_first_token_ms     integer,
    run_ms                     integer,
    total_ms                   integer,
    load_ms                    integer,
    prompt_tokens              integer,
    prompt_eval_ms             integer,
    output_tokens              integer,
    eval_ms                    integer,
    total_backend_ms           integer,
    prompt_tokens_per_second   numeric(10,2),
    output_tokens_per_second   numeric(10,2),
    model_was_loaded           boolean,
    request_bytes              integer,
    response_bytes             integer,
    messages_count             integer,
    images_count               integer,
    tools_count                integer,
    context_length             integer,
    context_used               integer,
    stop_reason                text,
    error_code                 text,
    error_text                 text,
    http_status                integer,
    memory_free_at_start_bytes bigint,
    loaded_models_at_start     text[],
    cpu_load_1m                numeric(8,2),
    kernel_ledger_id           bigint,                                                                 -- K58
    notional_cost              numeric(14,6),                                                          -- from sl_model_prices at mirror time
    mirrored_at                timestamptz NOT NULL DEFAULT now(),
    UNIQUE (node_id, node_run_id)
);
CREATE INDEX sl_runs_node_time_idx ON sl_runs (node_id, accepted_at DESC);
CREATE INDEX sl_runs_time_idx ON sl_runs (accepted_at DESC);
CREATE INDEX sl_runs_model_idx ON sl_runs (served_model, accepted_at DESC);
CREATE INDEX sl_runs_key_idx ON sl_runs (caller_key_id, accepted_at DESC) WHERE caller_key_id IS NOT NULL;
CREATE INDEX sl_runs_status_idx ON sl_runs (status, accepted_at DESC);
CREATE INDEX sl_runs_fallback_idx ON sl_runs (node_id, accepted_at DESC) WHERE fallback_reason IS NOT NULL;
CREATE INDEX sl_runs_tags_idx ON sl_runs USING gin (tags);

CREATE TABLE sl_run_events (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id        uuid NOT NULL REFERENCES sl_runs(id) ON DELETE CASCADE,
    node_event_id bigint NOT NULL,
    at            timestamptz NOT NULL,
    kind          text NOT NULL,
    detail        jsonb NOT NULL DEFAULT '{}'::jsonb,
    UNIQUE (run_id, node_event_id)
);
CREATE INDEX sl_run_events_run_idx ON sl_run_events (run_id, at);

CREATE TABLE sl_run_payloads (
    run_id        uuid PRIMARY KEY REFERENCES sl_runs(id) ON DELETE CASCADE,
    request       jsonb,
    response      jsonb,
    fetched_at    timestamptz NOT NULL DEFAULT now(),
    fetched_by    bigint REFERENCES members(id) ON DELETE SET NULL                                     -- NULL = the worker's mirror
);

CREATE TABLE sl_models (
    id                          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    node_id                     bigint NOT NULL REFERENCES sl_nodes(id) ON DELETE CASCADE,
    name                        text NOT NULL,
    node_seq                    bigint NOT NULL DEFAULT 0,
    lane                        text NOT NULL DEFAULT 'local' CHECK (lane IN ('local', 'cloud')),
    lane_override               text CHECK (lane_override IS NULL OR lane_override IN ('local', 'cloud')),
    family                      text, parameter_size text, quantization text, context_length integer,
    capabilities                text[] NOT NULL DEFAULT '{}',
    size_bytes                  bigint, digest text,
    on_disk                     boolean NOT NULL DEFAULT false,
    loaded                      boolean NOT NULL DEFAULT false, loaded_size_bytes bigint, expires_at timestamptz,
    status                      text NOT NULL DEFAULT 'available' CHECK (status IN ('available', 'pulling', 'missing', 'disabled')),
    -- what the node reports
    keep_alive                  text, warm_schedule text, fallback_model text, fallback_after_seconds integer, allowed boolean NOT NULL DEFAULT true, alias text,
    pull_error                  text,
    -- what the manager wants (D11): NULL = no intent, the node's value stands
    wanted_keep_alive           text, wanted_warm_schedule text, wanted_fallback_model text, wanted_fallback_after_seconds integer,
    wanted_allowed              boolean, wanted_alias text, wanted_lane_override text CHECK (wanted_lane_override IS NULL OR wanted_lane_override IN ('local', 'cloud')),
    wanted_set_by               bigint REFERENCES members(id) ON DELETE SET NULL,
    wanted_set_at               timestamptz,
    applied_at                  timestamptz,
    first_seen_at               timestamptz NOT NULL DEFAULT now(),
    updated_at                  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (node_id, name)
);
CREATE INDEX sl_models_node_idx ON sl_models (node_id, status, name);
CREATE TRIGGER sl_models_touch BEFORE UPDATE ON sl_models FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- Drift: a wanted value that the node does not report (D11).
CREATE OR REPLACE FUNCTION sl_model_drift(p_model_id bigint) RETURNS jsonb
    LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_strip_nulls(jsonb_build_object(
        'keep_alive',             CASE WHEN m.wanted_keep_alive IS NOT NULL AND m.wanted_keep_alive IS DISTINCT FROM m.keep_alive THEN jsonb_build_object('wanted', m.wanted_keep_alive, 'node', m.keep_alive) END,
        'warm_schedule',          CASE WHEN m.wanted_warm_schedule IS NOT NULL AND m.wanted_warm_schedule IS DISTINCT FROM m.warm_schedule THEN jsonb_build_object('wanted', m.wanted_warm_schedule, 'node', m.warm_schedule) END,
        'fallback_model',         CASE WHEN m.wanted_fallback_model IS NOT NULL AND m.wanted_fallback_model IS DISTINCT FROM m.fallback_model THEN jsonb_build_object('wanted', m.wanted_fallback_model, 'node', m.fallback_model) END,
        'fallback_after_seconds', CASE WHEN m.wanted_fallback_after_seconds IS NOT NULL AND m.wanted_fallback_after_seconds IS DISTINCT FROM m.fallback_after_seconds THEN jsonb_build_object('wanted', m.wanted_fallback_after_seconds, 'node', m.fallback_after_seconds) END,
        'allowed',                CASE WHEN m.wanted_allowed IS NOT NULL AND m.wanted_allowed IS DISTINCT FROM m.allowed THEN jsonb_build_object('wanted', m.wanted_allowed, 'node', m.allowed) END,
        'alias',                  CASE WHEN m.wanted_alias IS NOT NULL AND m.wanted_alias IS DISTINCT FROM m.alias THEN jsonb_build_object('wanted', m.wanted_alias, 'node', m.alias) END,
        'lane_override',          CASE WHEN m.wanted_lane_override IS NOT NULL AND m.wanted_lane_override IS DISTINCT FROM m.lane_override THEN jsonb_build_object('wanted', m.wanted_lane_override, 'node', m.lane_override) END
    )), '{}'::jsonb) FROM sl_models m WHERE m.id = p_model_id;
$$;

CREATE TABLE sl_model_prices (
    id                     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    model_name             text NOT NULL,                                   -- the served model's name; '*-cloud' patterns are not supported — one row per name
    price_input_per_mtok   numeric(12,6) NOT NULL DEFAULT 0 CHECK (price_input_per_mtok >= 0),
    price_output_per_mtok  numeric(12,6) NOT NULL DEFAULT 0 CHECK (price_output_per_mtok >= 0),
    currency               char(3) NOT NULL DEFAULT 'USD',
    note                   text,
    set_by                 bigint REFERENCES members(id) ON DELETE SET NULL,
    created_at             timestamptz NOT NULL DEFAULT now(),
    updated_at             timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX sl_model_prices_name_idx ON sl_model_prices (model_name);
CREATE TRIGGER sl_model_prices_touch BEFORE UPDATE ON sl_model_prices FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE OR REPLACE FUNCTION sl_notional_cost(p_model text, p_in integer, p_out integer) RETURNS numeric
    LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT round((COALESCE(p_in, 0) * p.price_input_per_mtok + COALESCE(p_out, 0) * p.price_output_per_mtok) / 1000000, 6)
                       FROM sl_model_prices p WHERE p.model_name = p_model), 0);
$$;

CREATE TABLE sl_caller_keys (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    node_id            bigint NOT NULL REFERENCES sl_nodes(id) ON DELETE CASCADE,
    node_key_id        uuid,                                                -- the node's id for it (NULL until minted)
    name               text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 80),
    prefix             text,                                                -- the first characters, to recognise it; never the key
    owner_member_id    bigint REFERENCES members(id) ON DELETE SET NULL,     -- D8: a person…
    application_key    text,                                                -- …or an application (its catalog key); 'kernel' for the proxy's
    max_priority       integer NOT NULL DEFAULT 5 CHECK (max_priority BETWEEN 1 AND 9),
    max_concurrent     integer NOT NULL DEFAULT 4 CHECK (max_concurrent >= 1),
    cloud_allowed      boolean NOT NULL DEFAULT false,
    fallback_allowed   boolean NOT NULL DEFAULT false,
    payload_retention  text NOT NULL DEFAULT 'metadata' CHECK (payload_retention IN ('none', 'metadata', 'full')),
    allowed_models     text[],
    daily_token_cap    integer CHECK (daily_token_cap IS NULL OR daily_token_cap > 0),
    status             text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'paused', 'revoked')),
    minted_by          bigint REFERENCES members(id) ON DELETE SET NULL,
    minted_at          timestamptz NOT NULL DEFAULT now(),
    last_used_at       timestamptz,
    revoked_at         timestamptz,
    revoked_by         bigint REFERENCES members(id) ON DELETE SET NULL,
    updated_at         timestamptz NOT NULL DEFAULT now(),
    CHECK (owner_member_id IS NOT NULL OR application_key IS NOT NULL)      -- D8: every key has an owner
);
CREATE UNIQUE INDEX sl_caller_keys_node_name_idx ON sl_caller_keys (node_id, lower(name)) WHERE status <> 'revoked';
CREATE UNIQUE INDEX sl_caller_keys_node_key_idx ON sl_caller_keys (node_id, node_key_id) WHERE node_key_id IS NOT NULL;
CREATE INDEX sl_caller_keys_owner_idx ON sl_caller_keys (owner_member_id);
CREATE TRIGGER sl_caller_keys_touch BEFORE UPDATE ON sl_caller_keys FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
ALTER TABLE sl_runs ADD CONSTRAINT sl_runs_key_fk FOREIGN KEY (caller_key_id) REFERENCES sl_caller_keys(id) ON DELETE SET NULL;

-- The mirror: one node run row in, upserted by (node, node_run_id); the caller key joined by name on the node; the notional cost priced.
CREATE OR REPLACE FUNCTION sl_run_mirror(p_node bigint, r jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid; v_key bigint;
BEGIN
    SELECT k.id INTO v_key FROM sl_caller_keys k WHERE k.node_id = p_node AND lower(k.name) = lower(r->>'key_name') AND k.status <> 'revoked' ORDER BY k.minted_at DESC LIMIT 1;
    INSERT INTO sl_runs AS s (node_id, node_run_id, node_seq, face, mode, kind, key_name, caller_key_id, tags, idempotency_key, client_ip, user_agent,
        requested_model, served_model, lane_requested, lane_served, fallback_reason, fallback_model, priority, stream, status, accepted_at, started_at,
        first_token_at, finished_at, queue_wait_ms, time_to_first_token_ms, run_ms, total_ms, load_ms, prompt_tokens, prompt_eval_ms, output_tokens,
        eval_ms, total_backend_ms, prompt_tokens_per_second, output_tokens_per_second, model_was_loaded, request_bytes, response_bytes, messages_count,
        images_count, tools_count, context_length, context_used, stop_reason, error_code, error_text, http_status, memory_free_at_start_bytes,
        loaded_models_at_start, cpu_load_1m, notional_cost)
    VALUES (p_node, (r->>'id')::uuid, (r->>'seq')::bigint, r->>'face', r->>'mode', r->>'kind', r->>'key_name', v_key,
        COALESCE(ARRAY(SELECT jsonb_array_elements_text(CASE WHEN jsonb_typeof(r->'tags') = 'array' THEN r->'tags' ELSE '[]'::jsonb END)), '{}'),
        r->>'idempotency_key', NULLIF(r->>'client_ip', '')::inet, r->>'user_agent', r->>'requested_model', r->>'served_model', r->>'lane_requested',
        r->>'lane_served', r->>'fallback_reason', r->>'fallback_model', (r->>'priority')::int, COALESCE((r->>'stream')::boolean, false), r->>'status',
        (r->>'accepted_at')::timestamptz, (r->>'started_at')::timestamptz, (r->>'first_token_at')::timestamptz, (r->>'finished_at')::timestamptz,
        (r->>'queue_wait_ms')::int, (r->>'time_to_first_token_ms')::int, (r->>'run_ms')::int, (r->>'total_ms')::int, (r->>'load_ms')::int,
        (r->>'prompt_tokens')::int, (r->>'prompt_eval_ms')::int, (r->>'output_tokens')::int, (r->>'eval_ms')::int, (r->>'total_backend_ms')::int,
        (r->>'prompt_tokens_per_second')::numeric, (r->>'output_tokens_per_second')::numeric, (r->>'model_was_loaded')::boolean,
        (r->>'request_bytes')::int, (r->>'response_bytes')::int, (r->>'messages_count')::int, (r->>'images_count')::int, (r->>'tools_count')::int,
        (r->>'context_length')::int, (r->>'context_used')::int, r->>'stop_reason', r->>'error_code', r->>'error_text', (r->>'http_status')::int,
        (r->>'memory_free_at_start_bytes')::bigint,
        CASE WHEN jsonb_typeof(r->'loaded_models_at_start') = 'array' THEN ARRAY(SELECT jsonb_array_elements_text(r->'loaded_models_at_start')) END,
        (r->>'cpu_load_1m')::numeric, sl_notional_cost(r->>'served_model', (r->>'prompt_tokens')::int, (r->>'output_tokens')::int))
    ON CONFLICT (node_id, node_run_id) DO UPDATE SET
        node_seq = EXCLUDED.node_seq, status = EXCLUDED.status, served_model = EXCLUDED.served_model, lane_served = EXCLUDED.lane_served,
        fallback_reason = EXCLUDED.fallback_reason, priority = EXCLUDED.priority, started_at = EXCLUDED.started_at, first_token_at = EXCLUDED.first_token_at,
        finished_at = EXCLUDED.finished_at, queue_wait_ms = EXCLUDED.queue_wait_ms, time_to_first_token_ms = EXCLUDED.time_to_first_token_ms,
        run_ms = EXCLUDED.run_ms, total_ms = EXCLUDED.total_ms, load_ms = EXCLUDED.load_ms, prompt_tokens = EXCLUDED.prompt_tokens,
        prompt_eval_ms = EXCLUDED.prompt_eval_ms, output_tokens = EXCLUDED.output_tokens, eval_ms = EXCLUDED.eval_ms, total_backend_ms = EXCLUDED.total_backend_ms,
        prompt_tokens_per_second = EXCLUDED.prompt_tokens_per_second, output_tokens_per_second = EXCLUDED.output_tokens_per_second,
        model_was_loaded = EXCLUDED.model_was_loaded, response_bytes = EXCLUDED.response_bytes, context_used = EXCLUDED.context_used,
        stop_reason = EXCLUDED.stop_reason, error_code = EXCLUDED.error_code, error_text = EXCLUDED.error_text, http_status = EXCLUDED.http_status,
        memory_free_at_start_bytes = EXCLUDED.memory_free_at_start_bytes, loaded_models_at_start = EXCLUDED.loaded_models_at_start,
        cpu_load_1m = EXCLUDED.cpu_load_1m, notional_cost = EXCLUDED.notional_cost, caller_key_id = COALESCE(s.caller_key_id, EXCLUDED.caller_key_id),
        mirrored_at = now()
    RETURNING id INTO v_id;
    RETURN v_id;
END$$;

-- The catalogue mirror: one node model row in (the node's /models shape); the wanted_* columns are never touched here.
CREATE OR REPLACE FUNCTION sl_model_mirror(p_node bigint, m jsonb) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id bigint;
BEGIN
    INSERT INTO sl_models AS s (node_id, name, node_seq, lane, lane_override, family, parameter_size, quantization, context_length, capabilities, size_bytes, digest,
        on_disk, loaded, loaded_size_bytes, expires_at, status, keep_alive, warm_schedule, fallback_model, fallback_after_seconds, allowed, alias, pull_error)
    VALUES (p_node, m->>'name', COALESCE((m->>'seq')::bigint, 0), COALESCE(m->>'lane', 'local'), m->>'lane_override', m->>'family', m->>'parameter_size',
        m->>'quantization', (m->>'context_length')::int,
        COALESCE(ARRAY(SELECT jsonb_array_elements_text(CASE WHEN jsonb_typeof(m->'capabilities') = 'array' THEN m->'capabilities' ELSE '[]'::jsonb END)), '{}'),
        (m->>'size_bytes')::bigint, m->>'digest', COALESCE((m->>'on_disk')::boolean, false), COALESCE((m->>'loaded')::boolean, false),
        (m->>'loaded_size_bytes')::bigint, (m->>'expires_at')::timestamptz, COALESCE(m->>'status', 'available'), m->>'keep_alive', m->>'warm_schedule',
        m->>'fallback_model', (m->>'fallback_after_seconds')::int, COALESCE((m->>'allowed')::boolean, true), m->>'alias', m->>'pull_error')
    ON CONFLICT (node_id, name) DO UPDATE SET
        node_seq = EXCLUDED.node_seq, lane = EXCLUDED.lane, lane_override = EXCLUDED.lane_override, family = EXCLUDED.family, parameter_size = EXCLUDED.parameter_size,
        quantization = EXCLUDED.quantization, context_length = EXCLUDED.context_length, capabilities = EXCLUDED.capabilities, size_bytes = EXCLUDED.size_bytes,
        digest = EXCLUDED.digest, on_disk = EXCLUDED.on_disk, loaded = EXCLUDED.loaded, loaded_size_bytes = EXCLUDED.loaded_size_bytes, expires_at = EXCLUDED.expires_at,
        status = EXCLUDED.status, keep_alive = EXCLUDED.keep_alive, warm_schedule = EXCLUDED.warm_schedule, fallback_model = EXCLUDED.fallback_model,
        fallback_after_seconds = EXCLUDED.fallback_after_seconds, allowed = EXCLUDED.allowed, alias = EXCLUDED.alias, pull_error = EXCLUDED.pull_error
    RETURNING id INTO v_id;
    RETURN v_id;
END$$;

GRANT SELECT, INSERT, UPDATE, DELETE ON sl_runs, sl_run_events, sl_run_payloads, sl_models, sl_model_prices, sl_caller_keys TO sovereign_llm_manager_rw;
GRANT EXECUTE ON FUNCTION sl_model_drift(bigint), sl_notional_cost(text, integer, integer) TO sovereign_llm_manager_rw, sovereign_llm_manager_records_ro;
GRANT EXECUTE ON FUNCTION sl_run_mirror(bigint, jsonb), sl_model_mirror(bigint, jsonb) TO sovereign_llm_manager_rw;

COMMIT;
