#!/bin/bash

cat << 'WELCOME'

  ╔════════════════════════════════════════════════════════════╗
  ║  🚀 FastHack Kubernetes Lab                               ║
  ║  From Server to Cluster — A Hands-on Hackathon            ║
  ╚════════════════════════════════════════════════════════════╝

  Your lab environment is ready! Here's what's installed:

    ☸️  kubectl    Kubernetes CLI
    🐳 docker     Container runtime (Docker-in-Docker)
    📦 kind       Local Kubernetes clusters
    ⎈  helm       Kubernetes package manager
    🖥️  k9s        Terminal UI for Kubernetes

  A Kind cluster named 'fasthack' is running with:
    • 1 control-plane node
    • 2 worker nodes

  Quick commands:
    kubectl get nodes          Check your cluster
    kubectl get pods -A        See all running pods
    k get deploy               Using the 'k' alias for kubectl
    k9s                        Launch the terminal UI
    kind delete cluster --name fasthack   Reset everything

  📖 Start with: Student/Challenge-01.md

  Happy hacking! 🎯

WELCOME

echo "  ── Cluster Status ──────────────────────────────────────"
kubectl get nodes 2>/dev/null || echo "  ⚠️  Cluster not running. Run: kind create cluster --name fasthack"
echo ""
