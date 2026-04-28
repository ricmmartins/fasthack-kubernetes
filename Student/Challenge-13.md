# Challenge 13 — Troubleshooting

[< Previous Challenge](Challenge-12.md) | **[Home](../README.md)** | [Next Challenge >](Challenge-14.md)

## Introduction

If you're a Linux administrator, you already have a troubleshooting playbook burned into muscle memory: something breaks, you check `dmesg` for kernel messages, `journalctl -xe` for service logs, `strace` to trace a misbehaving process, `netstat` to verify listeners, and `free -h` when you suspect memory pressure. You work systematically from symptoms to root cause.

Kubernetes troubleshooting follows the **exact same philosophy** — different tools, same mental model. Instead of `dmesg`, you read cluster events. Instead of `journalctl`, you `kubectl describe` a Pod. Instead of `strace`, you attach a debug container. The commands are different, but the thought process is identical: **observe symptoms → form hypothesis → verify → fix → confirm**.

This challenge is **different from every challenge before it**. There are no new concepts to learn. Instead, you get **eight broken deployments** — each with a deliberate bug — and your job is to diagnose and fix each one. This is where everything you learned in Challenges 01–12 comes together.

## Description

This challenge is **entirely break & fix**. Apply each broken manifest below (Scenarios 1–8 in the Break & Fix section), diagnose the problem, and fix it. The scenarios are ordered from easiest to hardest.

Your mission is to:

1. **Create a namespace for this challenge**

   ```bash
   kubectl create namespace troubleshooting
   ```

2. **Work through all 8 scenarios** in the [Break & Fix](#break--fix-) section below — apply each broken manifest, observe the symptoms, diagnose the root cause, and apply a fix.

3. **For each scenario, follow this systematic approach** (the same loop every time):
   - Apply the broken manifest
   - Observe: `kubectl get pods -n troubleshooting` — what status do you see?
   - Investigate: `kubectl describe pod <name> -n troubleshooting` — read the Events section
   - Dig deeper: `kubectl logs <name> -n troubleshooting` — check container output
   - Broader view: `kubectl get events -n troubleshooting --sort-by='.lastTimestamp'` — cluster-level events
   - Fix the manifest and re-apply

4. **Keep notes** — for each scenario, write down:
   - The symptom you observed
   - The `kubectl` command that revealed the root cause
   - The fix you applied

## Success Criteria

- [ ] All 8 scenarios have been diagnosed and fixed
- [ ] Scenario 1: Pod `broken-image` is Running with the correct nginx image
- [ ] Scenario 2: Pod `crashloop-app` is Running and not restarting
- [ ] Scenario 3: Pod `hungry-pod` is Running (not stuck in Pending)
- [ ] Scenario 4: Service `web-svc` has at least one Endpoint
- [ ] Scenario 5: PVC `data-pvc` is Bound
- [ ] Scenario 6: ServiceAccount `pod-reader` can list pods (`kubectl auth can-i list pods --as=system:serviceaccount:troubleshooting:pod-reader -n troubleshooting` returns `yes`)
- [ ] Scenario 7: Ingress `broken-ingress` routes traffic to the backend successfully (no 503)
- [ ] Scenario 8: Pod `leaky-app` is Running and stays Running (not OOMKilled)
- [ ] You can explain the diagnostic command that revealed each root cause

## Linux ↔ Kubernetes Reference

| Linux Command | Kubernetes Equivalent | What It Tells You |
|---|---|---|
| `dmesg` | `kubectl get events --sort-by='.lastTimestamp'` | Cluster-wide events: scheduling failures, image pulls, OOM kills |
| `journalctl -xe` | `kubectl describe pod <name>` | Detailed status of a single resource — conditions, events, state |
| `strace -p <PID>` | `kubectl debug -it <pod> --image=busybox --target=<container>` | Attach a debug container to inspect a running process |
| `systemctl status <svc>` | `kubectl get pods -o wide` | Quick status check — is it running, where, what IP? |
| `netstat -tlnp` / `ss -tlnp` | `kubectl get svc,endpoints` | Verify listeners and backend targets |
| `/var/log/messages` | `kubectl logs <pod> [-c container]` | Application stdout/stderr output |
| `free -h` | `kubectl top nodes` / `kubectl top pods` | Memory and CPU consumption |
| `lsof -i :<port>` | `kubectl exec <pod> -- netstat -tlnp` | Check which process owns a port inside a Pod |

## Hints

<details>
<summary>Hint 1: The universal troubleshooting loop</summary>

For **every** broken Pod, start with these three commands in this order:

```bash
# 1. What status is the Pod in?
kubectl get pods -n troubleshooting

# 2. WHY is it in that status? (read the Events at the bottom)
kubectl describe pod <pod-name> -n troubleshooting

# 3. What did the container print before it died?
kubectl logs <pod-name> -n troubleshooting
```

The `Events` section at the bottom of `kubectl describe` is the single most useful piece of output. Read it **every time**.
</details>

<details>
<summary>Hint 2: ImagePullBackOff — the image name is wrong</summary>

When you see `ImagePullBackOff` or `ErrImagePull`, Kubernetes cannot download the container image. Common causes:

- Typo in the image name (check spelling carefully!)
- Wrong tag (`:lastest` vs `:latest`)
- Private registry without `imagePullSecrets`

To verify: `kubectl describe pod <name> -n troubleshooting` will show the exact error message, such as `manifest unknown` or `repository does not exist`.

To fix a running deployment:
```bash
kubectl set image deployment/<name> <container>=<correct-image> -n troubleshooting
```
</details>

<details>
<summary>Hint 3: CrashLoopBackOff — the container keeps dying</summary>

`CrashLoopBackOff` means the container starts, exits, and Kubernetes restarts it — over and over with exponential backoff.

Check **why** it exits:
```bash
kubectl logs <pod-name> -n troubleshooting
# If the container already restarted, check the PREVIOUS instance:
kubectl logs <pod-name> -n troubleshooting --previous
```

Common causes:
- Bad command/entrypoint — the process exits immediately
- Missing environment variable that the app requires
- App crashes on startup (segfault, uncaught exception)
</details>

<details>
<summary>Hint 4: Pending Pods — scheduling failures</summary>

A Pod stuck in `Pending` was never scheduled to a node. Check why:

```bash
kubectl describe pod <name> -n troubleshooting
```

Look for events like:
- `FailedScheduling` — `Insufficient memory` or `Insufficient cpu`
- `0/1 nodes are available: 1 Insufficient memory`

On a Kind cluster, check node capacity:
```bash
kubectl describe node | grep -A 5 "Allocatable"
```

If the Pod requests more resources than any node has, reduce the request.
</details>

<details>
<summary>Hint 5: Service not routing — selector mismatch</summary>

If a Service has no Endpoints, traffic goes nowhere. Check:

```bash
# Does the service have endpoints?
kubectl get endpoints <svc-name> -n troubleshooting

# What selector is the service using?
kubectl describe svc <svc-name> -n troubleshooting

# What labels do the pods have?
kubectl get pods -n troubleshooting --show-labels
```

The Service selector must **exactly** match the Pod labels. Even `app: web` vs `app: Web` is a mismatch!
</details>

<details>
<summary>Hint 6: PVC Pending and RBAC Forbidden</summary>

**PVC Pending:**
```bash
kubectl describe pvc <name> -n troubleshooting
```
Look for: `storageclass.storage.k8s.io "<name>" not found`. List available StorageClasses:
```bash
kubectl get storageclass
```
On Kind, the default StorageClass is `standard`.

**RBAC Forbidden:**
Test permissions explicitly:
```bash
kubectl auth can-i list pods --as=system:serviceaccount:troubleshooting:pod-reader -n troubleshooting
```
If it says `no`, you need a Role + RoleBinding. Check what exists:
```bash
kubectl get roles,rolebindings -n troubleshooting
```
</details>

## Learning Resources

- [Kubernetes — Troubleshooting Applications](https://kubernetes.io/docs/tasks/debug/debug-application/)
- [Kubernetes — Troubleshooting Clusters](https://kubernetes.io/docs/tasks/debug/debug-cluster/)
- [Kubernetes — Debug Pods](https://kubernetes.io/docs/tasks/debug/debug-application/debug-pods/)
- [Kubernetes — Debug Services](https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/)
- [Kubernetes — Debug Running Pods (ephemeral containers)](https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/)
- [Kubernetes — Resource Management](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)
- [Kubernetes — RBAC Authorization](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
- [Kubernetes — Events](https://kubernetes.io/docs/reference/kubernetes-api/cluster-resources/event-v1/)

---

## Break & Fix 🔧

Work through each scenario in order. They get progressively harder.

---

### Scenario 1: ImagePullBackOff 🖼️

**Apply the broken manifest:**

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

**Symptoms you'll see:**
```
NAME                            READY   STATUS             RESTARTS   AGE
broken-image-xxxxxxxxx-xxxxx   0/1     ImagePullBackOff   0          30s
```

**Your task:** Diagnose why the image can't be pulled and fix the Deployment.

<details>
<summary>💡 Solution</summary>

**Diagnosis:**
```bash
kubectl describe pod -l app=broken-image -n troubleshooting
```
In the Events section you'll see:
```
Failed to pull image "ngnix:latest": ... manifest unknown
```

**Root cause:** The image name is `ngnix` — it should be `nginx` (letters transposed).

**Fix:**
```bash
kubectl set image deployment/broken-image web=nginx:latest -n troubleshooting
```

**Verify:**
```bash
kubectl get pods -n troubleshooting -l app=broken-image
# STATUS should be Running
```
</details>

---

### Scenario 2: CrashLoopBackOff 💥

**Apply the broken manifest:**

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

**Symptoms you'll see:**
```
NAME             READY   STATUS             RESTARTS      AGE
crashloop-app    0/1     CrashLoopBackOff   3 (20s ago)   60s
```

**Your task:** Figure out why the container keeps crashing and fix it so it stays running.

<details>
<summary>💡 Solution</summary>

**Diagnosis:**
```bash
kubectl logs crashloop-app -n troubleshooting
```
Output:
```
cat: can't open '/config/app.conf': No such file or directory
```

**Root cause:** The container runs `cat /config/app.conf`, but that file doesn't exist. The command exits immediately with an error, causing the restart loop.

**Fix:** Delete the broken Pod and create one with a command that stays running:

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

**Verify:**
```bash
kubectl get pod crashloop-app -n troubleshooting
# STATUS: Running, RESTARTS: 0
```
</details>

---

### Scenario 3: Pending Pod (Insufficient Resources) ⏳

**Apply the broken manifest:**

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

**Symptoms you'll see:**
```
NAME         READY   STATUS    RESTARTS   AGE
hungry-pod   0/1     Pending   0          45s
```

The Pod stays in `Pending` forever — it is never scheduled.

**Your task:** Diagnose why the Pod can't be scheduled and fix it.

<details>
<summary>💡 Solution</summary>

**Diagnosis:**
```bash
kubectl describe pod hungry-pod -n troubleshooting
```
In the Events section:
```
Warning  FailedScheduling  0/1 nodes are available: 1 Insufficient memory.
```

Check how much memory your Kind node actually has:
```bash
kubectl describe node | grep -A 5 "Allocatable:"
```
A typical Kind node has 8–16Gi. The Pod requests 64Gi — impossible to schedule.

**Fix:** Delete and recreate with a reasonable memory request:

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

**Verify:**
```bash
kubectl get pod hungry-pod -n troubleshooting
# STATUS: Running
```
</details>

---

### Scenario 4: Service Not Routing (Label Mismatch) 🏷️

**Apply the broken manifest:**

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

**Symptoms you'll see:**

The Pods are Running, the Service exists, but:
```bash
kubectl get endpoints web-svc -n troubleshooting
# ENDPOINTS: <none>
```
Any request to the Service times out or returns connection refused.

**Your task:** Figure out why the Service has no endpoints and fix it.

<details>
<summary>💡 Solution</summary>

**Diagnosis:**
```bash
# Check the service selector
kubectl describe svc web-svc -n troubleshooting
# Selector: app=web-backend

# Check the pod labels
kubectl get pods -n troubleshooting --show-labels
# Labels include: app=web-frontend
```

**Root cause:** The Service selects `app: web-backend`, but the Pods are labeled `app: web-frontend`. The selector doesn't match, so the Service has zero endpoints.

**Fix:** Patch the Service selector to match the Pod labels:

```bash
kubectl patch svc web-svc -n troubleshooting -p '{"spec":{"selector":{"app":"web-frontend"}}}'
```

**Verify:**
```bash
kubectl get endpoints web-svc -n troubleshooting
# ENDPOINTS: 10.244.x.x:80,10.244.x.x:80
```
</details>

---

### Scenario 5: PVC Stuck in Pending 💾

**Apply the broken manifest:**

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

**Symptoms you'll see:**
```bash
kubectl get pvc -n troubleshooting
# NAME       STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
# data-pvc   Pending                                       premium-fast   30s

kubectl get pod data-pod -n troubleshooting
# NAME       READY   STATUS    RESTARTS   AGE
# data-pod   0/1     Pending   0          30s
```

Both the PVC and Pod are stuck in Pending.

**Your task:** Diagnose why the PVC can't be bound and fix it.

<details>
<summary>💡 Solution</summary>

**Diagnosis:**
```bash
kubectl describe pvc data-pvc -n troubleshooting
```
In the Events section:
```
Warning  ProvisioningFailed  storageclass.storage.k8s.io "premium-fast" not found
```

Check what StorageClasses are available:
```bash
kubectl get storageclass
# NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
# standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer
```

**Root cause:** The PVC references StorageClass `premium-fast`, which doesn't exist. Kind uses `standard` as its default StorageClass.

**Fix:** Delete and recreate with the correct StorageClass:

```bash
kubectl delete pod data-pod -n troubleshooting
kubectl delete pvc data-pvc -n troubleshooting
```

Edit the manifest to change `storageClassName: premium-fast` to `storageClassName: standard` (or remove the `storageClassName` field entirely to use the default), then re-apply.

**Verify:**
```bash
kubectl get pvc -n troubleshooting
# STATUS: Bound

kubectl get pod data-pod -n troubleshooting
# STATUS: Running
```
</details>

---

### Scenario 6: RBAC Forbidden 🔐

**Apply the broken manifest:**

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

**Symptoms you'll see:**

The ServiceAccount exists, the Role exists, but:

```bash
kubectl auth can-i list pods --as=system:serviceaccount:troubleshooting:pod-reader -n troubleshooting
# no
```

The ServiceAccount is **forbidden** from listing Pods, even though a Role granting that permission exists.

**Your task:** Diagnose why the ServiceAccount can't list Pods and fix it.

<details>
<summary>💡 Solution</summary>

**Diagnosis:**
```bash
# The Role exists with the correct permissions:
kubectl describe role pod-reader-role -n troubleshooting
# Resources: pods — Verbs: get, list, watch  ✓

# But is there a RoleBinding connecting the ServiceAccount to the Role?
kubectl get rolebindings -n troubleshooting
# No resources found
```

**Root cause:** There is a Role, and there is a ServiceAccount, but there is **no RoleBinding** connecting them. Without the binding, the permission is never granted.

**Fix:** Create the missing RoleBinding:

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

**Verify:**
```bash
kubectl auth can-i list pods --as=system:serviceaccount:troubleshooting:pod-reader -n troubleshooting
# yes
```
</details>

---

### Scenario 7: Ingress Returns 503 🌐

> **Prerequisite:** This scenario requires the NGINX Ingress Controller from Challenge 06. If you don't have it installed, run:
> ```bash
> kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
> kubectl wait --namespace ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=90s
> ```

**Apply the broken manifest:**

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

**Symptoms you'll see:**

```bash
curl http://scenario7.localhost/
# <html><body><h1>503 Service Temporarily Unavailable</h1></body></html>
```

The Ingress is configured, the Pod is Running, the Service has endpoints — but you get 503.

**Your task:** Diagnose why the Ingress returns 503 and fix it.

<details>
<summary>💡 Solution</summary>

**Diagnosis:**
```bash
# Pod is running — check
kubectl get pods -l app=backend -n troubleshooting

# Service has endpoints — check
kubectl get endpoints backend-svc -n troubleshooting
# ENDPOINTS: 10.244.x.x:9999

# Wait — the endpoint port is 9999, but the container listens on 5678!
kubectl describe svc backend-svc -n troubleshooting
# TargetPort: 9999
```

The Service forwards traffic to port 9999, but `http-echo` listens on port **5678**. The connection is refused at the Pod level, and the Ingress Controller translates that to a 503.

**Root cause:** The Service `targetPort` is `9999` — it should be `5678` to match the container's listening port.

**Fix:**
```bash
kubectl patch svc backend-svc -n troubleshooting -p '{"spec":{"ports":[{"port":80,"targetPort":5678}]}}'
```

**Verify:**
```bash
curl http://scenario7.localhost/
# Scenario 7 works!
```
</details>

---

### Scenario 8: OOMKilled 💀

**Apply the broken manifest:**

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

**Symptoms you'll see:**
```bash
kubectl get pods -n troubleshooting
# NAME        READY   STATUS      RESTARTS      AGE
# leaky-app   0/1     OOMKilled   3 (20s ago)   60s
```

The Pod keeps restarting with `OOMKilled` status.

**Your task:** Diagnose what's happening and fix it so the Pod stays running.

<details>
<summary>💡 Solution</summary>

**Diagnosis:**
```bash
kubectl describe pod leaky-app -n troubleshooting
```
In the container status section:
```
Last State:  Terminated
  Reason:    OOMKilled
  Exit Code: 137
```

The `stress` tool is configured to allocate 256M of memory (`--vm-bytes 256M`), but the container has a hard memory limit of 64Mi. When the process exceeds 64Mi, the Linux kernel's OOM killer terminates it (exit code 137 = SIGKILL).

**Root cause:** The memory limit (64Mi) is far below what the process needs (256M).

**Fix:** Either increase the memory limit to accommodate the workload, or reduce the memory consumption. Delete and recreate:

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

**Verify:**
```bash
kubectl get pod leaky-app -n troubleshooting
# STATUS: Running, RESTARTS: 0

# Confirm it's actually using memory:
kubectl top pod leaky-app -n troubleshooting
```
</details>

---

## 🏆 Bonus: Debug Like a Pro

After completing all 8 scenarios, try these power moves:

**Ephemeral debug containers** — attach a troubleshooting container to a running Pod without modifying it:
```bash
kubectl debug -it <pod-name> -n troubleshooting --image=busybox:1.37 --target=<container-name>
```

**Node-level debugging** — get a shell on the Kind node itself:
```bash
kubectl debug node/<node-name> -it --image=busybox:1.37
```

**Rapid event monitoring** — watch events in real time as you apply broken manifests:
```bash
kubectl get events -n troubleshooting --watch
```

---

> **🎉 Congratulations!** If you made it through all 8 scenarios, you've built a real troubleshooting toolkit. These are the same failure modes you'll see in production — now you know how to diagnose them systematically.
