# Solução 03 — Criando um Cluster Local

[< Voltar para o Desafio](../Student/Challenge-03.md) | **[Home](README.md)**

## Pré-verificação

Certifique-se de que o Docker esteja em execução (Kind usa Docker para criar nós como containers):

```bash
docker info --format '{{.ServerVersion}}'
```

Saída esperada:

```
27.x.x
```

Se isto falhar, o daemon do Docker não está em execução.

---

## Tarefa 1: Instale o Kind e Crie um Cluster de Nó Único

### Passo a passo

**Instale o Kind** (escolha o método adequado ao ambiente do aluno):

```bash
# Linux (amd64)
[ $(uname -m) = x86_64 ] && curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.31.0/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind

# macOS
brew install kind

# Windows (com chocolatey)
choco install kind
```

Verifique a instalação:

```bash
kind version
```

Saída esperada:

```
kind v0.31.0 go1.23.x ...
```

**Crie um cluster de nó único:**

```bash
kind create cluster --name k8s-lab
```

Saída esperada:

```
Creating cluster "k8s-lab" ...
 ✓ Ensuring node image (kindest/node:v1.33.0) ��
 ✓ Preparing nodes 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
Set kubectl context to "kind-k8s-lab"
You can now use your cluster with:

kubectl cluster-info --context kind-k8s-lab

Have a nice day! 👋
```

> **Nota para o Coach:** A versão do Kubernetes na imagem do nó depende da versão do Kind. O Kind v0.31.0 vem com Kubernetes v1.33.0 por padrão.

**Verifique se o cluster está em execução:**

```bash
kubectl cluster-info
```

Saída esperada:

```
Kubernetes control plane is running at https://127.0.0.1:XXXXX
CoreDNS is running at https://127.0.0.1:XXXXX/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy
```

**Verifique se o nó está Ready:**

```bash
kubectl get nodes
```

Saída esperada:

```
NAME                    STATUS   ROLES           AGE   VERSION
k8s-lab-control-plane   Ready    control-plane   1m    v1.33.0
```

### Verificação

- `kind version` mostra uma versão válida
- `kubectl cluster-info` mostra a URL do control plane
- `kubectl get nodes` mostra um nó com status `Ready`

---

## Tarefa 2: Explore o kubeconfig

### Passo a passo

**Visualize o kubeconfig (credenciais omitidas):**

```bash
kubectl config view
```

Saída esperada:

```yaml
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: DATA+OMITTED
    server: https://127.0.0.1:XXXXX
  name: kind-k8s-lab
contexts:
- context:
    cluster: kind-k8s-lab
    user: kind-k8s-lab
  name: kind-k8s-lab
current-context: kind-k8s-lab
kind: Config
preferences: {}
users:
- name: kind-k8s-lab
  user:
    client-certificate-data: DATA+OMITTED
    client-key-data: DATA+OMITTED
```

> **Nota para o Coach:** Conduza os alunos pelas três seções:
> - **clusters** — onde o API server está (endereço + certificado CA)
> - **users** — credenciais (certificados de cliente neste caso)
> - **contexts** — vincula um cluster + usuário + namespace opcional em um atalho nomeado
>
> Analogia: É como o `~/.ssh/config` — mapeia nomes amigáveis para detalhes de conexão.

**Liste todos os contextos disponíveis:**

```bash
kubectl config get-contexts
```

Saída esperada:

```
CURRENT   NAME           CLUSTER        AUTHINFO       NAMESPACE
*         kind-k8s-lab   kind-k8s-lab   kind-k8s-lab
```

O `*` marca o contexto atualmente ativo.

**Mostre o contexto atual:**

```bash
kubectl config current-context
```

Saída esperada:

```
kind-k8s-lab
```

**Mude de contexto (útil ao gerenciar múltiplos clusters):**

```bash
kubectl config use-context kind-k8s-lab
```

Saída esperada:

```
Switched to context "kind-k8s-lab".
```

**Visualize a localização do arquivo kubeconfig:**

```bash
# Linux / macOS
cat ~/.kube/config | head -20

# Windows (PowerShell)
Get-Content $env:USERPROFILE\.kube\config | Select-Object -First 20
```

### Verificação

- Os alunos conseguem explicar: clusters = onde, users = quem, contexts = qual combinação usar
- `kubectl config get-contexts` lista o contexto do cluster Kind
- Os alunos entendem que mudar de contexto altera com qual cluster o `kubectl` se comunica

---

## Tarefa 3: Liste os Pods do kube-system e Identifique os Componentes do Control Plane

### Passo a passo

**Liste todos os Pods no namespace `kube-system`:**

```bash
kubectl get pods -n kube-system
```

Saída esperada:

```
NAME                                            READY   STATUS    RESTARTS   AGE
coredns-xxxxxxxxxx-xxxxx                        1/1     Running   0          5m
coredns-xxxxxxxxxx-xxxxx                        1/1     Running   0          5m
etcd-k8s-lab-control-plane                      1/1     Running   0          5m
kindnet-xxxxx                                   1/1     Running   0          5m
kube-apiserver-k8s-lab-control-plane            1/1     Running   0          5m
kube-controller-manager-k8s-lab-control-plane   1/1     Running   0          5m
kube-proxy-xxxxx                                1/1     Running   0          5m
kube-scheduler-k8s-lab-control-plane            1/1     Running   0          5m
```

> **Nota para o Coach:** Peça aos alunos para identificar cada componente:
>
> | Pod | Função | Analogia Linux |
> |---|---|---|
> | `kube-apiserver` | Porta de entrada — todas as requisições passam por ele | `sshd` — ponto de entrada único |
> | `etcd` | Banco de dados do cluster — armazena todo o estado | `/etc` + `/var/lib` — configuração persistente |
> | `kube-scheduler` | Atribui Pods aos nós | Balanceador de carga escolhendo um backend |
> | `kube-controller-manager` | Garante que estado desejado = estado atual | `systemd` reiniciando serviços com falha |
> | `coredns` | Resolução DNS do cluster | `systemd-resolved` / BIND |
> | `kindnet` | Plugin CNI — rede Pod-para-Pod | Bridge de rede / switch virtual |
> | `kube-proxy` | Regras de roteamento de Service | `iptables` / `nftables` |

**Veja em qual nó cada Pod está executando:**

```bash
kubectl get pods -n kube-system -o wide
```

**Inspecione o Pod do API server:**

```bash
kubectl describe pod -n kube-system -l component=kube-apiserver
```

Os alunos devem olhar a seção `Containers` para ver as flags de linha de comando com que o API server foi iniciado.

**Verifique os logs do etcd:**

```bash
kubectl logs -n kube-system -l component=etcd --tail=10
```

### Verificação

- Os alunos conseguem listar todos os Pods do kube-system
- Os alunos conseguem nomear os quatro componentes principais do control plane (apiserver, etcd, scheduler, controller-manager)
- Os alunos conseguem explicar a função de cada componente usando uma analogia Linux

---

## Tarefa 4: Crie um Cluster Multi-Nó

### Passo a passo

**Crie o arquivo de configuração do Kind** `kind-config.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

**Delete o cluster antigo de nó único:**

```bash
kind delete cluster --name k8s-lab
```

Saída esperada:

```
Deleting cluster "k8s-lab" ...
Deleted nodes: ["k8s-lab-control-plane"]
```

**Crie o cluster multi-nó:**

```bash
kind create cluster --name k8s-lab --config kind-config.yaml
```

Saída esperada:

```
Creating cluster "k8s-lab" ...
 ✓ Ensuring node image (kindest/node:v1.33.0) 🖼
 ✓ Preparing nodes 📦 📦 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
 ✓ Joining worker nodes 🚜
Set kubectl context to "kind-k8s-lab"
...
```

> **Nota para o Coach:** Observe `📦 📦 📦` — três nós sendo preparados (1 control plane + 2 workers).

**Verifique se os três nós estão Ready:**

```bash
kubectl get nodes
```

Saída esperada:

```
NAME                    STATUS   ROLES           AGE   VERSION
k8s-lab-control-plane   Ready    control-plane   1m    v1.33.0
k8s-lab-worker          Ready    <none>          1m    v1.33.0
k8s-lab-worker2         Ready    <none>          1m    v1.33.0
```

**Mostre os containers Docker que representam os nós:**

```bash
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
```

Saída esperada:

```
NAMES                    IMAGE                  STATUS
k8s-lab-control-plane    kindest/node:v1.33.0   Up 2 minutes
k8s-lab-worker           kindest/node:v1.33.0   Up 2 minutes
k8s-lab-worker2          kindest/node:v1.33.0   Up 2 minutes
```

> **Nota para o Coach:** Este é o momento "aha" — cada "nó" Kubernetes é na verdade um container Docker. O Kind executa o Kubernetes dentro do Docker.

**Verifique se os Pods do kube-system estão distribuídos entre os nós:**

```bash
kubectl get pods -n kube-system -o wide
```

Os alunos devem ver que os Pods `kindnet` e `kube-proxy` executam em todos os nós (são DaemonSets), enquanto os componentes do control plane executam apenas no nó control-plane.

### Verificação

- `kubectl get nodes` mostra 3 nós, todos `Ready`
- Um nó tem `Roles: control-plane`, dois têm `<none>` (workers)
- `docker ps` mostra 3 containers Kind em execução

---

## Problemas Comuns

| Problema | Sintoma | Correção |
|---|---|---|
| Versão do Kind muito antiga | `kind create cluster` falha ou cria uma versão antiga do Kubernetes | Atualize o Kind: baixe novamente o binário de https://kind.sigs.k8s.io/docs/user/quick-start/#installation |
| Docker não está em execução | `Cannot connect to the Docker daemon` | Inicie o Docker: `sudo systemctl start docker` ou inicie o Docker Desktop |
| Colisão de nomes | `ERROR: failed to create cluster: node(s) already exist for a cluster with the name "k8s-lab"` | Delete o cluster antigo primeiro: `kind delete cluster --name k8s-lab` |
| Recursos insuficientes | Nós ficam em `NotReady` ou containers sofrem OOMKill | Clusters multi-nó do Kind precisam de ~4 GB de RAM e ~2 CPUs disponíveis para o Docker. Aumente os limites de recursos do Docker Desktop |
| Contexto kubectl não definido | `kubectl` se comunica com o cluster errado após criar um novo | Mude o contexto: `kubectl config use-context kind-k8s-lab` |
| Nós worker mostram `<none>` para ROLES | Alunos se preocupam que é um erro | Isso é **normal** — nós worker não têm label de role especial. Apenas o nó control-plane é rotulado |
| kubeconfig não encontrado após deletar cluster | `~/.kube/config` referencia um cluster deletado | O Kind atualiza o kubeconfig ao criar/deletar. Se corrompido, re-exporte: `kind export kubeconfig --name k8s-lab` |
| Alunos confusos sobre nós Kind vs containers Docker | Eles pensam que cada nó Kind é uma VM separada | Explique: "nós" Kind são containers Docker executando `kubelet` + a pilha Kubernetes. São containers até o final |
