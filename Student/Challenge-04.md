# Desafio 04 — Deployments e Rolling Updates

[< Desafio Anterior](Challenge-03.md) | **[Início](../README.md)** | [Próximo Desafio >](Challenge-05.md)

## Introdução

No Linux, se o nginx trava, você reinicia manualmente (`systemctl restart nginx`). No Kubernetes, Deployments fazem isso automaticamente — e muito mais. Um Deployment gerencia ReplicaSets, que gerenciam Pods. Ele garante que o número desejado de réplicas esteja sempre em execução e realiza rolling updates sem downtime.

Pense assim:

- `systemctl` → **Deployment** (gerencia o ciclo de vida da sua aplicação)
- Contagem de processos → **replicas** (quantas instâncias manter em execução)
- `apt upgrade` → **rolling update** (atualizar a versão da aplicação com zero downtime)
- Rollback de pacote → **`kubectl rollout undo`** (reverter para a versão anterior instantaneamente)

## Descrição

Sua missão é:

1. Criar um Deployment com **3 réplicas** de `nginx:stable`
2. Escalar o Deployment para **5 réplicas**, depois voltar para **3**
3. Realizar um **rolling update** de `nginx:stable` para `nginx:alpine`
4. **Rollback** para a versão anterior
5. Definir **resource requests e limits** (CPU e memória) no Deployment

## Critérios de Sucesso

- [ ] Um Deployment chamado `webapp` está rodando com 3 réplicas e todos os Pods estão Ready
- [ ] Você consegue escalar o Deployment para 5 réplicas e voltar para 3
- [ ] Um rolling update de `nginx:stable` para `nginx:alpine` completa com zero downtime
- [ ] Você consegue fazer rollback para a versão anterior usando `kubectl rollout undo`
- [ ] Resource requests e limits estão definidos no container e visíveis via `kubectl describe`

## Referência Linux ↔ Kubernetes

| Conceito Linux | Equivalente Kubernetes |
|---|---|
| `systemctl start nginx` | `kubectl apply -f deployment.yaml` |
| `systemctl restart nginx` | `kubectl rollout restart deployment/webapp` |
| Contagem de processos (número de workers nginx) | `spec.replicas` |
| `apt upgrade nginx` | Atualização de imagem via `kubectl set image` (rolling) |
| `apt rollback` / downgrade de pacote | `kubectl rollout undo deployment/webapp` |
| `ulimit` / limites de recursos cgroups | `resources.requests` / `resources.limits` |
| `systemctl status nginx` | `kubectl rollout status deployment/webapp` |

## Dicas

<details>
<summary>Dica 1: Criar o YAML do Deployment</summary>

Crie um arquivo chamado `webapp-deployment.yaml`:

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

Aplique e verifique:

```bash
kubectl apply -f webapp-deployment.yaml
kubectl get deployment webapp
kubectl get pods -l app=webapp
```
</details>

<details>
<summary>Dica 2: Escalando para cima e para baixo</summary>

```bash
kubectl scale deployment webapp --replicas=5
kubectl get pods -l app=webapp -w  # watch Pods appear
kubectl scale deployment webapp --replicas=3
```
</details>

<details>
<summary>Dica 3: Realizando um rolling update</summary>

```bash
kubectl set image deployment/webapp nginx=nginx:alpine
kubectl rollout status deployment/webapp
kubectl get pods -l app=webapp  # observe old Pods terminating, new Pods starting
```
</details>

<details>
<summary>Dica 4: Fazendo rollback</summary>

```bash
kubectl rollout history deployment/webapp
kubectl rollout undo deployment/webapp
kubectl rollout status deployment/webapp
kubectl describe deployment webapp | grep Image
```
</details>

## Recursos de Aprendizado

- [Kubernetes Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/)
- [Gerenciando Recursos para Containers](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)
- [Realizando um Rolling Update](https://kubernetes.io/docs/tutorials/kubernetes-basics/update/update-intro/)

## Break & Fix 🔧

Após completar o desafio, tente estes cenários:

1. **Tag de imagem inválida** — Defina a imagem com uma tag inexistente (`nginx:doesnotexist`) e observe o rollout travar. Use `kubectl rollout status` para ver o travamento, depois faça rollback com `kubectl rollout undo deployment/webapp`
2. **OOMKilled** — Defina o limite de memória para `1Mi` e observe o Pod ser morto com status `OOMKilled`. Inspecione com `kubectl describe pod` e procure a seção `Last State`
3. **Auto-recuperação** — Delete um Pod manualmente (`kubectl delete pod <pod-name>`) e observe o Deployment recriá-lo automaticamente. Use `kubectl get pods -w` para ver o novo Pod aparecer
