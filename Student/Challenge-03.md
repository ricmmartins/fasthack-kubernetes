# Challenge 03 — Creating a Local Cluster

[< Previous Challenge](Challenge-02.md) | **[Home](../README.md)** | [Next Challenge >](Challenge-04.md)

## Introduction

Setting up your own Kubernetes cluster is like building a complete Linux server farm — but instead of racking physical servers, you spin up containers that *act* as servers.

**Kind** (Kubernetes IN Docker) runs full Kubernetes nodes as Docker containers on your local machine. Think of it this way:

| Installing a Linux service | Creating a Kubernetes cluster |
|---|---|
| `apt install nginx` | `kind create cluster` |
| `systemctl start nginx` | Cluster bootstraps automatically |
| One server, one service | Multiple "servers" (nodes) in containers |

A Kubernetes cluster has two planes:

- **Control Plane** (the brain): This is like the management layer of your server farm. It includes:
  - **API Server** — the front door (like `sshd` for your cluster, every request goes through it)
  - **etcd** — the database (like `/etc` for your entire cluster — stores all state)
  - **Scheduler** — decides which node runs a workload (like a load balancer choosing a backend)
  - **Controller Manager** — ensures desired state matches actual state (like `systemd` restarting crashed services)

- **Data Plane** (the workers): These are your workhorses, the servers that actually run your applications. Each worker node runs:
  - **kubelet** — the node agent (like `systemd` on each server, managing local workloads)
  - **kube-proxy** — networking rules (like `iptables` managing traffic routing)
  - **Container Runtime** — actually runs containers (like `containerd` or `dockerd`)

In this challenge, you'll build your own cluster from scratch, explore its internals, and understand how all these pieces fit together.

## Description

Your mission is to:

1. **Install Kind and create a single-node cluster** — Bootstrap your first Kubernetes cluster and verify it's running. This is the equivalent of provisioning a new Linux server and confirming you can SSH into it.

2. **Explore kubeconfig (`~/.kube/config`) and understand contexts** — Just like `/etc/hosts` maps hostnames to IPs, kubeconfig maps cluster names to API server endpoints and credentials. Understand how `kubectl` knows *which* cluster to talk to.

3. **List all Pods in the `kube-system` namespace and identify control plane components** — This is like running `systemctl list-units` on a Linux server to see what system services are running. The `kube-system` namespace holds the components that make Kubernetes itself work.

4. **Create a multi-node cluster using a Kind configuration file** — Scale from a single server to a farm. Define a cluster with one control plane node and two worker nodes using a YAML config file — like writing an infrastructure-as-code manifest for your server fleet.

> 💡 **Minikube alternative**: If you prefer, you can use [Minikube](https://minikube.sigs.k8s.io/) instead of Kind. The concepts are identical — only the CLI commands differ. Minikube creates a VM or container-based cluster with `minikube start` instead of `kind create cluster`.

## Success Criteria

- [ ] `kind create cluster` completes successfully and `kubectl cluster-info` shows a running cluster
- [ ] `kubectl get nodes` shows at least one node with status `Ready`
- [ ] You can list pods in the `kube-system` namespace and identify the API server, etcd, scheduler, and controller manager
- [ ] You can explain the structure of `~/.kube/config` (clusters, users, contexts) and switch between contexts
- [ ] You created a multi-node cluster (1 control plane + 2 workers) using a Kind config file and all nodes show `Ready`

## Linux ↔ Kubernetes Cluster Reference

| Linux Concept | Kubernetes Equivalent |
|---|---|
| `/etc/hosts` (host resolution) | `~/.kube/config` (cluster connection config) |
| `ssh user@server` (remote access) | `kubectl` with a context (cluster access) |
| `systemd` services (`systemctl list-units`) | `kube-system` Pods (control plane components) |
| `/var/log/syslog` (system logs) | `kubectl logs -n kube-system <pod>` |
| Network interfaces (`ip addr`) | CNI (Container Network Interface) plugins |
| Boot process (BIOS → GRUB → init) | Cluster bootstrap (Docker → Kind → kubelet → control plane) |

## Hints

<details>
<summary>Hint 1: Install Kind and create your first cluster</summary>

```bash
# Install Kind — pick one method:

# Option A: Download the binary (Linux amd64)
# Check https://kind.sigs.k8s.io/docs/user/quick-start/#installation for latest version
[ $(uname -m) = x86_64 ] && curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.31.0/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind

# Option B: Install with Go
go install sigs.k8s.io/kind@v0.31.0

# Option C: Package managers
# macOS: brew install kind
# Windows: choco install kind

# Verify installation
kind version

# Create your first cluster
kind create cluster --name k8s-lab

# Verify it's running
kubectl cluster-info
kubectl get nodes
```

After creation, Kind automatically configures `kubectl` to point to your new cluster. It's like a Linux installer that not only installs the server but also sets up your SSH keys.

</details>

<details>
<summary>Hint 2: Explore kubeconfig</summary>

The kubeconfig file is your cluster "address book." It contains three key sections:

- **clusters** — where your clusters live (API server addresses + CA certs)
- **users** — credentials to authenticate (like SSH keys)
- **contexts** — bindings of cluster + user + namespace (like SSH config entries)

```bash
# View the full kubeconfig (redacted secrets)
kubectl config view

# List all available contexts
kubectl config get-contexts

# Switch to a specific context
kubectl config use-context kind-k8s-lab

# See the raw file (contains actual certificates and keys)
cat ~/.kube/config
```

**Linux analogy**: This is like your `~/.ssh/config` file — it maps friendly names to connection details so you don't have to type full addresses every time.

</details>

<details>
<summary>Hint 3: Explore the kube-system namespace</summary>

The `kube-system` namespace is where Kubernetes runs its own infrastructure — like the `/usr/lib/systemd/system/` directory where Linux keeps its core service unit files.

```bash
# List all control plane pods
kubectl get pods -n kube-system

# See which node each pod runs on
kubectl get pods -n kube-system -o wide

# Inspect the API server pod in detail
kubectl describe pod -n kube-system -l component=kube-apiserver

# Check logs from etcd (the cluster database)
kubectl logs -n kube-system -l component=etcd

# List ALL resources in kube-system
kubectl get all -n kube-system
```

You should see pods for: `etcd`, `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`, `coredns`, and `kindnet` (Kind's CNI plugin).

</details>

<details>
<summary>Hint 4: Create a multi-node cluster with a config file</summary>

Create a file named `kind-config.yaml`:

```yaml
# kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
```

Then create the cluster:

```bash
# Delete the old single-node cluster first
kind delete cluster --name k8s-lab

# Create the multi-node cluster from the config file
kind create cluster --name k8s-lab --config kind-config.yaml

# Verify all three nodes are Ready
kubectl get nodes

# You should see output like:
# NAME                    STATUS   ROLES           AGE   VERSION
# k8s-lab-control-plane   Ready    control-plane   1m    v1.33.0
# k8s-lab-worker          Ready    <none>          1m    v1.33.0
# k8s-lab-worker2         Ready    <none>          1m    v1.33.0
```

**Linux analogy**: This is like writing an Ansible playbook or a Terraform config to provision multiple servers at once — infrastructure as code instead of manual setup.

</details>

## Learning Resources

- [Kind — Quick Start Guide](https://kind.sigs.k8s.io/docs/user/quick-start/)
- [Kind — Configuration](https://kind.sigs.k8s.io/docs/user/configuration/)
- [Kubernetes Components Overview](https://kubernetes.io/docs/concepts/overview/components/)
- [Organizing Cluster Access with kubeconfig](https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/)
- [Minikube — Getting Started (alternative to Kind)](https://minikube.sigs.k8s.io/docs/start/)

## Break & Fix 🔧

After completing the challenge, try these scenarios to deepen your understanding:

1. **Break the kubeconfig**: Delete (or rename) your `~/.kube/config` file and try running `kubectl get nodes`. What error do you get? How do you recover? *(Hint: `kind export kubeconfig --name k8s-lab` regenerates it — like resetting your SSH keys.)*

2. **Kill the runtime**: Create a cluster, then stop Docker (`sudo systemctl stop docker` on Linux, or quit Docker Desktop). Try `kubectl get nodes`. What happens? What does the cluster look like when you restart Docker? *(This simulates a power outage in your server room.)*

3. **Name collision**: Try creating a cluster with `kind create cluster --name k8s-lab` when one already exists with that name. What error do you get? How do you resolve it? *(Like trying to create a VM with a hostname that's already taken.)*
