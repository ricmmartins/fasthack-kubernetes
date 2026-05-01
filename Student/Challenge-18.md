# Desafio 18 — Administração de Cluster com kubeadm

[< Desafio Anterior](Challenge-17.md) - **[Início](../README.md)** - [Próximo Desafio >](Challenge-19.md)

## Introdução

Em um servidor Linux, construir um serviço de alta disponibilidade do zero significa inicializar software de cluster: você executa `pacemaker` ou `corosync` para inicializar o primeiro nó, depois `pcs cluster node add` para adicionar membros adicionais. Você faz backups periódicos com `pg_dump` ou snapshots LVM, e quando é hora de atualizar, você drena conexões com `systemctl isolate maintenance.target`, executa `apt upgrade`, e depois traz o nó de volta online. Você estende as capacidades do sistema escrevendo tipos customizados de unit `systemd` e carregando módulos de kernel (`modprobe`) para novos drivers de hardware ou rede.

O Kubernetes tem equivalentes diretos para cada uma dessas operações. `kubeadm init` inicializa o control plane (como a configuração inicial do Pacemaker), `kubeadm join` adiciona workers (como adicionar membros ao cluster), `etcdctl snapshot save` cria backups do banco de dados (como `pg_dump`), e o ciclo de upgrade de drain → upgrade → uncordon espelha uma janela de manutenção. Custom Resource Definitions (CRDs) estendem a API como tipos customizados de unit systemd, enquanto Container Network Interface (CNI), Container Storage Interface (CSI) e Container Runtime Interface (CRI) são arquiteturas de plugins — o equivalente Kubernetes dos módulos carregáveis de kernel do Linux ou módulos PAM.

Neste desafio você vai construir um cluster Kubernetes do zero com `kubeadm`, gerenciar seu ciclo de vida e explorar como ele é estendido.

| Padrão Linux | Padrão Kubernetes |
|---|---|
| `pacemaker` / `corosync` cluster init | `kubeadm init` — inicializar o control plane |
| `pcs cluster node add` | `kubeadm join` — adicionar worker nodes |
| `apt upgrade` com janelas de manutenção | `kubeadm upgrade` — drain, upgrade, uncordon |
| `pg_dump` / snapshots LVM | `etcdctl snapshot save` — backups do etcd |
| Pacemaker HA com `keepalived` / VIP | Múltiplos nós de control-plane (stacked ou external etcd) |
| Tipos customizados de unit `systemd` | Custom Resource Definitions (CRDs) e Operators |
| `modprobe` / módulos carregáveis de kernel / PAM | CNI, CSI, CRI — interfaces de plugin de extensão |

---

## ⚠️ Ambiente de Lab — VMs Necessárias (Não Kind)

Este desafio requer **máquinas virtuais reais** — não Kind ou Minikube. Você precisa de um cluster multi-nó com processos kubelet reais, serviços systemd e etcd rodando em disco. Escolha uma das opções abaixo:

### Opção A: VMs na Nuvem (Qualquer Provedor)

Provisione **3 VMs Ubuntu 24.04 LTS** (2 vCPU, 2 GB RAM mínimo cada) em qualquer provedor de nuvem (Azure, AWS, GCP, DigitalOcean, etc.). Garanta que:
- Todas as VMs podem se comunicar por uma rede privada
- As portas 6443 (API server), 2379-2380 (etcd), 10250 (kubelet) estão abertas entre os nós
- Você tem acesso SSH e privilégios `sudo`

Nomeie-as:
- `control-plane` (1 nó)
- `worker-1`, `worker-2` (2 nós)

### Opção B: Vagrant com VirtualBox

Salve como `Vagrantfile` e execute `vagrant up`:

```ruby
Vagrant.configure("2") do |config|
  config.vm.box = "bento/ubuntu-24.04"

  nodes = [
    { name: "control-plane", ip: "192.168.56.10" },
    { name: "worker-1",      ip: "192.168.56.11" },
    { name: "worker-2",      ip: "192.168.56.12" },
  ]

  nodes.each do |node|
    config.vm.define node[:name] do |n|
      n.vm.hostname = node[:name]
      n.vm.network "private_network", ip: node[:ip]
      n.vm.provider "virtualbox" do |vb|
        vb.memory = 2048
        vb.cpus   = 2
      end
    end
  end
end
```

Depois acesse via SSH cada nó: `vagrant ssh control-plane`, `vagrant ssh worker-1`, etc.

### Opção C: Killercoda Playground (Gratuito, No Navegador)

Use o playground gratuito de Kubernetes em [killercoda.com/playgrounds/scenario/kubernetes](https://killercoda.com/playgrounds/scenario/kubernetes). Ele fornece um cluster pré-construído de 2 nós (1 control-plane + 1 worker). Você pode praticar as Tarefas 4–7 diretamente. Para as Tarefas 1–3 (inicializar do zero), use o [playground Ubuntu](https://killercoda.com/playgrounds/scenario/ubuntu) e instale tudo você mesmo.

> **Nota:** Sessões do Killercoda expiram após ~60 minutos. Salve seu trabalho e esteja preparado para reiniciar se necessário.

---

## Descrição

### Tarefa 1 — Preparar Pré-requisitos das VMs

Antes de executar `kubeadm init`, cada nó deve ser preparado — exatamente como verificações pré-voo antes de configurar o Pacemaker. No Linux você executaria `swapoff -a`, carregaria módulos de kernel e instalaria pacotes. Kubernetes é o mesmo.

**Execute todos os passos abaixo em TODOS os 3 nós** (control-plane, worker-1, worker-2).

**Passo 1:** Desabilite o swap (Kubernetes requer swap desligado, como alguns sistemas de arquivos em cluster exigem):

```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
```

**Passo 2:** Carregue os módulos de kernel necessários (como `modprobe` para drivers de rede):

```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
```

**Passo 3:** Configure os parâmetros sysctl necessários (como habilitar IP forwarding para um roteador Linux):

```bash
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

sudo sysctl --system
```

**Passo 4:** Instale o containerd (a implementação da Container Runtime Interface):

```bash
sudo apt-get update
sudo apt-get install -y containerd
```

**Passo 5:** Configure o containerd para usar o driver de cgroup systemd (obrigatório para Kubernetes):

```bash
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd
```

**Passo 6:** Instale kubeadm, kubelet e kubectl:

```bash
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

**Passo 7:** Habilite e inicie o kubelet:

```bash
sudo systemctl enable --now kubelet
```

> **Por que `apt-mark hold`?** Isso previne que `apt upgrade` atualize acidentalmente componentes do Kubernetes — assim como fixar a versão de um pacote crítico em um servidor Linux de produção.

### Tarefa 2 — Inicializar o Control Plane com `kubeadm init`

Este é o equivalente a executar a configuração do `pacemaker` ou `corosync` pela primeira vez — o momento em que seu cluster ganha vida.

**Execute no nó control-plane apenas.**

**Passo 1:** Inicialize o cluster com o CIDR de rede de Pods que o Calico espera:

```bash
sudo kubeadm init \
  --pod-network-cidr=192.168.0.0/16 \
  --kubernetes-version=v1.36.0
```

> **Importante:** Salve o comando `kubeadm join` da saída — você vai precisar dele na Tarefa 3.

**Passo 2:** Configure seu kubeconfig (como usuário regular):

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

**Passo 3:** Verifique se o control plane está rodando:

```bash
kubectl get nodes
kubectl get pods -n kube-system
```

O nó deve aparecer como `NotReady` (sem plugin CNI ainda) e você deve ver Pods `kube-apiserver`, `kube-controller-manager`, `kube-scheduler` e `etcd` rodando.

### Tarefa 3 — Instalar Calico CNI e Adicionar Worker Nodes

Instalar um plugin CNI é como carregar um módulo de rede do kernel — ele fornece a fundação de rede. Adicionar workers é como `pcs cluster node add` no Pacemaker.

**Passo 1:** Instale o Calico CNI no nó **control-plane**:

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.0/manifests/calico.yaml
```

**Passo 2:** Aguarde todos os Pods do Calico estarem prontos:

```bash
kubectl get pods -n kube-system -l k8s-app=calico-node --watch
```

Uma vez que todos os Pods mostrem `Running`, o nó control-plane deve ficar `Ready`:

```bash
kubectl get nodes
```

**Passo 3:** Adicione os worker nodes. Em **cada worker** (worker-1 e worker-2), execute o comando `kubeadm join` da saída do `kubeadm init`:

```bash
sudo kubeadm join <CONTROL-PLANE-IP>:6443 \
  --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH>
```

> **Se o token expirou** (tokens são válidos por 24 horas), gere um novo no control-plane:
> ```bash
> kubeadm token create --print-join-command
> ```

**Passo 4:** Verifique se todos os nós estão Ready (de volta no control-plane):

```bash
kubectl get nodes -o wide
```

Você deve ver todos os 3 nós no status `Ready` com containerd como runtime.

### Tarefa 4 — Upgrade de Cluster com kubeadm

Atualizar um cluster Kubernetes segue a mesma disciplina de atualizar um cluster Linux HA: drene o nó (tire-o de rotação), atualize os pacotes, verifique, então traga-o de volta online (uncordon).

Vamos simular a atualização da versão patch atual para o próximo patch disponível. Se você instalou `v1.36.0`, você vai atualizar para o último patch `v1.36.x`.

**Passo 1:** Verifique qual upgrade está disponível (no control-plane):

```bash
sudo kubeadm upgrade plan
```

**Passo 2:** Atualize o nó control-plane:

```bash
# Drene o control-plane (permita que DaemonSets fiquem)
kubectl drain $(hostname) --ignore-daemonsets --delete-emptydir-data

# Desbloqueie pacotes, atualize kubeadm
sudo apt-mark unhold kubeadm
sudo apt-get update
sudo apt-get install -y kubeadm
sudo apt-mark hold kubeadm

# Verifique o plano e aplique o upgrade
sudo kubeadm upgrade plan
sudo kubeadm upgrade apply v1.36.0  # Substitua pela versão mostrada por 'kubeadm upgrade plan'

# Atualize kubelet e kubectl
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet kubectl
sudo apt-mark hold kubelet kubectl

# Reinicie o kubelet
sudo systemctl daemon-reload
sudo systemctl restart kubelet

# Uncordon o control-plane
kubectl uncordon $(hostname)
```

> **Nota:** Substitua `v1.36.0` pela versão alvo mostrada por `kubeadm upgrade plan`. Se você já está no último patch, ainda pode praticar o workflow de drain/uncordon — o `kubeadm upgrade apply` simplesmente confirmará que você está na última versão.

**Passo 3:** Atualize um worker node. No **control-plane**, drene o worker:

```bash
kubectl drain worker-1 --ignore-daemonsets --delete-emptydir-data
```

No **worker-1**, atualize os pacotes:

```bash
sudo apt-mark unhold kubeadm kubelet kubectl
sudo apt-get update
sudo apt-get install -y kubeadm kubelet kubectl
sudo apt-mark hold kubeadm kubelet kubectl

sudo kubeadm upgrade node
sudo systemctl daemon-reload
sudo systemctl restart kubelet
```

De volta no **control-plane**, faça uncordon:

```bash
kubectl uncordon worker-1
```

**Passo 4:** Repita para worker-2, depois verifique:

```bash
kubectl get nodes -o wide
```

Todos os nós devem mostrar a versão atualizada.

### Tarefa 5 — Snapshot e Restore do etcd

O etcd é o cérebro do Kubernetes — como um banco de dados PostgreSQL para o estado do seu cluster. Fazer backup dele é como executar `pg_dump` ou tirar um snapshot LVM antes de uma mudança arriscada.

**Execute no nó control-plane.**

**Passo 1:** Encontre seus certificados do etcd (verifique o manifest do static Pod do etcd):

```bash
sudo cat /etc/kubernetes/manifests/etcd.yaml | grep -E "cert-file|key-file|trusted-ca-file"
```

**Passo 2:** Tire um snapshot do etcd:

```bash
sudo ETCDCTL_API=3 etcdctl snapshot save /opt/etcd-backup.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
```

**Passo 3:** Verifique o snapshot:

```bash
sudo ETCDCTL_API=3 etcdctl snapshot status /opt/etcd-backup.db --write-table
```

Você deve ver o hash do snapshot, revisão, total de chaves e tamanho total.

**Passo 4:** Simule um desastre — crie um namespace de teste, depois delete-o:

```bash
kubectl create namespace snapshot-test
kubectl get namespace snapshot-test
kubectl delete namespace snapshot-test
```

**Passo 5:** Restaure a partir do snapshot:

```bash
# Pare o API server e o etcd (mova os manifests dos static Pods)
sudo mv /etc/kubernetes/manifests/etcd.yaml /etc/kubernetes/etcd.yaml.bak
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/kube-apiserver.yaml.bak

# Remova os dados antigos do etcd
sudo rm -rf /var/lib/etcd

# Restaure a partir do snapshot
sudo ETCDCTL_API=3 etcdctl snapshot restore /opt/etcd-backup.db \
  --data-dir=/var/lib/etcd

# Restaure os manifests dos static Pods
sudo mv /etc/kubernetes/etcd.yaml.bak /etc/kubernetes/manifests/etcd.yaml
sudo mv /etc/kubernetes/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml
```

**Passo 6:** Aguarde o API server e o etcd reiniciarem, depois verifique o namespace restaurado:

```bash
# Aguarde o API server voltar (pode levar 30-60 segundos)
sleep 60
kubectl get namespace snapshot-test
```

Se o snapshot foi tirado enquanto `snapshot-test` existia, ele deve estar de volta. Se foi tirado antes de você criá-lo, ele não aparecerá — confirmando que o restore funcionou.

> **Dica para o exame CKA:** Backup e restore do etcd é um tópico muito cobrado. Memorize os caminhos dos certificados e a sintaxe exata de `etcdctl snapshot save/restore`.

### Tarefa 6 — Custom Resource Definitions (CRDs) e Operators

CRDs permitem estender a API do Kubernetes com tipos de recursos customizados — como criar um novo tipo de unit systemd (`.service`, `.timer`, `.mount`) para que `systemctl` entenda um novo tipo de workload. Operators são controllers que observam esses recursos customizados e agem sobre eles — como um gerador customizado do systemd.

**Passo 1:** Crie um CRD para um recurso customizado `BackupSchedule`. Salve como `backupschedule-crd.yaml`:

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: backupschedules.fasthack.io
spec:
  group: fasthack.io
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                schedule:
                  type: string
                retentionDays:
                  type: integer
                target:
                  type: string
      additionalPrinterColumns:
        - name: Schedule
          type: string
          jsonPath: .spec.schedule
        - name: Retention
          type: integer
          jsonPath: .spec.retentionDays
        - name: Target
          type: string
          jsonPath: .spec.target
  scope: Namespaced
  names:
    plural: backupschedules
    singular: backupschedule
    kind: BackupSchedule
    shortNames:
      - bs
```

**Passo 2:** Aplique o CRD e verifique:

```bash
kubectl apply -f backupschedule-crd.yaml
kubectl get crds | grep fasthack
kubectl api-resources | grep backupschedule
```

**Passo 3:** Crie uma instância do recurso customizado. Salve como `my-backup.yaml`:

```yaml
apiVersion: fasthack.io/v1
kind: BackupSchedule
metadata:
  name: nightly-db-backup
spec:
  schedule: "0 2 * * *"
  retentionDays: 30
  target: production-database
```

```bash
kubectl apply -f my-backup.yaml
kubectl get backupschedules
kubectl get bs
kubectl describe backupschedule nightly-db-backup
```

**Passo 4:** Implante um Operator do mundo real — instale o **cert-manager**, que usa CRDs para gerenciar certificados TLS:

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

# Aguarde os pods do cert-manager estarem prontos
kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=120s
```

**Passo 5:** Explore os CRDs que o cert-manager instalou:

```bash
kubectl get crds | grep cert-manager
kubectl api-resources | grep cert-manager
```

Você deve ver CRDs como `certificates.cert-manager.io`, `issuers.cert-manager.io`, `clusterissuers.cert-manager.io`, etc. Estes são novos "tipos de API" que o Operator cert-manager observa e age sobre — assim como o `timerd` do systemd observa arquivos de unit `.timer`.

### Tarefa 7 — Explorar Interfaces de Extensão (CNI, CSI, CRI)

O Kubernetes tem uma arquitetura de plugins para rede, armazenamento e runtimes de containers — similar a como o Linux usa módulos carregáveis de kernel (`modprobe`), módulos PAM (`/etc/pam.d/`) e módulos NSS (`/etc/nsswitch.conf`) para estender funcionalidades centrais sem modificar o kernel.

**Passo 1:** Identifique a Container Runtime Interface (CRI) em uso:

```bash
kubectl get nodes -o wide
# Observe a coluna CONTAINER-RUNTIME

# Verifique o socket CRI do kubelet
sudo cat /var/lib/kubelet/kubeadm-flags.env
```

**Passo 2:** Identifique o plugin Container Network Interface (CNI):

```bash
# Liste os plugins CNI instalados
ls /etc/cni/net.d/
cat /etc/cni/net.d/*.conflist 2>/dev/null || cat /etc/cni/net.d/*.conf 2>/dev/null

# Verifique quais pods CNI estão rodando
kubectl get pods -n kube-system -l k8s-app=calico-node
```

**Passo 3:** Explore CSI (Container Storage Interface) — liste quaisquer drivers CSI instalados:

```bash
kubectl get csidrivers
kubectl get storageclasses
```

Em um cluster kubeadm puro você pode não ter um driver CSI ainda — isso é esperado. Em produção, você instalaria um (como `csi-driver-nfs`, `aws-ebs-csi-driver` ou `azuredisk-csi-driver`).

**Passo 4:** Entenda como essas interfaces se comparam a módulos de kernel do Linux:

```bash
# Módulos de kernel do Linux — extensões modulares ao kernel
lsmod | head -10

# Extensões do Kubernetes — interfaces modulares para runtime, rede, armazenamento
kubectl get nodes -o jsonpath='{.items[*].status.nodeInfo.containerRuntimeVersion}'
echo ""
kubectl get pods -n kube-system -o custom-columns="NAME:.metadata.name,IMAGE:.spec.containers[0].image" | grep -E "calico|coredns|etcd"
```

### Limpe

Se usando Vagrant:

```bash
vagrant destroy -f
```

Se usando VMs na nuvem, delete-as pelo console ou CLI do seu provedor.

Se você quiser destruir apenas o cluster Kubernetes (manter as VMs):

```bash
# Nos workers
sudo kubeadm reset -f

# No control-plane
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d $HOME/.kube
```

## Critérios de Sucesso

- [ ] Todos os 3 nós têm swap desabilitado, módulos de kernel carregados (`overlay`, `br_netfilter`) e parâmetros sysctl configurados.
- [ ] O containerd está instalado, rodando e configurado com `SystemdCgroup = true`.
- [ ] kubeadm, kubelet e kubectl estão instalados e fixados na versão correta.
- [ ] `kubeadm init` inicializou com sucesso o control-plane com `--pod-network-cidr=192.168.0.0/16`.
- [ ] O Calico CNI está instalado e todos os Pods do Calico estão Running.
- [ ] Ambos os workers se juntaram ao cluster com `kubeadm join` e todos os 3 nós mostram `Ready`.
- [ ] Você realizou um ciclo de drain → upgrade → uncordon em pelo menos um nó.
- [ ] Você consegue explicar por que `kubeadm upgrade apply` é usado no primeiro control-plane e `kubeadm upgrade node` em nós adicionais e workers.
- [ ] Um snapshot do etcd foi salvo com `etcdctl snapshot save` e verificado com `etcdctl snapshot status`.
- [ ] Você restaurou com sucesso a partir do snapshot do etcd e verificou o estado do cluster.
- [ ] Um CRD customizado (`BackupSchedule`) foi criado e você pode executar `kubectl get backupschedules`.
- [ ] O Operator cert-manager foi implantado e você pode listar seus CRDs.
- [ ] Você identificou o CRI (containerd), CNI (Calico) e verificou drivers CSI no seu cluster.
- [ ] Você consegue explicar como CNI/CSI/CRI são como módulos carregáveis de kernel do Linux — interfaces plugáveis que estendem funcionalidade.

## Referência Rápida Linux ↔ Kubernetes

| Conceito Linux | Equivalente Kubernetes | Notas |
|---|---|---|
| `pacemaker` / `corosync-cfgtool -s` | `kubeadm init` | Inicializar o primeiro nó de control-plane |
| `pcs cluster node add <node>` | `kubeadm join --token <token>` | Adicionar worker ou nós de control-plane ao cluster |
| `apt upgrade` com `systemctl isolate maintenance.target` | `kubectl drain` → `kubeadm upgrade` → `kubectl uncordon` | Padrão de janela de manutenção para upgrades graduais |
| `pg_dump` / `lvcreate --snapshot` | `etcdctl snapshot save` | Backup point-in-time do estado do cluster |
| `pg_restore` / `lvconvert --merge` | `etcdctl snapshot restore` | Recuperação de desastre a partir de backup |
| Pacemaker HA com `keepalived` + VIP | Múltiplos nós `--control-plane-endpoint` | Control plane HA com API server balanceado |
| Tipo customizado de unit `systemd` (`.service`, `.timer`) | Custom Resource Definition (CRD) | Estender a API com novos tipos de recurso |
| Geradores `systemd` / `systemd-run` | Operators (controllers que observam CRDs) | Automatizar ações quando recursos customizados mudam |
| `modprobe <driver>` — módulos carregáveis de kernel | Plugins CNI (Calico, Cilium, Flannel) | Rede de containers plugável |
| Módulos PAM (`/etc/pam.d/`) | Implementações CRI (containerd, CRI-O) | Runtimes de container plugáveis |
| Módulos NSS (`/etc/nsswitch.conf`) | Drivers CSI (EBS, Azure Disk, NFS) | Interfaces de armazenamento plugáveis |
| `apt-mark hold <package>` | `apt-mark hold kubeadm kubelet kubectl` | Prevenir upgrades acidentais de pacotes |
| `swapoff -a` + editar `/etc/fstab` | O mesmo — Kubernetes requer swap desabilitado | Pré-requisito do K8s desde v1.22 |

## Dicas

<details>
<summary>Dica 1: kubeadm init falha com erros de preflight</summary>

Verifique problemas comuns de preflight:

```bash
# Verifique se o swap está desligado
free -h | grep Swap

# Verifique se os módulos de kernel estão carregados
lsmod | grep br_netfilter
lsmod | grep overlay

# Verifique se o containerd está rodando
sudo systemctl status containerd

# Verifique se o driver de cgroup é systemd
sudo containerd config dump | grep SystemdCgroup
```

Se você vir `[ERROR NumCPU]: the number of available CPUs 1 is less than the required 2`, sua VM precisa de pelo menos 2 CPUs.

</details>

<details>
<summary>Dica 2: Nós presos em NotReady após kubeadm join</summary>

`NotReady` geralmente significa que o plugin CNI não está instalado ou não está funcionando:

```bash
kubectl get pods -n kube-system -l k8s-app=calico-node
kubectl describe node <node-name> | grep -A5 Conditions
```

Se os Pods do Calico estão em `CrashLoopBackOff`, verifique se o `--pod-network-cidr` usado no `kubeadm init` corresponde ao CIDR esperado pelo Calico (`192.168.0.0/16`).

</details>

<details>
<summary>Dica 3: Token do kubeadm join expirou</summary>

Tokens expiram após 24 horas por padrão. Crie um novo no control-plane:

```bash
kubeadm token create --print-join-command
```

Isso gera um comando `kubeadm join` completo com um token novo e o hash correto do certificado CA.

</details>

<details>
<summary>Dica 4: etcdctl não encontrado ou conexão recusada</summary>

`etcdctl` pode não estar instalado como um binário standalone. Você pode executá-lo do container etcd:

```bash
sudo crictl ps | grep etcd
```

Ou instale-o diretamente:

```bash
ETCD_VER=v3.5.21
curl -fsSL https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz | \
  sudo tar xz -C /usr/local/bin --strip-components=1 etcd-${ETCD_VER}-linux-amd64/etcdctl
```

Sempre defina `ETCDCTL_API=3` antes de executar comandos.

</details>

<details>
<summary>Dica 5: Restore do etcd — API server não volta</summary>

Após restaurar o etcd, o API server pode levar 30-60 segundos para reiniciar. Se não voltar:

```bash
# Verifique se os manifests dos static Pods estão de volta
ls /etc/kubernetes/manifests/

# Verifique os logs do kubelet
sudo journalctl -u kubelet --no-pager --since "5 minutes ago" | tail -30

# Force o restart do kubelet
sudo systemctl restart kubelet
```

Certifique-se de restaurar para `/var/lib/etcd` (o diretório de dados padrão). Se você usou um `--data-dir` diferente, precisa atualizar o manifest do static Pod do etcd para apontar para ele.

</details>

<details>
<summary>Dica 6: CRD não aparece em api-resources</summary>

Aguarde alguns segundos após aplicar o CRD — o API server precisa processá-lo:

```bash
kubectl get crds
kubectl api-resources | grep backupschedule
```

Se o CRD tem erros de validação, verifique:

```bash
kubectl describe crd backupschedules.fasthack.io
```

Garanta que é `apiVersion: apiextensions.k8s.io/v1` (não `v1beta1`, que foi removido desde K8s 1.22).

</details>

<details>
<summary>Dica 7: Qual é a diferença entre stacked e external etcd?</summary>

**Stacked etcd** (padrão do kubeadm): etcd roda em cada nó de control-plane como um static Pod. Mais simples de configurar mas uma falha de nó derruba tanto um membro do control-plane quanto um membro do etcd.

**External etcd**: etcd roda em nós dedicados separados. Mais resiliente — perder um nó de control-plane não afeta o quórum do etcd — mas mais complexo de gerenciar.

Para o exame CKA, conheça ambas as topologias. `kubeadm init --config` com `etcd.external` configura external etcd.

</details>

## Recursos de Aprendizado

- [Creating a cluster with kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/)
- [kubeadm init reference](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-init/)
- [kubeadm join reference](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-join/)
- [Upgrading kubeadm clusters](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/)
- [Operating etcd — backup and restore](https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/#snapshot-backup-and-restore)
- [Creating Highly Available clusters with kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/)
- [CustomResourceDefinitions (CRDs)](https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/)
- [Extend the Kubernetes API with CRDs](https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/)
- [Container Runtime Interface (CRI)](https://kubernetes.io/docs/concepts/architecture/cri/)
- [Network Plugins (CNI)](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/)
- [Container Storage Interface (CSI)](https://kubernetes.io/docs/concepts/storage/volumes/#csi)
- [Calico quickstart](https://docs.tigera.io/calico/latest/getting-started/kubernetes/quickstart)
- [cert-manager documentation](https://cert-manager.io/docs/)
- [CKA Curriculum](https://github.com/cncf/curriculum)

## Quebra & Conserta 🔧

Tente cada cenário, diagnostique o problema e corrija-o.

### Cenário 1 — kubeadm init falha: swap não desabilitado

Em uma VM nova, execute:

```bash
sudo kubeadm init --pod-network-cidr=192.168.0.0/16
```

**O que você verá:** Erro de preflight: `[ERROR Swap]: running with swap on is not supported. Please disable swap`.

**Diagnostique:**

```bash
free -h | grep Swap
cat /etc/fstab | grep swap
```

**Causa raiz:** O swap ainda está habilitado. A verificação de preflight do `kubeadm init` rejeita nós com swap ativo porque o gerenciamento de memória do kubelet não considera páginas trocadas para disco.

**Correção:**

```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
```

Depois tente `kubeadm init` novamente.

**Analogia com Linux:** É como um instalador de banco de dados Oracle recusando-se a prosseguir porque `vm.swappiness` está muito alto — alguns softwares de cluster têm requisitos rígidos sobre gerenciamento de memória.

---

### Cenário 2 — Worker node não consegue entrar: hash de certificado CA errado

Em um worker, execute:

```bash
sudo kubeadm join 192.168.56.10:6443 \
  --token abcdef.1234567890abcdef \
  --discovery-token-ca-cert-hash sha256:0000000000000000000000000000000000000000000000000000000000000000
```

**O que você verá:** `error execution phase preflight: unable to fetch the kubeadm-config ConfigMap` ou `certificate authority hash does not match`.

**Diagnostique:**

```bash
# No control-plane, verifique o hash real
openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | \
  openssl rsa -pubin -outform der 2>/dev/null | \
  openssl dgst -sha256 -hex | sed 's/^.* //'
```

**Causa raiz:** O hash do certificado CA não corresponde. Esta é uma funcionalidade de segurança — ela previne que um man-in-the-middle se faça passar pelo control-plane. Você ou copiou o hash errado ou o control-plane foi reinicializado.

**Correção:** Gere um novo comando join no control-plane:

```bash
kubeadm token create --print-join-command
```

Use a saída (que tem tanto um token válido quanto o hash correto) no worker.

**Analogia com Linux:** É como a verificação de host key do SSH falhando — `ssh-keygen -R host` seguido de reconexão. O fingerprint deve corresponder.

---

### Cenário 3 — Restore do etcd não traz de volta o namespace deletado

Após tirar um snapshot e deletar um namespace, você restaura:

```bash
sudo ETCDCTL_API=3 etcdctl snapshot restore /opt/etcd-backup.db \
  --data-dir=/var/lib/etcd-new
```

Mas o cluster ainda mostra o namespace como deletado.

**Diagnostique:**

```bash
# Verifique qual diretório de dados o etcd está realmente usando
sudo grep -i "data-dir" /etc/kubernetes/manifests/etcd.yaml
```

**Causa raiz:** Você restaurou para `/var/lib/etcd-new` mas o static Pod do etcd ainda está configurado para usar `/var/lib/etcd`. Os dados restaurados estão lá sem uso.

**Correção:** Ou:

a) Restaure para o diretório correto:

```bash
sudo rm -rf /var/lib/etcd
sudo ETCDCTL_API=3 etcdctl snapshot restore /opt/etcd-backup.db \
  --data-dir=/var/lib/etcd
```

b) Ou atualize o manifest do static Pod do etcd para usar o novo diretório:

```bash
sudo sed -i 's|/var/lib/etcd|/var/lib/etcd-new|g' /etc/kubernetes/manifests/etcd.yaml
```

**Analogia com Linux:** É como restaurar um dump do PostgreSQL para `/var/lib/postgresql/restored/` mas o `data_directory` do PostgreSQL ainda aponta para `/var/lib/postgresql/14/main/` — o restore está lá mas o serviço não o vê.

---

### Cenário 4 — Instância de CRD rejeitada: validação de schema falha

Aplique este BackupSchedule (assumindo que o CRD da Tarefa 6 está instalado):

```yaml
# Salve como broken-backup.yaml
apiVersion: fasthack.io/v1
kind: BackupSchedule
metadata:
  name: broken-backup
spec:
  schedule: "0 3 * * *"
  retentionDays: "thirty"
  target: staging-db
```

```bash
kubectl apply -f broken-backup.yaml
```

**O que você verá:** `error: .spec.retentionDays: Invalid value: "string": spec.retentionDays in body must be of type integer`.

**Causa raiz:** O schema do CRD define `retentionDays` como `type: integer`, mas o YAML fornece uma string `"thirty"`. O API server do Kubernetes impõe o schema OpenAPIV3 nas instâncias de CRD.

**Correção:** Use um valor inteiro:

```yaml
  retentionDays: 30
```

**Analogia com Linux:** É como um arquivo de unit systemd falhando na validação porque `TimeoutStartSec=thirty` não é um formato de tempo válido — systemd espera um número ou expressão de tempo como `30s`.
