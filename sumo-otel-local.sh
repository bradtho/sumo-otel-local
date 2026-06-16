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
    echo "  -p, --purge     Uninstall the Cluster and Podman Machine."
    echo "  -u, --uninstall Uninstall the Cluster only."
    echo "  -v, --version   Display the version of the script."
}


# Detect OS and CPU architecture, normalized to the tokens used by release assets.
OS_RAW=$(uname -s)
case "$OS_RAW" in
    Darwin) OS="darwin" ;;
    Linux)  OS="linux" ;;
    *)
        echo "Unsupported operating system: ${OS_RAW}. Only macOS (Darwin) and Linux are supported."
        exit 1
        ;;
esac

ARCH_RAW=$(uname -m)
case "$ARCH_RAW" in
    x86_64|amd64)  ARCH="amd64" ;;
    arm64|aarch64) ARCH="arm64" ;;
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
if [[ "$OS" == "darwin" ]] && command -v security &> /dev/null; then
    SECRET_BACKEND="keychain"
elif command -v secret-tool &> /dev/null; then
    SECRET_BACKEND="secret-tool"
else
    SECRET_BACKEND="env"
fi

# Check Dependencies
function install_dependencies {

    if command -v brew &> /dev/null; then
        echo "Installing Dependencies with Homebrew..."
        brew install --quiet jq kubectl helm kind podman
    elif ! command -v brew &> /dev/null; then
        read -rp "Homebrew is not installed. Would you like to install it? [y/n]" yn
        if [[ $yn =~ ^[Yy]$ ]]; then
            curl -fsSL -o install_homebrew.sh https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh
            chmod 700 install_homebrew.sh
            ./install_homebrew.sh
            rm install_homebrew.sh
            install_dependencies
        else
            echo "Installing Dependencies Directly..."
            if ! command -v jq &> /dev/null; then
                echo "Installing jq..."
                curl -Lo /usr/local/bin/jq https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-${JQ_OS}-${ARCH}
                chmod +x /usr/local/bin/jq
            fi

            if ! command -v kubectl &> /dev/null; then
                echo "Installing Kubectl..."
                curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/${OS}/${ARCH}/kubectl"
                chmod +x ./kubectl
                sudo mv ./kubectl /usr/local/bin/kubectl
                sudo chown root: /usr/local/bin/kubectl
                kubectl version --client
            fi

            if ! command -v helm &> /dev/null; then
                echo "Installing Helm..."
                curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3
                chmod 700 get_helm.sh
                ./get_helm.sh
            fi

            if ! command -v docker &> /dev/null && ! command -v podman &> /dev/null; then
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

            if ! command -v kind &> /dev/null; then
                echo "Installing Kind..."
                RELEASE=$(curl -L -s https://api.github.com/repos/kubernetes-sigs/kind/releases/latest | jq -r .tag_name)
                curl -Lo ./kind "https://kind.sigs.k8s.io/dl/${RELEASE}/kind-${OS}-${ARCH}"
                chmod +x ./kind
                mv ./kind /usr/local/bin/kind
            fi
        fi
    fi
}

function init_cluster {
    DEFAULT_CLUSTER_NAME="sumo"

    # Initialise and Start Podman
    if command -v podman &> /dev/null; then
        echo "Podman is installed..."
        if ! use_existing_podman; then
            echo "Podman machine setup did not complete; aborting."
            exit 1
        fi
    else
        read -rp "Podman is not installed. Are you using Docker Desktop? [y/n]" yn
        if [[ $yn =~ ^[Yy]$ ]]; then
            echo "Using Docker Desktop..."
        else
            echo "Please install Podman or Docker Desktop to continue."
            exit 1
        fi
    fi

    read -rp "KinD will install the latest Kubernetes version is this OK? [y/n]" yn
    if [[ $yn =~ ^[Yy]$ ]]; then
        # Create a cluster
        read -rp "Name of the cluster [default=${DEFAULT_CLUSTER_NAME}]: " CLUSTER_NAME
        : "${CLUSTER_NAME:=${DEFAULT_CLUSTER_NAME}}"
        kind create cluster --name "${CLUSTER_NAME}" --config kind-config.yaml
    else
        echo "Please select the version of Kubernetes you would like to run."
    fi   
}

# Escape a string for use as a double-quoted YAML scalar.
function yaml_escape {
    local s=$1
    s=${s//\\/\\\\}   # escape backslashes first
    s=${s//\"/\\\"}   # then double quotes
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
        keychain)    security find-generic-password -s "$name" -w 2>/dev/null ;;
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
        keychain)    security add-generic-password -a "$USER" -s "$name" -w "$value" ;;
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
        keychain)    security delete-generic-password -s "$name" > /dev/null 2>&1 ;;
        secret-tool) secret-tool clear service "$name" 2>/dev/null ;;
        env)         return 1 ;;
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
    echo "Additional example values can be found in the examples folder. When prompted, please provide the path to the values.yaml file. e.g. examples/values.yaml"
    read -rp "Name and Location of the Helm Values file. [default=values.yaml]: " HELM_VALUES
    : "${HELM_VALUES:=${DEFAULT_HELM_VALUES}}"

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
    cat > "$secrets_file" <<EOF
sumologic:
  accessId: "$(yaml_escape "$ACCESS_ID")"
  accessKey: "$(yaml_escape "$ACCESS_KEY")"
EOF

    helm upgrade \
    --install \
    sumologic sumologic/sumologic \
    --namespace=sumologic \
    --create-namespace \
    --values "${HELM_VALUES}" \
    --values "${secrets_file}" \
    --set-string sumologic.clusterName="${CLUSTER_NAME}" \
    --set-string fullnameOverride=sumo \
    --set sumologic.falco.enabled=false \
    --set sumologic.logs.systemd.enabled=false
}

function output {
    DEFAULT_HELM_VALUES="values.yaml"
    DEFAULT_K8S_YAML="sumologic-rendered.yaml"

    read -rp "Name and Location of the Helm Values file. [default=values.yaml]: " HELM_VALUES
    : "${HELM_VALUES:=${DEFAULT_HELM_VALUES}}"
    read -rp "Name and Location of the rendered Kubernetes Manifest YAML file. [default=sumologic-rendered.yaml]: " K8S_YAML
    : "${K8S_YAML:=${DEFAULT_K8S_YAML}}"   
 
    helm template \
    --namespace=sumologic \
    --create-namespace \
    -f "${HELM_VALUES}" \
    sumologic sumologic/sumologic | tee "${K8S_YAML}"
}

function uninstall {
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
            echo "Leaving Podman Machine intact"
        fi
    else
        echo "Cancelling and exiting script..."
        exit 0
    fi      
}

function purge {
    running_machine=$(podman machine list --format json | jq -r '.[] | select(.Running == true) | .Name')
    echo "Caution: This will delete the cluster and remove the - ${running_machine} - Podman machine!"
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
            echo "Stopping and Removing the - ${running_machine} - Podman Machine..."
            podman machine stop "${running_machine}"
            podman machine rm "${running_machine}"
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
    DEFAULT_MEMORY=18432
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
    # Minimum requirements
    MIN_MEM_MB=18432  # in MB
    MIN_CPU=4

    # Get list of all machines with their specs
    machines_json=$(podman machine list --format json)

    # Arrays to hold valid machines
    declare -a valid_names valid_memories valid_cpus valid_statuses

    index=0
    echo "Checking Podman machines for minimum requirements (Memory ≥ ${MIN_MEM_MB}MB, CPUs ≥ ${MIN_CPU})..."

    # Loop over machines using `jq` length and index
    machine_count=$(echo "$machines_json" | jq 'length')

    for ((i=0; i<machine_count; i++)); do
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

        create_option=$(( ${#valid_names[@]} + 1 ))
        exit_option=$(( ${#valid_names[@]} + 2 ))

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
        -h|--help)
            help
            exit 0
            ;;
        -i|--install)
            install_dependencies
            init_cluster
            install_sumo
            exit 0
            ;;
        -n|--init)
            install_dependencies
            init_cluster
            exit 0
            ;;
        -m|--helm)
            install_sumo
            exit 0
            ;;
        -o|--output)
            output
            exit 0
            ;;
        -p|--purge)
            purge
            exit 0
            ;;
        -u|--uninstall)
            uninstall
            exit 0
            ;;
        -v|--version)
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