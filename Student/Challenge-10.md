# Challenge 10 — Autoscaling

[< Previous Challenge](Challenge-09.md) | **[Home](../README.md)** | [Next Challenge >](Challenge-11.md)

## Introduction

On a Linux server, you watch system load with `top` or `htop` and react accordingly. If CPU spikes, you might spawn additional worker processes, resize the machine, or have a cron job that scales things up during business hours. All of these are forms of **autoscaling** — adjusting capacity to meet demand.

Kubernetes automates the same patterns:

| Strategy | Linux Equivalent | Kubernetes Equivalent |
|---|---|---|
| Add more worker processes | `fork()` / spawn more instances | **HPA** — Horizontal Pod Autoscaler |
| Give a process more CPU/RAM | Resize the VM or bump `ulimit` | **VPA** — Vertical Pod Autoscaler |
| Scale on an external signal (queue depth, cron) | Cron job + script that starts workers | **KEDA** — Event-Driven Autoscaler |

In this challenge you will install the **Metrics Server** on your Kind cluster (the equivalent of making `/proc/stat` and `/proc/meminfo` available to the cluster), create an HPA that automatically adjusts the number of Pod replicas based on CPU utilization, generate synthetic load to watch it scale up, and then observe the cool-down when load stops. You will also learn the concepts behind VPA and KEDA so you understand when to reach for each tool.

> **Cluster requirement:** All exercises use a local [Kind](https://kind.sigs.k8s.io/) cluster — no cloud account needed. If you haven't created one yet, run:
> ```bash
> kind create cluster --name fasthack
> ```

## Description

### Task 1 — Install Metrics Server on Kind

The HPA controller needs real-time CPU and memory metrics to make scaling decisions. On a Linux box this data comes from `/proc/stat`; in Kubernetes it comes from the **Metrics Server** API.

Install Metrics Server and patch it so it works on Kind (which uses self-signed kubelet certificates):

```bash
# Install Metrics Server
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Patch to accept Kind's self-signed kubelet certificates
kubectl patch -n kube-system deployment metrics-server \
  --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

Wait for the Metrics Server Pod to become `Running`, then verify it's collecting data:

```bash
kubectl -n kube-system rollout status deployment metrics-server
kubectl top nodes
kubectl top pods -A
```

You should see CPU and memory values — not errors. If `kubectl top` still fails, give Metrics Server another 30–60 seconds to collect its first scrape.

### Task 2 — Deploy a CPU-intensive application

Create a Deployment with an explicit CPU request (the HPA needs this to calculate utilization percentages). Save this as `php-apache.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: php-apache
spec:
  replicas: 1
  selector:
    matchLabels:
      app: php-apache
  template:
    metadata:
      labels:
        app: php-apache
    spec:
      containers:
        - name: php-apache
          image: registry.k8s.io/hpa-example
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 200m
            limits:
              cpu: 500m
---
apiVersion: v1
kind: Service
metadata:
  name: php-apache
spec:
  selector:
    app: php-apache
  ports:
    - port: 80
      targetPort: 80
```

Apply it:

```bash
kubectl apply -f php-apache.yaml
kubectl rollout status deployment php-apache
```

### Task 3 — Create an HPA targeting 50% CPU

Create a Horizontal Pod Autoscaler that keeps average CPU utilization at 50%, scaling between 1 and 10 replicas:

```bash
kubectl autoscale deployment php-apache \
  --cpu-percent=50 \
  --min=1 \
  --max=10
```

Verify the HPA was created and is reading metrics (not `<unknown>`):

```bash
kubectl get hpa php-apache
```

You should see something like:

```
NAME         REFERENCE               TARGETS   MINPODS   MAXPODS   REPLICAS   AGE
php-apache   Deployment/php-apache   0%/50%    1         10        1          30s
```

> **If you see `<unknown>/50%`:** Metrics Server is either not running or the Pod lacks a `resources.requests.cpu` field. See Break & Fix Scenario 1 below.

### Task 4 — Generate load and watch scale-up

Open a **second terminal** and start a load generator — a BusyBox Pod that hammers the Service in a tight loop:

```bash
kubectl run load-generator \
  --image=busybox:stable \
  --restart=Never \
  -- /bin/sh -c "while true; do wget -q -O- http://php-apache; done"
```

In your first terminal, watch the HPA react:

```bash
kubectl get hpa php-apache --watch
```

Within 1–2 minutes you should see the CPU target climb above 50% and the replica count increase. Also watch the Pods:

```bash
kubectl get pods -l app=php-apache --watch
```

### Task 5 — Stop load and observe scale-down

Delete the load generator:

```bash
kubectl delete pod load-generator
```

Keep watching the HPA. After the **stabilization window** (default 5 minutes for scale-down), the HPA will gradually reduce the replica count back toward 1.

```bash
kubectl get hpa php-apache --watch
```

> **Why does scale-down take so long?** The HPA has a default `--horizontal-pod-autoscaler-downscale-stabilization` window of 5 minutes. This prevents flapping — the same reason you'd add hysteresis to a monitoring alert on a Linux server.

### Task 6 — Explore the HPA manifest (YAML)

Export the HPA you created imperatively and study its structure:

```bash
kubectl get hpa php-apache -o yaml
```

Now create the equivalent HPA declaratively. Save this as `php-apache-hpa.yaml`:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: php-apache
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: php-apache
  minReplicas: 1
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 60
```

Apply it:

```bash
kubectl apply -f php-apache-hpa.yaml
```

Notice the `behavior.scaleDown.stabilizationWindowSeconds` — set to 60 seconds here for faster feedback in a lab environment. In production you would keep the default (300s) or tune it based on your workload's traffic pattern.

### Task 7 — Introduction to VPA (Vertical Pod Autoscaler)

The HPA adds or removes Pods (horizontal scaling). The **Vertical Pod Autoscaler (VPA)** adjusts `requests` and `limits` on existing Pods — like resizing a VM or changing `ulimit` values for a running process.

**When to use VPA instead of HPA:**

- Your workload cannot be scaled horizontally (e.g., a stateful singleton database).
- You don't know the right resource requests for a new application and want VPA to recommend values.
- You want to right-size Pods so they're not over- or under-provisioned.

> **Note:** VPA is not installed by default and is a separate project. You do **not** need to install it for this challenge — understanding the concept is sufficient. VPA and HPA should generally **not** target the same metric (CPU) on the same Deployment, as they can conflict.

Read the VPA README to understand its three modes:

| VPA Mode | Behavior |
|---|---|
| `Off` | Only recommends — does not change Pods |
| `Initial` | Sets requests/limits at Pod creation time only |
| `Auto` | Evicts and recreates Pods with updated requests/limits |

### Task 8 — Introduction to KEDA (Event-Driven Autoscaling)

**KEDA** (Kubernetes Event-Driven Autoscaling) extends the HPA to scale on signals beyond CPU and memory — like message queue depth, HTTP request rate, cron schedules, or Prometheus metrics.

**Linux analogy:** Imagine a cron job that checks a RabbitMQ queue every minute and spawns workers when messages pile up. KEDA does the same thing, but as a native Kubernetes controller.

KEDA uses **ScaledObject** resources that define:

- **What** to scale (a Deployment or Job)
- **What trigger** to watch (Prometheus, cron, Kafka, etc.)
- **When** to scale to zero (scale-to-zero is a key KEDA feature)

Example — a cron-based ScaledObject (cloud-agnostic):

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: cron-scaler
spec:
  scaleTargetRef:
    name: php-apache
  minReplicaCount: 0
  maxReplicaCount: 10
  triggers:
    - type: cron
      metadata:
        timezone: America/New_York
        start: "0 8 * * *"
        end: "0 18 * * *"
        desiredReplicas: "5"
```

This scales `php-apache` to 5 replicas during business hours and back to 0 outside of them — like a smarter cron job.

> **Note:** You do **not** need to install KEDA for this challenge. Understanding the concept and knowing when to use it is sufficient.

### Clean Up

```bash
kubectl delete -f php-apache.yaml
kubectl delete hpa php-apache 2>/dev/null
kubectl delete -f php-apache-hpa.yaml 2>/dev/null
kubectl delete pod load-generator 2>/dev/null
```

## Success Criteria

- [ ] Metrics Server is running on your Kind cluster and `kubectl top nodes` returns CPU/memory data.
- [ ] You deployed the `php-apache` application with explicit CPU `requests`.
- [ ] You created an HPA targeting 50% CPU utilization with min=1 and max=10 replicas.
- [ ] `kubectl get hpa` shows actual CPU percentage (not `<unknown>`).
- [ ] You generated load and observed the HPA scale the Deployment above 1 replica.
- [ ] After stopping load, you observed the HPA scale the Deployment back down.
- [ ] You can explain the difference between the `autoscaling/v2` YAML manifest and the imperative `kubectl autoscale` command.
- [ ] You can explain when you would use VPA instead of HPA.
- [ ] You can explain what KEDA does and give an example of an event-driven trigger.

## Linux ↔ Kubernetes Reference

| Linux Concept | Kubernetes Equivalent | Notes |
|---|---|---|
| `top` / `htop` | `kubectl top pods` | Real-time CPU and memory usage per Pod |
| `/proc/stat` (CPU counters) | Metrics Server API | The data source the HPA controller reads |
| `ulimit` (per-process limits) | `resources.requests` / `resources.limits` | Pod-level CPU and memory boundaries |
| Spawn workers based on load | HPA (Horizontal Pod Autoscaler) | Adds/removes Pod replicas automatically |
| Resize VM / add RAM | VPA (Vertical Pod Autoscaler) | Adjusts requests/limits on existing Pods |
| Cron + script to scale workers | KEDA (event-driven autoscaling) | Scales on queue depth, Prometheus, cron, etc. |
| `monit` / `supervisord` | HPA controller (kube-controller-manager) | The control loop that watches metrics and adjusts replicas |
| Load average → fork workers | `averageUtilization` threshold | HPA's target metric that triggers scaling |

## Hints

<details>
<summary>Hint 1: Metrics Server takes a minute to warm up</summary>

After installing Metrics Server and applying the `--kubelet-insecure-tls` patch, the Deployment will roll out a new Pod. Wait for it:

```bash
kubectl -n kube-system rollout status deployment metrics-server
```

Then give it 30–60 seconds before running `kubectl top`. The first scrape needs time to collect data from all kubelets.

If `kubectl top nodes` returns `error: metrics not available yet`, just wait and retry.

</details>

<details>
<summary>Hint 2: Why does the HPA show &lt;unknown&gt;?</summary>

The HPA calculates utilization as: `(current CPU usage) / (requested CPU)`.

If the target Pods have **no `resources.requests.cpu`** defined, the HPA cannot compute a percentage and shows `<unknown>`.

**Fix:** Add a `resources.requests.cpu` field to every container in the Deployment's Pod template. For this lab, `200m` (200 millicores) is a good starting value.

Also check that Metrics Server is healthy:

```bash
kubectl -n kube-system get pods -l k8s-app=metrics-server
kubectl top pods
```

</details>

<details>
<summary>Hint 3: Load generator isn't driving CPU high enough</summary>

Make sure the load generator is hitting the **Service name**, not a Pod IP:

```bash
kubectl run load-generator \
  --image=busybox:stable \
  --restart=Never \
  -- /bin/sh -c "while true; do wget -q -O- http://php-apache; done"
```

If `php-apache` Service doesn't exist, the wget requests will fail silently. Verify:

```bash
kubectl get svc php-apache
```

You can also run multiple load generators in parallel for faster results:

```bash
for i in 1 2 3; do
  kubectl run load-generator-$i \
    --image=busybox:stable \
    --restart=Never \
    -- /bin/sh -c "while true; do wget -q -O- http://php-apache; done"
done
```

</details>

<details>
<summary>Hint 4: Scale-down is slow — is that normal?</summary>

Yes. The HPA default stabilization window for scale-down is **5 minutes** (`--horizontal-pod-autoscaler-downscale-stabilization=5m0s`). This prevents the replica count from flapping if load fluctuates.

You can speed this up in a lab by setting `behavior.scaleDown.stabilizationWindowSeconds` in the HPA spec:

```yaml
behavior:
  scaleDown:
    stabilizationWindowSeconds: 30
```

In production, keep the default or increase it — premature scale-down can cause outages during bursty traffic.

</details>

<details>
<summary>Hint 5: Viewing HPA events and decisions</summary>

The HPA controller logs its scaling decisions as Kubernetes events. View them with:

```bash
kubectl describe hpa php-apache
```

Look at the **Conditions** and **Events** sections. You'll see entries like:

```
AbleToScale     True    ReadyForNewScale   recommended size matches current size
ScalingActive   True    ValidMetricFound   the HPA was able to successfully calculate a replica count
ScalingLimited  False   DesiredWithinRange  the desired count is within the acceptable range
```

This is the Kubernetes equivalent of reading system logs (`journalctl`) to understand why `monit` restarted a service.

</details>

## Learning Resources

- [Horizontal Pod Autoscaling — Kubernetes official docs](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)
- [HPA Walkthrough](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale-walkthrough/)
- [Metrics Server](https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/#metrics-server)
- [Resource Management for Pods and Containers](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)
- [autoscaling/v2 API Reference](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/horizontal-pod-autoscaler-v2/)
- [Vertical Pod Autoscaler — Kubernetes docs](https://kubernetes.io/docs/concepts/workloads/autoscaling/#scaling-workloads-vertically)
- [KEDA — Kubernetes Event-Driven Autoscaling](https://keda.sh/docs/latest/concepts/)

## Break & Fix 🔧

Try each scenario, diagnose the problem, and fix it.

### Scenario 1 — HPA shows `<unknown>/50%` for CPU

Apply this Deployment and HPA — the HPA will not work:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: broken-hpa-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: broken-hpa-app
  template:
    metadata:
      labels:
        app: broken-hpa-app
    spec:
      containers:
        - name: nginx
          image: nginx:stable
          ports:
            - containerPort: 80
          # BUG: no resources.requests defined!
```

```bash
kubectl apply -f broken-hpa-app.yaml
kubectl autoscale deployment broken-hpa-app --cpu-percent=50 --min=1 --max=5
kubectl get hpa broken-hpa-app
```

**What you'll see:** `TARGETS` shows `<unknown>/50%` even though Metrics Server is running.

**Diagnose:** `kubectl describe hpa broken-hpa-app` — look for the event: `FailedGetResourceMetric ... missing request for cpu`.

**Root cause:** The HPA computes utilization as `current / requested`. With no `requests.cpu`, there is nothing to divide by.

**Fix:** Add `resources.requests.cpu: 200m` to the container spec, re-apply, and verify:

```bash
kubectl get hpa broken-hpa-app --watch
```

**Clean up:**

```bash
kubectl delete deployment broken-hpa-app
kubectl delete hpa broken-hpa-app
```

---

### Scenario 2 — HPA doesn't scale up under load

Apply the correct `php-apache` Deployment and HPA from Tasks 2–3, then start this load generator:

```bash
kubectl run bad-load \
  --image=busybox:stable \
  --restart=Never \
  -- /bin/sh -c "while true; do wget -q -O- http://wrong-service-name; done"
```

**What you'll see:** The HPA stays at 1 replica — CPU never rises.

**Diagnose:**

```bash
# Check load generator logs — wget is failing
kubectl logs bad-load

# Check HPA — CPU stays near 0%
kubectl get hpa php-apache
```

**Root cause:** The load generator is hitting `wrong-service-name`, which doesn't exist. The requests never reach `php-apache`, so its CPU stays idle.

**Fix:** Delete the broken load generator and create one pointing to the correct Service:

```bash
kubectl delete pod bad-load
kubectl run good-load \
  --image=busybox:stable \
  --restart=Never \
  -- /bin/sh -c "while true; do wget -q -O- http://php-apache; done"
```

**Linux analogy:** It's like running a load test against `localhost:9999` when your app is on port `8080` — your monitoring shows zero load because nothing is actually hitting the server.

**Clean up:**

```bash
kubectl delete pod good-load
```

---

### Scenario 3 — Pods scaled up but won't come back down

Run the full load test from Tasks 4–5. Once the HPA has scaled up to several replicas, delete the load generator and immediately check replicas:

```bash
kubectl delete pod load-generator
kubectl get hpa php-apache
```

**What you'll see:** Even though CPU drops to 0%, the replica count stays elevated for several minutes.

**Diagnose:**

```bash
kubectl describe hpa php-apache
```

Look for the condition:

```
ScalingLimited  True  TooFewReplicas  the desired replica count is less than the minimum replica count
```

Or more likely:

```
AbleToScale  True  ReadyForNewScale  recommended size matches current size
```

The HPA is **waiting out the stabilization window** before scaling down.

**Root cause:** The default `stabilizationWindowSeconds` for scale-down is 300 seconds (5 minutes). This is by design — it prevents flapping if load comes back quickly.

**Fix (for lab only — not production):** Patch the HPA to use a shorter stabilization window:

```bash
kubectl patch hpa php-apache --type=merge -p '{
  "spec": {
    "behavior": {
      "scaleDown": {
        "stabilizationWindowSeconds": 30
      }
    }
  }
}'
```

After ~30 seconds of low CPU, the replicas will scale down.

**Linux analogy:** This is hysteresis — like setting a 5-minute cooldown on a monitoring alert so it doesn't page you for every brief spike. The same principle applies in reverse: don't deallocate workers the instant load drops, in case it comes right back.
