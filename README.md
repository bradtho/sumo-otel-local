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

Follow the in-script prompts. To tear everything down again, use `-u` (cluster) or
`-p` (cluster and, with Podman on macOS, the Podman machine).

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
```

`-y`/`--yes` is a modifier, combine it with an action, e.g. `./sumo-otel-local.sh -y -i`.
In unattended mode the Sumo credentials **must** come from secret storage or the
environment (the script will not block on a prompt).

## Configuration

The script reads a few environment variables; all are optional.

- **`CONTAINER_RUNTIME`** (default: _prompt_) — force the runtime: `docker` or
  `podman`. If unset and both are installed you're prompted; if only one is present
  it's used automatically.
- **`MIN_MEM_MB`** (default: `18432`) — minimum memory (MiB) the runtime/VM must have;
  also the size of a newly-created Podman machine.
- **`MIN_CPU`** (default: `4`) — minimum vCPUs the runtime/VM must have.
- **`ASSUME_YES`** (default: _unset_) — any non-empty value runs unattended (same as `-y`).
- **`SUMOLOGIC_ACCESS_ID`** / **`SUMOLOGIC_ACCESS_KEY`** (default: _unset_) — your Sumo
  credentials, used when no secret backend is available (see below).

Example — force Docker with a smaller footprint, unattended:

```bash
CONTAINER_RUNTIME=docker MIN_MEM_MB=8192 MIN_CPU=2 \
  SUMOLOGIC_ACCESS_ID=xxxx SUMOLOGIC_ACCESS_KEY=yyyy \
  ./sumo-otel-local.sh -y -i
```

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

During cluster creation the script fetches the available `kindest/node` image tags and
lets you pick a Kubernetes version (e.g. `v1.32.2`), or press Enter to use kind's
default. If the tag list can't be fetched (offline), you can type a version manually.

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
