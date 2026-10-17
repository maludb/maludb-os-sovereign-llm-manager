---
name: queue-triage
description: How to read a node's queue and what may be done about it: wait, position, priority, cancel, move to the cloud, pause a lane. Load when asked why a call is waiting or what to do about a backlog.
---
# Queue triage

1. `queue_list` for the node: lane, model, key name, priority, position, expected wait, tokens so far. Local lane serves one job at
   a time; a long job at the head explains every wait behind it.
2. A **model swap** is the hidden cost: a queued job for a model that is not loaded pays the load time. Group by model before blaming volume.
3. What you may do: `job_priority_set` (down only, for a job you own the tag of), `job_cancel` (same), `job_move` to the cloud lane
   only where the key and the request already allow it.
4. **A started job never moves.** Cancel it or wait.
5. `lane_pause` pauses for a person; ask, with the evidence (depth, oldest wait, what is ahead).

Thresholds (defaults): depth 20, oldest wait 5 minutes. Over them a notice exists already; do not raise a second one.
