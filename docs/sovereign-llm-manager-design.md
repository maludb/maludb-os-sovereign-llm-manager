# Sovereign LLM Manager — design (Phase 0 of the new-app workflow, fitted to the Business OS)

2026-10-16 · the business's **window on the machines that run its models**: every node running `maluos-local-llm-server`
(the owner's Mac Mini M4 first; a GPU box, a desk, a second office later) on one set of screens — the fleet's health, each
node's queue live, the run history with its performance numbers (queue wait, time to first token, tokens per second,
load time, fallbacks), token usage by period, caller, model and lane, the models on each node (pull, warm, unload, keep
warm, the cloud fallback a model may take), the keys callers hold, and the policies the node enforces — administered by
super-admins and operators, watched by an agent, and shared with the ledger. Its own repository
`/srv/apps/sovereign_llm_manager` (origin `github.com/maludb/maludb-os-sovereign-llm-manager`), served as `llm.<domain>`,
fitted to `maludb-os-integration` 0.9.0 and `htmx-php-builder` 0.9.0 exactly as Boards, the Data Lake and MaluMail were.
The nearest built exemplars: `/srv/apps/datalake` (the newest kit; services of the application's own; a fleet-like
catalog filled by the machine), `/srv/apps/inventory` (slice 3: **sources** pulled on a schedule by the worker with a
pull lifecycle, probes and a streak-keyed notice — the node sync is that pattern), `/srv/apps/shareholder_intelligence`
(fetch layer and credentials sealed per source).

> **What this document is.** The plan, in the kernel's words, and the brief a worker model builds from. The node
> service's design and **the node API this application consumes** are `~/maluos-local-llm-server/docs/server-design.md`
> (its §6); this document reads them by reference and never restates the API. The decisions still open are §13
> (D1–D16); the owner's answers go in §15. Phase 0's first half is this document and the owner's answers; the schema in
> `db/`, `maludb-os.json`, `os/`, `skills/` and `deploy/` complete it. Phase 1 adds the tool surface, the action manifest,
> the build specs and the slice specs. **No feature PHP is written until the owner approves them together.**

## 0. What is decided, and what the kernel and the estate say

### 0.1 Decided on 2026-10-16 — the owner's answers (the server design §0.1, R1–R7)

Two parts; many nodes; the node keeps its own history in SQLite and **the manager pulls**; callers are anything on the
network with a key and token usage is reported; sync and async with streaming; the cloud lane unlimited and the fallback;
the node pulls, warms and unloads. This application is the **manager** of that pair: it never serves an inference and
never speaks to Ollama — only to nodes, through their node API, with a node key sealed per node.

### 0.2 What the kernel gives

- **The ledger proxy already reaches a node.** A `model_registry` row of provider `local`, harness `openai_compatible` and
  `endpoint_url = http://<node>:11435/openai` with the node's inference key as its secret is all an agent needs to run on
  the Mac; the proxy prices it (0 for local, a notional price for Ollama cloud) and writes the prompt ledger. The manager
  does not duplicate that ledger; it **joins** it: a run the node served for the kernel's key carries the kernel's
  `X-OS-*`-less identity only by key name, so **K58** (§12) asks the proxy to keep the node's `X-Node-Job-Id` on the
  ledger row, and the manager's run page links to the kernel's.
- **Direct callers are the manager's alone.** A person's IDE, an application's engine on a direct key, a script — their
  usage exists nowhere but the node and here. The manager keeps `sl_usage_*` and publishes the K7 share `usage_by_period`
  so the General Ledger's AI statement (G6, owed) and the kernel's statement (K59, owed) can show "local models" beside the
  providers.
- The kernel's agents run this application's two agents; the chat endpoint answers the command bar; approvals pause the
  money-less but consequential actions (§5); the installer applies it from `maludb-os.json`.
- **K57** — the catalog row (`db/184`): key `sovereign_llm_manager`, area **Technology & Infrastructure**, category
  `platform` (already admitted; nothing widened), icon `feather-cpu`.

### 0.3 What the estate already has (the survey of the siblings' `db/*.sql`)

| This application needs | The estate already has | So it takes |
|---|---|---|
| nodes polled on a schedule, with a status, a last-pull outcome and a streak-keyed notice | **Inventory `sources`** + `source_pulls` (the pull lifecycle: due, running, ok, failed, the streak; sealed credentials; probes) | **`sl_nodes`** in the `sources` shape (`kind = llm_node`, `base_url`, the node key sealed with `app/secrets.php`'s successor in the kit, `last_seq`, `policy_version`) and **`sl_node_pulls`** verbatim from `source_pulls` |
| run rows mirrored from a machine | Data Lake `query_runs`, the kernel's `agent_runs` | **`sl_runs`** new canonical — *the LLM run record* (the server design §7's columns, `node_id` + `node_run_id` unique) |
| usage by period | the kernel's `ai_usage_postings` / `ai_periods` | **`sl_usage_daily`** (a rollup by day × node × key × model × lane; the K7 share reads it) — the kernel's shape kept in words, not copied (the kernel keeps money, this keeps tokens and a **notional price** per model the admin enters) |
| notices, worker passes, attachments, search | Spaces `notifications*`, `worker_passes`, `search_index` | reuse |
| keys minted on a machine, shown once | Knowledge `api_keys` (per base, shown once, hash kept) | **`sl_caller_keys`** in that shape, the hash the node's (the manager keeps the key's **name, limits and owner**; never the key) |

Prefix `sl_`; the name `nodes` is taken by nothing in the estate but is generic — the tables are `sl_nodes`, `sl_models`,
`sl_runs`, recorded in `shared-schema.md`.

## 1. What it is, and is not

**Is.** A **fleet** of nodes, each a machine with the node service; for each, **the queue** live, **the models** and their
policies, **the keys** callers hold, **the runs** with their numbers, and for the fleet, **usage** by period and
**notices** when a node is down, a queue backs up, a fallback fired, a model is missing. **Operators act**: cancel,
re-prioritise, move a job to the cloud, pause a lane, pull, warm, unload, keep warm, set a fallback, mint and revoke keys,
set the policies — every action a PHP handler the command bar and the agents share, carried to the node by the application
over the node API and recorded here as well as there.

**Is not.** Not an inference gateway (callers speak to the node; the manager's own chat is the kernel's), not a model
marketplace, not a prompt library, not evals (the kernel's Auditor and JEV grade runs; a node's run is a fact here), not
monitoring of anything but LLM nodes (the Sysadmin watches the estate), and not the ledger (tokens and notional prices,
never books).

## 2. Who uses it (the actors, in the OS's words)

| Actor | Kind | Role here | Reach |
|---|---|---|---|
| A super-admin | person | **LLM admin** (`is_admin`) | everything: nodes, keys, policies, settings, the ledger share |
| An operator (IT; whoever minds the machines) | person | **Operator** (`user`) | the queue's actions, models' operations (pull/warm/unload), their own keys; no node credentials, no policies |
| A viewer (a developer who wants to know why their call waited) | person | **Viewer** | read: fleet, queue, runs' metadata, usage; never a payload |
| The LLM Ops expert | agent, hired on install | the application's expert | answers questions through the records MCP; proposes (a pull, a fallback, a warm schedule); acts through the actions with the pause list |
| The Fleet Watcher | agent, hired on install | a duty at **06:35 UTC** daily | the morning note: nodes down, queue backlog, slowest models, fallbacks yesterday, tokens by key; no actions |
| The kernel | — | the ledger's reader through K7 | `usage_by_period`, `nodes_status`, `models_available` |

Roles are published through `app_roles` (C5) and granted by the kernel; scope kind **`none`** (a node is not a site; the
machine's `location_id` is recorded for the estate's map, not for scoping).

## 3. Who sees what — the rules, in one place

- **Every signed-in holder sees every node, queue and run's metadata.** The fleet is one business's; there is nothing to
  hide between operators.
- **A payload** (a run's request and response, when the node kept it) is read by an **LLM admin**, by the **key's owner**
  (the person a key was minted for), and by nobody else — including agents (`sl_can_read_payload()` in SQL; the records
  role holds no SELECT on `sl_run_payloads`).
- **A node's key** is sealed on write and never read back by anyone; a lost key is rotated from the node page (the node
  shows the new one once to the admin, who confirms the seal).
- **A caller key** is shown once at minting to the person who minted it, never stored here, and its hash lives only on
  the node.
- Agents see what their member id may see — never a payload, never a credential.

## 4. Doors for those who are not inside

None in v1. No public page, no token API of the manager's own (the node's API is the node's; the kernel's K7 the
siblings'). A caller who wants their usage reads it from the node with their inference key (`GET /usage` is scoped to the
key when presented with one — the server design §6.4).

## 5. Agents and the application — the OS requirement, in detail

- **Expert** — `sovereign_llm_manager.expert`, Claude harness, tools: every records tool, the activity tools, and the
  actions of §9 that are not a person's alone. Skills: `llm-fleet-overview`, `queue-triage`, `model-policy`,
  `fallback-reasoning`, `usage-explained`.
- **Fleet Watcher** — `sovereign_llm_manager.fleet_watcher`, duty `morning_note` 06:35 UTC, reads only; writes the note
  as a Spaces DM when Spaces is installed (K23's shape), else the kernel inbox.
- **Paused for an agent** (the kernel's approval, decided by a super-admin): `key_mint`, `key_revoke`, `node_register`,
  `node_key_rotate`, `node_settings_set`, `model_delete`, `policy_fallback_set` (a prompt may leave the machine — a
  person says so), `lane_pause`. **Refused in SQL** to an agent (not paused): reading a payload, reading a credential.
  Open to an agent: `job_cancel` of a job with a tag it owns, `job_priority_set` down, `model_pull`, `model_warm`,
  `model_unload`, `note_post`.
- A node sync is the **worker's** (`bin/worker.php`, every 15 s per node: `/health`; every 60 s: `/status`, `/queue`,
  `/models` and `/runs?since_seq=`; every 5 min: `/usage` as a check), with Inventory's pull lifecycle and a streak-keyed
  notice at three failures. The queue screen itself polls the manager, which answers from `sl_queue_snapshot` written by
  the worker at 15 s — a page never dials a node.

## 6. Memory model — what the manager remembers

### 6.1 Record memory (PostgreSQL 17, `<tenant>_sovereign_llm_manager`)

| Table | What |
|---|---|
| `sl_nodes` | the fleet: `name`, `base_url`, `node_uuid` (from the node), `node_key_sealed`, `status` (new / online / degraded / offline / retired), `backend_kind`, `backend_version`, `machine` jsonb (the node's `/status` machine block), `location_id` (kernel estate, nullable), `last_seen_at`, `last_seq`, `policy_version`, `clock_skew_ms`, `lanes` jsonb (last snapshot) |
| `sl_node_pulls` | Inventory's `source_pulls` verbatim: one row per worker pass per node |
| `sl_queue_snapshot` | the last `/queue` answer per node, one row per queued/running job (`node_id`, `node_job_id`, lane, model, key_name, priority, position, expected_wait_ms, queued_at, started_at, tokens_so_far) — rewritten every 15 s |
| `sl_runs` | **the LLM run record**, the server design §7's columns + `node_id`, `node_run_id` (unique), `caller_key_id` (joined by key name), `kernel_ledger_id` (K58, nullable) |
| `sl_run_events` | the timeline mirrored |
| `sl_run_payloads` | request/response when the node kept them and the manager's policy keeps them (`payload_mirror` per node: none / full; default none — the node has them) |
| `sl_models` | the catalogue per node: the server §5.2 columns + the manager's intent (`wanted_keep_alive`, `wanted_fallback_model`, `wanted_fallback_after_seconds`, `wanted_warm_schedule`, `wanted_allowed`, `wanted_alias`) and `applied_at` — the drift between wanted and the node's is shown and re-pushed |
| `sl_model_prices` | notional price per model name (input / output per Mtok, currency) for usage in money — the admin's; local models 0 |
| `sl_caller_keys` | name, `owner_member_id`, `application_id` (when minted for an application), `node_id`, limits (the server §2), `status`, `minted_by`, `minted_at`, `revoked_at` — **no key, no hash** |
| `sl_usage_daily` | day × node × caller key × model × lane: runs, failures, fallbacks, tokens in/out, queue wait p50/p95, duration p50/p95, tps p50, notional cost |
| `sl_notices` | node down / recovered, queue over threshold, fallback fired, model missing, pull failed, clock skew — with the streak key and the resolve |
| `sl_settings` | thresholds (queue depth, oldest wait, fallback rate), the sync intervals, `payload_mirror` default |
| `sl_rights`, `sl_roles` | the kit's rights model (three roles) |
| canonical | `notifications*`, `worker_passes`, `search_index`, `attachments` |

### 6.2 Activity memory (MaluDB, the tenant's)

Every action and every notice as an episode tagged `sovereign_llm_manager`; a run is **not** an episode (thousands a day,
a machine's facts) — the worker writes one `sync` episode per pass with counts, and a run becomes an episode only when a
person or agent acts on it (a cancel, a note, a payload read — the read is logged).

## 7. The question inventory — what the manager exists to answer

Is every node up, and what is each running right now? · How long will my call wait on node X, and why (what is ahead, which
model is loaded)? · What ran yesterday, for whom, on which model, how fast (queue wait, first token, tokens per second)? ·
Which model is slowest to load, which has the best tokens per second on this box? · How often did the local lane fall
back to the cloud, for which keys, and what did that cost? · Tokens by key / model / lane / day for the period, and the
notional cost · Which models are on disk, loaded, warm, pinned, and which policy differs from what we set? · Which keys
exist, who owns them, what may they do, when were they last used? · What failed, with what error? · What changed on a node
(a policy, a key, a setting), by whom, when? · What is the fleet's capacity (local slots, memory, disk) and where is it
short?

Records tools (~44): `nodes_list`, `node_show`, `node_status`, `queue_list`, `queue_show`, `runs_list`, `run_show`,
`run_timeline`, `runs_stats` (percentiles by model/node/key/period), `models_list`, `model_show`, `model_drift`,
`models_pullable`, `keys_list`, `key_show`, `usage_by_period`, `usage_by_key`, `usage_by_model`, `fallbacks_list`,
`notices_list`, `prices_list`, `settings_show`, `capacity_summary`, `app_roles`, plus the five K7 shares' twins; activity
tools 6 (the kit's). Three **K7 shares**: `usage_by_period` (the ledger's: tokens and notional cost by application tag /
key / model / lane for a period), `nodes_status`, `models_available` (which models a sibling may name on which node —
Knowledge's answer model, the Data Lake's steward).

## 8. The kernel's part, and the application's doors

The kernel: the catalog row (K57), the installer, the two agents, the chat endpoint, the approvals, K7, the application
switcher, `apps/mine`. **K58 (owed, the kernel):** the ledger proxy keeps `X-Node-Id` and `X-Node-Job-Id` from a local
endpoint's answer on the prompt-ledger row (`ai_prompt_ledger.upstream_ref` jsonb), so a run here links to the kernel's
ledger row and the kernel's statement can say which machine served an agent's call. **K59 (owed, the kernel):** the AI
statement reads this application's `usage_by_period` share as one more "provider" line — "Local models (nodes)" — with the
notional cost, when the application is installed. **G6 (owed, GL):** the same for the GL's AI bill.

The application's doors: the node API outward (the worker and the handlers dial nodes); the kernel's doors inward; no
others.

## 9. Screens

Groups in the menu, gated by rights: **Fleet** (home: node tiles with lane gauges, queue depth, tokens today, notices),
**Nodes** (cards; a node: status, machine, lanes, loaded models, the pull history, settings, key rotation, register / retire),
**Queue** (per node, auto-refreshing every 5 s from the snapshot; cancel, priority, move to cloud, pause/resume a lane),
**Runs** (the list with chips: node, model, lane, key, status, fallback; the run page: a timing waterfall accepted →
started → first token → finished, the backend stats, the machine at start, the timeline, the payload behind the wall,
the kernel ledger link), **Models** (per node: the catalogue as cards with on-disk / loaded / warm / pinned chips; pull
with progress from the node's events; warm; unload; keep-warm policy; the fallback model through the **record picker**
(a cloud model of the same node); the warm schedule; drift shown and re-applied), **Keys** (cards; mint — the key shown
once on the result page and never again; limits; revoke; last used), **Usage** (by period / node / key / model / lane with
one two-panel chart — tokens and queue wait; CSV/JSON export; the notional prices page), **Notices**, **Settings**
(thresholds, intervals, prices, payload mirror). The person's screens (My settings, Notifications, Tokens, My trail), the
command bar, the switcher and the tab bar come from the kit. **~62 screens, ~48 actions, 8 paused** — the manifest is
Phase 1's.

## 10. Build order, gates and size

- **Phase 0** — this document approved; K57 (`db/184`); the kit (Data Lake's, re-prefixed `sl_`); `db/001–0NN` proven by a
  schema proof; `maludb-os.json`, the two agents, five skills, `deploy/`; the installer's `plan` clean. **The node API
  stub** — a Python fake node under `tests/fake_node/` answering the server design §6 from fixtures — so every proof here
  runs without a Mac.
- **Phase 1** — the tool surface, the action manifest, the registry, three build specs (`node-sync.md`, `queue-live.md`,
  `usage-rollup.md`), the slice specs, the consistency check.
- **Phase 2** — the shell (the kit's menu, tab bar, bell, switcher, command bar, the person's screens, placeholders).
- **Phase 3** — slices: **1 nodes and the sync** (THE EXEMPLAR: register with the key sealed, the worker's pull lifecycle,
  `since_seq` mirroring of runs and models, the streak notice; proven against the fake node and once against the Mac),
  **2 the queue live** (THE SECOND EXEMPLAR: the snapshot, the 5-s partial, the four actions carried to the node, lane
  pause), **3 models and policies** (pull with progress, warm, unload, keep, fallback through the picker, drift), 4 runs
  and the run page, 5 keys, 6 usage, the rollup, prices and the exports, 7 notices and the Watcher's note, 8 home,
  settings, admin, the K7 shares.
- **Phase 4** — the records MCP (~44 tools + `app_roles` + the three shares), the activity MCP; the registry wrapper
  loaded by the kernel's own `application_actions.py`.
- **Phase 5** — the owner's: ROOT_STEPS, `apply`, DNS/TLS, the two hires, the Mac registered, the end-to-end proof (a call
  from the kernel's proxy to the Mac lands in the kernel's ledger and here, linked by K58).

**The division (D16):** the planning model builds Phase 0, Phase 1, Phase 2 and slices 1–3 (the sync and the live queue
are not templated work); Sonnet 5.5 workers build slices 4–8 and Phase 4, one at a time, in worktrees, each verified; the
worker brief lists `git push` among the forbidden commands.

## 11. Extended, later, and what other applications owe

Registration mode (a node dials in — with the server's S10); a per-key monthly budget enforced by pausing the key on the
node; a node's "shadow" cloud run graded by the kernel's JEV for a local-vs-cloud quality view; a cost-per-request compare
(local electricity notional vs cloud); the kernel's `model_registry` rows **created from here** (a model on a node becomes a
registered model for agents in one click — K60, later). **G6** the GL's AI bill line; **DL1** the Data Lake's dataset feed
of `sl_runs` (the first machine-facts feed, K37's shape).

## 12. What the kernel, the plugin and the siblings owe this application

K57 the catalog row (`db/184`, built with this design's approval); **K58** the proxy keeps the node's job reference on the
ledger row; **K59** the AI statement reads the share; the plugin's `shared-schema.md` gains `sl_runs` as the canonical LLM
run record and `sl_nodes` as the sources-family example for a machine; G6 (GL); DL1 (Data Lake).

## 13. The decisions (recommendations; the owner's answers go in §15)

R1–R7 are decided and not asked again.

| # | Decision | Recommendation | Alternative |
|---|---|---|---|
| D1 | Name, key, label, prefix | **"Sovereign LLM Manager"**, catalog key `sovereign_llm_manager`, repository `maludb-os-sovereign-llm-manager` (the owner's name, spelling corrected), **DNS label `llm`**, database `<tenant>_sovereign_llm_manager`, roles `sovereign_llm_manager_rw` / `_records_ro` / `_activity_ro`, prefix `sl_`; area Technology & Infrastructure, category `platform`, icon `feather-cpu` | label `models`; category `development` |
| D2 | Roles | **Viewer, Operator (`user`), LLM admin** | two (Operator, admin) |
| D3 | Payloads | **the node keeps them; the manager mirrors none by default** (`payload_mirror = none` per node); the run page fetches a payload from the node on demand, behind the wall, and logs the read | mirror `full` so the manager answers when the node is off |
| D4 | The queue screen | **a 5-second partial over the worker's 15-second snapshot** (the estate's polling; no socket) | a live socket as Boards built — not worth a relay for a queue |
| D5 | Runs as episodes | **no** — a `sync` episode per pass with counts; a run becomes an episode when acted on | every run an episode (thousands a day, drowning the activity memory) |
| D6 | Usage in money | **notional prices per model entered here** (local 0, Ollama cloud the admin's estimate); the kernel's statement and the GL read tokens and the notional cost through K7 | no money at all |
| D7 | K58 | **ask the kernel to keep `X-Node-Job-Id` on the ledger row** (one jsonb column, no behaviour change) so a run here links to the kernel's | match by time and model (unreliable) |
| D8 | Keys' owners | **every key has a person or an application as owner**; a key minted for the kernel's proxy is owned by the super-admin who minted it and tagged `kernel` | ownerless keys |
| D9 | The fallback as an approval | **setting a fallback on a model, or allowing it on a key, pauses for an agent** (a prompt may leave the machine); a person does it in one click | open to the expert |
| D10 | Thresholds and notices | defaults: queue depth 20, oldest wait 5 min, fallback rate 25 % an hour, node silent 2 min → a notice, streak-keyed, resolved on recovery; in-app + email, text opt-in through K6 | notices only in-app |
| D11 | Drift | **the manager is the source of a policy once set**; the worker re-pushes a drifted policy and records it; a node's own CLI change shows as drift until adopted ("take the node's") | the node wins |
| D12 | Node register | **register by URL + the node key pasted once** (sealed); the first sync fills everything; a node's `location_id` optional | an enrolment code (needs the node's registration mode) |
| D13 | Model registry one-click | **later (K60)** — v1 shows the `endpoint_url` and the key name an admin needs to register a model in the kernel | in v1 |
| D14 | K7 | **three shares: `usage_by_period`, `nodes_status`, `models_available`**; no reads | usage alone |
| D15 | Default, repository | **on request, not a default** install; **public** repository (nothing in it is a business's) | private |
| D16 | Ports and the division | **8202 / 8860 / 8861**, scratch 9501–9507; the planning model builds Phase 0–2 and slices 1–3, workers 4–8 and Phase 4 | the Spaces division from slice 4 |

**Open questions beyond the table:**

- **(a) Where the kernel's own agents should run local models.** With this application installed, should every
  `model_registry` row of provider `local` point at a node (through the node's OpenAI face) rather than at a bare Ollama?
  Recommendation: yes — the queue and the history are the point; the owner re-points the existing seven rows at Phase 5.
- **(b) The Watcher's channel.** Spaces DM when Spaces is installed, else the kernel's inbox. Recommendation: as stated.
- **(c) The name.** The owner wrote "soveriegn"; this document and the repository use **sovereign**. Recommendation: the
  corrected spelling.

## 14. Ports, names and files

- Repository `/srv/apps/sovereign_llm_manager` (origin `github.com/maludb/maludb-os-sovereign-llm-manager`); record
  database `<tenant>_sovereign_llm_manager` (`subello_sovereign_llm_manager`); the tenant's memory receives episodes
  tagged `sovereign_llm_manager`.
- `llm.<domain>` (`vhost.label = "llm"`).
- Ports: `APP_INTERNAL_PORT` **8202**, records MCP **8860**, activity MCP **8861**; scratch 9501–9507 for the proofs (checked free across `/srv/apps` 2026-10-16; Developer's research had pencilled 8860+ for a door it built as a socket).
- Files: `db/`, `app/` (the kit), `html/`, `mcp/` (two servers, the registry wrapper), `os/`, `skills/`, `deploy/`,
  `bin/worker.php`, `tests/` (`fake_node/`, `phase0/`, `phase1/`, `phase2/`, `phase3/sliceN/`, `phase4/`).
- The node service: `~/maluos-local-llm-server` (origin `github.com/maludb/maluos-local-llm-server`), on the Mac at
  `http://<mac>:11435`.

## 15. The owner's answers

_(awaiting)_

## 16. State

2026-10-16 — designed; nothing built. Local repository `/srv/apps/sovereign_llm_manager` (no origin yet). Next: the
owner's answers to §13 here and §12 of the server design → K57 (`db/184`) and Phase 0 of both.
