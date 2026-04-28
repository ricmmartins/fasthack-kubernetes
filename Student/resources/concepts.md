# Kubernetes Concepts for Linux Professionals

This document maps Linux concepts you already know to their Kubernetes equivalents.

## Architecture Comparison

### Linux Server
```
Hardware → Kernel → Processes → Services → Users
```

### Kubernetes Cluster
```
Nodes → Control Plane → Pods → Services → RBAC
```

## The Two Planes

| Plane | Purpose | Components |
|-------|---------|------------|
| **Control Plane** | The brain — decides what should run and where | API Server, etcd, Scheduler, Controller Manager |
| **Data Plane** | The body — executes workloads | kubelet, kube-proxy, Container Runtime |

## Key Analogies

### Process Management
- **Linux**: `systemctl start nginx` → starts a process
- **Kubernetes**: `kubectl apply -f deployment.yaml` → creates Pods managed by the cluster

### Networking
- **Linux**: `iptables`, `ip route`, `/etc/resolv.conf`
- **Kubernetes**: `kube-proxy` (iptables rules), CNI plugins, CoreDNS

### Storage
- **Linux**: `mount /dev/sdb1 /data`, `/etc/fstab`
- **Kubernetes**: PersistentVolume + PersistentVolumeClaim + StorageClass

### Security
- **Linux**: `chmod`, `chown`, `sudoers`, `iptables`
- **Kubernetes**: RBAC (Roles + RoleBindings), Pod Security Admission, NetworkPolicies

### Package Management
- **Linux**: `apt install nginx` or `yum install httpd`
- **Kubernetes**: `helm install my-app bitnami/nginx`

### Monitoring
- **Linux**: `top`, `htop`, `vmstat`, `journalctl`
- **Kubernetes**: `kubectl top`, Metrics Server, Prometheus, Grafana

## Declarative vs Imperative

The biggest mindset shift:

- **Linux (imperative)**: "Do this step, then this step, then this step"
- **Kubernetes (declarative)**: "This is the state I want — make it happen and keep it that way"

```yaml
# I want 3 nginx replicas running at all times
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: nginx
        image: nginx:stable
```

The cluster continuously reconciles: if a Pod dies, it creates a new one automatically.
