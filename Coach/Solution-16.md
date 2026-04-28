# Solution 16 — Container Image Engineering

[< Previous Solution](Solution-15.md) - **[Home](README.md)** - [Next Solution >](Solution-17.md)

---

> **Coach note:** This challenge covers CKAD-critical topics: writing Dockerfiles, multi-stage builds, image optimization, registries, and loading images into Kind. Students should have Docker (or Podman) installed from Challenge 01 setup. Task 6 (Podman) is optional if not installed. All other tasks are core.

## Setup

Ensure students have Docker running and a Kind cluster named `fasthack`:

```bash
docker info >/dev/null 2>&1 && echo "Docker OK" || echo "Docker not running"
kind get clusters | grep fasthack && echo "Kind cluster OK" || echo "No fasthack cluster"
```

Create the working directory:

```bash
mkdir -p ~/image-lab && cd ~/image-lab
```

---

## Task 1: Write a Dockerfile for a Simple Web Application

### Step-by-step

Create the application file:

```bash
cat <<'PYEOF' > app.py
from http.server import HTTPServer, BaseHTTPRequestHandler
import os

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        msg = os.getenv("APP_MESSAGE", "Hello from my custom image!")
        self.wfile.write(f"{msg}\n".encode())

    def log_message(self, format, *args):
        print(f"[request] {args[0]}")

if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", 8080), Handler)
    print("Server running on port 8080...")
    server.serve_forever()
PYEOF
```

Create the requirements file:

```bash
cat <<'EOF' > requirements.txt
# No external dependencies — stdlib only
EOF
```

Create the Dockerfile:

```bash
cat <<'DOCKERFILE' > Dockerfile
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

EXPOSE 8080

CMD ["python", "app.py"]
DOCKERFILE
```

Build the image:

```bash
docker build -t myapp:v1 .
```

Expected output (key lines):

```
[+] Building 12.3s (10/10) FINISHED
 => [1/5] FROM docker.io/library/python:3.12-slim@sha256:...
 => [2/5] WORKDIR /app
 => [3/5] COPY requirements.txt .
 => [4/5] RUN pip install --no-cache-dir -r requirements.txt
 => [5/5] COPY app.py .
 => exporting to image
 => => naming to docker.io/library/myapp:v1
```

### Verification

```bash
# Run the container
docker run --rm -d -p 8080:8080 --name myapp-test myapp:v1

# Test it
curl http://localhost:8080
```

Expected:

```
Hello from my custom image!
```

```bash
# Check the image size
docker images myapp:v1
```

Expected (approximately):

```
REPOSITORY   TAG   IMAGE ID       CREATED          SIZE
myapp        v1    abc123def456   30 seconds ago   155MB
```

Clean up:

```bash
docker stop myapp-test
```

> **Coach tip:** If students see `155MB` for a "hello world" Python app, ask: "Where does that size come from?" Answer: The `python:3.12-slim` base image itself is ~150MB. This motivates Task 2 and Task 3.

---

## Task 2: Optimize with Multi-Stage Builds

### Step-by-step

Create the Go application:

```bash
cat <<'GOEOF' > main.go
package main

import (
	"fmt"
	"net/http"
	"os"
)

func main() {
	msg := os.Getenv("APP_MESSAGE")
	if msg == "" {
		msg = "Hello from Go multi-stage build!"
	}
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "%s\n", msg)
	})
	fmt.Println("Server running on port 8080...")
	http.ListenAndServe(":8080", nil)
}
GOEOF
```

Create the Go module file:

```bash
cat <<'EOF' > go.mod
module myapp

go 1.22
EOF
```

Create the **single-stage** Dockerfile:

```bash
cat <<'DOCKERFILE' > Dockerfile.single
FROM golang:1.22

WORKDIR /src

COPY go.mod main.go ./

RUN go build -o /app

EXPOSE 8080

CMD ["/app"]
DOCKERFILE
```

Create the **multi-stage** Dockerfile:

```bash
cat <<'DOCKERFILE' > Dockerfile.multi
# Stage 1: Build (like your build VM with all compilers)
FROM golang:1.22 AS builder

WORKDIR /src

COPY go.mod main.go ./

RUN CGO_ENABLED=0 go build -o /app

# Stage 2: Runtime (like your minimal production server)
FROM alpine:3.20

COPY --from=builder /app /app

EXPOSE 8080

CMD ["/app"]
DOCKERFILE
```

Build both:

```bash
docker build -t myapp:single -f Dockerfile.single .
docker build -t myapp:multi -f Dockerfile.multi .
```

### Verification

```bash
docker images | grep myapp
```

Expected (approximate sizes):

```
REPOSITORY   TAG      IMAGE ID       CREATED          SIZE
myapp        multi    abc123def456   10 seconds ago   13.5MB
myapp        single   def456abc789   30 seconds ago   1.12GB
myapp        v1       789abc123def   2 minutes ago    155MB
```

**Key observation:** The multi-stage image (`~13.5MB`) is approximately **80x smaller** than the single-stage image (`~1.12GB`).

Test the multi-stage image:

```bash
docker run --rm -d -p 8080:8080 --name multi-test myapp:multi
curl http://localhost:8080
```

Expected:

```
Hello from Go multi-stage build!
```

```bash
docker stop multi-test
```

Inspect the layers to understand the difference:

```bash
# Single-stage: many layers from the Go SDK
docker history myapp:single --no-trunc --format "{{.Size}}\t{{.CreatedBy}}" | head -5

# Multi-stage: only the alpine base + your binary
docker history myapp:multi --no-trunc --format "{{.Size}}\t{{.CreatedBy}}" | head -5
```

> **Coach tip:** Ask students: "Why does `CGO_ENABLED=0` matter?" Answer: It produces a statically-linked binary that doesn't need glibc. Without it, the binary needs the C library from the build image, and won't run on Alpine (which uses musl, not glibc) or distroless (which has no C library at all).

---

## Task 3: Compare Base Image Sizes

### Step-by-step

Create three Dockerfiles for different base images:

**Ubuntu-based:**

```bash
cat <<'DOCKERFILE' > Dockerfile.ubuntu
FROM golang:1.22 AS builder
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -o /app

FROM ubuntu:24.04
COPY --from=builder /app /app
EXPOSE 8080
CMD ["/app"]
DOCKERFILE
```

**Alpine-based** (already created as `Dockerfile.multi`):

```bash
# Already exists from Task 2
```

**Distroless:**

```bash
cat <<'DOCKERFILE' > Dockerfile.distroless
FROM golang:1.22 AS builder
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -o /app

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /app /app
EXPOSE 8080
CMD ["/app"]
DOCKERFILE
```

Build all three:

```bash
docker build -t myapp:ubuntu -f Dockerfile.ubuntu .
docker build -t myapp:alpine -f Dockerfile.multi .
docker build -t myapp:distroless -f Dockerfile.distroless .
```

### Verification

```bash
docker images | grep myapp | sort -k7 -h
```

Expected (approximate):

```
REPOSITORY   TAG          IMAGE ID       CREATED          SIZE
myapp        distroless   aaa111bbb222   10 seconds ago   7.68MB
myapp        alpine       bbb222ccc333   30 seconds ago   13.5MB
myapp        ubuntu       ccc333ddd444   45 seconds ago   85.8MB
myapp        single       ddd444eee555   2 minutes ago    1.12GB
```

Verify all three work:

```bash
# Test Ubuntu variant
docker run --rm -d -p 8080:8080 --name test-ubuntu myapp:ubuntu
curl http://localhost:8080 && docker stop test-ubuntu

# Test Alpine variant
docker run --rm -d -p 8080:8080 --name test-alpine myapp:alpine
curl http://localhost:8080 && docker stop test-alpine

# Test Distroless variant
docker run --rm -d -p 8080:8080 --name test-distroless myapp:distroless
curl http://localhost:8080 && docker stop test-distroless
```

All three should return: `Hello from Go multi-stage build!`

Test shell access:

```bash
# Ubuntu — has a full shell
docker run --rm -it myapp:ubuntu /bin/bash -c "whoami && ls /app"
# Output: root, /app

# Alpine — has a minimal shell
docker run --rm -it myapp:alpine /bin/sh -c "whoami && ls /app"
# Output: root, /app

# Distroless — NO shell
docker run --rm -it myapp:distroless /bin/sh
# Error: exec: "/bin/sh": stat /bin/sh: no such file or directory
```

### Comparison Table

| Base Image | Size | Shell? | Package Manager? | Best For |
|---|---|---|---|---|
| `ubuntu:24.04` | ~85MB | ✅ bash | ✅ apt | Development, debugging, apps needing system libraries |
| `alpine:3.20` | ~13MB | ✅ sh | ✅ apk | Good balance of size and debuggability |
| `distroless/static` | ~8MB | ❌ | ❌ | Production — smallest attack surface |
| `golang:1.22` (single) | ~1.1GB | ✅ bash | ✅ apt | Never use as runtime base |

> **Coach tip:** Ask students which they'd choose for a CKAD exam scenario. Answer: For the exam, use `alpine` — it's small and you can still exec into it. For production security questions, the answer is `distroless`.

---

## Task 4: Create a .dockerignore File

### Step-by-step

Create files that should NOT end up in the image:

```bash
cd ~/image-lab
echo "SECRET_KEY=supersecret" > .env
mkdir -p .git && echo "git data" > .git/HEAD
dd if=/dev/zero of=large-test-data.bin bs=1M count=50
```

Build without `.dockerignore` and observe the context:

```bash
docker build -t myapp:no-ignore -f Dockerfile .
```

Expected — look for the build context transfer (BuildKit shows this differently but the context is still sent):

```
 => [internal] load build context
 => => transferring context: 52.43MB
```

Now create the `.dockerignore`:

```bash
cat <<'EOF' > .dockerignore
.git
.env
*.bin
*.md
Dockerfile*
.dockerignore
__pycache__
*.pyc
.venv
node_modules
EOF
```

Rebuild:

```bash
docker build -t myapp:with-ignore -f Dockerfile .
```

Expected:

```
 => [internal] load build context
 => => transferring context: 1.23kB
```

### Verification

Verify excluded files are not in the image:

```bash
docker run --rm myapp:with-ignore ls -la /app/
```

Expected — only `app.py` and `requirements.txt` should be present:

```
total 8
drwxr-xr-x 1 root root 4096 ... .
drwxr-xr-x 1 root root 4096 ... ..
-rw-r--r-- 1 root root  ...  app.py
-rw-r--r-- 1 root root  ...  requirements.txt
```

**No `.env`, no `.git`, no `large-test-data.bin`, no `Dockerfile`.**

Clean up the test files:

```bash
rm -f .env large-test-data.bin
rm -rf .git
```

> **Coach tip:** Emphasize the security angle: without `.dockerignore`, `.env` files with secrets, `.git` directories with full commit history, and other sensitive files get baked into the image. Anyone who pulls the image can extract them.

---

## Task 5: Tag and Push to a Local Registry

### Step-by-step

Start the local registry:

```bash
docker run -d -p 5000:5000 --name local-registry registry:2
```

Expected:

```
Unable to find image 'registry:2' locally
2: Pulling from library/registry
...
Status: Downloaded newer image for registry:2
<container-id>
```

Verify it's running:

```bash
docker ps | grep registry
curl http://localhost:5000/v2/
```

Expected from curl:

```
{}
```

Tag and push images:

```bash
docker tag myapp:multi localhost:5000/myapp:v1
docker tag myapp:multi localhost:5000/myapp:latest
docker push localhost:5000/myapp:v1
docker push localhost:5000/myapp:latest
```

Expected push output:

```
The push refers to repository [localhost:5000/myapp]
abc123: Pushed
def456: Pushed
v1: digest: sha256:... size: 739
```

### Verification

Query the registry API:

```bash
# List all repositories
curl http://localhost:5000/v2/_catalog
```

Expected:

```json
{"repositories":["myapp"]}
```

```bash
# List tags
curl http://localhost:5000/v2/myapp/tags/list
```

Expected:

```json
{"name":"myapp","tags":["v1","latest"]}
```

Prove round-trip works — delete local and pull from registry:

```bash
docker rmi localhost:5000/myapp:v1
docker pull localhost:5000/myapp:v1
docker run --rm -d -p 8080:8080 --name registry-test localhost:5000/myapp:v1
curl http://localhost:8080
```

Expected:

```
Hello from Go multi-stage build!
```

```bash
docker stop registry-test
```

Clean up the registry container (optional — keep it for other experiments):

```bash
docker stop local-registry && docker rm local-registry
```

---

## Task 6: Build with Podman (Rootless)

> **Coach note:** This task is optional. If students don't have Podman installed and can't easily install it, they should document the commands and note the differences instead.

### Step-by-step

Verify Podman is installed:

```bash
podman --version
```

Expected (version may vary):

```
podman version 5.x.x
```

Build the same image with Podman:

```bash
cd ~/image-lab
podman build -t myapp:podman -f Dockerfile.multi .
```

Expected output — nearly identical to Docker's output:

```
STEP 1/7: FROM golang:1.22 AS builder
STEP 2/7: WORKDIR /src
STEP 3/7: COPY go.mod main.go ./
STEP 4/7: RUN CGO_ENABLED=0 go build -o /app
STEP 5/7: FROM alpine:3.20
STEP 6/7: COPY --from=builder /app /app
STEP 7/7: CMD ["/app"]
COMMIT myapp:podman
--> abc123def456
Successfully tagged localhost/myapp:podman
```

### Verification

```bash
podman images | grep myapp
```

Expected:

```
REPOSITORY                TAG       IMAGE ID      CREATED        SIZE
localhost/myapp            podman    abc123def456  30 seconds ago  13.5 MB
```

Run the image:

```bash
podman run --rm -d -p 8081:8080 --name podman-test myapp:podman
curl http://localhost:8081
```

Expected:

```
Hello from Go multi-stage build!
```

```bash
podman stop podman-test
```

Verify rootless execution:

```bash
# Podman runs as the current user — no root needed
whoami
podman info | grep rootless
```

Expected:

```
<your-username>
    rootless: true
```

### Key Comparisons for Students

| Feature | Docker | Podman |
|---------|--------|--------|
| Build command | `docker build -t img .` | `podman build -t img .` |
| Daemon required | Yes (`dockerd`) | No |
| Default user for builds | root | Current user (rootless) |
| Image compatibility | OCI/Docker format | OCI/Docker format |
| Dockerfile syntax | Standard | Same — no changes needed |

> **Coach tip:** If a student asks "why would I use Podman?", the answer is security. In enterprise environments, running a root-level Docker daemon is a security concern. Podman eliminates that by running entirely in userspace. Some organizations mandate Podman for this reason.

---

## Task 7: Load a Custom Image into Kind and Deploy

### Step-by-step

Load the multi-stage image into the Kind cluster:

```bash
kind load docker-image myapp:multi --name fasthack
```

Expected:

```
Image: "myapp:multi" with ID "sha256:abc123..." not yet present on node "fasthack-control-plane", loading...
```

Verify the image is available inside the Kind node:

```bash
docker exec -it fasthack-control-plane crictl images | grep myapp
```

Expected:

```
docker.io/library/myapp    multi    abc123def456   13.5MB
```

Create the Pod manifest:

```bash
cat <<'EOF' > custom-image-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: custom-app
spec:
  containers:
    - name: app
      image: myapp:multi
      imagePullPolicy: Never
      ports:
        - containerPort: 8080
      env:
        - name: APP_MESSAGE
          value: "Hello from my custom Kind image!"
EOF
```

Deploy the Pod:

```bash
kubectl apply -f custom-image-pod.yaml
```

Expected:

```
pod/custom-app created
```

### Verification

```bash
kubectl get pod custom-app
```

Expected:

```
NAME         READY   STATUS    RESTARTS   AGE
custom-app   1/1     Running   0          10s
```

Test the application via port-forward:

```bash
kubectl port-forward pod/custom-app 8080:8080 &
sleep 2
curl http://localhost:8080
```

Expected:

```
Hello from my custom Kind image!
```

Stop the port-forward:

```bash
# Kill the background port-forward process
kill %1 2>/dev/null
```

Verify the image details in the Pod:

```bash
kubectl describe pod custom-app | grep -A 2 "Image:"
```

Expected:

```
    Image:          myapp:multi
    Image ID:       docker.io/library/myapp@sha256:...
```

```bash
kubectl describe pod custom-app | grep "Pull"
```

Expected — no pull events because `imagePullPolicy: Never`:

```
# No "Pulling image" events — the image was already on the node
```

### Bonus: Deploy with a Deployment (not just a Pod)

```bash
cat <<'EOF' > custom-image-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: custom-app-deploy
spec:
  replicas: 3
  selector:
    matchLabels:
      app: custom-app
  template:
    metadata:
      labels:
        app: custom-app
    spec:
      containers:
        - name: app
          image: myapp:multi
          imagePullPolicy: Never
          ports:
            - containerPort: 8080
          env:
            - name: APP_MESSAGE
              value: "Hello from replica!"
---
apiVersion: v1
kind: Service
metadata:
  name: custom-app-svc
spec:
  selector:
    app: custom-app
  ports:
    - port: 80
      targetPort: 8080
EOF

kubectl apply -f custom-image-deployment.yaml
kubectl get pods -l app=custom-app
```

Expected:

```
NAME                                READY   STATUS    RESTARTS   AGE
custom-app-deploy-xxxxxxxxx-aaaaa   1/1     Running   0          10s
custom-app-deploy-xxxxxxxxx-bbbbb   1/1     Running   0          10s
custom-app-deploy-xxxxxxxxx-ccccc   1/1     Running   0          10s
```

---

## Break & Fix Solutions

### Scenario 1: `RUN` vs `CMD` confusion

**Broken Dockerfile:**

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY app.py .
EXPOSE 8080
RUN python app.py
```

**Diagnostic commands:**

```bash
docker build -t broken-cmd .
docker run --rm broken-cmd
# Container exits immediately with no output
```

```bash
docker inspect broken-cmd --format='{{.Config.Cmd}}'
# Output: [] or null — no CMD set
```

**Root cause:** `RUN python app.py` executes during build. The server starts but either hangs the build or exits. There's no `CMD` set for runtime.

**Fix:**

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY app.py .
EXPOSE 8080
CMD ["python", "app.py"]
```

**Verification:**

```bash
docker build -t fixed-cmd .
docker run --rm -d -p 8080:8080 --name test-cmd fixed-cmd
curl http://localhost:8080
# Output: Hello from my custom image!
docker stop test-cmd
```

---

### Scenario 2: Multi-stage build still huge — wrong runtime base

**Broken Dockerfile:**

```dockerfile
FROM golang:1.22 AS builder
WORKDIR /src
COPY go.mod main.go ./
RUN go build -o /app

FROM golang:1.22
COPY --from=builder /app /app
EXPOSE 8080
CMD ["/app"]
```

**Diagnostic commands:**

```bash
docker build -t bloated-multi .
docker images bloated-multi
# SIZE: ~1.12GB
```

```bash
# Inspect both stages — the runtime image is the full Go SDK
docker history bloated-multi | head -3
```

**Root cause:** Both stages use `golang:1.22`. The runtime stage should use a minimal image like `alpine:3.20`.

**Fix:**

```dockerfile
FROM golang:1.22 AS builder
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -o /app

FROM alpine:3.20
COPY --from=builder /app /app
EXPOSE 8080
CMD ["/app"]
```

**Verification:**

```bash
docker build -t fixed-multi .
docker images fixed-multi
# SIZE: ~13.5MB
```

---

### Scenario 3: ErrImagePull with Kind — missing imagePullPolicy

**Setup:**

```bash
kind load docker-image myapp:latest --name fasthack
```

**Broken manifest:**

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pull-fail
spec:
  containers:
    - name: app
      image: myapp:latest
      ports:
        - containerPort: 8080
```

**Diagnostic commands:**

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: pull-fail
spec:
  containers:
    - name: app
      image: myapp:latest
      ports:
        - containerPort: 8080
EOF

kubectl get pod pull-fail
# STATUS: ErrImagePull or ImagePullBackOff

kubectl describe pod pull-fail
```

Key events:

```
Warning  Failed   Failed to pull image "myapp:latest": ... not found
Warning  Failed   Error: ErrImagePull
```

**Root cause:** The `:latest` tag causes Kubernetes to default to `imagePullPolicy: Always`, so it tries to pull from a remote registry instead of using the locally loaded image.

**Fix:**

```bash
kubectl delete pod pull-fail

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: pull-fail
spec:
  containers:
    - name: app
      image: myapp:latest
      imagePullPolicy: Never
      ports:
        - containerPort: 8080
EOF
```

**Verification:**

```bash
kubectl get pod pull-fail
# STATUS: Running
```

---

## Cleanup

After the challenge, clean up all resources:

```bash
# Delete Kubernetes resources
kubectl delete pod custom-app pull-fail 2>/dev/null
kubectl delete -f custom-image-deployment.yaml 2>/dev/null

# Clean up Docker resources
docker stop local-registry 2>/dev/null && docker rm local-registry 2>/dev/null
docker rmi myapp:v1 myapp:single myapp:multi myapp:alpine myapp:ubuntu myapp:distroless 2>/dev/null
docker rmi myapp:no-ignore myapp:with-ignore 2>/dev/null
docker rmi localhost:5000/myapp:v1 localhost:5000/myapp:latest 2>/dev/null
docker rmi broken-cmd fixed-cmd bloated-multi fixed-multi 2>/dev/null

# Clean up Podman images (if applicable)
podman rmi myapp:podman 2>/dev/null

# Remove working directory
rm -rf ~/image-lab
```

---

## Common Issues

| Problem | Cause | Fix |
|---------|-------|-----|
| `docker build` fails with "no such file" | `COPY` source doesn't exist or is excluded by `.dockerignore` | Check that the file exists and isn't in `.dockerignore` |
| Multi-stage image still large (>100MB) | Runtime stage uses the build base image | Change second `FROM` to `alpine:3.20` or `distroless` |
| `CGO_ENABLED=0` not set and binary crashes | Dynamic linking against glibc, but Alpine uses musl | Add `CGO_ENABLED=0` to the `go build` command |
| `kind load docker-image` fails | Image doesn't exist in local Docker cache | Run `docker images \| grep myapp` to verify the tag exists |
| Pod in `ErrImagePull` after `kind load` | `imagePullPolicy` not set to `Never` or `IfNotPresent` | Add `imagePullPolicy: Never` to the container spec |
| `:latest` tag causes pull from registry | K8s defaults to `Always` pull for `:latest` | Use a specific tag (`:v1`) or set `imagePullPolicy: Never` |
| `docker push` to `localhost:5000` fails | Local registry container not running | `docker ps \| grep registry` — restart if needed |
| `podman build` fails on macOS | Podman machine not initialized | Run `podman machine init && podman machine start` |
| Build context very large | Missing `.dockerignore` | Create `.dockerignore` excluding `.git`, `*.bin`, `node_modules`, etc. |
| `EXPOSE` doesn't make the port accessible | `EXPOSE` is documentation only — it doesn't publish ports | Use `-p 8080:8080` with `docker run` or `port-forward` in K8s |
