# Desafio 15 — Agendamento de Pods & Gerenciamento de Recursos

[< Desafio Anterior](Challenge-14.md) - **[Início](../README.md)** - [Próximo Desafio >](Challenge-16.md)

## Introdução

Em um servidor Linux, você controla *onde* e *como* os processos são executados usando ferramentas como `taskset` (fixar um processo em CPUs específicas), `cgroups` (limitar CPU e memória), `ulimit` (limitar recursos por usuário) e `nice`/`ionice` (definir prioridade de agendamento). Quando você gerencia múltiplas máquinas, decide qual servidor executa qual carga de trabalho — talvez o banco de dados vá para a máquina com SSDs, ou você mantém duas réplicas de um servidor web em hosts físicos diferentes para que uma única falha de hardware não derrube tudo.

O Kubernetes automatiza todas essas decisões através do seu **scheduler**. Em vez de acessar máquinas via SSH e posicionar cargas de trabalho manualmente, você declara *regras* — "este Pod precisa de um node com GPU", "mantenha estes dois Pods separados", "nunca coloque mais de 2 réplicas no mesmo node", "este namespace não pode usar mais de 4 CPUs no total." O scheduler lê suas regras e o estado atual do cluster, então posiciona os Pods de acordo.

Neste desafio você dominará o kit completo de agendamento e gerenciamento de recursos: **taints & tolerations** (repelentes no nível do node), **node affinity** (atraindo Pods para nodes), **Pod affinity & anti-affinity** (co-localizando ou separando Pods), **topology spread constraints** (distribuição uniforme), **static Pods** (Pods gerenciados pelo kubelet), **ResourceQuotas & LimitRanges** (limites de recursos no nível do namespace) e **PodDisruptionBudgets** (redes de segurança para manutenção).

> **Requisito do cluster:** Este desafio requer um **cluster Kind com 3 nodes** (1 control-plane + 2 workers) para que os exercícios de agendamento funcionem corretamente. Siga a Tarefa 0 abaixo para criar um.

## Descrição

### Tarefa 0 — Criar um Cluster Kind com 3 Nodes

Para que os exercícios de agendamento sejam significativos, você precisa de múltiplos worker nodes. Crie um cluster Kind com 1 control-plane e 2 workers.

Salve como `kind-scheduling.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

```bash
# Delete any existing cluster
kind delete cluster --name fasthack 2>/dev/null

# Create the 3-node cluster
kind create cluster --name fasthack --config kind-scheduling.yaml

# Verify all 3 nodes are Ready
kubectl get nodes
```

Você deve ver três nodes: `fasthack-control-plane`, `fasthack-worker` e `fasthack-worker2`.

Rotule os worker nodes para tarefas posteriores:

```bash
kubectl label node fasthack-worker disk=ssd zone=us-east-1a
kubectl label node fasthack-worker2 disk=hdd zone=us-east-1b
```

---

### Tarefa 1 — Taints & Tolerations

**Analogia com Linux:** Como definir uma regra de cgroup que impede certos processos de executar em CPUs específicas — apenas processos que explicitamente "optam por entrar" são permitidos.

Taints são aplicados a **nodes** para repelir Pods. Tolerations são aplicados a **Pods** para permitir que eles sejam alocados em nodes com taints.

**Passo 1:** Aplique um taint no `fasthack-worker2` para que apenas Pods com uma toleration correspondente possam ser agendados lá:

```bash
kubectl taint nodes fasthack-worker2 environment=production:NoSchedule
```

**Passo 2:** Crie um Pod **sem** toleration e observe que ele só é alocado no `fasthack-worker`:

Salve como `no-toleration-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: no-toleration
spec:
  containers:
    - name: nginx
      image: nginx:stable
```

```bash
kubectl apply -f no-toleration-pod.yaml
kubectl get pod no-toleration -o wide
```

O Pod deve ser agendado no `fasthack-worker` (não no `fasthack-worker2`).

**Passo 3:** Crie um Pod **com** uma toleration correspondente que pode executar no node com taint:

Salve como `tolerant-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: tolerant-pod
spec:
  containers:
    - name: nginx
      image: nginx:stable
  tolerations:
    - key: "environment"
      operator: "Equal"
      value: "production"
      effect: "NoSchedule"
```

```bash
kubectl apply -f tolerant-pod.yaml
kubectl get pod tolerant-pod -o wide
```

O Pod *pode* ser alocado em qualquer worker — tolerations *permitem* o agendamento no node com taint mas não *forçam*. Para garantir a alocação no node com taint, você combinaria uma toleration com node affinity (abordado na Tarefa 2).

**Passo 4:** Verifique checando os taints:

```bash
kubectl describe node fasthack-worker2 | grep -A 3 Taints
```

Limpe antes da próxima tarefa:

```bash
kubectl delete pod no-toleration tolerant-pod
```

---

### Tarefa 2 — Node Affinity

**Analogia com Linux:** Como `taskset -c 0,1 myprocess` — fixar um processo em CPUs específicas. Node affinity fixa Pods em nodes específicos baseado em labels.

O Kubernetes suporta dois tipos de node affinity:
- `requiredDuringSchedulingIgnoredDuringExecution` — **regra rígida** (deve ser satisfeita)
- `preferredDuringSchedulingIgnoredDuringExecution` — **regra flexível** (tenta satisfazer, mas agenda de qualquer forma se não for possível)

**Passo 1:** Crie um Pod com node affinity **obrigatória** que tem como alvo o node `disk=ssd`:

Salve como `required-affinity.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: ssd-required
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: disk
                operator: In
                values:
                  - ssd
  containers:
    - name: nginx
      image: nginx:stable
```

```bash
kubectl apply -f required-affinity.yaml
kubectl get pod ssd-required -o wide
```

O Pod **deve** ser alocado no `fasthack-worker` (o node rotulado como `disk=ssd`).

**Passo 2:** Crie um Pod com node affinity **preferencial** que prefere `disk=nvme` (que não existe), com fallback:

Salve como `preferred-affinity.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nvme-preferred
spec:
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 80
          preference:
            matchExpressions:
              - key: disk
                operator: In
                values:
                  - nvme
  containers:
    - name: nginx
      image: nginx:stable
```

```bash
kubectl apply -f preferred-affinity.yaml
kubectl get pod nvme-preferred -o wide
```

Como nenhum node tem `disk=nvme`, o scheduler coloca o Pod em qualquer node disponível — é uma preferência flexível, não uma exigência rígida.

**Passo 3:** Verifique a diferença — tente criar um Pod exigindo uma label inexistente:

Salve como `impossible-affinity.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: impossible-pod
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: gpu
                operator: In
                values:
                  - "true"
  containers:
    - name: nginx
      image: nginx:stable
```

```bash
kubectl apply -f impossible-affinity.yaml
kubectl get pod impossible-pod
```

O Pod deve ficar travado em `Pending` — nenhum node satisfaz o requisito. Verifique o motivo:

```bash
kubectl describe pod impossible-pod | grep -A 5 Events
```

Limpe:

```bash
kubectl delete pod ssd-required nvme-preferred impossible-pod
```

---

### Tarefa 3 — Pod Affinity & Anti-Affinity

**Analogia com Linux:** Como co-localizar processos no mesmo node NUMA para desempenho de memória compartilhada, ou separar processos críticos entre CPUs para que um não possa privar o outro de recursos.

Pod affinity atrai Pods em direção a outros Pods. Pod anti-affinity repele Pods uns dos outros.

**Passo 1:** Implante um Pod "cache" para o qual outros Pods serão atraídos:

Salve como `cache-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: cache
  labels:
    app: cache
spec:
  containers:
    - name: redis
      image: redis:7
```

```bash
kubectl apply -f cache-pod.yaml
kubectl get pod cache -o wide
```

Observe em qual node o Pod `cache` é alocado.

**Passo 2:** Crie um Pod com **podAffinity** que deseja ser co-localizado com o cache:

Salve como `web-with-affinity.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web-near-cache
spec:
  affinity:
    podAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchExpressions:
              - key: app
                operator: In
                values:
                  - cache
          topologyKey: kubernetes.io/hostname
  containers:
    - name: nginx
      image: nginx:stable
```

```bash
kubectl apply -f web-with-affinity.yaml
kubectl get pod web-near-cache -o wide
```

O Pod `web-near-cache` deve ser alocado no **mesmo node** que o Pod `cache`.

**Passo 3:** Crie um Deployment com **podAntiAffinity** para espalhar réplicas entre nodes:

Salve como `spread-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spread-web
spec:
  replicas: 2
  selector:
    matchLabels:
      app: spread-web
  template:
    metadata:
      labels:
        app: spread-web
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchExpressions:
                  - key: app
                    operator: In
                    values:
                      - spread-web
              topologyKey: kubernetes.io/hostname
      containers:
        - name: nginx
          image: nginx:stable
```

```bash
kubectl apply -f spread-deployment.yaml
kubectl get pods -l app=spread-web -o wide
```

Cada réplica deve ser alocada em um worker node **diferente**. Se você escalar para 3 réplicas, a terceira ficará `Pending` (apenas 2 worker nodes sem tolerations aplicáveis para remoção de taints):

```bash
kubectl scale deployment spread-web --replicas=3
kubectl get pods -l app=spread-web -o wide
```

Reduza a escala e limpe:

```bash
kubectl scale deployment spread-web --replicas=2
kubectl delete pod cache web-near-cache
kubectl delete deployment spread-web
```

---

### Tarefa 4 — Topology Spread Constraints

**Analogia com Linux:** Como distribuir processos uniformemente entre nodes NUMA para evitar hotspots de memória.

Topology spread constraints oferecem controle mais granular sobre a distribuição de Pods do que anti-affinity.

**Passo 1:** Remova o taint da Tarefa 1 para que ambos os workers estejam disponíveis:

```bash
kubectl taint nodes fasthack-worker2 environment=production:NoSchedule-
```

**Passo 2:** Crie um Deployment com topology spread constraints:

Salve como `topology-spread.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: balanced-web
spec:
  replicas: 4
  selector:
    matchLabels:
      app: balanced-web
  template:
    metadata:
      labels:
        app: balanced-web
    spec:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels:
              app: balanced-web
      containers:
        - name: nginx
          image: nginx:stable
```

```bash
kubectl apply -f topology-spread.yaml
kubectl get pods -l app=balanced-web -o wide
```

Com `maxSkew: 1`, os Pods devem ser distribuídos o mais uniformemente possível entre os worker nodes — espere 2 Pods por worker.

**Passo 3:** Altere `whenUnsatisfiable` para `ScheduleAnyway` e observe a diferença:

```bash
kubectl patch deployment balanced-web --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/topologySpreadConstraints/0/whenUnsatisfiable","value":"ScheduleAnyway"}]'

kubectl rollout status deployment balanced-web
kubectl get pods -l app=balanced-web -o wide
```

Com `ScheduleAnyway`, o scheduler *tenta* distribuir uniformemente mas não deixará Pods sem agendar se a restrição não puder ser perfeitamente atendida.

Limpe:

```bash
kubectl delete deployment balanced-web
```

---

### Tarefa 5 — Static Pods

**Analogia com Linux:** Como um serviço iniciado diretamente pelo `systemd` a partir de um arquivo unit em disco — o sistema init monitora o arquivo e gerencia o ciclo de vida do processo, ignorando qualquer gerenciador de processos de nível superior.

Static Pods são gerenciados diretamente pelo **kubelet** em um node específico, não pelo API server. O kubelet monitora um diretório por manifestos de Pod e inicia/para Pods conforme arquivos aparecem/desaparecem.

**Passo 1:** Encontre o caminho do static Pod no node control-plane do Kind:

```bash
docker exec fasthack-control-plane cat /var/lib/kubelet/config.yaml | grep staticPodPath
```

Você deve ver `staticPodPath: /etc/kubernetes/manifests`.

**Passo 2:** Crie um static Pod colocando um manifesto diretamente nesse diretório:

```bash
docker exec fasthack-control-plane bash -c 'cat > /etc/kubernetes/manifests/static-web.yaml << EOF
apiVersion: v1
kind: Pod
metadata:
  name: static-web
  labels:
    role: static
spec:
  containers:
    - name: nginx
      image: nginx:stable
      ports:
        - containerPort: 80
EOF'
```

**Passo 3:** Verifique se o static Pod aparece no API server como um **mirror Pod**:

```bash
kubectl get pods -A | grep static-web
```

Você deve ver `static-web-fasthack-control-plane` — o kubelet criou um mirror Pod. Note que o hostname do node é anexado ao nome.

**Passo 4:** Tente deletar o mirror Pod:

```bash
kubectl delete pod static-web-fasthack-control-plane -n default
```

Aguarde alguns segundos, depois verifique novamente:

```bash
kubectl get pods | grep static-web
```

O Pod volta! O kubelet o recria porque o arquivo de manifesto ainda existe no disco.

**Passo 5:** A única forma de realmente remover um static Pod é deletar o arquivo de manifesto:

```bash
docker exec fasthack-control-plane rm /etc/kubernetes/manifests/static-web.yaml
```

Aguarde 10–20 segundos, depois verifique que ele sumiu:

```bash
kubectl get pods | grep static-web
```

---

### Tarefa 6 — ResourceQuotas e LimitRanges

**Analogia com Linux:** `ResourceQuota` é como um `ulimit` por usuário — limita o uso total de recursos para um namespace. `LimitRange` é como definir valores padrão de `ulimit` para um grupo de usuários — fornece padrões automáticos e impõe mínimo/máximo por container.

**Passo 1:** Crie um namespace para este exercício:

```bash
kubectl create namespace quota-lab
```

**Passo 2:** Crie uma ResourceQuota que limita o namespace a 2 CPUs e 1Gi de memória no total:

Salve como `resource-quota.yaml`:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: compute-quota
  namespace: quota-lab
spec:
  hard:
    requests.cpu: "2"
    requests.memory: 1Gi
    limits.cpu: "4"
    limits.memory: 2Gi
    pods: "5"
```

```bash
kubectl apply -f resource-quota.yaml
kubectl describe quota compute-quota -n quota-lab
```

**Passo 3:** Crie um LimitRange que define requests/limits padrão de recursos para containers no namespace:

Salve como `limit-range.yaml`:

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
  namespace: quota-lab
spec:
  limits:
    - default:
        cpu: 500m
        memory: 256Mi
      defaultRequest:
        cpu: 100m
        memory: 128Mi
      max:
        cpu: "1"
        memory: 512Mi
      min:
        cpu: 50m
        memory: 64Mi
      type: Container
```

```bash
kubectl apply -f limit-range.yaml
kubectl describe limitrange default-limits -n quota-lab
```

**Passo 4:** Crie um Pod **sem** especificar recursos — o LimitRange deve injetar os padrões:

```bash
kubectl run auto-limits --image=nginx:stable -n quota-lab
kubectl get pod auto-limits -n quota-lab -o jsonpath='{.spec.containers[0].resources}' | python3 -m json.tool
```

Você deve ver os requests e limits padrão injetados pelo LimitRange.

**Passo 5:** Tente criar um Pod que excede o máximo do LimitRange:

Salve como `greedy-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: greedy-pod
  namespace: quota-lab
spec:
  containers:
    - name: hog
      image: nginx:stable
      resources:
        requests:
          cpu: "2"
          memory: 1Gi
        limits:
          cpu: "2"
          memory: 1Gi
```

```bash
kubectl apply -f greedy-pod.yaml
```

Isso deve ser **rejeitado** porque o limite de CPU do container (`2`) excede o máximo do LimitRange (`1`).

**Passo 6:** Verifique o uso da quota:

```bash
kubectl describe quota compute-quota -n quota-lab
```

Você deve ver os recursos consumidos pelo Pod `auto-limits` contabilizados na quota.

---

### Tarefa 7 — PodDisruptionBudgets (PDB)

**Analogia com Linux:** Como garantir que durante uma janela de manutenção (`systemctl stop`), você sempre mantenha pelo menos N instâncias de um serviço crítico em execução no seu pool de servidores.

PDBs protegem sua aplicação durante **interrupções voluntárias** (drains de nodes, upgrades de cluster) garantindo um número mínimo de Pods disponíveis.

**Passo 1:** Crie um Deployment com 3 réplicas:

Salve como `pdb-app.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pdb-web
spec:
  replicas: 3
  selector:
    matchLabels:
      app: pdb-web
  template:
    metadata:
      labels:
        app: pdb-web
    spec:
      containers:
        - name: nginx
          image: nginx:stable
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
```

```bash
kubectl apply -f pdb-app.yaml
kubectl get pods -l app=pdb-web -o wide
```

**Passo 2:** Crie um PodDisruptionBudget que exige pelo menos 2 Pods sempre disponíveis:

Salve como `pdb.yaml`:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: pdb-web
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: pdb-web
```

```bash
kubectl apply -f pdb.yaml
kubectl get pdb
```

A saída esperada mostra `ALLOWED-DISRUPTIONS: 1` (3 réplicas − 2 minAvailable = 1 interrupção permitida).

**Passo 3:** Teste o PDB fazendo drain de um worker node:

```bash
kubectl drain fasthack-worker --ignore-daemonsets --delete-emptydir-data
```

Observe que o drain prossegue, mas respeita o PDB — ele despeja Pods um de cada vez, esperando que substitutos subam antes de despejar o próximo.

```bash
kubectl get pods -l app=pdb-web -o wide
kubectl get pdb
```

Você deve ver pelo menos 2 Pods em execução o tempo todo.

**Passo 4:** Desbloqueie o node drenado para torná-lo agendável novamente:

```bash
kubectl uncordon fasthack-worker
```

**Passo 5 (Bônus):** Tente criar um PDB com `minAvailable: 3` (igual às réplicas) e fazer drain — o drain será **bloqueado** porque não pode despejar nenhum Pod sem violar o budget:

```bash
kubectl patch pdb pdb-web --type=merge -p '{"spec":{"minAvailable":3}}'
kubectl get pdb

# Isso vai bloquear — pressione Ctrl+C após 30 segundos
kubectl drain fasthack-worker --ignore-daemonsets --delete-emptydir-data --timeout=30s
```

Restaure:

```bash
kubectl uncordon fasthack-worker
kubectl patch pdb pdb-web --type=merge -p '{"spec":{"minAvailable":2}}'
```

---

## Critérios de Sucesso

- [ ] **Tarefa 0:** Cluster Kind com 3 nodes está em execução (1 control-plane + 2 workers) com labels personalizadas
- [ ] **Tarefa 1:** Node com taint repele Pods sem tolerations; Pod com toleration pode ser agendado no node com taint
- [ ] **Tarefa 2:** Pod com node affinity `requiredDuringScheduling` é alocado apenas no node correspondente; Pod com `preferredDuringScheduling` faz fallback quando não há correspondência; Pod com affinity impossível fica `Pending`
- [ ] **Tarefa 3:** Pod com podAffinity é alocado no mesmo node que o Pod alvo; Deployment com podAntiAffinity espalha réplicas em nodes diferentes
- [ ] **Tarefa 4:** Topology spread constraints distribuem 4 réplicas uniformemente (2 por worker node)
- [ ] **Tarefa 5:** Static Pod criado via diretório de manifestos do kubelet; mirror Pod visível no API server; Pod sobrevive a `kubectl delete`; removido apenas deletando o arquivo de manifesto
- [ ] **Tarefa 6:** ResourceQuota limita recursos totais do namespace; LimitRange injeta requests/limits padrão; Pod que excede o máximo do LimitRange é rejeitado
- [ ] **Tarefa 7:** PDB impede que `kubectl drain` despeje muitos Pods simultaneamente; pelo menos `minAvailable` Pods permanecem em execução durante o drain

---

## Referência Rápida Linux ↔ Kubernetes

| Conceito Linux | Equivalente Kubernetes | O Que Faz |
|---|---|---|
| Restrições de CPU via `cgroup` | **Taints & Tolerations** | Impedir processos/Pods de executar em certas CPUs/nodes |
| `taskset -c 0,1 process` | **Node Affinity** (`requiredDuringScheduling`) | Fixar um processo/Pod em CPUs/nodes específicos |
| `nice` / preferência de CPU | **Node Affinity** (`preferredDuringScheduling`) | Preferir certas CPUs/nodes mas permitir fallback |
| Co-localização NUMA | **Pod Affinity** | Co-localizar processos/Pods relacionados no mesmo node |
| Separação de processos entre CPUs | **Pod Anti-Affinity** | Manter processos/Pods em nodes diferentes |
| Balanceamento de carga entre nodes NUMA | **Topology Spread Constraints** | Distribuir processos/Pods uniformemente pela topologia |
| Arquivos unit do `systemd` em disco | **Static Pods** | kubelet monitora um diretório e gerencia o ciclo de vida do Pod diretamente |
| `ulimit` / limites de recursos por usuário | **ResourceQuota** | Limitar recursos totais por namespace |
| `ulimit` padrão para um grupo de usuários | **LimitRange** | Valores padrão e mínimo/máximo de recursos por container |
| Mínimo de instâncias durante manutenção | **PodDisruptionBudget** | Garantir mínimo de Pods disponíveis durante interrupções voluntárias |
| `nice -n 10` / `ionice` | **Resource requests/limits** | Prioridade e limites de CPU/memória por container |
| `/proc/sys/kernel/threads-max` | **ResourceQuota `pods`** | Número máximo de processos/Pods em um namespace |

---

## Dicas

<details>
<summary><strong>Dica 1 — Apliquei taint em um node mas meu Pod com toleration ainda não é alocado lá</strong></summary>

Tolerations *permitem* o agendamento em um node com taint mas não *forçam*. O scheduler ainda pode preferir nodes sem taint. Para forçar um Pod em um node específico, combine uma toleration com nodeAffinity ou use `nodeName`.

```bash
# Verifique os taints do node
kubectl describe node fasthack-worker2 | grep Taints

# Verifique as tolerations do Pod
kubectl get pod tolerant-pod -o jsonpath='{.spec.tolerations}'
```

</details>

<details>
<summary><strong>Dica 2 — Meu Pod com node affinity obrigatória está travado em Pending</strong></summary>

As labels do node devem corresponder exatamente. Verifique quais labels existem:

```bash
kubectl get nodes --show-labels
```

Verifique se a expressão de affinity no spec do seu Pod corresponde à chave e valor da label no node alvo.

</details>

<details>
<summary><strong>Dica 3 — Como encontro o caminho do static Pod no Kind?</strong></summary>

O arquivo de configuração do kubelet nos nodes Kind está em `/var/lib/kubelet/config.yaml`. Acesse-o com:

```bash
docker exec fasthack-control-plane cat /var/lib/kubelet/config.yaml | grep staticPodPath
```

O padrão é `/etc/kubernetes/manifests`.

</details>

<details>
<summary><strong>Dica 4 — Meu Pod foi rejeitado pela ResourceQuota</strong></summary>

Quando uma ResourceQuota existe em um namespace com quotas de CPU/memória, **todo** Pod deve especificar resource requests. Se não especificar, o API server rejeita. Por isso o LimitRange é útil — ele injeta os padrões.

Verifique a mensagem de erro:

```bash
kubectl describe quota -n quota-lab
```

</details>

<details>
<summary><strong>Dica 5 — kubectl drain está travado / não está progredindo</strong></summary>

O drain provavelmente está bloqueado por um PodDisruptionBudget. Verifique:

```bash
kubectl get pdb
kubectl get events --sort-by='.lastTimestamp'
```

Se `ALLOWED-DISRUPTIONS` é `0`, o drain não pode despejar nenhum Pod. Reduza `minAvailable` ou aumente as réplicas.

</details>

<details>
<summary><strong>Dica 6 — Qual a diferença entre topologySpreadConstraints e podAntiAffinity?</strong></summary>

- **podAntiAffinity** é binária: "não coloque dois Pods correspondentes no mesmo node" (obrigatória) ou "tente não colocar" (preferencial).
- **topologySpreadConstraints** oferece controle mais fino com `maxSkew` — permite até N Pods de diferença entre domínios de topologia, permitindo distribuição balanceada em vez de separação estrita um-por-node.

Use topologySpreadConstraints quando quiser *distribuição uniforme*, e podAntiAffinity quando quiser *separação estrita*.

</details>

---

## Recursos de Aprendizado

- [Taints and Tolerations](https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/)
- [Assigning Pods to Nodes (Node Affinity)](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/)
- [Pod Affinity & Anti-Affinity](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/#inter-pod-affinity-and-anti-affinity)
- [Topology Spread Constraints](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/)
- [Static Pods](https://kubernetes.io/docs/tasks/administer-cluster/static-pod/)
- [Resource Quotas](https://kubernetes.io/docs/concepts/policy/resource-quotas/)
- [Limit Ranges](https://kubernetes.io/docs/concepts/policy/limit-range/)
- [Pod Disruption Budgets](https://kubernetes.io/docs/tasks/run-application/configure-pdb/)
- [Managing Resources for Containers](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)
- [Kubernetes Scheduler](https://kubernetes.io/docs/concepts/scheduling-eviction/kube-scheduler/)

---

## Break & Fix Scenarios

### Scenario 1 — The Unschedulable Pod

A developer created a Pod but it's stuck in `Pending`. Diagnose and fix the issue.

```bash
kubectl run broken-schedule --image=nginx:stable --overrides='{
  "spec": {
    "affinity": {
      "nodeAffinity": {
        "requiredDuringSchedulingIgnoredDuringExecution": {
          "nodeSelectorTerms": [{
            "matchExpressions": [{
              "key": "accelerator",
              "operator": "In",
              "values": ["nvidia-tesla-v100"]
            }]
          }]
        }
      }
    }
  }
}'
```

**Tasks:**
1. Find out why the Pod is `Pending`
2. Fix it so the Pod gets scheduled (either add the label to a node or change the Pod spec)
3. Verify the Pod reaches `Running` status

### Scenario 2 — Quota Exhaustion

A team can't create new Pods in their namespace. Figure out why.

```bash
kubectl create namespace broken-quota
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tight-quota
  namespace: broken-quota
spec:
  hard:
    pods: "2"
    requests.cpu: 200m
    requests.memory: 128Mi
    limits.cpu: 400m
    limits.memory: 256Mi
EOF

kubectl run q1 --image=nginx:stable -n broken-quota \
  --overrides='{"spec":{"containers":[{"name":"q1","image":"nginx:stable","resources":{"requests":{"cpu":"100m","memory":"64Mi"},"limits":{"cpu":"200m","memory":"128Mi"}}}]}}'
kubectl run q2 --image=nginx:stable -n broken-quota \
  --overrides='{"spec":{"containers":[{"name":"q2","image":"nginx:stable","resources":{"requests":{"cpu":"100m","memory":"64Mi"},"limits":{"cpu":"200m","memory":"128Mi"}}}]}}'
```

Now try to create a third Pod:

```bash
kubectl run q3 --image=nginx:stable -n broken-quota \
  --overrides='{"spec":{"containers":[{"name":"q3","image":"nginx:stable","resources":{"requests":{"cpu":"50m","memory":"32Mi"},"limits":{"cpu":"100m","memory":"64Mi"}}}]}}'
```

**Tasks:**
1. Determine why the third Pod can't be created
2. Identify which quota limit is being hit
3. Fix the situation (increase the quota or free resources)

### Scenario 3 — Drain Blocked by PDB

An operator needs to drain a node for maintenance, but the drain is stuck.

```bash
kubectl create deployment drain-test --image=nginx:stable --replicas=2
kubectl apply -f - <<'EOF'
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: drain-test-pdb
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: drain-test
EOF
```

Now try:

```bash
kubectl drain fasthack-worker --ignore-daemonsets --delete-emptydir-data --timeout=30s
```

**Tasks:**
1. Determine why the drain is blocked
2. Identify the PDB that's preventing eviction
3. Fix the PDB to allow the drain to proceed (without reducing total replicas below a safe level)
4. Uncordon the node after maintenance
