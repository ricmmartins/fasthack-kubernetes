# Solution 15 — Pod Scheduling & Resource Management

[< Previous Solution](Solution-14.md) - **[Home](README.md)** - [Next Solution >](Solution-16.md)

---

> **Coach note:** This challenge covers CKA/CKAD scheduling and resource management topics. It requires a 3-node Kind cluster. If students are joining mid-hackathon, ensure they run Task 0 first. The static Pod exercise (Task 5) uses `docker exec` to access Kind nodes — make sure Docker is running.

> **Estimated time:** 75–90 minutes

---

## Task 0: Create a 3-Node Kind Cluster

### Step-by-step

Save `kind-scheduling.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

```bash
kind delete cluster --name fasthack 2>/dev/null
kind create cluster --name fasthack --config kind-scheduling.yaml
```

Expected output (last lines):

```
Set kubectl context to "kind-fasthack"
You can now use your cluster with:

kubectl cluster-info --context kind-fasthack
```

### Verification

```bash
kubectl get nodes
```

Expected:

```
NAME                     STATUS   ROLES           AGE   VERSION
fasthack-control-plane   Ready    control-plane   60s   v1.36.x
fasthack-worker          Ready    <none>          40s   v1.36.x
fasthack-worker2         Ready    <none>          40s   v1.36.x
```

Label the worker nodes:

```bash
kubectl label node fasthack-worker disk=ssd zone=us-east-1a
kubectl label node fasthack-worker2 disk=hdd zone=us-east-1b
```

Expected:

```
node/fasthack-worker labeled
node/fasthack-worker2 labeled
```

Verify labels:

```bash
kubectl get nodes --show-labels | grep -E "disk=|zone="
```

> **Coach tip:** If students already have a Kind cluster, they'll need to delete and recreate it. The existing single-node cluster won't work for scheduling exercises.

---

## Task 1: Taints & Tolerations

### Step-by-step

Apply the taint:

```bash
kubectl taint nodes fasthack-worker2 environment=production:NoSchedule
```

Expected:

```
node/fasthack-worker2 tainted
```

Verify the taint:

```bash
kubectl describe node fasthack-worker2 | grep -A 2 Taints
```

Expected:

```
Taints:             environment=production:NoSchedule
```

Create the Pod **without** toleration:

```yaml
# no-toleration-pod.yaml
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

Expected: Pod is scheduled on `fasthack-worker` (not `fasthack-worker2`):

```
NAME             READY   STATUS    RESTARTS   AGE   IP           NODE              
no-toleration    1/1     Running   0          10s   10.244.1.x   fasthack-worker
```

Create the Pod **with** toleration:

```yaml
# tolerant-pod.yaml
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

Expected: Pod may land on either worker — the toleration *allows* it on `fasthack-worker2` but doesn't force it there.

### Verification

```bash
kubectl describe node fasthack-worker2 | grep -A 3 Taints
```

Expected:

```
Taints:             environment=production:NoSchedule
```

Clean up:

```bash
kubectl delete pod no-toleration tolerant-pod
```

> **Coach tip:** A common misconception is that tolerations *attract* Pods to tainted nodes. They don't — they only *permit* scheduling. To force a Pod onto a tainted node, combine a toleration with node affinity or `nodeName`.

---

## Task 2: Node Affinity

### Step-by-step

**Required affinity:**

```yaml
# required-affinity.yaml
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

Expected: Pod runs on `fasthack-worker` (the only node with `disk=ssd`):

```
NAME           READY   STATUS    RESTARTS   AGE   IP           NODE
ssd-required   1/1     Running   0          10s   10.244.1.x   fasthack-worker
```

**Preferred affinity (non-existent label):**

```yaml
# preferred-affinity.yaml
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

Expected: Pod is Running on any worker — the preferred rule is a soft hint, not a hard requirement.

**Impossible required affinity:**

```yaml
# impossible-affinity.yaml
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

Expected: Pod stays `Pending`:

```
NAME              READY   STATUS    RESTARTS   AGE
impossible-pod    0/1     Pending   0          30s
```

Check the reason:

```bash
kubectl describe pod impossible-pod | grep -A 5 Events
```

Expected event:

```
Warning  FailedScheduling  ... 0/3 nodes are available: 1 node(s) had untainted ... 2 node(s) didn't match Pod's node affinity/selector ...
```

### Verification

Clean up:

```bash
kubectl delete pod ssd-required nvme-preferred impossible-pod
```

---

## Task 3: Pod Affinity & Anti-Affinity

### Step-by-step

**Deploy the cache Pod:**

```yaml
# cache-pod.yaml
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

Note the node name (e.g., `fasthack-worker`).

**Pod with podAffinity:**

```yaml
# web-with-affinity.yaml
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

Expected: `web-near-cache` is on the **same node** as `cache`:

```
NAME              READY   STATUS    RESTARTS   AGE   IP           NODE
cache             1/1     Running   0          30s   10.244.1.2   fasthack-worker
web-near-cache    1/1     Running   0          10s   10.244.1.3   fasthack-worker
```

**Deployment with podAntiAffinity:**

```yaml
# spread-deployment.yaml
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

Expected: Each replica on a **different** worker:

```
NAME                         READY   STATUS    RESTARTS   AGE   NODE
spread-web-xxxxxxxxx-aaaaa   1/1     Running   0          15s   fasthack-worker
spread-web-xxxxxxxxx-bbbbb   1/1     Running   0          15s   fasthack-worker2
```

> **Note:** The taint from Task 1 is still on `fasthack-worker2`. If a replica stays Pending, the student needs to remove it: `kubectl taint nodes fasthack-worker2 environment=production:NoSchedule-`. Alternatively, add a toleration to the Deployment spec.

Scale to 3 and observe the Pending Pod:

```bash
kubectl scale deployment spread-web --replicas=3
kubectl get pods -l app=spread-web -o wide
```

Expected: Third Pod is `Pending` — only 2 worker nodes available, and anti-affinity prevents two Pods on the same node.

### Verification

Scale back and clean up:

```bash
kubectl scale deployment spread-web --replicas=2
kubectl delete pod cache web-near-cache
kubectl delete deployment spread-web
```

---

## Task 4: Topology Spread Constraints

### Step-by-step

Remove the taint from Task 1:

```bash
kubectl taint nodes fasthack-worker2 environment=production:NoSchedule-
```

Expected:

```
node/fasthack-worker2 untainted
```

Create the Deployment:

```yaml
# topology-spread.yaml
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

Expected: 2 Pods on each worker node:

```
NAME                            READY   STATUS    NODE
balanced-web-xxxxxxxxx-aaaa     1/1     Running   fasthack-worker
balanced-web-xxxxxxxxx-bbbb     1/1     Running   fasthack-worker
balanced-web-xxxxxxxxx-cccc     1/1     Running   fasthack-worker2
balanced-web-xxxxxxxxx-dddd     1/1     Running   fasthack-worker2
```

> **Coach tip:** `maxSkew: 1` means the difference in Pod count between any two topology domains (nodes) can be at most 1. With 4 Pods and 2 workers, the only valid distribution is 2+2.

Patch to `ScheduleAnyway`:

```bash
kubectl patch deployment balanced-web --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/topologySpreadConstraints/0/whenUnsatisfiable","value":"ScheduleAnyway"}]'

kubectl rollout status deployment balanced-web
kubectl get pods -l app=balanced-web -o wide
```

Expected: Same distribution (the scheduler still tries to balance), but now it wouldn't leave Pods `Pending` if perfect balance were impossible.

### Verification

Clean up:

```bash
kubectl delete deployment balanced-web
```

---

## Task 5: Static Pods

### Step-by-step

Find the static Pod path:

```bash
docker exec fasthack-control-plane cat /var/lib/kubelet/config.yaml | grep staticPodPath
```

Expected:

```
staticPodPath: /etc/kubernetes/manifests
```

Create the static Pod manifest:

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

Wait 10–20 seconds for the kubelet to detect the new file.

### Verification

```bash
kubectl get pods -A | grep static-web
```

Expected:

```
default     static-web-fasthack-control-plane   1/1     Running   0          15s
```

The Pod name has the node hostname appended — this is the **mirror Pod** created by the kubelet.

Try to delete it:

```bash
kubectl delete pod static-web-fasthack-control-plane -n default
```

Wait a few seconds:

```bash
kubectl get pods | grep static-web
```

Expected: The Pod reappears! The kubelet recreates it because the manifest file still exists.

Delete the manifest file to truly remove the Pod:

```bash
docker exec fasthack-control-plane rm /etc/kubernetes/manifests/static-web.yaml
```

Wait 10–20 seconds:

```bash
kubectl get pods | grep static-web
```

Expected: No results — the Pod is gone.

> **Coach tip:** Explain that static Pods are how the control plane components themselves run on Kind and kubeadm clusters. Check `/etc/kubernetes/manifests/` on the control plane node to see `etcd.yaml`, `kube-apiserver.yaml`, `kube-controller-manager.yaml`, and `kube-scheduler.yaml`.
>
> ```bash
> docker exec fasthack-control-plane ls /etc/kubernetes/manifests/
> ```

---

## Task 6: ResourceQuotas and LimitRanges

### Step-by-step

Create the namespace:

```bash
kubectl create namespace quota-lab
```

Create the ResourceQuota:

```yaml
# resource-quota.yaml
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

Expected:

```
Name:            compute-quota
Namespace:       quota-lab
Resource         Used  Hard
--------         ----  ----
limits.cpu       0     4
limits.memory    0     2Gi
pods             0     5
requests.cpu     0     2
requests.memory  0     1Gi
```

Create the LimitRange:

```yaml
# limit-range.yaml
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

Expected:

```
Type        Resource  Min   Max    Default Request  Default Limit  ...
----        --------  ---   ---    ---------------  -------------  
Container   cpu       50m   1      100m             500m           
Container   memory    64Mi  512Mi  128Mi            256Mi          
```

Create a Pod without specifying resources:

```bash
kubectl run auto-limits --image=nginx:stable -n quota-lab
```

Verify the LimitRange injected defaults:

```bash
kubectl get pod auto-limits -n quota-lab -o jsonpath='{.spec.containers[0].resources}' | python3 -m json.tool
```

Expected:

```json
{
    "limits": {
        "cpu": "500m",
        "memory": "256Mi"
    },
    "requests": {
        "cpu": "100m",
        "memory": "128Mi"
    }
}
```

Try to create a Pod exceeding the LimitRange max:

```yaml
# greedy-pod.yaml
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

Expected error:

```
Error from server (Forbidden): ... cpu max limit is 1, but spec is 2
```

Check quota usage:

```bash
kubectl describe quota compute-quota -n quota-lab
```

Expected: Shows resources consumed by the `auto-limits` Pod:

```
Resource         Used   Hard
--------         ----   ----
limits.cpu       500m   4
limits.memory    256Mi  2Gi
pods             1      5
requests.cpu     100m   2
requests.memory  128Mi  1Gi
```

> **Coach tip:** A key insight — when a ResourceQuota with CPU/memory is active in a namespace but no LimitRange exists, Pods **without** explicit resource requests/limits will be rejected. The LimitRange acts as a safety net by injecting defaults.

---

## Task 7: PodDisruptionBudgets

### Step-by-step

Create the Deployment:

```yaml
# pdb-app.yaml
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

Expected: 3 Pods running, distributed across worker nodes.

Create the PDB:

```yaml
# pdb.yaml
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

Expected:

```
NAME      MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
pdb-web   2               N/A               1                     5s
```

`ALLOWED-DISRUPTIONS: 1` means the drain can evict at most 1 Pod at a time (3 current − 2 minAvailable = 1).

Drain a worker node:

```bash
kubectl drain fasthack-worker --ignore-daemonsets --delete-emptydir-data
```

Expected output includes:

```
evicting pod default/pdb-web-xxxxxxxxx-xxxxx
pod/pdb-web-xxxxxxxxx-xxxxx evicted
node/fasthack-worker drained
```

Verify Pods are still running (at least 2):

```bash
kubectl get pods -l app=pdb-web -o wide
kubectl get pdb
```

Expected: All 3 replicas should be Running (the evicted Pods get rescheduled to `fasthack-worker2`). The PDB ensured that at least 2 were available throughout the drain.

Uncordon:

```bash
kubectl uncordon fasthack-worker
```

Expected:

```
node/fasthack-worker uncordoned
```

**Bonus — block drain with minAvailable=3:**

```bash
kubectl patch pdb pdb-web --type=merge -p '{"spec":{"minAvailable":3}}'
kubectl get pdb
```

Expected:

```
NAME      MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
pdb-web   3               N/A               0                     2m
```

`ALLOWED-DISRUPTIONS: 0` — the drain will block:

```bash
kubectl drain fasthack-worker --ignore-daemonsets --delete-emptydir-data --timeout=30s
```

Expected: Drain times out after 30 seconds with an error about the PDB.

Reset:

```bash
kubectl uncordon fasthack-worker
kubectl patch pdb pdb-web --type=merge -p '{"spec":{"minAvailable":2}}'
```

---

## Break & Fix Solutions

### Scenario 1 — The Unschedulable Pod

**Diagnosis:**

```bash
kubectl get pod broken-schedule
kubectl describe pod broken-schedule | grep -A 10 Events
```

Expected event:

```
Warning  FailedScheduling  ... 0/3 nodes are available: ... didn't match Pod's node affinity/selector
```

The Pod requires `accelerator=nvidia-tesla-v100` — no node has this label.

**Fix (option A — add the label):**

```bash
kubectl label node fasthack-worker accelerator=nvidia-tesla-v100
```

Wait a few seconds — the Pod should become `Running`:

```bash
kubectl get pod broken-schedule -o wide
```

**Fix (option B — recreate without affinity):**

```bash
kubectl delete pod broken-schedule
kubectl run broken-schedule --image=nginx:stable
```

**Clean up:**

```bash
kubectl label node fasthack-worker accelerator-
kubectl delete pod broken-schedule
```

### Scenario 2 — Quota Exhaustion

**Diagnosis:**

```bash
kubectl describe quota tight-quota -n broken-quota
```

Expected:

```
Resource         Used   Hard
--------         ----   ----
pods             2      2
requests.cpu     200m   200m
requests.memory  128Mi  128Mi
limits.cpu       400m   400m
limits.memory    256Mi  256Mi
```

All resources are fully consumed. The `pods: 2` limit alone would block a third Pod.

**Fix — increase the quota:**

```bash
kubectl patch resourcequota tight-quota -n broken-quota --type=merge \
  -p '{"spec":{"hard":{"pods":"5","requests.cpu":"500m","requests.memory":"256Mi","limits.cpu":"1","limits.memory":"512Mi"}}}'
```

Now retry:

```bash
kubectl run q3 --image=nginx:stable -n broken-quota \
  --overrides='{"spec":{"containers":[{"name":"q3","image":"nginx:stable","resources":{"requests":{"cpu":"50m","memory":"32Mi"},"limits":{"cpu":"100m","memory":"64Mi"}}}]}}'
```

Expected: Pod is created successfully.

**Clean up:**

```bash
kubectl delete namespace broken-quota
```

### Scenario 3 — Drain Blocked by PDB

**Diagnosis:**

```bash
kubectl get pdb
```

Expected:

```
NAME             MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
drain-test-pdb   2               N/A               0                     30s
```

`ALLOWED-DISRUPTIONS: 0` — The PDB requires 2 Pods available, but there are only 2 replicas. No Pod can be evicted without violating the budget.

**Fix — lower minAvailable or increase replicas:**

Option A — reduce `minAvailable` to 1:

```bash
kubectl patch pdb drain-test-pdb --type=merge -p '{"spec":{"minAvailable":1}}'
```

Option B — increase replicas to 3:

```bash
kubectl scale deployment drain-test --replicas=3
```

Now drain works:

```bash
kubectl drain fasthack-worker --ignore-daemonsets --delete-emptydir-data
```

**Clean up:**

```bash
kubectl uncordon fasthack-worker
kubectl delete deployment drain-test
kubectl delete pdb drain-test-pdb
```

---

## Full Cleanup

To reset everything after the challenge:

```bash
kubectl delete namespace quota-lab --ignore-not-found
kubectl delete deployment pdb-web --ignore-not-found
kubectl delete pdb pdb-web --ignore-not-found
kubectl taint nodes fasthack-worker2 environment=production:NoSchedule- 2>/dev/null
kubectl label node fasthack-worker disk- zone- accelerator- 2>/dev/null
kubectl label node fasthack-worker2 disk- zone- 2>/dev/null
```

Or recreate the cluster from scratch:

```bash
kind delete cluster --name fasthack
kind create cluster --name fasthack --config kind-scheduling.yaml
```

---

## Common Issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| Pod stuck `Pending` after adding toleration | Toleration allows but doesn't force scheduling; other nodes may be preferred | Combine toleration with `nodeAffinity` or `nodeName` to force placement |
| `kubectl taint` says "node not found" | Wrong node name | Run `kubectl get nodes` to check exact names (e.g., `fasthack-worker2` not `worker-2`) |
| Required affinity Pod stays `Pending` | No node matches the label expression | Check labels with `kubectl get nodes --show-labels` |
| Anti-affinity Deployment won't scale to 3 | Only 2 worker nodes; `required` anti-affinity prevents 2 Pods per node | Use `preferred` anti-affinity instead of `required`, or add more nodes |
| `topologySpreadConstraints` doesn't spread evenly | `whenUnsatisfiable: ScheduleAnyway` allows imbalance | Use `DoNotSchedule` for strict spreading |
| Static Pod won't appear | Kubelet hasn't scanned yet or YAML is invalid | Wait 20 seconds; check `docker exec fasthack-control-plane cat /etc/kubernetes/manifests/static-web.yaml` for syntax |
| Static Pod shows `CrashLoopBackOff` | Invalid image or container command in the manifest | Fix the YAML file on the node and wait for kubelet to pick up changes |
| Pod rejected: "must specify requests/limits" | ResourceQuota requires CPU/memory but Pod has no resource spec | Create a LimitRange to inject defaults, or add explicit resources to the Pod |
| Pod rejected: "exceeds max limit" | Container resource limit exceeds LimitRange max | Reduce the container's resource limit to be within LimitRange bounds |
| `kubectl drain` blocked / times out | PDB `minAvailable` ≥ current replica count (0 disruptions allowed) | Reduce `minAvailable`, use `maxUnavailable: 1` instead, or increase replicas |
| `docker exec` fails on Kind node | Docker daemon not running or wrong container name | Run `docker ps` to verify Kind containers; names match Kind cluster+node names |
| Pods schedule on control-plane node unexpectedly | Control-plane taint was removed | Re-taint: `kubectl taint nodes fasthack-control-plane node-role.kubernetes.io/control-plane:NoSchedule` |

---

## Key Concepts Summary for Coaches

```
Scheduling Decision Flow:
                                                  
  Pod Created ──▶ Filtering Phase ──▶ Scoring Phase ──▶ Binding Phase
                     │                     │                │
              ┌──────┴──────┐       ┌──────┴──────┐       │
              │ Taints      │       │ Preferred   │   Pod bound
              │ Required    │       │   Affinity  │   to node
              │   Affinity  │       │ Topology    │
              │ Resource    │       │   Spread    │
              │   Fit       │       │ Weights     │
              └─────────────┘       └─────────────┘
              (eliminates nodes)    (ranks remaining)
```

| Mechanism | Phase | Granularity | Effect |
|-----------|-------|-------------|--------|
| Taints & Tolerations | Filter | Node → Pod | "Don't come here unless you tolerate me" |
| Required Node Affinity | Filter | Pod → Node | "I must run on nodes with these labels" |
| Preferred Node Affinity | Score | Pod → Node | "I'd prefer nodes with these labels" |
| Required Pod Affinity | Filter | Pod → Pod | "I must be on a node near Pod X" |
| Required Pod Anti-Affinity | Filter | Pod → Pod | "I must NOT be on a node with Pod X" |
| Topology Spread | Filter+Score | Pod distribution | "Spread me evenly across topology" |
| ResourceQuota | Admission | Namespace total | "Namespace can't exceed X total resources" |
| LimitRange | Admission | Per-container | "Each container must be within min/max" |
| PDB | Eviction | Pod group | "Keep at least N Pods available" |
