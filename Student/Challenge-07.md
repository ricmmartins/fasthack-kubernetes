# Challenge 07 — Volumes and Persistence

[< Previous Challenge](Challenge-06.md) | **[Home](../README.md)** | [Next Challenge >](Challenge-08.md)

## Introduction

On a Linux server you manage storage every day — editing `/etc/fstab` to declare filesystems, running `mount` to attach block devices, grouping disks into LVM volume groups, and using `/tmp` for throwaway scratch space. When a process dies, `/tmp` disappears, but data on a mounted volume survives.

Kubernetes follows the exact same philosophy. Containers are **ephemeral by default** — when a Pod is deleted, everything inside its writable layer is gone. To keep data across restarts you need volumes, just like a Linux process needs a mounted filesystem to persist anything beyond its own lifetime.

In this challenge you'll work through the full storage lifecycle: see data vanish with ephemeral storage, create persistent volumes, attach them to Pods and StatefulSets, explore dynamic provisioning via StorageClasses, and share data between containers using `emptyDir`.

## Description

Your mission is to:

1. **Prove that container storage is ephemeral**

   Create a Pod that writes a file, delete the Pod, recreate it, and confirm the file is gone.

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
   kubectl apply -f ephemeral-demo.yaml
   kubectl exec ephemeral-demo -- cat /data/message.txt
   kubectl delete pod ephemeral-demo
   kubectl apply -f ephemeral-demo.yaml
   kubectl exec ephemeral-demo -- cat /data/message.txt   # file is gone!
   ```

2. **Create a PersistentVolume (PV) and PersistentVolumeClaim (PVC) manually**

   Define a `hostPath` PV (suitable for Kind single-node clusters) and a matching PVC. Then launch a Pod that mounts the PVC, writes data, gets deleted, and a new Pod proves the data survives.

   Create the PV:
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

   Create the PVC:
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
     storageClassName: ""   # empty string prevents dynamic provisioning
   ```

   Deploy a Pod that uses the PVC:
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

   Test persistence:
   ```bash
   kubectl apply -f manual-pv.yaml
   kubectl apply -f manual-pvc.yaml
   kubectl apply -f pvc-demo.yaml
   kubectl exec pvc-demo -- cat /data/message.txt
   kubectl delete pod pvc-demo
   kubectl apply -f pvc-demo.yaml
   kubectl exec pvc-demo -- cat /data/message.txt   # data survives!
   ```

   Inspect the binding:
   ```bash
   kubectl get pv,pvc
   kubectl describe pv manual-pv
   ```

3. **Deploy a StatefulSet with volumeClaimTemplates**

   StatefulSets give each Pod a stable hostname (`redis-0`, `redis-1`, …) and its own PVC. Deploy a Redis StatefulSet and verify each replica has independent persistent storage.

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

   You also need a headless Service for the StatefulSet:
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

   Verify:
   ```bash
   kubectl apply -f redis-headless-svc.yaml
   kubectl apply -f redis-statefulset.yaml
   kubectl get pods -l app=redis -w                 # watch pods come up in order
   kubectl get pvc                                   # one PVC per replica
   kubectl exec redis-0 -- redis-cli SET mykey "hello from redis-0"
   kubectl exec redis-0 -- redis-cli GET mykey
   kubectl delete pod redis-0                        # StatefulSet recreates it
   kubectl exec redis-0 -- redis-cli GET mykey       # data survives!
   ```

4. **Explore StorageClasses and dynamic provisioning**

   Kind ships with a default StorageClass named `standard` backed by the `rancher.io/local-path` provisioner. When a PVC references this StorageClass, a PV is created automatically — no manual PV needed.

   ```bash
   kubectl get storageclass
   ```

   Create a PVC that uses dynamic provisioning:
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

   Deploy a Pod that uses it:
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
   kubectl apply -f dynamic-demo.yaml
   kubectl get pv    # a PV was created automatically!
   kubectl get pvc   # dynamic-pvc is Bound
   kubectl exec dynamic-demo -- cat /data/hello.txt
   ```

   > **Note:** The `standard` StorageClass in Kind uses `volumeBindingMode: WaitForFirstConsumer`, which means the PV is only created once a Pod actually claims the PVC. This avoids scheduling conflicts in multi-node clusters.

5. **Use emptyDir for sharing data between containers (sidecar pattern)**

   An `emptyDir` volume is created when a Pod is assigned to a node and exists as long as the Pod runs — both containers can read and write to it. This is the Kubernetes equivalent of a shared `/tmp` directory.

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
   kubectl logs sidecar-demo -c consumer -f   # see live timestamps from producer
   kubectl delete pod sidecar-demo              # emptyDir data is gone
   ```

## Success Criteria

- [ ] You demonstrated that data written inside a container is lost when the Pod is deleted (Task 1)
- [ ] You created a PV and PVC manually, mounted them in a Pod, and proved data survives Pod deletion (Task 2)
- [ ] You deployed a Redis StatefulSet where each replica has its own PVC and data persists across Pod restarts (Task 3)
- [ ] You used the `standard` StorageClass for dynamic provisioning and a PV was created automatically (Task 4)
- [ ] You deployed a multi-container Pod using `emptyDir` and observed data flowing between the sidecar containers (Task 5)
- [ ] You can run `kubectl get pv,pvc` and explain the Status, Access Mode, and StorageClass of each entry
- [ ] You can explain when to use `emptyDir` vs PVC, and why StatefulSets are needed for databases

## Linux ↔ Kubernetes Reference

| Linux Concept | Kubernetes Equivalent |
|---|---|
| `/etc/fstab` (declare filesystems) | PersistentVolume (PV) — declares a storage resource |
| `mount /dev/sdb1 /mnt/data` | PersistentVolumeClaim (PVC) binding — requests and attaches storage |
| LVM / volume groups | StorageClass — defines *how* to provision storage |
| `/tmp` (ephemeral, gone on reboot) | `emptyDir` volume — lives only as long as the Pod |
| NFS mount (`mount -t nfs ...`) | NFS PersistentVolume or CSI NFS driver |
| `df -h` (list mounted filesystems) | `kubectl get pv,pvc` |
| `blkid` / `lsblk` (inspect block devices) | `kubectl describe pv <name>` |
| `fsck` (filesystem health check) | Volume health monitoring (CSI drivers) |

## Hints

<details>
<summary>Hint 1: PVC stuck in Pending?</summary>

Check if a PV exists that matches the PVC's request:
```bash
kubectl describe pvc manual-pvc
```

Look at the `Events` section. Common issues:
- The PVC requests more storage than the PV offers
- The `storageClassName` in the PVC doesn't match the PV (use `storageClassName: ""` for manual binding)
- The `accessModes` don't match between PV and PVC

</details>

<details>
<summary>Hint 2: What's the difference between Retain and Delete reclaim policies?</summary>

- **Retain** — When the PVC is deleted, the PV and its data are kept. An administrator must manually reclaim it. Use this for important data.
- **Delete** — When the PVC is deleted, the PV and its underlying storage are automatically removed. This is the default for most dynamic provisioners (including Kind's `standard` StorageClass).

Check a PV's reclaim policy:
```bash
kubectl get pv -o custom-columns=NAME:.metadata.name,RECLAIM:.spec.persistentVolumeReclaimPolicy
```

</details>

<details>
<summary>Hint 3: Why does the StatefulSet need a headless Service?</summary>

A headless Service (one with `clusterIP: None`) gives each Pod a stable DNS name like `redis-0.redis.default.svc.cluster.local`. StatefulSets require this for ordered Pod identity. Without it, the StatefulSet controller cannot assign stable network identities.

</details>

<details>
<summary>Hint 4: How do I see where Kind stores data on the host?</summary>

Kind runs inside Docker containers. To find where local-path-provisioner stores PV data:
```bash
kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.hostPath.path}{"\n"}{end}'
```

You can exec into the Kind node container to inspect the directory:
```bash
docker exec -it kind-control-plane ls -la /var/local-path-provisioner/
```

</details>

<details>
<summary>Hint 5: What is the OCI VolumeSource? (new in v1.36)</summary>

Kubernetes v1.36 graduated the **OCI VolumeSource** to GA. This lets you mount content from any OCI-compliant registry directly as a read-only volume — no PVC needed. It's useful for ML model weights, static assets, or configuration bundles that are published as OCI artifacts.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: oci-volume-demo
spec:
  volumes:
    - name: model-data
      oci:
        image: registry.example.com/models/my-model:v1
  containers:
    - name: app
      image: busybox:1.37
      command: ["sh", "-c", "ls -la /model && sleep 3600"]
      volumeMounts:
        - name: model-data
          mountPath: /model
```

</details>

<details>
<summary>Hint 6: Cloud-equivalent StorageClasses (for reference)</summary>

In production you'll use CSI drivers instead of Kind's local-path provisioner:

| Cloud | CSI Driver | StorageClass Example |
|---|---|---|
| AKS (Azure) | `disk.csi.azure.com` | `managed-csi` |
| EKS (AWS) | `ebs.csi.aws.com` | `gp3` |
| GKE (Google) | `pd.csi.storage.gke.io` | `standard-rwo` |

> **Important:** The old in-tree provisioners (`kubernetes.io/azure-disk`, `kubernetes.io/aws-ebs`, `kubernetes.io/gce-pd`) are **deprecated**. Always use CSI drivers in production.

</details>

## Learning Resources

- [Volumes — kubernetes.io](https://kubernetes.io/docs/concepts/storage/volumes/)
- [Persistent Volumes — kubernetes.io](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)
- [Storage Classes — kubernetes.io](https://kubernetes.io/docs/concepts/storage/storage-classes/)
- [StatefulSets — kubernetes.io](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/)
- [Configure a Pod to Use a PersistentVolume — kubernetes.io](https://kubernetes.io/docs/tasks/configure-pod-container/configure-persistent-volume-storage/)
- [Dynamic Volume Provisioning — kubernetes.io](https://kubernetes.io/docs/concepts/storage/dynamic-provisioning/)
- [OCI VolumeSource (v1.36 GA) — kubernetes.io](https://kubernetes.io/docs/concepts/storage/volumes/#oci)
- [local-path-provisioner — GitHub](https://github.com/rancher/local-path-provisioner)

## Break & Fix 🔧

After completing the challenge, try diagnosing these broken scenarios:

**1. PVC stuck in Pending — no matching PV**

Apply this PVC and figure out why it never binds:
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: broken-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: "nonexistent-class"
```
```bash
kubectl apply -f broken-pvc.yaml
kubectl get pvc broken-pvc            # Stuck in Pending
kubectl describe pvc broken-pvc       # Read the Events section
```
> **Fix:** The `storageClassName` references a class that doesn't exist. Change it to `standard` (Kind's default) or `""` and provide a matching PV.

**2. Pod stuck in ContainerCreating — volume mount issue**

Apply this Pod and diagnose why it won't start:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: broken-mount
spec:
  containers:
    - name: app
      image: busybox:1.37
      command: ["sleep", "3600"]
      volumeMounts:
        - name: my-data
          mountPath: /data
  volumes:
    - name: my-data
      persistentVolumeClaim:
        claimName: does-not-exist
```
```bash
kubectl apply -f broken-mount.yaml
kubectl get pod broken-mount          # ContainerCreating (stuck)
kubectl describe pod broken-mount     # Look for "persistentvolumeclaim not found"
```
> **Fix:** The PVC `does-not-exist` was never created. Create the PVC first, or correct the `claimName` to reference an existing PVC.

**3. Data lost after Pod deletion — used emptyDir instead of PVC**

A developer complains their data keeps disappearing. Can you spot the bug?
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: broken-persistence
spec:
  containers:
    - name: db
      image: redis:7-alpine
      volumeMounts:
        - name: redis-data
          mountPath: /data
  volumes:
    - name: redis-data
      emptyDir: {}
```
```bash
kubectl apply -f broken-persistence.yaml
kubectl exec broken-persistence -- redis-cli SET important "critical-data"
kubectl delete pod broken-persistence
kubectl apply -f broken-persistence.yaml
kubectl exec broken-persistence -- redis-cli GET important   # returns (nil)!
```
> **Fix:** `emptyDir` is ephemeral — it's destroyed when the Pod is deleted. Replace the `emptyDir` volume with a `persistentVolumeClaim` reference, and create a corresponding PVC. For databases, use a StatefulSet with `volumeClaimTemplates` so each replica gets its own durable storage.
