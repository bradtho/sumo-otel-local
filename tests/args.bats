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
       uninstall(){ echo "UNINSTALL_RAN f=$FORCE"; }; status(){ echo "STATUS_RAN"; }'

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

@test "-n dispatches init only (no install_sumo)" {
    run_main -n
    [ "$status" -eq 0 ]
    [[ "$output" == *"INIT_RAN"* ]]
    [[ "$output" != *"SUMO_RAN"* ]]
}

@test "-v prints the version and exits 0" {
    run bash -c 'source "$1"; main -v' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"sumo-otel-local 0.4.0"* ]]
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

@test "long flags and aliases work (--non-interactive --install)" {
    run_main --non-interactive --install
    [ "$status" -eq 0 ]
    [[ "$output" == *"SUMO_RAN y=yes"* ]]
}
