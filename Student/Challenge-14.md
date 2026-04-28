# Challenge 14 — Deploying to the Cloud

[< Previous Challenge](Challenge-13.md) | **[Home](../README.md)**

## Introduction

🎓 **Congratulations — you made it to the graduation challenge!**

You started this hackathon running containers as Linux processes, built local clusters with Kind, deployed multi-tier apps, wired up networking, secured workloads with RBAC and NetworkPolicies, set up monitoring with Prometheus and Grafana, and debugged real-world failures. Everything so far has run on your local machine.

Now it's time to take what you've built and deploy it to the real cloud.

On a Linux server, the jump from "it works on my machine" to "it works in production" means provisioning VMs, configuring load balancers, setting up monitoring agents, and managing storage drivers. Managed Kubernetes services handle all of that for you — you bring the same YAML manifests you've been writing all along, and the cloud provider takes care of the control plane, node provisioning, and integrations.

In this challenge, you will pick one of the three major cloud providers — **Azure (AKS)**, **AWS (EKS)**, or **Google Cloud (GKE)** — create a managed cluster, deploy your multi-tier application from Challenge 05, and expose it to the internet with a real LoadBalancer.

> ⚠️ **This challenge is OPTIONAL.** All 13 previous challenges work entirely on Kind with no cloud account required. If you don't have a cloud account or prefer not to incur costs, you have already completed the core hackathon. Come back to this challenge whenever you're ready!

> 💰 **Cost awareness:** Each cloud provider offers free or low-cost options for learning (see the pricing notes below). However, **cloud resources cost money when left running**. Follow the cleanup instructions at the end carefully.

## Description

### Task 0 — Prerequisites

Before you begin, make sure you have:

- An active account on your chosen cloud provider (Azure, AWS, or Google Cloud)
- The provider's CLI tool installed and authenticated:

  | Provider | CLI Tool | Install Guide |
  |----------|----------|---------------|
  | Azure | `az` | [Install Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) |
  | AWS | `aws` + `eksctl` | [Install AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) + [Install eksctl](https://eksctl.io/installation/) |
  | Google Cloud | `gcloud` | [Install gcloud CLI](https://cloud.google.com/sdk/docs/install) |

- `kubectl` installed (you already have this from previous challenges)

Verify your CLI is authenticated:

```bash
# Azure
az login
az account show

# AWS
aws sts get-caller-identity

# Google Cloud
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
```

### Task 1 — Create a Managed Kubernetes Cluster

Create a small cluster suitable for learning. Use the minimum node count and smallest instance sizes to keep costs low.

<details>
<summary><strong>Azure (AKS)</strong></summary>

```bash
# Create a resource group
az group create --name fasthack-rg --location eastus

# Create the AKS cluster (Free tier — no control plane charge)
az aks create \
  --resource-group fasthack-rg \
  --name fasthack-aks \
  --node-count 2 \
  --node-vm-size Standard_B2s \
  --generate-ssh-keys
```

> 💰 **AKS Free tier:** The control plane is free. You only pay for the worker node VMs. `Standard_B2s` is one of the cheapest VM sizes available.

</details>

<details>
<summary><strong>AWS (EKS)</strong></summary>

```bash
# Create the EKS cluster with eksctl
eksctl create cluster \
  --name fasthack-eks \
  --region us-east-1 \
  --nodegroup-name fasthack-nodes \
  --node-type t3.small \
  --nodes 2
```

> 💰 **EKS pricing:** The control plane costs $0.10/hour (~$73/month). Use `t3.small` instances to minimize node costs. Delete the cluster promptly after completing the challenge.

</details>

<details>
<summary><strong>Google Cloud (GKE)</strong></summary>

```bash
# Create the GKE cluster (zonal — eligible for free tier)
gcloud container clusters create fasthack-gke \
  --zone us-central1-a \
  --num-nodes 2 \
  --machine-type e2-small \
  --release-channel regular
```

> 💰 **GKE Free tier:** One zonal or Autopilot cluster per billing account gets $74.40/month in free credits, which covers the cluster management fee. You still pay for node compute.

</details>

Cluster creation takes 5–15 minutes depending on the provider. Wait for it to complete before proceeding.

### Task 2 — Connect kubectl to Your Cloud Cluster

Configure your local `kubectl` to talk to the new cloud cluster.

<details>
<summary><strong>Azure (AKS)</strong></summary>

```bash
az aks get-credentials --resource-group fasthack-rg --name fasthack-aks
```

</details>

<details>
<summary><strong>AWS (EKS)</strong></summary>

```bash
aws eks update-kubeconfig --name fasthack-eks --region us-east-1
```

</details>

<details>
<summary><strong>Google Cloud (GKE)</strong></summary>

```bash
gcloud container clusters get-credentials fasthack-gke --zone us-central1-a
```

</details>

Verify the connection:

```bash
# Confirm you're connected to the cloud cluster (not your local Kind cluster)
kubectl config current-context

# Check the nodes — you should see cloud VMs, not Kind containers
kubectl get nodes -o wide
```

### Task 3 — Deploy the Multi-Tier App from Challenge 05

Take the frontend + backend application you built in Challenge 05 and deploy it to your cloud cluster. Use the same YAML manifests — they work identically on any Kubernetes cluster.

Create a file named `cloud-app.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  labels:
    app: backend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
    spec:
      containers:
        - name: echo
          image: hashicorp/http-echo
          args:
            - "-text=Hello from the cloud! ☁️"
          ports:
            - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: backend-svc
spec:
  selector:
    app: backend
  ports:
    - protocol: TCP
      port: 5678
      targetPort: 5678
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  labels:
    app: frontend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      containers:
        - name: nginx
          image: nginx:stable
          ports:
            - containerPort: 80
          volumeMounts:
            - name: config
              mountPath: /etc/nginx/conf.d/default.conf
              subPath: default.conf
      volumes:
        - name: config
          configMap:
            name: frontend-config
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: frontend-config
data:
  default.conf: |
    server {
        listen 80;
        location / {
            proxy_pass http://backend-svc:5678;
        }
    }
```

```bash
kubectl apply -f cloud-app.yaml

# Wait for all Pods to be running
kubectl get pods --watch
```

### Task 4 — Expose the App with a Cloud LoadBalancer

On Kind, you used `NodePort` to access services. In the cloud, you can use a `LoadBalancer` Service, which automatically provisions a real cloud load balancer with a public IP.

Create a file named `frontend-lb.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: frontend-lb
spec:
  type: LoadBalancer
  selector:
    app: frontend
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
```

```bash
kubectl apply -f frontend-lb.yaml

# Wait for the external IP to be assigned (may take 1-3 minutes)
kubectl get svc frontend-lb --watch
```

Once the `EXTERNAL-IP` column shows a real IP address (not `<pending>`), test it:

```bash
# Replace with your actual external IP
curl http://<EXTERNAL-IP>
```

You should see: `Hello from the cloud! ☁️`

🎉 **Your application is now live on the internet, running on managed Kubernetes!**

### Task 5 — Explore Cloud-Native Storage (CSI Drivers)

Each cloud provider has a CSI (Container Storage Interface) driver that lets Kubernetes provision cloud disks dynamically. Check which StorageClasses are available on your cluster:

```bash
# List the available StorageClasses
kubectl get storageclass
```

Create a PersistentVolumeClaim to test dynamic provisioning:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: cloud-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
```

```bash
kubectl apply -f cloud-pvc.yaml

# Check the PVC status — it should become "Bound"
kubectl get pvc cloud-pvc
```

Compare the CSI driver in use:

| Provider | CSI Driver | Default StorageClass | Backend |
|----------|-----------|---------------------|---------|
| AKS | `disk.csi.azure.com` | `managed-csi` | Azure Managed Disk |
| EKS | `ebs.csi.aws.com` | `gp2` | EBS Volume |
| GKE | `pd.csi.storage.gke.io` | `standard-rwo` | Persistent Disk |

### Task 6 — Set Up Basic Monitoring

Enable the cloud-native monitoring solution for your cluster. Each provider has a built-in option that requires minimal setup.

<details>
<summary><strong>Azure (AKS) — Azure Monitor Container Insights</strong></summary>

```bash
az aks enable-addons \
  --resource-group fasthack-rg \
  --name fasthack-aks \
  --addons monitoring
```

After a few minutes, go to the Azure Portal → your AKS cluster → **Insights** to see container metrics, logs, and node health.

</details>

<details>
<summary><strong>AWS (EKS) — CloudWatch Container Insights</strong></summary>

Install the CloudWatch Observability add-on:

```bash
aws eks create-addon \
  --cluster-name fasthack-eks \
  --addon-name amazon-cloudwatch-observability
```

After installation, verify the agent pods are running:

```bash
kubectl get pods -n amazon-cloudwatch
```

View metrics in the AWS Console → CloudWatch → Container Insights.

</details>

<details>
<summary><strong>Google Cloud (GKE) — Cloud Monitoring</strong></summary>

GKE clusters have Cloud Monitoring enabled by default. No extra steps needed!

Verify by going to Google Cloud Console → Kubernetes Engine → your cluster → **Observability** tab.

To check that metrics are flowing:

```bash
# Confirm monitoring pods are running in kube-system
kubectl get pods -n kube-system -l k8s-app=gke-metrics-agent
```

</details>

### Task 7 — Clean Up Cloud Resources ⚠️

> 🔴 **IMPORTANT: Do this step NOW. Do not leave cloud resources running — they will incur costs!**

<details>
<summary><strong>Azure (AKS) — Delete everything</strong></summary>

```bash
# Delete the resource group (this removes the cluster, VMs, disks, load balancer, and all associated resources)
az group delete --name fasthack-rg --yes --no-wait
```

Verify deletion in the Azure Portal or with:

```bash
az group show --name fasthack-rg 2>/dev/null || echo "Resource group deleted successfully"
```

</details>

<details>
<summary><strong>AWS (EKS) — Delete everything</strong></summary>

```bash
# Delete Kubernetes resources first (releases the cloud load balancer)
kubectl delete svc frontend-lb
kubectl delete pvc cloud-pvc

# Delete the EKS cluster and all associated resources
eksctl delete cluster --name fasthack-eks --region us-east-1
```

Verify in the AWS Console that no EC2 instances, EBS volumes, or Elastic Load Balancers remain.

</details>

<details>
<summary><strong>Google Cloud (GKE) — Delete everything</strong></summary>

```bash
# Delete the GKE cluster
gcloud container clusters delete fasthack-gke --zone us-central1-a --quiet
```

Verify in the Google Cloud Console that no Compute Engine instances or Load Balancers remain.

</details>

After cleanup, switch your kubectl context back to your local Kind cluster:

```bash
kubectl config use-context kind-fasthack
```

## Success Criteria

- [ ] You created a managed Kubernetes cluster on your chosen cloud provider (AKS, EKS, or GKE).
- [ ] `kubectl get nodes` shows cloud VM nodes (not Kind containers).
- [ ] The backend and frontend Deployments are running with all Pods in `Ready` state.
- [ ] A `LoadBalancer` Service has been assigned a real external IP address.
- [ ] You can `curl` the external IP and receive a response from the backend through the frontend.
- [ ] A PersistentVolumeClaim dynamically provisioned a cloud disk and is in `Bound` state.
- [ ] Cloud monitoring is enabled and you can see basic metrics in the provider's console.
- [ ] **All cloud resources have been deleted** and your kubectl context is back to your local Kind cluster.

## Cloud Provider Reference

| Operation | AKS (Azure) | EKS (AWS) | GKE (Google Cloud) |
|-----------|-------------|-----------|---------------------|
| **CLI tool** | `az` | `aws` + `eksctl` | `gcloud` |
| **Create cluster** | `az aks create` | `eksctl create cluster` | `gcloud container clusters create` |
| **Get credentials** | `az aks get-credentials` | `aws eks update-kubeconfig` | `gcloud container clusters get-credentials` |
| **CSI storage driver** | `disk.csi.azure.com` | `ebs.csi.aws.com` | `pd.csi.storage.gke.io` |
| **Monitoring** | Azure Monitor + Container Insights | CloudWatch Container Insights | Cloud Monitoring (enabled by default) |
| **Control plane cost** | Free (Free tier) | $0.10/hour (~$73/month) | Free ($74.40/mo credit for 1 zonal cluster) |
| **Delete cluster** | `az group delete` | `eksctl delete cluster` | `gcloud container clusters delete` |

## Hints

<details>
<summary>Hint 1: Azure (AKS) — Step-by-step walkthrough</summary>

```bash
# 1. Login
az login

# 2. Create resource group
az group create --name fasthack-rg --location eastus

# 3. Create AKS cluster (Free tier, 2 small nodes)
az aks create \
  --resource-group fasthack-rg \
  --name fasthack-aks \
  --node-count 2 \
  --node-vm-size Standard_B2s \
  --generate-ssh-keys

# 4. Get credentials
az aks get-credentials --resource-group fasthack-rg --name fasthack-aks

# 5. Verify
kubectl get nodes

# 6. Deploy the app
kubectl apply -f cloud-app.yaml
kubectl apply -f frontend-lb.yaml

# 7. Wait for external IP
kubectl get svc frontend-lb --watch

# 8. Test
curl http://<EXTERNAL-IP>

# 9. Enable monitoring
az aks enable-addons --resource-group fasthack-rg --name fasthack-aks --addons monitoring

# 10. CLEAN UP when done!
az group delete --name fasthack-rg --yes --no-wait
```

</details>

<details>
<summary>Hint 2: AWS (EKS) — Step-by-step walkthrough</summary>

```bash
# 1. Verify credentials
aws sts get-caller-identity

# 2. Create EKS cluster (this takes ~15 minutes)
eksctl create cluster \
  --name fasthack-eks \
  --region us-east-1 \
  --nodegroup-name fasthack-nodes \
  --node-type t3.small \
  --nodes 2

# 3. eksctl automatically configures kubectl — verify
kubectl get nodes

# 4. Deploy the app
kubectl apply -f cloud-app.yaml
kubectl apply -f frontend-lb.yaml

# 5. Wait for external IP (AWS creates a Classic Load Balancer — the EXTERNAL-IP will be a hostname)
kubectl get svc frontend-lb --watch

# 6. Test (use the hostname, not an IP)
curl http://<EXTERNAL-HOSTNAME>

# 7. Enable monitoring
aws eks create-addon \
  --cluster-name fasthack-eks \
  --addon-name amazon-cloudwatch-observability

# 8. CLEAN UP when done!
kubectl delete svc frontend-lb
kubectl delete pvc cloud-pvc
eksctl delete cluster --name fasthack-eks --region us-east-1
```

> **Note:** On AWS, the LoadBalancer `EXTERNAL-IP` is a DNS hostname (e.g., `abc123.us-east-1.elb.amazonaws.com`), not an IP address. Use it the same way — `curl http://<hostname>`.

</details>

<details>
<summary>Hint 3: Google Cloud (GKE) — Step-by-step walkthrough</summary>

```bash
# 1. Login and set project
gcloud auth login
gcloud config set project YOUR_PROJECT_ID

# 2. Create GKE cluster
gcloud container clusters create fasthack-gke \
  --zone us-central1-a \
  --num-nodes 2 \
  --machine-type e2-small \
  --release-channel regular

# 3. Get credentials
gcloud container clusters get-credentials fasthack-gke --zone us-central1-a

# 4. Verify
kubectl get nodes

# 5. Deploy the app
kubectl apply -f cloud-app.yaml
kubectl apply -f frontend-lb.yaml

# 6. Wait for external IP
kubectl get svc frontend-lb --watch

# 7. Test
curl http://<EXTERNAL-IP>

# 8. Monitoring is enabled by default — check the GKE console

# 9. CLEAN UP when done!
gcloud container clusters delete fasthack-gke --zone us-central1-a --quiet
```

</details>

<details>
<summary>Hint 4: Switching kubectl context between Kind and cloud</summary>

```bash
# List all contexts
kubectl config get-contexts

# Switch to your cloud cluster
kubectl config use-context <cloud-context-name>

# Switch back to Kind
kubectl config use-context kind-fasthack

# Rename a context for convenience
kubectl config rename-context <long-cloud-name> cloud
```

Common context names:
- **AKS:** `fasthack-aks`
- **EKS:** `<arn>:cluster/fasthack-eks` (use `kubectl config get-contexts` to find the exact name)
- **GKE:** `gke_<project>_<zone>_fasthack-gke`

</details>

<details>
<summary>Hint 5: Troubleshooting — LoadBalancer stuck on "pending"</summary>

If `EXTERNAL-IP` stays `<pending>` for more than 5 minutes:

```bash
# Check events for issues
kubectl describe svc frontend-lb

# Check node status
kubectl get nodes

# Check if the cloud provider integration is working
kubectl get events --sort-by='.lastTimestamp'
```

Common causes:
- **AKS:** Insufficient quota for public IPs in the region. Run `az network public-ip list --resource-group MC_fasthack-rg_fasthack-aks_eastus`.
- **EKS:** Missing IAM permissions for the AWS Load Balancer Controller. Check `eksctl` output for warnings.
- **GKE:** Firewall rules blocking health checks. Check `gcloud compute firewall-rules list`.

</details>

## Learning Resources

### Azure Kubernetes Service (AKS)
- [AKS Documentation](https://learn.microsoft.com/azure/aks/)
- [Quickstart: Deploy an AKS cluster](https://learn.microsoft.com/azure/aks/learn/quick-kubernetes-deploy-cli)
- [AKS Pricing Tiers](https://learn.microsoft.com/azure/aks/free-standard-pricing-tiers)
- [Azure Monitor Container Insights](https://learn.microsoft.com/azure/azure-monitor/containers/container-insights-overview)

### Amazon Elastic Kubernetes Service (EKS)
- [EKS Documentation](https://docs.aws.amazon.com/eks/latest/userguide/)
- [Getting Started with eksctl](https://eksctl.io/getting-started/)
- [EKS Pricing](https://aws.amazon.com/eks/pricing/)
- [CloudWatch Container Insights for EKS](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Container-Insights-setup-EKS-quickstart.html)

### Google Kubernetes Engine (GKE)
- [GKE Documentation](https://cloud.google.com/kubernetes-engine/docs)
- [Quickstart: Deploy an app to GKE](https://cloud.google.com/kubernetes-engine/docs/deploy-app-cluster)
- [GKE Pricing](https://cloud.google.com/kubernetes-engine/pricing)
- [GKE Observability](https://cloud.google.com/stackdriver/docs/managed-prometheus)

### General
- [Kubernetes Documentation — Cloud Providers](https://kubernetes.io/docs/concepts/cluster-administration/cloud-providers/)
- [CNCF Landscape — Certified Kubernetes](https://landscape.cncf.io/)

## What's Next?

🎉 **You did it!** You've completed the entire **Kubernetes for Linux Sysadmins** hackathon — from running your first container to deploying on production cloud infrastructure.

Here's the learning path you've followed and where to go next:

```
┌─────────────────────────┐     ┌─────────────────────────────────┐     ┌──────────────────────────────┐
│  🐧 Linux FUNdamentals  │ ──▶ │  ☸️ Kubernetes for Linux Sysadmins │ ──▶ │  🤖 AI for Infra Professionals │
│  linuxhackathon.com     │     │  (You are here — COMPLETE! ✅)   │     │  ai4infra.com                │
└─────────────────────────┘     └─────────────────────────────────┘     └──────────────────────────────┘
```

### Recommended next steps

1. **[AI for Infrastructure Professionals](https://ai4infra.com/)** — Learn how to run AI workloads on the infrastructure you just mastered.

2. **Get Certified** — You're now prepared to pursue:
   ```
   KCNA → CKA → CKAD → CKS
   ```

3. **Explore more at [ricardomartins.com.br](https://ricardomartins.com.br)** — More cloud-native content and learning resources.

4. **Give back** — Found a bug or want to improve a challenge? [Open an issue](https://github.com/ricmmartins/fasthack-kubernetes/issues) or submit a PR!

> **"You started knowing Linux. Now you orchestrate it at scale."** 🚀
