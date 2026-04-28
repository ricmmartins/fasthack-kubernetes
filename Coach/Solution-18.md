# Solution 18 — kubeadm Cluster Administration

[< Previous Solution](Solution-17.md) - **[Home](README.md)** - [Next Solution >](Solution-19.md)

---

> **Coach note:** This is the most CKA-critical challenge. It requires real VMs — not Kind or Minikube. Help students choose a lab environment (cloud VMs, Vagrant, or Killercoda). Tasks 1-3 are the core bootstrap sequence. Tasks 4-5 (upgrade + etcd) are the highest-exam-weight topics. Tasks 6-7 are conceptual with hands-on exploration. If time is limited, prioritize Tasks 1-5.

Estimated time: **90–120 minutes**

---

## Task 1: Prepare VM Prerequisites

### Step-by-step (ALL 3 NODES)

> **Coach tip:** Walk through this with students on the control-plane first, then have them repeat on both workers. The most common mistake is forgetting a step on one node.

**Disable swap:**

```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
```

### Verification — Swap disabled

```bash
free -h | grep Swap
```

Expected:

```
Swap:            0B          0B          0B
```

**Load kernel modules:**

```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
```

### Verification — Modules loaded

```bash
lsmod | grep -E "overlay|br_netfilter"
```

Expected (both modules listed):

```
br_netfilter           32768  0
overlay               212992  0
```

**Set sysctl parameters:**

```bash
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

sudo sysctl --system
```

### Verification — Sysctl parameters

```bash
sysctl net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward net.bridge.bridge-nf-call-ip6tables
```

Expected:

```
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-ip6tables = 1
```

**Install and configure containerd:**

```bash
sudo apt-get update
sudo apt-get install -y containerd

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd
```

### Verification — containerd running with systemd cgroup

```bash
sudo systemctl status containerd --no-pager
```

Expected: `Active: active (running)`

```bash
sudo containerd config dump | grep SystemdCgroup
```

Expected:

```
            SystemdCgroup = true
```

> **Coach tip:** The `SystemdCgroup = true` setting is the #1 missed step. If students skip it, kubelet will fail to start with cgroup driver mismatch errors. The symptom is kubelet crashing in a loop — check `journalctl -u kubelet`.

**Install kubeadm, kubelet, kubectl:**

```bash
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet
```

### Verification — Packages installed

```bash
kubeadm version -o short
kubelet --version
kubectl version --client --short 2>/dev/null || kubectl version --client
```

Expected: All show `v1.36.x`.

```bash
apt-mark showhold
```

Expected:

```
kubeadm
kubectl
kubelet
```

> **Coach tip:** If `apt-get install` fails with "package not found", the student likely has the wrong repo URL. Verify with:
> ```bash
> cat /etc/apt/sources.list.d/kubernetes.list
> ```
> It should contain `https://pkgs.k8s.io/core:/stable:/v1.36/deb/`.

---

## Task 2: Initialize the Control Plane

### Step-by-step (CONTROL-PLANE ONLY)

```bash
sudo kubeadm init \
  --pod-network-cidr=192.168.0.0/16 \
  --kubernetes-version=v1.36.0
```

Expected output (end of output):

```
Your Kubernetes control-plane has initialized successfully!

To start using your cluster, you need to run the following as a regular user:

  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

...

Then you can join any number of worker nodes by running the following on each as root:

kubeadm join <IP>:6443 --token <TOKEN> \
        --discovery-token-ca-cert-hash sha256:<HASH>
```

> **Coach tip:** Tell students to **copy and save the `kubeadm join` command immediately**. It's easy to lose in scroll-back. They can also regenerate it later with `kubeadm token create --print-join-command`, but that adds unnecessary troubleshooting time.

**Set up kubeconfig:**

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

### Verification — Control plane running

```bash
kubectl get nodes
```

Expected:

```
NAME            STATUS     ROLES           AGE   VERSION
control-plane   NotReady   control-plane   30s   v1.36.0
```

`NotReady` is correct at this point — no CNI plugin installed yet.

```bash
kubectl get pods -n kube-system
```

Expected (all Running or Pending for coredns):

```
NAME                                    READY   STATUS    RESTARTS   AGE
coredns-xxxxxxxxxx-xxxxx                0/1     Pending   0          30s
coredns-xxxxxxxxxx-xxxxx                0/1     Pending   0          30s
etcd-control-plane                      1/1     Running   0          40s
kube-apiserver-control-plane            1/1     Running   0          40s
kube-controller-manager-control-plane   1/1     Running   0          40s
kube-proxy-xxxxx                        1/1     Running   0          30s
kube-scheduler-control-plane            1/1     Running   0          40s
```

> **Coach tip:** CoreDNS will be Pending until a CNI is installed — this is expected. If `kube-apiserver` or `etcd` aren't Running, check:
> ```bash
> sudo crictl ps
> sudo journalctl -u kubelet --no-pager | tail -30
> ```

---

## Task 3: Install Calico CNI and Join Workers

### Step-by-step

**Install Calico (on control-plane):**

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.0/manifests/calico.yaml
```

### Verification — Calico running

```bash
kubectl get pods -n kube-system -l k8s-app=calico-node --watch
```

Wait until all show `Running` (may take 1-2 minutes), then Ctrl+C.

```bash
kubectl get nodes
```

Expected:

```
NAME            STATUS   ROLES           AGE    VERSION
control-plane   Ready    control-plane   2m     v1.36.0
```

The node should now be `Ready`.

```bash
kubectl get pods -n kube-system
```

CoreDNS should now also be Running.

**Join worker nodes (on each worker):**

```bash
sudo kubeadm join <CONTROL-PLANE-IP>:6443 \
  --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH>
```

Expected output:

```
This node has joined the cluster:
* Certificate signing request was sent to apiserver and a response was received.
* The Kubelet was informed of the new node details.

Run 'kubectl get nodes' on the control-plane node to see this node join the cluster.
```

> **Coach tip:** If the token expired:
> ```bash
> # On control-plane
> kubeadm token create --print-join-command
> ```
> Common mistakes: running `kubeadm join` without `sudo`, or running it on the control-plane instead of the worker.

### Verification — All nodes Ready (on control-plane)

```bash
kubectl get nodes -o wide
```

Expected:

```
NAME            STATUS   ROLES           AGE    VERSION   INTERNAL-IP      OS-IMAGE           KERNEL-VERSION    CONTAINER-RUNTIME
control-plane   Ready    control-plane   5m     v1.36.0   192.168.56.10    Ubuntu 24.04 LTS   6.x.x-xx-generic  containerd://1.7.x
worker-1        Ready    <none>          1m     v1.36.0   192.168.56.11    Ubuntu 24.04 LTS   6.x.x-xx-generic  containerd://1.7.x
worker-2        Ready    <none>          30s    v1.36.0   192.168.56.12    Ubuntu 24.04 LTS   6.x.x-xx-generic  containerd://1.7.x
```

**Test the cluster with a workload:**

```bash
kubectl create deployment nginx-test --image=nginx --replicas=3
kubectl get pods -o wide
```

Pods should be distributed across all 3 nodes.

```bash
kubectl delete deployment nginx-test
```

> **Coach tip:** If workers show `NotReady`, the most likely cause is Calico not deploying on the worker nodes yet. Check:
> ```bash
> kubectl get pods -n kube-system -o wide | grep calico
> ```
> Each node should have a `calico-node` Pod running on it. If a worker's calico-node is in CrashLoopBackOff, check the logs:
> ```bash
> kubectl logs -n kube-system <calico-node-pod-on-worker> -c calico-node
> ```

---

## Task 4: Cluster Upgrade

### Step-by-step

> **Coach tip:** This is the most CKA-relevant task. Students must understand the exact sequence: drain → upgrade kubeadm → `kubeadm upgrade plan/apply` → upgrade kubelet/kubectl → restart kubelet → uncordon. The order matters.

**Check available upgrades (on control-plane):**

```bash
sudo kubeadm upgrade plan
```

Expected output shows current version and available upgrade targets.

> **Coach tip:** If students installed the latest patch already and there's no newer version available, that's OK. Have them practice the drain/uncordon workflow anyway — it's the muscle memory that matters. They can also set up the v1.35 repo initially and upgrade to v1.36 for a real minor version upgrade.

**Upgrade the control-plane:**

```bash
# Step 1: Drain
kubectl drain $(hostname) --ignore-daemonsets --delete-emptydir-data
```

Expected:

```
node/control-plane cordoned
...
node/control-plane drained
```

```bash
# Step 2: Upgrade kubeadm
sudo apt-mark unhold kubeadm
sudo apt-get update
sudo apt-get install -y kubeadm
sudo apt-mark hold kubeadm

# Step 3: Plan and apply
sudo kubeadm upgrade plan
sudo kubeadm upgrade apply v1.36.0
```

Expected (end of output):

```
[upgrade/successful] SUCCESS! Your cluster was upgraded to "v1.36.0". Enjoy!
```

```bash
# Step 4: Upgrade kubelet and kubectl
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet kubectl
sudo apt-mark hold kubelet kubectl

# Step 5: Restart kubelet
sudo systemctl daemon-reload
sudo systemctl restart kubelet

# Step 6: Uncordon
kubectl uncordon $(hostname)
```

### Verification — Control-plane upgraded

```bash
kubectl get nodes
```

The control-plane should show the new version and `Ready` status.

**Upgrade a worker node:**

On the **control-plane**:

```bash
kubectl drain worker-1 --ignore-daemonsets --delete-emptydir-data
```

On **worker-1**:

```bash
sudo apt-mark unhold kubeadm kubelet kubectl
sudo apt-get update
sudo apt-get install -y kubeadm kubelet kubectl
sudo apt-mark hold kubeadm kubelet kubectl

# Workers use "upgrade node" (not "upgrade apply")
sudo kubeadm upgrade node

sudo systemctl daemon-reload
sudo systemctl restart kubelet
```

Back on the **control-plane**:

```bash
kubectl uncordon worker-1
```

> **Coach tip — why `upgrade node` vs `upgrade apply`?**
> - `kubeadm upgrade apply` is for the **first control-plane node** — it upgrades the cluster-wide components (API server, controller manager, scheduler, etcd, CoreDNS).
> - `kubeadm upgrade node` is for **additional control-plane nodes** and **all worker nodes** — it upgrades only the local kubelet configuration.
> This distinction is a common CKA exam question.

### Verification — All nodes upgraded

Repeat for worker-2, then verify:

```bash
kubectl get nodes -o wide
```

All nodes should show the target version.

---

## Task 5: etcd Snapshot and Restore

### Step-by-step

> **Coach tip:** This is the second most CKA-tested topic (after upgrades). Students must memorize the etcdctl syntax with TLS flags. On the exam, they'll need to figure out the cert paths from the etcd Pod manifest.

**Find certificate paths:**

```bash
sudo cat /etc/kubernetes/manifests/etcd.yaml | grep -E "cert-file|key-file|trusted-ca-file"
```

Expected:

```
    - --cert-file=/etc/kubernetes/pki/etcd/server.crt
    - --key-file=/etc/kubernetes/pki/etcd/server.key
    - --peer-cert-file=/etc/kubernetes/pki/etcd/peer.crt
    - --peer-key-file=/etc/kubernetes/pki/etcd/peer.key
    - --trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
```

> **Coach tip:** On the CKA exam, you won't be told the cert paths — you'll need to look them up from the etcd manifest or etcd Pod spec. Teach students to always check `/etc/kubernetes/manifests/etcd.yaml` first.

**Take the snapshot:**

```bash
sudo ETCDCTL_API=3 etcdctl snapshot save /opt/etcd-backup.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
```

Expected:

```
Snapshot saved at /opt/etcd-backup.db
```

### Verification — Snapshot created

```bash
sudo ETCDCTL_API=3 etcdctl snapshot status /opt/etcd-backup.db --write-table
```

Expected (table with hash, revision, total keys, total size):

```
+---------+----------+------------+------------+
|  HASH   | REVISION | TOTAL KEYS | TOTAL SIZE |
+---------+----------+------------+------------+
| 3f8aab2 |     1847 |       1020 |     3.2 MB |
+---------+----------+------------+------------+
```

(Values will vary.)

**Create a test namespace, then delete it (simulating disaster):**

```bash
kubectl create namespace snapshot-test
kubectl get namespace snapshot-test
kubectl delete namespace snapshot-test
kubectl get namespace snapshot-test  # Should say "not found"
```

**Restore from snapshot:**

```bash
# Stop API server and etcd
sudo mv /etc/kubernetes/manifests/etcd.yaml /etc/kubernetes/etcd.yaml.bak
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/kube-apiserver.yaml.bak

# Wait for them to stop
sleep 15

# Remove old data and restore
sudo rm -rf /var/lib/etcd
sudo ETCDCTL_API=3 etcdctl snapshot restore /opt/etcd-backup.db \
  --data-dir=/var/lib/etcd

# Restore static Pod manifests
sudo mv /etc/kubernetes/etcd.yaml.bak /etc/kubernetes/manifests/etcd.yaml
sudo mv /etc/kubernetes/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml
```

### Verification — Restore successful

```bash
# Wait for API server to come back
sleep 60
kubectl get namespace snapshot-test
```

If the snapshot was taken while `snapshot-test` existed, it should be back.

```bash
kubectl get nodes
kubectl get pods -n kube-system
```

The cluster should be fully functional.

> **Coach tip — common restore mistakes:**
> 1. Forgetting to remove `/var/lib/etcd` before restoring — the restore won't overwrite existing data
> 2. Restoring to a different `--data-dir` but not updating the etcd manifest — etcd starts with old data
> 3. Not waiting long enough for the API server to restart — it can take 30-60 seconds
> 4. Forgetting `ETCDCTL_API=3` — etcdctl defaults to API v2, which doesn't support `snapshot`

---

## Task 6: CRDs and Operators

### Step-by-step

**Create the CRD:**

Save `backupschedule-crd.yaml`:

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

Apply:

```bash
kubectl apply -f backupschedule-crd.yaml
```

### Verification — CRD registered

```bash
kubectl get crds | grep fasthack
```

Expected:

```
backupschedules.fasthack.io   2025-xx-xxTxx:xx:xxZ
```

```bash
kubectl api-resources | grep backupschedule
```

Expected:

```
backupschedules   bs   fasthack.io/v1   true   BackupSchedule
```

**Create a custom resource instance:**

Save `my-backup.yaml`:

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

Apply:

```bash
kubectl apply -f my-backup.yaml
```

### Verification — Custom resource created

```bash
kubectl get backupschedules
```

Expected (additionalPrinterColumns in action):

```
NAME                SCHEDULE      RETENTION   TARGET
nightly-db-backup   0 2 * * *     30          production-database
```

```bash
kubectl get bs  # Short name works
kubectl describe backupschedule nightly-db-backup
```

> **Coach tip:** Point out the `additionalPrinterColumns` feature — it's what makes `kubectl get` show useful columns instead of just the name and age. This is how real Operators provide user-friendly output.

**Deploy cert-manager Operator:**

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=120s
```

### Verification — cert-manager running

```bash
kubectl get pods -n cert-manager
```

Expected:

```
NAME                                       READY   STATUS    RESTARTS   AGE
cert-manager-xxxxxxxxx-xxxxx               1/1     Running   0          30s
cert-manager-cainjector-xxxxxxxxx-xxxxx    1/1     Running   0          30s
cert-manager-webhook-xxxxxxxxx-xxxxx       1/1     Running   0          30s
```

```bash
kubectl get crds | grep cert-manager
```

Expected (6+ CRDs):

```
certificaterequests.cert-manager.io    2025-xx-xxTxx:xx:xxZ
certificates.cert-manager.io          2025-xx-xxTxx:xx:xxZ
challenges.acme.cert-manager.io       2025-xx-xxTxx:xx:xxZ
clusterissuers.cert-manager.io        2025-xx-xxTxx:xx:xxZ
issuers.cert-manager.io               2025-xx-xxTxx:xx:xxZ
orders.acme.cert-manager.io           2025-xx-xxTxx:xx:xxZ
```

> **Coach tip — CRDs vs Operators:**
> - A **CRD** just defines a new resource type (schema). By itself, it doesn't do anything — it's like creating a new systemd unit type definition.
> - An **Operator** is a controller (Deployment + RBAC + CRDs) that watches for instances of those custom resources and acts on them. cert-manager watches for `Certificate` resources and actually provisions TLS certificates.
> - The BackupSchedule CRD we created has no Operator watching it — creating instances does nothing. In production, you'd write (or install) a controller that watches BackupSchedule resources and triggers actual backups.

---

## Task 7: Extension Interfaces (CNI, CSI, CRI)

### Step-by-step

**Identify CRI:**

```bash
kubectl get nodes -o wide
```

Look at the `CONTAINER-RUNTIME` column — should show `containerd://1.7.x`.

```bash
sudo cat /var/lib/kubelet/kubeadm-flags.env
```

Expected (contains the CRI socket path):

```
KUBELET_KUBEADM_ARGS="--container-runtime-endpoint=unix:///var/run/containerd/containerd.sock ..."
```

**Identify CNI:**

```bash
ls /etc/cni/net.d/
```

Expected:

```
10-calico.conflist  calico-kubeconfig
```

```bash
cat /etc/cni/net.d/10-calico.conflist | head -20
```

Shows the Calico CNI configuration with type `calico` and IPAM settings.

```bash
kubectl get pods -n kube-system -l k8s-app=calico-node -o wide
```

Expected: One `calico-node` Pod per node (DaemonSet).

**Explore CSI:**

```bash
kubectl get csidrivers
```

Expected on a bare kubeadm cluster:

```
No resources found
```

```bash
kubectl get storageclasses
```

Expected: Empty or `No resources found` — a bare kubeadm cluster doesn't come with a CSI driver or StorageClass.

> **Coach tip:** This is a great teaching moment:
> - **Kind/Minikube** come with a built-in storage provisioner — that's why PVCs "just work" in those environments.
> - **kubeadm** gives you a bare cluster — you must install a CSI driver for dynamic provisioning.
> - On cloud providers, the CSI driver is usually pre-installed (aws-ebs-csi, azuredisk-csi, gce-pd-csi).
> - For bare metal, options include `nfs-subdir-external-provisioner`, `local-path-provisioner`, or `longhorn`.

**Linux kernel module comparison:**

```bash
# Linux modules — extend the kernel
lsmod | head -10
modinfo br_netfilter

# Kubernetes CRI — extend container runtime support
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.containerRuntimeVersion}{"\n"}{end}'

# Kubernetes CNI — extend networking
kubectl get ds -n kube-system

# Kubernetes CSI — extend storage (none installed on bare kubeadm)
kubectl get csidrivers
```

> **Coach reference — Extension Interface Summary:**
>
> | Interface | Purpose | Linux Analogy | Our Cluster | Alternatives |
> |---|---|---|---|---|
> | **CRI** | Container runtime | PAM modules | containerd | CRI-O |
> | **CNI** | Pod networking | Kernel network modules | Calico | Cilium, Flannel, Weave |
> | **CSI** | Persistent storage | Block device drivers | (none) | aws-ebs-csi, nfs-csi, longhorn |

---

## Break & Fix Solutions

### Scenario 1: kubeadm init fails — swap not disabled

**Diagnosis path for students:**

```bash
# Read the error message carefully — it says "Swap"
free -h | grep Swap
# If Swap total > 0, swap is on
```

**Solution:**

```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
# Retry kubeadm init
sudo kubeadm init --pod-network-cidr=192.168.0.0/16
```

> **Coach tip:** The preflight error is very clear. This scenario teaches students to read error messages carefully rather than immediately googling.

---

### Scenario 2: Worker node can't join — bad CA cert hash

**Diagnosis path for students:**

```bash
# The error message mentions "certificate authority" or "unable to fetch kubeadm-config"
# Compare the hash they used with the real one:
openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | \
  openssl rsa -pubin -outform der 2>/dev/null | \
  openssl dgst -sha256 -hex | sed 's/^.* //'
```

**Solution:**

```bash
# On the control-plane, regenerate the join command
kubeadm token create --print-join-command
# Copy the full output and run it on the worker
```

> **Coach tip:** This teaches the security model — `kubeadm join` validates the API server's identity via the CA cert hash. It's the Kubernetes equivalent of SSH host key verification.

---

### Scenario 3: etcd restore — namespace not coming back

**Diagnosis path for students:**

```bash
# Check where etcd looks for its data
sudo grep "data-dir" /etc/kubernetes/manifests/etcd.yaml
# Compare with where the restore went
ls -la /var/lib/etcd*
```

**Solution:**

```bash
# Either restore to the correct directory:
sudo rm -rf /var/lib/etcd
sudo ETCDCTL_API=3 etcdctl snapshot restore /opt/etcd-backup.db \
  --data-dir=/var/lib/etcd

# Or update the etcd manifest:
sudo sed -i 's|/var/lib/etcd|/var/lib/etcd-new|g' /etc/kubernetes/manifests/etcd.yaml
```

> **Coach tip:** This is a realistic CKA scenario. The key insight: `--data-dir` in the restore command must match what etcd is configured to use. Always check the static Pod manifest.

---

### Scenario 4: CRD instance rejected — schema validation

**Diagnosis path for students:**

```bash
# The error message says "must be of type integer"
# Look at the YAML — retentionDays: "thirty" is a string
kubectl get crd backupschedules.fasthack.io -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.retentionDays}'
# Shows: {"type":"integer"}
```

**Solution:** Fix the YAML to use `retentionDays: 30` (integer, not string).

> **Coach tip:** CRD schema validation is enforced server-side. Unlike plain ConfigMaps where any string goes, CRDs enforce type safety. This is a feature, not a bug — it catches errors early, just like type checking in systemd unit files.

---

## Coach Quick Reference — Key Commands Cheat Sheet

```bash
# Bootstrap
kubeadm init --pod-network-cidr=192.168.0.0/16
kubeadm token create --print-join-command
kubeadm join <IP>:6443 --token <TOKEN> --discovery-token-ca-cert-hash sha256:<HASH>

# Upgrade sequence (MEMORIZE for CKA)
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
# ... upgrade packages ...
sudo kubeadm upgrade apply v1.36.x    # first control-plane
sudo kubeadm upgrade node              # additional CP + workers
sudo systemctl daemon-reload && sudo systemctl restart kubelet
kubectl uncordon <node>

# etcd backup/restore (MEMORIZE for CKA)
ETCDCTL_API=3 etcdctl snapshot save /opt/backup.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

ETCDCTL_API=3 etcdctl snapshot restore /opt/backup.db --data-dir=/var/lib/etcd

# CRDs
kubectl get crds
kubectl api-resources | grep <group>
kubectl get <custom-resource>

# Extensions
kubectl get nodes -o wide                    # CRI info
ls /etc/cni/net.d/                           # CNI config
kubectl get csidrivers                       # CSI drivers
```
