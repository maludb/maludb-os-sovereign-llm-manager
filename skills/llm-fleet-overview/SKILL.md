---
name: llm-fleet-overview
description: What the fleet is and which tool answers what: nodes, lanes, the queue snapshot, loaded models, notices. Load before any Sovereign LLM Manager work.
---
# The fleet at a glance

**A node** is a machine running the node service; it has a status (new, online, degraded, offline, retired), lanes (local: one job at a
time; cloud: unlimited; maintenance) and a catalogue of models. The manager **pulls** from nodes; a page never dials one. The queue you
see is the worker's snapshot, at most 15 seconds old; `last_seen_at` tells you how fresh a node is.

## Which tool answers what
- Is it up, what is it running: `nodes_list`, `node_status`, `capacity_summary` (slots, memory, disk — where it is short).
- What is waiting: `queue_list`, `queue_show`. What happened: `runs_list`, `run_show`, `run_timeline`, `runs_stats`.
- What is wrong: `notices_list` (streak-keyed: one notice per outage, resolved on recovery). Thresholds: `settings_show`.
- What changed: `node_trail`, `record_history`.

## Rules
- Fresh data first: if `last_seen_at` is older than two minutes, say the node is silent, not that it is idle.
- Drift means the manager's intent is not on the node yet; it is re-pushed, it is not a fault by itself.
- You never see a payload or a credential. Do not ask for one.
- Local models cost nothing unless a notional price is entered; say "tokens", not "money", by default.
