# Solution 02 — From Container to Pod

[< Back to Challenge](../Student/Challenge-02.md) | **[Home](README.md)**

## Pre-check

Ensure students have a running Kind cluster and `kubectl` configured:

```bash
kubectl cluster-info
```

Expected output:

```
Kubernetes control plane is running at https://127.0.0.1:XXXXX
CoreDNS is running at https://127.0.0.1:XXXXX/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy
```

If the cluster doesn't exist, create one:

```bash
kind create cluster --name fasthack
```

---

## Task 1: Create a Pod from a YAML Manifest

### Step-by-step

Create the Pod manifest file `nginx-pod.yaml`:

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

Apply it to the cluster:

```bash
kubectl apply -f nginx-pod.yaml
```

Expected output:

```
pod/nginx created
```

Watch the Pod reach `Running` status:

```bash
kubectl get pods -w
```

Expected output:

```
NAME    READY   STATUS              RESTARTS   AGE
nginx   0/1     ContainerCreating   0          2s
nginx   1/1     Running             0          5s
```

Press `Ctrl+C` to stop watching.

### Verification

```bash
kubectl get pods
```

Expected output:

```
NAME    READY   STATUS    RESTARTS   AGE
nginx   1/1     Running   0          30s
```

The Pod shows `1/1` Ready and `Running` status.

---

## Task 2: Inspect the Pod

### Step-by-step

**List Pods with extended details:**

```bash
kubectl get pods -o wide
```

Expected output:

```
NAME    READY   STATUS    RESTARTS   AGE   IP           NODE                     NOMINATED NODE   READINESS GATES
nginx   1/1     Running   0          1m    10.244.0.5   fasthack-control-plane   <none>           <none>
```

> **Coach note:** Explain each column:
> - `READY` — containers ready / total containers (1/1 means 1 container, 1 ready)
> - `IP` — the Pod's cluster-internal IP (not reachable from the host, only from within the cluster)
> - `NODE` — which cluster node the Pod was scheduled on

**Describe the Pod in detail:**

```bash
kubectl describe pod nginx
```

Expected output (key sections):

```
Name:             nginx
Namespace:        default
Priority:         0
Service Account:  default
Node:             fasthack-control-plane/172.18.0.2
Start Time:       ...
Labels:           app=nginx
Status:           Running
IP:               10.244.0.5
Containers:
  nginx:
    Container ID:   containerd://abc123...
    Image:          nginx:stable
    Port:           80/TCP
    State:          Running
      Started:      ...
    Ready:          True
    Restart Count:  0
...
Events:
  Type    Reason     Age   From               Message
  ----    ------     ----  ----               -------
  Normal  Scheduled  1m    default-scheduler  Successfully assigned default/nginx to fasthack-control-plane
  Normal  Pulling    1m    kubelet            Pulling image "nginx:stable"
  Normal  Pulled     55s   kubelet            Successfully pulled image "nginx:stable"
  Normal  Created    55s   kubelet            Created container nginx
  Normal  Started    55s   kubelet            Started container nginx
```

> **Coach note:** The **Events** section at the bottom is the most important diagnostic tool. Walk students through the lifecycle: Scheduled → Pulling → Pulled → Created → Started.

**View container logs:**

```bash
kubectl logs nginx
```

Expected output (nginx access log may be empty if nothing has hit it yet):

```
/docker-entrypoint.sh: /docker-entrypoint.d/ is not empty, will attempt to perform configuration
/docker-entrypoint.sh: Looking for shell scripts in /docker-entrypoint.d/
...
```

To follow logs in real time (like `tail -f`):

```bash
kubectl logs nginx --follow
```

Press `Ctrl+C` to stop following.

### Verification

- `kubectl get pods -o wide` shows IP, node, and status
- `kubectl describe pod nginx` shows the full event lifecycle
- `kubectl logs nginx` shows container stdout

---

## Task 3: Exec into the Pod

### Step-by-step

Open an interactive shell inside the container:

```bash
kubectl exec -it nginx -- /bin/sh
```

> **Coach note:** The `--` separates kubectl arguments from the command to run inside the container. This is the same pattern as `docker exec`.

Once inside, run diagnostic commands:

**List processes (PID 1 is nginx master):**

```bash
ps aux
```

Expected output:

```
PID   USER     TIME  COMMAND
    1 root      0:00 nginx: master process nginx -g daemon off;
   29 nginx     0:00 nginx: worker process
   ...
```

> If `ps` is not found, use: `apt-get update && apt-get install -y procps` then retry.

**Check the Pod's IP address:**

```bash
ip addr
```

Or if `ip` is not available:

```bash
cat /proc/net/fib_trie | head -20
hostname -i
```

**Check the hostname (matches the Pod name):**

```bash
cat /etc/hostname
```

Expected output:

```
nginx
```

**Verify localhost serves traffic:**

```bash
curl -s http://localhost:80 | head -5
```

> If `curl` is not installed: `apt-get update && apt-get install -y curl`

Expected output:

```html
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
<style>
```

Exit the shell:

```bash
exit
```

### Verification

- Students successfully exec into the Pod and run commands
- They can confirm the hostname matches the Pod name
- They can compare the experience with `docker exec` from Challenge 01

---

## Task 4: Delete the Pod and Observe the Lifecycle

### Step-by-step

Delete the Pod:

```bash
kubectl delete pod nginx
```

Expected output:

```
pod "nginx" deleted
```

> This may take a few seconds — Kubernetes sends SIGTERM, waits for the grace period (default 30s), then sends SIGKILL.

In a **separate terminal** (before deleting), you can watch the lifecycle:

```bash
kubectl get pods -w
```

Expected output:

```
NAME    READY   STATUS        RESTARTS   AGE
nginx   1/1     Terminating   0          5m
nginx   0/1     Terminating   0          5m
```

After a few seconds, the Pod disappears completely.

Confirm it's gone:

```bash
kubectl get pods
```

Expected output:

```
No resources found in default namespace.
```

> **Coach note — Key teaching moment:** The Pod is **not** recreated. This is because a bare Pod has no controller managing it. It's like running `kill <pid>` on a process that has no systemd unit to restart it. In Challenge 04, students will learn about Deployments, which **do** restart Pods automatically.

### Verification

- The Pod transitions through `Terminating` and is fully removed
- `kubectl get pods` shows no resources in the default namespace
- Students understand that bare Pods are not self-healing

---

## Common Issues

| Issue | Symptom | Fix |
|---|---|---|
| No cluster running | `The connection to the server localhost:8080 was refused` | Create a cluster: `kind create cluster --name fasthack` |
| Wrong context selected | kubectl talks to wrong cluster | Check: `kubectl config current-context` — switch: `kubectl config use-context kind-fasthack` |
| ImagePullBackOff | Pod stuck in `ErrImagePull` or `ImagePullBackOff` | Check image name/tag: `kubectl describe pod nginx` → look at Events. Common cause: typo in image name |
| `exec` fails with "pod not found" | Student deleted the Pod before exec | Recreate: `kubectl apply -f nginx-pod.yaml` |
| `ps` or `curl` not found inside container | Minimal base image | Install tools: `apt-get update && apt-get install -y procps curl iproute2` |
| Students use `kubectl create` and get "AlreadyExists" | They applied the YAML twice with `create` | Explain: use `kubectl apply` (idempotent) instead of `kubectl create`. Or delete first: `kubectl delete pod nginx` |
| Students expect Pod to restart after delete | They think Pods are self-healing | Explain: bare Pods are like processes without a supervisor. Deployments (Challenge 04) provide self-healing |

