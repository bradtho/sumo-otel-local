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
