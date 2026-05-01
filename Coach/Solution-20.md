# Solução 20 — Supply Chain & Runtime Security

[< Solução Anterior](Solution-19.md) - **[Home](README.md)**

---

> **Nota do Coach:** Este é o desafio final e o mais pesado em ferramentas. Os alunos instalarão múltiplas ferramentas CLI (Trivy, syft, cosign, kubesec, kube-linter, Falco). Ajude com problemas de instalação — eles não são o objetivo de aprendizado. As Tarefas 1-2 e 7 requerem acesso à VM (cluster kubeadm do Cap.18). As Tarefas 3-9 podem rodar no Kind. Reserve **90–120 minutos** — este é um desafio de encerramento.
>
> **Pré-requisitos para verificar:**
> - Os alunos têm um cluster Kind funcionando (`kind get clusters`)
> - Para tarefas na VM: acesso SSH aos nodes kubeadm, AppArmor instalado (`which apparmor_parser`)
> - Docker em execução (necessário para o registry local na Tarefa 5, acesso ao node Kind na Tarefa 9)
> - Helm instalado (necessário para o Falco na Tarefa 7)

Tempo estimado: **90–120 minutos**

---

## Tarefa 1: Perfis AppArmor para Containers [VM]

### Passo a passo

**Acesse o worker node via SSH** e crie o perfil AppArmor:

```bash
sudo tee /etc/apparmor.d/k8s-deny-etc-write << 'EOF'
#include <tunables/global>

profile k8s-deny-etc-write flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>

  # Allow everything by default
  file,

  # Deny writes to /etc
  deny /etc/** w,
  deny /etc/ w,
}
EOF
```

Carregue o perfil:

```bash
sudo apparmor_parser -r /etc/apparmor.d/k8s-deny-etc-write
```

### Verificação — Perfil carregado

```bash
sudo aa-status | grep k8s-deny-etc-write
```

Esperado:

```
   k8s-deny-etc-write
```

O perfil deve aparecer na seção `enforce`.

### Crie o Pod

Salve `apparmor-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: apparmor-test
spec:
  containers:
    - name: shell
      image: busybox:1.36
      command: ["sleep", "3600"]
      securityContext:
        appArmorProfile:
          type: Localhost
          localhostProfile: k8s-deny-etc-write
      resources:
        requests:
          cpu: 50m
          memory: 32Mi
        limits:
          cpu: 100m
          memory: 64Mi
```

> **Para Kubernetes < 1.30**, use a abordagem com annotation:
> ```yaml
> metadata:
>   annotations:
>     container.apparmor.security.beta.kubernetes.io/shell: localhost/k8s-deny-etc-write
> ```

Aplique:

```bash
kubectl apply -f apparmor-pod.yaml
kubectl wait --for=condition=ready pod/apparmor-test --timeout=60s
```

### Verificação — Aplicação do AppArmor

```bash
# Write to /tmp — should succeed
kubectl exec apparmor-test -- touch /tmp/allowed
echo "Exit code: $?"
```

Esperado: `Exit code: 0`

```bash
# Write to /etc — should fail
kubectl exec apparmor-test -- touch /etc/blocked
echo "Exit code: $?"
```

Esperado:

```
touch: /etc/blocked: Permission denied
command terminated with exit code 1
```

Verifique se o perfil está ativo:

```bash
kubectl exec apparmor-test -- cat /proc/1/attr/current
```

Esperado:

```
k8s-deny-etc-write (enforce)
```

> **Dica para o Coach:** Se os alunos virem `unconfined` em vez do nome do perfil, o perfil não está carregado no node onde o Pod foi agendado. Verifique em qual node o Pod está (`kubectl get pod -o wide`) e garanta que o perfil esteja carregado lá.

---

## Tarefa 2: Perfis Seccomp Personalizados [VM/Kind]

### Passo a passo

Crie o arquivo JSON do perfil seccomp:

```bash
cat > block-dangerous.json << 'EOF'
{
  "defaultAction": "SCMP_ACT_ALLOW",
  "architectures": [
    "SCMP_ARCH_X86_64",
    "SCMP_ARCH_AARCH64"
  ],
  "syscalls": [
    {
      "names": [
        "unshare",
        "mount",
        "umount2",
        "ptrace",
        "kexec_load",
        "open_by_handle_at",
        "init_module",
        "finit_module",
        "delete_module",
        "reboot"
      ],
      "action": "SCMP_ACT_ERRNO",
      "errnoRet": 1
    }
  ]
}
EOF
```

Copie para o caminho seccomp do kubelet:

```bash
# For VM (kubeadm):
sudo mkdir -p /var/lib/kubelet/seccomp/profiles
sudo cp block-dangerous.json /var/lib/kubelet/seccomp/profiles/

# For Kind:
docker exec fasthack-control-plane mkdir -p /var/lib/kubelet/seccomp/profiles
docker cp block-dangerous.json fasthack-control-plane:/var/lib/kubelet/seccomp/profiles/
```

Salve `seccomp-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-test
spec:
  securityContext:
    seccompProfile:
      type: Localhost
      localhostProfile: profiles/block-dangerous.json
  containers:
    - name: shell
      image: busybox:1.36
      command: ["sleep", "3600"]
      resources:
        requests:
          cpu: 50m
          memory: 32Mi
        limits:
          cpu: 100m
          memory: 64Mi
```

Aplique:

```bash
kubectl apply -f seccomp-pod.yaml
kubectl wait --for=condition=ready pod/seccomp-test --timeout=60s
```

### Verificação — Syscalls bloqueadas

```bash
# unshare should fail
kubectl exec seccomp-test -- unshare --user --pid --fork --mount-proc readlink /proc/self/ns/user
```

Esperado: `unshare: unshare(0x10000000): Operation not permitted` (ou erro EPERM similar)

```bash
# Normal commands should succeed
kubectl exec seccomp-test -- ls /
kubectl exec seccomp-test -- whoami
```

Esperado: Saída normal — `ls` e `whoami` não usam syscalls bloqueadas.

### Verificação — Perfil RuntimeDefault

```bash
cat > seccomp-default.yaml << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-default
spec:
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: shell
      image: busybox:1.36
      command: ["sleep", "3600"]
      resources:
        requests:
          cpu: 50m
          memory: 32Mi
EOF

kubectl apply -f seccomp-default.yaml
kubectl wait --for=condition=ready pod/seccomp-default --timeout=60s
kubectl exec seccomp-default -- ls /
```

Esperado: O Pod executa normalmente. `RuntimeDefault` é o perfil integrado do container runtime — ele bloqueia as syscalls mais perigosas (como `reboot`, `kexec_load`) enquanto permite operações normais.

> **Dica para o Coach:** Explique os tipos de perfil seccomp:
> - `Unconfined` — sem filtragem (perigoso, evite em produção)
> - `RuntimeDefault` — perfil integrado do CRI (boa linha de base)
> - `Localhost` — perfil personalizado no node (mais restritivo, melhor para defesa em profundidade)
>
> O caminho `localhostProfile` é relativo a `/var/lib/kubelet/seccomp/`. Então `profiles/block-dangerous.json` resolve para `/var/lib/kubelet/seccomp/profiles/block-dangerous.json`.

---

## Tarefa 3: Escaneamento de Imagens com Trivy [Kind]

### Passo a passo

Instale o Trivy:

```bash
curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin
trivy --version
```

### Verificação — Escanear imagens

```bash
# Scan an older image with known CVEs
trivy image --severity HIGH,CRITICAL nginx:1.21
```

Saída esperada (resumida):

```
nginx:1.21 (debian 11.2)
=========================
Total: XX (HIGH: XX, CRITICAL: XX)

┌─────────────────────┬────────────────┬──────────┬───────────────┬─────────────────────┐
│      Library        │ Vulnerability  │ Severity │ Installed Ver │    Fixed Version    │
├─────────────────────┼────────────────┼──────────┼───────────────┼─────────────────────┤
│ libssl1.1           │ CVE-2022-XXXXX │ CRITICAL │ 1.1.1k-1...  │ 1.1.1n-1...         │
...
```

> **Dica para o Coach:** A primeira execução baixa o banco de dados de vulnerabilidades (~30MB). Se os alunos estiverem offline, podem pré-baixar com `trivy image --download-db-only`.

```bash
# Scan a newer image — fewer CVEs
trivy image --severity HIGH,CRITICAL nginx:1.27

# Scan Alpine — even fewer
trivy image --severity HIGH,CRITICAL nginx:1.27-alpine
```

Os alunos devem observar:
- `nginx:1.21` — muitas CVEs (dezenas de HIGH/CRITICAL)
- `nginx:1.27` — menos CVEs (pacotes atualizados)
- `nginx:1.27-alpine` — menos CVEs ainda (imagem base mínima)

```bash
# JSON output for CI/CD pipelines
trivy image -f json -o nginx-scan.json nginx:1.21
cat nginx-scan.json | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Total vulnerabilities: {sum(len(r.get(\"Vulnerabilities\",[])) for r in d.get(\"Results\",[]))}')"
```

```bash
# Only show fixable vulnerabilities
trivy image --ignore-unfixed --severity HIGH,CRITICAL nginx:1.21
```

---

## Tarefa 4: Geração de SBOM [Kind]

### Passo a passo

Instale o syft:

```bash
curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin
syft --version
```

### Verificação — Gerar SBOMs

```bash
# Human-readable table
syft nginx:1.27-alpine
```

Esperado: Uma tabela listando todos os pacotes (pacotes apk, metadados do SO).

```bash
# CycloneDX JSON
syft nginx:1.27-alpine -o cyclonedx-json > nginx-sbom.cdx.json
cat nginx-sbom.cdx.json | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Components: {len(d.get(\"components\",[]))}')"
```

Esperado: Mostra o número de componentes (pacotes) no SBOM.

```bash
# SPDX JSON
syft nginx:1.27-alpine -o spdx-json > nginx-sbom.spdx.json
```

```bash
# Generate with Trivy (alternative)
trivy image --format cyclonedx -o nginx-trivy-sbom.cdx.json nginx:1.27-alpine
```

### Verificação — Escanear SBOM por vulnerabilidades

```bash
trivy sbom nginx-sbom.cdx.json
```

Esperado: O Trivy lê o SBOM e verifica cada componente contra o banco de dados de vulnerabilidades — mesmos resultados que escanear a imagem diretamente.

### Verificação — Comparar tamanhos de imagens

```bash
syft nginx:1.27 2>/dev/null | wc -l
syft nginx:1.27-alpine 2>/dev/null | wc -l
syft gcr.io/distroless/static-debian12 2>/dev/null | wc -l
```

Esperado (aproximado):
- `nginx:1.27` — ~150+ pacotes
- `nginx:1.27-alpine` — ~30-50 pacotes
- `gcr.io/distroless/static-debian12` — ~5-15 pacotes

> **Dica para o Coach:** Isso demonstra dramaticamente por que imagens base mínimas importam. Menos pacotes = menor superfície de ataque = menos CVEs potenciais.

---

## Tarefa 5: Assinar e Verificar Imagens com Cosign [Kind]

### Passo a passo

Instale o cosign:

```bash
curl -LO "https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64"
chmod +x cosign-linux-amd64
sudo mv cosign-linux-amd64 /usr/local/bin/cosign
cosign version
```

Esperado: Saída da versão mostrando `v2.x.x`.

Gere um par de chaves:

```bash
cosign generate-key-pair
```

Esperado: Cria `cosign.key` (privada) e `cosign.pub` (pública). Os alunos serão solicitados a definir uma senha.

Inicie um registry local:

```bash
docker run -d -p 5000:5000 --name registry registry:2 2>/dev/null || true
```

Envie uma imagem:

```bash
docker pull busybox:1.36
docker tag busybox:1.36 localhost:5000/busybox:signed
docker push localhost:5000/busybox:signed
```

### Verificação — Assinar a imagem

```bash
cosign sign --key cosign.key localhost:5000/busybox:signed --allow-insecure-registry
```

Esperado: Solicita a senha da chave privada e, em seguida, faz upload da assinatura para o registry. A saída mostra `Pushing signature to: localhost:5000/busybox:sha256-...`.

### Verificação — Verificar a assinatura

```bash
cosign verify --key cosign.pub localhost:5000/busybox:signed --allow-insecure-registry
```

Esperado:

```
Verification for localhost:5000/busybox:signed --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - The signatures were verified against the specified public key
[{"critical":{"identity":...},"optional":null}]
```

### Verificação — Imagem não assinada falha na verificação

```bash
docker tag busybox:1.36 localhost:5000/busybox:unsigned
docker push localhost:5000/busybox:unsigned
cosign verify --key cosign.pub localhost:5000/busybox:unsigned --allow-insecure-registry
```

Esperado: `Error: no matching signatures` — a verificação falha porque a imagem nunca foi assinada.

> **Dica para o Coach:** Este é o mesmo princípio do `gpg --verify` para pacotes `.deb`. Em produção, você integraria a verificação do cosign em admission controllers (como Kyverno ou OPA Gatekeeper) para rejeitar imagens não assinadas no momento do deploy.

---

## Tarefa 6: Análise Estática com Kubesec e KubeLinter [Kind]

### Passo a passo

Instale as ferramentas:

```bash
# kubesec
curl -LO https://github.com/controlplaneio/kubesec/releases/latest/download/kubesec_linux_amd64.tar.gz
tar xzf kubesec_linux_amd64.tar.gz
sudo mv kubesec /usr/local/bin/

# kube-linter
curl -LO https://github.com/stackrox/kube-linter/releases/latest/download/kube-linter-linux
chmod +x kube-linter-linux
sudo mv kube-linter-linux /usr/local/bin/kube-linter
```

Crie o manifesto inseguro:

```yaml
# Save as insecure-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: insecure-app
spec:
  containers:
    - name: app
      image: nginx
      securityContext:
        privileged: true
        runAsUser: 0
      ports:
        - containerPort: 80
```

### Verificação — Escaneamento com Kubesec

```bash
kubesec scan insecure-pod.yaml
```

Esperado (saída JSON — campos-chave):

```json
[
  {
    "object": "Pod/insecure-app.default",
    "valid": true,
    "message": "Failed with a score of -30 points",
    "score": -30,
    "scoring": {
      "critical": [
        { "id": "Privileged", "selector": "containers[] .securityContext .privileged == true", "reason": "..." }
      ],
      "advise": [
        { "id": "RunAsNonRoot", ... },
        { "id": "ReadOnlyRootFilesystem", ... }
      ]
    }
  }
]
```

A pontuação negativa indica problemas graves de segurança. `Privileged: true` é o maior infrator.

### Verificação — Escaneamento com KubeLinter

```bash
kube-linter lint insecure-pod.yaml
```

Esperado: Múltiplas descobertas:
- `run-as-non-root` — container executando como root
- `no-read-only-root-fs` — sistema de arquivos raiz é gravável
- `unset-cpu-requirements` — sem limites de recursos
- `unset-memory-requirements` — sem limites de recursos

### Verificação — Manifesto hardened pontua melhor

```yaml
# Save as secure-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-app
spec:
  containers:
    - name: app
      image: nginx:1.27-alpine
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
      ports:
        - containerPort: 80
      resources:
        requests:
          cpu: 50m
          memory: 32Mi
        limits:
          cpu: 100m
          memory: 64Mi
      volumeMounts:
        - name: tmp
          mountPath: /tmp
        - name: cache
          mountPath: /var/cache/nginx
        - name: run
          mountPath: /var/run
  volumes:
    - name: tmp
      emptyDir: {}
    - name: cache
      emptyDir: {}
    - name: run
      emptyDir: {}
```

```bash
kubesec scan secure-pod.yaml
kube-linter lint secure-pod.yaml
```

Esperado:
- Kubesec: pontuação positiva (ex: +7 ou mais)
- KubeLinter: significativamente menos ou zero descobertas

> **Dica para o Coach:** Peça aos alunos para comparar as pontuações lado a lado. O salto de -30 para +7 é dramático e demonstra visualmente o impacto do hardening de segurança.

---

## Tarefa 7: Detecção de Ameaças em Runtime com Falco [VM]

### Passo a passo

Instale o Falco via Helm:

```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update

helm install falco falcosecurity/falco \
  --namespace falco \
  --create-namespace \
  --set driver.kind=modern_ebpf \
  --set tty=true
```

> **Dica para o Coach:** Se `modern_ebpf` falhar (kernel mais antigo), tente `--set driver.kind=ebpf` ou `--set driver.kind=kmod`. O driver de módulo do kernel (`kmod`) requer os headers do kernel: `sudo apt-get install -y linux-headers-$(uname -r)`.

### Verificação — Falco está em execução

```bash
kubectl get pods -n falco
```

Esperado:

```
NAME          READY   STATUS    RESTARTS   AGE
falco-xxxxx   2/2     Running   0          60s
```

```bash
kubectl logs -n falco -l app.kubernetes.io/name=falco --tail=10
```

Esperado: Saída de log mostrando que o engine do Falco foi iniciado e as regras foram carregadas.

### Verificação — Disparar e detectar a criação de um shell

Terminal 1 — Monitore os logs do Falco:

```bash
kubectl logs -n falco -l app.kubernetes.io/name=falco -f --tail=0
```

Terminal 2 — Crie um Pod de teste e execute um shell nele:

```bash
kubectl run falco-test --image=nginx:1.27-alpine --restart=Never
kubectl wait --for=condition=ready pod/falco-test --timeout=60s
kubectl exec -it falco-test -- /bin/sh -c "whoami && cat /etc/shadow && ls /root"
```

### Verificação — Alerta nos logs do Falco

De volta no Terminal 1, procure por alertas:

```bash
kubectl logs -n falco -l app.kubernetes.io/name=falco --tail=30 | grep -E "shell|shadow|Terminal"
```

Alertas esperados (podem variar conforme a versão do Falco):

```
Notice A shell was spawned in a container with an attached terminal (...) container_id=xxx container_name=falco-test
Warning Sensitive file opened for reading (file=/etc/shadow ...)
```

> **Dica para o Coach:** Se os alunos não virem alertas, verifique:
> 1. O driver do Falco está carregado: `kubectl logs -n falco -l app.kubernetes.io/name=falco | grep -i driver`
> 2. As regras estão carregadas: `kubectl logs -n falco -l app.kubernetes.io/name=falco | grep "Loading rules"`
> 3. O Pod está em um node onde o Falco está executando (DaemonSet deploya em todos os nodes)

### Verificação — Examinar regras do Falco

```bash
# List Falco configmaps
kubectl get configmap -n falco

# View a snippet of the rules
kubectl get configmap -n falco -l app.kubernetes.io/name=falco -o yaml | grep -A3 "Terminal shell"
```

---

## Tarefa 8: Imutabilidade de Containers [Kind]

### Passo a passo

Salve `immutable-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: immutable-app
spec:
  containers:
    - name: app
      image: nginx:1.27-alpine
      securityContext:
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        runAsUser: 101
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
      ports:
        - containerPort: 80
      resources:
        requests:
          cpu: 50m
          memory: 32Mi
        limits:
          cpu: 100m
          memory: 64Mi
      volumeMounts:
        - name: tmp
          mountPath: /tmp
        - name: cache
          mountPath: /var/cache/nginx
        - name: run
          mountPath: /var/run
  volumes:
    - name: tmp
      emptyDir: {}
    - name: cache
      emptyDir: {}
    - name: run
      emptyDir: {}
```

```bash
kubectl apply -f immutable-pod.yaml
kubectl wait --for=condition=ready pod/immutable-app --timeout=60s
```

### Verificação — Sistema de arquivos somente leitura aplicado

```bash
# Write to root filesystem — should FAIL
kubectl exec immutable-app -- touch /usr/share/nginx/html/hacked.html
```

Esperado:

```
touch: /usr/share/nginx/html/hacked.html: Read-only file system
command terminated with exit code 1
```

```bash
# Write to emptyDir mount — should SUCCEED
kubectl exec immutable-app -- touch /tmp/allowed.txt
echo "Exit code: $?"
```

Esperado: `Exit code: 0`

### Verificação — Distroless não possui shell

```bash
kubectl run distroless-demo --image=gcr.io/distroless/base-debian12 --restart=Never --command -- sleep 3600
kubectl wait --for=condition=ready pod/distroless-demo --timeout=60s 2>/dev/null

# Try to get a shell — this will fail
kubectl exec -it distroless-demo -- /bin/sh
```

Esperado:

```
OCI runtime exec failed: exec failed: unable to start container process:
exec: "/bin/sh": stat /bin/sh: no such file or directory
```

> **Dica para o Coach:** Esta é uma medida de segurança poderosa — mesmo que um atacante consiga RCE na aplicação, não há shell disponível para movimentação lateral. Combinado com `readOnlyRootFilesystem`, também não é possível instalar ferramentas.

### Verificação — Comparação de quantidade de pacotes

```bash
echo "=== Full Debian-based nginx ==="
syft nginx:1.27 2>/dev/null | wc -l

echo "=== Alpine-based nginx ==="
syft nginx:1.27-alpine 2>/dev/null | wc -l

echo "=== Distroless static ==="
syft gcr.io/distroless/static-debian12 2>/dev/null | wc -l
```

Esperado: Diminuição dramática na quantidade de pacotes — demonstrando a redução da superfície de ataque.

---

## Tarefa 9: Análise de Audit Log do Kubernetes [Kind]

### Passo a passo

Crie o arquivo de política de auditoria:

```bash
cat > audit-policy.yaml << 'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  - level: None
    nonResourceURLs:
      - "/healthz*"
      - "/version"
      - "/swagger*"
      - "/readyz*"
      - "/livez*"

  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets"]

  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["clusterroles", "clusterrolebindings", "roles", "rolebindings"]

  - level: Request
    resources:
      - group: ""
        resources: ["pods", "pods/exec", "pods/portforward"]
    verbs: ["create", "delete", "patch", "update"]

  - level: Metadata
    omitStages:
      - "RequestReceived"
EOF
```

Crie a configuração do cluster Kind:

```bash
mkdir -p audit-logs

cat > kind-audit.yaml << 'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: ./audit-policy.yaml
        containerPath: /etc/kubernetes/audit-policy.yaml
        readOnly: true
      - hostPath: ./audit-logs
        containerPath: /var/log/kubernetes
    kubeadmConfigPatches:
      - |
        kind: ClusterConfiguration
        apiServer:
          extraArgs:
            audit-policy-file: /etc/kubernetes/audit-policy.yaml
            audit-log-path: /var/log/kubernetes/audit.log
            audit-log-maxage: "7"
            audit-log-maxbackup: "3"
            audit-log-maxsize: "50"
          extraVolumes:
            - name: audit-policy
              hostPath: /etc/kubernetes/audit-policy.yaml
              mountPath: /etc/kubernetes/audit-policy.yaml
              readOnly: true
            - name: audit-log
              hostPath: /var/log/kubernetes/
              mountPath: /var/log/kubernetes/
              readOnly: false
EOF
```

Crie o cluster:

```bash
kind create cluster --name audit-lab --config kind-audit.yaml
```

### Verificação — Auditoria está ativa

```bash
# Check the API server has audit flags
docker exec audit-lab-control-plane cat /etc/kubernetes/manifests/kube-apiserver.yaml | grep audit
```

Esperado: Linhas mostrando `--audit-policy-file` e `--audit-log-path`.

```bash
# Verify audit log file exists
docker exec audit-lab-control-plane ls -la /var/log/kubernetes/audit.log
```

Esperado: O arquivo existe e está crescendo.

### Gere eventos de auditoria

```bash
# Switch to the audit-lab context
kubectl cluster-info --context kind-audit-lab

# Create a secret
kubectl create secret generic audit-test-secret --from-literal=password=supersecret

# Create and delete a Pod
kubectl run audit-pod --image=busybox:1.36 --restart=Never --command -- sleep 30
sleep 5
kubectl delete pod audit-pod

# Exec into a Pod
kubectl run audit-exec --image=busybox:1.36 --restart=Never --command -- sleep 3600
kubectl wait --for=condition=ready pod/audit-exec --timeout=60s
kubectl exec audit-exec -- whoami
```

### Verificação — Analisar logs de auditoria

```bash
# Find secret access events
docker exec audit-lab-control-plane cat /var/log/kubernetes/audit.log | \
  python3 -c "
import sys, json
for line in sys.stdin:
    try:
        e = json.loads(line)
        if e.get('objectRef', {}).get('resource') == 'secrets':
            print(f\"{e['verb']:10s} {e['objectRef'].get('name','?'):30s} by {e['user'].get('username','?'):30s} at {e.get('requestReceivedTimestamp','?')}\")
    except: pass
"
```

Esperado: Mostra `create audit-test-secret by kubernetes-admin` (e possivelmente outros acessos de secrets do sistema).

```bash
# Find Pod exec events
docker exec audit-lab-control-plane cat /var/log/kubernetes/audit.log | \
  python3 -c "
import sys, json
for line in sys.stdin:
    try:
        e = json.loads(line)
        if e.get('objectRef', {}).get('subresource') == 'exec':
            print(f\"EXEC into {e['objectRef'].get('name','?'):20s} by {e['user'].get('username','?'):20s} at {e.get('requestReceivedTimestamp','?')}\")
    except: pass
"
```

Esperado: Mostra `EXEC into audit-exec by kubernetes-admin`.

```bash
# Count API calls per user
docker exec audit-lab-control-plane cat /var/log/kubernetes/audit.log | \
  python3 -c "
import sys, json
from collections import Counter
users = Counter()
for line in sys.stdin:
    try:
        e = json.loads(line)
        users[e['user'].get('username','unknown')] += 1
    except: pass
for user, count in users.most_common(10):
    print(f'{count:6d}  {user}')
"
```

Esperado: Mostra contas do sistema (`system:apiserver`, `system:kube-scheduler`, etc.) com mais chamadas, além de `kubernetes-admin` para as ações dos alunos.

> **Dica para o Coach:** Em uma investigação de segurança real, você procuraria por:
> - Usuários incomuns acessando secrets (potencial roubo de credenciais)
> - `pods/exec` de service accounts inesperadas (potencial escape de container)
> - Alterações de RBAC por usuários não-admin (escalação de privilégios)
> - Alta taxa de chamadas API de uma única fonte (potencial reconhecimento)
>
> Os níveis da política de auditoria controlam a verbosidade:
> - `None` — não registrar
> - `Metadata` — registrar quem/o quê/quando (sem corpos de request/response)
> - `Request` — registrar metadados + corpo da requisição
> - `RequestResponse` — registrar tudo (mais verboso, use para recursos sensíveis)

---

## Limpeza

```bash
# Task 1-2
kubectl delete pod apparmor-test seccomp-test seccomp-default 2>/dev/null

# Task 5 — local registry
docker rm -f registry 2>/dev/null

# Task 7 — Falco
kubectl delete pod falco-test 2>/dev/null
helm uninstall falco -n falco 2>/dev/null
kubectl delete namespace falco 2>/dev/null

# Task 8
kubectl delete pod immutable-app distroless-demo 2>/dev/null

# Task 9
kubectl delete pod audit-exec 2>/dev/null
kubectl delete secret audit-test-secret 2>/dev/null
kind delete cluster --name audit-lab 2>/dev/null
rm -rf audit-logs

# Tool artifacts
rm -f cosign.key cosign.pub nginx-scan.json nginx-sbom.cdx.json nginx-sbom.spdx.json nginx-trivy-sbom.cdx.json
rm -f block-dangerous.json kubesec_linux_amd64.tar.gz
rm -f insecure-pod.yaml secure-pod.yaml
```

---

## Soluções Break & Fix

### Cenário 1 — Perfil Seccomp não está sendo aplicado

**Problema:** O spec do Pod referencia `localhostProfile: block-dangerous.json` mas o arquivo está em `/var/lib/kubelet/seccomp/profiles/block-dangerous.json`.

**Correção:** Altere `localhostProfile` para `profiles/block-dangerous.json` — o caminho é relativo a `/var/lib/kubelet/seccomp/`.

**Como verificar a correção:**

```bash
kubectl get pod broken-seccomp -o yaml | grep -A3 seccompProfile
```

O `localhostProfile` deve mostrar `profiles/block-dangerous.json`.

### Cenário 2 — Container imutável crashando na inicialização

**Problema:** O Nginx precisa escrever em `/var/cache/nginx`, `/var/run` e `/tmp`, mas `readOnlyRootFilesystem: true` torna esses caminhos somente leitura.

**Correção:** Adicione volumes `emptyDir` para os caminhos graváveis:

```yaml
volumeMounts:
  - name: tmp
    mountPath: /tmp
  - name: cache
    mountPath: /var/cache/nginx
  - name: run
    mountPath: /var/run
volumes:
  - name: tmp
    emptyDir: {}
  - name: cache
    emptyDir: {}
  - name: run
    emptyDir: {}
```

**Como verificar a correção:**

```bash
kubectl get pod broken-immutable
# Should show Running, not CrashLoopBackOff
kubectl exec broken-immutable -- nginx -t
# Should show "test is successful"
```

### Cenário 3 — Falco não está detectando nada

**Problema:** O driver eBPF falhou ao carregar (headers do kernel ausentes ou kernel não suportado).

**Correção:**

```bash
# Check driver status
kubectl logs -n falco -l app.kubernetes.io/name=falco | grep -i "driver\|error"

# Option 1: Switch to kernel module driver
helm upgrade falco falcosecurity/falco -n falco --set driver.kind=kmod

# Option 2: Install kernel headers
sudo apt-get install -y linux-headers-$(uname -r)
# Then restart Falco pods
kubectl rollout restart daemonset/falco -n falco
```

**Como verificar a correção:**

```bash
kubectl logs -n falco -l app.kubernetes.io/name=falco | grep -i "driver.*loaded\|engine.*started"
# Then trigger a shell spawn and check for alerts
kubectl exec -it falco-test -- /bin/sh -c "exit"
kubectl logs -n falco -l app.kubernetes.io/name=falco --tail=5 | grep -i shell
```
