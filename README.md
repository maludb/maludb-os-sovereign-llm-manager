# Sovereign LLM Manager

An application for the MaluDB Business OS (catalog key `sovereign_llm_manager`, DNS label `llm`, prefix `sl_`): the business's fleet of
local and cloud model nodes -- nodes, the queue, runs, models, caller keys and usage.

The design, decisions and build order are in `docs/sovereign-llm-manager-design.md`.

This tree holds the application kit (sign-on, directory mirror, roles and rights, activity funnel, keys, settings, worker, ingest
bridge and the proofs). Prove it with:

    SL_MIGRATIONS_UPTO=005 bash tests/phase0/run.sh      # the kit alone, on a scratch database sl_dev0
