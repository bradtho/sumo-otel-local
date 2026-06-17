#!/bin/bash

# podman pull kindest/node:v1.32.2@sha256:f226345927d7e348497136874b6d207e0b32cc52154ad8323129352923a3142f

# podman save -o kind-node-v1.32.2.tar kindest/node:v1.32.2@sha256:f226345927d7e348497136874b6d207e0b32cc52154ad8323129352923a3142f

# podman load -i kind-node-v1.32.2.tar

# podman image tag kindest/node:v1.32.2@sha256:f226345927d7e348497136874b6d207e0b32cc52154ad8323129352923a3142f kindest/node:v1.32.2
# podman image ls

# kind create cluster --name ${CLUSTER_NAME} --image kindest/node:v1.32.2

#!/bin/bash

echo "Fetching available kindest/node tags from Docker Hub..."

TAGS=()
URL="https://hub.docker.com/v2/repositories/kindest/node/tags?page_size=100"

# Fetch all tags (handling pagination)
while [[ -n "$URL" && "$URL" != "null" ]]; do
    response=$(curl -s "$URL")
    next_url=$(echo "$response" | jq -r '.next')

    # Extract tag names manually into the array
    tag_list=$(echo "$response" | jq -r '.results[].name')
    while IFS= read -r tag; do
        TAGS+=("$tag")
    done <<<"$tag_list"

    URL="$next_url"
done

# Check if we got any tags
if [[ ${#TAGS[@]} -eq 0 ]]; then
    echo "❌ No tags found for kindest/node."
    exit 1
fi

# Display numbered list
echo "Available kindest/node tags:"
i=1
for tag in "${TAGS[@]}"; do
    printf "%3d. %s\n" "$i" "$tag"
    i=$((i + 1))
done

# Prompt user for selection
read -rp "Enter the number of the tag to use: " selection

# Validate input
if ! [[ "$selection" =~ ^[0-9]+$ ]] || ((selection < 1 || selection > ${#TAGS[@]})); then
    echo "❌ Invalid selection."
    exit 1
fi

# Use the selected tag
selected_tag="${TAGS[$((selection - 1))]}"
echo "✅ You selected: kindest/node:${selected_tag}"

# Optional: docker pull kindest/node:"$selected_tag"
