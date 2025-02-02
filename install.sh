#!/bin/bash

set -euo pipefail

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

function setup {
    # Initialise and Start Podman
    if command -v podman &> /dev/null; then
        PODMAN_MACHINE_STATUS=$(podman machine list | grep -c "running")
        if [ ${PODMAN_MACHINE_STATUS} -ge 1 ]; then
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
        echo "Podman is not installed."
    fi

    # Create a cluster
    DEFAULT_CLUSTER_NAME="sumo"
    read -p "Name of the cluster [default=${DEFAULT_CLUSTER_NAME}]: " CLUSTER_NAME
    : ${CLUSTER_NAME:=${DEFAULT_CLUSTER_NAME}}
    kind create cluster --name ${CLUSTER_NAME} --config kind-config.yaml

    # Install Sumo Logic Operator

    read -sp "Enter your SumoLogic Access ID: " ACCESS_ID
    read -sp "Enter your SumoLogic Access Key: " ACCESS_KEY

    helm upgrade \
    --install \
    sumologic sumologic/sumologic \
    --namespace=sumologic \
    --create-namespace \
    --set-string sumologic.accessId=${ACCESS_ID} \
    --set-string sumologic.accessKey=${ACCESS_KEY} \
    --set-string sumologic.clusterName=${CLUSTER_NAME} \
    --set-string fullnameOverride=sumo \
    --set sumologic.falco.enabled=false \
    --set sumologic.logs.systemd.enabled=false
}

install_dependencies
setup