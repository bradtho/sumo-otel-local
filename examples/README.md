# README for Example Helm Values files

## metrics_interval.yaml

This file is used to set the [OTel Metrics Scrape Interval](https://help.sumologic.com/docs/send-data/kubernetes/best-practices/#changing-scrape-interval-for-opentelemetry-metrics-collection)

## no_install.yaml

This file is used to disable the automatic installation of Sumo Logic Observability components and utilise an exsiting Sumo Logic collector.

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
