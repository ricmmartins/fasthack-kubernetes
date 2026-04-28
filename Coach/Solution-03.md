# Solution 03 — Creating a Local Cluster

[< Back to Challenge](../Student/Challenge-03.md) | **[Home](README.md)**

## Pre-check

Ensure Docker is running (Kind uses Docker to create nodes as containers):

```bash
docker info --format '{{.ServerVersion}}'
```

Expected output:

```
27.x.x
```

If this fails, the Docker daemon isn't running.

---

## Task 1: Install Kind and Create a Single-Node Cluster

### Step-by-step

**Install Kind** (pick the method that fits the student's environment):

```bash
# Linux (amd64)
[ $(uname -m) = x86_64 ] && curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.31.0/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind

# macOS
brew install kind

# Windows (with chocolatey)
choco install kind
```

Verify the installation:

```bash
kind version
```

Expected output:

```
kind v0.31.0 go1.23.x ...
```

**Create a single-node cluster:**

```bash
kind create cluster --name k8s-lab
```

Expected output:

```
Creating cluster "k8s-lab" ...
 ✓ Ensuring node image (kindest/node:v1.33.0) 🖼
 ✓ Preparing nodes 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
Set kubectl context to "kind-k8s-lab"
You can now use your cluster with:

kubectl cluster-info --context kind-k8s-lab

Have a nice day! 👋
```

> **Coach note:** The Kubernetes version in the node image depends on the Kind version. Kind v0.31.0 ships with Kubernetes v1.33.0 by default.

**Verify the cluster is running:**

```bash
kubectl cluster-info
```

Expected output:

```
Kubernetes control plane is running at https://127.0.0.1:XXXXX
CoreDNS is running at https://127.0.0.1:XXXXX/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy
```

**Verify the node is Ready:**

```bash
kubectl get nodes
```

Expected output:

```
NAME                    STATUS   ROLES           AGE   VERSION
k8s-lab-control-plane   Ready    control-plane   1m    v1.33.0
```

### Verification

- `kind version` shows a valid version
- `kubectl cluster-info` shows the control plane URL
- `kubectl get nodes` shows one node with `Ready` status

---

## Task 2: Explore kubeconfig

### Step-by-step

**View the kubeconfig (credentials redacted):**

```bash
kubectl config view
```

Expected output:

```yaml
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: DATA+OMITTED
    server: https://127.0.0.1:XXXXX
  name: kind-k8s-lab
contexts:
- context:
    cluster: kind-k8s-lab
    user: kind-k8s-lab
  name: kind-k8s-lab
current-context: kind-k8s-lab
kind: Config
preferences: {}
users:
- name: kind-k8s-lab
  user:
    client-certificate-data: DATA+OMITTED
    client-key-data: DATA+OMITTED
```

> **Coach note:** Walk students through the three sections:
> - **clusters** — where the API server lives (address + CA certificate)
> - **users** — credentials (client certificates in this case)
> - **contexts** — binds a cluster + user + optional namespace into a named shortcut
>
> Analogy: This is like `~/.ssh/config` — it maps friendly names to connection details.

**List all available contexts:**

```bash
kubectl config get-contexts
```

Expected output:

```
CURRENT   NAME           CLUSTER        AUTHINFO       NAMESPACE
*         kind-k8s-lab   kind-k8s-lab   kind-k8s-lab
```

The `*` marks the currently active context.

**Show the current context:**

```bash
kubectl config current-context
```

Expected output:

```
kind-k8s-lab
```

**Switch contexts (useful when managing multiple clusters):**

```bash
kubectl config use-context kind-k8s-lab
```

Expected output:

```
Switched to context "kind-k8s-lab".
```

**View the raw kubeconfig file location:**

```bash
# Linux / macOS
cat ~/.kube/config | head -20

# Windows (PowerShell)
Get-Content $env:USERPROFILE\.kube\config | Select-Object -First 20
```

### Verification

- Students can explain: clusters = where, users = who, contexts = which combo to use
- `kubectl config get-contexts` lists the Kind cluster context
- Students understand that switching contexts changes which cluster `kubectl` talks to

---

## Task 3: List kube-system Pods and Identify Control Plane Components

### Step-by-step

**List all Pods in the `kube-system` namespace:**

```bash
kubectl get pods -n kube-system
```

Expected output:

```
NAME                                            READY   STATUS    RESTARTS   AGE
coredns-xxxxxxxxxx-xxxxx                        1/1     Running   0          5m
coredns-xxxxxxxxxx-xxxxx                        1/1     Running   0          5m
etcd-k8s-lab-control-plane                      1/1     Running   0          5m
kindnet-xxxxx                                   1/1     Running   0          5m
kube-apiserver-k8s-lab-control-plane            1/1     Running   0          5m
kube-controller-manager-k8s-lab-control-plane   1/1     Running   0          5m
kube-proxy-xxxxx                                1/1     Running   0          5m
kube-scheduler-k8s-lab-control-plane            1/1     Running   0          5m
```

> **Coach note:** Have students identify each component:
>
> | Pod | Role | Linux Analogy |
> |---|---|---|
> | `kube-apiserver` | Front door — all requests go through it | `sshd` — single entry point |
> | `etcd` | Cluster database — stores all state | `/etc` + `/var/lib` — persistent config |
> | `kube-scheduler` | Assigns Pods to nodes | Load balancer choosing a backend |
> | `kube-controller-manager` | Ensures desired state = actual state | `systemd` restarting crashed services |
> | `coredns` | Cluster DNS resolution | `systemd-resolved` / BIND |
> | `kindnet` | CNI plugin — Pod-to-Pod networking | Network bridge / virtual switch |
> | `kube-proxy` | Service routing rules | `iptables` / `nftables` |

**See which node each Pod runs on:**

```bash
kubectl get pods -n kube-system -o wide
```

**Inspect the API server Pod:**

```bash
kubectl describe pod -n kube-system -l component=kube-apiserver
```

Students should look at the `Containers` section to see the command-line flags the API server was started with.

**Check etcd logs:**

```bash
kubectl logs -n kube-system -l component=etcd --tail=10
```

### Verification

- Students can list all kube-system Pods
- Students can name the four core control plane components (apiserver, etcd, scheduler, controller-manager)
- Students can explain the role of each component using a Linux analogy

---

## Task 4: Create a Multi-Node Cluster

### Step-by-step

**Create the Kind configuration file** `kind-config.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

**Delete the old single-node cluster:**

```bash
kind delete cluster --name k8s-lab
```

Expected output:

```
Deleting cluster "k8s-lab" ...
Deleted nodes: ["k8s-lab-control-plane"]
```

**Create the multi-node cluster:**

```bash
kind create cluster --name k8s-lab --config kind-config.yaml
```

Expected output:

```
Creating cluster "k8s-lab" ...
 ✓ Ensuring node image (kindest/node:v1.33.0) 🖼
 ✓ Preparing nodes 📦 📦 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
 ✓ Joining worker nodes 🚜
Set kubectl context to "kind-k8s-lab"
...
```

> **Coach note:** Notice `📦 📦 📦` — three nodes being prepared (1 control plane + 2 workers).

**Verify all three nodes are Ready:**

```bash
kubectl get nodes
```

Expected output:

```
NAME                    STATUS   ROLES           AGE   VERSION
k8s-lab-control-plane   Ready    control-plane   1m    v1.33.0
k8s-lab-worker          Ready    <none>          1m    v1.33.0
k8s-lab-worker2         Ready    <none>          1m    v1.33.0
```

**Show the Docker containers that represent the nodes:**

```bash
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
```

Expected output:

```
NAMES                    IMAGE                  STATUS
k8s-lab-control-plane    kindest/node:v1.33.0   Up 2 minutes
k8s-lab-worker           kindest/node:v1.33.0   Up 2 minutes
k8s-lab-worker2          kindest/node:v1.33.0   Up 2 minutes
```

> **Coach note:** This is the "aha" moment — each Kubernetes "node" is actually a Docker container. Kind runs Kubernetes inside Docker.

**Verify kube-system Pods are spread across nodes:**

```bash
kubectl get pods -n kube-system -o wide
```

Students should see that `kindnet` and `kube-proxy` Pods run on every node (they are DaemonSets), while control plane components run only on the control-plane node.

### Verification

- `kubectl get nodes` shows 3 nodes, all `Ready`
- One node has `Roles: control-plane`, two have `<none>` (workers)
- `docker ps` shows 3 Kind containers running

---

## Common Issues

| Issue | Symptom | Fix |
|---|---|---|
| Kind version too old | `kind create cluster` fails or creates an old Kubernetes version | Update Kind: re-download the binary from https://kind.sigs.k8s.io/docs/user/quick-start/#installation |
| Docker not running | `Cannot connect to the Docker daemon` | Start Docker: `sudo systemctl start docker` or launch Docker Desktop |
| Name collision | `ERROR: failed to create cluster: node(s) already exist for a cluster with the name "k8s-lab"` | Delete the old cluster first: `kind delete cluster --name k8s-lab` |
| Insufficient resources | Nodes stay `NotReady` or containers OOMKill | Kind multi-node clusters need ~4 GB RAM and ~2 CPUs available for Docker. Increase Docker Desktop resource limits |
| kubectl context not set | `kubectl` talks to wrong cluster after creating a new one | Switch context: `kubectl config use-context kind-k8s-lab` |
| Worker nodes show `<none>` for ROLES | Students worry this is an error | This is **normal** — worker nodes have no special role label. Only the control-plane node is labeled |
| kubeconfig not found after deleting cluster | `~/.kube/config` references a deleted cluster | Kind updates kubeconfig on create/delete. If corrupted, re-export: `kind export kubeconfig --name k8s-lab` |
| Students confused about Kind nodes vs Docker containers | They think each Kind node is a separate VM | Explain: Kind "nodes" are Docker containers running `kubelet` + the Kubernetes stack. It's containers all the way down |

