# Solution 07 — Volumes and Persistence

[< Back to Challenge](../Student/Challenge-07.md) | **[Home](README.md)**

## Prerequisites

Students should have a running Kind cluster. The cluster from Challenge 06 (with Ingress config) works fine — it includes the `standard` StorageClass by default.

```bash
# Verify the cluster is running and has the default StorageClass
kubectl get nodes
kubectl get storageclass
```

Expected StorageClass output:

```
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   false                  1h
```

> **Coach tip:** Kind automatically installs the `rancher.io/local-path` provisioner and marks the `standard` StorageClass as default. This is what enables dynamic provisioning in Tasks 3 and 4.

---

## Task 1: Prove Container Storage Is Ephemeral

### Step-by-step

Save as `ephemeral-demo.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: ephemeral-demo
spec:
  containers:
    - name: writer
      image: busybox:1.37
      command: ["sh", "-c", "mkdir -p /data && echo 'hello from ephemeral storage' > /data/message.txt && sleep 3600"]
```

```bash
# Create the Pod
kubectl apply -f ephemeral-demo.yaml
kubectl wait --for=condition=ready pod/ephemeral-demo --timeout=60s
```

```bash
# Read the file — it exists
kubectl exec ephemeral-demo -- cat /data/message.txt
```

Expected output:

```
hello from ephemeral storage
```

```bash
# Delete the Pod
kubectl delete pod ephemeral-demo
```

```bash
# Recreate the same Pod
kubectl apply -f ephemeral-demo.yaml
kubectl wait --for=condition=ready pod/ephemeral-demo --timeout=60s
```

```bash
# Try to read the file again — it's gone
kubectl exec ephemeral-demo -- cat /data/message.txt
```

Expected output:

```
hello from ephemeral storage
```

> **Wait — the file is still there?** Yes! The command in the Pod spec *recreates* the file on every start (`echo ... > /data/message.txt`). To properly demonstrate ephemeral storage, we need to write data *after* Pod creation and then check if it survives.

**Correct demonstration:**

```bash
# Delete the Pod if it exists
kubectl delete pod ephemeral-demo --ignore-not-found

# Create the Pod (this time with just sleep, no file writing)
kubectl apply -f ephemeral-demo.yaml
kubectl wait --for=condition=ready pod/ephemeral-demo --timeout=60s

# Manually write data into the running container
kubectl exec ephemeral-demo -- sh -c "echo 'data written at runtime' > /tmp/runtime.txt"

# Confirm it exists
kubectl exec ephemeral-demo -- cat /tmp/runtime.txt
```

Expected output:

```
data written at runtime
```

```bash
# Delete and recreate
kubectl delete pod ephemeral-demo
kubectl apply -f ephemeral-demo.yaml
kubectl wait --for=condition=ready pod/ephemeral-demo --timeout=60s

# The runtime file is gone
kubectl exec ephemeral-demo -- cat /tmp/runtime.txt
```

Expected output:

```
cat: can't open '/tmp/runtime.txt': No such file or directory
command terminated with exit code 1
```

### Verification

- The file created at runtime (`/tmp/runtime.txt`) is gone after Pod deletion and recreation
- The file written by the Pod's command (`/data/message.txt`) gets recreated because it's part of the container start command — but it's *new* data, not the *old* data

> **Coach tip:** This is an important distinction. Help students understand: the writable layer is destroyed when the container is removed. The `command` in the spec runs fresh each time. Real-world data (database files, uploads, logs) that aren't recreated by the startup command will be lost.

```bash
# Cleanup
kubectl delete pod ephemeral-demo
```

---

## Task 2: Manual PersistentVolume and PersistentVolumeClaim

### Step-by-step

**2a. Create the PersistentVolume**

Save as `manual-pv.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: manual-pv
spec:
  capacity:
    storage: 256Mi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  hostPath:
    path: /tmp/k8s-manual-pv
    type: DirectoryOrCreate
```

**2b. Create the PersistentVolumeClaim**

Save as `manual-pvc.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: manual-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 256Mi
  storageClassName: ""
```

> **Important:** `storageClassName: ""` (empty string) prevents dynamic provisioning and forces static binding to the manually created PV.

**2c. Create a Pod that uses the PVC**

Save as `pvc-demo.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pvc-demo
spec:
  containers:
    - name: writer
      image: busybox:1.37
      command: ["sh", "-c", "echo 'persistent data' > /data/message.txt && sleep 3600"]
      volumeMounts:
        - name: my-storage
          mountPath: /data
  volumes:
    - name: my-storage
      persistentVolumeClaim:
        claimName: manual-pvc
```

```bash
# Apply in order: PV → PVC → Pod
kubectl apply -f manual-pv.yaml
kubectl apply -f manual-pvc.yaml
kubectl apply -f pvc-demo.yaml
kubectl wait --for=condition=ready pod/pvc-demo --timeout=60s
```

Expected output:

```
persistentvolume/manual-pv created
persistentvolumeclaim/manual-pvc created
pod/pvc-demo created
```

### Verification

```bash
# Check PV and PVC are Bound
kubectl get pv,pvc
```

Expected output:

```
NAME                         CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                STORAGECLASS   AGE
persistentvolume/manual-pv   256Mi      RWO            Retain           Bound    default/manual-pvc                  30s

NAME                               STATUS   VOLUME      CAPACITY   ACCESS MODES   STORAGECLASS   AGE
persistentvolumeclaim/manual-pvc   Bound    manual-pv   256Mi      RWO                           25s
```

```bash
# Verify data exists
kubectl exec pvc-demo -- cat /data/message.txt
```

Expected output:

```
persistent data
```

```bash
# Delete the Pod (NOT the PVC)
kubectl delete pod pvc-demo

# Recreate the Pod
kubectl apply -f pvc-demo.yaml
kubectl wait --for=condition=ready pod/pvc-demo --timeout=60s

# Data survives!
kubectl exec pvc-demo -- cat /data/message.txt
```

Expected output:

```
persistent data
```

```bash
# Inspect the PV details
kubectl describe pv manual-pv
```

Look for:
- `Source.Path: /tmp/k8s-manual-pv` — the actual directory on the Kind node
- `Status: Bound`
- `Claim: default/manual-pvc`

> **Coach tip:** `hostPath` volumes store data on the node's filesystem. In Kind, the "node" is a Docker container. Students can verify with: `docker exec -it fasthack-control-plane ls -la /tmp/k8s-manual-pv/`

```bash
# Cleanup
kubectl delete pod pvc-demo
kubectl delete pvc manual-pvc
kubectl delete pv manual-pv
```

---

## Task 3: StatefulSet with volumeClaimTemplates

### Step-by-step

**3a. Create the headless Service**

Save as `redis-headless-svc.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: redis
spec:
  clusterIP: None
  selector:
    app: redis
  ports:
    - port: 6379
```

**3b. Create the StatefulSet**

Save as `redis-statefulset.yaml`:

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: redis
spec:
  serviceName: redis
  replicas: 2
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
        - name: redis
          image: redis:7-alpine
          ports:
            - containerPort: 6379
          volumeMounts:
            - name: redis-data
              mountPath: /data
  volumeClaimTemplates:
    - metadata:
        name: redis-data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 128Mi
```

> **Important:** The headless Service must be created **before** the StatefulSet, because the StatefulSet references it via `serviceName`.

```bash
kubectl apply -f redis-headless-svc.yaml
kubectl apply -f redis-statefulset.yaml
```

Expected output:

```
service/redis created
statefulset.apps/redis created
```

```bash
# Watch Pods come up IN ORDER (redis-0, then redis-1)
kubectl get pods -l app=redis -w
```

Expected output (over ~30 seconds):

```
NAME      READY   STATUS              RESTARTS   AGE
redis-0   0/1     ContainerCreating   0          2s
redis-0   1/1     Running             0          5s
redis-1   0/1     Pending             0          0s
redis-1   0/1     ContainerCreating   0          1s
redis-1   1/1     Running             0          4s
```

> Press `Ctrl+C` to stop watching.

### Verification

```bash
# Check PVCs — one per replica
kubectl get pvc
```

Expected output:

```
NAME                   STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
redis-data-redis-0     Bound    pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   128Mi      RWO            standard       30s
redis-data-redis-1     Bound    pvc-yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy   128Mi      RWO            standard       25s
```

> **Key point:** Each PVC name follows the pattern `<volumeClaimTemplate-name>-<statefulset-name>-<ordinal>`. This is automatic.

```bash
# Write data to redis-0
kubectl exec redis-0 -- redis-cli SET mykey "hello from redis-0"
```

Expected output:

```
OK
```

```bash
# Read it back
kubectl exec redis-0 -- redis-cli GET mykey
```

Expected output:

```
"hello from redis-0"
```

```bash
# Delete redis-0 — the StatefulSet controller will recreate it
kubectl delete pod redis-0

# Wait for it to come back
kubectl wait --for=condition=ready pod/redis-0 --timeout=60s
```

```bash
# Data survives because the PVC persists!
kubectl exec redis-0 -- redis-cli GET mykey
```

Expected output:

```
"hello from redis-0"
```

```bash
# Verify redis-1 has INDEPENDENT storage (no data from redis-0)
kubectl exec redis-1 -- redis-cli GET mykey
```

Expected output:

```
(nil)
```

```bash
# Show stable DNS names via the headless Service
kubectl run tmp-dns --rm -it --restart=Never --image=busybox:stable -- nslookup redis-0.redis
```

Expected output:

```
Name:      redis-0.redis.default.svc.cluster.local
Address:   10.244.x.x
```

> **Coach tip:** Explain why StatefulSets exist: Deployments treat all replicas as interchangeable — they share the same PVC. StatefulSets give each replica a unique identity (stable hostname, own PVC). This is essential for databases, message queues, and any workload where each instance owns distinct data.

```bash
# Cleanup (PVCs are NOT deleted when the StatefulSet is deleted!)
kubectl delete statefulset redis
kubectl delete svc redis
kubectl get pvc  # PVCs still exist — this is by design
kubectl delete pvc redis-data-redis-0 redis-data-redis-1
```

---

## Task 4: Dynamic Provisioning with StorageClass

### Step-by-step

```bash
# First, see what StorageClasses are available
kubectl get storageclass
```

Expected output:

```
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   false                  2h
```

Save as `dynamic-pvc.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: dynamic-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 128Mi
  storageClassName: standard
```

Save as `dynamic-demo.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: dynamic-demo
spec:
  containers:
    - name: app
      image: busybox:1.37
      command: ["sh", "-c", "echo 'dynamically provisioned!' > /data/hello.txt && sleep 3600"]
      volumeMounts:
        - name: dynamic-vol
          mountPath: /data
  volumes:
    - name: dynamic-vol
      persistentVolumeClaim:
        claimName: dynamic-pvc
```

```bash
kubectl apply -f dynamic-pvc.yaml
```

```bash
# Check PVC status — it will be Pending (WaitForFirstConsumer)
kubectl get pvc dynamic-pvc
```

Expected output:

```
NAME          STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
dynamic-pvc   Pending                                      standard       5s
```

> **Coach tip:** This is expected! The `standard` StorageClass uses `volumeBindingMode: WaitForFirstConsumer`, meaning the PV is NOT created until a Pod actually references the PVC. This avoids scheduling conflicts on multi-node clusters.

```bash
# Now create the Pod — this triggers PV provisioning
kubectl apply -f dynamic-demo.yaml
kubectl wait --for=condition=ready pod/dynamic-demo --timeout=60s
```

### Verification

```bash
# PVC is now Bound and a PV was created automatically
kubectl get pv
```

Expected output:

```
NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                 STORAGECLASS   AGE
pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   128Mi      RWO            Delete           Bound    default/dynamic-pvc   standard       10s
```

```bash
kubectl get pvc dynamic-pvc
```

Expected output:

```
NAME          STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
dynamic-pvc   Bound    pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   128Mi      RWO            standard       30s
```

```bash
# Verify the data was written
kubectl exec dynamic-demo -- cat /data/hello.txt
```

Expected output:

```
dynamically provisioned!
```

```bash
# Show where Kind stores the data on the node
kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.hostPath.path}{"\n"}{end}'
```

Expected output: shows the path under `/var/local-path-provisioner/` on the Kind node.

```bash
# Optional: peek inside the Kind node container
docker exec -it fasthack-control-plane ls -la /var/local-path-provisioner/
```

> **Coach tip:** Compare Task 2 (manual PV/PVC) vs Task 4 (dynamic). Manual: you create both PV and PVC. Dynamic: you only create the PVC and the StorageClass provisioner creates the PV automatically. In production, dynamic provisioning is the norm — nobody manually creates PVs for every application.

```bash
# Cleanup
kubectl delete pod dynamic-demo
kubectl delete pvc dynamic-pvc
# The PV is auto-deleted because reclaimPolicy is Delete
kubectl get pv  # should be gone
```

---

## Task 5: emptyDir Sidecar Pattern

### Step-by-step

Save as `sidecar-demo.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: sidecar-demo
spec:
  containers:
    - name: producer
      image: busybox:1.37
      command: ["sh", "-c", "while true; do date >> /shared/log.txt; sleep 5; done"]
      volumeMounts:
        - name: shared-data
          mountPath: /shared
    - name: consumer
      image: busybox:1.37
      command: ["sh", "-c", "tail -f /shared/log.txt"]
      volumeMounts:
        - name: shared-data
          mountPath: /shared
  volumes:
    - name: shared-data
      emptyDir: {}
```

```bash
kubectl apply -f sidecar-demo.yaml
kubectl wait --for=condition=ready pod/sidecar-demo --timeout=60s
```

### Verification

```bash
# See live timestamps from the producer via the consumer's tail -f
kubectl logs sidecar-demo -c consumer --tail=5
```

Expected output (timestamps will vary):

```
Mon Jun 16 14:00:00 UTC 2025
Mon Jun 16 14:00:05 UTC 2025
Mon Jun 16 14:00:10 UTC 2025
Mon Jun 16 14:00:15 UTC 2025
Mon Jun 16 14:00:20 UTC 2025
```

```bash
# Follow the logs live (Ctrl+C to stop)
kubectl logs sidecar-demo -c consumer -f
```

New timestamps should appear every 5 seconds.

```bash
# Verify both containers see the same file
kubectl exec sidecar-demo -c producer -- wc -l /shared/log.txt
kubectl exec sidecar-demo -c consumer -- wc -l /shared/log.txt
```

Both should show the same line count (growing over time).

```bash
# Prove emptyDir is ephemeral — delete and recreate
kubectl delete pod sidecar-demo
kubectl apply -f sidecar-demo.yaml
kubectl wait --for=condition=ready pod/sidecar-demo --timeout=60s

# The consumer starts with fresh data — old logs are gone
kubectl logs sidecar-demo -c consumer --tail=3
```

Expected output: only 1-3 new timestamps — no old data carried over.

> **Coach tip:** `emptyDir` is the Kubernetes equivalent of a shared `/tmp` directory between processes. It's perfect for:
> - Sidecar log collectors (like this demo)
> - Cache directories shared between init containers and app containers
> - Scratch space for computation
>
> It is NOT suitable for data that must survive Pod deletion — use a PVC for that.

```bash
# Cleanup
kubectl delete pod sidecar-demo
```

---

## Common Issues

| Problem | Likely Cause | Fix |
|---------|-------------|-----|
| PVC stuck in `Pending` | `storageClassName` doesn't match any StorageClass | Use `standard` (Kind default) or `""` for manual binding |
| PVC stuck in `Pending` (dynamic) | `WaitForFirstConsumer` — no Pod created yet | Create a Pod that references the PVC |
| PVC stuck in `Pending` (manual) | PV capacity < PVC request, or accessModes mismatch | Check `kubectl describe pvc <name>` Events section |
| Pod stuck in `ContainerCreating` | PVC `claimName` references a non-existent PVC | `kubectl describe pod <name>` — look for "persistentvolumeclaim not found" |
| StatefulSet Pods don't start | Headless Service not created before StatefulSet | Create the headless Service (`clusterIP: None`) first |
| StatefulSet Pods start but data lost | Using `emptyDir` instead of `volumeClaimTemplates` | Replace `emptyDir` with `volumeClaimTemplates` in the StatefulSet spec |
| `redis-cli` command not found | Wrong Redis image | Use `redis:7-alpine` which includes `redis-cli` |
| PV not auto-deleted after PVC deletion | `reclaimPolicy: Retain` on manually created PV | Manually delete the PV: `kubectl delete pv manual-pv` |
| `local-path-provisioner` not working | Pod not in kube-system namespace | `kubectl -n local-path-storage get pods` (Kind puts it in its own namespace) |

> **Coach coaching tips for this challenge:**
>
> 1. **The fstab analogy works great here:** PV = the block device (`/dev/sdb1`), PVC = the mount request (`mount /dev/sdb1 /mnt/data`), StorageClass = the LVM volume group configuration that auto-creates logical volumes on demand.
>
> 2. **Students often confuse StatefulSet PVC behavior:** When you delete a StatefulSet, the PVCs are intentionally NOT deleted. This is a safety feature — you don't lose database data just because you scaled down or redeployed. Students must manually delete PVCs if they want to reclaim storage.
>
> 3. **Key question to ask students:** "When would you use `emptyDir` vs a PVC?" Answer: `emptyDir` for temporary/cache/scratch data that can be regenerated. PVC for data that must survive Pod restarts (databases, uploads, state).

