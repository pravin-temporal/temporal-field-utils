#!/usr/bin/env bash
#
# Temporal Environment Switcher
# -----------------------------
# Lets you flip TEMPORAL_ADDRESS / TEMPORAL_NAMESPACE / TEMPORAL_API_KEY
# between "local" and "cloud" with a single command.
#
# IMPORTANT: this file must be SOURCED, not executed. Running it directly
# (e.g. `bash env-switch.sh`) only sets variables in a throwaway subshell
# that disappears the moment the script exits.
#
# SETUP (one-time):
#   1. Clone the repo somewhere permanent, e.g.:
#        git clone https://github.com/pravin-temporal/temporal-field-utils.git ~/temporal-field-utils
#   2. Add this line to your ~/.bashrc or ~/.zshrc:
#        source ~/temporal-field-utils/env/env-switch.sh
#   3. Reload your shell: source ~/.zshrc   (or open a new terminal)
#
# FIRST-TIME CLOUD CONFIG (pick one):
#   a) If TEMPORAL_ADDRESS / TEMPORAL_NAMESPACE / TEMPORAL_API_KEY are
#      already exported in your current shell (your current setup):
#        temporal-cloud-import-current
#   b) Otherwise, enter them interactively (stored securely on disk):
#        temporal-cloud-setup
#
# DAILY USE:
#   temporal-cloud     -> switch to Temporal Cloud
#   temporal-local      -> switch to local dev server
#   temporal-status     -> show which env is active + current values
#
# Whichever profile you last switched to is remembered and automatically
# re-applied the next time you open a new terminal (no need to re-run
# temporal-cloud/temporal-local every tab) — see ~/.temporal/last_profile.
#
# Credentials are stored in ~/.temporal/cloud.env with chmod 600
# (readable only by you). Nothing is sent anywhere.
# Compatible with bash and zsh.

# Detect direct execution vs. sourcing (works in both bash and zsh): a bare
# `return` only succeeds when this file is being sourced.
if (return 0 2>/dev/null); then
    : # sourced, continue normally
else
    echo "This script sets environment variables in your shell, so it must" >&2
    echo "be SOURCED, not executed. Run it like this instead:" >&2
    echo "  source ${BASH_SOURCE[0]:-$0}" >&2
    exit 1
fi

TEMPORAL_CONFIG_DIR="${TEMPORAL_CONFIG_DIR:-$HOME/.temporal}"
TEMPORAL_CLOUD_ENV_FILE="$TEMPORAL_CONFIG_DIR/cloud.env"
TEMPORAL_LOCAL_ENV_FILE="$TEMPORAL_CONFIG_DIR/local.env"
TEMPORAL_LAST_PROFILE_FILE="$TEMPORAL_CONFIG_DIR/last_profile"

mkdir -p "$TEMPORAL_CONFIG_DIR"

# Create a sane local.env default the first time, if one doesn't exist yet.
if [ ! -f "$TEMPORAL_LOCAL_ENV_FILE" ]; then
    cat > "$TEMPORAL_LOCAL_ENV_FILE" <<'EOF'
export TEMPORAL_ADDRESS="localhost:7233"
export TEMPORAL_NAMESPACE="default"
EOF
fi

# ---- One-time setup helpers -------------------------------------------

# Interactively prompt for and save Cloud credentials.
temporal-cloud-setup() {
    mkdir -p "$TEMPORAL_CONFIG_DIR"
    echo "Setting up Temporal Cloud credentials (saved to $TEMPORAL_CLOUD_ENV_FILE)"
    # NOTE: deliberately using `printf` + plain `read -r` instead of
    # `read -p` here: -p means "show a prompt" in bash but "read from a
    # coprocess" in zsh, so read -p silently misbehaves when this file is
    # sourced into a zsh shell.
    printf "%s" "TEMPORAL_ADDRESS   (e.g. my-namespace.a2b3c.tmprl.cloud:7233): "
    read -r addr
    printf "%s" "TEMPORAL_NAMESPACE (e.g. my-namespace.a2b3c): "
    read -r ns
    printf "%s" "TEMPORAL_API_KEY: "
    read -rs key
    echo
    cat > "$TEMPORAL_CLOUD_ENV_FILE" <<EOF
export TEMPORAL_ADDRESS="$addr"
export TEMPORAL_NAMESPACE="$ns"
export TEMPORAL_API_KEY="$key"
EOF
    chmod 600 "$TEMPORAL_CLOUD_ENV_FILE"
    echo "Saved."
    temporal-cloud
}

# Capture whatever TEMPORAL_ADDRESS/NAMESPACE/API_KEY are CURRENTLY
# exported in your shell (your existing setup) and save them as the
# "cloud" profile, so you don't have to retype anything.
temporal-cloud-import-current() {
    if [ -z "$TEMPORAL_ADDRESS" ] || [ -z "$TEMPORAL_NAMESPACE" ] || [ -z "$TEMPORAL_API_KEY" ]; then
        echo "One or more of TEMPORAL_ADDRESS / TEMPORAL_NAMESPACE / TEMPORAL_API_KEY"
        echo "is not currently set in this shell. Use temporal-cloud-setup instead."
        return 1
    fi
    mkdir -p "$TEMPORAL_CONFIG_DIR"
    cat > "$TEMPORAL_CLOUD_ENV_FILE" <<EOF
export TEMPORAL_ADDRESS="$TEMPORAL_ADDRESS"
export TEMPORAL_NAMESPACE="$TEMPORAL_NAMESPACE"
export TEMPORAL_API_KEY="$TEMPORAL_API_KEY"
EOF
    chmod 600 "$TEMPORAL_CLOUD_ENV_FILE"
    export TEMPORAL_ACTIVE_PROFILE="cloud"
    echo "cloud" > "$TEMPORAL_LAST_PROFILE_FILE"
    echo "Imported current shell values into $TEMPORAL_CLOUD_ENV_FILE"
    temporal-status
}

# ---- Daily switch commands ---------------------------------------------

temporal-cloud() {
    if [ ! -f "$TEMPORAL_CLOUD_ENV_FILE" ]; then
        echo "No cloud config found yet."
        echo "Run 'temporal-cloud-setup' or 'temporal-cloud-import-current' first."
        return 1
    fi
    unset TEMPORAL_ADDRESS TEMPORAL_NAMESPACE TEMPORAL_API_KEY TEMPORAL_ENV
    # shellcheck disable=SC1090
    source "$TEMPORAL_CLOUD_ENV_FILE"
    export TEMPORAL_ACTIVE_PROFILE="cloud"
    echo "cloud" > "$TEMPORAL_LAST_PROFILE_FILE"
    echo "Switched to Temporal CLOUD"
    temporal-status
}

temporal-local() {
    unset TEMPORAL_API_KEY TEMPORAL_ADDRESS TEMPORAL_NAMESPACE TEMPORAL_ENV
    # shellcheck disable=SC1090
    source "$TEMPORAL_LOCAL_ENV_FILE"
    export TEMPORAL_ACTIVE_PROFILE="local"
    echo "local" > "$TEMPORAL_LAST_PROFILE_FILE"
    echo "Switched to Temporal LOCAL"
    temporal-status
}

temporal-status() {
    echo "Active Temporal profile: ${TEMPORAL_ACTIVE_PROFILE:-<not set yet>}"
    echo "  TEMPORAL_ADDRESS   = ${TEMPORAL_ADDRESS:-<unset>}"
    echo "  TEMPORAL_NAMESPACE = ${TEMPORAL_NAMESPACE:-<unset>}"
    if [ -n "$TEMPORAL_API_KEY" ]; then
        echo "  TEMPORAL_API_KEY   = ****${TEMPORAL_API_KEY: -4}"
    else
        echo "  TEMPORAL_API_KEY   = <unset>"
    fi
}

# ---- Auto-reactivate last-used profile on new shells --------------------
# Runs once each time this file is sourced (i.e. once per new terminal).
# Silent on success; quietly skips if the saved profile's file is missing
# (e.g. cloud.env was deleted) rather than erroring out your shell startup.
if [ -f "$TEMPORAL_LAST_PROFILE_FILE" ]; then
    _temporal_last_profile="$(cat "$TEMPORAL_LAST_PROFILE_FILE" 2>/dev/null)"
    case "$_temporal_last_profile" in
        cloud)
            if [ -f "$TEMPORAL_CLOUD_ENV_FILE" ]; then
                # shellcheck disable=SC1090
                source "$TEMPORAL_CLOUD_ENV_FILE"
                export TEMPORAL_ACTIVE_PROFILE="cloud"
            fi
            ;;
        local)
            # shellcheck disable=SC1090
            source "$TEMPORAL_LOCAL_ENV_FILE"
            export TEMPORAL_ACTIVE_PROFILE="local"
            ;;
    esac
    unset _temporal_last_profile
fi
