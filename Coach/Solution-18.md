# Solução 18 — Administração de Cluster com kubeadm

[< Solução Anterior](Solution-17.md) - **[Home](README.md)** - [Próxima Solução >](Solution-19.md)

---

> **Nota do Coach:** Este é o desafio mais crítico para o CKA. Requer VMs reais — não Kind ou Minikube. Ajude os alunos a escolher um ambiente de laboratório (VMs na nuvem, Vagrant ou Killercoda). As Tarefas 1-3 são a sequência principal de bootstrap. As Tarefas 4-5 (upgrade + etcd) são os tópicos com maior peso no exame. As Tarefas 6-7 são conceituais com exploração prática. Se o tempo for limitado, priorize as Tarefas 1-5.

Tempo estimado: **90–120 minutos**

---

## Tarefa 1: Preparar Pré-requisitos das VMs

### Passo a passo (TODOS OS 3 NODES)

> **Dica para o Coach:** Faça o passo a passo com os alunos no control-plane primeiro, depois peça que repitam nos dois workers. O erro mais comum é esquecer um passo em um dos nodes.

**Desabilitar swap:**

```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
```

### Verificação — Swap desabilitado

```bash
free -h | grep Swap
```

Esperado:

```
Swap:            0B          0B          0B
```

**Carregar módulos do kernel:**

```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
```

### Verificação — Módulos carregados

```bash
lsmod | grep -E "overlay|br_netfilter"
```

Esperado (ambos os módulos listados):

```
br_netfilter           32768  0
overlay               212992  0
```

**Configurar parâmetros sysctl:**

```bash
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

sudo sysctl --system
```

### Verificação — Parâmetros sysctl

```bash
sysctl net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward net.bridge.bridge-nf-call-ip6tables
```

Esperado:

```
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-ip6tables = 1
```

**Instalar e configurar o containerd:**

```bash
sudo apt-get update
sudo apt-get install -y containerd

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd
```

### Verificação — containerd em execução com systemd cgroup

```bash
sudo systemctl status containerd --no-pager
```

Esperado: `Active: active (running)`

```bash
sudo containerd config dump | grep SystemdCgroup
```

Esperado:

```
            SystemdCgroup = true
```

> **Dica para o Coach:** A configuração `SystemdCgroup = true` é o passo nº 1 mais esquecido. Se os alunos pularem, o kubelet falhará ao iniciar com erros de incompatibilidade do driver de cgroup. O sintoma é o kubelet entrando em loop de crash — verifique com `journalctl -u kubelet`.

**Instalar kubeadm, kubelet, kubectl:**

```bash
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet
```

### Verificação — Pacotes instalados

```bash
kubeadm version -o short
kubelet --version
kubectl version --client --short 2>/dev/null || kubectl version --client
```

Esperado: Todos mostram `v1.36.x`.

```bash
apt-mark showhold
```

Esperado:

```
kubeadm
kubectl
kubelet
```

> **Dica para o Coach:** Se o `apt-get install` falhar com "package not found", o aluno provavelmente está com a URL do repositório errada. Verifique com:
> ```bash
> cat /etc/apt/sources.list.d/kubernetes.list
> ```
> Deve conter `https://pkgs.k8s.io/core:/stable:/v1.36/deb/`.

---

## Tarefa 2: Inicializar o Control Plane

### Passo a passo (SOMENTE NO CONTROL-PLANE)

```bash
sudo kubeadm init \
  --pod-network-cidr=192.168.0.0/16 \
  --kubernetes-version=v1.36.0
```

Saída esperada (final da saída):

```
Your Kubernetes control-plane has initialized successfully!

To start using your cluster, you need to run the following as a regular user:

  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

...

Then you can join any number of worker nodes by running the following on each as root:

kubeadm join <IP>:6443 --token <TOKEN> \
        --discovery-token-ca-cert-hash sha256:<HASH>
```

> **Dica para o Coach:** Diga aos alunos para **copiar e salvar o comando `kubeadm join` imediatamente**. É fácil perder no scroll. Eles também podem regenerá-lo depois com `kubeadm token create --print-join-command`, mas isso adiciona tempo desnecessário de troubleshooting.

**Configurar o kubeconfig:**

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

### Verificação — Control plane em execução

```bash
kubectl get nodes
```

Esperado:

`NotReady` is correct at this point — no CNI plugin installed yet.

```bash
kubectl get pods -n kube-system
```

Esperado (todos Running ou Pending para coredns):

```
NAME                                    READY   STATUS    RESTARTS   AGE
coredns-xxxxxxxxxx-xxxxx                0/1     Pending   0          30s
coredns-xxxxxxxxxx-xxxxx                0/1     Pending   0          30s
etcd-control-plane                      1/1     Running   0          40s
kube-apiserver-control-plane            1/1     Running   0          40s
kube-controller-manager-control-plane   1/1     Running   0          40s
kube-proxy-xxxxx                        1/1     Running   0          30s
kube-scheduler-control-plane            1/1     Running   0          40s
```

> **Dica para o Coach:** O CoreDNS ficará Pending até que um CNI seja instalado — isso é esperado. Se `kube-apiserver` ou `etcd` não estiverem Running, verifique:
> ```bash
> sudo crictl ps
> sudo journalctl -u kubelet --no-pager | tail -30
> ```

---

## Tarefa 3: Instalar Calico CNI e Adicionar Workers

### Passo a passo

**Instalar Calico (no control-plane):**

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.0/manifests/calico.yaml
```

### Verificação — Calico em execução

```bash
kubectl get pods -n kube-system -l k8s-app=calico-node --watch
```

Aguarde até que todos mostrem `Running` (pode levar 1-2 minutos), depois Ctrl+C.

```bash
kubectl get nodes
```

Esperado:

```
NAME            STATUS   ROLES           AGE    VERSION
control-plane   Ready    control-plane   2m     v1.36.0
```

O node agora deve estar `Ready`.

```bash
kubectl get pods -n kube-system
```

O CoreDNS agora também deve estar Running.

**Adicionar worker nodes (em cada worker):**

```bash
sudo kubeadm join <CONTROL-PLANE-IP>:6443 \
  --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH>
```

Saída esperada:

```
This node has joined the cluster:
* Certificate signing request was sent to apiserver and a response was received.
* The Kubelet was informed of the new node details.

Run 'kubectl get nodes' on the control-plane node to see this node join the cluster.
```

> **Dica para o Coach:** Se o token expirou:
> ```bash
> # No control-plane
> kubeadm token create --print-join-command
> ```
> Erros comuns: executar `kubeadm join` sem `sudo`, ou executá-lo no control-plane ao invés do worker.

### Verificação — Todos os nodes Ready (no control-plane)

```bash
kubectl get nodes -o wide
```

Esperado:

```
NAME            STATUS   ROLES           AGE    VERSION   INTERNAL-IP      OS-IMAGE           KERNEL-VERSION    CONTAINER-RUNTIME
control-plane   Ready    control-plane   5m     v1.36.0   192.168.56.10    Ubuntu 24.04 LTS   6.x.x-xx-generic  containerd://1.7.x
worker-1        Ready    <none>          1m     v1.36.0   192.168.56.11    Ubuntu 24.04 LTS   6.x.x-xx-generic  containerd://1.7.x
worker-2        Ready    <none>          30s    v1.36.0   192.168.56.12    Ubuntu 24.04 LTS   6.x.x-xx-generic  containerd://1.7.x
```

**Testar o cluster com uma carga de trabalho:**

```bash
kubectl create deployment nginx-test --image=nginx --replicas=3
kubectl get pods -o wide
```

Os Pods devem ser distribuídos entre os 3 nodes.

```bash
kubectl delete deployment nginx-test
```

> **Dica para o Coach:** Se os workers mostrarem `NotReady`, a causa mais provável é o Calico ainda não ter sido implantado nos worker nodes. Verifique:
> ```bash
> kubectl get pods -n kube-system -o wide | grep calico
> ```
> Cada node deve ter um Pod `calico-node` em execução. Se o calico-node de um worker estiver em CrashLoopBackOff, verifique os logs:
> ```bash
> kubectl logs -n kube-system <calico-node-pod-on-worker> -c calico-node
> ```

---

## Tarefa 4: Upgrade do Cluster

### Passo a passo

> **Dica para o Coach:** Esta é a tarefa mais relevante para o CKA. Os alunos devem entender a sequência exata: drain → upgrade kubeadm → `kubeadm upgrade plan/apply` → upgrade kubelet/kubectl → restart kubelet → uncordon. A ordem importa.

**Verificar upgrades disponíveis (no control-plane):**

```bash
sudo kubeadm upgrade plan
```

A saída esperada mostra a versão atual e os alvos de upgrade disponíveis.

> **Dica para o Coach:** Se os alunos já instalaram o patch mais recente e não há versão mais nova disponível, tudo bem. Peça que pratiquem o fluxo de drain/uncordon de qualquer forma — é a memória muscular que importa. Eles também podem configurar o repositório v1.35 inicialmente e fazer upgrade para v1.36 para um upgrade real de versão minor.

**Fazer upgrade do control-plane:**

```bash
# Step 1: Drain
kubectl drain $(hostname) --ignore-daemonsets --delete-emptydir-data
```

Esperado:

```
node/control-plane cordoned
...
node/control-plane drained
```

```bash
# Step 2: Upgrade kubeadm
sudo apt-mark unhold kubeadm
sudo apt-get update
sudo apt-get install -y kubeadm
sudo apt-mark hold kubeadm

# Step 3: Plan and apply
sudo kubeadm upgrade plan
sudo kubeadm upgrade apply v1.36.0  # Use a versão mostrada por 'kubeadm upgrade plan'
```

Esperado (final da saída):

```
[upgrade/successful] SUCCESS! Your cluster was upgraded to "v1.36.x". Enjoy!
```

```bash
# Step 4: Upgrade kubelet and kubectl
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet kubectl
sudo apt-mark hold kubelet kubectl

# Step 5: Restart kubelet
sudo systemctl daemon-reload
sudo systemctl restart kubelet

# Step 6: Uncordon
kubectl uncordon $(hostname)
```

### Verificação — Control-plane atualizado

```bash
kubectl get nodes
```

O control-plane deve mostrar a nova versão e o status `Ready`.

**Fazer upgrade de um worker node:**

No **control-plane**:

```bash
kubectl drain worker-1 --ignore-daemonsets --delete-emptydir-data
```

No **worker-1**:

```bash
sudo apt-mark unhold kubeadm kubelet kubectl
sudo apt-get update
sudo apt-get install -y kubeadm kubelet kubectl
sudo apt-mark hold kubeadm kubelet kubectl

# Workers usam "upgrade node" (não "upgrade apply")
sudo kubeadm upgrade node

sudo systemctl daemon-reload
sudo systemctl restart kubelet
```

De volta no **control-plane**:

```bash
kubectl uncordon worker-1
```

> **Dica para o Coach — por que `upgrade node` vs `upgrade apply`?**
> - `kubeadm upgrade apply` é para o **primeiro node control-plane** — ele atualiza os componentes do cluster inteiro (API server, controller manager, scheduler, etcd, CoreDNS).
> - `kubeadm upgrade node` é para **nodes control-plane adicionais** e **todos os worker nodes** — ele atualiza apenas a configuração local do kubelet.
> Essa distinção é uma pergunta comum no exame CKA.

### Verificação — Todos os nodes atualizados

Repita para o worker-2, depois verifique:

```bash
kubectl get nodes -o wide
```

Todos os nodes devem mostrar a versão alvo.

---

## Tarefa 5: Snapshot e Restauração do etcd

### Passo a passo

> **Dica para o Coach:** Este é o segundo tópico mais cobrado no CKA (depois de upgrades). Os alunos devem memorizar a sintaxe do etcdctl com as flags TLS. No exame, eles precisarão descobrir os caminhos dos certificados a partir do manifesto do Pod etcd.

**Encontrar caminhos dos certificados:**

```bash
sudo cat /etc/kubernetes/manifests/etcd.yaml | grep -E "cert-file|key-file|trusted-ca-file"
```

Esperado:

```
    - --cert-file=/etc/kubernetes/pki/etcd/server.crt
    - --key-file=/etc/kubernetes/pki/etcd/server.key
    - --peer-cert-file=/etc/kubernetes/pki/etcd/peer.crt
    - --peer-key-file=/etc/kubernetes/pki/etcd/peer.key
    - --trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
```

> **Dica para o Coach:** No exame CKA, os caminhos dos certificados não serão informados — você precisará procurá-los no manifesto do etcd ou na spec do Pod etcd. Ensine os alunos a sempre verificar `/etc/kubernetes/manifests/etcd.yaml` primeiro.

**Criar o snapshot:**

```bash
sudo ETCDCTL_API=3 etcdctl snapshot save /opt/etcd-backup.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
```

Esperado:

```
Snapshot saved at /opt/etcd-backup.db
```

### Verificação — Snapshot criado

```bash
sudo ETCDCTL_API=3 etcdctl snapshot status /opt/etcd-backup.db --write-table
```

Esperado (tabela com hash, revisão, total de chaves, tamanho total):

```
+---------+----------+------------+------------+
|  HASH   | REVISION | TOTAL KEYS | TOTAL SIZE |
+---------+----------+------------+------------+
| 3f8aab2 |     1847 |       1020 |     3.2 MB |
+---------+----------+------------+------------+
```

(Os valores irão variar.)

**Criar um namespace de teste, depois deletá-lo (simulando um desastre):**

```bash
kubectl create namespace snapshot-test
kubectl get namespace snapshot-test
kubectl delete namespace snapshot-test
kubectl get namespace snapshot-test  # Deve dizer "not found"
```

**Restaurar a partir do snapshot:**

```bash
# Stop API server and etcd
sudo mv /etc/kubernetes/manifests/etcd.yaml /etc/kubernetes/etcd.yaml.bak
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/kube-apiserver.yaml.bak

# Aguardar a parada
sleep 15

# Remover dados antigos e restaurar
sudo rm -rf /var/lib/etcd
sudo ETCDCTL_API=3 etcdctl snapshot restore /opt/etcd-backup.db \
  --data-dir=/var/lib/etcd

# Restaurar manifestos de static Pod
sudo mv /etc/kubernetes/etcd.yaml.bak /etc/kubernetes/manifests/etcd.yaml
sudo mv /etc/kubernetes/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml
```

### Verificação — Restauração bem-sucedida

```bash
# Wait for API server to come back
sleep 60
kubectl get namespace snapshot-test
```

Se o snapshot foi tirado enquanto `snapshot-test` existia, ele deve estar de volta.

```bash
kubectl get nodes
kubectl get pods -n kube-system
```

O cluster deve estar totalmente funcional.

> **Dica para o Coach — erros comuns na restauração:**
> 1. Esquecer de remover `/var/lib/etcd` antes de restaurar — a restauração não sobrescreve dados existentes
> 2. Restaurar em um `--data-dir` diferente mas não atualizar o manifesto do etcd — o etcd inicia com dados antigos
> 3. Não esperar tempo suficiente para o API server reiniciar — pode levar 30-60 segundos
> 4. Esquecer `ETCDCTL_API=3` — etcdctl usa API v2 por padrão, que não suporta `snapshot`

---

## Tarefa 6: CRDs e Operators

### Passo a passo

**Criar o CRD:**

Salve `backupschedule-crd.yaml`:

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

Aplique:

```bash
kubectl apply -f backupschedule-crd.yaml
```

### Verificação — CRD registrado

```bash
kubectl get crds | grep fasthack
```

Esperado:

```
backupschedules.fasthack.io   2025-xx-xxTxx:xx:xxZ
```

```bash
kubectl api-resources | grep backupschedule
```

Esperado:

```
backupschedules   bs   fasthack.io/v1   true   BackupSchedule
```

**Criar uma instância de custom resource:**

Salve `my-backup.yaml`:

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

Aplique:

```bash
kubectl apply -f my-backup.yaml
```

### Verificação — Custom resource criado

```bash
kubectl get backupschedules
```

Esperado (additionalPrinterColumns em ação):

```
NAME                SCHEDULE      RETENTION   TARGET
nightly-db-backup   0 2 * * *     30          production-database
```

```bash
kubectl get bs  # Nome curto funciona
kubectl describe backupschedule nightly-db-backup
```

> **Dica para o Coach:** Destaque a funcionalidade `additionalPrinterColumns` — é o que faz o `kubectl get` mostrar colunas úteis ao invés de apenas nome e idade. É assim que Operators reais fornecem saída amigável ao usuário.

**Implantar o Operator cert-manager:**

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=120s
```

### Verificação — cert-manager em execução

```bash
kubectl get pods -n cert-manager
```

Esperado:

```
NAME                                       READY   STATUS    RESTARTS   AGE
cert-manager-xxxxxxxxx-xxxxx               1/1     Running   0          30s
cert-manager-cainjector-xxxxxxxxx-xxxxx    1/1     Running   0          30s
cert-manager-webhook-xxxxxxxxx-xxxxx       1/1     Running   0          30s
```

```bash
kubectl get crds | grep cert-manager
```

Esperado (6+ CRDs):

```
certificaterequests.cert-manager.io    2025-xx-xxTxx:xx:xxZ
certificates.cert-manager.io          2025-xx-xxTxx:xx:xxZ
challenges.acme.cert-manager.io       2025-xx-xxTxx:xx:xxZ
clusterissuers.cert-manager.io        2025-xx-xxTxx:xx:xxZ
issuers.cert-manager.io               2025-xx-xxTxx:xx:xxZ
orders.acme.cert-manager.io           2025-xx-xxTxx:xx:xxZ
```

> **Dica para o Coach — CRDs vs Operators:**
> - Um **CRD** apenas define um novo tipo de recurso (schema). Por si só, ele não faz nada — é como criar uma nova definição de tipo de unit no systemd.
> - Um **Operator** é um controller (Deployment + RBAC + CRDs) que observa instâncias desses custom resources e age sobre eles. O cert-manager observa recursos `Certificate` e efetivamente provisiona certificados TLS.
> - O CRD BackupSchedule que criamos não tem nenhum Operator observando-o — criar instâncias não faz nada. Em produção, você escreveria (ou instalaria) um controller que observa recursos BackupSchedule e dispara backups reais.

---

## Tarefa 7: Interfaces de Extensão (CNI, CSI, CRI)

### Passo a passo

**Identificar CRI:**

```bash
kubectl get nodes -o wide
```

Observe a coluna `CONTAINER-RUNTIME` — deve mostrar `containerd://1.7.x`.

```bash
sudo cat /var/lib/kubelet/kubeadm-flags.env
```

Esperado (contém o caminho do socket CRI):

```
KUBELET_KUBEADM_ARGS="--container-runtime-endpoint=unix:///var/run/containerd/containerd.sock ..."
```

**Identificar CNI:**

```bash
ls /etc/cni/net.d/
```

Esperado:

```
10-calico.conflist  calico-kubeconfig
```

```bash
cat /etc/cni/net.d/10-calico.conflist | head -20
```

Mostra a configuração CNI do Calico com o tipo `calico` e configurações de IPAM.

```bash
kubectl get pods -n kube-system -l k8s-app=calico-node -o wide
```

Esperado: Um Pod `calico-node` por node (DaemonSet).

**Explorar CSI:**

```bash
kubectl get csidrivers
```

Esperado em um cluster kubeadm puro:

```
No resources found
```

```bash
kubectl get storageclasses
```

Esperado: Vazio ou `No resources found` — um cluster kubeadm puro não vem com um driver CSI ou StorageClass.

> **Dica para o Coach:** Este é um ótimo momento de aprendizado:
> - **Kind/Minikube** vêm com um provisionador de storage embutido — é por isso que PVCs "simplesmente funcionam" nesses ambientes.
> - **kubeadm** te dá um cluster puro — você deve instalar um driver CSI para provisionamento dinâmico.
> - Em provedores de nuvem, o driver CSI geralmente vem pré-instalado (aws-ebs-csi, azuredisk-csi, gce-pd-csi).
> - Para bare metal, as opções incluem `nfs-subdir-external-provisioner`, `local-path-provisioner` ou `longhorn`.

**Comparação de módulos do kernel Linux:**

```bash
# Módulos Linux — estendem o kernel
lsmod | head -10
modinfo br_netfilter

# Kubernetes CRI — estende suporte a container runtime
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.containerRuntimeVersion}{"\n"}{end}'

# Kubernetes CNI — estende networking
kubectl get ds -n kube-system

# Kubernetes CSI — estende storage (nenhum instalado em kubeadm puro)
kubectl get csidrivers
```

> **Referência do Coach — Resumo das Interfaces de Extensão:**
>
> | Interface | Propósito | Analogia Linux | Nosso Cluster | Alternativas |
> |---|---|---|---|---|
> | **CRI** | Container runtime | Módulos PAM | containerd | CRI-O |
> | **CNI** | Networking de Pods | Módulos de rede do kernel | Calico | Cilium, Flannel, Weave |
> | **CSI** | Storage persistente | Drivers de dispositivo de bloco | (nenhum) | aws-ebs-csi, nfs-csi, longhorn |

---

## Soluções de Break & Fix

### Cenário 1: kubeadm init falha — swap não desabilitado

**Caminho de diagnóstico para os alunos:**

```bash
# Leia a mensagem de erro com atenção — ela diz "Swap"
free -h | grep Swap
# Se o Swap total > 0, o swap está ligado
```

**Solução:**

```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
# Tente novamente o kubeadm init
sudo kubeadm init --pod-network-cidr=192.168.0.0/16
```

> **Dica para o Coach:** O erro de preflight é muito claro. Este cenário ensina os alunos a ler mensagens de erro cuidadosamente ao invés de sair pesquisando no Google imediatamente.

---

### Cenário 2: Worker node não consegue entrar — hash do certificado CA incorreto

**Caminho de diagnóstico para os alunos:**

```bash
# A mensagem de erro menciona "certificate authority" ou "unable to fetch kubeadm-config"
# Compare o hash usado com o real:
openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | \
  openssl rsa -pubin -outform der 2>/dev/null | \
  openssl dgst -sha256 -hex | sed 's/^.* //'
```

**Solução:**

```bash
# No control-plane, regenere o comando de join
kubeadm token create --print-join-command
# Copie a saída completa e execute no worker
```

> **Dica para o Coach:** Isso ensina o modelo de segurança — `kubeadm join` valida a identidade do API server via o hash do certificado CA. É o equivalente Kubernetes da verificação de chave de host do SSH.

---

### Cenário 3: Restauração do etcd — namespace não retorna

**Caminho de diagnóstico para os alunos:**

```bash
# Verifique onde o etcd procura seus dados
sudo grep "data-dir" /etc/kubernetes/manifests/etcd.yaml
# Compare com onde a restauração foi direcionada
ls -la /var/lib/etcd*
```

**Solução:**

```bash
# Ou restaure para o diretório correto:
sudo rm -rf /var/lib/etcd
sudo ETCDCTL_API=3 etcdctl snapshot restore /opt/etcd-backup.db \
  --data-dir=/var/lib/etcd

# Ou atualize o manifesto do etcd:
sudo sed -i 's|/var/lib/etcd|/var/lib/etcd-new|g' /etc/kubernetes/manifests/etcd.yaml
```

> **Dica para o Coach:** Este é um cenário realista do CKA. O insight chave: `--data-dir` no comando de restauração deve corresponder ao que o etcd está configurado para usar. Sempre verifique o manifesto do static Pod.

---

### Cenário 4: Instância de CRD rejeitada — validação de schema

**Caminho de diagnóstico para os alunos:**

```bash
# A mensagem de erro diz "must be of type integer"
# Olhe o YAML — retentionDays: "thirty" é uma string
kubectl get crd backupschedules.fasthack.io -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.retentionDays}'
# Shows: {"type":"integer"}
```

**Solução:** Corrija o YAML para usar `retentionDays: 30` (inteiro, não string).

> **Dica para o Coach:** A validação de schema do CRD é aplicada no lado do servidor. Diferente de ConfigMaps simples onde qualquer string é aceita, CRDs impõem segurança de tipos. Isso é uma funcionalidade, não um bug — captura erros cedo, assim como verificação de tipos em arquivos unit do systemd.

---

## Referência Rápida do Coach — Folha de Consulta de Comandos Principais

```bash
# Bootstrap
kubeadm init --pod-network-cidr=192.168.0.0/16
kubeadm token create --print-join-command
kubeadm join <IP>:6443 --token <TOKEN> --discovery-token-ca-cert-hash sha256:<HASH>

# Sequência de upgrade (MEMORIZE para o CKA)
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
# ... upgrade dos pacotes ...
sudo kubeadm upgrade apply v1.36.x    # primeiro control-plane
sudo kubeadm upgrade node              # CP adicional + workers
sudo systemctl daemon-reload && sudo systemctl restart kubelet
kubectl uncordon <node>

# Backup/restore do etcd (MEMORIZE para o CKA)
ETCDCTL_API=3 etcdctl snapshot save /opt/backup.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

ETCDCTL_API=3 etcdctl snapshot restore /opt/backup.db --data-dir=/var/lib/etcd

# CRDs
kubectl get crds
kubectl api-resources | grep <group>
kubectl get <custom-resource>

# Extensões
kubectl get nodes -o wide                    # Informações de CRI
ls /etc/cni/net.d/                           # Configuração CNI
kubectl get csidrivers                       # Drivers CSI
```
