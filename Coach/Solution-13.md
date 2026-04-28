# Solution 13 — Troubleshooting (Break & Fix)

[< Back to Challenge](../Student/Challenge-13.md) | **[Home](README.md)**

---

> **Coach note:** This challenge is the capstone of Challenges 01–12. Students should work through each scenario independently using the troubleshooting loop: **Observe → Investigate → Diagnose → Fix → Verify**. Only provide hints if students are stuck for more than 10 minutes on a single scenario.

## Setup

Create the troubleshooting namespace:

```bash
kubectl create namespace troubleshooting
```

---

## Scenario 1: ImagePullBackOff 🖼️

### The Broken Manifest

```yaml
# scenario-1-imagepull.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: broken-image
  namespace: troubleshooting
spec:
  replicas: 1
  selector:
    matchLabels:
      app: broken-image
  template:
    metadata:
      labels:
        app: broken-image
    spec:
      containers:
      - name: web
        image: ngnix:latest
        ports:
        - containerPort: 80
```

```bash
kubectl apply -f scenario-1-imagepull.yaml
```

### Diagnostic Commands

```bash
# Step 1: Observe the symptom
kubectl get pods -n troubleshooting -l app=broken-image
```

Expected:

```
NAME                            READY   STATUS             RESTARTS   AGE
broken-image-xxxxxxxxx-xxxxx   0/1     ImagePullBackOff   0          30s
```

```bash
# Step 2: Investigate — read the Events section
kubectl describe pod -l app=broken-image -n troubleshooting
```

Key event in the output:

```
Warning  Failed   Failed to pull image "ngnix:latest": ... manifest unknown
Warning  Failed   Error: ErrImagePull
Warning  BackOff  Back-off pulling image "ngnix:latest"
```

### Root Cause

The image name is `ngnix` — the letters `i` and `n` are transposed. It should be `nginx`.

### Fix

```bash
kubectl set image deployment/broken-image web=nginx:latest -n troubleshooting
```

### Verification

```bash
kubectl get pods -n troubleshooting -l app=broken-image
```

Expected:

```
NAME                            READY   STATUS    RESTARTS   AGE
broken-image-xxxxxxxxx-xxxxx   1/1     Running   0          15s
```

> **Coach tip:** This is the easiest scenario — a simple typo. The key lesson is that `kubectl describe pod` reveals the exact image pull error in the Events section.

---

## Scenario 2: CrashLoopBackOff 💥

### The Broken Manifest

```yaml
# scenario-2-crashloop.yaml
apiVersion: v1
kind: Pod
metadata:
  name: crashloop-app
  namespace: troubleshooting
spec:
  containers:
  - name: app
    image: busybox:1.37
    command: ["cat", "/config/app.conf"]
```

```bash
kubectl apply -f scenario-2-crashloop.yaml
```

### Diagnostic Commands

```bash
# Step 1: Observe
kubectl get pods -n troubleshooting
```

Expected:

```
NAME             READY   STATUS             RESTARTS      AGE
crashloop-app    0/1     CrashLoopBackOff   3 (20s ago)   60s
```

```bash
# Step 2: Check container logs — what did it print before dying?
kubectl logs crashloop-app -n troubleshooting
```

Expected:

```
cat: can't open '/config/app.conf': No such file or directory
```

```bash
# If the container already restarted, check the previous instance:
kubectl logs crashloop-app -n troubleshooting --previous
```

### Root Cause

The container runs `cat /config/app.conf`, but that file doesn't exist. The command exits immediately with a non-zero exit code, causing the restart loop.

### Fix

Delete the broken Pod and create one with a command that stays running:

```bash
kubectl delete pod crashloop-app -n troubleshooting
```

```yaml
# scenario-2-fixed.yaml
apiVersion: v1
kind: Pod
metadata:
  name: crashloop-app
  namespace: troubleshooting
spec:
  containers:
  - name: app
    image: busybox:1.37
    command: ["sh", "-c", "echo 'App started' && sleep infinity"]
```

```bash
kubectl apply -f scenario-2-fixed.yaml
```

### Verification

```bash
kubectl get pod crashloop-app -n troubleshooting
```

Expected:

```
NAME             READY   STATUS    RESTARTS   AGE
crashloop-app    1/1     Running   0          10s
```

> **Coach tip:** The key lesson is using `kubectl logs` and `kubectl logs --previous` to see what the container printed before it died. This is the equivalent of `journalctl -u <service>` on Linux.

---

## Scenario 3: Pending Pod (Insufficient Resources) ⏳

### The Broken Manifest

```yaml
# scenario-3-pending.yaml
apiVersion: v1
kind: Pod
metadata:
  name: hungry-pod
  namespace: troubleshooting
spec:
  containers:
  - name: hungry
    image: nginx:1.27
    resources:
      requests:
        memory: "64Gi"
        cpu: "100m"
```

```bash
kubectl apply -f scenario-3-pending.yaml
```

### Diagnostic Commands

```bash
# Step 1: Observe — Pod is stuck in Pending
kubectl get pods -n troubleshooting
```

Expected:

```
NAME         READY   STATUS    RESTARTS   AGE
hungry-pod   0/1     Pending   0          45s
```

```bash
# Step 2: Investigate — WHY is it Pending?
kubectl describe pod hungry-pod -n troubleshooting
```

Key event:

```
Warning  FailedScheduling  0/1 nodes are available: 1 Insufficient memory.
```

```bash
# Step 3: Check node capacity
kubectl describe node | grep -A 5 "Allocatable:"
```

Expected: A Kind node typically has 8–16Gi of allocatable memory. The Pod requests 64Gi — impossible to schedule.

### Root Cause

The Pod requests 64Gi of memory, which exceeds the allocatable memory of any node in the Kind cluster.

### Fix

```bash
kubectl delete pod hungry-pod -n troubleshooting
```

```yaml
# scenario-3-fixed.yaml
apiVersion: v1
kind: Pod
metadata:
  name: hungry-pod
  namespace: troubleshooting
spec:
  containers:
  - name: hungry
    image: nginx:1.27
    resources:
      requests:
        memory: "128Mi"
        cpu: "100m"
```

```bash
kubectl apply -f scenario-3-fixed.yaml
```

### Verification

```bash
kubectl get pod hungry-pod -n troubleshooting
```

Expected:

```
NAME         READY   STATUS    RESTARTS   AGE
hungry-pod   1/1     Running   0          15s
```

> **Coach tip:** `Pending` pods were never scheduled. The `kubectl describe` Events section always tells you why — usually `Insufficient memory`, `Insufficient cpu`, or taint/toleration mismatches. This is the equivalent of a process failing to start because the server ran out of RAM.

---

## Scenario 4: Service Not Routing (Label Mismatch) 🏷️

### The Broken Manifest

```yaml
# scenario-4-labels.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-deploy
  namespace: troubleshooting
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web-frontend
  template:
    metadata:
      labels:
        app: web-frontend
    spec:
      containers:
      - name: nginx
        image: nginx:1.27
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: web-svc
  namespace: troubleshooting
spec:
  selector:
    app: web-backend
  ports:
  - port: 80
    targetPort: 80
```

```bash
kubectl apply -f scenario-4-labels.yaml
```

### Diagnostic Commands

```bash
# Step 1: Pods are Running — looks fine at first glance
kubectl get pods -n troubleshooting -l app=web-frontend
```

Expected: 2 pods Running.

```bash
# Step 2: Check Service endpoints — this reveals the problem
kubectl get endpoints web-svc -n troubleshooting
```

Expected:

```
NAME      ENDPOINTS   AGE
web-svc   <none>      30s
```

**No endpoints!** Traffic goes nowhere.

```bash
# Step 3: Compare Service selector with Pod labels
kubectl describe svc web-svc -n troubleshooting | grep Selector
# Selector: app=web-backend

kubectl get pods -n troubleshooting --show-labels
# app=web-frontend
```

### Root Cause

The Service selects `app: web-backend`, but the Pods are labeled `app: web-frontend`. The selector doesn't match, so the Service has zero endpoints.

### Fix

```bash
kubectl patch svc web-svc -n troubleshooting \
  -p '{"spec":{"selector":{"app":"web-frontend"}}}'
```

### Verification

```bash
kubectl get endpoints web-svc -n troubleshooting
```

Expected:

```
NAME      ENDPOINTS                       AGE
web-svc   10.244.x.x:80,10.244.x.x:80   5s
```

> **Coach tip:** This is one of the most common real-world mistakes. The debugging pattern is: Service has no endpoints → compare `kubectl describe svc` selector with `kubectl get pods --show-labels`. This is like checking that Nginx's `upstream` block points to the right backend IPs.

---

## Scenario 5: PVC Stuck in Pending 💾

### The Broken Manifest

```yaml
# scenario-5-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-pvc
  namespace: troubleshooting
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: premium-fast
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: data-pod
  namespace: troubleshooting
spec:
  containers:
  - name: writer
    image: busybox:1.37
    command: ["sh", "-c", "echo hello > /data/test.txt && sleep infinity"]
    volumeMounts:
    - name: data-vol
      mountPath: /data
  volumes:
  - name: data-vol
    persistentVolumeClaim:
      claimName: data-pvc
```

```bash
kubectl apply -f scenario-5-pvc.yaml
```

### Diagnostic Commands

```bash
# Step 1: Observe — both PVC and Pod are Pending
kubectl get pvc -n troubleshooting
```

Expected:

```
NAME       STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
data-pvc   Pending                                       premium-fast   30s
```

```bash
kubectl get pod data-pod -n troubleshooting
# STATUS: Pending (waiting for PVC)
```

```bash
# Step 2: Investigate the PVC
kubectl describe pvc data-pvc -n troubleshooting
```

Key event:

```
Warning  ProvisioningFailed  storageclass.storage.k8s.io "premium-fast" not found
```

```bash
# Step 3: Check available StorageClasses
kubectl get storageclass
```

Expected:

```
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      AGE
standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   1h
```

### Root Cause

The PVC references StorageClass `premium-fast`, which doesn't exist. Kind uses `standard` as its default StorageClass.

### Fix

```bash
kubectl delete pod data-pod -n troubleshooting
kubectl delete pvc data-pvc -n troubleshooting
```

Edit the manifest: change `storageClassName: premium-fast` to `storageClassName: standard` (or remove the `storageClassName` field entirely to use the default):

```yaml
# scenario-5-fixed.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-pvc
  namespace: troubleshooting
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: standard
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: data-pod
  namespace: troubleshooting
spec:
  containers:
  - name: writer
    image: busybox:1.37
    command: ["sh", "-c", "echo hello > /data/test.txt && sleep infinity"]
    volumeMounts:
    - name: data-vol
      mountPath: /data
  volumes:
  - name: data-vol
    persistentVolumeClaim:
      claimName: data-pvc
```

```bash
kubectl apply -f scenario-5-fixed.yaml
```

### Verification

```bash
kubectl get pvc -n troubleshooting
```

Expected:

```
NAME       STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
data-pvc   Bound    pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   1Gi        RWO            standard       15s
```

```bash
kubectl get pod data-pod -n troubleshooting
```

Expected: `Running`.

> **Coach tip:** The lesson is that PVCs depend on StorageClasses. Always check `kubectl get storageclass` to see what's available. On Kind it's `standard`; on cloud it's `managed-csi` (AKS), `gp2` (EKS), or `standard-rwo` (GKE).

---

## Scenario 6: RBAC Forbidden 🔐

### The Broken Manifest

```yaml
# scenario-6-rbac.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pod-reader
  namespace: troubleshooting
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader-role
  namespace: troubleshooting
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
```

```bash
kubectl apply -f scenario-6-rbac.yaml
```

### Diagnostic Commands

```bash
# Step 1: Test permissions
kubectl auth can-i list pods \
  --as=system:serviceaccount:troubleshooting:pod-reader \
  -n troubleshooting
```

Expected:

```
no
```

```bash
# Step 2: The Role exists with correct permissions
kubectl describe role pod-reader-role -n troubleshooting
```

Expected: Resources: pods, Verbs: get, list, watch ✓

```bash
# Step 3: Check for RoleBindings
kubectl get rolebindings -n troubleshooting
```

Expected:

```
No resources found in troubleshooting namespace.
```

### Root Cause

There is a Role with the correct permissions, and there is a ServiceAccount, but there is **no RoleBinding** connecting them. Without the binding, the permission is never granted. RBAC requires all three: Role + RoleBinding + Subject.

### Fix

```yaml
# scenario-6-fix-rolebinding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pod-reader-binding
  namespace: troubleshooting
subjects:
- kind: ServiceAccount
  name: pod-reader
  namespace: troubleshooting
roleRef:
  kind: Role
  name: pod-reader-role
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f scenario-6-fix-rolebinding.yaml
```

### Verification

```bash
kubectl auth can-i list pods \
  --as=system:serviceaccount:troubleshooting:pod-reader \
  -n troubleshooting
```

Expected:

```
yes
```

> **Coach tip:** The RBAC triad is: **Role** (what permissions) + **RoleBinding** (who gets them) + **Subject** (the identity). Missing any one of the three means "no access." This is the equivalent of creating a sudoers rule but never adding the user to the group.

---

## Scenario 7: Ingress Returns 503 🌐

### Prerequisites

Ensure the NGINX Ingress Controller is installed:

```bash
kubectl get pods -n ingress-nginx
```

If not installed:

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=90s
```

### The Broken Manifest

```yaml
# scenario-7-ingress.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend-app
  namespace: troubleshooting
spec:
  replicas: 1
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
        image: hashicorp/http-echo:latest
        args:
        - "-text=Scenario 7 works!"
        ports:
        - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: backend-svc
  namespace: troubleshooting
spec:
  selector:
    app: backend
  ports:
  - port: 80
    targetPort: 9999
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: broken-ingress
  namespace: troubleshooting
spec:
  ingressClassName: nginx
  rules:
  - host: scenario7.localhost
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: backend-svc
            port:
              number: 80
```

```bash
kubectl apply -f scenario-7-ingress.yaml
```

### Diagnostic Commands

```bash
# Step 1: Test the ingress
curl http://scenario7.localhost/
```

Expected:

```html
<html><body><h1>503 Service Temporarily Unavailable</h1></body></html>
```

```bash
# Step 2: Pod is Running — check ✓
kubectl get pods -l app=backend -n troubleshooting

# Step 3: Service has endpoints — but look at the PORT
kubectl get endpoints backend-svc -n troubleshooting
```

Expected:

```
NAME          ENDPOINTS          AGE
backend-svc   10.244.x.x:9999   30s
```

The endpoint port is **9999** — but `http-echo` listens on port **5678**!

```bash
# Step 4: Confirm the mismatch
kubectl describe svc backend-svc -n troubleshooting | grep -i targetport
# TargetPort: 9999
```

### Root Cause

The Service `targetPort` is `9999`, but the `hashicorp/http-echo` container listens on port **5678**. The Ingress Controller forwards traffic to the Service → Service forwards to port 9999 → connection refused at the Pod → Ingress returns 503.

### Fix

```bash
kubectl patch svc backend-svc -n troubleshooting \
  -p '{"spec":{"ports":[{"port":80,"targetPort":5678}]}}'
```

### Verification

```bash
curl http://scenario7.localhost/
```

Expected:

```
Scenario 7 works!
```

> **Coach tip:** 503 from an Ingress usually means the backend is unreachable. The debugging path is: check endpoints exist → check targetPort matches the container's listening port → check the container is actually listening. This is the same as troubleshooting Nginx → HAProxy → backend where the proxy config points to the wrong port.

---

## Scenario 8: OOMKilled 💀

### The Broken Manifest

```yaml
# scenario-8-oomkilled.yaml
apiVersion: v1
kind: Pod
metadata:
  name: leaky-app
  namespace: troubleshooting
spec:
  containers:
  - name: stress
    image: polinux/stress:latest
    command: ["stress"]
    args: ["--vm", "1", "--vm-bytes", "256M", "--vm-hang", "0"]
    resources:
      limits:
        memory: "64Mi"
      requests:
        memory: "32Mi"
```

```bash
kubectl apply -f scenario-8-oomkilled.yaml
```

### Diagnostic Commands

```bash
# Step 1: Observe — OOMKilled status
kubectl get pods -n troubleshooting
```

Expected:

```
NAME        READY   STATUS      RESTARTS      AGE
leaky-app   0/1     OOMKilled   3 (20s ago)   60s
```

```bash
# Step 2: Investigate
kubectl describe pod leaky-app -n troubleshooting
```

Key information in the container status:

```
Last State:  Terminated
  Reason:    OOMKilled
  Exit Code: 137
```

```bash
# Step 3: Understand the mismatch
# The stress tool tries to allocate 256M
# The memory limit is only 64Mi
# The kernel OOM killer terminates the process (exit code 137 = SIGKILL)
```

### Root Cause

The `stress` tool is configured to allocate 256M of memory (`--vm-bytes 256M`), but the container has a hard memory limit of 64Mi. When the process exceeds 64Mi, the Linux kernel's OOM killer terminates it (exit code 137 = SIGKILL).

### Fix

Either increase the memory limit OR reduce the memory consumption. The fix does both for stability:

```bash
kubectl delete pod leaky-app -n troubleshooting
```

```yaml
# scenario-8-fixed.yaml
apiVersion: v1
kind: Pod
metadata:
  name: leaky-app
  namespace: troubleshooting
spec:
  containers:
  - name: stress
    image: polinux/stress:latest
    command: ["stress"]
    args: ["--vm", "1", "--vm-bytes", "64M", "--vm-hang", "0"]
    resources:
      limits:
        memory: "256Mi"
      requests:
        memory: "128Mi"
```

```bash
kubectl apply -f scenario-8-fixed.yaml
```

### Verification

```bash
kubectl get pod leaky-app -n troubleshooting
```

Expected:

```
NAME        READY   STATUS    RESTARTS   AGE
leaky-app   1/1     Running   0          15s
```

```bash
# Confirm it's actually using memory
kubectl top pod leaky-app -n troubleshooting
```

Expected: Memory usage around 64Mi.

> **Coach tip:** OOMKilled is the Kubernetes equivalent of the Linux OOM killer (`dmesg | grep -i oom`). Exit code 137 = 128 + 9 (SIGKILL). The lesson: always set memory limits higher than the application's peak working set, and set requests to the typical usage.

---

## Cleanup

```bash
kubectl delete namespace troubleshooting
```

This removes all resources in the namespace at once.

---

## Common Issues

| Problem | Cause | Fix |
|---------|-------|-----|
| Student can't tell ImagePullBackOff from CrashLoopBackOff | Both show error status but different root causes | ImagePullBackOff = image doesn't exist; CrashLoopBackOff = image exists but process dies |
| `kubectl logs` returns "no logs" for Pending pods | Pending pods were never scheduled, so no container ran | Use `kubectl describe pod` instead — check the Events section for scheduling failures |
| Scenario 7 curl returns "connection refused" instead of 503 | NGINX Ingress Controller not installed | Install it: `kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml` |
| PVC stays Pending even after fixing StorageClass | Must delete and recreate PVC — `storageClassName` is immutable | `kubectl delete pvc <name>` then re-apply with correct StorageClass |
| Student patches the wrong field | JSON patch syntax confusion | Show them the exact `kubectl patch` command from the solution |
| OOMKilled happens too fast to observe | The stress tool exceeds limits within seconds | Have students run `kubectl get pods --watch` in one terminal before applying the manifest |

## Troubleshooting Loop Summary (for coach reference)

For **every** broken scenario, the loop is the same:

```
1. kubectl get pods -n troubleshooting              → What status?
2. kubectl describe pod <name> -n troubleshooting    → Read the Events section
3. kubectl logs <name> -n troubleshooting            → What did the container print?
4. kubectl get events -n troubleshooting --sort-by='.lastTimestamp'  → Cluster-wide view
5. Fix the manifest and re-apply
6. Verify the fix
```

The Events section of `kubectl describe` is the single most useful piece of output. **Read it every time.**
