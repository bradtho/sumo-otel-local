# Shared helpers for the sumo-otel-local bats suite.
#
# The script under test enables `set -euo pipefail` and its ERR trap inside main()
# (guarded by `BASH_SOURCE == $0`), so sourcing it here only defines functions and
# constants — the CLI is never parsed and no traps leak into the test shell.

SCRIPT="${BATS_TEST_DIRNAME}/../sumo-otel-local.sh"

# Source the script under test into the current shell.
load_script() {
    # shellcheck disable=SC1090
    source "$SCRIPT"
}

# Initialise an argv-recording file and a stub bin dir at the front of PATH.
# Call from setup(). External commands can be stubbed either as bash functions
# (simplest) or as PATH scripts via stub_cmd below.
setup_stubs() {
    CALLS="${BATS_TEST_TMPDIR}/calls"
    STUB_BIN="${BATS_TEST_TMPDIR}/bin"
    : >"$CALLS"
    mkdir -p "$STUB_BIN"
    PATH="$STUB_BIN:$PATH"
}

# stub_cmd <name> [exit_code] : create a PATH stub that appends "<name> <args>" to
# $CALLS and exits with the given code (default 0). Use for commands invoked by
# sub-processes (so a bash function override wouldn't be seen).
stub_cmd() {
    local name=$1 rc=${2:-0}
    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf "%%s %%s\\n" %q "$*" >> %q\n' "$name" "$CALLS"
        printf 'exit %s\n' "$rc"
    } >"$STUB_BIN/$name"
    chmod +x "$STUB_BIN/$name"
}

# Assert the recorded calls contain a line matching the extended regex $1.
assert_called() {
    if ! grep -Eq -- "$1" "$CALLS"; then
        echo "expected a recorded call matching: $1" >&2
        echo "recorded calls were:" >&2
        cat "$CALLS" >&2
        return 1
    fi
}

# Assert the recorded calls do NOT contain a line matching the extended regex $1.
refute_called() {
    if grep -Eq -- "$1" "$CALLS"; then
        echo "did NOT expect a recorded call matching: $1" >&2
        echo "recorded calls were:" >&2
        cat "$CALLS" >&2
        return 1
    fi
}
