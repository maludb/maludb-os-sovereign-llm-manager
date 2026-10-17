-- 002: activity memory -- the one funnel (memory.md §2). Exists before the first feature ships; it cannot be
-- backfilled. Every row is shipped to the tenant's one MaluDB as an `activity` episode by mcp/activity_ingest.py
-- (payload key "application": "sovereign_llm_manager" first). What a person or an agent DID is here.
-- THE ESTATE'S DATA MODEL: the contract table (memory.md / Consultant Tracking db/002) with token_id as Knowledge db/002 appended it.
-- `before`/`after` carry ids, names, counts, kinds and byte sizes -- A PROMPT, A RESPONSE, A KEY OR A NODE'S SECRET IS NEVER HERE
-- (a key is named by its label). `source` widens the contract's list with 'system' (the worker's own passes act on no one's click) --
-- an enumeration widened, the shared-schema rule's allowed change.
BEGIN;

CREATE TABLE activity_log (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    occurred_at     timestamptz NOT NULL DEFAULT now(),
    actor_member_id bigint REFERENCES members(id) ON DELETE SET NULL,
    source          text NOT NULL DEFAULT 'web'
                    CHECK (source IN ('web', 'assistant', 'mcp', 'cron', 'agent', 'desk', 'webhook', 'portal', 'api', 'application', 'system')),
    action          text NOT NULL,                 -- entity.verb
    screen          text,
    route           text,                          -- "METHOD /path"
    entity_type     text,
    entity_id       bigint,
    before          jsonb,
    after           jsonb,                         -- changed fields only
    request_id      text,
    session_id      text,
    ip_address      inet,
    agent_run_id    bigint,                        -- the kernel's run id when an agent acted (no FK)
    department_id   bigint,                        -- the department the event concerns (a permission given to it)
    location_id     bigint,                        -- the contract's (unused: scope none)
    kernel_request_id text,                        -- the kernel's request id for a call that crossed to it
    created_at      timestamptz NOT NULL DEFAULT now(),
    token_id        bigint                         -- appended (Knowledge db/002): the token (mcp_access_tokens.id) an event ran under; its LABEL is in `after`, never the token
);
CREATE INDEX activity_log_actor_idx    ON activity_log (actor_member_id, occurred_at DESC);
CREATE INDEX activity_log_entity_idx   ON activity_log (entity_type, entity_id, occurred_at DESC);
CREATE INDEX activity_log_action_idx   ON activity_log (action, occurred_at DESC);
CREATE INDEX activity_log_time_idx     ON activity_log (occurred_at DESC);
CREATE INDEX activity_log_request_idx  ON activity_log (request_id);
CREATE INDEX activity_log_token_idx    ON activity_log (token_id, occurred_at DESC) WHERE token_id IS NOT NULL;

GRANT INSERT, SELECT ON activity_log TO sovereign_llm_manager_rw;
REVOKE ALL ON activity_log FROM sovereign_llm_manager_records_ro, sovereign_llm_manager_activity_ro;

-- The ingest checkpoint: only ever moves forward.
CREATE TABLE activity_ingest_state (
    id          smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    last_id     bigint NOT NULL DEFAULT 0,
    updated_at  timestamptz NOT NULL DEFAULT now()
);
INSERT INTO activity_ingest_state (id, last_id) VALUES (1, 0) ON CONFLICT DO NOTHING;
GRANT SELECT, UPDATE ON activity_ingest_state TO sovereign_llm_manager_rw;

COMMIT;
