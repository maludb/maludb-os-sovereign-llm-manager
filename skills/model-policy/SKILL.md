---
name: model-policy
description: The manager's intent for a model: keep-alive, warm schedule, allowed, alias, pull and unload, and drift. Load before proposing or changing a model's policy.
---
# Model policy

Each model on a node carries what the node reports and what the manager **wants**: `wanted_keep_alive`, `wanted_warm_schedule`,
`wanted_allowed`, `wanted_alias`, `wanted_fallback_*`. `model_drift` lists where they differ.

- **Drift** means the manager's intent is not on the node yet. The worker re-pushes it; wait a pass before calling it a fault. A change made
  at the node's own command line shows as drift until an admin adopts it.
- `model_pull` (see `models_pullable` first: size, disk free), `model_warm`, `model_unload` are open to you. A model that is in use or
  warm for a schedule is not unloaded without saying so.
- Propose a warm schedule when the first call of the day pays a long load time (`runs_stats`). Propose a pull when calls name a model the
  node does not have. Give the numbers.
- `model_delete` and any fallback change pause for a person.
