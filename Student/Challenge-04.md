# Challenge 04 — Deployments and Rolling Updates

[< Previous Challenge](Challenge-03.md) | **[Home](../README.md)** | [Next Challenge >](Challenge-05.md)

## Introduction

In Linux, if nginx crashes, you restart it manually (`systemctl restart nginx`). In Kubernetes, Deployments do this automatically — and more. A Deployment manages ReplicaSets, which manage Pods. It ensures the desired number of replicas are always running and handles rolling updates without downtime.

Think of it this way:

- `systemctl` → **Deployment** (manages the lifecycle of your application)
- Process count → **replicas** (how many instances to keep running)
- `apt upgrade` → **rolling update** (upgrade the application version with zero downtime)
- Package rollback → **`kubectl rollout undo`** (revert to the previous version instantly)

## Description

Your mission is to:

1. Create a Deployment with **3 replicas** of `nginx:stable`
2. Scale the Deployment up to **5 replicas**, then back down to **3**
3. Perform a **rolling update** from `nginx:stable` to `nginx:alpine`
4. **Rollback** to the previous version
5. Set **resource requests and limits** (CPU and memory) on the Deployment

## Success Criteria

- [ ] A Deployment named `webapp` is running with 3 replicas and all Pods are Ready
- [ ] You can scale the Deployment up to 5 replicas and back down to 3
- [ ] A rolling update from `nginx:stable` to `nginx:alpine` completes with zero downtime
- [ ] You can rollback to the previous version using `kubectl rollout undo`
- [ ] Resource requests and limits are set on the container and visible via `kubectl describe`

## Linux ↔ Kubernetes Reference

| Linux Concept | Kubernetes Equivalent |
|---|---|
| `systemctl start nginx` | `kubectl apply -f deployment.yaml` |
| `systemctl restart nginx` | `kubectl rollout restart deployment/webapp` |
| Process count (number of nginx workers) | `spec.replicas` |
| `apt upgrade nginx` | Image update via `kubectl set image` (rolling) |
| `apt rollback` / downgrade package | `kubectl rollout undo deployment/webapp` |
| `ulimit` / cgroups resource limits | `resources.requests` / `resources.limits` |
| `systemctl status nginx` | `kubectl rollout status deployment/webapp` |

## Hints

<details>
<summary>Hint 1: Create the Deployment YAML</summary>

Create a file named `webapp-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp
spec:
  replicas: 3
  selector:
    matchLabels:
      app: webapp
  template:
    metadata:
      labels:
        app: webapp
    spec:
      containers:
      - name: nginx
        image: nginx:stable
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: "50m"
            memory: "64Mi"
          limits:
            cpu: "100m"
            memory: "128Mi"
```

Apply it and verify:

```bash
kubectl apply -f webapp-deployment.yaml
kubectl get deployment webapp
kubectl get pods -l app=webapp
```
</details>

<details>
<summary>Hint 2: Scaling up and down</summary>

```bash
kubectl scale deployment webapp --replicas=5
kubectl get pods -l app=webapp -w  # watch Pods appear
kubectl scale deployment webapp --replicas=3
```
</details>

<details>
<summary>Hint 3: Performing a rolling update</summary>

```bash
kubectl set image deployment/webapp nginx=nginx:alpine
kubectl rollout status deployment/webapp
kubectl get pods -l app=webapp  # observe old Pods terminating, new Pods starting
```
</details>

<details>
<summary>Hint 4: Rolling back</summary>

```bash
kubectl rollout history deployment/webapp
kubectl rollout undo deployment/webapp
kubectl rollout status deployment/webapp
kubectl describe deployment webapp | grep Image
```
</details>

## Learning Resources

- [Kubernetes Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/)
- [Managing Resources for Containers](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)
- [Performing a Rolling Update](https://kubernetes.io/docs/tutorials/kubernetes-basics/update/update-intro/)

## Break & Fix 🔧

After completing the challenge, try these scenarios:

1. **Bad image tag** — Set the image to a nonexistent tag (`nginx:doesnotexist`) and observe the rollout get stuck. Use `kubectl rollout status` to see it hang, then rollback with `kubectl rollout undo deployment/webapp`
2. **OOMKilled** — Set the memory limit to `1Mi` and watch the Pod get killed with an `OOMKilled` status. Inspect it with `kubectl describe pod` and look for the `Last State` section
3. **Self-healing** — Delete a Pod manually (`kubectl delete pod <pod-name>`) and watch the Deployment recreate it automatically. Use `kubectl get pods -w` to see the new Pod appear
