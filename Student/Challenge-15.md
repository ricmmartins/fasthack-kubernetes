# Challenge 15 — Pod Scheduling & Resource Management

[< Previous Challenge](Challenge-14.md) - **[Home](../README.md)** - [Next Challenge >](Challenge-16.md)

## Introduction

On a Linux server, you control *where* and *how* processes run using tools like `taskset` (pin a process to specific CPUs), `cgroups` (limit CPU and memory), `ulimit` (cap resources per user), and `nice`/`ionice` (set scheduling priority). When you manage multiple machines, you decide which server runs which workload — maybe the database goes on the box with SSDs, or you keep two replicas of a web server on different physical hosts so a single hardware failure doesn't take everything down.

Kubernetes automates all of these decisions through its **scheduler**. Instead of SSH-ing into machines and placing workloads manually, you declare *rules* — "this Pod needs a GPU node," "keep these two Pods apart," "never put more than 2 replicas on the same node," "this namespace can't use more than 4 CPUs total." The scheduler reads your rules and the current cluster state, then places Pods accordingly.

In this challenge you will master the full scheduling and resource management toolkit: **taints & tolerations** (node-level repellents), **node affinity** (attracting Pods to nodes), **Pod affinity & anti-affinity** (co-locating or separating Pods), **topology spread constraints** (even distribution), **static Pods** (kubelet-managed Pods), **ResourceQuotas & LimitRanges** (namespace-level resource caps), and **PodDisruptionBudgets** (maintenance safety nets).

> **Cluster requirement:** This challenge requires a **3-node Kind cluster** (1 control-plane + 2 workers) so that scheduling exercises work correctly. Follow Task 0 below to create one.

## Description

### Task 0 — Create a 3-Node Kind Cluster

For scheduling exercises to be meaningful, you need multiple worker nodes. Create a Kind cluster with 1 control-plane and 2 workers.

Save this as `kind-scheduling.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

```bash
# Delete any existing cluster
kind delete cluster --name fasthack 2>/dev/null

# Create the 3-node cluster
kind create cluster --name fasthack --config kind-scheduling.yaml

# Verify all 3 nodes are Ready
kubectl get nodes
```

You should see three nodes: `fasthack-control-plane`, `fasthack-worker`, and `fasthack-worker2`.

Label the worker nodes for later tasks:

```bash
kubectl label node fasthack-worker disk=ssd zone=us-east-1a
kubectl label node fasthack-worker2 disk=hdd zone=us-east-1b
```

---

### Task 1 — Taints & Tolerations

**Linux analogy:** Like setting a cgroup rule that prevents certain processes from running on specific CPUs — only processes that explicitly "opt in" are allowed.

Taints are applied to **nodes** to repel Pods. Tolerations are applied to **Pods** to allow them onto tainted nodes.

**Step 1:** Taint `fasthack-worker2` so that only Pods with a matching toleration can be scheduled there:

```bash
kubectl taint nodes fasthack-worker2 environment=production:NoSchedule
```

**Step 2:** Create a Pod **without** a toleration and observe that it only lands on `fasthack-worker`:

Save as `no-toleration-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: no-toleration
spec:
  containers:
    - name: nginx
      image: nginx:stable
```

```bash
kubectl apply -f no-toleration-pod.yaml
kubectl get pod no-toleration -o wide
```

The Pod should be scheduled on `fasthack-worker` (not `fasthack-worker2`).

**Step 3:** Create a Pod **with** a matching toleration that can run on the tainted node:

Save as `tolerant-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: tolerant-pod
spec:
  containers:
    - name: nginx
      image: nginx:stable
  tolerations:
    - key: "environment"
      operator: "Equal"
      value: "production"
      effect: "NoSchedule"
```

```bash
kubectl apply -f tolerant-pod.yaml
kubectl get pod tolerant-pod -o wide
```

The Pod *may* land on either worker — tolerations *allow* scheduling on the tainted node but don't *force* it. To guarantee placement on the tainted node, you would combine a toleration with node affinity (covered in Task 2).

**Step 4:** Verify by checking taints:

```bash
kubectl describe node fasthack-worker2 | grep -A 3 Taints
```

Clean up before the next task:

```bash
kubectl delete pod no-toleration tolerant-pod
```

---

### Task 2 — Node Affinity

**Linux analogy:** Like `taskset -c 0,1 myprocess` — pinning a process to specific CPUs. Node affinity pins Pods to specific nodes based on labels.

Kubernetes supports two types of node affinity:
- `requiredDuringSchedulingIgnoredDuringExecution` — **hard rule** (must be satisfied)
- `preferredDuringSchedulingIgnoredDuringExecution` — **soft rule** (try to satisfy, but schedule anyway if not possible)

**Step 1:** Create a Pod with **required** node affinity that targets the `disk=ssd` node:

Save as `required-affinity.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: ssd-required
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: disk
                operator: In
                values:
                  - ssd
  containers:
    - name: nginx
      image: nginx:stable
```

```bash
kubectl apply -f required-affinity.yaml
kubectl get pod ssd-required -o wide
```

The Pod **must** land on `fasthack-worker` (the node labeled `disk=ssd`).

**Step 2:** Create a Pod with **preferred** node affinity that prefers `disk=nvme` (which doesn't exist), with a fallback:

Save as `preferred-affinity.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nvme-preferred
spec:
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 80
          preference:
            matchExpressions:
              - key: disk
                operator: In
                values:
                  - nvme
  containers:
    - name: nginx
      image: nginx:stable
```

```bash
kubectl apply -f preferred-affinity.yaml
kubectl get pod nvme-preferred -o wide
```

Since no node has `disk=nvme`, the scheduler places the Pod on any available node — it's a soft preference, not a hard requirement.

**Step 3:** Verify the difference — try to create a Pod requiring a non-existent label:

Save as `impossible-affinity.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: impossible-pod
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: gpu
                operator: In
                values:
                  - "true"
  containers:
    - name: nginx
      image: nginx:stable
```

```bash
kubectl apply -f impossible-affinity.yaml
kubectl get pod impossible-pod
```

The Pod should be stuck in `Pending` — no node satisfies the requirement. Check why:

```bash
kubectl describe pod impossible-pod | grep -A 5 Events
```

Clean up:

```bash
kubectl delete pod ssd-required nvme-preferred impossible-pod
```

---

### Task 3 — Pod Affinity & Anti-Affinity

**Linux analogy:** Like co-locating processes on the same NUMA node for shared memory performance, or separating critical processes across CPUs so one can't starve the other.

Pod affinity attracts Pods toward other Pods. Pod anti-affinity repels Pods away from each other.

**Step 1:** Deploy a "cache" Pod that other Pods will be attracted to:

Save as `cache-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: cache
  labels:
    app: cache
spec:
  containers:
    - name: redis
      image: redis:7
```

```bash
kubectl apply -f cache-pod.yaml
kubectl get pod cache -o wide
```

Note which node the `cache` Pod lands on.

**Step 2:** Create a Pod with **podAffinity** that wants to be co-located with the cache:

Save as `web-with-affinity.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web-near-cache
spec:
  affinity:
    podAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchExpressions:
              - key: app
                operator: In
                values:
                  - cache
          topologyKey: kubernetes.io/hostname
  containers:
    - name: nginx
      image: nginx:stable
```

```bash
kubectl apply -f web-with-affinity.yaml
kubectl get pod web-near-cache -o wide
```

The `web-near-cache` Pod should land on the **same node** as the `cache` Pod.

**Step 3:** Create a Deployment with **podAntiAffinity** to spread replicas across nodes:

Save as `spread-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spread-web
spec:
  replicas: 2
  selector:
    matchLabels:
      app: spread-web
  template:
    metadata:
      labels:
        app: spread-web
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchExpressions:
                  - key: app
                    operator: In
                    values:
                      - spread-web
              topologyKey: kubernetes.io/hostname
      containers:
        - name: nginx
          image: nginx:stable
```

```bash
kubectl apply -f spread-deployment.yaml
kubectl get pods -l app=spread-web -o wide
```

Each replica should land on a **different** worker node. If you scale to 3 replicas, the third will be `Pending` (only 2 worker nodes with no taint-removing tolerations applicable):

```bash
kubectl scale deployment spread-web --replicas=3
kubectl get pods -l app=spread-web -o wide
```

Scale back down and clean up:

```bash
kubectl scale deployment spread-web --replicas=2
kubectl delete pod cache web-near-cache
kubectl delete deployment spread-web
```

---

### Task 4 — Topology Spread Constraints

**Linux analogy:** Like distributing processes evenly across NUMA nodes to prevent memory hotspots.

Topology spread constraints give you finer-grained control over Pod distribution than anti-affinity.

**Step 1:** Remove the taint from Task 1 so both workers are available:

```bash
kubectl taint nodes fasthack-worker2 environment=production:NoSchedule-
```

**Step 2:** Create a Deployment with topology spread constraints:

Save as `topology-spread.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: balanced-web
spec:
  replicas: 4
  selector:
    matchLabels:
      app: balanced-web
  template:
    metadata:
      labels:
        app: balanced-web
    spec:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: balanced-web
      containers:
        - name: nginx
          image: nginx:stable
```

```bash
kubectl apply -f topology-spread.yaml
kubectl get pods -l app=balanced-web -o wide
```

With `maxSkew: 1`, Pods should be distributed as evenly as possible across worker nodes — expect 2 Pods per worker.

**Step 3:** Change `whenUnsatisfiable` to `ScheduleAnyway` and observe the difference:

```bash
kubectl patch deployment balanced-web --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/topologySpreadConstraints/0/whenUnsatisfiable","value":"ScheduleAnyway"}]'

kubectl rollout status deployment balanced-web
kubectl get pods -l app=balanced-web -o wide
```

With `ScheduleAnyway`, the scheduler *tries* to spread evenly but won't leave Pods unscheduled if the constraint can't be perfectly met.

Clean up:

```bash
kubectl delete deployment balanced-web
```

---

### Task 5 — Static Pods

**Linux analogy:** Like a service started directly by `systemd` from a unit file on disk — the init system watches the file and manages the process lifecycle, bypassing any higher-level process manager.

Static Pods are managed directly by the **kubelet** on a specific node, not by the API server. The kubelet watches a directory for Pod manifests and starts/stops Pods as files appear/disappear.

**Step 1:** Find the static Pod path on your Kind control-plane node:

```bash
docker exec fasthack-control-plane cat /var/lib/kubelet/config.yaml | grep staticPodPath
```

You should see `staticPodPath: /etc/kubernetes/manifests`.

**Step 2:** Create a static Pod by placing a manifest directly in that directory:

```bash
docker exec fasthack-control-plane bash -c 'cat > /etc/kubernetes/manifests/static-web.yaml << EOF
apiVersion: v1
kind: Pod
metadata:
  name: static-web
  labels:
    role: static
spec:
  containers:
    - name: nginx
      image: nginx:stable
      ports:
        - containerPort: 80
EOF'
```

**Step 3:** Verify the static Pod appears in the API server as a **mirror Pod**:

```bash
kubectl get pods -A | grep static-web
```

You should see `static-web-fasthack-control-plane` — the kubelet created a mirror Pod. Notice the node hostname is appended to the name.

**Step 4:** Try to delete the mirror Pod:

```bash
kubectl delete pod static-web-fasthack-control-plane -n default
```

Wait a few seconds, then check again:

```bash
kubectl get pods | grep static-web
```

The Pod comes back! The kubelet recreates it because the manifest file still exists on disk.

**Step 5:** The only way to truly remove a static Pod is to delete the manifest file:

```bash
docker exec fasthack-control-plane rm /etc/kubernetes/manifests/static-web.yaml
```

Wait 10–20 seconds, then verify it's gone:

```bash
kubectl get pods | grep static-web
```

---

### Task 6 — ResourceQuotas and LimitRanges

**Linux analogy:** `ResourceQuota` is like a per-user `ulimit` — it caps total resource usage for a namespace. `LimitRange` is like setting default `ulimit` values for a user group — it provides automatic defaults and enforces min/max per container.

**Step 1:** Create a namespace for this exercise:

```bash
kubectl create namespace quota-lab
```

**Step 2:** Create a ResourceQuota that limits the namespace to 2 CPUs and 1Gi of memory total:

Save as `resource-quota.yaml`:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: compute-quota
  namespace: quota-lab
spec:
  hard:
    requests.cpu: "2"
    requests.memory: 1Gi
    limits.cpu: "4"
    limits.memory: 2Gi
    pods: "5"
```

```bash
kubectl apply -f resource-quota.yaml
kubectl describe quota compute-quota -n quota-lab
```

**Step 3:** Create a LimitRange that sets default resource requests/limits for containers in the namespace:

Save as `limit-range.yaml`:

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
  namespace: quota-lab
spec:
  limits:
    - default:
        cpu: 500m
        memory: 256Mi
      defaultRequest:
        cpu: 100m
        memory: 128Mi
      max:
        cpu: "1"
        memory: 512Mi
      min:
        cpu: 50m
        memory: 64Mi
      type: Container
```

```bash
kubectl apply -f limit-range.yaml
kubectl describe limitrange default-limits -n quota-lab
```

**Step 4:** Create a Pod **without** specifying resources — the LimitRange should inject defaults:

```bash
kubectl run auto-limits --image=nginx:stable -n quota-lab
kubectl get pod auto-limits -n quota-lab -o jsonpath='{.spec.containers[0].resources}' | python3 -m json.tool
```

You should see the default requests and limits injected by the LimitRange.

**Step 5:** Try to create a Pod that exceeds the LimitRange maximum:

Save as `greedy-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: greedy-pod
  namespace: quota-lab
spec:
  containers:
    - name: hog
      image: nginx:stable
      resources:
        requests:
          cpu: "2"
          memory: 1Gi
        limits:
          cpu: "2"
          memory: 1Gi
```

```bash
kubectl apply -f greedy-pod.yaml
```

This should be **rejected** because the container's CPU limit (`2`) exceeds the LimitRange max (`1`).

**Step 6:** Check the quota usage:

```bash
kubectl describe quota compute-quota -n quota-lab
```

You should see the resources consumed by the `auto-limits` Pod counted against the quota.

---

### Task 7 — PodDisruptionBudgets (PDB)

**Linux analogy:** Like ensuring that during a maintenance window (`systemctl stop`), you always keep at least N instances of a critical service running across your server pool.

PDBs protect your application during **voluntary disruptions** (node drains, cluster upgrades) by guaranteeing a minimum number of available Pods.

**Step 1:** Create a Deployment with 3 replicas:

Save as `pdb-app.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pdb-web
spec:
  replicas: 3
  selector:
    matchLabels:
      app: pdb-web
  template:
    metadata:
      labels:
        app: pdb-web
    spec:
      containers:
        - name: nginx
          image: nginx:stable
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
```

```bash
kubectl apply -f pdb-app.yaml
kubectl get pods -l app=pdb-web -o wide
```

**Step 2:** Create a PodDisruptionBudget that requires at least 2 Pods to always be available:

Save as `pdb.yaml`:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: pdb-web
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: pdb-web
```

```bash
kubectl apply -f pdb.yaml
kubectl get pdb
```

Expected output shows `ALLOWED-DISRUPTIONS: 1` (3 replicas − 2 minAvailable = 1 disruption allowed).

**Step 3:** Test the PDB by draining a worker node:

```bash
kubectl drain fasthack-worker --ignore-daemonsets --delete-emptydir-data
```

Observe that the drain proceeds, but respects the PDB — it evicts Pods one at a time, waiting for replacements to come up before evicting the next.

```bash
kubectl get pods -l app=pdb-web -o wide
kubectl get pdb
```

You should still see at least 2 running Pods at all times.

**Step 4:** Uncordon the drained node to make it schedulable again:

```bash
kubectl uncordon fasthack-worker
```

**Step 5 (Bonus):** Try creating a PDB with `minAvailable: 3` (equal to replicas) and draining — the drain will **block** because it can't evict any Pod without violating the budget:

```bash
kubectl patch pdb pdb-web --type=merge -p '{"spec":{"minAvailable":3}}'
kubectl get pdb

# This will block — press Ctrl+C after 30 seconds
kubectl drain fasthack-worker --ignore-daemonsets --delete-emptydir-data --timeout=30s
```

Reset:

```bash
kubectl uncordon fasthack-worker
kubectl patch pdb pdb-web --type=merge -p '{"spec":{"minAvailable":2}}'
```

---

## Success Criteria

- [ ] **Task 0:** 3-node Kind cluster is running (1 control-plane + 2 workers) with custom labels
- [ ] **Task 1:** Tainted node repels Pods without tolerations; toleration-bearing Pod can be scheduled on the tainted node
- [ ] **Task 2:** Pod with `requiredDuringScheduling` node affinity lands only on the matching node; Pod with `preferredDuringScheduling` falls back when no match exists; Pod with impossible affinity stays `Pending`
- [ ] **Task 3:** Pod with podAffinity lands on the same node as target Pod; Deployment with podAntiAffinity spreads replicas to different nodes
- [ ] **Task 4:** Topology spread constraints distribute 4 replicas evenly (2 per worker node)
- [ ] **Task 5:** Static Pod created via kubelet manifest directory; mirror Pod visible in API server; Pod survives `kubectl delete`; removed only by deleting the manifest file
- [ ] **Task 6:** ResourceQuota limits total namespace resources; LimitRange injects default requests/limits; Pod exceeding LimitRange max is rejected
- [ ] **Task 7:** PDB prevents `kubectl drain` from evicting too many Pods simultaneously; at least `minAvailable` Pods remain running during drain

---

## Linux ↔ Kubernetes Quick Reference

| Linux Concept | Kubernetes Equivalent | What It Does |
|---|---|---|
| `cgroup` CPU restrictions | **Taints & Tolerations** | Prevent processes/Pods from running on certain CPUs/nodes |
| `taskset -c 0,1 process` | **Node Affinity** (`requiredDuringScheduling`) | Pin a process/Pod to specific CPUs/nodes |
| `nice` / CPU preference | **Node Affinity** (`preferredDuringScheduling`) | Prefer certain CPUs/nodes but allow fallback |
| NUMA co-location | **Pod Affinity** | Co-locate related processes/Pods on same node |
| Process separation across CPUs | **Pod Anti-Affinity** | Keep processes/Pods on different nodes |
| Load balancing across NUMA nodes | **Topology Spread Constraints** | Distribute processes/Pods evenly across topology |
| `systemd` unit files on disk | **Static Pods** | kubelet watches a directory and manages Pod lifecycle directly |
| `ulimit` / per-user resource caps | **ResourceQuota** | Cap total resources per namespace |
| Default `ulimit` for a user group | **LimitRange** | Default and min/max resource values per container |
| Minimum instances during maintenance | **PodDisruptionBudget** | Guarantee minimum available Pods during voluntary disruptions |
| `nice -n 10` / `ionice` | **Resource requests/limits** | CPU/memory priority and caps per container |
| `/proc/sys/kernel/threads-max` | **ResourceQuota `pods`** | Max number of processes/Pods in a namespace |

---

## Hints

<details>
<summary><strong>Hint 1 — I tainted a node but my toleration Pod still doesn't land there</strong></summary>

Tolerations *allow* scheduling on a tainted node but don't *force* it. The scheduler may still prefer untainted nodes. To force a Pod onto a specific node, combine a toleration with nodeAffinity or use `nodeName`.

```bash
# Check the node's taints
kubectl describe node fasthack-worker2 | grep Taints

# Check the Pod's tolerations
kubectl get pod tolerant-pod -o jsonpath='{.spec.tolerations}'
```

</details>

<details>
<summary><strong>Hint 2 — My Pod with required node affinity is stuck Pending</strong></summary>

The node labels must match exactly. Check what labels exist:

```bash
kubectl get nodes --show-labels
```

Verify the affinity expression in your Pod spec matches the label key and value on the target node.

</details>

<details>
<summary><strong>Hint 3 — How do I find the static Pod path in Kind?</strong></summary>

The kubelet configuration file on Kind nodes is at `/var/lib/kubelet/config.yaml`. Access it with:

```bash
docker exec fasthack-control-plane cat /var/lib/kubelet/config.yaml | grep staticPodPath
```

The default is `/etc/kubernetes/manifests`.

</details>

<details>
<summary><strong>Hint 4 — My Pod was rejected by the ResourceQuota</strong></summary>

When a ResourceQuota exists in a namespace with CPU/memory quotas, **every** Pod must specify resource requests. If you don't, the API server rejects it. That's why LimitRange is useful — it injects defaults.

Check the error message:

```bash
kubectl describe quota -n quota-lab
```

</details>

<details>
<summary><strong>Hint 5 — kubectl drain is stuck / not progressing</strong></summary>

The drain is likely blocked by a PodDisruptionBudget. Check:

```bash
kubectl get pdb
kubectl get events --sort-by='.lastTimestamp'
```

If `ALLOWED-DISRUPTIONS` is `0`, the drain cannot evict any Pod. Reduce `minAvailable` or increase replicas.

</details>

<details>
<summary><strong>Hint 6 — What's the difference between topologySpreadConstraints and podAntiAffinity?</strong></summary>

- **podAntiAffinity** is binary: "don't place two matching Pods on the same node" (required) or "try not to" (preferred).
- **topologySpreadConstraints** gives finer control with `maxSkew` — allows up to N Pods difference between topology domains, enabling balanced distribution rather than strict one-per-node.

Use topologySpreadConstraints when you want *even distribution*, and podAntiAffinity when you want *strict separation*.

</details>

---

## Learning Resources

- [Taints and Tolerations](https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/)
- [Assigning Pods to Nodes (Node Affinity)](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/)
- [Pod Affinity & Anti-Affinity](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/#inter-pod-affinity-and-anti-affinity)
- [Topology Spread Constraints](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/)
- [Static Pods](https://kubernetes.io/docs/tasks/administer-cluster/static-pod/)
- [Resource Quotas](https://kubernetes.io/docs/concepts/policy/resource-quotas/)
- [Limit Ranges](https://kubernetes.io/docs/concepts/policy/limit-range/)
- [Pod Disruption Budgets](https://kubernetes.io/docs/tasks/run-application/configure-pdb/)
- [Managing Resources for Containers](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)
- [Kubernetes Scheduler](https://kubernetes.io/docs/concepts/scheduling-eviction/kube-scheduler/)

---

## Break & Fix Scenarios

### Scenario 1 — The Unschedulable Pod

A developer created a Pod but it's stuck in `Pending`. Diagnose and fix the issue.

```bash
kubectl run broken-schedule --image=nginx:stable --overrides='{
  "spec": {
    "affinity": {
      "nodeAffinity": {
        "requiredDuringSchedulingIgnoredDuringExecution": {
          "nodeSelectorTerms": [{
            "matchExpressions": [{
              "key": "accelerator",
              "operator": "In",
              "values": ["nvidia-tesla-v100"]
            }]
          }]
        }
      }
    }
  }
}'
```

**Tasks:**
1. Find out why the Pod is `Pending`
2. Fix it so the Pod gets scheduled (either add the label to a node or change the Pod spec)
3. Verify the Pod reaches `Running` status

### Scenario 2 — Quota Exhaustion

A team can't create new Pods in their namespace. Figure out why.

```bash
kubectl create namespace broken-quota
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tight-quota
  namespace: broken-quota
spec:
  hard:
    pods: "2"
    requests.cpu: 200m
    requests.memory: 128Mi
    limits.cpu: 400m
    limits.memory: 256Mi
EOF

kubectl run q1 --image=nginx:stable -n broken-quota \
  --overrides='{"spec":{"containers":[{"name":"q1","image":"nginx:stable","resources":{"requests":{"cpu":"100m","memory":"64Mi"},"limits":{"cpu":"200m","memory":"128Mi"}}}]}}'
kubectl run q2 --image=nginx:stable -n broken-quota \
  --overrides='{"spec":{"containers":[{"name":"q2","image":"nginx:stable","resources":{"requests":{"cpu":"100m","memory":"64Mi"},"limits":{"cpu":"200m","memory":"128Mi"}}}]}}'
```

Now try to create a third Pod:

```bash
kubectl run q3 --image=nginx:stable -n broken-quota \
  --overrides='{"spec":{"containers":[{"name":"q3","image":"nginx:stable","resources":{"requests":{"cpu":"50m","memory":"32Mi"},"limits":{"cpu":"100m","memory":"64Mi"}}}]}}'
```

**Tasks:**
1. Determine why the third Pod can't be created
2. Identify which quota limit is being hit
3. Fix the situation (increase the quota or free resources)

### Scenario 3 — Drain Blocked by PDB

An operator needs to drain a node for maintenance, but the drain is stuck.

```bash
kubectl create deployment drain-test --image=nginx:stable --replicas=2
kubectl apply -f - <<'EOF'
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: drain-test-pdb
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: drain-test
EOF
```

Now try:

```bash
kubectl drain fasthack-worker --ignore-daemonsets --delete-emptydir-data --timeout=30s
```

**Tasks:**
1. Determine why the drain is blocked
2. Identify the PDB that's preventing eviction
3. Fix the PDB to allow the drain to proceed (without reducing total replicas below a safe level)
4. Uncordon the node after maintenance
