# Table of Contents
<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->

- [Datadog clone](#datadog-clone)
  - [Purpose](#purpose)
  - [Disclaimer](#disclaimer)
  - [Starting from scratch (non-partners)](#starting-from-scratch-non-partners)
    - [Prerequesites](#prerequesites)
    - [Install the microservices](#install-the-microservices)
    - [Observability Pipeline Steps](#observability-pipeline-steps)
    - [Datadog Agent](#datadog-agent)
    - [Final](#final)
  - [OP Demo Environment (for partners)](#op-demo-environment-for-partners)
    - [Prerequesites & Assumptions](#prerequesites--assumptions)
    - [Partner Steps](#partner-steps)
  - [Supplemental testing](#supplemental-testing)
    - [Send logs over network (TCP/HTTP)](#send-logs-over-network-tcphttp)
- [Original README from GCP](#original-readme-from-gcp)
  - [Architecture](#architecture)
  - [Screenshots](#screenshots)
  - [Quickstart (GKE)](#quickstart-gke)
  - [Additional deployment options](#additional-deployment-options)
  - [Documentation](#documentation)
  - [Demos featuring Online Boutique](#demos-featuring-online-boutique)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

# Datadog clone

This is a non-fork clone of the OSS project <https://github.com/GoogleCloudPlatform/microservices-demo> with modifications to deploy the Datadog Agent and Observability Pipelines.

## Purpose

- May 2024: To help provide an OP installation into a DD Partner's demo environment (they use this project)
- June 2024: To help provide an OP "sandbox" for DD Sales Engineering

## Disclaimer

These projects are not a part of Datadog's subscription services and are provided for example purposes only. They are NOT guaranteed to be bug free and are not production quality. If you choose to use to adapt them for use in a production environment, you do so at your own risk.

## Starting from scratch (non-partners)

This project can be used as a learning tool, "sandbox", or demo environment (for internal Datadog employees, this would be supplemental to US1 Org `11287` and data supplied by [Demo Engineering](https://datadoghq.atlassian.net/wiki/spaces/DH/pages/2381840410/Ownership#Who-owns-Demo-Data-feeding-the-Demo-Environment)).

_It ONLY comes with infrastructure, containers, and logs out of the box. Any other telemetry will be on you to configure._

### Prerequesites

- A k8s cluster
- `helm` and `kubectl` CLI utils installed

### Install the microservices

Follow the original guide from GCP: [Quickstart (GKE)](#quickstart-gke) or [local machine (minikube / kind)](./docs/development-guide.md#option-2---local-cluster)

### Observability Pipeline Steps

- Create a new API Key with [Remote Configuration (RC)](https://docs.datadoghq.com/agent/remote_config/) enabled or update an existing one to use RC
  - Fine if you want to use the same one as/for the Datadog Agent
- Add the API Key to your k8s environment secrets
  - `kubectl create secret generic dd-api-key --from-literal api-key="<API-KEY>"`
- Create a new pipeline via <https://khax.datadoghq.com/observability-pipelines>
  - For the purposes of illustration the Author decided to simply do `DD Agent -> OP -> DD` using the "Log Volume Control" template
  - Add any Processors you want, delete any you don't need
- Follow the in-app instructions for install for k8s OR follow those inline below to deploy:
  - Update the helm values with your Pipeline ID in the file: `./k8s-dd/observability-pipelines/values.yaml`
    - Modify `DD_OP_PIPELINE_ID`
  - `helm repo add datadog https://helm.datadoghq.com`
  - `helm repo update`
  - `helm upgrade --install opw datadog/observability-pipelines-worker -f k8s-dd/observability-pipelines/values.yaml`
  - You will see two "errors": `ERROR: You did not set a datadog.apiKey` and `ERROR: You did not set a datadog.pipelineId` - we set these via environment variables in the helm manifest, so they are invalid and everything should work fine.
- Proceed to the "Deploy" step in-app, then "view pipeline" once the pipeline has been deployed
- You will **not** see any events passing through OP yet, you'll need to proceed to the

### Datadog Agent

Installed via helm:

- `helm repo add datadog https://helm.datadoghq.com`
- `helm repo update`
- You should already have an API key secret from the OP step and not need to do this, if you missed it, do so now (and you may need to restart your OP containers as well)!
  - Alternatively you may want to use a different secret from OP, if so you'll need to swap `dd-api-key` with some other value, and update `./k8s-dd/datadog-agent/values.yaml` key: `apiKeyExistingSecret` with the new name.
  - `kubectl create secret generic dd-api-key --from-literal api-key="<API-KEY>"`
- `kubectl create secret generic dd-app-key --from-literal app-key="<APP-KEY>"`
- `helm upgrade --install datadog-agent datadog/datadog -f k8s-dd/datadog-agent/values.yaml`

This only enables infrastructure and log collection, if you want other telemetry, you'll need to do update various configs for whichever telemetry you are  after.

### Final

You should now see something like the following in-app for your pipeline:

![Screenshot of OP overview](./docs/img/op-pipelines.png)

![Screenshot of OP config](./docs/img/simple-op-pipe.png)

![Screenshot of OP workers](./docs/img/op-workers.png)

## OP Demo Environment (for partners)

### Prerequesites & Assumptions

- You have a k8s cluster
- You already have this project running in a kubernetes environment
  - If not, please follow the original [Quickstart (GKE)](#quickstart-gke) or [Additional deployment options](#additional-deployment-options)
- You have already deployed the Datadog Agent to this environment in some way
  - The Author(s) have implemented the agent using helm, see [Datadog Agent](#datadog-agent) for details

### Partner Steps

- Follow [Observability Pipeline Steps](#observability-pipeline-steps)
- Update your Datadog Agent configurations to include:

  ```
  env:
    - name: DD_OBSERVABILITY_PIPELINES_WORKER_LOGS_ENABLED
      value: true
    - name: DD_OBSERVABILITY_PIPELINES_WORKER_LOGS_URL
      value: "http://opw-observability-pipelines-worker:8282"
  ```

- Restart your agents
- You should now see something akin to the screenshots seen here: [Final](#final).

## Supplemental testing

### Send logs over network (TCP/HTTP)

- `k apply -f ./k8s-dd/datadog-agent/agent-service.yaml`

# Original README from GCP

**Online Boutique** is a cloud-first microservices demo application.  The application is a
web-based e-commerce app where users can browse items, add them to the cart, and purchase them.

Google uses this application to demonstrate how developers can modernize enterprise applications using Google Cloud products, including: [Google Kubernetes Engine (GKE)](https://cloud.google.com/kubernetes-engine), [Anthos Service Mesh (ASM)](https://cloud.google.com/service-mesh), [gRPC](https://grpc.io/), [Cloud Operations](https://cloud.google.com/products/operations), [Spanner](https://cloud.google.com/spanner), [Memorystore](https://cloud.google.com/memorystore), [AlloyDB](https://cloud.google.com/alloydb), and [Gemini](https://ai.google.dev/). This application works on any Kubernetes cluster.

If you’re using this demo, please **★Star** this repository to show your interest!

**Note to Googlers:** Please fill out the form at [go/microservices-demo](http://go/microservices-demo).

## Architecture

**Online Boutique** is composed of 11 microservices written in different
languages that talk to each other over gRPC.

[![Architecture of
microservices](/docs/img/architecture-diagram.png)](/docs/img/architecture-diagram.png)

Find **Protocol Buffers Descriptions** at the [`./protos` directory](/protos).

| Service                                              | Language      | Description                                                                                                                       |
| ---------------------------------------------------- | ------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| [frontend](/src/frontend)                           | Go            | Exposes an HTTP server to serve the website. Does not require signup/login and generates session IDs for all users automatically. |
| [cartservice](/src/cartservice)                     | C#            | Stores the items in the user's shopping cart in Redis and retrieves it.                                                           |
| [productcatalogservice](/src/productcatalogservice) | Go            | Provides the list of products from a JSON file and ability to search products and get individual products.                        |
| [currencyservice](/src/currencyservice)             | Node.js       | Converts one money amount to another currency. Uses real values fetched from European Central Bank. It's the highest QPS service. |
| [paymentservice](/src/paymentservice)               | Node.js       | Charges the given credit card info (mock) with the given amount and returns a transaction ID.                                     |
| [shippingservice](/src/shippingservice)             | Go            | Gives shipping cost estimates based on the shopping cart. Ships items to the given address (mock)                                 |
| [emailservice](/src/emailservice)                   | Python        | Sends users an order confirmation email (mock).                                                                                   |
| [checkoutservice](/src/checkoutservice)             | Go            | Retrieves user cart, prepares order and orchestrates the payment, shipping and the email notification.                            |
| [recommendationservice](/src/recommendationservice) | Python        | Recommends other products based on what's given in the cart.                                                                      |
| [adservice](/src/adservice)                         | Java          | Provides text ads based on given context words.                                                                                   |
| [loadgenerator](/src/loadgenerator)                 | Python/Locust | Continuously sends requests imitating realistic user shopping flows to the frontend.                                              |

## Screenshots

| Home Page                                                                                                         | Checkout Screen                                                                                                    |
| ----------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| [![Screenshot of store homepage](./docs/img/online-boutique-frontend-1.png)](./docs/img/online-boutique-frontend-1.png) | [![Screenshot of checkout screen](./docs/img/online-boutique-frontend-2.png)](/docs/img/online-boutique-frontend-2.png) |

## Quickstart (GKE)

1. Ensure you have the following requirements:
   - [Google Cloud project](https://cloud.google.com/resource-manager/docs/creating-managing-projects#creating_a_project).
   - Shell environment with `gcloud`, `git`, and `kubectl`.

2. Clone the latest major version.

   ```sh
   git clone --depth 1 --branch v0 https://github.com/GoogleCloudPlatform/microservices-demo.git
   cd microservices-demo/
   ```

   The `--depth 1` argument skips downloading git history.

3. Set the Google Cloud project and region and ensure the Google Kubernetes Engine API is enabled.

   ```sh
   export PROJECT_ID=<PROJECT_ID>
   export REGION=us-central1
   gcloud services enable container.googleapis.com \
     --project=${PROJECT_ID}
   ```

   Substitute `<PROJECT_ID>` with the ID of your Google Cloud project.

4. Create a GKE cluster and get the credentials for it.

   ```sh
   gcloud container clusters create-auto online-boutique \
     --project=${PROJECT_ID} --region=${REGION}
   ```

   Creating the cluster may take a few minutes.

5. Deploy Online Boutique to the cluster.

   ```sh
   kubectl apply -f ./release/kubernetes-manifests.yaml
   ```

6. Wait for the pods to be ready.

   ```sh
   kubectl get pods
   ```

   After a few minutes, you should see the Pods in a `Running` state:

   ```
   NAME                                     READY   STATUS    RESTARTS   AGE
   adservice-76bdd69666-ckc5j               1/1     Running   0          2m58s
   cartservice-66d497c6b7-dp5jr             1/1     Running   0          2m59s
   checkoutservice-666c784bd6-4jd22         1/1     Running   0          3m1s
   currencyservice-5d5d496984-4jmd7         1/1     Running   0          2m59s
   emailservice-667457d9d6-75jcq            1/1     Running   0          3m2s
   frontend-6b8d69b9fb-wjqdg                1/1     Running   0          3m1s
   loadgenerator-665b5cd444-gwqdq           1/1     Running   0          3m
   paymentservice-68596d6dd6-bf6bv          1/1     Running   0          3m
   productcatalogservice-557d474574-888kr   1/1     Running   0          3m
   recommendationservice-69c56b74d4-7z8r5   1/1     Running   0          3m1s
   redis-cart-5f59546cdd-5jnqf              1/1     Running   0          2m58s
   shippingservice-6ccc89f8fd-v686r         1/1     Running   0          2m58s
   ```

7. Access the web frontend in a browser using the frontend's external IP.

   ```sh
   kubectl get service frontend-external | awk '{print $4}'
   ```

   Visit `http://EXTERNAL_IP` in a web browser to access your instance of Online Boutique.

8. Congrats! You've deployed the default Online Boutique. To deploy a different variation of Online Boutique (e.g., with Google Cloud Operations tracing, Istio, etc.), see [Deploy Online Boutique variations with Kustomize](#deploy-online-boutique-variations-with-kustomize).

9. Once you are done with it, delete the GKE cluster.

   ```sh
   gcloud container clusters delete online-boutique \
     --project=${PROJECT_ID} --region=${REGION}
   ```

   Deleting the cluster may take a few minutes.

## Additional deployment options

- **Terraform**: [See these instructions](/terraform) to learn how to deploy Online Boutique using [Terraform](https://www.terraform.io/intro).
- **Istio / Anthos Service Mesh**: [See these instructions](/kustomize/components/service-mesh-istio/README.md) to deploy Online Boutique alongside an Istio-backed service mesh.
- **Non-GKE clusters (Minikube, Kind, etc)**: See the [Development guide](/docs/development-guide.md) to learn how you can deploy Online Boutique on non-GKE clusters.
- **AI assistant using Gemini**: [See these instructions](/kustomize/components/shopping-assistant/README.md) to deploy a Gemini-powered AI assistant that suggests products to purchase based on an image.
- **And more**: The [`/kustomize` directory](/kustomize) contains instructions for customizing the deployment of Online Boutique with other variations.

## Documentation

- [Development](/docs/development-guide.md) to learn how to run and develop this app locally.

## Demos featuring Online Boutique

- [Platform Engineering in action: Deploy the Online Boutique sample apps with Score and Humanitec](https://medium.com/p/d99101001e69)
- [The new Kubernetes Gateway API with Istio and Anthos Service Mesh (ASM)](https://medium.com/p/9d64c7009cd)
- [Use Azure Redis Cache with the Online Boutique sample on AKS](https://medium.com/p/981bd98b53f8)
- [Sail Sharp, 8 tips to optimize and secure your .NET containers for Kubernetes](https://medium.com/p/c68ba253844a)
- [Deploy multi-region application with Anthos and Google cloud Spanner](https://medium.com/google-cloud/a2ea3493ed0)
- [Use Google Cloud Memorystore (Redis) with the Online Boutique sample on GKE](https://medium.com/p/82f7879a900d)
- [Use Helm to simplify the deployment of Online Boutique, with a Service Mesh, GitOps, and more!](https://medium.com/p/246119e46d53)
- [How to reduce microservices complexity with Apigee and Anthos Service Mesh](https://cloud.google.com/blog/products/application-modernization/api-management-and-service-mesh-go-together)
- [gRPC health probes with Kubernetes 1.24+](https://medium.com/p/b5bd26253a4c)
- [Use Google Cloud Spanner with the Online Boutique sample](https://medium.com/p/f7248e077339)
- [Seamlessly encrypt traffic from any apps in your Mesh to Memorystore (redis)](https://medium.com/google-cloud/64b71969318d)
- [Strengthen your app's security with Anthos Service Mesh and Anthos Config Management](https://cloud.google.com/service-mesh/docs/strengthen-app-security)
- [From edge to mesh: Exposing service mesh applications through GKE Ingress](https://cloud.google.com/architecture/exposing-service-mesh-apps-through-gke-ingress)
- [Take the first step toward SRE with Cloud Operations Sandbox](https://cloud.google.com/blog/products/operations/on-the-road-to-sre-with-cloud-operations-sandbox)
- [Deploying the Online Boutique sample application on Anthos Service Mesh](https://cloud.google.com/service-mesh/docs/onlineboutique-install-kpt)
- [Anthos Service Mesh Workshop: Lab Guide](https://codelabs.developers.google.com/codelabs/anthos-service-mesh-workshop)
- [KubeCon EU 2019 - Reinventing Networking: A Deep Dive into Istio's Multicluster Gateways - Steve Dake, Independent](https://youtu.be/-t2BfT59zJA?t=982)
- Google Cloud Next'18 SF
  - [Day 1 Keynote](https://youtu.be/vJ9OaAqfxo4?t=2416) showing GKE On-Prem
  - [Day 3 Keynote](https://youtu.be/JQPOPV_VH5w?t=815) showing Stackdriver
    APM (Tracing, Code Search, Profiler, Google Cloud Build)
  - [Introduction to Service Management with Istio](https://www.youtube.com/watch?v=wCJrdKdD6UM&feature=youtu.be&t=586)
- [Google Cloud Next'18 London – Keynote](https://youtu.be/nIq2pkNcfEI?t=3071)
  showing Stackdriver Incident Response Management
