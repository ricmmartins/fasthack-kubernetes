# Challenge 12 — Observability

[< Previous Challenge](Challenge-11.md) | **[Home](../README.md)** | [Next Challenge >](Challenge-13.md)

## Introduction

On a Linux server you already know the observability toolkit: `journalctl -u nginx` to read service logs, `tail -f /var/log/syslog` to follow them in real time, `top` or `htop` for CPU and memory usage, `sar` and `vmstat` for historical metrics, and Nagios or Zabbix for health-check alerts. Your application writes to stdout/stderr (or to files under `/var/log`), systemd watches your process and restarts it if it dies, and you wire up Grafana or Cacti against Prometheus or collectd to get dashboards.

Kubernetes follows the **exact same three-pillar model** — Logs, Metrics, and Traces — but replaces the Linux-specific tools with cluster-aware equivalents:

| Pillar | What it answers | Linux tool | Kubernetes tool |
|---|---|---|---|
| **Logs** | "What happened?" | `journalctl`, `tail -f`, `/var/log` | `kubectl logs`, container stdout/stderr |
| **Metrics** | "How is it performing?" | `top`, `sar`, `vmstat`, Prometheus on bare-metal | `kubectl top`, Metrics Server, Prometheus |
| **Traces** | "Where did time go across services?" | `strace`, application-level tracing | OpenTelemetry, Jaeger (concept only in this lab) |

In addition, Linux uses **systemd watchdogs** and **Nagios health checks** to know if a process is alive and healthy. Kubernetes replaces those with **Liveness, Readiness, and Startup Probes** — built-in health checks that run inside the cluster and drive automated restart and traffic decisions.

In this challenge you will collect logs, inspect resource metrics, deploy a full monitoring stack (Prometheus + Grafana), and configure health probes — all on your local Kind cluster.

> **Cluster requirement:** All exercises use a local [Kind](https://kind.sigs.k8s.io/) cluster — no cloud account needed. If you haven't created one yet, run:
> ```bash
> kind create cluster --name fasthack
> ```

## Description

### Task 1 — Container logs with `kubectl logs`

Container logs in Kubernetes are the equivalent of `journalctl` and `/var/log` on Linux. Every container's stdout and stderr are captured by the kubelet and made available through the API.

**1a.** Deploy a multi-container Pod to practice with:

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
# Single container (when Pod has only one container, or specify -c)
kubectl logs pod/logging-demo -c webapp

# Follow mode — like tail -f /var/log/syslog
kubectl logs -f pod/logging-demo -c webapp

# Press Ctrl+C to stop following

# All containers in a Pod
kubectl logs pod/logging-demo --all-containers=true

# Last 10 lines only — like tail -n 10
kubectl logs pod/logging-demo -c webapp --tail=10

# Logs from the last 30 seconds
kubectl logs pod/logging-demo -c webapp --since=30s

# Logs from a Deployment (picks one Pod)
kubectl create deployment nginx-log-test --image=nginx:stable --replicas=2
kubectl logs deployment/nginx-log-test
```

**1c.** View **previous container** logs (critical for debugging crashes):

```bash
# Force the webapp container to restart by killing the Pod
kubectl delete pod logging-demo
kubectl apply -f logging-pod.yaml
kubectl wait --for=condition=Ready pod/logging-demo --timeout=60s

# Simulate a crash — exec into the container and exit with error
kubectl exec logging-demo -c webapp -- /bin/sh -c "kill 1"

# Wait a moment for the container to restart, then view previous logs
sleep 5
kubectl logs pod/logging-demo -c webapp --previous
```

The `--previous` flag retrieves logs from the **last terminated instance** of the container — like reading a rotated log file on Linux.

### Task 2 — Resource metrics with `kubectl top`

The `kubectl top` command is the Kubernetes equivalent of `top` / `htop`. It requires the **Metrics Server** you installed in Challenge 10.

```bash
# Verify Metrics Server is running (installed in Challenge 10)
kubectl -n kube-system get pods -l k8s-app=metrics-server

# Node-level metrics — like running top on each server
kubectl top nodes

# Pod-level metrics — like ps aux sorted by CPU
kubectl top pods -A

# Sort by CPU usage
kubectl top pods -A --sort-by=cpu

# Sort by memory
kubectl top pods -A --sort-by=memory

# Specific namespace
kubectl top pods -n kube-system
```

> **If `kubectl top` returns an error:** Make sure Metrics Server is installed and patched for Kind. Refer to Challenge 10, Task 1, or run:
> ```bash
> kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
> kubectl patch -n kube-system deployment metrics-server \
>   --type=json \
>   -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
> kubectl -n kube-system rollout status deployment metrics-server
> ```

### Task 3 — Deploy Prometheus and Grafana with Helm

On Linux, you might install Prometheus from a tarball and configure Grafana manually. In Kubernetes, the **kube-prometheus-stack** Helm chart bundles everything: Prometheus, Grafana, Alertmanager, node-exporter, and kube-state-metrics — with pre-built dashboards.

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

> The two `--set` flags tell Prometheus to discover **all** ServiceMonitors and PodMonitors in the cluster, not just those with the Helm release label. This is important for Task 7 (Break & Fix Scenario 3).

**3b.** Verify everything is running:

```bash
kubectl -n monitoring get pods
```

You should see Pods for: `prometheus-kube-prometheus-stack-prometheus-0`, `kube-prometheus-stack-grafana-*`, `alertmanager-*`, `kube-prometheus-stack-kube-state-metrics-*`, `kube-prometheus-stack-prometheus-node-exporter-*`, and the `kube-prometheus-stack-operator-*`.

**3c.** Retrieve the Grafana admin password:

```bash
kubectl -n monitoring get secret kube-prometheus-stack-grafana \
  -o jsonpath="{.data.admin-password}" | base64 --decode; echo
```

The default username is `admin`.

**3d.** Access Grafana via port-forward:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

Open [http://localhost:3000](http://localhost:3000) in your browser and log in with the credentials above.

### Task 4 — Explore built-in Grafana dashboards

The kube-prometheus-stack ships with dozens of pre-configured dashboards.

**4a.** In Grafana, navigate to **Dashboards** (left sidebar) → **Browse**. Look for these dashboards:

- **Kubernetes / Compute Resources / Cluster** — overall CPU and memory usage
- **Kubernetes / Compute Resources / Namespace (Pods)** — per-namespace breakdown
- **Kubernetes / Compute Resources / Pod** — drill into a specific Pod
- **Node Exporter / Nodes** — node-level OS metrics (like `sar` on Linux)
- **CoreDNS** — DNS query rates and latency

**4b.** Generate some cluster activity to see the dashboards populate:

```bash
# In a separate terminal, create a load generator
kubectl run metrics-load --image=busybox:stable --restart=Never \
  -- /bin/sh -c "while true; do echo 'working'; done"
```

Watch the **Kubernetes / Compute Resources / Cluster** dashboard — you should see CPU usage climb.

```bash
# Clean up the load generator when done observing
kubectl delete pod metrics-load
```

**4c.** (Optional) Access the Prometheus UI directly:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

Open [http://localhost:9090](http://localhost:9090), go to **Status → Targets** to see what Prometheus is scraping. This is analogous to checking that your Nagios NRPE agents are all reporting in.

### Task 5 — The three pillars: Logs, Metrics, Traces

Before moving on, make sure you understand the conceptual framework:

| Pillar | Question it answers | Kubernetes tools | Linux analogy |
|---|---|---|---|
| **Logs** | What discrete events happened? | `kubectl logs`, Fluentd/Fluent Bit, Loki | `journalctl`, `/var/log`, rsyslog |
| **Metrics** | How are numeric indicators trending over time? | Metrics Server, Prometheus, Grafana | `sar`, `vmstat`, `top`, collectd |
| **Traces** | How does a single request flow across services? | OpenTelemetry, Jaeger, Zipkin | `strace`, application APM agents |

> **Note:** Distributed tracing (Jaeger/OpenTelemetry) is a concept-only topic in this challenge. Setting up a full tracing pipeline is beyond the scope of this lab, but you should understand where it fits in the observability picture.

### Task 6 — Liveness, Readiness, and Startup Probes

On Linux, `systemd` restarts a crashed process and Nagios checks if a service is healthy. Kubernetes uses **probes** for the same purpose:

| Probe | Purpose | Linux analogy | What happens on failure |
|---|---|---|---|
| **Liveness** | Is the container process alive? | systemd `Restart=always` | Container is killed and restarted |
| **Readiness** | Can the container serve traffic? | Nagios/Zabbix health check | Pod removed from Service endpoints (no traffic) |
| **Startup** | Has the container finished starting? | systemd `ExecStartPre` check | Liveness/readiness probes are paused until startup succeeds |

**6a.** Deploy a Pod with all three probes configured:

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

**6b.** Verify the probes are working:

```bash
kubectl describe pod -l app=probed-app | grep -A 5 "Liveness\|Readiness\|Startup"
```

**6c.** Observe **liveness probe behavior** — simulate a stuck process:

```bash
# Exec into the Pod and delete the default nginx page
POD_NAME=$(kubectl get pods -l app=probed-app -o jsonpath='{.items[0].metadata.name}')
kubectl exec "$POD_NAME" -- rm /usr/share/nginx/html/index.html

# Watch the Pod — liveness probe will fail and restart the container
kubectl get pods -l app=probed-app --watch
```

Within 30 seconds you should see the `RESTARTS` count increase. The liveness probe returned a 404, Kubernetes killed the container, and the restart restored the default `index.html`.

```bash
# Check events for proof
kubectl describe pod "$POD_NAME" | grep -A 5 "Events"
```

**6d.** Observe **readiness probe behavior** — the Pod stays running but stops receiving traffic:

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

The Pod will show `0/1 READY` because `/ready` does not exist in the default nginx image (returns 404). The Pod is running but the Service has **zero endpoints**:

```bash
kubectl get endpoints unready-app
```

The endpoints list will be empty — no traffic reaches this Pod. This is the Kubernetes equivalent of a Nagios check marking a server as "down" so the load balancer stops routing to it.

### Clean Up

```bash
kubectl delete -f logging-pod.yaml 2>/dev/null
kubectl delete deployment nginx-log-test 2>/dev/null
kubectl delete -f probed-app.yaml 2>/dev/null
kubectl delete -f unready-app.yaml 2>/dev/null
kubectl delete pod metrics-load 2>/dev/null
# Keep kube-prometheus-stack installed — you'll use it in later challenges
# To remove it later: helm uninstall kube-prometheus-stack -n monitoring
```

## Success Criteria

- [ ] You can retrieve logs from a single container, a specific container in a multi-container Pod, and from the previous (crashed) instance.
- [ ] You used `kubectl logs -f` to follow logs in real time (like `tail -f`).
- [ ] `kubectl top nodes` and `kubectl top pods` display CPU and memory metrics.
- [ ] Prometheus and Grafana are running in the `monitoring` namespace via the kube-prometheus-stack Helm chart.
- [ ] You logged into Grafana and viewed at least two built-in dashboards showing cluster health data.
- [ ] You can access the Prometheus UI and see healthy scrape targets under **Status → Targets**.
- [ ] You can explain the three pillars of observability (Logs, Metrics, Traces) and name a Kubernetes tool for each.
- [ ] You deployed a Pod with liveness, readiness, and startup probes and can explain what each one does.
- [ ] You observed a liveness probe failure cause a container restart.
- [ ] You observed a readiness probe failure cause a Pod to show `0/1 READY` and receive no traffic.

## Linux ↔ Kubernetes Reference

| Linux Concept | Kubernetes Equivalent | Notes |
|---|---|---|
| `journalctl -u nginx` | `kubectl logs deployment/webapp` | View logs for a specific workload |
| `tail -f /var/log/syslog` | `kubectl logs -f pod/webapp` | Follow logs in real time |
| `top` / `htop` | `kubectl top pods` | Real-time CPU and memory per Pod |
| `/var/log/*.log` | Container stdout/stderr | Containers should log to stdout; kubelet captures it |
| `nagios` / `zabbix` health checks | Liveness / Readiness Probes | Built-in health checks that drive restart and traffic decisions |
| `systemd` watchdog / `Restart=always` | Startup Probe + Liveness Probe | Startup probe gates the liveness probe during slow boots |
| `sar` / `vmstat` | Prometheus metrics | Time-series metrics collection and storage |
| Cacti / Grafana on Linux | Grafana dashboards in Kubernetes | Same tool, deployed as a Pod, pre-configured by Helm |

## Hints

<details>
<summary>Hint 1: Metrics Server must be healthy before kubectl top works</summary>

`kubectl top` depends on the Metrics Server (installed in Challenge 10). If it is not running, you'll get:

```
error: Metrics API not available
```

Check its status:

```bash
kubectl -n kube-system get pods -l k8s-app=metrics-server
kubectl -n kube-system logs deployment/metrics-server --tail=20
```

On Kind, the most common issue is missing `--kubelet-insecure-tls`. The Metrics Server can't verify the kubelet's self-signed certificate and refuses to scrape. Re-apply the patch from Challenge 10 if needed.

</details>

<details>
<summary>Hint 2: kube-prometheus-stack Pods stuck in Pending or CrashLoopBackOff</summary>

Kind clusters have limited resources. If Pods are stuck in `Pending`, check for resource pressure:

```bash
kubectl -n monitoring describe pod <pod-name> | grep -A 5 "Events"
kubectl top nodes
```

If the node is at capacity, you can reduce the stack's resource requests:

```bash
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set prometheus.prometheusSpec.resources.requests.memory=256Mi \
  --set prometheus.prometheusSpec.resources.requests.cpu=100m \
  --reuse-values
```

Also ensure your Kind cluster has enough memory allocated (at least 4 GB recommended for this challenge).

</details>

<details>
<summary>Hint 3: How to find the Grafana password</summary>

The Grafana admin password is stored in a Kubernetes Secret:

```bash
kubectl -n monitoring get secret kube-prometheus-stack-grafana \
  -o jsonpath="{.data.admin-password}" | base64 --decode; echo
```

Username is always `admin`. If you set a custom release name, replace `kube-prometheus-stack` with your release name.

</details>

<details>
<summary>Hint 4: Understanding probe timing parameters</summary>

Each probe has four timing knobs:

| Parameter | Default | Meaning |
|---|---|---|
| `initialDelaySeconds` | 0 | Seconds to wait after container starts before probing |
| `periodSeconds` | 10 | How often to probe |
| `failureThreshold` | 3 | How many consecutive failures before taking action |
| `timeoutSeconds` | 1 | How long to wait for a probe response |

The total time before Kubernetes takes action on failure is roughly:

```
initialDelaySeconds + (periodSeconds × failureThreshold)
```

For the liveness probe with defaults: `0 + (10 × 3) = 30 seconds` before the container is killed.

**Startup probes** use `failureThreshold × periodSeconds` as the total startup budget. In Task 6a: `30 × 2 = 60 seconds` for nginx to start before Kubernetes gives up.

</details>

<details>
<summary>Hint 5: Why use a Startup Probe?</summary>

Without a startup probe, the liveness probe starts immediately. If your application takes 60 seconds to boot (e.g., a Java app loading a large classpath), the liveness probe will kill it before it finishes starting — creating an infinite restart loop.

The startup probe **pauses** the liveness and readiness probes until it succeeds. Once the startup probe passes, Kubernetes switches to the liveness and readiness probes for ongoing health checking.

**Linux analogy:** It's like telling `systemd` to wait for `ExecStartPre` to succeed before starting the watchdog timer. You don't want the watchdog killing a process that's still initializing.

</details>

## Learning Resources

- [Logging Architecture — Kubernetes official docs](https://kubernetes.io/docs/concepts/cluster-administration/logging/)
- [kubectl logs reference](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_logs/)
- [Resource Metrics Pipeline (Metrics Server)](https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/)
- [Configure Liveness, Readiness and Startup Probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)
- [kube-prometheus-stack Helm chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Prometheus Operator — ServiceMonitor](https://prometheus-operator.dev/docs/developer/api-resources/servicemonitor/)
- [Grafana Documentation](https://grafana.com/docs/grafana/latest/)

## Break & Fix 🔧

Try each scenario, diagnose the problem, and fix it.

### Scenario 1 — Liveness probe wrong path → CrashLoopBackOff

Apply this Deployment — the liveness probe points to a path that does not exist:

```yaml
# Save as broken-liveness.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: broken-liveness
spec:
  replicas: 1
  selector:
    matchLabels:
      app: broken-liveness
  template:
    metadata:
      labels:
        app: broken-liveness
    spec:
      containers:
        - name: nginx
          image: nginx:stable
          ports:
            - containerPort: 80
          livenessProbe:
            httpGet:
              path: /healthzz
              port: 80
            initialDelaySeconds: 2
            periodSeconds: 3
            failureThreshold: 2
```

```bash
kubectl apply -f broken-liveness.yaml
```

**What you'll see:** After ~10 seconds the Pod enters a restart loop. Run:

```bash
kubectl get pods -l app=broken-liveness --watch
```

The `RESTARTS` count climbs rapidly and the status alternates between `Running` and `CrashLoopBackOff`.

**Diagnose:**

```bash
kubectl describe pod -l app=broken-liveness | grep -A 10 "Events"
```

Look for events like:

```
Unhealthy  Liveness probe failed: HTTP probe failed with statuscode: 404
Killing    Container nginx failed liveness probe, will be restarted
```

**Root cause:** The liveness probe path `/healthzz` does not exist. Nginx returns a 404, which is not a success (2xx). After 2 failures (`failureThreshold: 2`) every 3 seconds (`periodSeconds: 3`), Kubernetes kills the container.

**Fix:** Change the probe path to `/` (or any path nginx actually serves):

```bash
kubectl patch deployment broken-liveness --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/path","value":"/"}]'

kubectl rollout status deployment broken-liveness
kubectl get pods -l app=broken-liveness
```

The Pod should now be `Running` with `1/1 READY` and zero restarts.

**Linux analogy:** It's like configuring Nagios to check `http://localhost/healthzz` — if the endpoint doesn't exist, the health check always fails and Nagios marks the service as critical.

**Clean up:**

```bash
kubectl delete -f broken-liveness.yaml
```

---

### Scenario 2 — Readiness probe failing → 0/1 READY, no traffic

Apply this Deployment — the readiness probe checks a port that nothing listens on:

```yaml
# Save as broken-readiness.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: broken-readiness
spec:
  replicas: 2
  selector:
    matchLabels:
      app: broken-readiness
  template:
    metadata:
      labels:
        app: broken-readiness
    spec:
      containers:
        - name: nginx
          image: nginx:stable
          ports:
            - containerPort: 80
          readinessProbe:
            tcpSocket:
              port: 8081
            periodSeconds: 5
            failureThreshold: 1
---
apiVersion: v1
kind: Service
metadata:
  name: broken-readiness
spec:
  selector:
    app: broken-readiness
  ports:
    - port: 80
      targetPort: 80
```

```bash
kubectl apply -f broken-readiness.yaml
sleep 15
```

**What you'll see:** Both Pods show `Running` but `0/1 READY`:

```bash
kubectl get pods -l app=broken-readiness
```

```
NAME                                READY   STATUS    RESTARTS   AGE
broken-readiness-xxxx-aaaa          0/1     Running   0          20s
broken-readiness-xxxx-bbbb          0/1     Running   0          20s
```

**Diagnose:**

```bash
# The Service has zero endpoints — no Pod is receiving traffic
kubectl get endpoints broken-readiness

# Events show the readiness probe failing
kubectl describe pod -l app=broken-readiness | grep -A 5 "Readiness"
```

You'll see: `Readiness probe failed: dial tcp ...:8081: connect: connection refused`

**Root cause:** Nginx listens on port 80, but the readiness probe checks port 8081. The TCP connection is refused, so the probe fails. Kubernetes removes the Pod from the Service endpoints — it's running but **not receiving any traffic**.

**Fix:** Change the readiness probe to the correct port:

```bash
kubectl patch deployment broken-readiness --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/tcpSocket/port","value":80}]'

kubectl rollout status deployment broken-readiness
kubectl get pods -l app=broken-readiness
kubectl get endpoints broken-readiness
```

Now both Pods should show `1/1 READY` and the endpoints should list two IP addresses.

**Linux analogy:** It's like configuring a load balancer health check against port 8081 when your app is on port 80 — the LB marks all backends as down and the site goes offline, even though every backend process is running fine.

**Clean up:**

```bash
kubectl delete -f broken-readiness.yaml
```

---

### Scenario 3 — Prometheus can't scrape metrics (ServiceMonitor mismatch)

In this scenario you deploy an application that exposes Prometheus metrics, create a ServiceMonitor, but Prometheus never discovers the target.

**3a.** Deploy a simple metrics-exporting app:

```yaml
# Save as metrics-app.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: metrics-app
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: metrics-app
  template:
    metadata:
      labels:
        app: metrics-app
    spec:
      containers:
        - name: exporter
          image: quay.io/prometheus/node-exporter:latest
          ports:
            - containerPort: 9100
              name: metrics
---
apiVersion: v1
kind: Service
metadata:
  name: metrics-app
  namespace: default
  labels:
    app: metrics-app
spec:
  selector:
    app: metrics-app
  ports:
    - port: 9100
      targetPort: 9100
      name: metrics
```

```bash
kubectl apply -f metrics-app.yaml
kubectl rollout status deployment metrics-app
```

**3b.** Create a ServiceMonitor with a **wrong label selector**:

```yaml
# Save as broken-servicemonitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: metrics-app-monitor
  namespace: monitoring
spec:
  namespaceSelector:
    matchNames:
      - default
  selector:
    matchLabels:
      app: metrics-app-TYPO
  endpoints:
    - port: metrics
      interval: 15s
```

```bash
kubectl apply -f broken-servicemonitor.yaml
```

**What you'll see:** In the Prometheus UI ([http://localhost:9090](http://localhost:9090) via port-forward), go to **Status → Targets**. The `metrics-app` target does **not** appear. Prometheus has no idea this Service exists.

**Diagnose:**

```bash
# Check the ServiceMonitor's selector
kubectl -n monitoring get servicemonitor metrics-app-monitor -o yaml | grep -A 3 "selector"

# Compare with the Service's actual labels
kubectl get svc metrics-app --show-labels
```

The ServiceMonitor looks for `app: metrics-app-TYPO` but the Service has `app: metrics-app`.

**Root cause:** The ServiceMonitor `selector.matchLabels` does not match any Service labels. Prometheus Operator uses this selector to discover which Services to scrape — no match means no scrape target.

**Fix:** Correct the label in the ServiceMonitor:

```bash
kubectl -n monitoring patch servicemonitor metrics-app-monitor --type=json \
  -p '[{"op":"replace","path":"/spec/selector/matchLabels/app","value":"metrics-app"}]'
```

Wait 30–60 seconds, then check Prometheus **Status → Targets** again. The `metrics-app` target should now appear and show as `UP`.

**Linux analogy:** This is like misconfiguring a Nagios host definition — if the hostname in your `check_command` doesn't match any real host, Nagios never polls it and you think everything is fine because there are no alerts. The absence of data is itself a problem.

**Clean up:**

```bash
kubectl delete -f broken-servicemonitor.yaml
kubectl delete -f metrics-app.yaml
```
