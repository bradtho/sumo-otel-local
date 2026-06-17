#!/bin/bash

set -euo pipefail

# Helper Functions
function help {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -h, --help      Display this help message."
    echo "  -i, --install   Install the dependencies and setup the Sumo Operator."
    echo "  -n, --init      Install dependencies without setting up the Sumo Operator."
    echo "  -m, --helm      Install Sumo Operator onto existing cluster."
    echo "  -o, --output    Output the rendered Kubernetes manifest YAML file."
    echo "  -p, --purge     Uninstall the cluster (and, with Podman on macOS, the Podman machine)."
    echo "  -u, --uninstall Uninstall the Cluster only."
    echo "  -v, --version   Display the version of the script."
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

# Choose a secret-storage backend: macOS Keychain, Linux libsecret (secret-tool),
# or an environment-variable fallback when neither is available.
if [[ "$OS" == "darwin" ]] && command -v security &>/dev/null; then
    SECRET_BACKEND="keychain"
elif command -v secret-tool &>/dev/null; then
    SECRET_BACKEND="secret-tool"
else
    SECRET_BACKEND="env"
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

# Check Dependencies
function install_dependencies {

    if command -v brew &>/dev/null; then
        echo "Installing Dependencies with Homebrew..."
        brew install --quiet jq kubectl helm kind podman
    elif ! command -v brew &>/dev/null; then
        read -rp "Homebrew is not installed. Would you like to install it? [y/n]" yn
        if [[ $yn =~ ^[Yy]$ ]]; then
            curl -fsSL -o install_homebrew.sh https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh
            chmod 700 install_homebrew.sh
            ./install_homebrew.sh
            rm install_homebrew.sh
            install_dependencies
        else
            echo "Installing Dependencies Directly..."
            if ! command -v jq &>/dev/null; then
                echo "Installing jq..."
                curl -Lo /usr/local/bin/jq https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-${JQ_OS}-${ARCH}
                chmod +x /usr/local/bin/jq
            fi

            if ! command -v kubectl &>/dev/null; then
                echo "Installing Kubectl..."
                curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/${OS}/${ARCH}/kubectl"
                chmod +x ./kubectl
                sudo mv ./kubectl /usr/local/bin/kubectl
                sudo chown root: /usr/local/bin/kubectl
                kubectl version --client
            fi

            if ! command -v helm &>/dev/null; then
                echo "Installing Helm..."
                curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3
                chmod 700 get_helm.sh
                ./get_helm.sh
            fi

            if ! command -v docker &>/dev/null && ! command -v podman &>/dev/null; then
                echo "Installing Podman..."
                if [[ "$OS" == "darwin" ]]; then
                    RELEASE=$(curl -L -s https://api.github.com/repos/containers/podman/releases/latest | jq -r .tag_name)
                    curl -Lo "./podman-remote-release-darwin_${ARCH}.zip" "https://github.com/containers/podman/releases/download/${RELEASE}/podman-remote-release-darwin_${ARCH}.zip"
                    unzip "podman-remote-release-darwin_${ARCH}.zip"
                    chmod +x ./podman-"${RELEASE}"/usr/bin/podman
                    sudo mv ./podman-"${RELEASE}"/usr/bin/podman /usr/local/bin/podman
                    chmod +x ./podman-"${RELEASE}"/usr/bin/podman-mac-helper
                    sudo mv ./podman-"${RELEASE}"/usr/bin/podman-mac-helper /usr/local/bin/podman-mac-helper
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
                echo "Installing Kind..."
                RELEASE=$(curl -L -s https://api.github.com/repos/kubernetes-sigs/kind/releases/latest | jq -r .tag_name)
                curl -Lo ./kind "https://kind.sigs.k8s.io/dl/${RELEASE}/kind-${OS}-${ARCH}"
                chmod +x ./kind
                mv ./kind /usr/local/bin/kind
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
        read -rp "Enter a kindest/node version tag (e.g. v1.32.2), blank for kind's default: " manual
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
        read -rp "Select a version [1-${manual_option}]: " selection
        if ! [[ "$selection" =~ ^[0-9]+$ ]]; then
            echo "Please enter a number between 1 and ${manual_option}." >&2
            continue
        fi
        if [[ "$selection" -eq "$manual_option" ]]; then
            read -rp "Enter a kindest/node version tag (e.g. v1.32.2): " manual
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
        echo "Both Podman and Docker are available." >&2
        while true; do
            read -rp "Which runtime should KinD use? [podman/docker] (default=podman): " choice
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

function init_cluster {
    DEFAULT_CLUSTER_NAME="sumo"

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
    read -rp "Name of the cluster [default=${DEFAULT_CLUSTER_NAME}]: " CLUSTER_NAME
    : "${CLUSTER_NAME:=${DEFAULT_CLUSTER_NAME}}"

    read -rp "KinD will install the latest Kubernetes version, is this OK? [y/n]" yn
    if [[ $yn =~ ^[Yy]$ ]]; then
        kind create cluster --name "${CLUSTER_NAME}" --config kind-config.yaml
    else
        node_image=$(select_node_image)
        if [[ -n "$node_image" ]]; then
            echo "Creating cluster '${CLUSTER_NAME}' with ${node_image}..."
            kind create cluster --name "${CLUSTER_NAME}" --config kind-config.yaml --image "${node_image}"
        else
            echo "No version selected; using KinD's default node image."
            kind create cluster --name "${CLUSTER_NAME}" --config kind-config.yaml
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
    local name=$1 value=$2 var
    case "$SECRET_BACKEND" in
        keychain) security add-generic-password -a "$USER" -s "$name" -w "$value" ;;
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

    # Install Sumo Logic Operator

    ## Securely handle ACCESS_ID and ACCESS_KEY

    if ! ACCESS_ID=$(secret_get sumologic_access_id); then
        echo "Sumo Logic Access ID not found in secret storage"
        read -rsp "Enter Sumo Logic Access ID: " ACCESS_ID
        echo ""
        secret_set sumologic_access_id "$ACCESS_ID"
    fi

    if ! ACCESS_KEY=$(secret_get sumologic_access_key); then
        echo "Sumo Logic Access Key not found in secret storage"
        read -rsp "Enter Sumo Logic Access Key: " ACCESS_KEY
        echo ""
        secret_set sumologic_access_key "$ACCESS_KEY"
    fi

    DEFAULT_HELM_VALUES="values.yaml"
    echo "A Helm values file is optional; the chart can install with --set values alone."
    echo "Example values live in the examples folder, e.g. examples/metrics_interval.yaml"
    read -rp "Path to a Helm values file (blank to skip) [default if present=${DEFAULT_HELM_VALUES}]: " HELM_VALUES
    # Blank falls back to the default file only when it actually exists.
    if [[ -z "$HELM_VALUES" && -f "$DEFAULT_HELM_VALUES" ]]; then
        HELM_VALUES="$DEFAULT_HELM_VALUES"
    fi
    # A values file is optional, but if one is named it must exist.
    [[ -n "$HELM_VALUES" ]] && require_values_file "$HELM_VALUES"

    DEFAULT_CLUSTER_NAME="sumo"
    read -rp "Name of the cluster [default=${DEFAULT_CLUSTER_NAME}]: " CLUSTER_NAME
    : "${CLUSTER_NAME:=${DEFAULT_CLUSTER_NAME}}"

    read -rp "Do you want to check for Helm Repo Updates? [y/n]" yn
    if [[ $yn =~ ^[Yy]$ ]]; then
        helm repo add sumologic https://sumologic.github.io/sumologic-kubernetes-collection
        helm repo update sumologic
    else
        echo "Skipping Update."
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
    local helm_args=(upgrade --install sumologic sumologic/sumologic
        --namespace=sumologic --create-namespace)
    [[ -n "$HELM_VALUES" ]] && helm_args+=(--values "$HELM_VALUES")
    helm_args+=(--values "$secrets_file")
    helm_args+=(--set-string "sumologic.clusterName=${CLUSTER_NAME}")
    helm_args+=(--set-string fullnameOverride=sumo)
    helm_args+=(--set sumologic.falco.enabled=false)
    helm_args+=(--set sumologic.logs.systemd.enabled=false)

    helm "${helm_args[@]}"
}

function output {
    DEFAULT_HELM_VALUES="values.yaml"
    DEFAULT_K8S_YAML="sumologic-rendered.yaml"

    read -rp "Path to a Helm values file (blank to skip) [default if present=${DEFAULT_HELM_VALUES}]: " HELM_VALUES
    if [[ -z "$HELM_VALUES" && -f "$DEFAULT_HELM_VALUES" ]]; then
        HELM_VALUES="$DEFAULT_HELM_VALUES"
    fi
    [[ -n "$HELM_VALUES" ]] && require_values_file "$HELM_VALUES"
    read -rp "Name and Location of the rendered Kubernetes Manifest YAML file. [default=sumologic-rendered.yaml]: " K8S_YAML
    : "${K8S_YAML:=${DEFAULT_K8S_YAML}}"

    # Only pass -f when a values file is in use; the chart renders with defaults otherwise.
    local template_args=(template --namespace=sumologic --create-namespace)
    [[ -n "$HELM_VALUES" ]] && template_args+=(-f "$HELM_VALUES")
    template_args+=(sumologic sumologic/sumologic)

    helm "${template_args[@]}" | tee "${K8S_YAML}"
}

function uninstall {
    # Match KinD to the runtime that backs the cluster so it can find/delete it.
    if ! select_runtime; then exit 1; fi
    set_kind_provider

    echo "Caution: This will delete the cluster"
    read -rp "Are you sure you want to continue? [y/n]" yn
    if [[ $yn =~ ^[Yy]$ ]]; then
        DEFAULT_CLUSTER_NAME="sumo"
        read -rp "Type the name of the cluster (Default: sumo) to continue. Type [exit] to cancel: " CLUSTER_NAME
        : "${CLUSTER_NAME:=${DEFAULT_CLUSTER_NAME}}"
        if [[ $CLUSTER_NAME == "exit" ]]; then
            echo "Cancelling and exiting script..."
            exit 0
        else
            echo "Deleting Cluster: ${CLUSTER_NAME}"
            kind delete cluster --name "${CLUSTER_NAME}"
            if [[ "$CONTAINER_RUNTIME" == "podman" && "$OS" == "darwin" ]]; then
                echo "Leaving Podman machine intact (use --purge to remove it)."
            fi
        fi
    else
        echo "Cancelling and exiting script..."
        exit 0
    fi
}

function purge {
    if ! select_runtime; then exit 1; fi
    set_kind_provider

    # Podman machines only exist with Podman on macOS; under Docker (or Linux
    # Podman) there is no machine to remove.
    local has_machine="no" running_machine=""
    if [[ "$CONTAINER_RUNTIME" == "podman" && "$OS" == "darwin" ]]; then
        has_machine="yes"
        running_machine=$(podman machine list --format json | jq -r '.[] | select(.Running == true) | .Name')
        echo "Caution: This will delete the cluster and remove the - ${running_machine} - Podman machine!"
    else
        echo "Caution: This will delete the cluster. (No Podman machine to remove under ${CONTAINER_RUNTIME}.)"
    fi

    read -rp "Are you sure you want to continue? [y/n]" yn
    if [[ $yn =~ ^[Yy]$ ]]; then
        DEFAULT_CLUSTER_NAME="sumo"
        read -rp "Type the name of the cluster (Default: sumo) to continue. Type [exit] to cancel: " CLUSTER_NAME
        : "${CLUSTER_NAME:=${DEFAULT_CLUSTER_NAME}}"
        if [[ $CLUSTER_NAME == "exit" ]]; then
            echo "Cancelling and exiting script..."
            exit 0
        else
            echo "Deleting Cluster: ${CLUSTER_NAME}"
            kind delete cluster --name "${CLUSTER_NAME}"
            if [[ "$has_machine" == "yes" && -n "$running_machine" ]]; then
                echo "Stopping and Removing the - ${running_machine} - Podman Machine..."
                podman machine stop "${running_machine}"
                podman machine rm "${running_machine}"
            fi
        fi
    else
        echo "Cancelling and exiting script..."
        exit 0
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
    RELEASE=$(curl -L -s https://api.github.com/repos/bradtho/sumo-otel-local/releases/latest | jq -r .tag_name)
    echo "sumo-otel-local ${RELEASE}"
}

## Helper Functions
function new_podman {
    echo "Creating a new Podman machine..."
    DEFAULT_NAME="sumo"
    DEFAULT_MEMORY="${MIN_MEM_MB}" # default a new machine to the configured minimum
    read -rp "Allocate memory for Podman machine (in MiB) [default=${DEFAULT_MEMORY}]: " MEMORY
    read -rp "Name of the Podman machine [default=${DEFAULT_NAME}]: " NAME
    : "${MEMORY:=${DEFAULT_MEMORY}}"
    : "${NAME:=${DEFAULT_NAME}}"

    echo "Initializing Podman machine '$NAME' with ${MEMORY}MiB RAM..."
    podman machine init --memory "${MEMORY}" "${NAME}"

    running_machine=$(podman machine list --format json | jq -r '.[] | select(.Running == true) | .Name')
    if [[ -n "$running_machine" ]]; then
        echo "Podman machine '$running_machine' is currently running."
        echo "Only one Podman machine can run at a time"
        read -rp "Would you like to stop it before starting the new one? [y/N]: " stop_choice
        if [[ "$stop_choice" =~ ^[Yy]$ ]]; then
            echo "Stopping '$running_machine'..."
            podman machine stop "$running_machine"
        else
            echo "Cannot start new machine while another is running."
            return 1
        fi
    fi

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
        mem_bytes=$(echo "$machines_json" | jq -r ".[$i].Memory")
        cpu=$(echo "$machines_json" | jq -r ".[$i].CPUs")
        status=$(echo "$machines_json" | jq -r ".[$i].Running")

        #Convert memory from bytes to MB
        mem_mb=$(awk "BEGIN { printf \"%d\", $mem_bytes / 1024 / 1024 }")

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
        read -rp "Would you like to create a new Podman machine with the correct specs? [y/N]: " create_choice

        if [[ "$create_choice" =~ ^[Yy]$ ]]; then
            # Check if any Podman machine is currently running
            running_machine=$(echo "$machines_json" | jq -r '.[] | select(.Running == true) | .Name')

            if [[ -n "$running_machine" ]]; then
                echo "⚠️  Podman machine '$running_machine' is currently running."
                read -rp "Would you like to stop it before creating a new one? [y/N]: " stop_choice

                if [[ "$stop_choice" =~ ^[Yy]$ ]]; then
                    echo "Stopping '$running_machine'..."
                    podman machine stop "$running_machine"
                else
                    echo "Cannot proceed while another machine is running."
                    return 1
                fi
            fi

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

        read -rp "Enter your choice [1-$exit_option]: " selection

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
            read -rp "Would you like to start it now? [y/N]: " start_choice
            if [[ "$start_choice" =~ ^[Yy]$ ]]; then
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
trap 'on_error ${LINENO}' ERR

# Parse Arguments
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -h | --help)
            help
            exit 0
            ;;
        -i | --install)
            install_dependencies
            init_cluster
            install_sumo
            exit 0
            ;;
        -n | --init)
            install_dependencies
            init_cluster
            exit 0
            ;;
        -m | --helm)
            install_sumo
            exit 0
            ;;
        -o | --output)
            output
            exit 0
            ;;
        -p | --purge)
            purge
            exit 0
            ;;
        -u | --uninstall)
            uninstall
            exit 0
            ;;
        -v | --version)
            version
            exit 0
            ;;
        *)
            echo "Invalid Option: $1"
            help
            exit 1
            ;;
    esac
    # Each case branch exits, so this is only reached if that ever changes.
    # shellcheck disable=SC2317
    shift
done
