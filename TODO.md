# TODO

Work backlog for `sumo-otel-local`, ordered by criticality. Checkboxes track
progress; line references point at the current Bash implementation.

**Decisions (2026-06-12):**

- **Language:** Stay on Bash and land all P0 fixes first; revisit the Python port
  (P3) once the script is stable.
- **Platforms:** Support **macOS + Linux** (was macOS-only). This widens several P0
  items — arch/OS detection, dependency install, and secret storage must not assume
  macOS-only tooling (`brew`, `security`/Keychain).

---

## P0 — Critical (correctness / data-loss / security)

These cause broken installs, surprise destruction, or secret exposure.

- [ ] **Fix `kind` direct-install platform** — `sumo-otel-local.sh:75` hardcodes
  `kind-linux-amd64`. Detect OS (`uname -s` → `darwin`/`linux`) and arch, then build
  `kind-${OS}-${ARCH}`. Same OS-awareness needed for the jq/podman downloads.
- [ ] **Remove / rework `trap cleanup ERR`** — `sumo-otel-local.sh:404-408`. With
  `set -e`, *any* failed command triggers the interactive `uninstall` flow and can
  delete the user's cluster. Replace with a safe handler that only reports the error.
- [ ] **Fix `-i` install flow early `exit 0`** — `sumo-otel-local.sh:330-332,365,371`.
  Creating/selecting a Podman machine exits the whole script, so cluster creation and
  Sumo install never run during `--install`. Return instead of exiting.
- [ ] **Stop leaking secrets on the Helm CLI** — `sumo-otel-local.sh:154-155`.
  `--set-string sumologic.accessId/accessKey` exposes credentials in the process list.
  Write to a temp values file (mode 600) or feed via `--set-file`/stdin and shred after.
- [ ] **Cross-platform secret storage** — `security`/Keychain
  (`sumo-otel-local.sh:117-129,222-234`) is macOS-only. Add a Linux path (e.g.
  `secret-tool`/libsecret, or an env-var fallback) so the install/purge flows work there.
- [ ] **Fix architecture mapping** — `uname -m` returns `x86_64`/`arm64`, but jq/kind
  release assets expect `amd64`/`arm64` (`sumo-otel-local.sh:41,64,75`). Add a
  normalization step so Intel Macs don't hit 404s.

## P1 — High (reliability / UX correctness)

- [ ] **Resolve cluster-name conflict** — `kind-config.yaml` hardcodes `name: cluster`
  while the script passes `--name ${CLUSTER_NAME}` (`sumo-otel-local.sh:105`). Decide
  on one source of truth so `uninstall`/`purge` target the right cluster.
- [ ] **Declare `valid_statuses`** — used at `sumo-otel-local.sh:302` but absent from the
  `declare -a` at line 281; fragile under `set -u`.
- [ ] **Pin / prompt Kubernetes version** — `init_cluster` always uses "latest"
  (`sumo-otel-local.sh:100-108`); the "choose a version" branch is a dead-end `echo`.
  Wire it to a real `--image kindest/node:<tag>` selection (see `local-image.sh`).
- [ ] **Validate the Helm values path** before calling Helm (`:131-159`) — fail early
  with a clear message if the file doesn't exist.
- [ ] **Make memory/CPU minimums configurable** — `MIN_MEM_MB=18432`, `MIN_CPU=4` are
  hardcoded (`sumo-otel-local.sh:274-275`); allow override via flag/env.

## P2 — Medium (maintainability / cleanup)

- [ ] **Wire up or remove `local-image.sh`** — the pull/load/tag logic is entirely
  commented out (`local-image.sh:1-12`); the script only lists tags and does nothing
  with the selection. Either integrate offline image loading or delete the file.
- [ ] **De-duplicate constants** — `DEFAULT_CLUSTER_NAME="sumo"` is redefined in five
  places; lift to a single top-level constant.
- [ ] **Consolidate Podman-running checks** — the "is a machine already running / stop
  it?" logic is duplicated across `new_podman` and `use_existing_podman`.
- [ ] **Consistent confirmation prompts** — mix of `[y/n]`, `[y/N]`, and case handling;
  standardize a `confirm()` helper.
- [ ] **Add a `--non-interactive` / env-driven mode** so the script can run in CI.

## P3 — Decision: Bash → Python migration

Tracked as a deliberate decision rather than a straight task. See "Open Questions".

- [ ] **Decide whether to port to Python.** Pros: real arg parsing (`argparse`/`click`),
  structured error handling instead of `trap`+`set -e`, testable functions
  (`pytest`), cross-platform arch detection, safer secret handling, JSON parsing
  without shelling out to `jq`. Cons: adds a Python runtime dependency, rewrite effort,
  current script is "done enough".
- [ ] If yes: scaffold a `click`-based CLI mirroring the existing flags
  (`-i/-n/-m/-o/-p/-u/-v`), shelling out to `kubectl`/`helm`/`kind`/`podman`.
- [ ] If yes: keep the P0/P1 fixes in mind so they're designed-in, not re-ported.
- [ ] If yes: add `pyproject.toml`, `pytest` suite, and CI (lint + smoke test).

## P4 — Docs / housekeeping

- [ ] README references a non-existent `install.sh` (`README.md:51`) — should be
  `sumo-otel-local.sh`.
- [ ] Add a `CLAUDE.md` (run `/init`) documenting structure, prerequisites, and the
  install/uninstall flows.
- [ ] Add `shellcheck` (and `shfmt`) to a CI workflow while the project remains Bash.
- [ ] Document the Keychain entries (`sumologic_access_id`/`_key`) and how to rotate them.

---

## Open Questions

1. **Bash or Python?** — primary fork in the road; see P3. What's the appetite for a
   runtime dependency vs. keeping a dependency-free shell script?
2. **Docker vs. Podman** — is Podman the supported default, with Docker best-effort?
3. **Target platforms** — macOS only (current assumption), or should Linux be supported?
