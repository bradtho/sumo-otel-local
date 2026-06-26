#!/bin/bash

# Strict mode and the ERR trap are enabled inside main() (see bottom), not at the top
# level, so the script can be safely `source`d by the test suite (tests/) to exercise
# individual functions without running the CLI, enabling errexit, or installing traps.

# Helper Functions
function help {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -h, --help      Display this help message."
    echo "  -i, --install   Install the dependencies and setup the Sumo Operator."
    echo "  -n, --init      Install dependencies without setting up the Sumo Operator."
    echo "  -m, --helm      Install Sumo Operator onto existing cluster."
    echo "  -o, --output    Output the rendered Kubernetes manifest YAML file."
    echo "  -s, --status    Report cluster and collector health (read-only)."
    echo "  -p, --purge     Uninstall the cluster (and, with Podman on macOS, the Podman machine)."
    echo "  -u, --uninstall Uninstall the Cluster only."
    echo "  -v, --version   Display the version of the script."
    echo "  -y, --yes       Run unattended: assume yes and use defaults for all prompts."
    echo "                  (also via the ASSUME_YES env var; --non-interactive is an alias)"
    echo "  -f, --force     Confirm destructive teardown (-u/-p) non-interactively."
    echo "                  Required for -u/-p under -y; never read from the environment."
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

# Optional project-local config for repeatable runs. A shell snippet of KEY=value lines
# (no YAML parser needed); it is sourced with `set -a` BEFORE the constants below, so it
# can set any env knob the script reads: CONTAINER_RUNTIME, CLUSTER_NAME, HELM_VALUES,
# SUMO_CHART_VERSION, MIN_MEM_MB, MIN_CPU, ASSUME_YES. See .sumo-otel-local.env.example.
# It deliberately CANNOT set FORCE (that is flag-only; reset below) and is not a place
# for credentials. Path overridable via SUMO_CONFIG_FILE.
SUMO_CONFIG_FILE="${SUMO_CONFIG_FILE:-./.sumo-otel-local.env}"
if [[ -f "$SUMO_CONFIG_FILE" ]]; then
    echo "Loading config from ${SUMO_CONFIG_FILE}" >&2
    set -a
    # shellcheck disable=SC1090
    . "$SUMO_CONFIG_FILE"
    set +a
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

# Pinned kindest/node image — the Kubernetes version the KinD cluster runs. This is the
# default node image that kind ${KIND_VERSION} ships and tests with, so it pairs with the
# pinned kind and renders/validates against the pinned chart. Used as the default in
# init_cluster; select_node_image still lets you pick another version interactively.
# Deliberately NOT Renovate-annotated: the node image is coupled to KIND_VERSION (it must
# fall in kind's supported range), so bump it together with kind, not independently.
# Known-good digest (kind v0.32.0 default): sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5
KINDEST_NODE_VERSION="${KINDEST_NODE_VERSION:-v1.36.1}"

# Script version. Kept in sync with the published GitHub Release tag; printed by
# -v/--version without any network calls. The trailing annotation lets
# release-please rewrite this line automatically when it cuts a release.
VERSION="0.4.0" # x-release-please-version

# Default KinD cluster name, used by create and teardown. Honors a CLUSTER_NAME set in
# the environment / config file, so every name prompt (which defaults to this) and the
# teardown/status flows pick it up.
DEFAULT_CLUSTER_NAME="${CLUSTER_NAME:-sumo}"

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

# Ask a yes/no question. $1=prompt, $2=default (y|n, default n). Returns 0 for yes.
# In unattended mode (ASSUME_YES) it answers yes without prompting.
function confirm {
    local prompt=$1 default=${2:-n} reply hint
    [[ "$default" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
    if [[ -n "$ASSUME_YES" ]]; then
        echo "${prompt} ${hint} y (assumed)" >&2
        return 0
    fi
    read -rp "${prompt} ${hint} " reply
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
    read -rp "$prompt" reply
    printf '%s' "${reply:-$default}"
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
function install_dependencies {

    if command -v brew &>/dev/null; then
        echo "Installing Dependencies with Homebrew..."
        # Homebrew always installs the current formula version; the KIND_VERSION /
        # KUBECTL_VERSION / HELM_VERSION / PODMAN_VERSION pins apply only to the
        # direct-download fallback below, so brew pinning is best-effort (none here).
        # Only install a container runtime when the user has neither already.
        local brew_pkgs=(jq kubectl helm kind)
        if ! command -v docker &>/dev/null && ! command -v podman &>/dev/null; then
            brew_pkgs+=(podman)
        fi
        brew install --quiet "${brew_pkgs[@]}"
    elif ! command -v brew &>/dev/null; then
        if confirm "Homebrew is not installed. Install it?" n; then
            curl -fsSL -o install_homebrew.sh https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh
            chmod 700 install_homebrew.sh
            ./install_homebrew.sh
            rm install_homebrew.sh
            install_dependencies
        else
            echo "Installing Dependencies Directly..."
            local jq_base ver
            if ! command -v jq &>/dev/null; then
                echo "Installing jq..."
                jq_base="https://github.com/jqlang/jq/releases/download/jq-1.7.1"
                curl -fsSL -o /tmp/jq "${jq_base}/jq-${JQ_OS}-${ARCH}"
                verify_sha256 /tmp/jq "$(remote_sha256 "${jq_base}/sha256sum.txt" "jq-${JQ_OS}-${ARCH}")" jq
                install_binary /tmp/jq jq
            fi

            if ! command -v kubectl &>/dev/null; then
                echo "Installing Kubectl ${KUBECTL_VERSION}..."
                curl -fsSL -o /tmp/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl"
                verify_sha256 /tmp/kubectl "$(remote_sha256 "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl.sha256")" kubectl
                install_binary /tmp/kubectl kubectl
                kubectl version --client
            fi

            if ! command -v helm &>/dev/null; then
                echo "Installing Helm ${HELM_VERSION}..."
                # get-helm-3 verifies the downloaded helm tarball against its published
                # SHA-256 itself, so the binary is checksum-checked; DESIRED_VERSION pins
                # which helm version it installs. (The script is fetched from a mutable
                # master ref — pinning that is a separate item.)
                curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3
                chmod 700 /tmp/get_helm.sh
                DESIRED_VERSION="$HELM_VERSION" /tmp/get_helm.sh
                rm -f /tmp/get_helm.sh
            fi

            # Only auto-install a runtime when the user has neither Docker nor Podman.
            if ! command -v docker &>/dev/null && ! command -v podman &>/dev/null; then
                echo "Installing Podman ${PODMAN_VERSION}..."
                if [[ "$OS" == "darwin" ]]; then
                    # The release tag carries a leading 'v' (used in the URL); the zip's
                    # internal directory does not (podman-6.0.0/, not podman-v6.0.0/).
                    ver="${PODMAN_VERSION#v}"
                    curl -fsSL -o /tmp/podman.zip "https://github.com/containers/podman/releases/download/${PODMAN_VERSION}/podman-remote-release-darwin_${ARCH}.zip"
                    verify_sha256 /tmp/podman.zip "$(remote_sha256 "https://github.com/containers/podman/releases/download/${PODMAN_VERSION}/shasums" "podman-remote-release-darwin_${ARCH}.zip")" podman
                    rm -rf /tmp/podman-extract
                    unzip -q /tmp/podman.zip -d /tmp/podman-extract
                    install_binary "/tmp/podman-extract/podman-${ver}/usr/bin/podman" podman
                    install_binary "/tmp/podman-extract/podman-${ver}/usr/bin/podman-mac-helper" podman-mac-helper
                    rm -rf /tmp/podman.zip /tmp/podman-extract
                else
                    # On Linux, Podman runs natively (no VM/machine) and needs rootless
                    # dependencies a single static binary can't provide. Defer to the
                    # distro package manager. See TODO.md (P1 first-class runtime task).
                    echo "On Linux, install Podman with your distribution's package manager, e.g.:"
                    echo "  sudo apt-get install -y podman   # Debian/Ubuntu"
                    echo "  sudo dnf install -y podman       # Fedora/RHEL"
                    echo "Then re-run this script."
                    exit 1
                fi
            fi

            if ! command -v kind &>/dev/null; then
                echo "Installing Kind ${KIND_VERSION}..."
                curl -fsSL -o /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${OS}-${ARCH}"
                verify_sha256 /tmp/kind "$(remote_sha256 "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-${OS}-${ARCH}.sha256sum" "kind-${OS}-${ARCH}")" kind
                install_binary /tmp/kind kind
            fi
        fi
    fi
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
        read -rp "Enter a kindest/node version tag (e.g. v1.32.2), blank for kind's default: " manual || manual=""
        [[ -n "$manual" ]] && printf 'kindest/node:%s' "$manual"
        return 0
    fi

    echo "Available kindest/node versions:" >&2
    for i in "${!tags[@]}"; do
        printf "%3d. %s\n" "$((i + 1))" "${tags[$i]}" >&2
    done
    local manual_option=$((${#tags[@]} + 1))
    printf "%3d. %s\n" "$manual_option" "Enter a tag manually" >&2

    while true; do
        if ! read -rp "Select a version [1-${manual_option}]: " selection; then
            echo "No input (stdin closed); using kind's default Kubernetes version." >&2
            return 0
        fi
        if ! [[ "$selection" =~ ^[0-9]+$ ]]; then
            echo "Please enter a number between 1 and ${manual_option}." >&2
            continue
        fi
        if [[ "$selection" -eq "$manual_option" ]]; then
            if ! read -rp "Enter a kindest/node version tag (e.g. v1.32.2): " manual; then
                echo "No input (stdin closed); using kind's default Kubernetes version." >&2
                return 0
            fi
            [[ -n "$manual" ]] && {
                printf 'kindest/node:%s' "$manual"
                return 0
            }
            continue
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
        if ! read -rp "Select a version [1-${manual_option}, blank=${default}]: " selection; then
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
            if ! read -rp "Enter a chart version (e.g. 5.2.0): " manual; then
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
            if ! read -rp "Which runtime should KinD use? [podman/docker] (default=podman): " choice; then
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
    info=$(docker info --format '{{.NCPU}} {{.MemTotal}}' 2>/dev/null) || return 0
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

# True if a KinD cluster with the given name already exists (for the current provider).
function cluster_exists {
    kind get clusters 2>/dev/null | grep -Fxq "$1"
}

function init_cluster {
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

    # Cluster name is asked once, regardless of the version choice.
    CLUSTER_NAME=$(ask "Name of the cluster [default=${DEFAULT_CLUSTER_NAME}]: " "$DEFAULT_CLUSTER_NAME")

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
                kind delete cluster --name "${CLUSTER_NAME}"
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
        kind create cluster --name "${CLUSTER_NAME}" --config "$kind_config" --image "kindest/node:${KINDEST_NODE_VERSION}"
    else
        node_image=$(select_node_image)
        if [[ -n "$node_image" ]]; then
            echo "Creating cluster '${CLUSTER_NAME}' with ${node_image}..."
            kind create cluster --name "${CLUSTER_NAME}" --config "$kind_config" --image "${node_image}"
        else
            echo "No version selected; using KinD's default node image."
            kind create cluster --name "${CLUSTER_NAME}" --config "$kind_config"
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

# Print a stored secret to stdout. Returns non-zero if it is not found.
function secret_get {
    local name=$1 var
    case "$SECRET_BACKEND" in
        keychain) security find-generic-password -s "$name" -w 2>/dev/null ;;
        secret-tool) secret-tool lookup service "$name" 2>/dev/null ;;
        env)
            var=$(secret_env_var "$name")
            [[ -n "${!var:-}" ]] && printf '%s' "${!var}"
            ;;
    esac
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

function install_sumo {
    require_cmd helm

    # Install Sumo Logic Operator

    ## Securely handle ACCESS_ID and ACCESS_KEY

    if ! ACCESS_ID=$(secret_get sumologic_access_id); then
        if [[ -n "$ASSUME_YES" ]]; then
            echo "Error: Access ID not found and running unattended. Set SUMOLOGIC_ACCESS_ID or store it first." >&2
            exit 1
        fi
        echo "Sumo Logic Access ID not found in secret storage"
        read -rsp "Enter Sumo Logic Access ID: " ACCESS_ID
        echo ""
        secret_set sumologic_access_id "$ACCESS_ID"
    fi

    if ! ACCESS_KEY=$(secret_get sumologic_access_key); then
        if [[ -n "$ASSUME_YES" ]]; then
            echo "Error: Access Key not found and running unattended. Set SUMOLOGIC_ACCESS_KEY or store it first." >&2
            exit 1
        fi
        echo "Sumo Logic Access Key not found in secret storage"
        read -rsp "Enter Sumo Logic Access Key: " ACCESS_KEY
        echo ""
        secret_set sumologic_access_key "$ACCESS_KEY"
    fi

    DEFAULT_HELM_VALUES="$SCRIPT_DIR/values.yaml"
    echo "A Helm values file is optional; the chart can install with --set values alone."
    echo "Example values live in the examples folder, e.g. examples/metrics_interval.yaml"
    HELM_VALUES=$(ask "Path to a Helm values file (blank to skip) [default if present=${DEFAULT_HELM_VALUES}]: " "${HELM_VALUES:-}")
    # Blank falls back to the default file only when it actually exists.
    if [[ -z "$HELM_VALUES" && -f "$DEFAULT_HELM_VALUES" ]]; then
        HELM_VALUES="$DEFAULT_HELM_VALUES"
    fi
    # A values file is optional, but if one is named it must exist.
    [[ -n "$HELM_VALUES" ]] && require_values_file "$HELM_VALUES"

    CLUSTER_NAME=$(ask "Name of the cluster [default=${DEFAULT_CLUSTER_NAME}]: " "$DEFAULT_CLUSTER_NAME")

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
    local helm_args=(upgrade --install sumologic sumologic/sumologic
        --version "$chart_version"
        --namespace=sumologic --create-namespace)
    [[ -n "$HELM_VALUES" ]] && helm_args+=(--values "$HELM_VALUES")
    helm_args+=(--values "$secrets_file")
    helm_args+=(--set-string "sumologic.clusterName=${CLUSTER_NAME}")
    helm_args+=("${SUMO_COMMON_SET[@]}")

    # Optionally block until the collector pods are Ready (helm --wait). Default yes;
    # decline for a fire-and-forget install and check progress with -s/--status.
    if confirm "Wait for the collector pods to become ready?" y; then
        helm_args+=(--wait --timeout 10m)
    fi

    # Guard the install so a failure (incl. a --wait timeout) gives an actionable hint
    # rather than the generic ERR-trap message.
    if ! helm "${helm_args[@]}"; then
        echo "Helm install did not complete cleanly (see the error above)." >&2
        echo "Inspect what's deployed:  $0 -s" >&2
        echo "Watch the pods:           kubectl get pods -n sumologic -w" >&2
        exit 1
    fi

    # Success: surface concrete next steps (label/name reflect fullnameOverride=sumo).
    cat <<EOF

Sumo collector installed — chart ${chart_version}, cluster '${CLUSTER_NAME}'.
Next steps:
  Watch pods:           kubectl get pods -n sumologic -w
  Tail collector logs:  kubectl logs -n sumologic -l app.kubernetes.io/name=sumo-otelcol-logs-collector -f
  Health check:         $0 -s
  Confirm data in Sumo: https://help.sumologic.com/docs/send-data/kubernetes/
EOF
}

function output {
    require_cmd helm
    DEFAULT_HELM_VALUES="$SCRIPT_DIR/values.yaml"
    DEFAULT_K8S_YAML="sumologic-rendered.yaml"

    HELM_VALUES=$(ask "Path to a Helm values file (blank to skip) [default if present=${DEFAULT_HELM_VALUES}]: " "${HELM_VALUES:-}")
    if [[ -z "$HELM_VALUES" && -f "$DEFAULT_HELM_VALUES" ]]; then
        HELM_VALUES="$DEFAULT_HELM_VALUES"
    fi
    [[ -n "$HELM_VALUES" ]] && require_values_file "$HELM_VALUES"
    CLUSTER_NAME=$(ask "Name of the cluster [default=${DEFAULT_CLUSTER_NAME}]: " "$DEFAULT_CLUSTER_NAME")
    K8S_YAML=$(ask "Name and Location of the rendered Kubernetes Manifest YAML file. [default=sumologic-rendered.yaml]: " "$DEFAULT_K8S_YAML")

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
    local template_args=(template sumologic sumologic/sumologic
        --version "$chart_version"
        --namespace=sumologic --create-namespace)
    [[ -n "$HELM_VALUES" ]] && template_args+=(--values "$HELM_VALUES")
    template_args+=(--values "$secrets_file")
    template_args+=(--set-string "sumologic.clusterName=${CLUSTER_NAME}")
    template_args+=("${SUMO_COMMON_SET[@]}")

    helm "${template_args[@]}" | tee "${K8S_YAML}"
    echo "Rendered sumologic/sumologic chart version ${chart_version} to ${K8S_YAML}." >&2
    echo "Note: the rendered Secret uses placeholder credentials; deploy with -i/-m to inject real ones." >&2
}

function uninstall {
    require_cmd kind
    # Match KinD to the runtime that backs the cluster so it can find/delete it.
    if ! select_runtime; then exit 1; fi
    set_kind_provider

    echo "Caution: This will delete the cluster"
    confirm_destructive "delete the cluster"
    echo "Deleting Cluster: ${CLUSTER_NAME}"
    kind delete cluster --name "${CLUSTER_NAME}"
    if [[ "$CONTAINER_RUNTIME" == "podman" && "$OS" == "darwin" ]]; then
        echo "Leaving Podman machine intact (use --purge to remove it)."
    fi
}

function purge {
    require_cmd kind
    if ! select_runtime; then exit 1; fi
    set_kind_provider

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
    echo "Deleting Cluster: ${CLUSTER_NAME}"
    kind delete cluster --name "${CLUSTER_NAME}"
    if [[ "$has_machine" == "yes" && -n "$running_machine" ]]; then
        echo "Stopping and Removing the - ${running_machine} - Podman Machine..."
        podman machine stop "${running_machine}"
        podman machine rm "${running_machine}"
    fi

    if secret_delete sumologic_access_id; then
        echo "Removed 'sumologic_access_id' from secret storage."
    else
        echo "Sumo Logic Access ID not found in secret storage; continuing to purge."
    fi

    if secret_delete sumologic_access_key; then
        echo "Removed 'sumologic_access_key' from secret storage."
    else
        echo "Sumo Logic Access Key not found in secret storage; continuing to purge."
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
    echo "== sumo-otel-local status =="

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

## Helper Functions

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
    echo "Creating a new Podman machine..."
    DEFAULT_NAME="sumo"
    DEFAULT_MEMORY="${MIN_MEM_MB}" # default a new machine to the configured minimum
    MEMORY=$(ask "Allocate memory for Podman machine (in MiB) [default=${DEFAULT_MEMORY}]: " "$DEFAULT_MEMORY")
    NAME=$(ask "Name of the Podman machine [default=${DEFAULT_NAME}]: " "$DEFAULT_NAME")

    # Free the single run slot before creating/starting the new machine.
    stop_running_machine || return 1

    echo "Initializing Podman machine '$NAME' with ${MEMORY}MiB RAM..."
    podman machine init --memory "${MEMORY}" "${NAME}"
    podman machine start "${NAME}"
}

function use_existing_podman {
    # Minimum requirements come from MIN_MEM_MB / MIN_CPU (set/overridable above).

    # Get list of all machines with their specs
    machines_json=$(podman machine list --format json)

    # Arrays to hold valid machines
    declare -a valid_names valid_memories valid_cpus valid_statuses

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

    # Check if any valid machine was found
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
        elif ! read -rp "Enter your choice [1-$exit_option]: " selection; then
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
            echo "Invalid selection: please enter a number from 1 and $exit_option."
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
                podman machine start "$chosen_machine"
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

# Report errors without destroying anything. Previously this trap ran the
# interactive uninstall flow, so any failed command (with `set -e`) could delete
# the user's cluster. Now it only reports the failure and exits non-zero; cluster
# teardown is left to the explicit --uninstall / --purge options.
function on_error {
    local exit_code=$?
    local line_no=${1:-unknown}
    echo "" >&2
    echo "Error: command failed (exit ${exit_code}) at line ${line_no}." >&2
    echo "Nothing has been changed or removed. To tear down a cluster, re-run with -u/--uninstall or -p/--purge." >&2
    exit "${exit_code}"
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
    local action="" conflict="" show_help="" bad_flag=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help) show_help="yes" ;;
            -i | --install) set_action install ;;
            -n | --init) set_action init ;;
            -m | --helm) set_action helm ;;
            -o | --output) set_action output ;;
            -s | --status) set_action status ;;
            -p | --purge) set_action purge ;;
            -u | --uninstall) set_action uninstall ;;
            -v | --version) set_action version ;;
            # Modifiers (not actions): order-independent, may appear before or after.
            -y | --yes | --non-interactive) ASSUME_YES="yes" ;;
            -f | --force) FORCE="yes" ;;
            *) if [[ -z "$bad_flag" ]]; then bad_flag="$1"; fi ;;
        esac
        shift
    done

    # -h/--help always wins: print usage and exit cleanly, before any error.
    if [[ -n "$show_help" ]]; then
        help
        exit 0
    fi

    if [[ -n "$bad_flag" ]]; then
        echo "Invalid Option: $bad_flag" >&2
        help
        exit 1
    fi

    if [[ -n "$conflict" ]]; then
        echo "Specify exactly one action (-i/-n/-m/-o/-s/-p/-u/-v)." >&2
        help
        exit 1
    fi

    case "$action" in
        install)
            install_dependencies
            init_cluster
            install_sumo
            ;;
        init)
            install_dependencies
            init_cluster
            ;;
        helm) install_sumo ;;
        output) output ;;
        status) status ;;
        purge) purge ;;
        uninstall) uninstall ;;
        version) version ;;
        *)
            echo "Specify exactly one action (-i/-n/-m/-o/-s/-p/-u/-v), or -h for help." >&2
            help
            exit 1
            ;;
    esac
}

# Run main only when executed directly, not when sourced (e.g. by the test suite).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
