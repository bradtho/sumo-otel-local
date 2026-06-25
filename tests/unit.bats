#!/usr/bin/env bats
# Unit tests for the pure, dependency-light helper functions.

setup() {
    load "test_helper"
    load_script
}

# --- mem_to_mib -------------------------------------------------------------

@test "mem_to_mib: bytes (>= 1 GiB) convert to MiB" {
    run mem_to_mib 19327352832 # 18432 MiB in bytes (podman 5.x)
    [ "$status" -eq 0 ]
    [ "$output" -eq 18432 ]
}

@test "mem_to_mib: a MiB value (< 1 GiB-in-bytes) passes through unchanged" {
    run mem_to_mib 18432
    [ "$output" -eq 18432 ]
}

@test "mem_to_mib: boundary 1073741824 bytes == 1024 MiB" {
    run mem_to_mib 1073741824
    [ "$output" -eq 1024 ]
}

@test "mem_to_mib: non-numeric input yields 0" {
    run mem_to_mib "lots"
    [ "$output" -eq 0 ]
}

# --- yaml_escape ------------------------------------------------------------

@test "yaml_escape: leaves a plain value untouched" {
    run yaml_escape "su1234abcd"
    [ "$output" = "su1234abcd" ]
}

@test "yaml_escape: escapes double quotes" {
    run yaml_escape 'a"b'
    [ "$output" = 'a\"b' ]
}

@test "yaml_escape: escapes backslashes before quotes" {
    run yaml_escape 'a\b"c'
    [ "$output" = 'a\\b\"c' ]
}

# --- secret_env_var ---------------------------------------------------------

@test "secret_env_var: uppercases the secret name to its env var" {
    run secret_env_var sumologic_access_id
    [ "$output" = "SUMOLOGIC_ACCESS_ID" ]
}

# --- confirm / ask (unattended behaviour) -----------------------------------

@test "confirm: returns yes under ASSUME_YES without reading stdin" {
    ASSUME_YES=yes
    run confirm "proceed?" n
    [ "$status" -eq 0 ]
}

@test "confirm: interactive 'y' is accepted, 'n'/default is rejected" {
    ASSUME_YES=""
    run bash -c 'source "$1"; ASSUME_YES=""; confirm "ok?" n <<<"y"' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    run bash -c 'source "$1"; ASSUME_YES=""; confirm "ok?" n <<<""' _ "$SCRIPT"
    [ "$status" -ne 0 ]
}

@test "ask: returns the default under ASSUME_YES" {
    ASSUME_YES=yes
    run ask "name? " "sumo"
    [ "$output" = "sumo" ]
}

# --- MIN_* validation (top-level guard) -------------------------------------

@test "MIN_MEM_MB validation: non-integer aborts sourcing" {
    run bash -c 'MIN_MEM_MB=lots source "$1"' _ "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"must be positive integers"* ]]
}

@test "MIN_CPU is overridable via the environment" {
    MIN_CPU=2 run bash -c 'source "$1"; echo "$MIN_CPU"' _ "$SCRIPT"
    [ "$output" = "2" ]
}
