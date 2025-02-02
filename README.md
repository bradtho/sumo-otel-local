# sumo-otel-local

Sumo OTEL Collector Local Bootstrapper for MacOS

## About

A quick method for testing the Sumo OTEL Collector using a local KinD Cluster. The cluster configuration creates a `3` node cluster which is sufficient for the
Sumo OTEL Collector to install and for the user to validate configuration settings.

## Basic Usage

Clone this repo and run the script

```bash
git clone git@github.com:bradtho/sumo-otel-local.git
cd sumo-otel-local
chmod +x install.sh
./install.sh
```

Follow the in-script prompts.

## Caveat

To run on the Docker/Podman Virtual Machine the `--set sumologic.logs.systemd.enabled=false` had to be set as these systems don't write to the JournalD and will cause the installation to fail.

## Editing and Advanced

Instructions on how to amend the `kind-config.yaml` file are available on the [KinD website](https://kind.sigs.k8s.io/docs/user/configuration/#getting-started)

You may wish to create a Helm Configuration `values.yaml` file or to amend the `--set` and/or `--set-string` entries in the `install.sh` script.

## Contributing

This was always intended to be a basic bootstrapping script. However feel free to raise a PR or an issue and I'll get valid ideas incorporated.
