# Contributing

## Guidelines

- **One script, one job.** Small, composable scripts over do-everything ones.
- **Group by purpose** (`env/`, `diagnostics/`, …), not by tool or vendor.
  Add a folder if nothing fits.
- **Document it.** A short usage block at the top of the script, plus a
  `README.md` in its folder (see `env/` for the pattern).
- **Test it.** Run `make check` (needs [shellcheck](https://www.shellcheck.net/),
  [bats](https://github.com/bats-core/bats-core), and zsh). CI runs the same.

## Secrets hygiene

- Never commit real API keys, addresses, namespace IDs, internal hostnames, or
  customer data, even redacted, in code, examples, screenshots, or commit
  messages. Use placeholders like `my-namespace.a1b2c.tmprl.cloud:7233`.
- If your script writes local config or credential files, keep them outside
  the repo and extend `.gitignore` before the first commit.
- If GitHub secret scanning flags something, treat it as a real leak and
  rotate the credential.

## Pull requests

Keep PRs to one script or logical change, say how you tested it, and call
out any behaviour change to an existing script.
