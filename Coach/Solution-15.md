# Solução 15 — Pod Scheduling & Resource Management

[< Solução Anterior](Solution-14.md) - **[Home](README.md)** - [Próxima Solução >](Solution-16.md)

---

> **Nota do Coach:** Este desafio cobre tópicos de scheduling e gerenciamento de recursos do CKA/CKAD. Requer um cluster Kind com 3 nodes. Se os alunos estiverem entrando no meio do hackathon, certifique-se de que executem a Tarefa 0 primeiro. O exercício de static Pod (Tarefa 5) usa `docker exec` para acessar os nodes do Kind — garanta que o Docker esteja rodando.

> **Tempo estimado:** 75–90 minutos

---

## Tarefa 0: Criar um Cluster Kind com 3 Nodes

### Passo a passo

Salve `kind-scheduling.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

```bash
kind delete cluster --name fasthack 2>/dev/null
kind create cluster --name fasthack --config kind-scheduling.yaml
```

Saída esperada (últimas linhas):

```
Set kubectl context to "kind-fasthack"
You can now use your cluster with:

kubectl cluster-info --context kind-fasthack
```

### Verificação

```bash
kubectl get nodes
```

Esperado:

```
NAME                     STATUS   ROLES           AGE   VERSION
fasthack-control-plane   Ready    control-plane   60s   v1.36.x
fasthack-worker          Ready    <none>          40s   v1.36.x
fasthack-worker2         Ready    <none>          40s   v1.36.x
```

Adicione labels aos worker nodes:

```bash
kubectl label node fasthack-worker disk=ssd zone=us-east-1a
kubectl label node fasthack-worker2 disk=hdd zone=us-east-1b
```

Esperado:

```
node/fasthack-worker labeled
node/fasthack-worker2 labeled
```

Verifique os labels:

```bash
kubectl get nodes --show-labels | grep -E "disk=|zone="
```

> **Dica para o Coach:** Se os alunos já tiverem um cluster Kind, precisarão deletá-lo e recriá-lo. O cluster de node único existente não funcionará para os exercícios de scheduling.

---

## Tarefa 1: Taints & Tolerations

### Passo a passo

Aplique o taint:

```bash
kubectl taint nodes fasthack-worker2 environment=production:NoSchedule
```

Esperado:

```
node/fasthack-worker2 tainted
```

Verifique o taint:

```bash
kubectl describe node fasthack-worker2 | grep -A 2 Taints
```

Esperado:

```
Taints:             environment=production:NoSchedule
```

Crie o Pod **sem** toleration:

```yaml
# no-toleration-pod.yaml
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

Esperado: O Pod é agendado no `fasthack-worker` (não no `fasthack-worker2`):

```
NAME             READY   STATUS    RESTARTS   AGE   IP           NODE              
no-toleration    1/1     Running   0          10s   10.244.1.x   fasthack-worker
```

Crie o Pod **com** toleration:

```yaml
# tolerant-pod.yaml
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

Esperado: O Pod pode cair em qualquer um dos workers — o toleration *permite* que ele vá para `fasthack-worker2`, mas não o força a ir para lá.

### Verificação

```bash
kubectl describe node fasthack-worker2 | grep -A 3 Taints
```

Esperado:

```
Taints:             environment=production:NoSchedule
```

Limpeza:

```bash
kubectl delete pod no-toleration tolerant-pod
```

> **Dica para o Coach:** Um equívoco comum é que tolerations *atraem* Pods para nodes com taint. Eles não fazem isso — apenas *permitem* o scheduling. Para forçar um Pod em um node com taint, combine um toleration com node affinity ou `nodeName`.

---

## Tarefa 2: Node Affinity

### Passo a passo

**Affinity obrigatória:**

```yaml
# required-affinity.yaml
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

Esperado: O Pod roda no `fasthack-worker` (o único node com `disk=ssd`):

```
NAME           READY   STATUS    RESTARTS   AGE   IP           NODE
ssd-required   1/1     Running   0          10s   10.244.1.x   fasthack-worker
```

**Affinity preferencial (label inexistente):**

```yaml
# preferred-affinity.yaml
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

Esperado: O Pod está Running em qualquer worker — a regra preferencial é uma sugestão suave, não um requisito rígido.

**Affinity obrigatória impossível:**

```yaml
# impossible-affinity.yaml
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

Esperado: O Pod fica `Pending`:

```
NAME              READY   STATUS    RESTARTS   AGE
impossible-pod    0/1     Pending   0          30s
```

Verifique o motivo:

```bash
kubectl describe pod impossible-pod | grep -A 5 Events
```

Evento esperado:

```
Warning  FailedScheduling  ... 0/3 nodes are available: 1 node(s) had untainted ... 2 node(s) didn't match Pod's node affinity/selector ...
```

### Verificação

Limpeza:

```bash
kubectl delete pod ssd-required nvme-preferred impossible-pod
```

---

## Tarefa 3: Pod Affinity & Anti-Affinity

### Passo a passo

**Faça deploy do Pod de cache:**

```yaml
# cache-pod.yaml
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

Anote o nome do node (ex.: `fasthack-worker`).

**Pod com podAffinity:**

```yaml
# web-with-affinity.yaml
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

Esperado: `web-near-cache` está no **mesmo node** que `cache`:

```
NAME              READY   STATUS    RESTARTS   AGE   IP           NODE
cache             1/1     Running   0          30s   10.244.1.2   fasthack-worker
web-near-cache    1/1     Running   0          10s   10.244.1.3   fasthack-worker
```

**Deployment com podAntiAffinity:**

```yaml
# spread-deployment.yaml
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

Esperado: Cada réplica em um worker **diferente**:

```
NAME                         READY   STATUS    RESTARTS   AGE   NODE
spread-web-xxxxxxxxx-aaaaa   1/1     Running   0          15s   fasthack-worker
spread-web-xxxxxxxxx-bbbbb   1/1     Running   0          15s   fasthack-worker2
```

> **Nota:** O taint da Tarefa 1 ainda está no `fasthack-worker2`. Se uma réplica ficar Pending, o aluno precisa removê-lo: `kubectl taint nodes fasthack-worker2 environment=production:NoSchedule-`. Alternativamente, adicione um toleration ao spec do Deployment.

Escale para 3 e observe o Pod Pending:

```bash
kubectl scale deployment spread-web --replicas=3
kubectl get pods -l app=spread-web -o wide
```

Esperado: O terceiro Pod fica `Pending` — apenas 2 worker nodes disponíveis, e o anti-affinity impede dois Pods no mesmo node.

### Verificação

Reduza a escala e faça a limpeza:

```bash
kubectl scale deployment spread-web --replicas=2
kubectl delete pod cache web-near-cache
kubectl delete deployment spread-web
```

---

## Tarefa 4: Topology Spread Constraints

### Passo a passo

Remova o taint da Tarefa 1:

```bash
kubectl taint nodes fasthack-worker2 environment=production:NoSchedule-
```

Esperado:

```
node/fasthack-worker2 untainted
```

Crie o Deployment:

```yaml
# topology-spread.yaml
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

Esperado: 2 Pods em cada worker node:

```
NAME                            READY   STATUS    NODE
balanced-web-xxxxxxxxx-aaaa     1/1     Running   fasthack-worker
balanced-web-xxxxxxxxx-bbbb     1/1     Running   fasthack-worker
balanced-web-xxxxxxxxx-cccc     1/1     Running   fasthack-worker2
balanced-web-xxxxxxxxx-dddd     1/1     Running   fasthack-worker2
```

> **Dica para o Coach:** `maxSkew: 1` significa que a diferença na contagem de Pods entre quaisquer dois domínios de topologia (nodes) pode ser no máximo 1. Com 4 Pods e 2 workers, a única distribuição válida é 2+2.

Altere para `ScheduleAnyway`:

```bash
kubectl patch deployment balanced-web --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/topologySpreadConstraints/0/whenUnsatisfiable","value":"ScheduleAnyway"}]'

kubectl rollout status deployment balanced-web
kubectl get pods -l app=balanced-web -o wide
```

Esperado: Mesma distribuição (o scheduler ainda tenta balancear), mas agora ele não deixaria Pods `Pending` se o balanceamento perfeito fosse impossível.

### Verificação

Limpeza:

```bash
kubectl delete deployment balanced-web
```

---

## Tarefa 5: Static Pods

### Passo a passo

Encontre o caminho do static Pod:

```bash
docker exec fasthack-control-plane cat /var/lib/kubelet/config.yaml | grep staticPodPath
```

Esperado:

```
staticPodPath: /etc/kubernetes/manifests
```

Crie o manifesto do static Pod:

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

Aguarde 10–20 segundos para o kubelet detectar o novo arquivo.

### Verificação

```bash
kubectl get pods -A | grep static-web
```

Esperado:

```
default     static-web-fasthack-control-plane   1/1     Running   0          15s
```

O nome do Pod tem o hostname do node adicionado — este é o **mirror Pod** criado pelo kubelet.

Tente deletá-lo:

```bash
kubectl delete pod static-web-fasthack-control-plane -n default
```

Aguarde alguns segundos:

```bash
kubectl get pods | grep static-web
```

Esperado: O Pod reaparece! O kubelet o recria porque o arquivo de manifesto ainda existe.

Delete o arquivo de manifesto para realmente remover o Pod:

```bash
docker exec fasthack-control-plane rm /etc/kubernetes/manifests/static-web.yaml
```

Aguarde 10–20 segundos:

```bash
kubectl get pods | grep static-web
```

Esperado: Nenhum resultado — o Pod foi removido.

> **Dica para o Coach:** Explique que static Pods são a maneira como os componentes do control plane rodam em clusters Kind e kubeadm. Verifique `/etc/kubernetes/manifests/` no node do control plane para ver `etcd.yaml`, `kube-apiserver.yaml`, `kube-controller-manager.yaml` e `kube-scheduler.yaml`.
>
> ```bash
> docker exec fasthack-control-plane ls /etc/kubernetes/manifests/
> ```

---

## Tarefa 6: ResourceQuotas e LimitRanges

### Passo a passo

Crie o namespace:

```bash
kubectl create namespace quota-lab
```

Crie a ResourceQuota:

```yaml
# resource-quota.yaml
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

Esperado:

```
Name:            compute-quota
Namespace:       quota-lab
Resource         Used  Hard
--------         ----  ----
limits.cpu       0     4
limits.memory    0     2Gi
pods             0     5
requests.cpu     0     2
requests.memory  0     1Gi
```

Crie a LimitRange:

```yaml
# limit-range.yaml
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

Esperado:

```
Type        Resource  Min   Max    Default Request  Default Limit  ...
----        --------  ---   ---    ---------------  -------------  
Container   cpu       50m   1      100m             500m           
Container   memory    64Mi  512Mi  128Mi            256Mi          
```

Crie um Pod sem especificar recursos:

```bash
kubectl run auto-limits --image=nginx:stable -n quota-lab
```

Verifique se a LimitRange injetou os valores padrão:

```bash
kubectl get pod auto-limits -n quota-lab -o jsonpath='{.spec.containers[0].resources}' | python3 -m json.tool
```

Esperado:

```json
{
    "limits": {
        "cpu": "500m",
        "memory": "256Mi"
    },
    "requests": {
        "cpu": "100m",
        "memory": "128Mi"
    }
}
```

Tente criar um Pod que exceda o máximo da LimitRange:

```yaml
# greedy-pod.yaml
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

Erro esperado:

```
Error from server (Forbidden): ... cpu max limit is 1, but spec is 2
```

Verifique o uso da quota:

```bash
kubectl describe quota compute-quota -n quota-lab
```

Esperado: Mostra os recursos consumidos pelo Pod `auto-limits`:

```
Resource         Used   Hard
--------         ----   ----
limits.cpu       500m   4
limits.memory    256Mi  2Gi
pods             1      5
requests.cpu     100m   2
requests.memory  128Mi  1Gi
```

> **Dica para o Coach:** Uma percepção importante — quando uma ResourceQuota com CPU/memória está ativa em um namespace mas nenhuma LimitRange existe, Pods **sem** requests/limits de recursos explícitos serão rejeitados. A LimitRange atua como uma rede de segurança ao injetar valores padrão.

---

## Tarefa 7: PodDisruptionBudgets

### Passo a passo

Crie o Deployment:

```yaml
# pdb-app.yaml
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

Esperado: 3 Pods rodando, distribuídos entre os worker nodes.

Crie o PDB:

```yaml
# pdb.yaml
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

Esperado:

```
NAME      MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
pdb-web   2               N/A               1                     5s
```

`ALLOWED-DISRUPTIONS: 1` significa que o drain pode evacuar no máximo 1 Pod por vez (3 atuais − 2 minAvailable = 1).

Faça drain de um worker node:

```bash
kubectl drain fasthack-worker --ignore-daemonsets --delete-emptydir-data
```

A saída esperada inclui:

```
evicting pod default/pdb-web-xxxxxxxxx-xxxxx
pod/pdb-web-xxxxxxxxx-xxxxx evicted
node/fasthack-worker drained
```

Verifique se os Pods ainda estão rodando (pelo menos 2):

```bash
kubectl get pods -l app=pdb-web -o wide
kubectl get pdb
```

Esperado: Todas as 3 réplicas devem estar Running (os Pods evacuados são reagendados no `fasthack-worker2`). O PDB garantiu que pelo menos 2 estivessem disponíveis durante todo o drain.

Desfaça o cordon:

```bash
kubectl uncordon fasthack-worker
```

Esperado:

```
node/fasthack-worker uncordoned
```

**Bônus — bloquear drain com minAvailable=3:**

```bash
kubectl patch pdb pdb-web --type=merge -p '{"spec":{"minAvailable":3}}'
kubectl get pdb
```

Esperado:

```
NAME      MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
pdb-web   3               N/A               0                     2m
```

`ALLOWED-DISRUPTIONS: 0` — o drain ficará bloqueado:

```bash
kubectl drain fasthack-worker --ignore-daemonsets --delete-emptydir-data --timeout=30s
```

Esperado: O drain expira após 30 segundos com um erro sobre o PDB.

Restaure:

```bash
kubectl uncordon fasthack-worker
kubectl patch pdb pdb-web --type=merge -p '{"spec":{"minAvailable":2}}'
```

---

## Soluções Break & Fix

### Cenário 1 — O Pod Não Agendável

**Diagnóstico:**

```bash
kubectl get pod broken-schedule
kubectl describe pod broken-schedule | grep -A 10 Events
```

Evento esperado:

```
Warning  FailedScheduling  ... 0/3 nodes are available: ... didn't match Pod's node affinity/selector
```

O Pod requer `accelerator=nvidia-tesla-v100` — nenhum node possui esse label.

**Correção (opção A — adicionar o label):**

```bash
kubectl label node fasthack-worker accelerator=nvidia-tesla-v100
```

Aguarde alguns segundos — o Pod deve ficar `Running`:

```bash
kubectl get pod broken-schedule -o wide
```

**Correção (opção B — recriar sem affinity):**

```bash
kubectl delete pod broken-schedule
kubectl run broken-schedule --image=nginx:stable
```

**Limpeza:**

```bash
kubectl label node fasthack-worker accelerator-
kubectl delete pod broken-schedule
```

### Cenário 2 — Exaustão de Quota

**Diagnóstico:**

```bash
kubectl describe quota tight-quota -n broken-quota
```

Esperado:

```
Resource         Used   Hard
--------         ----   ----
pods             2      2
requests.cpu     200m   200m
requests.memory  128Mi  128Mi
limits.cpu       400m   400m
limits.memory    256Mi  256Mi
```

Todos os recursos estão totalmente consumidos. O limite `pods: 2` sozinho já bloquearia um terceiro Pod.

**Correção — aumentar a quota:**

```bash
kubectl patch resourcequota tight-quota -n broken-quota --type=merge \
  -p '{"spec":{"hard":{"pods":"5","requests.cpu":"500m","requests.memory":"256Mi","limits.cpu":"1","limits.memory":"512Mi"}}}'
```

Agora tente novamente:

```bash
kubectl run q3 --image=nginx:stable -n broken-quota \
  --overrides='{"spec":{"containers":[{"name":"q3","image":"nginx:stable","resources":{"requests":{"cpu":"50m","memory":"32Mi"},"limits":{"cpu":"100m","memory":"64Mi"}}}]}}'
```

Esperado: Pod é criado com sucesso.

**Limpeza:**

```bash
kubectl delete namespace broken-quota
```

### Cenário 3 — Drain Bloqueado pelo PDB

**Diagnóstico:**

```bash
kubectl get pdb
```

Esperado:

```
NAME             MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
drain-test-pdb   2               N/A               0                     30s
```

`ALLOWED-DISRUPTIONS: 0` — O PDB requer 2 Pods disponíveis, mas há apenas 2 réplicas. Nenhum Pod pode ser evacuado sem violar o budget.

**Correção — diminuir minAvailable ou aumentar réplicas:**

Opção A — reduzir `minAvailable` para 1:

```bash
kubectl patch pdb drain-test-pdb --type=merge -p '{"spec":{"minAvailable":1}}'
```

Opção B — aumentar réplicas para 3:

```bash
kubectl scale deployment drain-test --replicas=3
```

Agora o drain funciona:

```bash
kubectl drain fasthack-worker --ignore-daemonsets --delete-emptydir-data
```

**Limpeza:**

```bash
kubectl uncordon fasthack-worker
kubectl delete deployment drain-test
kubectl delete pdb drain-test-pdb
```

---

## Limpeza Completa

Para resetar tudo após o desafio:

```bash
kubectl delete namespace quota-lab --ignore-not-found
kubectl delete deployment pdb-web --ignore-not-found
kubectl delete pdb pdb-web --ignore-not-found
kubectl taint nodes fasthack-worker2 environment=production:NoSchedule- 2>/dev/null
kubectl label node fasthack-worker disk- zone- accelerator- 2>/dev/null
kubectl label node fasthack-worker2 disk- zone- 2>/dev/null
```

Ou recrie o cluster do zero:

```bash
kind delete cluster --name fasthack
kind create cluster --name fasthack --config kind-scheduling.yaml
```

---

## Problemas Comuns

| Sintoma | Causa | Correção |
|---------|-------|----------|
| Pod preso em `Pending` após adicionar toleration | Toleration permite mas não força o scheduling; outros nodes podem ser preferidos | Combine toleration com `nodeAffinity` ou `nodeName` para forçar o posicionamento |
| `kubectl taint` diz "node not found" | Nome do node incorreto | Execute `kubectl get nodes` para verificar os nomes exatos (ex.: `fasthack-worker2` e não `worker-2`) |
| Pod com required affinity fica `Pending` | Nenhum node corresponde à expressão de label | Verifique os labels com `kubectl get nodes --show-labels` |
| Deployment com anti-affinity não escala para 3 | Apenas 2 worker nodes; anti-affinity `required` impede 2 Pods por node | Use anti-affinity `preferred` em vez de `required`, ou adicione mais nodes |
| `topologySpreadConstraints` não distribui uniformemente | `whenUnsatisfiable: ScheduleAnyway` permite desbalanceamento | Use `DoNotSchedule` para distribuição estrita |
| Static Pod não aparece | Kubelet ainda não escaneou ou YAML está inválido | Aguarde 20 segundos; verifique `docker exec fasthack-control-plane cat /etc/kubernetes/manifests/static-web.yaml` para validar a sintaxe |
| Static Pod mostra `CrashLoopBackOff` | Imagem ou comando do container inválido no manifesto | Corrija o arquivo YAML no node e aguarde o kubelet detectar as alterações |
| Pod rejeitado: "must specify requests/limits" | ResourceQuota requer CPU/memória mas o Pod não tem spec de recursos | Crie uma LimitRange para injetar valores padrão, ou adicione recursos explícitos ao Pod |
| Pod rejeitado: "exceeds max limit" | Limite de recursos do container excede o máximo da LimitRange | Reduza o limite de recursos do container para ficar dentro dos limites da LimitRange |
| `kubectl drain` bloqueado / expira | PDB `minAvailable` ≥ contagem atual de réplicas (0 disruptions permitidos) | Reduza `minAvailable`, use `maxUnavailable: 1` em vez disso, ou aumente as réplicas |
| `docker exec` falha no node Kind | Docker daemon não está rodando ou nome do container incorreto | Execute `docker ps` para verificar os containers Kind; os nomes correspondem ao cluster+node do Kind |
| Pods agendados no node control-plane inesperadamente | Taint do control-plane foi removido | Re-aplique o taint: `kubectl taint nodes fasthack-control-plane node-role.kubernetes.io/control-plane:NoSchedule` |

---

## Resumo de Conceitos-Chave para Coaches

```
Fluxo de Decisão de Scheduling:
                                                  
  Pod Criado ──▶ Fase de Filtragem ──▶ Fase de Pontuação ──▶ Fase de Binding
                     │                     │                │
              ┌──────┴──────┐       ┌──────┴──────┐       │
              │ Taints      │       │ Preferred   │   Pod vinculado
              │ Required    │       │   Affinity  │   ao node
              │   Affinity  │       │ Topology    │
              │ Resource    │       │   Spread    │
              │   Fit       │       │ Weights     │
              └─────────────┘       └─────────────┘
              (elimina nodes)    (classifica restantes)
```

| Mecanismo | Fase | Granularidade | Efeito |
|-----------|------|---------------|--------|
| Taints & Tolerations | Filtragem | Node → Pod | "Não venha aqui a menos que me tolere" |
| Required Node Affinity | Filtragem | Pod → Node | "Eu devo rodar em nodes com esses labels" |
| Preferred Node Affinity | Pontuação | Pod → Node | "Eu prefiro nodes com esses labels" |
| Required Pod Affinity | Filtragem | Pod → Pod | "Eu devo estar em um node perto do Pod X" |
| Required Pod Anti-Affinity | Filtragem | Pod → Pod | "Eu NÃO devo estar em um node com Pod X" |
| Topology Spread | Filtragem+Pontuação | Distribuição de Pods | "Distribua-me uniformemente pela topologia" |
| ResourceQuota | Admissão | Total do namespace | "O namespace não pode exceder X recursos totais" |
| LimitRange | Admissão | Por container | "Cada container deve estar dentro do mín/máx" |
| PDB | Evacuação | Grupo de Pods | "Mantenha pelo menos N Pods disponíveis" |
