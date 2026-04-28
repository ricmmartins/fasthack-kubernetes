# Challenge 17 — Advanced Deployment Strategies

[< Previous Challenge](Challenge-16.md) - **[Home](../README.md)** - [Next Challenge >](Challenge-18.md)

## Introduction

On a Linux server, upgrading a production application is a carefully choreographed process. You might keep two identical server pools behind a load balancer and flip traffic from the old to the new (`blue/green`). Or you might configure Nginx upstream weights to send only 10% of traffic to the new version while 90% stays on the proven one (`canary / A/B testing`). A simple `apt upgrade nginx` replaces the binary in-place while the service stays up (`rolling update`). And sometimes the only safe option is `systemctl stop myapp && systemctl start myapp` — a hard restart with a brief outage (`recreate`).

Kubernetes formalizes every one of these patterns as a **deployment strategy**. Instead of scripting failovers and upstream weights yourself, you declare the strategy in YAML and the cluster handles the rollout mechanics.

In this challenge you will implement all four patterns on your Kind cluster, plus learn how to handle **API version deprecations** — the Kubernetes equivalent of `apt-get dist-upgrade` breaking your configs when old package interfaces are removed.

| Linux Pattern | Kubernetes Pattern |
|---|---|
| Two server pools + DNS/VIP flip | Blue/Green Deployments |
| Nginx upstream weights (10/90) | Canary with Ingress annotations or Gateway API |
| `apt upgrade` (in-place, no downtime) | RollingUpdate strategy |
| `systemctl stop && start` (brief outage) | Recreate strategy |
| `apt-get dist-upgrade` (breaking changes) | API deprecation & version migration |

> **Cluster requirement:** All exercises use a local [Kind](https://kind.sigs.k8s.io/) cluster — no cloud account needed. If you haven't created one yet, run:
> ```bash
> kind create cluster --name fasthack
> ```

## Description

### Task 1 — Blue/Green Deployment

Blue/Green is the Kubernetes equivalent of maintaining two identical server pools behind a load balancer and switching the VIP from "blue" (current) to "green" (new). The key insight: **two Deployments exist simultaneously, but only one receives traffic** — controlled by the Service selector.

**Step 1:** Create two Deployments — one "blue" (v1) and one "green" (v2). Both use the same base `app` label but differ on a `version` label. Save this as `blue-green.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp-blue
spec:
  replicas: 3
  selector:
    matchLabels:
      app: webapp
      version: blue
  template:
    metadata:
      labels:
        app: webapp
        version: blue
    spec:
      containers:
        - name: webapp
          image: hashicorp/http-echo
          args:
            - "-text=v1 - BLUE"
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
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp-green
spec:
  replicas: 3
  selector:
    matchLabels:
      app: webapp
      version: green
  template:
    metadata:
      labels:
        app: webapp
        version: green
    spec:
      containers:
        - name: webapp
          image: hashicorp/http-echo
          args:
            - "-text=v2 - GREEN"
          ports:
            - containerPort: 5678
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 64Mi
```

**Step 2:** Create a Service that currently points to the **blue** version. Save as `webapp-svc.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: webapp-svc
spec:
  selector:
    app: webapp
    version: blue
  ports:
    - protocol: TCP
      port: 80
      targetPort: 5678
```

**Step 3:** Apply both files and verify that traffic goes to the blue Deployment:

```bash
kubectl apply -f blue-green.yaml
kubectl apply -f webapp-svc.yaml
kubectl run curl-test --image=curlimages/curl --restart=Never --rm -it -- curl -s http://webapp-svc
```

You should see `v1 - BLUE`.

**Step 4:** Switch traffic to green by updating the Service selector:

```bash
kubectl patch svc webapp-svc -p '{"spec":{"selector":{"version":"green"}}}'
```

**Step 5:** Verify the cutover — all traffic now goes to v2:

```bash
kubectl run curl-test --image=curlimages/curl --restart=Never --rm -it -- curl -s http://webapp-svc
```

You should now see `v2 - GREEN`.

> **Why this works:** The Service uses label selectors to choose which Pods receive traffic. By changing one label value, you instantly redirect 100% of traffic — no DNS propagation delay, no connection draining headaches. This is the Kubernetes equivalent of flipping a VIP in a load balancer.

### Task 2 — Canary Deployment with NGINX Ingress Controller

A canary deployment sends a small percentage of traffic to the new version while keeping most traffic on the stable version — like configuring `upstream` weights in an Nginx config to do A/B testing.

The NGINX Ingress Controller supports canary traffic splitting natively via annotations.

**Step 1:** Install the NGINX Ingress Controller on your Kind cluster:

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

# Wait for the controller to be ready
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
```

**Step 2:** Create two Deployments and Services — "stable" and "canary". Save as `canary-app.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp-stable
spec:
  replicas: 3
  selector:
    matchLabels:
      app: myapp
      track: stable
  template:
    metadata:
      labels:
        app: myapp
        track: stable
    spec:
      containers:
        - name: myapp
          image: hashicorp/http-echo
          args:
            - "-text=STABLE v1"
          ports:
            - containerPort: 5678
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
---
apiVersion: v1
kind: Service
metadata:
  name: myapp-stable
spec:
  selector:
    app: myapp
    track: stable
  ports:
    - port: 80
      targetPort: 5678
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp-canary
spec:
  replicas: 1
  selector:
    matchLabels:
      app: myapp
      track: canary
  template:
    metadata:
      labels:
        app: myapp
        track: canary
    spec:
      containers:
        - name: myapp
          image: hashicorp/http-echo
          args:
            - "-text=CANARY v2"
          ports:
            - containerPort: 5678
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
---
apiVersion: v1
kind: Service
metadata:
  name: myapp-canary
spec:
  selector:
    app: myapp
    track: canary
  ports:
    - port: 80
      targetPort: 5678
```

**Step 3:** Create the **main** Ingress for the stable Service. Save as `canary-ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp-main
spec:
  ingressClassName: nginx
  rules:
    - host: myapp.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: myapp-stable
                port:
                  number: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp-canary
  annotations:
    nginx.ingress.kubernetes.io/canary: "true"
    nginx.ingress.kubernetes.io/canary-weight: "20"
spec:
  ingressClassName: nginx
  rules:
    - host: myapp.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: myapp-canary
                port:
                  number: 80
```

The `canary-weight: "20"` annotation tells NGINX to send **20% of traffic** to the canary Service and 80% to stable.

**Step 4:** Apply everything:

```bash
kubectl apply -f canary-app.yaml
kubectl apply -f canary-ingress.yaml
```

**Step 5:** Test the traffic split. Send 20 requests and count the results:

```bash
for i in $(seq 1 20); do
  curl -s -H "Host: myapp.local" http://localhost:80
done | sort | uniq -c
```

You should see roughly 16 responses saying `STABLE v1` and 4 saying `CANARY v2` (80/20 split).

> **Note:** On Kind, the NGINX Ingress Controller listens on the host's port 80. If port 80 is unavailable, use `kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80` and curl `http://localhost:8080` instead.

**Step 6:** Increase canary weight to promote the new version gradually:

```bash
kubectl annotate ingress myapp-canary \
  nginx.ingress.kubernetes.io/canary-weight="50" --overwrite
```

Re-run the curl loop — you should now see a ~50/50 split.

### Task 3 — Canary Deployment with Gateway API HTTPRoute

The Gateway API is the successor to Ingress and provides native traffic splitting without annotations. It's like having weighted upstream configuration built into the load balancer's routing rules instead of bolted on via comments.

**Step 1:** Install Gateway API CRDs and a controller. We'll use **Contour** as the Gateway controller:

```bash
# Install Gateway API CRDs (standard channel)
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/latest/download/standard-install.yaml

# Install Contour (includes a Gateway controller)
kubectl apply -f https://projectcontour.io/quickstart/contour.yaml

# Wait for Contour to be ready
kubectl wait --namespace projectcontour \
  --for=condition=ready pod \
  --selector=app=contour \
  --timeout=120s
```

**Step 2:** Create a GatewayClass and Gateway. Save as `gateway.yaml`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: contour
spec:
  controllerName: projectcontour.io/gateway-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: contour-gateway
  namespace: projectcontour
spec:
  gatewayClassName: contour
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
```

**Step 3:** Create an HTTPRoute with **weighted backendRefs** for traffic splitting. Save as `canary-httproute.yaml`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp-canary-route
spec:
  parentRefs:
    - name: contour-gateway
      namespace: projectcontour
  hostnames:
    - "myapp.local"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: myapp-stable
          port: 80
          weight: 80
        - name: myapp-canary
          port: 80
          weight: 20
```

**Step 4:** Apply and test:

```bash
kubectl apply -f gateway.yaml
kubectl apply -f canary-httproute.yaml

# Find the Envoy service port
kubectl get svc -n projectcontour envoy -o jsonpath='{.spec.ports[0].nodePort}'
```

Send test requests through the Gateway (adjust the port as needed):

```bash
ENVOY_PORT=$(kubectl get svc -n projectcontour envoy -o jsonpath='{.spec.ports[0].nodePort}')
for i in $(seq 1 20); do
  curl -s -H "Host: myapp.local" http://localhost:${ENVOY_PORT}
done | sort | uniq -c
```

**Step 5:** Shift traffic fully to canary by updating the HTTPRoute weights:

```bash
kubectl patch httproute myapp-canary-route --type=merge -p '{
  "spec": {
    "rules": [{
      "matches": [{"path": {"type": "PathPrefix", "value": "/"}}],
      "backendRefs": [
        {"name": "myapp-stable", "port": 80, "weight": 0},
        {"name": "myapp-canary", "port": 80, "weight": 100}
      ]
    }]
  }
}'
```

### Task 4 — Rolling Update Deep Dive (maxSurge & maxUnavailable)

In Challenge 04 you performed a basic rolling update. Now we'll tune the rollout speed with `maxSurge` and `maxUnavailable` — the equivalent of controlling how many servers you take out of the pool at once during an `apt upgrade` cycle.

**Step 1:** Create a Deployment with explicit rolling update parameters. Save as `rolling-deep.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rolling-app
  annotations:
    kubernetes.io/change-cause: "initial deployment v1"
spec:
  replicas: 6
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 2
      maxUnavailable: 1
  selector:
    matchLabels:
      app: rolling-app
  template:
    metadata:
      labels:
        app: rolling-app
    spec:
      containers:
        - name: app
          image: nginx:1.27
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 64Mi
```

With `replicas: 6`, `maxSurge: 2`, and `maxUnavailable: 1`:
- During rollout, up to **8 Pods** can exist at once (6 + 2 surge)
- At least **5 Pods** are always available (6 − 1 unavailable)

**Step 2:** Apply and then trigger a rolling update:

```bash
kubectl apply -f rolling-deep.yaml
kubectl rollout status deployment rolling-app

# Update the image to trigger a rollout
kubectl set image deployment/rolling-app app=nginx:1.28
kubectl annotate deployment rolling-app kubernetes.io/change-cause="update to nginx:1.28" --overwrite
```

**Step 3:** Watch the rollout in real time — observe surge and availability:

```bash
kubectl rollout status deployment/rolling-app
kubectl get pods -l app=rolling-app --watch
```

Notice how Kubernetes creates new Pods before terminating old ones — never dropping below 5 available.

**Step 4:** Inspect the rollout history:

```bash
kubectl rollout history deployment/rolling-app
```

**Step 5:** Experiment with different configurations to see the speed/safety trade-off:

```bash
# Fast rollout — aggressive surge, allow more unavailable
kubectl patch deployment rolling-app -p '{
  "spec": {"strategy": {"rollingUpdate": {"maxSurge": 3, "maxUnavailable": 2}}}
}'
kubectl set image deployment/rolling-app app=nginx:1.27

# Slow, safe rollout — minimal surge, zero unavailable
kubectl patch deployment rolling-app -p '{
  "spec": {"strategy": {"rollingUpdate": {"maxSurge": 1, "maxUnavailable": 0}}}
}'
kubectl set image deployment/rolling-app app=nginx:1.28
```

> **Key insight:** `maxSurge: 1, maxUnavailable: 0` means "never have fewer Pods than desired, create one new before removing one old." This is the safest but slowest option — exactly like taking one server out of a pool at a time during a rolling firmware upgrade.

### Task 5 — Recreate Strategy

The Recreate strategy is the equivalent of `systemctl stop myapp && systemctl start myapp` — all old Pods are terminated before any new ones are created. There **will** be downtime.

**Step 1:** Create a Deployment with Recreate strategy. Save as `recreate-app.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: recreate-app
spec:
  replicas: 4
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: recreate-app
  template:
    metadata:
      labels:
        app: recreate-app
    spec:
      containers:
        - name: app
          image: nginx:1.27
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
```

**Step 2:** Apply and wait for all Pods to be ready:

```bash
kubectl apply -f recreate-app.yaml
kubectl rollout status deployment recreate-app
```

**Step 3:** Trigger an update and **watch carefully** — you'll see all old Pods terminate before any new ones start:

```bash
kubectl set image deployment/recreate-app app=nginx:1.28

# In another terminal, watch the Pod transitions
kubectl get pods -l app=recreate-app --watch
```

**Step 4:** Observe the timeline:

```bash
kubectl describe deployment recreate-app
```

Look at the Events section — you'll see `ScalingReplicaSet` events showing the old ReplicaSet scaled to 0 *before* the new ReplicaSet scales up.

> **When to use Recreate:**
> - Your application cannot tolerate two versions running simultaneously (e.g., database schema migration in progress)
> - You have a singleton workload that holds an exclusive lock on a resource
> - Brief downtime is acceptable and simpler than managing version coexistence

### Task 6 — API Deprecation Handling

When Kubernetes removes old API versions, your stored manifests break — just like when `apt-get dist-upgrade` removes a deprecated package interface and scripts relying on it stop working.

**Step 1:** Check your cluster for deprecated API usage:

```bash
# See which API versions your cluster supports
kubectl api-versions | sort

# Check for deprecation warnings (the API server returns warnings in response headers)
kubectl get deployments -v=8 2>&1 | grep -i deprecat
```

**Step 2:** Practice converting a manifest with an old API version. Create a file `old-ingress.yaml` with the **deprecated** `extensions/v1beta1` API:

```yaml
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: legacy-ingress
spec:
  rules:
    - host: old.example.com
      http:
        paths:
          - path: /
            backend:
              serviceName: legacy-svc
              servicePort: 80
```

**Step 3:** Try to apply it — the API server will reject it:

```bash
kubectl apply -f old-ingress.yaml
```

You'll see an error like: `error: resource mapping not found for name: "legacy-ingress" namespace: "" from "old-ingress.yaml": no matches for kind "Ingress" in version "extensions/v1beta1"`.

**Step 4:** Install and use `kubectl-convert` to migrate to the current API version:

```bash
# Install the kubectl-convert plugin (if not already installed)
# Via Krew:
kubectl krew install convert

# Or download directly:
# curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl-convert"
# chmod +x kubectl-convert && sudo mv kubectl-convert /usr/local/bin/
```

```bash
# Convert to the current networking.k8s.io/v1 API
kubectl convert -f old-ingress.yaml --output-version networking.k8s.io/v1
```

**Step 5:** If `kubectl-convert` is not available, manually migrate the manifest. Create `new-ingress.yaml` with the current API:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: legacy-ingress
spec:
  rules:
    - host: old.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: legacy-svc
                port:
                  number: 80
```

Key changes from `extensions/v1beta1` → `networking.k8s.io/v1`:
- `apiVersion` changed
- `backend.serviceName` → `backend.service.name`
- `backend.servicePort` → `backend.service.port.number`
- `pathType` is now **required** (was optional before)

**Step 6:** Explore tools for detecting deprecated APIs across your manifests:

```bash
# List all API resources and their preferred versions
kubectl api-resources -o wide

# The Kubernetes deprecation guide is the authoritative reference:
# https://kubernetes.io/docs/reference/using-api/deprecation-guide/
```

### Clean Up

```bash
kubectl delete -f blue-green.yaml 2>/dev/null
kubectl delete -f webapp-svc.yaml 2>/dev/null
kubectl delete -f canary-app.yaml 2>/dev/null
kubectl delete -f canary-ingress.yaml 2>/dev/null
kubectl delete -f gateway.yaml 2>/dev/null
kubectl delete -f canary-httproute.yaml 2>/dev/null
kubectl delete -f rolling-deep.yaml 2>/dev/null
kubectl delete -f recreate-app.yaml 2>/dev/null
kubectl delete -f old-ingress.yaml 2>/dev/null
kubectl delete -f new-ingress.yaml 2>/dev/null
```

## Success Criteria

- [ ] You deployed a blue/green setup with two Deployments and switched traffic by patching the Service selector.
- [ ] You can explain why blue/green gives instant rollback (just patch the selector back).
- [ ] You installed the NGINX Ingress Controller and created a canary Ingress with `canary-weight` annotation.
- [ ] Curl tests confirm the ~80/20 traffic split between stable and canary.
- [ ] You created a Gateway API HTTPRoute with weighted `backendRefs` for canary traffic splitting.
- [ ] You can explain the difference between Ingress annotations and Gateway API native traffic splitting.
- [ ] You deployed with `maxSurge: 2` and `maxUnavailable: 1` and observed the rollout behavior.
- [ ] You can explain the speed vs. safety trade-off of different `maxSurge`/`maxUnavailable` values.
- [ ] You deployed with `strategy: Recreate` and observed all old Pods terminate before new ones started.
- [ ] You can explain when Recreate is appropriate despite its downtime.
- [ ] You understand why `extensions/v1beta1` Ingress fails on modern clusters and can manually migrate to `networking.k8s.io/v1`.
- [ ] You know how to use `kubectl-convert` (or manual migration) to handle API deprecations.

## Linux ↔ Kubernetes Reference

| Linux Concept | Kubernetes Equivalent | Notes |
|---|---|---|
| Two server pools + DNS/VIP failover | Blue/Green Deployments + Service selector switch | Instant cutover by changing which Pods the Service selects |
| Nginx `upstream` weights (10/90 split) | Canary with Ingress annotations or Gateway API HTTPRoute weights | Gradual traffic shift to the new version |
| `apt upgrade` (in-place, no downtime) | `RollingUpdate` strategy with `maxSurge`/`maxUnavailable` | New Pods created before old ones removed |
| `systemctl stop && systemctl start` | `Recreate` strategy | All old Pods killed before new Pods start — brief outage |
| `apt-get dist-upgrade` (breaking changes) | API deprecation — `apiVersion` migration | Old API versions removed; manifests must be updated |
| `dpkg --configure -a` (fix broken upgrades) | `kubectl convert` / manual manifest migration | Repair manifests that reference removed API versions |
| Load balancer health checks | Service `readinessProbe` + selector labels | Only healthy, selected Pods receive traffic |
| `/etc/nginx/upstream.conf` weights | `backendRefs[].weight` in HTTPRoute | Native weighted routing in Gateway API |

## Hints

<details>
<summary>Hint 1: Blue/Green — How to verify which version is active</summary>

Check which Pods the Service is currently selecting:

```bash
kubectl get endpoints webapp-svc -o yaml
```

The `addresses` list shows the Pod IPs receiving traffic. Cross-reference with:

```bash
kubectl get pods -l app=webapp --show-labels -o wide
```

To rollback to blue after switching to green:

```bash
kubectl patch svc webapp-svc -p '{"spec":{"selector":{"version":"blue"}}}'
```

</details>

<details>
<summary>Hint 2: NGINX Ingress not routing traffic on Kind</summary>

Kind requires a specific NGINX Ingress manifest that maps ports correctly. Make sure you used the Kind-specific manifest:

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
```

If port 80 is not accessible on localhost, use port-forward:

```bash
kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80
```

Then test with:

```bash
curl -s -H "Host: myapp.local" http://localhost:8080
```

Also verify both Ingress resources exist and share the same `host`:

```bash
kubectl get ingress
```

</details>

<details>
<summary>Hint 3: Canary weight not taking effect</summary>

The canary Ingress **must** use the same `host` and `path` as the main Ingress. If they differ, NGINX treats them as separate routes instead of applying the canary weight.

Also ensure the `canary: "true"` annotation is present — without it, the `canary-weight` annotation is ignored:

```bash
kubectl get ingress myapp-canary -o yaml | grep -A5 annotations
```

</details>

<details>
<summary>Hint 4: Understanding maxSurge and maxUnavailable math</summary>

Given `replicas: 6`, `maxSurge: 2`, `maxUnavailable: 1`:

- **Maximum Pods during rollout:** 6 + 2 = **8**
- **Minimum available Pods:** 6 − 1 = **5**

Kubernetes will:
1. Create up to 2 new Pods (surge)
2. Once new Pods are Ready, terminate up to 1 old Pod
3. Repeat until all old Pods are replaced

Setting `maxUnavailable: 0` means "never have fewer Pods than desired" — the safest but slowest option.

</details>

<details>
<summary>Hint 5: Gateway API Pods not starting</summary>

If Contour Pods are not ready, check the namespace:

```bash
kubectl get pods -n projectcontour
```

Gateway API CRDs must be installed before Contour:

```bash
kubectl get crds | grep gateway
```

You should see `gatewayclasses.gateway.networking.k8s.io`, `gateways.gateway.networking.k8s.io`, and `httproutes.gateway.networking.k8s.io`.

</details>

<details>
<summary>Hint 6: kubectl-convert not found</summary>

`kubectl-convert` is a separate plugin, not built into kubectl. Install it via:

**Krew (recommended):**

```bash
kubectl krew install convert
```

**Direct download:**

```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl-convert"
chmod +x kubectl-convert
sudo mv kubectl-convert /usr/local/bin/
```

If you can't install it, manually convert manifests by referencing the [Kubernetes Deprecated API Migration Guide](https://kubernetes.io/docs/reference/using-api/deprecation-guide/).

</details>

## Learning Resources

- [Kubernetes Deployments — strategies](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#strategy)
- [Rolling Update tutorial](https://kubernetes.io/docs/tutorials/kubernetes-basics/update/update-intro/)
- [NGINX Ingress Controller — Canary annotations](https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/#canary)
- [Gateway API — HTTPRoute traffic splitting](https://gateway-api.sigs.k8s.io/guides/traffic-splitting/)
- [Gateway API — HTTPRoute reference](https://gateway-api.sigs.k8s.io/reference/spec/#gateway.networking.k8s.io/v1.HTTPRoute)
- [Kubernetes Deprecated API Migration Guide](https://kubernetes.io/docs/reference/using-api/deprecation-guide/)
- [kubectl-convert plugin](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/#install-kubectl-convert-plugin)
- [CKAD Curriculum — Deployment strategies](https://github.com/cncf/curriculum)

## Break & Fix 🔧

Try each scenario, diagnose the problem, and fix it.

### Scenario 1 — Blue/Green switch didn't work

Apply this Service and both Deployments from Task 1:

```yaml
# Save as broken-bg-svc.yaml
apiVersion: v1
kind: Service
metadata:
  name: broken-bg-svc
spec:
  selector:
    app: webapp
    version: teal
  ports:
    - port: 80
      targetPort: 5678
```

```bash
kubectl apply -f blue-green.yaml
kubectl apply -f broken-bg-svc.yaml
kubectl run curl-test --image=curlimages/curl --restart=Never --rm -it -- curl -s --max-time 5 http://broken-bg-svc
```

**What you'll see:** The curl times out or returns a connection refused error.

**Diagnose:**

```bash
kubectl get endpoints broken-bg-svc
kubectl describe svc broken-bg-svc
```

The Endpoints list is empty — no Pods match the selector.

**Root cause:** The Service selector uses `version: teal`, but neither Deployment has that label. Blue uses `version: blue`, green uses `version: green`.

**Fix:** Patch the selector to an actual version:

```bash
kubectl patch svc broken-bg-svc -p '{"spec":{"selector":{"version":"blue"}}}'
```

**Linux analogy:** It's like configuring a VIP to point to a backend server pool that doesn't exist — no servers answer health checks, so the load balancer has nowhere to send traffic.

**Clean up:**

```bash
kubectl delete svc broken-bg-svc
```

---

### Scenario 2 — Canary Ingress sends 100% to canary instead of 20%

Apply the canary app and this Ingress:

```yaml
# Save as broken-canary-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: broken-canary
  annotations:
    nginx.ingress.kubernetes.io/canary-weight: "20"
spec:
  ingressClassName: nginx
  rules:
    - host: broken.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: myapp-canary
                port:
                  number: 80
```

```bash
kubectl apply -f canary-app.yaml
kubectl apply -f broken-canary-ingress.yaml

for i in $(seq 1 10); do
  curl -s -H "Host: broken.local" http://localhost:80
done
```

**What you'll see:** 100% of responses are `CANARY v2`, not the expected 20%.

**Diagnose:** Look at the annotations:

```bash
kubectl get ingress broken-canary -o yaml | grep -A5 annotations
```

**Root cause:** The `nginx.ingress.kubernetes.io/canary: "true"` annotation is **missing**. Without it, the `canary-weight` annotation is ignored and the Ingress acts as a standalone route — sending all traffic matching `broken.local` directly to the canary backend.

**Fix:** Add the missing canary annotation:

```bash
kubectl annotate ingress broken-canary nginx.ingress.kubernetes.io/canary="true"
```

But this still won't work correctly because there's no **main** Ingress for `broken.local`. The canary Ingress needs a corresponding stable Ingress to split traffic against.

**Clean up:**

```bash
kubectl delete ingress broken-canary
```

---

### Scenario 3 — Rolling update stuck in progress

Apply this Deployment:

```yaml
# Save as broken-rolling.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: broken-rolling
spec:
  replicas: 4
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: broken-rolling
  template:
    metadata:
      labels:
        app: broken-rolling
    spec:
      containers:
        - name: app
          image: nginx:1.27
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 3
```

```bash
kubectl apply -f broken-rolling.yaml
kubectl rollout status deployment broken-rolling --timeout=60s

# Trigger an update
kubectl set image deployment/broken-rolling app=nginx:1.28
kubectl rollout status deployment/broken-rolling --timeout=60s
```

**What you'll see:** The rollout hangs. New Pods are created but never become Ready.

**Diagnose:**

```bash
kubectl get pods -l app=broken-rolling
kubectl describe pod -l app=broken-rolling | grep -A5 "Readiness"
```

**Root cause:** The `readinessProbe` checks port `8080` at path `/healthz`, but nginx listens on port `80` and doesn't have a `/healthz` endpoint. The new Pods never pass their readiness check, so with `maxUnavailable: 0`, Kubernetes cannot terminate any old Pods — the rollout is stuck.

**Fix:** Correct the readiness probe to match the actual application:

```bash
kubectl patch deployment broken-rolling --type=json -p '[
  {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/port","value":80},
  {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/"}
]'
```

**Linux analogy:** It's like having a load balancer health check pinging the wrong port — the new servers never enter the pool, so the LB keeps all traffic on the old servers.

**Clean up:**

```bash
kubectl delete deployment broken-rolling
```
