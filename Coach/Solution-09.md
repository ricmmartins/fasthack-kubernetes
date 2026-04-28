# Solution 09 — RBAC and Security

[< Back to Challenge](../Student/Challenge-09.md) | **[Home](README.md)**

## Notes for Coaches

This is one of the more conceptually dense challenges. The Linux analogy works very well here — lean on it. The key message: RBAC is just users, groups, and permissions with different names; PSA is SELinux enforcement levels.

**Important:** PodSecurityPolicy (PSP) was **removed** in Kubernetes v1.25. If students mention PSP, redirect them to Pod Security Admission (PSA). User Namespaces are GA in v1.36 but not required for this challenge.

Estimated time: **60 minutes**

---

## Task 1: Create a ServiceAccount

### Step-by-step

```bash
kubectl create namespace secure-ns
kubectl create serviceaccount app-reader -n secure-ns
```

Save `reader-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: reader-pod
  namespace: secure-ns
spec:
  serviceAccountName: app-reader
  containers:
  - name: kubectl-shell
    image: bitnami/kubectl:latest
    command: ["sleep", "3600"]
```

```bash
kubectl apply -f reader-pod.yaml
kubectl wait --for=condition=Ready pod/reader-pod -n secure-ns --timeout=120s
```

### Verification

```bash
kubectl get pod reader-pod -n secure-ns -o jsonpath='{.spec.serviceAccountName}'
```

Expected output:

```
app-reader
```

Verify the projected token is mounted:

```bash
kubectl exec -n secure-ns reader-pod -- ls /var/run/secrets/kubernetes.io/serviceaccount/
```

Expected output:

```
ca.crt
namespace
token
```

> **Coach tip:** Explain that since Kubernetes v1.24, the token at this path is a **bound, time-limited** projected token — not a static long-lived secret like in older versions. The kubelet automatically rotates it.

---

## Task 2: Create a Role and RoleBinding (Namespace-Scoped)

### Step-by-step

Save `pod-reader-role.yaml`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: secure-ns
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
```

Save `pod-reader-binding.yaml`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: read-pods-binding
  namespace: secure-ns
subjects:
- kind: ServiceAccount
  name: app-reader
  namespace: secure-ns
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f pod-reader-role.yaml
kubectl apply -f pod-reader-binding.yaml
```

### Verification

**Test: list Pods (should succeed):**

```bash
kubectl exec -n secure-ns reader-pod -- kubectl get pods -n secure-ns
```

Expected output:

```
NAME         READY   STATUS    RESTARTS   AGE
reader-pod   1/1     Running   0          ...
```

**Test: list Secrets (should FAIL):**

```bash
kubectl exec -n secure-ns reader-pod -- kubectl get secrets -n secure-ns
```

Expected output:

```
Error from server (Forbidden): secrets is forbidden: User "system:serviceaccount:secure-ns:app-reader" cannot list resource "secrets" in API group "" in the namespace "secure-ns"
```

> **Coach tip:** The `apiGroups: [""]` refers to the **core** API group (Pods, Services, Secrets, ConfigMaps). Deployments live in the `apps` group. If a student forgets to include the right apiGroup, the rule won't match.

---

## Task 3: Create a ClusterRole and ClusterRoleBinding (Cluster-Scoped)

### Step-by-step

Save `node-viewer-clusterrole.yaml`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: node-viewer
rules:
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list"]
```

Save `node-viewer-binding.yaml`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: view-nodes-binding
subjects:
- kind: ServiceAccount
  name: app-reader
  namespace: secure-ns
roleRef:
  kind: ClusterRole
  name: node-viewer
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f node-viewer-clusterrole.yaml
kubectl apply -f node-viewer-binding.yaml
```

### Verification

```bash
kubectl exec -n secure-ns reader-pod -- kubectl get nodes
```

Expected output:

```
NAME                     STATUS   ROLES           AGE   VERSION
fasthack-control-plane   Ready    control-plane   ...   v1.36.x
```

> **Coach tip:** Emphasize the difference: a **Role + RoleBinding** grants permissions in a single namespace (like per-directory file permissions). A **ClusterRole + ClusterRoleBinding** grants permissions cluster-wide (like root access). Nodes are a cluster-scoped resource — they don't live in any namespace — so you must use a ClusterRole.

---

## Task 4: Verify Permissions with `kubectl auth can-i`

### Step-by-step

```bash
# Should be: yes
kubectl auth can-i list pods -n secure-ns \
  --as=system:serviceaccount:secure-ns:app-reader

# Should be: no
kubectl auth can-i delete pods -n secure-ns \
  --as=system:serviceaccount:secure-ns:app-reader

# Should be: yes (from the ClusterRoleBinding)
kubectl auth can-i list nodes \
  --as=system:serviceaccount:secure-ns:app-reader

# Should be: no
kubectl auth can-i list secrets -n secure-ns \
  --as=system:serviceaccount:secure-ns:app-reader
```

### Verification

Expected outputs in order:

```
yes
no
yes
no
```

**List ALL permissions for the ServiceAccount:**

```bash
kubectl auth can-i --list -n secure-ns \
  --as=system:serviceaccount:secure-ns:app-reader
```

Expected: a table showing the allowed verbs and resources, including `get`, `list`, `watch` on `pods` in `secure-ns` and `get`, `list` on `nodes` cluster-wide.

> **Coach tip:** `kubectl auth can-i` is the Kubernetes equivalent of `sudo -l`. It's the first tool to reach for when debugging "Forbidden" errors.

---

## Task 5: Pod Security Admission (PSA) Labels

### Step-by-step

**5a — Create namespace with `restricted` enforcement:**

```bash
kubectl create namespace psa-restricted
kubectl label namespace psa-restricted \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted
```

**5b — Attempt to deploy a privileged Pod (should be REJECTED):**

Save `privileged-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: bad-pod
  namespace: psa-restricted
spec:
  containers:
  - name: shell
    image: busybox:1.37
    command: ["sleep", "3600"]
    securityContext:
      privileged: true
```

```bash
kubectl apply -f privileged-pod.yaml
```

### Verification

Expected error output:

```
Error from server (Forbidden): error when creating "privileged-pod.yaml": pods "bad-pod" is forbidden: violates PodSecurity "restricted:latest": privileged (container "shell" must not set securityContext.privileged=true), ...
```

**5c — Create a `baseline` namespace with `restricted` warnings:**

```bash
kubectl create namespace psa-baseline
kubectl label namespace psa-baseline \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/warn=restricted
```

**5d — Deploy a non-privileged Pod in the baseline namespace (should succeed with warnings):**

```bash
kubectl run test-baseline --image=busybox:1.37 -n psa-baseline -- sleep 3600
```

Expected: the Pod is created, but you see **warnings** (not errors) about restricted violations. Something like:

```
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "test-baseline" must set securityContext.allowPrivilegeEscalation=false), ...
```

> **Coach tip:** This is the progressive adoption pattern — `enforce=baseline` blocks the worst offenders, while `warn=restricted` shows students what they still need to fix for full compliance. This is analogous to running SELinux in permissive mode to gather violations before switching to enforcing.

---

## Task 6: SecurityContext (Hardened Pod)

### Step-by-step

Save `hardened-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hardened-pod
  namespace: psa-restricted
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: app
    image: busybox:1.37
    command: ["sleep", "3600"]
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop:
          - ALL
```

```bash
kubectl apply -f hardened-pod.yaml
kubectl wait --for=condition=Ready pod/hardened-pod -n psa-restricted --timeout=60s
```

### Verification

**Verify UID:**

```bash
kubectl exec -n psa-restricted hardened-pod -- id
```

Expected output:

```
uid=1000 gid=1000 groups=1000
```

**Verify read-only root filesystem:**

```bash
kubectl exec -n psa-restricted hardened-pod -- touch /test-file
```

Expected output:

```
touch: /test-file: Read-only file system
command terminated with exit code 1
```

**Verify capabilities are dropped:**

```bash
kubectl exec -n psa-restricted hardened-pod -- cat /proc/1/status | grep -i cap
```

Expected: all capability bitmasks should be `0000000000000000` (or all zeros), indicating all capabilities are dropped.

```
CapInh: 0000000000000000
CapPrm: 0000000000000000
CapEff: 0000000000000000
CapBnd: 0000000000000000
CapAmb: 0000000000000000
```

> **Coach tip:** Walk through each SecurityContext field and its Linux equivalent:
>
> | Field | Linux Equivalent |
> |-------|-----------------|
> | `runAsNonRoot: true` | Refuse to start if UID is 0 |
> | `runAsUser: 1000` | `runuser -u uid1000 -- ...` |
> | `readOnlyRootFilesystem: true` | `mount -o ro /` |
> | `capabilities.drop: ["ALL"]` | `capsh --drop=all` |
> | `allowPrivilegeEscalation: false` | `prctl(PR_SET_NO_NEW_PRIVS, 1)` — blocks setuid/setgid |
> | `seccompProfile.type: RuntimeDefault` | Default seccomp filter (blocks dangerous syscalls) |

---

## Common Issues

| Problem | Cause | Fix |
|---------|-------|-----|
| `Forbidden` when running kubectl inside Pod | ServiceAccount has no RoleBinding | Create a RoleBinding that binds the appropriate Role to the ServiceAccount |
| `auth can-i` says `yes` but Pod still can't access | The `--as` flag uses format `system:serviceaccount:NAMESPACE:NAME` — check for typos | Verify exact format: `--as=system:serviceaccount:secure-ns:app-reader` |
| Privileged Pod is not rejected | Namespace doesn't have PSA labels | Check with `kubectl get namespace psa-restricted --show-labels` |
| Pod fails with "container has runAsNonRoot and image will run as root" | Image defaults to root but Pod spec requires non-root | Add `runAsUser: 1000` to the securityContext |
| PSA error lists multiple violations | The `restricted` profile requires MANY fields to be set | You need ALL of: `runAsNonRoot`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`, and `seccompProfile` |
| ClusterRoleBinding doesn't work | Forgot `namespace` field in the `subjects` section | ServiceAccount subjects in ClusterRoleBindings MUST specify the namespace |
| RBAC rule matches wrong resources | Wrong `apiGroups` value | Core resources (Pods, Services, Secrets) use `""`, Deployments use `"apps"`, RBAC resources use `"rbac.authorization.k8s.io"` |

---

## Clean Up

```bash
kubectl delete namespace secure-ns psa-restricted psa-baseline psa-lockdown 2>/dev/null
kubectl delete clusterrole node-viewer 2>/dev/null
kubectl delete clusterrolebinding view-nodes-binding 2>/dev/null
rm -f reader-pod.yaml pod-reader-role.yaml pod-reader-binding.yaml \
  node-viewer-clusterrole.yaml node-viewer-binding.yaml \
  privileged-pod.yaml hardened-pod.yaml
```
