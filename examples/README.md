# README for Example Helm Values files

## metrics_interval.yaml

This file is used to set the [OTel Metrics Scrape Interval](https://help.sumologic.com/docs/send-data/kubernetes/best-practices/#changing-scrape-interval-for-opentelemetry-metrics-collection)

## no_install.yaml

This file is used to disable the automatic installation of Sumo Logic Observability components and utilise an exsiting Sumo Logic collector.

To avoid PODS failing to run because the secret "sumologic" is not available, Create the secret manually to fix the setup POD failing to run.

```bash
kubectl create secret generic sumologic \
   --from-literal=endpoint-events="my endpoint events" \
   --from-literal=endpoint-events-otlp="my endpoint events otlp" \
   --namespace sumologic
```

Patch this secret with following data the other configuration required by the failing pods:

```bash
kubectl patch secret sumologic --namespace sumologic --type='merge' -p '{
   "data": {
     "endpoint-metrics-apiserver": "'$(echo -n "https://<endpoint obtained from Data Collection page>" | base64)'",
     "endpoint-control_plane_metrics_source": "'$(echo -n "https://<endpoint obtained from Data Collection page>" | base64)'",
     "endpoint-metrics-kube-controller-manager": "'$(echo -n "https://<endpoint obtained from Data Collection page>" | base64)'",
     "endpoint-metrics": "'$(echo -n "https://<endpoint obtained from Data Collection page>" | base64)'",
     "endpoint-metrics-otlp": "'$(echo -n "https://<endpoint obtained from Data Collection page>" | base64)'",
     "endpoint-metrics-kubelet": "'$(echo -n "https://<endpoint obtained from Data Collection page>" | base64)'",
     "endpoint-metrics-node-exporter": "'$(echo -n "https://<endpoint obtained from Data Collection page>" | base64)'",
     "endpoint-metrics-kube-scheduler": "'$(echo -n "https://<endpoint obtained from Data Collection page>" | base64)'",
     "endpoint-metrics-kube-state": "'$(echo -n "https://<endpoint obtained from Data Collection page>" | base64)'"
    } 
}'
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
