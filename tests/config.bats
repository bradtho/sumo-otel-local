#!/usr/bin/env bats
# Tests for the optional project-local config file (.sumo-otel-local.env).

setup() {
    load "test_helper"
    CFG="${BATS_TEST_TMPDIR}/cfg.env"
}

# Source the script with SUMO_CONFIG_FILE pointed at $CFG, then echo a probe line.
source_with_config() {
    run bash -c 'export SUMO_CONFIG_FILE="$2"; source "$1"; trap - ERR EXIT
        echo "rt=$CONTAINER_RUNTIME|mem=$MIN_MEM_MB|cpu=$MIN_CPU|dcn=$DEFAULT_CLUSTER_NAME|cv=$SUMO_CHART_VERSION|cvfe=$CHART_VERSION_FROM_ENV|ay=$ASSUME_YES|force=[$FORCE]"' _ "$SCRIPT" "$CFG"
}

@test "config: sets the env knobs it declares" {
    cat >"$CFG" <<'EOF'
CONTAINER_RUNTIME=docker
MIN_MEM_MB=8192
MIN_CPU=2
ASSUME_YES=yes
EOF
    source_with_config
    [ "$status" -eq 0 ]
    [[ "$output" == *"rt=docker"* ]]
    [[ "$output" == *"mem=8192"* ]]
    [[ "$output" == *"cpu=2"* ]]
    [[ "$output" == *"ay=yes"* ]]
}

@test "config: CLUSTER_NAME becomes the default cluster name" {
    echo 'CLUSTER_NAME=mycluster' >"$CFG"
    source_with_config
    [[ "$output" == *"dcn=mycluster"* ]]
}

@test "config: SUMO_CHART_VERSION pins the chart and skips the picker" {
    echo 'SUMO_CHART_VERSION=5.1.0' >"$CFG"
    source_with_config
    [[ "$output" == *"cv=5.1.0"* ]]
    [[ "$output" == *"cvfe=yes"* ]]
}

@test "config: cannot enable --force (FORCE stays empty for safety)" {
    echo 'FORCE=yes' >"$CFG"
    source_with_config
    [[ "$output" == *"force=[]"* ]]
}

@test "config: a missing config file is fine (defaults apply)" {
    # $CFG does not exist.
    source_with_config
    [ "$status" -eq 0 ]
    [[ "$output" == *"dcn=sumo"* ]]
    [[ "$output" == *"cv=5.2.0"* ]]
    [[ "$output" == *"force=[]"* ]]
}

@test "config: warns when the file sets Sumo credentials, but still loads other knobs" {
    printf 'SUMOLOGIC_ACCESS_ID=leakid\nCLUSTER_NAME=fromcfg\n' >"$CFG"
    source_with_config
    [ "$status" -eq 0 ]
    # Combined last: the plaintext-credential warning fired AND the non-cred knob still loaded.
    [[ "$output" == *"sets Sumo credentials"* && "$output" == *"dcn=fromcfg"* ]]
}

@test "config: a present-but-unreadable file warns and is skipped (defaults apply)" {
    [[ $EUID -ne 0 ]] || skip "chmod 000 is ineffective as root"
    echo 'CLUSTER_NAME=fromcfg' >"$CFG"
    chmod 000 "$CFG"
    source_with_config
    chmod 644 "$CFG" # restore so tmpdir cleanup can remove it
    [ "$status" -eq 0 ]
    [[ "$output" == *"not readable"* && "$output" == *"dcn=sumo"* ]]
}

# --- --init-config / maybe_offer_config_init --------------------------------

@test "init_config: creates the config from the template (documents SUMOLOGIC_ENDPOINT, mode 600)" {
    local dest="${BATS_TEST_TMPDIR}/created.env"
    run bash -c 'source "$1"; trap - ERR EXIT; SUMO_CONFIG_FILE="$2"; ASSUME_YES=yes; init_config' _ "$SCRIPT" "$dest"
    [ "$status" -eq 0 ]
    # Created AND documents the region knob the live-test needed AND is not world/group-readable
    # (600), matching the temp-values-file convention (combined so all are load-bearing).
    grep -q 'SUMOLOGIC_ENDPOINT' "$dest" && [[ "$(ls -ld "$dest" | cut -c1-10)" == "-rw-------" ]]
}

@test "init_config: refuses to clobber an existing config when the overwrite is declined" {
    local dest="${BATS_TEST_TMPDIR}/exists.env"
    echo 'CLUSTER_NAME=keep' >"$dest"
    run bash -c 'source "$1"; trap - ERR EXIT; SUMO_CONFIG_FILE="$2"; confirm(){ return 1; }; init_config' _ "$SCRIPT" "$dest"
    [ "$status" -eq 0 ]
    grep -q 'CLUSTER_NAME=keep' "$dest" # original preserved, not replaced by the template
}

@test "init_config: under -y/ASSUME_YES alone REFUSES to overwrite an existing config (no --force)" {
    # ASSUME_YES must never silently wipe a hand-edited config (it may hold the user's knobs,
    # even creds). Overwriting an existing config requires an interactive yes or --force.
    local dest="${BATS_TEST_TMPDIR}/exists-y.env"
    echo 'CLUSTER_NAME=IMPORTANT' >"$dest"
    run bash -c 'source "$1"; trap - ERR EXIT; SUMO_CONFIG_FILE="$2"; ASSUME_YES=yes; FORCE=""; init_config' _ "$SCRIPT" "$dest"
    [ "$status" -ne 0 ]
    # File preserved AND the refusal is explained (combined, load-bearing on macOS).
    [[ "$(cat "$dest")" == *"CLUSTER_NAME=IMPORTANT"* && "$output" == *"Refusing to overwrite"* ]]
}

@test "init_config: --force overwrites an existing config (under -y)" {
    local dest="${BATS_TEST_TMPDIR}/exists-f.env"
    echo 'CLUSTER_NAME=OLD' >"$dest"
    run bash -c 'source "$1"; trap - ERR EXIT; SUMO_CONFIG_FILE="$2"; ASSUME_YES=yes; FORCE=yes; init_config' _ "$SCRIPT" "$dest"
    [ "$status" -eq 0 ]
    # Replaced by the template: the old knob is gone and the template content is present.
    [[ "$(cat "$dest")" != *"CLUSTER_NAME=OLD"* && "$(cat "$dest")" == *"SUMOLOGIC_ENDPOINT"* ]]
}

@test "init_config: refuses when the config is disabled (SUMO_CONFIG_FILE=/dev/null)" {
    run bash -c 'source "$1"; trap - ERR EXIT; SUMO_CONFIG_FILE=/dev/null; ASSUME_YES=yes; init_config' _ "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Config is disabled"* ]]
}

@test "maybe_offer_config_init: interactive + no config offers; declining continues" {
    local none="${BATS_TEST_TMPDIR}/absent.env"
    run bash -c 'source "$1"; trap - ERR EXIT; SUMO_CONFIG_FILE="$2"; ASSUME_YES=""; confirm(){ return 1; }
        maybe_offer_config_init; echo DONE' _ "$SCRIPT" "$none"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No project config"* && "$output" == *"DONE"* ]]
}

@test "maybe_offer_config_init: does not prompt under ASSUME_YES or when a config already exists" {
    local none="${BATS_TEST_TMPDIR}/absent2.env" have="${BATS_TEST_TMPDIR}/have.env"
    echo 'CLUSTER_NAME=x' >"$have"
    # ASSUME_YES: must skip the offer entirely (no prompt), even with no config present.
    run bash -c 'source "$1"; trap - ERR EXIT; SUMO_CONFIG_FILE="$2"; ASSUME_YES=yes; confirm(){ echo NOPE; }
        maybe_offer_config_init; echo A' _ "$SCRIPT" "$none"
    local ay="$output"
    # Config already present: also skip (no prompt).
    run bash -c 'source "$1"; trap - ERR EXIT; SUMO_CONFIG_FILE="$2"; ASSUME_YES=""; confirm(){ echo NOPE; }
        maybe_offer_config_init; echo B' _ "$SCRIPT" "$have"
    # One combined final command so BOTH scenarios are load-bearing on macOS bats: neither
    # offered (no "No project config" / no confirm "NOPE") and both continued (A / B).
    [[ "$ay" != *"No project config"* && "$ay" != *"NOPE"* && "$ay" == *"A"* \
        && "$output" != *"No project config"* && "$output" != *"NOPE"* && "$output" == *"B"* ]]
}

@test "maybe_offer_config_init: does not offer under --dry-run or when config is disabled (/dev/null)" {
    local none="${BATS_TEST_TMPDIR}/none.env"
    # --dry-run must touch nothing: no offer even with no config and interactive.
    run bash -c 'source "$1"; trap - ERR EXIT; SUMO_CONFIG_FILE="$2"; ASSUME_YES=""; DRY_RUN=yes; confirm(){ echo NOPE; }
        maybe_offer_config_init; echo A' _ "$SCRIPT" "$none"
    local dry="$output"
    # /dev/null = "config disabled" idiom: don't nag to create one.
    run bash -c 'source "$1"; trap - ERR EXIT; SUMO_CONFIG_FILE=/dev/null; ASSUME_YES=""; DRY_RUN=""; confirm(){ echo NOPE; }
        maybe_offer_config_init; echo B' _ "$SCRIPT"
    [[ "$dry" != *"No project config"* && "$dry" == *"A"* \
        && "$output" != *"No project config"* && "$output" == *"B"* ]]
}

@test "maybe_offer_config_init: accepting creates the config and EXITS (no fall-through to install)" {
    # Guards the affirmative branch: confirm-yes -> write + exit 0. A regression turning the
    # exit into a return would fall through into the real install of an un-edited config.
    local dest="${BATS_TEST_TMPDIR}/offered.env"
    run bash -c 'source "$1"; trap - ERR EXIT; SUMO_CONFIG_FILE="$2"; ASSUME_YES=""; DRY_RUN=""; confirm(){ return 0; }
        maybe_offer_config_init; echo SHOULD_NOT_REACH' _ "$SCRIPT" "$dest"
    [ "$status" -eq 0 ]
    # Created the config AND exited before the caller's next step (no SHOULD_NOT_REACH).
    [[ -f "$dest" && "$output" != *"SHOULD_NOT_REACH"* ]]
}
