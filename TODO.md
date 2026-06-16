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
- [ ] **Pin / prompt Kubernetes version** — `init_cluster` always uses "latest"
  (`sumo-otel-local.sh:100-108`); the "choose a version" branch is a dead-end `echo`.
  Wire it to a real `--image kindest/node:<tag>` selection (see `local-image.sh`).
- [ ] **Validate the Helm values path** before calling Helm (`:131-159`) — fail early
  with a clear message if the file doesn't exist.
- [ ] **Make memory/CPU minimums configurable** — `MIN_MEM_MB=18432`, `MIN_CPU=4` are
  hardcoded (`sumo-otel-local.sh:274-275`); allow override via flag/env.
- [ ] **Treat Docker and Podman as first-class runtimes** — today `init_cluster`
  centers on Podman and only asks a yes/no "Are you using Docker Desktop?"
  (`sumo-otel-local.sh:83-98`), while the Podman machine/resource logic
  (`new_podman`, `use_existing_podman`) has no Docker equivalent. Detect the available
  runtime, let the user choose when both exist, and gate Podman-machine handling so
  Docker users get an equivalent (resource check + KinD provider) path. Podman-only
  operations like `purge` (`:199-216`) must no-op or branch cleanly under Docker.

## CI/CD & Releases (gates merge to `main`)

The `main` branch now requires passing status checks, so standing up CI is a
prerequisite for *any* PR merge — treat as high priority alongside P0/P1.

- [ ] **GitHub Actions CI workflow** — `.github/workflows/ci.yml` triggered on PRs and
  pushes to `dev`. At minimum: `shellcheck` + `shfmt --diff` on `*.sh`, and a YAML lint
  on `kind-config.yaml` / `values.yaml` / `examples/*.yaml`. Run on both macOS and Linux
  runners to back the macOS+Linux support goal.
- [ ] **Register the check as a required status check** on `main` once the workflow name
  is stable, so the branch-protection rule is actually enforced.
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
