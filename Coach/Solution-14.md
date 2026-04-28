# Solution 14 — Deploy to the Cloud

[< Back to Challenge](../Student/Challenge-14.md) | **[Home](README.md)**

---

> **Coach note:** This challenge is **OPTIONAL**. Students need a cloud account with billing enabled. The most critical part of this challenge is the **cleanup** — students MUST delete all cloud resources when done. Monitor this actively.

## Task 0: Prerequisites

Ensure students have:
- An active account on their chosen cloud provider
- The provider's CLI installed and authenticated
- `kubectl` installed (from previous challenges)

### Verify CLI Authentication

**Azure:**

```bash
az login
az account show
```

Expected: Shows subscription name, ID, and tenant.

**AWS:**

```bash
aws sts get-caller-identity
```

Expected: Shows Account ID, ARN, and UserID.

**Google Cloud:**

```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
gcloud config get-value project
```

Expected: Shows the configured project ID.

> **Coach tip:** If students don't have a cloud account, they can pair with someone who does, or skip this challenge entirely — all core learning is in Challenges 01–13.

---

## Task 1: Create a Managed Kubernetes Cluster

### Step-by-step

#### Azure (AKS)

```bash
# Create a resource group
az group create --name fasthack-rg --location eastus
```

Expected:

```json
{
  "id": "/subscriptions/.../resourceGroups/fasthack-rg",
  "location": "eastus",
  "name": "fasthack-rg",
  "properties": { "provisioningState": "Succeeded" }
}
```

```bash
# Create the AKS cluster (Free tier — no control plane charge)
az aks create \
  --resource-group fasthack-rg \
  --name fasthack-aks \
  --node-count 2 \
  --node-vm-size Standard_B2s \
  --generate-ssh-keys
```

Takes 5–10 minutes. Expected: JSON output with `"provisioningState": "Succeeded"`.

> 💰 **AKS Free tier:** The control plane is free. You pay only for the 2× Standard_B2s worker nodes (~$0.042/hour each).

#### AWS (EKS)

```bash
eksctl create cluster \
  --name fasthack-eks \
  --region us-east-1 \
  --nodegroup-name fasthack-nodes \
  --node-type t3.small \
  --nodes 2
```

Takes 10–15 minutes. `eksctl` creates the VPC, subnets, security groups, IAM roles, and node group automatically.

Expected output ends with:

```
EKS cluster "fasthack-eks" in "us-east-1" region is ready
```

> 💰 **EKS pricing:** The control plane costs $0.10/hour (~$73/month). Worker nodes are 2× t3.small (~$0.021/hour each). Delete promptly!

#### Google Cloud (GKE)

```bash
gcloud container clusters create fasthack-gke \
  --zone us-central1-a \
  --num-nodes 2 \
  --machine-type e2-small \
  --release-channel regular
```

Takes 5–10 minutes. Expected:

```
NAME           LOCATION       MASTER_VERSION  NUM_NODES  STATUS
fasthack-gke   us-central1-a  1.XX.XX-gke.XX  2          RUNNING
```

> 💰 **GKE Free tier:** One zonal cluster per billing account gets $74.40/month in free credits. You still pay for node compute (2× e2-small ~$0.017/hour each).

### Verification

After cluster creation:

```bash
kubectl get nodes -o wide
```

Expected: 2 nodes with cloud provider names (not `kind-control-plane`).

---

## Task 2: Connect kubectl to Your Cloud Cluster

### Step-by-step

#### Azure (AKS)

```bash
az aks get-credentials --resource-group fasthack-rg --name fasthack-aks
```

Expected:

```
Merged "fasthack-aks" as current context in /home/user/.kube/config
```

#### AWS (EKS)

```bash
aws eks update-kubeconfig --name fasthack-eks --region us-east-1
```

Expected:

```
Updated context arn:aws:eks:us-east-1:XXXX:cluster/fasthack-eks in /home/user/.kube/config
```

> Note: `eksctl create cluster` auto-configures kubectl, so this step may already be done.

#### Google Cloud (GKE)

```bash
gcloud container clusters get-credentials fasthack-gke --zone us-central1-a
```

Expected:

```
Fetching cluster endpoint and auth data.
kubeconfig entry generated for fasthack-gke.
```

### Verification

```bash
# Confirm you're connected to the cloud cluster (not Kind)
kubectl config current-context
```

Expected: Context name includes the cloud cluster name (e.g., `fasthack-aks`, `arn:aws:eks:...`, `gke_project_zone_fasthack-gke`).

```bash
# Verify cloud nodes
kubectl get nodes -o wide
```

Expected: Nodes show cloud-provider instance names and external IPs.

---

## Task 3: Deploy the Multi-Tier App

### Step-by-step

Create `cloud-app.yaml`:

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

### Verification

```bash
kubectl get pods
```

Expected: 2 backend pods and 2 frontend pods, all `1/1 Running`.

```bash
kubectl get svc
```

Expected: `backend-svc` with `ClusterIP`, `kubernetes` with `ClusterIP`.

---

## Task 4: Expose the App with a Cloud LoadBalancer

### Step-by-step

Create `frontend-lb.yaml`:

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

# Wait for the external IP (1-3 minutes)
kubectl get svc frontend-lb --watch
```

Expected: `EXTERNAL-IP` transitions from `<pending>` to a real IP address (or hostname on AWS).

> **AWS note:** On EKS, the `EXTERNAL-IP` is a DNS hostname (e.g., `abc123.us-east-1.elb.amazonaws.com`), not an IP address. Use it the same way.

### Verification

```bash
# Replace <EXTERNAL-IP> with the actual IP/hostname
curl http://<EXTERNAL-IP>
```

Expected:

```
Hello from the cloud! ☁️
```

🎉 **The application is live on the internet!**

> **Coach tip:** If `EXTERNAL-IP` stays `<pending>` for more than 5 minutes, check: `kubectl describe svc frontend-lb` for events, and ensure the cloud provider has sufficient quota for public IPs.

---

## Task 5: Cloud-Native Storage (CSI Drivers)

### Step-by-step

Check available StorageClasses:

```bash
kubectl get storageclass
```

Expected output varies by provider:

| Provider | Default StorageClass | CSI Driver |
|----------|---------------------|------------|
| AKS | `managed-csi` | `disk.csi.azure.com` |
| EKS | `gp2` | `ebs.csi.aws.com` |
| GKE | `standard-rwo` | `pd.csi.storage.gke.io` |

Create a test PVC:

```yaml
# Save as cloud-pvc.yaml
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
kubectl get pvc cloud-pvc
```

### Verification

```bash
kubectl get pvc cloud-pvc
```

Expected:

```
NAME        STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
cloud-pvc   Bound    pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   1Gi        RWO            <default-sc>   30s
```

The PVC should be `Bound` — the cloud provider dynamically provisioned a real disk.

> **Coach tip:** Point out the difference from Kind — on Kind, `standard` uses `rancher.io/local-path` (local directory). On cloud, the CSI driver provisions actual cloud disks (Azure Managed Disk, AWS EBS, GCE Persistent Disk). Same API, different backends.

---

## Task 6: Set Up Basic Monitoring

### Step-by-step

#### Azure (AKS) — Azure Monitor Container Insights

```bash
az aks enable-addons \
  --resource-group fasthack-rg \
  --name fasthack-aks \
  --addons monitoring
```

After a few minutes, view metrics in Azure Portal → AKS cluster → **Insights**.

#### AWS (EKS) — CloudWatch Container Insights

```bash
aws eks create-addon \
  --cluster-name fasthack-eks \
  --addon-name amazon-cloudwatch-observability
```

Verify:

```bash
kubectl get pods -n amazon-cloudwatch
```

View metrics in AWS Console → CloudWatch → Container Insights.

#### Google Cloud (GKE) — Cloud Monitoring

GKE has Cloud Monitoring enabled **by default** — no extra steps needed.

Verify:

```bash
kubectl get pods -n kube-system -l k8s-app=gke-metrics-agent
```

View metrics in Google Cloud Console → Kubernetes Engine → cluster → **Observability**.

### Verification

- Monitoring agent pods are running in the respective namespace
- The cloud provider's console shows basic container metrics

---

## Task 7: Clean Up Cloud Resources ⚠️

> 🔴 **THIS IS THE MOST IMPORTANT STEP. Students MUST delete all cloud resources NOW.**
>
> **Coach: Actively verify that every student has cleaned up before they leave.**

### Azure (AKS)

```bash
# Delete the entire resource group — removes cluster, VMs, disks, LB, and all associated resources
az group delete --name fasthack-rg --yes --no-wait
```

Verify deletion:

```bash
az group show --name fasthack-rg 2>/dev/null || echo "Resource group deleted successfully"
```

### AWS (EKS)

```bash
# Delete Kubernetes resources first (releases the cloud load balancer)
kubectl delete svc frontend-lb
kubectl delete pvc cloud-pvc

# Delete the EKS cluster and all associated resources
eksctl delete cluster --name fasthack-eks --region us-east-1
```

This takes 5–10 minutes. Verify in the AWS Console that no EC2 instances, EBS volumes, or Elastic Load Balancers remain.

> **⚠️ AWS extra check:** If `eksctl delete` fails or hangs, manually check for leftover resources in the AWS Console: EC2 Instances, Load Balancers, VPCs, NAT Gateways, and EBS Volumes in `us-east-1`.

### Google Cloud (GKE)

```bash
# Delete the GKE cluster
gcloud container clusters delete fasthack-gke --zone us-central1-a --quiet
```

Verify in Google Cloud Console that no Compute Engine instances or Load Balancers remain.

### Switch Back to Kind

After cleanup, switch kubectl back to your local Kind cluster:

```bash
kubectl config use-context kind-fasthack

# Verify
kubectl get nodes
```

Expected: Shows `fasthack-control-plane` (the Kind node), not cloud VMs.

### Verification

- [ ] Cloud cluster is deleted (verify in the provider's web console)
- [ ] No running VMs, load balancers, or disks remain
- [ ] kubectl context is back to `kind-fasthack`

---

## What's Next — Learning Path 🎓

```
┌─────────────────────────┐     ┌─────────────────────────────────┐     ┌──────────────────────────────┐
│  🐧 Linux FUNdamentals  │ ──▶ │  ☸️ Kubernetes for Linux Sysadmins │ ──▶ │  🤖 AI for Infra Professionals │
│  linuxhackathon.com     │     │  (You are here — COMPLETE! ✅)   │     │  ai4infra.com                │
└─────────────────────────┘     └─────────────────────────────────┘     └──────────────────────────────┘
```

Recommended next steps for students:

1. **[AI for Infrastructure Professionals](https://ai4infra.com/)** — Learn how to run AI workloads on the infrastructure you just mastered.
2. **Get Certified** — Students are now prepared for: `KCNA → CKA → CKAD → CKS`
3. **[Linux FUNdamentals](https://linuxhackathon.com/)** — If they haven't done this hackathon yet, it's the foundation for everything they just learned.
4. **Give back** — [Open issues](https://github.com/ricmmartins/fasthack-kubernetes/issues) or submit PRs to improve the hackathon!

---

## Common Issues

| Problem | Cause | Fix |
|---------|-------|-----|
| `az aks create` fails with quota error | Subscription has insufficient vCPU quota for the region | Try a different region: `--location westus2` or request a quota increase |
| `eksctl create cluster` takes 20+ minutes | EKS cluster creation is naturally slow | Wait patiently — it provisions VPC, subnets, NAT gateways, IAM roles, and nodes |
| `gcloud` says "billing not enabled" | GCP project needs billing linked | Enable billing in Google Cloud Console → Billing |
| `EXTERNAL-IP` stuck on `<pending>` | Cloud LB provisioning delay or insufficient permissions | Wait 5 min; check `kubectl describe svc frontend-lb` for events |
| Can't connect to cloud cluster after creation | kubectl context not updated | Re-run the get-credentials command for your provider |
| `eksctl delete cluster` hangs | Leftover LoadBalancer resources blocking VPC deletion | Manually delete the ELB in AWS Console, then retry |
| Student forgot to clean up and left | Resources running = costs accruing | **Coach must verify cleanup.** Use the cloud console to check for orphaned resources |
| PVC stays Pending on EKS | EBS CSI driver not installed | Run: `eksctl create addon --name aws-ebs-csi-driver --cluster fasthack-eks` |

## Cloud Provider Quick Reference

| Operation | AKS (Azure) | EKS (AWS) | GKE (Google Cloud) |
|-----------|-------------|-----------|---------------------|
| **CLI tool** | `az` | `aws` + `eksctl` | `gcloud` |
| **Create cluster** | `az aks create` | `eksctl create cluster` | `gcloud container clusters create` |
| **Get credentials** | `az aks get-credentials` | `aws eks update-kubeconfig` | `gcloud container clusters get-credentials` |
| **CSI driver** | `disk.csi.azure.com` | `ebs.csi.aws.com` | `pd.csi.storage.gke.io` |
| **Default StorageClass** | `managed-csi` | `gp2` | `standard-rwo` |
| **Monitoring** | Azure Monitor Container Insights | CloudWatch Container Insights | Cloud Monitoring (auto) |
| **Control plane cost** | Free (Free tier) | $0.10/hour (~$73/mo) | Free ($74.40/mo credit) |
| **Delete cluster** | `az group delete --name fasthack-rg --yes` | `eksctl delete cluster --name fasthack-eks` | `gcloud container clusters delete fasthack-gke --quiet` |
