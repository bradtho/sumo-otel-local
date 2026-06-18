# README for Example Helm Values files

## Table of Contents

1. [Change the Metrics Scrape Interval](#metrics_intervalyaml)
2. [Add Persistent Volume Claim Metrics](#metrics_pvcyaml)
3. [Skip Installation](#no_installyaml)
4. [Authenticated Metrics Endpoints](#metrics_authyaml)
5. [Delete Finalisers](#finalisers)

## metrics_interval.yaml

This file is used to set the [OTel Metrics Scrape Interval](https://help.sumologic.com/docs/send-data/kubernetes/best-practices/#changing-scrape-interval-for-opentelemetry-metrics-collection)

## metrics_pvc.yaml

This file is used to enable the `kubelet_volume_stats_capacity_bytes` and `kubelet_volume_stats_used_bytes` Metrics which allows grants the ability to view Persistent Volume Claim information.

## no_install.yaml

This file is used to disable the automatic installation of Sumo Logic Observability components and utilise an existing Sumo Logic collector.

To avoid PODS failing to run because the secret "sumologic" is not available, Create the secret manually to fix the setup POD failing to run.

```bash
kubectl create secret generic sumologic --namespace sumologic \
  --from-literal=endpoint-metrics-apiserver="https://<endpoint obtained from Data Collection page>" \
  --from-literal=endpoint-control_plane_metrics_source="https://<endpoint obtained from Data Collection page>" \
  --from-literal=endpoint-metrics-kube-controller-manager="https://<endpoint obtained from Data Collection page>" \
  --from-literal=endpoint-metrics="https://<endpoint obtained from Data Collection page>" \
  --from-literal=endpoint-metrics-otlp="https://<endpoint obtained from Data Collection page>" \
  --from-literal=endpoint-metrics-kubelet="https://<endpoint obtained from Data Collection page>" \
  --from-literal=endpoint-metrics-node-exporter="https://<endpoint obtained from Data Collection page>" \
  --from-literal=endpoint-metrics-kube-scheduler="https://<endpoint obtained from Data Collection page>" \
  --from-literal=endpoint-metrics-kube-state="https://<endpoint obtained from Data Collection page>" \
  --from-literal=endpoint-traces="https://<endpoint obtained from Data Collection page>" \
  --from-literal=endpoint-traces-otlp="https://<endpoint obtained from Data Collection page>" \
  --from-literal=endpoint-events-otlp="https://<endpoint obtained from Data Collection page>" \
  --from-literal=endpoint-events="https://<endpoint obtained from Data Collection page>" \
  --from-literal=endpoint-logs="https://<endpoint obtained from Data Collection page>" \
  --from-literal=endpoint-logs-otlp="https://<endpoint obtained from Data Collection page>" 
```

PODS should now be running and ingesting data to a pre-existed collector within Sumo.

This assumes "Hosted collectors" and Sources were previously created in Sumo Logic either Manually, via API or Terraform.

## metrics_auth.yaml

To make use of this file you will first need to deploy the kubernetes manifest found in [../manifests/metrics_auth](../manifests/metrics_auth.yaml)

```bash
kubectl apply -f ../manifests/metrics_auth.yaml
```

This will install the following resources:

- Deployment of a Python App exposing two unauthenticated endpoints.
- Deployment of a Python App exposing an authenticated endpoint.
- Namespace for the Authenticated App.
- Secret for the Authenticated App.
- Service exposing the unauthenticated enpoints.
- Service exposing the authenticated enpoint.
- A ServiceMonitor for Prometheus to scrape the authenticated endpoint.

Code for the Python Apps can be found at [github.com/bradtho/auth-metrics](https://github.com/bradtho/auth-metrics) and
[github.com/bradtho/no-auth-metrics](https://github.com/bradtho/no-auth-metrics)

Once these Kuberenetes resources have been installed you can then run the Helm Deployment which will install a ServiceMonitor via
`sumologic.metrics.additionalServiceMonitors`. The ServiceMonitor CRD and the operator that reconciles it are provided by the chart's
bundled `kube-prometheus-stack` dependency, so no extra toggles are required.

> **Note:** chart v5 collects metrics through the bundled OpenTelemetry Collector and **rejects** the old
> `kube-prometheus-stack.prometheusOperator.enabled` / `kube-prometheus-stack.prometheus.enabled` values, so they have been removed
> from `metrics_auth.yaml`.

## Notes

When you deploy the Helm Chart as per normal. You can see how it creates all sources and their structure in the console.

Endpoints can be taken from the console as needed. Alternatively if an existing Kubernetes cluster is running you can execute the following:

To get the list of endpoints

```bash
kubectl get --namespace sumologic secrets/sumologic -o json
```

To extract the values of each endpoint e.g. for "endpoint-logs"

```bash
kubectl get --namespace sumologic secrets/sumologic --template='{{ index .data "endpoint-logs" }}' | base64 -d
```

## Finalisers

In the event that a resource is stuck because of a finaliser

```bash
kubectl patch crd/opentelemetrycollectors.opentelemetry.io -p '{"metadata": {"finalizers":[] }}' --type=merge
```

```bash
kubectl patch -n sumologic opentelemetrycollector.opentelemetry.io/sumologic-sumologic-metrics -p '{"metadata":{"finalizers":null}}' --type=merge
```
