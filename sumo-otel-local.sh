#!/bin/bash

set -euo pipefail

# Helper Functions
function help {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -h, --help      Display this help message."
    echo "  -i, --install   Install the dependencies and setup the environment."
    echo "  -o, --output    Output the rendered Kubernetes manifest YAML file."
    echo "  -u, --uninstall Uninstall the dependencies and cleanup the environment."
    echo "  -v, --version   Display the version of the script."
}


# Check Architecture
ARCH=$(uname -m)

# Check Dependencies
function install_dependencies {

    if command -v brew &> /dev/null; then
        echo "Installing Dependencies with Homebrew..."
        brew install jq kubectl helm kind podman
    elif ! command -v brew &> /dev/null; then
        read -p "Homebrew is not installed. Would you like to install it? [y/n]" yn
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
                curl -Lo /usr/local/bin/jq https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-macos-${ARCH} 
                chmod +x /usr/local/bin/jq
            fi

            if ! command -v kubectl &> /dev/null; then
                echo "Installing Kubectl..."
                curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/darwin/${ARCH}/kubectl"
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
                RELEASE=$(curl -L -s https://api.github.com/repos/containers/podman/releases/latest | jq -r .tag_name)
                curl -Lo ./podman-remote-release-darwin_${ARCH}.zip https://github.com/containers/podman/releases/download/${RELEASE}/podman-remote-release-darwin_${ARCH}.zip
                unzip podman-remote-release-darwin_${ARCH}.zip
                chmod +x ./podman-${RELEASE}/usr/bin/podman
                sudo mv ./podman-${RELEASE}/usr/bin/podman /usr/local/bin/podman
                chmod +x ./podman-${RELEASE}/usr/bin/podman-mac-helper
                sudo mv ./podman-${RELEASE}/usr/bin/podman-mac-helper /usr/local/bin/podman-mac-helper
            fi    

            if ! command -v kind &> /dev/null; then
                echo "Installing Kind..."
                RELEASE=$(curl -L -s https://api.github.com/repos/kubernetes-sigs/kind/releases/latest | jq -r .tag_name)
                curl -Lo ./kind https://kind.sigs.k8s.io/dl/${RELEASE}/kind-linux-amd64
                chmod +x ./kind
                mv ./kind /usr/local/bin/kind
            fi
        fi
    fi
}

function install {
    # Initialise and Start Podman
    if command -v podman &> /dev/null; then
        echo "Podman is installed..."
        if podman machine list | grep -q "running" ; then
            read -p "Podman Machine already running. Would you like to use it? [y/n]" yn
            if [[ $yn =~ ^[Yy]$ ]]; then
                echo "Using existing Podman machine..."
            else
                echo "Creating a new Podman machine..."   
                DEFAULT_NAME="sumo"
                DEFAULT_MEMORY=18432
                read -p "Allocate memory for Podman machine (in MiB) [default=${DEFAULT_MEMORY}]: " MEMORY
                read -p "Name of the Podman machine [default=${DEFAULT_NAME}]: " NAME
                : ${MEMORY:=${DEFAULT_MEMORY}}
                : ${NAME:=${DEFAULT_NAME}}
                podman machine init --memory ${MEMORY} ${NAME}
                podman machine start ${NAME}
            fi
        else
            echo "Initialising a default Podman machine..."
            DEFAULT_MEMORY=18432
            read -p "Allocate memory for Podman machine (in MiB) [default=${DEFAULT_MEMORY}]: " MEMORY
            : ${MEMORY:=${DEFAULT_MEMORY}}
            podman machine init --memory ${MEMORY}
            podman machine start
        fi
    else
        read -p "Podman is not installed. Are you using Docker Desktop? [y/n]" yn
        if [[ $yn =~ ^[Yy]$ ]]; then
            echo "Using Docker Desktop..."
        else
            echo "Please install Podman or Docker Desktop to continue."
            exit 1
        fi
    fi

    # Create a cluster
    DEFAULT_CLUSTER_NAME="sumo"
    read -p "Name of the cluster [default=${DEFAULT_CLUSTER_NAME}]: " CLUSTER_NAME
    : ${CLUSTER_NAME:=${DEFAULT_CLUSTER_NAME}}
    kind create cluster --name ${CLUSTER_NAME} --config kind-config.yaml

    # Install Sumo Logic Operator

    ACCESS_ID=""
    ACCESS_ID_VAR="Enter your SumoLogic Access ID: "            # to take password character wise
    while IFS= read -p "$ACCESS_ID_VAR" -r -s -n 1 letter
    do
        if [[ $letter == $'\0' ]]                               #  if enter is pressed, exit the loop
        then
            break
        fi
        
        ACCESS_ID+="$letter"                                    # store the letter in ACCESS_ID, use pass+="$letter" for more concise and readable.
        ACCESS_ID_VAR="*"                                       # in place of password the asterisk (*) will be printed
    done
    echo ""

    ACCESS_KEY=""
    ACCESS_KEY_VAR="Enter your SumoLogic Access Key: "           # to take password character wise
    while IFS= read -p "$ACCESS_KEY_VAR" -r -s -n 1 letter
    do
        if [[ $letter == $'\0' ]]                               #  if enter is pressed, exit the loop
        then
            break
        fi
        
        ACCESS_KEY+="$letter"                                   # store the letter in ACCESS_KEY, use VAR+="$letter" for more concise and readable.
        ACCESS_KEY_VAR="*"                                      # in place of password the asterisk (*) will be printed
    done
    echo ""

    DEFAULT_HELM_VALUES="values.yaml"
    echo "Additional example values can in the examples folder. When prompted, please provide the path to the values.yaml file. e.g. examples/values.yaml"
    read -p "Name and Location of the Helm Values file. [default=values.yaml]: " HELM_VALUES
    : ${HELM_VALUES:=${DEFAULT_HELM_VALUES}}

    helm upgrade \
    --install \
    sumologic sumologic/sumologic \
    --namespace=sumologic \
    --create-namespace \
    --values ${HELM_VALUES} \
    --set-string sumologic.accessId=${ACCESS_ID} \
    --set-string sumologic.accessKey=${ACCESS_KEY} \
    --set-string sumologic.clusterName=${CLUSTER_NAME} \
    --set-string fullnameOverride=sumo \
    --set sumologic.falco.enabled=false \
    --set sumologic.logs.systemd.enabled=false
}

function output {
    DEFAULT_HELM_VALUES="values.yaml"
    DEFAULT_K8S_YAML="sumologic-rendered.yaml"

    read -p "Name and Location of the Helm Values file. [default=values.yaml]: " HELM_VALUES
    : ${HELM_VALUES:=${DEFAULT_HELM_VALUES}}
    read -p "Name and Location of the rendered Kuberenetes Manifest YAML file. [default=sumologic-rendered.yaml]: " K8S_YAML
    : ${K8S_YAML:=${DEFAULT_K8S_YAML}}   
 
    helm template \
    --namespace=sumologic \
    --create-namespace \
    -f ${HELM_VALUES} \
    sumologic sumologic/sumologic | tee ${K8S_YAML}
}

function uninstall {
    echo "Caution: This will delete the cluster and remove the Podman machine!"
    read -p "Are you sure you want to continue? [y/n]" yn
    if [[ $yn =~ ^[Yy]$ ]]; then
        DEFAULT_CLUSTER_NAME="sumo"
        echo "Listing Kind Clusters on this machine" 
        echo $(kind get clusters)
        read -p "Type the name of the cluster to continue. Type [exit] to cancel: " CLUSTER_NAME
        : ${CLUSTER_NAME:=${DEFAULT_CLUSTER_NAME}}
        if [[ $CLUSTER_NAME == "exit" ]]; then
            echo "Exiting..."
            exit 0
        else
            echo "Deleting Cluster: ${CLUSTER_NAME}"
            kind delete cluster --name ${CLUSTER_NAME}
            echo "Stopping and Removing Podman Machine..."
            podman machine stop
            podman machine rm
        fi
    else
        echo "Exiting..."
        exit 0
    fi
}

function version {
    RELEASE=$(curl -L -s https://api.github.com/repos/bradtho/sumo-otel-local/releases/latest | jq -r .tag_name)
    echo "sumo-otel-local ${RELEASE}"
}

function cleanup {
    echo "Installation Failed: Cleaning up..."
    uninstall
}
trap cleanup EXIT

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
            install
            exit 0
            ;;
        -o|--output)
            output
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
    shift
done