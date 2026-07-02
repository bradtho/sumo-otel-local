# CLAUDE.md

Guidance for working in this repository. See [README.md](README.md) for user-facing
usage and [CONTRIBUTING.md](CONTRIBUTING.md) for the versioning/commit conventions.

## What this is

A single Bash script, [`sumo-otel-local.sh`](sumo-otel-local.sh), that bootstraps a
local [KinD](https://kind.sigs.k8s.io/) cluster and installs the Sumo Logic
OpenTelemetry Collector Helm chart (`sumologic/sumologic`) for local testing. Runs on
**macOS and Linux**, backed by **Docker or Podman**.

## Repository layout

- `sumo-otel-local.sh` — the entire tool (~930 lines). Everything below lives here.
- `kind-config.yaml` — 3-node KinD cluster (1 control-plane, 2 workers). The cluster
  **name is intentionally not set here**; the script owns it via `--name` (default `sumo`).
- `values.yaml` — default Helm values (used by `-o`/`-m` if present).
- `examples/` — advanced Helm values files + their `README.md`.
- `manifests/metrics_auth.yaml` — sample K8s resources for the `metrics_auth` example.
- `.github/workflows/ci.yml` — lint matrix (Ubuntu+macOS) + `mock-deploy` validation.
- `.github/workflows/release-please.yml` + `release-please-config.json` +
  `.release-please-manifest.json` — release automation.
- `.yamllint.yml` — relaxed yamllint config.
- `TODO.md` — prioritised backlog with a "Done" section recording completed work.

## Script structure

Top of file: `set -euo pipefail`, an `on_error` ERR trap (reports and exits; it does
**not** delete anything), platform detection (`OS`, `ARCH`, `JQ_OS`), the
`SECRET_BACKEND` selection, and the overridable constants (`MIN_MEM_MB`, `MIN_CPU`,
`CONTAINER_RUNTIME`, `VERSION`, `DEFAULT_CLUSTER_NAME`, `ASSUME_YES`).

Flags are parsed in a `while`/`case` loop at the bottom. Each **action** flag runs its
flow and `exit`s; `-y`/`--yes`/`--non-interactive` is a **modifier** (sets
`ASSUME_YES`, then falls through to process the action), so it goes before the action,
e.g. `-y -i`.

| Flag             | Flow (functions called)                                  |
| ---------------- | -------------------------------------------------------- |
| `-i/--install`   | `preflight_credentials` (unattended) → `install_dependencies` → `init_cluster` → `install_sumo` |
| `-n/--init`      | `install_dependencies` → `init_cluster`                  |
| `-m/--helm`      | `install_sumo` (existing cluster)                        |
| `-o/--output`    | `output` (renders manifests via `helm template`)         |
| `-s/--status`    | `status` (read-only doctor; all probes non-fatal)        |
| `-u/--uninstall` | `uninstall` (deletes the cluster)                        |
| `-p/--purge`     | `purge` (cluster + Podman machine on macOS + secrets)    |
| `-v/--version`   | `version` (offline; prints `VERSION`)                    |

Key helper groups:

- **Prompts:** `confirm` (y/n with `[Y/n]`/`[y/N]` hints) and `ask` (value with
  default). Both honour `ASSUME_YES`. **All interactive prompts must route through
  these** so unattended mode works.
- **Runtime:** `select_runtime` (docker/podman, honours `CONTAINER_RUNTIME`),
  `set_kind_provider` (exports `KIND_EXPERIMENTAL_PROVIDER`), `ensure_podman_ready` /
  `ensure_docker_ready`, `check_docker_resources` (enforces `MIN_MEM_MB`/`MIN_CPU`),
  `new_podman` / `use_existing_podman` / `stop_running_machine`, `mem_to_mib`.
- **Cluster:** `cluster_exists`, `init_cluster` (offers reuse/recreate/cancel if the
  named cluster exists), `select_node_image` (prompts for a `kindest/node` tag).
- **Helm:** `ensure_helm_repo` (idempotent `repo add --force-update`),
  `require_values_file` (values files are **optional**; only validated when used),
  `yaml_escape`, `install_sumo`, `output`.
- **Secrets:** `secret_get`/`secret_set`/`secret_delete`/`secret_env_var` over
  `SECRET_BACKEND` ∈ {`keychain`, `secret-tool`, `env`}. Stored under
  `sumologic_access_id` / `sumologic_access_key`. `secret_get` falls back to the
  `SUMOLOGIC_ACCESS_ID`/`KEY` env vars on **every** backend (a stored keyring value wins).
  `store_credentials` (the `--store-credentials` action) persists creds to the keyring
  without installing; `preflight_credentials` runs first on an unattended `-i`/`-m`/`-r`
  and **fails fast** if creds aren't available, before deps/Podman/cluster work.
  Credentials are **never** passed on the Helm CLI — they go in a `chmod 600` temp values
  file deleted on exit.
- **Dependencies:** `install_dependencies` (brew on macOS, direct binary downloads on
  Linux), `install_bin_dir`, `install_binary`, `require_cmd` (fail-fast pre-flight for
  flows that skip dependency install).

## Hard constraints

- **Bash 3.2 compatible** (macOS ships 3.2). No `declare -A`/associative arrays, no
  `${var^^}` — use `tr`, indexed arrays, and temp files instead.
- **`set -euo pipefail`** is in force: guard optional vars with `${var:-}`.
- **Credentials never on the command line / process list.** Keep the temp-values-file
  pattern.
- **Stderr for UI, stdout for results.** Functions whose output is captured with
  `$(...)` (e.g. `select_node_image`) must send prompts/logs to `>&2`.

## Lint & validate (this is the CI gate)

Run before every commit — CI runs exactly these on an Ubuntu + macOS matrix:

```bash
bash -n sumo-otel-local.sh                       # syntax
shellcheck sumo-otel-local.sh                     # lint (must be clean)
shfmt -d -i 4 -ci sumo-otel-local.sh              # format (4-space indent, switch-case indent)
yamllint -c .yamllint.yml kind-config.yaml values.yaml examples/*.yaml
npx markdownlint-cli2 "**/*.md" "!CHANGELOG.md"   # Markdown (config: .markdownlint.jsonc)
```

`shfmt -w -i 4 -ci sumo-otel-local.sh` rewrites in place. markdownlint config lives in
`.markdownlint.jsonc` (relaxed, like `.yamllint.yml`); `CHANGELOG.md` is excluded (it is
release-please-generated). In CI, markdownlint runs once (Linux only) inside the `Lint` job.

The **`mock-deploy`** CI job additionally renders the chart against every values file
with dummy creds + `kubeconform`, then validates server-side on a KinD cluster
(`helm install --dry-run=server`). No live Sumo org is required.

## How changes are verified

A committed **bats-core** suite lives in `tests/` and runs in CI (the `Tests
(ubuntu-latest)` / `Tests (macos-latest)` jobs). Run it locally with `bats tests/`
(`brew install bats-core` / `apt-get install -y bats`).

- `tests/test_helper.bash` — `load_script` sources the script (strict mode + the ERR
  trap live in `main()`, guarded by `BASH_SOURCE == $0`, so sourcing has no side
  effects), plus `setup_stubs` / `stub_cmd` / `assert_called` / `refute_called`.
- `tests/unit.bats` — pure functions (`mem_to_mib`, `yaml_escape`, `secret_env_var`,
  `confirm`/`ask`, the `MIN_*` validation).
- `tests/verify.bats` — the download-integrity helpers (`sha256_of`, `remote_sha256`,
  `verify_sha256`: accept / mismatch / fail-closed).
- `tests/flow.bats` — action functions against stubbed externals: the
  `confirm_destructive` teardown gate, `uninstall`/`purge`, and `install_sumo`/`output`
  arg-building (including that credentials never reach the helm command line).

Pattern: override external commands (`kind`, `helm`, `podman`, …) as Bash functions
that record argv, or use `stub_cmd` for PATH stubs; drive the target function with
`run`; assert on `$status`/`$output` or the recorded calls. Functions that set an EXIT
trap (`install_sumo`, `output`) are driven inside a subshell (`run bash -c '…'`) so the
trap can't disturb bats. Feed prompt input via here-strings so `read` sees it.

## Workflow & releases

- Work on **`dev`**; `main` is protected (PRs + **GPG-signed commits** + required
  checks `Lint (ubuntu-latest)` / `Lint (macos-latest)`; admin bypass). Commit with
  `git commit -S`. After a squash-merge, reset `dev` onto `main`.
- **Conventional Commits**, enforced at the **PR title** (squash-merge makes the PR
  title the commit subject on `main`). `feat:`→MINOR, `fix:`→PATCH; `ci`/`docs`/`chore`
  /`refactor` don't bump. While `0.x`, breaking changes bump MINOR.
- `release-please` runs on push to `main`, opens a release PR from the conventional
  subjects, and on merge tags `vX.Y.Z` + rewrites the `VERSION` line (annotated
  `# x-release-please-version`). Keep that annotation intact.
