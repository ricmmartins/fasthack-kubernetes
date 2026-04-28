# Solution 08 — ConfigMaps and Secrets

[< Back to Challenge](../Student/Challenge-08.md) | **[Home](README.md)**

## Notes for Coaches

This challenge is conceptually straightforward but the hot-reload behavior (Task 6) is the "aha moment." Make sure students actually **wait** and observe the volume-mounted file change while the env var stays frozen. That contrast is the most valuable takeaway.

Estimated time: **30 minutes**

---

## Task 1: Create ConfigMaps (Literal + From File)

### Step-by-step

**1a — ConfigMap from literal values:**

```bash
kubectl create configmap app-config \
  --from-literal=APP_COLOR=blue \
  --from-literal=APP_MODE=production
```

**1b — Create the config file and build a ConfigMap from it:**

```bash
cat <<'EOF' > nginx-custom.conf
server {
    listen       80;
    server_name  localhost;
    location / {
        root   /usr/share/nginx/html;
        index  index.html;
    }
    location /health {
        return 200 'OK';
        add_header Content-Type text/plain;
    }
}
EOF

kubectl create configmap nginx-config --from-file=default.conf=nginx-custom.conf
```

### Verification

```bash
kubectl get configmap app-config -o yaml
```

Expected output (key section):

```yaml
data:
  APP_COLOR: blue
  APP_MODE: production
```

```bash
kubectl get configmap nginx-config -o yaml
```

Expected: the `data` section has a key named `default.conf` whose value is the full nginx config file content.

> **Coach tip:** Point out that `--from-file=default.conf=nginx-custom.conf` sets the key name to `default.conf`. Without the `key=` prefix the key defaults to the local filename (`nginx-custom.conf`). This is a common gotcha.

---

## Task 2: Mount ConfigMap as a Volume

### Step-by-step

Save `nginx-with-config.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx-configured
spec:
  containers:
    - name: nginx
      image: nginx:1.27-alpine
      ports:
        - containerPort: 80
      volumeMounts:
        - name: config-volume
          mountPath: /etc/nginx/conf.d
  volumes:
    - name: config-volume
      configMap:
        name: nginx-config
```

```bash
kubectl apply -f nginx-with-config.yaml
kubectl wait --for=condition=Ready pod/nginx-configured --timeout=60s
```

### Verification

```bash
kubectl exec nginx-configured -- cat /etc/nginx/conf.d/default.conf
```

Expected: the full nginx config file is printed.

```bash
kubectl exec nginx-configured -- curl -s http://localhost/health
```

Expected output:

```
OK
```

> **Coach tip:** Explain that mounting a ConfigMap to a directory **replaces the entire directory contents**. If the student needs to keep existing files in that directory they must use `subPath` — but warn them that `subPath` mounts do not receive auto-updates.

---

## Task 3: Use ConfigMap as Environment Variables

### Step-by-step

Save `env-demo.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: env-demo
spec:
  containers:
    - name: app
      image: busybox:1.37
      command: ["sh", "-c", "echo Color=$APP_COLOR Mode=$APP_MODE && sleep 3600"]
      envFrom:
        - configMapRef:
            name: app-config
```

```bash
kubectl apply -f env-demo.yaml
kubectl wait --for=condition=Ready pod/env-demo --timeout=60s
kubectl logs env-demo
```

### Verification

Expected output:

```
Color=blue Mode=production
```

> **Coach tip:** Explain the difference between `envFrom` (injects ALL keys as env vars) and `env[].valueFrom.configMapKeyRef` (injects a single key, optionally renaming it). Ask students: "When would you use one vs the other?"

---

## Task 4: Create a Secret and Mount It

### Step-by-step

```bash
kubectl create secret generic db-creds \
  --from-literal=DB_USER=admin \
  --from-literal=DB_PASSWORD='S3cur3P@ss!'
```

Save `secret-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secret-pod
spec:
  containers:
    - name: app
      image: busybox:1.37
      command: ["sh", "-c", "ls -la /etc/credentials/ && cat /etc/credentials/DB_USER && echo && sleep 3600"]
      volumeMounts:
        - name: secret-volume
          mountPath: /etc/credentials
          readOnly: true
  volumes:
    - name: secret-volume
      secret:
        secretName: db-creds
        defaultMode: 0400
```

```bash
kubectl apply -f secret-pod.yaml
kubectl wait --for=condition=Ready pod/secret-pod --timeout=60s
```

### Verification

```bash
kubectl logs secret-pod
```

Expected: you see file listing with `-r--------` permissions (0400) and the content `admin`.

```bash
kubectl exec secret-pod -- ls -la /etc/credentials/
```

Expected output includes:

```
-r--------    1 root     root             5 ...  DB_PASSWORD
-r--------    1 root     root             5 ...  DB_USER
```

> **Coach tip:** Emphasize `defaultMode: 0400` — this is the Kubernetes equivalent of `chmod 400`. Each key becomes a separate file. The `readOnly: true` on the volumeMount is an additional layer of protection.

---

## Task 5: Base64 Is NOT Encryption

### Step-by-step

```bash
kubectl get secret db-creds -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
```

### Verification

Expected output:

```
S3cur3P@ss!
```

Also demonstrate `stringData` vs `data`. Save `manual-secret.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: manual-secret
type: Opaque
stringData:
  API_KEY: my-super-secret-key
```

```bash
kubectl apply -f manual-secret.yaml
kubectl get secret manual-secret -o jsonpath='{.data.API_KEY}' | base64 -d
```

Expected output:

```
my-super-secret-key
```

> **Coach tip:** This is the most important security discussion in this challenge. Ask students: "If base64 is not encryption, how do we actually protect Secrets?" Expected answers: RBAC (restrict `get secret`), encryption at rest in etcd, external secret managers (Sealed Secrets, external-secrets-operator), never committing Secret manifests to version control.

---

## Task 6: Hot-Reload — Volume Update vs Env Var Freeze

This is the key learning moment of the challenge.

### Step-by-step

**6a — Create the watcher Pod:**

Save `watch-config.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: watch-config
spec:
  containers:
    - name: watcher
      image: busybox:1.37
      command: ["sh", "-c", "while true; do cat /config/APP_COLOR 2>/dev/null; echo; sleep 5; done"]
      volumeMounts:
        - name: config-vol
          mountPath: /config
  volumes:
    - name: config-vol
      configMap:
        name: app-config
```

```bash
kubectl apply -f watch-config.yaml
kubectl wait --for=condition=Ready pod/watch-config --timeout=60s
```

**6b — Verify current value:**

```bash
kubectl logs watch-config --tail=3
```

Expected: prints `blue` repeatedly.

**6c — Update the ConfigMap:**

```bash
kubectl patch configmap app-config -p '{"data":{"APP_COLOR":"red"}}'
```

**6d — Watch the volume-mounted file update (wait 30–60 seconds):**

```bash
kubectl logs watch-config -f
```

Expected: after 30–60 seconds the output changes from `blue` to `red` — **without restarting the Pod**.

**6e — Check the environment variable Pod — it does NOT update:**

```bash
kubectl exec env-demo -- sh -c 'echo $APP_COLOR'
```

Expected output:

```
blue
```

The env var is still `blue` because environment variables are frozen at container start.

**6f — Restart to pick up new env vars:**

```bash
kubectl delete pod env-demo
kubectl apply -f env-demo.yaml
kubectl wait --for=condition=Ready pod/env-demo --timeout=60s
kubectl logs env-demo
```

Expected output:

```
Color=red Mode=production
```

### Verification

| Test | Expected Result |
|------|----------------|
| `kubectl logs watch-config --tail=1` | `red` (auto-updated) |
| `kubectl exec env-demo -- sh -c 'echo $APP_COLOR'` | `red` (after Pod restart) |

> **Coach tip:** Ask the student: "If you use a Deployment, how would you trigger a rollout when a ConfigMap changes?" Answer: annotate the Pod template with a hash of the ConfigMap data, or use a tool like Reloader. Kubernetes does NOT automatically restart Deployments when referenced ConfigMaps change.

---

## Common Issues

| Problem | Cause | Fix |
|---------|-------|-----|
| Pod stuck in `ContainerCreating` | Referenced ConfigMap/Secret doesn't exist | Create the missing resource, or add `optional: true` to the volume spec |
| Secret apply fails with "illegal base64" | Used `data:` field with plain text instead of base64 | Use `stringData:` instead, or base64-encode the value first |
| Env var doesn't update after ConfigMap change | Env vars are frozen at container start | Restart the Pod (delete + recreate, or `kubectl rollout restart deployment`) |
| Volume-mounted file doesn't update | Using `subPath` mount | `subPath` mounts don't receive auto-updates; use a full-directory mount instead |
| ConfigMap file key has wrong name | Didn't use `key=` prefix in `--from-file` | Use `--from-file=desired-key=local-filename` |
| Volume mount hides existing files in the directory | ConfigMap volume replaces entire directory | Use `subPath` for individual files (trade-off: no auto-update) |

---

## Clean Up

```bash
kubectl delete pod nginx-configured env-demo secret-pod watch-config 2>/dev/null
kubectl delete configmap app-config nginx-config 2>/dev/null
kubectl delete secret db-creds manual-secret 2>/dev/null
rm -f nginx-custom.conf nginx-with-config.yaml env-demo.yaml secret-pod.yaml watch-config.yaml manual-secret.yaml
```
