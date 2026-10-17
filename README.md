# Sovereign LLM Manager

An application for the MaluDB Business OS (catalog key `sovereign_llm_manager`, DNS label `llm`, prefix `sl_`): the business's window on
the machines that run its models. It manages the fleet of nodes that run `maluos-local-llm-server` (repository
`github.com/maludb/maluos-local-llm-server`): nodes, each queue live, runs with their numbers, models and their policies, caller keys
and usage by period. It never serves an inference and never speaks to Ollama -- only to nodes, through their node API.

- Design, decisions and build order: `docs/sovereign-llm-manager-design.md`
- Agents: the LLM Ops Expert (`os/expert.md`) and the Fleet Watcher (`os/fleet_watcher.md`, morning note 06:35 UTC); five skills in `skills/`
- Packaging: `maludb-os.json`, `deploy/`

## Prove it

    SL_MIGRATIONS_UPTO=010 bash tests/phase0/run.sh      # the kit and the schema, on a scratch database sl_dev0

## Install

By the kernel's installer, from the kernel's checkout:

    php /var/www/bin/app_install.php plan  /srv/apps/sovereign_llm_manager --by <super-admin email> --domain <domain>
    sudo php /var/www/bin/app_install.php apply /srv/apps/sovereign_llm_manager --by <super-admin email> --domain <domain>

`deploy/ROOT_STEPS.sh` prints the order, including the steps that are the owner's (DNS/TLS, registering the first node).
