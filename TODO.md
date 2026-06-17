# TODO

Work backlog for `sumo-otel-local`, ordered by criticality. Checkboxes track
progress; line references point at the current Bash implementation.

**Decisions (2026-06-12):**

- **Language:** Stay on Bash and land all P0 fixes first; revisit the Python port
  (P3) once the script is stable.
- **Platforms:** Support **macOS + Linux** (was macOS-only). This widens several P0
  items — arch/OS detection, dependency install, and secret storage must not assume
  macOS-only tooling (`brew`, `security`/Keychain).
- **Releases:** GitHub Releases with semantic versioning. Current latest is `0.4.0`.
- **Merge rules on `main`:** PRs required, signed commits required, and status
  checks required (the status-check requirement is *pending* CI via Actions). Admin
  (repo owner) can bypass. ⇒ commits on `dev` must be **signed** (GPG/SSH) so the
  eventual `dev → main` PR satisfies the rule without an admin override.
- **Container runtime:** Docker **and** Podman are both **first-class** (not
  best-effort). Rationale: Docker Desktop's licensing restricts some users, so Podman
  must be a fully supported peer. Both must work in the script and be exercised in CI.

---

## P0 — Critical (correctness / data-loss / security)

These cause broken installs, surprise destruction, or secret exposure.

- [x] **Fix `kind` direct-install platform** — done. Added normalized `OS`/`ARCH`
  detection; `kind`, `kubectl`, and `jq` downloads are now OS+arch aware. Podman's
  direct install branches: macOS keeps the release zip, Linux defers to the distro
  package manager (a static binary can't provide a working rootless setup).
- [x] **Remove / rework `trap cleanup ERR`** — done. Replaced the `cleanup`→`uninstall`
  trap with `on_error`, which reports the failing line + exit code, changes/removes
  nothing, and exits non-zero. Cluster teardown is now only via explicit `-u`/`-p`.
- [x] **Fix `-i` install flow early `exit 0`** — done. `new_podman` and
  `use_existing_podman` now `return` a status (0 = machine ready, 1 = user aborted)
  instead of calling `exit`. `init_cluster` checks the result and only aborts on
  failure, so a successful create/select continues to `kind create cluster` and
  `install_sumo`. Verified both paths with command stubs.
- [x] **Stop leaking secrets on the Helm CLI** — done. Access ID/Key are now written
  to a `mktemp` values file (`chmod 600`) passed via `--values`, with an `EXIT` trap
  that removes it (also fires when the `ERR` trap exits on failure). A `yaml_escape`
  helper safely quotes the values. Only the non-secret `clusterName` stays on the CLI.
  Verified: no secret in helm argv, file is 0600, escaping round-trips, file removed.
- [x] **Cross-platform secret storage** — done. Added a `SECRET_BACKEND` selector
  (macOS Keychain → Linux `secret-tool`/libsecret → env-var fallback) and
  `secret_get`/`secret_set`/`secret_delete` helpers; `install_sumo` and `purge` now
  route through them instead of calling `security` directly. Verified all three
  backends with stubs (11/11) under bash 3.2.
- [x] **Fix architecture mapping** — done as part of the OS/arch detection above:
  `x86_64`→`amd64`, `arm64`/`aarch64`→`arm64`, with an explicit error on anything else.
  Intel Macs no longer hit 404s.

## P1 — High (reliability / UX correctness)

- [x] **Resolve cluster-name conflict** — done. Removed `name: cluster` from
  `kind-config.yaml` so the script's `--name "${CLUSTER_NAME}"` (default `sumo`) is
  the single source of truth. Create, `uninstall`, and `purge` all use `CLUSTER_NAME`,
  so teardown targets the cluster that was created. YAML still parses (kind/apiVersion/nodes).
- [x] **Declare `valid_statuses`** — done. Added to the `declare -a` line alongside
  the other valid-machine arrays so it is declared in lockstep under `set -u`.
- [x] **Pin / prompt Kubernetes version** — done. Added `select_node_image` (fetches
  kindest/node tags from Docker Hub, filters to semver, newest-first, with manual-entry
  and offline fallbacks). The "is latest OK?" → no branch now creates the cluster with
  `--image kindest/node:<tag>`. Cluster name is asked once up front. Verified 6/6.
- [x] **Validate the Helm values path** before calling Helm — done, treating the user
  values file as *optional* (the chart can install with `--set` alone). A named file
  must exist (`require_values_file` fails early with a clear message); blank falls back
  to `values.yaml` only if present, else is skipped. `install_sumo`/`output` build helm
  args in an array and only add `--values`/`-f` when a file is in use. Verified 6/6.
- [x] **Make memory/CPU minimums configurable** — done. `MIN_MEM_MB` (18432) and
  `MIN_CPU` (4) are now set once at the top via `${VAR:-default}` so they can be
  overridden by environment, with a positive-integer guard. `new_podman` also defaults
  a new machine's memory to `MIN_MEM_MB`. Verified defaults, override, and invalid input.
- [x] **Treat Docker and Podman as first-class runtimes** — done. Added
  `select_runtime` (detects both, prompts when both exist, honors a preset
  `CONTAINER_RUNTIME`, errors if neither), `set_kind_provider` (exports
  `KIND_EXPERIMENTAL_PROVIDER` to match), `ensure_podman_ready` (machine logic gated to
  macOS; native `podman info` on Linux), and `ensure_docker_ready` +
  `check_docker_resources` (equivalent readiness + resource check). `init_cluster`,
  `uninstall`, and `purge` branch by runtime; purge's machine teardown is podman+macOS
  only. Verified select/provider/ready/purge paths with stubs.

## CI/CD & Releases (gates merge to `main`)

The `main` branch now requires passing status checks, so standing up CI is a
prerequisite for *any* PR merge — treat as high priority alongside P0/P1.

- [x] **GitHub Actions CI workflow** — done. `.github/workflows/ci.yml` runs on PRs and
  pushes to `dev`, on an Ubuntu + macOS matrix: `bash -n`, `shellcheck`, `shfmt -d -i 4
  -ci` (pinned shfmt v3.13.1 on both runners), and `yamllint -c .yamllint.yml` over
  `kind-config.yaml` / `values.yaml` / `examples/*.yaml`. Scripts were shfmt-formatted
  and the YAML cleaned (trailing whitespace / final newlines) so the first run is green;
  all four checks verified locally with the exact CI commands.
- [x] **Register the check as a required status check** on `main` — done. Added a
  `required_status_checks` rule to the active `main` ruleset (id 3514911) requiring
  `Lint (ubuntu-latest)` and `Lint (macos-latest)`, alongside the existing
  `pull_request` / `required_signatures` / `deletion` / `non_fast_forward` rules and the
  admin bypass. `strict_required_status_checks_policy` is false (PRs need not be
  up-to-date with base before merging).
- [ ] **Mock-deployment validation job** — in CI, stand up a KinD cluster (e.g.
  `helm/kind-action`), run `helm template`/`helm install --dry-run` (and ideally
  `helm lint`) against `values.yaml` and the `examples/*.yaml` to prove the chart
  renders and the manifests apply. Use dummy/placeholder Sumo credentials; do not
  require real secrets. This validates a deployment without touching a live Sumo org.
  Exercise **both runtimes**: Docker on Linux runners, and Podman (e.g. via the
  `redhat-actions/podman` tooling or a Podman-backed KinD provider) so the
  first-class-both decision is actually verified in CI.
- [ ] **Release automation** — GitHub Releases with SemVer (continue from `0.4.0`).
  Tag-driven workflow (`v*.*.*`) that builds release notes (e.g. from Conventional
  Commits) and publishes the release. Update `version()` in `sumo-otel-local.sh:237-240`
  to report the same version (it currently queries the GitHub API at runtime).
- [ ] **Adopt a versioning/commit convention** — document SemVer bump rules; consider
  Conventional Commits so release notes and version bumps can be automated.

## P2 — Medium (maintainability / cleanup)

- [ ] **Remove `local-image.sh`** — its tag-picker is now superseded by
  `select_node_image` in the main script (live version selection wired into
  `kind create --image`). The remaining unique idea is the *offline* pull/save/load
  flow (all commented out). Either fold air-gapped image loading into the main script
  or just delete the file; leaning delete.
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
- [ ] Document the Keychain entries (`sumologic_access_id`/`_key`) and how to rotate them.
- [x] **`shellcheck` clean** — both `sumo-otel-local.sh` and `local-image.sh` pass
  `shellcheck` with no findings (quoted expansions, `read -r`, quoted default
  assignments, arithmetic indices). CI just needs to run it; `shfmt` still TODO.

---

## Open Questions

None currently — see resolved decisions below.

*Resolved 2026-06-12: Bash now / Python later (P3); platforms = macOS + Linux;
commit signing = GPG (already configured locally, `commit.gpgsign=true`).*
*Resolved 2026-06-15: Docker and Podman are both first-class runtimes (Docker
licensing makes Podman a required peer, not a fallback).*
