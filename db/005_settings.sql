-- 005: the application's SETTINGS (one row) and the KEY rules that read them (design §6.1 sl_settings; D1).
--
-- THE ESTATE'S DATA MODEL: sl_settings is the siblings' one-row `app_settings` skeleton (id smallint = 1, updated_at) with the kit's
-- generic columns (business name, time zone, the key rates). THIS application's columns (the queue and fallback thresholds, the sync
-- intervals, the payload mirror default) are appended by the migrations of the slices that read them. The key functions are Knowledge
-- db/011's = Sales CRM db/005's = the Data Lake db/005's (sl_resolve_key, sl_rate_ok, sl_key_calls_today, sl_key_rotate,
-- sl_prune_key_usage) -- here because they read the settings.
BEGIN;

CREATE TABLE sl_settings (
    id                          smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    business_name               text,
    timezone                    text NOT NULL DEFAULT 'UTC',
    -- keys (the kit's; db/003)
    key_rate_per_minute         integer NOT NULL DEFAULT 60 CHECK (key_rate_per_minute BETWEEN 1 AND 100000),
    key_rate_per_day            integer NOT NULL DEFAULT 5000 CHECK (key_rate_per_day BETWEEN 1 AND 10000000),
    key_rotation_overlap_hours  smallint NOT NULL DEFAULT 24 CHECK (key_rotation_overlap_hours BETWEEN 0 AND 168),
    updated_at                  timestamptz NOT NULL DEFAULT now()
);
INSERT INTO sl_settings (id) VALUES (1) ON CONFLICT DO NOTHING;
CREATE TRIGGER sl_settings_touch BEFORE UPDATE ON sl_settings FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- One setting by name, for the rules that read them (never for a column that is not a number / not text).
CREATE OR REPLACE FUNCTION sl_setting_int(p_name text) RETURNS bigint
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v bigint;
BEGIN
    EXECUTE format('SELECT %I::bigint FROM sl_settings WHERE id = 1', p_name) INTO v;
    RETURN v;
END$$;
CREATE OR REPLACE FUNCTION sl_setting_text(p_name text) RETURNS text
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v text;
BEGIN
    EXECUTE format('SELECT %I::text FROM sl_settings WHERE id = 1', p_name) INTO v;
    RETURN v;
END$$;
CREATE OR REPLACE FUNCTION sl_setting_bool(p_name text) RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v boolean;
BEGIN
    EXECUTE format('SELECT %I::boolean FROM sl_settings WHERE id = 1', p_name) INTO v;
    RETURN v;
END$$;

-- ---------------------------------------------------------------------------------------------
-- KEYS (db/003): a key's defaults, its resolution, the rate rule, rotation and pruning — Knowledge db/011 minus the base
-- (Sales CRM's and the Data Lake's copies, without the Data Lake's per-key SQL switch).
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sl_access_tokens_before() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF NEW.scope = 'api' THEN
        NEW.rate_per_minute := COALESCE(NEW.rate_per_minute, sl_setting_int('key_rate_per_minute')::integer);
        NEW.rate_per_day := COALESCE(NEW.rate_per_day, sl_setting_int('key_rate_per_day')::integer);
        IF NEW.rotated_from IS NOT NULL AND NOT EXISTS (SELECT 1 FROM mcp_access_tokens o WHERE o.id = NEW.rotated_from AND o.member_id = NEW.member_id AND o.scope = 'api') THEN
            RAISE EXCEPTION 'A key is rotated from a key of the same person' USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END$$;
CREATE TRIGGER mcp_access_tokens_before BEFORE INSERT OR UPDATE ON mcp_access_tokens FOR EACH ROW EXECUTE FUNCTION sl_access_tokens_before();

-- Resolve a key by its hash: the token, its person, its label and its limits, with last_used_at touched. Nothing for a
-- revoked, expired or mcp-scope token, or one whose person is no longer admitted (a revoked grant shuts this door too).
CREATE OR REPLACE FUNCTION sl_resolve_key(p_hash text)
    RETURNS TABLE (token_id bigint, member_id bigint, label text, rate_per_minute integer, rate_per_day integer)
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    UPDATE mcp_access_tokens t SET last_used_at = now()
      FROM members m
     WHERE t.token_hash = p_hash AND t.scope = 'api' AND t.revoked_at IS NULL AND (t.expires_at IS NULL OR t.expires_at > now())
       AND m.id = t.member_id AND m.status = 'active' AND m.capability IS NOT NULL;
    RETURN QUERY
        SELECT t.id, t.member_id, t.label, t.rate_per_minute, t.rate_per_day
          FROM mcp_access_tokens t JOIN members m ON m.id = t.member_id
         WHERE t.token_hash = p_hash AND t.scope = 'api' AND t.revoked_at IS NULL AND (t.expires_at IS NULL OR t.expires_at > now())
           AND m.status = 'active' AND m.capability IS NOT NULL;
END$$;

-- Count one call. ok = the call may proceed; when not, limit_hit says which bucket and retry_after how many seconds until it
-- opens. The minute bucket is charged first; a call the minute refuses is not charged to the day (so a burst never eats the
-- day); a call the day refuses stays counted in the minute (it was made). `refused` is kept per bucket for the keys screen.
CREATE OR REPLACE FUNCTION sl_rate_ok(p_token_id bigint, p_at timestamptz DEFAULT now())
    RETURNS TABLE (ok boolean, limit_hit text, retry_after integer, minute_calls integer, day_calls integer)
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE t mcp_access_tokens%ROWTYPE; m_start timestamptz; d_start timestamptz; m_calls integer; d_calls integer;
BEGIN
    SELECT * INTO t FROM mcp_access_tokens WHERE id = p_token_id AND scope = 'api' FOR UPDATE;   -- serialises the two upserts per key
    IF NOT FOUND THEN
        RETURN QUERY SELECT false, 'no_key'::text, 0, 0, 0; RETURN;
    END IF;
    IF t.revoked_at IS NOT NULL OR (t.expires_at IS NOT NULL AND t.expires_at <= p_at) THEN
        RETURN QUERY SELECT false, 'revoked'::text, 0, 0, 0; RETURN;
    END IF;
    m_start := date_trunc('minute', p_at);
    d_start := date_trunc('day', p_at);
    INSERT INTO key_usage (token_id, bucket_kind, bucket_start, calls) VALUES (p_token_id, 'minute', m_start, 1)
    ON CONFLICT (token_id, bucket_kind, bucket_start) DO UPDATE SET calls = key_usage.calls + 1
    RETURNING calls INTO m_calls;
    IF m_calls > t.rate_per_minute THEN
        UPDATE key_usage SET calls = calls - 1, refused = refused + 1 WHERE token_id = p_token_id AND bucket_kind = 'minute' AND bucket_start = m_start;
        SELECT COALESCE(calls, 0) INTO d_calls FROM key_usage WHERE token_id = p_token_id AND bucket_kind = 'day' AND bucket_start = d_start;
        RETURN QUERY SELECT false, 'minute'::text, GREATEST(1, ceil(extract(epoch FROM (m_start + interval '1 minute' - p_at)))::integer), m_calls - 1, COALESCE(d_calls, 0);
        RETURN;
    END IF;
    INSERT INTO key_usage (token_id, bucket_kind, bucket_start, calls) VALUES (p_token_id, 'day', d_start, 1)
    ON CONFLICT (token_id, bucket_kind, bucket_start) DO UPDATE SET calls = key_usage.calls + 1
    RETURNING calls INTO d_calls;
    IF d_calls > t.rate_per_day THEN
        UPDATE key_usage SET calls = calls - 1, refused = refused + 1 WHERE token_id = p_token_id AND bucket_kind = 'day' AND bucket_start = d_start;
        RETURN QUERY SELECT false, 'day'::text, GREATEST(1, ceil(extract(epoch FROM (d_start + interval '1 day' - p_at)))::integer), m_calls, d_calls - 1;
        RETURN;
    END IF;
    RETURN QUERY SELECT true, NULL::text, 0, m_calls, d_calls;
END$$;

-- Today's count for a key (the keys screen, find_keys).
CREATE OR REPLACE FUNCTION sl_key_calls_today(p_token_id bigint) RETURNS integer
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT COALESCE((SELECT calls FROM key_usage WHERE token_id = p_token_id AND bucket_kind = 'day' AND bucket_start = date_trunc('day', now())), 0);
$$;

-- Rotate: a new key for the same person, label and limits; the old one expires after the overlap (24 h) and points nowhere —
-- the new one says `rotated_from`. Returns the new row's id; the raw key is the caller's (PHP mints the 48 hex, hashes them, and
-- passes the hash in).
CREATE OR REPLACE FUNCTION sl_key_rotate(p_old_token_id bigint, p_new_hash text) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE o mcp_access_tokens%ROWTYPE; nid bigint; overlap integer;
BEGIN
    SELECT * INTO o FROM mcp_access_tokens WHERE id = p_old_token_id AND scope = 'api' FOR UPDATE;
    IF NOT FOUND OR o.revoked_at IS NOT NULL THEN RAISE EXCEPTION 'Only a live key is rotated' USING ERRCODE = 'check_violation'; END IF;
    overlap := sl_setting_int('key_rotation_overlap_hours')::integer;
    INSERT INTO mcp_access_tokens (member_id, label, token_hash, scope, rate_per_minute, rate_per_day, rotated_from)
    VALUES (o.member_id, o.label, p_new_hash, 'api', o.rate_per_minute, o.rate_per_day, o.id)
    RETURNING id INTO nid;
    UPDATE mcp_access_tokens SET expires_at = LEAST(COALESCE(expires_at, 'infinity'::timestamptz), now() + make_interval(hours => overlap)) WHERE id = o.id;
    RETURN nid;
END$$;

-- The worker prunes buckets once a minute: minute buckets older than a day, day buckets older than 35 days.
CREATE OR REPLACE FUNCTION sl_prune_key_usage() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n integer;
BEGIN
    DELETE FROM key_usage WHERE (bucket_kind = 'minute' AND bucket_start < now() - interval '1 day') OR (bucket_kind = 'day' AND bucket_start < now() - interval '35 days');
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END$$;

GRANT SELECT, UPDATE ON sl_settings TO sovereign_llm_manager_rw;
GRANT EXECUTE ON FUNCTION sl_setting_int(text), sl_setting_text(text), sl_setting_bool(text), sl_key_calls_today(bigint) TO sovereign_llm_manager_rw, sovereign_llm_manager_records_ro, sovereign_llm_manager_activity_ro;
REVOKE ALL ON FUNCTION sl_resolve_key(text), sl_rate_ok(bigint, timestamptz), sl_key_rotate(bigint, text), sl_prune_key_usage() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION sl_resolve_key(text), sl_rate_ok(bigint, timestamptz), sl_key_rotate(bigint, text), sl_prune_key_usage() TO sovereign_llm_manager_rw;

COMMIT;
