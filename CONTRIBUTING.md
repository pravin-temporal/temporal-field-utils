# Contributing

Thanks for considering a contribution — this toolkit is meant to grow with
whatever friction points come up in day-to-day field/platform-architecture
work with Temporal.

## Ground rules

1. **No secrets, ever.** No real API keys, namespace IDs, internal hostnames,
   or customer-identifying information in code, comments, examples, or
   commit messages. Use obviously fake placeholders
   (`my-namespace.a1b2c.tmprl.cloud:7233`, etc.).
2. **One script, one job.** Prefer small, composable scripts over one script
   that tries to do everything.
3. **Group by purpose, not by tool.** Folders are organized around the kind
   of problem a script solves (`env/`, `observability/`, `cost/`,
   `diagnostics/`), not around which vendor or technology it touches —
   since the repo itself is already scoped to Temporal, a `temporal/`
   subfolder would be redundant. Create a new folder if nothing existing
   fits the task.
4. **Document usage at the top of the file.** A short comment block
   explaining what the script does, how to install/source it, and the
   commands it exposes — see `env/env-switch.sh` for the pattern.
5. **Test before opening a PR.** At minimum, run the script yourself
   end-to-end. Shell scripts should be checked with
   [shellcheck](https://www.shellcheck.net/) where practical.

## Opening a PR

- Briefly describe the problem the script solves and how you've tested it.
- Keep PRs scoped to one script or one logical change where possible —
  easier to review, easier to revert if something's off.
- If you're updating an existing script's behavior (not just adding to it),
  call that out explicitly in the PR description so others relying on it
  aren't surprised.

## Reporting issues

If something in here breaks for you or seems unsafe (e.g. a secret-handling
pattern you're not comfortable with), open an issue or reach out directly —
no need for a polished writeup, a quick heads-up is enough.
