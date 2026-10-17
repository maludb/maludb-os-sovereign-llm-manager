-- 004: Sovereign LLM Manager's roles and the rights they give (kernel db/145; roles-and-rights.md; the design §2, §3, D2).
--
-- Published to the kernel by app_roles on the records MCP (os.app-roles/1). The kernel grants a SET of roles; the claims and
-- the feed carry them back into members.roles. What a role lets its holder do is the application's to enforce:
-- sl_has_right(right) answers from the catalogue and the mirror. The base role's KEY IS `user` on purpose (the Operator): the
-- installer's --grant-standing-departments gives a department the role keyed member/user/write.
--
-- Three roles: Viewer (read), Operator (user, write), LLM admin (is_admin). Rights are cumulative: each higher role holds every lower
-- one's -- fifteen in all (viewer 6, user 10, admin 15). Which node or run a caller reaches beyond a right is a wall a later
-- migration adds (a run's payload is `payloads.read` and nobody else's, agents included -- design §3).
--
-- THE ESTATE'S DATA MODEL: the shape is Consultant Tracking db/004 = DocCloud db/004 = Sales CRM db/004 = the Data Lake db/004
-- (dl_ -> sl_); the roles and rights are this application's; sl_member_roles(member) is Inventory db/004's convenience (the
-- roles a member holds, resolved); sl_member_has_right(member, right) the Data Lake's.
BEGIN;

CREATE TABLE sl_rights (
    right_key   text PRIMARY KEY CHECK (right_key ~ '^[a-z][a-z0-9_.]{0,59}$'),
    description text NOT NULL,
    sort_order  integer NOT NULL DEFAULT 0
);
CREATE TABLE sl_roles (
    role_key    text PRIMARY KEY CHECK (role_key ~ '^[a-z][a-z0-9_]{0,39}$'),
    name        text NOT NULL,
    description text NOT NULL,
    capability  text NOT NULL CHECK (capability IN ('read', 'write', 'admin')),
    is_admin    boolean NOT NULL DEFAULT false,
    sort_order  integer NOT NULL DEFAULT 0,
    CHECK (NOT is_admin OR capability = 'admin')
);
CREATE UNIQUE INDEX sl_roles_one_admin ON sl_roles (is_admin) WHERE is_admin;
CREATE TABLE sl_role_rights (
    role_key  text NOT NULL REFERENCES sl_roles(role_key) ON DELETE CASCADE,
    right_key text NOT NULL REFERENCES sl_rights(right_key) ON DELETE CASCADE,
    PRIMARY KEY (role_key, right_key)
);

INSERT INTO sl_rights (right_key, description, sort_order) VALUES
 -- every role (Viewer)
 ('fleet.read',      'See the nodes, their status, machine and policy version', 1),
 ('queue.read',      'See the live queue: what is running and waiting, on which node and lane', 2),
 ('runs.read',       'Read the run record: model, lane, timings, tokens, outcome (never the payload)', 3),
 ('models.read',     'See the models on each node, their intent and any drift', 4),
 ('usage.read',      'Read usage by period, node, key and model', 5),
 ('keys.read_own',   'See the caller keys they own: name, limits, status (never the key)', 6),
 -- Operator
 ('queue.act',       'Act on the queue: cancel or reprioritise a job, move it to another lane', 7),
 ('models.operate',  'Pull, warm, unload and keep a model on a node', 8),
 ('keys.mint_own',   'Mint and revoke their own caller keys and their own tokens for the two read MCP servers', 9),
 ('notes.write',     'Write notes on a node, a model or a run', 10),
 -- LLM admin
 ('nodes.admin',     'Add, retire and configure nodes; run the fleet', 11),
 ('keys.admin',      'See and revoke every caller key, mint one for another person or an application', 12),
 ('policies.admin',  'Set the model policies and fallbacks, and the notional prices', 13),
 ('settings.admin',  'Run the application: thresholds, sync intervals, the payload mirror default', 14),
 ('payloads.read',   'Read a run''s request and response where the manager keeps them (pauses for an agent)', 15);

INSERT INTO sl_roles (role_key, name, description, capability, is_admin, sort_order) VALUES
 ('viewer', 'Viewer',    'Sees the fleet, the queue, the runs, the models and the usage; never changes anything.', 'read', false, 1),
 ('user',   'Operator',  'Everything a Viewer does, and works the fleet: acts on the queue, pulls and warms models, mints their own keys, writes notes.', 'write', false, 2),
 ('admin',  'LLM admin', 'Every right: the nodes, every key, the policies and prices, the settings and the payloads. A super-admin holds this role.', 'admin', true, 3);

INSERT INTO sl_role_rights (role_key, right_key)
SELECT 'viewer', right_key FROM sl_rights WHERE sort_order <= 6
UNION ALL SELECT 'user', right_key FROM sl_rights WHERE sort_order <= 10
UNION ALL SELECT 'admin', right_key FROM sl_rights;

-- The roles a member holds, resolved: the kernel's list; a super-admin always holds admin; a member the kernel has not yet sent
-- roles for is read from the capability (admin = admin, write = user, read = viewer -- unlike the Data Lake, this application HAS a read-only
-- role, so a read grant never draws). Empty for nobody.
CREATE OR REPLACE FUNCTION sl_member_roles(p_member_id bigint) RETURNS text[]
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE r text[];
BEGIN
    SELECT CASE
             WHEN m.member_kind = 'human' AND m.business_role = 'super_admin' THEN (SELECT array_agg(DISTINCT x) FROM unnest(m.roles || ARRAY['admin']) x)
             WHEN cardinality(m.roles) > 0 THEN m.roles
             ELSE ARRAY[CASE m.capability WHEN 'admin' THEN 'admin' WHEN 'write' THEN 'user' ELSE 'viewer' END]
           END
      INTO r
      FROM members m
     WHERE m.id = p_member_id AND m.status = 'active' AND m.capability IS NOT NULL;
    RETURN COALESCE(r, '{}');
END$$;

-- A right a given member's roles give (the member must be active and admitted).
CREATE OR REPLACE FUNCTION sl_member_has_right(p_member_id bigint, p_right text) RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM sl_role_rights rr
         WHERE rr.right_key = p_right AND rr.role_key = ANY (sl_member_roles(p_member_id)));
END$$;

-- The rule: a right the acting member's roles give.
CREATE OR REPLACE FUNCTION sl_has_right(p_right text) RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
    RETURN sl_member_has_right(app_current_member_id(), p_right);
END$$;

-- Runs the application: the super-admin, or a human holding nodes.admin.
CREATE OR REPLACE FUNCTION sl_is_admin() RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
    RETURN app_is_super_admin() OR (app_member_kind() = 'human' AND sl_has_right('nodes.admin'));
END$$;

-- Someone who belongs in the business here: admitted (any role; an agent granted a role too).
CREATE OR REPLACE FUNCTION sl_is_member_here() RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
    RETURN app_is_active_member();
END$$;

-- What app_roles answers, in one read.
CREATE OR REPLACE VIEW mcp_app_roles AS
SELECT r.role_key, r.name, r.description, r.capability, r.is_admin, r.sort_order,
       COALESCE((SELECT array_agg(rr.right_key ORDER BY h.sort_order) FROM sl_role_rights rr
                   JOIN sl_rights h ON h.right_key = rr.right_key WHERE rr.role_key = r.role_key), '{}') AS rights
FROM sl_roles r;

GRANT SELECT ON sl_rights, sl_roles, sl_role_rights, mcp_app_roles TO sovereign_llm_manager_rw, sovereign_llm_manager_records_ro;
GRANT EXECUTE ON FUNCTION sl_member_roles(bigint), sl_member_has_right(bigint, text), sl_has_right(text), sl_is_admin(), sl_is_member_here()
    TO sovereign_llm_manager_rw, sovereign_llm_manager_records_ro, sovereign_llm_manager_activity_ro;

COMMIT;
