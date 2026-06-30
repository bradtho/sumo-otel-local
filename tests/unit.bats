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

@test "read_secret: stdout is exactly the entered value (no prompt/warning leakage)" {
    # Two empty lines then the value; stderr discarded so $output is the captured stdout.
    run bash -c 'source "$1"; printf "\n\nhunter2\n" | read_secret "PW: " 2>/dev/null' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$output" = "hunter2" ]
}

@test "read_secret: re-prompts on empty input (warning goes to stderr)" {
    # stdout discarded so $output is stderr: the empty-value warning must appear there.
    run bash -c 'source "$1"; printf "\nhunter2\n" | read_secret "PW: " 1>/dev/null' _ "$SCRIPT"
    [[ "$output" == *"cannot be empty"* ]]
}

@test "read_secret: aborts on EOF/closed stdin instead of looping forever" {
    run bash -c 'source "$1"; read_secret "PW: " </dev/null' _ "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"stdin closed"* ]]
}

@test "ask: EOF/closed stdin falls back to the default without aborting (note on stderr)" {
    # Captured via $() under set -e: an unguarded read would fail and abort the caller.
    run bash -c 'source "$1"; set -Eeuo pipefail; trap "echo ERR_TRAP" ERR; ASSUME_YES=""
        val=$(ask "name? " "sumo" </dev/null); echo "VAL=$val"' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"VAL=sumo"* ]]     # returned the default
    [[ "$output" != *"ERR_TRAP"* ]]     # did not trip the ERR trap
    [[ "$output" == *"stdin closed"* ]] # noted the fallback
}

@test "confirm: EOF/closed stdin uses the default (n->no, y->yes), no abort" {
    run bash -c 'source "$1"; set -Eeuo pipefail; ASSUME_YES=""; confirm "ok?" n </dev/null' _ "$SCRIPT"
    [ "$status" -eq 1 ] # default n -> rejected
    run bash -c 'source "$1"; set -Eeuo pipefail; ASSUME_YES=""; confirm "ok?" y </dev/null' _ "$SCRIPT"
    [ "$status" -eq 0 ] # default y -> accepted
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

@test "KINDEST_NODE_IMAGE: digest-pinned by default; version+digest overridable; empty digest opts out" {
    # One subshell per case so the env overrides don't leak; assert the combined marker as a
    # single last command (every check load-bearing on macOS bats too).
    run bash -c '
        src="$1"
        d=$(source "$src"; echo "$KINDEST_NODE_IMAGE")
        b=$(KINDEST_NODE_VERSION=v1.35.5 KINDEST_NODE_DIGEST=sha256:ce97; source "$src"; echo "$KINDEST_NODE_IMAGE")
        c=$(KINDEST_NODE_VERSION=v1.35.5 KINDEST_NODE_DIGEST=; source "$src"; echo "$KINDEST_NODE_IMAGE")
        printf "DEFAULT=[%s] BOTH=[%s] CLEAR=[%s]" "$d" "$b" "$c"
    ' _ "$SCRIPT"
    [[ "$output" == *"DEFAULT=[kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5]"* ]] \
        && [[ "$output" == *"BOTH=[kindest/node:v1.35.5@sha256:ce97]"* ]] \
        && [[ "$output" == *"CLEAR=[kindest/node:v1.35.5]"* ]] # empty digest -> tag-only, no mismatch
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
