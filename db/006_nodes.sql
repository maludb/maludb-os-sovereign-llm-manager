-- 006: NODES — the fleet, the worker's pull lifecycle per node, and the queue snapshot (docs/sovereign-llm-manager-design.md §6.1;
-- D11 drift, D12 register).
--
-- THE ESTATE'S DATA MODEL (design §0.3, shared-schema.md):
--   sl_nodes        Inventory `sources` family, for a MACHINE: base_url, the credential sealed (Inventory's source_credentials shape
--                   folded in: ciphertext + last4), the pull lifecycle columns (last_pull_id, last_ok_at, consecutive_failures,
--                   backoff_until, paused_at/reason, active) verbatim; appended: node_uuid, status, backend, machine, location_id,
--                   last_seq, policy_version, clock_skew_ms, lanes
--   sl_node_pulls   Inventory `source_pulls` verbatim (source_id → node_id; the counters renamed to what a node sync counts)
--   sl_queue_snapshot  NEW — the last /queue answer per node, rewritten by the worker every 15 s; the queue screen's 5-s partial reads it
--
-- A node key is sealed with libsodium secretbox under SL_SECRETS_KEY (config/.env) in app/nodes/credentials.php alone; it is never
-- read back by any screen or tool (design §3). The records role sees no credential column (db/010's views).
BEGIN;

CREATE TABLE sl_nodes (
    id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name                  text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 80),
    base_url              text NOT NULL CHECK (base_url ~ '^https?://[^/\s]+(:[0-9]+)?$'),           -- scheme://host[:port], no path
    node_uuid             uuid,                                                                      -- the node's own id, from its first /status
    node_key_ciphertext   bytea,                                                                     -- sealed; NULL until registered
    node_key_last4        text CHECK (node_key_last4 IS NULL OR length(node_key_last4) BETWEEN 1 AND 4),
    status                text NOT NULL DEFAULT 'new' CHECK (status IN ('new', 'online', 'degraded', 'offline', 'retired')),
    backend_kind          text,
    backend_version       text,
    node_version          text,
    machine               jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(machine) = 'object'),    -- the /status machine block
    lanes                 jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(lanes) = 'array'),      -- the last /status lanes block
    loaded_models         text[] NOT NULL DEFAULT '{}',
    location_id           bigint,                                                                    -- the kernel's estate location (optional)
    payload_mirror        text NOT NULL DEFAULT 'none' CHECK (payload_mirror IN ('none', 'full')),    -- D3
    last_seen_at          timestamptz,
    last_seq              bigint NOT NULL DEFAULT 0,                                                  -- the sync cursor: the node's seq last mirrored
    policy_version        integer,                                                                   -- what the node reported last
    wanted_settings       jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(wanted_settings) = 'object'),   -- the manager's intent (D11)
    clock_skew_ms         integer,
    schedule_seconds      integer NOT NULL DEFAULT 60 CHECK (schedule_seconds BETWEEN 15 AND 3600),  -- the status/runs/models pull cadence
    last_pull_id          bigint,                                                                    -- FK below
    last_ok_at            timestamptz,
    consecutive_failures  integer NOT NULL DEFAULT 0 CHECK (consecutive_failures >= 0),
    backoff_until         timestamptz,
    paused_at             timestamptz,
    paused_reason         text,
    active                boolean NOT NULL DEFAULT true,
    created_by            bigint REFERENCES members(id) ON DELETE SET NULL,
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX sl_nodes_name_idx ON sl_nodes (lower(name));
CREATE UNIQUE INDEX sl_nodes_uuid_idx ON sl_nodes (node_uuid) WHERE node_uuid IS NOT NULL;
CREATE INDEX sl_nodes_status_idx ON sl_nodes (status, active);
CREATE TRIGGER sl_nodes_touch BEFORE UPDATE ON sl_nodes FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

CREATE TABLE sl_node_pulls (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    node_id        bigint NOT NULL REFERENCES sl_nodes(id) ON DELETE CASCADE,
    kind           text NOT NULL DEFAULT 'scheduled' CHECK (kind IN ('scheduled', 'manual', 'probe', 'health')),
    started_at     timestamptz NOT NULL DEFAULT now(),
    finished_at    timestamptz,
    status         text NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'ok', 'partial', 'failed')),
    runs_seen      integer NOT NULL DEFAULT 0,
    runs_new       integer NOT NULL DEFAULT 0,
    runs_changed   integer NOT NULL DEFAULT 0,
    models_changed integer NOT NULL DEFAULT 0,
    policies_pushed integer NOT NULL DEFAULT 0,
    http_requests  integer NOT NULL DEFAULT 0,
    bytes          bigint NOT NULL DEFAULT 0,
    error          text CHECK (error IS NULL OR length(error) <= 200),
    seq_from       bigint,
    seq_to         bigint,
    started_by     bigint REFERENCES members(id) ON DELETE SET NULL
);
CREATE INDEX sl_node_pulls_node_idx ON sl_node_pulls (node_id, started_at DESC);
CREATE INDEX sl_node_pulls_status_idx ON sl_node_pulls (status, started_at DESC);
ALTER TABLE sl_nodes ADD CONSTRAINT sl_nodes_last_pull_fk FOREIGN KEY (last_pull_id) REFERENCES sl_node_pulls(id) ON DELETE SET NULL;

-- The pull lifecycle (Inventory's, D10's streak): the worker opens a pull, closes it ok or failed; three failures in a row → offline
-- and a backoff that doubles to an hour; an ok pass → online, the streak reset, the notice resolved by the worker.
CREATE OR REPLACE FUNCTION sl_node_pull_open(p_node bigint, p_kind text, p_by bigint DEFAULT NULL) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id bigint;
BEGIN
    INSERT INTO sl_node_pulls (node_id, kind, started_by, seq_from)
    SELECT p_node, p_kind, p_by, n.last_seq FROM sl_nodes n WHERE n.id = p_node RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'no such node %', p_node USING ERRCODE = 'no_data_found'; END IF;
    RETURN v_id;
END$$;

CREATE OR REPLACE FUNCTION sl_node_pull_close(p_pull bigint, p_status text, p_error text DEFAULT NULL, p_counts jsonb DEFAULT '{}'::jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_node bigint; v_fail integer;
BEGIN
    UPDATE sl_node_pulls SET finished_at = now(), status = p_status, error = left(p_error, 200),
           runs_seen = COALESCE((p_counts->>'runs_seen')::int, runs_seen), runs_new = COALESCE((p_counts->>'runs_new')::int, runs_new),
           runs_changed = COALESCE((p_counts->>'runs_changed')::int, runs_changed), models_changed = COALESCE((p_counts->>'models_changed')::int, models_changed),
           policies_pushed = COALESCE((p_counts->>'policies_pushed')::int, policies_pushed), http_requests = COALESCE((p_counts->>'http_requests')::int, http_requests),
           bytes = COALESCE((p_counts->>'bytes')::bigint, bytes), seq_to = COALESCE((p_counts->>'seq_to')::bigint, seq_to)
     WHERE id = p_pull RETURNING node_id INTO v_node;
    IF v_node IS NULL THEN RAISE EXCEPTION 'no such pull %', p_pull USING ERRCODE = 'no_data_found'; END IF;
    IF p_status IN ('ok', 'partial') THEN
        UPDATE sl_nodes SET last_pull_id = p_pull, last_ok_at = now(), last_seen_at = now(), consecutive_failures = 0, backoff_until = NULL,
               status = CASE WHEN status = 'retired' THEN 'retired' WHEN p_status = 'partial' THEN 'degraded' ELSE 'online' END,
               last_seq = GREATEST(last_seq, COALESCE((p_counts->>'seq_to')::bigint, last_seq))
         WHERE id = v_node;
    ELSE
        UPDATE sl_nodes SET last_pull_id = p_pull, consecutive_failures = consecutive_failures + 1 WHERE id = v_node RETURNING consecutive_failures INTO v_fail;
        UPDATE sl_nodes SET status = CASE WHEN status = 'retired' THEN 'retired' WHEN v_fail >= 3 THEN 'offline' ELSE 'degraded' END,
               backoff_until = now() + make_interval(secs => LEAST(3600, 30 * power(2, LEAST(v_fail, 8))))
         WHERE id = v_node;
    END IF;
END$$;

-- Which nodes the worker visits now: active, not retired, not paused, past their backoff, due by cadence (or never pulled).
CREATE OR REPLACE FUNCTION sl_nodes_due(p_at timestamptz DEFAULT now()) RETURNS SETOF bigint
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT n.id FROM sl_nodes n
     WHERE n.active AND n.status <> 'retired' AND n.paused_at IS NULL AND n.node_key_ciphertext IS NOT NULL
       AND (n.backoff_until IS NULL OR n.backoff_until <= p_at)
       AND (n.last_pull_id IS NULL OR NOT EXISTS (SELECT 1 FROM sl_node_pulls p WHERE p.id = n.last_pull_id AND p.kind <> 'health' AND p.started_at > p_at - make_interval(secs => n.schedule_seconds)))
     ORDER BY n.last_ok_at NULLS FIRST, n.id;
$$;

-- The queue snapshot: one row per queued/running job on a node, rewritten whole by the worker.
CREATE TABLE sl_queue_snapshot (
    node_id           bigint NOT NULL REFERENCES sl_nodes(id) ON DELETE CASCADE,
    node_job_id       uuid NOT NULL,
    lane              text NOT NULL,
    status            text NOT NULL CHECK (status IN ('queued', 'running')),
    kind              text NOT NULL DEFAULT 'chat',
    requested_model   text,
    served_model      text,
    key_name          text,
    priority          integer,
    mode              text,
    face              text,
    position          integer,
    expected_wait_ms  integer,
    queued_at         timestamptz,
    started_at        timestamptz,
    tokens_so_far     integer,
    fallback_model    text,
    tags              text[] NOT NULL DEFAULT '{}',
    taken_at          timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (node_id, node_job_id)
);
CREATE INDEX sl_queue_snapshot_node_idx ON sl_queue_snapshot (node_id, lane, status, position);

CREATE OR REPLACE FUNCTION sl_queue_snapshot_replace(p_node bigint, p_rows jsonb) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n integer;
BEGIN
    DELETE FROM sl_queue_snapshot WHERE node_id = p_node;
    INSERT INTO sl_queue_snapshot (node_id, node_job_id, lane, status, kind, requested_model, served_model, key_name, priority, mode, face, position,
                                   expected_wait_ms, queued_at, started_at, tokens_so_far, fallback_model, tags)
    SELECT p_node, (r->>'job_id')::uuid, r->>'lane', r->>'status', COALESCE(r->>'kind', 'chat'), r->>'requested_model', r->>'served_model', r->>'key_name',
           (r->>'priority')::int, r->>'mode', r->>'face', (r->>'position')::int, (r->>'expected_wait_ms')::int,
           (r->>'queued_at')::timestamptz, (r->>'started_at')::timestamptz, (r->>'tokens_so_far')::int, r->>'fallback_model',
           COALESCE(ARRAY(SELECT jsonb_array_elements_text(CASE WHEN jsonb_typeof(r->'tags') = 'array' THEN r->'tags' ELSE '[]'::jsonb END)), '{}')
      FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_rows) = 'array' THEN p_rows ELSE '[]'::jsonb END) r;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END$$;

GRANT SELECT, INSERT, UPDATE, DELETE ON sl_nodes, sl_node_pulls, sl_queue_snapshot TO sovereign_llm_manager_rw;
GRANT EXECUTE ON FUNCTION sl_node_pull_open(bigint, text, bigint), sl_node_pull_close(bigint, text, text, jsonb), sl_nodes_due(timestamptz),
                          sl_queue_snapshot_replace(bigint, jsonb) TO sovereign_llm_manager_rw;

COMMIT;
