# Solução 04 — Deployments e Rolling Updates

[< Voltar para o Desafio](../Student/Challenge-04.md) | **[Home](README.md)**

## Pré-verificação

Certifique-se de que os alunos tenham um cluster Kind em execução (idealmente o cluster multi-nó do Desafio 03):

```bash
kubectl get nodes
```

Saída esperada (nó único também funciona):

```
NAME                    STATUS   ROLES           AGE   VERSION
k8s-lab-control-plane   Ready    control-plane   30m   v1.33.0
k8s-lab-worker          Ready    <none>          30m   v1.33.0
k8s-lab-worker2         Ready    <none>          30m   v1.33.0
```

Limpe quaisquer Pods remanescentes de desafios anteriores:

```bash
kubectl delete pods --all 2>/dev/null
```

---

## Tarefa 1: Crie um Deployment com 3 Réplicas

### Passo a passo

Crie o arquivo de manifesto do Deployment `webapp-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp
spec:
  replicas: 3
  selector:
    matchLabels:
      app: webapp
  template:
    metadata:
      labels:
        app: webapp
    spec:
      containers:
        - name: nginx
          image: nginx:stable
          ports:
            - containerPort: 80
```

Aplique o Deployment:

```bash
kubectl apply -f webapp-deployment.yaml
```

Saída esperada:

```
deployment.apps/webapp created
```

**Verifique o Deployment:**

```bash
kubectl get deployment webapp
```

Saída esperada:

```
NAME     READY   UP-TO-DATE   AVAILABLE   AGE
webapp   3/3     3            3           30s
```

> **Nota para o Coach:** Explique as colunas:
> - `READY` — Pods prontos / réplicas desejadas
> - `UP-TO-DATE` — Pods executando o template mais recente
> - `AVAILABLE` — Pods disponíveis para servir tráfego

**Liste os Pods criados pelo Deployment:**

```bash
kubectl get pods -l app=webapp
```

Saída esperada:

```
NAME                      READY   STATUS    RESTARTS   AGE
webapp-xxxxxxxxxx-abcde   1/1     Running   0          45s
webapp-xxxxxxxxxx-fghij   1/1     Running   0          45s
webapp-xxxxxxxxxx-klmno   1/1     Running   0          45s
```

**Mostre o ReplicaSet gerenciando estes Pods:**

```bash
kubectl get replicaset -l app=webapp
```

Saída esperada:

```
NAME                DESIRED   CURRENT   READY   AGE
webapp-xxxxxxxxxx   3         3         3       1m
```

> **Nota para o Coach:** Explique a hierarquia: **Deployment** → **ReplicaSet** → **Pods**. O Deployment gerencia ReplicaSets, que gerenciam Pods. Os alunos nunca devem editar ReplicaSets diretamente.

**Demonstre a auto-recuperação — delete um Pod e observe-o voltar:**

```bash
# Obtenha o nome de um Pod
POD_NAME=$(kubectl get pods -l app=webapp -o jsonpath='{.items[0].metadata.name}')

# Delete-o
kubectl delete pod $POD_NAME

# Observe o Deployment recriá-lo imediatamente
kubectl get pods -l app=webapp -w
```

Saída esperada:

```
NAME                      READY   STATUS        RESTARTS   AGE
webapp-xxxxxxxxxx-abcde   1/1     Terminating   0          2m
webapp-xxxxxxxxxx-fghij   1/1     Running       0          2m
webapp-xxxxxxxxxx-klmno   1/1     Running       0          2m
webapp-xxxxxxxxxx-pqrst   0/1     Pending       0          1s
webapp-xxxxxxxxxx-pqrst   0/1     ContainerCreating   0    1s
webapp-xxxxxxxxxx-pqrst   1/1     Running       0          3s
```

Pressione `Ctrl+C` para parar de acompanhar.

> **Nota para o Coach:** Esta é a diferença-chave dos Pods sem controller do Desafio 02. O controller do Deployment detecta a réplica ausente e cria um substituto.

### Verificação

- `kubectl get deployment webapp` mostra `3/3` Ready
- `kubectl get pods -l app=webapp` mostra 3 Pods Running
- Deletar um Pod faz com que o Deployment crie automaticamente um substituto

---

## Tarefa 2: Escale o Deployment

### Passo a passo

**Escale para 5 réplicas:**

```bash
kubectl scale deployment webapp --replicas=5
```

Saída esperada:

```
deployment.apps/webapp scaled
```

Observe os novos Pods aparecerem:

```bash
kubectl get pods -l app=webapp
```

Saída esperada:

```
NAME                      READY   STATUS    RESTARTS   AGE
webapp-xxxxxxxxxx-abcde   1/1     Running   0          3m
webapp-xxxxxxxxxx-fghij   1/1     Running   0          3m
webapp-xxxxxxxxxx-klmno   1/1     Running   0          3m
webapp-xxxxxxxxxx-pqrst   1/1     Running   0          10s
webapp-xxxxxxxxxx-uvwxy   1/1     Running   0          10s
```

Confirme que o Deployment mostra 5 réplicas:

```bash
kubectl get deployment webapp
```

Saída esperada:

```
NAME     READY   UP-TO-DATE   AVAILABLE   AGE
webapp   5/5     5            5           4m
```

**Reduza para 3 réplicas:**

```bash
kubectl scale deployment webapp --replicas=3
```

Observe os Pods sendo terminados:

```bash
kubectl get pods -l app=webapp -w
```

Saída esperada:

```
NAME                      READY   STATUS        RESTARTS   AGE
webapp-xxxxxxxxxx-abcde   1/1     Running       0          5m
webapp-xxxxxxxxxx-fghij   1/1     Running       0          5m
webapp-xxxxxxxxxx-klmno   1/1     Running       0          5m
webapp-xxxxxxxxxx-pqrst   1/1     Terminating   0          2m
webapp-xxxxxxxxxx-uvwxy   1/1     Terminating   0          2m
```

Pressione `Ctrl+C` para parar de acompanhar.

Confirme que 3 réplicas permanecem:

```bash
kubectl get deployment webapp
```

Saída esperada:

```
NAME     READY   UP-TO-DATE   AVAILABLE   AGE
webapp   3/3     3            3           6m
```

### Verificação

- Após escalar para cima: `kubectl get deployment webapp` mostra `5/5`
- Após escalar para baixo: `kubectl get deployment webapp` mostra `3/3`
- Os Pods excedentes foram terminados graciosamente

---

## Tarefa 3: Realize um Rolling Update

### Passo a passo

**Atualize a imagem de `nginx:stable` para `nginx:alpine`:**

```bash
kubectl set image deployment/webapp nginx=nginx:alpine
```

Saída esperada:

```
deployment.apps/webapp image updated
```

**Acompanhe o progresso do rollout:**

```bash
kubectl rollout status deployment/webapp
```

Saída esperada:

```
Waiting for deployment "webapp" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "webapp" rollout to finish: 2 out of 3 new replicas have been updated...
Waiting for deployment "webapp" rollout to finish: 2 of 3 updated replicas are available...
deployment "webapp" successfully rolled out
```

**Observe a estratégia de rolling update — Pods antigos terminam enquanto novos Pods iniciam:**

```bash
kubectl get pods -l app=webapp
```

Saída esperada (todos os Pods devem ter novos nomes e AGE curto):

```
NAME                      READY   STATUS    RESTARTS   AGE
webapp-yyyyyyyyyy-aaaaa   1/1     Running   0          30s
webapp-yyyyyyyyyy-bbbbb   1/1     Running   0          25s
webapp-yyyyyyyyyy-ccccc   1/1     Running   0          20s
```

> **Nota para o Coach:** Observe que o hash do ReplicaSet mudou (`xxxxxxxxxx` → `yyyyyyyyyy`). Um rolling update cria um **novo** ReplicaSet, escala-o para cima e escala o antigo para baixo.

**Verifique se a imagem foi atualizada:**

```bash
kubectl describe deployment webapp | grep Image
```

Saída esperada:

```
    Image:        nginx:alpine
```

**Mostre os ReplicaSets — antigo e novo:**

```bash
kubectl get replicaset -l app=webapp
```

Saída esperada:

```
NAME                DESIRED   CURRENT   READY   AGE
webapp-xxxxxxxxxx   0         0         0       10m    # antigo - escalado para 0
webapp-yyyyyyyyyy   3         3         3       1m     # novo - ativo
```

> **Nota para o Coach:** O ReplicaSet antigo é mantido (escalado para 0) para permitir rollback. É assim que o Kubernetes rastreia o histórico de revisões.

**Verifique o histórico de rollout:**

```bash
kubectl rollout history deployment/webapp
```

Saída esperada:

```
deployment.apps/webapp
REVISION  CHANGE-CAUSE
1         <none>
2         <none>
```

### Verificação

- `kubectl rollout status deployment/webapp` reporta "successfully rolled out"
- `kubectl describe deployment webapp | grep Image` mostra `nginx:alpine`
- Dois ReplicaSets existem: o antigo escalado para 0, o novo com 3

---

## Tarefa 4: Rollback para a Versão Anterior

### Passo a passo

**Faça rollback para a revisão anterior:**

```bash
kubectl rollout undo deployment/webapp
```

Saída esperada:

```
deployment.apps/webapp rolled back
```

**Acompanhe o rollback completar:**

```bash
kubectl rollout status deployment/webapp
```

Saída esperada:

```
deployment "webapp" successfully rolled out
```

**Verifique se a imagem voltou para `nginx:stable`:**

```bash
kubectl describe deployment webapp | grep Image
```

Saída esperada:

```
    Image:        nginx:stable
```

**Verifique o histórico de rollout — uma nova revisão foi criada:**

```bash
kubectl rollout history deployment/webapp
```

Saída esperada:

```
deployment.apps/webapp
REVISION  CHANGE-CAUSE
2         <none>
3         <none>
```

> **Nota para o Coach:** A Revisão 1 desapareceu porque o rollback reutilizou seu template (o Kubernetes o renumera como revisão 3). A Revisão 2 é a versão `nginx:alpine`, ainda disponível para rollback se necessário.

### Verificação

- `kubectl describe deployment webapp | grep Image` mostra `nginx:stable`
- `kubectl rollout history deployment/webapp` mostra uma nova revisão

---

## Tarefa 5: Defina Resource Requests e Limits

### Passo a passo

Atualize o manifesto do Deployment para incluir restrições de recursos. Edite `webapp-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp
spec:
  replicas: 3
  selector:
    matchLabels:
      app: webapp
  template:
    metadata:
      labels:
        app: webapp
    spec:
      containers:
        - name: nginx
          image: nginx:stable
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "100m"
              memory: "128Mi"
```

> **Nota para o Coach:** Explique a diferença:
> - **requests** — os recursos mínimos que o scheduler garante ao Pod. Usados para decisões de agendamento (como reservar um assento em um voo).
> - **limits** — os recursos máximos que o container pode usar. Exceder limites de memória → OOMKill. Exceder limites de CPU → throttling.
> - `50m` CPU = 50 millicores = 5% de um núcleo de CPU.
> - `64Mi` memória = 64 mebibytes.

Aplique o manifesto atualizado:

```bash
kubectl apply -f webapp-deployment.yaml
```

Saída esperada:

```
deployment.apps/webapp configured
```

Isso dispara um rolling update porque o template do Pod mudou.

**Aguarde o rollout completar:**

```bash
kubectl rollout status deployment/webapp
```

**Verifique se os recursos estão definidos:**

```bash
kubectl describe deployment webapp
```

Procure a seção `Containers`:

```
  Containers:
   nginx:
    Image:      nginx:stable
    Port:       80/TCP
    Limits:
      cpu:     100m
      memory:  128Mi
    Requests:
      cpu:     50m
      memory:  64Mi
```

**Alternativamente, inspecione um Pod específico:**

```bash
POD_NAME=$(kubectl get pods -l app=webapp -o jsonpath='{.items[0].metadata.name}')
kubectl describe pod $POD_NAME | grep -A 6 "Limits\|Requests"
```

Saída esperada:

```
    Limits:
      cpu:     100m
      memory:  128Mi
    Requests:
      cpu:     50m
      memory:  64Mi
```

### Verificação

- `kubectl describe deployment webapp` mostra `Requests` e `Limits` sob a spec do container
- Todos os 3 Pods estão executando com as restrições de recursos aplicadas

---

## Limpeza

```bash
kubectl delete deployment webapp
```

Saída esperada:

```
deployment.apps/webapp deleted
```

Confirme que todos os Pods foram removidos:

```bash
kubectl get pods -l app=webapp
```

Saída esperada:

```
No resources found in default namespace.
```

---

## Problemas Comuns

| Problema | Sintoma | Correção |
|---|---|---|
| `selector` não corresponde aos labels do template | Criação do Deployment falha: `invalid: spec.template.metadata.labels: Invalid value` | Certifique-se de que `spec.selector.matchLabels` corresponda exatamente a `spec.template.metadata.labels` |
| Rolling update travado | `kubectl rollout status` fica preso indefinidamente | Verifique eventos dos Pods: `kubectl describe pods -l app=webapp`. Geralmente é uma tag de imagem inválida. Corrija com `kubectl rollout undo deployment/webapp` |
| Alunos editam ReplicaSets diretamente | As mudanças são sobrescritas pelo controller do Deployment | Explique: sempre modifique a spec do **Deployment**. O controller do Deployment é dono dos ReplicaSets |
| `kubectl scale` não persiste | Após reaplicar o YAML, as réplicas voltam ao valor do YAML | Explique: `kubectl scale` é imperativo. Se reaplicarem o YAML com `replicas: 3`, isso sobrescreve o comando de scale. Para persistência, edite o arquivo YAML |
| Valores de recursos rejeitados | `must match the regex` ou `quantities must match` | CPU usa millicores (`50m`), memória usa Mi/Gi (`64Mi`). Erro comum: `50M` (megabytes, não millicores) para CPU |
| Pods pendentes após adicionar resource requests | Pods presos em `Pending` com "Insufficient cpu/memory" | O cluster Kind tem recursos limitados. Reduza os requests (ex: `cpu: 10m, memory: 32Mi`) ou reduza as réplicas |
| Alunos não entendem por que rollout undo cria uma nova revisão | Eles esperam que o número da revisão volte para 1 | Explique: `undo` cria uma nova revisão que coincidentemente corresponde a um template antigo. O histórico sempre avança. O número da revisão antiga é aposentado |
| Pods com OOMKilled | Status do Pod mostra `OOMKilled` | O limite de memória é muito baixo para o processo. Aumente `limits.memory`. Inspecione com `kubectl describe pod <name>` → procure "Last State: Terminated, Reason: OOMKilled" |
