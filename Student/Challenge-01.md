# Challenge 01 — Your First Container

[< Previous Challenge](../README.md) | **[Home](../README.md)** | [Next Challenge >](Challenge-02.md)

## Introduction

Before you can understand Kubernetes, you need to understand what it manages: **containers**.

As a Linux professional, you already know about processes, namespaces, and cgroups. A container is simply a process with extra isolation — not a mini virtual machine.

In this challenge, you'll build, run, and inspect containers to understand the foundation that Kubernetes orchestrates.

## Description

Your mission is to:

1. Run your first container from a public image
2. Build a custom container image from a Dockerfile
3. Inspect the container's processes, network, and filesystem
4. Understand the relationship between Linux primitives and container isolation

## Success Criteria

- [ ] You can run an `nginx` container and access it on `http://localhost:8080`
- [ ] You built a custom image from a Dockerfile and ran it
- [ ] You can exec into a running container and list its processes (`ps aux`)
- [ ] You can explain the difference between a container and a virtual machine
- [ ] You understand how Linux namespaces and cgroups relate to container isolation

## Linux ↔ Container Reference

| Linux Concept | Container Equivalent |
|---|---|
| Process (`ps aux`) | Container process (PID 1) |
| `chroot` | Container filesystem (rootfs) |
| Namespaces (PID, NET, MNT) | Container isolation |
| cgroups | Resource limits (CPU, memory) |
| `/etc/hosts`, DNS | Container network bridge |
| `apt` / `yum` repos | Container registries (Docker Hub, GHCR) |

## Hints

<details>
<summary>Hint 1: Running a container</summary>

```bash
docker run -d --name web -p 8080:80 nginx
```

This maps port 8080 on your host to port 80 inside the container.
</details>

<details>
<summary>Hint 2: Building a custom image</summary>

Create a file named `Dockerfile`:
```dockerfile
FROM nginx:alpine
COPY index.html /usr/share/nginx/html/
```

Build it:
```bash
echo "<h1>Hello from my container!</h1>" > index.html
docker build -t myapp:v1 .
docker run -d -p 8081:80 myapp:v1
```
</details>

<details>
<summary>Hint 3: Inspecting processes inside a container</summary>

```bash
docker exec -it web sh
ps aux
ip addr
cat /etc/hostname
exit
```

Notice: PID 1 is nginx — the container has its own process namespace.
</details>

## Learning Resources

- [Docker Documentation — Getting Started](https://docs.docker.com/get-started/)
- [What is a Container? (Docker)](https://www.docker.com/resources/what-container/)
- [Linux Namespaces — man7.org](https://man7.org/linux/man-pages/man7/namespaces.7.html)
- [cgroups — Kernel Documentation](https://docs.kernel.org/admin-guide/cgroup-v2.html)

## Break & Fix 🔧

After completing the challenge, try this:

1. Run a container with `--memory=32m` and see what happens when the process exceeds it
2. Run a container with `--read-only` and try to write a file inside it
3. Run two containers and try to `ping` between them — what network do they share?
