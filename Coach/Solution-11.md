# Solution 11 — Helm and Kustomize

[< Back to Challenge](../Student/Challenge-11.md) | **[Home](README.md)**

---

## Task 1: Install Helm and Add the Bitnami Repository

### Step-by-step

```bash
# Verify Helm is installed
helm version
```

Expected output (version will vary):

```
version.BuildInfo{Version:"v3.17.x", ...}
```

If Helm is not installed:

```bash
# Linux / macOS
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Or: brew install helm       (macOS)
# Or: sudo snap install helm --classic  (Ubuntu)
```

Add the Bitnami repo and update:

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
```

Expected output:

```
"bitnami" has been added to your repositories
Hang tight while we grab the latest from your chart repositories...
...Successfully got an update from the "bitnami" chart repository
Update Complete. ⎈Happy Helming!⎈
```

Explore available charts:

```bash
helm search repo bitnami | head -20
helm search repo bitnami/nginx
```

### Verification

```bash
helm repo list
```

Expected:

```
NAME    URL
bitnami https://charts.bitnami.com/bitnami
```

> **Coach tip:** If students already have Helm and the Bitnami repo, they can skip straight to Task 2. The `helm repo update` command is the equivalent of `apt update` — always run it before installing.

---

## Task 2: Deploy a Chart with Default Values

### Step-by-step

```bash
helm install my-nginx bitnami/nginx
```

> **⚠️ Kind gotcha:** The Bitnami nginx chart defaults to `service.type=LoadBalancer`. On Kind there is no cloud load balancer, so the Service will stay in `Pending` state forever. The install will still succeed, but the Service won't get an external IP.

Check what was created:

```bash
helm list
helm status my-nginx
kubectl get all -l app.kubernetes.io/instance=my-nginx
```

Expected output shows a Deployment, ReplicaSet, Pod(s), and a Service. The Service `EXTERNAL-IP` will show `<pending>` on Kind — this is expected.

View the default values:

```bash
helm show values bitnami/nginx | head -50
```

### Verification

```bash
# Pods should be Running
kubectl get pods -l app.kubernetes.io/instance=my-nginx
```

Expected:

```
NAME                        READY   STATUS    RESTARTS   AGE
my-nginx-xxxxxxxxx-xxxxx    1/1     Running   0          60s
```

To actually reach the nginx service on Kind, use port-forward:

```bash
kubectl port-forward svc/my-nginx 8080:80
# In another terminal:
curl http://localhost:8080
```

> **Coach tip:** If the install hangs, students likely hit the LoadBalancer issue. Tell them to Ctrl+C and either add `--set service.type=ClusterIP` or use `--wait=false`.

---

## Task 3: Customize a Release with `--set` and `values.yaml`

### Step-by-step

**Method 1 — Inline `--set`:**

```bash
helm upgrade my-nginx bitnami/nginx \
  --set replicaCount=3 \
  --set service.type=ClusterIP
```

Expected output:

```
Release "my-nginx" has been upgraded. Happy Helming!
```

**Method 2 — Values file:**

Create `my-nginx-values.yaml`:

```yaml
replicaCount: 2
service:
  type: ClusterIP
  port: 8080
```

Apply it:

```bash
helm upgrade my-nginx bitnami/nginx -f my-nginx-values.yaml
```

### Verification

```bash
kubectl get pods -l app.kubernetes.io/instance=my-nginx
```

Expected: 2 pods running (matching `replicaCount: 2`).

```bash
kubectl get svc -l app.kubernetes.io/instance=my-nginx
```

Expected: Service type is `ClusterIP` and port is `8080`.

> **Coach tip:** Explain that `--set` is for quick one-off changes (like command-line flags), while `values.yaml` is the version-controllable, repeatable approach (like editing `/etc/default/nginx`).

---

## Task 4: Upgrade and Rollback a Helm Release

### Step-by-step

Check the current release history:

```bash
helm history my-nginx
```

Expected output shows revisions 1, 2, 3 (from Tasks 2 and 3).

Perform another upgrade:

```bash
helm upgrade my-nginx bitnami/nginx \
  --set replicaCount=4 \
  --set service.type=ClusterIP
```

Verify the new revision:

```bash
helm history my-nginx
```

Expected: A new revision appears with status `deployed`.

Now rollback:

```bash
helm rollback my-nginx 1
```

Expected output:

```
Rollback was a success! Happy Helming!
```

### Verification

```bash
helm history my-nginx
```

Expected: A new revision is created (rollback creates a forward revision, not a reverse). The description says "Rollback to 1".

```bash
kubectl get pods -l app.kubernetes.io/instance=my-nginx
```

Expected: Pod count matches the original revision 1 configuration.

> **Coach tip:** Emphasize that `helm rollback` creates a **new** revision — revision numbers always increase. This is different from `git revert` which creates a new commit.

---

## Task 5: Create a Helm Chart from Scratch

### Step-by-step

```bash
helm create myapp
```

Expected directory structure:

```
myapp/
├── Chart.yaml
├── values.yaml
├── charts/
├── templates/
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   ├── hpa.yaml
│   ├── serviceaccount.yaml
│   ├── _helpers.tpl
│   ├── NOTES.txt
│   └── tests/
│       └── test-connection.yaml
└── .helmignore
```

Edit `myapp/values.yaml` to customize defaults:

```yaml
replicaCount: 2

image:
  repository: nginx
  pullPolicy: IfNotPresent
  tag: "stable"

service:
  type: ClusterIP
  port: 80

resources:
  requests:
    cpu: 100m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 128Mi
```

Lint, dry-run, and install:

```bash
# Lint the chart
helm lint myapp/

# Dry-run to preview generated manifests
helm install myapp-release myapp/ --dry-run

# Install for real
helm install myapp-release myapp/
```

### Verification

```bash
helm list
```

Expected:

```
NAME            NAMESPACE  REVISION  STATUS    CHART        APP VERSION
my-nginx        default    X         deployed  nginx-X.X.X  X.X.X
myapp-release   default    1         deployed  myapp-0.1.0  1.16.0
```

```bash
kubectl get all -l app.kubernetes.io/instance=myapp-release
```

Expected: 2 pods running (from `replicaCount: 2`), a Service, a Deployment, and a ReplicaSet.

Clean up:

```bash
helm uninstall myapp-release
```

> **Coach tip:** Walk students through the `templates/deployment.yaml` file and show how `{{ .Values.replicaCount }}` maps to `values.yaml`. This is the key insight — Helm templates are Go templates that render into Kubernetes YAML.

---

## Task 6: Kustomize Base + Overlays

### Step-by-step

Create the directory structure:

```bash
mkdir -p kustom-demo/base kustom-demo/overlays/dev kustom-demo/overlays/prod
```

Create `kustom-demo/base/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web-app
  template:
    metadata:
      labels:
        app: web-app
    spec:
      containers:
        - name: nginx
          image: nginx:stable
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
```

Create `kustom-demo/base/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-app
spec:
  selector:
    app: web-app
  ports:
    - port: 80
      targetPort: 80
```

Create `kustom-demo/base/kustomization.yaml`:

```yaml
resources:
  - deployment.yaml
  - service.yaml
```

Create `kustom-demo/overlays/dev/kustomization.yaml`:

```yaml
resources:
  - ../../base

namePrefix: dev-

labels:
  - pairs:
      env: dev

replicas:
  - name: web-app
    count: 1
```

Create `kustom-demo/overlays/prod/kustomization.yaml`:

```yaml
resources:
  - ../../base

namePrefix: prod-

labels:
  - pairs:
      env: prod

replicas:
  - name: web-app
    count: 3
```

Preview the rendered output:

```bash
kubectl kustomize kustom-demo/overlays/dev/
kubectl kustomize kustom-demo/overlays/prod/
```

Expected: Dev output shows `dev-web-app` with 1 replica and `env: dev` label. Prod output shows `prod-web-app` with 3 replicas and `env: prod` label.

Deploy both overlays:

```bash
kubectl create namespace dev
kubectl create namespace prod

kubectl apply -k kustom-demo/overlays/dev/ -n dev
kubectl apply -k kustom-demo/overlays/prod/ -n prod
```

### Verification

```bash
kubectl get all -n dev
```

Expected: `dev-web-app` deployment with 1 replica.

```bash
kubectl get all -n prod
```

Expected: `prod-web-app` deployment with 3 replicas.

```bash
# Verify the labels
kubectl get pods -n dev --show-labels
kubectl get pods -n prod --show-labels
```

Expected: Dev pods have `env=dev`, prod pods have `env=prod`.

Clean up:

```bash
kubectl delete -k kustom-demo/overlays/dev/ -n dev
kubectl delete -k kustom-demo/overlays/prod/ -n prod
kubectl delete namespace dev prod
```

> **Coach tip:** The key insight is that Kustomize never modifies the base files. The base is the "upstream default" and overlays are your "local overrides." This is the `/etc/default/nginx` analogy.

---

## Task 7: Helm vs Kustomize Comparison

This is a discussion/conceptual task. Ensure students can articulate:

| Aspect | Helm | Kustomize |
|---|---|---|
| **Approach** | Templating (`{{ .Values.x }}`) | Patching (overlays on plain YAML) |
| **Packaging** | Charts (versioned, distributable archives) | Directories of YAML files |
| **Distribution** | Chart repositories (like `apt` repos) | Git repositories |
| **Lifecycle** | Install, upgrade, rollback, uninstall | Apply only (use Git for rollback) |
| **Dependencies** | Built-in sub-chart support | Manual (list in `resources`) |
| **Learning curve** | Steeper (Go templates, chart structure) | Gentler (plain YAML + patches) |
| **Best for** | Third-party apps; complex parameterization | Internal apps; environment promotion |
| **Built into kubectl** | No (separate binary) | Yes (`kubectl apply -k`) |

**Rule of thumb:**
- **Helm** → consuming third-party apps (databases, monitoring stacks) or distributing your own app to others
- **Kustomize** → you own the manifests, want plain YAML, and need dev→staging→prod promotion
- **Both together** → install a Helm chart, then apply Kustomize patches on the rendered output

---

## Final Cleanup

```bash
helm uninstall my-nginx 2>/dev/null
kubectl delete -k kustom-demo/overlays/dev/ -n dev 2>/dev/null
kubectl delete -k kustom-demo/overlays/prod/ -n prod 2>/dev/null
kubectl delete namespace dev prod 2>/dev/null
rm -rf myapp/ kustom-demo/ my-nginx-values.yaml
```

---

## Common Issues

| Problem | Cause | Fix |
|---------|-------|-----|
| `helm install` hangs forever | Chart defaults to `LoadBalancer` Service; Kind has no LB provider | Add `--set service.type=ClusterIP` or use `--wait=false` |
| `helm search repo` returns nothing | Repo cache is stale | Run `helm repo update` first |
| `kubectl kustomize` says "accumulating resources" | Wrong relative path in `kustomization.yaml` | Paths are relative to the `kustomization.yaml` file — check `../../base` is correct |
| Pods stuck in `Pending` after chart install | Insufficient resources on Kind node | Check `kubectl describe pod` events; reduce resource requests in values |
| `helm create` chart fails lint | Leftover template variables referencing undefined values | Edit `values.yaml` to match what the templates expect |
| Kustomize overlay not changing replicas | `replicas` field uses the Deployment `metadata.name`, not the overlay name | Ensure the name in the `replicas` block matches the **base** Deployment name (before any prefix) |
