# Solution 01 — Your First Container

[< Back to Challenge](../Student/Challenge-01.md) | **[Home](README.md)**

## Pre-check

Ensure students have Docker (or Podman) installed and running:

```bash
docker version
```

Expected output (version numbers may differ):

```
Client:
 Version:           27.x.x
 ...
Server:
 Engine:
  Version:          27.x.x
```

If the **Server** section is missing, the Docker daemon isn't running — have the student start it (`sudo systemctl start docker` on Linux, or launch Docker Desktop on macOS/Windows).

---

## Task 1: Run Your First Container

### Step-by-step

Pull and run an nginx container, mapping host port 8080 to container port 80:

```bash
docker run -d --name web -p 8080:80 nginx
```

Expected output:

```
Unable to find image 'nginx:latest' locally
latest: Pulling from library/nginx
...
Status: Downloaded newer image for nginx:latest
a1b2c3d4e5f6...   # <- container ID
```

Verify the container is running:

```bash
docker ps
```

Expected output:

```
CONTAINER ID   IMAGE   COMMAND                  CREATED          STATUS          PORTS                  NAMES
a1b2c3d4e5f6   nginx   "/docker-entrypoint.…"   10 seconds ago   Up 9 seconds    0.0.0.0:8080->80/tcp   web
```

Test that nginx is serving traffic:

```bash
curl -s http://localhost:8080 | head -5
```

Expected output:

```html
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
<style>
```

### Verification

- `docker ps` shows the `web` container in `Up` status
- `curl http://localhost:8080` returns the default nginx welcome page

---

## Task 2: Build a Custom Container Image

### Step-by-step

Create a project directory and the required files:

```bash
mkdir -p ~/container-lab && cd ~/container-lab
```

Create a simple HTML file:

```bash
echo '<h1>Hello from my container!</h1>' > index.html
```

Create the Dockerfile:

```bash
cat > Dockerfile <<'EOF'
FROM nginx:alpine
COPY index.html /usr/share/nginx/html/
EOF
```

Build the image:

```bash
docker build -t myapp:v1 .
```

Expected output:

```
[+] Building 2.1s (7/7) FINISHED
 => [internal] load build definition from Dockerfile
 => [internal] load .dockerignore
 => [internal] load metadata for docker.io/library/nginx:alpine
 => [1/2] FROM docker.io/library/nginx:alpine
 => [2/2] COPY index.html /usr/share/nginx/html/
 => exporting to image
 => => naming to docker.io/library/myapp:v1
```

Run the custom image:

```bash
docker run -d --name myapp -p 8081:80 myapp:v1
```

Test it:

```bash
curl -s http://localhost:8081
```

Expected output:

```html
<h1>Hello from my container!</h1>
```

Verify the image appears in the local registry:

```bash
docker images myapp
```

Expected output:

```
REPOSITORY   TAG   IMAGE ID       CREATED          SIZE
myapp        v1    abc123def456   30 seconds ago   ~50MB
```

### Verification

- `docker images myapp` shows `myapp:v1`
- `curl http://localhost:8081` returns `<h1>Hello from my container!</h1>`

---

## Task 3: Inspect the Container's Processes, Network, and Filesystem

### Step-by-step

Exec into the `web` container (the nginx one from Task 1):

```bash
docker exec -it web sh
```

Once inside the container, run these diagnostic commands:

**List processes — PID 1 is the nginx master:**

```bash
ps aux
```

Expected output:

```
PID   USER     TIME  COMMAND
    1 root      0:00 nginx: master process nginx -g daemon off;
   29 nginx     0:00 nginx: worker process
   ...
   35 root      0:00 sh
   36 root      0:00 ps aux
```

> **Coach note:** Point out that PID 1 is nginx — not `init` or `systemd`. The container has its own PID namespace.

**Check the network — the container has its own network namespace:**

```bash
ip addr
```

Expected output (IP will vary):

```
1: lo: <LOOPBACK,UP,LOWER_UP> ...
    inet 127.0.0.1/8 scope host lo
...
42: eth0@if43: <BROADCAST,MULTICAST,UP,LOWER_UP> ...
    inet 172.17.0.2/16 brd 172.17.255.255 scope global eth0
```

**Check the hostname:**

```bash
cat /etc/hostname
```

Expected output:

```
a1b2c3d4e5f6   # <- matches the container ID
```

**Explore the filesystem:**

```bash
ls /usr/share/nginx/html/
cat /etc/os-release | head -3
```

Exit the container shell:

```bash
exit
```

**Inspect from the host side — view container metadata as JSON:**

```bash
docker inspect web --format '{{.State.Pid}}'
```

This prints the real PID of the container's init process on the **host**. Students can verify this with:

```bash
# On Linux only:
ps aux | grep <PID_from_above>
```

### Verification

- Students can explain that PID 1 inside the container is the application process (nginx), not systemd/init
- Students can show the container has its own IP address (not the host's)
- Students can use `docker inspect` to view container metadata from the host

---

## Task 4: Explain Linux Primitives vs Containers

### Coach Talking Points

Walk students through this table and have them confirm each concept:

| Linux Primitive | What It Does | How Containers Use It |
|---|---|---|
| **PID Namespace** | Isolates the process ID tree — the container sees PID 1 as its own init process | `ps aux` inside the container shows only container processes; the host sees the real PID |
| **NET Namespace** | Gives the container its own network stack (IP, routes, iptables) | `ip addr` shows a different IP than the host; the `docker0` bridge connects them |
| **MNT Namespace** | Isolates mount points — the container has its own root filesystem | `ls /` inside the container shows the image's filesystem, not the host's |
| **UTS Namespace** | Isolates hostname | `hostname` inside the container shows the container ID, not the host's hostname |
| **cgroups** | Limits CPU, memory, and I/O for a group of processes | `docker run --memory=128m --cpus=0.5` sets cgroup limits; exceeding memory → OOMKill |

**Key question to ask students:** *"What is the difference between a container and a virtual machine?"*

**Expected answer:**
- A **VM** runs a full operating system with its own kernel on a hypervisor. It's heavy (GBs of memory, minutes to boot).
- A **container** is a regular Linux process with namespace isolation and cgroup limits. It shares the host kernel. It's lightweight (MBs of memory, milliseconds to start).
- Containers are **not** VMs — they're processes with extra isolation boundaries.

**Optional demo — show cgroups in action:**

```bash
docker run -d --name limited --memory=32m --cpus=0.5 nginx
docker stats limited --no-stream
```

Expected output:

```
CONTAINER ID   NAME      CPU %   MEM USAGE / LIMIT   MEM %   ...
abc123def456   limited   0.00%   3.5MiB / 32MiB      10.94%  ...
```

> The `LIMIT` column shows the cgroup memory cap.

### Verification

- Students can articulate that containers use namespaces (PID, NET, MNT, UTS) for isolation
- Students can articulate that cgroups enforce resource limits
- Students understand containers share the host kernel (unlike VMs)

---

## Cleanup

```bash
docker stop web myapp limited 2>/dev/null
docker rm web myapp limited 2>/dev/null
docker rmi myapp:v1 2>/dev/null
```

---

## Common Issues

| Issue | Symptom | Fix |
|---|---|---|
| Docker daemon not running | `Cannot connect to the Docker daemon` | Start the daemon: `sudo systemctl start docker` or launch Docker Desktop |
| Port 8080 already in use | `Bind for 0.0.0.0:8080 failed: port is already allocated` | Use a different port (`-p 9090:80`) or stop whatever is using 8080 |
| Permission denied on Docker socket | `Got permission denied while trying to connect to the Docker daemon socket` | Add user to docker group: `sudo usermod -aG docker $USER` then log out/in |
| `ps` command not found inside container | `sh: ps: not found` | The base image may not have procps. Install it: `apt-get update && apt-get install -y procps` (for Debian-based images) |
| `ip` command not found inside container | `sh: ip: not found` | Some minimal images lack iproute2. Use `cat /proc/net/fib_trie` as a fallback, or install with `apt-get install -y iproute2` |
| Students confuse images and containers | They try `docker rm myapp:v1` | Explain: an **image** is a template (like a `.iso`), a **container** is a running instance. Use `docker rmi` for images, `docker rm` for containers |

