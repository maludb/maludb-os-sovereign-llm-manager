---
name: fallback-reasoning
description: When a call may leave the machine for a cloud model, and how to reason about fallbacks seen in the history. Load before discussing or proposing a fallback.
---
# Fallback reasoning

A prompt leaves a machine only when a person allowed it **twice**: on the key, and on the model or the request. Neither alone is enough.

- **Never recommend a fallback as a default.** It is an exception for a model whose local queue wait keeps passing its limit and whose
  prompts the owner has judged fit to leave.
- Read what happened: `fallbacks_list` (which keys, which models, why — queue wait, load failure, node down) and `runs_list` filtered to
  fallbacks. Count them against the total before calling a rate high; the default notice is 25 % in an hour.
- A fallback has a cost: the cloud model's tokens at a notional price, and the prompt's journey. Say both.
- Setting or allowing a fallback is `policy_fallback_set`, which pauses for a super-admin. Ask with the evidence; do not argue for it.
