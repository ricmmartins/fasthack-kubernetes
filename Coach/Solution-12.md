# Solution 12 — Observability

[< Back to Challenge](../Student/Challenge-12.md) | **[Home](README.md)**

---

## Task 1: Container Logs with `kubectl logs`

### Step-by-step

**1a.** Deploy the multi-container logging Pod:

```yaml
# Save as logging-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: logging-demo
  labels:
    app: logging-demo
spec:
  containers:
    - name: webapp
      image: busybox:stable
      command: ["/bin/sh", "-c"]
      args:
        - |
          i=0
          while true; do
            echo "[webapp] Request $i handled successfully"
            i=$((i+1))
            sleep 2
          done
    - name: sidecar
      image: busybox:stable
      command: ["/bin/sh", "-c"]
      args:
        - |
          while true; do
            echo "[sidecar] Health check passed at $(date)"
            sleep 5
          done
```

```bash
kubectl apply -f logging-pod.yaml
kubectl wait --for=condition=Ready pod/logging-demo --timeout=60s
```

**1b.** Practice every log retrieval pattern:

```bash
# Single container
kubectl logs pod/logging-demo -c webapp
```

Expected output:

```
[webapp] Request 0 handled successfully
[webapp] Request 1 handled successfully
[webapp] Request 2 handled successfully
...
```

```bash
# Follow mode — like tail -f
kubectl logs -f pod/logging-demo -c webapp
# Press Ctrl+C to stop

# All containers in a Pod
kubectl logs pod/logging-demo --all-containers=true

# Last 10 lines only
kubectl logs pod/logging-demo -c webapp --tail=10

# Logs from the last 30 seconds
kubectl logs pod/logging-demo -c webapp --since=30s
```

```bash
# Logs from a Deployment (picks one Pod automatically)
kubectl create deployment nginx-log-test --image=nginx:stable --replicas=2
kubectl logs deployment/nginx-log-test
```

**1c.** View previous container logs (critical for debugging crashes):

```bash
# Force the webapp container to crash
kubectl exec logging-demo -c webapp -- /bin/sh -c "kill 1"

# Wait a moment for the container to restart
sleep 5

# View previous (crashed) instance logs
kubectl logs pod/logging-demo -c webapp --previous
```

Expected: You see the log output from the **terminated** container instance — this is like reading a rotated log file.

### Verification

```bash
# Confirm the container restarted
kubectl get pod logging-demo
```

Expected: `RESTARTS` count ≥ 1, status `Running`.

> **Coach tip:** The `--previous` flag is the #1 most useful debugging tool for CrashLoopBackOff. Make sure students understand this — it retrieves logs from the last terminated container instance.

---

## Task 2: Resource Metrics with `kubectl top`

### Step-by-step

Verify Metrics Server is running (installed in Challenge 10):

```bash
kubectl -n kube-system get pods -l k8s-app=metrics-server
```

Expected: A `metrics-server-xxxx` pod in `Running` state.

If Metrics Server is NOT running, install and patch it for Kind:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl patch -n kube-system deployment metrics-server \
  --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl -n kube-system rollout status deployment metrics-server
```

> **Why the patch?** Kind uses self-signed kubelet certificates. Without `--kubelet-insecure-tls`, Metrics Server refuses to scrape and `kubectl top` fails.

Now run metrics commands:

```bash
# Node-level metrics — like running top on each server
kubectl top nodes
```

Expected output:

```
NAME                     CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
fasthack-control-plane   150m         7%     1200Mi          30%
```

```bash
# Pod-level metrics
kubectl top pods -A

# Sort by CPU
kubectl top pods -A --sort-by=cpu

# Sort by memory
kubectl top pods -A --sort-by=memory

# Specific namespace
kubectl top pods -n kube-system
```

### Verification

```bash
kubectl top nodes && kubectl top pods -A --sort-by=memory | head -10
```

Both commands should return data without errors.

> **Coach tip:** If `kubectl top` returns `error: Metrics API not available`, the Metrics Server either isn't installed or failed to start. Check logs: `kubectl -n kube-system logs deployment/metrics-server --tail=20`. The most common issue on Kind is the missing `--kubelet-insecure-tls` flag.

---

## Task 3: Deploy Prometheus and Grafana with Helm

### Step-by-step

**3a.** Add the Helm repo and install:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --wait --timeout 5m
```

> **Why the two `--set` flags?** They tell Prometheus to discover **all** ServiceMonitors and PodMonitors in the cluster, not just those labeled with the Helm release. Without them, Prometheus misses monitors created outside the Helm release.

**3b.** Verify everything is running:

```bash
kubectl -n monitoring get pods
```

Expected output (names will vary):

```
NAME                                                      READY   STATUS    RESTARTS   AGE
alertmanager-kube-prometheus-stack-alertmanager-0          2/2     Running   0          2m
kube-prometheus-stack-grafana-xxxxxxxxx-xxxxx              3/3     Running   0          2m
kube-prometheus-stack-kube-state-metrics-xxxxxxxxx-xxxxx   1/1     Running   0          2m
kube-prometheus-stack-operator-xxxxxxxxx-xxxxx             1/1     Running   0          2m
kube-prometheus-stack-prometheus-node-exporter-xxxxx       1/1     Running   0          2m
prometheus-kube-prometheus-stack-prometheus-0              2/2     Running   0          2m
```

All pods should be `Running`. This may take 2-5 minutes on Kind.

**3c.** Retrieve the Grafana admin password:

```bash
kubectl -n monitoring get secret kube-prometheus-stack-grafana \
  -o jsonpath="{.data.admin-password}" | base64 --decode; echo
```

Expected output:

```
prom-operator
```

Username is `admin`.

**3d.** Access Grafana via port-forward:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

Open [http://localhost:3000](http://localhost:3000) and log in with `admin` / `prom-operator`.

### Verification

- Grafana login page loads at localhost:3000
- Login succeeds with `admin` / `prom-operator`
- Dashboards menu shows pre-configured dashboards

> **Coach tip:** If pods are stuck in `Pending`, it's likely resource pressure on the Kind node. Check `kubectl -n monitoring describe pod <name>` for scheduling failures. You can reduce requests with `helm upgrade ... --set prometheus.prometheusSpec.resources.requests.memory=256Mi --reuse-values`.

---

## Task 4: Explore Built-in Grafana Dashboards

### Step-by-step

**4a.** In Grafana, navigate to **Dashboards** → **Browse**. Look for these dashboards:

- **Kubernetes / Compute Resources / Cluster** — overall CPU and memory usage
- **Kubernetes / Compute Resources / Namespace (Pods)** — per-namespace breakdown
- **Kubernetes / Compute Resources / Pod** — drill into a specific Pod
- **Node Exporter / Nodes** — node-level OS metrics (like `sar` on Linux)
- **CoreDNS** — DNS query rates and latency

**4b.** Generate load to see dashboards populate:

```bash
# Create a CPU load generator
kubectl run metrics-load --image=busybox:stable --restart=Never \
  -- /bin/sh -c "while true; do echo 'working'; done"
```

Watch the **Kubernetes / Compute Resources / Cluster** dashboard — CPU usage should climb.

```bash
# Clean up when done observing
kubectl delete pod metrics-load
```

**4c.** (Optional) Access Prometheus UI directly:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

Open [http://localhost:9090](http://localhost:9090) → **Status → Targets** to see what Prometheus is scraping.

### Verification

- At least 2 Grafana dashboards show real data (CPU, memory graphs)
- Prometheus Targets page shows healthy scrape targets (green "UP" status)

> **Coach tip:** Students often struggle to find dashboards. In newer Grafana versions, navigate to the hamburger menu → Dashboards. The pre-installed dashboards are in a "General" folder or searchable by name.

---

## Task 5: The Three Pillars — Logs, Metrics, Traces

This is a conceptual checkpoint. Ensure students can explain:

| Pillar | Question it answers | Kubernetes tools | Linux analogy |
|---|---|---|---|
| **Logs** | What discrete events happened? | `kubectl logs`, Fluentd/Fluent Bit, Loki | `journalctl`, `/var/log`, rsyslog |
| **Metrics** | How are numeric indicators trending? | Metrics Server, Prometheus, Grafana | `sar`, `vmstat`, `top`, collectd |
| **Traces** | How does a request flow across services? | OpenTelemetry, Jaeger, Zipkin | `strace`, application APM agents |

> **Coach tip:** Traces are concept-only in this lab. No hands-on tracing setup is required. The key point is understanding where tracing fits — it answers "where did the time go?" for a single request across multiple microservices.

---

## Task 6: Liveness, Readiness, and Startup Probes

### Step-by-step

**6a.** Deploy a Pod with all three probes:

```yaml
# Save as probed-app.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: probed-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: probed-app
  template:
    metadata:
      labels:
        app: probed-app
    spec:
      containers:
        - name: webapp
          image: nginx:stable
          ports:
            - containerPort: 80
          startupProbe:
            httpGet:
              path: /
              port: 80
            failureThreshold: 30
            periodSeconds: 2
          livenessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 0
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 0
            periodSeconds: 5
            failureThreshold: 3
---
apiVersion: v1
kind: Service
metadata:
  name: probed-app
spec:
  selector:
    app: probed-app
  ports:
    - port: 80
      targetPort: 80
```

```bash
kubectl apply -f probed-app.yaml
kubectl rollout status deployment probed-app
```

**6b.** Verify the probes are configured:

```bash
kubectl describe pod -l app=probed-app | grep -A 5 "Liveness\|Readiness\|Startup"
```

Expected: All three probes listed with their HTTP GET paths and timing parameters.

**6c.** Observe liveness probe failure — simulate a stuck process:

```bash
# Delete the default nginx page to make the liveness probe fail
POD_NAME=$(kubectl get pods -l app=probed-app -o jsonpath='{.items[0].metadata.name}')
kubectl exec "$POD_NAME" -- rm /usr/share/nginx/html/index.html

# Watch the Pod — liveness probe will fail and restart the container
kubectl get pods -l app=probed-app --watch
```

Expected: Within ~30 seconds, `RESTARTS` count increases. The probe returned 404 (not 2xx), Kubernetes killed and restarted the container, which restored the default `index.html`.

```bash
# Check events for proof
kubectl describe pod "$POD_NAME" | tail -20
```

Expected events:

```
Warning  Unhealthy  Liveness probe failed: HTTP probe failed with statuscode: 404
Normal   Killing    Container webapp failed liveness probe, will be restarted
```

**6d.** Observe readiness probe failure:

```yaml
# Save as unready-app.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: unready-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: unready-app
  template:
    metadata:
      labels:
        app: unready-app
    spec:
      containers:
        - name: webapp
          image: nginx:stable
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /ready
              port: 80
            periodSeconds: 5
            failureThreshold: 1
---
apiVersion: v1
kind: Service
metadata:
  name: unready-app
spec:
  selector:
    app: unready-app
  ports:
    - port: 80
      targetPort: 80
```

```bash
kubectl apply -f unready-app.yaml
sleep 10
kubectl get pods -l app=unready-app
```

Expected: Pod shows `0/1 READY` — the `/ready` path doesn't exist in nginx, so the readiness probe fails. The Pod stays running but receives **no traffic**.

```bash
kubectl get endpoints unready-app
```

Expected: `ENDPOINTS: <none>` — the Service has zero backends.

### Verification

- Probed-app: container restarted after liveness failure (RESTARTS ≥ 1)
- Unready-app: Pod is `0/1 READY`, endpoints list is empty
- Students can explain: liveness → restart, readiness → remove from endpoints, startup → gate liveness/readiness

> **Coach tip:** The key mental model:
> - **Startup probe** = "Is it done booting?" (gates the other probes)
> - **Liveness probe** = "Is it still alive?" (like systemd Restart=always)
> - **Readiness probe** = "Can it serve traffic?" (like Nagios health check driving LB)

---

## Cleanup

```bash
kubectl delete -f logging-pod.yaml 2>/dev/null
kubectl delete deployment nginx-log-test 2>/dev/null
kubectl delete -f probed-app.yaml 2>/dev/null
kubectl delete -f unready-app.yaml 2>/dev/null
kubectl delete pod metrics-load 2>/dev/null
# Keep kube-prometheus-stack installed for later challenges
# To remove later: helm uninstall kube-prometheus-stack -n monitoring
```

---

## Common Issues

| Problem | Cause | Fix |
|---------|-------|-----|
| `kubectl top` returns "Metrics API not available" | Metrics Server not installed or not running | Install and patch for Kind with `--kubelet-insecure-tls` (see Task 2) |
| kube-prometheus-stack pods stuck in `Pending` | Insufficient resources on Kind node | Reduce resource requests via `helm upgrade ... --set prometheus.prometheusSpec.resources.requests.memory=256Mi --reuse-values` |
| Grafana port-forward disconnects | Idle timeout or Pod restart | Re-run the `kubectl port-forward` command |
| Can't find dashboards in Grafana | UI navigation changed in newer versions | Use the search bar (magnifying glass) and type "Kubernetes" |
| `--previous` flag returns "previous terminated container not found" | Container hasn't crashed yet | Force a crash first with `kubectl exec <pod> -- kill 1`, wait, then retry |
| Helm install times out | The `--wait` flag waits for all pods to be Ready; resource-heavy on Kind | Add `--timeout 10m` or remove `--wait` and manually verify |
