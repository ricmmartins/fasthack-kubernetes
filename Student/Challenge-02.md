# Challenge 02 — From Container to Pod

[< Previous Challenge](Challenge-01.md) | **[Home](../README.md)** | [Next Challenge >](Challenge-03.md)

## Introduction

In Challenge 01 you built and ran containers with Docker — the equivalent of launching individual processes on a Linux box. Now it's time to hand those containers over to Kubernetes.

In Linux, related processes are often grouped into a **process group** so the kernel can manage them as a unit (think of a parent process and its children sharing a session). Kubernetes has the same idea: a **Pod** is the smallest deployable unit and it wraps **one or more containers** that share:

| Shared resource | What it means |
|---|---|
| **Network namespace** | All containers in the Pod share the same IP address and port space — just like processes in the same network namespace on Linux. |
| **Storage volumes** | Containers in a Pod can mount the same volumes — similar to processes reading/writing to the same filesystem path. |
| **Lifecycle** | Containers in a Pod are scheduled, started, and stopped together — like a process group receiving the same signal. |

A Pod is **not** a VM and it is **not** a container. It is a thin wrapper that tells Kubernetes: *"run these containers together on the same node and let them talk over localhost."*

In this challenge you will create your first Pod using a YAML manifest, inspect it the way you would inspect a Linux process, exec into it just like you would with `docker exec`, and observe what happens when a Pod is deleted.

> **Cluster requirement:** All exercises use a local [Kind](https://kind.sigs.k8s.io/) cluster — no cloud account needed. If you haven't created one yet, run:
> ```bash
> kind create cluster --name fasthack
> ```

## Description

1. **Create a Pod from a YAML manifest**
   Write a file called `nginx-pod.yaml` that defines a single Pod running the `nginx:stable` image. Apply it to your Kind cluster with `kubectl apply`.

2. **Inspect the Pod**
   Use `kubectl get`, `kubectl describe`, and `kubectl logs` to examine the Pod's status, events, IP address, and container output — the same way you would use `ps`, `journalctl`, or `cat /proc` on Linux.

3. **Exec into the Pod**
   Open an interactive shell inside the running container with `kubectl exec`. Compare the experience with `docker exec` from Challenge 01. Run a few diagnostic commands inside the Pod to prove the container is just a Linux process with its own namespaces.

4. **Delete the Pod and observe the lifecycle**
   Delete the Pod with `kubectl delete` and watch what happens. Unlike a Deployment (which you'll meet later), a bare Pod is **not** restarted automatically — just like a process you `kill` without a supervisor daemon to restart it.

## Success Criteria

- [ ] You created a Pod using a YAML manifest and it reaches the `Running` state.
- [ ] You can retrieve Pod details with `kubectl get pods -o wide` and explain the output columns.
- [ ] You can exec into the Pod and run commands inside the container.
- [ ] You can view container logs with `kubectl logs`.
- [ ] You can articulate the difference between a **container** and a **Pod** (a Pod can hold multiple containers that share network and storage; a container is a single process/image).
- [ ] After deleting the Pod, you observe that it is **not** recreated automatically.

## Linux ↔ Kubernetes Reference

| Linux Concept | Kubernetes Equivalent | Notes |
|---|---|---|
| Process / process group | Pod | A Pod is a group of one or more containers scheduled together. |
| PID | Pod name | The unique identifier you use to interact with the workload. |
| `ps aux` | `kubectl get pods` | List running workloads and their status. |
| `ps aux -o pid,stat,cmd` | `kubectl get pods -o wide` | Wider output with node, IP, and more. |
| `kill <pid>` | `kubectl delete pod <name>` | Terminates the workload (SIGTERM → SIGKILL after grace period). |
| `docker exec -it <ctr> sh` | `kubectl exec -it <pod> -- /bin/sh` | Open an interactive shell inside the running container. |
| `docker logs <ctr>` | `kubectl logs <pod>` | Stream stdout/stderr from the container. |
| `/proc/<pid>/status` | `kubectl describe pod <name>` | Detailed status, events, and resource info. |

## Hints

<details>
<summary>Hint 1: Creating a Pod YAML manifest</summary>

Create a file named `nginx-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx
  labels:
    app: nginx
spec:
  containers:
    - name: nginx
      image: nginx:stable
      ports:
        - containerPort: 80
```

Apply it:

```bash
kubectl apply -f nginx-pod.yaml
```

Verify:

```bash
kubectl get pods
```

You should see the Pod transition from `ContainerCreating` to `Running`.

</details>

<details>
<summary>Hint 2: Inspecting the Pod</summary>

**List Pods with extra detail (like `ps aux` on Linux):**

```bash
kubectl get pods -o wide
```

This shows the Pod IP, the node it's running on, and the container status.

**Describe the Pod (like reading `/proc/<pid>/status`):**

```bash
kubectl describe pod nginx
```

Look for the **Events** section at the bottom — it shows the scheduler assigning the Pod to a node, the kubelet pulling the image, and the container starting.

**View container logs (like `docker logs` or `journalctl`):**

```bash
kubectl logs nginx
```

To follow logs in real time (like `tail -f`):

```bash
kubectl logs nginx --follow
```

</details>

<details>
<summary>Hint 3: Exec into the Pod</summary>

Open a shell inside the running container:

```bash
kubectl exec -it nginx -- /bin/sh
```

Once inside, explore — just like you would on any Linux box:

```bash
# What processes are running? (PID 1 is nginx master)
ps aux

# What IP address does this Pod have?
ip addr

# What is the hostname? (it matches the Pod name)
cat /etc/hostname

# Can you reach localhost:80?
curl -s http://localhost:80 | head -5

# Exit the shell
exit
```

Compare this with `docker exec -it <container_id> /bin/sh` from Challenge 01 — the experience is almost identical because under the hood, `kubectl exec` is doing the same thing: attaching to the container's namespaces.

</details>

<details>
<summary>Hint 4: Deleting a Pod and observing the lifecycle</summary>

Delete the Pod:

```bash
kubectl delete pod nginx
```

Watch it disappear:

```bash
kubectl get pods --watch
```

The Pod goes through `Terminating` and then is removed. **It does not come back** — there is no controller (like a Deployment) watching for it. This is equivalent to running `kill <pid>` on a process that has no systemd unit or supervisor to restart it.

</details>

## Learning Resources

- [Pods — Kubernetes official docs](https://kubernetes.io/docs/concepts/workloads/pods/)
- [kubectl Quick Reference](https://kubernetes.io/docs/reference/kubectl/)
- [kubectl exec](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_exec/)
- [kubectl logs](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_logs/)
- [Pod Lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/)
- [Kind — Quick Start](https://kind.sigs.k8s.io/docs/user/quick-start/)

## Break & Fix 🔧

Try each scenario, diagnose the problem, and fix it.

### Scenario 1 — ImagePullBackOff

Create a Pod with a deliberately wrong image name:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: broken-image
spec:
  containers:
    - name: web
      image: nginx:this-tag-does-not-exist
```

```bash
kubectl apply -f broken-image.yaml
kubectl get pods --watch
```

**What you'll see:** The Pod stays in `ErrImagePull` and then `ImagePullBackOff`.

**Diagnose:** `kubectl describe pod broken-image` — look at the Events section for the pull error.

**Fix:** Edit the YAML to use a valid tag (e.g., `nginx:stable`), delete the broken Pod, and re-apply.

---

### Scenario 2 — CrashLoopBackOff

Create a Pod whose command exits immediately:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: crash-loop
spec:
  containers:
    - name: app
      image: busybox:stable
      command: ["sh", "-c", "echo 'goodbye'; exit 1"]
```

```bash
kubectl apply -f crash-loop.yaml
kubectl get pods --watch
```

**What you'll see:** The Pod enters `CrashLoopBackOff` — Kubernetes keeps restarting the container, with increasing back-off delays.

**Diagnose:** `kubectl logs crash-loop` shows the output before the crash. `kubectl describe pod crash-loop` shows the restart count climbing.

**Linux analogy:** This is like a process that segfaults on startup while systemd keeps trying to restart it (`Restart=always`).

**Fix:** Change the command to something that stays running (e.g., `["sh", "-c", "echo 'hello'; sleep 3600"]`), delete the Pod, and re-apply.

---

### Scenario 3 — Duplicate Pod name

Try to create two Pods with the same name:

```bash
kubectl apply -f nginx-pod.yaml
kubectl apply -f nginx-pod.yaml
```

**What you'll see:** The second `apply` does **not** fail — it updates the existing Pod (idempotent operation). Now try with `kubectl create`:

```bash
kubectl delete pod nginx
kubectl create -f nginx-pod.yaml
kubectl create -f nginx-pod.yaml
```

**What you'll see:** The second `create` fails with: `Error from server (AlreadyExists): pods "nginx" already exists`.

**Lesson:** `kubectl apply` is declarative and idempotent (like `ansible`). `kubectl create` is imperative and fails if the resource already exists. In practice, prefer `apply`.

**Linux analogy:** It's like the difference between `mkdir -p /data` (idempotent, no error if exists) and `mkdir /data` (fails if already exists).
