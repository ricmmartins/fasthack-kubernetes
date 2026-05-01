# Desafio 03 — Criando um Cluster Local

[< Desafio Anterior](Challenge-02.md) | **[Início](../README.md)** | [Próximo Desafio >](Challenge-04.md)

## Introdução

Configurar seu próprio cluster Kubernetes é como construir um data center Linux completo — mas em vez de montar servidores físicos, você inicia containers que *agem* como servidores.

**Kind** (Kubernetes IN Docker) executa nodes Kubernetes completos como containers Docker na sua máquina local. Pense assim:

| Instalar um serviço Linux | Criar um cluster Kubernetes |
|---|---|
| `apt install nginx` | `kind create cluster` |
| `systemctl start nginx` | O cluster inicializa automaticamente |
| Um servidor, um serviço | Múltiplos "servidores" (nodes) em containers |

Um cluster Kubernetes tem dois planos:

- **Control Plane** (o cérebro): É como a camada de gerenciamento do seu data center. Ele inclui:
  - **API Server** — a porta de entrada (como `sshd` para o seu cluster, toda requisição passa por ele)
  - **etcd** — o banco de dados (como `/etc` para o cluster inteiro — armazena todo o estado)
  - **Scheduler** — decide qual node executa um workload (como um load balancer escolhendo um backend)
  - **Controller Manager** — garante que o estado desejado corresponda ao estado real (como `systemd` reiniciando serviços que caíram)

- **Data Plane** (os trabalhadores): São os cavalos de batalha, os servidores que realmente executam suas aplicações. Cada worker node executa:
  - **kubelet** — o agente do node (como `systemd` em cada servidor, gerenciando workloads locais)
  - **kube-proxy** — regras de rede (como `iptables` gerenciando roteamento de tráfego)
  - **Container Runtime** — realmente executa containers (como `containerd` ou `dockerd`)

Neste desafio, você vai construir seu próprio cluster do zero, explorar seus internos e entender como todas essas peças se encaixam.

## Descrição

Sua missão é:

1. **Instalar Kind e criar um cluster de node único** — Inicie seu primeiro cluster Kubernetes e verifique se está rodando. Isso é equivalente a provisionar um novo servidor Linux e confirmar que você pode acessá-lo via SSH.

2. **Explorar kubeconfig (`~/.kube/config`) e entender contexts** — Assim como `/etc/hosts` mapeia hostnames para IPs, kubeconfig mapeia nomes de clusters para endpoints do API server e credenciais. Entenda como `kubectl` sabe *com qual* cluster se comunicar.

3. **Listar todos os Pods no namespace `kube-system` e identificar componentes do control plane** — Isso é como executar `systemctl list-units` em um servidor Linux para ver quais serviços do sistema estão rodando. O namespace `kube-system` contém os componentes que fazem o próprio Kubernetes funcionar.

4. **Criar um cluster multi-node usando um arquivo de configuração Kind** — Escale de um único servidor para um data center. Defina um cluster com um node control plane e dois worker nodes usando um arquivo de configuração YAML — como escrever um manifesto de infraestrutura como código para sua frota de servidores.

> 💡 **Alternativa Minikube**: Se preferir, você pode usar [Minikube](https://minikube.sigs.k8s.io/) em vez de Kind. Os conceitos são idênticos — apenas os comandos CLI diferem. Minikube cria um cluster baseado em VM ou container com `minikube start` em vez de `kind create cluster`.

## Critérios de Sucesso

- [ ] `kind create cluster` completa com sucesso e `kubectl cluster-info` mostra um cluster em execução
- [ ] `kubectl get nodes` mostra pelo menos um node com status `Ready`
- [ ] Você consegue listar pods no namespace `kube-system` e identificar o API server, etcd, scheduler e controller manager
- [ ] Você consegue explicar a estrutura de `~/.kube/config` (clusters, users, contexts) e alternar entre contexts
- [ ] Você criou um cluster multi-node (1 control plane + 2 workers) usando um arquivo de configuração Kind e todos os nodes mostram `Ready`

## Referência Linux ↔ Cluster Kubernetes

| Conceito Linux | Equivalente Kubernetes |
|---|---|
| `/etc/hosts` (resolução de host) | `~/.kube/config` (configuração de conexão do cluster) |
| `ssh user@server` (acesso remoto) | `kubectl` com um context (acesso ao cluster) |
| Serviços `systemd` (`systemctl list-units`) | Pods `kube-system` (componentes do control plane) |
| `/var/log/syslog` (logs do sistema) | `kubectl logs -n kube-system <pod>` |
| Interfaces de rede (`ip addr`) | Plugins CNI (Container Network Interface) |
| Processo de boot (BIOS → GRUB → init) | Bootstrap do cluster (Docker → Kind → kubelet → control plane) |

## Dicas

<details>
<summary>Dica 1: Instalar Kind e criar seu primeiro cluster</summary>

```bash
# Install Kind — pick one method:

# Option A: Download the binary (Linux amd64)
# Check https://kind.sigs.k8s.io/docs/user/quick-start/#installation for latest version
[ $(uname -m) = x86_64 ] && curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.31.0/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind

# Option B: Install with Go
go install sigs.k8s.io/kind@v0.31.0

# Option C: Package managers
# macOS: brew install kind
# Windows: choco install kind

# Verify installation
kind version

# Create your first cluster
kind create cluster --name k8s-lab

# Verify it's running
kubectl cluster-info
kubectl get nodes
```

Após a criação, Kind automaticamente configura `kubectl` para apontar ao seu novo cluster. É como um instalador Linux que não só instala o servidor, mas também configura suas chaves SSH.

</details>

<details>
<summary>Dica 2: Explorar kubeconfig</summary>

O arquivo kubeconfig é seu "catálogo de endereços" dos clusters. Ele contém três seções principais:

- **clusters** — onde seus clusters estão (endereços do API server + certificados CA)
- **users** — credenciais para autenticar (como chaves SSH)
- **contexts** — vínculos de cluster + user + namespace (como entradas do SSH config)

```bash
# View the full kubeconfig (redacted secrets)
kubectl config view

# List all available contexts
kubectl config get-contexts

# Switch to a specific context
kubectl config use-context kind-k8s-lab

# See the raw file (contains actual certificates and keys)
cat ~/.kube/config
```

**Analogia Linux**: Isso é como seu arquivo `~/.ssh/config` — ele mapeia nomes amigáveis para detalhes de conexão para que você não precise digitar endereços completos toda vez.

</details>

<details>
<summary>Dica 3: Explorar o namespace kube-system</summary>

O namespace `kube-system` é onde o Kubernetes executa sua própria infraestrutura — como o diretório `/usr/lib/systemd/system/` onde o Linux mantém seus arquivos de unit de serviços principais.

```bash
# List all control plane pods
kubectl get pods -n kube-system

# See which node each pod runs on
kubectl get pods -n kube-system -o wide

# Inspect the API server pod in detail
kubectl describe pod -n kube-system -l component=kube-apiserver

# Check logs from etcd (the cluster database)
kubectl logs -n kube-system -l component=etcd

# List ALL resources in kube-system
kubectl get all -n kube-system
```

Você deve ver pods para: `etcd`, `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`, `coredns` e `kindnet` (plugin CNI do Kind).

</details>

<details>
<summary>Dica 4: Criar um cluster multi-node com arquivo de configuração</summary>

Crie um arquivo chamado `kind-config.yaml`:

```yaml
# kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
```

Depois crie o cluster:

```bash
# Delete the old single-node cluster first
kind delete cluster --name k8s-lab

# Create the multi-node cluster from the config file
kind create cluster --name k8s-lab --config kind-config.yaml

# Verify all three nodes are Ready
kubectl get nodes

# You should see output like:
# NAME                    STATUS   ROLES           AGE   VERSION
# k8s-lab-control-plane   Ready    control-plane   1m    v1.33.0
# k8s-lab-worker          Ready    <none>          1m    v1.33.0
# k8s-lab-worker2         Ready    <none>          1m    v1.33.0
```

**Analogia Linux**: Isso é como escrever um playbook Ansible ou uma configuração Terraform para provisionar múltiplos servidores de uma vez — infraestrutura como código em vez de setup manual.

</details>

## Recursos de Aprendizado

- [Kind — Guia Quick Start](https://kind.sigs.k8s.io/docs/user/quick-start/)
- [Kind — Configuração](https://kind.sigs.k8s.io/docs/user/configuration/)
- [Visão Geral dos Componentes Kubernetes](https://kubernetes.io/docs/concepts/overview/components/)
- [Organizando Acesso ao Cluster com kubeconfig](https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/)
- [Minikube — Primeiros Passos (alternativa ao Kind)](https://minikube.sigs.k8s.io/docs/start/)

## Break & Fix 🔧

Após completar o desafio, tente estes cenários para aprofundar seu entendimento:

1. **Quebrar o kubeconfig**: Delete (ou renomeie) seu arquivo `~/.kube/config` e tente executar `kubectl get nodes`. Que erro você recebe? Como recuperar? *(Dica: `kind export kubeconfig --name k8s-lab` regenera — como resetar suas chaves SSH.)*

2. **Matar o runtime**: Crie um cluster, depois pare o Docker (`sudo systemctl stop docker` no Linux, ou saia do Docker Desktop). Tente `kubectl get nodes`. O que acontece? Como fica o cluster quando você reinicia o Docker? *(Isso simula uma queda de energia no seu data center.)*

3. **Colisão de nome**: Tente criar um cluster com `kind create cluster --name k8s-lab` quando já existe um com esse nome. Que erro você recebe? Como resolver? *(Como tentar criar uma VM com um hostname que já está em uso.)*
