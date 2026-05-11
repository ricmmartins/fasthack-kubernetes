#!/bin/bash

cat << 'WELCOME'

  ╔════════════════════════════════════════════════════════════╗
  ║  🚀 FastHack Kubernetes Lab                               ║
  ║  Do Servidor ao Cluster — Um Hackathon Hands-on           ║
  ╚════════════════════════════════════════════════════════════╝

  Seu ambiente de lab está pronto! Ferramentas instaladas:

    ☸️  kubectl    CLI do Kubernetes
    🐳 docker     Runtime de containers (Docker-in-Docker)
    📦 kind       Clusters Kubernetes locais
    ⎈  helm       Gerenciador de pacotes do Kubernetes
    🖥️  k9s        Interface terminal para Kubernetes

  Um cluster Kind chamado 'fasthack' está rodando com:
    • 1 nó control-plane
    • 2 nós worker

  Comandos rápidos:
    kubectl get nodes          Verificar seu cluster
    kubectl get pods -A        Ver todos os pods rodando
    k get deploy               Usando o alias 'k' para kubectl
    k9s                        Abrir a interface terminal
    kind delete cluster --name fasthack   Resetar tudo

  📖 Comece pelo: Student/Challenge-01.md

  Bom hacking! 🎯

WELCOME

echo "  ── Status do Cluster ─────────────────────────────────────"
kubectl get nodes 2>/dev/null || echo "  ⚠️  Cluster não está rodando. Execute: kind create cluster --name fasthack"
echo ""
