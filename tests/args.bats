#!/usr/bin/env bats
# Argument-parser tests for main(): single-action dispatch, order-independent
# modifiers, and clear errors for ambiguous/empty/unknown input.
#
# Each case runs main() in a subshell (run bash -c '…') so its strict mode + ERR/EXIT
# traps stay contained, with the action functions stubbed to echo distinctive markers
# (chosen NOT to collide with words in the help text, e.g. "dependencies"/"uninstall").

setup() {
    load "test_helper"
}

STUBS='install_dependencies(){ echo "DEPS_RAN"; }; init_cluster(){ echo "INIT_RAN"; }
       install_sumo(){ echo "SUMO_RAN y=$ASSUME_YES f=$FORCE"; }
       output(){ echo "OUTPUT_RAN"; }; purge(){ echo "PURGE_RAN f=$FORCE"; }
       uninstall(){ echo "UNINSTALL_RAN f=$FORCE"; }; status(){ echo "STATUS_RAN"; }
       endpoints(){ echo "ENDPOINTS_RAN"; }; forward(){ echo "FORWARD_RAN"; }
       reinstall(){ echo "REINSTALL_RAN"; }; init_config(){ echo "INITCONFIG_RAN"; }
       maybe_offer_config_init(){ :; }'

# run_main <args...> : source the script, install stubs, then run main with the args.
run_main() {
    run bash -c "source \"\$1\"; $STUBS; shift; main \"\$@\"" _ "$SCRIPT" "$@"
}

@test "-i dispatches the full install flow" {
    run_main -i
    [ "$status" -eq 0 ]
    [[ "$output" == *"DEPS_RAN"* ]]
    [[ "$output" == *"INIT_RAN"* ]]
    [[ "$output" == *"SUMO_RAN"* ]]
}

@test "-s/--status dispatches the status action" {
    run_main -s
    [ "$status" -eq 0 ]
    [[ "$output" == *"STATUS_RAN"* ]]
}

@test "--init-config dispatches the init_config action" {
    run_main --init-config
    [ "$status" -eq 0 ]
    [[ "$output" == *"INITCONFIG_RAN"* ]]
}

@test "-r/--reinstall dispatches the reinstall action" {
    run_main -r
    [ "$status" -eq 0 ]
    [[ "$output" == *"REINSTALL_RAN"* ]]
    run_main --reinstall
    [ "$status" -eq 0 ]
    [[ "$output" == *"REINSTALL_RAN"* ]]
}

@test "-e/--endpoints and --forward dispatch their actions" {
    run_main -e
    [ "$status" -eq 0 ]
    [[ "$output" == *"ENDPOINTS_RAN"* ]]
    run_main --endpoints
    [[ "$output" == *"ENDPOINTS_RAN"* ]]
    run_main --forward
    [ "$status" -eq 0 ]
    [[ "$output" == *"FORWARD_RAN"* ]]
}

@test "-e and --forward are still single actions (conflict with another action errors)" {
    run_main -e -i
    [ "$status" -eq 1 ]
    [[ "$output" == *"Specify exactly one action"* ]]
    [[ "$output" != *"ENDPOINTS_RAN"* ]]
}

@test "-n dispatches init only (no install_sumo)" {
    run_main -n
    [ "$status" -eq 0 ]
    [[ "$output" == *"INIT_RAN"* ]]
    [[ "$output" != *"SUMO_RAN"* ]]
}

@test "-v prints the script VERSION and exits 0" {
    run bash -c 'source "$1"; main -v' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    # Derive the expected string from the script's VERSION constant rather than
    # hardcoding a number, so a release-please version bump doesn't break this test.
    local want
    want=$(bash -c 'source "$1"; printf "sumo-otel-local %s" "$VERSION"' _ "$SCRIPT")
    [[ "$output" == *"$want"* ]]
}

@test "-h prints usage and exits 0, even alongside an action (help wins)" {
    run_main -h -i
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" != *"DEPS_RAN"* ]] # the install flow must not run
}

@test "an unknown flag is a clear error (exit 1)" {
    run_main --bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid Option: --bogus"* ]]
}

@test "no action is a clear error (exit 1)" {
    run_main
    [ "$status" -eq 1 ]
    [[ "$output" == *"Specify exactly one action"* ]]
}

@test "two conflicting actions are rejected (exit 1), not partially run" {
    run_main -i -u
    [ "$status" -eq 1 ]
    [[ "$output" == *"Specify exactly one action"* ]]
    [[ "$output" != *"DEPS_RAN"* ]]
    [[ "$output" != *"UNINSTALL_RAN"* ]]
}

@test "repeating the SAME action is idempotent, not an error (-i -i runs once)" {
    run_main -i -i
    [ "$status" -eq 0 ]
    [[ "$output" == *"SUMO_RAN"* ]]
    [[ "$output" != *"Specify exactly one action"* ]]
}

@test "-h wins even before an unknown flag (-h --bogus -> help, exit 0)" {
    run_main -h --bogus
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" != *"Invalid Option"* ]]
}

@test "-y is order-independent: -y -i and -i -y both enable unattended mode" {
    run_main -y -i
    [[ "$output" == *"SUMO_RAN y=yes"* ]]
    run_main -i -y
    [[ "$output" == *"SUMO_RAN y=yes"* ]]
}

@test "--force is order-independent: --force -p and -p --force both set FORCE" {
    run_main --force -p
    [ "$status" -eq 0 ]
    [[ "$output" == *"PURGE_RAN f=yes"* ]]
    run_main -p --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"PURGE_RAN f=yes"* ]]
}

@test "--dry-run and -V/--verbose are modifiers, combinable with an install-flow action" {
    run_main --dry-run -n
    [ "$status" -eq 0 ]
    [[ "$output" == *"INIT_RAN"* ]]
    run_main -V -i
    [ "$status" -eq 0 ]
    [[ "$output" == *"SUMO_RAN"* ]]
}

@test "--dry-run is refused for EVERY non-install action (the only guard against e.g. --dry-run -u deleting)" {
    # The guard is the sole thing stopping --dry-run -u/-p from running a real teardown
    # (uninstall/purge don't honor DRY_RUN), so pin the refusal for all of them. Failures
    # accumulate into $bad; the load-bearing assertion is last (robust on macOS + Linux bats).
    local act bad=""
    for act in -u -p -r -o -s --forward; do
        run_main --dry-run "$act"
        { [ "$status" -eq 1 ] && [[ "$output" == *"only applies to the install flow"* ]] && [[ "$output" != *_RAN* ]]; } || bad="$bad $act"
    done
    [ -z "$bad" ] # every non-install action refused --dry-run before dispatching
}

@test "long flags and aliases work (--non-interactive --install)" {
    run_main --non-interactive --install
    [ "$status" -eq 0 ]
    [[ "$output" == *"SUMO_RAN y=yes"* ]]
}

@test "clustered short flags: -yi is the same as -y -i (unattended install)" {
    run_main -yi
    [ "$status" -eq 0 ]
    [[ "$output" == *"SUMO_RAN y=yes"* ]]
}

@test "clustered short flags: -iy works too (order within a cluster is irrelevant)" {
    run_main -iy
    [ "$status" -eq 0 ]
    [[ "$output" == *"SUMO_RAN y=yes"* ]]
}

@test "clustered short flags: -fp is --force + purge" {
    run_main -fp
    [ "$status" -eq 0 ]
    [[ "$output" == *"PURGE_RAN f=yes"* ]]
}

@test "a cluster containing an unknown letter errors (-ix -> Invalid Option: -x)" {
    run_main -ix
    [ "$status" -eq 1 ]
    [[ "$output" == *"Invalid Option: -x"* ]]
    [[ "$output" != *"DEPS_RAN"* ]] # the install flow must not run
}

@test "invalid-option error and help go to stderr, not stdout" {
    # stdout only (stderr discarded): the error/help must NOT appear here
    run bash -c "source \"\$1\"; $STUBS; main --bogus 2>/dev/null" _ "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" != *"Invalid Option"* ]]
    [[ "$output" != *"Usage:"* ]]
    # stderr only (stdout discarded): the error AND help ARE here
    run bash -c "source \"\$1\"; $STUBS; main --bogus 1>/dev/null" _ "$SCRIPT"
    [[ "$output" == *"Invalid Option: --bogus"* ]]
    [[ "$output" == *"Usage:"* ]]
}
