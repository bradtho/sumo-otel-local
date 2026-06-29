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
    [[ "$output" != *"PLACEHOLDER_ACCESS"* ]]
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
