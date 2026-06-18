# TODO

Work backlog for `sumo-otel-local`, ordered by criticality. Line references point
at the current Bash implementation.

**Decisions:**

- **Language:** Stay on Bash for now; revisit a Python port (P3) once the script is
  stable. (2026-06-12)
- **Platforms:** Support **macOS + Linux** — arch/OS detection, dependency install,
  and secret storage must not assume macOS-only tooling. (2026-06-12)
- **Container runtime:** Docker **and** Podman are both **first-class** (Docker Desktop
  licensing makes Podman a required peer, not a fallback). (2026-06-15)
- **Releases:** GitHub Releases with semantic versioning; latest published is `0.4.0`.
- **Merge rules on `main`:** PRs, signed commits (GPG), and the CI status checks
  `Lint (ubuntu-latest)` / `Lint (macos-latest)` are all required; admin can bypass.
  `dev` is the working branch and is kept rebased on `main` after each squash-merge.

---

## P3 — Decision: Bash → Python migration

- [ ] **Decide whether to port to Python.** Pros: real arg parsing (`argparse`/`click`),
  structured error handling, testable functions (`pytest`), JSON without `jq`. Cons:
  adds a runtime dependency; the Bash script is now stable and well-tested.
- [ ] If yes: scaffold a `click` CLI mirroring the flags (`-i/-n/-m/-o/-p/-u/-v`),
  shelling out to `kubectl`/`helm`/`kind`/`podman`/`docker`; add `pyproject.toml`,
  `pytest`, and extend CI.

## P4 — Docs / housekeeping

- [ ] **Update README** — it still says "for MacOS" and references a non-existent
  `install.sh` (should be `sumo-otel-local.sh`); document macOS **+ Linux**, both
  runtimes, the env knobs (`CONTAINER_RUNTIME`, `MIN_MEM_MB`, `MIN_CPU`,
  `SUMOLOGIC_ACCESS_ID/KEY`), and the new Kubernetes-version prompt.
- [ ] **Add `CLAUDE.md`** (run `/init`) documenting structure, prerequisites, and the
  install/uninstall flows.
- [ ] **Document the secret entries** (`sumologic_access_id`/`_key`) per backend
  (Keychain / secret-tool / env) and how to rotate them.
- [ ] **`.gitignore` generated artifacts** — the `output` default `sumologic-rendered.yaml`
  and direct-install leftovers (downloaded `kind`/`kubectl`, podman zips). Currently only
  `.DS_Store` and `*.tar*` are ignored.
- [ ] **Lint `manifests/*.yaml` too** — CI's yamllint currently covers `kind-config.yaml`,
  `values.yaml`, and `examples/*.yaml` but not `manifests/`.

---

## Done

### P0 — Critical (all complete)

- [x] OS/arch-aware downloads for `kind`/`kubectl`/`jq`/`podman` (normalized `OS`/`ARCH`;
  no more `kind-linux-amd64` on macOS or Intel-Mac 404s).
- [x] Replaced the destructive `trap cleanup ERR` (which could delete the cluster on any
  failure) with `on_error`, which only reports and exits.
- [x] Fixed `--install` aborting before cluster creation (Podman helpers now `return`
  instead of `exit`).
- [x] Stopped leaking Sumo credentials on the Helm CLI — written to a `chmod 600` temp
  values file removed on exit; `yaml_escape` for safe encoding.
- [x] Cross-platform secret storage (`SECRET_BACKEND`: Keychain → secret-tool → env) via
  `secret_get`/`secret_set`/`secret_delete`.

### P1 — High (all complete)

- [x] Ensure the `sumologic` Helm repo is registered before any `helm template`/`upgrade`
  — added an `ensure_helm_repo` helper (idempotent `helm repo add --force-update`, with
  an optional index update) used by both `install_sumo` and `output`; the prompt now only
  controls refreshing the index. Verified all paths add the repo (6/6).
- [x] Resolved the cluster-name conflict (dropped `name:` from `kind-config.yaml`;
  `--name` is the single source of truth).
- [x] Declared `valid_statuses` alongside the other valid-machine arrays.
- [x] Kubernetes version selection (`select_node_image` → `kind create --image`) with
  manual + offline fallbacks.
- [x] Helm values file validated and treated as optional (`require_values_file`;
  `--values`/`-f` added only when a file is in use).
- [x] Configurable Podman minimums (`MIN_MEM_MB`/`MIN_CPU` env-overridable, validated).
- [x] Docker and Podman both first-class (`select_runtime`, `set_kind_provider`,
  `ensure_podman_ready`/`ensure_docker_ready`, runtime-branched `purge`/`uninstall`).

### P2 — Medium (complete)

- [x] Standardized confirmation prompts behind a `confirm()` helper (consistent
  `[y/N]`/`[Y/n]` hints + default handling); all y/n prompts now route through it.
- [x] Added an unattended / env-driven mode — `-y`/`--yes`/`--non-interactive` (or the
  `ASSUME_YES` env var). `confirm()` auto-answers yes and an `ask()` helper returns
  defaults without blocking; value prompts use it. The flag is a modifier (e.g. `-y -i`).
  Secrets must come from storage/env in unattended mode (clear error otherwise).
  Verified confirm/ask both modes, flag parsing, and a no-stdin uninstall (15/15).
- [x] De-duplicated `DEFAULT_CLUSTER_NAME` — lifted to a single top-level constant
  (with `VERSION`/`MIN_*`); removed the four inline `="sumo"` assignments.
- [x] Consolidated the Podman "a machine is already running / stop it?" logic into a
  single `stop_running_machine` helper owned by `new_podman` (called before init/start);
  removed the duplicate block from `use_existing_podman`. Verified (10/10).
- [x] Removed `local-image.sh` — its tag picker was superseded by `select_node_image`,
  and the only unique bit (a commented-out offline pull/save/load flow) wasn't wired up.
  Deleted; no references remained.
- [x] Normalize `podman machine` `Memory` units — confirmed podman 5.x reports bytes
  (`"19327352832"` = 18432 MiB); older versions reported MiB. Added a magnitude-based
  `mem_to_mib` helper (≥ 1 GiB-in-bytes → bytes, else already MiB) so the resource check
  isn't off by 1024×. Verified both unit conventions + boundary/non-numeric (6/6).
- [x] Guard `kind create cluster` when the cluster already exists — `cluster_exists`
  (via `kind get clusters`) detects a same-named cluster and `init_cluster` offers
  reuse / recreate (delete + create) / cancel instead of letting kind emit a raw error.
  Verified all branches with stubs (8/8).
- [x] Offline `version()` — `-v` now prints an embedded `VERSION` constant (`0.4.0`)
  instead of querying the GitHub API; no network/`jq`/`curl`. Release automation will
  keep the constant in sync.
- [x] Pre-flight dependency check — added `require_cmd` and called it at the start of the
  flows that skip `install_dependencies`: `install_sumo`/`output` require `helm`,
  `uninstall`/`purge` require `kind` (purge's Podman-machine branch also requires `jq`).
  Missing tools now fail fast with "install X / run -n first" instead of a cryptic ERR
  trap. Verified all four flows fail fast (4/4).
- [x] Hardened `install_dependencies` — added `install_bin_dir` (prefers a writable
  on-PATH dir, falls back to `/usr/local/bin` with `sudo` only when needed, warns if not
  on PATH) and `install_binary`; direct installs download to `/tmp` then route through it.
  The runtime (podman) is only installed when the user has neither Docker nor Podman
  (both the brew and direct paths). Verified the helpers with stubs (5/5).

### CI / quality (complete)

- [x] **Release automation** (`release-please`) — a `release-please.yml` workflow with
  `release-please-config.json` and `.release-please-manifest.json`. On each push to `main`
  it maintains a release PR whose version/`CHANGELOG.md` are derived from the Conventional-
  Commit (PR-title) subjects since the last release; merging it tags `vX.Y.Z`, publishes a
  GitHub Release, and rewrites the script's `VERSION` line (annotated
  `# x-release-please-version`). Anchored at `last-release-sha` = `main` HEAD so old
  non-conventional subjects are ignored. Uses `RELEASE_PLEASE_TOKEN` (PAT) if set so the
  release PR runs CI; otherwise the release PR is merged with admin bypass.
- [x] **Adopted a versioning/commit convention** — [CONTRIBUTING.md](CONTRIBUTING.md)
  documents SemVer bump rules (with the pre-1.0 `0.x` caveat and the CLI-contract
  definition of "public API"), Conventional Commits with a type→bump table, the
  squash-merge implication that **PR titles** are the canonical subjects, and the
  manual release steps + `VERSION`-constant sync. Sets up the release-automation item.
- [x] **Mock-deployment validation job** (`mock-deploy`) — adds the `sumologic` repo and
  renders the upstream chart against `values.yaml` + every `examples/*.yaml` with dummy
  credentials (mirroring `install_sumo`'s exact `--set` flags), asserts a non-empty render,
  and schema-checks the output with `kubeconform -ignore-missing-schemas`. Then a KinD
  cluster (Docker, `helm/kind-action`) pre-applies the chart's 12 CRDs and runs
  `helm install --dry-run=server` per values file. No live Sumo org required.
- [x] **Reviewed the KinD server-side dry-run** (2026-06-18) — kept it. Across 4 CI runs
  it was 4/4 green with no retries; the job is ~85s (render+kubeconform 16s, KinD create
  39s, CRD apply 5s, server dry-run 18s), on par with the lint jobs — neither flaky nor
  slow by the review criterion. Added `timeout-minutes: 15` so a future KinD hang fails
  fast instead of inheriting the 6-hour default. Documented fallback if it ever regresses:
  drop to `--dry-run=client`, or rely on the cluster-free render+kubeconform gate.
- [x] **Fixed `examples/metrics_auth.yaml`** — it set the chart-v5-rejected
  `kube-prometheus-stack.{prometheusOperator,prometheus}.enabled: true` (the render gate
  caught it). Removed those toggles; the `additionalServiceMonitors` intent is preserved
  (the ServiceMonitor CRD/operator ship with the chart's bundled dependency). README updated.
- [x] `shellcheck`-clean and `shfmt -i 4 -ci`-formatted.
- [x] GitHub Actions CI (`bash -n` + shellcheck + shfmt + yamllint) on an Ubuntu + macOS
  matrix, triggered on PRs and pushes to `dev`.
- [x] Registered `Lint (ubuntu-latest)` / `Lint (macos-latest)` as required status checks
  on the `main` ruleset.
