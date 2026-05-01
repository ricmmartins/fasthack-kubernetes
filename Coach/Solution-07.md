# Solução 07 — Volumes e Persistência

[< Voltar para o Desafio](../Student/Challenge-07.md) | **[Home](README.md)**

## Pré-requisitos

Os alunos devem ter um cluster Kind em execução. O cluster do Desafio 06 (com configuração de Ingress) funciona bem — ele inclui a StorageClass `standard` por padrão.

```bash
# Verifique se o cluster está em execução e tem a StorageClass padrão
kubectl get nodes
kubectl get storageclass
```

Saída esperada da StorageClass:

```
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   false                  1h
```

> **Dica do Coach:** O Kind instala automaticamente o provisioner `rancher.io/local-path` e marca a StorageClass `standard` como padrão. É isso que habilita o provisionamento dinâmico nas Tarefas 3 e 4.

---

## Tarefa 1: Prove que o Armazenamento do Container é Efêmero

### Passo a passo

Salve como `ephemeral-demo.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: ephemeral-demo
spec:
  containers:
    - name: writer
      image: busybox:1.37
      command: ["sh", "-c", "mkdir -p /data && echo 'hello from ephemeral storage' > /data/message.txt && sleep 3600"]
```

```bash
# Crie o Pod
kubectl apply -f ephemeral-demo.yaml
kubectl wait --for=condition=ready pod/ephemeral-demo --timeout=60s
```

```bash
# Leia o arquivo — ele existe
kubectl exec ephemeral-demo -- cat /data/message.txt
```

Saída esperada:

```
hello from ephemeral storage
```

```bash
# Delete o Pod
kubectl delete pod ephemeral-demo
```

```bash
# Recrie o mesmo Pod
kubectl apply -f ephemeral-demo.yaml
kubectl wait --for=condition=ready pod/ephemeral-demo --timeout=60s
```

```bash
# Tente ler o arquivo novamente — ele desapareceu
kubectl exec ephemeral-demo -- cat /data/message.txt
```

Saída esperada:

```
hello from ephemeral storage
```

> **Espere — o arquivo ainda está lá?** Sim! O comando na spec do Pod *recria* o arquivo a cada início (`echo ... > /data/message.txt`). Para demonstrar corretamente o armazenamento efêmero, precisamos escrever dados *após* a criação do Pod e verificar se sobrevivem.

**Demonstração correta:**

```bash
# Delete o Pod se existir
kubectl delete pod ephemeral-demo --ignore-not-found

# Crie o Pod (desta vez apenas com sleep, sem escrita de arquivo)
kubectl apply -f ephemeral-demo.yaml
kubectl wait --for=condition=ready pod/ephemeral-demo --timeout=60s

# Escreva dados manualmente no container em execução
kubectl exec ephemeral-demo -- sh -c "echo 'data written at runtime' > /tmp/runtime.txt"

# Confirme que existe
kubectl exec ephemeral-demo -- cat /tmp/runtime.txt
```

Saída esperada:

```
data written at runtime
```

```bash
# Delete e recrie
kubectl delete pod ephemeral-demo
kubectl apply -f ephemeral-demo.yaml
kubectl wait --for=condition=ready pod/ephemeral-demo --timeout=60s

# O arquivo de runtime não existe mais
kubectl exec ephemeral-demo -- cat /tmp/runtime.txt
```

Saída esperada:

```
cat: can't open '/tmp/runtime.txt': No such file or directory
command terminated with exit code 1
```

### Verificação

- O arquivo criado em tempo de execução (`/tmp/runtime.txt`) desapareceu após a exclusão e recriação do Pod
- O arquivo escrito pelo comando do Pod (`/data/message.txt`) é recriado porque faz parte do comando de inicialização do container — mas são dados *novos*, não os *antigos*

> **Dica do Coach:** Esta é uma distinção importante. Ajude os alunos a entender: a camada de escrita é destruída quando o container é removido. O `command` na spec é executado novamente a cada vez. Dados reais (arquivos de banco de dados, uploads, logs) que não são recriados pelo comando de inicialização serão perdidos.

```bash
# Limpeza
kubectl delete pod ephemeral-demo
```

---

## Tarefa 2: PersistentVolume e PersistentVolumeClaim Manuais

### Passo a passo

**2a. Crie o PersistentVolume**

Salve como `manual-pv.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: manual-pv
spec:
  capacity:
    storage: 256Mi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  hostPath:
    path: /tmp/k8s-manual-pv
    type: DirectoryOrCreate
```

**2b. Crie o PersistentVolumeClaim**

Salve como `manual-pvc.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: manual-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 256Mi
  storageClassName: ""
```

> **Importante:** `storageClassName: ""` (string vazia) evita o provisionamento dinâmico e força a vinculação estática ao PV criado manualmente.

**2c. Crie um Pod que usa o PVC**

Salve como `pvc-demo.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pvc-demo
spec:
  containers:
    - name: writer
      image: busybox:1.37
      command: ["sh", "-c", "echo 'persistent data' > /data/message.txt && sleep 3600"]
      volumeMounts:
        - name: my-storage
          mountPath: /data
  volumes:
    - name: my-storage
      persistentVolumeClaim:
        claimName: manual-pvc
```

```bash
# Aplique na ordem: PV → PVC → Pod
kubectl apply -f manual-pv.yaml
kubectl apply -f manual-pvc.yaml
kubectl apply -f pvc-demo.yaml
kubectl wait --for=condition=ready pod/pvc-demo --timeout=60s
```

Saída esperada:

```
persistentvolume/manual-pv created
persistentvolumeclaim/manual-pvc created
pod/pvc-demo created
```

### Verificação

```bash
# Verifique se PV e PVC estão Bound
kubectl get pv,pvc
```

Saída esperada:

```
NAME                         CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                STORAGECLASS   AGE
persistentvolume/manual-pv   256Mi      RWO            Retain           Bound    default/manual-pvc                  30s

NAME                               STATUS   VOLUME      CAPACITY   ACCESS MODES   STORAGECLASS   AGE
persistentvolumeclaim/manual-pvc   Bound    manual-pv   256Mi      RWO                           25s
```

```bash
# Verifique se os dados existem
kubectl exec pvc-demo -- cat /data/message.txt
```

Saída esperada:

```
persistent data
```

```bash
# Delete o Pod (NÃO o PVC)
kubectl delete pod pvc-demo

# Recrie o Pod
kubectl apply -f pvc-demo.yaml
kubectl wait --for=condition=ready pod/pvc-demo --timeout=60s

# Os dados sobrevivem!
kubectl exec pvc-demo -- cat /data/message.txt
```

Saída esperada:

```
persistent data
```

```bash
# Inspecione os detalhes do PV
kubectl describe pv manual-pv
```

Procure por:
- `Source.Path: /tmp/k8s-manual-pv` — o diretório real no nó Kind
- `Status: Bound`
- `Claim: default/manual-pvc`

> **Dica do Coach:** Volumes `hostPath` armazenam dados no sistema de arquivos do nó. No Kind, o "nó" é um container Docker. Os alunos podem verificar com: `docker exec -it fasthack-control-plane ls -la /tmp/k8s-manual-pv/`

```bash
# Limpeza
kubectl delete pod pvc-demo
kubectl delete pvc manual-pvc
kubectl delete pv manual-pv
```

---

## Tarefa 3: StatefulSet com volumeClaimTemplates

### Passo a passo

**3a. Crie o Service headless**

Salve como `redis-headless-svc.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: redis
spec:
  clusterIP: None
  selector:
    app: redis
  ports:
    - port: 6379
```

**3b. Crie o StatefulSet**

Salve como `redis-statefulset.yaml`:

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: redis
spec:
  serviceName: redis
  replicas: 2
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
        - name: redis
          image: redis:7-alpine
          ports:
            - containerPort: 6379
          volumeMounts:
            - name: redis-data
              mountPath: /data
  volumeClaimTemplates:
    - metadata:
        name: redis-data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 128Mi
```

> **Importante:** O Service headless deve ser criado **antes** do StatefulSet, porque o StatefulSet o referencia via `serviceName`.

```bash
kubectl apply -f redis-headless-svc.yaml
kubectl apply -f redis-statefulset.yaml
```

Saída esperada:

```
service/redis created
statefulset.apps/redis created
```

```bash
# Observe os Pods iniciando EM ORDEM (redis-0, depois redis-1)
kubectl get pods -l app=redis -w
```

Saída esperada (ao longo de ~30 segundos):

```
NAME      READY   STATUS              RESTARTS   AGE
redis-0   0/1     ContainerCreating   0          2s
redis-0   1/1     Running             0          5s
redis-1   0/1     Pending             0          0s
redis-1   0/1     ContainerCreating   0          1s
redis-1   1/1     Running             0          4s
```

> Pressione `Ctrl+C` para parar de acompanhar.

### Verificação

```bash
# Verifique os PVCs — um por réplica
kubectl get pvc
```

Saída esperada:

```
NAME                   STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
redis-data-redis-0     Bound    pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   128Mi      RWO            standard       30s
redis-data-redis-1     Bound    pvc-yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy   128Mi      RWO            standard       25s
```

> **Ponto-chave:** Cada nome de PVC segue o padrão `<nome-do-volumeClaimTemplate>-<nome-do-statefulset>-<ordinal>`. Isso é automático.

```bash
# Escreva dados no redis-0
kubectl exec redis-0 -- redis-cli SET mykey "hello from redis-0"
```

Saída esperada:

```
OK
```

```bash
# Leia de volta
kubectl exec redis-0 -- redis-cli GET mykey
```

Saída esperada:

```
"hello from redis-0"
```

```bash
# Delete redis-0 — o controller do StatefulSet irá recriá-lo
kubectl delete pod redis-0

# Aguarde ele voltar
kubectl wait --for=condition=ready pod/redis-0 --timeout=60s
```

```bash
# Os dados sobrevivem porque o PVC persiste!
kubectl exec redis-0 -- redis-cli GET mykey
```

Saída esperada:

```
"hello from redis-0"
```

```bash
# Verifique que redis-1 tem armazenamento INDEPENDENTE (sem dados do redis-0)
kubectl exec redis-1 -- redis-cli GET mykey
```

Saída esperada:

```
(nil)
```

```bash
# Mostre nomes DNS estáveis via Service headless
kubectl run tmp-dns --rm -it --restart=Never --image=busybox:stable -- nslookup redis-0.redis
```

Saída esperada:

```
Name:      redis-0.redis.default.svc.cluster.local
Address:   10.244.x.x
```

> **Dica do Coach:** Explique por que StatefulSets existem: Deployments tratam todas as réplicas como intercambiáveis — elas compartilham o mesmo PVC. StatefulSets dão a cada réplica uma identidade única (hostname estável, PVC próprio). Isso é essencial para bancos de dados, filas de mensagens e qualquer carga de trabalho onde cada instância possui dados distintos.

```bash
# Limpeza (PVCs NÃO são deletados quando o StatefulSet é deletado!)
kubectl delete statefulset redis
kubectl delete svc redis
kubectl get pvc  # PVCs ainda existem — isso é por design
kubectl delete pvc redis-data-redis-0 redis-data-redis-1
```

---

## Tarefa 4: Provisionamento Dinâmico com StorageClass

### Passo a passo

```bash
# Primeiro, veja quais StorageClasses estão disponíveis
kubectl get storageclass
```

Saída esperada:

```
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   false                  2h
```

Salve como `dynamic-pvc.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: dynamic-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 128Mi
  storageClassName: standard
```

Salve como `dynamic-demo.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: dynamic-demo
spec:
  containers:
    - name: app
      image: busybox:1.37
      command: ["sh", "-c", "echo 'dynamically provisioned!' > /data/hello.txt && sleep 3600"]
      volumeMounts:
        - name: dynamic-vol
          mountPath: /data
  volumes:
    - name: dynamic-vol
      persistentVolumeClaim:
        claimName: dynamic-pvc
```

```bash
kubectl apply -f dynamic-pvc.yaml
```

```bash
# Verifique o status do PVC — estará em Pending (WaitForFirstConsumer)
kubectl get pvc dynamic-pvc
```

Saída esperada:

```
NAME          STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
dynamic-pvc   Pending                                      standard       5s
```

> **Dica do Coach:** Isso é esperado! A StorageClass `standard` usa `volumeBindingMode: WaitForFirstConsumer`, significando que o PV NÃO é criado até que um Pod realmente referencie o PVC. Isso evita conflitos de agendamento em clusters multi-nó.

```bash
# Agora crie o Pod — isso dispara o provisionamento do PV
kubectl apply -f dynamic-demo.yaml
kubectl wait --for=condition=ready pod/dynamic-demo --timeout=60s
```

### Verificação

```bash
# O PVC agora está Bound e um PV foi criado automaticamente
kubectl get pv
```

Saída esperada:

```
NAME                                       CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                 STORAGECLASS   AGE
pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   128Mi      RWO            Delete           Bound    default/dynamic-pvc   standard       10s
```

```bash
kubectl get pvc dynamic-pvc
```

Saída esperada:

```
NAME          STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
dynamic-pvc   Bound    pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   128Mi      RWO            standard       30s
```

```bash
# Verifique se os dados foram escritos
kubectl exec dynamic-demo -- cat /data/hello.txt
```

Saída esperada:

```
dynamically provisioned!
```

```bash
# Mostre onde o Kind armazena os dados no nó
kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.hostPath.path}{"\n"}{end}'
```

Saída esperada: mostra o caminho sob `/var/local-path-provisioner/` no nó Kind.

```bash
# Opcional: espie dentro do container do nó Kind
docker exec -it fasthack-control-plane ls -la /var/local-path-provisioner/
```

> **Dica do Coach:** Compare Tarefa 2 (PV/PVC manual) vs Tarefa 4 (dinâmico). Manual: você cria ambos PV e PVC. Dinâmico: você só cria o PVC e o provisioner da StorageClass cria o PV automaticamente. Em produção, provisionamento dinâmico é a norma — ninguém cria PVs manualmente para cada aplicação.

```bash
# Limpeza
kubectl delete pod dynamic-demo
kubectl delete pvc dynamic-pvc
# O PV é auto-deletado porque reclaimPolicy é Delete
kubectl get pv  # deve ter desaparecido
```

---

## Tarefa 5: Padrão Sidecar com emptyDir

### Passo a passo

Salve como `sidecar-demo.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: sidecar-demo
spec:
  containers:
    - name: producer
      image: busybox:1.37
      command: ["sh", "-c", "while true; do date >> /shared/log.txt; sleep 5; done"]
      volumeMounts:
        - name: shared-data
          mountPath: /shared
    - name: consumer
      image: busybox:1.37
      command: ["sh", "-c", "tail -f /shared/log.txt"]
      volumeMounts:
        - name: shared-data
          mountPath: /shared
  volumes:
    - name: shared-data
      emptyDir: {}
```

```bash
kubectl apply -f sidecar-demo.yaml
kubectl wait --for=condition=ready pod/sidecar-demo --timeout=60s
```

### Verificação

```bash
# Veja timestamps ao vivo do producer via o tail -f do consumer
kubectl logs sidecar-demo -c consumer --tail=5
```

Saída esperada (timestamps irão variar):

```
Mon Jun 16 14:00:00 UTC 2025
Mon Jun 16 14:00:05 UTC 2025
Mon Jun 16 14:00:10 UTC 2025
Mon Jun 16 14:00:15 UTC 2025
Mon Jun 16 14:00:20 UTC 2025
```

```bash
# Acompanhe os logs ao vivo (Ctrl+C para parar)
kubectl logs sidecar-demo -c consumer -f
```

Novos timestamps devem aparecer a cada 5 segundos.

```bash
# Verifique que ambos os containers veem o mesmo arquivo
kubectl exec sidecar-demo -c producer -- wc -l /shared/log.txt
kubectl exec sidecar-demo -c consumer -- wc -l /shared/log.txt
```

Ambos devem mostrar a mesma contagem de linhas (crescendo ao longo do tempo).

```bash
# Prove que emptyDir é efêmero — delete e recrie
kubectl delete pod sidecar-demo
kubectl apply -f sidecar-demo.yaml
kubectl wait --for=condition=ready pod/sidecar-demo --timeout=60s

# O consumer começa com dados novos — logs antigos desapareceram
kubectl logs sidecar-demo -c consumer --tail=3
```

Saída esperada: apenas 1-3 novos timestamps — nenhum dado antigo mantido.

> **Dica do Coach:** `emptyDir` é o equivalente Kubernetes de um diretório `/tmp` compartilhado entre processos. É perfeito para:
> - Coletores de log sidecar (como esta demo)
> - Diretórios de cache compartilhados entre init containers e containers da app
> - Espaço temporário para computação
>
> NÃO é adequado para dados que devem sobreviver à exclusão do Pod — use um PVC para isso.

```bash
# Limpeza
kubectl delete pod sidecar-demo
```

---

## Problemas Comuns

| Problema | Causa Provável | Correção |
|---------|-------------|-----|
| PVC preso em `Pending` | `storageClassName` não corresponde a nenhuma StorageClass | Use `standard` (padrão do Kind) ou `""` para vinculação manual |
| PVC preso em `Pending` (dinâmico) | `WaitForFirstConsumer` — nenhum Pod criado ainda | Crie um Pod que referencie o PVC |
| PVC preso em `Pending` (manual) | Capacidade do PV < request do PVC, ou accessModes incompatíveis | Verifique `kubectl describe pvc <name>` seção Events |
| Pod preso em `ContainerCreating` | `claimName` do PVC referencia um PVC inexistente | `kubectl describe pod <name>` — procure "persistentvolumeclaim not found" |
| Pods do StatefulSet não iniciam | Service headless não criado antes do StatefulSet | Crie o Service headless (`clusterIP: None`) primeiro |
| Pods do StatefulSet iniciam mas dados são perdidos | Usando `emptyDir` em vez de `volumeClaimTemplates` | Substitua `emptyDir` por `volumeClaimTemplates` na spec do StatefulSet |
| Comando `redis-cli` não encontrado | Imagem Redis errada | Use `redis:7-alpine` que inclui `redis-cli` |
| PV não auto-deletado após exclusão do PVC | `reclaimPolicy: Retain` no PV criado manualmente | Delete manualmente o PV: `kubectl delete pv manual-pv` |
| `local-path-provisioner` não funciona | Pod não está no namespace kube-system | `kubectl -n local-path-storage get pods` (Kind o coloca em seu próprio namespace) |

> **Dicas de coaching para este desafio:**
>
> 1. **A analogia do fstab funciona muito bem aqui:** PV = o dispositivo de bloco (`/dev/sdb1`), PVC = a requisição de montagem (`mount /dev/sdb1 /mnt/data`), StorageClass = a configuração do volume group LVM que auto-cria volumes lógicos sob demanda.
>
> 2. **Alunos frequentemente confundem o comportamento de PVC do StatefulSet:** Quando você deleta um StatefulSet, os PVCs intencionalmente NÃO são deletados. Isso é um recurso de segurança — você não perde dados do banco de dados apenas porque fez scale down ou redeployment. Os alunos devem deletar PVCs manualmente se quiserem recuperar o armazenamento.
>
> 3. **Pergunta-chave para os alunos:** "Quando você usaria `emptyDir` vs um PVC?" Resposta: `emptyDir` para dados temporários/cache/scratch que podem ser regenerados. PVC para dados que devem sobreviver reinícios do Pod (bancos de dados, uploads, estado).
