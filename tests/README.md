# Tests

[bats-core](https://github.com/bats-core/bats-core) suite for `sumo-otel-local.sh`.
Runs in CI on Ubuntu + macOS (the `Tests (…)` jobs).

```bash
brew install bats-core      # macOS
apt-get install -y bats     # Debian/Ubuntu
bats tests/                 # run everything
bats tests/flow.bats -f "install_sumo"   # filter by name
```

## Files

| File           | Covers |
| -------------- | ------ |
| `unit.bats`    | Pure functions + constants: `mem_to_mib`, `yaml_escape`, `secret_env_var`, `confirm`/`ask`, the `MIN_*` / version / `KINDEST_NODE_*` pins. |
| `verify.bats`  | Download-integrity helpers: `sha256_of`, `remote_sha256`, `verify_sha256` (accept / mismatch / fail-closed). |
| `flow.bats`    | Action functions against stubbed externals: teardown, install/output arg-building, the podman-machine helpers, `install_dependencies`, etc. |
| `args.bats`    | `main()` argument parsing: single-action dispatch, order-independent modifiers, clustered short flags, errors. |
| `config.bats`  | The optional project config file. |
| `meta.bats`    | Cross-file repo invariants (CONTRIBUTING ↔ pr-title workflow types; workflow concurrency; **every workflow action is SHA-pinned**). |
| `test_helper.bash` | `load_script`, `setup_stubs`, `stub_cmd`, `assert_called`, `refute_called`. |

## How the script is loaded

`load_script` (or `source "$SCRIPT"`) sources the script into the test shell. Strict
mode (`set -Eeuo pipefail`) and the ERR/EXIT traps live in `main()`, guarded by
`BASH_SOURCE == $0`, so **sourcing has no side effects** — no traps, no arg parsing.
That means `set -u`/errexit are *off* in tests; assert exit codes explicitly.

## Driving interactive prompts (the injection seam)

The script prompts via three helpers — `confirm` (y/n), `ask` (value+default), and
`read_secret` (silent) — each backed by a `read`. There are three ways to drive them,
in order of preference:

1. **Unattended path** — set `ASSUME_YES=yes`. `confirm` returns yes and `ask` returns
   its default without reading. Best when you don't care about the prompts themselves.

2. **Override `confirm`/`ask` as functions, mapped by prompt substring.** This is the
   primary seam — a test maps *prompt → answer* instead of relying on positional stdin,
   so reordering a prompt can't silently feed the wrong answer:

   ```bash
   ask(){ case "$1" in
            *"values file"*)        printf "%s" "$myvals";;
            *"Name of the cluster"*) printf sumo;;
            *) printf "";;
          esac; }
   confirm(){ case "$1" in *"Overwrite"*) return 1;; *) return 0;; esac; }
   ```

3. **Real `read` via stdin** — a here-string (`<<<"y"`) or `</dev/null` (EOF). Use for
   testing the *real* `confirm`/`ask`/`read_secret` EOF/parsing behavior. Positional, so
   brittle to reordering — prefer (2) for multi-prompt flows.

**Keep prompt order stable.** `flow.bats` has an `install_sumo … prompt order is stable`
test that records the exact `confirm`/`ask` call sequence and asserts it — reorder, add,
or remove a prompt and it fails. Update that test deliberately when you change a flow.

## Gotchas (learned the hard way)

- **macOS bats only fails a test on its LAST command; Linux bats fails on ANY.** So a
  wrong *intermediate* assertion passes locally/on the macOS job but fails on
  `Tests (ubuntu-latest)`. Put the load-bearing assertion last, and to keep *several*
  load-bearing, combine them into one final command: `[[ A && B ]]` or `cmd1 && cmd2`.
- **Don't assert on a stub's stdout when it's piped/captured.** `output()` runs
  `helm … | tee`, and `ask` is called in `$(...)`; a stub's stdout is swallowed. Record
  to a **marker file** (`echo … >>"$rec"`) and assert on the file — it survives subshells.
- **Don't name a script-level function `run`/`load`/`skip`/`setup`/`teardown`/`bats_*`.**
  Sourcing the script would clobber bats-core's builtin and red the whole suite.
- **Prove a new test is load-bearing** by mutating the script (a throwaway copy, or append
  a function redefinition) and confirming the test *fails*. CI is the backstop, but a test
  that can't fail is worthless.
