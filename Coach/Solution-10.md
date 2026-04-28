# Solution 10 — Autoscaling

[< Back to Challenge](../Student/Challenge-10.md) | **[Home](README.md)**

## Notes for Coaches

The main blocker in this challenge is Metrics Server on Kind. If `kubectl top` shows errors, don't let students spin — walk them through the `--kubelet-insecure-tls` patch immediately. The actual HPA demo is straightforward once metrics are flowing.

The load test takes 1–2 minutes for scale-up and ~5 minutes for scale-down (stabilization window). Reduce the stabilization window to 60s in Task 6 if time is tight.

Estimated time: **45 minutes**

---

## Task 1: Install Metrics Server on Kind

### Step-by-step

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

Kind uses self-signed kubelet certificates, so Metrics Server will fail TLS verification by default. Patch it to skip TLS verification:

```bash
kubectl patch -n kube-system deployment metrics-server \
  --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

Wait for the rollout to complete:

```bash
kubectl -n kube-system rollout status deployment metrics-server --timeout=120s
```

### Verification

Wait 30–60 seconds after rollout completes for the first metrics scrape, then:

```bash
kubectl top nodes
```

Expected output (values will vary):

```
NAME                     CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
fasthack-control-plane   150m         7%     800Mi           20%
```

```bash
kubectl top pods -A
```

Expected: a table showing CPU and memory usage for system pods (coredns, etcd, etc.). If you see `error: metrics not available yet`, wait another 30 seconds and retry.

> **Coach tip:** If Metrics Server pods are crash-looping, check logs:
> ```bash
> kubectl -n kube-system logs -l k8s-app=metrics-server --tail=20
> ```
> The most common error is `x509: cannot validate certificate` — which means the `--kubelet-insecure-tls` patch wasn't applied or the rollout hasn't completed.

---

## Task 2: Deploy CPU-Intensive Application

### Step-by-step

Save `php-apache.yaml`:

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

```bash
kubectl apply -f php-apache.yaml
kubectl rollout status deployment php-apache --timeout=120s
```

### Verification

```bash
kubectl get deployment php-apache
```

Expected:

```
NAME         READY   UP-TO-DATE   AVAILABLE   AGE
php-apache   1/1     1            1           ...
```

```bash
kubectl get svc php-apache
```

Expected: a ClusterIP service on port 80.

> **Coach tip:** The `resources.requests.cpu: 200m` is **critical** — without it, the HPA cannot calculate a utilization percentage and will show `<unknown>`. This is the #1 cause of "my HPA doesn't work" issues.

---

## Task 3: Create HPA Targeting 50% CPU

### Step-by-step

```bash
kubectl autoscale deployment php-apache \
  --cpu-percent=50 \
  --min=1 \
  --max=10
```

### Verification

```bash
kubectl get hpa php-apache
```

Expected output:

```
NAME         REFERENCE               TARGETS   MINPODS   MAXPODS   REPLICAS   AGE
php-apache   Deployment/php-apache   0%/50%    1         10        1          30s
```

If you see `<unknown>/50%`, Metrics Server either isn't running or the Pod lacks CPU requests. Wait 60 seconds and check again — it can take one scrape interval for metrics to appear.

```bash
kubectl describe hpa php-apache
```

Expected: under Conditions, `ScalingActive` should show `True` with reason `ValidMetricFound`.

> **Coach tip:** The imperative `kubectl autoscale` command creates an `autoscaling/v2` HPA resource. Students will create the declarative YAML equivalent in Task 6.

---

## Task 4: Generate Load and Observe Scale-Up

### Step-by-step

Start the load generator:

```bash
kubectl run load-generator \
  --image=busybox:stable \
  --restart=Never \
  -- /bin/sh -c "while true; do wget -q -O- http://php-apache; done"
```

Watch the HPA in a separate terminal (or use `--watch`):

```bash
kubectl get hpa php-apache --watch
```

### Verification

Within 1–2 minutes you should see:

1. **CPU target rises** above 50% (e.g., `250%/50%`)
2. **Replica count increases** (e.g., from 1 → 4 → 7 → 10)

Example progression:

```
NAME         REFERENCE               TARGETS    MINPODS   MAXPODS   REPLICAS   AGE
php-apache   Deployment/php-apache   0%/50%     1         10        1          2m
php-apache   Deployment/php-apache   250%/50%   1         10        1          3m
php-apache   Deployment/php-apache   250%/50%   1         10        5          3m30s
php-apache   Deployment/php-apache   48%/50%    1         10        7          4m
```

Also watch Pods being created:

```bash
kubectl get pods -l app=php-apache
```

Expected: multiple pods in `Running` state.

> **Coach tip:** If load isn't driving CPU high enough, run multiple load generators:
> ```bash
> for i in 1 2 3; do
>   kubectl run load-generator-$i \
>     --image=busybox:stable \
>     --restart=Never \
>     -- /bin/sh -c "while true; do wget -q -O- http://php-apache; done"
> done
> ```

---

## Task 5: Stop Load and Observe Scale-Down

### Step-by-step

```bash
kubectl delete pod load-generator
# If you started multiple:
# kubectl delete pod load-generator-1 load-generator-2 load-generator-3
```

Keep watching the HPA:

```bash
kubectl get hpa php-apache --watch
```

### Verification

1. CPU target drops to `0%/50%` within 1–2 minutes.
2. Replica count stays elevated for approximately **5 minutes** (the default stabilization window).
3. After the stabilization window, replicas gradually scale down back to `1`.

Example progression:

```
NAME         REFERENCE               TARGETS   MINPODS   MAXPODS   REPLICAS   AGE
php-apache   Deployment/php-apache   0%/50%    1         10        7          10m
...wait ~5 minutes...
php-apache   Deployment/php-apache   0%/50%    1         10        1          16m
```

> **Coach tip:** If students are impatient, explain the stabilization window and skip ahead to Task 6 where they'll reduce it to 60 seconds. The default 5-minute cooldown exists to prevent flapping in production.

---

## Task 6: Declarative HPA with `autoscaling/v2`

### Step-by-step

First, delete the imperative HPA:

```bash
kubectl delete hpa php-apache
```

Save `php-apache-hpa.yaml`:

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

```bash
kubectl apply -f php-apache-hpa.yaml
```

### Verification

```bash
kubectl get hpa php-apache
```

Expected: same as Task 3, but now the HPA was created from a YAML manifest.

```bash
kubectl get hpa php-apache -o yaml | grep -A3 behavior
```

Expected:

```yaml
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 60
```

> **Coach tip:** Walk through the key differences between the imperative and declarative approaches:
>
> | Feature | `kubectl autoscale` | `autoscaling/v2` YAML |
> |---------|--------------------|-----------------------|
> | API version | Creates `autoscaling/v2` | Explicitly declares `autoscaling/v2` |
> | Custom behavior | Not configurable | Full control over scale-up/down policies |
> | Multiple metrics | CPU only | CPU, memory, custom, external metrics |
> | GitOps-friendly | No | Yes — stored in version control |

---

## Task 7: VPA Concept (Discussion Only)

> No hands-on commands — this is a discussion topic.

### Key Points for Coaches

Ask the student: "When would horizontal scaling NOT work?"

Expected answers:
- **Stateful singletons** — a database that can't be sharded
- **Batch jobs** — a single process that needs more CPU/RAM
- **Unknown right-sizing** — new apps where you don't know the correct resource requests

VPA modes:

| Mode | Behavior | Analogy |
|------|----------|---------|
| `Off` | Recommends but doesn't change | `htop` — you see the data, you decide |
| `Initial` | Sets resources at Pod creation | `ulimit` in `/etc/profile.d/` — applies on login |
| `Auto` | Evicts and recreates Pods with new resources | Live VM resize with reboot |

> **Coach tip:** VPA and HPA should NOT both target CPU on the same Deployment — they will fight each other. You can use VPA for memory and HPA for CPU on the same workload.

---

## Task 8: KEDA Concept (Discussion Only)

> No hands-on commands — this is a discussion topic.

### Key Points for Coaches

Ask the student: "What if you want to scale based on something other than CPU or memory?"

Examples:
- **Message queue depth** — scale workers when RabbitMQ/Kafka messages pile up
- **Cron schedule** — scale to 5 replicas during business hours, 0 at night
- **HTTP request rate** — scale based on requests per second from Prometheus
- **Database connections** — scale based on active connection count

Walk through the KEDA cron ScaledObject from the challenge:

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

Key KEDA features vs HPA:
- **Scale to zero** — HPA min is 1; KEDA can scale to 0
- **60+ trigger types** — Prometheus, Kafka, RabbitMQ, Azure Queue, cron, HTTP, etc.
- **ScaledJobs** — create Kubernetes Jobs on demand (not just scale Deployments)

> **Coach tip:** KEDA actually creates and manages HPA objects under the hood. It's an extension of HPA, not a replacement.

---

## Common Issues

| Problem | Cause | Fix |
|---------|-------|-----|
| `kubectl top` returns "metrics not available yet" | Metrics Server hasn't completed first scrape | Wait 60 seconds after rollout completes and retry |
| Metrics Server crash-loops with `x509` error | Kind's self-signed kubelet certs | Apply the `--kubelet-insecure-tls` patch and wait for rollout |
| HPA shows `<unknown>/50%` | Missing `resources.requests.cpu` on Pod | Add `resources.requests.cpu: 200m` to the container spec |
| HPA doesn't scale up under load | Load generator hitting wrong Service name | Verify `kubectl get svc php-apache` exists and load generator uses `http://php-apache` |
| Scale-down takes 5+ minutes | Default stabilization window is 300s | Expected behavior; use `behavior.scaleDown.stabilizationWindowSeconds: 60` for labs |
| Load generator Pod in `CrashLoopBackOff` | Used `--restart=Never` but the wget loop has no error handling | Delete and recreate; check `kubectl logs load-generator` for DNS errors |
| HPA maxes out at `maxReplicas` but CPU is still high | Need more headroom or the app is CPU-bound | Increase `maxReplicas` or increase `resources.requests.cpu` so each replica handles more |

---

## Clean Up

```bash
kubectl delete -f php-apache.yaml 2>/dev/null
kubectl delete -f php-apache-hpa.yaml 2>/dev/null
kubectl delete hpa php-apache 2>/dev/null
kubectl delete pod load-generator 2>/dev/null
kubectl delete pod load-generator-1 load-generator-2 load-generator-3 2>/dev/null
rm -f php-apache.yaml php-apache-hpa.yaml
```
