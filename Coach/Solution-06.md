# Solution 06 — Ingress and Gateway API

[< Back to Challenge](../Student/Challenge-06.md) | **[Home](README.md)**

## Prerequisites

This challenge requires a fresh Kind cluster with specific port mappings. Students **must** delete any existing cluster and start with the Ingress-ready config.

---

## Task 1: Recreate Kind Cluster with Ingress Support

### Step-by-step

Save as `kind-ingress.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
```

```bash
# Delete any existing cluster
kind delete cluster --name fasthack

# Create the new cluster with Ingress port mappings
kind create cluster --name fasthack --config kind-ingress.yaml
```

Expected output:

```
Creating cluster "fasthack" ...
 ✓ Ensuring node image (kindest/node:v1.36.x) 🖼
 ✓ Preparing nodes 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
Set kubectl context to "kind-fasthack"
```

### Verification

```bash
# Confirm the node has the ingress-ready label
kubectl get nodes --show-labels | grep ingress-ready
```

Expected output: `ingress-ready=true` appears in the labels.

```bash
# Confirm port mappings from Docker side
docker port fasthack-control-plane
```

Expected output:

```
80/tcp -> 0.0.0.0:80
443/tcp -> 0.0.0.0:443
6443/tcp -> 127.0.0.1:XXXXX
```

> **Coach tip:** If ports 80/443 are already in use on the host (Apache, nginx, IIS, another container), Kind cluster creation will fail. Have students stop any conflicting services first.

---

## Task 2: Install NGINX Ingress Controller

### Step-by-step

```bash
# Install the Kind-specific NGINX Ingress Controller manifest
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
```

Expected output: multiple resources created (namespace, serviceaccount, configmap, roles, deployment, service, etc.).

```bash
# Wait for the controller Pod to be ready
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
```

Expected output:

```
pod/ingress-nginx-controller-xxxxx condition met
```

### Verification

```bash
# Confirm the controller is running
kubectl get pods -n ingress-nginx
```

Expected output:

```
NAME                                        READY   STATUS    RESTARTS   AGE
ingress-nginx-controller-xxxxxxxxxx-xxxxx   1/1     Running   0          30s
```

```bash
# Confirm the IngressClass was created
kubectl get ingressclass
```

Expected output:

```
NAME    CONTROLLER                      PARAMETERS   AGE
nginx   k8s.io/ingress-nginx            <none>       30s
```

> **Coach tip:** The Kind-specific manifest includes a `hostPort` DaemonSet configuration instead of a LoadBalancer Service. This is what makes `localhost:80` reachable — the controller Pod binds directly to the node's ports 80 and 443 via `hostPort`.

---

## Task 3: Deploy Two Backend Applications

### Step-by-step

Save as `app1.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app1
spec:
  replicas: 1
  selector:
    matchLabels:
      app: app1
  template:
    metadata:
      labels:
        app: app1
    spec:
      containers:
      - name: app1
        image: hashicorp/http-echo:latest
        args:
        - "-text=Hello from App1"
        ports:
        - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: app1-svc
spec:
  selector:
    app: app1
  ports:
  - port: 80
    targetPort: 5678
```

Save as `app2.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app2
spec:
  replicas: 1
  selector:
    matchLabels:
      app: app2
  template:
    metadata:
      labels:
        app: app2
    spec:
      containers:
      - name: app2
        image: hashicorp/http-echo:latest
        args:
        - "-text=Hello from App2"
        ports:
        - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: app2-svc
spec:
  selector:
    app: app2
  ports:
  - port: 80
    targetPort: 5678
```

```bash
kubectl apply -f app1.yaml
kubectl apply -f app2.yaml
```

### Verification

```bash
kubectl wait --for=condition=ready pod -l app=app1 --timeout=60s
kubectl wait --for=condition=ready pod -l app=app2 --timeout=60s
kubectl get pods -l 'app in (app1,app2)'
```

Expected output:

```
NAME                    READY   STATUS    RESTARTS   AGE
app1-xxxxxxxxxx-xxxxx   1/1     Running   0          15s
app2-xxxxxxxxxx-xxxxx   1/1     Running   0          15s
```

```bash
# Verify the Services have Endpoints
kubectl get endpoints app1-svc app2-svc
```

Expected output: each Service shows one Pod IP on port 5678.

---

## Task 4: Host-Based Ingress Routing

### Step-by-step

Save as `host-ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: host-routing
spec:
  ingressClassName: nginx
  rules:
  - host: app1.localhost
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: app1-svc
            port:
              number: 80
  - host: app2.localhost
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: app2-svc
            port:
              number: 80
```

```bash
kubectl apply -f host-ingress.yaml
```

Expected output:

```
ingress.networking.k8s.io/host-routing created
```

### Verification

```bash
# Check the Ingress has an ADDRESS
kubectl get ingress host-routing
```

Expected output:

```
NAME           CLASS   HOSTS                          ADDRESS     PORTS   AGE
host-routing   nginx   app1.localhost,app2.localhost   localhost   80      10s
```

> **Note:** The ADDRESS may take 10-30 seconds to appear. If it stays blank, check that `ingressClassName: nginx` is set.

```bash
# Test host-based routing
curl -s http://app1.localhost/
```

Expected output:

```
Hello from App1
```

```bash
curl -s http://app2.localhost/
```

Expected output:

```
Hello from App2
```

> **Coach tip:** On most systems, `*.localhost` resolves to `127.0.0.1` automatically. If it doesn't work on a student's machine (especially Windows), they need to add entries to the hosts file:
> - **Linux/Mac:** `echo "127.0.0.1 app1.localhost app2.localhost" | sudo tee -a /etc/hosts`
> - **Windows:** Add `127.0.0.1 app1.localhost` and `127.0.0.1 app2.localhost` to `C:\Windows\System32\drivers\etc\hosts`
>
> Alternatively, use the `-H` flag with curl: `curl -s -H "Host: app1.localhost" http://localhost/`

---

## Task 5: Path-Based Ingress Routing

### Step-by-step

Save as `path-ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: path-routing
spec:
  ingressClassName: nginx
  rules:
  - host: localhost
    http:
      paths:
      - path: /app1
        pathType: Prefix
        backend:
          service:
            name: app1-svc
            port:
              number: 80
      - path: /app2
        pathType: Prefix
        backend:
          service:
            name: app2-svc
            port:
              number: 80
```

```bash
kubectl apply -f path-ingress.yaml
```

Expected output:

```
ingress.networking.k8s.io/path-routing created
```

### Verification

```bash
kubectl get ingress path-routing
```

Expected output:

```
NAME           CLASS   HOSTS       ADDRESS     PORTS   AGE
path-routing   nginx   localhost   localhost   80      10s
```

```bash
curl -s http://localhost/app1
```

Expected output:

```
Hello from App1
```

```bash
curl -s http://localhost/app2
```

Expected output:

```
Hello from App2
```

> **Coach tip:** `pathType: Prefix` means `/app1` matches `/app1`, `/app1/`, and `/app1/anything`. If students use `pathType: Exact`, only the exact path `/app1` would match (no trailing slash or sub-paths). This is a common confusion point — ask students: "What would happen if you changed to `Exact`?"

---

## Task 6: Gateway API with HTTPRoute

### Step-by-step

**6a. Install Gateway API CRDs**

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
```

Expected output: multiple CRDs created (gateways, gatewayclasses, httproutes, referencegrants, etc.).

```bash
# Verify CRDs are installed
kubectl get crds | grep gateway.networking.k8s.io
```

Expected output:

```
gatewayclasses.gateway.networking.k8s.io          2025-xx-xxTxx:xx:xxZ
gateways.gateway.networking.k8s.io                2025-xx-xxTxx:xx:xxZ
grpcroutes.gateway.networking.k8s.io              2025-xx-xxTxx:xx:xxZ
httproutes.gateway.networking.k8s.io              2025-xx-xxTxx:xx:xxZ
referencegrants.gateway.networking.k8s.io         2025-xx-xxTxx:xx:xxZ
```

**6b. Install NGINX Gateway Fabric**

```bash
kubectl apply -f https://github.com/nginx/nginx-gateway-fabric/releases/download/v1.6.2/nginx-gateway-fabric.yaml
```

Expected output: namespace, serviceaccount, clusterroles, deployment, and GatewayClass created.

```bash
# Wait for the Gateway Fabric controller to be ready
kubectl wait --namespace nginx-gateway \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/instance=nginx-gateway-fabric \
  --timeout=120s
```

Expected output:

```
pod/nginx-gateway-fabric-xxxxxxxxxx-xxxxx condition met
```

```bash
# Verify the GatewayClass exists
kubectl get gatewayclass
```

Expected output:

```
NAME    CONTROLLER                          ACCEPTED   AGE
nginx   gateway.nginx.org/nginx-gateway-fabric-controller   True       30s
```

**6c. Create the Gateway resource**

Save as `gateway.yaml`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: my-gateway
spec:
  gatewayClassName: nginx
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: Same
```

```bash
kubectl apply -f gateway.yaml
```

**6d. Create the HTTPRoute**

Save as `httproute.yaml`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: app-routes
spec:
  parentRefs:
  - name: my-gateway
  hostnames:
  - "demo.localhost"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /app1
    backendRefs:
    - name: app1-svc
      port: 80
  - matches:
    - path:
        type: PathPrefix
        value: /app2
    backendRefs:
    - name: app2-svc
      port: 80
```

```bash
kubectl apply -f httproute.yaml
```

### Verification

```bash
# Check Gateway status — look for Accepted/Programmed
kubectl get gateway my-gateway
```

Expected output:

```
NAME         CLASS   ADDRESS   PROGRAMMED   AGE
my-gateway   nginx   ...       True         30s
```

```bash
# Check HTTPRoute status
kubectl get httproute app-routes
```

Expected output:

```
NAME         HOSTNAMES            AGE
app-routes   ["demo.localhost"]   15s
```

```bash
# Inspect details
kubectl describe httproute app-routes
```

Look for `Accepted: True` in the `parentRefs` status section.

> **Coach tip:** Testing the HTTPRoute via `curl http://demo.localhost/app1` depends on the Gateway controller's Service type and port. NGINX Gateway Fabric creates a LoadBalancer Service, which stays in `Pending` on Kind. To test, students can port-forward to the gateway:
>
> ```bash
> # Find the gateway service
> kubectl -n nginx-gateway get svc
>
> # Port-forward to the NGINX Gateway Fabric service
> kubectl -n nginx-gateway port-forward svc/nginx-gateway-fabric 8080:80 &
>
> # Test (use -H to set the Host header since we're going via localhost:8080)
> curl -s -H "Host: demo.localhost" http://localhost:8080/app1
> curl -s -H "Host: demo.localhost" http://localhost:8080/app2
> ```
>
> Expected output: `Hello from App1` and `Hello from App2` respectively.

---

## Task 7: Compare Ingress vs Gateway API

This is a discussion/knowledge task. Key points students should be able to articulate:

| Aspect | Ingress | Gateway API |
|--------|---------|-------------|
| **Role separation** | Single Ingress resource for everything | `GatewayClass` (infra provider) → `Gateway` (cluster operator) → `HTTPRoute` (app developer) |
| **Protocol support** | HTTP/HTTPS only (by spec) | HTTP, gRPC, TCP, UDP, TLS via typed route resources |
| **Extensibility** | Vendor-specific annotations (non-portable) | Typed, versioned policy resources (portable across implementations) |
| **Traffic splitting** | Not built-in (annotation-dependent) | Native weight-based splitting in `backendRefs` |
| **Header matching** | Annotation-dependent | First-class `matches` in HTTPRoute rules |
| **Status feedback** | Minimal | Rich status conditions on every resource |
| **Maturity** | Stable but frozen — no new features | GA since K8s 1.29, actively evolving |

> **Coach tip:** Frame it like this: "Ingress is like a single nginx.conf file that one person edits. Gateway API is like splitting that config into the infrastructure team managing the `server` block (Gateway) and the app team managing the `location` blocks (HTTPRoute). Who manages what is now explicit."

---

## Common Issues

| Problem | Likely Cause | Fix |
|---------|-------------|-----|
| `curl: (7) Failed to connect to localhost port 80` | Kind cluster not created with `extraPortMappings` | Delete cluster and recreate with `kind-ingress.yaml` config |
| Ingress ADDRESS is `<none>` | Missing `ingressClassName: nginx` | Add `ingressClassName: nginx` to the Ingress spec |
| `curl app1.localhost` returns 404 | Wrong path or host in Ingress rules | Check `kubectl describe ingress host-routing` for the rules |
| `*.localhost` doesn't resolve | OS doesn't auto-resolve `*.localhost` | Add entries to hosts file or use `curl -H "Host: app1.localhost" http://localhost/` |
| Gateway stays in `Pending` | GatewayClass controller not running | Check `kubectl get pods -n nginx-gateway` |
| NGINX Gateway Fabric pod in CrashLoopBackOff | Port 80 conflict with Ingress controller | They share port 80 — either remove the Ingress controller or use a different port for Gateway |
| Port 80/443 already in use on host | Another service (Apache, IIS, etc.) using the port | Stop the conflicting service before creating the Kind cluster |
| Gateway API CRDs not found | `kubectl apply` for CRDs failed silently | Re-run the CRD install command and check `kubectl get crds | grep gateway` |

