# Challenge 20 — Supply Chain & Runtime Security

[< Previous Challenge](Challenge-19.md) - **[Home](../README.md)**

## Introduction

On a hardened Linux server, security is layered. You restrict which system calls a process can make with `seccomp-bpf`. You confine daemons to only the files and capabilities they need with `AppArmor` or `SELinux`. You scan packages for known CVEs with tools like `apt-get audit` or `yum updateinfo`. You verify package signatures with GPG before installing. You run intrusion detection with `OSSEC` or `AIDE` to catch unexpected file changes or process spawns. And you ship every `syslog` and `auditd` entry to a central SIEM for analysis.

Kubernetes inherits all of these concerns — but the enforcement points move from the host into the cluster's API, the container runtime, and the supply chain pipeline. Instead of hardening one server, you're hardening an entire platform where workloads are ephemeral, images come from registries, and every API call is recorded in an audit log.

This **final challenge** brings together the remaining CKS (Certified Kubernetes Security Specialist) domains: **System Hardening**, **Minimize Microservice Vulnerabilities**, **Supply Chain Security**, and **Monitoring, Logging & Runtime Security**. You'll apply the same defense-in-depth philosophy you know from Linux — just with Kubernetes-native tools.

| Linux Concept | Kubernetes Equivalent | Notes |
|---|---|---|
| AppArmor / SELinux profiles | `appArmorProfile` in securityContext | Confine container processes to allowed file/network/capability access |
| `seccomp-bpf` syscall filtering | `seccompProfile` in securityContext | Block dangerous syscalls like `unshare`, `mount`, `ptrace` |
| `dpkg --list` / `rpm -qa` | SBOM generation with `syft` or `trivy` | Inventory every package in a container image |
| `gpg --verify` package signatures | `cosign sign` / `cosign verify` | Cryptographic image signing and verification |
| `apt-get audit` / Nessus scans | `trivy image` vulnerability scanning | Find CVEs in container images before deployment |
| `shellcheck` for scripts | `kubesec scan` / `kube-linter lint` | Static analysis of Kubernetes manifests for security misconfigurations |
| OSSEC / AIDE / auditd | Falco runtime threat detection | Detect suspicious syscalls, file access, network activity in containers |
| CIS Benchmarks / `lynis audit` | Minimize host OS footprint, immutable containers | Reduce attack surface on nodes and in container images |
| `/var/log/audit/audit.log` | Kubernetes API audit logs | Record who did what to which resource and when |

> **Cluster requirements:**
> - **Tasks marked [VM]** require SSH access to a kubeadm cluster node (from Challenge 18). AppArmor and Falco operate at the kernel/node level.
> - **Tasks marked [Kind]** run on your local Kind cluster — no cloud account needed.
>
> ```bash
> # If you need a fresh Kind cluster:
> kind create cluster --name fasthack
> ```

## Description

### Task 1 — AppArmor Profiles for Containers [VM]

AppArmor on Kubernetes works the same way as on a Linux server — you write a profile that restricts file access, capabilities, and network operations, then enforce it. The difference is that the profile is applied to container processes via the Pod's `securityContext`.

**Step 1:** SSH into your kubeadm worker node and create an AppArmor profile that denies writes to `/etc`. Save as `/etc/apparmor.d/k8s-deny-etc-write`:

```
#include <tunables/global>

profile k8s-deny-etc-write flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>

  # Allow everything by default
  file,

  # Deny writes to /etc
  deny /etc/** w,
  deny /etc/ w,
}
```

**Step 2:** Load and verify the profile:

```bash
sudo apparmor_parser -r /etc/apparmor.d/k8s-deny-etc-write
sudo aa-status | grep k8s-deny-etc-write
```

**Step 3:** Create a Pod that uses this profile. On Kubernetes 1.30+, use the `securityContext` field. Save as `apparmor-pod.yaml`:

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

> **Note:** For clusters running Kubernetes < 1.30, use the annotation approach instead:
> ```yaml
> metadata:
>   annotations:
>     container.apparmor.security.beta.kubernetes.io/shell: localhost/k8s-deny-etc-write
> ```

**Step 4:** Apply and test — writes to `/etc` should be denied:

```bash
kubectl apply -f apparmor-pod.yaml
kubectl exec apparmor-test -- touch /tmp/allowed          # Should succeed
kubectl exec apparmor-test -- touch /etc/blocked           # Should be DENIED
```

**Step 5:** Verify the AppArmor profile is active inside the container:

```bash
kubectl exec apparmor-test -- cat /proc/1/attr/current
```

You should see `k8s-deny-etc-write (enforce)`.

### Task 2 — Custom Seccomp Profiles [VM/Kind]

Seccomp (Secure Computing Mode) filters syscalls at the kernel level — like `seccomp-bpf` on Linux. You create a JSON profile that allowlists or blocklists specific system calls, then reference it from the Pod spec.

**Step 1:** Create a custom seccomp profile that blocks dangerous syscalls. On the node (VM) or Kind container, place it at the kubelet seccomp profile path:

```bash
# For VM (kubeadm):
sudo mkdir -p /var/lib/kubelet/seccomp/profiles

# For Kind — exec into the control plane node:
docker exec -it fasthack-control-plane mkdir -p /var/lib/kubelet/seccomp/profiles
```

Create the profile file `block-dangerous.json`:

```json
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
```

**Step 2:** Copy the profile to the correct location:

```bash
# For VM:
sudo cp block-dangerous.json /var/lib/kubelet/seccomp/profiles/

# For Kind:
docker cp block-dangerous.json fasthack-control-plane:/var/lib/kubelet/seccomp/profiles/
```

**Step 3:** Create a Pod that uses this seccomp profile. Save as `seccomp-pod.yaml`:

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

**Step 4:** Apply and verify the blocked syscalls:

```bash
kubectl apply -f seccomp-pod.yaml

# This should fail — unshare is blocked
kubectl exec seccomp-test -- unshare --user --pid --fork --mount-proc readlink /proc/self/ns/user

# This should succeed — normal commands are allowed
kubectl exec seccomp-test -- ls /
```

**Step 5:** Also create a Pod with `RuntimeDefault` seccomp profile (the recommended baseline):

```yaml
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
```

### Task 3 — Image Scanning with Trivy [Kind]

Trivy scans container images for known CVEs — like running `apt-get audit` or a Nessus scan against every package in the image. It checks the OS packages, language-specific dependencies, and configuration files.

**Step 1:** Install Trivy:

```bash
# On Ubuntu/Debian:
sudo apt-get install -y wget apt-transport-https gnupg lsb-release
wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | sudo apt-key add -
echo "deb https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -sc) main" | sudo tee /etc/apt/sources.list.d/trivy.list
sudo apt-get update && sudo apt-get install -y trivy

# Or direct binary:
curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin
```

**Step 2:** Scan an image with known vulnerabilities:

```bash
# Scan nginx for all vulnerability severities
trivy image nginx:1.21

# Filter to only HIGH and CRITICAL
trivy image --severity HIGH,CRITICAL nginx:1.21

# Scan with JSON output for automation
trivy image -f json -o nginx-scan.json nginx:1.21
```

**Step 3:** Scan a minimal image and compare:

```bash
trivy image nginx:1.27-alpine
```

**Step 4:** Scan ignoring unfixed CVEs (only show actionable vulnerabilities):

```bash
trivy image --ignore-unfixed nginx:1.21
```

**Step 5:** Compare the vulnerability counts between `nginx:1.21`, `nginx:1.27`, and `nginx:1.27-alpine`. Note how newer and smaller images have fewer CVEs.

### Task 4 — SBOM Generation [Kind]

A Software Bill of Materials (SBOM) is the container equivalent of `dpkg --list` — it inventories every package, library, and dependency inside an image. SBOMs are essential for vulnerability tracking, license compliance, and incident response.

**Step 1:** Install syft:

```bash
curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin
```

**Step 2:** Generate an SBOM with syft:

```bash
# Default table output — human-readable
syft nginx:1.27-alpine

# CycloneDX JSON format (industry standard)
syft nginx:1.27-alpine -o cyclonedx-json > nginx-sbom.cdx.json

# SPDX JSON format
syft nginx:1.27-alpine -o spdx-json > nginx-sbom.spdx.json
```

**Step 3:** Generate an SBOM using Trivy (alternative tool):

```bash
trivy image --format cyclonedx -o nginx-trivy-sbom.cdx.json nginx:1.27-alpine
```

**Step 4:** Scan the SBOM for vulnerabilities (Trivy can scan SBOMs directly):

```bash
trivy sbom nginx-sbom.cdx.json
```

**Step 5:** Compare the package counts between a full image and an Alpine/distroless image:

```bash
syft nginx:1.27 | wc -l
syft nginx:1.27-alpine | wc -l
syft gcr.io/distroless/static-debian12 | wc -l
```

### Task 5 — Sign and Verify Images with Cosign [Kind]

Cosign provides cryptographic signing for container images — like GPG-signing `.deb` packages so you can verify they haven't been tampered with.

**Step 1:** Install cosign:

```bash
curl -LO "https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64"
chmod +x cosign-linux-amd64
sudo mv cosign-linux-amd64 /usr/local/bin/cosign
cosign version
```

**Step 2:** Generate a key pair:

```bash
cosign generate-key-pair
# Creates cosign.key (private) and cosign.pub (public)
# You'll be prompted for a password — remember it
```

**Step 3:** For this exercise, we'll use a local registry to push and sign an image:

```bash
# Start a local registry (if not already running)
docker run -d -p 5000:5000 --name registry registry:2

# Tag and push an image
docker pull busybox:1.36
docker tag busybox:1.36 localhost:5000/busybox:signed
docker push localhost:5000/busybox:signed
```

**Step 4:** Sign the image:

```bash
cosign sign --key cosign.key localhost:5000/busybox:signed --allow-insecure-registry
```

**Step 5:** Verify the signature:

```bash
cosign verify --key cosign.pub localhost:5000/busybox:signed --allow-insecure-registry
```

The output will show the signature payload with verified metadata. An unsigned or tampered image would fail verification.

**Step 6:** Try verifying an unsigned image — it should fail:

```bash
docker tag busybox:1.36 localhost:5000/busybox:unsigned
docker push localhost:5000/busybox:unsigned
cosign verify --key cosign.pub localhost:5000/busybox:unsigned --allow-insecure-registry
```

### Task 6 — Static Analysis with Kubesec and KubeLinter [Kind]

Static analysis tools scan your YAML manifests for security misconfigurations before you even deploy — like `shellcheck` for shell scripts or `lint` for code.

**Step 1:** Install kubesec and kube-linter:

```bash
# kubesec — easiest via Docker
# Or download binary:
curl -LO https://github.com/controlplaneio/kubesec/releases/latest/download/kubesec_linux_amd64.tar.gz
tar xzf kubesec_linux_amd64.tar.gz
sudo mv kubesec /usr/local/bin/

# kube-linter
curl -LO https://github.com/stackrox/kube-linter/releases/latest/download/kube-linter-linux
chmod +x kube-linter-linux
sudo mv kube-linter-linux /usr/local/bin/kube-linter
```

**Step 2:** Create an intentionally insecure manifest. Save as `insecure-pod.yaml`:

```yaml
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

**Step 3:** Scan with kubesec:

```bash
kubesec scan insecure-pod.yaml
```

Review the JSON output — note the **score** (lower is worse), the **critical** and **advisory** findings. A privileged container running as root will score very poorly.

**Step 4:** Scan with kube-linter:

```bash
kube-linter lint insecure-pod.yaml
```

Note the specific checks that fail (e.g., `run-as-non-root`, `no-read-only-root-fs`, `unset-cpu-requirements`).

**Step 5:** Create a hardened version and re-scan. Save as `secure-pod.yaml`:

```yaml
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

Compare the scores — the hardened manifest should score significantly better.

### Task 7 — Runtime Threat Detection with Falco [VM]

Falco is the Kubernetes equivalent of `OSSEC` or `AIDE` — it monitors syscalls in real time and alerts when suspicious activity occurs (shell spawns in containers, sensitive file reads, unexpected network connections).

**Step 1:** Install Falco on your kubeadm cluster using Helm:

```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update

helm install falco falcosecurity/falco \
  --namespace falco \
  --create-namespace \
  --set driver.kind=modern_ebpf \
  --set tty=true
```

**Step 2:** Verify Falco is running:

```bash
kubectl get pods -n falco -o wide
kubectl wait --namespace falco --for=condition=ready pod --selector=app.kubernetes.io/name=falco --timeout=120s
```

**Step 3:** Watch Falco logs in one terminal:

```bash
kubectl logs -n falco -l app.kubernetes.io/name=falco -f --tail=50
```

**Step 4:** In another terminal, trigger a detection — spawn a shell inside a container:

```bash
# Create a test Pod
kubectl run falco-test --image=nginx:1.27-alpine --restart=Never

# Wait for it to be ready
kubectl wait --for=condition=ready pod/falco-test --timeout=60s

# Spawn a shell — Falco should detect this!
kubectl exec -it falco-test -- /bin/sh -c "whoami && cat /etc/shadow"
```

**Step 5:** Check Falco logs for the alert:

```bash
kubectl logs -n falco -l app.kubernetes.io/name=falco --tail=20 | grep -i "shell\|exec\|shadow"
```

You should see alerts like:
- `Notice A shell was spawned in a container`
- `Warning Sensitive file opened for reading (file=/etc/shadow)`

**Step 6:** Examine Falco's default rules:

```bash
kubectl get configmap -n falco falco-rules -o yaml | head -100
```

### Task 8 — Container Immutability [Kind]

An immutable container is the equivalent of mounting a filesystem read-only (`mount -o ro`) and removing all administrative tools (`rm /bin/sh`). If an attacker gets into a container, they can't modify files, install backdoors, or use a shell.

**Step 1:** Create a Pod with `readOnlyRootFilesystem` and `emptyDir` for temp files. Save as `immutable-pod.yaml`:

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

**Step 2:** Apply and verify the filesystem is read-only:

```bash
kubectl apply -f immutable-pod.yaml

# This should FAIL — filesystem is read-only
kubectl exec immutable-app -- touch /usr/share/nginx/html/hacked.html

# This should SUCCEED — /tmp is writable via emptyDir
kubectl exec immutable-app -- touch /tmp/allowed.txt
```

**Step 3:** Demonstrate why distroless images improve security — they have no shell:

```bash
# Create a Pod with a distroless image
kubectl run distroless-test --image=gcr.io/distroless/static-debian12 --restart=Never --command -- /bin/sleep 3600

# This will fail because the image doesn't have sleep — that's the point!
# Use a real distroless app image in practice

# Try to exec into it — no shell available
kubectl run distroless-demo --image=gcr.io/distroless/base-debian12 --restart=Never --command -- sleep 3600
kubectl exec -it distroless-demo -- /bin/sh
# Error: OCI runtime exec failed: exec failed: unable to start container process: exec: "/bin/sh": stat /bin/sh: no such file or directory
```

**Step 4:** List the packages in distroless vs. regular images to see the attack surface difference:

```bash
# Regular Debian-based image
syft nginx:1.27 | wc -l

# Alpine-based
syft nginx:1.27-alpine | wc -l

# Distroless
syft gcr.io/distroless/static-debian12 | wc -l
```

### Task 9 — Kubernetes Audit Log Analysis [Kind]

Kubernetes audit logs record every API request — like `auditd` on Linux but for the cluster API. They tell you who created, modified, or deleted resources, and can reveal suspicious activity like unauthorized secret access or privilege escalation attempts.

**Step 1:** Create an audit policy. Save as `audit-policy.yaml`:

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  # Don't log requests to the healthz endpoints or API discovery
  - level: None
    nonResourceURLs:
      - "/healthz*"
      - "/version"
      - "/swagger*"
      - "/readyz*"
      - "/livez*"

  # Log Secret access at Metadata level (don't log the actual secret data!)
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets"]

  # Log RBAC changes at RequestResponse level
  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["clusterroles", "clusterrolebindings", "roles", "rolebindings"]

  # Log Pod creation/deletion at Request level
  - level: Request
    resources:
      - group: ""
        resources: ["pods", "pods/exec", "pods/portforward"]
    verbs: ["create", "delete", "patch", "update"]

  # Log everything else at Metadata level
  - level: Metadata
    omitStages:
      - "RequestReceived"
```

**Step 2:** For Kind, create a cluster with audit logging enabled. Save as `kind-audit.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
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
```

```bash
# Copy the audit policy into the Kind node first, then create the cluster
kind create cluster --name audit-lab --config kind-audit.yaml

# Copy the audit policy into the node
docker cp audit-policy.yaml audit-lab-control-plane:/etc/kubernetes/audit-policy.yaml

# The API server needs to be restarted to pick up the policy
# For Kind, recreate the cluster with the policy pre-loaded:
kind delete cluster --name audit-lab

# Create the policy file inside the node image by using an init container approach
# Simplest method: mount the policy via Kind's extraMounts
```

**Alternative approach — use extraMounts in Kind config:**

```yaml
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
```

```bash
mkdir -p audit-logs
kind create cluster --name audit-lab --config kind-audit.yaml
```

**Step 3:** Generate some audit events:

```bash
# Create a secret
kubectl create secret generic audit-test-secret --from-literal=password=supersecret

# Create and delete a Pod
kubectl run audit-pod --image=busybox:1.36 --restart=Never --command -- sleep 30
kubectl delete pod audit-pod

# Exec into a Pod
kubectl run audit-exec --image=busybox:1.36 --restart=Never --command -- sleep 3600
kubectl wait --for=condition=ready pod/audit-exec --timeout=60s
kubectl exec audit-exec -- whoami
```

**Step 4:** Analyze the audit log:

```bash
# Read the audit log from the Kind node
docker exec audit-lab-control-plane cat /var/log/kubernetes/audit.log | head -50

# Find who accessed secrets
docker exec audit-lab-control-plane cat /var/log/kubernetes/audit.log | \
  python3 -c "
import sys, json
for line in sys.stdin:
    try:
        e = json.loads(line)
        if e.get('objectRef', {}).get('resource') == 'secrets':
            print(f\"{e['verb']} {e['objectRef'].get('name','?')} by {e['user'].get('username','?')} at {e['requestReceivedTimestamp']}\")
    except: pass
"

# Find Pod exec events (potential container escape indicator)
docker exec audit-lab-control-plane cat /var/log/kubernetes/audit.log | \
  python3 -c "
import sys, json
for line in sys.stdin:
    try:
        e = json.loads(line)
        if e.get('objectRef', {}).get('subresource') == 'exec':
            print(f\"EXEC into {e['objectRef'].get('name','?')} by {e['user'].get('username','?')} at {e['requestReceivedTimestamp']}\")
    except: pass
"
```

**Step 5:** Identify suspicious patterns in the audit log:

```bash
# Count API calls per user — spot unusual activity
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

### Clean Up

```bash
# Task 1-2 resources
kubectl delete pod apparmor-test seccomp-test seccomp-default 2>/dev/null

# Task 3-6 artifacts
rm -f nginx-scan.json nginx-sbom.cdx.json nginx-sbom.spdx.json nginx-trivy-sbom.cdx.json
rm -f cosign.key cosign.pub
rm -f insecure-pod.yaml secure-pod.yaml

# Task 7 resources
kubectl delete pod falco-test 2>/dev/null
helm uninstall falco -n falco 2>/dev/null
kubectl delete namespace falco 2>/dev/null

# Task 8-9 resources
kubectl delete pod immutable-app distroless-test distroless-demo 2>/dev/null
kubectl delete pod audit-exec 2>/dev/null
kubectl delete secret audit-test-secret 2>/dev/null
kind delete cluster --name audit-lab 2>/dev/null
rm -rf audit-logs
```

## Success Criteria

- [ ] **Task 1:** You created and loaded an AppArmor profile, applied it to a Pod via `securityContext`, and verified that writes to `/etc` are denied.
- [ ] **Task 2:** You created a custom seccomp profile that blocks `unshare`/`mount`/`ptrace`, applied it to a Pod, and verified the syscalls are blocked.
- [ ] **Task 3:** You scanned container images with Trivy, filtered by severity, and can explain the difference in CVE counts between full, Alpine, and distroless images.
- [ ] **Task 4:** You generated SBOMs in CycloneDX and SPDX formats using both syft and Trivy, and scanned an SBOM for vulnerabilities.
- [ ] **Task 5:** You generated a cosign key pair, signed a container image, verified the signature, and demonstrated that unsigned images fail verification.
- [ ] **Task 6:** You scanned manifests with kubesec and kube-linter, compared scores between insecure and hardened manifests.
- [ ] **Task 7:** You installed Falco, triggered a shell spawn detection by exec'ing into a container, and found the alert in Falco logs.
- [ ] **Task 8:** You deployed a Pod with `readOnlyRootFilesystem`, verified writes fail on the root filesystem but succeed on `emptyDir` mounts.
- [ ] **Task 9:** You configured Kubernetes audit logging, generated audit events, and analyzed the log to find secret access and Pod exec events.

## Linux ↔ Kubernetes Reference

| Linux Concept | Kubernetes Equivalent | Notes |
|---|---|---|
| `apparmor_parser -r /etc/apparmor.d/profile` | `securityContext.appArmorProfile.type: Localhost` | Load profile on node, reference in Pod spec |
| `seccomp-bpf` filter program | `securityContext.seccompProfile.type: Localhost` | JSON profile at `/var/lib/kubelet/seccomp/profiles/` |
| `RuntimeDefault` seccomp = CRI default | `seccompProfile.type: RuntimeDefault` | Recommended baseline for all Pods |
| `dpkg --list` / `rpm -qa` | `syft <image>` or `trivy image --format cyclonedx` | Generate SBOM of container contents |
| `gpg --sign` / `gpg --verify` | `cosign sign --key` / `cosign verify --key` | Cryptographic image signing |
| `apt-get audit` / Nessus | `trivy image --severity HIGH,CRITICAL` | CVE scanning with severity filtering |
| `shellcheck myscript.sh` | `kubesec scan pod.yaml` / `kube-linter lint pod.yaml` | Static security analysis of manifests |
| OSSEC / AIDE (file integrity) | Falco DaemonSet | Real-time syscall monitoring and alerting |
| `mount -o ro /` | `readOnlyRootFilesystem: true` + `emptyDir` for temp | Prevent file modifications in containers |
| `/var/log/audit/audit.log` | `--audit-log-path=/var/log/kubernetes/audit.log` | API server audit logging |
| `ausearch -m execve -i` | Parse audit log JSON for `pods/exec` subresource | Find who exec'd into containers |

## Hints

<details>
<summary>Hint 1: AppArmor profile not loading</summary>

Make sure the profile is loaded on the **node where the Pod will be scheduled**, not just the control plane. On a kubeadm cluster, SSH into the worker node:

```bash
sudo apparmor_parser -r /etc/apparmor.d/k8s-deny-etc-write
sudo aa-status | grep k8s-deny-etc-write
```

If the Pod is stuck in `Blocked` status, the profile name in the Pod spec must **exactly** match the profile name in the file (the `profile <name>` line).

For Kubernetes < 1.30, use the annotation:
```yaml
container.apparmor.security.beta.kubernetes.io/<container-name>: localhost/<profile-name>
```

</details>

<details>
<summary>Hint 2: Seccomp profile path confusion</summary>

The `localhostProfile` path in the Pod spec is **relative** to the kubelet's seccomp profile root directory: `/var/lib/kubelet/seccomp/`.

So if your file is at `/var/lib/kubelet/seccomp/profiles/block-dangerous.json`, the Pod spec should have:
```yaml
seccompProfile:
  type: Localhost
  localhostProfile: profiles/block-dangerous.json
```

On Kind, copy the file into the container node:
```bash
docker cp block-dangerous.json fasthack-control-plane:/var/lib/kubelet/seccomp/profiles/
```

</details>

<details>
<summary>Hint 3: Trivy not finding vulnerabilities</summary>

Trivy downloads its vulnerability database on first run. If you're offline or behind a proxy, pre-download the DB:

```bash
trivy image --download-db-only
```

Use an **older image** like `nginx:1.21` to see more CVEs. Newer images have fewer known vulnerabilities. Use `--severity HIGH,CRITICAL` to focus on impactful issues.

</details>

<details>
<summary>Hint 4: Cosign sign fails with registry errors</summary>

For a local registry without TLS, you must use `--allow-insecure-registry`:

```bash
cosign sign --key cosign.key localhost:5000/busybox:signed --allow-insecure-registry
```

Make sure the registry is running:
```bash
docker ps | grep registry
```

If not, start it:
```bash
docker run -d -p 5000:5000 --name registry registry:2
```

</details>

<details>
<summary>Hint 5: Falco not detecting shell spawns</summary>

Check that Falco Pods are `Running` and the driver loaded successfully:

```bash
kubectl get pods -n falco
kubectl logs -n falco -l app.kubernetes.io/name=falco | head -20
```

If the eBPF driver fails to load, try the kernel module driver:
```bash
helm upgrade falco falcosecurity/falco -n falco --set driver.kind=kmod
```

Falco rules for shell detection are in the default ruleset. Check with:
```bash
kubectl logs -n falco -l app.kubernetes.io/name=falco | grep -i "shell\|exec"
```

</details>

<details>
<summary>Hint 6: Kind audit log cluster not starting</summary>

The audit policy file must exist on the host **before** creating the Kind cluster when using `extraMounts`. Create the file first:

```bash
# Save audit-policy.yaml locally
mkdir -p audit-logs
kind create cluster --name audit-lab --config kind-audit.yaml
```

Verify the API server has the audit flags:
```bash
docker exec audit-lab-control-plane cat /etc/kubernetes/manifests/kube-apiserver.yaml | grep audit
```

Check if audit logs are being written:
```bash
docker exec audit-lab-control-plane ls -la /var/log/kubernetes/
```

</details>

## Learning Resources

- [Kubernetes AppArmor documentation](https://kubernetes.io/docs/tutorials/security/apparmor/)
- [Kubernetes Seccomp tutorial](https://kubernetes.io/docs/tutorials/security/seccomp/)
- [Trivy vulnerability scanner](https://aquasecurity.github.io/trivy/)
- [Syft SBOM generator](https://github.com/anchore/syft)
- [Sigstore Cosign documentation](https://docs.sigstore.dev/cosign/overview/)
- [Kubesec — security risk analysis](https://kubesec.io/)
- [KubeLinter — static analysis](https://docs.kubelinter.io/)
- [Falco — runtime security](https://falco.org/docs/)
- [Kubernetes Auditing](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/)
- [CKS Curriculum](https://github.com/cncf/curriculum/blob/master/CKS_Curriculum_v1.31.pdf)
- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)

## Break & Fix 🔧

Try each scenario, diagnose the problem, and fix it.

### Scenario 1 — Seccomp profile not being applied

Apply this Pod:

```yaml
# Save as broken-seccomp.yaml
apiVersion: v1
kind: Pod
metadata:
  name: broken-seccomp
spec:
  securityContext:
    seccompProfile:
      type: Localhost
      localhostProfile: block-dangerous.json
  containers:
    - name: shell
      image: busybox:1.36
      command: ["sleep", "3600"]
      resources:
        requests:
          cpu: 50m
          memory: 32Mi
```

```bash
kubectl apply -f broken-seccomp.yaml
kubectl get pod broken-seccomp
```

**What you'll see:** The Pod is stuck in `CreateContainerError` or `Error` status.

**Diagnose:**

```bash
kubectl describe pod broken-seccomp | grep -A5 Events
```

**Root cause:** The `localhostProfile` path is wrong. The profile was placed at `/var/lib/kubelet/seccomp/profiles/block-dangerous.json`, but the Pod spec references `block-dangerous.json` (without the `profiles/` prefix).

**Fix:** Update the profile path:

```bash
kubectl delete pod broken-seccomp
```

Edit the Pod spec to use `localhostProfile: profiles/block-dangerous.json` and re-apply.

**Linux analogy:** It's like specifying the wrong path in an `LD_PRELOAD` — the library exists but the loader can't find it at the path you gave.

---

### Scenario 2 — Immutable container crashing on startup

Apply this Pod:

```yaml
# Save as broken-immutable.yaml
apiVersion: v1
kind: Pod
metadata:
  name: broken-immutable
spec:
  containers:
    - name: nginx
      image: nginx:1.27
      securityContext:
        readOnlyRootFilesystem: true
      ports:
        - containerPort: 80
      resources:
        requests:
          cpu: 50m
          memory: 32Mi
```

```bash
kubectl apply -f broken-immutable.yaml
kubectl get pod broken-immutable --watch
```

**What you'll see:** The Pod enters `CrashLoopBackOff`. Nginx can't start.

**Diagnose:**

```bash
kubectl logs broken-immutable
```

You'll see errors like: `nginx: [emerg] mkdir() "/var/cache/nginx/client_temp" failed (30: Read-only file system)`.

**Root cause:** Nginx needs to write to `/var/cache/nginx`, `/var/run`, and `/tmp` at startup. With `readOnlyRootFilesystem: true`, those paths are read-only.

**Fix:** Add `emptyDir` volumes for the writable paths:

```bash
kubectl delete pod broken-immutable
```

Add `volumeMounts` for `/tmp`, `/var/cache/nginx`, and `/var/run` backed by `emptyDir` volumes (see Task 8 for the correct manifest).

**Linux analogy:** It's like mounting a filesystem read-only (`mount -o ro /`) and then wondering why `nginx` can't create its PID file in `/var/run/`.

---

### Scenario 3 — Falco not detecting anything

Falco is installed and running but no alerts appear even after exec'ing into containers.

```bash
kubectl exec -it falco-test -- /bin/sh -c "whoami"
kubectl logs -n falco -l app.kubernetes.io/name=falco --tail=10
```

**What you'll see:** No shell-related alerts in the logs.

**Diagnose:**

```bash
# Check if Falco driver loaded
kubectl logs -n falco -l app.kubernetes.io/name=falco | grep -i "driver\|error\|fail"

# Check if rules are loaded
kubectl logs -n falco -l app.kubernetes.io/name=falco | grep -i "rule"
```

**Root cause (possible):** The eBPF driver failed to load due to missing kernel headers or an unsupported kernel version. Falco starts but can't intercept syscalls.

**Fix:** Switch to the kernel module driver or ensure kernel headers are installed:

```bash
# Switch driver
helm upgrade falco falcosecurity/falco -n falco --set driver.kind=kmod

# Or on the node:
sudo apt-get install -y linux-headers-$(uname -r)
```

After fixing, restart Falco and retry the exec test.

**Linux analogy:** It's like installing OSSEC but forgetting to load the kernel auditing module — the tool runs but can't see any events.

---

## 🎉 Congratulations — You've Completed the FastHack Kubernetes Hackathon!

You've made it through all **20 challenges** — from your first Pod to supply chain security. Here's what you've accomplished:

### Your Journey — All 20 Challenges

| # | Challenge | Key Skills |
|---|---|---|
| 01 | Core Concepts | Pods, kubectl, cluster architecture |
| 02 | Namespaces & Labels | Organization, label selectors, resource isolation |
| 03 | Deployments & ReplicaSets | Declarative workloads, scaling, self-healing |
| 04 | Rollouts & Rollbacks | Update strategies, revision history, undo |
| 05 | Services & Networking | ClusterIP, NodePort, LoadBalancer, DNS |
| 06 | ConfigMaps & Secrets | Configuration injection, environment variables, volumes |
| 07 | Storage & Persistence | PVs, PVCs, StorageClasses, dynamic provisioning |
| 08 | Scheduling & Node Affinity | nodeSelector, affinity, taints, tolerations |
| 09 | Pod Security | SecurityContext, Pod Security Standards, RBAC basics |
| 10 | Ingress & Traffic Management | Ingress controllers, path/host routing, TLS |
| 11 | StatefulSets & Headless Services | Ordered deployment, stable network IDs, persistent storage |
| 12 | DaemonSets, Jobs & CronJobs | Node-level workloads, batch processing, scheduled tasks |
| 13 | Resource Management | Requests, limits, LimitRanges, ResourceQuotas |
| 14 | Health Checks & Observability | Liveness, readiness, startup probes, monitoring |
| 15 | RBAC Deep Dive | Roles, ClusterRoles, ServiceAccounts, least privilege |
| 16 | Troubleshooting & Debugging | Pod/node/network diagnostics, log analysis |
| 17 | Advanced Deployment Strategies | Blue/green, canary, rolling update tuning, API deprecation |
| 18 | Cluster Setup with kubeadm | Bootstrap production clusters, etcd, certificates |
| 19 | Network Policies & Service Mesh | L3/L4 network segmentation, zero-trust networking |
| 20 | Supply Chain & Runtime Security | AppArmor, seccomp, Trivy, Falco, cosign, audit logs |

### Certification Readiness Assessment

**CKA (Certified Kubernetes Administrator) — Domains Covered:**

| CKA Domain | Weight | Challenges |
|---|---|---|
| Cluster Architecture, Installation & Configuration | 25% | Ch01, Ch18 |
| Workloads & Scheduling | 15% | Ch03, Ch04, Ch08, Ch12 |
| Services & Networking | 20% | Ch05, Ch10, Ch19 |
| Storage | 10% | Ch07, Ch11 |
| Troubleshooting | 30% | Ch14, Ch16 |

**CKAD (Certified Kubernetes Application Developer) — Domains Covered:**

| CKAD Domain | Weight | Challenges |
|---|---|---|
| Application Design and Build | 20% | Ch03, Ch04, Ch11, Ch12 |
| Application Deployment | 20% | Ch04, Ch17 |
| Application Observability and Maintenance | 15% | Ch14, Ch16 |
| Application Environment, Configuration and Security | 25% | Ch02, Ch06, Ch08, Ch09, Ch13 |
| Services & Networking | 20% | Ch05, Ch10 |

**CKS (Certified Kubernetes Security Specialist) — Domains Covered:**

| CKS Domain | Weight | Challenges |
|---|---|---|
| Cluster Setup | 10% | Ch18, Ch19 |
| Cluster Hardening | 15% | Ch09, Ch15 |
| System Hardening | 15% | Ch20 (Tasks 1-2) |
| Minimize Microservice Vulnerabilities | 20% | Ch09, Ch20 (Tasks 6, 8) |
| Supply Chain Security | 20% | Ch20 (Tasks 3-6) |
| Monitoring, Logging & Runtime Security | 20% | Ch14, Ch20 (Tasks 7, 9) |

### Recommended Next Steps

1. **Practice Exams:**
   - [Killer.sh](https://killer.sh/) — The exam simulator used by the Linux Foundation (included with exam purchase)
   - [KillerCoda CKA/CKAD/CKS Scenarios](https://killercoda.com/) — Free browser-based labs

2. **Official Training:**
   - [Linux Foundation — CKA Course (LFS258)](https://training.linuxfoundation.org/training/kubernetes-fundamentals/)
   - [Linux Foundation — CKAD Course (LFD259)](https://training.linuxfoundation.org/training/kubernetes-for-developers/)
   - [Linux Foundation — CKS Course (LFS260)](https://training.linuxfoundation.org/training/kubernetes-security-essentials-lfs260/)

3. **Register for Exams:**
   - [CKA Exam](https://training.linuxfoundation.org/certification/certified-kubernetes-administrator-cka/)
   - [CKAD Exam](https://training.linuxfoundation.org/certification/certified-kubernetes-application-developer-ckad/)
   - [CKS Exam](https://training.linuxfoundation.org/certification/certified-kubernetes-security-specialist/)

4. **Continue Learning:**
   - Visit **[k8shackathon.com](https://k8shackathon.com)** for updates, additional challenges, and community resources
   - Join the [Kubernetes Slack](https://slack.k8s.io/) — channels: `#cka-prep`, `#ckad-prep`, `#cks-prep`
   - Read the [Kubernetes Documentation](https://kubernetes.io/docs/home/) — the official docs are allowed during the exam

> **Remember:** The exams are performance-based. You'll have a terminal with `kubectl` access and must solve real tasks under time pressure. The hands-on skills you've built in these 20 challenges are exactly what you need. Practice speed, learn `kubectl` shortcuts, and bookmark key documentation pages.
>
> **You're ready. Go get certified! 🚀**
