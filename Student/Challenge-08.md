# Challenge 08 — ConfigMaps and Secrets

[< Previous Challenge](Challenge-07.md) | **[Home](../README.md)** | [Next Challenge >](Challenge-09.md)

## Introduction

On a Linux server, configuration is everywhere: `/etc/nginx/nginx.conf` controls your web server, `export DB_HOST=10.0.0.5` injects connection strings into a process, and `/etc/shadow` keeps passwords in a file readable only by root (`chmod 600`). When you want every shell to inherit variables you drop a script in `/etc/profile.d/`, and if you need to react to a config file change you use `inotifywait`.

Kubernetes has direct equivalents for all of this:

- **ConfigMaps** are the `/etc/*.conf` files and environment variables of the cluster — they hold non-sensitive configuration data (feature flags, connection strings, entire config files).
- **Secrets** are the `/etc/shadow` and `/etc/ssl/private` of the cluster — they hold sensitive data (passwords, tokens, TLS certificates) and can be restricted with RBAC and file permissions (`defaultMode`).

Both can be injected into a Pod as **environment variables** (like `export`) or **mounted as files** (like bind-mounting a config file into a container). The critical difference from traditional Linux: ConfigMap-mounted volumes are **automatically updated** by the kubelet when the source changes — like having `inotifywait` built in — but environment variables are **frozen at Pod start** and never change until you restart the Pod.

In this challenge you will create ConfigMaps and Secrets, inject them both ways, and observe the hot-reload behavior that catches many newcomers off guard.

## Description

Your mission is to:

1. **Create a ConfigMap from literal values and from a file**

   First, create a ConfigMap using `--from-literal`:

   ```bash
   kubectl create configmap app-config \
     --from-literal=APP_COLOR=blue \
     --from-literal=APP_MODE=production
   ```

   Next, create a local configuration file and build a ConfigMap from it:

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

   Inspect what was created:

   ```bash
   kubectl get configmap app-config -o yaml
   kubectl get configmap nginx-config -o yaml
   ```

   > **Note:** `--from-file=default.conf=nginx-custom.conf` sets the key name to `default.conf` inside the ConfigMap. Without the `key=` prefix, the key defaults to the filename.

2. **Mount a ConfigMap as a volume in a Pod**

   Just like bind-mounting `/etc/nginx/conf.d/default.conf` on a Linux host, mount the `nginx-config` ConfigMap into an NGINX container:

   ```yaml
   # nginx-with-config.yaml
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
   kubectl exec nginx-configured -- cat /etc/nginx/conf.d/default.conf
   kubectl exec nginx-configured -- curl -s http://localhost/health
   ```

   The config file appears inside the container exactly as if you had mounted it with `mount --bind`.

3. **Use ConfigMap values as environment variables**

   This is the Kubernetes equivalent of `export VAR=val` or `source /etc/profile.d/myapp.sh`:

   ```yaml
   # env-demo.yaml
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
   kubectl logs env-demo
   # Output: Color=blue Mode=production
   ```

   You can also pick individual keys using `env[].valueFrom.configMapKeyRef`:

   ```yaml
   env:
     - name: COLOR
       valueFrom:
         configMapKeyRef:
           name: app-config
           key: APP_COLOR
   ```

4. **Create a Secret and mount it in a Pod**

   Secrets are like `/etc/shadow` — they hold sensitive data and should have restricted permissions. Create an opaque Secret:

   ```bash
   kubectl create secret generic db-creds \
     --from-literal=DB_USER=admin \
     --from-literal=DB_PASSWORD='S3cur3P@ss!'
   ```

   Inspect the Secret (values are base64-encoded in the output):

   ```bash
   kubectl get secret db-creds -o yaml
   ```

   Mount it into a Pod as a volume with restricted file permissions, just like `chmod 0400`:

   ```yaml
   # secret-pod.yaml
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
   kubectl logs secret-pod
   kubectl exec secret-pod -- ls -la /etc/credentials/
   ```

   Each key in the Secret becomes a file. The `defaultMode: 0400` is the Kubernetes equivalent of `chmod 400` — owner-read only.

   You can also inject Secrets as environment variables:

   ```yaml
   env:
     - name: DB_PASSWORD
       valueFrom:
         secretKeyRef:
           name: db-creds
           key: DB_PASSWORD
   ```

5. **Understand Secret encoding — base64 is NOT encryption**

   A common misconception: Secrets are **encoded** with base64, not **encrypted**. Anyone with `kubectl get secret -o yaml` access can decode them instantly:

   ```bash
   kubectl get secret db-creds -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
   # Output: S3cur3P@ss!
   ```

   Verify this yourself — create a Secret from a YAML manifest using `stringData` (which handles encoding for you) vs `data` (which requires pre-encoded base64):

   ```yaml
   # manual-secret.yaml
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

   **Security best practices:**
   - Use RBAC to restrict who can `get` Secrets
   - Enable [encryption at rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/) for the etcd datastore
   - Consider external secret management (e.g., Sealed Secrets, external-secrets-operator)
   - Never commit Secret manifests with `data:` values to version control
   - Mark Secrets as `immutable: true` when they should never change

6. **Hot-reload: update a ConfigMap and observe volume vs env var behavior**

   This is the task that surprises everyone. Update the ConfigMap and watch what happens:

   ```bash
   kubectl edit configmap app-config
   ```

   Change `APP_COLOR` from `blue` to `red`, save, and exit.

   **Test the volume-mounted Pod** — create one if you haven't:

   ```yaml
   # watch-config.yaml
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
   kubectl logs watch-config -f
   ```

   After editing the ConfigMap, the volume-mounted file updates automatically within ~30–60 seconds (the kubelet sync period). You'll see the output change from `blue` to `red` **without restarting the Pod**.

   **Test the env var Pod** — check `env-demo`:

   ```bash
   kubectl exec env-demo -- sh -c 'echo $APP_COLOR'
   # Still outputs: blue  (the OLD value!)
   ```

   **Environment variables are set at container start and never change.** To pick up new values you must restart the Pod:

   ```bash
   kubectl delete pod env-demo
   kubectl apply -f env-demo.yaml
   kubectl logs env-demo
   # Now outputs: Color=red Mode=production
   ```

   > **Key takeaway:** If your application reads config from **files**, it can react to ConfigMap changes without a restart. If it reads from **environment variables**, a Pod restart is required.

## Success Criteria

- [ ] You created a ConfigMap from `--from-literal` and verified it with `kubectl get configmap -o yaml` (Task 1)
- [ ] You created a ConfigMap from a file (`--from-file`) and confirmed the key/value structure (Task 1)
- [ ] You mounted a ConfigMap as a volume and the config file appears at the expected path inside the container (Task 2)
- [ ] You injected ConfigMap values as environment variables using `envFrom` and `configMapRef` (Task 3)
- [ ] You created an opaque Secret and mounted it as a volume with `defaultMode: 0400` (Task 4)
- [ ] You decoded a Secret's base64 value and can explain why base64 is not encryption (Task 5)
- [ ] You updated a ConfigMap and observed the volume-mounted file change automatically (Task 6)
- [ ] You confirmed that environment variables do **not** update after a ConfigMap change — a Pod restart is required (Task 6)
- [ ] You can explain when to use volume mounts vs environment variables for configuration

## Linux ↔ Kubernetes Reference

| Linux Concept | Kubernetes Equivalent |
|---|---|
| `/etc/nginx/nginx.conf` (config file) | ConfigMap mounted as a volume |
| `export VAR=val` (environment variable) | ConfigMap/Secret as env vars (`envFrom` or `valueFrom`) |
| `source /etc/profile.d/*.sh` (load all vars) | `envFrom: configMapRef` (inject all keys as env vars) |
| `/etc/shadow`, `/etc/ssl/private` (sensitive files) | Secret (opaque, TLS, docker-registry) |
| `chmod 600` (restricted file permissions) | Secret with `defaultMode: 0400` |
| `inotifywait` (file change watcher) | ConfigMap volume auto-update (~30–60s kubelet sync) |
| `/etc/environment` (set once at boot) | Env vars from ConfigMap — frozen at Pod start |
| `echo 'password' | base64` (encoding) | Secret `.data` field — base64-encoded, **not encrypted** |

## Hints

<details>
<summary>Hint 1: What's the difference between <code>data</code> and <code>stringData</code> in a Secret manifest?</summary>

When writing a Secret in YAML:

- **`data`** — values must be **base64-encoded** before you put them in the manifest:
  ```yaml
  data:
    password: UEBzc3cwcmQ=    # echo -n 'P@ssw0rd' | base64
  ```

- **`stringData`** — values are plain text; Kubernetes encodes them for you:
  ```yaml
  stringData:
    password: P@ssw0rd
  ```

Both produce the same Secret object. Use `stringData` for readability during development, but remember: the Secret is still only base64-encoded in etcd, **not encrypted**.

</details>

<details>
<summary>Hint 2: How do I mount only one key from a ConfigMap instead of the whole thing?</summary>

Use the `items` field to select specific keys and control the filename:

```yaml
volumes:
  - name: config-vol
    configMap:
      name: nginx-config
      items:
        - key: default.conf
          path: site.conf
```

This mounts only the `default.conf` key as a file named `site.conf`. Without `items`, every key in the ConfigMap becomes a file in the mount directory.

**Warning:** When you mount a ConfigMap (or Secret) to a directory, it **replaces the entire directory contents**. Use `subPath` if you need to mount a single file without hiding other files:

```yaml
volumeMounts:
  - name: config-vol
    mountPath: /etc/nginx/conf.d/custom.conf
    subPath: default.conf
```

> **Trade-off:** `subPath` mounts do **not** receive automatic updates when the ConfigMap changes.

</details>

<details>
<summary>Hint 3: Why aren't my ConfigMap changes showing up in the Pod?</summary>

Three common reasons:

1. **You're reading from environment variables** — env vars are set at container start and never refresh. You must delete and recreate the Pod (or use a Deployment and trigger a rollout).

2. **You used `subPath`** — volume mounts with `subPath` do not receive automatic updates. Only full-directory ConfigMap mounts are auto-refreshed.

3. **Not enough time has passed** — the kubelet syncs ConfigMap volumes on its sync period (default ~60 seconds) plus a cache propagation delay. Wait at least 1–2 minutes after editing the ConfigMap.

Check the current values inside the Pod:
```bash
kubectl exec watch-config -- cat /config/APP_COLOR
kubectl exec env-demo -- printenv APP_COLOR
```

</details>

<details>
<summary>Hint 4: How do I trigger a Deployment rollout when a ConfigMap changes?</summary>

Kubernetes doesn't automatically restart Pods in a Deployment when a referenced ConfigMap changes. A common pattern is to annotate the Pod template with a hash of the ConfigMap data:

```bash
kubectl patch deployment my-app -p \
  "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"configmap-hash\":\"$(kubectl get configmap app-config -o jsonpath='{.data}' | md5sum | cut -d' ' -f1)\"}}}}}"
```

This changes the Pod template, which triggers a rolling update. Some tools (like Reloader by stakater) automate this pattern.

</details>

<details>
<summary>Hint 5: How do I mark a ConfigMap or Secret as immutable?</summary>

Add `immutable: true` to prevent any further changes:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: release-config
immutable: true
data:
  VERSION: "2.5.0"
```

Once set, **you cannot change the data or remove the `immutable` flag** — you must delete and recreate the ConfigMap. This improves cluster performance (the kubelet stops polling for updates) and protects against accidental changes in production.

The same `immutable: true` field works on Secrets.

</details>

## Learning Resources

- [ConfigMaps — kubernetes.io](https://kubernetes.io/docs/concepts/configuration/configmap/)
- [Secrets — kubernetes.io](https://kubernetes.io/docs/concepts/configuration/secret/)
- [Configure a Pod to Use a ConfigMap — kubernetes.io](https://kubernetes.io/docs/tasks/configure-pod-container/configure-pod-configmap/)
- [Managing Secrets using kubectl — kubernetes.io](https://kubernetes.io/docs/tasks/configmap-secret/managing-secret-using-kubectl/)
- [Distribute Credentials Securely Using Secrets — kubernetes.io](https://kubernetes.io/docs/tasks/inject-data-application/distribute-credentials-secure/)
- [Encrypting Confidential Data at Rest — kubernetes.io](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)

## Break & Fix 🔧

After completing the challenge, try diagnosing these broken scenarios:

### Scenario 1: Pod stuck in ContainerCreating — missing ConfigMap

A developer deploys a Pod, but it never starts:

```yaml
# broken-configmap-ref.yaml
apiVersion: v1
kind: Pod
metadata:
  name: broken-cm-pod
spec:
  containers:
    - name: app
      image: busybox:1.37
      command: ["sleep", "3600"]
      volumeMounts:
        - name: config
          mountPath: /config
  volumes:
    - name: config
      configMap:
        name: does-not-exist
```

```bash
kubectl apply -f broken-configmap-ref.yaml
kubectl get pod broken-cm-pod            # ContainerCreating (stuck)
kubectl describe pod broken-cm-pod       # Look at Events
```

<details>
<summary>💡 Root cause & fix</summary>

The Pod references a ConfigMap named `does-not-exist` that was never created. The kubelet cannot mount the volume, so the container never starts.

The Events section will show:
```
Warning  FailedMount  ... configmap "does-not-exist" not found
```

**Fix:** Create the missing ConfigMap, or correct the name in the Pod spec:
```bash
kubectl create configmap does-not-exist --from-literal=placeholder=value
```

> **Tip:** You can make the ConfigMap reference optional using `optional: true`:
> ```yaml
> volumes:
>   - name: config
>     configMap:
>       name: does-not-exist
>       optional: true
> ```
> With `optional: true`, the Pod starts even if the ConfigMap doesn't exist (the mount directory will be empty).

</details>

### Scenario 2: Secret creation fails — value not base64-encoded

A developer writes a Secret manifest by hand but gets an error:

```yaml
# broken-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: broken-secret
type: Opaque
data:
  password: NotBase64Encoded!@#
```

```bash
kubectl apply -f broken-secret.yaml
# Error: illegal base64 data at input byte ...
```

<details>
<summary>💡 Root cause & fix</summary>

The `data` field requires **valid base64** values. The string `NotBase64Encoded!@#` is plain text, not base64.

**Fix option 1** — encode the value:
```bash
echo -n 'NotBase64Encoded!@#' | base64
# Output: Tm90QmFzZTY0RW5jb2RlZCFAIw==
```
Then use the encoded value in `data.password`.

**Fix option 2** — use `stringData` instead of `data` (Kubernetes encodes it for you):
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: broken-secret
type: Opaque
stringData:
  password: "NotBase64Encoded!@#"
```

> **Rule of thumb:** Use `stringData` when writing manifests by hand. Use `data` only when you're generating manifests programmatically and already have base64 values.

</details>

### Scenario 3: Environment variable doesn't update after ConfigMap change

A developer updates a ConfigMap and expects the running Pod to pick up the change, but it doesn't:

```yaml
# env-no-refresh.yaml
apiVersion: v1
kind: Pod
metadata:
  name: env-no-refresh
spec:
  containers:
    - name: app
      image: busybox:1.37
      command: ["sh", "-c", "while true; do echo COLOR=$APP_COLOR; sleep 10; done"]
      env:
        - name: APP_COLOR
          valueFrom:
            configMapKeyRef:
              name: app-config
              key: APP_COLOR
```

```bash
kubectl apply -f env-no-refresh.yaml
kubectl logs env-no-refresh --tail=1         # COLOR=blue

kubectl patch configmap app-config -p '{"data":{"APP_COLOR":"green"}}'

kubectl logs env-no-refresh --tail=1         # Still COLOR=blue  ← not updated!
```

<details>
<summary>💡 Root cause & fix</summary>

**Environment variables are injected at container start time and never change.** This is identical to how Linux processes work — if you `export VAR=val` and start a process, changing the variable in the parent shell does not affect the running child process.

Unlike volume-mounted ConfigMaps (which the kubelet syncs automatically), env vars are static for the lifetime of the container.

**Fix:** Restart the Pod to pick up the new values:
```bash
kubectl delete pod env-no-refresh
kubectl apply -f env-no-refresh.yaml
kubectl logs env-no-refresh --tail=1         # Now: COLOR=green
```

**Better pattern:** If you need hot-reloadable config, mount the ConfigMap as a volume and have your application read from the file. Or use a Deployment and trigger a rollout restart:
```bash
kubectl rollout restart deployment my-app
```

</details>
