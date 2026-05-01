# Conceitos Kubernetes para Profissionais Linux

Este documento mapeia conceitos Linux que você já conhece para seus equivalentes em Kubernetes.

## Comparação de Arquitetura

### Servidor Linux
```
Hardware → Kernel → Processos → Serviços → Usuários
```

### Cluster Kubernetes
```
Nodes → Control Plane → Pods → Services → RBAC
```

## Os Dois Planos

| Plano | Propósito | Componentes |
|-------|---------|------------|
| **Control Plane** | O cérebro — decide o que deve rodar e onde | API Server, etcd, Scheduler, Controller Manager |
| **Data Plane** | O corpo — executa os workloads | kubelet, kube-proxy, Container Runtime |

## Analogias Principais

### Gerenciamento de Processos
- **Linux**: `systemctl start nginx` → inicia um processo
- **Kubernetes**: `kubectl apply -f deployment.yaml` → cria Pods gerenciados pelo cluster

### Rede
- **Linux**: `iptables`, `ip route`, `/etc/resolv.conf`
- **Kubernetes**: `kube-proxy` (regras iptables), plugins CNI, CoreDNS

### Armazenamento
- **Linux**: `mount /dev/sdb1 /data`, `/etc/fstab`
- **Kubernetes**: PersistentVolume + PersistentVolumeClaim + StorageClass

### Segurança
- **Linux**: `chmod`, `chown`, `sudoers`, `iptables`
- **Kubernetes**: RBAC (Roles + RoleBindings), Pod Security Admission, NetworkPolicies

### Gerenciamento de Pacotes
- **Linux**: `apt install nginx` ou `yum install httpd`
- **Kubernetes**: `helm install my-app bitnami/nginx`

### Monitoramento
- **Linux**: `top`, `htop`, `vmstat`, `journalctl`
- **Kubernetes**: `kubectl top`, Metrics Server, Prometheus, Grafana

## Declarativo vs Imperativo

A maior mudança de mentalidade:

- **Linux (imperativo)**: "Faça este passo, depois este passo, depois este passo"
- **Kubernetes (declarativo)**: "Este é o estado que eu quero — faça acontecer e mantenha assim"

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

O cluster reconcilia continuamente: se um Pod morre, ele cria um novo automaticamente.
