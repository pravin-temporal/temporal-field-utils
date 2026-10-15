#!/usr/bin/env bats
#
# Tests for env/env-switch.sh. Runs under bash by default; set TEST_SHELL=zsh
# to run the same tests under zsh (`make test` does both).
#
# Snippets are single-quoted on purpose: the shell under test expands them.
# shellcheck disable=SC2016

setup() {
    TEST_SHELL="${TEST_SHELL:-bash}"
    SCRIPT="$BATS_TEST_DIRNAME/../env/env-switch.sh"
    CFG="$BATS_TEST_TMPDIR/cfg"
}

# Run a snippet in a clean shell (no inherited TEMPORAL_* vars, no rc files)
# with the script sourced. Extra VAR=value args are passed into the environment.
in_shell() {
    local snippet="$1"
    shift
    local flags=()
    [ "$TEST_SHELL" = zsh ] && flags=(-f)
    run env -i HOME="$BATS_TEST_TMPDIR" PATH="$PATH" TFU_CONFIG_DIR="$CFG" "$@" \
        "$TEST_SHELL" "${flags[@]}" -c "source '$SCRIPT' && $snippet"
}

perms() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

@test "refuses to run when executed instead of sourced" {
    run env -i HOME="$BATS_TEST_TMPDIR" PATH="$PATH" TFU_CONFIG_DIR="$CFG" "$TEST_SHELL" "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"must"*"SOURCED"* ]]
}

@test "first run creates a private config dir and default local profile" {
    in_shell 'true'
    [ "$status" -eq 0 ]
    [ "$(perms "$CFG")" = 700 ]
    [ "$(perms "$CFG/local.env")" = 600 ]
    grep -qx 'TEMPORAL_ADDRESS=localhost:7233' "$CFG/local.env"
}

@test "import stores values literally and never executes them" {
    local nasty='k$(touch '"$BATS_TEST_TMPDIR"'/pwned)"`x`'"'"'end'
    in_shell 'temporal-import cloud >/dev/null' \
        TEMPORAL_ADDRESS=a:7233 TEMPORAL_NAMESPACE=ns TEMPORAL_API_KEY="$nasty"
    [ "$status" -eq 0 ]
    [ "$(perms "$CFG/cloud.env")" = 600 ]

    in_shell 'temporal-use cloud >/dev/null && printf %s "$TEMPORAL_API_KEY"'
    [ "$status" -eq 0 ]
    [ "$output" = "$nasty" ]
    [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}

@test "switching profiles clears variables from the previous one" {
    in_shell 'true'
    printf 'TEMPORAL_ADDRESS=c:7233\nTEMPORAL_NAMESPACE=c\nTEMPORAL_API_KEY=secret\nTEMPORAL_TLS_CERT=/c.pem\nTEMPORAL_CUSTOM=x\n' > "$CFG/cloud.env"

    in_shell 'temporal-cloud >/dev/null && temporal-local >/dev/null &&
        echo "${TEMPORAL_ADDRESS}|${TEMPORAL_API_KEY-unset}|${TEMPORAL_TLS_CERT-unset}|${TEMPORAL_CUSTOM-unset}|${TEMPORAL_ENV-unset}"' \
        TEMPORAL_ENV=prod
    [ "$status" -eq 0 ]
    [ "$output" = "localhost:7233|unset|unset|unset|unset" ]
}

@test "a malformed profile leaves the environment untouched" {
    in_shell 'true'
    printf 'TEMPORAL_ADDRESS=bad:7233\nPATH=/nope\n' > "$CFG/bad.env"

    in_shell 'temporal-use bad; echo "rc=$? $TEMPORAL_ADDRESS ${TEMPORAL_ACTIVE_PROFILE-none}"' \
        TEMPORAL_ADDRESS=orig:7233
    [[ "$output" == *"'PATH' is not allowed"* ]]
    [[ "$output" == *"rc=1 orig:7233 none" ]]
}

@test "reads profiles written by older versions (export + quotes)" {
    in_shell 'true'
    printf 'export TEMPORAL_ADDRESS="old:7233"\nexport TEMPORAL_NAMESPACE="old-ns"\n' > "$CFG/cloud.env"
    in_shell 'temporal-cloud >/dev/null && echo "$TEMPORAL_ADDRESS $TEMPORAL_NAMESPACE"'
    [ "$output" = "old:7233 old-ns" ]
}

@test "last profile is restored in new shells unless TFU_AUTO_RESTORE=0" {
    in_shell 'temporal-local >/dev/null'
    in_shell 'echo "${TEMPORAL_ACTIVE_PROFILE-none} ${TEMPORAL_ADDRESS-unset}"'
    [ "$output" = "local localhost:7233" ]

    in_shell 'echo "${TEMPORAL_ACTIVE_PROFILE-none}"' TFU_AUTO_RESTORE=0
    [ "$output" = "none" ]
}

@test "setup re-prompts for empty values and saves the profile" {
    in_shell 'printf "\nhost:7233\nmy-ns\nmy-api-key-123456\n" | temporal-setup dev >/dev/null 2>&1; temporal-use dev >/dev/null; echo "$TEMPORAL_ADDRESS $TEMPORAL_NAMESPACE $TEMPORAL_API_KEY"'
    [ "$output" = "host:7233 my-ns my-api-key-123456" ]
}

@test "status masks the API key and reports drift" {
    in_shell 'printf "TEMPORAL_ADDRESS=a:7233\nTEMPORAL_NAMESPACE=n\nTEMPORAL_API_KEY=abcdefgh-wxyz\n" > "$TFU_CONFIG_DIR/cloud.env" &&
        temporal-cloud >/dev/null && export TEMPORAL_NAMESPACE=other && temporal-status'
    [ "$status" -eq 0 ]
    [[ "$output" == *"****wxyz"* ]]
    [[ "$output" != *"abcdefgh"* ]]
    [[ "$output" == *"changed since switching: TEMPORAL_NAMESPACE"* ]]
}

@test "profiles lists saved profiles and marks the active one" {
    in_shell 'printf "TEMPORAL_ADDRESS=a\n" > "$TFU_CONFIG_DIR/cloud.env" && temporal-local >/dev/null && temporal-profiles'
    [ "$output" = "$(printf '  cloud\n* local')" ]
}

@test "rejects unsafe profile names" {
    in_shell 'temporal-use ../etc/passwd'
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid profile name"* ]]
}

@test "loading via eval inside a function (zsh plugin managers) works and keeps the shell alive" {
    run env -i HOME="$BATS_TEST_TMPDIR" PATH="$PATH" TFU_CONFIG_DIR="$CFG" "$TEST_SHELL" -c \
        "load() { eval \"\$(cat '$SCRIPT')\"; }; load; temporal-local >/dev/null; echo \"alive \$TEMPORAL_ADDRESS\""
    [ "$status" -eq 0 ]
    [ "$output" = "alive localhost:7233" ]
}

@test "re-sourcing does not pick up a switch made in another terminal" {
    in_shell 'printf "TEMPORAL_ADDRESS=c:7233\nTEMPORAL_NAMESPACE=c\n" > "$TFU_CONFIG_DIR/cloud.env" &&
        temporal-cloud >/dev/null &&
        ( temporal-local >/dev/null ) &&
        source "$SCRIPT" && echo "$TEMPORAL_ACTIVE_PROFILE $TEMPORAL_ADDRESS"' SCRIPT="$SCRIPT"
    [ "$output" = "cloud c:7233" ]
}

@test "an inherited profile is kept, and its extra vars are cleared on the next switch" {
    in_shell 'temporal-local >/dev/null'   # last_profile=local
    printf 'TEMPORAL_ADDRESS=c:7233\nTEMPORAL_NAMESPACE=c\nTEMPORAL_CUSTOM=x\n' > "$CFG/cloud.env"

    in_shell 'echo "$TEMPORAL_ACTIVE_PROFILE $TEMPORAL_CUSTOM" && temporal-local >/dev/null && echo "${TEMPORAL_CUSTOM-unset}"' \
        TEMPORAL_ACTIVE_PROFILE=cloud TEMPORAL_ADDRESS=c:7233 TEMPORAL_NAMESPACE=c TEMPORAL_CUSTOM=x
    [ "$output" = "$(printf 'cloud x\nunset')" ]
}

@test "a user-exported TEMPORAL_ADDRESS is not overridden by auto-restore" {
    in_shell 'temporal-local >/dev/null'
    in_shell 'echo "$TEMPORAL_ADDRESS ${TEMPORAL_ACTIVE_PROFILE-none}"' TEMPORAL_ADDRESS=mine:7233
    [ "$output" = "mine:7233 none" ]
}

@test "import asks before overwriting an existing profile" {
    in_shell 'true'
    printf 'TEMPORAL_ADDRESS=keep\nTEMPORAL_NAMESPACE=keep\nTEMPORAL_TLS_CERT=/my.pem\n' > "$CFG/prod.env"
    in_shell 'printf "n\n" | temporal-import prod' TEMPORAL_ADDRESS=new TEMPORAL_NAMESPACE=new
    [ "$status" -eq 1 ]
    grep -qx 'TEMPORAL_TLS_CERT=/my.pem' "$CFG/prod.env"

    in_shell 'printf "y\n" | temporal-import prod >/dev/null' TEMPORAL_ADDRESS=new TEMPORAL_NAMESPACE=new
    [ "$status" -eq 0 ]
    grep -qx 'TEMPORAL_ADDRESS=new' "$CFG/prod.env"
}

@test "setup can be cancelled without touching the existing profile" {
    in_shell 'printf "n\n" | temporal-setup local'
    [ "$status" -eq 1 ]
    grep -qx 'TEMPORAL_ADDRESS=localhost:7233' "$CFG/local.env"
}

@test "PEM *_DATA and gRPC metadata vars are cleared on switch; metadata is imported and masked" {
    in_shell 'temporal-import meta >/dev/null && temporal-status' \
        TEMPORAL_ADDRESS=a:7233 TEMPORAL_NAMESPACE=n TEMPORAL_GRPC_META_X_TENANT=tenant-secret-1234
    grep -qx 'TEMPORAL_GRPC_META_X_TENANT=tenant-secret-1234' "$CFG/meta.env"
    [[ "$output" == *"TEMPORAL_GRPC_META_X_TENANT = ****1234"* ]]

    in_shell 'temporal-local >/dev/null && echo "${TEMPORAL_TLS_CLIENT_CERT_DATA-unset} ${TEMPORAL_GRPC_META_X_TENANT-unset}"' \
        TEMPORAL_TLS_CLIENT_CERT_DATA=pem TEMPORAL_GRPC_META_X_TENANT=t
    [ "$output" = "unset unset" ]
}

@test "an existing config dir keeps its permissions" {
    mkdir -p "$CFG" && chmod 755 "$CFG"
    in_shell 'true'
    [ "$(perms "$CFG")" = 755 ]
}

@test "status does not trust an invalid inherited profile name" {
    in_shell 'temporal-status | head -1' TEMPORAL_ACTIVE_PROFILE=../../etc/x
    [ "$output" = "Active Temporal profile: <invalid name>" ]
}

@test "reads profiles with CRLF line endings" {
    in_shell 'true'
    printf 'TEMPORAL_ADDRESS=crlf:7233\r\nTEMPORAL_NAMESPACE=n\r\n' > "$CFG/win.env"
    in_shell 'temporal-use win >/dev/null && printf "%s|" "$TEMPORAL_ADDRESS"'
    [ "$output" = "crlf:7233|" ]
}

@test "import refuses PEM *_DATA vars instead of silently dropping them" {
    in_shell 'temporal-import mtls; echo "rc=$? ${TEMPORAL_TLS_CLIENT_CERT_DATA-gone}"' \
        TEMPORAL_ADDRESS=a:7233 TEMPORAL_NAMESPACE=n TEMPORAL_TLS_CLIENT_CERT_DATA=PEMCERT
    [[ "$output" == *"can't import: TEMPORAL_TLS_CLIENT_CERT_DATA"* ]]
    [[ "$output" == *"rc=1 PEMCERT" ]]
    [ ! -e "$CFG/mtls.env" ]
}

@test "status explains values that weren't set by a profile" {
    in_shell 'temporal-status' TEMPORAL_ADDRESS=old:7233
    [[ "$output" == *"weren't set by a profile"* ]]
    [[ "$output" == *"temporal-import"* ]]
}

@test "status flags connection vars exported by hand that the profile doesn't define" {
    in_shell 'temporal-local >/dev/null && export TEMPORAL_API_KEY=sneaky-key-1234 && temporal-status'
    [[ "$output" == *"changed since switching: TEMPORAL_API_KEY"* ]]
}

@test "temporal-use without a profile prints usage" {
    in_shell 'temporal-use'
    [ "$status" -eq 1 ]
    [[ "$output" == *"usage: temporal-use <profile>"* ]]
}

@test "registers tab completion for profile names" {
    if [ "$TEST_SHELL" = zsh ]; then
        run env -i HOME="$BATS_TEST_TMPDIR" PATH="$PATH" TFU_CONFIG_DIR="$CFG" zsh -f -c \
            "autoload -U compinit && compinit -u -d \"\$HOME/.zcompdump\" && source '$SCRIPT' && echo \"\${_comps[temporal-use]}\""
        [ "$output" = "_tfu_complete" ]
    else
        in_shell 'complete -p temporal-use'
        [[ "$output" == *"-F _tfu_complete temporal-use"* ]]
    fi
}

@test "works when sourced into a shell with set -eu" {
    run env -i HOME="$BATS_TEST_TMPDIR" PATH="$PATH" TFU_CONFIG_DIR="$CFG" "$TEST_SHELL" -c \
        "set -eu; source '$SCRIPT'; temporal-local >/dev/null; temporal-status >/dev/null; temporal-profiles >/dev/null; source '$SCRIPT'; echo \"ok \$TEMPORAL_ACTIVE_PROFILE\""
    [ "$status" -eq 0 ]
    [ "$output" = "ok local" ]
}

@test "status masks *_DATA values set in a profile" {
    in_shell 'printf "TEMPORAL_ADDRESS=a:7233\nTEMPORAL_NAMESPACE=n\nTEMPORAL_TLS_CLIENT_KEY_DATA=private-key-abcd\n" > "$TFU_CONFIG_DIR/k.env" &&
        temporal-use k'
    [[ "$output" == *"TEMPORAL_TLS_CLIENT_KEY_DATA = ****abcd"* ]]
    [[ "$output" != *"private-key"* ]]
}

@test "import refusal explains how to import without the *_DATA vars" {
    in_shell 'temporal-import mtls' \
        TEMPORAL_ADDRESS=a:7233 TEMPORAL_NAMESPACE=n TEMPORAL_TLS_CLIENT_KEY_DATA=PEMKEY
    [[ "$output" == *"or unset them to import without them"* ]]
}

@test "status says when the active profile's file is missing" {
    in_shell 'temporal-status | head -1' TEMPORAL_ACTIVE_PROFILE=gone
    [[ "$output" == *"gone ("*"gone.env, file missing)" ]]
}

@test "an invalid inherited profile name doesn't trigger the rc-export hint" {
    in_shell 'temporal-status' TEMPORAL_ACTIVE_PROFILE=../x TEMPORAL_ADDRESS=a:7233
    [[ "$output" == *"<invalid name>"* ]]
    [[ "$output" != *"weren't set by a profile"* ]]
}
