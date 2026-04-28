# Solution 05 — Services and Networking

[< Back to Challenge](../Student/Challenge-05.md) | **[Home](README.md)**

## Prerequisites

Students should have a running Kind cluster. If they completed Challenge 06's cluster (with Ingress port mappings), that works too — it's a superset. If they're starting fresh:

```bash
kind create cluster --name fasthack
```

---

## Task 1: ClusterIP Service

### Step-by-step

**1a. Create the Deployment**

Save as `web-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: nginx
          image: nginx:stable
          ports:
            - containerPort: 80
```

```bash
kubectl apply -f web-deployment.yaml
```

Expected output:

```
deployment.apps/web created
```

**1b. Create the ClusterIP Service**

Save as `web-svc.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-svc
spec:
  selector:
    app: web
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
```

```bash
kubectl apply -f web-svc.yaml
```

Expected output:

```
service/web-svc created
```

### Verification

```bash
# Confirm the Service exists and has a ClusterIP
kubectl get svc web-svc
```

Expected output:

```
NAME      TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
web-svc   ClusterIP   10.96.x.x     <none>        80/TCP    5s
```

```bash
# Confirm Endpoints (should list 3 Pod IPs)
kubectl get endpoints web-svc
```

Expected output:

```
NAME      ENDPOINTS                                    AGE
web-svc   10.244.0.5:80,10.244.0.6:80,10.244.0.7:80   10s
```

```bash
# Test connectivity from inside the cluster
kubectl run tmp-curl --rm -it --restart=Never --image=curlimages/curl -- curl -s http://web-svc
```

Expected output: the default nginx welcome page HTML. The line `<title>Welcome to nginx!</title>` confirms it works.

> **Coach tip:** If students see `<none>` for Endpoints, have them compare `kubectl get svc web-svc -o yaml | grep -A2 selector` with `kubectl get pods --show-labels`. Mismatched labels are the #1 cause.

---

## Task 2: NodePort Service

### Step-by-step

Save as `web-nodeport.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-nodeport
spec:
  type: NodePort
  selector:
    app: web
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
```

```bash
kubectl apply -f web-nodeport.yaml
```

### Verification

```bash
# See the assigned NodePort (30000–32767 range)
kubectl get svc web-nodeport
```

Expected output:

```
NAME           TYPE       CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE
web-nodeport   NodePort   10.96.x.x     <none>        80:3XXXX/TCP   5s
```

```bash
# Get the node IP and NodePort, then curl from the host
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
NODE_PORT=$(kubectl get svc web-nodeport -o jsonpath='{.spec.ports[0].nodePort}')
echo "Curling http://${NODE_IP}:${NODE_PORT}"
curl -s http://${NODE_IP}:${NODE_PORT} | head -5
```

Expected output: first lines of the nginx welcome page HTML.

> **Coach tip:** In Kind, the "node" is a Docker container. `docker ps` shows it. The node's InternalIP is reachable from the host because Kind sets up Docker networking. If curl hangs, have students check `docker ps` to confirm the kind node container is running.

---

## Task 3: DNS Resolution

### Step-by-step

```bash
# Launch a temporary debugging Pod
kubectl run tmp-dns --rm -it --restart=Never --image=busybox:stable -- sh
```

Inside the Pod, run:

```sh
# Resolve the short name (works within the same namespace)
nslookup web-svc
```

Expected output:

```
Server:    10.96.0.10
Address:   10.96.0.10:53

Name:      web-svc.default.svc.cluster.local
Address:   10.96.X.X
```

```sh
# Resolve the FQDN
nslookup web-svc.default.svc.cluster.local
```

Expected output: same ClusterIP as above.

```sh
# Inspect DNS configuration
cat /etc/resolv.conf
```

Expected output:

```
search default.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5
```

```sh
# Reach the service by name
wget -qO- http://web-svc
```

Expected output: nginx welcome page.

```sh
exit
```

**Cross-namespace test:**

```bash
# Create a second namespace and test FQDN resolution
kubectl create namespace other
kubectl run tmp-cross --rm -it --restart=Never --namespace=other --image=curlimages/curl \
  -- curl -s http://web-svc.default.svc.cluster.local
```

Expected output: nginx welcome page. This proves that the FQDN works across namespaces.

```bash
# Cleanup
kubectl delete namespace other
```

### Verification

- `nslookup web-svc` returns the ClusterIP
- `/etc/resolv.conf` shows the search domains (`default.svc.cluster.local`, etc.)
- Cross-namespace FQDN resolution works

> **Coach tip:** Explain the `ndots:5` option — any name with fewer than 5 dots gets the search domains appended before trying as-is. That's why `web-svc` (0 dots) resolves to `web-svc.default.svc.cluster.local` automatically.

---

## Task 4: Multi-Tier App (Frontend + Backend)

### Step-by-step

Save as `multi-tier.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
spec:
  replicas: 2
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
          image: hashicorp/http-echo
          args:
            - "-text=Hello from backend"
          ports:
            - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: backend-svc
spec:
  selector:
    app: backend
  ports:
    - protocol: TCP
      port: 5678
      targetPort: 5678
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      containers:
        - name: curl
          image: curlimages/curl
          command: ["sh", "-c"]
          args:
            - |
              while true; do
                echo "$(date) - $(curl -s http://backend-svc:5678)"
                sleep 5
              done
```

```bash
kubectl apply -f multi-tier.yaml
```

Expected output:

```
deployment.apps/backend created
service/backend-svc created
deployment.apps/frontend created
```

### Verification

```bash
# Wait for Pods to be ready
kubectl wait --for=condition=ready pod -l app=backend --timeout=60s
kubectl wait --for=condition=ready pod -l app=frontend --timeout=60s

# Check the frontend logs
kubectl logs -l app=frontend --tail=5
```

Expected output:

```
Mon Jun 16 12:00:00 UTC 2025 - Hello from backend
Mon Jun 16 12:00:05 UTC 2025 - Hello from backend
Mon Jun 16 12:00:10 UTC 2025 - Hello from backend
```

```bash
# Also confirm the backend Endpoints are populated
kubectl get endpoints backend-svc
```

Expected output: shows 2 Pod IPs on port 5678.

> **Coach tip:** If students see `curl: (6) Could not resolve host: backend-svc`, the Service name or port is wrong. Have them double-check with `kubectl get svc backend-svc`.

---

## Task 5: NetworkPolicy

### Step-by-step

**5a. Install Calico CNI (required for NetworkPolicy enforcement)**

Kind's default CNI (`kindnet`) does **not** enforce NetworkPolicies. Students need to install Calico.

**Option A — Recreate the cluster with Calico (recommended, clean start):**

```bash
kind delete cluster --name fasthack

cat <<'EOF' | kind create cluster --name fasthack --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
  podSubnet: 192.168.0.0/16
EOF
```

```bash
# Install Calico
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.0/manifests/calico.yaml

# Wait for Calico to be ready (takes 1-2 minutes)
kubectl -n kube-system wait --for=condition=ready pod -l k8s-app=calico-node --timeout=120s
```

Expected output:

```
pod/calico-node-xxxxx condition met
```

After Calico is ready, re-apply all resources from Tasks 1-4:

```bash
kubectl apply -f web-deployment.yaml
kubectl apply -f web-svc.yaml
kubectl apply -f multi-tier.yaml
```

**Option B — Install Calico on existing cluster (faster but less clean):**

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.0/manifests/calico.yaml
kubectl -n kube-system wait --for=condition=ready pod -l k8s-app=calico-node --timeout=120s
```

**5b. Verify open communication (before any policy)**

```bash
# Test from a pod without the frontend label — should succeed
kubectl run tmp-test --rm -it --restart=Never --image=curlimages/curl \
  -- curl -s --max-time 5 http://backend-svc:5678
```

Expected output:

```
Hello from backend
```

**5c. Deny all ingress to backend Pods**

Save as `deny-all-backend.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-backend
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
    - Ingress
```

```bash
kubectl apply -f deny-all-backend.yaml
```

Expected output:

```
networkpolicy.networking.k8s.io/deny-all-backend created
```

### Verification (deny-all)

```bash
# This should now time out
kubectl run tmp-test --rm -it --restart=Never --image=curlimages/curl \
  -- curl -s --max-time 5 http://backend-svc:5678
```

Expected output:

```
curl: (28) Connection timed out after 5001 milliseconds
pod "tmp-test" deleted
pod default/tmp-test terminated (Error)
```

```bash
# Frontend logs should also show failures
kubectl logs -l app=frontend --tail=3
```

Expected output: curl errors (timeouts or connection refused).

**5d. Allow ingress only from frontend Pods**

Save as `allow-frontend-to-backend.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: frontend
      ports:
        - protocol: TCP
          port: 5678
```

```bash
# Remove the deny-all policy
kubectl delete networkpolicy deny-all-backend

# Apply the selective allow policy
kubectl apply -f allow-frontend-to-backend.yaml
```

### Verification (selective allow)

```bash
# Frontend should work again
kubectl logs -l app=frontend --tail=5
```

Expected output:

```
... Hello from backend
... Hello from backend
```

```bash
# A Pod WITHOUT the app=frontend label should still be blocked
kubectl run tmp-test --rm -it --restart=Never --image=curlimages/curl \
  -- curl -s --max-time 5 http://backend-svc:5678
```

Expected output:

```
curl: (28) Connection timed out after 5001 milliseconds
```

This confirms: only Pods with `app: frontend` can reach the backend on port 5678.

---

## Common Issues

| Problem | Likely Cause | Fix |
|---------|-------------|-----|
| Endpoints show `<none>` | Service selector doesn't match Pod labels | Compare `kubectl describe svc <name>` selector with `kubectl get pods --show-labels` |
| NodePort curl hangs | Kind node container not running or wrong IP | Run `docker ps` and use the node's InternalIP |
| DNS resolution fails in Pod | CoreDNS not running | `kubectl -n kube-system get pods -l k8s-app=kube-dns` |
| NetworkPolicy has no effect | Using kindnet (no enforcement) | Install Calico or recreate cluster with `disableDefaultCNI: true` |
| `tmp-*` Pods left over | Previous `--rm` Pod didn't clean up | `kubectl delete pod tmp-test tmp-curl tmp-dns --ignore-not-found` |
| Frontend logs show `curl: (6) Could not resolve host` | Service name typo or Service not created | `kubectl get svc backend-svc` |
| NetworkPolicy blocks everything | Empty `podSelector: {}` selects all Pods | Use specific label selectors |

> **Coach coaching tip:** The NetworkPolicy task is where students struggle most. Walk them through the mental model: "A NetworkPolicy is like iptables — once you create ANY policy that selects a Pod, that Pod switches from default-allow to default-deny for the specified policyTypes. Then you add explicit `ingress` rules to whitelist traffic."

