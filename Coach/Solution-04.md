# Solution 04 — Deployments and Rolling Updates

[< Back to Challenge](../Student/Challenge-04.md) | **[Home](README.md)**

## Pre-check

Ensure students have a running Kind cluster (ideally the multi-node cluster from Challenge 03):

```bash
kubectl get nodes
```

Expected output (single-node is also fine):

```
NAME                    STATUS   ROLES           AGE   VERSION
k8s-lab-control-plane   Ready    control-plane   30m   v1.33.0
k8s-lab-worker          Ready    <none>          30m   v1.33.0
k8s-lab-worker2         Ready    <none>          30m   v1.33.0
```

Clean up any leftover Pods from previous challenges:

```bash
kubectl delete pods --all 2>/dev/null
```

---

## Task 1: Create a Deployment with 3 Replicas

### Step-by-step

Create the Deployment manifest file `webapp-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp
spec:
  replicas: 3
  selector:
    matchLabels:
      app: webapp
  template:
    metadata:
      labels:
        app: webapp
    spec:
      containers:
        - name: nginx
          image: nginx:stable
          ports:
            - containerPort: 80
```

Apply the Deployment:

```bash
kubectl apply -f webapp-deployment.yaml
```

Expected output:

```
deployment.apps/webapp created
```

**Verify the Deployment:**

```bash
kubectl get deployment webapp
```

Expected output:

```
NAME     READY   UP-TO-DATE   AVAILABLE   AGE
webapp   3/3     3            3           30s
```

> **Coach note:** Explain the columns:
> - `READY` — Pods ready / desired replicas
> - `UP-TO-DATE` — Pods running the latest template
> - `AVAILABLE` — Pods available to serve traffic

**List the Pods created by the Deployment:**

```bash
kubectl get pods -l app=webapp
```

Expected output:

```
NAME                      READY   STATUS    RESTARTS   AGE
webapp-xxxxxxxxxx-abcde   1/1     Running   0          45s
webapp-xxxxxxxxxx-fghij   1/1     Running   0          45s
webapp-xxxxxxxxxx-klmno   1/1     Running   0          45s
```

**Show the ReplicaSet managing these Pods:**

```bash
kubectl get replicaset -l app=webapp
```

Expected output:

```
NAME                DESIRED   CURRENT   READY   AGE
webapp-xxxxxxxxxx   3         3         3       1m
```

> **Coach note:** Explain the hierarchy: **Deployment** → **ReplicaSet** → **Pods**. The Deployment manages ReplicaSets, which manage Pods. Students should never edit ReplicaSets directly.

**Demonstrate self-healing — delete a Pod and watch it come back:**

```bash
# Get a Pod name
POD_NAME=$(kubectl get pods -l app=webapp -o jsonpath='{.items[0].metadata.name}')

# Delete it
kubectl delete pod $POD_NAME

# Watch the Deployment recreate it immediately
kubectl get pods -l app=webapp -w
```

Expected output:

```
NAME                      READY   STATUS        RESTARTS   AGE
webapp-xxxxxxxxxx-abcde   1/1     Terminating   0          2m
webapp-xxxxxxxxxx-fghij   1/1     Running       0          2m
webapp-xxxxxxxxxx-klmno   1/1     Running       0          2m
webapp-xxxxxxxxxx-pqrst   0/1     Pending       0          1s
webapp-xxxxxxxxxx-pqrst   0/1     ContainerCreating   0    1s
webapp-xxxxxxxxxx-pqrst   1/1     Running       0          3s
```

Press `Ctrl+C` to stop watching.

> **Coach note:** This is the key difference from bare Pods in Challenge 02. The Deployment controller detects the missing replica and creates a replacement.

### Verification

- `kubectl get deployment webapp` shows `3/3` Ready
- `kubectl get pods -l app=webapp` shows 3 Running Pods
- Deleting a Pod causes the Deployment to automatically create a replacement

---

## Task 2: Scale the Deployment

### Step-by-step

**Scale up to 5 replicas:**

```bash
kubectl scale deployment webapp --replicas=5
```

Expected output:

```
deployment.apps/webapp scaled
```

Watch the new Pods appear:

```bash
kubectl get pods -l app=webapp
```

Expected output:

```
NAME                      READY   STATUS    RESTARTS   AGE
webapp-xxxxxxxxxx-abcde   1/1     Running   0          3m
webapp-xxxxxxxxxx-fghij   1/1     Running   0          3m
webapp-xxxxxxxxxx-klmno   1/1     Running   0          3m
webapp-xxxxxxxxxx-pqrst   1/1     Running   0          10s
webapp-xxxxxxxxxx-uvwxy   1/1     Running   0          10s
```

Confirm the Deployment shows 5 replicas:

```bash
kubectl get deployment webapp
```

Expected output:

```
NAME     READY   UP-TO-DATE   AVAILABLE   AGE
webapp   5/5     5            5           4m
```

**Scale back down to 3 replicas:**

```bash
kubectl scale deployment webapp --replicas=3
```

Watch Pods terminate:

```bash
kubectl get pods -l app=webapp -w
```

Expected output:

```
NAME                      READY   STATUS        RESTARTS   AGE
webapp-xxxxxxxxxx-abcde   1/1     Running       0          5m
webapp-xxxxxxxxxx-fghij   1/1     Running       0          5m
webapp-xxxxxxxxxx-klmno   1/1     Running       0          5m
webapp-xxxxxxxxxx-pqrst   1/1     Terminating   0          2m
webapp-xxxxxxxxxx-uvwxy   1/1     Terminating   0          2m
```

Press `Ctrl+C` to stop watching.

Confirm 3 replicas remain:

```bash
kubectl get deployment webapp
```

Expected output:

```
NAME     READY   UP-TO-DATE   AVAILABLE   AGE
webapp   3/3     3            3           6m
```

### Verification

- After scaling up: `kubectl get deployment webapp` shows `5/5`
- After scaling down: `kubectl get deployment webapp` shows `3/3`
- Excess Pods were terminated gracefully

---

## Task 3: Perform a Rolling Update

### Step-by-step

**Update the image from `nginx:stable` to `nginx:alpine`:**

```bash
kubectl set image deployment/webapp nginx=nginx:alpine
```

Expected output:

```
deployment.apps/webapp image updated
```

**Watch the rollout progress:**

```bash
kubectl rollout status deployment/webapp
```

Expected output:

```
Waiting for deployment "webapp" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "webapp" rollout to finish: 2 out of 3 new replicas have been updated...
Waiting for deployment "webapp" rollout to finish: 2 of 3 updated replicas are available...
deployment "webapp" successfully rolled out
```

**Observe the rolling update strategy — old Pods terminate as new Pods start:**

```bash
kubectl get pods -l app=webapp
```

Expected output (all Pods should have new names and short AGE):

```
NAME                      READY   STATUS    RESTARTS   AGE
webapp-yyyyyyyyyy-aaaaa   1/1     Running   0          30s
webapp-yyyyyyyyyy-bbbbb   1/1     Running   0          25s
webapp-yyyyyyyyyy-ccccc   1/1     Running   0          20s
```

> **Coach note:** Notice the ReplicaSet hash changed (`xxxxxxxxxx` → `yyyyyyyyyy`). A rolling update creates a **new** ReplicaSet, scales it up, and scales the old one down.

**Verify the image was updated:**

```bash
kubectl describe deployment webapp | grep Image
```

Expected output:

```
    Image:        nginx:alpine
```

**Show the ReplicaSets — old and new:**

```bash
kubectl get replicaset -l app=webapp
```

Expected output:

```
NAME                DESIRED   CURRENT   READY   AGE
webapp-xxxxxxxxxx   0         0         0       10m    # old - scaled to 0
webapp-yyyyyyyyyy   3         3         3       1m     # new - active
```

> **Coach note:** The old ReplicaSet is kept (scaled to 0) to enable rollback. This is how Kubernetes tracks revision history.

**Check rollout history:**

```bash
kubectl rollout history deployment/webapp
```

Expected output:

```
deployment.apps/webapp
REVISION  CHANGE-CAUSE
1         <none>
2         <none>
```

### Verification

- `kubectl rollout status deployment/webapp` reports "successfully rolled out"
- `kubectl describe deployment webapp | grep Image` shows `nginx:alpine`
- Two ReplicaSets exist: the old one scaled to 0, the new one at 3

---

## Task 4: Rollback to the Previous Version

### Step-by-step

**Rollback to the previous revision:**

```bash
kubectl rollout undo deployment/webapp
```

Expected output:

```
deployment.apps/webapp rolled back
```

**Watch the rollback complete:**

```bash
kubectl rollout status deployment/webapp
```

Expected output:

```
deployment "webapp" successfully rolled out
```

**Verify the image is back to `nginx:stable`:**

```bash
kubectl describe deployment webapp | grep Image
```

Expected output:

```
    Image:        nginx:stable
```

**Check rollout history — a new revision was created:**

```bash
kubectl rollout history deployment/webapp
```

Expected output:

```
deployment.apps/webapp
REVISION  CHANGE-CAUSE
2         <none>
3         <none>
```

> **Coach note:** Revision 1 is gone because the rollback reused its template (Kubernetes renumbers it as revision 3). Revision 2 is the `nginx:alpine` version, still available for rollback if needed.

### Verification

- `kubectl describe deployment webapp | grep Image` shows `nginx:stable`
- `kubectl rollout history deployment/webapp` shows a new revision

---

## Task 5: Set Resource Requests and Limits

### Step-by-step

Update the Deployment manifest to include resource constraints. Edit `webapp-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp
spec:
  replicas: 3
  selector:
    matchLabels:
      app: webapp
  template:
    metadata:
      labels:
        app: webapp
    spec:
      containers:
        - name: nginx
          image: nginx:stable
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "100m"
              memory: "128Mi"
```

> **Coach note:** Explain the difference:
> - **requests** — the minimum resources the scheduler guarantees to the Pod. Used for scheduling decisions (like reserving a seat on a flight).
> - **limits** — the maximum resources the container can use. Exceeding memory limits → OOMKill. Exceeding CPU limits → throttling.
> - `50m` CPU = 50 millicores = 5% of one CPU core.
> - `64Mi` memory = 64 mebibytes.

Apply the updated manifest:

```bash
kubectl apply -f webapp-deployment.yaml
```

Expected output:

```
deployment.apps/webapp configured
```

This triggers a rolling update because the Pod template changed.

**Wait for the rollout to complete:**

```bash
kubectl rollout status deployment/webapp
```

**Verify the resources are set:**

```bash
kubectl describe deployment webapp
```

Look for the `Containers` section:

```
  Containers:
   nginx:
    Image:      nginx:stable
    Port:       80/TCP
    Limits:
      cpu:     100m
      memory:  128Mi
    Requests:
      cpu:     50m
      memory:  64Mi
```

**Alternatively, inspect a specific Pod:**

```bash
POD_NAME=$(kubectl get pods -l app=webapp -o jsonpath='{.items[0].metadata.name}')
kubectl describe pod $POD_NAME | grep -A 6 "Limits\|Requests"
```

Expected output:

```
    Limits:
      cpu:     100m
      memory:  128Mi
    Requests:
      cpu:     50m
      memory:  64Mi
```

### Verification

- `kubectl describe deployment webapp` shows `Requests` and `Limits` under the container spec
- All 3 Pods are running with the resource constraints applied

---

## Cleanup

```bash
kubectl delete deployment webapp
```

Expected output:

```
deployment.apps/webapp deleted
```

Confirm all Pods are gone:

```bash
kubectl get pods -l app=webapp
```

Expected output:

```
No resources found in default namespace.
```

---

## Common Issues

| Issue | Symptom | Fix |
|---|---|---|
| `selector` doesn't match template labels | Deployment creation fails: `invalid: spec.template.metadata.labels: Invalid value` | Ensure `spec.selector.matchLabels` exactly matches `spec.template.metadata.labels` |
| Rolling update stuck | `kubectl rollout status` hangs forever | Check Pod events: `kubectl describe pods -l app=webapp`. Usually a bad image tag. Fix with `kubectl rollout undo deployment/webapp` |
| Students edit ReplicaSets directly | Changes get overwritten by the Deployment controller | Explain: always modify the **Deployment** spec. The Deployment controller owns the ReplicaSets |
| `kubectl scale` doesn't persist | After reapplying the YAML, replicas revert to the YAML value | Explain: `kubectl scale` is imperative. If they re-apply the YAML with `replicas: 3`, it overrides the scale command. For persistence, edit the YAML file |
| Resource values rejected | `must match the regex` or `quantities must match` | CPU uses millicores (`50m`), memory uses Mi/Gi (`64Mi`). Common mistake: `50M` (megabytes, not millicores) for CPU |
| Pods pending after adding resource requests | Pods stuck in `Pending` with "Insufficient cpu/memory" | The Kind cluster has limited resources. Lower the requests (e.g., `cpu: 10m, memory: 32Mi`) or reduce replicas |
| Students don't understand why rollout undo creates a new revision | They expect the revision number to go back to 1 | Explain: `undo` creates a new revision that happens to match an old template. History always moves forward. The old revision number is retired |
| OOMKilled Pods | Pod status shows `OOMKilled` | The memory limit is too low for the process. Increase `limits.memory`. Inspect with `kubectl describe pod <name>` → look at "Last State: Terminated, Reason: OOMKilled" |

