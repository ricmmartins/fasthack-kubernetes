# Challenge 18 — kubeadm Cluster Administration

[< Previous Challenge](Challenge-17.md) - **[Home](../README.md)** - [Next Challenge >](Challenge-19.md)

## Introduction

On a Linux server, building a highly available service from scratch means bootstrapping cluster software: you run `pacemaker` or `corosync` to initialize the first node, then `pcs cluster node add` to join additional members. You take periodic backups with `pg_dump` or LVM snapshots, and when it's time to upgrade, you drain connections with `systemctl isolate maintenance.target`, run `apt upgrade`, then bring the node back online. You extend system capabilities by writing custom `systemd` unit types and loading kernel modules (`modprobe`) for new hardware or network drivers.

Kubernetes has direct equivalents for every one of these operations. `kubeadm init` bootstraps the control plane (like Pacemaker's initial setup), `kubeadm join` adds workers (like adding cluster members), `etcdctl snapshot save` creates database backups (like `pg_dump`), and the upgrade cycle of drain → upgrade → uncordon mirrors a maintenance window. Custom Resource Definitions (CRDs) extend the API like custom systemd unit types, while Container Network Interface (CNI), Container Storage Interface (CSI), and Container Runtime Interface (CRI) are plugin architectures — the Kubernetes equivalent of Linux's loadable kernel modules or PAM modules.

In this challenge you will build a Kubernetes cluster from scratch with `kubeadm`, manage its lifecycle, and explore how it's extended.

| Linux Pattern | Kubernetes Pattern |
|---|---|
| `pacemaker` / `corosync` cluster init | `kubeadm init` — bootstrap the control plane |
| `pcs cluster node add` | `kubeadm join` — add worker nodes |
| `apt upgrade` with maintenance windows | `kubeadm upgrade` — drain, upgrade, uncordon |
| `pg_dump` / LVM snapshots | `etcdctl snapshot save` — etcd backups |
| Pacemaker HA with `keepalived` / VIP | Multiple control-plane nodes (stacked or external etcd) |
| Custom `systemd` unit types | Custom Resource Definitions (CRDs) and Operators |
| `modprobe` / loadable kernel modules / PAM | CNI, CSI, CRI — extension plugin interfaces |

---

## ⚠️ Lab Environment — VMs Required (Not Kind)

This challenge requires **real virtual machines** — not Kind or Minikube. You need a multi-node cluster with actual kubelet processes, systemd services, and etcd running on disk. Choose one of the options below:

### Option A: Cloud VMs (Any Provider)

Provision **3 Ubuntu 24.04 LTS VMs** (2 vCPU, 2 GB RAM minimum each) on any cloud provider (Azure, AWS, GCP, DigitalOcean, etc.). Ensure:
- All VMs can communicate over a private network
- Ports 6443 (API server), 2379-2380 (etcd), 10250 (kubelet) are open between nodes
- You have SSH access and `sudo` privileges

Name them:
- `control-plane` (1 node)
- `worker-1`, `worker-2` (2 nodes)

### Option B: Vagrant with VirtualBox

Save this as `Vagrantfile` and run `vagrant up`:

```ruby
Vagrant.configure("2") do |config|
  config.vm.box = "bento/ubuntu-24.04"

  nodes = [
    { name: "control-plane", ip: "192.168.56.10" },
    { name: "worker-1",      ip: "192.168.56.11" },
    { name: "worker-2",      ip: "192.168.56.12" },
  ]

  nodes.each do |node|
    config.vm.define node[:name] do |n|
      n.vm.hostname = node[:name]
      n.vm.network "private_network", ip: node[:ip]
      n.vm.provider "virtualbox" do |vb|
        vb.memory = 2048
        vb.cpus   = 2
      end
    end
  end
end
```

Then SSH into each node: `vagrant ssh control-plane`, `vagrant ssh worker-1`, etc.

### Option C: Killercoda Playground (Free, Browser-Based)

Use the free Kubernetes playground at [killercoda.com/playgrounds/scenario/kubernetes](https://killercoda.com/playgrounds/scenario/kubernetes). It provides a pre-built 2-node cluster (1 control-plane + 1 worker). You can practice Tasks 4–7 directly. For Tasks 1–3 (bootstrap from scratch), use the [Ubuntu playground](https://killercoda.com/playgrounds/scenario/ubuntu) and install everything yourself.

> **Note:** Killercoda sessions expire after ~60 minutes. Save your work and be prepared to restart if needed.

---

## Description

### Task 1 — Prepare VM Prerequisites

Before running `kubeadm init`, every node must be prepared — exactly like pre-flight checks before setting up Pacemaker. On Linux you'd run `swapoff -a`, load kernel modules, and install packages. Kubernetes is the same.

**Run all steps below on ALL 3 nodes** (control-plane, worker-1, worker-2).

**Step 1:** Disable swap (Kubernetes requires swap off, like how some cluster filesystems require it):

```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
```

**Step 2:** Load the required kernel modules (like `modprobe` for network drivers):

```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
```

**Step 3:** Set required sysctl parameters (like enabling IP forwarding for a Linux router):

```bash
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

sudo sysctl --system
```

**Step 4:** Install containerd (the Container Runtime Interface implementation):

```bash
sudo apt-get update
sudo apt-get install -y containerd
```

**Step 5:** Configure containerd to use the systemd cgroup driver (required for Kubernetes):

```bash
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd
```

**Step 6:** Install kubeadm, kubelet, and kubectl:

```bash
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

**Step 7:** Enable and start kubelet:

```bash
sudo systemctl enable --now kubelet
```

> **Why `apt-mark hold`?** This prevents `apt upgrade` from accidentally updating Kubernetes components — just like pinning a critical package version on a production Linux server.

### Task 2 — Initialize the Control Plane with `kubeadm init`

This is the equivalent of running `pacemaker` or `corosync` setup for the first time — the moment your cluster comes alive.

**Run on the control-plane node only.**

**Step 1:** Initialize the cluster with the pod network CIDR that Calico expects:

```bash
sudo kubeadm init \
  --pod-network-cidr=192.168.0.0/16 \
  --kubernetes-version=v1.36.0
```

> **Important:** Save the `kubeadm join` command from the output — you'll need it for Task 3.

**Step 2:** Set up your kubeconfig (as a regular user):

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

**Step 3:** Verify the control plane is running:

```bash
kubectl get nodes
kubectl get pods -n kube-system
```

The node should appear as `NotReady` (no CNI plugin yet) and you should see `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`, and `etcd` Pods running.

### Task 3 — Install Calico CNI and Join Worker Nodes

Installing a CNI plugin is like loading a kernel network module — it provides the networking foundation. Joining workers is like `pcs cluster node add` in Pacemaker.

**Step 1:** Install Calico CNI on the **control-plane** node:

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.0/manifests/calico.yaml
```

**Step 2:** Wait for all Calico Pods to be ready:

```bash
kubectl get pods -n kube-system -l k8s-app=calico-node --watch
```

Once all Pods show `Running`, the control-plane node should become `Ready`:

```bash
kubectl get nodes
```

**Step 3:** Join the worker nodes. On **each worker** (worker-1 and worker-2), run the `kubeadm join` command from the `kubeadm init` output:

```bash
sudo kubeadm join <CONTROL-PLANE-IP>:6443 \
  --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH>
```

> **If the token expired** (tokens are valid for 24 hours), generate a new one on the control-plane:
> ```bash
> kubeadm token create --print-join-command
> ```

**Step 4:** Verify all nodes are Ready (back on the control-plane):

```bash
kubectl get nodes -o wide
```

You should see all 3 nodes in `Ready` status with containerd as the runtime.

### Task 4 — Cluster Upgrade with kubeadm

Upgrading a Kubernetes cluster follows the same discipline as upgrading a Linux HA cluster: drain the node (take it out of rotation), upgrade packages, verify, then bring it back online (uncordon).

We'll simulate upgrading from the current patch version to the next available patch. If you installed `v1.36.0`, you'll upgrade to the latest `v1.36.x` patch.

**Step 1:** Check what upgrade is available (on the control-plane):

```bash
sudo kubeadm upgrade plan
```

**Step 2:** Upgrade the control-plane node:

```bash
# Drain the control-plane (allow DaemonSets to stay)
kubectl drain $(hostname) --ignore-daemonsets --delete-emptydir-data

# Unhold packages, upgrade kubeadm
sudo apt-mark unhold kubeadm
sudo apt-get update
sudo apt-get install -y kubeadm
sudo apt-mark hold kubeadm

# Check the plan and apply the upgrade
sudo kubeadm upgrade plan
sudo kubeadm upgrade apply v1.36.0  # Replace with the version shown by 'kubeadm upgrade plan'

# Upgrade kubelet and kubectl
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet kubectl
sudo apt-mark hold kubelet kubectl

# Restart kubelet
sudo systemctl daemon-reload
sudo systemctl restart kubelet

# Uncordon the control-plane
kubectl uncordon $(hostname)
```

> **Note:** Replace `v1.36.0` with the target version shown by `kubeadm upgrade plan`. If you're already on the latest patch, you can still practice the drain/uncordon workflow — the `kubeadm upgrade apply` will simply confirm you're at the latest version.

**Step 3:** Upgrade a worker node. On the **control-plane**, drain the worker:

```bash
kubectl drain worker-1 --ignore-daemonsets --delete-emptydir-data
```

On **worker-1**, upgrade packages:

```bash
sudo apt-mark unhold kubeadm kubelet kubectl
sudo apt-get update
sudo apt-get install -y kubeadm kubelet kubectl
sudo apt-mark hold kubeadm kubelet kubectl

sudo kubeadm upgrade node
sudo systemctl daemon-reload
sudo systemctl restart kubelet
```

Back on the **control-plane**, uncordon:

```bash
kubectl uncordon worker-1
```

**Step 4:** Repeat for worker-2, then verify:

```bash
kubectl get nodes -o wide
```

All nodes should show the upgraded version.

### Task 5 — etcd Snapshot and Restore

etcd is Kubernetes' brain — like a PostgreSQL database for your cluster state. Backing it up is like running `pg_dump` or taking an LVM snapshot before a risky change.

**Run on the control-plane node.**

**Step 1:** Find your etcd certificates (check the etcd static Pod manifest):

```bash
sudo cat /etc/kubernetes/manifests/etcd.yaml | grep -E "cert-file|key-file|trusted-ca-file"
```

**Step 2:** Take an etcd snapshot:

```bash
sudo ETCDCTL_API=3 etcdctl snapshot save /opt/etcd-backup.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
```

**Step 3:** Verify the snapshot:

```bash
sudo ETCDCTL_API=3 etcdctl snapshot status /opt/etcd-backup.db --write-table
```

You should see the snapshot hash, revision, total keys, and total size.

**Step 4:** Simulate a disaster — create a test namespace, then delete it:

```bash
kubectl create namespace snapshot-test
kubectl get namespace snapshot-test
kubectl delete namespace snapshot-test
```

**Step 5:** Restore from the snapshot:

```bash
# Stop the API server and etcd (move their static Pod manifests)
sudo mv /etc/kubernetes/manifests/etcd.yaml /etc/kubernetes/etcd.yaml.bak
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/kube-apiserver.yaml.bak

# Remove the old etcd data
sudo rm -rf /var/lib/etcd

# Restore from the snapshot
sudo ETCDCTL_API=3 etcdctl snapshot restore /opt/etcd-backup.db \
  --data-dir=/var/lib/etcd

# Restore the static Pod manifests
sudo mv /etc/kubernetes/etcd.yaml.bak /etc/kubernetes/manifests/etcd.yaml
sudo mv /etc/kubernetes/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml
```

**Step 6:** Wait for the API server and etcd to restart, then verify the restored namespace:

```bash
# Wait for the API server to come back (may take 30-60 seconds)
sleep 60
kubectl get namespace snapshot-test
```

If the snapshot was taken while `snapshot-test` existed, it should be back. If it was taken before you created it, it won't appear — confirming the restore worked.

> **CKA Exam tip:** etcd backup and restore is a heavily tested topic. Memorize the certificate paths and the exact `etcdctl snapshot save/restore` syntax.

### Task 6 — Custom Resource Definitions (CRDs) and Operators

CRDs let you extend the Kubernetes API with custom resource types — like creating a new systemd unit type (`.service`, `.timer`, `.mount`) so that `systemctl` understands a new kind of workload. Operators are controllers that watch these custom resources and act on them — like a custom systemd generator.

**Step 1:** Create a CRD for a custom `BackupSchedule` resource. Save as `backupschedule-crd.yaml`:

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: backupschedules.fasthack.io
spec:
  group: fasthack.io
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                schedule:
                  type: string
                retentionDays:
                  type: integer
                target:
                  type: string
      additionalPrinterColumns:
        - name: Schedule
          type: string
          jsonPath: .spec.schedule
        - name: Retention
          type: integer
          jsonPath: .spec.retentionDays
        - name: Target
          type: string
          jsonPath: .spec.target
  scope: Namespaced
  names:
    plural: backupschedules
    singular: backupschedule
    kind: BackupSchedule
    shortNames:
      - bs
```

**Step 2:** Apply the CRD and verify:

```bash
kubectl apply -f backupschedule-crd.yaml
kubectl get crds | grep fasthack
kubectl api-resources | grep backupschedule
```

**Step 3:** Create a custom resource instance. Save as `my-backup.yaml`:

```yaml
apiVersion: fasthack.io/v1
kind: BackupSchedule
metadata:
  name: nightly-db-backup
spec:
  schedule: "0 2 * * *"
  retentionDays: 30
  target: production-database
```

```bash
kubectl apply -f my-backup.yaml
kubectl get backupschedules
kubectl get bs
kubectl describe backupschedule nightly-db-backup
```

**Step 4:** Deploy a real-world Operator — install **cert-manager**, which uses CRDs to manage TLS certificates:

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

# Wait for cert-manager pods to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=120s
```

**Step 5:** Explore the CRDs that cert-manager installed:

```bash
kubectl get crds | grep cert-manager
kubectl api-resources | grep cert-manager
```

You should see CRDs like `certificates.cert-manager.io`, `issuers.cert-manager.io`, `clusterissuers.cert-manager.io`, etc. These are new "API types" that the cert-manager Operator watches and acts on — just like how systemd's `timerd` watches `.timer` unit files.

### Task 7 — Explore Extension Interfaces (CNI, CSI, CRI)

Kubernetes has a plugin architecture for networking, storage, and container runtimes — similar to how Linux uses loadable kernel modules (`modprobe`), PAM modules (`/etc/pam.d/`), and NSS modules (`/etc/nsswitch.conf`) to extend core functionality without modifying the kernel.

**Step 1:** Identify the Container Runtime Interface (CRI) in use:

```bash
kubectl get nodes -o wide
# Look at the CONTAINER-RUNTIME column

# Check the kubelet's CRI socket
sudo cat /var/lib/kubelet/kubeadm-flags.env
```

**Step 2:** Identify the Container Network Interface (CNI) plugin:

```bash
# List installed CNI plugins
ls /etc/cni/net.d/
cat /etc/cni/net.d/*.conflist 2>/dev/null || cat /etc/cni/net.d/*.conf 2>/dev/null

# Check which CNI pods are running
kubectl get pods -n kube-system -l k8s-app=calico-node
```

**Step 3:** Explore CSI (Container Storage Interface) — list any CSI drivers installed:

```bash
kubectl get csidrivers
kubectl get storageclasses
```

On a bare kubeadm cluster you may not have a CSI driver yet — that's expected. In production, you'd install one (like `csi-driver-nfs`, `aws-ebs-csi-driver`, or `azuredisk-csi-driver`).

**Step 4:** Understand how these interfaces compare to Linux kernel modules:

```bash
# Linux kernel modules — modular extensions to the kernel
lsmod | head -10

# Kubernetes extensions — modular interfaces for runtime, network, storage
kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.containerRuntimeVersion}'
echo ""
kubectl get pods -n kube-system -o custom-columns="NAME:.metadata.name,IMAGE:.spec.containers[0].image" | grep -E "calico|coredns|etcd"
```

### Clean Up

If using Vagrant:

```bash
vagrant destroy -f
```

If using cloud VMs, delete them through your provider's console or CLI.

If you want to tear down only the Kubernetes cluster (keep the VMs):

```bash
# On workers
sudo kubeadm reset -f

# On control-plane
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d $HOME/.kube
```

## Success Criteria

- [ ] All 3 nodes have swap disabled, kernel modules loaded (`overlay`, `br_netfilter`), and sysctl parameters set.
- [ ] containerd is installed, running, and configured with `SystemdCgroup = true`.
- [ ] kubeadm, kubelet, and kubectl are installed and held at the correct version.
- [ ] `kubeadm init` successfully bootstrapped the control-plane with `--pod-network-cidr=192.168.0.0/16`.
- [ ] Calico CNI is installed and all Calico Pods are Running.
- [ ] Both workers joined the cluster with `kubeadm join` and all 3 nodes show `Ready`.
- [ ] You performed a drain → upgrade → uncordon cycle on at least one node.
- [ ] You can explain why `kubeadm upgrade apply` is used on the first control-plane and `kubeadm upgrade node` on additional nodes and workers.
- [ ] An etcd snapshot was saved with `etcdctl snapshot save` and verified with `etcdctl snapshot status`.
- [ ] You successfully restored from the etcd snapshot and verified the cluster state.
- [ ] A custom CRD (`BackupSchedule`) was created and you can `kubectl get backupschedules`.
- [ ] cert-manager Operator was deployed and you can list its CRDs.
- [ ] You identified the CRI (containerd), CNI (Calico), and checked for CSI drivers on your cluster.
- [ ] You can explain how CNI/CSI/CRI are like Linux's loadable kernel modules — pluggable interfaces that extend functionality.

## Linux ↔ Kubernetes Reference

| Linux Concept | Kubernetes Equivalent | Notes |
|---|---|---|
| `pacemaker` / `corosync-cfgtool -s` | `kubeadm init` | Bootstrap the first control-plane node |
| `pcs cluster node add <node>` | `kubeadm join --token <token>` | Add worker or control-plane nodes to the cluster |
| `apt upgrade` with `systemctl isolate maintenance.target` | `kubectl drain` → `kubeadm upgrade` → `kubectl uncordon` | Maintenance window pattern for rolling upgrades |
| `pg_dump` / `lvcreate --snapshot` | `etcdctl snapshot save` | Point-in-time backup of cluster state |
| `pg_restore` / `lvconvert --merge` | `etcdctl snapshot restore` | Disaster recovery from backup |
| Pacemaker HA with `keepalived` + VIP | Multiple `--control-plane-endpoint` nodes | HA control plane with load-balanced API server |
| Custom `systemd` unit type (`.service`, `.timer`) | Custom Resource Definition (CRD) | Extend the API with new resource types |
| `systemd` generators / `systemd-run` | Operators (controllers that watch CRDs) | Automate actions when custom resources change |
| `modprobe <driver>` — loadable kernel modules | CNI plugins (Calico, Cilium, Flannel) | Pluggable container networking |
| PAM modules (`/etc/pam.d/`) | CRI implementations (containerd, CRI-O) | Pluggable container runtimes |
| NSS modules (`/etc/nsswitch.conf`) | CSI drivers (EBS, Azure Disk, NFS) | Pluggable storage interfaces |
| `apt-mark hold <package>` | `apt-mark hold kubeadm kubelet kubectl` | Prevent accidental package upgrades |
| `swapoff -a` + edit `/etc/fstab` | Same — Kubernetes requires swap disabled | K8s prerequisite since v1.22 |

## Hints

<details>
<summary>Hint 1: kubeadm init fails with preflight errors</summary>

Check common preflight issues:

```bash
# Verify swap is off
free -h | grep Swap

# Verify kernel modules are loaded
lsmod | grep br_netfilter
lsmod | grep overlay

# Verify containerd is running
sudo systemctl status containerd

# Verify the cgroup driver is systemd
sudo containerd config dump | grep SystemdCgroup
```

If you see `[ERROR NumCPU]: the number of available CPUs 1 is less than the required 2`, your VM needs at least 2 CPUs.

</details>

<details>
<summary>Hint 2: Nodes stuck in NotReady after kubeadm join</summary>

`NotReady` usually means the CNI plugin isn't installed or isn't working:

```bash
kubectl get pods -n kube-system -l k8s-app=calico-node
kubectl describe node <node-name> | grep -A5 Conditions
```

If Calico Pods are in `CrashLoopBackOff`, check that the `--pod-network-cidr` used in `kubeadm init` matches Calico's expected CIDR (`192.168.0.0/16`).

</details>

<details>
<summary>Hint 3: kubeadm join token expired</summary>

Tokens expire after 24 hours by default. Create a new one on the control-plane:

```bash
kubeadm token create --print-join-command
```

This outputs a full `kubeadm join` command with a fresh token and the correct CA cert hash.

</details>

<details>
<summary>Hint 4: etcdctl not found or connection refused</summary>

`etcdctl` may not be installed as a standalone binary. You can run it from the etcd container:

```bash
sudo crictl ps | grep etcd
```

Or install it directly:

```bash
ETCD_VER=v3.5.21
curl -fsSL https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz | \
  sudo tar xz -C /usr/local/bin --strip-components=1 etcd-${ETCD_VER}-linux-amd64/etcdctl
```

Always set `ETCDCTL_API=3` before running commands.

</details>

<details>
<summary>Hint 5: etcd restore — API server won't come back</summary>

After restoring etcd, the API server may take 30-60 seconds to restart. If it doesn't:

```bash
# Check if static Pod manifests are back
ls /etc/kubernetes/manifests/

# Check kubelet logs
sudo journalctl -u kubelet --no-pager --since "5 minutes ago" | tail -30

# Force kubelet restart
sudo systemctl restart kubelet
```

Make sure you restored to `/var/lib/etcd` (the default data directory). If you used a different `--data-dir`, you need to update the etcd static Pod manifest to point to it.

</details>

<details>
<summary>Hint 6: CRD not showing in api-resources</summary>

Wait a few seconds after applying the CRD — the API server needs to process it:

```bash
kubectl get crds
kubectl api-resources | grep backupschedule
```

If the CRD has validation errors, check:

```bash
kubectl describe crd backupschedules.fasthack.io
```

Ensure `apiVersion: apiextensions.k8s.io/v1` (not `v1beta1`, which is removed since K8s 1.22).

</details>

<details>
<summary>Hint 7: What's the difference between stacked and external etcd?</summary>

**Stacked etcd** (default for kubeadm): etcd runs on each control-plane node as a static Pod. Simpler to set up but a node failure takes down both a control-plane member and an etcd member.

**External etcd**: etcd runs on separate dedicated nodes. More resilient — losing a control-plane node doesn't affect etcd quorum — but more complex to manage.

For the CKA exam, know both topologies. `kubeadm init --config` with `etcd.external` configures external etcd.

</details>

## Learning Resources

- [Creating a cluster with kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/)
- [kubeadm init reference](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-init/)
- [kubeadm join reference](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-join/)
- [Upgrading kubeadm clusters](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/)
- [Operating etcd — backup and restore](https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/#snapshot-backup-and-restore)
- [Creating Highly Available clusters with kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/)
- [CustomResourceDefinitions (CRDs)](https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/)
- [Extend the Kubernetes API with CRDs](https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/)
- [Container Runtime Interface (CRI)](https://kubernetes.io/docs/concepts/architecture/cri/)
- [Network Plugins (CNI)](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/)
- [Container Storage Interface (CSI)](https://kubernetes.io/docs/concepts/storage/volumes/#csi)
- [Calico quickstart](https://docs.tigera.io/calico/latest/getting-started/kubernetes/quickstart)
- [cert-manager documentation](https://cert-manager.io/docs/)
- [CKA Curriculum](https://github.com/cncf/curriculum)

## Break & Fix 🔧

Try each scenario, diagnose the problem, and fix it.

### Scenario 1 — kubeadm init fails: swap not disabled

On a fresh VM, run:

```bash
sudo kubeadm init --pod-network-cidr=192.168.0.0/16
```

**What you'll see:** Preflight error: `[ERROR Swap]: running with swap on is not supported. Please disable swap`.

**Diagnose:**

```bash
free -h | grep Swap
cat /etc/fstab | grep swap
```

**Root cause:** Swap is still enabled. The `kubeadm init` preflight check rejects nodes with active swap because the kubelet's memory management doesn't account for swapped-out pages.

**Fix:**

```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
```

Then retry `kubeadm init`.

**Linux analogy:** It's like an Oracle database installer refusing to proceed because `vm.swappiness` is too high — some clustered software has hard requirements about memory management.

---

### Scenario 2 — Worker node can't join: bad CA cert hash

On a worker, run:

```bash
sudo kubeadm join 192.168.56.10:6443 \
  --token abcdef.1234567890abcdef \
  --discovery-token-ca-cert-hash sha256:0000000000000000000000000000000000000000000000000000000000000000
```

**What you'll see:** `error execution phase preflight: unable to fetch the kubeadm-config ConfigMap` or `certificate authority hash does not match`.

**Diagnose:**

```bash
# On the control-plane, check the real hash
openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | \
  openssl rsa -pubin -outform der 2>/dev/null | \
  openssl dgst -sha256 -hex | sed 's/^.* //'
```

**Root cause:** The CA certificate hash doesn't match. This is a security feature — it prevents a man-in-the-middle from impersonating the control-plane. You either copied the hash wrong or the control-plane was re-initialized.

**Fix:** Generate a fresh join command on the control-plane:

```bash
kubeadm token create --print-join-command
```

Use the output (which has both a valid token and the correct hash) on the worker.

**Linux analogy:** It's like SSH host key verification failing — `ssh-keygen -R host` followed by re-connecting. The fingerprint must match.

---

### Scenario 3 — etcd restore doesn't bring back the deleted namespace

After taking a snapshot and deleting a namespace, you restore:

```bash
sudo ETCDCTL_API=3 etcdctl snapshot restore /opt/etcd-backup.db \
  --data-dir=/var/lib/etcd-new
```

But the cluster still shows the namespace as deleted.

**Diagnose:**

```bash
# Check which data directory etcd is actually using
sudo grep -i "data-dir" /etc/kubernetes/manifests/etcd.yaml
```

**Root cause:** You restored to `/var/lib/etcd-new` but the etcd static Pod is still configured to use `/var/lib/etcd`. The restored data is sitting unused.

**Fix:** Either:

a) Restore to the correct directory:

```bash
sudo rm -rf /var/lib/etcd
sudo ETCDCTL_API=3 etcdctl snapshot restore /opt/etcd-backup.db \
  --data-dir=/var/lib/etcd
```

b) Or update the etcd static Pod manifest to use the new directory:

```bash
sudo sed -i 's|/var/lib/etcd|/var/lib/etcd-new|g' /etc/kubernetes/manifests/etcd.yaml
```

**Linux analogy:** It's like restoring a PostgreSQL dump to `/var/lib/postgresql/restored/` but PostgreSQL's `data_directory` still points to `/var/lib/postgresql/14/main/` — the restore is there but the service doesn't see it.

---

### Scenario 4 — CRD instance rejected: schema validation fails

Apply this BackupSchedule (assuming the CRD from Task 6 is installed):

```yaml
# Save as broken-backup.yaml
apiVersion: fasthack.io/v1
kind: BackupSchedule
metadata:
  name: broken-backup
spec:
  schedule: "0 3 * * *"
  retentionDays: "thirty"
  target: staging-db
```

```bash
kubectl apply -f broken-backup.yaml
```

**What you'll see:** `error: .spec.retentionDays: Invalid value: "string": spec.retentionDays in body must be of type integer`.

**Root cause:** The CRD schema defines `retentionDays` as `type: integer`, but the YAML provides a string `"thirty"`. Kubernetes API server enforces the OpenAPIV3 schema on CRD instances.

**Fix:** Use an integer value:

```yaml
  retentionDays: 30
```

**Linux analogy:** It's like a systemd unit file failing validation because `TimeoutStartSec=thirty` isn't a valid time format — systemd expects a number or time expression like `30s`.
