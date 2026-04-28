# Challenge 11 — Helm and Kustomize

[< Previous Challenge](Challenge-10.md) | **[Home](../README.md)** | [Next Challenge >](Challenge-12.md)

## Introduction

On a Linux server, you rarely compile every piece of software from source. Instead you use **package managers** — `apt`, `yum`, `dnf` — to install, upgrade, and remove software with a single command. The package manager handles dependencies, versioning, and rollback. When you need to override default configuration, you drop files into directories like `/etc/default/` or `/etc/nginx/conf.d/` — layering your customizations on top of upstream defaults without editing the original files.

Kubernetes has its own equivalents:

| Linux Concept | Kubernetes Equivalent | What It Does |
|---|---|---|
| `apt` / `yum` / `dnf` (package manager) | **Helm** | Packages, installs, upgrades, and rolls back complete Kubernetes applications |
| `/etc/apt/sources.list` (package repos) | `helm repo add` | Points Helm at a chart repository |
| `/etc/default/nginx` (config overrides) | **Kustomize** overlays | Layers environment-specific patches on top of base manifests |

**Helm** is the package manager for Kubernetes. A Helm **chart** bundles all the YAML manifests a Kubernetes application needs — Deployments, Services, ConfigMaps, Ingress — into a single versioned, parameterizable package. You install it with one command, customize it with values, and roll it back if something goes wrong.

**Kustomize** takes a different approach. Instead of templates with placeholders, Kustomize uses **overlays** — small patch files that modify a set of base manifests. It's built into `kubectl` (no extra tool needed) and follows a purely declarative model: you describe the desired end state, and Kustomize merges it for you.

In this challenge you will learn both tools, understand when to use each, and gain the hands-on skills to manage Kubernetes applications like a sysadmin manages packages.

> **Cluster requirement:** All exercises use a local [Kind](https://kind.sigs.k8s.io/) cluster — no cloud account needed. If you haven't created one yet, run:
> ```bash
> kind create cluster --name fasthack
> ```

## Description

### Task 1 — Install Helm and Add the Bitnami Repository

Just as `apt` needs `/etc/apt/sources.list` to know where to find packages, Helm needs **chart repositories** to know where to find charts.

First, verify Helm is installed:

```bash
helm version
```

If Helm is not installed, install it:

```bash
# Linux / macOS (via script)
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Or via package manager
# macOS:  brew install helm
# Ubuntu: sudo snap install helm --classic
```

Now add the Bitnami chart repository — one of the largest collections of curated, production-ready Helm charts:

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
```

Explore what's available:

```bash
# List all charts in the Bitnami repo
helm search repo bitnami | head -20

# Search for a specific chart
helm search repo bitnami/nginx
```

This is the equivalent of running `apt update && apt search nginx` on Debian/Ubuntu.

### Task 2 — Deploy a Chart with Default Values

Install the Bitnami NGINX chart with default settings:

```bash
helm install my-nginx bitnami/nginx
```

Inspect what Helm created:

```bash
# List all releases
helm list

# See the Kubernetes resources the chart created
kubectl get all -l app.kubernetes.io/instance=my-nginx

# Check the status of the release
helm status my-nginx
```

Now look at the **default values** the chart uses — this is the equivalent of `apt show nginx` or reading the default config:

```bash
helm show values bitnami/nginx | head -50
```

### Task 3 — Customize a Release with `--set` and `values.yaml`

Helm charts are parameterized via **values**. You can override defaults two ways:

**Method 1 — Inline with `--set`** (quick, ad hoc):

```bash
helm upgrade my-nginx bitnami/nginx \
  --set replicaCount=3 \
  --set service.type=ClusterIP
```

**Method 2 — With a `values.yaml` file** (repeatable, version-controllable):

Create a file called `my-nginx-values.yaml`:

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

Verify the changes took effect:

```bash
kubectl get pods -l app.kubernetes.io/instance=my-nginx
kubectl get svc -l app.kubernetes.io/instance=my-nginx
```

> **Linux analogy:** `--set` is like passing `-o` flags to a command; a `values.yaml` is like editing `/etc/default/nginx` — a persistent configuration file that survives upgrades.

### Task 4 — Upgrade and Rollback a Helm Release

Helm tracks every change as a **revision**. This is like having `apt` snapshots you can revert to.

Check the release history:

```bash
helm history my-nginx
```

Upgrade to a different configuration:

```bash
helm upgrade my-nginx bitnami/nginx \
  --set replicaCount=4 \
  --set service.type=ClusterIP
```

Verify a new revision was created:

```bash
helm history my-nginx
```

Something went wrong? **Rollback** to the previous revision:

```bash
# Roll back to the previous revision
helm rollback my-nginx 1
```

Verify the rollback:

```bash
helm history my-nginx
kubectl get pods -l app.kubernetes.io/instance=my-nginx
```

> **Linux analogy:** `helm rollback` is like `apt install nginx=1.18.0-0ubuntu1` — pinning to a known-good version. Helm makes this even easier because it tracks the full state, not just the package version.

### Task 5 — Create a Helm Chart from Scratch

Now create your own chart. This is like writing your own `.deb` or `.rpm` package.

```bash
helm create myapp
```

Explore the generated structure:

```
myapp/
├── Chart.yaml          # Chart metadata (name, version, description)
├── values.yaml         # Default configuration values
├── charts/             # Dependencies (sub-charts)
├── templates/          # Kubernetes manifest templates
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   ├── hpa.yaml
│   ├── serviceaccount.yaml
│   ├── _helpers.tpl    # Template helper functions
│   ├── NOTES.txt       # Post-install message
│   └── tests/
│       └── test-connection.yaml
└── .helmignore         # Files to exclude from packaging
```

Edit `myapp/values.yaml` to customize the defaults:

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

Validate and install your chart:

```bash
# Lint the chart for errors
helm lint myapp/

# Dry-run to see what would be created (without actually applying)
helm install myapp-release myapp/ --dry-run

# Install for real
helm install myapp-release myapp/
```

Verify it's running:

```bash
helm list
kubectl get all -l app.kubernetes.io/instance=myapp-release
```

Clean up the Helm release when done:

```bash
helm uninstall myapp-release
```

### Task 6 — Introduction to Kustomize: Base + Overlays

Kustomize takes a fundamentally different approach from Helm. Instead of templates with `{{ .Values.x }}` placeholders, Kustomize uses **plain YAML** with **patches** layered on top. It's built directly into `kubectl` — no extra binary needed.

**Concept:** You define a **base** set of manifests, then create **overlays** (dev, staging, prod) that modify only what needs to change.

Create the following directory structure:

```
kustom-demo/
├── base/
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   └── service.yaml
└── overlays/
    ├── dev/
    │   └── kustomization.yaml
    └── prod/
        └── kustomization.yaml
```

**Step 1 — Create the base manifests:**

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

**Step 2 — Create the dev overlay:**

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

**Step 3 — Create the prod overlay:**

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

**Step 4 — Preview and apply:**

Preview what each overlay produces (without applying):

```bash
# Preview the dev overlay
kubectl kustomize kustom-demo/overlays/dev/

# Preview the prod overlay
kubectl kustomize kustom-demo/overlays/prod/
```

Notice how the base manifests are identical, but the overlays change the name prefix, labels, and replica count. Apply both to different namespaces:

```bash
# Create namespaces
kubectl create namespace dev
kubectl create namespace prod

# Apply dev overlay
kubectl apply -k kustom-demo/overlays/dev/ -n dev

# Apply prod overlay
kubectl apply -k kustom-demo/overlays/prod/ -n prod
```

Verify both environments:

```bash
kubectl get all -n dev
kubectl get all -n prod
```

You should see `dev-web-app` with 1 replica in the `dev` namespace and `prod-web-app` with 3 replicas in `prod`.

> **Linux analogy:** The base is like the upstream package's default config (`/etc/nginx/nginx.conf`). The overlays are like your site-specific overrides in `/etc/nginx/conf.d/` — you never edit the original, you layer on top.

### Task 7 — Compare Helm vs Kustomize: When to Use Which

Now that you've used both tools, let's understand when to reach for each:

| Aspect | Helm | Kustomize |
|---|---|---|
| **Approach** | Templating (`{{ .Values.x }}`) | Patching (overlay on plain YAML) |
| **Packaging** | Charts (versioned, distributable archives) | Directories of YAML files |
| **Distribution** | Chart repositories (like `apt` repos) | Git repositories |
| **Lifecycle mgmt** | Install, upgrade, rollback, uninstall | Apply only (use Git for rollback) |
| **Dependencies** | Built-in sub-chart support | Manual (list in `resources`) |
| **Learning curve** | Steeper (Go templates, chart structure) | Gentler (plain YAML + patches) |
| **Best for** | Distributing apps to others; complex parameterization | Internal apps; environment promotion (dev→prod) |
| **Built into kubectl** | No (separate binary) | Yes (`kubectl apply -k`) |

**Rule of thumb:**

- **Use Helm** when you're consuming third-party applications (databases, monitoring stacks, ingress controllers) or packaging your own app for distribution to multiple teams/clusters.
- **Use Kustomize** when you own the manifests, want to keep them as plain YAML, and need to promote the same app across environments (dev → staging → prod).
- **You can use both together** — install a Helm chart, then layer Kustomize patches on top of the rendered output.

### Clean Up

```bash
# Remove Helm releases
helm uninstall my-nginx 2>/dev/null

# Remove Kustomize resources
kubectl delete -k kustom-demo/overlays/dev/ -n dev 2>/dev/null
kubectl delete -k kustom-demo/overlays/prod/ -n prod 2>/dev/null
kubectl delete namespace dev prod 2>/dev/null

# Remove local files (optional)
rm -rf myapp/ kustom-demo/ my-nginx-values.yaml
```

## Success Criteria

- [ ] Helm is installed and `helm version` returns a v3.x version.
- [ ] You added the Bitnami repo and can run `helm search repo bitnami/nginx` successfully.
- [ ] You deployed `bitnami/nginx` with `helm install` and verified the Pods and Service are running.
- [ ] You customized the release using both `--set` flags and a `values.yaml` file.
- [ ] You performed a `helm upgrade` followed by a `helm rollback` and verified the release history shows multiple revisions.
- [ ] You created a Helm chart from scratch with `helm create`, linted it, and installed it successfully.
- [ ] You created a Kustomize base with a Deployment and Service.
- [ ] You created dev and prod overlays that change the name prefix, labels, and replica count.
- [ ] `kubectl kustomize` shows the correct rendered output for each overlay.
- [ ] You deployed both overlays to separate namespaces and verified the differences (replica count, name prefix, labels).
- [ ] You can explain when to use Helm vs Kustomize and give a concrete example of each.

## Linux ↔ Kubernetes Reference

| Linux Concept | Kubernetes Equivalent | Notes |
|---|---|---|
| `apt install nginx` | `helm install my-nginx bitnami/nginx` | Install a packaged application with one command |
| `apt upgrade nginx` | `helm upgrade my-nginx bitnami/nginx` | Upgrade to a new version or new config values |
| `apt remove nginx` | `helm uninstall my-nginx` | Remove all resources associated with a release |
| `/etc/apt/sources.list` | `helm repo add` | Register a package/chart repository |
| `dpkg -l` / `rpm -qa` | `helm list` | List all installed packages/releases |
| `apt show nginx` | `helm show values bitnami/nginx` | View package metadata and default configuration |
| `/etc/default/nginx` (config overrides) | Kustomize overlays | Layer environment-specific changes on top of defaults |
| `apt-cache policy nginx` (version pinning) | `helm rollback my-nginx 1` | Revert to a known-good release revision |
| `dpkg -L nginx` (list package files) | `helm get manifest my-nginx` | Show all Kubernetes manifests installed by a release |

## Hints

<details>
<summary>Hint 1: Helm install hangs — chart is waiting for a LoadBalancer</summary>

Many Bitnami charts default to `service.type=LoadBalancer`. On Kind, there is no cloud load balancer, so the Service will stay in `Pending` state forever.

**Fix:** Override the service type during install:

```bash
helm install my-nginx bitnami/nginx --set service.type=ClusterIP
```

Or if you already installed it:

```bash
helm upgrade my-nginx bitnami/nginx --set service.type=ClusterIP
```

This is a common gotcha when running Helm charts designed for cloud environments on a local cluster.

</details>

<details>
<summary>Hint 2: helm repo update — always run it before install/upgrade</summary>

Helm caches the chart index locally. If you added the repo days ago, the cache may be stale. Always run:

```bash
helm repo update
```

This is the Helm equivalent of `apt update` — it refreshes the list of available chart versions before you install or upgrade.

</details>

<details>
<summary>Hint 3: Debugging Kustomize — preview before you apply</summary>

Never apply a Kustomize overlay blindly. Always preview the rendered output first:

```bash
# Preview only — does not apply anything
kubectl kustomize kustom-demo/overlays/dev/
```

This prints the fully merged YAML to stdout. Pipe it through `less` or redirect to a file to inspect it carefully:

```bash
kubectl kustomize kustom-demo/overlays/dev/ | less
```

If you see an error like `accumulating resources`, it usually means a path in the `resources` list of `kustomization.yaml` is wrong. Double-check relative paths — they are relative to the directory containing the `kustomization.yaml` file.

</details>

<details>
<summary>Hint 4: Helm dry-run — test before you deploy</summary>

Before installing or upgrading a Helm chart, render the templates locally to see exactly what Kubernetes manifests will be created:

```bash
# See what would be installed (without applying)
helm install my-release bitnami/nginx --dry-run

# Or for an upgrade
helm upgrade my-nginx bitnami/nginx --dry-run -f my-nginx-values.yaml
```

This is the equivalent of `apt install --simulate` — it shows you what would happen without actually doing it. If you see template rendering errors, fix your values before deploying.

</details>

<details>
<summary>Hint 5: Understanding Helm revision numbers</summary>

Every `helm install`, `helm upgrade`, and `helm rollback` creates a new **revision**. View them with:

```bash
helm history my-nginx
```

You'll see output like:

```
REVISION  UPDATED                   STATUS      CHART         APP VERSION  DESCRIPTION
1         2025-01-15 10:00:00       superseded  nginx-18.3.1  1.27.3       Install complete
2         2025-01-15 10:05:00       superseded  nginx-18.3.1  1.27.3       Upgrade complete
3         2025-01-15 10:10:00       deployed    nginx-18.3.1  1.27.3       Rollback to 1
```

Notice that a rollback creates a **new** revision (3) that restores the state of an old revision (1). Revision numbers always increase — they are never reused.

</details>

## Learning Resources

- [Helm — Getting Started Guide](https://helm.sh/docs/intro/quickstart/)
- [Helm — Using Helm (install, upgrade, rollback)](https://helm.sh/docs/intro/using_helm/)
- [Helm — Creating Your First Chart](https://helm.sh/docs/chart_template_guide/getting_started/)
- [Helm — Values Files](https://helm.sh/docs/chart_template_guide/values_files/)
- [Helm — Chart Best Practices](https://helm.sh/docs/chart_best_practices/)
- [Kustomize — Declarative Management of Kubernetes Objects](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/)
- [Kustomize — Official Documentation](https://kubectl.docs.kubernetes.io/references/kustomize/)
- [Kubernetes — Managing Kubernetes Objects Using Kustomize](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/)

## Break & Fix 🔧

Try each scenario, diagnose the problem, and fix it.

### Scenario 1 — Helm install fails: chart not found

Run this command:

```bash
helm install my-redis fakerepo/redis
```

**What you'll see:**

```
Error: INSTALLATION FAILED: repo fakerepo not found
```

**Diagnose:** Helm doesn't know about a repository called `fakerepo`. Check what repos are configured:

```bash
helm repo list
```

**Root cause:** You must add a chart repository before you can install charts from it. This is exactly like trying to `apt install` a package when its PPA hasn't been added to `sources.list`.

**Fix:**

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm install my-redis bitnami/redis --set architecture=standalone --set auth.enabled=false
```

Verify it's running:

```bash
helm list
kubectl get pods -l app.kubernetes.io/instance=my-redis
```

**Clean up:**

```bash
helm uninstall my-redis
```

---

### Scenario 2 — Kustomize overlay references a missing resource

Create the following broken overlay. First, set up the base:

```bash
mkdir -p kustom-broken/base kustom-broken/overlays/dev
```

Create `kustom-broken/base/deployment.yaml`:

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
```

Create `kustom-broken/base/kustomization.yaml`:

```yaml
resources:
  - deployment.yaml
```

Now create a broken dev overlay that references a resource not in the base. Create `kustom-broken/overlays/dev/kustomization.yaml`:

```yaml
resources:
  - ../../base
  - extra-configmap.yaml
```

Try to build it:

```bash
kubectl kustomize kustom-broken/overlays/dev/
```

**What you'll see:**

```
Error: accumulating resources: accumulating resources from 'extra-configmap.yaml': ...
```

**Root cause:** The overlay's `kustomization.yaml` references `extra-configmap.yaml`, but that file doesn't exist. Unlike Helm (which fails at template render time), Kustomize fails at resource accumulation time.

**Fix:** Either create the missing file, or remove the reference from `kustomization.yaml`:

Option A — Remove the reference:

```yaml
resources:
  - ../../base
```

Option B — Create the missing resource. Create `kustom-broken/overlays/dev/extra-configmap.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  LOG_LEVEL: debug
```

Then rebuild:

```bash
kubectl kustomize kustom-broken/overlays/dev/
```

**Clean up:**

```bash
rm -rf kustom-broken/
```

---

### Scenario 3 — Helm values.yaml has wrong indentation: template rendering error

Create a broken values file called `broken-values.yaml`:

```yaml
replicaCount: 2
service:
  type: ClusterIP
port: 8080
```

Notice the bug: `port` is at the **root level** instead of nested under `service`. Now try to upgrade:

```bash
helm upgrade my-nginx bitnami/nginx -f broken-values.yaml --dry-run
```

**What you'll see:** Depending on the chart, you may get a template rendering error, or worse — the chart may render successfully but produce unexpected results because `service.port` was never overridden (the `port: 8080` at root level was simply ignored, and the Service still uses the default port).

**Diagnose:**

```bash
# Render the templates and check the Service definition
helm template my-nginx bitnami/nginx -f broken-values.yaml | grep -A 10 "kind: Service"
```

**Root cause:** YAML is indentation-sensitive. `port: 8080` at the root level is a completely different key from `service.port: 8080`. Helm doesn't warn about unused values in your file — they are silently ignored.

**Fix:** Correct the indentation in `broken-values.yaml`:

```yaml
replicaCount: 2
service:
  type: ClusterIP
  port: 8080
```

Verify the fix:

```bash
helm template my-nginx bitnami/nginx -f broken-values.yaml | grep -A 10 "kind: Service"
```

> **Lesson learned:** Always use `helm template` or `helm install --dry-run` to preview rendered manifests before applying. Silent misconfiguration from bad YAML indentation is one of the most common Helm mistakes — like a typo in `/etc/default/nginx` that the service silently ignores.

**Clean up:**

```bash
rm -f broken-values.yaml
```
