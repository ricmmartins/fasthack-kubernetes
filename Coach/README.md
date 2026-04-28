# Coach's Guide

This directory contains solutions and guidance for coaches running the Kubernetes for Linux Sysadmins Hackathon.

## Guidelines for Coaches

1. **Don't give answers immediately** — let students struggle and discover. That's where learning happens.
2. **Use the Linux analogy** — when a student is stuck, relate the K8s concept back to Linux. "Remember iptables? NetworkPolicy is the same idea."
3. **Encourage `kubectl describe`** — most answers are in the events section of `describe` output.
4. **Let them break things** — the Break & Fix sections are the most valuable learning moments.
5. **Validate, don't memorize** — students should reference the [official docs](https://kubernetes.io/docs/) during the hackathon.

## Solutions

- [Solution 01: Your First Container](Solution-01.md)
- [Solution 02: From Container to Pod](Solution-02.md)
- [Solution 03: Creating a Local Cluster](Solution-03.md)
- [Solution 04: Deployments and Rolling Updates](Solution-04.md)
- [Solution 05: Services and Networking](Solution-05.md)
- [Solution 06: Ingress and Gateway API](Solution-06.md)
- [Solution 07: Volumes and Persistence](Solution-07.md)
- [Solution 08: ConfigMaps and Secrets](Solution-08.md)
- [Solution 09: Security: RBAC and Pod Security](Solution-09.md)
- [Solution 10: Autoscaling and Resource Management](Solution-10.md)
- [Solution 11: Helm, Kustomize, and GitOps](Solution-11.md)
- [Solution 12: Observability: Prometheus and Grafana](Solution-12.md)
- [Solution 13: Troubleshooting: Break and Fix](Solution-13.md)
- [Solution 14: Deploy to the Cloud](Solution-14.md)

## Timing Recommendations

| Challenge | Estimated Time | Notes |
|-----------|---------------|-------|
| 01 | 30 min | Quick if Docker experience exists |
| 02 | 30 min | First kubectl experience |
| 03 | 45 min | Cluster setup can vary |
| 04 | 45 min | Core deployment concepts |
| 05 | 60 min | Networking takes time |
| 06 | 60 min | Ingress setup is common pain point |
| 07 | 45 min | Storage concepts click fast for Linux people |
| 08 | 30 min | Straightforward |
| 09 | 60 min | RBAC is conceptually complex |
| 10 | 45 min | Metrics Server setup needed |
| 11 | 60 min | Helm has a learning curve |
| 12 | 60 min | Stack installation takes time |
| 13 | 90 min | Most valuable challenge |
| 14 | 60+ min | Depends on cloud access |

**Total: ~10-12 hours** (ideal for a 2-day hackathon)
