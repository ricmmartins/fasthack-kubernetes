# Desafio 20 — Supply Chain & Runtime Security

[< Desafio Anterior](Challenge-19.md) - **[Início](../README.md)**

## Introdução

Em um servidor Linux hardened, a segurança é em camadas. Você restringe quais chamadas de sistema um processo pode fazer com `seccomp-bpf`. Você confina daemons apenas aos arquivos e capacidades que precisam com `AppArmor` ou `SELinux`. Você verifica pacotes em busca de CVEs conhecidas com ferramentas como `apt-get audit` ou `yum updateinfo`. Você verifica assinaturas de pacotes com GPG antes de instalar. Você executa detecção de intrusão com `OSSEC` ou `AIDE` para capturar mudanças inesperadas em arquivos ou spawns de processos. E você envia toda entrada de `syslog` e `auditd` para um SIEM central para análise.

O Kubernetes herda todas essas preocupações — mas os pontos de aplicação se movem do host para a API do cluster, o container runtime e o pipeline de supply chain. Em vez de proteger um servidor, você está protegendo uma plataforma inteira onde workloads são efêmeros, imagens vêm de registries, e toda chamada de API é registrada em um audit log.

Este **desafio final** reúne os domínios restantes do CKS (Certified Kubernetes Security Specialist): **System Hardening**, **Minimize Microservice Vulnerabilities**, **Supply Chain Security** e **Monitoring, Logging & Runtime Security**. Você aplicará a mesma filosofia de defesa em profundidade que conhece do Linux — apenas com ferramentas nativas do Kubernetes.

| Conceito Linux | Equivalente Kubernetes | Notas |
|---|---|---|
| AppArmor / SELinux profiles | `appArmorProfile` in securityContext | Confina processos de containers ao acesso permitido de arquivos/rede/capabilities |
| `seccomp-bpf` syscall filtering | `seccompProfile` in securityContext | Bloqueia syscalls perigosas como `unshare`, `mount`, `ptrace` |
| `dpkg --list` / `rpm -qa` | Geração de SBOM com `syft` ou `trivy` | Inventaria cada pacote em uma imagem de container |
| `gpg --verify` assinaturas de pacotes | `cosign sign` / `cosign verify` | Assinatura criptográfica de imagens e verificação |
| `apt-get audit` / Nessus scans | `trivy image` vulnerability scanning | Encontra CVEs em imagens de container antes do deployment |
| `shellcheck` para scripts | `kubesec scan` / `kube-linter lint` | Análise estática de manifestos Kubernetes para falhas de segurança |
| OSSEC / AIDE / auditd | Falco runtime threat detection | Detecta syscalls suspeitas, acesso a arquivos, atividade de rede em containers |
| CIS Benchmarks / `lynis audit` | Minimizar footprint do host OS, containers imutáveis | Reduz superfície de ataque em nodes e imagens de container |
| `/var/log/audit/audit.log` | Kubernetes API audit logs | Registra quem fez o quê em qual recurso e quando |

> **Requisitos do cluster:**
> - **Tarefas marcadas com [VM]** requerem acesso SSH a um node de cluster kubeadm (do Desafio 18). AppArmor e Falco operam no nível do kernel/node.
> - **Tarefas marcadas com [Kind]** rodam no seu cluster Kind local — nenhuma conta cloud necessária.
>
> ```bash
> # Se você precisar de um cluster Kind novo:
> kind create cluster --name fasthack
> ```

## Descrição

### Tarefa 1 — AppArmor Profiles para Containers [VM]

AppArmor no Kubernetes funciona da mesma forma que em um servidor Linux — você escreve um profile que restringe acesso a arquivos, capabilities e operações de rede, e então o aplica. A diferença é que o profile é aplicado aos processos do container via o `securityContext` do Pod.

**Passo 1:** Conecte via SSH no worker node do kubeadm e crie um profile AppArmor que nega escritas em `/etc`. Salve como `/etc/apparmor.d/k8s-deny-etc-write`:

```
#include <tunables/global>

profile k8s-deny-etc-write flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>

  # Permite tudo por padrão
  file,

  # Nega escritas em /etc
  deny /etc/** w,
  deny /etc/ w,
}
```

**Passo 2:** Carregue e verifique o profile:

```bash
sudo apparmor_parser -r /etc/apparmor.d/k8s-deny-etc-write
sudo aa-status | grep k8s-deny-etc-write
```

**Passo 3:** Crie um Pod que usa este profile. No Kubernetes 1.30+, use o campo `securityContext`. Salve como `apparmor-pod.yaml`:

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

> **Nota:** Para clusters rodando Kubernetes < 1.30, use a abordagem por annotation:
> ```yaml
> metadata:
>   annotations:
>     container.apparmor.security.beta.kubernetes.io/shell: localhost/k8s-deny-etc-write
> ```

**Passo 4:** Aplique e teste — escritas em `/etc` devem ser negadas:

```bash
kubectl apply -f apparmor-pod.yaml
kubectl exec apparmor-test -- touch /tmp/allowed          # Deve ter sucesso
kubectl exec apparmor-test -- touch /etc/blocked           # Deve ser NEGADO
```

**Passo 5:** Verifique que o profile AppArmor está ativo dentro do container:

```bash
kubectl exec apparmor-test -- cat /proc/1/attr/current
```

Você deve ver `k8s-deny-etc-write (enforce)`.

### Tarefa 2 — Custom Seccomp Profiles [VM/Kind]

Seccomp (Secure Computing Mode) filtra syscalls no nível do kernel — como `seccomp-bpf` no Linux. Você cria um profile JSON que permite ou bloqueia chamadas de sistema específicas, e então o referencia na spec do Pod.

**Passo 1:** Crie um profile seccomp customizado que bloqueia syscalls perigosas. No node (VM) ou container Kind, coloque-o no caminho de profiles seccomp do kubelet:

```bash
# Para VM (kubeadm):
sudo mkdir -p /var/lib/kubelet/seccomp/profiles

# Para Kind — entre no node do control plane:
docker exec -it fasthack-control-plane mkdir -p /var/lib/kubelet/seccomp/profiles
```

Crie o arquivo de profile `block-dangerous.json`:

```json
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
```

**Passo 2:** Copie o profile para o local correto:

```bash
# Para VM:
sudo cp block-dangerous.json /var/lib/kubelet/seccomp/profiles/

# Para Kind:
docker cp block-dangerous.json fasthack-control-plane:/var/lib/kubelet/seccomp/profiles/
```

**Passo 3:** Crie um Pod que usa este profile seccomp. Salve como `seccomp-pod.yaml`:

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

**Passo 4:** Aplique e verifique as syscalls bloqueadas:

```bash
kubectl apply -f seccomp-pod.yaml

# Isto deve falhar — unshare está bloqueado
kubectl exec seccomp-test -- unshare --user --pid --fork --mount-proc readlink /proc/self/ns/user

# Isto deve ter sucesso — comandos normais são permitidos
kubectl exec seccomp-test -- ls /
```

**Passo 5:** Também crie um Pod com profile seccomp `RuntimeDefault` (a baseline recomendada):

```yaml
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
```

### Tarefa 3 — Image Scanning com Trivy [Kind]

Trivy escaneia imagens de container em busca de CVEs conhecidas — como executar `apt-get audit` ou um scan Nessus contra cada pacote na imagem. Ele verifica os pacotes do OS, dependências específicas de linguagem e arquivos de configuração.

**Passo 1:** Instale o Trivy:

```bash
# No Ubuntu/Debian:
sudo apt-get install -y wget apt-transport-https gnupg lsb-release
sudo mkdir -p /etc/apt/keyrings
wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | sudo gpg --dearmor -o /etc/apt/keyrings/trivy.gpg
echo "deb [signed-by=/etc/apt/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -sc) main" | sudo tee /etc/apt/sources.list.d/trivy.list
sudo apt-get update && sudo apt-get install -y trivy

# Ou binário direto:
curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin
```

**Passo 2:** Escaneie uma imagem com vulnerabilidades conhecidas:

```bash
# Escaneia nginx para todas as severidades de vulnerabilidade
trivy image nginx:1.21

# Filtra apenas HIGH e CRITICAL
trivy image --severity HIGH,CRITICAL nginx:1.21

# Escaneia com saída JSON para automação
trivy image -f json -o nginx-scan.json nginx:1.21
```

**Passo 3:** Escaneie uma imagem mínima e compare:

```bash
trivy image nginx:1.27-alpine
```

**Passo 4:** Escaneie ignorando CVEs sem correção (mostra apenas vulnerabilidades acionáveis):

```bash
trivy image --ignore-unfixed nginx:1.21
```

**Passo 5:** Compare as contagens de vulnerabilidades entre `nginx:1.21`, `nginx:1.27` e `nginx:1.27-alpine`. Note como imagens mais novas e menores têm menos CVEs.

### Tarefa 4 — Geração de SBOM [Kind]

Um Software Bill of Materials (SBOM) é o equivalente em container do `dpkg --list` — ele inventaria cada pacote, biblioteca e dependência dentro de uma imagem. SBOMs são essenciais para rastreamento de vulnerabilidades, conformidade de licenças e resposta a incidentes.

**Passo 1:** Instale o syft:

```bash
curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin
```

**Passo 2:** Gere um SBOM com syft:

```bash
# Saída em tabela padrão — legível por humanos
syft nginx:1.27-alpine

# Formato CycloneDX JSON (padrão da indústria)
syft nginx:1.27-alpine -o cyclonedx-json > nginx-sbom.cdx.json

# Formato SPDX JSON
syft nginx:1.27-alpine -o spdx-json > nginx-sbom.spdx.json
```

**Passo 3:** Gere um SBOM usando Trivy (ferramenta alternativa):

```bash
trivy image --format cyclonedx -o nginx-trivy-sbom.cdx.json nginx:1.27-alpine
```

**Passo 4:** Escaneie o SBOM em busca de vulnerabilidades (Trivy pode escanear SBOMs diretamente):

```bash
trivy sbom nginx-sbom.cdx.json
```

**Passo 5:** Compare as contagens de pacotes entre uma imagem completa e uma imagem Alpine/distroless:

```bash
syft nginx:1.27 | wc -l
syft nginx:1.27-alpine | wc -l
syft gcr.io/distroless/static-debian12 | wc -l
```

### Tarefa 5 — Assinar e Verificar Imagens com Cosign [Kind]

Cosign fornece assinatura criptográfica para imagens de container — como assinar pacotes `.deb` com GPG para que você possa verificar que não foram adulterados.

**Passo 1:** Instale o cosign:

```bash
curl -LO "https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64"
chmod +x cosign-linux-amd64
sudo mv cosign-linux-amd64 /usr/local/bin/cosign
cosign version
```

**Passo 2:** Gere um par de chaves:

```bash
cosign generate-key-pair
# Cria cosign.key (privada) e cosign.pub (pública)
# Você será solicitado a criar uma senha — lembre-se dela
```

**Passo 3:** Para este exercício, usaremos um registry local para fazer push e assinar uma imagem:

```bash
# Inicie um registry local (se não estiver rodando)
docker run -d -p 5000:5000 --name registry registry:2

# Tag e push de uma imagem
docker pull busybox:1.36
docker tag busybox:1.36 localhost:5000/busybox:signed
docker push localhost:5000/busybox:signed
```

**Passo 4:** Assine a imagem:

```bash
cosign sign --key cosign.key localhost:5000/busybox:signed --allow-insecure-registry
```

**Passo 5:** Verifique a assinatura:

```bash
cosign verify --key cosign.pub localhost:5000/busybox:signed --allow-insecure-registry
```

A saída mostrará o payload da assinatura com metadados verificados. Uma imagem não assinada ou adulterada falharia na verificação.

**Passo 6:** Tente verificar uma imagem não assinada — deve falhar:

```bash
docker tag busybox:1.36 localhost:5000/busybox:unsigned
docker push localhost:5000/busybox:unsigned
cosign verify --key cosign.pub localhost:5000/busybox:unsigned --allow-insecure-registry
```

### Tarefa 6 — Análise Estática com Kubesec e KubeLinter [Kind]

Ferramentas de análise estática escaneiam seus manifestos YAML em busca de falhas de segurança antes mesmo de fazer deploy — como `shellcheck` para shell scripts ou `lint` para código.

**Passo 1:** Instale kubesec e kube-linter:

```bash
# kubesec — mais fácil via Docker
# Ou baixe o binário:
curl -LO https://github.com/controlplaneio/kubesec/releases/latest/download/kubesec_linux_amd64.tar.gz
tar xzf kubesec_linux_amd64.tar.gz
sudo mv kubesec /usr/local/bin/

# kube-linter
curl -LO https://github.com/stackrox/kube-linter/releases/latest/download/kube-linter-linux
chmod +x kube-linter-linux
sudo mv kube-linter-linux /usr/local/bin/kube-linter
```

**Passo 2:** Crie um manifesto intencionalmente inseguro. Salve como `insecure-pod.yaml`:

```yaml
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

**Passo 3:** Escaneie com kubesec:

```bash
kubesec scan insecure-pod.yaml
```

Revise a saída JSON — note o **score** (menor é pior), os achados **critical** e **advisory**. Um container privilegiado rodando como root terá uma pontuação muito ruim.

**Passo 4:** Escaneie com kube-linter:

```bash
kube-linter lint insecure-pod.yaml
```

Note as verificações específicas que falham (ex.: `run-as-non-root`, `no-read-only-root-fs`, `unset-cpu-requirements`).

**Passo 5:** Crie uma versão hardened e escaneie novamente. Salve como `secure-pod.yaml`:

```yaml
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

Compare as pontuações — o manifesto hardened deve pontuar significativamente melhor.

### Tarefa 7 — Detecção de Ameaças em Runtime com Falco [VM]

Falco é o equivalente Kubernetes do `OSSEC` ou `AIDE` — ele monitora syscalls em tempo real e alerta quando atividade suspeita ocorre (spawns de shell em containers, leituras de arquivos sensíveis, conexões de rede inesperadas).

**Passo 1:** Instale o Falco no seu cluster kubeadm usando Helm:

```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update

helm install falco falcosecurity/falco \
  --namespace falco \
  --create-namespace \
  --set driver.kind=modern_ebpf \
  --set tty=true
```

**Passo 2:** Verifique que o Falco está rodando:

```bash
kubectl get pods -n falco -o wide
kubectl wait --namespace falco --for=condition=ready pod --selector=app.kubernetes.io/name=falco --timeout=120s
```

**Passo 3:** Observe os logs do Falco em um terminal:

```bash
kubectl logs -n falco -l app.kubernetes.io/name=falco -f --tail=50
```

**Passo 4:** Em outro terminal, dispare uma detecção — abra um shell dentro de um container:

```bash
# Crie um Pod de teste
kubectl run falco-test --image=nginx:1.27-alpine --restart=Never

# Aguarde estar pronto
kubectl wait --for=condition=ready pod/falco-test --timeout=60s

# Abra um shell — Falco deve detectar isso!
kubectl exec -it falco-test -- /bin/sh -c "whoami && cat /etc/shadow"
```

**Passo 5:** Verifique os logs do Falco em busca do alerta:

```bash
kubectl logs -n falco -l app.kubernetes.io/name=falco --tail=20 | grep -i "shell\|exec\|shadow"
```

Você deve ver alertas como:
- `Notice A shell was spawned in a container`
- `Warning Sensitive file opened for reading (file=/etc/shadow)`

**Passo 6:** Examine as regras padrão do Falco:

```bash
kubectl get configmap -n falco falco-rules -o yaml | head -100
```

### Tarefa 8 — Imutabilidade de Containers [Kind]

Um container imutável é o equivalente de montar um filesystem como somente leitura (`mount -o ro`) e remover todas as ferramentas administrativas (`rm /bin/sh`). Se um atacante entrar em um container, ele não pode modificar arquivos, instalar backdoors ou usar um shell.

**Passo 1:** Crie um Pod com `readOnlyRootFilesystem` e `emptyDir` para arquivos temporários. Salve como `immutable-pod.yaml`:

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

**Passo 2:** Aplique e verifique que o filesystem é somente leitura:

```bash
kubectl apply -f immutable-pod.yaml

# Isto deve FALHAR — filesystem é somente leitura
kubectl exec immutable-app -- touch /usr/share/nginx/html/hacked.html

# Isto deve TER SUCESSO — /tmp é gravável via emptyDir
kubectl exec immutable-app -- touch /tmp/allowed.txt
```

**Passo 3:** Demonstre por que imagens distroless melhoram a segurança — elas não têm shell:

```bash
# Crie um Pod com uma imagem distroless
kubectl run distroless-test --image=gcr.io/distroless/static-debian12 --restart=Never --command -- /bin/sleep 3600

# Isso vai falhar porque a imagem não tem sleep — esse é o ponto!
# Use uma imagem distroless real de aplicação na prática

# Tente entrar com exec — nenhum shell disponível
kubectl run distroless-demo --image=gcr.io/distroless/base-debian12 --restart=Never --command -- sleep 3600
kubectl exec -it distroless-demo -- /bin/sh
# Error: OCI runtime exec failed: exec failed: unable to start container process: exec: "/bin/sh": stat /bin/sh: no such file or directory
```

**Passo 4:** Liste os pacotes em imagens distroless vs. regulares para ver a diferença na superfície de ataque:

```bash
# Imagem regular baseada em Debian
syft nginx:1.27 | wc -l

# Baseada em Alpine
syft nginx:1.27-alpine | wc -l

# Distroless
syft gcr.io/distroless/static-debian12 | wc -l
```

### Tarefa 9 — Análise de Audit Log do Kubernetes [Kind]

Os audit logs do Kubernetes registram cada requisição à API — como `auditd` no Linux mas para a API do cluster. Eles dizem quem criou, modificou ou deletou recursos, e podem revelar atividade suspeita como acesso não autorizado a secrets ou tentativas de escalação de privilégios.

**Passo 1:** Crie uma política de auditoria. Salve como `audit-policy.yaml`:

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  # Não registra requisições para endpoints healthz ou API discovery
  - level: None
    nonResourceURLs:
      - "/healthz*"
      - "/version"
      - "/swagger*"
      - "/readyz*"
      - "/livez*"

  # Registra acesso a Secrets no nível Metadata (não registra os dados reais do secret!)
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets"]

  # Registra mudanças de RBAC no nível RequestResponse
  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["clusterroles", "clusterrolebindings", "roles", "rolebindings"]

  # Registra criação/deleção de Pod no nível Request
  - level: Request
    resources:
      - group: ""
        resources: ["pods", "pods/exec", "pods/portforward"]
    verbs: ["create", "delete", "patch", "update"]

  # Registra todo o resto no nível Metadata
  - level: Metadata
    omitStages:
      - "RequestReceived"
```

**Passo 2:** Para Kind, crie um cluster com audit logging habilitado. Salve como `kind-audit.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
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
```

```bash
# Copie a política de auditoria para o node Kind primeiro, depois crie o cluster
kind create cluster --name audit-lab --config kind-audit.yaml

# Copie a política de auditoria para o node
docker cp audit-policy.yaml audit-lab-control-plane:/etc/kubernetes/audit-policy.yaml

# O API server precisa ser reiniciado para aplicar a política
# Para Kind, recrie o cluster com a política pré-carregada:
kind delete cluster --name audit-lab

# Crie o arquivo de política dentro do node image usando uma abordagem de init container
# Método mais simples: monte a política via extraMounts do Kind
```

**Abordagem alternativa — use extraMounts na configuração do Kind:**

```yaml
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
```

```bash
mkdir -p audit-logs
kind create cluster --name audit-lab --config kind-audit.yaml
```

**Passo 3:** Gere alguns eventos de auditoria:

```bash
# Crie um secret
kubectl create secret generic audit-test-secret --from-literal=password=supersecret

# Crie e delete um Pod
kubectl run audit-pod --image=busybox:1.36 --restart=Never --command -- sleep 30
kubectl delete pod audit-pod

# Execute exec em um Pod
kubectl run audit-exec --image=busybox:1.36 --restart=Never --command -- sleep 3600
kubectl wait --for=condition=ready pod/audit-exec --timeout=60s
kubectl exec audit-exec -- whoami
```

**Passo 4:** Analise o audit log:

```bash
# Leia o audit log do node Kind
docker exec audit-lab-control-plane cat /var/log/kubernetes/audit.log | head -50

# Encontre quem acessou secrets
docker exec audit-lab-control-plane cat /var/log/kubernetes/audit.log | \
  python3 -c "
import sys, json
for line in sys.stdin:
    try:
        e = json.loads(line)
        if e.get('objectRef', {}).get('resource') == 'secrets':
            print(f\"{e['verb']} {e['objectRef'].get('name','?')} by {e['user'].get('username','?')} at {e['requestReceivedTimestamp']}\")
    except: pass
"

# Encontre eventos de Pod exec (indicador potencial de escape de container)
docker exec audit-lab-control-plane cat /var/log/kubernetes/audit.log | \
  python3 -c "
import sys, json
for line in sys.stdin:
    try:
        e = json.loads(line)
        if e.get('objectRef', {}).get('subresource') == 'exec':
            print(f\"EXEC into {e['objectRef'].get('name','?')} by {e['user'].get('username','?')} at {e['requestReceivedTimestamp']}\")
    except: pass
"
```

**Passo 5:** Identifique padrões suspeitos no audit log:

```bash
# Conte chamadas de API por usuário — identifique atividade incomum
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

### Limpe

```bash
# Recursos das Tarefas 1-2
kubectl delete pod apparmor-test seccomp-test seccomp-default 2>/dev/null

# Artefatos das Tarefas 3-6
rm -f nginx-scan.json nginx-sbom.cdx.json nginx-sbom.spdx.json nginx-trivy-sbom.cdx.json
rm -f cosign.key cosign.pub
rm -f insecure-pod.yaml secure-pod.yaml

# Recursos da Tarefa 7
kubectl delete pod falco-test 2>/dev/null
helm uninstall falco -n falco 2>/dev/null
kubectl delete namespace falco 2>/dev/null

# Recursos das Tarefas 8-9
kubectl delete pod immutable-app distroless-test distroless-demo 2>/dev/null
kubectl delete pod audit-exec 2>/dev/null
kubectl delete secret audit-test-secret 2>/dev/null
kind delete cluster --name audit-lab 2>/dev/null
rm -rf audit-logs
```

## Critérios de Sucesso

- [ ] **Tarefa 1:** Você criou e carregou um profile AppArmor, aplicou-o a um Pod via `securityContext`, e verificou que escritas em `/etc` são negadas.
- [ ] **Tarefa 2:** Você criou um profile seccomp customizado que bloqueia `unshare`/`mount`/`ptrace`, aplicou-o a um Pod, e verificou que as syscalls são bloqueadas.
- [ ] **Tarefa 3:** Você escaneou imagens de container com Trivy, filtrou por severidade, e pode explicar a diferença nas contagens de CVEs entre imagens completas, Alpine e distroless.
- [ ] **Tarefa 4:** Você gerou SBOMs nos formatos CycloneDX e SPDX usando tanto syft quanto Trivy, e escaneou um SBOM em busca de vulnerabilidades.
- [ ] **Tarefa 5:** Você gerou um par de chaves cosign, assinou uma imagem de container, verificou a assinatura, e demonstrou que imagens não assinadas falham na verificação.
- [ ] **Tarefa 6:** Você escaneou manifestos com kubesec e kube-linter, comparou pontuações entre manifestos inseguros e hardened.
- [ ] **Tarefa 7:** Você instalou o Falco, disparou uma detecção de shell spawn executando exec em um container, e encontrou o alerta nos logs do Falco.
- [ ] **Tarefa 8:** Você implantou um Pod com `readOnlyRootFilesystem`, verificou que escritas falham no filesystem root mas têm sucesso em mounts `emptyDir`.
- [ ] **Tarefa 9:** Você configurou audit logging do Kubernetes, gerou eventos de auditoria, e analisou o log para encontrar acesso a secrets e eventos de Pod exec.

## Referência Rápida Linux ↔ Kubernetes

| Conceito Linux | Equivalente Kubernetes | Notas |
|---|---|---|
| `apparmor_parser -r /etc/apparmor.d/profile` | `securityContext.appArmorProfile.type: Localhost` | Carregue o profile no node, referencie na spec do Pod |
| `seccomp-bpf` filter program | `securityContext.seccompProfile.type: Localhost` | Profile JSON em `/var/lib/kubelet/seccomp/profiles/` |
| `RuntimeDefault` seccomp = CRI default | `seccompProfile.type: RuntimeDefault` | Baseline recomendada para todos os Pods |
| `dpkg --list` / `rpm -qa` | `syft <image>` ou `trivy image --format cyclonedx` | Gera SBOM do conteúdo do container |
| `gpg --sign` / `gpg --verify` | `cosign sign --key` / `cosign verify --key` | Assinatura criptográfica de imagens |
| `apt-get audit` / Nessus | `trivy image --severity HIGH,CRITICAL` | Scanning de CVEs com filtro por severidade |
| `shellcheck myscript.sh` | `kubesec scan pod.yaml` / `kube-linter lint pod.yaml` | Análise estática de segurança de manifestos |
| OSSEC / AIDE (file integrity) | Falco DaemonSet | Monitoramento e alerta de syscalls em tempo real |
| `mount -o ro /` | `readOnlyRootFilesystem: true` + `emptyDir` para temp | Previne modificações de arquivos em containers |
| `/var/log/audit/audit.log` | `--audit-log-path=/var/log/kubernetes/audit.log` | Audit logging do API server |
| `ausearch -m execve -i` | Parse audit log JSON para subresource `pods/exec` | Encontra quem executou exec em containers |

## Dicas

<details>
<summary>Dica 1: Profile AppArmor não carrega</summary>

Certifique-se de que o profile está carregado no **node onde o Pod será agendado**, não apenas no control plane. Em um cluster kubeadm, conecte via SSH no worker node:

```bash
sudo apparmor_parser -r /etc/apparmor.d/k8s-deny-etc-write
sudo aa-status | grep k8s-deny-etc-write
```

Se o Pod estiver preso no status `Blocked`, o nome do profile na spec do Pod deve corresponder **exatamente** ao nome do profile no arquivo (a linha `profile <name>`).

Para Kubernetes < 1.30, use a annotation:
```yaml
container.apparmor.security.beta.kubernetes.io/<container-name>: localhost/<profile-name>
```

</details>

<details>
<summary>Dica 2: Confusão com caminho do profile Seccomp</summary>

O caminho `localhostProfile` na spec do Pod é **relativo** ao diretório raiz de profiles seccomp do kubelet: `/var/lib/kubelet/seccomp/`.

Então se seu arquivo está em `/var/lib/kubelet/seccomp/profiles/block-dangerous.json`, a spec do Pod deve ter:
```yaml
seccompProfile:
  type: Localhost
  localhostProfile: profiles/block-dangerous.json
```

No Kind, copie o arquivo para o container node:
```bash
docker cp block-dangerous.json fasthack-control-plane:/var/lib/kubelet/seccomp/profiles/
```

</details>

<details>
<summary>Dica 3: Trivy não encontra vulnerabilidades</summary>

O Trivy baixa seu banco de dados de vulnerabilidades na primeira execução. Se você estiver offline ou atrás de um proxy, baixe o DB previamente:

```bash
trivy image --download-db-only
```

Use uma **imagem mais antiga** como `nginx:1.21` para ver mais CVEs. Imagens mais novas têm menos vulnerabilidades conhecidas. Use `--severity HIGH,CRITICAL` para focar em problemas impactantes.

</details>

<details>
<summary>Dica 4: Falha no cosign sign com erros de registry</summary>

Para um registry local sem TLS, você deve usar `--allow-insecure-registry`:

```bash
cosign sign --key cosign.key localhost:5000/busybox:signed --allow-insecure-registry
```

Certifique-se de que o registry está rodando:
```bash
docker ps | grep registry
```

Se não estiver, inicie-o:
```bash
docker run -d -p 5000:5000 --name registry registry:2
```

</details>

<details>
<summary>Dica 5: Falco não detecta shell spawns</summary>

Verifique que os Pods do Falco estão `Running` e que o driver carregou com sucesso:

```bash
kubectl get pods -n falco
kubectl logs -n falco -l app.kubernetes.io/name=falco | head -20
```

Se o driver eBPF falhar ao carregar, tente o driver de kernel module:
```bash
helm upgrade falco falcosecurity/falco -n falco --set driver.kind=kmod
```

As regras do Falco para detecção de shell estão no ruleset padrão. Verifique com:
```bash
kubectl logs -n falco -l app.kubernetes.io/name=falco | grep -i "shell\|exec"
```

</details>

<details>
<summary>Dica 6: Cluster Kind com audit log não inicia</summary>

O arquivo de política de auditoria deve existir no host **antes** de criar o cluster Kind quando usando `extraMounts`. Crie o arquivo primeiro:

```bash
# Salve audit-policy.yaml localmente
mkdir -p audit-logs
kind create cluster --name audit-lab --config kind-audit.yaml
```

Verifique que o API server tem as flags de auditoria:
```bash
docker exec audit-lab-control-plane cat /etc/kubernetes/manifests/kube-apiserver.yaml | grep audit
```

Verifique se os audit logs estão sendo escritos:
```bash
docker exec audit-lab-control-plane ls -la /var/log/kubernetes/
```

</details>

## Recursos de Aprendizado

- [Kubernetes AppArmor documentation](https://kubernetes.io/docs/tutorials/security/apparmor/)
- [Kubernetes Seccomp tutorial](https://kubernetes.io/docs/tutorials/security/seccomp/)
- [Trivy vulnerability scanner](https://aquasecurity.github.io/trivy/)
- [Syft SBOM generator](https://github.com/anchore/syft)
- [Sigstore Cosign documentation](https://docs.sigstore.dev/cosign/signing/overview/)
- [Kubesec — security risk analysis](https://kubesec.io/)
- [KubeLinter — static analysis](https://docs.kubelinter.io/)
- [Falco — runtime security](https://falco.org/docs/)
- [Kubernetes Auditing](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/)
- [CKS Curriculum](https://github.com/cncf/curriculum)
- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)

## Quebra & Conserta 🔧

Tente cada cenário, diagnostique o problema e corrija-o.

### Cenário 1 — Profile Seccomp não está sendo aplicado

Aplique este Pod:

```yaml
# Salve como broken-seccomp.yaml
apiVersion: v1
kind: Pod
metadata:
  name: broken-seccomp
spec:
  securityContext:
    seccompProfile:
      type: Localhost
      localhostProfile: block-dangerous.json
  containers:
    - name: shell
      image: busybox:1.36
      command: ["sleep", "3600"]
      resources:
        requests:
          cpu: 50m
          memory: 32Mi
```

```bash
kubectl apply -f broken-seccomp.yaml
kubectl get pod broken-seccomp
```

**O que você verá:** O Pod fica preso em status `CreateContainerError` ou `Error`.

**Diagnostique:**

```bash
kubectl describe pod broken-seccomp | grep -A5 Events
```

**Causa raiz:** O caminho `localhostProfile` está errado. O profile foi colocado em `/var/lib/kubelet/seccomp/profiles/block-dangerous.json`, mas a spec do Pod referencia `block-dangerous.json` (sem o prefixo `profiles/`).

**Correção:** Atualize o caminho do profile:

```bash
kubectl delete pod broken-seccomp
```

Edite a spec do Pod para usar `localhostProfile: profiles/block-dangerous.json` e re-aplique.

**Analogia com Linux:** É como especificar o caminho errado em um `LD_PRELOAD` — a biblioteca existe mas o loader não consegue encontrá-la no caminho que você forneceu.

---

### Cenário 2 — Container imutável crashando na inicialização

Aplique este Pod:

```yaml
# Salve como broken-immutable.yaml
apiVersion: v1
kind: Pod
metadata:
  name: broken-immutable
spec:
  containers:
    - name: nginx
      image: nginx:1.27
      securityContext:
        readOnlyRootFilesystem: true
      ports:
        - containerPort: 80
      resources:
        requests:
          cpu: 50m
          memory: 32Mi
```

```bash
kubectl apply -f broken-immutable.yaml
kubectl get pod broken-immutable --watch
```

**O que você verá:** O Pod entra em `CrashLoopBackOff`. O Nginx não consegue iniciar.

**Diagnostique:**

```bash
kubectl logs broken-immutable
```

Você verá erros como: `nginx: [emerg] mkdir() "/var/cache/nginx/client_temp" failed (30: Read-only file system)`.

**Causa raiz:** O Nginx precisa escrever em `/var/cache/nginx`, `/var/run` e `/tmp` na inicialização. Com `readOnlyRootFilesystem: true`, esses caminhos são somente leitura.

**Correção:** Adicione volumes `emptyDir` para os caminhos graváveis:

```bash
kubectl delete pod broken-immutable
```

Adicione `volumeMounts` para `/tmp`, `/var/cache/nginx` e `/var/run` com volumes `emptyDir` (veja a Tarefa 8 para o manifesto correto).

**Analogia com Linux:** É como montar um filesystem somente leitura (`mount -o ro /`) e depois se perguntar por que o `nginx` não consegue criar seu arquivo PID em `/var/run/`.

---

### Cenário 3 — Falco não detecta nada

O Falco está instalado e rodando mas nenhum alerta aparece mesmo após exec em containers.

```bash
kubectl exec -it falco-test -- /bin/sh -c "whoami"
kubectl logs -n falco -l app.kubernetes.io/name=falco --tail=10
```

**O que você verá:** Nenhum alerta relacionado a shell nos logs.

**Diagnostique:**

```bash
# Verifique se o driver do Falco carregou
kubectl logs -n falco -l app.kubernetes.io/name=falco | grep -i "driver\|error\|fail"

# Verifique se as regras estão carregadas
kubectl logs -n falco -l app.kubernetes.io/name=falco | grep -i "rule"
```

**Causa raiz (possível):** O driver eBPF falhou ao carregar devido a headers de kernel ausentes ou uma versão de kernel não suportada. O Falco inicia mas não consegue interceptar syscalls.

**Correção:** Mude para o driver de kernel module ou garanta que os headers do kernel estão instalados:

```bash
# Mude o driver
helm upgrade falco falcosecurity/falco -n falco --set driver.kind=kmod

# Ou no node:
sudo apt-get install -y linux-headers-$(uname -r)
```

Após corrigir, reinicie o Falco e tente novamente o teste de exec.

**Analogia com Linux:** É como instalar o OSSEC mas esquecer de carregar o módulo de auditoria do kernel — a ferramenta roda mas não consegue ver nenhum evento.

---

## 🎉 Parabéns — Você Completou o FastHack Kubernetes Hackathon!

Você passou por todos os **20 desafios** — do seu primeiro Pod até supply chain security. Aqui está o que você realizou:

### Sua Jornada — Todos os 20 Desafios

| # | Desafio | Habilidades Principais |
|---|---|---|
| 01 | Core Concepts | Pods, kubectl, arquitetura do cluster |
| 02 | Namespaces & Labels | Organização, label selectors, isolamento de recursos |
| 03 | Deployments & ReplicaSets | Workloads declarativos, scaling, auto-recuperação |
| 04 | Rollouts & Rollbacks | Estratégias de atualização, histórico de revisões, undo |
| 05 | Services & Networking | ClusterIP, NodePort, LoadBalancer, DNS |
| 06 | ConfigMaps & Secrets | Injeção de configuração, variáveis de ambiente, volumes |
| 07 | Storage & Persistence | PVs, PVCs, StorageClasses, provisionamento dinâmico |
| 08 | Scheduling & Node Affinity | nodeSelector, affinity, taints, tolerations |
| 09 | Pod Security | SecurityContext, Pod Security Standards, básico de RBAC |
| 10 | Ingress & Traffic Management | Ingress controllers, roteamento por path/host, TLS |
| 11 | StatefulSets & Headless Services | Deployment ordenado, IDs de rede estáveis, storage persistente |
| 12 | DaemonSets, Jobs & CronJobs | Workloads em nível de node, processamento em lote, tarefas agendadas |
| 13 | Resource Management | Requests, limits, LimitRanges, ResourceQuotas |
| 14 | Health Checks & Observability | Liveness, readiness, startup probes, monitoramento |
| 15 | RBAC Deep Dive | Roles, ClusterRoles, ServiceAccounts, menor privilégio |
| 16 | Troubleshooting & Debugging | Diagnósticos de Pod/node/rede, análise de logs |
| 17 | Advanced Deployment Strategies | Blue/green, canary, ajuste de rolling update, depreciação de API |
| 18 | Cluster Setup com kubeadm | Bootstrap de clusters de produção, etcd, certificados |
| 19 | Network Policies & Service Mesh | Segmentação de rede L3/L4, zero-trust networking |
| 20 | Supply Chain & Runtime Security | AppArmor, seccomp, Trivy, Falco, cosign, audit logs |

### Avaliação de Prontidão para Certificação

**CKA (Certified Kubernetes Administrator) — Domínios Cobertos:**

| Domínio CKA | Peso | Desafios |
|---|---|---|
| Cluster Architecture, Installation & Configuration | 25% | Ch01, Ch18 |
| Workloads & Scheduling | 15% | Ch03, Ch04, Ch08, Ch12 |
| Services & Networking | 20% | Ch05, Ch10, Ch19 |
| Storage | 10% | Ch07, Ch11 |
| Troubleshooting | 30% | Ch14, Ch16 |

**CKAD (Certified Kubernetes Application Developer) — Domínios Cobertos:**

| Domínio CKAD | Peso | Desafios |
|---|---|---|
| Application Design and Build | 20% | Ch03, Ch04, Ch11, Ch12 |
| Application Deployment | 20% | Ch04, Ch17 |
| Application Observability and Maintenance | 15% | Ch14, Ch16 |
| Application Environment, Configuration and Security | 25% | Ch02, Ch06, Ch08, Ch09, Ch13 |
| Services & Networking | 20% | Ch05, Ch10 |

**CKS (Certified Kubernetes Security Specialist) — Domínios Cobertos:**

| Domínio CKS | Peso | Desafios |
|---|---|---|
| Cluster Setup | 10% | Ch18, Ch19 |
| Cluster Hardening | 15% | Ch09, Ch15 |
| System Hardening | 15% | Ch20 (Tasks 1-2) |
| Minimize Microservice Vulnerabilities | 20% | Ch09, Ch20 (Tasks 6, 8) |
| Supply Chain Security | 20% | Ch20 (Tasks 3-6) |
| Monitoring, Logging & Runtime Security | 20% | Ch14, Ch20 (Tasks 7, 9) |

### Próximos Passos Recomendados

1. **Exames Práticos:**
   - [Killer.sh](https://killer.sh/) — O simulador de exame usado pela Linux Foundation (incluído na compra do exame)
   - [KillerCoda CKA/CKAD/CKS Scenarios](https://killercoda.com/) — Labs gratuitos no navegador

2. **Treinamento Oficial:**
   - [Linux Foundation — CKA Course (LFS258)](https://training.linuxfoundation.org/training/kubernetes-fundamentals/)
   - [Linux Foundation — CKAD Course (LFD259)](https://training.linuxfoundation.org/training/kubernetes-for-developers/)
   - [Linux Foundation — CKS Course (LFS260)](https://training.linuxfoundation.org/training/kubernetes-security-essentials-lfs260/)

3. **Registre-se para os Exames:**
   - [CKA Exam](https://training.linuxfoundation.org/certification/certified-kubernetes-administrator-cka/)
   - [CKAD Exam](https://training.linuxfoundation.org/certification/certified-kubernetes-application-developer-ckad/)
   - [CKS Exam](https://training.linuxfoundation.org/certification/certified-kubernetes-security-specialist/)

4. **Continue Aprendendo:**
   - Visite **[k8shackathon.com](https://k8shackathon.com)** para atualizações, desafios adicionais e recursos da comunidade
   - Participe do [Kubernetes Slack](https://slack.k8s.io/) — canais: `#cka-prep`, `#ckad-prep`, `#cks-prep`
   - Leia a [Documentação do Kubernetes](https://kubernetes.io/docs/home/) — a documentação oficial é permitida durante o exame

> **Lembre-se:** Os exames são baseados em desempenho. Você terá um terminal com acesso ao `kubectl` e deve resolver tarefas reais sob pressão de tempo. As habilidades práticas que você construiu nestes 20 desafios são exatamente o que você precisa. Pratique velocidade, aprenda atalhos do `kubectl` e salve páginas-chave da documentação nos favoritos.
>
> **Você está pronto. Vá buscar sua certificação! 🚀**
