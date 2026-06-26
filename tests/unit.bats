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

@test "runtime tool versions default to their pins" {
    run bash -c 'source "$1"; echo "$KUBECTL_VERSION $HELM_VERSION $KIND_VERSION $PODMAN_VERSION"' _ "$SCRIPT"
    [ "$output" = "v1.36.2 v4.2.2 v0.32.0 v6.0.0" ]
}

@test "runtime tool versions are overridable via the environment" {
    KIND_VERSION=v0.30.0 KUBECTL_VERSION=v1.30.0 run bash -c 'source "$1"; echo "$KUBECTL_VERSION $KIND_VERSION"' _ "$SCRIPT"
    [ "$output" = "v1.30.0 v0.30.0" ]
}

@test "SCRIPT_DIR resolves to the script directory holding the bundled assets" {
    run bash -c 'source "$1"; echo "$SCRIPT_DIR"' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -f "$output/kind-config.yaml" ]
    [ -f "$output/values.yaml" ]
}

@test "KINDEST_NODE_VERSION defaults to the pin and is overridable" {
    run bash -c 'source "$1"; echo "$KINDEST_NODE_VERSION"' _ "$SCRIPT"
    [ "$output" = "v1.36.1" ]
    KINDEST_NODE_VERSION=v1.30.0 run bash -c 'source "$1"; echo "$KINDEST_NODE_VERSION"' _ "$SCRIPT"
    [ "$output" = "v1.30.0" ]
}

@test "Homebrew installer is pinned to a commit (no mutable HEAD) and checksum-verified" {
    run grep -c 'Homebrew/install/HEAD' "$SCRIPT"
    [ "$output" -eq 0 ] # the mutable HEAD ref is gone
    grep -Fq 'HOMEBREW_INSTALL_COMMIT' "$SCRIPT"
    grep -Fq 'HOMEBREW_INSTALL_SHA256' "$SCRIPT"
    run bash -c 'source "$1"; printf "%s %s" "$HOMEBREW_INSTALL_COMMIT" "$HOMEBREW_INSTALL_SHA256"' _ "$SCRIPT"
    [[ "$output" =~ ^[0-9a-f]{40}\ [0-9a-f]{64}$ ]] # 40-hex commit + 64-hex sha256
}

@test "helm installs from a verified tarball, not the get-helm-3 script" {
    run grep -c 'scripts/get-helm-3' "$SCRIPT"
    [ "$output" -eq 0 ] # the get-helm-3 bootstrap download is gone (comment mention is fine)
    grep -Fq 'get.helm.sh' "$SCRIPT"
}

@test "secret_set (keychain): tolerates unset USER under set -u and uses -U" {
    run bash -c '
        source "$1"
        set -u
        SECRET_BACKEND=keychain
        security() { printf "security %s\n" "$*"; }
        unset USER LOGNAME
        secret_set sumologic_access_id mysecret
    ' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *" -U "* ]]
    [[ "$output" == *"-s sumologic_access_id"* ]]
    # The account passed to -a must be non-empty (USER/LOGNAME fell back to id -un).
    printf '%s\n' "$output" | grep -Eq -- '-a [^[:space:]]+'
}
