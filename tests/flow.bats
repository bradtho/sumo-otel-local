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

# --- shared teardown skeleton (prepare_teardown / delete_kind_cluster) -------
# uninstall and purge share a preamble (require_cmd kind -> select_runtime ->
# set_kind_provider) and the kind-delete step; guard that the extraction didn't drop
# or reorder a preamble step, and that a runtime-selection failure still aborts cleanly.

@test "prepare_teardown: uninstall runs the full preamble before the kind delete" {
    # Record the preamble steps (setup stubs them as silent no-ops) so a dropped step shows.
    require_cmd() { echo "require_cmd $*" >>"$CALLS"; }
    select_runtime() {
        echo "select_runtime" >>"$CALLS"
        return 0
    }
    set_kind_provider() { echo "set_kind_provider" >>"$CALLS"; }
    FORCE=yes ASSUME_YES="" run uninstall
    # Chained so each step is load-bearing on macOS bats (only a test's last command counts).
    [ "$status" -eq 0 ] && assert_called '^require_cmd kind' && assert_called '^select_runtime' \
        && assert_called '^set_kind_provider' && assert_called '^kind delete cluster --name sumo'
}

@test "prepare_teardown: a select_runtime failure aborts before deleting (no kind delete)" {
    run bash -c 'source "$1"; require_cmd(){ :;}; set_kind_provider(){ :;}
        select_runtime(){ return 1; }            # runtime cannot be selected
        kind(){ echo CALLED_KIND; }; FORCE=yes; ASSUME_YES=""; uninstall' _ "$SCRIPT"
    # Combined (load-bearing last command): clean exit 1 AND nothing was deleted.
    [[ "$output" != *"CALLED_KIND"* ]] && [ "$status" -eq 1 ]
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
    # Final, combined assertion so BOTH halves are load-bearing on macOS bats (which only
    # checks a test's last command): the context is pinned to the named cluster AND the
    # resolved values file (blank prompt -> bundled values.yaml) actually reaches the argv,
    # ahead of the secrets --values. The latter guards the prompt_values_file extraction —
    # a dropped helper would leave only the secrets --values.
    [[ "$output" == *"--kube-context kind-sumo"* && "$output" == *"values.yaml --values "* ]]
}

@test "install_sumo: interactive prompt order is stable (values -> cluster -> repo-update -> wait)" {
    # Pins the confirm/ask call ORDER + COUNT so reordering, adding, or dropping a prompt is
    # caught (the testing-seam finding's option-(a) deliverable). The stubs map prompt
    # substring -> a short tag recorded to a marker FILE (survives the $(...) subshells `ask`
    # runs in); any unmapped prompt records "UNEXPECTED-…" and breaks the exact match.
    local rec="${BATS_TEST_TMPDIR}/prompts"
    run bash -c 'source "$1"; rec="$2"; trap - ERR EXIT
        secret_get(){ printf STORED; }     # creds already stored -> no read_secret prompts
        require_values_file(){ :; }; ensure_helm_repo(){ :; }; select_chart_version(){ printf 5.2.0; }; helm(){ :; }
        ask(){ case "$1" in
                 *"Helm values file"*)    echo values  >>"$rec";;
                 *"Name of the cluster"*) echo cluster >>"$rec";;
                 *) echo "UNEXPECTED-ASK[$1]" >>"$rec";;
               esac; printf "%s" "$2"; }
        confirm(){ case "$1" in
                     *"repo updates"*)           echo repo-update >>"$rec";;
                     *"Wait for the collector"*) echo wait        >>"$rec";;
                     *) echo "UNEXPECTED-CONFIRM[$1]" >>"$rec";;
                   esac; return 0; }
        install_sumo >/dev/null 2>&1; rc=$?
        paste -sd" " "$rec"        # one-line ordered signature of the prompts
        exit $rc' _ "$SCRIPT" "$rec"
    # Exact ordered sequence (and count) of the four prompts, asserted as one last command.
    [ "$status" -eq 0 ] && [ "$output" = "values cluster repo-update wait" ]
}

@test "install_sumo: credentials never appear on the helm command line" {
    run bash -c 'source "$1"; require_cmd(){ :;}; ensure_helm_repo(){ :;}; secret_get(){ printf SECRETVALUE;}
        helm(){ printf "HELM %s\n" "$*"; }; ASSUME_YES=yes; install_sumo' _ "$SCRIPT"
    [[ "$output" != *"SECRETVALUE"* ]]
    [[ "$output" != *"accessId"* ]]
}

@test "install_sumo: on success appends --wait and prints copy-paste next steps" {
    run bash -c 'source "$1"; require_cmd(){ :;}; ensure_helm_repo(){ :;}; secret_get(){ printf STORED;}; select_chart_version(){ printf 5.2.0;}
        helm(){ printf "HELM %s\n" "$*"; }; ASSUME_YES=yes; install_sumo' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--wait --timeout 10m"* ]]
    [[ "$output" == *"Next steps:"* ]]
    [[ "$output" == *"app.kubernetes.io/name=sumo-otelcol-logs-collector"* ]]
}

@test "install_sumo: declining the wait omits --wait" {
    run bash -c 'source "$1"; require_cmd(){ :;}; ensure_helm_repo(){ :;}; secret_get(){ printf STORED;}; select_chart_version(){ printf 5.2.0;}
        confirm(){ return 1; }; helm(){ printf "HELM %s\n" "$*"; }; ASSUME_YES=""; install_sumo </dev/null' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" != *"--wait"* ]]
}

@test "install_sumo: a failed install hints at -s without tripping the ERR trap or printing next steps" {
    run bash -c 'source "$1"; set -Eeuo pipefail; trap "echo TRAP_FIRED" ERR
        require_cmd(){ :;}; ensure_helm_repo(){ :;}; secret_get(){ printf STORED;}; select_chart_version(){ printf 5.2.0;}
        helm(){ return 1; }; ASSUME_YES=yes; install_sumo' _ "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" != *"TRAP_FIRED"* ]]
    [[ "$output" == *"did not complete"* ]]
    [[ "$output" != *"Next steps"* ]]
}

# --- --dry-run / --verbose (install flow) -----------------------------------

@test "install_sumo --dry-run: previews the helm command and installs nothing" {
    run bash -c 'source "$1"; require_cmd(){ :;}; ensure_helm_repo(){ :;}; secret_get(){ printf S;}; select_chart_version(){ printf 5.2.0;}
        helm(){ echo HELM_RAN; }; DRY_RUN=yes; ASSUME_YES=yes; install_sumo' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[dry-run] would run: helm upgrade --install"* ]]
    [[ "$output" == *"--dry-run"* ]]  # helm's own dry-run appended to the previewed command
    [[ "$output" != *"Next steps"* ]] # success path skipped
    [[ "$output" != *"HELM_RAN"* ]]   # real helm never executed (asserted last)
}

@test "install_sumo --verbose: echoes the helm command before running it" {
    run bash -c 'source "$1"; require_cmd(){ :;}; ensure_helm_repo(){ :;}; secret_get(){ printf S;}; select_chart_version(){ printf 5.2.0;}
        helm(){ echo HELM_RAN; }; VERBOSE=yes; ASSUME_YES=yes; install_sumo' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"+ helm upgrade --install"* ]] # echoed
    [[ "$output" == *"HELM_RAN"* ]]                 # and actually run
}

@test "init_cluster --dry-run: previews the kind create without touching the runtime or creating a cluster" {
    # No runtime stubs on purpose: the dry-run early-return must skip select_runtime /
    # ensure_*_ready entirely. If it regressed, the REAL select_runtime would run here.
    run bash -c 'source "$1"; kind(){ echo "KIND_RAN $*"; }; DRY_RUN=yes; ASSUME_YES=yes; init_cluster' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    # No real cluster created AND the preview shows the digest-pinned node image (combined so
    # both are load-bearing on macOS bats).
    [[ "$output" != *"KIND_RAN"* ]] \
        && [[ "$output" == *"[dry-run] would run: kind create"*"--image kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5"* ]]
}

@test "init_cluster: the default-yes create uses the digest-pinned node image" {
    run bash -c 'source "$1"; trap - ERR EXIT
        select_runtime(){ CONTAINER_RUNTIME=docker; return 0; }
        set_kind_provider(){ :; }; ensure_docker_ready(){ :; }
        cluster_exists(){ return 1; }        # no existing cluster -> straight to create
        kind(){ echo "kind $*"; }            # capture the create argv
        ASSUME_YES=yes; init_cluster' _ "$SCRIPT"
    [ "$status" -eq 0 ] \
        && [[ "$output" == *"kind create cluster --name sumo --config"*"--image kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5"* ]]
}

@test "uninstall --verbose echoes the kind delete before running it" {
    run bash -c 'source "$1"; require_cmd(){ :;}; select_runtime(){ CONTAINER_RUNTIME=docker; return 0; }; set_kind_provider(){ :; }
        kind(){ echo KIND_RAN; }; VERBOSE=yes; FORCE=yes; uninstall' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"KIND_RAN"* ]]                          # real delete still runs
    [[ "$output" == *"+ kind delete cluster --name sumo"* ]] # ...and is echoed under --verbose
}

# --- reinstall (uninstall the release, then install_sumo) -------------------

@test "reinstall: declining the confirm aborts without uninstalling or installing" {
    run bash -c 'source "$1"; require_cmd(){ :;}; install_sumo(){ echo INSTALL_RAN; }
        confirm(){ return 1; }; helm(){ echo "HELM $*"; }
        ASSUME_YES=""; reinstall </dev/null' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cancelled"* ]]
    [[ "$output" != *"HELM"* ]]        # no helm status/uninstall ran
    [[ "$output" != *"INSTALL_RAN"* ]]
}

@test "reinstall: the real confirm defaults to NO on EOF (drives confirm, not a stub)" {
    # Exercises the real `confirm "..." n`: closed stdin + no -y -> default no -> cancel.
    # The stubbed test above can't catch a default-no -> default-yes regression.
    run bash -c 'source "$1"; require_cmd(){ :;}; install_sumo(){ echo INSTALL_RAN; }
        helm(){ echo "HELM $*"; }; ASSUME_YES=""; reinstall </dev/null' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" != *"INSTALL_RAN"* ]] # default-no path: never reinstalls
    [[ "$output" != *"HELM"* ]]
}

@test "reinstall: an existing release is uninstalled (context-pinned), then install_sumo runs" {
    # Match on $* (not $1) since the call is now `helm --kube-context kind-<c> uninstall ...`.
    run bash -c 'source "$1"; require_cmd(){ :;}; install_sumo(){ echo INSTALL_RAN; }
        helm(){ case "$*" in *"status sumologic"*) return 0;; *"uninstall sumologic"*) echo "UNINST $*";; esac; }
        ASSUME_YES=yes; reinstall' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"UNINST --kube-context kind-sumo uninstall sumologic"* ]] # uninstall pins the context
    [[ "$output" == *"INSTALL_RAN"* ]]
}

@test "reinstall: a stuck uninstall errors with the finalizer hint and skips reinstall" {
    run bash -c 'source "$1"; set -Eeuo pipefail; trap "echo ERR_TRAP" ERR; require_cmd(){ :;}; install_sumo(){ echo INSTALL_RAN; }
        helm(){ case "$*" in *"status sumologic"*) return 0;; *"uninstall sumologic"*) return 1;; esac; }
        ASSUME_YES=yes; reinstall' _ "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"finaliser"* ]]   # matches examples/README.md's "## Finalisers" (UK spelling)
    [[ "$output" != *"ERR_TRAP"* ]]    # exit 1 (not return 1) -> no bare-dispatch on_error
    [[ "$output" != *"INSTALL_RAN"* ]] # reinstall skipped after the failed uninstall
}

@test "reinstall: no existing release proceeds straight to a fresh install" {
    run bash -c 'source "$1"; require_cmd(){ :;}; install_sumo(){ echo INSTALL_RAN; }
        helm(){ case "$*" in *"status sumologic"*) return 1;; *"uninstall sumologic"*) echo "UNINST $*";; esac; }
        ASSUME_YES=yes; reinstall' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" != *"UNINST"* ]]       # nothing to uninstall
    [[ "$output" == *"INSTALL_RAN"* ]]  # proceeded to a fresh install
    [[ "$output" == *"No active"* ]]    # the hedged "no release / maybe unreachable" message (asserted last)
}

# NB: helm's stdout is piped into `| tee`, so a `helm(){ echo MARKER;}` stub's output
# never reaches $output. Signal "helm ran" by writing a marker FILE via redirection
# (survives the pipe), mirroring the arg-capture test below. (Asserting on $output here
# would silently pass under macOS's bats, which only checks a test's last command, yet
# fail under Linux's bats, which fails on any command.)
@test "output: declining the overwrite of an existing render aborts before rendering" {
    local kfile="${BATS_TEST_TMPDIR}/out.yaml" ran="${BATS_TEST_TMPDIR}/helm_ran"
    : >"$kfile" # pre-existing render
    run bash -c 'source "$1"; kfile="$2"; ran="$3"
        require_cmd(){ :;}; require_values_file(){ :;}
        ensure_helm_repo(){ :;}; select_chart_version(){ printf 5.2.0;}
        ask(){ case "$1" in *Manifest*) printf "%s" "$kfile";; *) printf "";; esac; }
        confirm(){ return 1; }       # user declines the overwrite
        tee(){ cat >/dev/null;}; helm(){ echo ran >"$ran";}
        ASSUME_YES=""; output </dev/null' _ "$SCRIPT" "$kfile" "$ran"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Aborted"* ]]
    [ ! -e "$ran" ] # aborted before helm ran (no clobbering work)
}

@test "output: -y/ASSUME_YES auto-overwrites an existing render (regenerable artifact)" {
    local kfile="${BATS_TEST_TMPDIR}/out.yaml" ran="${BATS_TEST_TMPDIR}/helm_ran"
    : >"$kfile" # pre-existing render
    run bash -c 'source "$1"; kfile="$2"; ran="$3"
        require_cmd(){ :;}; require_values_file(){ :;}; ensure_helm_repo(){ :;}; select_chart_version(){ printf 5.2.0;}
        ask(){ case "$1" in *Manifest*) printf "%s" "$kfile";; *) printf "";; esac; }
        tee(){ cat >/dev/null;}; helm(){ echo ran >"$ran";}
        ASSUME_YES=yes; output' _ "$SCRIPT" "$kfile" "$ran"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Aborted"* ]]
    [ -s "$ran" ] # render proceeded (helm ran) -> -y auto-overwrote
}

@test "output: no overwrite prompt when the target file does not exist" {
    local kfile="${BATS_TEST_TMPDIR}/new.yaml" ran="${BATS_TEST_TMPDIR}/helm_ran" # kfile does NOT exist
    run bash -c 'source "$1"; kfile="$2"; ran="$3"
        require_cmd(){ :;}; require_values_file(){ :;}; ensure_helm_repo(){ :;}; select_chart_version(){ printf 5.2.0;}
        ask(){ case "$1" in *Manifest*) printf "%s" "$kfile";; *) printf "";; esac; }
        confirm(){ echo CONFIRM_CALLED; return 0;}
        tee(){ cat >/dev/null;}; helm(){ echo ran >"$ran";}
        ASSUME_YES=""; output </dev/null' _ "$SCRIPT" "$kfile" "$ran"
    [ "$status" -eq 0 ]
    [[ "$output" != *"CONFIRM_CALLED"* ]] # the `-e` short-circuit skips confirm entirely
    [ -s "$ran" ]                         # render still proceeded
}

@test "output: a missing target directory fails fast before rendering" {
    local kfile="${BATS_TEST_TMPDIR}/nope/out.yaml" ran="${BATS_TEST_TMPDIR}/helm_ran" # parent dir absent
    run bash -c 'source "$1"; kfile="$2"; ran="$3"
        require_cmd(){ :;}; require_values_file(){ :;}; ensure_helm_repo(){ echo REPO_RAN;}; select_chart_version(){ printf 5.2.0;}
        ask(){ case "$1" in *Manifest*) printf "%s" "$kfile";; *) printf "";; esac; }
        tee(){ cat >/dev/null;}; helm(){ echo ran >"$ran";}
        ASSUME_YES=yes; output' _ "$SCRIPT" "$kfile" "$ran"
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not exist"* ]]
    [[ "$output" != *"REPO_RAN"* ]] # bailed before the helm repo / render work
    [ ! -e "$ran" ]                 # helm never ran
}

@test "output: a write (tee) failure is reported clearly, not via the ERR trap" {
    local kfile="${BATS_TEST_TMPDIR}/out.yaml" ran="${BATS_TEST_TMPDIR}/helm_ran"
    run bash -c 'source "$1"; set -Eeuo pipefail; trap "echo ERR_TRAP" ERR
        kfile="$2"; ran="$3"
        require_cmd(){ :;}; require_values_file(){ :;}; ensure_helm_repo(){ :;}; select_chart_version(){ printf 5.2.0;}
        ask(){ case "$1" in *Manifest*) printf "%s" "$kfile";; *) printf "";; esac; }
        tee(){ cat >/dev/null; return 1;}; helm(){ echo ran >"$ran";}
        ASSUME_YES=yes; output' _ "$SCRIPT" "$kfile" "$ran"
    [ "$status" -eq 1 ]
    [[ "$output" == *"failed to write"* ]] # PIPESTATUS distinguishes the write half
    [[ "$output" != *"ERR_TRAP"* ]]        # handled gracefully (pipeline in an `if` is errexit-exempt)
    [ ! -e "$kfile" ]                      # target never created (render goes to a temp; mv skipped on failure)
}

@test "output: a helm render failure is reported distinctly from a write failure" {
    local kfile="${BATS_TEST_TMPDIR}/out.yaml"
    run bash -c 'source "$1"; set -Eeuo pipefail; trap "echo ERR_TRAP" ERR
        kfile="$2"
        require_cmd(){ :;}; require_values_file(){ :;}; ensure_helm_repo(){ :;}; select_chart_version(){ printf 5.2.0;}
        ask(){ case "$1" in *Manifest*) printf "%s" "$kfile";; *) printf "";; esac; }
        tee(){ cat >/dev/null;}; helm(){ return 1;}
        ASSUME_YES=yes; output' _ "$SCRIPT" "$kfile"
    [ "$status" -eq 1 ]
    [[ "$output" == *"helm failed to render"* ]] # PIPESTATUS[0] != 0 -> render half
    [[ "$output" != *"ERR_TRAP"* ]]
    [ ! -e "$kfile" ]                            # target never created
}

@test "output: a failed render leaves an existing file untouched (atomic write)" {
    local kfile="${BATS_TEST_TMPDIR}/out.yaml"
    printf 'OLD CONTENT\n' >"$kfile" # a prior good render
    run bash -c 'source "$1"; set -Eeuo pipefail; trap "echo ERR_TRAP" ERR; kfile="$2"
        require_cmd(){ :;}; require_values_file(){ :;}; ensure_helm_repo(){ :;}; select_chart_version(){ printf 5.2.0;}
        ask(){ case "$1" in *Manifest*) printf "%s" "$kfile";; *) printf "";; esac; }
        confirm(){ return 0;}                      # accept overwriting the existing file
        tee(){ cat >/dev/null;}; helm(){ echo PARTIAL; return 1;}
        ASSUME_YES=""; output </dev/null' _ "$SCRIPT" "$kfile"
    [ "$status" -eq 1 ]
    [[ "$output" == *"left unchanged"* ]]
    run cat "$kfile"
    [ "$output" = "OLD CONTENT" ] # render failed -> prior content preserved (mv never ran)
    # The temp must be cleaned on the failure path too (EXIT trap); regression guard for a
    # `local render_tmp` that the global-scope EXIT trap couldn't see and so leaked.
    run bash -c 'ls "$1"/.sumo-render.* 2>/dev/null | wc -l | tr -d " "' _ "$BATS_TEST_TMPDIR"
    [ "$output" = "0" ]
}

@test "output: a successful render is moved into place atomically, no leftover temp" {
    local kfile="${BATS_TEST_TMPDIR}/out.yaml"
    run bash -c 'source "$1"; kfile="$2"
        require_cmd(){ :;}; require_values_file(){ :;}; ensure_helm_repo(){ :;}; select_chart_version(){ printf 5.2.0;}
        ask(){ case "$1" in *Manifest*) printf "%s" "$kfile";; *) printf "";; esac; }
        tee(){ cat >"$1";}; helm(){ echo RENDERED_MANIFEST;}
        ASSUME_YES=yes; output' _ "$SCRIPT" "$kfile"
    [ "$status" -eq 0 ]
    run cat "$kfile"
    [ "$output" = "RENDERED_MANIFEST" ] # temp content mv'd into the target
    run bash -c 'ls "$1"/.sumo-render.* 2>/dev/null | wc -l | tr -d " "' _ "$BATS_TEST_TMPDIR"
    [ "$output" = "0" ]                 # same-dir temp was moved, none left behind
}

@test "output: rejects a target that is an existing directory" {
    local adir="${BATS_TEST_TMPDIR}/adir"
    mkdir -p "$adir"
    run bash -c 'source "$1"; adir="$2"
        require_cmd(){ :;}; require_values_file(){ :;}; ensure_helm_repo(){ echo REPO_RAN;}; select_chart_version(){ printf 5.2.0;}
        ask(){ case "$1" in *Manifest*) printf "%s" "$adir";; *) printf "";; esac; }
        tee(){ cat >/dev/null;}; helm(){ echo X;}
        ASSUME_YES=yes; output' _ "$SCRIPT" "$adir"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is an existing directory"* ]]
    [[ "$output" != *"REPO_RAN"* ]] # rejected before any helm work (the atomic mv would move INTO it)
}

@test "output: a successful render atomically replaces a pre-existing file's contents" {
    local kfile="${BATS_TEST_TMPDIR}/out.yaml"
    printf 'STALE\n' >"$kfile"
    run bash -c 'source "$1"; kfile="$2"
        require_cmd(){ :;}; require_values_file(){ :;}; ensure_helm_repo(){ :;}; select_chart_version(){ printf 5.2.0;}
        ask(){ case "$1" in *Manifest*) printf "%s" "$kfile";; *) printf "";; esac; }
        confirm(){ return 0;}; tee(){ cat >"$1";}; helm(){ echo FRESH_RENDER;}
        ASSUME_YES=""; output </dev/null' _ "$SCRIPT" "$kfile"
    [ "$status" -eq 0 ]
    run cat "$kfile"
    [ "$output" = "FRESH_RENDER" ] # stale content fully replaced by the mv
}

@test "output: a failed mv reports clearly, leaves the prior file and no temp" {
    local kfile="${BATS_TEST_TMPDIR}/out.yaml"
    printf 'PRIOR\n' >"$kfile"
    run bash -c 'source "$1"; set -Eeuo pipefail; trap "echo ERR_TRAP" ERR; kfile="$2"
        require_cmd(){ :;}; require_values_file(){ :;}; ensure_helm_repo(){ :;}; select_chart_version(){ printf 5.2.0;}
        ask(){ case "$1" in *Manifest*) printf "%s" "$kfile";; *) printf "";; esac; }
        confirm(){ return 0;}; mv(){ return 1;}; tee(){ cat >"$1";}; helm(){ echo NEW;}
        ASSUME_YES=""; output </dev/null' _ "$SCRIPT" "$kfile"
    [ "$status" -eq 1 ]
    [[ "$output" == *"left unchanged"* ]]
    [[ "$output" != *"ERR_TRAP"* ]]
    run cat "$kfile"
    [ "$output" = "PRIOR" ] # mv failed -> prior content intact
    run bash -c 'ls "$1"/.sumo-render.* 2>/dev/null | wc -l | tr -d " "' _ "$BATS_TEST_TMPDIR"
    [ "$output" = "0" ] # temp cleaned even on the mv-failure path
}

@test "output: a helm failure is caught even with pipefail off (PIPESTATUS[0], not tee's status)" {
    local kfile="${BATS_TEST_TMPDIR}/out.yaml"
    run bash -c 'source "$1"; set -Eeuo pipefail; set +o pipefail; trap "echo ERR_TRAP" ERR; kfile="$2"
        require_cmd(){ :;}; require_values_file(){ :;}; ensure_helm_repo(){ :;}; select_chart_version(){ printf 5.2.0;}
        ask(){ case "$1" in *Manifest*) printf "%s" "$kfile";; *) printf "";; esac; }
        tee(){ cat >/dev/null;}; helm(){ echo GARBAGE; return 1;}
        ASSUME_YES=yes; output' _ "$SCRIPT" "$kfile"
    [ "$status" -eq 1 ]
    [[ "$output" == *"helm failed to render"* ]]
    [ ! -e "$kfile" ] # garbage tee output never promoted to the target
}

@test "output: a temp-file creation failure reports clearly, not via the ERR trap" {
    local kfile="${BATS_TEST_TMPDIR}/out.yaml"
    run bash -c 'source "$1"; set -Eeuo pipefail; trap "echo ERR_TRAP" ERR; kfile="$2"
        require_cmd(){ :;}; require_values_file(){ :;}; ensure_helm_repo(){ :;}; select_chart_version(){ printf 5.2.0;}
        ask(){ case "$1" in *Manifest*) printf "%s" "$kfile";; *) printf "";; esac; }
        mktemp(){ case "$*" in *sumo-render*) return 1;; *) command mktemp "$@";; esac; }
        tee(){ cat >/dev/null;}; helm(){ echo X;}
        ASSUME_YES=yes; output' _ "$SCRIPT" "$kfile"
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot create a temporary file"* ]]
    [[ "$output" != *"ERR_TRAP"* ]]
}

@test "output: mirrors install (version + clusterName + overrides) with placeholder creds off-argv" {
    # Capture helm's argv to a file (via a closure) so the assertion doesn't depend on
    # the `helm | tee` pipe's stdout, which behaves differently across platforms. K8S_YAML
    # points into the test tmpdir so the atomic mv stays hermetic (no file in the cwd).
    local cap="${BATS_TEST_TMPDIR}/helm_args" kfile="${BATS_TEST_TMPDIR}/out.yaml"
    run bash -c 'source "$1"; cap="$2"; kfile="$3"
        require_cmd(){ :;}; require_values_file(){ :;}; ensure_helm_repo(){ :;}; select_chart_version(){ printf 5.2.0;}
        ask(){ case "$1" in *Manifest*) printf "%s" "$kfile";; *cluster*) printf sumo;; *) printf "";; esac; }
        tee(){ cat >/dev/null;}
        helm(){ printf "%s\n" "$*" >"$cap"; }; ASSUME_YES=yes; output' _ "$SCRIPT" "$cap" "$kfile"
    [ "$status" -eq 0 ]
    run cat "$cap"
    [[ "$output" == *"template sumologic sumologic/sumologic"* ]]
    [[ "$output" == *"--version 5.2.0"* ]]
    [[ "$output" == *"sumologic.clusterName=sumo"* ]]
    [[ "$output" == *"fullnameOverride=sumo"* ]]
    # Final, combined assertion so BOTH halves are load-bearing on macOS bats: the resolved
    # values file reaches the template argv ahead of secrets, AND creds never appear on argv.
    [[ "$output" == *"values.yaml --values "* && "$output" != *"PLACEHOLDER_ACCESS"* ]]
}

# --- prompt_values_file (shared helper for install_sumo + output) -----------
# Extracted from the duplicated prompt-and-default block: prompt -> bundled-default
# fallback -> validate, printing the resolved path to stdout (UI via `ask` -> stderr).
# A bad named path makes require_values_file exit non-zero so the caller's `|| exit 1`
# turns it into a clean script exit. NB: the function has a `local vf`, so the ask
# stubs use a distinctly-named VF_IN to avoid a dynamic-scoping collision.

# Tests 1-3 capture both the returned value AND `rc=$?` into the marker, then assert
# the combined `RESULT=[…] RC=[…]` as the single LAST command — so the success path is
# load-bearing on macOS bats too (which only checks a test's last command). A bare
# `[ "$status" -eq 0 ]` would be inert here: strict mode is off when sourced, so a
# failing helper still lets the trailing printf run and the wrapper exits 0.

@test "prompt_values_file: an explicit path is returned (and validated)" {
    local vf="${BATS_TEST_TMPDIR}/my-values.yaml"
    : >"$vf" # exists + readable, so the REAL require_values_file passes
    run bash -c 'source "$1"; VF_IN="$2"
        ask(){ printf "%s" "$VF_IN"; }   # user types an explicit path
        out=$(prompt_values_file); rc=$?; printf "RESULT=[%s] RC=[%s]" "$out" "$rc"' _ "$SCRIPT" "$vf"
    [[ "$output" == *"RESULT=[${vf}] RC=[0]"* ]]
}

@test "prompt_values_file: blank input falls back to the bundled default when it exists" {
    local def="${BATS_TEST_TMPDIR}/default-values.yaml"
    : >"$def"
    run bash -c 'source "$1"; def="$2"
        DEFAULT_HELM_VALUES="$def"
        ask(){ printf ""; }              # blank (Enter)
        out=$(prompt_values_file); rc=$?; printf "RESULT=[%s] RC=[%s]" "$out" "$rc"' _ "$SCRIPT" "$def"
    [[ "$output" == *"RESULT=[${def}] RC=[0]"* ]]
}

@test "prompt_values_file: blank input with no default yields an empty (skip) result" {
    run bash -c 'source "$1"
        DEFAULT_HELM_VALUES="/no/such/default.yaml"
        ask(){ printf ""; }
        out=$(prompt_values_file); rc=$?; printf "RESULT=[%s] RC=[%s]" "$out" "$rc"' _ "$SCRIPT"
    [[ "$output" == *"RESULT=[] RC=[0]"* ]] # empty + success -> chart installs with --set values alone
}

@test "prompt_values_file: a preset HELM_VALUES (env/config knob) threads through on EOF/unattended" {
    # Regression guard that the `\${HELM_VALUES:-}` default is still passed to `ask` (a mutant
    # dropping it silently skips the preset file). Drives the REAL ask via closed stdin.
    local pre="${BATS_TEST_TMPDIR}/preset.yaml"
    : >"$pre"
    run bash -c 'source "$1"; HELM_VALUES="$2"; DEFAULT_HELM_VALUES="/no/such/default.yaml"
        out=$(prompt_values_file </dev/null); rc=$?; printf "RESULT=[%s] RC=[%s]" "$out" "$rc"' _ "$SCRIPT" "$pre"
    [[ "$output" == *"RESULT=[${pre}] RC=[0]"* ]] # preset returned, not skipped
}

@test "prompt_values_file: a named-but-missing path exits non-zero with a clear error" {
    run bash -c 'source "$1"
        ask(){ printf "%s" "/no/such/file.yaml"; }   # uses the REAL require_values_file
        prompt_values_file' _ "$SCRIPT"
    # Combined so both halves are load-bearing on macOS bats: the clear "not found" message
    # AND the non-zero exit (which the caller's `|| exit 1` turns into a clean script exit).
    [[ "$output" == *"not found"* ]] && [ "$status" -ne 0 ]
}

# --- status (read-only doctor; every probe must be non-fatal under errexit) -

# Run status() the way main does — under `set -Eeuo pipefail` with the ERR trap — but
# with a sentinel trap so we can assert the trap never fires. $1 = extra stub defs
# (passed as $2 to the inner shell; keep stub bodies free of positional params).
run_status() {
    run bash -c 'source "$1"
        set -Eeuo pipefail
        trap "echo TRAP_FIRED" ERR
        ASSUME_YES=yes
        eval "$2"
        status' _ "$SCRIPT" "$1"
}

@test "status: no container runtime reports cleanly (exit 0, no ERR trap)" {
    run_status 'select_runtime(){ return 1; }'
    [ "$status" -eq 0 ]
    [[ "$output" != *"TRAP_FIRED"* ]]
    [[ "$output" == *"none found"* ]]
}

@test "status: absent cluster reports 'not found' (exit 0, no ERR trap)" {
    run_status 'select_runtime(){ CONTAINER_RUNTIME=docker; return 0; }; set_kind_provider(){ :; }; kind(){ :; }; cluster_exists(){ return 1; }'
    [ "$status" -eq 0 ]
    [[ "$output" != *"TRAP_FIRED"* ]]
    [[ "$output" == *"not found"* ]]
}

@test "status: failing helm/kubectl probes stay non-fatal (exit 0, no ERR trap)" {
    run_status 'select_runtime(){ CONTAINER_RUNTIME=docker; return 0; }; set_kind_provider(){ :; }; kind(){ :; }; cluster_exists(){ return 0; }; helm(){ return 1; }; kubectl(){ return 1; }'
    [ "$status" -eq 0 ]
    [[ "$output" != *"TRAP_FIRED"* ]]
    [[ "$output" == *"not installed"* ]]
    [[ "$output" == *"could not list pods"* ]]
}

@test "status: reports release + pods when present (exit 0)" {
    run_status 'select_runtime(){ CONTAINER_RUNTIME=docker; return 0; }; set_kind_provider(){ :; }; kind(){ :; }; cluster_exists(){ return 0; }; helm(){ echo "NAME: sumologic"; echo "STATUS: deployed"; }; kubectl(){ echo "sumo-otelcol-0 1/1 Running"; }'
    [ "$status" -eq 0 ]
    [[ "$output" == *"STATUS: deployed"* ]]
    [[ "$output" == *"Running"* ]]
}

# --- endpoints / forward (read-only kubectl helpers) ------------------------

@test "endpoints: decodes the secret's endpoint-* keys and filters the rest" {
    local b64; b64=$(printf 'https://logs.example' | base64)
    run bash -c 'source "$1"; b="$2"; require_cmd(){ :;}
        kubectl(){ printf "{\"data\":{\"endpoint-logs\":\"%s\",\"version\":\"eA==\"}}" "$b"; }
        ASSUME_YES=yes; endpoints' _ "$SCRIPT" "$b64"
    [ "$status" -eq 0 ]
    [[ "$output" != *"version"* ]]                              # non-endpoint key filtered out
    [[ "$output" == *"endpoint-logs = https://logs.example"* ]] # decoded (load-bearing: asserted last)
}

@test "endpoints: errors clearly when the sumologic secret can't be read" {
    run bash -c 'source "$1"; require_cmd(){ :;}; kubectl(){ return 1; }; ASSUME_YES=yes; endpoints' _ "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"could not read the 'sumologic' secret"* ]]
}

@test "endpoints: a non-base64 secret value fails cleanly (exit 1, no ERR trap)" {
    run bash -c 'source "$1"; set -Eeuo pipefail; trap "echo ERR_TRAP" ERR; require_cmd(){ :;}
        kubectl(){ printf "{\"data\":{\"endpoint-logs\":\"!!notbase64!!\"}}"; }
        ASSUME_YES=yes; endpoints' _ "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" != *"ERR_TRAP"* ]] # exit 1 (not return 1) avoids the bare-dispatch on_error
    [[ "$output" == *"could not decode"* ]]
}

@test "forward: errors (no port-forward) when svc/sumo-otelcol is absent" {
    run bash -c 'source "$1"; require_cmd(){ :;}
        kubectl(){ case "$*" in *"get svc"*) return 1;; *) echo "PF $*";; esac; }
        ASSUME_YES=yes; forward' _ "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"sumo-otelcol not found"* ]]
    [[ "$output" != *"port-forward"* ]] # never reached the blocking port-forward
}

@test "forward: port-forwards svc/sumo-otelcol on 4317 + 4318 when present" {
    run bash -c 'source "$1"; require_cmd(){ :;}
        kubectl(){ case "$*" in *"get svc"*) return 0;; *) echo "PF $*";; esac; }
        ASSUME_YES=yes; forward' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"port-forward svc/sumo-otelcol 4317:4317 4318:4318"* ]]
}

@test "forward: a Ctrl-C stop (kubectl exit 130) is clean, not an ERR-trap failure" {
    run bash -c 'source "$1"; set -Eeuo pipefail; trap "echo ERR_TRAP" ERR; require_cmd(){ :;}
        kubectl(){ case "$*" in *"get svc"*) return 0;; *"port-forward"*) return 130;; *) :;; esac; }
        ASSUME_YES=yes; forward' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" != *"ERR_TRAP"* ]] # SIGINT/130 treated as a clean stop
    [[ "$output" == *"Stopped port-forwarding"* ]]
}

@test "endpoints: reports '(no endpoint-* keys found)' when the secret has none" {
    run bash -c 'source "$1"; require_cmd(){ :;}
        kubectl(){ printf "{\"data\":{\"version\":\"eA==\"}}"; }
        ASSUME_YES=yes; endpoints' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no endpoint-* keys found"* ]]
}

# --- error handling (errtrace) ----------------------------------------------

@test "on_error fires for a failure inside a function (set -Eeuo / errtrace)" {
    # Stub helm to fail; running -o reaches `helm repo add` inside ensure_helm_repo.
    # With errtrace the ERR trap must fire and print on_error's friendly message
    # (rather than the script dying silently with the raw exit code).
    printf '#!/usr/bin/env bash\nexit 1\n' >"${BATS_TEST_TMPDIR}/helm"
    chmod +x "${BATS_TEST_TMPDIR}/helm"
    run env PATH="${BATS_TEST_TMPDIR}:$PATH" bash "$SCRIPT" -y -o </dev/null
    [ "$status" -ne 0 ]
    [[ "$output" == *"Error: command failed"* ]]
}

# --- select_runtime ---------------------------------------------------------

@test "select_runtime: honours a preset CONTAINER_RUNTIME=docker" {
    stub_cmd docker
    CONTAINER_RUNTIME=docker
    run select_runtime
    [ "$status" -eq 0 ]
}

@test "select_runtime: EOF with both runtimes defaults to podman (no busy-loop)" {
    printf '#!/usr/bin/env bash\nexit 0\n' >"${BATS_TEST_TMPDIR}/docker"
    printf '#!/usr/bin/env bash\nexit 0\n' >"${BATS_TEST_TMPDIR}/podman"
    chmod +x "${BATS_TEST_TMPDIR}/docker" "${BATS_TEST_TMPDIR}/podman"
    run bash -c 'source "$1"; trap - ERR EXIT; PATH="$2:$PATH"; ASSUME_YES=""
        select_runtime </dev/null >/dev/null 2>&1; echo "$CONTAINER_RUNTIME"' _ "$SCRIPT" "${BATS_TEST_TMPDIR}"
    [ "$status" -eq 0 ]
    [ "$output" = "podman" ]
}

# --- new_podman memory validation -------------------------------------------
# new_podman is called as `new_podman || return 1`, so its return 1 is errexit-exempt
# in the real flow; the tests call it bare (no ERR trap) and assert on $status.

@test "new_podman: rejects non-integer memory before stopping/creating a machine" {
    run bash -c 'source "$1"
        ask(){ case "$1" in *Allocate*) printf "lots";; *) printf "sumo";; esac; }
        stop_running_machine(){ echo STOP_RAN; }; podman(){ echo "PODMAN $*"; }
        new_podman' _ "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"must be a positive integer"* ]]
    [[ "$output" != *"STOP_RAN"* ]] # bailed before stopping the running machine
    [[ "$output" != *"PODMAN"* ]]   # ...and before `podman machine init`
}

@test "new_podman: warns when memory is below the minimum but still proceeds" {
    run bash -c 'source "$1"
        ask(){ case "$1" in *Allocate*) printf "100";; *) printf "sumo";; esac; }
        stop_running_machine(){ return 0; }; podman(){ echo "PODMAN $*"; }
        new_podman' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"below the recommended minimum"* ]]
    [[ "$output" == *"PODMAN machine init --memory 100"* ]] # proceeded with the value
}

@test "new_podman: a valid memory >= minimum passes through with no warning" {
    run bash -c 'source "$1"
        ask(){ case "$1" in *Allocate*) printf "20000";; *) printf "sumo";; esac; }
        stop_running_machine(){ return 0; }; podman(){ echo "PODMAN $*"; }
        new_podman' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" != *"below the recommended"* ]]
    [[ "$output" == *"PODMAN machine init --memory 20000"* ]]
}

# --- use_existing_podman scoping --------------------------------------------
# Regression guard for the unscoped-locals fix: the function must select a
# qualifying machine AND leave no working variable behind in the global scope.
# (On the pre-fix code all 16 scalars leaked; the four arrays were already local
# via `declare -a`, which localizes inside a function in Bash 3.2.)

@test "use_existing_podman: picks a qualifying machine and leaks no globals" {
    run bash -c 'source "$1"
        trap - ERR EXIT
        MIN_MEM_MB=2048; MIN_CPU=1; ASSUME_YES=yes
        podman(){ if [ "$*" = "machine list --format json" ]; then
            printf "%s" "[{\"Name\":\"sumo\",\"Memory\":21474836480,\"CPUs\":8,\"Running\":true}]"
          else echo "PODMAN $*"; fi; }
        use_existing_podman >/dev/null   # menu output is irrelevant; rc + leak check below
        rc=$?
        leaked=""
        for v in machines_json index machine_count name mem_raw cpu status mem_mb \
                 display_number create_option exit_option selection selection_index \
                 chosen_machine machine_running valid_names valid_memories valid_cpus valid_statuses; do
            eval "val=\${$v:-}"
            [ -z "$val" ] || leaked="$leaked $v=$val"
        done
        echo "RC=$rc"
        echo "LEAKED:${leaked}"' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=0"* ]]      # selected the running, qualifying machine
    [[ "$output" == *"LEAKED:"* ]]   # the marker line printed at all
    [[ "$output" != *"LEAKED: "* ]]  # ...with nothing after the colon -> no leaked vars
}

# --- list_valid_machines / prompt_machine_selection (the split helpers) ------
# use_existing_podman was split into list_valid_machines (discover+filter, fills the
# caller's valid_* arrays) and prompt_machine_selection (menu over those arrays). The
# arrays stay `local -a` in use_existing_podman and are shared with the helpers by Bash
# dynamic scoping; these guard that contract (fill, read, and the no-valid orchestration).

@test "list_valid_machines: fills the caller's valid_* arrays, filtering by the minimums" {
    run bash -c 'source "$1"
        MIN_MEM_MB=2048; MIN_CPU=1
        podman(){ printf "%s" "[{\"Name\":\"big\",\"Memory\":21474836480,\"CPUs\":8,\"Running\":true},{\"Name\":\"tiny\",\"Memory\":1073741824,\"CPUs\":1,\"Running\":false}]"; }
        wrap(){ local -a valid_names valid_memories valid_cpus valid_statuses
            list_valid_machines >/dev/null     # discovered list is irrelevant here
            printf "NAMES=[%s] MEM=[%s] CPU=[%s] STAT=[%s] N=%s" \
                "${valid_names[*]}" "${valid_memories[*]}" "${valid_cpus[*]}" "${valid_statuses[*]}" "${#valid_names[@]}"; }
        wrap' _ "$SCRIPT"
    # "big" (20480MB/8cpu) qualifies; "tiny" (1024MB) is filtered out -> exactly one entry.
    [[ "$output" == *"NAMES=[big] MEM=[20480] CPU=[8] STAT=[true] N=1"* ]]
}

@test "prompt_machine_selection: reads the caller's arrays and starts a non-running pick" {
    run bash -c 'source "$1"
        confirm(){ return 0; }                 # yes, start it
        podman(){ echo "podman $*"; }
        wrap(){ local -a valid_names=("m1") valid_memories=("8192") valid_cpus=("4") valid_statuses=("false")
            ASSUME_YES=yes                      # auto-selects machine #1
            prompt_machine_selection; }
        wrap' _ "$SCRIPT"
    [ "$status" -eq 0 ] && [[ "$output" == *"You selected: m1"* ]] && [[ "$output" == *"podman machine start m1"* ]]
}

@test "use_existing_podman: no qualifying machine + declined creation returns non-zero" {
    run bash -c 'source "$1"
        MIN_MEM_MB=999999; MIN_CPU=1           # nothing can qualify
        podman(){ printf "%s" "[{\"Name\":\"tiny\",\"Memory\":1073741824,\"CPUs\":1,\"Running\":false}]"; }
        confirm(){ return 1; }                  # decline creating a new machine
        use_existing_podman' _ "$SCRIPT"
    # The no-valid branch reads the (empty) dynamic-scoped array and bails cleanly.
    [[ "$output" == *"No Podman machines meet the minimum"* ]] && [ "$status" -ne 0 ]
}

@test "list_valid_machines: returns 0 when exactly one machine qualifies (rc not data-dependent)" {
    # Regression guard: the loop's trailing `((index++))` post-incrementing 0 must not become
    # the helper's exit status (it returns 1), which would abort use_existing_podman under
    # set -e on the common single-machine case. An explicit `return 0` fixes it.
    run bash -c 'source "$1"
        MIN_MEM_MB=2048; MIN_CPU=1
        podman(){ printf "%s" "[{\"Name\":\"only\",\"Memory\":21474836480,\"CPUs\":8,\"Running\":true}]"; }
        wrap(){ local -a valid_names valid_memories valid_cpus valid_statuses
            list_valid_machines >/dev/null; printf "RC=[%s] N=[%s]" "$?" "${#valid_names[@]}"; }
        wrap' _ "$SCRIPT"
    [[ "$output" == *"RC=[0] N=[1]"* ]] # found the one machine AND returned success
}

# prompt_machine_selection menu branches (all driven with ASSUME_YES='' over a 1-element
# array, so create_option=2 / exit_option=3). Each asserts a single combined last command
# so every check is load-bearing on macOS bats.

@test "prompt_machine_selection: EOF on the menu read aborts with a clear message" {
    run bash -c 'source "$1"
        wrap(){ local -a valid_names=("m1") valid_memories=("8192") valid_cpus=("4") valid_statuses=("true")
            ASSUME_YES=""; prompt_machine_selection </dev/null; }
        wrap' _ "$SCRIPT"
    [[ "$output" == *"aborting machine selection"* ]] && [ "$status" -ne 0 ]
}

@test "prompt_machine_selection: choosing 'None (exit)' returns non-zero without selecting" {
    run bash -c 'source "$1"
        wrap(){ local -a valid_names=("m1") valid_memories=("8192") valid_cpus=("4") valid_statuses=("true")
            ASSUME_YES=""; prompt_machine_selection <<<"3"; }
        wrap' _ "$SCRIPT"
    [[ "$output" == *"Exiting without selecting a Podman machine"* ]] && [ "$status" -ne 0 ]
}

@test "prompt_machine_selection: choosing 'Create a new Podman machine' calls new_podman" {
    run bash -c 'source "$1"
        new_podman(){ echo "NEW_PODMAN_RAN"; return 0; }
        wrap(){ local -a valid_names=("m1") valid_memories=("8192") valid_cpus=("4") valid_statuses=("true")
            ASSUME_YES=""; prompt_machine_selection <<<"2"; }
        wrap' _ "$SCRIPT"
    [ "$status" -eq 0 ] && [[ "$output" == *"NEW_PODMAN_RAN"* ]]
}

@test "prompt_machine_selection: non-numeric then out-of-range input re-prompts, then selects" {
    run bash -c 'source "$1"
        confirm(){ return 0; }; podman(){ echo "podman $*"; }
        wrap(){ local -a valid_names=("m1") valid_memories=("8192") valid_cpus=("4") valid_statuses=("true")
            ASSUME_YES=""; prompt_machine_selection <<<"abc
9
1"; }
        wrap' _ "$SCRIPT"
    [[ "$output" == *"Invalid input"* ]] && [[ "$output" == *"Invalid selection"* ]] && [ "$status" -eq 0 ]
}

@test "prompt_machine_selection: declining 'Start it now?' on a stopped machine returns non-zero" {
    run bash -c 'source "$1"
        confirm(){ return 1; }                  # decline starting
        podman(){ echo "podman $*"; }
        wrap(){ local -a valid_names=("m1") valid_memories=("8192") valid_cpus=("4") valid_statuses=("false")
            ASSUME_YES=yes; prompt_machine_selection; }
        wrap' _ "$SCRIPT"
    [[ "$output" == *"Exiting without starting machine"* ]] && [[ "$output" != *"podman machine start"* ]] && [ "$status" -ne 0 ]
}

# --- select_chart_version ---------------------------------------------------

# helm stub emitting a `helm search repo --versions` style table (with an unrelated
# sub-chart row that must be filtered out by the $1=="sumologic/sumologic" match).
CHART_STUB='helm(){ printf "%s\n" "NAME CHART_VERSION APP_VERSION DESC" "sumologic/sumologic 5.2.0 5.2.0 x" "sumologic/sumologic 5.1.1 5.1.1 x" "sumologic/sumologic-fluentd 1.0.0 1 x"; }'

@test "select_chart_version: unattended returns the pinned default (no prompt)" {
    run bash -c "source \"\$1\"; trap - ERR EXIT; $CHART_STUB; ASSUME_YES=yes; select_chart_version 2>/dev/null" _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$output" = "5.2.0" ]
}

@test "select_chart_version: env-pinned returns that version without prompting" {
    run bash -c "source \"\$1\"; trap - ERR EXIT; $CHART_STUB; ASSUME_YES=''; CHART_VERSION_FROM_ENV=yes; SUMO_CHART_VERSION=5.1.0; select_chart_version 2>/dev/null" _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$output" = "5.1.0" ]
}

@test "select_chart_version: picking from the list returns that version (sub-chart filtered out)" {
    run bash -c "source \"\$1\"; trap - ERR EXIT; $CHART_STUB; ASSUME_YES=''; CHART_VERSION_FROM_ENV=''; printf '2\n' | select_chart_version 2>/dev/null" _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$output" = "5.1.1" ]
}

@test "select_chart_version: blank selection uses the pinned default" {
    run bash -c "source \"\$1\"; trap - ERR EXIT; $CHART_STUB; ASSUME_YES=''; CHART_VERSION_FROM_ENV=''; printf '\n' | select_chart_version 2>/dev/null" _ "$SCRIPT"
    [ "$output" = "5.2.0" ]
}

@test "select_chart_version: EOF on the prompt falls back to the pinned default" {
    run bash -c "source \"\$1\"; trap - ERR EXIT; $CHART_STUB; ASSUME_YES=''; CHART_VERSION_FROM_ENV=''; select_chart_version </dev/null 2>/dev/null" _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$output" = "5.2.0" ]
}

# --- select_node_image (EOF must not busy-loop) -----------------------------

@test "select_node_image: EOF on the version prompt falls back to kind's default" {
    # Return a tag list so we enter the numbered-selection loop, then feed EOF.
    run bash -c 'source "$1"; trap - ERR EXIT
        curl(){ printf "%s" "{\"results\":[{\"name\":\"v1.32.2\"}]}"; }
        select_node_image </dev/null 2>/dev/null' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$output" ] # no node image emitted -> caller uses kind's default
}

# --- install_dependencies (direct-download path uses a private scratch dir) --

@test "install_dependencies: direct path downloads into a mktemp scratch dir, never /tmp, and cleans up" {
    # Isolated subshell so the command/mktemp/curl overrides can't leak into bats.
    # Force the no-brew direct path; report the CLIs absent so the install branches
    # run, but docker "present" so the podman branch (which exits on Linux) is skipped.
    run bash -c '
        source "$1"; trap - ERR EXIT
        scratch="$2"; calls="$3"
        confirm() { return 1; }
        command() {
            if [ "$1" = "-v" ]; then
                case "$2" in
                    brew|jq|kubectl|helm|kind|podman) return 1 ;;
                    docker) return 0 ;;
                    *) builtin command "$@" ;;
                esac
            else builtin command "$@"; fi
        }
        mktemp() { mkdir -p "$scratch"; printf "%s\n" "$scratch"; }
        curl() {
            local out="" prev=""
            for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
            [ -n "$out" ] && printf "#!/bin/sh\nexit 0\n" >"$out"
            return 0
        }
        verify_sha256() { :; }
        kubectl() { :; }
        tar() { :; }
        install_binary() { echo "install_binary $1" >>"$calls"; }
        install_dependencies
        [ -d "$scratch" ] && echo "SCRATCH_REMAINS" || echo "SCRATCH_GONE"
    ' _ "$SCRIPT" "$BATS_TEST_TMPDIR/scratch" "$CALLS"
    [ "$status" -eq 0 ]
    assert_called 'install_binary .*/scratch/jq$'
    assert_called 'install_binary .*/scratch/kubectl$'
    assert_called 'install_binary .*/scratch/kind$'
    # helm comes from the verified release tarball: $tmpdir/${OS}-${ARCH}/helm
    assert_called 'install_binary .*/scratch/(darwin|linux)-(amd64|arm64)/helm$'
    # Must not use the OLD predictable paths. mktemp -d legitimately lives under /tmp
    # (and bats' own tmpdir is under /tmp on Linux), so refute the specific fixed
    # filenames directly in /tmp, not the /tmp prefix.
    refute_called 'install_binary /tmp/(jq|kubectl|kind)$'
    [[ "$output" == *"SCRATCH_GONE"* ]]
}

@test "install_dependencies: no-brew path fails fast with a clear message when curl is missing" {
    run bash -c '
        source "$1"; trap - ERR EXIT
        confirm() { return 1; }              # would pick direct-download, but the curl guard fires first
        command() {
            if [ "$1" = "-v" ]; then
                case "$2" in
                    brew|curl) return 1 ;;       # no Homebrew, and no curl on PATH
                    *) builtin command "$@" ;;
                esac
            else builtin command "$@"; fi
        }
        install_dependencies
    ' _ "$SCRIPT"
    # The standard require_cmd message, not a raw "curl: command not found" under the ERR trap.
    [[ "$output" == *"required command(s) not found: curl"* ]] && [ "$status" -ne 0 ]
}

@test "install_dependencies: no-brew direct path guards curl, tar (helm), and unzip (macOS Podman)" {
    run bash -c '
        source "$1"; trap - ERR EXIT
        scratch="$2"; calls="$3"
        OS=darwin; ARCH=arm64                  # force the macOS Podman (.zip) branch even on Linux CI
        confirm() { return 1; }                # decline Homebrew -> direct-download path
        command() {
            if [ "$1" = "-v" ]; then
                case "$2" in
                    brew|jq|kubectl|helm|kind|docker|podman) return 1 ;;  # all absent -> every block runs
                    *) builtin command "$@" ;;
                esac
            else builtin command "$@"; fi
        }
        # Record require_cmd targets (instead of enforcing) so the whole path runs.
        require_cmd() { local c; for c in "$@"; do echo "require_cmd $c" >>"$calls"; done; }
        mktemp() { mkdir -p "$scratch"; printf "%s\n" "$scratch"; }
        curl() { local out="" prev=""; for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done; [ -n "$out" ] && : >"$out"; return 0; }
        verify_sha256() { :; }; remote_sha256() { echo deadbeef; }
        tar() { :; }; unzip() { :; }; kubectl() { :; }; install_binary() { :; }
        install_dependencies
    ' _ "$SCRIPT" "$BATS_TEST_TMPDIR/scratch" "$CALLS"
    # All three guards fire on the macOS no-runtime path (chained -> each load-bearing on macOS bats).
    assert_called "^require_cmd curl$" && assert_called "^require_cmd tar$" && assert_called "^require_cmd unzip$"
}
