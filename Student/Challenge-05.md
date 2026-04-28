# Challenge 05 — Services and Networking

[< Previous Challenge](Challenge-04.md) | **[Home](../README.md)** | [Next Challenge >](Challenge-06.md)

## Introduction

On a Linux box, you expose a daemon to the network by binding it to a port, then manage access with `iptables` rules. If other services need to find it, you add entries to `/etc/hosts` or rely on DNS. Port forwarding with `ssh -L` lets you reach things behind a firewall. And when you want to lock down traffic, `ufw` or raw `iptables` rules act as your firewall.

Kubernetes follows the same ideas but automates them at a cluster level:

- **Services** replace manual `iptables` rules — they provide a stable IP and port for a set of Pods, automatically load-balancing traffic across healthy replicas.
- **CoreDNS** replaces `/etc/hosts` — every Service gets a DNS name (`service-name.namespace.svc.cluster.local`) that any Pod in the cluster can resolve.
- **`kubectl port-forward`** replaces `ssh -L` — it tunnels a local port to a Pod or Service inside the cluster.
- **NetworkPolicies** replace firewall rules — they control which Pods can talk to which, using label selectors instead of IP addresses.

In this challenge you will expose Pods with different Service types, use DNS to wire a multi-tier app together, and lock down traffic with a NetworkPolicy — all on your local Kind cluster.

> **Cluster requirement:** All exercises use a local [Kind](https://kind.sigs.k8s.io/) cluster. If you haven't created one yet:
> ```bash
> kind create cluster --name fasthack
> ```

## Description

1. **Create a ClusterIP Service to expose a Deployment internally**

   Create a Deployment named `web` running `nginx:stable` with **3 replicas**. Then create a ClusterIP Service named `web-svc` that routes traffic on port 80 to the Deployment's Pods. Verify the Service has Endpoints and that you can reach it from inside the cluster.

2. **Create a NodePort Service to access the app from outside the cluster**

   Create a second Service named `web-nodeport` of type `NodePort` that exposes the same `web` Deployment on a node port. Verify you can reach the app from your host machine by curling the node's IP and the assigned port.

3. **Use DNS resolution to discover Services by name**

   From a temporary Pod, use `nslookup` or `dig` to resolve `web-svc.default.svc.cluster.local`. Then verify the Pod's `/etc/resolv.conf` to see how Kubernetes auto-configures DNS. Confirm you can `curl http://web-svc` from within the same namespace, and `curl http://web-svc.default.svc.cluster.local` from a different namespace.

4. **Create a multi-tier app: frontend + backend connected via Services**

   - Create a Deployment named `backend` running `hashicorp/http-echo` with the argument `-text=Hello from backend`.
   - Create a ClusterIP Service named `backend-svc` exposing it on port 5678.
   - Create a Deployment named `frontend` running `curlimages/curl` with a command that loops forever, curling `http://backend-svc:5678` every 5 seconds.
   - Verify the frontend can reach the backend by checking the frontend Pod logs.

5. **Explore NetworkPolicy to restrict Pod-to-Pod communication**

   > **Note:** Kind's default CNI (`kindnet`) does **not** support NetworkPolicies. For this task, either recreate your cluster with Calico as the CNI, or install Calico on your existing cluster (see Hint 4 for instructions).

   - First, verify that all Pods can communicate with each other freely (the default).
   - Create a NetworkPolicy that **denies all ingress** to the `backend` Pods.
   - Confirm the frontend can **no longer** reach the backend.
   - Update the NetworkPolicy to allow ingress **only** from Pods with the label `app: frontend` on port 5678.
   - Confirm the frontend can reach the backend again, but other Pods still cannot.

## Success Criteria

- [ ] The `web-svc` ClusterIP Service has 3 Endpoints matching the `web` Deployment Pods.
- [ ] You can reach `web-svc` from inside the cluster using a temporary Pod (`kubectl run --rm -it` with `curl`).
- [ ] The `web-nodeport` NodePort Service is accessible from your host machine.
- [ ] DNS resolution for `web-svc.default.svc.cluster.local` returns the correct ClusterIP.
- [ ] The `frontend` Pod logs show repeated successful responses from the `backend` Service.
- [ ] After applying the deny-all NetworkPolicy, the frontend **cannot** reach the backend.
- [ ] After applying the allow-frontend NetworkPolicy, the frontend **can** reach the backend, but a test Pod without the `app: frontend` label **cannot**.

## Linux ↔ Kubernetes Reference

| Linux Concept | Kubernetes Equivalent | Notes |
|---|---|---|
| `iptables` rules | Service (ClusterIP/NodePort) | kube-proxy programs iptables (or IPVS) rules to route traffic to Pod IPs. |
| `/etc/hosts` | CoreDNS | Automatic DNS for every Service — no manual entries needed. |
| DNS resolution (`dig`, `nslookup`) | `service.namespace.svc.cluster.local` | Every Service gets a fully qualified domain name. Within the same namespace, the short name works. |
| Port forwarding (`ssh -L`) | `kubectl port-forward` | Tunnels a local port to a Pod or Service — useful for debugging without exposing NodePorts. |
| Firewall rules (`ufw` / `iptables`) | NetworkPolicy | Controls ingress/egress per Pod using label selectors instead of IPs. |
| `netstat -tlnp` / `ss -tlnp` | `kubectl get endpoints` | Shows the actual Pod IPs and ports backing a Service. |
| `/etc/resolv.conf` | Pod's `/etc/resolv.conf` (auto-configured) | kubelet injects nameserver entries pointing to CoreDNS so Pods can resolve Services. |

## Hints

<details>
<summary>Hint 1: Creating the Deployment and ClusterIP Service</summary>

Create a file named `web-deployment.yaml`:

```yaml
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
          ports:
            - containerPort: 80
```

Create a file named `web-svc.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-svc
spec:
  selector:
    app: web
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
```

Apply both and verify:

```bash
kubectl apply -f web-deployment.yaml
kubectl apply -f web-svc.yaml

# Check the Service exists and has a ClusterIP
kubectl get svc web-svc

# Check that Endpoints are populated (should list 3 Pod IPs)
kubectl get endpoints web-svc

# Test from inside the cluster using a temporary Pod
kubectl run tmp-curl --rm -it --restart=Never --image=curlimages/curl -- curl -s http://web-svc
```

</details>

<details>
<summary>Hint 2: NodePort Service and DNS discovery</summary>

Create a file named `web-nodeport.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-nodeport
spec:
  type: NodePort
  selector:
    app: web
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
```

```bash
kubectl apply -f web-nodeport.yaml

# See the assigned NodePort (30000–32767 range)
kubectl get svc web-nodeport

# Get the node's internal IP
kubectl get nodes -o wide

# In Kind, use the container IP to reach the NodePort
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
NODE_PORT=$(kubectl get svc web-nodeport -o jsonpath='{.spec.ports[0].nodePort}')
curl -s http://${NODE_IP}:${NODE_PORT}
```

**DNS discovery — verify resolution from inside the cluster:**

```bash
# Launch a temporary DNS debugging Pod
kubectl run tmp-dns --rm -it --restart=Never --image=busybox:stable -- sh

# Inside the Pod:
nslookup web-svc
nslookup web-svc.default.svc.cluster.local
cat /etc/resolv.conf
wget -qO- http://web-svc
exit
```

Notice that `/etc/resolv.conf` contains `search default.svc.cluster.local svc.cluster.local cluster.local` — this is how the short name `web-svc` resolves automatically within the same namespace.

</details>

<details>
<summary>Hint 3: Multi-tier app (frontend + backend)</summary>

Create a file named `multi-tier.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
    spec:
      containers:
        - name: echo
          image: hashicorp/http-echo
          args:
            - "-text=Hello from backend"
          ports:
            - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: backend-svc
spec:
  selector:
    app: backend
  ports:
    - protocol: TCP
      port: 5678
      targetPort: 5678
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      containers:
        - name: curl
          image: curlimages/curl
          command: ["sh", "-c"]
          args:
            - |
              while true; do
                echo "$(date) - $(curl -s http://backend-svc:5678)"
                sleep 5
              done
```

```bash
kubectl apply -f multi-tier.yaml

# Wait for all Pods to be ready
kubectl get pods -l 'app in (frontend,backend)' --watch

# Check the frontend logs — you should see periodic responses from the backend
kubectl logs -l app=frontend --follow
```

You should see output like:
```
Mon Jun 16 12:00:00 UTC 2025 - Hello from backend
Mon Jun 16 12:00:05 UTC 2025 - Hello from backend
```

</details>

<details>
<summary>Hint 4: NetworkPolicy (including Calico setup for Kind)</summary>

**Step 1 — Install a CNI that supports NetworkPolicy in Kind:**

Kind's default CNI (`kindnet`) does not enforce NetworkPolicies. You have two options:

**Option A — Create a new cluster with Calico:**

```bash
# Delete existing cluster
kind delete cluster --name fasthack

# Create a cluster without the default CNI
cat <<EOF | kind create cluster --name fasthack --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
  podSubnet: 192.168.0.0/16
EOF

# Install Calico
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.3/manifests/calico.yaml

# Wait for Calico Pods to be ready
kubectl -n kube-system get pods -l k8s-app=calico-node --watch
```

**Option B — If you want to keep your cluster, install Calico alongside kindnet** (not recommended for production but works for learning):

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.3/manifests/calico.yaml
kubectl -n kube-system get pods -l k8s-app=calico-node --watch
```

After Calico is running, re-apply your Deployments and Services from the previous tasks if you recreated the cluster.

**Step 2 — Verify open communication (before any policy):**

```bash
# Test from a pod without the frontend label
kubectl run tmp-test --rm -it --restart=Never --image=curlimages/curl -- curl -s --max-time 5 http://backend-svc:5678
# Expected: "Hello from backend"
```

**Step 3 — Deny all ingress to backend Pods:**

Create a file named `deny-all-backend.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-backend
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
    - Ingress
```

```bash
kubectl apply -f deny-all-backend.yaml

# Test — this should now time out
kubectl run tmp-test --rm -it --restart=Never --image=curlimages/curl -- curl -s --max-time 5 http://backend-svc:5678
# Expected: timeout / connection refused

# Check frontend logs — requests should also be failing
kubectl logs -l app=frontend --tail=5
```

**Step 4 — Allow ingress only from the frontend:**

Create a file named `allow-frontend-to-backend.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: frontend
      ports:
        - protocol: TCP
          port: 5678
```

```bash
# Remove the deny-all policy first
kubectl delete networkpolicy deny-all-backend

# Apply the selective allow policy
kubectl apply -f allow-frontend-to-backend.yaml

# Frontend should work again
kubectl logs -l app=frontend --tail=5
# Expected: "Hello from backend"

# But a Pod without app=frontend label should still be blocked
kubectl run tmp-test --rm -it --restart=Never --image=curlimages/curl -- curl -s --max-time 5 http://backend-svc:5678
# Expected: timeout
```

</details>

## Learning Resources

- [Service — Kubernetes official docs](https://kubernetes.io/docs/concepts/services-networking/service/)
- [DNS for Services and Pods](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/)
- [Connecting Applications with Services](https://kubernetes.io/docs/tutorials/services/connect-applications-service/)
- [NetworkPolicies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [kubectl port-forward](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_port-forward/)
- [Debugging DNS Resolution](https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/)
- [Kind — Configuration](https://kind.sigs.k8s.io/docs/user/configuration/)

## Break & Fix 🔧

Try each scenario, diagnose the problem, and fix it.

### Scenario 1 — Service selector doesn't match Pod labels (empty Endpoints)

Create a Service with a mismatched selector:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: broken-svc
spec:
  selector:
    app: webapp
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
```

```bash
kubectl apply -f broken-svc.yaml
kubectl get endpoints broken-svc
```

**What you'll see:** The Endpoints list is `<none>` — no Pods match the selector `app: webapp` because the Deployment uses `app: web`.

**Diagnose:**

```bash
# Compare the Service selector with actual Pod labels
kubectl describe svc broken-svc | grep Selector
kubectl get pods --show-labels
```

**Linux analogy:** This is like writing an `iptables` DNAT rule that forwards to an IP address where nothing is listening — packets arrive but nobody answers.

<details>
<summary>Fix</summary>

Update the Service selector to match the Pod labels:

```bash
kubectl patch svc broken-svc -p '{"spec":{"selector":{"app":"web"}}}'
# Or edit the YAML and re-apply
kubectl get endpoints broken-svc
```

You should now see the Pod IPs listed as Endpoints.

</details>

---

### Scenario 2 — Wrong `targetPort` in Service (connection refused)

Create a Service that points to the wrong port:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: wrong-port-svc
spec:
  selector:
    app: web
  ports:
    - protocol: TCP
      port: 80
      targetPort: 8080
```

```bash
kubectl apply -f wrong-port-svc.yaml

# Endpoints exist but the port is wrong
kubectl get endpoints wrong-port-svc

# Try to connect — this will fail
kubectl run tmp-curl --rm -it --restart=Never --image=curlimages/curl -- curl -s --max-time 5 http://wrong-port-svc
```

**What you'll see:** The Endpoints list shows Pod IPs on port 8080, but nginx listens on port 80. Connections get "connection refused."

**Diagnose:**

```bash
# Check what port the Endpoints are actually using
kubectl get endpoints wrong-port-svc -o yaml

# Check what port the container is actually listening on
kubectl exec deploy/web -- ss -tlnp
```

**Linux analogy:** This is like setting up a port-forward to `localhost:8080` when the daemon is actually listening on `localhost:80`.

<details>
<summary>Fix</summary>

Change `targetPort` to match the container port:

```bash
kubectl patch svc wrong-port-svc -p '{"spec":{"ports":[{"port":80,"targetPort":80,"protocol":"TCP"}]}}'

# Verify
kubectl run tmp-curl --rm -it --restart=Never --image=curlimages/curl -- curl -s http://wrong-port-svc
```

</details>

---

### Scenario 3 — NetworkPolicy denying all traffic (app unreachable)

Apply a NetworkPolicy that denies all ingress to all Pods in the namespace:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all
spec:
  podSelector: {}
  policyTypes:
    - Ingress
```

```bash
kubectl apply -f deny-all.yaml

# Try to reach the backend — should fail
kubectl run tmp-curl --rm -it --restart=Never --image=curlimages/curl -- curl -s --max-time 5 http://backend-svc:5678

# Check frontend logs — also failing
kubectl logs -l app=frontend --tail=3
```

**What you'll see:** All inter-Pod communication in the namespace is blocked. The empty `podSelector: {}` selects **every** Pod, and the `Ingress` policy type with no `ingress` rules means "deny all inbound."

**Diagnose:**

```bash
# List all NetworkPolicies in the namespace
kubectl get networkpolicy

# Inspect the deny-all policy
kubectl describe networkpolicy deny-all
```

**Linux analogy:** This is like running `iptables -P INPUT DROP` without adding any ACCEPT rules — everything is blocked.

<details>
<summary>Fix</summary>

Either delete the blanket deny policy:

```bash
kubectl delete networkpolicy deny-all
```

Or replace it with a more targeted policy that only restricts specific Pods while allowing the traffic you need (like the `allow-frontend-to-backend` policy from Task 5).

</details>
