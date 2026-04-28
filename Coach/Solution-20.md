# Solution 20 — Supply Chain & Runtime Security

[< Previous Solution](Solution-19.md) - **[Home](README.md)**

---

> **Coach note:** This is the final challenge and the most tool-heavy. Students will install multiple CLI tools (Trivy, syft, cosign, kubesec, kube-linter, Falco). Help with tool installation issues — they're not the learning objective. Tasks 1-2 and 7 require VM access (kubeadm cluster from Ch18). Tasks 3-9 can run on Kind. Allow **90–120 minutes** — this is a capstone challenge.
>
> **Pre-requisites to verify:**
> - Students have a working Kind cluster (`kind get clusters`)
> - For VM tasks: SSH access to kubeadm nodes, AppArmor installed (`which apparmor_parser`)
> - Docker is running (needed for local registry in Task 5, Kind node access in Task 9)
> - Helm is installed (needed for Falco in Task 7)

Estimated time: **90–120 minutes**

---

## Task 1: AppArmor Profiles for Containers [VM]

### Step-by-step

**SSH into the worker node** and create the AppArmor profile:

```bash
sudo tee /etc/apparmor.d/k8s-deny-etc-write << 'EOF'
#include <tunables/global>

profile k8s-deny-etc-write flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>

  # Allow everything by default
  file,

  # Deny writes to /etc
  deny /etc/** w,
  deny /etc/ w,
}
EOF
```

Load the profile:

```bash
sudo apparmor_parser -r /etc/apparmor.d/k8s-deny-etc-write
```

### Verification — Profile loaded

```bash
sudo aa-status | grep k8s-deny-etc-write
```

Expected:

```
   k8s-deny-etc-write
```

The profile should appear in the `enforce` section.

### Create the Pod

Save `apparmor-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: apparmor-test
spec:
  containers:
    - name: shell
      image: busybox:1.36
      command: ["sleep", "3600"]
      securityContext:
        appArmorProfile:
          type: Localhost
          localhostProfile: k8s-deny-etc-write
      resources:
        requests:
          cpu: 50m
          memory: 32Mi
        limits:
          cpu: 100m
          memory: 64Mi
```

> **For Kubernetes < 1.30**, use the annotation approach:
> ```yaml
> metadata:
>   annotations:
>     container.apparmor.security.beta.kubernetes.io/shell: localhost/k8s-deny-etc-write
> ```

Apply:

```bash
kubectl apply -f apparmor-pod.yaml
kubectl wait --for=condition=ready pod/apparmor-test --timeout=60s
```

### Verification — AppArmor enforcement

```bash
# Write to /tmp — should succeed
kubectl exec apparmor-test -- touch /tmp/allowed
echo "Exit code: $?"
```

Expected: `Exit code: 0`

```bash
# Write to /etc — should fail
kubectl exec apparmor-test -- touch /etc/blocked
echo "Exit code: $?"
```

Expected:

```
touch: /etc/blocked: Permission denied
command terminated with exit code 1
```

Verify the profile is active:

```bash
kubectl exec apparmor-test -- cat /proc/1/attr/current
```

Expected:

```
k8s-deny-etc-write (enforce)
```

> **Coach tip:** If students see `unconfined` instead of the profile name, the profile is not loaded on the node where the Pod was scheduled. Check which node the Pod is on (`kubectl get pod -o wide`) and ensure the profile is loaded there.

---

## Task 2: Custom Seccomp Profiles [VM/Kind]

### Step-by-step

Create the seccomp profile JSON:

```bash
cat > block-dangerous.json << 'EOF'
{
  "defaultAction": "SCMP_ACT_ALLOW",
  "architectures": [
    "SCMP_ARCH_X86_64",
    "SCMP_ARCH_AARCH64"
  ],
  "syscalls": [
    {
      "names": [
        "unshare",
        "mount",
        "umount2",
        "ptrace",
        "kexec_load",
        "open_by_handle_at",
        "init_module",
        "finit_module",
        "delete_module",
        "reboot"
      ],
      "action": "SCMP_ACT_ERRNO",
      "errnoRet": 1
    }
  ]
}
EOF
```

Copy to the kubelet seccomp path:

```bash
# For VM (kubeadm):
sudo mkdir -p /var/lib/kubelet/seccomp/profiles
sudo cp block-dangerous.json /var/lib/kubelet/seccomp/profiles/

# For Kind:
docker exec fasthack-control-plane mkdir -p /var/lib/kubelet/seccomp/profiles
docker cp block-dangerous.json fasthack-control-plane:/var/lib/kubelet/seccomp/profiles/
```

Save `seccomp-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-test
spec:
  securityContext:
    seccompProfile:
      type: Localhost
      localhostProfile: profiles/block-dangerous.json
  containers:
    - name: shell
      image: busybox:1.36
      command: ["sleep", "3600"]
      resources:
        requests:
          cpu: 50m
          memory: 32Mi
        limits:
          cpu: 100m
          memory: 64Mi
```

Apply:

```bash
kubectl apply -f seccomp-pod.yaml
kubectl wait --for=condition=ready pod/seccomp-test --timeout=60s
```

### Verification — Blocked syscalls

```bash
# unshare should fail
kubectl exec seccomp-test -- unshare --user --pid --fork --mount-proc readlink /proc/self/ns/user
```

Expected: `unshare: unshare(0x10000000): Operation not permitted` (or similar EPERM error)

```bash
# Normal commands should succeed
kubectl exec seccomp-test -- ls /
kubectl exec seccomp-test -- whoami
```

Expected: Normal output — `ls` and `whoami` don't use blocked syscalls.

### Verification — RuntimeDefault profile

```bash
cat > seccomp-default.yaml << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-default
spec:
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: shell
      image: busybox:1.36
      command: ["sleep", "3600"]
      resources:
        requests:
          cpu: 50m
          memory: 32Mi
EOF

kubectl apply -f seccomp-default.yaml
kubectl wait --for=condition=ready pod/seccomp-default --timeout=60s
kubectl exec seccomp-default -- ls /
```

Expected: Pod runs normally. `RuntimeDefault` is the container runtime's built-in profile — it blocks the most dangerous syscalls (like `reboot`, `kexec_load`) while allowing normal operations.

> **Coach tip:** Explain the seccomp profile types:
> - `Unconfined` — no filtering (dangerous, avoid in production)
> - `RuntimeDefault` — CRI's built-in profile (good baseline)
> - `Localhost` — custom profile on the node (most restrictive, best for defense-in-depth)
>
> The `localhostProfile` path is relative to `/var/lib/kubelet/seccomp/`. So `profiles/block-dangerous.json` resolves to `/var/lib/kubelet/seccomp/profiles/block-dangerous.json`.

---

## Task 3: Image Scanning with Trivy [Kind]

### Step-by-step

Install Trivy:

```bash
curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin
trivy --version
```

### Verification — Scan images

```bash
# Scan an older image with known CVEs
trivy image --severity HIGH,CRITICAL nginx:1.21
```

Expected output (truncated):

```
nginx:1.21 (debian 11.2)
=========================
Total: XX (HIGH: XX, CRITICAL: XX)

┌─────────────────────┬────────────────┬──────────┬───────────────┬─────────────────────┐
│      Library        │ Vulnerability  │ Severity │ Installed Ver │    Fixed Version    │
├─────────────────────┼────────────────┼──────────┼───────────────┼─────────────────────┤
│ libssl1.1           │ CVE-2022-XXXXX │ CRITICAL │ 1.1.1k-1...  │ 1.1.1n-1...         │
...
```

> **Coach tip:** The first run downloads the vulnerability DB (~30MB). If students are offline, they can pre-download with `trivy image --download-db-only`.

```bash
# Scan a newer image — fewer CVEs
trivy image --severity HIGH,CRITICAL nginx:1.27

# Scan Alpine — even fewer
trivy image --severity HIGH,CRITICAL nginx:1.27-alpine
```

Students should observe:
- `nginx:1.21` — many CVEs (dozens of HIGH/CRITICAL)
- `nginx:1.27` — fewer CVEs (patched packages)
- `nginx:1.27-alpine` — fewest CVEs (minimal base image)

```bash
# JSON output for CI/CD pipelines
trivy image -f json -o nginx-scan.json nginx:1.21
cat nginx-scan.json | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Total vulnerabilities: {sum(len(r.get(\"Vulnerabilities\",[])) for r in d.get(\"Results\",[]))}')"
```

```bash
# Only show fixable vulnerabilities
trivy image --ignore-unfixed --severity HIGH,CRITICAL nginx:1.21
```

---

## Task 4: SBOM Generation [Kind]

### Step-by-step

Install syft:

```bash
curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin
syft --version
```

### Verification — Generate SBOMs

```bash
# Human-readable table
syft nginx:1.27-alpine
```

Expected: A table listing all packages (apk packages, OS metadata).

```bash
# CycloneDX JSON
syft nginx:1.27-alpine -o cyclonedx-json > nginx-sbom.cdx.json
cat nginx-sbom.cdx.json | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Components: {len(d.get(\"components\",[]))}')"
```

Expected: Shows the number of components (packages) in the SBOM.

```bash
# SPDX JSON
syft nginx:1.27-alpine -o spdx-json > nginx-sbom.spdx.json
```

```bash
# Generate with Trivy (alternative)
trivy image --format cyclonedx -o nginx-trivy-sbom.cdx.json nginx:1.27-alpine
```

### Verification — Scan SBOM for vulnerabilities

```bash
trivy sbom nginx-sbom.cdx.json
```

Expected: Trivy reads the SBOM and checks each component against the vulnerability database — same results as scanning the image directly.

### Verification — Compare image sizes

```bash
syft nginx:1.27 2>/dev/null | wc -l
syft nginx:1.27-alpine 2>/dev/null | wc -l
syft gcr.io/distroless/static-debian12 2>/dev/null | wc -l
```

Expected (approximate):
- `nginx:1.27` — ~150+ packages
- `nginx:1.27-alpine` — ~30-50 packages
- `gcr.io/distroless/static-debian12` — ~5-15 packages

> **Coach tip:** This dramatically demonstrates why minimal base images matter. Fewer packages = smaller attack surface = fewer potential CVEs.

---

## Task 5: Sign and Verify Images with Cosign [Kind]

### Step-by-step

Install cosign:

```bash
curl -LO "https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64"
chmod +x cosign-linux-amd64
sudo mv cosign-linux-amd64 /usr/local/bin/cosign
cosign version
```

Expected: Version output showing `v2.x.x`.

Generate a key pair:

```bash
cosign generate-key-pair
```

Expected: Creates `cosign.key` (private) and `cosign.pub` (public). Students will be prompted for a password.

Start a local registry:

```bash
docker run -d -p 5000:5000 --name registry registry:2 2>/dev/null || true
```

Push an image:

```bash
docker pull busybox:1.36
docker tag busybox:1.36 localhost:5000/busybox:signed
docker push localhost:5000/busybox:signed
```

### Verification — Sign the image

```bash
cosign sign --key cosign.key localhost:5000/busybox:signed --allow-insecure-registry
```

Expected: Prompts for the private key password, then uploads the signature to the registry. Output shows `Pushing signature to: localhost:5000/busybox:sha256-...`.

### Verification — Verify the signature

```bash
cosign verify --key cosign.pub localhost:5000/busybox:signed --allow-insecure-registry
```

Expected:

```
Verification for localhost:5000/busybox:signed --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - The signatures were verified against the specified public key
[{"critical":{"identity":...},"optional":null}]
```

### Verification — Unsigned image fails verification

```bash
docker tag busybox:1.36 localhost:5000/busybox:unsigned
docker push localhost:5000/busybox:unsigned
cosign verify --key cosign.pub localhost:5000/busybox:unsigned --allow-insecure-registry
```

Expected: `Error: no matching signatures` — verification fails because the image was never signed.

> **Coach tip:** This is the same principle as `gpg --verify` for `.deb` packages. In production, you'd integrate cosign verification into admission controllers (like Kyverno or OPA Gatekeeper) to reject unsigned images at deploy time.

---

## Task 6: Static Analysis with Kubesec and KubeLinter [Kind]

### Step-by-step

Install tools:

```bash
# kubesec
curl -LO https://github.com/controlplaneio/kubesec/releases/latest/download/kubesec_linux_amd64.tar.gz
tar xzf kubesec_linux_amd64.tar.gz
sudo mv kubesec /usr/local/bin/

# kube-linter
curl -LO https://github.com/stackrox/kube-linter/releases/latest/download/kube-linter-linux
chmod +x kube-linter-linux
sudo mv kube-linter-linux /usr/local/bin/kube-linter
```

Create the insecure manifest:

```yaml
# Save as insecure-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: insecure-app
spec:
  containers:
    - name: app
      image: nginx
      securityContext:
        privileged: true
        runAsUser: 0
      ports:
        - containerPort: 80
```

### Verification — Kubesec scan

```bash
kubesec scan insecure-pod.yaml
```

Expected (JSON output — key fields):

```json
[
  {
    "object": "Pod/insecure-app.default",
    "valid": true,
    "message": "Failed with a score of -30 points",
    "score": -30,
    "scoring": {
      "critical": [
        { "id": "Privileged", "selector": "containers[] .securityContext .privileged == true", "reason": "..." }
      ],
      "advise": [
        { "id": "RunAsNonRoot", ... },
        { "id": "ReadOnlyRootFilesystem", ... }
      ]
    }
  }
]
```

The negative score indicates severe security issues. `Privileged: true` is the biggest offender.

### Verification — KubeLinter scan

```bash
kube-linter lint insecure-pod.yaml
```

Expected: Multiple findings:
- `run-as-non-root` — container running as root
- `no-read-only-root-fs` — root filesystem is writable
- `unset-cpu-requirements` — no resource limits
- `unset-memory-requirements` — no resource limits

### Verification — Hardened manifest scores better

```yaml
# Save as secure-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-app
spec:
  containers:
    - name: app
      image: nginx:1.27-alpine
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
      ports:
        - containerPort: 80
      resources:
        requests:
          cpu: 50m
          memory: 32Mi
        limits:
          cpu: 100m
          memory: 64Mi
      volumeMounts:
        - name: tmp
          mountPath: /tmp
        - name: cache
          mountPath: /var/cache/nginx
        - name: run
          mountPath: /var/run
  volumes:
    - name: tmp
      emptyDir: {}
    - name: cache
      emptyDir: {}
    - name: run
      emptyDir: {}
```

```bash
kubesec scan secure-pod.yaml
kube-linter lint secure-pod.yaml
```

Expected:
- Kubesec: positive score (e.g., +7 or higher)
- KubeLinter: significantly fewer or zero findings

> **Coach tip:** Have students compare the scores side by side. The jump from -30 to +7 is dramatic and visually demonstrates the impact of security hardening.

---

## Task 7: Runtime Threat Detection with Falco [VM]

### Step-by-step

Install Falco via Helm:

```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update

helm install falco falcosecurity/falco \
  --namespace falco \
  --create-namespace \
  --set driver.kind=modern_ebpf \
  --set tty=true
```

> **Coach tip:** If `modern_ebpf` fails (older kernel), try `--set driver.kind=ebpf` or `--set driver.kind=kmod`. The kernel module driver (`kmod`) requires kernel headers: `sudo apt-get install -y linux-headers-$(uname -r)`.

### Verification — Falco is running

```bash
kubectl get pods -n falco
```

Expected:

```
NAME          READY   STATUS    RESTARTS   AGE
falco-xxxxx   2/2     Running   0          60s
```

```bash
kubectl logs -n falco -l app.kubernetes.io/name=falco --tail=10
```

Expected: Log output showing Falco engine started and rules loaded.

### Verification — Trigger and detect a shell spawn

Terminal 1 — Watch Falco logs:

```bash
kubectl logs -n falco -l app.kubernetes.io/name=falco -f --tail=0
```

Terminal 2 — Create a test Pod and exec into it:

```bash
kubectl run falco-test --image=nginx:1.27-alpine --restart=Never
kubectl wait --for=condition=ready pod/falco-test --timeout=60s
kubectl exec -it falco-test -- /bin/sh -c "whoami && cat /etc/shadow && ls /root"
```

### Verification — Alert in Falco logs

Back in Terminal 1, look for alerts:

```bash
kubectl logs -n falco -l app.kubernetes.io/name=falco --tail=30 | grep -E "shell|shadow|Terminal"
```

Expected alerts (may vary by Falco version):

```
Notice A shell was spawned in a container with an attached terminal (...) container_id=xxx container_name=falco-test
Warning Sensitive file opened for reading (file=/etc/shadow ...)
```

> **Coach tip:** If students don't see alerts, check:
> 1. Falco driver is loaded: `kubectl logs -n falco -l app.kubernetes.io/name=falco | grep -i driver`
> 2. Rules are loaded: `kubectl logs -n falco -l app.kubernetes.io/name=falco | grep "Loading rules"`
> 3. The Pod is on a node where Falco is running (DaemonSet deploys to all nodes)

### Verification — Examine Falco rules

```bash
# List Falco configmaps
kubectl get configmap -n falco

# View a snippet of the rules
kubectl get configmap -n falco -l app.kubernetes.io/name=falco -o yaml | grep -A3 "Terminal shell"
```

---

## Task 8: Container Immutability [Kind]

### Step-by-step

Save `immutable-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: immutable-app
spec:
  containers:
    - name: app
      image: nginx:1.27-alpine
      securityContext:
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        runAsUser: 101
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
      ports:
        - containerPort: 80
      resources:
        requests:
          cpu: 50m
          memory: 32Mi
        limits:
          cpu: 100m
          memory: 64Mi
      volumeMounts:
        - name: tmp
          mountPath: /tmp
        - name: cache
          mountPath: /var/cache/nginx
        - name: run
          mountPath: /var/run
  volumes:
    - name: tmp
      emptyDir: {}
    - name: cache
      emptyDir: {}
    - name: run
      emptyDir: {}
```

```bash
kubectl apply -f immutable-pod.yaml
kubectl wait --for=condition=ready pod/immutable-app --timeout=60s
```

### Verification — Read-only filesystem enforced

```bash
# Write to root filesystem — should FAIL
kubectl exec immutable-app -- touch /usr/share/nginx/html/hacked.html
```

Expected:

```
touch: /usr/share/nginx/html/hacked.html: Read-only file system
command terminated with exit code 1
```

```bash
# Write to emptyDir mount — should SUCCEED
kubectl exec immutable-app -- touch /tmp/allowed.txt
echo "Exit code: $?"
```

Expected: `Exit code: 0`

### Verification — Distroless has no shell

```bash
kubectl run distroless-demo --image=gcr.io/distroless/base-debian12 --restart=Never --command -- sleep 3600
kubectl wait --for=condition=ready pod/distroless-demo --timeout=60s 2>/dev/null

# Try to get a shell — this will fail
kubectl exec -it distroless-demo -- /bin/sh
```

Expected:

```
OCI runtime exec failed: exec failed: unable to start container process:
exec: "/bin/sh": stat /bin/sh: no such file or directory
```

> **Coach tip:** This is a powerful security measure — even if an attacker gets RCE in the application, there's no shell to use for lateral movement. Combined with `readOnlyRootFilesystem`, they can't install tools either.

### Verification — Package count comparison

```bash
echo "=== Full Debian-based nginx ==="
syft nginx:1.27 2>/dev/null | wc -l

echo "=== Alpine-based nginx ==="
syft nginx:1.27-alpine 2>/dev/null | wc -l

echo "=== Distroless static ==="
syft gcr.io/distroless/static-debian12 2>/dev/null | wc -l
```

Expected: Dramatic decrease in package count — demonstrating the reduced attack surface.

---

## Task 9: Kubernetes Audit Log Analysis [Kind]

### Step-by-step

Create the audit policy file:

```bash
cat > audit-policy.yaml << 'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  - level: None
    nonResourceURLs:
      - "/healthz*"
      - "/version"
      - "/swagger*"
      - "/readyz*"
      - "/livez*"

  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets"]

  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["clusterroles", "clusterrolebindings", "roles", "rolebindings"]

  - level: Request
    resources:
      - group: ""
        resources: ["pods", "pods/exec", "pods/portforward"]
    verbs: ["create", "delete", "patch", "update"]

  - level: Metadata
    omitStages:
      - "RequestReceived"
EOF
```

Create the Kind cluster config:

```bash
mkdir -p audit-logs

cat > kind-audit.yaml << 'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: ./audit-policy.yaml
        containerPath: /etc/kubernetes/audit-policy.yaml
        readOnly: true
      - hostPath: ./audit-logs
        containerPath: /var/log/kubernetes
    kubeadmConfigPatches:
      - |
        kind: ClusterConfiguration
        apiServer:
          extraArgs:
            audit-policy-file: /etc/kubernetes/audit-policy.yaml
            audit-log-path: /var/log/kubernetes/audit.log
            audit-log-maxage: "7"
            audit-log-maxbackup: "3"
            audit-log-maxsize: "50"
          extraVolumes:
            - name: audit-policy
              hostPath: /etc/kubernetes/audit-policy.yaml
              mountPath: /etc/kubernetes/audit-policy.yaml
              readOnly: true
            - name: audit-log
              hostPath: /var/log/kubernetes/
              mountPath: /var/log/kubernetes/
              readOnly: false
EOF
```

Create the cluster:

```bash
kind create cluster --name audit-lab --config kind-audit.yaml
```

### Verification — Audit logging is active

```bash
# Check the API server has audit flags
docker exec audit-lab-control-plane cat /etc/kubernetes/manifests/kube-apiserver.yaml | grep audit
```

Expected: Lines showing `--audit-policy-file` and `--audit-log-path`.

```bash
# Verify audit log file exists
docker exec audit-lab-control-plane ls -la /var/log/kubernetes/audit.log
```

Expected: File exists and is growing.

### Generate audit events

```bash
# Switch to the audit-lab context
kubectl cluster-info --context kind-audit-lab

# Create a secret
kubectl create secret generic audit-test-secret --from-literal=password=supersecret

# Create and delete a Pod
kubectl run audit-pod --image=busybox:1.36 --restart=Never --command -- sleep 30
sleep 5
kubectl delete pod audit-pod

# Exec into a Pod
kubectl run audit-exec --image=busybox:1.36 --restart=Never --command -- sleep 3600
kubectl wait --for=condition=ready pod/audit-exec --timeout=60s
kubectl exec audit-exec -- whoami
```

### Verification — Analyze audit logs

```bash
# Find secret access events
docker exec audit-lab-control-plane cat /var/log/kubernetes/audit.log | \
  python3 -c "
import sys, json
for line in sys.stdin:
    try:
        e = json.loads(line)
        if e.get('objectRef', {}).get('resource') == 'secrets':
            print(f\"{e['verb']:10s} {e['objectRef'].get('name','?'):30s} by {e['user'].get('username','?'):30s} at {e.get('requestReceivedTimestamp','?')}\")
    except: pass
"
```

Expected: Shows `create audit-test-secret by kubernetes-admin` (and possibly other system secret accesses).

```bash
# Find Pod exec events
docker exec audit-lab-control-plane cat /var/log/kubernetes/audit.log | \
  python3 -c "
import sys, json
for line in sys.stdin:
    try:
        e = json.loads(line)
        if e.get('objectRef', {}).get('subresource') == 'exec':
            print(f\"EXEC into {e['objectRef'].get('name','?'):20s} by {e['user'].get('username','?'):20s} at {e.get('requestReceivedTimestamp','?')}\")
    except: pass
"
```

Expected: Shows `EXEC into audit-exec by kubernetes-admin`.

```bash
# Count API calls per user
docker exec audit-lab-control-plane cat /var/log/kubernetes/audit.log | \
  python3 -c "
import sys, json
from collections import Counter
users = Counter()
for line in sys.stdin:
    try:
        e = json.loads(line)
        users[e['user'].get('username','unknown')] += 1
    except: pass
for user, count in users.most_common(10):
    print(f'{count:6d}  {user}')
"
```

Expected: Shows system accounts (`system:apiserver`, `system:kube-scheduler`, etc.) with the most calls, plus `kubernetes-admin` for the student's actions.

> **Coach tip:** In a real security investigation, you'd look for:
> - Unusual users accessing secrets (potential credential theft)
> - `pods/exec` from unexpected service accounts (potential container escape)
> - RBAC changes by non-admin users (privilege escalation)
> - High API call rates from a single source (potential reconnaissance)
>
> The audit policy levels control verbosity:
> - `None` — don't log
> - `Metadata` — log who/what/when (not request/response bodies)
> - `Request` — log metadata + request body
> - `RequestResponse` — log everything (most verbose, use for sensitive resources)

---

## Clean Up

```bash
# Task 1-2
kubectl delete pod apparmor-test seccomp-test seccomp-default 2>/dev/null

# Task 5 — local registry
docker rm -f registry 2>/dev/null

# Task 7 — Falco
kubectl delete pod falco-test 2>/dev/null
helm uninstall falco -n falco 2>/dev/null
kubectl delete namespace falco 2>/dev/null

# Task 8
kubectl delete pod immutable-app distroless-demo 2>/dev/null

# Task 9
kubectl delete pod audit-exec 2>/dev/null
kubectl delete secret audit-test-secret 2>/dev/null
kind delete cluster --name audit-lab 2>/dev/null
rm -rf audit-logs

# Tool artifacts
rm -f cosign.key cosign.pub nginx-scan.json nginx-sbom.cdx.json nginx-sbom.spdx.json nginx-trivy-sbom.cdx.json
rm -f block-dangerous.json kubesec_linux_amd64.tar.gz
rm -f insecure-pod.yaml secure-pod.yaml
```

---

## Break & Fix Solutions

### Scenario 1 — Seccomp profile not being applied

**Problem:** Pod spec references `localhostProfile: block-dangerous.json` but the file is at `/var/lib/kubelet/seccomp/profiles/block-dangerous.json`.

**Fix:** Change `localhostProfile` to `profiles/block-dangerous.json` — the path is relative to `/var/lib/kubelet/seccomp/`.

**How to verify the fix:**

```bash
kubectl get pod broken-seccomp -o yaml | grep -A3 seccompProfile
```

The `localhostProfile` should show `profiles/block-dangerous.json`.

### Scenario 2 — Immutable container crashing on startup

**Problem:** Nginx needs to write to `/var/cache/nginx`, `/var/run`, and `/tmp` but `readOnlyRootFilesystem: true` makes those read-only.

**Fix:** Add `emptyDir` volumes for writable paths:

```yaml
volumeMounts:
  - name: tmp
    mountPath: /tmp
  - name: cache
    mountPath: /var/cache/nginx
  - name: run
    mountPath: /var/run
volumes:
  - name: tmp
    emptyDir: {}
  - name: cache
    emptyDir: {}
  - name: run
    emptyDir: {}
```

**How to verify the fix:**

```bash
kubectl get pod broken-immutable
# Should show Running, not CrashLoopBackOff
kubectl exec broken-immutable -- nginx -t
# Should show "test is successful"
```

### Scenario 3 — Falco not detecting anything

**Problem:** eBPF driver failed to load (missing kernel headers or unsupported kernel).

**Fix:**

```bash
# Check driver status
kubectl logs -n falco -l app.kubernetes.io/name=falco | grep -i "driver\|error"

# Option 1: Switch to kernel module driver
helm upgrade falco falcosecurity/falco -n falco --set driver.kind=kmod

# Option 2: Install kernel headers
sudo apt-get install -y linux-headers-$(uname -r)
# Then restart Falco pods
kubectl rollout restart daemonset/falco -n falco
```

**How to verify the fix:**

```bash
kubectl logs -n falco -l app.kubernetes.io/name=falco | grep -i "driver.*loaded\|engine.*started"
# Then trigger a shell spawn and check for alerts
kubectl exec -it falco-test -- /bin/sh -c "exit"
kubectl logs -n falco -l app.kubernetes.io/name=falco --tail=5 | grep -i shell
```
