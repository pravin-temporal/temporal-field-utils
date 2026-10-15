# env-switch.sh

Switch the `TEMPORAL_*` connection env vars between named profiles (local
dev server, one or more Cloud namespaces, …) with one command. Works in bash
(3.2+) and zsh.

## Install

```bash
git clone https://github.com/pravin-temporal/temporal-field-utils.git ~/temporal-field-utils
echo 'source ~/temporal-field-utils/env/env-switch.sh' >> ~/.zshrc   # or ~/.bashrc
source ~/.zshrc
```

In zsh, tab completion needs `compinit` to run before the `source` line
(Oh My Zsh and most frameworks already do this).

Then create a Cloud profile, either from vars already exported in your shell
or interactively:

```bash
temporal-import            # saves the current connection vars as profile "cloud"
temporal-setup             # or: prompt for address / namespace / API key
temporal-setup prod-us     # any number of named profiles
```

If you imported vars that were exported in your rc file, remove those
`export TEMPORAL_*` lines afterwards. While they're there, new shells use
them instead of restoring your last profile.

## Commands

| Command | |
|---|---|
| `temporal-use <profile>` | Switch to a profile (tab-completes) |
| `temporal-cloud` / `temporal-local` | Shortcuts for `temporal-use cloud` / `local` |
| `temporal-status` | Show the active profile and values (secrets masked) |
| `temporal-profiles` | List profiles |
| `temporal-setup [profile]` | Create or overwrite a profile interactively |
| `temporal-import [profile]` | Save the current shell's connection vars (address, namespace, API key, TLS paths, codec, `TEMPORAL_GRPC_META_*`) |

Both `setup` and `import` ask before overwriting an existing profile.

## How it works

- Profiles are plain `KEY=value` files in `~/.temporal/<profile>.env`
  (mode 600). Values are read literally, never executed. Edit them directly,
  e.g. to add mTLS settings:
  ```
  TEMPORAL_ADDRESS=my-ns.a1b2c.tmprl.cloud:7233
  TEMPORAL_NAMESPACE=my-ns.a1b2c
  TEMPORAL_TLS_CLIENT_CERT_PATH=/path/to/client.pem
  TEMPORAL_TLS_CLIENT_KEY_PATH=/path/to/client.key
  ```
- `local.env` is created on first run (`localhost:7233`, namespace `default`).
- Switching clears all connection vars first, so nothing from the previous
  profile leaks through. That includes `TEMPORAL_ENV` (which would make the
  CLI load a `temporal env` set instead) and the `*_DATA` PEM vars, which
  profiles can't store. `temporal-import` refuses to run while `*_DATA` vars
  are set; save the cert/key to files and use the `*_PATH` vars instead.
- Because switching (and auto-restore) clears these vars, put settings you
  want everywhere, such as `TEMPORAL_CODEC_ENDPOINT`, in each profile rather
  than exporting them from your rc file.
- A new shell re-applies the last profile you switched to, unless it already
  has a Temporal connection (inherited from a parent shell, or a
  `TEMPORAL_ADDRESS` you exported). The restored profile's API key is
  exported to everything you run from that shell.
- Settings go before the `source` line: `TFU_AUTO_RESTORE=0` turns off
  auto-restore, and `TFU_CONFIG_DIR` stores profiles somewhere other than
  `~/.temporal`. (`TFU` = Temporal Field Utils, the prefix for this repo's
  own settings.)

## CLI and SDK config profiles

**TL;DR:** no conflicts; you can use both. Where both set a value, this
script's env vars win over the TOML profile.

The Temporal CLI and recent SDKs can load named profiles from a TOML file
(`temporal.toml`, picked with `--profile` or `TEMPORAL_PROFILE`). If every
tool you use supports that, you may not need this script.

**Why use this instead:** it only sets plain `TEMPORAL_*` env vars, so it
works with anything that reads them: the CLI, the SDKs, samples and your own
code that read `TEMPORAL_ADDRESS` etc. directly (common in apps written
before TOML profiles), and tools like Docker that pass env vars through. One
command switches all of them for the whole shell, and `temporal-status`
shows what's active.

**How they interact:** this script never reads or changes the TOML file,
`TEMPORAL_PROFILE` or `TEMPORAL_CONFIG_FILE`, and keeps its own files in
`~/.temporal`. But clients combine both sources:

- Env vars set here override the same settings from a TOML profile, even one
  picked with `--profile`. Command-line flags still override both.
- Settings a profile here doesn't set fall back to the TOML profile. For
  example, an `api_key` in the TOML default profile is also sent when you
  switch to `local`. Keep the TOML default profile free of credentials, or
  set every value you need in each profile here.
- Switching clears `TEMPORAL_ENV`, which selects a set from the CLI's older
  `temporal env` command.

## Uninstall

Remove the `source` line from your shell rc file, then `rm -rf ~/.temporal`.
