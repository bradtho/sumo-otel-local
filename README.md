# sumo-otel-local

Sumo OTEL Collector local bootstrapper for **macOS and Linux**.

## About

A quick way to test the Sumo Logic OpenTelemetry Collector on a local
[KinD](https://kind.sigs.k8s.io/) cluster. The bundled `kind-config.yaml` creates a
3-node cluster (one control-plane, two workers) — enough to install the collector and
validate configuration.

It runs on **macOS and Linux** (Intel/`amd64` and Apple Silicon/`arm64`) and supports
**Docker and Podman** as first-class container runtimes — if both are installed it
asks which to use; otherwise it uses whichever is present.

## Prerequisites

- **A container runtime: Docker or Podman.** If neither is installed, `--install` /
  `--init` will offer to install Podman (via Homebrew on macOS, or with guidance on
  Linux).
- **macOS:** [Homebrew](https://brew.sh/) — used to install the remaining tools.
- **Linux:** `curl` and `tar` — the script downloads the remaining tools directly.
- Remaining CLIs (`kind`, `kubectl`, `helm`, `jq`) are installed for you by
  `--install` / `--init` if they are missing.
- A Sumo Logic **Access ID** and **Access Key** (prompted for, or supplied via secret
  storage / environment — see [Credentials](#credentials--secret-storage)).

> **Resources:** the collector stack is memory-hungry. By default the script expects
> the runtime/VM to have at least **18 GiB RAM (`18432` MiB) and 4 vCPUs**, and a new
> Podman machine is created with those defaults. Both are overridable — see
> [Configuration](#configuration).

## Basic usage

Clone the repo and run the script:

```bash
git clone git@github.com:bradtho/sumo-otel-local.git
cd sumo-otel-local
chmod +x sumo-otel-local.sh
./sumo-otel-local.sh -i
```

Follow the in-script prompts. Install offers to **wait for the collector pods to become
ready** (`helm --wait`) and, on success, prints copy-paste next steps (watch pods, tail
the collector logs, run `-s`/`--status`, and verify data in Sumo); on failure it points
you at `-s`. To tear everything down again, use `-u` (cluster) or `-p` (cluster and, with
Podman on macOS, the Podman machine).

## Commands

```text
Usage: ./sumo-otel-local.sh [options]
Options:
  -h, --help      Display this help message.
  -i, --install   Install the dependencies and setup the Sumo Operator.
  -n, --init      Install dependencies without setting up the Sumo Operator.
  -m, --helm      Install Sumo Operator onto existing cluster.
  -o, --output    Output the rendered Kubernetes manifest YAML file.
  -p, --purge     Uninstall the cluster (and, with Podman on macOS, the Podman machine).
  -u, --uninstall Uninstall the Cluster only.
  -v, --version   Display the version of the script.
  -y, --yes       Run unattended: assume yes and use defaults for all prompts.
                  (also via the ASSUME_YES env var; --non-interactive is an alias)
  -f, --force     Confirm destructive teardown (-u/-p) non-interactively.
                  Required for -u/-p under -y; never read from the environment.
```

Exactly one **action** (`-i`/`-n`/`-m`/`-o`/`-p`/`-u`/`-v`) is run per invocation;
giving two different actions is rejected with a clear error, and `-h`/`--help` always
wins. `-y`/`--yes` and `-f`/`--force` are **modifiers** and are order-independent —
combine either with an action in any order, e.g. `./sumo-otel-local.sh -y -i` or
`./sumo-otel-local.sh -i -y`. Short flags may also be **clustered**, so `-yi` is
equivalent to `-y -i`. In unattended mode the Sumo credentials **must** come from
secret storage or the environment (the script will not block on a prompt).

### Destructive teardown requires `--force` when unattended

`-y`/`ASSUME_YES` does **not** auto-confirm `-u`/`--uninstall` or `-p`/`--purge` — a
stray `ASSUME_YES` (e.g. exported in a shell profile) must never be able to delete a
cluster, Podman machine, or your stored credentials. To tear down without prompts, pass
the explicit `-f`/`--force` flag (which, unlike `ASSUME_YES`, is **never** read from the
environment); like `-y`, it can go before or after the action:

```bash
./sumo-otel-local.sh --force -u        # delete the cluster, no prompt
./sumo-otel-local.sh -y --force -p     # full unattended teardown + remove stored creds
```

Without `--force`, `-y -p` refuses and exits non-zero. Run `-u`/`-p` with no flags for
the normal interactive confirm + type-the-cluster-name guard.

## Checking status

`-s`/`--status` is a **read-only** doctor command — it changes nothing and reports:

- the selected container runtime + KinD provider;
- on macOS with Podman, the Podman machine(s) and their running state;
- whether the KinD cluster exists (prompts for the name, default `sumo`);
- the Sumo collector Helm release (`helm status sumologic -n sumologic`); and
- the collector pods (`kubectl get pods -n sumologic`).

```bash
./sumo-otel-local.sh -s
```

Every probe is non-fatal: a missing runtime, cluster, release, pod, or CLI tool is
reported as "not found"/"not installed" rather than erroring out.

## Configuration

The script reads a few environment variables; all are optional.

- **`CONTAINER_RUNTIME`** (default: _prompt_) — force the runtime: `docker` or
  `podman`. If unset and both are installed you're prompted; if only one is present
  it's used automatically.
- **`MIN_MEM_MB`** (default: `18432`) — minimum memory (MiB) the runtime/VM must have;
  also the size of a newly-created Podman machine.
- **`MIN_CPU`** (default: `4`) — minimum vCPUs the runtime/VM must have.
- **`ASSUME_YES`** (default: _unset_) — any non-empty value runs unattended (same as `-y`).
- **`SUMO_CHART_VERSION`** (default: pinned in the script) — the `sumologic/sumologic`
  chart version that install and `-o`/--output use. Pinned for reproducibility (CI
  validates the pinned version). Set it in the environment to use a specific version
  without prompting, e.g. `SUMO_CHART_VERSION=5.3.0`. When **not** set in the
  environment, an interactive run lets you pick a version from the available list
  (or enter one), defaulting to the pin; unattended runs (`-y`) use the pin. The chosen
  version is echoed on install so runs are reproducible.
- **`SUMOLOGIC_ACCESS_ID`** / **`SUMOLOGIC_ACCESS_KEY`** (default: _unset_) — your Sumo
  credentials, used when no secret backend is available (see below).

Example — force Docker with a smaller footprint, unattended:

```bash
CONTAINER_RUNTIME=docker MIN_MEM_MB=8192 MIN_CPU=2 \
  SUMOLOGIC_ACCESS_ID=xxxx SUMOLOGIC_ACCESS_KEY=yyyy \
  ./sumo-otel-local.sh -y -i
```

### Pinned tool versions

The **direct-download** install path (the no-Homebrew fallback) pins each CLI to a
known-good version so runs are reproducible and match what CI validates; every pin is
overridable from the environment. Homebrew always installs its current formula, so
these pins apply **only** to the direct-download path.

| Tool                            | Pinned default | Override env var       |
| ------------------------------- | -------------- | ---------------------- |
| `kubectl`                       | `v1.36.2`      | `KUBECTL_VERSION`      |
| `helm`                          | `v4.2.2`       | `HELM_VERSION`         |
| `kind`                          | `v0.32.0`      | `KIND_VERSION`         |
| `podman` (macOS direct install) | `v6.0.0`       | `PODMAN_VERSION`       |
| `sumologic/sumologic` chart     | `5.2.0`        | `SUMO_CHART_VERSION`   |
| `kindest/node` (Kubernetes)     | `v1.36.1`      | `KINDEST_NODE_VERSION` |

CI installs the **same `helm`** as the script's `HELM_VERSION` and creates its KinD
cluster with the **same `kind` + `kindest/node`** (so render/dry-run match what users
deploy), and [Renovate](#contributing) keeps these pins current via annotations next to
each constant. `KINDEST_NODE_VERSION` is the default node image kind `v0.32.0` ships and
tests with, so it's coupled to `KIND_VERSION` (bump them together) — that's why it isn't
Renovate-tracked. You can still pick another version interactively — see
[Kubernetes version](#kubernetes-version).

### Project config file

For repeatable runs, drop a **`.sumo-otel-local.env`** in your working directory and the
script sources it on startup (it's plain shell — `KEY=value` lines, no YAML parser). It
can set any of the knobs above (`CONTAINER_RUNTIME`, `CLUSTER_NAME`, `SUMO_CHART_VERSION`,
`HELM_VALUES`, `MIN_MEM_MB`, `MIN_CPU`, `ASSUME_YES`) so you don't re-answer prompts.
Copy [`.sumo-otel-local.env.example`](.sumo-otel-local.env.example) to get started; the
real file is git-ignored. Point `SUMO_CONFIG_FILE` at another path, or `=/dev/null` to
ignore it for a run. For safety it **cannot** enable `--force` or carry credentials.

## Credentials & secret storage

Your Sumo Access ID/Key are stored once and reused on later runs. The backend is
chosen automatically:

- **macOS** → Keychain (`security`), under the items `sumologic_access_id` and
  `sumologic_access_key`.
- **Linux** → libsecret (`secret-tool`), if installed, under the same names.
- **Fallback** → environment variables `SUMOLOGIC_ACCESS_ID` / `SUMOLOGIC_ACCESS_KEY`
  (nothing is persisted; export them to avoid re-entering).

Both entries are named `sumologic_access_id` and `sumologic_access_key`. The install
flow only prompts when an entry is **not found** — once stored, it is reused silently,
so to change credentials you must overwrite or delete the stored entry (see below).

Credentials are never passed on the Helm command line — they're written to a private,
`chmod 600` temporary values file that is deleted on exit.

### Inspecting & rotating credentials

**macOS Keychain** (the same items appear in _Keychain Access.app_):

```bash
# Inspect
security find-generic-password -s sumologic_access_id -w

# Rotate in place (-U updates the existing item)
security add-generic-password -U -a "$USER" -s sumologic_access_id -w 'NEW_ACCESS_ID'
security add-generic-password -U -a "$USER" -s sumologic_access_key -w 'NEW_ACCESS_KEY'

# …or delete so the next install re-prompts
security delete-generic-password -s sumologic_access_id
security delete-generic-password -s sumologic_access_key
```

**Linux libsecret** (`secret-tool`):

```bash
# Inspect
secret-tool lookup service sumologic_access_id

# Rotate (store overwrites the existing entry)
printf %s 'NEW_ACCESS_ID'  | secret-tool store --label=sumologic_access_id  service sumologic_access_id
printf %s 'NEW_ACCESS_KEY' | secret-tool store --label=sumologic_access_key service sumologic_access_key

# …or clear so the next install re-prompts
secret-tool clear service sumologic_access_id
secret-tool clear service sumologic_access_key
```

**Environment fallback:** nothing is cached — just re-export `SUMOLOGIC_ACCESS_ID` /
`SUMOLOGIC_ACCESS_KEY` with the new values.

`-p`/`--purge` also removes both stored entries, but it tears down the cluster (and the
Podman machine on macOS) too — for a credentials-only change, prefer the per-backend
commands above.

## Kubernetes version

During cluster creation the script offers to use the **pinned** Kubernetes version
(`kindest/node:v1.36.1` by default — the image kind `v0.32.0` ships and tests with, so
the cluster is reproducible and matches CI). Accept it (the default) for a known-good
cluster, or decline to pick another version: the script fetches the available
`kindest/node` image tags and lets you choose one (e.g. `v1.32.2`), enter a tag manually,
or fall back to kind's built-in default. Override the pin non-interactively with
`KINDEST_NODE_VERSION` (see [Pinned tool versions](#pinned-tool-versions)).

## Container runtimes

Docker and Podman are both first-class:

- Set `CONTAINER_RUNTIME=docker` or `CONTAINER_RUNTIME=podman` to choose
  non-interactively, otherwise you're prompted when both are present.
- On macOS, Podman runs in a VM ("machine"); the script will create/start one sized to
  `MIN_MEM_MB` / `MIN_CPU` if needed. On Linux, Podman runs natively.
- KinD is pointed at the selected runtime automatically
  (`KIND_EXPERIMENTAL_PROVIDER=podman` when Podman is chosen).

## Advanced (Sandpit)

The `examples` folder contains a curated list of advanced implementation methods.
Instructions are in the [examples README](./examples/README.md).

You may wish to create a Helm `values.yaml` (pass it when prompted, or via the
chart's `--set` values) or to amend the `--set`/`--set-string` entries in
`sumo-otel-local.sh`.

## Caveat

On the Docker/Podman VM, `--set sumologic.logs.systemd.enabled=false` is required —
these environments don't write to journald and the install would otherwise fail. The
script also sets `sumologic.falco.enabled=false`.

## Editing the cluster

Instructions for amending `kind-config.yaml` are on the
[KinD website](https://kind.sigs.k8s.io/docs/user/configuration/#getting-started).
Note the cluster name is **not** set in that file — `sumo-otel-local.sh` owns it via
`--name` (default `sumo`).

## Contributing

This started as a basic bootstrapping script; PRs and issues are welcome. See
[CONTRIBUTING.md](./CONTRIBUTING.md) for the versioning and commit conventions
(SemVer + Conventional Commits) used to automate releases.
