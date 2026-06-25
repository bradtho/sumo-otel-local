#!/usr/bin/env bats
# Flow tests: drive the action functions against stubbed external commands.

setup() {
    load "test_helper"
    load_script
    setup_stubs
    # Replace externals + heavy helpers with recording/no-op stubs.
    require_cmd() { :; }
    select_runtime() { return 0; }
    set_kind_provider() { :; }
    ensure_helm_repo() { :; }
    secret_get() { printf 'STORED'; }
    kind() { echo "kind $*" >>"$CALLS"; }
    podman() { echo "podman $*" >>"$CALLS"; }
    secret_delete() {
        echo "secret_delete $1" >>"$CALLS"
        return 0
    }
}

# --- confirm_destructive ----------------------------------------------------

@test "confirm_destructive: --force proceeds and sets the default cluster name" {
    FORCE=yes ASSUME_YES=""
    run confirm_destructive "delete the cluster"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--force"* ]]
}

@test "confirm_destructive: ASSUME_YES without --force refuses (exit 1)" {
    FORCE="" ASSUME_YES=yes
    run confirm_destructive "delete the cluster"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Refusing"* ]]
}

# --- uninstall --------------------------------------------------------------

@test "uninstall: -y without --force refuses and does NOT delete" {
    ASSUME_YES=yes FORCE="" run uninstall
    [ "$status" -eq 1 ]
    refute_called '^kind delete'
}

@test "uninstall: --force deletes the cluster" {
    ASSUME_YES="" FORCE=yes run uninstall
    [ "$status" -eq 0 ]
    assert_called '^kind delete cluster --name sumo'
}

@test "uninstall: interactive 'no' cancels without deleting" {
    run bash -c 'source "$1"; require_cmd(){ :;}; select_runtime(){ return 0;}; set_kind_provider(){ :;}
        kind(){ echo CALLED_KIND; }; ASSUME_YES=""; FORCE=""; uninstall <<<"n"' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" != *"CALLED_KIND"* ]]
}

# --- purge ------------------------------------------------------------------

@test "purge: -y without --force refuses, deleting neither cluster nor secrets" {
    ASSUME_YES=yes FORCE="" run purge
    [ "$status" -eq 1 ]
    refute_called '^kind delete'
    refute_called '^secret_delete'
}

@test "purge: --force deletes the cluster and clears stored credentials" {
    ASSUME_YES="" FORCE=yes run purge
    [ "$status" -eq 0 ]
    assert_called '^kind delete cluster --name sumo'
    assert_called '^secret_delete sumologic_access_id'
    assert_called '^secret_delete sumologic_access_key'
}

# --- install_sumo / output arg-building (run in a subshell to contain their
#     EXIT trap so it cannot interfere with bats teardown) --------------------

@test "install_sumo: passes pinned chart version, clusterName, and shared overrides" {
    run bash -c 'source "$1"; require_cmd(){ :;}; ensure_helm_repo(){ :;}; secret_get(){ printf STORED;}
        helm(){ printf "HELM %s\n" "$*"; }; ASSUME_YES=yes; install_sumo' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--version 5.2.0"* ]]
    [[ "$output" == *"sumologic.clusterName=sumo"* ]]
    [[ "$output" == *"fullnameOverride=sumo"* ]]
    [[ "$output" == *"sumologic.falco.enabled=false"* ]]
    [[ "$output" == *"sumologic.logs.systemd.enabled=false"* ]]
}

@test "install_sumo: credentials never appear on the helm command line" {
    run bash -c 'source "$1"; require_cmd(){ :;}; ensure_helm_repo(){ :;}; secret_get(){ printf SECRETVALUE;}
        helm(){ printf "HELM %s\n" "$*"; }; ASSUME_YES=yes; install_sumo' _ "$SCRIPT"
    [[ "$output" != *"SECRETVALUE"* ]]
    [[ "$output" != *"accessId"* ]]
}

@test "output: mirrors install (version + clusterName + overrides) with placeholder creds off-argv" {
    # Capture helm's argv to a file (via a closure) so the assertion doesn't depend on
    # the `helm | tee` pipe's stdout, which behaves differently across platforms.
    local cap="${BATS_TEST_TMPDIR}/helm_args"
    run bash -c 'source "$1"; cap="$2"; require_cmd(){ :;}; ensure_helm_repo(){ :;}; tee(){ cat >/dev/null;}
        helm(){ printf "%s\n" "$*" >"$cap"; }; ASSUME_YES=yes; output' _ "$SCRIPT" "$cap"
    [ "$status" -eq 0 ]
    run cat "$cap"
    [[ "$output" == *"template sumologic sumologic/sumologic"* ]]
    [[ "$output" == *"--version 5.2.0"* ]]
    [[ "$output" == *"sumologic.clusterName=sumo"* ]]
    [[ "$output" == *"fullnameOverride=sumo"* ]]
    [[ "$output" != *"PLACEHOLDER_ACCESS"* ]]
}

# --- select_runtime ---------------------------------------------------------

@test "select_runtime: honours a preset CONTAINER_RUNTIME=docker" {
    stub_cmd docker
    CONTAINER_RUNTIME=docker
    run select_runtime
    [ "$status" -eq 0 ]
}
