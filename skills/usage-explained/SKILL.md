---
name: usage-explained
description: How tokens, runs and the notional cost are counted and reported by period, key, model, lane and node. Load before answering a usage or cost question.
---
# Usage, explained

`usage_by_period` and its siblings (`usage_by_key`, `usage_by_model`) read the daily rollup: runs, failures, fallbacks, tokens in and out,
queue-wait and duration percentiles, tokens per second, and the notional cost. The same numbers go to the ledger through the
`usage_by_period` share.

- **Tokens are the fact; money is notional.** A local model costs nothing unless an admin entered a price (`prices_list`); an Ollama cloud
  model's price is the admin's estimate. Say "about" and name the price table.
- A period boundary is a UTC day; yesterday is the last complete day.
- A run counts under the key that made it; a key minted for the kernel's proxy is owned by the super-admin who minted it and tagged
  `kernel`.
- Failures and fallbacks are counted separately from successes; do not subtract one from the other.
- If a number is missing (a node was offline when it should have been pulled), say so; the node keeps its own history and the next pull fills it.
