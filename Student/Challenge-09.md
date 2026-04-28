# Challenge 09 — RBAC and Security

[< Previous Challenge](Challenge-08.md) | **[Home](../README.md)** | [Next Challenge >](Challenge-10.md)

## Introduction

On a Linux server, security is layered: you create **users** in `/etc/passwd`, organize them into **groups** in `/etc/group`, grant elevated privileges with the **sudoers** file, set file-level access with **chmod**, and enforce mandatory access control with **SELinux** or **AppArmor**. If a process doesn't have the right UID, the right group membership, or the right security context — access denied.

Kubernetes follows the exact same philosophy, just with different names:

| Linux Layer | Kubernetes Layer |
|---|---|
| "Who are you?" (`/etc/passwd`) | "Which **ServiceAccount** is this Pod running as?" |
| "What group are you in?" (`/etc/group`) | "What **Role** or **ClusterRole** defines this set of permissions?" |
| "Are you in sudoers?" | "Is there a **RoleBinding** or **ClusterRoleBinding** granting this identity these permissions?" |
| "Does your UID have read/write/execute?" (`chmod`) | "Does the RBAC policy include the right **verbs** (`get`, `list`, `create`, `delete`)?" |
| "Does SELinux/AppArmor allow this action?" | "Does the namespace's **Pod Security Admission (PSA)** policy permit this Pod configuration?" |
| "What user is this process running as?" (`runuser`, `su`) | "What does the Pod's **SecurityContext** (`runAsUser`, `runAsNonRoot`) enforce?" |

Every request to the Kubernetes API server passes through three gates — **Authentication** (who are you?), **Authorization** (are you allowed?), and **Admission Control** (does this request comply with policy?). In this challenge, you'll configure all three layers using RBAC, ServiceAccounts, Pod Security Admission, and SecurityContext.

> 📝 **Historical note**: Older tutorials may reference **PodSecurityPolicy (PSP)**. PSP was deprecated in Kubernetes v1.21 and **removed entirely in v1.25**. The replacement is **Pod Security Admission (PSA)**, which is what we use in this challenge. If you encounter PSP in the wild, it's legacy — migrate to PSA.

> 🆕 **Kubernetes v1.36**: **User Namespaces** are now GA (generally available). This feature maps container UIDs to unprivileged UIDs on the host, similar to rootless containers in Podman. While not covered in this challenge's tasks, be aware of this powerful security feature for defense-in-depth — see `pod.spec.hostUsers: false` in the learning resources.

## Description

Your mission is to:

1. **Create a ServiceAccount and use it in a Pod** — ServiceAccounts are the Kubernetes equivalent of Linux service users (like `www-data` for Apache or `postgres` for PostgreSQL). Create a ServiceAccount named `app-reader` in a namespace called `secure-ns`, then launch a Pod that uses it.

   ```bash
   kubectl create namespace secure-ns
   kubectl create serviceaccount app-reader -n secure-ns
   ```

   Create a Pod manifest that references this ServiceAccount:

   ```yaml
   # reader-pod.yaml
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

   Apply it and verify the ServiceAccount is mounted:

   ```bash
   kubectl apply -f reader-pod.yaml
   kubectl exec -n secure-ns reader-pod -- cat /var/run/secrets/kubernetes.io/serviceaccount/token
   ```

2. **Create a Role and RoleBinding to grant read-only access to Pods in a namespace** — A Role defines *what* actions are allowed on *which* resources within a single namespace. A RoleBinding connects a Role to a subject (ServiceAccount, User, or Group). This is like writing a sudoers entry that says "user `app-reader` can run `cat` and `ls` on files in `/var/log` but nothing else."

   Create a Role that allows reading Pods:

   ```yaml
   # pod-reader-role.yaml
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

   Bind it to the `app-reader` ServiceAccount:

   ```yaml
   # pod-reader-binding.yaml
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

   Apply both and test from inside the Pod:

   ```bash
   kubectl apply -f pod-reader-role.yaml
   kubectl apply -f pod-reader-binding.yaml

   # This should succeed (list Pods)
   kubectl exec -n secure-ns reader-pod -- kubectl get pods -n secure-ns

   # This should FAIL (no permission to list Secrets)
   kubectl exec -n secure-ns reader-pod -- kubectl get secrets -n secure-ns
   ```

3. **Create a ClusterRole and ClusterRoleBinding for cluster-wide permissions** — While Roles are namespace-scoped (like per-directory permissions), ClusterRoles apply across *all* namespaces (like a global sudoers rule). Create a ClusterRole that can list Nodes (a cluster-scoped resource) and bind it to the `app-reader` ServiceAccount.

   ```yaml
   # node-viewer-clusterrole.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: node-viewer
   rules:
   - apiGroups: [""]
     resources: ["nodes"]
     verbs: ["get", "list"]
   ```

   ```yaml
   # node-viewer-binding.yaml
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

   Apply and verify:

   ```bash
   kubectl apply -f node-viewer-clusterrole.yaml
   kubectl apply -f node-viewer-binding.yaml

   # This should now succeed
   kubectl exec -n secure-ns reader-pod -- kubectl get nodes
   ```

4. **Use `kubectl auth can-i` to verify permissions** — This is the Kubernetes equivalent of `sudo -l` (list what a user is allowed to do). Use it to check what the `app-reader` ServiceAccount can and cannot do.

   ```bash
   # Check if app-reader can list Pods in secure-ns (should be: yes)
   kubectl auth can-i list pods -n secure-ns --as=system:serviceaccount:secure-ns:app-reader

   # Check if app-reader can delete Pods in secure-ns (should be: no)
   kubectl auth can-i delete pods -n secure-ns --as=system:serviceaccount:secure-ns:app-reader

   # Check if app-reader can list Nodes cluster-wide (should be: yes)
   kubectl auth can-i list nodes --as=system:serviceaccount:secure-ns:app-reader

   # List ALL permissions for app-reader in secure-ns
   kubectl auth can-i --list -n secure-ns --as=system:serviceaccount:secure-ns:app-reader
   ```

5. **Apply Pod Security Admission (PSA) labels to a namespace** — PSA enforces security standards at the namespace level using labels. There are three policy levels — `privileged` (no restrictions), `baseline` (prevents known privilege escalations), and `restricted` (heavily locked down). This is the Kubernetes equivalent of SELinux enforcement modes (`disabled`, `permissive`, `enforcing`).

   Create a namespace with the `restricted` policy enforced:

   ```bash
   kubectl create namespace psa-restricted
   kubectl label namespace psa-restricted \
     pod-security.kubernetes.io/enforce=restricted \
     pod-security.kubernetes.io/warn=restricted \
     pod-security.kubernetes.io/audit=restricted
   ```

   Try deploying a privileged Pod into this namespace — it should be rejected:

   ```yaml
   # privileged-pod.yaml
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
   # This should be REJECTED by PSA
   kubectl apply -f privileged-pod.yaml
   ```

   Now create a namespace with `baseline` enforcement and verify that non-privileged Pods are accepted:

   ```bash
   kubectl create namespace psa-baseline
   kubectl label namespace psa-baseline \
     pod-security.kubernetes.io/enforce=baseline \
     pod-security.kubernetes.io/warn=restricted
   ```

   The `warn=restricted` label means Kubernetes will **warn** you (but not block) when a Pod doesn't meet the `restricted` standard — useful for progressive adoption.

6. **Configure SecurityContext on a Pod** — SecurityContext is how you set the "user identity" and capabilities of a container, just like using `runuser` to switch UIDs or `capsh` to drop Linux capabilities.

   Create a hardened Pod that follows security best practices:

   ```yaml
   # hardened-pod.yaml
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

   Apply and verify:

   ```bash
   kubectl apply -f hardened-pod.yaml

   # Verify the Pod is running
   kubectl get pod hardened-pod -n psa-restricted

   # Confirm it runs as UID 1000 (not root)
   kubectl exec -n psa-restricted hardened-pod -- id

   # Confirm the root filesystem is read-only
   kubectl exec -n psa-restricted hardened-pod -- touch /test-file
   # Should fail with "Read-only file system"

   # Confirm capabilities are dropped
   kubectl exec -n psa-restricted hardened-pod -- cat /proc/1/status | grep Cap
   ```

## Success Criteria

- [ ] A ServiceAccount named `app-reader` exists in namespace `secure-ns` and a Pod is running with that ServiceAccount
- [ ] A Role named `pod-reader` grants `get`, `list`, `watch` on Pods in `secure-ns`, and a RoleBinding connects it to `app-reader`
- [ ] The `reader-pod` can list Pods in `secure-ns` but **cannot** list Secrets
- [ ] A ClusterRole named `node-viewer` grants `get`, `list` on Nodes, and the `reader-pod` can list Nodes
- [ ] `kubectl auth can-i` correctly reports `yes` for permitted actions and `no` for denied actions
- [ ] Namespace `psa-restricted` rejects a Pod with `privileged: true`
- [ ] Namespace `psa-baseline` accepts a non-privileged Pod and **warns** when a Pod doesn't meet `restricted`
- [ ] A hardened Pod runs as non-root (UID 1000), has a read-only root filesystem, and drops all capabilities
- [ ] You can explain the difference between Role/RoleBinding (namespace-scoped) and ClusterRole/ClusterRoleBinding (cluster-scoped)

## Linux ↔ Kubernetes Reference

| Linux Concept | Kubernetes Equivalent | Example |
|---|---|---|
| Users (`/etc/passwd`) | ServiceAccounts | `kubectl create sa app-reader` |
| Groups (`/etc/group`) | Roles / ClusterRoles | `rules: [{resources: ["pods"], verbs: ["get"]}]` |
| sudoers file | RoleBinding / ClusterRoleBinding | Binds a Role to a ServiceAccount |
| `chmod` / file permissions | RBAC verbs | `get`, `list`, `watch`, `create`, `update`, `delete` |
| `sudo -l` (list privileges) | `kubectl auth can-i --list` | Check what a ServiceAccount can do |
| SELinux / AppArmor profiles | Pod Security Admission (PSA) | `pod-security.kubernetes.io/enforce=restricted` |
| `runuser` / `su` (switch user) | `securityContext.runAsUser` | `runAsUser: 1000` |
| `chroot` (restrict filesystem view) | `readOnlyRootFilesystem: true` | Prevent writes to container rootfs |
| `capsh --print` (capabilities) | `securityContext.capabilities.drop` | `drop: ["ALL"]` |
| `/etc/security/limits.conf` | `allowPrivilegeEscalation: false` | Prevent setuid/setgid escalation |

## Hints

<details>
<summary>Hint 1: Understanding the ServiceAccount token mount</summary>

When a Pod runs with a ServiceAccount, Kubernetes automatically mounts a **projected token volume** at `/var/run/secrets/kubernetes.io/serviceaccount/`. This directory contains:

- `token` — a time-limited JWT (JSON Web Token) that identifies the ServiceAccount
- `ca.crt` — the cluster's CA certificate (so the Pod can verify the API server's identity)
- `namespace` — the namespace the Pod is running in

This is similar to how SSH agent forwarding injects credentials into a session. The `kubectl` binary inside the container automatically uses these files when talking to the API server.

```bash
# Inspect the mounted token
kubectl exec -n secure-ns reader-pod -- ls -la /var/run/secrets/kubernetes.io/serviceaccount/

# Decode the JWT payload (second segment, base64-decoded)
kubectl exec -n secure-ns reader-pod -- cat /var/run/secrets/kubernetes.io/serviceaccount/token | \
  cut -d'.' -f2 | base64 -d 2>/dev/null | python3 -m json.tool
```

</details>

<details>
<summary>Hint 2: RBAC verbs explained — mapping to REST and Linux</summary>

Every RBAC rule specifies **verbs** (actions) on **resources**. These map to both HTTP methods and Linux file operations:

| RBAC Verb | HTTP Method | Linux Equivalent |
|---|---|---|
| `get` | GET (single resource) | `cat /path/to/file` |
| `list` | GET (collection) | `ls /path/to/directory` |
| `watch` | GET with `?watch=true` | `inotifywait -m /path` |
| `create` | POST | `touch /path/to/file` |
| `update` | PUT | `echo "new content" > /path/to/file` |
| `patch` | PATCH | `sed -i 's/old/new/' /path/to/file` |
| `delete` | DELETE | `rm /path/to/file` |

For read-only access, grant only `get`, `list`, and `watch`. The `apiGroups: [""]` in a rule refers to the **core** API group (Pods, Services, Secrets, ConfigMaps). Other resources live in named groups like `apps` (Deployments) or `rbac.authorization.k8s.io` (Roles).

</details>

<details>
<summary>Hint 3: PSA levels — what each one restricts</summary>

Pod Security Admission defines three levels, each progressively more strict:

**`privileged`** — No restrictions at all. Like running SELinux in `disabled` mode.

**`baseline`** — Blocks the most dangerous configurations:
- No `privileged: true` containers
- No `hostNetwork`, `hostPID`, `hostIPC`
- No `hostPath` volumes
- Restricted port ranges

**`restricted`** — Enforces security best practices:
- Everything in `baseline`, plus:
- Must `runAsNonRoot: true`
- Must drop `ALL` capabilities (only `NET_BIND_SERVICE` can be added back)
- Must set `allowPrivilegeEscalation: false`
- Must set `seccompProfile.type: RuntimeDefault` or `Localhost`
- No writable root filesystem is *recommended* but not required

Each namespace can set three **modes** independently:

| Mode | Behavior |
|---|---|
| `enforce` | Rejects Pods that violate the policy |
| `warn` | Accepts the Pod but shows a warning to the user |
| `audit` | Logs violations in the API server audit log |

A common progressive rollout pattern:
```bash
# Start with warn + audit on restricted, enforce baseline
kubectl label namespace my-ns \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted
```

</details>

<details>
<summary>Hint 4: Debugging RBAC denials</summary>

When a request fails with `Error from server (Forbidden)`, here's how to debug it:

```bash
# 1. Check what the ServiceAccount CAN do
kubectl auth can-i --list -n secure-ns --as=system:serviceaccount:secure-ns:app-reader

# 2. Check a specific permission
kubectl auth can-i get secrets -n secure-ns --as=system:serviceaccount:secure-ns:app-reader
# Output: no

# 3. List all RoleBindings in the namespace to see what's bound
kubectl get rolebindings -n secure-ns -o wide

# 4. Describe a specific RoleBinding to see the subjects and roleRef
kubectl describe rolebinding read-pods-binding -n secure-ns

# 5. List all ClusterRoleBindings (watch for over-permissive cluster-wide bindings)
kubectl get clusterrolebindings -o wide | grep app-reader
```

**Common mistakes:**
- Forgetting the `namespace` field in the RoleBinding's `subjects` section
- Using `Role` in a `ClusterRoleBinding` (you can bind a ClusterRole with a RoleBinding to limit it to one namespace, but not the reverse)
- Typos in the ServiceAccount name — RBAC silently does nothing if the subject doesn't match

</details>

<details>
<summary>Hint 5: SecurityContext at Pod level vs Container level</summary>

SecurityContext can be set at **two levels**, and they behave like Linux defaults vs overrides:

| Level | Scope | Linux Analogy |
|---|---|---|
| `spec.securityContext` (Pod-level) | Applies to ALL containers | `/etc/login.defs` (system-wide defaults) |
| `spec.containers[].securityContext` (Container-level) | Applies to ONE container | `runuser -u appuser -- ./myapp` (per-process) |

Container-level settings **override** Pod-level settings when both are specified.

**Common fields at Pod level:**
```yaml
spec:
  securityContext:
    runAsNonRoot: true    # Reject containers that would run as root
    runAsUser: 1000       # Default UID for all containers
    runAsGroup: 1000      # Default GID for all containers
    fsGroup: 2000         # GID applied to all mounted volumes
    seccompProfile:
      type: RuntimeDefault
```

**Common fields at Container level:**
```yaml
containers:
- name: app
  securityContext:
    allowPrivilegeEscalation: false   # No setuid/setgid
    readOnlyRootFilesystem: true      # Like mounting / as read-only
    capabilities:
      drop: ["ALL"]                   # Drop all Linux capabilities
      add: ["NET_BIND_SERVICE"]       # Re-add only what's needed
```

</details>

## Learning Resources

- [Kubernetes RBAC — Using RBAC Authorization](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
- [Kubernetes — Configure Service Accounts for Pods](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/)
- [Kubernetes — Pod Security Admission](https://kubernetes.io/docs/concepts/security/pod-security-admission/)
- [Kubernetes — Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [Kubernetes — Configure a Security Context for a Pod or Container](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)
- [Kubernetes — Checking API Access with kubectl auth can-i](https://kubernetes.io/docs/reference/access-authn-authz/authorization/#checking-api-access)
- [Kubernetes — User Namespaces](https://kubernetes.io/docs/concepts/workloads/pods/user-namespaces/)

## Break & Fix 🔧

After completing the challenge, try these scenarios to deepen your understanding:

### Scenario 1: Pod can't access the API — missing RoleBinding

Deploy this Pod and try to list Pods from inside it:

```yaml
# broken-reader.yaml
apiVersion: v1
kind: Pod
metadata:
  name: broken-reader
  namespace: secure-ns
spec:
  serviceAccountName: lonely-sa
  containers:
  - name: shell
    image: bitnami/kubectl:latest
    command: ["sleep", "3600"]
```

```bash
kubectl create serviceaccount lonely-sa -n secure-ns
kubectl apply -f broken-reader.yaml
kubectl exec -n secure-ns broken-reader -- kubectl get pods -n secure-ns
# ERROR: pods is forbidden: User "system:serviceaccount:secure-ns:lonely-sa"
#        cannot list resource "pods" in API group "" in the namespace "secure-ns"
```

**Your task**: The `lonely-sa` ServiceAccount exists but has no permissions. Create the missing RoleBinding to grant it `pod-reader` Role access. Verify the fix by re-running the `kubectl get pods` command from inside the Pod.

*(Linux analogy: A user exists in `/etc/passwd` but has no group membership or sudoers entry — they can log in but can't do anything useful.)*

### Scenario 2: Pod fails with "container has runAsNonRoot and image will run as root"

Try applying this Pod:

```yaml
# broken-nonroot.yaml
apiVersion: v1
kind: Pod
metadata:
  name: broken-nonroot
  namespace: secure-ns
spec:
  securityContext:
    runAsNonRoot: true
  containers:
  - name: app
    image: nginx:1.27
    command: ["sleep", "3600"]
```

```bash
kubectl apply -f broken-nonroot.yaml
kubectl get pod broken-nonroot -n secure-ns
# STATUS: CreateContainerConfigError

kubectl describe pod broken-nonroot -n secure-ns
# Error: container has runAsNonRoot and image will run as root
```

**Your task**: The Pod spec says `runAsNonRoot: true`, but the `nginx:1.27` image's default user is root (UID 0). Fix this by adding `runAsUser: 1000` to the container's `securityContext`. After fixing, verify the Pod starts and runs as UID 1000.

*(Linux analogy: You configured `/etc/login.defs` to reject root logins, but the service is hardcoded to start as root — you need to add a `User=` directive in the systemd unit file.)*

### Scenario 3: Namespace rejects a Pod — PSA enforce=restricted

Create a namespace with strict PSA enforcement and try deploying a Pod that violates it:

```bash
kubectl create namespace psa-lockdown
kubectl label namespace psa-lockdown pod-security.kubernetes.io/enforce=restricted
```

```yaml
# broken-psa.yaml
apiVersion: v1
kind: Pod
metadata:
  name: broken-psa
  namespace: psa-lockdown
spec:
  containers:
  - name: app
    image: busybox:1.37
    command: ["sleep", "3600"]
    securityContext:
      privileged: true
```

```bash
kubectl apply -f broken-psa.yaml
# Error from server (Forbidden): ...violates PodSecurity "restricted:latest":
#   privileged (container "app" must not set securityContext.privileged=true),
#   ...
```

**Your task**: Fix the Pod spec to comply with the `restricted` PSA standard. You'll need to: remove `privileged: true`, add `runAsNonRoot: true` and `runAsUser: 1000` at the Pod level, add `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, and `capabilities.drop: ["ALL"]` at the container level, and set `seccompProfile.type: RuntimeDefault` at the Pod level. Apply the fixed manifest and verify the Pod starts successfully.
