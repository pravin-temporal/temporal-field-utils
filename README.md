# Temporal Field Utils

> ⚠️ **Not an official Temporal repository.** This is a personal collection of
> utility scripts maintained by me in my individual capacity as a Platform
> Architect. It is **not supported, endorsed, or maintained by Temporal
> Technologies, Inc.** Use at your own risk. See [LICENSE](./LICENSE) for terms.

A growing collection of small, practical scripts for working with Temporal day
to day — built out of real friction points from customer-facing Platform
Architect / Solution Architect work (environment switching, diagnostics,
reporting helpers, etc.).

## What's here

Folders are organized by what the script helps with, not by which tool or
vendor it touches:

| Folder | Purpose |
|---|---|
| [`env/`](./env) | Environment/config management — switching contexts, credentials, connection setup. |
| `observability/` *(planned)* | Dashboards, alert-threshold checks, log/metric pulls. |
| `cost/` *(planned)* | Consumption and cost reporting helpers. |
| `diagnostics/` *(planned)* | Health checks, workflow/queue/worker inspection scripts. |

| Script | What it does |
|---|---|
| [`env/env-switch.sh`](./env/env-switch.sh) | Switch your shell between Temporal **local** dev server and **Cloud** credentials with one command (`temporal-local` / `temporal-cloud`), without manually re-exporting env vars each time. Remembers your last-used profile and re-applies it in new terminals automatically. |

## Quick start — `env-switch.sh`

```bash
# 1. Clone and save it somewhere permanent
git clone https://github.com/pravin-temporal/temporal-field-utils.git ~/temporal-field-utils

# 2. Source it from your shell rc file
echo 'source ~/temporal-field-utils/env/env-switch.sh' >> ~/.zshrc   # or ~/.bashrc
source ~/.zshrc

# 3. One-time: import your existing Cloud env vars, OR enter them interactively
temporal-cloud-import-current     # if TEMPORAL_ADDRESS / NAMESPACE / API_KEY are already exported
# -- or --
temporal-cloud-setup              # interactive prompt, stored in ~/.temporal/cloud.env (chmod 600)
```

Daily use:

```bash
temporal-cloud      # switch to Temporal Cloud
temporal-local       # switch to local dev server
temporal-status      # show which profile is active
```

Credentials are stored locally in `~/.temporal/cloud.env` (outside this repo,
chmod 600) — nothing is ever written into the repo itself.

## Security / secrets hygiene

- Never commit real `TEMPORAL_API_KEY`, `TEMPORAL_ADDRESS`, or namespace
  values — even partially redacted — into this repo, including in example
  output, screenshots, or commit messages.
- `.gitignore` already excludes common patterns (`*.env`, `.temporal/`,
  `secrets/`). If you add a script that generates local config/credential
  files, extend `.gitignore` accordingly *before* your first commit of it.
- GitHub's secret scanning is enabled by default on public repos — if it
  flags something, treat it as a real incident (rotate the credential)
  even if you think it was caught in time.

## Contributing

Contributions are welcome! A few light guidelines:

- Keep each script focused on one job; group related scripts into their own
  top-level folder (e.g. `temporal/`, `aws/`) rather than a flat file dump.
- Include a short usage comment block at the top of any new script (see
  `temporal/env-switch.sh` for the pattern).
- No real credentials, customer data, or internal URLs in examples —
  use placeholders.
- Open a PR with a brief description of the problem the script solves.

See [CONTRIBUTING.md](./CONTRIBUTING.md) for more detail.

## License

MIT — see [LICENSE](./LICENSE). The MIT license applies to the code in this
repository; it does not imply any endorsement by or affiliation with
Temporal Technologies, Inc.
