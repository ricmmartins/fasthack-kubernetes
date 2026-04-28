# Challenge 16 — Container Image Engineering

[< Previous Challenge](Challenge-15.md) - **[Home](../README.md)** - [Next Challenge >](Challenge-17.md)

## Introduction

If you've ever provisioned a Linux server from scratch, you know the ritual: start with a minimal install (maybe a netinstall ISO), run a shell script that installs packages (`apt-get install -y nginx curl`), copies config files into place, opens firewall ports, and sets the startup command (`systemctl enable nginx`). That shell script **is** your server's build recipe — run it on a fresh VM and you get an identical machine every time.

A **Dockerfile** is exactly that shell script, but for containers. Each instruction (`FROM`, `RUN`, `COPY`, `CMD`) maps directly to a step in your provisioning script. The difference is that Docker captures each step as an **immutable image layer**, so you get caching, reproducibility, and portability that shell scripts on bare metal can only dream of.

In the Linux world, you've probably also done this: compiled software in a build chroot or a beefy build VM (with `gcc`, `make`, header files), then copied just the final binary to a minimal production server that doesn't have any build tools. This is exactly what **multi-stage builds** do — build in one stage, copy the artifact to a tiny runtime stage.

And just like you'd choose between Ubuntu Server (full-featured, large) and Alpine Linux (minimal, tiny) as your base OS, you'll choose between `ubuntu`, `alpine`, and `distroless` base images depending on whether you need a shell for debugging or want the smallest possible attack surface.

In this challenge, you'll write Dockerfiles from scratch, optimize images with multi-stage builds, compare base image strategies, work with registries (like pushing RPMs to a yum repo), and load custom images into your Kind cluster for deployment.

## Description

### Task 1 — Write a Dockerfile for a Simple Web Application

Just like writing a shell script that provisions a fresh VM, you'll write a Dockerfile that builds a container image for a simple Python web application.

Create a project directory and the application files:

```bash
mkdir -p ~/image-lab && cd ~/image-lab
```

Create a simple Python web app:

```python
# app.py
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
```

Create a `requirements.txt` (empty for this app, but good practice):

```
# requirements.txt
# No external dependencies — stdlib only
```

Now write a `Dockerfile` that:
- Starts from the `python:3.12-slim` base image
- Sets a working directory (`/app`)
- Copies the requirements file and installs dependencies
- Copies the application code
- Exposes port 8080
- Sets the startup command to run the app

Build and test it:

```bash
docker build -t myapp:v1 .
docker run --rm -p 8080:8080 myapp:v1
# In another terminal:
curl http://localhost:8080
```

> **Linux analogy:** `FROM python:3.12-slim` = choosing your base OS. `RUN pip install` = running your provisioning script. `COPY . .` = deploying your application files. `CMD` = setting the default service to start.

### Task 2 — Optimize with Multi-Stage Builds

Multi-stage builds are like compiling in a build chroot (with all the compilers and headers), then copying just the final binary to a minimal rootfs for production.

Create a Go web application to demonstrate the power of multi-stage builds:

```go
// main.go
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
```

Initialize the Go module:

```bash
go mod init myapp
```

> **Note:** If you don't have Go installed locally, that's fine — Docker will use the Go toolchain inside the build stage. You can create `go.mod` manually:
> ```
> module myapp
> go 1.22
> ```

Write a **single-stage** Dockerfile first (`Dockerfile.single`):
- Use `golang:1.22` as the base image
- Copy the source code, build it with `go build`, and run it

Then write a **multi-stage** Dockerfile (`Dockerfile.multi`):
- **Stage 1 (builder):** Use `golang:1.22` — copy source, run `CGO_ENABLED=0 go build -o /app`
- **Stage 2 (runtime):** Use `alpine:3.20` — copy only the compiled binary from Stage 1, expose port 8080, set the CMD

Build both and compare the image sizes:

```bash
docker build -t myapp:single -f Dockerfile.single .
docker build -t myapp:multi -f Dockerfile.multi .
docker images | grep myapp
```

The multi-stage image should be **dramatically** smaller (megabytes vs gigabytes).

> **Linux analogy:** Stage 1 is your build VM with `gcc`, `make`, and all dev headers. Stage 2 is your production server — you `scp` just the compiled binary and nothing else.

### Task 3 — Compare Base Image Sizes

Just like choosing between Ubuntu Server (full) vs Alpine (minimal) vs a stripped-down busybox rootfs, your base image choice dramatically affects image size and attack surface.

Build the same Go application with three different runtime bases:

1. **Ubuntu-based:** Use `ubuntu:24.04` as the runtime stage
2. **Alpine-based:** Use `alpine:3.20` as the runtime stage
3. **Distroless:** Use `gcr.io/distroless/static-debian12:nonroot` as the runtime stage

Write three Dockerfiles (or parameterize using build args) and compare:

```bash
docker images | grep myapp
```

Create a comparison table of the results — note the image sizes and think about the trade-offs:
- Which image has a shell you can `exec` into for debugging?
- Which image has the smallest attack surface?
- Which would you use in production vs development?

### Task 4 — Create a .dockerignore File

Just like `.gitignore` prevents unwanted files from entering your repository, `.dockerignore` prevents unwanted files from entering your build context.

First, observe the build context **without** a `.dockerignore`. Create some files that shouldn't be in your image:

```bash
# Create files that should NOT be in the image
echo "SECRET_KEY=supersecret" > .env
mkdir -p .git && echo "git data" > .git/HEAD
dd if=/dev/zero of=large-test-data.bin bs=1M count=50
```

Build and check the build context size in the output:

```bash
docker build -t myapp:no-ignore .
```

Look for the line: `Sending build context to Docker daemon  XX.XXB` (or equivalent progress in BuildKit).

Now create a `.dockerignore` file:

```
# .dockerignore
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
```

Rebuild and compare the build context size:

```bash
docker build -t myapp:with-ignore .
```

The build context should be significantly smaller. Verify that excluded files are not in the image:

```bash
docker run --rm myapp:with-ignore ls -la /app/
```

### Task 5 — Tag and Push to a Local Registry

Working with registries is like pushing packages to an apt/yum repository so other machines can install them.

Start a local registry (Docker's official `registry:2` image):

```bash
docker run -d -p 5000:5000 --name local-registry registry:2
```

Tag your image for the local registry and push it:

```bash
docker tag myapp:multi localhost:5000/myapp:v1
docker tag myapp:multi localhost:5000/myapp:latest
docker push localhost:5000/myapp:v1
docker push localhost:5000/myapp:latest
```

Verify the image is in the registry:

```bash
curl http://localhost:5000/v2/_catalog
curl http://localhost:5000/v2/myapp/tags/list
```

Now delete the local copy and pull from the registry to prove it works:

```bash
docker rmi localhost:5000/myapp:v1
docker pull localhost:5000/myapp:v1
docker run --rm -p 8080:8080 localhost:5000/myapp:v1
```

> **Linux analogy:** `docker push` = `rpm --addsign && createrepo` (sign and publish to your repo). `docker pull` = `yum install` (download from the repo). The registry is your private package mirror.

### Task 6 — Build with Podman (Rootless)

On Linux, running builds as root is a security risk — just like you'd avoid running `make install` as root when you can use `fakeroot` or user namespaces. Podman builds images **rootlessly** by default — no daemon, no root privileges.

Build the same image with Podman:

```bash
podman build -t myapp:podman -f Dockerfile.multi .
podman images | grep myapp
```

Compare the experience:
- Does the Dockerfile syntax change? (No — Podman uses the same Dockerfile format)
- Does Podman need a daemon running? (No — it's daemonless)
- Can you run Podman builds as a non-root user? (Yes — by default)

Run the Podman-built image:

```bash
podman run --rm -p 8081:8080 myapp:podman
curl http://localhost:8081
```

> **Note:** If Podman is not installed on your system, install it:
> - **Ubuntu/Debian:** `sudo apt-get install -y podman`
> - **Fedora/RHEL:** `sudo dnf install -y podman`
> - **macOS:** `brew install podman && podman machine init && podman machine start`
>
> If you cannot install Podman, document the commands you would run and note the differences from Docker in your notes. This task is optional but recommended.

### Task 7 — Load a Custom Image into Kind and Deploy

Kind clusters run inside Docker containers, so they can't pull from your local Docker image cache directly. You need to explicitly load images into the cluster.

Load your multi-stage image into the Kind cluster:

```bash
kind load docker-image myapp:multi --name fasthack
```

Verify the image is available inside the Kind node:

```bash
docker exec -it fasthack-control-plane crictl images | grep myapp
```

Now deploy it as a Pod:

```yaml
# custom-image-pod.yaml
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
```

```bash
kubectl apply -f custom-image-pod.yaml
kubectl get pod custom-app
kubectl port-forward pod/custom-app 8080:8080
# In another terminal:
curl http://localhost:8080
```

> **Critical:** `imagePullPolicy: Never` tells Kubernetes not to try pulling the image from a registry — it must already exist on the node. Without this, the Pod will fail with `ErrImagePull` because `myapp:multi` doesn't exist in any registry.

## Success Criteria

- [ ] You wrote a Dockerfile from scratch with `FROM`, `COPY`, `RUN`, `EXPOSE`, and `CMD` — and the built image runs correctly (Task 1)
- [ ] You built a multi-stage Dockerfile and the runtime image is significantly smaller than the single-stage image (Task 2)
- [ ] You compared image sizes across `ubuntu`, `alpine`, and `distroless` base images and can explain the trade-offs (Task 3)
- [ ] You created a `.dockerignore` file and confirmed the build context size decreased (Task 4)
- [ ] You pushed an image to a local `registry:2` and pulled it back successfully (Task 5)
- [ ] You built an image with Podman and confirmed it produces the same result as Docker (Task 6 — optional if Podman not available)
- [ ] You loaded a custom image into Kind with `kind load docker-image` and deployed it as a Pod with `imagePullPolicy: Never` (Task 7)
- [ ] The Pod is Running and responds to `curl` via `port-forward` (Task 7)

## Linux ↔ Kubernetes Reference

| Linux Concept | Container/Kubernetes Equivalent |
|---|---|
| Shell provisioning script (`setup.sh`) | Dockerfile (`FROM`, `RUN`, `COPY`, `CMD`) |
| `chroot` + `debootstrap` (create a minimal rootfs) | `FROM` base image (e.g., `alpine:3.20`, `ubuntu:24.04`) |
| Compile in build VM, copy binary to production server | Multi-stage build (build stage → runtime stage) |
| RPM/DEB package repository (`yum repo`, `apt repo`) | Container registry (`registry:2`, Docker Hub, GHCR) |
| Package versions (`nginx-1.27.0-1.el9.x86_64`) | Image tags (`myapp:v1`, `myapp:latest`, `myapp:v1.2.3`) |
| `.gitignore` (exclude files from repo) | `.dockerignore` (exclude files from build context) |
| `su` / `sudo` for builds (running as root) | Rootless Podman (build without root privileges) |
| `scp binary user@prod:/usr/local/bin/` | `COPY --from=builder /app /app` (copy from build stage) |
| `rpm -qa \| wc -l` (count installed packages) | `docker images` / `docker history` (check image layers and sizes) |
| Minimal install (netinstall ISO) | Distroless images (no shell, no package manager) |

## Hints

<details>
<summary>Hint 1: Basic Dockerfile structure</summary>

A Dockerfile follows this pattern — think of it as your server provisioning script:

```dockerfile
# Step 1: Choose your base OS (like picking a Linux ISO)
FROM python:3.12-slim

# Step 2: Set where you'll work (like cd /opt/myapp)
WORKDIR /app

# Step 3: Install dependencies first (for layer caching)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Step 4: Copy your application code
COPY app.py .

# Step 5: Document the port (like opening a firewall port)
EXPOSE 8080

# Step 6: Set the startup command (like systemctl start)
CMD ["python", "app.py"]
```

**Key optimization:** Copy `requirements.txt` and install dependencies **before** copying application code. This way, Docker caches the dependency layer and only rebuilds it when `requirements.txt` changes — not every time you edit `app.py`.

</details>

<details>
<summary>Hint 2: Multi-stage build pattern</summary>

The key syntax is naming stages with `AS` and copying between them with `COPY --from=`:

```dockerfile
# Stage 1: Build environment (like your build VM)
FROM golang:1.22 AS builder
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -o /app

# Stage 2: Runtime environment (like your production server)
FROM alpine:3.20
COPY --from=builder /app /app
EXPOSE 8080
CMD ["/app"]
```

`CGO_ENABLED=0` produces a statically-linked binary that doesn't need glibc — this is what lets you run it on `alpine` or even `distroless` (which has no C library).

</details>

<details>
<summary>Hint 3: Distroless images — no shell, no package manager</summary>

Distroless images from Google contain **only** your application and its runtime dependencies. No shell, no `ls`, no `cat`, no package manager.

```dockerfile
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /app /app
EXPOSE 8080
CMD ["/app"]
```

**Trade-off:**
- ✅ Smallest image size, smallest attack surface
- ✅ No shell means attackers can't get an interactive session
- ❌ You can't `kubectl exec` into the container for debugging
- ❌ Debugging requires ephemeral debug containers: `kubectl debug -it <pod> --image=busybox --target=app`

Use distroless in production, use alpine in development/staging.

</details>

<details>
<summary>Hint 4: Loading images into Kind</summary>

Kind runs as Docker containers, so it has its own image store separate from your host. You must explicitly load images:

```bash
# Load from your local Docker image cache
kind load docker-image myapp:multi --name fasthack

# Verify it's there
docker exec -it fasthack-control-plane crictl images | grep myapp
```

**Critical Pod config:** When deploying images loaded this way, set `imagePullPolicy: Never` — otherwise Kubernetes tries to pull from a registry and fails:

```yaml
containers:
  - name: app
    image: myapp:multi
    imagePullPolicy: Never
```

If you use the `:latest` tag, Kubernetes defaults to `imagePullPolicy: Always` — so either use a specific tag or explicitly set `Never`.

</details>

<details>
<summary>Hint 5: Registry basics</summary>

The local registry runs as a container:

```bash
docker run -d -p 5000:5000 --name local-registry registry:2
```

To push an image, you must tag it with the registry address:

```bash
docker tag myapp:multi localhost:5000/myapp:v1
docker push localhost:5000/myapp:v1
```

Query the registry API:
```bash
# List all repositories
curl http://localhost:5000/v2/_catalog

# List tags for a specific image
curl http://localhost:5000/v2/myapp/tags/list
```

</details>

<details>
<summary>Hint 6: Podman vs Docker — key differences</summary>

| Feature | Docker | Podman |
|---------|--------|--------|
| Daemon required | Yes (`dockerd`) | No (daemonless) |
| Root required for builds | Yes (by default) | No (rootless by default) |
| Dockerfile compatible | Yes | Yes (same syntax) |
| CLI compatible | Yes | Yes (drop-in replacement) |
| Image format | OCI / Docker | OCI / Docker |

The commands are nearly identical:

```bash
# Docker
docker build -t myapp:v1 .
docker run --rm myapp:v1

# Podman
podman build -t myapp:v1 .
podman run --rm myapp:v1
```

Some people alias `alias docker=podman` and never notice the difference.

</details>

## Learning Resources

- [Dockerfile reference — Docker docs](https://docs.docker.com/reference/dockerfile/)
- [Multi-stage builds — Docker docs](https://docs.docker.com/build/building/multi-stage/)
- [Best practices for writing Dockerfiles — Docker docs](https://docs.docker.com/build/building/best-practices/)
- [.dockerignore file — Docker docs](https://docs.docker.com/build/concepts/context/#dockerignore-files)
- [Deploy a registry server — Docker docs](https://docs.docker.com/registry/deploying/)
- [Podman — Getting Started](https://podman.io/get-started)
- [Distroless container images — GitHub](https://github.com/GoogleContainerTools/distroless)
- [Kind — Loading an image into your cluster](https://kind.sigs.k8s.io/docs/user/quick-start/#loading-an-image-into-your-cluster)
- [CKAD curriculum — Application Design and Build](https://github.com/cncf/curriculum/blob/master/CKAD_Curriculum_v1.31.pdf)

---

## Break & Fix 🔧

After completing the challenge, try diagnosing these broken scenarios:

---

### Scenario 1: Dockerfile builds but container exits immediately

A developer writes a Dockerfile, builds it successfully, but the container exits immediately on `docker run`:

```dockerfile
# broken-cmd/Dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY app.py .
EXPOSE 8080
RUN python app.py
```

```bash
docker build -t broken-cmd .
docker run --rm broken-cmd
# Container exits immediately — no output, no server
```

**Your task:** Why does the container exit? Fix the Dockerfile.

<details>
<summary>💡 Root cause & fix</summary>

**Root cause:** The developer used `RUN python app.py` instead of `CMD ["python", "app.py"]`. `RUN` executes during the **build** phase — the server starts, the build hangs (or the process runs briefly), and the resulting layer has no startup command. At runtime there's nothing to run.

**Fix:** Replace `RUN` with `CMD`:

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY app.py .
EXPOSE 8080
CMD ["python", "app.py"]
```

> **Rule:** `RUN` = runs at build time (like installing packages). `CMD` = runs at container start time (like your service's start command).

</details>

---

### Scenario 2: Image is huge despite multi-stage build

A developer claims to use a multi-stage build, but the image is still over 1GB:

```dockerfile
# bloated-multi/Dockerfile
FROM golang:1.22 AS builder
WORKDIR /src
COPY go.mod main.go ./
RUN go build -o /app

FROM golang:1.22
COPY --from=builder /app /app
EXPOSE 8080
CMD ["/app"]
```

```bash
docker build -t bloated-multi .
docker images bloated-multi
# SIZE: ~1.1GB — not what you'd expect from multi-stage!
```

**Your task:** Spot the mistake and fix it.

<details>
<summary>💡 Root cause & fix</summary>

**Root cause:** The runtime stage also uses `golang:1.22` — the full Go SDK image (~1.1GB). The developer forgot to switch to a minimal base image in the second stage.

**Fix:** Use `alpine:3.20` or `distroless` for the runtime stage, and build a static binary:

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

Now the image should be ~15MB instead of 1.1GB.

</details>

---

### Scenario 3: Pod stuck in ErrImagePull after loading into Kind

A developer loads an image into Kind and creates a Pod, but it fails:

```bash
kind load docker-image myapp:latest --name fasthack
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
# STATUS: ErrImagePull
```

**Your task:** The image was loaded — why can't Kubernetes find it?

<details>
<summary>💡 Root cause & fix</summary>

**Root cause:** The image tag is `:latest`. Kubernetes defaults to `imagePullPolicy: Always` for `:latest` tags, which means it tries to pull from a remote registry instead of using the local image on the node.

**Fix:** Set `imagePullPolicy: Never`:

```yaml
spec:
  containers:
    - name: app
      image: myapp:latest
      imagePullPolicy: Never
```

Or better yet, use a specific version tag instead of `:latest`:

```bash
docker tag myapp:latest myapp:v1.0.0
kind load docker-image myapp:v1.0.0 --name fasthack
```

```yaml
image: myapp:v1.0.0
imagePullPolicy: IfNotPresent
```

> **Best practice:** Avoid `:latest` in Kubernetes manifests — it makes deployments unpredictable and causes issues with `imagePullPolicy`.

</details>
