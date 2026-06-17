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

## P1 — High (reliability / UX correctness)

- [ ] **Ensure the `sumologic` Helm repo is added before use** — `output` (`-o`) never
  runs `helm repo add`, and `install_sumo`'s repo step is gated behind the "check for
  updates?" prompt (`sumo-otel-local.sh:432-438`). If the repo was never added,
  `helm template`/`upgrade ... sumologic/sumologic` fails with "repo not found". Add the
  repo unconditionally (idempotent) before any `helm template`/`upgrade`, and make the
  prompt about *updating* only. Factor into an `ensure_helm_repo` helper used by both
  `install_sumo` and `output`.

## P2 — Medium (reliability / maintainability)

- [ ] **Pre-flight dependency check for `-m`/`-o`/`-u`/`-p`** — only `-i`/`-n` run
  `install_dependencies`; the other flags call `helm`/`kind`/`jq` directly and fail
  cryptically (via the ERR trap) if a tool is missing. Add a `require_cmd` check at the
  start of those flows with a clear "install X / run -n first" message.
- [ ] **Offline `version()`** — `-v` makes a live GitHub API call
  (`sumo-otel-local.sh` `version`), so it's slow and fails offline. Embed a `VERSION`
  constant (kept in sync by release automation) and print that instead.
- [ ] **Harden `install_dependencies` direct-install path** — it hardcodes
  `/usr/local/bin` (wrong for Apple Silicon Homebrew at `/opt/homebrew`; needs `sudo`)
  and always installs `podman` even when the user runs Docker. Make it path-aware and
  avoid forcing a runtime the user isn't using.
- [ ] **Guard `kind create cluster` when the cluster already exists** — `init_cluster`
  (`:316,321,324`) lets `kind` emit a raw "already exists" error. Detect via
  `kind get clusters` and offer to reuse or recreate.
- [ ] **Verify `podman machine` `Memory` units across versions** — `use_existing_podman`
  (`:~495`) divides `Memory` by 1024/1024 assuming bytes; some Podman versions report
  MiB. Confirm the unit (or normalize) so the resource check isn't off by 1024x.
- [ ] **Remove `local-image.sh`** — superseded by `select_node_image`. The only unique
  idea left is the commented-out offline pull/save/load (air-gapped) flow; fold that into
  the main script or delete the file (leaning delete).
- [ ] **De-duplicate constants** — `DEFAULT_CLUSTER_NAME="sumo"` is redefined in several
  places; lift to a single top-level constant (alongside `MIN_MEM_MB`/`MIN_CPU`).
- [ ] **Consolidate Podman-running checks** — the "a machine is already running / stop
  it?" logic is duplicated across `new_podman` and `use_existing_podman`.
- [ ] **Consistent confirmation prompts** — mix of `[y/n]`, `[y/N]`, and case handling;
  standardize a `confirm()` helper.
- [ ] **Add a `--non-interactive` / env-driven mode** so the script can run unattended
  (needed by the CI mock-deployment job and friendlier scripting). `read` prompts
  currently fail on EOF under `set -e`.

## CI/CD & Releases

- [ ] **Mock-deployment validation job** — stand up a KinD cluster in CI (e.g.
  `helm/kind-action`), run `helm lint` + `helm template`/`install --dry-run` against
  `values.yaml` and `examples/*.yaml` with dummy credentials (no live Sumo org).
  Exercise **both runtimes**: Docker on Linux runners and a Podman-backed KinD provider.
- [ ] **Release automation** — tag-driven (`v*.*.*`) GitHub Release workflow with SemVer
  (continue from `0.4.0`) and generated notes; keep the script's `VERSION` constant in
  sync (see the offline-`version()` P2 item).
- [ ] **Adopt a versioning/commit convention** — document SemVer bump rules; consider
  Conventional Commits so notes/bumps can be automated.

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

### CI / quality (complete)

- [x] `shellcheck`-clean and `shfmt -i 4 -ci`-formatted.
- [x] GitHub Actions CI (`bash -n` + shellcheck + shfmt + yamllint) on an Ubuntu + macOS
  matrix, triggered on PRs and pushes to `dev`.
- [x] Registered `Lint (ubuntu-latest)` / `Lint (macos-latest)` as required status checks
  on the `main` ruleset.
