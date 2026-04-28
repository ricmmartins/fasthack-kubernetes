# Solution 19 — Cluster Security & Hardening

[< Previous Solution](Solution-18.md) - **[Home](README.md)** - [Next Solution >](Solution-20.md)

---

> **Coach note:** This is a CKS-focused challenge covering cluster setup security, cluster hardening, audit logging, and encryption at rest. Tasks 1, 6, and 7 **require** kubeadm cluster access (SSH to control-plane node, edit static Pod manifests). Tasks 2–5, 8 can be adapted for Kind with limitations. Budget extra time for Tasks 6 and 7 — editing API server manifests is error-prone and students may need recovery help.

Estimated time: **90–120 minutes**

---

## Task 1: CIS Kubernetes Benchmark with kube-bench

### Step-by-step

**SSH into the control-plane node:**

```bash
ssh user@control-plane-ip
```

**Download kube-bench:**

```bash
curl -L https://github.com/aquasecurity/kube-bench/releases/latest/download/kube-bench_0.10.7_linux_amd64.tar.gz -o kube-bench.tar.gz
tar xzf kube-bench.tar.gz
```

**Run against the control-plane:**

```bash
sudo ./kube-bench run --targets master
```

### Expected output (abbreviated)

```
[INFO] 1 Control Plane Security Configuration
[INFO] 1.1 Control Plane Node Configuration Files
[PASS] 1.1.1 Ensure that the API server pod specification file permissions are set to 600 or more restrictive
[PASS] 1.1.2 Ensure that the API server pod specification file ownership is set to root:root
...
[FAIL] 1.2.15 Ensure that the admission control plugin NamespaceLifecycle is set
[FAIL] 1.2.17 Ensure that the --audit-log-path argument is set
[FAIL] 1.2.18 Ensure that the --audit-log-maxage argument is set
...
== Summary master ==
42 checks PASS
12 checks FAIL
10 checks WARN
0 checks INFO
```

### Common remediations

**Fix 1 — File permissions too permissive:**

```bash
sudo chmod 600 /etc/kubernetes/manifests/kube-apiserver.yaml
sudo chmod 600 /etc/kubernetes/manifests/kube-controller-manager.yaml
sudo chmod 600 /etc/kubernetes/manifests/kube-scheduler.yaml
sudo chmod 600 /etc/kubernetes/manifests/etcd.yaml
sudo chmod 600 /etc/kubernetes/admin.conf
```

**Fix 2 — Audit logging not configured (1.2.17–1.2.20):**

This will be fully addressed in Task 6. For now, note that the fix requires:
- `--audit-log-path`
- `--audit-log-maxage`
- `--audit-log-maxbackup`
- `--audit-log-maxsize`

**Fix 3 — Encryption provider not configured (1.2.29):**

This will be addressed in Task 7. Requires `--encryption-provider-config`.

**Fix 4 — Admission controllers:**

If kube-bench reports missing admission controllers, edit `/etc/kubernetes/manifests/kube-apiserver.yaml` and ensure the `--enable-admission-plugins` flag includes required plugins:

```bash
# Check current admission plugins
sudo grep admission /etc/kubernetes/manifests/kube-apiserver.yaml
```

Standard recommended set:

```yaml
    - --enable-admission-plugins=NodeRestriction,NamespaceLifecycle,LimitRanger,ServiceAccount,DefaultStorageClass,ResourceQuota
```

**Fix 5 — kubelet anonymous auth (4.2.1):**

Check kubelet config:

```bash
sudo cat /var/lib/kubelet/config.yaml | grep -A2 authentication
```

Ensure:

```yaml
authentication:
  anonymous:
    enabled: false
```

If it's `true`, edit the file and restart kubelet:

```bash
sudo systemctl restart kubelet
```

### Run on worker node

```bash
ssh user@worker-node-ip
sudo ./kube-bench run --targets node
```

### Re-run after fixes

```bash
sudo ./kube-bench run --targets master 2>&1 | tail -10
```

Expected: fewer FAILs than the initial run.

> **Coach tip:** Don't let students spend too long chasing every FAIL. The goal is to understand the process — audit, identify, remediate, verify. 5 fixes is sufficient. Tasks 6 and 7 will fix additional findings automatically.

### Alternative — Run as Job

```bash
kubectl apply -f https://raw.githubusercontent.com/aquasecurity/kube-bench/main/job.yaml
kubectl wait --for=condition=complete job/kube-bench --timeout=300s
kubectl logs job/kube-bench
```

> **Coach tip:** The Job approach may not detect all findings because it can't access all host-level paths. Running directly on the node is more thorough.

---

## Task 2: Ingress with TLS Using cert-manager

### Step-by-step

**Install cert-manager:**

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
```

Wait for all components:

```bash
kubectl wait --for=condition=available deployment/cert-manager -n cert-manager --timeout=120s
kubectl wait --for=condition=available deployment/cert-manager-webhook -n cert-manager --timeout=120s
kubectl wait --for=condition=available deployment/cert-manager-cainjector -n cert-manager --timeout=120s
```

Expected:

```
deployment.apps/cert-manager condition met
deployment.apps/cert-manager-webhook condition met
deployment.apps/cert-manager-cainjector condition met
```

**Create ClusterIssuer:**

Save `self-signed-issuer.yaml`:

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
```

### Verification — ClusterIssuer ready

```bash
kubectl get clusterissuer selfsigned-issuer
```

Expected:

```
NAME                READY   AGE
selfsigned-issuer   True    10s
```

**Create test app:**

Save `tls-demo-app.yaml`:

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

**Create Certificate:**

Save `tls-demo-cert.yaml`:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: tls-demo-cert
  namespace: default
spec:
  secretName: tls-demo-tls
  duration: 2160h
  renewBefore: 360h
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

### Verification — Certificate issued

```bash
kubectl get certificate tls-demo-cert
```

Expected:

```
NAME            READY   SECRET         AGE
tls-demo-cert   True    tls-demo-tls   30s
```

```bash
kubectl get secret tls-demo-tls
```

Expected:

```
NAME           TYPE                DATA   AGE
tls-demo-tls   kubernetes.io/tls   3      30s
```

**Inspect the certificate:**

```bash
kubectl get secret tls-demo-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout | head -20
```

Expected output includes:

```
        Issuer: CN = tls-demo.local
        Subject: CN = tls-demo.local
        ...
        X509v3 Subject Alternative Name:
            DNS:tls-demo.local
```

**Create Ingress:**

Save `tls-demo-ingress.yaml`:

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

### Verification — Ingress with TLS

```bash
kubectl get ingress tls-demo-ingress
kubectl describe ingress tls-demo-ingress
```

The `TLS` section should show the host and secret name.

**Test (if Ingress Controller is running):**

```bash
curl -k -H "Host: tls-demo.local" https://localhost
```

Expected: `Hello from TLS-secured app!`

> **Coach tip:** If no Ingress Controller is installed, the key learning is the Certificate → Secret → Ingress TLS pipeline. The actual HTTPS test is a bonus. Students should verify the Secret was created with valid TLS data.

### Alternative — Manual TLS Secret

If cert-manager installation stalls:

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key -out tls.crt \
  -subj "/CN=tls-demo.local"
kubectl create secret tls tls-demo-tls --cert=tls.crt --key=tls.key
```

---

## Task 3: Default-Deny Egress NetworkPolicy

### Step-by-step

```bash
kubectl create namespace egress-lab
```

**Apply default-deny egress:**

Save `default-deny-egress.yaml`:

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

```bash
kubectl apply -f default-deny-egress.yaml
```

### Verification — All egress blocked

```bash
kubectl run test-pod --image=busybox --namespace=egress-lab --restart=Never -- sleep 3600
kubectl wait --for=condition=ready pod/test-pod -n egress-lab --timeout=60s
```

```bash
kubectl exec -n egress-lab test-pod -- wget -qO- --timeout=5 http://google.com 2>&1
```

Expected: `wget: bad address 'google.com'` or timeout — DNS resolution fails because all egress (including port 53) is blocked.

```bash
kubectl exec -n egress-lab test-pod -- nslookup kubernetes.default 2>&1
```

Expected: timeout or `nslookup: write to '10.96.0.10': Operation not permitted`

**Apply selective egress:**

Save `allow-dns-and-api.yaml`:

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
    - to:
        - namespaceSelector: {}
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
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

### Verification — Selective egress

```bash
kubectl run labeled-pod --image=busybox --namespace=egress-lab --labels="role=api-consumer" --restart=Never -- sleep 3600
kubectl wait --for=condition=ready pod/labeled-pod -n egress-lab --timeout=60s
```

DNS should work:

```bash
kubectl exec -n egress-lab labeled-pod -- nslookup kubernetes.default
```

Expected:

```
Server:    10.96.0.10
Address 1: 10.96.0.10 kube-dns.kube-system.svc.cluster.local

Name:      kubernetes.default
Address 1: 10.96.0.1 kubernetes.default.svc.cluster.local
```

Internet still blocked:

```bash
kubectl exec -n egress-lab labeled-pod -- wget -qO- --timeout=5 http://google.com 2>&1
```

Expected: timeout (DNS resolves, but the egress policy doesn't allow HTTP to external IPs).

> **Coach tip:** Students often forget that default-deny blocks DNS too. This is the #1 source of confusion. Emphasize that DNS must be explicitly allowed in egress rules. The unlabeled `test-pod` still has no egress at all — only Pods matching `role: api-consumer` get the DNS exemption.

---

## Task 4: Verify Kubernetes Binary Checksums

### Step-by-step

**Get versions:**

```bash
kubectl version --client --output=yaml | grep gitVersion
kubelet --version
kubeadm version -o short
```

Example output:

```
  gitVersion: v1.32.0
Kubernetes v1.32.0
v1.32.0
```

**Verify kubectl:**

```bash
KUBE_VERSION=$(kubectl version --client -o json | grep -oP '"gitVersion": "\K[^"]+')
echo "Verifying kubectl ${KUBE_VERSION}"

curl -sLO "https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/amd64/kubectl.sha256"
echo "$(cat kubectl.sha256)  $(which kubectl)" | sha256sum --check
```

Expected:

```
/usr/local/bin/kubectl: OK
```

**Verify kubelet:**

```bash
KUBELET_VERSION=$(kubelet --version | awk '{print $2}')
echo "Verifying kubelet ${KUBELET_VERSION}"

curl -sLO "https://dl.k8s.io/release/${KUBELET_VERSION}/bin/linux/amd64/kubelet.sha256"
echo "$(cat kubelet.sha256)  $(which kubelet)" | sha256sum --check
```

Expected:

```
/usr/bin/kubelet: OK
```

**Verify kubeadm:**

```bash
KUBEADM_VERSION=$(kubeadm version -o short)
echo "Verifying kubeadm ${KUBEADM_VERSION}"

curl -sLO "https://dl.k8s.io/release/${KUBEADM_VERSION}/bin/linux/amd64/kubeadm.sha256"
echo "$(cat kubeadm.sha256)  $(which kubeadm)" | sha256sum --check
```

Expected:

```
/usr/bin/kubeadm: OK
```

> **Coach tip:** If a student's checksum doesn't match, it could mean: (1) they installed from a different source (package manager vs. direct download — binary path may differ), (2) the binary was compiled locally, or (3) the download was corrupted. On kubeadm clusters installed via apt, the binaries should match the upstream checksums.

> **Note on SHA512 vs SHA256:** The CKS exam references SHA512 checksums. The Kubernetes release artifacts publish `.sha256` files. Both verify integrity — SHA256 is the standard for K8s releases. If the student wants SHA512 specifically:
> ```bash
> sha512sum $(which kubectl)
> ```
> Then manually compare against the Kubernetes GitHub release page checksums.

---

## Task 5: ServiceAccount Hardening

### Step-by-step

```bash
kubectl create namespace sa-lab
```

**Show default token mounting:**

```bash
kubectl run default-sa-test --image=busybox --namespace=sa-lab --restart=Never -- sleep 3600
kubectl wait --for=condition=ready pod/default-sa-test -n sa-lab --timeout=60s
```

```bash
kubectl exec -n sa-lab default-sa-test -- ls /var/run/secrets/kubernetes.io/serviceaccount/
```

Expected:

```
ca.crt
namespace
token
```

The token file contains a JWT that can authenticate to the API server:

```bash
kubectl exec -n sa-lab default-sa-test -- cat /var/run/secrets/kubernetes.io/serviceaccount/token
```

**Disable automount on default SA:**

```bash
kubectl patch serviceaccount default -n sa-lab \
  -p '{"automountServiceAccountToken": false}'
```

### Verification — No token on new Pods

```bash
kubectl delete pod default-sa-test -n sa-lab
kubectl run no-token-test --image=busybox --namespace=sa-lab --restart=Never -- sleep 3600
kubectl wait --for=condition=ready pod/no-token-test -n sa-lab --timeout=60s
```

```bash
kubectl exec -n sa-lab no-token-test -- ls /var/run/secrets/kubernetes.io/serviceaccount/ 2>&1
```

Expected:

```
ls: /var/run/secrets/kubernetes.io/serviceaccount/: No such file or directory
```

**Create dedicated ServiceAccount:**

Save `app-sa.yaml`:

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
kubectl create configmap test-config -n sa-lab --from-literal=key1=value1
```

**Test dedicated SA:**

Save `sa-test-pod.yaml`:

```yaml
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
kubectl wait --for=condition=ready pod/sa-test -n sa-lab --timeout=120s
```

### Verification — Least privilege

ConfigMaps allowed:

```bash
kubectl exec -n sa-lab sa-test -- kubectl get configmaps -n sa-lab
```

Expected:

```
NAME               DATA   AGE
kube-root-ca.crt   1      5m
test-config        1      2m
```

Secrets denied:

```bash
kubectl exec -n sa-lab sa-test -- kubectl get secrets -n sa-lab 2>&1
```

Expected:

```
Error from server (Forbidden): secrets is forbidden: User "system:serviceaccount:sa-lab:configmap-reader" cannot list resource "secrets" in API group "" in the namespace "sa-lab"
```

Pods denied:

```bash
kubectl exec -n sa-lab sa-test -- kubectl get pods -n sa-lab 2>&1
```

Expected:

```
Error from server (Forbidden): pods is forbidden: User "system:serviceaccount:sa-lab:configmap-reader" cannot list resource "pods" in API group "" in the namespace "sa-lab"
```

**Audit cluster-admin bindings:**

```bash
kubectl get clusterrolebindings -o json | \
  jq -r '.items[] | select(.roleRef.name=="cluster-admin") | .metadata.name + " -> " + (.subjects[]? | .kind + "/" + .name)'
```

Expected output (will vary by cluster):

```
cluster-admin -> User/kubernetes-admin
kubeadm:cluster-admins -> Group/kubeadm:cluster-admins
```

> **Coach tip:** Students should understand that every `cluster-admin` binding is a potential security risk. In production, minimize these. The kubeadm bootstrap bindings are expected — look for any unexpected ServiceAccounts or Users with cluster-admin access.

---

## Task 6: Kubernetes Audit Logging

### Step-by-step

> **Important:** Always backup the API server manifest before editing!
> ```bash
> sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/manifests/kube-apiserver.yaml.bak
> ```

**Create audit policy:**

Save as `/etc/kubernetes/audit-policy.yaml`:

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  - level: None
    nonResourceURLs:
      - /healthz*
      - /readyz*
      - /livez*

  - level: None
    users:
      - "system:kube-proxy"
    verbs:
      - watch

  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets"]

  - level: RequestResponse
    resources:
      - group: ""
        resources: ["configmaps"]
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
    verbs: ["create", "update", "patch", "delete"]

  - level: Request
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach"]

  - level: Metadata
    omitStages:
      - RequestReceived
```

```bash
sudo tee /etc/kubernetes/audit-policy.yaml <<'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  - level: None
    nonResourceURLs:
      - /healthz*
      - /readyz*
      - /livez*
  - level: None
    users:
      - "system:kube-proxy"
    verbs:
      - watch
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets"]
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["configmaps"]
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
    verbs: ["create", "update", "patch", "delete"]
  - level: Request
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach"]
  - level: Metadata
    omitStages:
      - RequestReceived
EOF
```

**Create log directory:**

```bash
sudo mkdir -p /var/log/kubernetes/audit
```

**Edit kube-apiserver.yaml:**

```bash
sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
```

Add to `spec.containers[0].command`:

```yaml
    - --audit-policy-file=/etc/kubernetes/audit-policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit/audit.log
    - --audit-log-maxage=30
    - --audit-log-maxbackup=10
    - --audit-log-maxsize=100
```

Add to `spec.containers[0].volumeMounts`:

```yaml
    - mountPath: /etc/kubernetes/audit-policy.yaml
      name: audit-policy
      readOnly: true
    - mountPath: /var/log/kubernetes/audit
      name: audit-log
```

Add to `spec.volumes`:

```yaml
  - name: audit-policy
    hostPath:
      path: /etc/kubernetes/audit-policy.yaml
      type: File
  - name: audit-log
    hostPath:
      path: /var/log/kubernetes/audit
      type: DirectoryOrCreate
```

### Verification — API server restarts

```bash
# Wait for API server to come back (may take up to 60 seconds)
sleep 30
kubectl get nodes
```

If `kubectl` hangs, check with:

```bash
sudo crictl ps | grep kube-apiserver
```

Expected: a running kube-apiserver container with a recent start time.

### Verification — Audit logs are generated

Generate some activity:

```bash
kubectl create namespace audit-test
kubectl create secret generic test-secret -n audit-test --from-literal=password=supersecret
kubectl get secrets -n audit-test
kubectl delete namespace audit-test
```

Check audit logs:

```bash
sudo tail -5 /var/log/kubernetes/audit/audit.log | jq .
```

Expected: JSON entries like:

```json
{
  "kind": "Event",
  "apiVersion": "audit.k8s.io/v1",
  "level": "Metadata",
  "auditID": "xxxx-xxxx-xxxx",
  "stage": "ResponseComplete",
  "requestURI": "/api/v1/namespaces/audit-test/secrets",
  "verb": "create",
  "user": {
    "username": "kubernetes-admin",
    "groups": ["kubeadm:cluster-admins", "system:authenticated"]
  },
  "objectRef": {
    "resource": "secrets",
    "namespace": "audit-test",
    "name": "test-secret",
    "apiVersion": "v1"
  },
  "responseStatus": {
    "metadata": {},
    "code": 201
  },
  "requestReceivedTimestamp": "2025-01-15T10:30:00.000000Z",
  "stageTimestamp": "2025-01-15T10:30:00.100000Z"
}
```

**Verify key audit policy behaviors:**

```bash
# Secrets logged at Metadata level (no request/response body)
sudo grep '"resource":"secrets"' /var/log/kubernetes/audit/audit.log | jq '.level' | head -3
```

Expected: `"Metadata"`

```bash
# Health checks NOT logged
sudo grep 'healthz' /var/log/kubernetes/audit/audit.log | wc -l
```

Expected: `0`

> **Coach tip:** If the API server fails to start after editing, the most common causes are:
> 1. YAML indentation error in the static Pod manifest
> 2. Missing volume mount (the container can't see the policy file)
> 3. Audit policy YAML syntax error
>
> Recovery: `sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml`
>
> To debug: `sudo journalctl -u kubelet --since "5 minutes ago" | grep -i error`

---

## Task 7: Secrets Encryption at Rest

### Step-by-step

> **Important:** Backup the API server manifest first!
> ```bash
> sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/manifests/kube-apiserver.yaml.bak
> ```

**Generate encryption key:**

```bash
ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)
echo "Encryption key: $ENCRYPTION_KEY"
```

**Create EncryptionConfiguration:**

```bash
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

### Verification — Config file valid

```bash
sudo cat /etc/kubernetes/encryption-config.yaml
```

Expected:

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
              secret: <base64-encoded-32-byte-key>
      - identity: {}
```

**Edit kube-apiserver.yaml:**

Add to `spec.containers[0].command`:

```yaml
    - --encryption-provider-config=/etc/kubernetes/encryption-config.yaml
```

Add to `spec.containers[0].volumeMounts`:

```yaml
    - mountPath: /etc/kubernetes/encryption-config.yaml
      name: encryption-config
      readOnly: true
```

Add to `spec.volumes`:

```yaml
  - name: encryption-config
    hostPath:
      path: /etc/kubernetes/encryption-config.yaml
      type: File
```

**Wait for API server restart:**

```bash
sleep 30
kubectl get nodes
```

### Verification — New Secrets are encrypted

```bash
kubectl create namespace encryption-test
kubectl create secret generic encrypted-secret -n encryption-test --from-literal=mykey=mydata
```

Read raw data from etcd:

```bash
sudo ETCDCTL_API=3 etcdctl get /registry/secrets/encryption-test/encrypted-secret \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  | hexdump -C | head -20
```

Expected: The output contains `k8s:enc:aescbc:v1:key1:` followed by binary encrypted data:

```
00000000  2f 72 65 67 69 73 74 72  79 2f 73 65 63 72 65 74  |/registry/secret|
00000010  73 2f 65 6e 63 72 79 70  74 69 6f 6e 2d 74 65 73  |s/encryption-tes|
00000020  74 2f 65 6e 63 72 79 70  74 65 64 2d 73 65 63 72  |t/encrypted-secr|
00000030  65 74 0a 6b 38 73 3a 65  6e 63 3a 61 65 73 63 62  |et.k8s:enc:aescb|
00000040  63 3a 76 31 3a 6b 65 79  31 3a ...                |c:v1:key1:...|
```

The `k8s:enc:aescbc:v1:key1:` prefix confirms encryption is active.

**Verify the Secret is still readable via kubectl (transparent decryption):**

```bash
kubectl get secret encrypted-secret -n encryption-test -o jsonpath='{.data.mykey}' | base64 -d
```

Expected: `mydata`

### Re-encrypt existing Secrets

```bash
kubectl get secrets --all-namespaces -o json | kubectl replace -f -
```

Expected: Each Secret is read (decrypted) and written back (encrypted). You may see `replaced` for each Secret.

> **Coach tip:** Common issues:
> 1. **API server won't start:** Check `sudo journalctl -u kubelet --since "5 min ago" | grep encrypt` — usually a malformed config or missing volume mount
> 2. **"invalid key length":** The key must be exactly 32 bytes (base64-encoded result of `head -c 32 /dev/urandom`)
> 3. **etcdctl not found:** Use `sudo apt install etcd-client` or exec into the etcd Pod:
>    ```bash
>    kubectl exec -n kube-system etcd-<node-name> -- etcdctl \
>      --cacert=/etc/kubernetes/pki/etcd/ca.crt \
>      --cert=/etc/kubernetes/pki/etcd/server.crt \
>      --key=/etc/kubernetes/pki/etcd/server.key \
>      get /registry/secrets/encryption-test/encrypted-secret
>    ```

---

## Task 8: Block Cloud Metadata Endpoint

### Step-by-step

Ensure the `egress-lab` namespace and test Pods exist from Task 3.

**Apply metadata-blocking policy:**

Save `block-metadata.yaml`:

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
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 169.254.169.254/32
```

```bash
# First, remove the default-deny from Task 3 to test this policy in isolation
kubectl delete networkpolicy default-deny-egress -n egress-lab 2>/dev/null
kubectl delete networkpolicy allow-dns-and-api -n egress-lab 2>/dev/null

kubectl apply -f block-metadata.yaml
```

### Verification — Metadata blocked

```bash
kubectl exec -n egress-lab test-pod -- wget -qO- --timeout=5 http://169.254.169.254/ 2>&1
```

Expected: timeout or connection refused — the metadata endpoint is blocked.

```bash
kubectl exec -n egress-lab test-pod -- wget -qO- --timeout=5 http://kubernetes.default.svc.cluster.local/healthz 2>&1
```

Expected: `ok` — general egress still works (except to `169.254.169.254`).

> **Coach tip:** On a non-cloud VM (local VMs, bare metal), `169.254.169.254` isn't actually reachable anyway. The learning goal is the NetworkPolicy pattern. In a real cloud environment (AWS, GCP, Azure), this policy prevents Pod-level credential theft from the instance metadata service. The test may show "connection refused" or "network unreachable" rather than a clean block — both indicate the policy is working.

### Verification — Policy details

```bash
kubectl describe networkpolicy deny-cloud-metadata -n egress-lab
```

Expected:

```
Name:         deny-cloud-metadata
Namespace:    egress-lab
...
Spec:
  PodSelector:     <none> (Coverage: all pods in the namespace)
  Allowing egress traffic:
    To Port: <any> (traffic allowed to all ports)
    To:
      IPBlock:
        CIDR: 0.0.0.0/0
        Except: 169.254.169.254/32
  Policy Types: Egress
```

---

## Task 9: Sandboxed Containers with RuntimeClass

### Step-by-step

**Install gVisor on each node:**

```bash
# Add gVisor repo
curl -fsSL https://gvisor.dev/archive.key | sudo gpg --dearmor -o /usr/share/keyrings/gvisor-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/gvisor-archive-keyring.gpg] https://storage.googleapis.com/gvisor/releases release main" | sudo tee /etc/apt/sources.list.d/gvisor.list > /dev/null
sudo apt-get update && sudo apt-get install -y runsc
```

**Configure containerd:**

```bash
# Add the runsc runtime handler
cat <<EOF | sudo tee -a /etc/containerd/config.toml

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
EOF

sudo systemctl restart containerd
```

**Create the RuntimeClass:**

Save `gvisor-runtimeclass.yaml`:

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
```

```bash
kubectl apply -f gvisor-runtimeclass.yaml
```

**Deploy a sandboxed Pod:**

Save `sandboxed-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: sandboxed-pod
  namespace: sandbox-lab
spec:
  runtimeClassName: gvisor
  containers:
    - name: app
      image: nginx:1.27
      ports:
        - containerPort: 80
```

```bash
kubectl create namespace sandbox-lab
kubectl apply -f sandboxed-pod.yaml
```

### Verification — gVisor running

```bash
kubectl exec -n sandbox-lab sandboxed-pod -- dmesg 2>&1 | head -5
```

Expected: Output includes "Starting gVisor..." — this is gVisor's user-space kernel, not the host.

```bash
kubectl exec -n sandbox-lab sandboxed-pod -- uname -r
```

Expected: A synthetic kernel version like `4.4.0` — NOT the host kernel version.

**Compare with a standard Pod:**

```bash
kubectl run standard-pod -n sandbox-lab --image=nginx:1.27 --restart=Never
kubectl exec -n sandbox-lab standard-pod -- uname -r
```

Expected: Returns the actual host kernel (e.g., `6.8.0-xxx`). The difference proves gVisor sandboxing is active.

> **Coach tip:** gVisor adds latency to syscalls (they go through user-space instead of directly to the kernel). This is the security-performance tradeoff. Some workloads (high-I/O, GPU) may not work well in gVisor. The CKS exam tests understanding of when and why to use sandboxed runtimes, not deep gVisor tuning.

---

## Task 10: Pod-to-Pod Encryption with Cilium WireGuard

### Step-by-step

**Install Cilium CLI:**

```bash
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz
```

**Remove existing CNI and install Cilium with WireGuard:**

```bash
# Remove Calico (if installed)
kubectl delete -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.0/manifests/calico.yaml 2>/dev/null

# Wait for Calico pods to terminate
kubectl -n kube-system wait --for=delete pod -l k8s-app=calico-node --timeout=60s 2>/dev/null

# Install Cilium with WireGuard encryption
cilium install --version 1.17.3 \
  --set encryption.enabled=true \
  --set encryption.type=wireguard
```

**Wait for Cilium to be ready:**

```bash
cilium status --wait
```

### Verification — Encryption active

```bash
cilium status | grep Encryption
```

Expected:

```
Encryption:   Wireguard [cilium_wg0 (Pubkey: <key>, Port: 51871, Peers: N)]
```

Where N = number of other nodes in the cluster.

**Deploy test workload:**

```bash
kubectl create namespace encryption-test
kubectl run client -n encryption-test --image=busybox:1.36 --restart=Never -- sleep 3600
kubectl run server -n encryption-test --image=nginx:1.27 --restart=Never --labels="app=server"
kubectl expose pod server -n encryption-test --port=80

# Wait for pods to be ready
kubectl wait -n encryption-test --for=condition=Ready pod --all --timeout=60s
```

### Verification — Traffic on WireGuard tunnel

In one terminal, capture traffic on the WireGuard interface:

```bash
kubectl -n kube-system exec -ti ds/cilium -- bash -c "apt-get update -qq && apt-get install -y -qq tcpdump > /dev/null 2>&1 && tcpdump -c 10 -n -i cilium_wg0"
```

In a second terminal, generate traffic:

```bash
kubectl exec -n encryption-test client -- wget -qO- http://server.encryption-test.svc.cluster.local
```

Expected: The tcpdump shows TCP traffic on `cilium_wg0` — meaning packets are being routed through the encrypted WireGuard tunnel.

### Verification — Connectivity test

```bash
cilium connectivity test
```

Expected: All tests pass. The connectivity test validates encryption, network policies, and DNS resolution.

> **Coach tip:** Cilium replaces the entire CNI. If students had Calico-based NetworkPolicies from earlier tasks, those policies continue to work because Cilium also enforces NetworkPolicy. However, the policy enforcement engine is now Cilium, not Calico. For the CKS exam, students should understand that Cilium provides both CNI networking AND encryption — it's not just a NetworkPolicy enforcer.

> **Coach tip:** If the cluster only has a single node, WireGuard shows 0 peers and there's no cross-node traffic to encrypt. Students need a multi-node kubeadm cluster (at least 2 nodes) to see WireGuard encryption in action. This is expected.

---

## Clean Up

```bash
kubectl delete namespace egress-lab 2>/dev/null
kubectl delete namespace sa-lab 2>/dev/null
kubectl delete namespace encryption-test 2>/dev/null
kubectl delete namespace sandbox-lab 2>/dev/null
kubectl delete runtimeclass gvisor 2>/dev/null
kubectl delete -f tls-demo-app.yaml 2>/dev/null
kubectl delete -f tls-demo-ingress.yaml 2>/dev/null
kubectl delete -f tls-demo-cert.yaml 2>/dev/null
kubectl delete -f self-signed-issuer.yaml 2>/dev/null
kubectl delete job kube-bench 2>/dev/null
```

On the control-plane node, optionally revert API server changes:

```bash
# Only if you want to remove audit logging and encryption for subsequent challenges
sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml
```

> **Coach tip:** If students are continuing to Challenge 20, they may want to **keep** the audit logging and encryption changes — they're production-good practices. Only revert for a clean slate.
