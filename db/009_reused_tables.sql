-- 009: THE REUSED TABLES — notifications, a person's preferences, the outbox the worker sends, agent dispatches, the worker's passes
-- (design §5, §6.1). THE ESTATE'S DATA MODEL (shared-schema.md §4): notifications / notification_prefs / notification_outbox = Spaces
-- db/012 (the GL's canonical, member-only); kinds are this application's; appended record_uuid and actor_member_id as Spaces does, and
-- node_id. agent_dispatches = GL db/014 canonical + record_uuid; appended node_id and next_attempt_at (Boards' loosening).
-- worker_passes = Spaces db/016 verbatim.
BEGIN;

CREATE TABLE notifications (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    member_id        bigint NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    kind             text NOT NULL CHECK (kind IN ('notice', 'notice_resolved', 'key_minted', 'key_revoked', 'fallback', 'agent_replied', 'digest', 'morning_note')),
    record_type      text,
    record_id        bigint,
    title            text NOT NULL,
    body             text,
    read_at          timestamptz,
    created_at       timestamptz NOT NULL DEFAULT now(),
    record_uuid      uuid,
    actor_member_id  bigint REFERENCES members(id) ON DELETE SET NULL,
    node_id          bigint REFERENCES sl_nodes(id) ON DELETE CASCADE
);
CREATE INDEX notifications_member_idx     ON notifications (member_id, created_at DESC) WHERE read_at IS NULL;
CREATE INDEX notifications_record_idx     ON notifications (record_type, record_id);
CREATE INDEX notifications_member_all_idx ON notifications (member_id, created_at DESC);

CREATE TABLE notification_prefs (
    member_id      bigint PRIMARY KEY REFERENCES members(id) ON DELETE CASCADE,
    email_enabled  boolean NOT NULL DEFAULT true,
    text_enabled   boolean NOT NULL DEFAULT false,                -- K6: the kernel keeps the opt-out; this is the person's choice here
    kinds          text[] NOT NULL DEFAULT '{notice,notice_resolved,key_minted,key_revoked,fallback,agent_replied,morning_note}',
    text_kinds     text[] NOT NULL DEFAULT '{notice}',
    updated_at     timestamptz NOT NULL DEFAULT now(),
    digest         boolean NOT NULL DEFAULT false
);

CREATE TABLE notification_outbox (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    channel        text NOT NULL CHECK (channel IN ('email', 'text')),
    member_id      bigint NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    to_email       citext,
    kind           text NOT NULL,
    record_type    text,
    record_id      bigint,
    dedupe_key     text,
    subject        text,
    body           text NOT NULL,
    body_html      text,
    status         text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'sent', 'skipped', 'failed')),
    attempts       integer NOT NULL DEFAULT 0,
    detail         text,
    provider_ref   text,
    send_after     timestamptz NOT NULL DEFAULT now(),
    sent_at        timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX notification_outbox_dedupe ON notification_outbox (dedupe_key) WHERE dedupe_key IS NOT NULL;
CREATE INDEX notification_outbox_queue_idx  ON notification_outbox (status, send_after) WHERE status = 'queued';
CREATE INDEX notification_outbox_member_idx ON notification_outbox (member_id, created_at DESC);

CREATE TABLE agent_dispatches (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    record_type         text,
    record_id           bigint,
    agent_member_id     bigint NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    kind                text NOT NULL CHECK (kind IN ('mention', 'ask', 'duty')),
    via                 text NOT NULL CHECK (via IN ('chat', 'wake', 'duty')),
    acting_member_id    bigint REFERENCES members(id) ON DELETE SET NULL,
    run_id              bigint,
    request_id          text,
    status              text NOT NULL DEFAULT 'sent' CHECK (status IN ('sent', 'answered', 'refused', 'failed', 'awaiting_approval')),
    reply_excerpt       text,
    detail              text,
    attempts            integer NOT NULL DEFAULT 1,
    created_at          timestamptz NOT NULL DEFAULT now(),
    answered_at         timestamptz,
    record_uuid         uuid,
    node_id             bigint REFERENCES sl_nodes(id) ON DELETE CASCADE,
    next_attempt_at     timestamptz NOT NULL DEFAULT now(),
    CHECK (reply_excerpt IS NULL OR length(reply_excerpt) <= 200)
);
CREATE INDEX agent_dispatches_due_idx ON agent_dispatches (next_attempt_at) WHERE status IN ('sent', 'awaiting_approval');

CREATE TABLE worker_passes (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    started_at    timestamptz NOT NULL DEFAULT now(),
    finished_at   timestamptz,
    steps         jsonb NOT NULL DEFAULT '{}'::jsonb,
    error         text
);

GRANT SELECT, INSERT, UPDATE, DELETE ON notifications, notification_prefs, notification_outbox, agent_dispatches, worker_passes TO sovereign_llm_manager_rw;

COMMIT;
