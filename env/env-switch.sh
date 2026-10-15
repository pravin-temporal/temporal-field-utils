# shellcheck shell=bash
#
# Temporal Environment Switcher
# -----------------------------
# Switch the TEMPORAL_* connection env vars (address, namespace, API key,
# TLS, ...) between named profiles with a single command.
#
# This file must be SOURCED, not executed, from bash or zsh:
#   source ~/temporal-field-utils/env/env-switch.sh     # add to ~/.zshrc or ~/.bashrc
#
# COMMANDS
#   temporal-use <profile>     switch to a profile
#   temporal-cloud             shortcut for: temporal-use cloud
#   temporal-local             shortcut for: temporal-use local
#   temporal-status            show the active profile and its values (secrets masked)
#   temporal-profiles          list saved profiles
#   temporal-setup [profile]   create/overwrite a profile interactively (default: cloud)
#   temporal-import [profile]  save the current shell's connection vars (default: cloud)
#
# Profiles are plain KEY=value files in ~/.temporal/<profile>.env (mode 600).
# Values are read literally, never executed. New shells re-apply the last
# profile you switched to, unless they already have a Temporal connection
# (e.g. inherited from a parent shell); set TFU_AUTO_RESTORE=0 to disable.
# Set TFU_CONFIG_DIR before sourcing to use another directory.
# Nothing is sent anywhere.
#
# See env/README.md for details.

# ---- Refuse to run unless sourced ---------------------------------------
# Executing the file would only set variables in a throwaway subshell.
if [ -n "${ZSH_VERSION:-}" ]; then
    # Exactly "toplevel" means the file is running as a script. Sourcing
    # gives "...:file", and plugin managers that eval it give "...:eval".
    [ "${ZSH_EVAL_CONTEXT:-}" = toplevel ] && _tfu_not_sourced=1
elif [ -n "${BASH_VERSION:-}" ]; then
    [ "${BASH_SOURCE[0]}" = "$0" ] && _tfu_not_sourced=1
else
    echo "env-switch.sh supports bash and zsh only." >&2
    # shellcheck disable=SC2317  # exit is reached when not sourced
    return 1 2>/dev/null || exit 1
fi
if [ -n "${_tfu_not_sourced:-}" ]; then
    unset _tfu_not_sourced
    echo "This script sets environment variables in your shell, so it must" >&2
    echo "be SOURCED, not executed. Run it like this instead:" >&2
    echo "  source $0" >&2
    # `return` where possible, so a misdetection can never close the shell.
    # shellcheck disable=SC2317
    return 1 2>/dev/null || exit 1
fi

# ---- Configuration ------------------------------------------------------

# TEMPORAL_CONFIG_DIR is honoured for compatibility with older versions.
_TFU_DIR="${TFU_CONFIG_DIR:-${TEMPORAL_CONFIG_DIR:-$HOME/.temporal}}"

# The active profile is exported as TEMPORAL_ACTIVE_PROFILE. It keeps that
# name (rather than a TFU_ one) for compatibility with earlier versions, e.g.
# shell prompts that display it. No Temporal tool reads it.
_TFU_LAST_FILE="$_TFU_DIR/last_profile"

# Connection vars cleared on every switch and saved by temporal-import, so
# nothing from the previous profile leaks into the next one. Includes the
# CLI's legacy TLS names (TEMPORAL_TLS_CERT/KEY/CA), which override the
# current ones. TEMPORAL_GRPC_META_* vars are handled separately below.
_TFU_MANAGED_VARS="TEMPORAL_ADDRESS TEMPORAL_NAMESPACE TEMPORAL_API_KEY \
TEMPORAL_TLS TEMPORAL_TLS_CERT TEMPORAL_TLS_KEY TEMPORAL_TLS_CA \
TEMPORAL_TLS_CLIENT_CERT_PATH TEMPORAL_TLS_CLIENT_KEY_PATH \
TEMPORAL_TLS_SERVER_CA_CERT_PATH TEMPORAL_TLS_SERVER_NAME \
TEMPORAL_TLS_DISABLE_HOST_VERIFICATION \
TEMPORAL_CODEC_ENDPOINT TEMPORAL_CODEC_AUTH"

# Cleared on every switch but never saved:
# - TEMPORAL_ENV makes the CLI load a named `temporal env` set, which would
#   silently override the values here.
# - *_DATA vars hold multi-line PEM data, which profile files can't store.
_TFU_CLEAR_ONLY_VARS="TEMPORAL_ENV \
TEMPORAL_TLS_CLIENT_CERT_DATA TEMPORAL_TLS_CLIENT_KEY_DATA \
TEMPORAL_TLS_SERVER_CA_CERT_DATA \
TEMPORAL_TLS_CERT_DATA TEMPORAL_TLS_KEY_DATA TEMPORAL_TLS_CA_DATA"

# ---- Internal helpers ---------------------------------------------------

_tfu_err() { printf 'temporal: %s\n' "$*" >&2; }

_tfu_valid_name() {
    case "$1" in
        '' | .* | *[!A-Za-z0-9._-]*)
            _tfu_err "invalid profile name '$1' (use letters, digits, '.', '_', '-')"
            return 1 ;;
    esac
}

# Write stdin to $1 with mode 600, atomically. The umask is set before the
# file exists, so it is never readable by others, even briefly.
_tfu_write_file() {
    local tmp="$1.tmp.$$"
    ( umask 077 && cat > "$tmp" ) && mv -f "$tmp" "$1"
}

# Ask before replacing an existing profile file.
_tfu_confirm_overwrite() {
    local ans=""
    [ -f "$2" ] || return 0
    printf 'Profile "%s" already exists. Overwriting replaces the whole file,\n' "$1"
    printf 'including any lines you added by hand. Overwrite? [y/N] '
    read -r ans || ans=""
    case "$ans" in y | Y | yes) return 0 ;; esac
    echo "Cancelled."
    return 1
}

# Validate a profile file and print it back as normalised KEY=value lines.
# Fails (printing nothing) on the first bad line, so callers can parse a
# profile completely before touching the environment.
_tfu_parse() {
    local file="$1" line key val n=0 key_ok=0 out=""
    if [ ! -r "$file" ]; then
        _tfu_err "cannot read $file"
        return 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        line="${line%$'\r'}"
        case "$line" in '' | '#'*) continue ;; esac
        line="${line#export }"
        key="${line%%=*}"
        val="${line#*=}"
        if [ "$key" = "$line" ]; then
            _tfu_err "$file:$n: expected KEY=value"
            return 1
        fi
        case "$key" in
            TEMPORAL_ACTIVE_PROFILE | *[!A-Za-z0-9_]*) ;;
            TEMPORAL_?*) key_ok=1 ;;
        esac
        if [ "$key_ok" != 1 ]; then
            _tfu_err "$file:$n: '$key' is not allowed (expected a TEMPORAL_* variable name)"
            return 1
        fi
        key_ok=0
        # Files written by older versions wrapped values in quotes. This means
        # a value that itself starts and ends with the same quote loses them.
        case "$val" in \"*\" | \'*\') val="${val#?}"; val="${val%?}" ;; esac
        out="$out$key=$val
"
    done < "$file"
    printf '%s' "$out"
}

# Names of exported TEMPORAL_GRPC_META_* vars, space-separated.
_tfu_grpc_meta_vars() {
    env | sed -n 's/^\(TEMPORAL_GRPC_META_[A-Za-z0-9_]*\)=.*/\1/p' | tr '\n' ' '
}

# Every connection var this script knows about, de-duplicated: the managed
# list, whatever the active profile loaded, and any gRPC metadata vars.
# shellcheck disable=SC2120  # reuses "$@" as a scratch list, takes no args
_tfu_known_vars() {
    local key seen=""
    eval "set -- $_TFU_MANAGED_VARS ${_TFU_LOADED_VARS:-} $(_tfu_grpc_meta_vars)"
    for key in "$@"; do
        case " $seen " in *" $key "*) continue ;; esac
        seen="$seen $key"
    done
    printf '%s' "$seen"
}

_tfu_clear() {
    eval "unset $_TFU_MANAGED_VARS $_TFU_CLEAR_ONLY_VARS ${_TFU_LOADED_VARS:-} $(_tfu_grpc_meta_vars)"
}

# Load a profile into the current shell. The environment is left untouched
# if the profile is missing or malformed.
_tfu_activate() {
    local name="$1" file parsed line key
    _tfu_valid_name "$name" || return 1
    file="$_TFU_DIR/$name.env"
    if [ ! -f "$file" ]; then
        _tfu_err "no profile '$name' ($file). Create it with: temporal-setup $name"
        return 1
    fi
    parsed="$(_tfu_parse "$file")" || return 1
    _tfu_clear
    _TFU_LOADED_VARS=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        key="${line%%=*}"
        export "$key=${line#*=}"
        _TFU_LOADED_VARS="$_TFU_LOADED_VARS $key"
    done <<EOF
$parsed
EOF
    export TEMPORAL_ACTIVE_PROFILE="$name"
}

_tfu_profile_names() {
    find "$_TFU_DIR" -maxdepth 1 -type f -name '?*.env' 2>/dev/null |
        sed 's#.*/##; s#\.env$##' | sort
}

_tfu_mask() {
    if [ "${#1}" -ge 12 ]; then
        printf '****%s' "${1: -4}"
    else
        printf '****'
    fi
}

# ---- Commands -----------------------------------------------------------

temporal-use() {
    if [ $# -ne 1 ]; then
        echo "usage: temporal-use <profile>" >&2
        temporal-profiles >&2
        return 1
    fi
    _tfu_activate "$1" || return 1
    printf '%s\n' "$1" | _tfu_write_file "$_TFU_LAST_FILE"
    printf 'Switched to Temporal profile "%s"\n' "$1"
    # shellcheck disable=SC2119
    temporal-status
}

temporal-cloud() { temporal-use cloud; }
temporal-local() { temporal-use local; }

# shellcheck disable=SC2120  # reuses "$@" as a scratch list, takes no args
temporal-status() {
    local name="${TEMPORAL_ACTIVE_PROFILE:-}" file="" parsed line key val shown="" width=18 drift="" fkeys=""
    if [ -z "$name" ]; then
        echo "Active Temporal profile: <none>"
    elif ! _tfu_valid_name "$name" 2>/dev/null; then
        echo "Active Temporal profile: <invalid name>"
        name=""
    else
        file="$_TFU_DIR/$name.env"
        if [ -f "$file" ]; then
            printf 'Active Temporal profile: %s (%s)\n' "$name" "$file"
        else
            printf 'Active Temporal profile: %s (%s, file missing)\n' "$name" "$file"
        fi
    fi

    # Address, namespace and API key are always shown; other vars only if set.
    # shellcheck disable=SC2119
    eval "set -- $(_tfu_known_vars)"
    for key in "$@"; do
        eval "val=\${$key-}"
        case "$key" in
            TEMPORAL_ADDRESS | TEMPORAL_NAMESPACE | TEMPORAL_API_KEY) ;;
            *) [ -n "$val" ] || continue ;;
        esac
        shown="$shown $key"
        [ "${#key}" -le "$width" ] || width="${#key}"
    done
    eval "set -- $shown"
    for key in "$@"; do
        eval "val=\${$key-}"
        if [ -z "$val" ]; then
            val="<unset>"
        else
            case "$key" in
                *API_KEY* | *AUTH* | *SECRET* | *TOKEN* | *PASSWORD* | *GRPC_META* | *_DATA)
                    val="$(_tfu_mask "$val")" ;;
            esac
        fi
        printf '  %-*s = %s\n' "$width" "$key" "$val"
    done

    # Values present without any profile were exported some other way, which
    # also stops new shells from restoring the last profile. (Skipped for an
    # invalid inherited profile name, which the header already reports.)
    if [ -z "${TEMPORAL_ACTIVE_PROFILE:-}" ] && [ -n "${TEMPORAL_ADDRESS:-}" ]; then
        echo "  Note: these values weren't set by a profile (e.g. exported in your shell rc)."
        echo "  Save them with 'temporal-import <name>', then remove those exports."
    fi

    # Warn if the shell no longer matches the profile file: a value changed,
    # or a connection var the profile doesn't define was set by hand.
    if [ -n "$name" ] && [ -f "$file" ] && parsed="$(_tfu_parse "$file" 2>/dev/null)"; then
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            key="${line%%=*}"
            fkeys="$fkeys $key"
            eval "val=\${$key-}"
            [ "$val" = "${line#*=}" ] || drift="$drift $key"
        done <<EOF
$parsed
EOF
        # shellcheck disable=SC2119
        eval "set -- $(_tfu_known_vars) $_TFU_CLEAR_ONLY_VARS"
        for key in "$@"; do
            case " $fkeys " in *" $key "*) continue ;; esac
            eval "val=\${$key-}"
            [ -z "$val" ] || drift="$drift $key"
        done
        if [ -n "$drift" ]; then
            echo "  Note: changed since switching:$drift"
            echo "  Run 'temporal-use $name' to reset."
        fi
    fi
}

temporal-profiles() {
    local names line
    names="$(_tfu_profile_names)"
    if [ -z "$names" ]; then
        echo "No profiles in $_TFU_DIR yet. Create one with: temporal-setup <name>"
        return 0
    fi
    while IFS= read -r line; do
        if [ "$line" = "${TEMPORAL_ACTIVE_PROFILE:-}" ]; then
            printf '* %s\n' "$line"
        else
            printf '  %s\n' "$line"
        fi
    done <<EOF
$names
EOF
}

temporal-setup() {
    local name="${1:-cloud}" file addr="" ns="" key=""
    _tfu_valid_name "$name" || return 1
    file="$_TFU_DIR/$name.env"
    _tfu_confirm_overwrite "$name" "$file" || return 1
    echo "Setting up Temporal profile \"$name\" (saved to $file)"
    # printf + plain `read -r` rather than `read -p`: in zsh, -p reads from
    # a coprocess instead of showing a prompt.
    while [ -z "$addr" ]; do
        printf '%s' "TEMPORAL_ADDRESS   (e.g. my-namespace.a1b2c.tmprl.cloud:7233): "
        read -r addr || return 1
    done
    while [ -z "$ns" ]; do
        printf '%s' "TEMPORAL_NAMESPACE (e.g. my-namespace.a1b2c): "
        read -r ns || return 1
    done
    printf '%s' "TEMPORAL_API_KEY   (blank for none, e.g. local or mTLS): "
    if [ -t 0 ]; then read -rs key; echo; else read -r key; fi
    case "$addr" in
        *tmprl.cloud*) [ -n "$key" ] || echo "No API key given. For mTLS, add TEMPORAL_TLS_* lines to $file." ;;
    esac
    {
        printf 'TEMPORAL_ADDRESS=%s\n' "$addr"
        printf 'TEMPORAL_NAMESPACE=%s\n' "$ns"
        if [ -n "$key" ]; then printf 'TEMPORAL_API_KEY=%s\n' "$key"; fi
    } | _tfu_write_file "$file" || return 1
    echo "Saved."
    temporal-use "$name"
}

temporal-import() {
    local name="${1:-cloud}" file key val out="" data="" nl='
'
    _tfu_valid_name "$name" || return 1
    if [ -z "${TEMPORAL_ADDRESS:-}" ] || [ -z "${TEMPORAL_NAMESPACE:-}" ]; then
        _tfu_err "TEMPORAL_ADDRESS and TEMPORAL_NAMESPACE must be set in this shell. Use temporal-setup instead."
        return 1
    fi
    # PEM *_DATA vars can't be stored in a profile, and switching clears
    # them, so importing would silently break a working mTLS setup.
    eval "set -- $_TFU_CLEAR_ONLY_VARS"
    for key in "$@"; do
        case "$key" in *_DATA) ;; *) continue ;; esac
        eval "val=\${$key-}"
        [ -z "$val" ] || data="$data $key"
    done
    if [ -n "$data" ]; then
        _tfu_err "can't import:$data (PEM data can't be stored in a profile)."
        _tfu_err "Save the certificate/key to files and set the *_PATH variables instead"
        _tfu_err "(e.g. TEMPORAL_TLS_CLIENT_CERT_PATH), or unset them to import without them."
        return 1
    fi
    file="$_TFU_DIR/$name.env"
    _tfu_confirm_overwrite "$name" "$file" || return 1
    # shellcheck disable=SC2119
    eval "set -- $(_tfu_known_vars)"
    for key in "$@"; do
        eval "val=\${$key-}"
        [ -n "$val" ] || continue
        case "$val" in
            *"$nl"*) _tfu_err "skipping $key: multi-line values aren't supported"; continue ;;
        esac
        out="$out$key=$val$nl"
    done
    printf '%s' "$out" | _tfu_write_file "$file" || return 1
    echo "Imported current shell values into $file"
    temporal-use "$name"
}

# Names used by earlier versions.
temporal-cloud-setup() { temporal-setup cloud; }
temporal-cloud-import-current() { temporal-import cloud; }

# ---- Tab completion for profile names -----------------------------------

if [ -n "${BASH_VERSION:-}" ]; then
    _tfu_complete() {
        # shellcheck disable=SC2207
        COMPREPLY=($(compgen -W "$(_tfu_profile_names)" -- "${COMP_WORDS[COMP_CWORD]}"))
    }
    complete -F _tfu_complete temporal-use temporal-setup temporal-import
elif type compdef >/dev/null 2>&1; then
    # zsh: only available if compinit already ran earlier in ~/.zshrc.
    # shellcheck disable=SC2046
    _tfu_complete() { compadd -- $(_tfu_profile_names); }
    compdef _tfu_complete temporal-use temporal-setup temporal-import
fi

# ---- First-run setup and auto-restore ------------------------------------

# Only a directory we create gets restricted permissions; an existing one
# (possibly chosen via TFU_CONFIG_DIR) is left as it is.
if [ ! -d "$_TFU_DIR" ]; then
    ( umask 077 && mkdir -p "$_TFU_DIR" )
fi

if [ ! -f "$_TFU_DIR/local.env" ]; then
    printf 'TEMPORAL_ADDRESS=localhost:7233\nTEMPORAL_NAMESPACE=default\n' |
        _tfu_write_file "$_TFU_DIR/local.env"
fi

# Never override a shell that already has a Temporal connection: one
# inherited from a parent shell (tmux, IDE terminals, nested shells), one
# already active when ~/.zshrc is re-sourced, or one the user exported.
if [ -n "${TEMPORAL_ACTIVE_PROFILE:-}" ]; then
    # Keep the inherited profile, and record its vars so the next switch
    # clears them properly. They're read from the profile file as it is now:
    # if it was edited after the parent shell loaded it, extra non-standard
    # vars from the parent aren't tracked (the standard ones always are).
    if _tfu_valid_name "$TEMPORAL_ACTIVE_PROFILE" 2>/dev/null &&
        _tfu_last="$(_tfu_parse "$_TFU_DIR/$TEMPORAL_ACTIVE_PROFILE.env" 2>/dev/null)"; then
        _TFU_LOADED_VARS="$(printf '%s\n' "$_tfu_last" | sed 's/=.*//' | tr '\n' ' ')"
    fi
elif [ -n "${TEMPORAL_ADDRESS:-}" ]; then
    :
elif [ "${TFU_AUTO_RESTORE:-1}" != 0 ] && [ -f "$_TFU_LAST_FILE" ]; then
    # Re-apply the last-used profile. Note this exports that profile's API
    # key into the shell (and every process it starts).
    _tfu_last="$(cat "$_TFU_LAST_FILE" 2>/dev/null)"
    if [ -f "$_TFU_DIR/$_tfu_last.env" ]; then
        _tfu_activate "$_tfu_last" || _tfu_err "could not restore profile '$_tfu_last'"
    fi
fi
unset _tfu_last
