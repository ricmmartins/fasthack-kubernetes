#!/bin/bash
set -euo pipefail

echo ""
echo "🔧 Setting up FastHack Kubernetes Lab..."
echo ""

# ── Install Kind ──────────────────────────────────────────
KIND_VERSION="v0.31.0"
ARCH=$(dpkg --print-architecture)

echo "📦 Installing Kind ${KIND_VERSION}..."
curl -fsSL -o /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}"
chmod +x /tmp/kind
sudo mv /tmp/kind /usr/local/bin/kind
echo "   ✅ Kind $(kind version)"

# ── Install k9s (terminal UI) ────────────────────────────
K9S_VERSION="v0.50.4"

echo "📦 Installing k9s ${K9S_VERSION}..."
curl -fsSL -o /tmp/k9s.tar.gz "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_${ARCH}.tar.gz"
tar -xzf /tmp/k9s.tar.gz -C /tmp k9s
sudo mv /tmp/k9s /usr/local/bin/k9s
rm -f /tmp/k9s.tar.gz
echo "   ✅ k9s installed"

# ── Create Kind cluster ──────────────────────────────────
cat <<EOF > /tmp/kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30000
    hostPort: 30000
    protocol: TCP
  - containerPort: 30001
    hostPort: 30001
    protocol: TCP
  - containerPort: 30002
    hostPort: 30002
    protocol: TCP
- role: worker
- role: worker
EOF

echo ""
echo "⏳ Creating Kind cluster 'fasthack' (1 control-plane + 2 workers)..."
echo "   This may take 2-3 minutes..."
echo ""
kind create cluster --name fasthack --config /tmp/kind-config.yaml --wait 120s
rm -f /tmp/kind-config.yaml

# ── Shell configuration ──────────────────────────────────
{
  echo ""
  echo "# FastHack Kubernetes Lab"
  echo 'source <(kubectl completion bash)'
  echo 'alias k=kubectl'
  echo 'complete -o default -F __start_kubectl k'
  echo 'source <(helm completion bash)'
  echo 'export KUBE_EDITOR="code --wait"'
} >> "${HOME}/.bashrc"

# ── Verify ────────────────────────────────────────────────
echo ""
echo "✅ Lab environment ready!"
echo ""
kubectl get nodes
echo ""
echo "🎯 Start with: Student/Challenge-01.md"
