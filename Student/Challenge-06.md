# Challenge 06 — Ingress and Gateway API

[< Previous Challenge](Challenge-05.md) | **[Home](../README.md)** | [Next Challenge >](Challenge-07.md)

## Introduction

If you've ever configured **nginx** or **Apache** as a reverse proxy — writing `server` blocks with `server_name`, `location` directives, and `proxy_pass` rules — you already understand the problem that Ingress and Gateway API solve.

On a traditional Linux server, you expose multiple web applications behind a single IP by configuring virtual hosts and path-based routing in your reverse proxy config. In Kubernetes, **Ingress** and the newer **Gateway API** are the declarative equivalents: you describe _what_ traffic should go _where_, and a controller (the running reverse proxy) makes it happen.

**Ingress** has been the standard since Kubernetes 1.1, but it has well-known limitations — no standard way to handle TCP/UDP traffic, limited extensibility, and a single resource trying to serve both cluster operators and application developers. **Gateway API** is the official successor: it's more expressive, role-oriented, and already GA as of Kubernetes 1.29. In this challenge, you'll learn both.

## Description

Your mission is to:

1. **Recreate your Kind cluster with Ingress support**

   Your current Kind cluster likely doesn't have the port mappings needed for Ingress. Delete it and create a new one using this config:

   ```yaml
   # kind-ingress.yaml
   kind: Cluster
   apiVersion: kind.x-k8s.io/v1alpha4
   nodes:
   - role: control-plane
     kubeadmConfigPatches:
     - |
       kind: InitConfiguration
       nodeRegistration:
         kubeletExtraArgs:
           node-labels: "ingress-ready=true"
     extraPortMappings:
     - containerPort: 80
       hostPort: 80
       protocol: TCP
     - containerPort: 443
       hostPort: 443
       protocol: TCP
   ```

   ```bash
   kind delete cluster --name fasthack
   kind create cluster --name fasthack --config kind-ingress.yaml
   ```

2. **Install the NGINX Ingress Controller**

   Deploy the NGINX Ingress Controller using the Kind-specific manifest:

   ```bash
   kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
   ```

   Wait for it to be ready:

   ```bash
   kubectl wait --namespace ingress-nginx \
     --for=condition=ready pod \
     --selector=app.kubernetes.io/component=controller \
     --timeout=90s
   ```

3. **Deploy two backend applications**

   Create two simple web apps to route traffic to:

   ```yaml
   # app1.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: app1
     namespace: default
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
     namespace: default
   spec:
     selector:
       app: app1
     ports:
     - port: 80
       targetPort: 5678
   ```

   Create a similar manifest for `app2` (with `"-text=Hello from App2"`), then apply both.

4. **Create an Ingress with host-based routing**

   Write an Ingress resource that routes:
   - `app1.localhost` → `app1-svc`
   - `app2.localhost` → `app2-svc`

   Verify with:

   ```bash
   curl http://app1.localhost/
   curl http://app2.localhost/
   ```

   > **Note:** On most systems, `*.localhost` resolves to `127.0.0.1` automatically. If it doesn't on yours, add entries to `/etc/hosts` (Linux/Mac) or `C:\Windows\System32\drivers\etc\hosts` (Windows).

5. **Create an Ingress with path-based routing**

   Write a _second_ Ingress resource (or modify the first) that routes by path on a single hostname:
   - `localhost/app1` → `app1-svc`
   - `localhost/app2` → `app2-svc`

   Use `pathType: Prefix` and verify with:

   ```bash
   curl http://localhost/app1
   curl http://localhost/app2
   ```

6. **Install Gateway API and create an HTTPRoute**

   Install the Gateway API CRDs:

   ```bash
   kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
   ```

   The NGINX Ingress Controller you already installed supports Gateway API. Enable it by adding the `--enable-gateway-api` flag, or install a dedicated Gateway API controller. For this lab, use the NGINX Gateway Fabric:

   ```bash
   kubectl apply -f https://github.com/nginx/nginx-gateway-fabric/releases/download/v1.6.2/nginx-gateway-fabric.yaml
   ```

   Then create a **Gateway** and **HTTPRoute**:

   ```yaml
   # gateway.yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: Gateway
   metadata:
     name: my-gateway
     namespace: default
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

   ```yaml
   # httproute.yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: HTTPRoute
   metadata:
     name: app-routes
     namespace: default
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

   Inspect the resources:

   ```bash
   kubectl get gateways
   kubectl get httproutes
   kubectl describe httproute app-routes
   ```

7. **Compare Ingress vs Gateway API**

   Study the differences and be prepared to explain:
   - How Gateway API separates concerns (infrastructure owner → `Gateway`, app developer → `HTTPRoute`)
   - What features Gateway API adds (traffic splitting, header matching, request mirroring)
   - Why Gateway API is the recommended path forward for new projects

## Success Criteria

- [ ] Your Kind cluster was created with `extraPortMappings` for ports 80 and 443
- [ ] The NGINX Ingress Controller is running in the `ingress-nginx` namespace
- [ ] You can reach `app1` and `app2` via **host-based routing** (`app1.localhost`, `app2.localhost`)
- [ ] You can reach `app1` and `app2` via **path-based routing** (`localhost/app1`, `localhost/app2`)
- [ ] Gateway API CRDs are installed (`kubectl get crds | grep gateway`)
- [ ] A `Gateway` resource exists and shows `Accepted` or `Programmed` status
- [ ] An `HTTPRoute` is attached to the Gateway and routes traffic to your backend services
- [ ] You can explain at least three differences between Ingress and Gateway API

## Linux ↔ Kubernetes Reference

| Linux Concept | Kubernetes Equivalent |
|---|---|
| nginx / Apache as reverse proxy | Ingress Controller (e.g., NGINX Ingress) |
| `server { }` blocks / VirtualHosts | Ingress resource `rules[].host` |
| `location /path { proxy_pass ... }` | Ingress path-based routing (`rules[].http.paths[]`) |
| `server_name app1.example.com` | Host-based routing (`rules[].host`) |
| HAProxy frontend/backend model | Gateway API: `Gateway` (frontend) + `HTTPRoute` (backend) |
| SSL termination (certbot / Let's Encrypt) | TLS section in Ingress or Gateway `listeners[].tls` |
| `nginx -t` (config test) | `kubectl describe ingress` / `kubectl describe httproute` |
| `/etc/nginx/sites-enabled/` | `ingressClassName` selects which controller handles the resource |

## Hints

<details>
<summary>Hint 1: Host-based Ingress resource</summary>

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: host-routing
  namespace: default
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

The `ingressClassName: nginx` field tells Kubernetes which Ingress Controller should handle this resource.
</details>

<details>
<summary>Hint 2: Path-based Ingress resource</summary>

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: path-routing
  namespace: default
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

**Important:** `pathType` can be `Exact` or `Prefix`. With `Prefix`, `/app1` matches `/app1`, `/app1/`, and `/app1/anything`.
</details>

<details>
<summary>Hint 3: Debugging Ingress issues</summary>

If your Ingress isn't working:

```bash
# Check the Ingress has an ADDRESS assigned
kubectl get ingress

# If ADDRESS is blank, the controller isn't processing it.
# Verify the controller is running:
kubectl get pods -n ingress-nginx

# Check for errors in the Ingress Controller logs:
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=50

# Verify your ingressClassName matches what the controller expects:
kubectl get ingressclass
```

Common issue: if you see `<none>` under ADDRESS, either the controller isn't installed or the `ingressClassName` doesn't match.
</details>

<details>
<summary>Hint 4: Gateway API — verifying your setup</summary>

```bash
# Verify CRDs are installed
kubectl get crds | grep gateway.networking.k8s.io

# Check GatewayClass is available
kubectl get gatewayclass

# Check Gateway status — look for "Accepted" or "Programmed"
kubectl get gateway my-gateway -o yaml | grep -A 5 conditions

# Check HTTPRoute status — look for "Accepted" under parentRefs
kubectl describe httproute app-routes
```

If the Gateway stays in `Pending`, the GatewayClass controller may not be running. Verify the controller pods are up.
</details>

<details>
<summary>Hint 5: Ingress vs Gateway API — key differences</summary>

| Aspect | Ingress | Gateway API |
|---|---|---|
| **Role separation** | Single resource for all config | `Gateway` (infra) + `HTTPRoute` (app dev) |
| **Protocol support** | HTTP/HTTPS only (by spec) | HTTP, gRPC, TCP, UDP, TLS via typed routes |
| **Extensibility** | Annotations (non-portable) | Typed, versioned policy objects |
| **Traffic splitting** | Not built-in | Native weight-based splitting |
| **Header matching** | Annotation-dependent | First-class `matches` in HTTPRoute |
| **Status** | Stable but frozen | GA and actively evolving |
| **Recommendation** | Existing workloads | New projects going forward |

</details>

## Learning Resources

- [Kubernetes Ingress](https://kubernetes.io/docs/concepts/services-networking/ingress/)
- [Kubernetes Ingress Controllers](https://kubernetes.io/docs/concepts/services-networking/ingress-controllers/)
- [Kubernetes Gateway API](https://kubernetes.io/docs/concepts/services-networking/gateway/)
- [Gateway API Official Site](https://gateway-api.sigs.k8s.io/)
- [Kind — Ingress Setup](https://kind.sigs.k8s.io/docs/user/ingress/)
- [NGINX Ingress Controller — Kind Guide](https://kubernetes.github.io/ingress-nginx/deploy/#quick-start)

## Break & Fix 🔧

After completing the challenge, try these diagnostic scenarios:

### Scenario 1: Ingress has no ADDRESS

An Ingress resource was created but `kubectl get ingress` shows a blank ADDRESS column:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: broken-ingress
  namespace: default
spec:
  rules:
  - host: broken.localhost
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: app1-svc
            port:
              number: 80
```

Apply it and investigate. Why is there no ADDRESS? How do you fix it?

> 💡 **Root cause:** The `ingressClassName` field is missing. Without it, no Ingress Controller claims the resource. Add `ingressClassName: nginx` to the `spec` section.

### Scenario 2: Wrong ingressClassName

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: wrong-class
  namespace: default
spec:
  ingressClassName: traefik
  rules:
  - host: wrong.localhost
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: app1-svc
            port:
              number: 80
```

Apply this and try `curl http://wrong.localhost/`. What happens? How do you diagnose and fix it?

> 💡 **Root cause:** `ingressClassName: traefik` doesn't match any installed controller. Run `kubectl get ingressclass` to see available classes and change it to `nginx`.

### Scenario 3: Backend Service doesn't exist

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: missing-backend
  namespace: default
spec:
  ingressClassName: nginx
  rules:
  - host: ghost.localhost
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: does-not-exist
            port:
              number: 80
```

Apply this and `curl http://ghost.localhost/`. What HTTP status code do you get? Check the Ingress Controller logs to understand why.

> 💡 **Root cause:** The Service `does-not-exist` is not found. The NGINX Ingress Controller returns a **503 Service Temporarily Unavailable**. Check logs with `kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=20` and create the missing Service.
