#!/bin/bash

# Strict mode and the ERR trap are enabled inside main() (see bottom), not at the top
# level, so the script can be safely `source`d by the test suite (tests/) to exercise
# individual functions without running the CLI, enabling errexit, or installing traps.

# --- Usage --------------------------------------------------------------------
function help {
    # Flags are coloured bold-green, headings bold, the footer dim. Colour vars are empty
    # unless stderr is a TTY (set at top level; help is only ever called after that), so the
    # TEXT is unchanged when captured/piped — the tests match on the plain substrings.
    local f="${C_BOLD}${C_GREEN}" h="${C_BOLD}" d="${C_DIM}" r="${C_RESET}"
    echo "${h}Usage:${r} $0 [options]"
    echo "${h}Options:${r}"
    echo "  ${f}-h, --help${r}      Display this help message."
    echo "  ${f}-i, --install${r}   Install the dependencies and setup the Sumo Operator."
    echo "  ${f}-n, --init${r}      Install dependencies without setting up the Sumo Operator."
    echo "  ${f}-m, --helm${r}      Install or upgrade the Sumo collector on an existing cluster."
    echo "  ${f}-r, --reinstall${r} Uninstall the Sumo collector then reinstall it (cluster stays)."
    echo "  ${f}-o, --output${r}    Output the rendered Kubernetes manifest YAML file."
    echo "  ${f}-s, --status${r}    Report cluster and collector health (read-only)."
    echo "  ${f}-e, --endpoints${r} Print the Sumo collection endpoints from the 'sumologic' secret."
    echo "      ${f}--forward${r}   Port-forward the traces collector's OTLP receiver to localhost:4317/4318."
    echo "  ${f}-p, --purge${r}     Uninstall the cluster (and, with Podman on macOS, the Podman machine)."
    echo "  ${f}-u, --uninstall${r} Uninstall the Cluster only."
    echo "  ${f}-v, --version${r}   Display the version of the script."
    echo "      ${f}--init-config${r}  Create .sumo-otel-local.env from the bundled template, then edit it"
    echo "                  to preset the Sumo region, cluster, chart version, etc. and skip prompts."
    echo "      ${f}--store-credentials${r}  Save the Sumo Access ID/Key in the OS keyring so unattended"
    echo "                  installs can reuse them (takes SUMOLOGIC_ACCESS_ID/KEY if set, else prompts)."
    echo "  ${f}-y, --yes${r}       Run unattended: assume yes and use defaults for all prompts."
    echo "                  (also via the ASSUME_YES env var; --non-interactive is an alias)"
    echo "  ${f}-f, --force${r}     Confirm destructive teardown (-u/-p) non-interactively."
    echo "                  Required for -u/-p under -y; never read from the environment."
    echo "      ${f}--dry-run${r}   Preview the install flow (-i/-n/-m): print the cluster-create and"
    echo "                  helm commands without creating/installing anything."
    echo "  ${f}-V, --verbose${r}   Echo each external command (kind/helm/podman) before running it."
    echo
    echo "${d}Short flags may be combined, e.g. -yi is the same as -y -i.${r}"
}

# Detect OS and CPU architecture, normalized to the tokens used by release assets.
OS_RAW=$(uname -s)
case "$OS_RAW" in
    Darwin) OS="darwin" ;;
    Linux) OS="linux" ;;
    *)
        echo "Unsupported operating system: ${OS_RAW}. Only macOS (Darwin) and Linux are supported."
        exit 1
        ;;
esac

ARCH_RAW=$(uname -m)
case "$ARCH_RAW" in
    x86_64 | amd64) ARCH="amd64" ;;
    arm64 | aarch64) ARCH="arm64" ;;
    *)
        echo "Unsupported architecture: ${ARCH_RAW}. Only amd64 (x86_64) and arm64 (aarch64) are supported."
        exit 1
        ;;
esac

# jq names its macOS assets "macos" rather than "darwin".
if [[ "$OS" == "darwin" ]]; then
    JQ_OS="macos"
else
    JQ_OS="linux"
fi

# Directory holding this script, so bundled assets (kind-config.yaml, values.yaml)
# resolve no matter the caller's CWD. Bash 3.2-safe; works whether the script is run
# or sourced (BASH_SOURCE[0] is the script path either way). User-supplied --values
# paths stay relative to the CWD — only the bundled defaults are anchored here.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Choose a secret-storage backend: macOS Keychain, Linux libsecret (secret-tool),
# or an environment-variable fallback when neither is available.
if [[ "$OS" == "darwin" ]] && command -v security &>/dev/null; then
    SECRET_BACKEND="keychain"
elif command -v secret-tool &>/dev/null; then
    SECRET_BACKEND="secret-tool"
else
    SECRET_BACKEND="env"
fi

# Terminal colours for prompts, the banner, and status words. Enabled ONLY when stderr is a
# TTY and NO_COLOR is unset (https://no-color.org, an ENVIRONMENT convention — so it's read
# here, before the config file) — piped/redirected/CI output, and the captured output the
# test suite asserts on, stay plain (no escape codes leak in). UI goes to stderr, so the gate
# is on fd 2. Defined before the config load so the loader's own warnings can use them. Bash
# 3.2: plain string vars, not an associative array. NB: cyan/yellow wash out to near-white
# when combined with bold on many themes, so bold is paired only with blue/green/red/magenta.
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m' C_BOLD=$'\033[1m' C_DIM=$'\033[2m'
    C_RED=$'\033[31m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m' C_BLUE=$'\033[34m' C_MAGENTA=$'\033[35m'
else
    C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_MAGENTA=""
fi

# Optional project-local config for repeatable runs. A shell snippet of KEY=value lines
# (no YAML parser needed); it is sourced with `set -a` BEFORE the constants below, so it
# can set any env knob the script reads: CONTAINER_RUNTIME, CLUSTER_NAME, HELM_VALUES,
# SUMO_CHART_VERSION, MIN_MEM_MB, MIN_CPU, ASSUME_YES. See .sumo-otel-local.env.example.
# It deliberately CANNOT set FORCE (that is flag-only; reset below). Credentials are
# discouraged here (see the warning below) but — since the file is sourced under `set -a`
# — a credential in it becomes an env var and IS honoured on every backend, so the guidance
# is advisory, not enforced. Path overridable via SUMO_CONFIG_FILE.
SUMO_CONFIG_FILE="${SUMO_CONFIG_FILE:-./.sumo-otel-local.env}"
if [[ -f "$SUMO_CONFIG_FILE" ]]; then
    if [[ -r "$SUMO_CONFIG_FILE" ]]; then
        echo "Loading config from ${SUMO_CONFIG_FILE}" >&2
        # Discourage plaintext credentials on disk: warn if the file assigns them. The loader
        # still sources it under `set -a`, so a credential here becomes an env var and (via
        # secret_get's env fallback) IS now used on every backend — discouraged, not blocked.
        # Prefer the keyring (--store-credentials) or SUMOLOGIC_ACCESS_ID/KEY in the environment.
        if grep -qE '^[[:space:]]*(export[[:space:]]+)?SUMOLOGIC_ACCESS_(ID|KEY)=' "$SUMO_CONFIG_FILE"; then
            echo "${C_YELLOW}Warning: ${SUMO_CONFIG_FILE} sets Sumo credentials — storing them in a plaintext" >&2
            echo "         config on disk is discouraged; prefer secret storage or the environment.${C_RESET}" >&2
        fi
        set -a
        # shellcheck disable=SC1090
        . "$SUMO_CONFIG_FILE"
        set +a
    else
        echo "${C_YELLOW}Warning: config file ${SUMO_CONFIG_FILE} exists but is not readable; skipping it.${C_RESET}" >&2
    fi
fi

# Minimum Podman machine resources, overridable via the environment.
MIN_MEM_MB="${MIN_MEM_MB:-18432}" # minimum memory in MiB
MIN_CPU="${MIN_CPU:-4}"           # minimum vCPUs
if ! [[ "$MIN_MEM_MB" =~ ^[0-9]+$ && "$MIN_CPU" =~ ^[0-9]+$ ]]; then
    echo "MIN_MEM_MB and MIN_CPU must be positive integers (got MIN_MEM_MB='${MIN_MEM_MB}', MIN_CPU='${MIN_CPU}')." >&2
    exit 1
fi

# Container runtime (podman or docker). May be preset via the environment to skip
# the interactive prompt (e.g. CONTAINER_RUNTIME=docker); select_runtime fills it in.
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-}"

# Helm repository for the Sumo Logic collection.
SUMO_HELM_REPO_URL="https://sumologic.github.io/sumologic-kubernetes-collection"

# Pinned sumologic/sumologic chart version. The chart is otherwise mutable ("latest"),
# and a v5 breaking change has already silently broken example values — so install,
# `output`, and CI all pin this exact version for reproducibility. CI validates the
# pinned version, so what CI proves is what users deploy. Override deliberately with
# SUMO_CHART_VERSION=<x.y.z> to try a newer chart. To bump: change this default, re-run
# the examples through `helm template` (CI's mock-deploy does this), and update docs.
# When set in the environment it is used as-is (no prompt); otherwise install/output
# offer an interactive picker (select_chart_version) defaulting to this value.
if [[ -n "${SUMO_CHART_VERSION+x}" ]]; then
    CHART_VERSION_FROM_ENV="yes"
else
    CHART_VERSION_FROM_ENV=""
fi
# renovate: datasource=helm depName=sumologic registryUrl=https://sumologic.github.io/sumologic-kubernetes-collection
SUMO_CHART_VERSION="${SUMO_CHART_VERSION:-5.2.0}"

# Sumo Logic deployment endpoint. Sumo orgs live in regional deployments, each with its own
# API host; the chart's setup job authenticates against ONE of them and a blank endpoint
# defaults to us1 — so a non-us1 org gets HTTP 401 ("Credential could not be verified") even
# with valid creds. May be preset (env/config) as a region code (e.g. SUMOLOGIC_ENDPOINT=us2)
# or a full API URL (https://api.us2.sumologic.com/api/v1); blank prompts then auto-detects.
SUMOLOGIC_ENDPOINT="${SUMOLOGIC_ENDPOINT:-}"

# Known Sumo deployments (region codes), probed in order during endpoint auto-detection.
# ref: https://help.sumologic.com/docs/api/getting-started/#sumo-logic-endpoints-by-deployment-and-firewall-security
SUMO_REGIONS="us1 us2 au ca de eu fed in jp kr"

# Skip the pre-flight credential check (offline/air-gapped, or the API is firewalled). The
# chart's setup job still validates server-side. Any non-empty value skips. Not security-
# sensitive (it only forgoes an early check), so it is read from the environment.
SUMO_SKIP_CRED_CHECK="${SUMO_SKIP_CRED_CHECK:-}"

# helm --wait timeout for the collector pods. Overridable so a slow image pull doesn't force
# the default (and a bad-cred setup job no longer silently blocks for the full window — the
# pre-flight check catches it first).
HELM_WAIT_TIMEOUT="${HELM_WAIT_TIMEOUT:-10m}"

# Pinned versions for the CLIs the direct-download path installs (the no-Homebrew
# fallback). Each is env-overridable (e.g. KIND_VERSION=v0.30.0) and tracked by
# Renovate via the annotations below. Pinning replaces the old "latest"/"stable"
# lookups — including their unauthenticated GitHub API calls — so direct installs are
# reproducible and match the toolchain CI validates. NOTE: the Homebrew path always
# installs brew's current formula; these pins apply only to the direct-download path.
# renovate: datasource=github-releases depName=kubernetes/kubernetes
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.36.2}"
# renovate: datasource=github-releases depName=helm/helm
HELM_VERSION="${HELM_VERSION:-v4.2.2}"
# renovate: datasource=github-releases depName=kubernetes-sigs/kind
KIND_VERSION="${KIND_VERSION:-v0.32.0}"
# renovate: datasource=github-releases depName=containers/podman
PODMAN_VERSION="${PODMAN_VERSION:-v6.0.0}"

# Pinned kindest/node image — the Kubernetes version the KinD cluster runs. v1.36.1 is the
# default node image that kind ${KIND_VERSION} ships and tests with, so it pairs with the
# pinned kind and renders/validates against the pinned chart. Used as the default in
# init_cluster; select_node_image still lets you pick another version interactively.
# DIGEST-pinned, not just the tag: a Docker tag can be re-pushed but the digest can't, so
# pinning the sha256 makes the node image reproducible. v1.36.1@sha256:3489… is kind
# v0.32.0's default per its release notes (verified against Docker Hub). Bump the version
# and digest TOGETHER from the kind release notes. Deliberately NOT Renovate-annotated: the
# node image is coupled to KIND_VERSION, so bump it with kind, not independently. To run a
# different/unpinned version, override KINDEST_NODE_VERSION and clear KINDEST_NODE_DIGEST
# (`KINDEST_NODE_DIGEST=`), which falls back to a tag-only ref.
KINDEST_NODE_VERSION="${KINDEST_NODE_VERSION:-v1.36.1}"
# Note: `-` (not `:-`) so an explicitly-empty `KINDEST_NODE_DIGEST=` opts out to a tag-only
# ref (rather than re-applying this default, which would mismatch an overridden version).
KINDEST_NODE_DIGEST="${KINDEST_NODE_DIGEST-sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5}"
# Full image ref: tag + digest when a digest is set, else tag only (graceful override).
KINDEST_NODE_IMAGE="kindest/node:${KINDEST_NODE_VERSION}${KINDEST_NODE_DIGEST:+@${KINDEST_NODE_DIGEST}}"

# Homebrew bootstrap installer, pinned to a specific commit (not mutable HEAD) and
# verified against this SHA-256 before it is made executable and run, so --install/--init
# never execute an unreviewed upstream script. To bump: pick a newer Homebrew/install
# commit and recompute the digest (the installer itself then fetches current Homebrew).
# NOT Renovate-tracked — the content digest can't be auto-refreshed (cf. shfmt in CI).
HOMEBREW_INSTALL_COMMIT="5e78e698e405a17b63b5fe41ff747f9fccf39472"
HOMEBREW_INSTALL_SHA256="99287f194a8b3c9e6b0203a11a5fa54518be57209343e6bb954dec4635796d9d"

# Script version. Kept in sync with the published GitHub Release tag; printed by
# -v/--version without any network calls. The trailing annotation lets
# release-please rewrite this line automatically when it cuts a release.
VERSION="0.9.0" # x-release-please-version

# Default KinD cluster name, used by create and teardown. Honors a CLUSTER_NAME set in
# the environment / config file, so every name prompt (which defaults to this) and the
# teardown/status flows pick it up.
#
# CLUSTER_NAME (the runtime value, not this default) is intentionally a SHARED global, not
# a per-function local: confirm_destructive sets it for uninstall/purge to read, and
# init_cluster/reinstall set it for install_sumo to reuse so the install targets the same
# cluster (see install_sumo's `${CLUSTER_NAME:-...}` prompt default). HELM_VALUES is
# likewise a config/env knob read by install_sumo and output. Don't localise either.
DEFAULT_CLUSTER_NAME="${CLUSTER_NAME:-sumo}"

# Bundled default Helm values file and the default -o/--output render path. Constants
# (hoisted from install_sumo/output, where they were duplicated string literals); both
# flows reference them read-only.
DEFAULT_HELM_VALUES="$SCRIPT_DIR/values.yaml"
DEFAULT_K8S_YAML="sumologic-rendered.yaml"

# Chart overrides applied to EVERY install and render, so `-o`/--output mirrors what
# `-i`/`-m` deploys. Single source of truth: both install_sumo and output append this,
# and CI sources the script to reuse it. Per-invocation values (credentials,
# clusterName, user --values file) are added separately by each flow.
SUMO_COMMON_SET=(
    --set-string fullnameOverride=sumo
    --set sumologic.falco.enabled=false
    --set sumologic.logs.systemd.enabled=false
)

# Unattended mode: when set (via -y/--yes/--non-interactive or the ASSUME_YES env
# var), confirm() auto-answers yes and value prompts use their defaults without
# blocking on input.
ASSUME_YES="${ASSUME_YES:-}"

# Explicit confirmation for destructive teardown (-u/-p), set ONLY by the -f/--force
# flag. Deliberately NOT read from the environment: ASSUME_YES alone must never be able
# to delete a cluster/machine/credentials, so a stray ASSUME_YES in a shell profile
# can't trigger an irreversible wipe. See confirm_destructive().
FORCE=""

# Flag-only modifiers (never read from the environment, so a stray env var can't silently
# turn a real install into a no-op or change output): --dry-run previews the install flow
# without running the side-effecting steps; -V/--verbose echoes external commands as run.
DRY_RUN=""
VERBOSE=""

# Runtime signal (never from env/config): set once a flow has already resolved CLUSTER_NAME
# via a prompt (init_cluster on -i/-n, reinstall on -r) so install_sumo doesn't ask for it a
# SECOND time. A direct -m/--helm leaves it empty, so install_sumo still prompts there.
CLUSTER_NAME_RESOLVED=""

# Ask a yes/no question. $1=prompt, $2=default (y|n, default n). Returns 0 for yes.
# In unattended mode (ASSUME_YES) it answers yes without prompting.
function confirm {
    local prompt=$1 default=${2:-n} reply hint
    [[ "$default" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
    if [[ -n "$ASSUME_YES" ]]; then
        echo "${prompt} ${hint} y (assumed)" >&2
        return 0
    fi
    # On EOF/closed stdin (e.g. piped input with no -y) fall back to the default with a
    # clear note, rather than letting the unguarded read fail and abort via the ERR trap.
    if ! read -rp "${C_BOLD}${C_BLUE}${prompt} ${hint}${C_RESET} " reply; then
        echo "No input (stdin closed); using default '${default}'. Pass -y to run unattended." >&2
        reply=$default
    fi
    reply=${reply:-$default}
    [[ "$reply" =~ ^[Yy]$ ]]
}

# Read a value with a default ($2). In unattended mode, returns the default without
# prompting. Echoes the result to stdout.
function ask {
    local prompt=$1 default=${2:-} reply
    if [[ -n "$ASSUME_YES" ]]; then
        printf '%s' "$default"
        return 0
    fi
    # On EOF/closed stdin (e.g. piped input with no -y) fall back to the default with a
    # note on stderr, rather than letting the unguarded read fail and abort via the ERR
    # trap (ask is captured with $(...), so the note must not go to stdout).
    if ! read -rp "${C_BOLD}${C_BLUE}${prompt}${C_RESET}" reply; then
        echo "No input (stdin closed); using default '${default}'. Pass -y to run unattended." >&2
    fi
    printf '%s' "${reply:-$default}"
}

# Prompt silently for a secret, re-prompting until a non-empty value is entered, and
# echo it to stdout (for $(...) capture). Prompt and warnings go to stderr (so they
# don't pollute the captured value), per the stderr-for-UI/stdout-for-result convention.
# Aborts (return 1) on EOF/closed stdin rather than looping forever — callers reach this
# only on the interactive path (the unattended path errors before prompting).
function read_secret {
    local prompt=$1 value
    while true; do
        if ! read -rsp "${C_BOLD}${C_BLUE}${prompt}${C_RESET}" value; then
            echo "" >&2
            echo "No input (stdin closed); aborting." >&2
            return 1
        fi
        echo "" >&2
        if [[ -n "$value" ]]; then
            # Silent read shows nothing as you type/paste; echo a masked confirmation (one '*'
            # per character) so it's clear the value registered and its length looks right,
            # without revealing it. To stderr, so the captured stdout stays exactly the value.
            printf '%s\n' "${C_DIM}${value//?/*}${C_RESET}" >&2
            printf '%s' "$value"
            return 0
        fi
        echo "Value cannot be empty; please try again." >&2
    done
}

# Gate a destructive teardown (cluster / Podman machine / stored credentials). Sets
# CLUSTER_NAME to the cluster to remove and returns 0 to proceed. On an interactive
# "no" or a typed [exit] it prints a cancel message and exits 0.
#
# Unlike confirm(), this does NOT proceed under ASSUME_YES alone — unattended teardown
# requires the explicit -f/--force flag (FORCE), so a stray ASSUME_YES env var cannot
# trigger an irreversible wipe. With --force it proceeds on the default cluster without
# prompting. $1 = human description of the action (for messages).
function confirm_destructive {
    local action=$1
    if [[ -n "$FORCE" ]]; then
        CLUSTER_NAME="$DEFAULT_CLUSTER_NAME"
        echo "--force: proceeding to ${action} (cluster '${CLUSTER_NAME}') without prompting." >&2
        return 0
    fi
    if [[ -n "$ASSUME_YES" ]]; then
        echo "Refusing to ${action} in unattended mode (-y/ASSUME_YES) without --force." >&2
        echo "Re-run with --force to confirm destructive teardown non-interactively." >&2
        exit 1
    fi
    if ! confirm "Are you sure you want to continue?" n; then
        echo "Cancelling and exiting script..."
        exit 0
    fi
    CLUSTER_NAME=$(ask "Type the name of the cluster (Default: ${DEFAULT_CLUSTER_NAME}) to continue. Type [exit] to cancel: " "$DEFAULT_CLUSTER_NAME")
    if [[ "$CLUSTER_NAME" == "exit" ]]; then
        echo "Cancelling and exiting script..."
        exit 0
    fi
    return 0
}

# Verify required commands exist; exit with clear guidance if any are missing.
# Used by the flows that don't run install_dependencies (-m/-o/-u/-p).
function require_cmd {
    local missing=() c
    for c in "$@"; do
        command -v "$c" &>/dev/null || missing+=("$c")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Error: required command(s) not found: ${missing[*]}" >&2
        echo "Install them, or run '$0 -n' to install dependencies first." >&2
        exit 1
    fi
}

# Run an external command, echoing it first under -V/--verbose. The echo goes to stderr
# (so captured stdout stays clean) and shows the temp-values-file path, not credentials.
# NB: named run_cmd, not run, to avoid clobbering bats-core's `run` when the test suite
# sources this script.
function run_cmd {
    [[ -n "$VERBOSE" ]] && echo "${C_BOLD}${C_BLUE}+ $*${C_RESET}" >&2
    "$@"
}

# Pick a directory for direct binary installs: prefer a writable dir already on
# PATH; otherwise fall back to /usr/local/bin (written via sudo).
function install_bin_dir {
    local d
    for d in "$HOME/.local/bin" /usr/local/bin /opt/homebrew/bin; do
        case ":$PATH:" in *":$d:"*) ;; *) continue ;; esac
        [[ -d "$d" && -w "$d" ]] && {
            printf '%s' "$d"
            return 0
        }
    done
    printf '/usr/local/bin'
}

# Install binary $1 into the chosen bin dir as $2, using sudo only when the dir
# isn't writable. Warns if the dir isn't on PATH.
function install_binary {
    local src=$1 name=$2 dir
    dir=$(install_bin_dir)
    if [[ -w "$dir" ]]; then
        mkdir -p "$dir" && mv "$src" "$dir/$name" && chmod +x "$dir/$name"
    else
        sudo mkdir -p "$dir" && sudo mv "$src" "$dir/$name" && sudo chmod +x "$dir/$name"
    fi
    case ":$PATH:" in
        *":$dir:"*) ;;
        *) echo "Note: '$dir' is not on your PATH; add it so '$name' is found." >&2 ;;
    esac
    echo "Installed $name to $dir"
}

# Compute the SHA-256 of file $1 (hex, lowercase), using whichever tool is present.
function sha256_of {
    if command -v sha256sum &>/dev/null; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        echo "Error: need 'sha256sum' or 'shasum' to verify downloads; refusing to continue." >&2
        exit 1
    fi
}

# Echo the expected SHA-256 from a remote checksum file at $1. With a filename in $2,
# select that file's line from a multi-entry list ("<hash>  <file>", tolerating a
# leading '*'); without $2, use the first line (per-asset .sha256/.sha256sum files).
function remote_sha256 {
    local url=$1 name=${2:-}
    if [[ -n "$name" ]]; then
        curl -fsSL "$url" | awk -v n="$name" '{f=$2; sub(/^[*]/, "", f); if (f == n) {print $1; exit}}'
    else
        curl -fsSL "$url" | awk 'NR==1 {print $1; exit}'
    fi
}

# Verify that file $1 matches the expected hex digest $2; abort (and delete the file)
# on mismatch or when no expected digest is available (fail closed). $3 = label.
function verify_sha256 {
    local file=$1 expected=$2 label=${3:-$1} actual
    expected=$(printf '%s' "$expected" | tr 'A-F' 'a-f')
    if [[ -z "$expected" ]]; then
        echo "Error: could not obtain a checksum for ${label}; refusing to install an unverified binary." >&2
        rm -f "$file"
        exit 1
    fi
    actual=$(sha256_of "$file" | tr 'A-F' 'a-f')
    if [[ "$actual" != "$expected" ]]; then
        echo "Error: SHA-256 mismatch for ${label} (${file})." >&2
        echo "  expected: ${expected}" >&2
        echo "  actual:   ${actual}" >&2
        rm -f "$file"
        exit 1
    fi
    echo "Verified ${label} checksum." >&2
}

# Check Dependencies
# Install the required CLIs with Homebrew. Brew always installs its current formula, so
# the KIND_VERSION/KUBECTL_VERSION/HELM_VERSION/PODMAN_VERSION pins (direct-download only)
# don't apply here. Adds a container runtime only when neither Docker nor Podman is present.
function install_with_brew {
    echo "Installing Dependencies with Homebrew..."
    local brew_pkgs=(jq kubectl helm kind)
    if ! command -v docker &>/dev/null && ! command -v podman &>/dev/null; then
        brew_pkgs+=(podman)
    fi
    brew install --quiet "${brew_pkgs[@]}"
}

# Direct binary downloads — the no-Homebrew fallback. Each CLI is pinned to its *_VERSION
# and checksum-verified before install. Downloads into a private, unpredictable 0700
# scratch dir (mktemp -d, not fixed /tmp paths) so a hostile pre-created file/symlink on a
# shared host can't redirect or clobber a download; cleaned on exit (a backstop for the
# mid-download error path) and again explicitly at the end. The caller has already run
# `require_cmd curl` (shared with the Homebrew-installer download path).
function install_deps_direct {
    echo "Installing Dependencies Directly..."
    local jq_base ver tmpdir helm_tgz
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT
    if ! command -v jq &>/dev/null; then
        echo "Installing jq..."
        jq_base="https://github.com/jqlang/jq/releases/download/jq-1.7.1"
        curl -fsSL -o "$tmpdir/jq" "${jq_base}/jq-${JQ_OS}-${ARCH}"
        verify_sha256 "$tmpdir/jq" "$(remote_sha256 "${jq_base}/sha256sum.txt" "jq-${JQ_OS}-${ARCH}")" jq
        install_binary "$tmpdir/jq" jq
    fi

    if ! command -v kubectl &>/dev/null; then
        echo "Installing Kubectl ${KUBECTL_VERSION}..."
        curl -fsSL -o "$tmpdir/kubectl" "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl"
        verify_sha256 "$tmpdir/kubectl" "$(remote_sha256 "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl.sha256")" kubectl
        install_binary "$tmpdir/kubectl" kubectl
        kubectl version --client
    fi

    if ! command -v helm &>/dev/null; then
        echo "Installing Helm ${HELM_VERSION}..."
        require_cmd tar # the pinned release tarball is extracted with tar below
        # Download the pinned helm release tarball directly and verify its published
        # SHA-256 before extracting — avoids executing the get-helm-3 bootstrap script
        # from a mutable master ref. Tarball lays out as ${OS}-${ARCH}/helm.
        helm_tgz="helm-${HELM_VERSION}-${OS}-${ARCH}.tar.gz"
        curl -fsSL -o "$tmpdir/$helm_tgz" "https://get.helm.sh/${helm_tgz}"
        verify_sha256 "$tmpdir/$helm_tgz" "$(remote_sha256 "https://get.helm.sh/${helm_tgz}.sha256")" helm
        tar -xzf "$tmpdir/$helm_tgz" -C "$tmpdir"
        install_binary "$tmpdir/${OS}-${ARCH}/helm" helm
    fi

    # Only auto-install a runtime when the user has neither Docker nor Podman.
    if ! command -v docker &>/dev/null && ! command -v podman &>/dev/null; then
        echo "Installing Podman ${PODMAN_VERSION}..."
        if [[ "$OS" == "darwin" ]]; then
            require_cmd unzip # the darwin release ships as a .zip, extracted below
            # The release tag carries a leading 'v' (used in the URL); the zip's internal
            # directory does not (podman-6.0.0/, not podman-v6.0.0/).
            ver="${PODMAN_VERSION#v}"
            curl -fsSL -o "$tmpdir/podman.zip" "https://github.com/containers/podman/releases/download/${PODMAN_VERSION}/podman-remote-release-darwin_${ARCH}.zip"
            verify_sha256 "$tmpdir/podman.zip" "$(remote_sha256 "https://github.com/containers/podman/releases/download/${PODMAN_VERSION}/shasums" "podman-remote-release-darwin_${ARCH}.zip")" podman
            unzip -q "$tmpdir/podman.zip" -d "$tmpdir/podman-extract"
            install_binary "$tmpdir/podman-extract/podman-${ver}/usr/bin/podman" podman
            install_binary "$tmpdir/podman-extract/podman-${ver}/usr/bin/podman-mac-helper" podman-mac-helper
        else
            # On Linux, Podman runs natively (no VM/machine) and needs rootless
            # dependencies a single static binary can't provide. Defer to the distro
            # package manager. See TODO.md (P1 first-class runtime task).
            echo "On Linux, install Podman with your distribution's package manager, e.g.:"
            echo "  sudo apt-get install -y podman   # Debian/Ubuntu"
            echo "  sudo dnf install -y podman       # Fedora/RHEL"
            echo "Then re-run this script."
            exit 1
        fi
    fi

    if ! command -v kind &>/dev/null; then
        echo "Installing Kind ${KIND_VERSION}..."
        curl -fsSL -o "$tmpdir/kind" "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${OS}-${ARCH}"
        verify_sha256 "$tmpdir/kind" "$(remote_sha256 "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-${OS}-${ARCH}.sha256sum" "kind-${OS}-${ARCH}")" kind
        install_binary "$tmpdir/kind" kind
    fi

    rm -rf "$tmpdir"
    trap - EXIT
}

function install_dependencies {
    # --dry-run previews the install flow without side effects, so don't install anything.
    if [[ -n "$DRY_RUN" ]]; then
        echo "${C_BOLD}${C_BLUE}[dry-run]${C_RESET} would install any missing dependencies (kind, kubectl, helm, jq, and a container runtime)." >&2
        return 0
    fi

    # Install-strategy selection: prefer Homebrew when present; otherwise offer to install
    # it (then re-run), or fall back to verified direct downloads.
    if command -v brew &>/dev/null; then
        install_with_brew
        return
    fi

    # No Homebrew. Both branches below fetch with curl (the Homebrew-installer download,
    # and every direct download), so fail fast with the standard clear message if curl is
    # missing (e.g. a minimal Linux image) instead of a raw 'curl: command not found'.
    require_cmd curl
    if confirm "Homebrew is not installed. Install it?" n; then
        # Run a PINNED, checksum-verified copy of the Homebrew installer rather than piping
        # mutable HEAD straight into a shell. Surface the exact source so the user can see
        # what will execute; verify_sha256 aborts on any mismatch.
        local brew_tmp
        brew_tmp=$(mktemp -d)
        trap 'rm -rf "$brew_tmp"' EXIT
        echo "Fetching the Homebrew installer (pinned commit ${HOMEBREW_INSTALL_COMMIT}):" >&2
        echo "  https://github.com/Homebrew/install/blob/${HOMEBREW_INSTALL_COMMIT}/install.sh" >&2
        curl -fsSL -o "$brew_tmp/install_homebrew.sh" "https://raw.githubusercontent.com/Homebrew/install/${HOMEBREW_INSTALL_COMMIT}/install.sh"
        verify_sha256 "$brew_tmp/install_homebrew.sh" "$HOMEBREW_INSTALL_SHA256" "Homebrew installer"
        chmod 700 "$brew_tmp/install_homebrew.sh"
        "$brew_tmp/install_homebrew.sh"
        rm -rf "$brew_tmp"
        trap - EXIT
        install_dependencies
    else
        install_deps_direct
    fi
}

# True if $1 is a valid kindest/node version tag (vMAJOR.MINOR.PATCH) — the same shape
# the auto-list is filtered to. Manual input is validated against this before it's
# interpolated into the `kind create --image kindest/node:<tag>` ref, so an arbitrary
# string can't redirect kind to an unintended image/tag/digest.
function valid_node_tag {
    [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# True if $1 is a usable KinD cluster name. KinD names (and the kind-<name> kube context
# the script pins everywhere) are RFC-1123-ish: a leading lowercase letter/digit, then
# lowercase letters, digits, '-' or '.'. Reject anything else early so a stray line —
# e.g. type-ahead/pasted text consumed by the prompt while a long step runs — can't become
# CLUSTER_NAME and produce a bogus `kind-<junk>` context that only fails much later with a
# confusing "context ... does not exist".
function valid_cluster_name {
    [[ "$1" =~ ^[a-z0-9][a-z0-9.-]*$ ]]
}

# Prompt for a cluster name with a default, re-prompting until the entered value is a valid
# KinD name (interactive) — the default is always valid, so unattended/EOF runs return it
# unread on the first pass. UI goes to stderr so the result is safe to capture with $(...).
function ask_cluster_name {
    local prompt=$1 default=$2 name
    while true; do
        name=$(ask "$prompt" "$default")
        if valid_cluster_name "$name"; then
            printf '%s' "$name"
            return 0
        fi
        echo "Invalid cluster name '${name}'. Use lowercase letters, digits, '-' or '.' (e.g. '${default}')." >&2
        # Unattended (ask returns the default without reading): never loop forever. The
        # default is validated above, so this only guards an explicitly-bad default.
        if [[ -n "$ASSUME_YES" ]]; then
            printf '%s' "$default"
            return 0
        fi
    done
}

# Prompt for a kindest/node image and echo the chosen ref (e.g.
# kindest/node:v1.32.2) to stdout. All prompts/UI go to stderr so the result is
# safe to capture with $(...). Echoes nothing if the user opts for kind's default.
function select_node_image {
    local url="https://hub.docker.com/v2/repositories/kindest/node/tags?page_size=100&ordering=last_updated"
    local tags=() response tag i selection manual

    echo "Fetching available kindest/node tags from Docker Hub..." >&2
    if response=$(curl -fsSL "$url" 2>/dev/null); then
        # Keep only semantic version tags (vMAJOR.MINOR.PATCH), newest first, de-duped.
        while IFS= read -r tag; do
            [[ -n "$tag" ]] && tags+=("$tag")
        done < <(printf '%s' "$response" | jq -r '.results[].name' |
            grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | awk '!seen[$0]++')
    fi

    if [[ ${#tags[@]} -eq 0 ]]; then
        echo "Could not fetch a tag list (offline or API change)." >&2
        while true; do
            read -rp "${C_BOLD}${C_BLUE}Enter a kindest/node version tag (e.g. v1.32.2), blank for kind's default: ${C_RESET}" manual || manual=""
            if [[ -z "$manual" ]]; then
                return 0 # blank / EOF -> use kind's built-in default (no output)
            elif valid_node_tag "$manual"; then
                printf 'kindest/node:%s' "$manual"
                return 0
            fi
            echo "Invalid tag '${manual}': expected vMAJOR.MINOR.PATCH (e.g. v1.32.2)." >&2
        done
    fi

    echo "Available kindest/node versions:" >&2
    for i in "${!tags[@]}"; do
        printf "%3d. %s\n" "$((i + 1))" "${tags[$i]}" >&2
    done
    local manual_option=$((${#tags[@]} + 1))
    printf "%3d. %s\n" "$manual_option" "Enter a tag manually" >&2

    while true; do
        if ! read -rp "${C_BOLD}${C_BLUE}Select a version [1-${manual_option}]: ${C_RESET}" selection; then
            echo "No input (stdin closed); using kind's default Kubernetes version." >&2
            return 0
        fi
        if ! [[ "$selection" =~ ^[0-9]+$ ]]; then
            echo "Please enter a number between 1 and ${manual_option}." >&2
            continue
        fi
        if [[ "$selection" -eq "$manual_option" ]]; then
            if ! read -rp "${C_BOLD}${C_BLUE}Enter a kindest/node version tag (e.g. v1.32.2): ${C_RESET}" manual; then
                echo "No input (stdin closed); using kind's default Kubernetes version." >&2
                return 0
            fi
            if [[ -z "$manual" ]]; then
                continue # blank -> re-show the menu
            elif valid_node_tag "$manual"; then
                printf 'kindest/node:%s' "$manual"
                return 0
            else
                echo "Invalid tag '${manual}': expected vMAJOR.MINOR.PATCH (e.g. v1.32.2)." >&2
                continue
            fi
        fi
        if [[ "$selection" -ge 1 && "$selection" -le ${#tags[@]} ]]; then
            printf 'kindest/node:%s' "${tags[$((selection - 1))]}"
            return 0
        fi
        echo "Invalid selection: enter a number between 1 and ${manual_option}." >&2
    done
}

# Prompt for a sumologic/sumologic chart version and echo the chosen version to stdout
# (all UI goes to stderr, so the result is safe to capture with $(...)). Defaults to the
# pinned SUMO_CHART_VERSION. Returns that default WITHOUT prompting when unattended
# (ASSUME_YES) or when the version was pinned via the environment. Requires the helm repo
# to be registered (call after ensure_helm_repo).
function select_chart_version {
    local default="$SUMO_CHART_VERSION" versions=() v i selection manual
    if [[ -n "$ASSUME_YES" || -n "$CHART_VERSION_FROM_ENV" ]]; then
        printf '%s' "$default"
        return 0
    fi

    echo "Fetching available sumologic/sumologic chart versions..." >&2
    while IFS= read -r v; do
        [[ -n "$v" ]] && versions+=("$v")
    done < <(helm search repo sumologic/sumologic --versions 2>/dev/null |
        awk '$1 == "sumologic/sumologic" {print $2}' | head -n 20)

    if [[ ${#versions[@]} -eq 0 ]]; then
        echo "Could not list chart versions; using the pinned default ${default}." >&2
        printf '%s' "$default"
        return 0
    fi

    echo "Available sumologic/sumologic chart versions (newest first):" >&2
    for i in "${!versions[@]}"; do
        printf "%3d. %s\n" "$((i + 1))" "${versions[$i]}" >&2
    done
    local manual_option=$((${#versions[@]} + 1))
    printf "%3d. %s\n" "$manual_option" "Enter a version manually" >&2

    while true; do
        if ! read -rp "${C_BOLD}${C_BLUE}Select a version [1-${manual_option}, blank=${default}]: ${C_RESET}" selection; then
            echo "No input (stdin closed); using the pinned default ${default}." >&2
            printf '%s' "$default"
            return 0
        fi
        if [[ -z "$selection" ]]; then
            printf '%s' "$default"
            return 0
        fi
        if ! [[ "$selection" =~ ^[0-9]+$ ]]; then
            echo "Please enter a number between 1 and ${manual_option}." >&2
            continue
        fi
        if [[ "$selection" -eq "$manual_option" ]]; then
            if ! read -rp "${C_BOLD}${C_BLUE}Enter a chart version (e.g. 5.2.0): ${C_RESET}" manual; then
                echo "No input (stdin closed); using the pinned default ${default}." >&2
                printf '%s' "$default"
                return 0
            fi
            [[ -n "$manual" ]] && {
                printf '%s' "$manual"
                return 0
            }
            continue
        fi
        if [[ "$selection" -ge 1 && "$selection" -le ${#versions[@]} ]]; then
            printf '%s' "${versions[$((selection - 1))]}"
            return 0
        fi
        echo "Invalid selection: enter a number between 1 and ${manual_option}." >&2
    done
}

# --- Container runtime (Podman and Docker are both first-class) ---------------

# Select the container runtime into CONTAINER_RUNTIME. Prompts only when both are
# installed; honors a preset CONTAINER_RUNTIME; returns non-zero if neither exists.
function select_runtime {
    local has_podman="no" has_docker="no" choice
    command -v podman &>/dev/null && has_podman="yes"
    command -v docker &>/dev/null && has_docker="yes"

    # Honor an explicit override (env var or earlier selection) when it is available.
    if [[ -n "$CONTAINER_RUNTIME" ]]; then
        if [[ "$CONTAINER_RUNTIME" == "podman" && "$has_podman" == "yes" ]] ||
            [[ "$CONTAINER_RUNTIME" == "docker" && "$has_docker" == "yes" ]]; then
            echo "Using container runtime: ${CONTAINER_RUNTIME}" >&2
            return 0
        fi
        echo "Requested CONTAINER_RUNTIME='${CONTAINER_RUNTIME}' is not available." >&2
        return 1
    fi

    if [[ "$has_podman" == "yes" && "$has_docker" == "yes" ]]; then
        if [[ -n "$ASSUME_YES" ]]; then
            CONTAINER_RUNTIME="podman"
            echo "Both runtimes available; defaulting to podman (unattended)." >&2
            return 0
        fi
        echo "Both Podman and Docker are available." >&2
        while true; do
            if ! read -rp "${C_BOLD}${C_BLUE}Which runtime should KinD use? [podman/docker] (default=podman): ${C_RESET}" choice; then
                echo "No input (stdin closed); defaulting to podman." >&2
                choice="podman"
            fi
            choice="${choice:-podman}"
            case "$choice" in
                [Pp]odman | PODMAN)
                    CONTAINER_RUNTIME="podman"
                    break
                    ;;
                [Dd]ocker | DOCKER)
                    CONTAINER_RUNTIME="docker"
                    break
                    ;;
                *) echo "Please answer 'podman' or 'docker'." >&2 ;;
            esac
        done
    elif [[ "$has_podman" == "yes" ]]; then
        CONTAINER_RUNTIME="podman"
    elif [[ "$has_docker" == "yes" ]]; then
        CONTAINER_RUNTIME="docker"
    else
        echo "Neither Podman nor Docker is installed. Install one to continue." >&2
        return 1
    fi
    echo "Using container runtime: ${CONTAINER_RUNTIME}" >&2
}

# Point KinD at the provider that matches the selected runtime.
function set_kind_provider {
    if [[ "$CONTAINER_RUNTIME" == "podman" ]]; then
        export KIND_EXPERIMENTAL_PROVIDER=podman
    else
        export KIND_EXPERIMENTAL_PROVIDER=docker
    fi
}

# Best-effort resource check for Docker, mirroring the Podman machine minimums.
function check_docker_resources {
    local info ncpu mem_bytes mem_mb
    # `|| true` INSIDE the $() (not `$(…) || return 0`): under `set -E` a `docker info` failure
    # inside the subshell fires the inherited ERR trap there, defeating this best-effort skip
    # (the outer `|| return 0` can't reach into the subshell). Empty output => can't probe => skip.
    info=$(docker info --format '{{.NCPU}} {{.MemTotal}}' 2>/dev/null || true)
    [[ -n "$info" ]] || return 0
    ncpu=${info%% *}
    mem_bytes=${info##* }
    [[ "$ncpu" =~ ^[0-9]+$ && "$mem_bytes" =~ ^[0-9]+$ ]] || return 0
    mem_mb=$(awk "BEGIN { printf \"%d\", $mem_bytes / 1024 / 1024 }")
    echo "Docker resources: ${mem_mb}MB RAM, ${ncpu} CPUs (minimum ${MIN_MEM_MB}MB / ${MIN_CPU} CPUs)."
    if [[ "$mem_mb" -lt "$MIN_MEM_MB" || "$ncpu" -lt "$MIN_CPU" ]]; then
        echo "⚠️  Docker is below the recommended minimums; the Sumo stack may be unstable." >&2
        echo "    Increase CPU/Memory in Docker Desktop → Settings → Resources." >&2
    fi
}

# Ensure Podman is ready. macOS needs a running machine (VM) meeting the minimums;
# on Linux Podman runs natively, so just confirm it responds.
function ensure_podman_ready {
    if [[ "$OS" == "darwin" ]]; then
        use_existing_podman
    else
        if podman info &>/dev/null; then
            return 0
        fi
        echo "Podman is installed but not responding (podman info failed)." >&2
        return 1
    fi
}

# Ensure Docker is running, then report its resources.
function ensure_docker_ready {
    if ! docker info &>/dev/null; then
        echo "Docker is installed but not running. Start Docker and retry." >&2
        return 1
    fi
    echo "Docker is running."
    check_docker_resources
    return 0
}

# --- Podman machine helpers (macOS; used by ensure_podman_ready above) -------

# Normalize a `podman machine` Memory value to MiB. Podman has reported this field
# in bytes (5.x) and in MiB (older versions); decide by magnitude. Any real machine
# has >= 1 GiB, so a value at/above 1 GiB-in-bytes is bytes, otherwise it's MiB.
function mem_to_mib {
    local raw=$1
    [[ "$raw" =~ ^[0-9]+$ ]] || {
        echo 0
        return 0
    }
    if [[ "$raw" -ge 1073741824 ]]; then
        echo $((raw / 1024 / 1024))
    else
        echo "$raw"
    fi
}

# Only one Podman machine can run at a time. If one is running, offer to stop it.
# Returns 0 if nothing is running or it was stopped, 1 if the user declines.
function stop_running_machine {
    local running_machine
    running_machine=$(podman machine list --format json | jq -r '.[] | select(.Running == true) | .Name')
    [[ -z "$running_machine" ]] && return 0
    echo "Podman machine '$running_machine' is currently running (only one can run at a time)."
    if confirm "Stop it before continuing?" n; then
        echo "Stopping '$running_machine'..."
        podman machine stop "$running_machine"
        return 0
    fi
    echo "Cannot proceed while another machine is running."
    return 1
}

function new_podman {
    local DEFAULT_NAME DEFAULT_MEMORY MEMORY NAME # all new_podman-local
    echo "Creating a new Podman machine..."
    DEFAULT_NAME="sumo"
    DEFAULT_MEMORY="${MIN_MEM_MB}" # default a new machine to the configured minimum
    MEMORY=$(ask "Allocate memory for Podman machine (in MiB) [default=${DEFAULT_MEMORY}]: " "$DEFAULT_MEMORY")
    # Validate before handing it to `podman machine init --memory`, which otherwise fails
    # cryptically on non-numeric input. Reject non-integers hard; warn (don't block) when
    # below the minimum, matching check_docker_resources' tone for a deliberate choice.
    if ! [[ "$MEMORY" =~ ^[0-9]+$ ]]; then
        echo "Error: memory must be a positive integer (MiB), got '${MEMORY}'." >&2
        return 1
    fi
    MEMORY=$((10#$MEMORY)) # normalize: strip leading zeros so the comparison isn't read as octal
    if [[ "$MEMORY" -lt "$MIN_MEM_MB" ]]; then
        echo "⚠️  ${MEMORY}MiB is below the recommended minimum (${MIN_MEM_MB}MiB); the Sumo stack may be unstable." >&2
    fi
    NAME=$(ask "Name of the Podman machine [default=${DEFAULT_NAME}]: " "$DEFAULT_NAME")

    # Free the single run slot before creating/starting the new machine.
    stop_running_machine || return 1

    echo "Initializing Podman machine '$NAME' with ${MEMORY}MiB RAM..."
    run_cmd podman machine init --memory "${MEMORY}" "${NAME}"
    run_cmd podman machine start "${NAME}"
}

# Populate the caller's valid_* arrays with the Podman machines that meet the minimum
# Memory/CPU requirements (MIN_MEM_MB / MIN_CPU, overridable above), printing the
# discovered list as it goes. The four arrays are read from the CALLER's scope via Bash
# dynamic scoping — use_existing_podman declares them `local -a`, so they stay
# function-scoped (no global leak, verified on 3.2.57) while this helper fills them.
function list_valid_machines {
    local machines_json index machine_count i name mem_raw cpu status mem_mb

    # Get list of all machines with their specs
    machines_json=$(podman machine list --format json)

    index=0
    echo "Checking Podman machines for minimum requirements (Memory ≥ ${MIN_MEM_MB}MB, CPUs ≥ ${MIN_CPU})..."

    # Loop over machines using `jq` length and index
    machine_count=$(echo "$machines_json" | jq 'length')

    for ((i = 0; i < machine_count; i++)); do
        name=$(echo "$machines_json" | jq -r ".[$i].Name")
        mem_raw=$(echo "$machines_json" | jq -r ".[$i].Memory")
        cpu=$(echo "$machines_json" | jq -r ".[$i].CPUs")
        status=$(echo "$machines_json" | jq -r ".[$i].Running")

        # Normalize Memory to MiB (podman reports bytes on 5.x, MiB on older versions).
        mem_mb=$(mem_to_mib "$mem_raw")

        if [[ "$mem_mb" -ge "$MIN_MEM_MB" && "$cpu" -ge "$MIN_CPU" ]]; then
            valid_names[index]="$name"
            valid_memories[index]="$mem_mb"
            valid_cpus[index]="$cpu"
            valid_statuses[index]="$status"
            echo "$((index + 1)). $name - Memory: ${mem_mb}MB, CPUs: $cpu"
            ((index++))
        fi
    done

    # Explicit success: as the function tail, the loop's own status is data-dependent — a
    # final `((index++))` post-incrementing 0 (a single qualifying machine) returns 1, and an
    # unqualified last machine leaves the `if`-test's status. Neither should be our exit code.
    return 0
}

# Drive the interactive menu over the caller's valid_* arrays (populated by
# list_valid_machines, read here via dynamic scoping): pick a machine, create a new one,
# or exit; start the chosen machine if it isn't running. Returns 0 on a usable machine,
# non-zero on cancel/EOF. Assumes the caller has already confirmed at least one valid
# machine exists.
function prompt_machine_selection {
    local i display_number create_option exit_option selection selection_index
    local chosen_machine machine_running

    # Prompt in a loop until valid input
    while true; do
        echo
        echo "Select a Podman machine to use:"
        for i in "${!valid_names[@]}"; do
            display_number=$((i + 1))
            echo "$display_number. ${valid_names[$i]} - Memory: ${valid_memories[$i]}MB, CPUs: ${valid_cpus[$i]}"
        done

        create_option=$((${#valid_names[@]} + 1))
        exit_option=$((${#valid_names[@]} + 2))

        echo "$create_option. Create a new Podman machine"
        echo "$exit_option. None (exit)"

        if [[ -n "$ASSUME_YES" ]]; then
            selection=1 # unattended: use the first machine that meets the minimums
        elif ! read -rp "${C_BOLD}${C_BLUE}Enter your choice [1-$exit_option]: ${C_RESET}" selection; then
            echo "No input (stdin closed); aborting machine selection." >&2
            return 1
        fi

        # Check input is numeric
        if ! [[ "$selection" =~ ^[0-9]+$ ]]; then
            echo "Invalid input: please enter a number between 1 and $exit_option."
            continue
        fi

        # Handle "Create a new machine"
        if [[ "$selection" -eq "$create_option" ]]; then
            new_podman || return 1
            return 0
        fi

        # Handle "None"
        if [[ "$selection" -eq "$exit_option" ]]; then
            echo "Exiting without selecting a Podman machine."
            return 1
        fi

        # Convert to 0-based index and validate
        selection_index=$((selection - 1))
        if [[ "$selection_index" -lt 0 || "$selection_index" -ge ${#valid_names[@]} ]]; then
            echo "Invalid selection: please enter a number between 1 and $exit_option."
            continue
        fi

        # Valid selection
        chosen_machine="${valid_names[$selection_index]}"
        machine_running="${valid_statuses[$selection_index]}"

        echo "You selected: $chosen_machine"

        if [[ "$machine_running" != "true" ]]; then
            echo "Machine '$chosen_machine' is not running."
            if confirm "Start it now?" n; then
                echo "Starting Podman machine '$chosen_machine'..."
                run_cmd podman machine start "$chosen_machine"
            else
                echo "Exiting without starting machine."
                return 1
            fi
        fi
        # Optional: Activate it
        # podman machine use "$chosen_machine"
        break
    done

    return 0
}

# Reuse an existing Podman machine that meets the minimums, or offer to create one.
# Orchestrates list_valid_machines (discover/filter) + prompt_machine_selection (menu).
function use_existing_podman {
    # Declare the valid_* arrays here (function-local, so nothing leaks to the global
    # environment) and share them by dynamic scope with the two helpers: list_valid_machines
    # fills them, prompt_machine_selection reads them. `local -a` localizes arrays in Bash
    # 3.2 just as `local` does scalars (verified on 3.2.57).
    local -a valid_names valid_memories valid_cpus valid_statuses

    list_valid_machines

    # No machine met the minimums: offer to create one, else bail.
    if [[ ${#valid_names[@]} -eq 0 ]]; then
        echo "No Podman machines meet the minimum requirements (≥ ${MIN_MEM_MB}MB RAM, ≥ ${MIN_CPU} CPUs)."
        if confirm "Create a new Podman machine with the correct specs?" n; then
            # new_podman stops any running machine before starting the new one.
            new_podman || return 1
            return 0
        else
            echo "No machine selected and creation declined."
            return 1
        fi
    fi

    prompt_machine_selection
}

# True if a KinD cluster with the given name already exists (for the current provider).
function cluster_exists {
    kind get clusters 2>/dev/null | grep -Fxq "$1"
}

function init_cluster {
    # --dry-run: preview the runtime prep + cluster create and touch nothing — no runtime
    # setup, no Podman machine, no `kind create`. (Shows the pinned-default create command.)
    if [[ -n "$DRY_RUN" ]]; then
        local cn="${CLUSTER_NAME:-$DEFAULT_CLUSTER_NAME}"
        echo "${C_BOLD}${C_BLUE}[dry-run]${C_RESET} would prepare the container runtime, then run:" >&2
        echo "${C_BOLD}${C_BLUE}[dry-run]${C_RESET} would run: kind create cluster --name ${cn} --config ${SCRIPT_DIR}/kind-config.yaml --image ${KINDEST_NODE_IMAGE}" >&2
        return 0
    fi

    local choice node_image # function-local working vars (the reuse choice and node-image tag)

    # Choose and prepare the container runtime (Podman or Docker, both first-class).
    if ! select_runtime; then
        exit 1
    fi
    set_kind_provider

    if [[ "$CONTAINER_RUNTIME" == "podman" ]]; then
        if ! ensure_podman_ready; then
            echo "Podman setup did not complete; aborting."
            exit 1
        fi
    else
        if ! ensure_docker_ready; then
            echo "Docker setup did not complete; aborting."
            exit 1
        fi
    fi

    # Cluster name is asked once, regardless of the version choice. Validated so a stray
    # line can't yield a bogus kind-<junk> context (see ask_cluster_name/valid_cluster_name).
    CLUSTER_NAME=$(ask_cluster_name "Name of the cluster [default=${DEFAULT_CLUSTER_NAME}]: " "$DEFAULT_CLUSTER_NAME")
    CLUSTER_NAME_RESOLVED=yes # install_sumo (in the -i flow) reuses this instead of re-asking

    # Handle an existing cluster of the same name instead of letting kind error out.
    if cluster_exists "$CLUSTER_NAME"; then
        echo "A KinD cluster named '${CLUSTER_NAME}' already exists."
        choice=$(ask "Reuse it (r), recreate it [delete + create] (d), or cancel (c)? [r/d/c]: " "r")
        case "$choice" in
            [Rr]*)
                echo "Reusing existing cluster '${CLUSTER_NAME}'."
                return 0
                ;;
            [Dd]*)
                echo "Deleting existing cluster '${CLUSTER_NAME}'..."
                run_cmd kind delete cluster --name "${CLUSTER_NAME}"
                ;;
            *)
                echo "Cancelling; leaving the existing cluster in place."
                exit 0
                ;;
        esac
    fi

    # Anchor the bundled cluster config to the script dir (not the CWD) and fail early
    # with a clear message if it's missing, instead of letting kind emit a raw error.
    local kind_config="$SCRIPT_DIR/kind-config.yaml"
    if [[ ! -f "$kind_config" ]]; then
        echo "Error: bundled kind-config.yaml not found at '${kind_config}'." >&2
        echo "Run the script from its repository clone (kind-config.yaml ships alongside it)." >&2
        exit 1
    fi

    if confirm "Create the cluster with the pinned Kubernetes version (kindest/node:${KINDEST_NODE_VERSION})?" y; then
        run_cmd kind create cluster --name "${CLUSTER_NAME}" --config "$kind_config" --image "${KINDEST_NODE_IMAGE}"
    else
        node_image=$(select_node_image)
        if [[ -n "$node_image" ]]; then
            echo "Creating cluster '${CLUSTER_NAME}' with ${node_image}..."
            run_cmd kind create cluster --name "${CLUSTER_NAME}" --config "$kind_config" --image "${node_image}"
        else
            echo "No version selected; using KinD's default node image."
            run_cmd kind create cluster --name "${CLUSTER_NAME}" --config "$kind_config"
        fi
    fi
}

# Fail early with a clear message if a Helm values file is missing or unreadable.
function require_values_file {
    local f=$1
    if [[ ! -f "$f" ]]; then
        echo "Error: Helm values file not found: '${f}'" >&2
        echo "Provide a valid path, e.g. values.yaml or examples/metrics_interval.yaml" >&2
        exit 1
    fi
    if [[ ! -r "$f" ]]; then
        echo "Error: Helm values file is not readable: '${f}'" >&2
        exit 1
    fi
}

# Prompt for the Helm values file, falling back to the bundled default when one
# exists, and validate any named path. Values files are optional, so a blank result
# (no default present) is fine. Prints the resolved path to stdout (the prompt/UI
# goes to stderr via `ask`), so callers capture it: `HELM_VALUES=$(prompt_values_file)
# || exit 1`. A named-but-bad path makes require_values_file exit this command
# substitution non-zero, which the caller's `|| exit 1` turns into a clean script exit
# (mirroring the `ACCESS_KEY=$(read_secret …) || exit 1` idiom).
function prompt_values_file {
    local vf
    vf=$(ask "Path to a Helm values file (blank to skip) [default if present=${DEFAULT_HELM_VALUES}]: " "${HELM_VALUES:-}")
    # Blank falls back to the bundled default only when it actually exists.
    if [[ -z "$vf" && -f "$DEFAULT_HELM_VALUES" ]]; then
        vf="$DEFAULT_HELM_VALUES"
    fi
    # Optional, but if one is named it must exist and be readable.
    [[ -n "$vf" ]] && require_values_file "$vf"
    printf '%s' "$vf"
}

# Ensure the sumologic Helm repo is registered before any template/upgrade.
# `helm repo add --force-update` is idempotent (adds it, or updates the URL if it
# changed). Pass "update" to also refresh the repo index.
function ensure_helm_repo {
    helm repo add sumologic "$SUMO_HELM_REPO_URL" --force-update >/dev/null
    if [[ "${1:-}" == "update" ]]; then
        echo "Updating Helm repo 'sumologic'..."
        helm repo update sumologic
    fi
}

# Escape a string for use as a double-quoted YAML scalar.
function yaml_escape {
    local s=$1
    s=${s//\\/\\\\} # escape backslashes first
    s=${s//\"/\\\"} # then double quotes
    printf '%s' "$s"
}

# --- Cross-platform secret storage -------------------------------------------
# Backends (selected above into SECRET_BACKEND): macOS Keychain, Linux libsecret
# (secret-tool), or an env-var fallback (e.g. SUMOLOGIC_ACCESS_ID).

# Map a secret name (e.g. sumologic_access_id) to its fallback env var name.
function secret_env_var {
    printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

# Print a stored secret to stdout, or NOTHING if it isn't stored; ALWAYS returns 0.
# Callers detect "not found" by an empty result, NOT a non-zero status. Why: secret_get is
# captured with $(...), and under `set -E` a non-zero return trips the ERR trap *inside* the
# command-substitution subshell — the `if !`/`||` at the call site can't reach in to exempt
# it (same hazard the `endpoints` jq pipeline documents). `security` exits 44
# (errSecItemNotFound) and `secret-tool` exits 1 when the item is absent — the NORMAL
# first-run path — so each lookup is made errexit-exempt with `|| true` and the result is
# returned via stdout only. Returning non-zero here surfaced a spurious "command failed
# (exit 44)" report before every "not found" prompt.
function secret_get {
    local name=$1 var out=""
    case "$SECRET_BACKEND" in
        keychain) out=$(security find-generic-password -s "$name" -w 2>/dev/null || true) ;;
        secret-tool) out=$(secret-tool lookup service "$name" 2>/dev/null || true) ;;
    esac
    # Fall back to the env var (e.g. SUMOLOGIC_ACCESS_ID) on ANY backend, not just `env`: a
    # secret stored in the keychain/secret-tool wins, but SUMOLOGIC_ACCESS_ID/KEY still work
    # for unattended/CI runs where nothing is in the OS keyring. (On the `env` backend the
    # case above matches nothing, so this becomes the only lookup — same result as before.)
    if [[ -z "$out" ]]; then
        var=$(secret_env_var "$name")
        out=${!var:-}
    fi
    [[ -n "$out" ]] && printf '%s' "$out"
    return 0
}

# Store a secret for reuse on the next run.
function secret_set {
    local name=$1 value=$2 var account
    case "$SECRET_BACKEND" in
        keychain)
            # The account label is cosmetic here; fall back when USER is unset so the
            # command doesn't abort under `set -u` (id -un is portable and TTY-free).
            account="${USER:-${LOGNAME:-$(id -un 2>/dev/null || echo unknown)}}"
            # -U updates an existing item in place, so re-storing is idempotent instead
            # of failing on a pre-existing entry. NOTE: `security` has no stdin-password
            # mode, so -w briefly exposes the value on this process's argv (local only);
            # the secret-tool backend below reads the value from stdin, which is the model.
            security add-generic-password -U -a "$account" -s "$name" -w "$value"
            ;;
        secret-tool) printf '%s' "$value" | secret-tool store --label="$name" service "$name" ;;
        env)
            var=$(secret_env_var "$name")
            echo "Note: no Keychain/secret-tool backend found; '$name' was not persisted." >&2
            echo "      Export ${var} in your environment to avoid re-entering it next time." >&2
            ;;
    esac
}

# Delete a stored secret. Returns non-zero if it was not present.
function secret_delete {
    local name=$1
    case "$SECRET_BACKEND" in
        keychain) security delete-generic-password -s "$name" >/dev/null 2>&1 ;;
        secret-tool) secret-tool clear service "$name" 2>/dev/null ;;
        env) return 1 ;;
    esac
}

# True if $1 is one of the known Sumo deployment region codes (SUMO_REGIONS). Gates an
# explicitly-supplied region so an alphanumeric typo (e.g. "us22") isn't turned into a
# garbage endpoint that later 401s and hangs `helm --wait` — an unknown code falls back to
# auto-detection instead.
function is_known_region {
    case " $SUMO_REGIONS " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# True if $1 is free of control characters (newline, CR, tab, ...). A Sumo Access ID/Key is
# a clean token; a stray control char (e.g. a multi-line value pasted into the keychain or
# an env var) would break OUT of the `curl -K -` config line — injecting arbitrary curl
# options (url/output/proxy) — and out of the values-file YAML scalar. Rejecting them up
# front keeps yaml_escape (which handles only \ and ") sufficient for both sinks.
function credential_is_clean {
    case "$1" in
        *[[:cntrl:]]*) return 1 ;;
        *) return 0 ;;
    esac
}

# Persist the Sumo Access ID/Key into the OS keyring (keychain/secret-tool) so later
# unattended installs can reuse them (the --store-credentials action). Each value is taken
# from SUMOLOGIC_ACCESS_ID/KEY when set — so `SUMOLOGIC_ACCESS_ID=… --store-credentials`
# persists non-interactively — otherwise prompted for (masked). Requires a real keyring:
# on the env backend there is nothing to store into, so it directs the user to export instead.
function store_credentials {
    if [[ "$SECRET_BACKEND" == "env" ]]; then
        echo "Error: no OS keyring available (no Keychain/secret-tool) to store credentials in." >&2
        echo "Export SUMOLOGIC_ACCESS_ID and SUMOLOGIC_ACCESS_KEY in your environment instead." >&2
        exit 1
    fi
    local id key
    id="${SUMOLOGIC_ACCESS_ID:-}"
    if [[ -z "$id" ]]; then
        if [[ -n "$ASSUME_YES" ]]; then
            echo "Error: SUMOLOGIC_ACCESS_ID not set and running unattended; nothing to store." >&2
            exit 1
        fi
        id=$(read_secret "Enter Sumo Logic Access ID: ") || exit 1
    fi
    key="${SUMOLOGIC_ACCESS_KEY:-}"
    if [[ -z "$key" ]]; then
        if [[ -n "$ASSUME_YES" ]]; then
            echo "Error: SUMOLOGIC_ACCESS_KEY not set and running unattended; nothing to store." >&2
            exit 1
        fi
        key=$(read_secret "Enter Sumo Logic Access Key: ") || exit 1
    fi
    # Reject control-char values up front (same rationale as install_sumo): a stray newline/tab
    # would break out of the curl -K - config line and the values-file YAML scalar downstream.
    if ! credential_is_clean "$id" || ! credential_is_clean "$key"; then
        echo "Error: the Sumo Access ID/Key contain control characters (a stray newline/tab?)." >&2
        exit 1
    fi
    secret_set sumologic_access_id "$id"
    secret_set sumologic_access_key "$key"
    echo "${C_BOLD}${C_GREEN}Stored${C_RESET} the Sumo Logic Access ID and Access Key (backend: ${SECRET_BACKEND})."
    echo "Unattended installs (${0##*/} -i -y) can now reuse them."
}

# Map a Sumo region code OR URL to the API base URL the setup job needs (SUMOLOGIC_BASE_URL
# / sumologic.endpoint), e.g. us2 -> https://api.us2.sumologic.com/api/v1. A value already
# starting with http(s):// is trusted as-is; us1 is the one deployment with no region infix;
# empty in -> empty out. Region codes are case-normalized.
function sumo_region_to_endpoint {
    local v=$1
    case "$v" in
        "") return 0 ;;
        http://* | https://*)
            printf '%s' "$v"
            return 0
            ;;
    esac
    v=$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')
    if [[ "$v" == "us1" ]]; then
        printf 'https://api.sumologic.com/api/v1'
    else
        printf 'https://api.%s.sumologic.com/api/v1' "$v"
    fi
}

# Offline (no-network) endpoint resolution for the `output` render and install `--dry-run`
# preview: a full URL or a KNOWN region maps to its URL; an unknown/typo'd region maps to
# EMPTY — so the preview matches what the live install resolves (which discards an unknown
# region and auto-detects / leaves the endpoint blank). Never probes or touches credentials.
function endpoint_for_input {
    local v=$1
    case "$v" in
        "") return 0 ;;
        http://* | https://*)
            printf '%s' "$v"
            return 0
            ;;
    esac
    v=$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')
    is_known_region "$v" && sumo_region_to_endpoint "$v"
    return 0
}

# Probe one Sumo API base URL with the credentials and print the HTTP status (000 if the
# host is unreachable). Credentials go via a stdin curl config (`-K -`), NEVER on argv, so
# they can't leak into the process list (ps); callers MUST pre-reject control-char creds
# (credential_is_clean) so a newline can't inject extra curl config lines. The pipeline is
# errexit-exempt (`|| true`) so a curl transport failure can't trip the ERR trap inside this
# capture. --connect-timeout bounds the unreachable case so auto-detect can't stall for long.
function sumo_api_status {
    local base=$1 id=$2 key=$3 code
    code=$(printf 'user = "%s:%s"\n' "$(yaml_escape "$id")" "$(yaml_escape "$key")" |
        curl -K - -s -o /dev/null --connect-timeout 5 --max-time 10 -w '%{http_code}' "${base}/collectors?limit=1" 2>/dev/null || true)
    printf '%s' "${code:-000}"
}

# Resolve the Sumo API endpoint for the given creds and pre-flight-validate them, so a bad
# credential/region fails fast HERE instead of wedging `helm --wait` on a CrashLooping setup
# job for the full timeout (the live-test symptom). Sets RESOLVED_ENDPOINT (the caller's
# local, via dynamic scope) to the working API base URL — empty means "leave the chart's
# endpoint unset / auto-discovery". UI goes to stderr. Returns 1 ONLY when the API
# definitively REJECTS the credentials (HTTP 401), so the caller can abort. MUST be called
# directly (not via $(...)): a non-zero return inside a command substitution would trip the
# ERR trap in that subshell (see secret_get). $1=id $2=key $3=user-supplied region/URL.
function resolve_sumo_endpoint {
    local id=$1 key=$2 want=$3 base code region saw_reject="" saw_unreachable=""
    RESOLVED_ENDPOINT=""

    # A bare region typo (not a URL, not a valid code) shouldn't build a garbage URL — fall
    # back to auto-detection instead.
    if [[ -n "$want" ]]; then
        case "$want" in
            http://* | https://*) ;;
            *)
                want=$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')
                if ! is_known_region "$want"; then
                    echo "Unrecognized Sumo region '${want}'; auto-detecting instead." >&2
                    want=""
                fi
                ;;
        esac
    fi

    if [[ -n "$SUMO_SKIP_CRED_CHECK" ]]; then
        RESOLVED_ENDPOINT=$(sumo_region_to_endpoint "$want")
        if [[ -n "$RESOLVED_ENDPOINT" ]]; then
            echo "Skipping credential pre-flight check (SUMO_SKIP_CRED_CHECK); using endpoint ${RESOLVED_ENDPOINT}." >&2
        else
            echo "Skipping credential pre-flight check (SUMO_SKIP_CRED_CHECK); leaving the endpoint to chart auto-discovery." >&2
        fi
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        RESOLVED_ENDPOINT=$(sumo_region_to_endpoint "$want")
        echo "curl not found; skipping the credential pre-flight check." >&2
        return 0
    fi

    if [[ -n "$want" ]]; then
        base=$(sumo_region_to_endpoint "$want")
        case "$base" in
            http://*) echo "${C_YELLOW}Warning: '${base}' is http:// — credentials will be sent unencrypted.${C_RESET}" >&2 ;;
        esac
        echo "Verifying Sumo credentials against ${base}..." >&2
        code=$(sumo_api_status "$base" "$id" "$key")
        case "$code" in
            200 | 403) # 403 = authenticated but limited role: the endpoint/region is right
                echo "${C_BOLD}${C_GREEN}Credentials verified (${base}).${C_RESET}" >&2
                RESOLVED_ENDPOINT=$base
                return 0
                ;;
            401)
                echo "Credentials REJECTED by ${base} (HTTP 401)." >&2
                return 1
                ;;
            *) # a KNOWN region unreachable from here (e.g. firewall): pin it (the cluster may
                # still reach it) but note we couldn't verify. Not a typo — is_known_region gated it.
                echo "Could not reach ${base} to verify (HTTP ${code}); proceeding without the pre-flight check." >&2
                RESOLVED_ENDPOINT=$base
                return 0
                ;;
        esac
    fi

    echo "Auto-detecting your Sumo deployment (probing regional API endpoints)..." >&2
    for region in $SUMO_REGIONS; do
        base=$(sumo_region_to_endpoint "$region")
        code=$(sumo_api_status "$base" "$id" "$key")
        case "$code" in
            200 | 403)
                echo "Detected Sumo deployment: ${region} (${base})." >&2
                RESOLVED_ENDPOINT=$base
                return 0
                ;;
            401) saw_reject=yes ;;
            *) saw_unreachable=yes ;; # 000/5xx: no definitive answer from this region
        esac
    done

    # Abort ONLY when every region answered and all rejected (creds are provably bad). If any
    # region was unreachable (e.g. a firewall allows us1 but blocks the home region), a lone
    # 401 isn't proof the creds are globally bad — proceed and let the chart resolve.
    if [[ -n "$saw_reject" && -z "$saw_unreachable" ]]; then
        echo "Credentials REJECTED by all Sumo deployments (HTTP 401)." >&2
        return 1
    fi
    if [[ -n "$saw_reject" ]]; then
        echo "Some Sumo deployments rejected these credentials and others were unreachable; cannot confirm your region." >&2
        echo "Proceeding; set SUMOLOGIC_ENDPOINT to your region to be explicit if the install fails." >&2
    else
        echo "Could not reach any Sumo API endpoint to verify (network/firewall?); proceeding and letting the chart resolve the endpoint." >&2
    fi
    return 0
}

# Fast pre-flight for UNATTENDED installs: confirm the Sumo Access ID/Key are available
# (stored in the keyring or provided via SUMOLOGIC_ACCESS_ID/KEY) BEFORE the expensive
# dependency install, Podman-machine selection, and cluster creation — so `-i -y` fails
# immediately with clear guidance instead of only when install_sumo is finally reached.
# Interactive runs skip this: install_sumo prompts for anything missing. Mirrors install_sumo's
# resolution (secret_get + credential_is_clean) so a pass here guarantees install_sumo won't
# abort on credentials.
function preflight_credentials {
    [[ -n "$ASSUME_YES" ]] || return 0 # interactive: install_sumo will prompt
    local id key
    id=$(secret_get sumologic_access_id)
    key=$(secret_get sumologic_access_key)
    if [[ -z "$id" || -z "$key" ]]; then
        echo "Error: Sumo Logic credentials not found and running unattended." >&2
        echo "Provide them before an unattended install, either by:" >&2
        echo "  - exporting SUMOLOGIC_ACCESS_ID and SUMOLOGIC_ACCESS_KEY, or" >&2
        echo "  - running '${0##*/} --store-credentials' once to save them in the OS keyring." >&2
        exit 1
    fi
    if ! credential_is_clean "$id" || ! credential_is_clean "$key"; then
        echo "Error: the Sumo Access ID/Key contain control characters (a stray newline/tab?)." >&2
        echo "Fix SUMOLOGIC_ACCESS_ID/KEY or the stored secret before re-running." >&2
        exit 1
    fi
}

function install_sumo {
    require_cmd helm

    # Install Sumo Logic Operator

    ## Securely handle ACCESS_ID and ACCESS_KEY

    # secret_get always returns 0 and prints the value (empty when unstored); detect "not
    # stored" by the empty result rather than its exit status — see secret_get for why a
    # non-zero return there would trip the ERR trap inside this $(...) capture.
    ACCESS_ID=$(secret_get sumologic_access_id)
    if [[ -z "$ACCESS_ID" ]]; then
        if [[ -n "$ASSUME_YES" ]]; then
            echo "Error: Access ID not found and running unattended. Export SUMOLOGIC_ACCESS_ID or run '${0##*/} --store-credentials' first." >&2
            exit 1
        fi
        echo "${C_YELLOW}Sumo Logic Access ID not found in secret storage${C_RESET}"
        ACCESS_ID=$(read_secret "Enter Sumo Logic Access ID: ") || exit 1
        secret_set sumologic_access_id "$ACCESS_ID"
    fi

    ACCESS_KEY=$(secret_get sumologic_access_key)
    if [[ -z "$ACCESS_KEY" ]]; then
        if [[ -n "$ASSUME_YES" ]]; then
            echo "Error: Access Key not found and running unattended. Export SUMOLOGIC_ACCESS_KEY or run '${0##*/} --store-credentials' first." >&2
            exit 1
        fi
        echo "${C_YELLOW}Sumo Logic Access Key not found in secret storage${C_RESET}"
        ACCESS_KEY=$(read_secret "Enter Sumo Logic Access Key: ") || exit 1
        secret_set sumologic_access_key "$ACCESS_KEY"
    fi

    # Reject credentials carrying control characters (newline/tab/…). A clean Sumo token never
    # has them; a stray one (a multi-line value pasted into the keychain or an env var) would
    # break out of the curl -K - config line and the values-file YAML scalar. Rejecting here
    # keeps yaml_escape (only \ and ") sufficient downstream.
    if ! credential_is_clean "$ACCESS_ID" || ! credential_is_clean "$ACCESS_KEY"; then
        echo "Error: the Sumo Access ID/Key contain control characters (a stray newline/tab?)." >&2
        echo "Re-enter them without embedded whitespace, or fix SUMOLOGIC_ACCESS_ID/KEY or the stored secret." >&2
        exit 1
    fi

    echo "A Helm values file is optional; the chart can install with --set values alone."
    echo "Example values live in the examples folder, e.g. examples/metrics_interval.yaml"
    HELM_VALUES=$(prompt_values_file) || exit 1

    # Ask for the cluster name ONLY when a caller hasn't already resolved it. On -i/-n
    # (init_cluster) and -r (reinstall) the name was just prompted for, so re-asking here is a
    # confusing double-prompt; reuse it. A direct -m/--helm leaves CLUSTER_NAME_RESOLVED empty,
    # so install_sumo still prompts (defaulting to any env/config CLUSTER_NAME).
    if [[ -n "$CLUSTER_NAME_RESOLVED" ]]; then
        echo "${C_BOLD}${C_GREEN}Using cluster '${CLUSTER_NAME}'.${C_RESET}"
    else
        CLUSTER_NAME=$(ask_cluster_name "Name of the cluster [default=${CLUSTER_NAME:-$DEFAULT_CLUSTER_NAME}]: " "${CLUSTER_NAME:-$DEFAULT_CLUSTER_NAME}")
    fi

    # Always ensure the repo is registered; the prompt only controls refreshing it.
    if confirm "Check for Helm repo updates?" n; then
        ensure_helm_repo update
    else
        ensure_helm_repo
        echo "Skipping repo index update."
    fi

    # Resolve the chart version (pinned default, env override, or interactive pick) and
    # report it so the run is reproducible.
    local chart_version
    chart_version=$(select_chart_version)
    echo "Using sumologic/sumologic chart version: ${chart_version}"

    # Resolve the Sumo deployment endpoint and pre-flight-validate the credentials. A wrong
    # region or bad key makes the chart's setup job fail 401 ("Credential could not be
    # verified"), and `helm --wait` then blocks on that CrashLooping pod for the whole
    # timeout — so catch it here and bail with guidance instead.
    local endpoint_input RESOLVED_ENDPOINT=""
    if [[ -n "$SUMOLOGIC_ENDPOINT" ]]; then
        endpoint_input="$SUMOLOGIC_ENDPOINT" # preset (env/config): no prompt
    else
        endpoint_input=$(ask "Sumo deployment region (e.g. us2, au) or full API URL [blank=auto-detect]: " "")
    fi
    if [[ -n "$DRY_RUN" ]]; then
        # Preview only: map a given region/URL to the endpoint (unknown region -> blank, as
        # the live path resolves it), but make NO network call.
        RESOLVED_ENDPOINT=$(endpoint_for_input "$endpoint_input")
    elif ! resolve_sumo_endpoint "$ACCESS_ID" "$ACCESS_KEY" "$endpoint_input"; then
        echo "" >&2
        echo "Aborting before install: the Sumo API rejected these credentials (HTTP 401)." >&2
        echo "  - Check the Access ID/Key are correct and belong to this Sumo org." >&2
        echo "  - If your org is in a specific deployment, set it: SUMOLOGIC_ENDPOINT=us2 (or au, eu, ...)." >&2
        echo "  - To bypass this pre-flight check (offline/firewalled API): SUMO_SKIP_CRED_CHECK=1." >&2
        # Offer to drop the rejected creds so the next run re-prompts instead of reusing them.
        if [[ -z "$ASSUME_YES" ]] && confirm "Remove the stored Sumo credentials so the next run re-prompts?" n; then
            secret_delete sumologic_access_id || true
            secret_delete sumologic_access_key || true
            if [[ "$SECRET_BACKEND" == "env" ]]; then
                echo "Note: these credentials come from SUMOLOGIC_ACCESS_ID/KEY in your environment; unset or change them before re-running." >&2
            else
                echo "Stored credentials removed." >&2
            fi
        fi
        exit 1
    fi

    # Pass the credentials via a private temp values file instead of on the command
    # line, where --set-string would expose them in the process list (ps/argv).
    secrets_file=$(mktemp)
    chmod 600 "$secrets_file"
    # Remove the secrets file on exit, including when the ERR trap fires on failure.
    trap 'rm -f "$secrets_file"' EXIT
    cat >"$secrets_file" <<EOF
sumologic:
  accessId: "$(yaml_escape "$ACCESS_ID")"
  accessKey: "$(yaml_escape "$ACCESS_KEY")"
EOF

    # Build the helm args; only include the user values file when one is in use.
    # Pin --kube-context to the named KinD cluster so a stray/wrong *current* kubectl
    # context can't make this install/upgrade hit an unintended cluster.
    local helm_args=(upgrade --install sumologic sumologic/sumologic
        --version "$chart_version"
        --kube-context "kind-${CLUSTER_NAME}"
        --namespace=sumologic --create-namespace)
    [[ -n "$HELM_VALUES" ]] && helm_args+=(--values "$HELM_VALUES")
    helm_args+=(--values "$secrets_file")
    helm_args+=(--set-string "sumologic.clusterName=${CLUSTER_NAME}")
    # Pin the resolved deployment endpoint so the setup job authenticates against the right
    # region (not secret; shown in the previewed/verbose command). Blank => chart default.
    [[ -n "$RESOLVED_ENDPOINT" ]] && helm_args+=(--set-string "sumologic.endpoint=${RESOLVED_ENDPOINT}")
    helm_args+=("${SUMO_COMMON_SET[@]}")

    # --dry-run: show the assembled command (with helm's own --dry-run appended, the
    # validating form) and stop — no wait prompt, no install, no next-steps. The shown
    # --values path is the temp secrets file, so no credentials are echoed. (Args are
    # space-joined for display; copy-paste needs quoting if a values path has spaces.)
    if [[ -n "$DRY_RUN" ]]; then
        echo "${C_BOLD}${C_BLUE}[dry-run]${C_RESET} would run: helm ${helm_args[*]} --dry-run" >&2
        echo "${C_BOLD}${C_BLUE}[dry-run]${C_RESET} collector not installed; no changes made." >&2
        return 0
    fi

    # Optionally block until the collector pods are Ready (helm --wait). Default yes;
    # decline for a fire-and-forget install and check progress with -s/--status.
    if confirm "Wait for the collector pods to become ready?" y; then
        helm_args+=(--wait --timeout "$HELM_WAIT_TIMEOUT")
    fi

    # Guard the install so a failure (incl. a --wait timeout) gives an actionable hint
    # rather than the generic ERR-trap message. run_cmd echoes it first under --verbose.
    if ! run_cmd helm "${helm_args[@]}"; then
        echo "Helm install did not complete cleanly (see the error above)." >&2
        echo "Inspect what's deployed:  $0 -s" >&2
        echo "Watch the pods:           kubectl get pods -n sumologic -w" >&2
        exit 1
    fi

    # Success: surface concrete next steps (label/name reflect fullnameOverride=sumo).
    cat <<EOF

${C_BOLD}${C_GREEN}Sumo collector installed — chart ${chart_version}, cluster '${CLUSTER_NAME}'.${C_RESET}
${C_BOLD}Next steps:${C_RESET}
  Watch pods:           kubectl get pods -n sumologic -w
  Tail collector logs:  kubectl logs -n sumologic -l app.kubernetes.io/name=sumo-otelcol-logs-collector -f
  Health check:         $0 -s
  Confirm data in Sumo: https://help.sumologic.com/docs/send-data/kubernetes/
EOF
}

# Reinstall the collector: uninstall the existing `sumologic` Helm release, then run the
# normal install (`helm upgrade --install`). For when an in-place upgrade (-m) is wedged.
# The KinD cluster and Podman machine are left intact (use -u/-p to remove those).
function reinstall {
    require_cmd helm
    echo "Reinstall removes the 'sumologic' Helm release and installs it fresh."
    echo "The KinD cluster and Podman machine stay intact (use -u/-p to remove those)."
    # Plain confirm() (honors -y) is intentional here, NOT confirm_destructive: a reinstall
    # is recoverable (install_sumo runs immediately after, and the cluster/machine/stored
    # credentials are untouched), unlike the irreversible wipes confirm_destructive guards.
    if ! confirm "Uninstall and reinstall the sumologic collector?" n; then
        echo "Cancelled; nothing changed."
        exit 0
    fi
    # Resolve the cluster once and pin --kube-context so the uninstall and the reinstall
    # target the SAME cluster and neither touches a stray current context. install_sumo
    # (called below) reuses this CLUSTER_NAME instead of re-asking (CLUSTER_NAME_RESOLVED).
    CLUSTER_NAME=$(ask_cluster_name "Name of the cluster [default=${DEFAULT_CLUSTER_NAME}]: " "$DEFAULT_CLUSTER_NAME")
    CLUSTER_NAME_RESOLVED=yes
    local cluster_ctx="kind-${CLUSTER_NAME}"
    # Only uninstall if a release is actually present, so a reinstall also works as a plain
    # install after a partial/failed deploy. `exit 1` (not return) keeps a stuck-uninstall
    # error from being doubled by the bare-dispatch ERR trap.
    if helm --kube-context "$cluster_ctx" status sumologic --namespace sumologic >/dev/null 2>&1; then
        echo "Uninstalling the existing 'sumologic' release..."
        if ! run_cmd helm --kube-context "$cluster_ctx" uninstall sumologic --namespace sumologic; then
            echo "Error: 'helm uninstall sumologic' failed. If a resource is stuck on a finaliser," >&2
            echo "       see the finaliser-patch steps in examples/README.md, then re-run --reinstall." >&2
            exit 1
        fi
    else
        # helm status also exits non-zero when the cluster is unreachable, so hedge rather
        # than assert "no release" — install_sumo surfaces a clear error if it can't connect.
        echo "No active 'sumologic' release found (or the cluster is unreachable); proceeding to install."
    fi
    install_sumo
}

function output {
    require_cmd helm
    local K8S_YAML # CLUSTER_NAME / HELM_VALUES stay global (shared / config knob); K8S_YAML is output-only.

    HELM_VALUES=$(prompt_values_file) || exit 1
    CLUSTER_NAME=$(ask "Name of the cluster [default=${DEFAULT_CLUSTER_NAME}]: " "$DEFAULT_CLUSTER_NAME")
    K8S_YAML=$(ask "Name and Location of the rendered Kubernetes Manifest YAML file. [default=sumologic-rendered.yaml]: " "$DEFAULT_K8S_YAML")

    # Validate the target path up front, before any prompt or helm work: reject a missing
    # parent directory, or a path that is itself an existing directory (the atomic mv
    # below would otherwise move the render *into* it). dirname of a bare filename like
    # the default is ".", which always exists.
    local out_dir
    out_dir=$(dirname "$K8S_YAML")
    [[ -d "$out_dir" ]] || {
        echo "Error: output directory '${out_dir}' for '${K8S_YAML}' does not exist." >&2
        exit 1
    }
    if [[ -d "$K8S_YAML" ]]; then
        echo "Error: '${K8S_YAML}' is an existing directory, not a file." >&2
        exit 1
    fi

    # Don't silently clobber an existing render. confirm() honours -y/ASSUME_YES
    # (auto-overwrite) — acceptable here because the output file is a regenerable
    # artifact, not irreversible state like a cluster teardown (which routes through
    # confirm_destructive instead). Checked before the helm work so a declined
    # overwrite costs nothing and leaves the file untouched.
    if [[ -e "$K8S_YAML" ]] && ! confirm "File '${K8S_YAML}' already exists. Overwrite?" n; then
        echo "Aborted; '${K8S_YAML}' left unchanged." >&2
        exit 0
    fi

    # The chart is referenced as sumologic/sumologic, so the repo must be registered.
    ensure_helm_repo

    local chart_version
    chart_version=$(select_chart_version)

    # The chart requires accessId/accessKey to render. Use PLACEHOLDER credentials so
    # the rendered manifest is faithful in structure without writing real secrets to the
    # output file; deploy with -i/-m, which inject real credentials securely. Placeholders
    # go via a private temp values file (consistent with install_sumo) rather than argv.
    secrets_file=$(mktemp)
    chmod 600 "$secrets_file"
    trap 'rm -f "$secrets_file"' EXIT
    cat >"$secrets_file" <<'EOF'
sumologic:
  accessId: "PLACEHOLDER_ACCESS_ID"
  accessKey: "PLACEHOLDER_ACCESS_KEY"
EOF

    # Mirror install_sumo's args so the rendered manifest matches what -i/-m deploys:
    # optional user values, then placeholder creds, clusterName, and the shared overrides.
    # No --kube-context here (unlike install_sumo/reinstall): `helm template` renders
    # offline and never contacts a cluster, so there is no current-context to pin against.
    local template_args=(template sumologic sumologic/sumologic
        --version "$chart_version"
        --namespace=sumologic --create-namespace)
    [[ -n "$HELM_VALUES" ]] && template_args+=(--values "$HELM_VALUES")
    template_args+=(--values "$secrets_file")
    template_args+=(--set-string "sumologic.clusterName=${CLUSTER_NAME}")
    # Reflect a preset deployment endpoint so the render matches a regional install. No
    # prompt/validation here: `output` renders offline with placeholder creds. Uses the same
    # offline resolver as install --dry-run (unknown region -> blank), so the render can't
    # drift from what a live install would deploy. Blank => unset.
    local rendered_endpoint
    rendered_endpoint=$(endpoint_for_input "$SUMOLOGIC_ENDPOINT")
    [[ -n "$rendered_endpoint" ]] && template_args+=(--set-string "sumologic.endpoint=${rendered_endpoint}")
    template_args+=("${SUMO_COMMON_SET[@]}")

    # Render atomically: write to a temp file in the SAME directory as the target (so the
    # final mv is an atomic rename that never crosses a filesystem), then mv into place
    # only on a fully-successful render. A failed render therefore never leaves a partial
    # file nor clobbers a pre-existing good render. tee still echoes the manifest to stdout.
    # render_tmp is intentionally NOT local: the EXIT trap runs in the global scope, where
    # function-locals are invisible (an empty "$render_tmp" would skip the cleanup and leak
    # the temp on failure). secrets_file is global for the same reason.
    # Capture with `|| true` INSIDE the $() (a bare `if ! …=$(mktemp …)` does NOT protect it):
    # under `set -E` the subshell inherits the ERR trap, so an mktemp failure fires the generic
    # ERR-trap message there (on stderr) before our clear line. Empty render_tmp => mktemp failed.
    render_tmp=$(mktemp "${out_dir}/.sumo-render.XXXXXX" 2>/dev/null || true)
    if [[ -z "$render_tmp" ]]; then
        echo "Error: cannot create a temporary file in '${out_dir}' to render into." >&2
        exit 1
    fi
    trap 'rm -f "$secrets_file" "$render_tmp"' EXIT
    # mktemp creates the temp 0600; the rendered manifest is non-secret (placeholder
    # creds), so restore the umask-derived perms the old `tee` redirect produced.
    chmod "$(printf '%04o' "$((0666 & ~0$(umask)))")" "$render_tmp"

    # Run the pipeline errexit-exempt and capture BOTH stage statuses (identical in either
    # branch — `:`/another command would reset PIPESTATUS). Checking PIPESTATUS[0] (helm)
    # explicitly, not the pipeline's aggregate status, catches a helm-render failure even
    # though tee still exits 0 — i.e. independent of whether pipefail is set. tee echoes to
    # stdout. index 0 is helm (render), index 1 is tee (write).
    local pipe_status
    if helm "${template_args[@]}" | tee "${render_tmp}"; then
        pipe_status=("${PIPESTATUS[@]}")
    else
        pipe_status=("${PIPESTATUS[@]}")
    fi
    if [[ "${pipe_status[0]}" -ne 0 ]]; then
        echo "Error: helm failed to render the chart (exit ${pipe_status[0]}); '${K8S_YAML}' left unchanged." >&2
        exit 1
    elif [[ "${pipe_status[1]:-0}" -ne 0 ]]; then
        echo "Error: failed to write the rendered manifest (tee exit ${pipe_status[1]}); '${K8S_YAML}' left unchanged." >&2
        exit 1
    fi
    if ! mv "$render_tmp" "$K8S_YAML"; then
        echo "Error: rendered the chart but could not move it into place at '${K8S_YAML}'; '${K8S_YAML}' left unchanged." >&2
        exit 1
    fi
    echo "Rendered sumologic/sumologic chart version ${chart_version} to ${K8S_YAML}." >&2
    echo "Note: the rendered Secret uses placeholder credentials; deploy with -i/-m to inject real ones." >&2
}

# Shared teardown preamble for uninstall/purge: ensure kind is present and point KinD at
# the runtime that backs the cluster, so it can find and delete it. select_runtime failure
# is a clean exit (not the ERR trap), matching the originals.
function prepare_teardown {
    require_cmd kind
    # Match KinD to the runtime that backs the cluster so it can find/delete it.
    if ! select_runtime; then exit 1; fi
    set_kind_provider
}

# Delete the named KinD cluster. CLUSTER_NAME is resolved by confirm_destructive (the
# caller must run it first). Shared by uninstall/purge.
function delete_kind_cluster {
    echo "Deleting Cluster: ${CLUSTER_NAME}"
    run_cmd kind delete cluster --name "${CLUSTER_NAME}"
}

function uninstall {
    prepare_teardown

    echo "Caution: This will delete the cluster"
    confirm_destructive "delete the cluster"
    delete_kind_cluster
    if [[ "$CONTAINER_RUNTIME" == "podman" && "$OS" == "darwin" ]]; then
        echo "Leaving Podman machine intact (use --purge to remove it)."
    fi
}

function purge {
    prepare_teardown

    # Podman machines only exist with Podman on macOS; under Docker (or Linux
    # Podman) there is no machine to remove.
    local has_machine="no" running_machine=""
    if [[ "$CONTAINER_RUNTIME" == "podman" && "$OS" == "darwin" ]]; then
        require_cmd jq
        has_machine="yes"
        running_machine=$(podman machine list --format json | jq -r '.[] | select(.Running == true) | .Name')
        echo "Caution: This will delete the cluster and remove the - ${running_machine} - Podman machine!"
    else
        echo "Caution: This will delete the cluster. (No Podman machine to remove under ${CONTAINER_RUNTIME}.)"
    fi

    confirm_destructive "delete the cluster and remove the Podman machine"
    delete_kind_cluster
    if [[ "$has_machine" == "yes" && -n "$running_machine" ]]; then
        # Teardown is already gated by confirm_destructive above (which also made the user
        # retype the cluster name), so pass --force to `podman machine rm`: without it podman
        # prints its own file list and a SECOND "Are you sure?" prompt that gets visually lost
        # in that list. One clear, coloured heading here instead of a buried plain-text prompt.
        echo "${C_BOLD}${C_MAGENTA}Stopping and removing the '${running_machine}' Podman machine...${C_RESET}"
        podman machine stop "${running_machine}"
        podman machine rm --force "${running_machine}"
    fi

    if secret_delete sumologic_access_id; then
        echo "${C_BOLD}${C_GREEN}Removed${C_RESET} '${C_BOLD}sumologic_access_id${C_RESET}' from secret storage."
    else
        echo "${C_YELLOW}Sumo Logic Access ID not found in secret storage; continuing to purge.${C_RESET}"
    fi

    if secret_delete sumologic_access_key; then
        echo "${C_BOLD}${C_GREEN}Removed${C_RESET} '${C_BOLD}sumologic_access_key${C_RESET}' from secret storage."
    else
        echo "${C_YELLOW}Sumo Logic Access Key not found in secret storage; continuing to purge.${C_RESET}"
    fi
}

function version {
    echo "sumo-otel-local ${VERSION}"
}

# Report the health of the local setup: container runtime, Podman machine (macOS),
# the KinD cluster, the Sumo collector Helm release, and its pods. This is a read-only
# doctor command: EVERY probe is non-fatal (guarded so a missing piece reports
# "not found" rather than tripping errexit / the ERR trap), and missing tools are
# reported rather than fatal.
function status {
    echo "${C_BOLD}${C_MAGENTA}== sumo-otel-local status ==${C_RESET}"

    # Container runtime + KinD provider.
    if select_runtime; then
        set_kind_provider
        echo "Container runtime: ${CONTAINER_RUNTIME} (KIND_EXPERIMENTAL_PROVIDER=${KIND_EXPERIMENTAL_PROVIDER:-})"
    else
        echo "Container runtime: none found — install Docker or Podman."
        return 0
    fi

    # Podman machine (macOS only).
    if [[ "$CONTAINER_RUNTIME" == "podman" && "$OS" == "darwin" ]]; then
        if command -v jq &>/dev/null; then
            local machines
            machines=$(podman machine list --format json 2>/dev/null || true)
            if [[ -n "$machines" && "$machines" != "[]" ]]; then
                echo "Podman machines:"
                printf '%s' "$machines" |
                    jq -r '.[] | "  - \(.Name): running=\(.Running), memory=\(.Memory), cpus=\(.CPUs)"' 2>/dev/null ||
                    echo "  (could not parse machine list)"
            else
                echo "Podman machines: none (run -n/--init to create one)."
            fi
        else
            echo "Podman machines: jq not installed; skipping."
        fi
    fi

    # KinD cluster.
    local cluster_name
    cluster_name=$(ask "Cluster name to check [default=${DEFAULT_CLUSTER_NAME}]: " "$DEFAULT_CLUSTER_NAME")
    if ! command -v kind &>/dev/null; then
        echo "Cluster '${cluster_name}': kind not installed; cannot check."
        return 0
    fi
    if cluster_exists "$cluster_name"; then
        echo "Cluster '${cluster_name}': present."
    else
        echo "Cluster '${cluster_name}': not found (run -i/--install or -n/--init)."
        return 0
    fi

    # Sumo collector Helm release.
    if command -v helm &>/dev/null; then
        if helm status sumologic --namespace sumologic >/dev/null 2>&1; then
            echo "Helm release 'sumologic' (namespace sumologic):"
            helm status sumologic --namespace sumologic 2>/dev/null |
                grep -E '^(NAME|NAMESPACE|STATUS|REVISION|LAST DEPLOYED):' | sed 's/^/  /' || true
        else
            echo "Helm release 'sumologic': not installed (run -m/--helm or -i/--install)."
        fi
    else
        echo "Helm release: helm not installed; skipping."
    fi

    # Collector pods.
    if command -v kubectl &>/dev/null; then
        echo "Pods (namespace sumologic):"
        kubectl --context "kind-${cluster_name}" get pods -n sumologic 2>/dev/null | sed 's/^/  /' ||
            echo "  could not list pods (cluster unreachable or namespace absent)."
    else
        echo "Pods: kubectl not installed; skipping."
    fi
}

# Report errors without destroying anything. Previously this trap ran the
# interactive uninstall flow, so any failed command (with `set -e`) could delete
# the user's cluster. Now it only reports the failure and exits non-zero; cluster
# teardown is left to the explicit --uninstall / --purge options.
function on_error {
    local exit_code=$?
    local line_no=${1:-unknown}
    echo "" >&2
    echo "${C_BOLD}${C_RED}Error: command failed (exit ${exit_code}) at line ${line_no}.${C_RESET}" >&2
    echo "Nothing has been changed or removed. To tear down a cluster, re-run with -u/--uninstall or -p/--purge." >&2
    exit "${exit_code}"
}

# Print an ASCII banner on launch. Stderr-only and TTY-gated (like colours), so it never
# pollutes captured stdout or non-interactive/CI output. Purely cosmetic.
function banner {
    [[ -t 2 ]] || return 0
    printf '%s\n' "${C_BOLD}${C_MAGENTA}" >&2
    cat >&2 <<'EOF'
   ___                    ___ _____ ___ _
  / __|_  _ _ __  ___    / _ \_   _| __| |
  \__ \ || | '  \/ _ \  | (_) || | | _|| |__
  |___/\_,_|_|_|_\___/   \___/ |_| |___|____|
EOF
    printf '%s  local KinD cluster + Sumo Logic OpenTelemetry collector  ·  v%s%s\n\n' \
        "${C_RESET}${C_DIM}" "${VERSION}" "${C_RESET}" >&2
}

# Record the CLI action chosen during parsing. Repeating the same action is idempotent;
# selecting a *different* action flags a conflict. Updates main()'s `action`/`conflict`
# via bash dynamic scope (this is only ever called from main).
function set_action {
    # shellcheck disable=SC2154  # action/conflict are main()'s locals (dynamic scope)
    if [[ -n "$action" && "$action" != "$1" ]]; then
        conflict="yes"
    fi
    action="$1"
}

# Print the Sumo Logic collection endpoints from the in-cluster `sumologic` secret,
# base64-decoded (the secret stores one `endpoint-*` key per signal). Read-only; requires
# kubectl + jq and a reachable cluster. Uses the script's conventions (namespace sumologic,
# kind-<cluster> context).
function endpoints {
    require_cmd kubectl jq
    local cluster_name secret_json
    cluster_name=$(ask_cluster_name "Cluster name [default=${DEFAULT_CLUSTER_NAME}]: " "$DEFAULT_CLUSTER_NAME")
    # Put the graceful `|| true` INSIDE the command substitution — a bare `if ! …=$(kubectl …)`
    # does NOT protect the kubectl call: under `set -E` the $(…) subshell inherits the ERR trap,
    # so a kubectl failure fires on_error *inside the subshell* (the outer `if !` only exempts the
    # assignment in this shell), printing a spurious "command failed / nothing changed" line —
    # on stderr, so `2>/dev/null` can't hide it — before our own message. `|| true` keeps the
    # subshell's status 0; an unreachable cluster / missing secret yields empty output.
    secret_json=$(kubectl --context "kind-${cluster_name}" -n sumologic get secret sumologic -o json 2>/dev/null || true)
    if [[ -z "$secret_json" ]]; then
        echo "Error: could not read the 'sumologic' secret (cluster unreachable, or the collector isn't installed)." >&2
        exit 1
    fi
    echo "Sumo Logic collection endpoints (namespace sumologic):"
    # Stream through jq in the `if` condition (errexit-exempt) so a jq failure — e.g. a
    # value that isn't valid base64 — is reported cleanly here, rather than firing the ERR
    # trap inside a command-substitution subshell (where the pipeline wouldn't be exempt).
    # jq emits the "none found" line itself when there are no endpoint-* keys.
    if ! printf '%s' "$secret_json" | jq -r '
        (.data // {} | to_entries | map(select(.key | startswith("endpoint-")))) as $eps
        | if ($eps | length) == 0 then "  (no endpoint-* keys found)"
          else $eps[] | "  \(.key) = \(.value | @base64d)" end'; then
        echo "Error: could not decode the secret's endpoint values (a value was not valid base64?)." >&2
        exit 1
    fi
}

# Port-forward the TRACES collector's OTLP receiver to localhost so local apps can send
# OTLP traces to the cluster. The script installs with fullnameOverride=sumo, so the
# traces collector service is svc/sumo-otelcol, exposing 4317 (gRPC) + 4318 (HTTP).
# Blocks until Ctrl-C. Requires kubectl + a reachable cluster.
function forward {
    require_cmd kubectl
    local cluster_name cluster_ctx rc
    cluster_name=$(ask_cluster_name "Cluster name [default=${DEFAULT_CLUSTER_NAME}]: " "$DEFAULT_CLUSTER_NAME")
    cluster_ctx="kind-${cluster_name}"
    if ! kubectl --context "$cluster_ctx" -n sumologic get svc sumo-otelcol >/dev/null 2>&1; then
        echo "Error: svc/sumo-otelcol not found in namespace sumologic (is the collector installed and the cluster reachable?)." >&2
        exit 1
    fi
    echo "Forwarding the traces collector (svc/sumo-otelcol) OTLP -> localhost:4317 (gRPC) and :4318 (HTTP)." >&2
    echo "Point an OTLP trace exporter at localhost:4317 or :4318. Press Ctrl-C to stop." >&2
    # port-forward blocks until Ctrl-C, which delivers SIGINT and makes kubectl exit 130.
    # Treat that (and a clean 0) as a normal stop, so it doesn't trip the ERR trap with a
    # misleading "command failed / nothing changed" teardown message.
    rc=0
    kubectl --context "$cluster_ctx" -n sumologic port-forward svc/sumo-otelcol 4317:4317 4318:4318 || rc=$?
    if [[ "$rc" -eq 0 || "$rc" -eq 130 ]]; then
        echo "Stopped port-forwarding." >&2
        return 0
    fi
    echo "Error: port-forward exited unexpectedly (exit ${rc})." >&2
    exit 1
}

# Copy the bundled template to $SUMO_CONFIG_FILE so the user can preset knobs (region,
# cluster, chart version) instead of re-answering prompts. The caller decides whether to
# overwrite; this just writes and prints guidance. Returns non-zero if the template is
# missing or the copy fails.
# True if the project config is explicitly disabled — SUMO_CONFIG_FILE=/dev/null (the
# documented "ignore config for this run" idiom) or empty. Neither the offer nor --init-config
# should act on a disabled config.
function config_disabled {
    [[ -z "$SUMO_CONFIG_FILE" || "$SUMO_CONFIG_FILE" == "/dev/null" ]]
}

function write_config_from_template {
    local example="$SCRIPT_DIR/.sumo-otel-local.env.example"
    if [[ ! -f "$example" ]]; then
        echo "Error: config template not found at '${example}'." >&2
        echo "Run the script from its repository clone (the template ships alongside it)." >&2
        return 1
    fi
    cp "$example" "$SUMO_CONFIG_FILE" || return 1
    # A per-user config that may end up holding credentials should not be world-readable;
    # match the chmod-600 convention used for the temp values file.
    chmod 600 "$SUMO_CONFIG_FILE" 2>/dev/null || true
    echo "${C_BOLD}${C_GREEN}Created ${SUMO_CONFIG_FILE} from the template.${C_RESET}" >&2
    echo "Edit it (e.g. uncomment 'SUMOLOGIC_ENDPOINT=us2'), then re-run to apply." >&2
}

# --init-config action: scaffold the project config. Overwriting an EXISTING config is
# treated as destructive (it holds the user's hand-edited knobs, possibly credentials): like
# confirm_destructive, ASSUME_YES alone must NOT wipe it — require an interactive yes or the
# explicit --force.
function init_config {
    if config_disabled; then
        echo "Config is disabled (SUMO_CONFIG_FILE='${SUMO_CONFIG_FILE}'); nothing to create." >&2
        exit 1
    fi
    if [[ -e "$SUMO_CONFIG_FILE" ]]; then
        if [[ -n "$FORCE" ]]; then
            echo "--force: overwriting existing config '${SUMO_CONFIG_FILE}'." >&2
        elif [[ -n "$ASSUME_YES" ]]; then
            echo "Refusing to overwrite existing config '${SUMO_CONFIG_FILE}' under -y/ASSUME_YES." >&2
            echo "Pass --force to overwrite it, or remove it first." >&2
            exit 1
        elif ! confirm "Config '${SUMO_CONFIG_FILE}' already exists. Overwrite?" n; then
            echo "Left '${SUMO_CONFIG_FILE}' unchanged." >&2
            exit 0
        fi
    fi
    write_config_from_template || exit 1
}

# On an interactive setup run (-i/-n/-m/-r) with no project config present, offer to scaffold
# one so the user can preset the Sumo region etc. and skip prompts. On yes: create it and exit
# so they can edit before running. On no (or EOF): continue normally. Skipped under ASSUME_YES
# (the config is sourced at startup, so a mid-run create can't affect it), under --dry-run
# (which must touch nothing), and when the config is explicitly disabled.
function maybe_offer_config_init {
    [[ -n "$ASSUME_YES" ]] && return 0       # unattended: never prompt
    [[ -n "$DRY_RUN" ]] && return 0          # dry-run touches nothing
    config_disabled && return 0              # config explicitly disabled (/dev/null)
    [[ -f "$SUMO_CONFIG_FILE" ]] && return 0 # already have one (it was loaded at startup)
    echo "No project config (${SUMO_CONFIG_FILE}) found. Creating one lets you preset the Sumo" >&2
    echo "region (SUMOLOGIC_ENDPOINT), cluster name, chart version, etc. and skip these prompts." >&2
    if confirm "Create ${SUMO_CONFIG_FILE} from the template now?" n; then
        write_config_from_template || exit 1
        exit 0
    fi
    echo "Continuing without one; create it anytime with '$0 --init-config'." >&2
}

# Entry point. Enabling strict mode and the ERR trap here (rather than at the top
# level) keeps the script sourceable by the test suite without side effects.
function main {
    # -E (errtrace) makes the ERR trap fire for failures inside functions too —
    # without it on_error would be dead code, since every fallible command runs in a
    # function. errexit already exits on those failures; -E adds the friendly report.
    set -Eeuo pipefail
    trap 'on_error ${LINENO}' ERR

    # Parse ALL flags into state first, then dispatch a single action. This keeps the
    # modifiers (-y/--yes, -f/--force) order-independent. Repeating the same action is
    # fine; two *different* actions (e.g. `-i -u`) is a clear error instead of the old
    # silent first-wins. Errors are deferred to after parsing so -h always wins and the
    # report doesn't depend on token order.
    # Expand clustered short flags (e.g. -iy -> -i -y, -yi -> -y -i) so modifiers can be
    # combined with an action. Only a single dash followed by 2+ letters is split; long
    # flags (--foo), single short flags (-i) and non-flags pass through unchanged. Guarded
    # so an empty array isn't expanded under `set -u` (a Bash 3.2 nounset gotcha).
    if [[ $# -gt 0 ]]; then
        local expanded=() tok j
        for tok in "$@"; do
            if [[ "$tok" =~ ^-[A-Za-z][A-Za-z]+$ ]]; then
                for ((j = 1; j < ${#tok}; j++)); do
                    expanded+=("-${tok:j:1}")
                done
            else
                expanded+=("$tok")
            fi
        done
        set -- "${expanded[@]}"
    fi

    local action="" conflict="" show_help="" bad_flag=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help) show_help="yes" ;;
            -i | --install) set_action install ;;
            -n | --init) set_action init ;;
            -m | --helm) set_action helm ;;
            -r | --reinstall) set_action reinstall ;;
            -o | --output) set_action output ;;
            -s | --status) set_action status ;;
            -e | --endpoints) set_action endpoints ;;
            --forward) set_action forward ;;
            -p | --purge) set_action purge ;;
            -u | --uninstall) set_action uninstall ;;
            -v | --version) set_action version ;;
            --init-config) set_action init_config ;;
            --store-credentials) set_action store_credentials ;;
            # Modifiers (not actions): order-independent, may appear before or after.
            -y | --yes | --non-interactive) ASSUME_YES="yes" ;;
            -f | --force) FORCE="yes" ;;
            --dry-run) DRY_RUN="yes" ;;
            -V | --verbose) VERBOSE="yes" ;;
            *) if [[ -z "$bad_flag" ]]; then bad_flag="$1"; fi ;;
        esac
        shift
    done

    # Cosmetic launch banner (stderr, TTY-only). Skipped for -v/--version so its stdout stays
    # a clean, parseable version string.
    [[ "$action" != "version" ]] && banner

    # -h/--help always wins: print usage and exit cleanly, before any error.
    if [[ -n "$show_help" ]]; then
        help
        exit 0
    fi

    if [[ -n "$bad_flag" ]]; then
        echo "Invalid Option: $bad_flag" >&2
        help >&2
        exit 1
    fi

    if [[ -n "$conflict" ]]; then
        echo "Specify exactly one action (-i/-n/-m/-r/-o/-s/-e/--forward/-p/-u/-v/--init-config/--store-credentials)." >&2
        help >&2
        exit 1
    fi

    # --dry-run only previews the install flow. Refuse it for other actions rather than
    # silently ignoring it — otherwise e.g. `--dry-run -u` would still delete the cluster.
    if [[ -n "$DRY_RUN" && "$action" != "install" && "$action" != "init" && "$action" != "helm" ]]; then
        echo "Error: --dry-run only applies to the install flow (-i/-n/-m)." >&2
        exit 1
    fi

    # On interactive setup runs with no project config, offer to scaffold one first so the
    # user can preset the region/cluster and skip prompts (declining just continues).
    case "$action" in
        install | init | helm | reinstall) maybe_offer_config_init ;;
    esac

    case "$action" in
        install)
            preflight_credentials # fail fast (unattended) before deps/Podman/cluster work
            install_dependencies
            init_cluster
            install_sumo
            ;;
        init)
            install_dependencies
            init_cluster
            ;;
        helm)
            preflight_credentials
            install_sumo
            ;;
        reinstall)
            preflight_credentials # before the release uninstall reinstall performs
            reinstall
            ;;
        output) output ;;
        status) status ;;
        endpoints) endpoints ;;
        forward) forward ;;
        purge) purge ;;
        uninstall) uninstall ;;
        version) version ;;
        init_config) init_config ;;
        store_credentials) store_credentials ;;
        *)
            echo "Specify exactly one action (-i/-n/-m/-r/-o/-s/-e/--forward/-p/-u/-v/--init-config/--store-credentials), or -h for help." >&2
            help >&2
            exit 1
            ;;
    esac
}

# Run main only when executed directly, not when sourced (e.g. by the test suite).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
