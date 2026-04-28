# Challenge 19 — Cluster Security & Hardening

[< Previous Challenge](Challenge-18.md) - **[Home](../README.md)** - [Next Challenge >](Challenge-20.md)

## Introduction

On a Linux server, security hardening is a discipline you already know. You run **Lynis** or **OpenSCAP** to audit the system against CIS benchmarks and fix the findings one by one. You lock down SSH with `/etc/ssh/sshd_config` — disabling root login, enforcing key-only auth. You use **iptables** or **firewalld** to restrict which IPs can reach which ports. You audit privilege with `visudo` and the principle of least privilege. You encrypt disks with **LUKS/dm-crypt** so data at rest is unreadable without the key. You configure **auditd** to track who did what and when. And before trusting a downloaded binary, you verify its `sha256sum` against the publisher's checksum.

Kubernetes has direct analogs for every one of these practices. The **Certified Kubernetes Security Specialist (CKS)** exam tests your ability to apply them in a cluster context. In this challenge, you will harden a kubeadm cluster end-to-end — from benchmarking against CIS standards and locking down the API server, to encrypting Secrets at rest and enabling audit logging.

| Linux Practice | Kubernetes Equivalent |
|---|---|
| Lynis / OpenSCAP CIS audit | **kube-bench** — CIS Kubernetes Benchmark |
| Nginx + Let's Encrypt TLS certs | **cert-manager** + Ingress TLS termination |
| `iptables -A OUTPUT -d 169.254.169.254 -j DROP` | **NetworkPolicy** blocking cloud metadata endpoint |
| `sha256sum` / `gpg --verify` on downloaded packages | SHA256 checksum verification of K8s binaries |
| `visudo` — audit sudoers, least privilege | **RBAC** — audit ClusterRoleBindings, minimize permissions |
| Disable root login + use service-specific users | **ServiceAccount hardening** — disable automount, dedicated SAs |
| `iptables` / `firewalld` restricting SSH access | API server flags restricting access |
| `auditd` — track system calls and user actions | **Kubernetes audit logging** — audit policy + log backend |
| LUKS / dm-crypt disk encryption | **EncryptionConfiguration** — Secrets encryption at rest |

> **Cluster requirement:** This challenge requires a **kubeadm cluster** (VMs or bare-metal). If you completed Challenge 18, use that cluster. If not, set up a minimal kubeadm cluster with one control-plane and one worker node. Some tasks (NetworkPolicy, RBAC, ServiceAccount) can also be practiced on a Kind cluster, but kube-bench, audit logging, and encryption at rest require control-plane access to static Pod manifests and API server flags.
>
> **Kind limitations:** Tasks 1 (kube-bench), 6 (audit logging), and 7 (encryption at rest) require direct access to `/etc/kubernetes/manifests/kube-apiserver.yaml` and control-plane node filesystem — these **cannot** be done on Kind.

## Description

### Task 1 — CIS Kubernetes Benchmark with kube-bench

On Linux you'd run `lynis audit system` or `oscap xccdf eval` to check your server against CIS benchmarks. The Kubernetes equivalent is **kube-bench** from Aqua Security — it evaluates your cluster against the CIS Kubernetes Benchmark and reports PASS/FAIL/WARN for each control.

**Step 1:** SSH into your **control-plane** node and download kube-bench:

```bash
# Download and extract kube-bench
curl -L https://github.com/aquasecurity/kube-bench/releases/latest/download/kube-bench_0.10.7_linux_amd64.tar.gz -o kube-bench.tar.gz
tar xzf kube-bench.tar.gz
```

**Step 2:** Run kube-bench against the control-plane (master) node:

```bash
sudo ./kube-bench run --targets master
```

**Step 3:** Review the output. You'll see results organized by CIS sections:

```
[INFO] 1 Control Plane Security Configuration
[INFO] 1.1 Control Plane Node Configuration Files
[PASS] 1.1.1 Ensure that the API server pod specification file permissions are set to 600 or more restrictive
[FAIL] 1.1.2 Ensure that the API server pod specification file ownership is set to root:root
...
== Summary master ==
42 checks PASS
12 checks FAIL
10 checks WARN
```

**Step 4:** Pick the **top 5 FAIL findings** from your output and remediate them. Common findings on a fresh kubeadm cluster include:

- File permissions on `/etc/kubernetes/manifests/*.yaml` being too permissive
- Missing `--audit-log-path` flag on the API server (you'll fix this in Task 6)
- Missing `--encryption-provider-config` (you'll fix this in Task 7)
- Insecure port or anonymous auth settings
- Missing admission controllers

For each finding, kube-bench provides a **Remediation** section — follow its instructions.

**Step 5:** Run kube-bench on the **worker** node too:

```bash
sudo ./kube-bench run --targets node
```

**Step 6:** Re-run kube-bench after your fixes to confirm improvement:

```bash
sudo ./kube-bench run --targets master 2>&1 | tail -5
```

> **Alternatively**, you can run kube-bench as a Kubernetes Job (useful when you can't SSH directly):
> ```bash
> kubectl apply -f https://raw.githubusercontent.com/aquasecurity/kube-bench/main/job.yaml
> kubectl wait --for=condition=complete job/kube-bench --timeout=300s
> kubectl logs job/kube-bench
> ```

### Task 2 — Ingress with TLS Using cert-manager

On Linux, you'd configure Nginx with Let's Encrypt using `certbot` to automatically obtain and renew TLS certificates. In Kubernetes, **cert-manager** automates certificate management. For this lab, we'll use a self-signed ClusterIssuer (production would use Let's Encrypt or an internal CA).

**Step 1:** Install cert-manager using its static manifests:

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

# Wait for cert-manager to be ready
kubectl wait --for=condition=available deployment/cert-manager -n cert-manager --timeout=120s
kubectl wait --for=condition=available deployment/cert-manager-webhook -n cert-manager --timeout=120s
```

**Step 2:** Create a self-signed ClusterIssuer. Save as `self-signed-issuer.yaml`:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
```

```bash
kubectl apply -f self-signed-issuer.yaml
kubectl get clusterissuer selfsigned-issuer
```

**Step 3:** Create a test application and Service. Save as `tls-demo-app.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tls-demo
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: tls-demo
  template:
    metadata:
      labels:
        app: tls-demo
    spec:
      containers:
        - name: web
          image: hashicorp/http-echo
          args:
            - "-text=Hello from TLS-secured app!"
          ports:
            - containerPort: 5678
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 64Mi
---
apiVersion: v1
kind: Service
metadata:
  name: tls-demo-svc
  namespace: default
spec:
  selector:
    app: tls-demo
  ports:
    - port: 80
      targetPort: 5678
```

```bash
kubectl apply -f tls-demo-app.yaml
```

**Step 4:** Create a Certificate resource that tells cert-manager to issue a self-signed certificate. Save as `tls-demo-cert.yaml`:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: tls-demo-cert
  namespace: default
spec:
  secretName: tls-demo-tls
  duration: 2160h    # 90 days
  renewBefore: 360h  # 15 days before expiry
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
  commonName: tls-demo.local
  dnsNames:
    - tls-demo.local
```

```bash
kubectl apply -f tls-demo-cert.yaml
```

**Step 5:** Verify the certificate was issued and the TLS Secret was created:

```bash
kubectl get certificate tls-demo-cert
kubectl describe certificate tls-demo-cert
kubectl get secret tls-demo-tls
```

The certificate status should show `Ready: True`.

**Step 6:** Create an Ingress that uses the TLS Secret. Save as `tls-demo-ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: tls-demo-ingress
  namespace: default
  annotations:
    cert-manager.io/cluster-issuer: selfsigned-issuer
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - tls-demo.local
      secretName: tls-demo-tls
  rules:
    - host: tls-demo.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: tls-demo-svc
                port:
                  number: 80
```

```bash
kubectl apply -f tls-demo-ingress.yaml
```

**Step 7:** Test TLS connectivity (the cert is self-signed, so use `-k` to skip verification):

```bash
# If you have an Ingress controller running:
curl -k -H "Host: tls-demo.local" https://localhost

# Or inspect the certificate details:
kubectl get secret tls-demo-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout
```

> **Alternative (manual TLS Secret):** If cert-manager is not available, you can create TLS Secrets manually:
> ```bash
> openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
>   -keyout tls.key -out tls.crt \
>   -subj "/CN=tls-demo.local"
> kubectl create secret tls tls-demo-tls --cert=tls.crt --key=tls.key
> ```

### Task 3 — Default-Deny Egress NetworkPolicy

In Challenge 9, you created NetworkPolicies for **ingress** filtering. Now you'll implement **egress** controls — the equivalent of outbound firewall rules. A default-deny egress policy prevents Pods from calling out to anything unless explicitly allowed — like setting the default `iptables OUTPUT` chain to `DROP`.

**Step 1:** Create a namespace for this exercise:

```bash
kubectl create namespace egress-lab
```

**Step 2:** Create a **default-deny egress** NetworkPolicy. Save as `default-deny-egress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: egress-lab
spec:
  podSelector: {}
  policyTypes:
    - Egress
```

This blocks **all** outbound traffic from every Pod in the namespace — including DNS lookups.

```bash
kubectl apply -f default-deny-egress.yaml
```

**Step 3:** Deploy a test Pod and confirm egress is blocked:

```bash
kubectl run test-pod --image=busybox --namespace=egress-lab --restart=Never -- sleep 3600
kubectl exec -n egress-lab test-pod -- wget -qO- --timeout=5 http://google.com 2>&1 || echo "Egress blocked as expected"
```

**Step 4:** Now create a policy that allows **only DNS egress** (port 53 to kube-dns) and egress to a specific Service. Save as `allow-dns-and-api.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-and-api
  namespace: egress-lab
spec:
  podSelector:
    matchLabels:
      role: api-consumer
  policyTypes:
    - Egress
  egress:
    # Allow DNS resolution
    - to:
        - namespaceSelector: {}
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    # Allow egress to Pods with label app=backend on port 8080
    - to:
        - podSelector:
            matchLabels:
              app: backend
      ports:
        - protocol: TCP
          port: 8080
```

```bash
kubectl apply -f allow-dns-and-api.yaml
```

**Step 5:** Test the policy — create a labeled Pod and verify DNS works but general internet is still blocked:

```bash
kubectl run labeled-pod --image=busybox --namespace=egress-lab --labels="role=api-consumer" --restart=Never -- sleep 3600

# DNS should work now
kubectl exec -n egress-lab labeled-pod -- nslookup kubernetes.default

# Internet should still be blocked
kubectl exec -n egress-lab labeled-pod -- wget -qO- --timeout=5 http://google.com 2>&1 || echo "Internet still blocked - correct!"
```

> **Note:** Egress NetworkPolicies require a CNI plugin that supports them (Calico, Cilium, Weave). The default `kubenet` does NOT enforce NetworkPolicies. If using kubeadm, ensure you installed Calico or Cilium.

### Task 4 — Verify Kubernetes Binary Checksums

On Linux, you'd run `sha256sum` after downloading a package to verify it hasn't been tampered with — like checking GPG signatures on an RPM or DEB. For Kubernetes binaries, the project publishes SHA256 checksums for every release.

**Step 1:** Find the versions of your kubectl and kubelet binaries:

```bash
kubectl version --client --output=yaml | grep gitVersion
kubelet --version
```

**Step 2:** Get the SHA256 checksum for your kubectl binary from the official release:

```bash
# Replace v1.32.0 with your actual version
KUBE_VERSION=$(kubectl version --client -o json | grep -oP '"gitVersion": "\K[^"]+')
echo "Verifying kubectl version: $KUBE_VERSION"

# Download the official checksum
curl -sLO "https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/amd64/kubectl.sha256"

# Calculate the local binary checksum and compare
echo "$(cat kubectl.sha256)  $(which kubectl)" | sha256sum --check
```

**Step 3:** Do the same for kubelet:

```bash
KUBELET_VERSION=$(kubelet --version | awk '{print $2}')
echo "Verifying kubelet version: $KUBELET_VERSION"

# Download the official checksum
curl -sLO "https://dl.k8s.io/release/${KUBELET_VERSION}/bin/linux/amd64/kubelet.sha256"

# Calculate and compare
echo "$(cat kubelet.sha256)  $(which kubelet)" | sha256sum --check
```

**Step 4:** For kubeadm:

```bash
KUBEADM_VERSION=$(kubeadm version -o short)
echo "Verifying kubeadm version: $KUBEADM_VERSION"

curl -sLO "https://dl.k8s.io/release/${KUBEADM_VERSION}/bin/linux/amd64/kubeadm.sha256"
echo "$(cat kubeadm.sha256)  $(which kubeadm)" | sha256sum --check
```

Each command should print `OK` if the binary matches. A mismatch means the binary was tampered with or corrupted.

> **Why this matters on the CKS exam:** An attacker who gains access to a node could replace kubectl or kubelet with a trojaned version. Verifying checksums is a foundational supply-chain security practice.

### Task 5 — ServiceAccount Hardening

On Linux, you disable root login in `sshd_config`, create service-specific users (`www-data`, `postgres`), and give each the minimum permissions needed. In Kubernetes, the equivalent is **ServiceAccount hardening**: disabling automatic token mounting, creating dedicated ServiceAccounts, and minimizing their RBAC permissions.

**Step 1:** See how the default ServiceAccount works — every Pod gets a token mounted automatically:

```bash
kubectl create namespace sa-lab

# Create a Pod without specifying a ServiceAccount
kubectl run default-sa-test --image=busybox --namespace=sa-lab --restart=Never -- sleep 3600

# Check the mounted token
kubectl exec -n sa-lab default-sa-test -- ls /var/run/secrets/kubernetes.io/serviceaccount/
kubectl exec -n sa-lab default-sa-test -- cat /var/run/secrets/kubernetes.io/serviceaccount/token
```

That token grants API access — any container compromise leaks it.

**Step 2:** Disable automounting on the **default** ServiceAccount. This is like setting `PermitRootLogin no` in `sshd_config`:

```bash
kubectl patch serviceaccount default -n sa-lab \
  -p '{"automountServiceAccountToken": false}'
```

**Step 3:** Verify the patch — new Pods using the default SA will no longer get tokens:

```bash
kubectl delete pod default-sa-test -n sa-lab
kubectl run no-token-test --image=busybox --namespace=sa-lab --restart=Never -- sleep 3600

# This should fail — no token mounted
kubectl exec -n sa-lab no-token-test -- ls /var/run/secrets/kubernetes.io/serviceaccount/ 2>&1 || echo "No token mounted - correct!"
```

**Step 4:** Create a **dedicated ServiceAccount** with minimal permissions for an application that only needs to read ConfigMaps. Save as `app-sa.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: configmap-reader
  namespace: sa-lab
automountServiceAccountToken: true
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: configmap-read-role
  namespace: sa-lab
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: configmap-read-binding
  namespace: sa-lab
subjects:
  - kind: ServiceAccount
    name: configmap-reader
    namespace: sa-lab
roleRef:
  kind: Role
  name: configmap-read-role
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f app-sa.yaml
```

**Step 5:** Deploy a Pod using the dedicated ServiceAccount and verify it can only do what it's allowed to:

```bash
kubectl create configmap test-config -n sa-lab --from-literal=key1=value1
```

```yaml
# Save as sa-test-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: sa-test
  namespace: sa-lab
spec:
  serviceAccountName: configmap-reader
  containers:
    - name: test
      image: bitnami/kubectl:latest
      command: ["sleep", "3600"]
      resources:
        requests:
          cpu: 50m
          memory: 32Mi
```

```bash
kubectl apply -f sa-test-pod.yaml
kubectl wait --for=condition=ready pod/sa-test -n sa-lab --timeout=60s

# This should work — reading configmaps is allowed
kubectl exec -n sa-lab sa-test -- kubectl get configmaps -n sa-lab

# This should fail — listing Secrets is NOT allowed
kubectl exec -n sa-lab sa-test -- kubectl get secrets -n sa-lab 2>&1 || echo "Access denied - correct!"

# This should fail — listing Pods is NOT allowed
kubectl exec -n sa-lab sa-test -- kubectl get pods -n sa-lab 2>&1 || echo "Access denied - correct!"
```

**Step 6:** Audit existing ClusterRoleBindings for overly broad access — look for bindings to `cluster-admin`:

```bash
# Find all ClusterRoleBindings that reference cluster-admin
kubectl get clusterrolebindings -o json | \
  jq -r '.items[] | select(.roleRef.name=="cluster-admin") | .metadata.name + " -> " + (.subjects[]? | .kind + "/" + .name)'
```

### Task 6 — Kubernetes Audit Logging

On Linux, `auditd` records system calls, file access, and user actions. Kubernetes audit logging does the same for the API server — recording who requested what, when, and the response. This is essential for incident response and compliance.

**Step 1:** Create an audit policy file on the **control-plane** node. Save as `/etc/kubernetes/audit-policy.yaml`:

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  # Don't log read-only requests to healthz, readyz, livez
  - level: None
    nonResourceURLs:
      - /healthz*
      - /readyz*
      - /livez*

  # Don't log events from the system:nodes group to avoid noise
  - level: None
    users:
      - "system:kube-proxy"
    verbs:
      - watch

  # Log Secret access at Metadata level (don't log the Secret values!)
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets"]

  # Log configmap and RBAC changes at RequestResponse level
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["configmaps"]
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
    verbs: ["create", "update", "patch", "delete"]

  # Log all Pod exec/attach at Request level
  - level: Request
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach"]

  # Catch-all — log everything else at Metadata level
  - level: Metadata
    omitStages:
      - RequestReceived
```

```bash
sudo cp audit-policy.yaml /etc/kubernetes/audit-policy.yaml
```

**Step 2:** Create the audit log directory:

```bash
sudo mkdir -p /var/log/kubernetes/audit
```

**Step 3:** Edit the API server static Pod manifest to enable audit logging. Edit `/etc/kubernetes/manifests/kube-apiserver.yaml` and add these flags to the `command` section:

```yaml
    - --audit-policy-file=/etc/kubernetes/audit-policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit/audit.log
    - --audit-log-maxage=30
    - --audit-log-maxbackup=10
    - --audit-log-maxsize=100
```

**Step 4:** Add volume mounts so the API server container can access the policy file and write logs:

```yaml
    volumeMounts:
    # ... existing mounts ...
    - mountPath: /etc/kubernetes/audit-policy.yaml
      name: audit-policy
      readOnly: true
    - mountPath: /var/log/kubernetes/audit
      name: audit-log
```

```yaml
  volumes:
  # ... existing volumes ...
  - name: audit-policy
    hostPath:
      path: /etc/kubernetes/audit-policy.yaml
      type: File
  - name: audit-log
    hostPath:
      path: /var/log/kubernetes/audit
      type: DirectoryOrCreate
```

**Step 5:** Save the file. The kubelet will detect the change and restart the API server Pod automatically. Wait for it to come back:

```bash
# Wait for API server to restart (may take 30-60 seconds)
kubectl wait --for=condition=ready pod -l component=kube-apiserver -n kube-system --timeout=120s
```

If kubectl stops responding, wait — the API server is restarting. Check with:

```bash
sudo crictl ps | grep kube-apiserver
```

**Step 6:** Generate some API activity and verify audit logs are being written:

```bash
kubectl create namespace audit-test
kubectl create secret generic test-secret -n audit-test --from-literal=password=supersecret
kubectl get secrets -n audit-test
kubectl delete namespace audit-test

# Check the audit log
sudo tail -20 /var/log/kubernetes/audit/audit.log | jq .
```

You should see JSON entries with `verb`, `user`, `resource`, `responseStatus`, and `requestReceivedTimestamp` fields.

### Task 7 — Secrets Encryption at Rest

By default, Kubernetes Secrets are stored **base64-encoded but not encrypted** in etcd — anyone with etcd access can read them. This is like storing passwords in plaintext on a Linux filesystem. **EncryptionConfiguration** encrypts Secrets before writing to etcd — the equivalent of LUKS/dm-crypt for disk encryption.

**Step 1:** Generate a 32-byte encryption key:

```bash
ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)
echo "Your encryption key: $ENCRYPTION_KEY"
```

> **Keep this key safe** — losing it means you cannot decrypt your Secrets.

**Step 2:** Create the EncryptionConfiguration file on the control-plane node. Save as `/etc/kubernetes/encryption-config.yaml`:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: <INSERT_YOUR_BASE64_KEY_HERE>
      - identity: {}
```

Replace `<INSERT_YOUR_BASE64_KEY_HERE>` with the key from Step 1.

```bash
# Create the file with the actual key substituted
cat <<EOF | sudo tee /etc/kubernetes/encryption-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${ENCRYPTION_KEY}
      - identity: {}
EOF

sudo chmod 600 /etc/kubernetes/encryption-config.yaml
```

> **Provider order matters:** The first provider (`aescbc`) is used for **encrypting** new Secrets. The `identity` fallback is used for **decrypting** existing unencrypted Secrets. Without `identity: {}`, pre-existing Secrets become unreadable.

**Step 3:** Edit the API server static Pod manifest `/etc/kubernetes/manifests/kube-apiserver.yaml` to add the encryption flag:

```yaml
    - --encryption-provider-config=/etc/kubernetes/encryption-config.yaml
```

Add the volume mount and volume:

```yaml
    volumeMounts:
    # ... existing mounts ...
    - mountPath: /etc/kubernetes/encryption-config.yaml
      name: encryption-config
      readOnly: true
```

```yaml
  volumes:
  # ... existing volumes ...
  - name: encryption-config
    hostPath:
      path: /etc/kubernetes/encryption-config.yaml
      type: File
```

**Step 4:** Wait for the API server to restart:

```bash
kubectl wait --for=condition=ready pod -l component=kube-apiserver -n kube-system --timeout=120s
```

**Step 5:** Create a new Secret and verify it's encrypted in etcd:

```bash
kubectl create namespace encryption-test
kubectl create secret generic encrypted-secret -n encryption-test --from-literal=mykey=mydata
```

**Step 6:** Read the Secret directly from etcd to confirm encryption:

```bash
# On the control-plane node, read the raw etcd data
sudo ETCDCTL_API=3 etcdctl get /registry/secrets/encryption-test/encrypted-secret \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  | hexdump -C | head -20
```

You should see `k8s:enc:aescbc:v1:key1:` prefix followed by encrypted data — NOT plaintext.

**Step 7:** Re-encrypt all existing Secrets (those created before encryption was enabled):

```bash
kubectl get secrets --all-namespaces -o json | kubectl replace -f -
```

This reads each Secret (decrypting it) and writes it back (encrypting it with the new provider).

### Task 8 — Block Cloud Metadata Endpoint with NetworkPolicy

Cloud providers expose instance metadata at `169.254.169.254`. If an attacker compromises a Pod, they can hit this endpoint to steal IAM credentials, instance identity tokens, and other sensitive data. On Linux, you'd block it with `iptables -A OUTPUT -d 169.254.169.254 -j DROP`. In Kubernetes, you use a **NetworkPolicy**.

**Step 1:** Create a namespace and default-deny egress policy that also blocks the metadata endpoint. Save as `block-metadata.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-cloud-metadata
  namespace: egress-lab
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    # Allow all egress EXCEPT to the metadata endpoint
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 169.254.169.254/32
```

```bash
kubectl apply -f block-metadata.yaml
```

> **Note:** This policy replaces the default-deny from Task 3 for this namespace. It allows all egress **except** to the metadata IP — a common pattern in cloud environments.

**Step 2:** Test the policy:

```bash
# This should be blocked (connection timeout)
kubectl exec -n egress-lab test-pod -- wget -qO- --timeout=5 http://169.254.169.254/ 2>&1 || echo "Metadata blocked - correct!"

# General egress should still work (if DNS is available)
kubectl exec -n egress-lab test-pod -- wget -qO- --timeout=5 http://kubernetes.default.svc.cluster.local/healthz 2>&1 || echo "Cluster egress works"
```

**Step 3:** For extra security, combine metadata blocking with the restrictive egress policy from Task 3 by adding the `except` clause to specific egress rules.

### Clean Up

```bash
kubectl delete namespace egress-lab 2>/dev/null
kubectl delete namespace sa-lab 2>/dev/null
kubectl delete namespace encryption-test 2>/dev/null
kubectl delete -f tls-demo-app.yaml 2>/dev/null
kubectl delete -f tls-demo-ingress.yaml 2>/dev/null
kubectl delete -f tls-demo-cert.yaml 2>/dev/null
kubectl delete -f self-signed-issuer.yaml 2>/dev/null
kubectl delete job kube-bench 2>/dev/null
```

## Success Criteria

- [ ] You ran kube-bench on both control-plane and worker nodes, identified FAIL findings, and remediated at least 5.
- [ ] Re-running kube-bench shows fewer FAILs than the initial run.
- [ ] You installed cert-manager, created a self-signed ClusterIssuer, and issued a TLS certificate.
- [ ] The TLS Secret (`tls-demo-tls`) contains valid certificate and key data.
- [ ] An Ingress resource references the TLS Secret and terminates TLS.
- [ ] You created a default-deny egress NetworkPolicy and verified Pods cannot reach the internet.
- [ ] You created a selective egress policy allowing only DNS and specific backends.
- [ ] You verified SHA256 checksums of kubectl, kubelet, and kubeadm against official release checksums.
- [ ] You disabled automountServiceAccountToken on the default SA and confirmed Pods no longer get tokens.
- [ ] You created a dedicated ServiceAccount with a Role limited to reading ConfigMaps and proved it cannot access Secrets or Pods.
- [ ] You can identify overprivileged ClusterRoleBindings (e.g., bindings to `cluster-admin`).
- [ ] Kubernetes audit logging is enabled — you can see JSON audit events in `/var/log/kubernetes/audit/audit.log`.
- [ ] The audit policy uses appropriate levels (None for health checks, Metadata for Secrets, RequestResponse for RBAC changes).
- [ ] Secrets encryption at rest is configured with `aescbc` provider.
- [ ] Raw etcd reads show the `k8s:enc:aescbc:v1:key1:` prefix, confirming encryption.
- [ ] You re-encrypted all existing Secrets with `kubectl get secrets --all-namespaces -o json | kubectl replace -f -`.
- [ ] A NetworkPolicy blocks egress to `169.254.169.254/32` (cloud metadata endpoint).

## Linux ↔ Kubernetes Reference

| Linux Concept | Kubernetes Equivalent | Notes |
|---|---|---|
| `lynis audit system` / OpenSCAP | `kube-bench run --targets master` | CIS benchmark audit for K8s nodes |
| Nginx + `certbot` + Let's Encrypt | cert-manager + ClusterIssuer + Certificate CRD | Automated TLS lifecycle management |
| `openssl req -x509 -newkey` (self-signed) | `kubectl create secret tls` (manual) or cert-manager self-signed issuer | Manual vs. automated TLS |
| `iptables -P OUTPUT DROP` | NetworkPolicy with `policyTypes: [Egress]` and empty `egress` | Default-deny outbound |
| `iptables -A OUTPUT -d X -j ACCEPT` | NetworkPolicy `egress` rule with `to` and `ports` | Whitelist-specific egress |
| `iptables -A OUTPUT -d 169.254.169.254 -j DROP` | NetworkPolicy with `ipBlock.except: [169.254.169.254/32]` | Block cloud metadata |
| `sha256sum --check file.sha256` | `sha256sum --check` on kubectl/kubelet/kubeadm binaries | Supply-chain verification |
| `/etc/ssh/sshd_config: PermitRootLogin no` | `automountServiceAccountToken: false` on default SA | Disable default credentials |
| Create `www-data`, `postgres` users with limited perms | Dedicated ServiceAccount + Role + RoleBinding | Least privilege per workload |
| `visudo` — audit sudoers | `kubectl get clusterrolebindings` — audit cluster-admin bindings | Privilege audit |
| `/etc/audit/auditd.conf` + audit rules | `--audit-policy-file` + `--audit-log-path` on API server | Who did what, when |
| `auditctl -w /etc/shadow -p rwa` | Audit policy rule: `level: Metadata` for Secrets | Monitor sensitive resource access |
| LUKS / dm-crypt disk encryption | EncryptionConfiguration with `aescbc` provider | Secrets encrypted before writing to etcd |
| `cryptsetup luksFormat /dev/sda1` | `--encryption-provider-config` on API server | Enable encryption at rest |

## Hints

<details>
<summary>Hint 1: kube-bench fails to run or shows "unable to determine benchmark version"</summary>

kube-bench auto-detects your Kubernetes version and maps it to a CIS benchmark version. If detection fails:

```bash
# Specify the benchmark manually
sudo ./kube-bench run --targets master --benchmark cis-2.0
```

If running as a Job and Pods can't mount host paths, use the container approach:

```bash
# Run on the node directly
sudo docker run --rm --pid=host \
  -v /etc:/etc:ro -v /var:/var:ro \
  aquasec/kube-bench:latest run --targets master
```

</details>

<details>
<summary>Hint 2: cert-manager Certificate stays "Not Ready"</summary>

Check the cert-manager logs for errors:

```bash
kubectl logs -n cert-manager -l app.kubernetes.io/name=cert-manager
kubectl describe certificate tls-demo-cert
kubectl get certificaterequests -o wide
```

Common issues:
- The ClusterIssuer name in the Certificate doesn't match: `issuerRef.name` must be exactly `selfsigned-issuer`
- cert-manager webhook isn't ready yet — wait a minute and retry
- CRDs aren't installed — check `kubectl get crds | grep cert-manager`

</details>

<details>
<summary>Hint 3: Default-deny egress blocks DNS too</summary>

When you apply a default-deny egress policy, it blocks **everything** — including DNS (port 53). Pods will fail to resolve any hostname.

To allow DNS while still blocking other egress:

```yaml
egress:
  - to:
      - namespaceSelector: {}
    ports:
      - protocol: UDP
        port: 53
      - protocol: TCP
        port: 53
```

This allows DNS to kube-dns in any namespace. Without this, even `nslookup` inside the Pod will timeout.

</details>

<details>
<summary>Hint 4: API server won't start after editing the static Pod manifest</summary>

Common causes:
- **YAML syntax error** — Validate with `python3 -c "import yaml; yaml.safe_load(open('/etc/kubernetes/manifests/kube-apiserver.yaml'))"`
- **Wrong volume mount path** — The `mountPath` must match exactly what the flag references
- **File doesn't exist** — Ensure the audit policy or encryption config file actually exists at the hostPath
- **File permissions** — The file must be readable by the apiserver process

Check the kubelet logs for error details:

```bash
sudo journalctl -u kubelet --since "5 minutes ago" | grep -i apiserver
sudo crictl ps -a | grep kube-apiserver
sudo crictl logs <container-id>
```

**Emergency recovery:** If the API server is stuck, revert your changes to the static Pod manifest:

```bash
sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml
```

Always make a backup **before** editing: `sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml{,.bak}`

</details>

<details>
<summary>Hint 5: etcdctl not found or "permission denied"</summary>

On kubeadm clusters, etcdctl may not be installed on the host. Use the etcd Pod:

```bash
kubectl exec -n kube-system etcd-<node-name> -- etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/encryption-test/encrypted-secret | hexdump -C | head
```

Or install etcdctl on the host:

```bash
sudo apt-get install -y etcd-client
```

</details>

<details>
<summary>Hint 6: ServiceAccount token still mounted after disabling automount</summary>

The `automountServiceAccountToken: false` setting on a ServiceAccount only affects **newly created** Pods. Existing Pods keep their tokens until they're recreated.

Also note the override precedence:
1. Pod-level `automountServiceAccountToken` overrides the ServiceAccount setting
2. If the Pod spec explicitly sets `automountServiceAccountToken: true`, it mounts regardless of the SA setting

Check both levels:

```bash
kubectl get sa default -n sa-lab -o yaml | grep automount
kubectl get pod <name> -n sa-lab -o yaml | grep automount
```

</details>

<details>
<summary>Hint 7: Encryption key format issues</summary>

The encryption key must be exactly 32 bytes, base64-encoded. Common mistakes:

```bash
# WRONG — this generates a random string, not 32 raw bytes
echo "mysecretkey" | base64

# CORRECT — 32 random bytes, then base64-encoded
head -c 32 /dev/urandom | base64
```

If the API server fails to start after adding encryption config, check logs:

```bash
sudo journalctl -u kubelet --since "2 minutes ago" | grep -i encrypt
```

Look for "invalid key length" or "failed to parse encryption config" messages.

</details>

<details>
<summary>Hint 8: NetworkPolicy doesn't seem to block metadata endpoint</summary>

NetworkPolicies require a CNI plugin that enforces them. Check your CNI:

```bash
kubectl get pods -n kube-system | grep -E "calico|cilium|weave"
```

If you're using `flannel` or default `kubenet`, NetworkPolicies are accepted by the API but **not enforced**. Install Calico:

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.0/manifests/calico.yaml
```

Also, test from a Pod **inside** the cluster, not from the node itself. The NetworkPolicy only affects Pod traffic.

</details>

## Learning Resources

- [CIS Kubernetes Benchmark (kube-bench)](https://github.com/aquasecurity/kube-bench)
- [Kubernetes — Encrypting Confidential Data at Rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)
- [Kubernetes — Auditing](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/)
- [Kubernetes — Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [cert-manager Documentation](https://cert-manager.io/docs/)
- [Kubernetes — RBAC Authorization](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
- [Kubernetes — Configure Service Accounts for Pods](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/)
- [Kubernetes — Verify Signed Kubernetes Artifacts](https://kubernetes.io/docs/tasks/administer-cluster/verify-signed-artifacts/)
- [CKS Curriculum](https://github.com/cncf/curriculum)
- [Kubernetes — Restrict Access to Kubernetes API](https://kubernetes.io/docs/concepts/security/controlling-access/)

## Break & Fix 🔧

Try each scenario, diagnose the problem, and fix it.

### Scenario 1 — Audit logs are empty after enabling audit logging

Apply these API server changes (on the control-plane node, edit `/etc/kubernetes/manifests/kube-apiserver.yaml`):

```yaml
    - --audit-policy-file=/etc/kubernetes/audit-policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit/audit.log
```

But "forget" to add the volume mounts:

```bash
# After API server restarts, check logs
sudo tail /var/log/kubernetes/audit/audit.log
```

**What you'll see:** The API server Pod keeps restarting (CrashLoopBackOff) or the audit log file doesn't exist.

**Diagnose:**

```bash
sudo crictl ps -a | grep kube-apiserver
sudo crictl logs <container-id> 2>&1 | grep audit
sudo journalctl -u kubelet --since "5 minutes ago" | grep -i error
```

**Root cause:** The API server container can't access `/etc/kubernetes/audit-policy.yaml` or write to `/var/log/kubernetes/audit/` because the **volume and volumeMount** entries are missing. The container has its own filesystem — it only sees host paths that are explicitly mounted.

**Fix:** Add the volumes and volumeMounts as shown in Task 6, Steps 3–4.

**Linux analogy:** Like configuring `auditd` to write to `/var/log/audit/audit.log` but forgetting to create the directory or set permissions — auditd won't start.

---

### Scenario 2 — New Secrets are not encrypted despite EncryptionConfiguration

The encryption config exists and is referenced by the API server, but new Secrets still appear as plaintext in etcd:

```yaml
# /etc/kubernetes/encryption-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - identity: {}
      - aescbc:
          keys:
            - name: key1
              secret: dGhpcyBpcyBhIHRlc3Qga2V5MTIzNDU2Nzg5MDEyMzQ=
```

```bash
kubectl create secret generic broken-secret -n default --from-literal=data=sensitive
sudo ETCDCTL_API=3 etcdctl get /registry/secrets/default/broken-secret \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
```

**What you'll see:** The raw etcd data shows plaintext — no `k8s:enc:aescbc:` prefix.

**Diagnose:** Look at the provider order in the EncryptionConfiguration.

**Root cause:** The `identity: {}` provider is listed **first**. Kubernetes uses the **first provider** for encryption. Since `identity` means "no encryption", Secrets are stored in plaintext. The `aescbc` provider is only used for decryption fallback.

**Fix:** Swap the provider order — `aescbc` must come first:

```yaml
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: dGhpcyBpcyBhIHRlc3Qga2V5MTIzNDU2Nzg5MDEyMzQ=
      - identity: {}
```

Restart the API server and re-create the Secret. Then re-encrypt existing Secrets:

```bash
kubectl get secrets --all-namespaces -o json | kubectl replace -f -
```

**Linux analogy:** Like configuring dm-crypt but mounting the unencrypted partition first in `/etc/fstab` — the encrypted partition exists but is never used.

---

### Scenario 3 — Pod can still reach the metadata endpoint despite NetworkPolicy

Apply this NetworkPolicy:

```yaml
# Save as broken-metadata-policy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: block-metadata-broken
  namespace: egress-lab
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 169.254.169.254/32
```

```bash
kubectl apply -f broken-metadata-policy.yaml
kubectl exec -n egress-lab test-pod -- wget -qO- --timeout=5 http://169.254.169.254/latest/meta-data/ 2>&1
```

**What you'll see:** The metadata endpoint is still reachable.

**Diagnose:**

```bash
kubectl get networkpolicy block-metadata-broken -n egress-lab -o yaml
```

**Root cause:** The policy restricts **Ingress** (incoming traffic), not **Egress** (outgoing traffic). The metadata endpoint is an **outbound** call from the Pod. Ingress policies control who can talk **to** the Pod, not where the Pod can call.

**Fix:** Change `policyTypes` to `Egress` and use `egress` rules instead of `ingress`:

```yaml
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 169.254.169.254/32
```

**Linux analogy:** Like adding a rule to the iptables `INPUT` chain when you meant to add it to `OUTPUT` — blocking incoming connections from the metadata IP doesn't stop your server from reaching out to it.

---

### Scenario 4 — ServiceAccount token still mounted despite `automountServiceAccountToken: false`

Apply this Pod:

```yaml
# Save as broken-sa-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: broken-sa-pod
  namespace: sa-lab
spec:
  serviceAccountName: configmap-reader
  automountServiceAccountToken: true
  containers:
    - name: test
      image: busybox
      command: ["sleep", "3600"]
      resources:
        requests:
          cpu: 50m
          memory: 32Mi
```

Even though the ServiceAccount has `automountServiceAccountToken: false`, check the Pod:

```bash
kubectl apply -f broken-sa-pod.yaml
kubectl exec -n sa-lab broken-sa-pod -- ls /var/run/secrets/kubernetes.io/serviceaccount/
```

**What you'll see:** The token is mounted!

**Root cause:** The Pod spec has `automountServiceAccountToken: true`, which **overrides** the ServiceAccount setting. Pod-level settings always win.

**Fix:** Remove the Pod-level override or set it to `false`:

```bash
kubectl delete pod broken-sa-pod -n sa-lab
# Edit the YAML to remove automountServiceAccountToken: true, then re-apply
```

**Linux analogy:** Like setting `PermitRootLogin no` in `sshd_config` but then adding `Match User root` with `PermitRootLogin yes` — the specific override wins.
