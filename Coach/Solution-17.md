# Solution 17 — Advanced Deployment Strategies

[< Previous Solution](Solution-16.md) - **[Home](README.md)** - [Next Solution >](Solution-18.md)

---

> **Coach note:** This challenge covers five CKAD-relevant deployment patterns. Tasks 1 (Blue/Green), 4 (Rolling Update), and 5 (Recreate) work out of the box. Tasks 2 and 3 require installing NGINX Ingress Controller and Gateway API + Contour — help students if installation stalls. Task 6 (API deprecation) is conceptual with a hands-on exercise.

Estimated time: **60–75 minutes**

---

## Task 1: Blue/Green Deployment

### Step-by-step

Save `blue-green.yaml`:

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

Save `webapp-svc.yaml`:

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

Apply:

```bash
kubectl apply -f blue-green.yaml
kubectl apply -f webapp-svc.yaml
```

### Verification — Blue is active

```bash
kubectl get deployments -l app=webapp
```

Expected:

```
NAME           READY   UP-TO-DATE   AVAILABLE   AGE
webapp-blue    3/3     3            3           30s
webapp-green   3/3     3            3           30s
```

```bash
kubectl run curl-test --image=curlimages/curl --restart=Never --rm -it -- curl -s http://webapp-svc
```

Expected:

```
v1 - BLUE
```

Verify the Service endpoints point only to blue Pods:

```bash
kubectl get endpoints webapp-svc
```

Expected: 3 IP addresses, all matching blue Pods.

```bash
kubectl get pods -l app=webapp,version=blue -o wide
```

Cross-reference the IPs — they should match.

### Switch to Green

```bash
kubectl patch svc webapp-svc -p '{"spec":{"selector":{"version":"green"}}}'
```

### Verification — Green is active

```bash
kubectl run curl-test --image=curlimages/curl --restart=Never --rm -it -- curl -s http://webapp-svc
```

Expected:

```
v2 - GREEN
```

```bash
kubectl get endpoints webapp-svc
```

Expected: 3 IPs now matching green Pods.

### Rollback to Blue

```bash
kubectl patch svc webapp-svc -p '{"spec":{"selector":{"version":"blue"}}}'
kubectl run curl-test --image=curlimages/curl --restart=Never --rm -it -- curl -s http://webapp-svc
```

Expected: `v1 - BLUE` — instant rollback, no Pod recreation needed.

> **Coach tip:** Emphasize that rollback is instant because both Deployments are running. You're just changing which Pods the Service selects — no image pulls, no Pod scheduling. The trade-off is resource cost: you're running 2x the Pods.

---

## Task 2: Canary Deployment with NGINX Ingress Controller

### Step-by-step

**Install NGINX Ingress Controller (Kind-specific manifest):**

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
```

Wait for it:

```bash
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
```

Expected:

```
pod/ingress-nginx-controller-xxxxx condition met
```

> **Coach tip:** If the Kind cluster wasn't created with `extraPortMappings` for ports 80/443, the NGINX controller won't be accessible on localhost directly. In that case, use port-forward:
> ```bash
> kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80 &
> ```
> And test with `http://localhost:8080` instead.

**Create canary app resources:**

Save `canary-app.yaml`:

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

Save `canary-ingress.yaml`:

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

Apply everything:

```bash
kubectl apply -f canary-app.yaml
kubectl apply -f canary-ingress.yaml
```

### Verification

Check Ingress resources:

```bash
kubectl get ingress
```

Expected:

```
NAME           CLASS   HOSTS         ADDRESS     PORTS   AGE
myapp-canary   nginx   myapp.local   localhost   80      10s
myapp-main     nginx   myapp.local   localhost   80      10s
```

Verify the canary annotations:

```bash
kubectl describe ingress myapp-canary | grep -A5 Annotations
```

Expected:

```
Annotations:  nginx.ingress.kubernetes.io/canary: true
              nginx.ingress.kubernetes.io/canary-weight: 20
```

**Test the traffic split (20 requests):**

```bash
for i in $(seq 1 20); do
  curl -s -H "Host: myapp.local" http://localhost:80
done | sort | uniq -c
```

Expected output (approximate — randomness applies):

```
     16 STABLE v1
      4 CANARY v2
```

> **Coach tip:** The split won't be exact on small sample sizes. With 20 requests, students might see 14-18 stable and 2-6 canary. Run 100 requests for a closer match to 80/20.

**Increase canary weight to 50%:**

```bash
kubectl annotate ingress myapp-canary \
  nginx.ingress.kubernetes.io/canary-weight="50" --overwrite
```

Re-test:

```bash
for i in $(seq 1 20); do
  curl -s -H "Host: myapp.local" http://localhost:80
done | sort | uniq -c
```

Expected: roughly 10 STABLE / 10 CANARY.

**Full promotion — set weight to 100%:**

```bash
kubectl annotate ingress myapp-canary \
  nginx.ingress.kubernetes.io/canary-weight="100" --overwrite
```

Now 100% of traffic goes to canary. At this point you would:
1. Update the stable Deployment image to v2
2. Remove the canary Ingress and Deployment

---

## Task 3: Canary Deployment with Gateway API HTTPRoute

### Step-by-step

**Install Gateway API CRDs:**

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/latest/download/standard-install.yaml
```

Expected:

```
customresourcedefinition.apiextensions.k8s.io/gatewayclasses.gateway.networking.k8s.io created
customresourcedefinition.apiextensions.k8s.io/gateways.gateway.networking.k8s.io created
customresourcedefinition.apiextensions.k8s.io/httproutes.gateway.networking.k8s.io created
...
```

**Install Contour as the Gateway controller:**

```bash
kubectl apply -f https://projectcontour.io/quickstart/contour.yaml
```

Wait for Contour to be ready:

```bash
kubectl wait --namespace projectcontour \
  --for=condition=ready pod \
  --selector=app=contour \
  --timeout=120s
```

Expected:

```
pod/contour-xxxxx condition met
```

Verify the Envoy proxy is running:

```bash
kubectl get pods -n projectcontour
```

Expected: `contour-*` and `envoy-*` pods all Running.

**Create Gateway resources:**

Save `gateway.yaml`:

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

Save `canary-httproute.yaml`:

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

Apply:

```bash
kubectl apply -f gateway.yaml
kubectl apply -f canary-httproute.yaml
```

### Verification

Check Gateway status:

```bash
kubectl get gateway -n projectcontour
```

Expected:

```
NAME               CLASS     ADDRESS   PROGRAMMED   AGE
contour-gateway    contour             True         30s
```

Check HTTPRoute:

```bash
kubectl get httproute
```

Expected:

```
NAME                 HOSTNAMES          PARENTREFS                                AGE
myapp-canary-route   ["myapp.local"]    [{"name":"contour-gateway",...}]           10s
```

**Test traffic splitting through the Gateway:**

```bash
# Get the Envoy service port
ENVOY_PORT=$(kubectl get svc -n projectcontour envoy -o jsonpath='{.spec.ports[0].nodePort}')
echo "Envoy NodePort: ${ENVOY_PORT}"

# Send 20 requests
for i in $(seq 1 20); do
  curl -s -H "Host: myapp.local" http://localhost:${ENVOY_PORT}
done | sort | uniq -c
```

Expected (approximate):

```
     16 STABLE v1
      4 CANARY v2
```

> **Coach tip:** If NodePort isn't accessible, use port-forward:
> ```bash
> kubectl port-forward -n projectcontour svc/envoy 9080:80 &
> ```
> Then curl `http://localhost:9080`.

**Shift traffic fully to canary:**

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

Re-test — 100% should now be CANARY v2.

> **Coach tip — Ingress vs Gateway API:** Highlight the key difference:
> - Ingress uses **annotations** for traffic splitting — non-standard, controller-specific
> - Gateway API uses **native YAML fields** (`backendRefs[].weight`) — standardized across controllers
>
> Gateway API is the future; Ingress annotations are the established pattern. Students should know both.

---

## Task 4: Rolling Update Deep Dive

### Step-by-step

Save `rolling-deep.yaml`:

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

Apply:

```bash
kubectl apply -f rolling-deep.yaml
kubectl rollout status deployment rolling-app --timeout=120s
```

### Verification — Initial state

```bash
kubectl get deployment rolling-app
```

Expected:

```
NAME          READY   UP-TO-DATE   AVAILABLE   AGE
rolling-app   6/6     6            6           30s
```

### Trigger the rolling update

```bash
kubectl set image deployment/rolling-app app=nginx:1.28
```

**Watch the rollout in real time:**

```bash
kubectl rollout status deployment/rolling-app
```

Expected (scrolling output):

```
Waiting for deployment "rolling-app" rollout to finish: 2 out of 6 new replicas have been updated...
Waiting for deployment "rolling-app" rollout to finish: 3 out of 6 new replicas have been updated...
...
deployment "rolling-app" successfully rolled out
```

**Observe Pods during rollout** (run this in a separate terminal before triggering the update):

```bash
kubectl get pods -l app=rolling-app --watch
```

Students should see:
1. New Pods being created (surge — up to 8 total)
2. Old Pods being terminated (but never more than 1 at a time)
3. At no point do fewer than 5 Pods exist in Ready state

### Inspect rollout history

```bash
kubectl rollout history deployment/rolling-app
```

Expected:

```
REVISION  CHANGE-CAUSE
1         initial deployment v1
2         <none>
```

### Experiment with different configurations

**Fast rollout (aggressive):**

```bash
kubectl patch deployment rolling-app -p '{
  "spec": {"strategy": {"rollingUpdate": {"maxSurge": 3, "maxUnavailable": 2}}}
}'
kubectl set image deployment/rolling-app app=nginx:1.27
kubectl rollout status deployment/rolling-app
```

This is faster — up to 9 Pods at once, 4 minimum available. The rollout completes in fewer rounds.

**Slow, safe rollout (zero unavailable):**

```bash
kubectl patch deployment rolling-app -p '{
  "spec": {"strategy": {"rollingUpdate": {"maxSurge": 1, "maxUnavailable": 0}}}
}'
kubectl set image deployment/rolling-app app=nginx:1.28
kubectl rollout status deployment/rolling-app
```

This is the safest — always 6 available Pods, one new Pod at a time. Takes the longest.

> **Coach reference table:**
>
> | Config | Max Pods | Min Available | Speed | Safety |
> |---|---|---|---|---|
> | `maxSurge: 2, maxUnavailable: 1` | 8 | 5 | Medium | Medium |
> | `maxSurge: 3, maxUnavailable: 2` | 9 | 4 | Fast | Lower |
> | `maxSurge: 1, maxUnavailable: 0` | 7 | 6 | Slow | Highest |
> | `maxSurge: "50%", maxUnavailable: "25%"` | 9 | 4 | Fast | Medium |

---

## Task 5: Recreate Strategy

### Step-by-step

Save `recreate-app.yaml`:

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

Apply:

```bash
kubectl apply -f recreate-app.yaml
kubectl rollout status deployment recreate-app --timeout=60s
```

### Verification — Initial state

```bash
kubectl get pods -l app=recreate-app
```

Expected: 4 Pods, all `1/1 Running`.

### Trigger update and observe downtime

**In Terminal 1 — Watch Pods:**

```bash
kubectl get pods -l app=recreate-app --watch
```

**In Terminal 2 — Trigger the update:**

```bash
kubectl set image deployment/recreate-app app=nginx:1.28
```

**What students should see in Terminal 1:**

```
NAME                            READY   STATUS        RESTARTS   AGE
recreate-app-7c9d4f8b5-abc12   1/1     Terminating   0          2m
recreate-app-7c9d4f8b5-def34   1/1     Terminating   0          2m
recreate-app-7c9d4f8b5-ghi56   1/1     Terminating   0          2m
recreate-app-7c9d4f8b5-jkl78   1/1     Terminating   0          2m
recreate-app-7c9d4f8b5-abc12   0/1     Terminating   0          2m
...
(all Pods terminated — gap where zero Pods are running)
...
recreate-app-5f8c7d9a1-mno90   0/1     Pending       0          0s
recreate-app-5f8c7d9a1-pqr12   0/1     Pending       0          0s
recreate-app-5f8c7d9a1-stu34   0/1     Pending       0          0s
recreate-app-5f8c7d9a1-vwx56   0/1     Pending       0          0s
recreate-app-5f8c7d9a1-mno90   1/1     Running       0          3s
...
```

The key observation: **there is a gap where zero Pods are running**. This is the downtime window.

### Verify via Deployment events

```bash
kubectl describe deployment recreate-app | grep -A20 Events
```

Expected events:

```
Events:
  Type    Reason             Age   From                   Message
  ----    ------             ----  ----                   -------
  Normal  ScalingReplicaSet  2m    deployment-controller  Scaled down replica set recreate-app-7c9d4f8b5 to 0 from 4
  Normal  ScalingReplicaSet  1m    deployment-controller  Scaled up replica set recreate-app-5f8c7d9a1 to 4 from 0
```

Note: The old ReplicaSet scales to **0 first**, then the new ReplicaSet scales to 4. This confirms the downtime gap.

> **Coach tip:** Ask students: "When would you choose Recreate over RollingUpdate?" Good answers:
> - Database schema migrations where old and new code versions are incompatible
> - Singleton workloads that hold exclusive locks (e.g., a cron runner that must not have concurrent instances)
> - GPU workloads where only one Pod can claim the device
> - The app itself crashes when two versions run simultaneously

---

## Task 6: API Deprecation Handling

### Step-by-step

**Check available API versions:**

```bash
kubectl api-versions | sort
```

Students should see a list including `apps/v1`, `networking.k8s.io/v1`, etc. but **not** `extensions/v1beta1`.

**Create the legacy manifest:**

Save `old-ingress.yaml`:

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

**Try to apply it:**

```bash
kubectl apply -f old-ingress.yaml
```

Expected error:

```
error: resource mapping not found for name: "legacy-ingress" namespace: "" from "old-ingress.yaml": no matches for kind "Ingress" in version "extensions/v1beta1"
ensure CRDs are installed first
```

> **Coach tip:** This is exactly what happens when you upgrade a cluster and old API versions have been removed. The API server no longer recognizes `extensions/v1beta1`.

**Install kubectl-convert (if available):**

```bash
# Option 1: Via Krew
kubectl krew install convert

# Option 2: Direct download
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl-convert"
chmod +x kubectl-convert
sudo mv kubectl-convert /usr/local/bin/
```

**Convert the manifest:**

```bash
kubectl convert -f old-ingress.yaml --output-version networking.k8s.io/v1
```

Expected output (YAML with the new API version and updated field names).

> **Coach tip:** If `kubectl-convert` is not available or doesn't work in the lab environment, that's fine — the manual migration in the next step is the important learning outcome.

**Manual migration — create the updated manifest:**

Save `new-ingress.yaml`:

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

**Key changes to highlight:**

| Old (`extensions/v1beta1`) | New (`networking.k8s.io/v1`) |
|---|---|
| `apiVersion: extensions/v1beta1` | `apiVersion: networking.k8s.io/v1` |
| `backend.serviceName: legacy-svc` | `backend.service.name: legacy-svc` |
| `backend.servicePort: 80` | `backend.service.port.number: 80` |
| `pathType` not required | `pathType: Prefix` **required** |

**Explore other deprecation detection tools:**

```bash
# List all API resources with their preferred versions
kubectl api-resources -o wide | head -20

# Check the Kubernetes deprecation guide
echo "Reference: https://kubernetes.io/docs/reference/using-api/deprecation-guide/"
```

> **Coach tip:** Other tools for detecting deprecated APIs in production:
> - **kubent** (kube-no-trouble): Scans running clusters for deprecated APIs
> - **pluto**: Scans Helm releases and manifest files
> - **kubepug**: PreUpgrade checker for Kubernetes API deprecations
>
> These are good to mention but not required for this lab.

---

## Clean Up

```bash
# Task 1
kubectl delete -f blue-green.yaml 2>/dev/null
kubectl delete -f webapp-svc.yaml 2>/dev/null

# Task 2
kubectl delete -f canary-app.yaml 2>/dev/null
kubectl delete -f canary-ingress.yaml 2>/dev/null

# Task 3
kubectl delete -f canary-httproute.yaml 2>/dev/null
kubectl delete -f gateway.yaml 2>/dev/null

# Task 4
kubectl delete -f rolling-deep.yaml 2>/dev/null

# Task 5
kubectl delete -f recreate-app.yaml 2>/dev/null

# Task 6
kubectl delete -f old-ingress.yaml 2>/dev/null
kubectl delete -f new-ingress.yaml 2>/dev/null

# Break & Fix
kubectl delete -f broken-bg-svc.yaml 2>/dev/null
kubectl delete -f broken-canary-ingress.yaml 2>/dev/null
kubectl delete -f broken-rolling.yaml 2>/dev/null

# Optional: Remove NGINX Ingress Controller and Contour (only if not needed for other challenges)
# kubectl delete -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
# kubectl delete -f https://projectcontour.io/quickstart/contour.yaml
# kubectl delete -f https://github.com/kubernetes-sigs/gateway-api/releases/latest/download/standard-install.yaml
```

---

## Common Issues

| Problem | Cause | Fix |
|---------|-------|-----|
| `curl: (7) Failed to connect to localhost port 80` | Kind cluster not configured with port mappings for NGINX Ingress | Use `kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80` and curl `:8080` |
| Canary weight has no effect | Missing `canary: "true"` annotation | Add `nginx.ingress.kubernetes.io/canary: "true"` to the canary Ingress |
| 100% traffic goes to canary instead of 20% | No main Ingress exists for the same host | Create a non-canary Ingress for the same host pointing to the stable Service |
| Gateway API CRDs not found | CRDs not installed before Contour | Run `kubectl apply -f .../standard-install.yaml` first, then install Contour |
| Envoy service has no NodePort | Service type is ClusterIP by default | Use `kubectl port-forward -n projectcontour svc/envoy 9080:80` |
| Rolling update stuck at partial rollout | Readiness probe failing on new Pods | Check probe config: `kubectl describe pod <new-pod>`, fix probe port/path |
| `kubectl convert` not found | Plugin not installed | Install via Krew (`kubectl krew install convert`) or direct download |
| `extensions/v1beta1` rejected by API server | API version removed in K8s 1.22+ | Migrate manifest to `networking.k8s.io/v1` with updated field names |
| Blue/Green Service returns no response | Selector doesn't match any Pod labels | Check `kubectl get endpoints <svc>` — empty means no label match |
| HPA from Challenge 10 conflicts with manual replicas | HPA overrides `spec.replicas` on the Deployment | Delete HPA before manually managing replicas: `kubectl delete hpa <name>` |

## Strategy Decision Matrix (Coach Reference)

Use this table to help students choose the right strategy for different scenarios:

| Scenario | Best Strategy | Why |
|----------|--------------|-----|
| Zero-downtime web app upgrade | **RollingUpdate** | Gradual replacement, always available |
| Database migration with schema changes | **Recreate** | Can't run old+new code against different schemas |
| High-risk release, instant rollback needed | **Blue/Green** | Both versions running, switch is instant |
| Validating new version with real traffic | **Canary** | Small % of users test the new version |
| GPU workload (exclusive device access) | **Recreate** | Only one Pod can claim the GPU at a time |
| Gradual rollout with monitoring | **Canary → RollingUpdate** | Canary first (10%), then rolling update for the rest |
| Stateless API with good health checks | **RollingUpdate** (`maxUnavailable: 0`) | Safest rolling update — never fewer than desired Pods |
