# Desafio 17 — Estratégias Avançadas de Deployment

[< Desafio Anterior](Challenge-16.md) - **[Início](../README.md)** - [Próximo Desafio >](Challenge-18.md)

## Introdução

Em um servidor Linux, atualizar uma aplicação em produção é um processo cuidadosamente orquestrado. Você pode manter dois pools de servidores idênticos atrás de um load balancer e alternar o tráfego do antigo para o novo (`blue/green`). Ou pode configurar pesos de upstream no Nginx para enviar apenas 10% do tráfego para a nova versão enquanto 90% permanece na versão comprovada (`canary / teste A/B`). Um simples `apt upgrade nginx` substitui o binário in-place enquanto o serviço continua ativo (`rolling update`). E às vezes a única opção segura é `systemctl stop myapp && systemctl start myapp` — uma reinicialização forçada com uma breve indisponibilidade (`recreate`).

O Kubernetes formaliza cada um desses padrões como uma **estratégia de deployment**. Em vez de criar scripts de failover e pesos de upstream manualmente, você declara a estratégia em YAML e o cluster cuida da mecânica do rollout.

Neste desafio você implementará todos os quatro padrões no seu cluster Kind, além de aprender como lidar com **depreciações de API** — o equivalente Kubernetes de um `apt-get dist-upgrade` quebrando suas configurações quando interfaces antigas de pacotes são removidas.

| Padrão Linux | Padrão Kubernetes |
|---|---|
| Dois pools de servidores + flip DNS/VIP | Blue/Green Deployments |
| Pesos de upstream Nginx (10/90) | Canary com annotations de Ingress ou Gateway API |
| `apt upgrade` (in-place, sem downtime) | Estratégia RollingUpdate |
| `systemctl stop && start` (breve indisponibilidade) | Estratégia Recreate |
| `apt-get dist-upgrade` (breaking changes) | Depreciação de API & migração de versão |

> **Requisito do cluster:** Todos os exercícios usam um cluster [Kind](https://kind.sigs.k8s.io/) local — nenhuma conta cloud é necessária. Se você ainda não criou um, execute:
> ```bash
> kind create cluster --name fasthack
> ```

## Descrição

### Tarefa 1 — Blue/Green Deployment

Blue/Green é o equivalente Kubernetes de manter dois pools de servidores idênticos atrás de um load balancer e alternar o VIP de "blue" (atual) para "green" (novo). O insight chave: **dois Deployments existem simultaneamente, mas apenas um recebe tráfego** — controlado pelo selector do Service.

**Passo 1:** Crie dois Deployments — um "blue" (v1) e um "green" (v2). Ambos usam a mesma label base `app` mas diferem na label `version`. Salve como `blue-green.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp-blue
spec:
  replicas: 3
  selector:
    matchLabels:
      app: webapp
      version: blue
  template:
    metadata:
      labels:
        app: webapp
        version: blue
    spec:
      containers:
        - name: webapp
          image: hashicorp/http-echo
          args:
            - "-text=v1 - BLUE"
          ports:
            - containerPort: 5678
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 64Mi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webapp-green
spec:
  replicas: 3
  selector:
    matchLabels:
      app: webapp
      version: green
  template:
    metadata:
      labels:
        app: webapp
        version: green
    spec:
      containers:
        - name: webapp
          image: hashicorp/http-echo
          args:
            - "-text=v2 - GREEN"
          ports:
            - containerPort: 5678
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 64Mi
```

**Passo 2:** Crie um Service que atualmente aponta para a versão **blue**. Salve como `webapp-svc.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: webapp-svc
spec:
  selector:
    app: webapp
    version: blue
  ports:
    - protocol: TCP
      port: 80
      targetPort: 5678
```

**Passo 3:** Aplique ambos os arquivos e verifique que o tráfego vai para o Deployment blue:

```bash
kubectl apply -f blue-green.yaml
kubectl apply -f webapp-svc.yaml
kubectl run curl-test --image=curlimages/curl --restart=Never --rm -it -- curl -s http://webapp-svc
```

Você deve ver `v1 - BLUE`.

**Passo 4:** Troque o tráfego para green atualizando o selector do Service:

```bash
kubectl patch svc webapp-svc -p '{"spec":{"selector":{"version":"green"}}}'
```

**Passo 5:** Verifique a troca — todo o tráfego agora vai para v2:

```bash
kubectl run curl-test --image=curlimages/curl --restart=Never --rm -it -- curl -s http://webapp-svc
```

Agora você deve ver `v2 - GREEN`.

> **Por que funciona:** O Service usa label selectors para escolher quais Pods recebem tráfego. Alterando um valor de label, você redireciona instantaneamente 100% do tráfego — sem atraso de propagação DNS, sem dores de cabeça com connection draining. Este é o equivalente Kubernetes de alternar um VIP em um load balancer.

### Tarefa 2 — Canary Deployment com NGINX Ingress Controller

Um canary deployment envia uma pequena porcentagem de tráfego para a nova versão enquanto mantém a maior parte do tráfego na versão estável — como configurar pesos de `upstream` em uma configuração Nginx para fazer teste A/B.

O NGINX Ingress Controller suporta divisão de tráfego canary nativamente via annotations.

**Passo 1:** Instale o NGINX Ingress Controller no seu cluster Kind:

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

# Aguarde o controller estar pronto
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
```

**Passo 2:** Crie dois Deployments e Services — "stable" e "canary". Salve como `canary-app.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp-stable
spec:
  replicas: 3
  selector:
    matchLabels:
      app: myapp
      track: stable
  template:
    metadata:
      labels:
        app: myapp
        track: stable
    spec:
      containers:
        - name: myapp
          image: hashicorp/http-echo
          args:
            - "-text=STABLE v1"
          ports:
            - containerPort: 5678
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
---
apiVersion: v1
kind: Service
metadata:
  name: myapp-stable
spec:
  selector:
    app: myapp
    track: stable
  ports:
    - port: 80
      targetPort: 5678
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp-canary
spec:
  replicas: 1
  selector:
    matchLabels:
      app: myapp
      track: canary
  template:
    metadata:
      labels:
        app: myapp
        track: canary
    spec:
      containers:
        - name: myapp
          image: hashicorp/http-echo
          args:
            - "-text=CANARY v2"
          ports:
            - containerPort: 5678
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
---
apiVersion: v1
kind: Service
metadata:
  name: myapp-canary
spec:
  selector:
    app: myapp
    track: canary
  ports:
    - port: 80
      targetPort: 5678
```

**Passo 3:** Crie o Ingress **principal** para o Service estável. Salve como `canary-ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp-main
spec:
  ingressClassName: nginx
  rules:
    - host: myapp.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: myapp-stable
                port:
                  number: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp-canary
  annotations:
    nginx.ingress.kubernetes.io/canary: "true"
    nginx.ingress.kubernetes.io/canary-weight: "20"
spec:
  ingressClassName: nginx
  rules:
    - host: myapp.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: myapp-canary
                port:
                  number: 80
```

A annotation `canary-weight: "20"` diz ao NGINX para enviar **20% do tráfego** para o Service canary e 80% para o estável.

**Passo 4:** Aplique tudo:

```bash
kubectl apply -f canary-app.yaml
kubectl apply -f canary-ingress.yaml
```

**Passo 5:** Teste a divisão de tráfego. Envie 20 requisições e conte os resultados:

```bash
for i in $(seq 1 20); do
  curl -s -H "Host: myapp.local" http://localhost:80
done | sort | uniq -c
```

Você deve ver aproximadamente 16 respostas dizendo `STABLE v1` e 4 dizendo `CANARY v2` (divisão 80/20).

> **Nota:** No Kind, o NGINX Ingress Controller escuta na porta 80 do host. Se a porta 80 não estiver disponível, use `kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80` e faça curl em `http://localhost:8080`.

**Passo 6:** Aumente o peso canary para promover a nova versão gradualmente:

```bash
kubectl annotate ingress myapp-canary \
  nginx.ingress.kubernetes.io/canary-weight="50" --overwrite
```

Re-execute o loop de curl — agora você deve ver uma divisão ~50/50.

### Tarefa 3 — Canary Deployment com Gateway API HTTPRoute

A Gateway API é a sucessora do Ingress e fornece divisão de tráfego nativa sem annotations. É como ter configuração de upstream ponderada embutida nas regras de roteamento do load balancer em vez de adicionada via comentários.

**Passo 1:** Instale os CRDs da Gateway API e um controller. Usaremos **Contour** como controller do Gateway:

```bash
# Instalar CRDs da Gateway API (canal standard)
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/latest/download/standard-install.yaml

# Instalar Contour (inclui um controller de Gateway)
kubectl apply -f https://projectcontour.io/quickstart/contour.yaml

# Aguardar Contour ficar pronto
kubectl wait --namespace projectcontour \
  --for=condition=ready pod \
  --selector=app=contour \
  --timeout=120s
```

**Passo 2:** Crie um GatewayClass e Gateway. Salve como `gateway.yaml`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: contour
spec:
  controllerName: projectcontour.io/gateway-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: contour-gateway
  namespace: projectcontour
spec:
  gatewayClassName: contour
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
```

**Passo 3:** Crie um HTTPRoute com **backendRefs ponderados** para divisão de tráfego. Salve como `canary-httproute.yaml`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp-canary-route
spec:
  parentRefs:
    - name: contour-gateway
      namespace: projectcontour
  hostnames:
    - "myapp.local"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: myapp-stable
          port: 80
          weight: 80
        - name: myapp-canary
          port: 80
          weight: 20
```

**Passo 4:** Aplique e teste:

```bash
kubectl apply -f gateway.yaml
kubectl apply -f canary-httproute.yaml

# Encontre a porta do serviço Envoy
kubectl get svc -n projectcontour envoy -o jsonpath='{.spec.ports[0].nodePort}'
```

Envie requisições de teste pelo Gateway (ajuste a porta conforme necessário):

```bash
ENVOY_PORT=$(kubectl get svc -n projectcontour envoy -o jsonpath='{.spec.ports[0].nodePort}')
for i in $(seq 1 20); do
  curl -s -H "Host: myapp.local" http://localhost:${ENVOY_PORT}
done | sort | uniq -c
```

**Passo 5:** Mude o tráfego totalmente para canary atualizando os pesos do HTTPRoute:

```bash
kubectl patch httproute myapp-canary-route --type=merge -p '{
  "spec": {
    "rules": [{
      "matches": [{"path": {"type": "PathPrefix", "value": "/"}}],
      "backendRefs": [
        {"name": "myapp-stable", "port": 80, "weight": 0},
        {"name": "myapp-canary", "port": 80, "weight": 100}
      ]
    }]
  }
}'
```

### Tarefa 4 — Rolling Update Deep Dive (maxSurge & maxUnavailable)

No Desafio 04 você realizou um rolling update básico. Agora vamos ajustar a velocidade do rollout com `maxSurge` e `maxUnavailable` — o equivalente a controlar quantos servidores você tira do pool de uma vez durante um ciclo de `apt upgrade`.

**Passo 1:** Crie um Deployment com parâmetros explícitos de rolling update. Salve como `rolling-deep.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rolling-app
  annotations:
    kubernetes.io/change-cause: "initial deployment v1"
spec:
  replicas: 6
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 2
      maxUnavailable: 1
  selector:
    matchLabels:
      app: rolling-app
  template:
    metadata:
      labels:
        app: rolling-app
    spec:
      containers:
        - name: app
          image: nginx:1.27
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 64Mi
```

Com `replicas: 6`, `maxSurge: 2` e `maxUnavailable: 1`:
- Durante o rollout, até **8 Pods** podem existir ao mesmo tempo (6 + 2 surge)
- Pelo menos **5 Pods** estão sempre disponíveis (6 − 1 unavailable)

**Passo 2:** Aplique e então dispare um rolling update:

```bash
kubectl apply -f rolling-deep.yaml
kubectl rollout status deployment rolling-app

# Atualize a imagem para disparar um rollout
kubectl set image deployment/rolling-app app=nginx:1.28
kubectl annotate deployment rolling-app kubernetes.io/change-cause="update to nginx:1.28" --overwrite
```

**Passo 3:** Observe o rollout em tempo real — observe o surge e a disponibilidade:

```bash
kubectl rollout status deployment/rolling-app
kubectl get pods -l app=rolling-app --watch
```

Observe como o Kubernetes cria novos Pods antes de terminar os antigos — nunca caindo abaixo de 5 disponíveis.

**Passo 4:** Inspecione o histórico de rollout:

```bash
kubectl rollout history deployment/rolling-app
```

**Passo 5:** Experimente com diferentes configurações para ver o trade-off velocidade/segurança:

```bash
# Rollout rápido — surge agressivo, permite mais indisponibilidade
kubectl patch deployment rolling-app -p '{
  "spec": {"strategy": {"rollingUpdate": {"maxSurge": 3, "maxUnavailable": 2}}}
}'
kubectl set image deployment/rolling-app app=nginx:1.27

# Rollout lento e seguro — surge mínimo, zero indisponibilidade
kubectl patch deployment rolling-app -p '{
  "spec": {"strategy": {"rollingUpdate": {"maxSurge": 1, "maxUnavailable": 0}}}
}'
kubectl set image deployment/rolling-app app=nginx:1.28
```

> **Insight chave:** `maxSurge: 1, maxUnavailable: 0` significa "nunca tenha menos Pods que o desejado, crie um novo antes de remover um antigo." Esta é a opção mais segura mas mais lenta — exatamente como tirar um servidor do pool por vez durante um upgrade de firmware gradual.

### Tarefa 5 — Estratégia Recreate

A estratégia Recreate é o equivalente a `systemctl stop myapp && systemctl start myapp` — todos os Pods antigos são terminados antes de quaisquer novos serem criados. **Haverá** downtime.

**Passo 1:** Crie um Deployment com estratégia Recreate. Salve como `recreate-app.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: recreate-app
spec:
  replicas: 4
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: recreate-app
  template:
    metadata:
      labels:
        app: recreate-app
    spec:
      containers:
        - name: app
          image: nginx:1.27
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
```

**Passo 2:** Aplique e aguarde todos os Pods estarem prontos:

```bash
kubectl apply -f recreate-app.yaml
kubectl rollout status deployment recreate-app
```

**Passo 3:** Dispare uma atualização e **observe com atenção** — você verá todos os Pods antigos terminarem antes de quaisquer novos iniciarem:

```bash
kubectl set image deployment/recreate-app app=nginx:1.28

# Em outro terminal, observe as transições dos Pods
kubectl get pods -l app=recreate-app --watch
```

**Passo 4:** Observe a linha do tempo:

```bash
kubectl describe deployment recreate-app
```

Observe a seção Events — você verá eventos `ScalingReplicaSet` mostrando o antigo ReplicaSet escalado para 0 *antes* do novo ReplicaSet escalar para cima.

> **Quando usar Recreate:**
> - Sua aplicação não pode tolerar duas versões rodando simultaneamente (ex: migração de schema de banco de dados em andamento)
> - Você tem um workload singleton que mantém um lock exclusivo em um recurso
> - Um breve downtime é aceitável e mais simples do que gerenciar coexistência de versões

### Tarefa 6 — Tratamento de Depreciação de API

Quando o Kubernetes remove versões antigas de API, seus manifests armazenados quebram — assim como quando `apt-get dist-upgrade` remove uma interface de pacote depreciada e scripts que dependem dela param de funcionar.

**Passo 1:** Verifique o uso de APIs depreciadas no seu cluster:

```bash
# Veja quais versões de API seu cluster suporta
kubectl api-versions | sort

# Verifique avisos de depreciação (o API server retorna avisos nos headers de resposta)
kubectl get deployments -v=8 2>&1 | grep -i deprecat
```

**Passo 2:** Pratique a conversão de um manifest com uma versão de API antiga. Crie um arquivo `old-ingress.yaml` com a API **depreciada** `extensions/v1beta1`:

```yaml
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: legacy-ingress
spec:
  rules:
    - host: old.example.com
      http:
        paths:
          - path: /
            backend:
              serviceName: legacy-svc
              servicePort: 80
```

**Passo 3:** Tente aplicá-lo — o API server irá rejeitá-lo:

```bash
kubectl apply -f old-ingress.yaml
```

Você verá um erro como: `error: resource mapping not found for name: "legacy-ingress" namespace: "" from "old-ingress.yaml": no matches for kind "Ingress" in version "extensions/v1beta1"`.

**Passo 4:** Instale e use `kubectl-convert` para migrar para a versão atual da API:

```bash
# Instale o plugin kubectl-convert (se ainda não estiver instalado)
# Via Krew:
kubectl krew install convert

# Ou baixe diretamente:
# curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl-convert"
# chmod +x kubectl-convert && sudo mv kubectl-convert /usr/local/bin/
```

```bash
# Converta para a API atual networking.k8s.io/v1
kubectl convert -f old-ingress.yaml --output-version networking.k8s.io/v1
```

**Passo 5:** Se `kubectl-convert` não estiver disponível, migre o manifest manualmente. Crie `new-ingress.yaml` com a API atual:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: legacy-ingress
spec:
  rules:
    - host: old.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: legacy-svc
                port:
                  number: 80
```

Mudanças chave de `extensions/v1beta1` → `networking.k8s.io/v1`:
- `apiVersion` mudou
- `backend.serviceName` → `backend.service.name`
- `backend.servicePort` → `backend.service.port.number`
- `pathType` agora é **obrigatório** (era opcional antes)

**Passo 6:** Explore ferramentas para detectar APIs depreciadas nos seus manifests:

```bash
# Liste todos os recursos de API e suas versões preferidas
kubectl api-resources -o wide

# O guia de depreciação do Kubernetes é a referência oficial:
# https://kubernetes.io/docs/reference/using-api/deprecation-guide/
```

### Limpe

```bash
kubectl delete -f blue-green.yaml 2>/dev/null
kubectl delete -f webapp-svc.yaml 2>/dev/null
kubectl delete -f canary-app.yaml 2>/dev/null
kubectl delete -f canary-ingress.yaml 2>/dev/null
kubectl delete -f gateway.yaml 2>/dev/null
kubectl delete -f canary-httproute.yaml 2>/dev/null
kubectl delete -f rolling-deep.yaml 2>/dev/null
kubectl delete -f recreate-app.yaml 2>/dev/null
kubectl delete -f old-ingress.yaml 2>/dev/null
kubectl delete -f new-ingress.yaml 2>/dev/null
```

## Critérios de Sucesso

- [ ] Você implantou uma configuração blue/green com dois Deployments e alternou o tráfego fazendo patch no selector do Service.
- [ ] Você consegue explicar por que blue/green oferece rollback instantâneo (basta fazer patch no selector de volta).
- [ ] Você instalou o NGINX Ingress Controller e criou um Ingress canary com a annotation `canary-weight`.
- [ ] Testes com curl confirmam a divisão de tráfego ~80/20 entre estável e canary.
- [ ] Você criou um HTTPRoute da Gateway API com `backendRefs` ponderados para divisão de tráfego canary.
- [ ] Você consegue explicar a diferença entre annotations de Ingress e divisão de tráfego nativa da Gateway API.
- [ ] Você implantou com `maxSurge: 2` e `maxUnavailable: 1` e observou o comportamento do rollout.
- [ ] Você consegue explicar o trade-off velocidade vs. segurança de diferentes valores de `maxSurge`/`maxUnavailable`.
- [ ] Você implantou com `strategy: Recreate` e observou todos os Pods antigos terminarem antes dos novos iniciarem.
- [ ] Você consegue explicar quando Recreate é apropriado apesar do seu downtime.
- [ ] Você entende por que Ingress `extensions/v1beta1` falha em clusters modernos e pode migrar manualmente para `networking.k8s.io/v1`.
- [ ] Você sabe como usar `kubectl-convert` (ou migração manual) para lidar com depreciações de API.

## Referência Rápida Linux ↔ Kubernetes

| Conceito Linux | Equivalente Kubernetes | Notas |
|---|---|---|
| Dois pools de servidores + failover DNS/VIP | Blue/Green Deployments + troca de selector do Service | Cutover instantâneo alterando quais Pods o Service seleciona |
| Pesos de `upstream` do Nginx (divisão 10/90) | Canary com annotations de Ingress ou pesos de HTTPRoute da Gateway API | Mudança gradual de tráfego para a nova versão |
| `apt upgrade` (in-place, sem downtime) | Estratégia `RollingUpdate` com `maxSurge`/`maxUnavailable` | Novos Pods criados antes dos antigos serem removidos |
| `systemctl stop && systemctl start` | Estratégia `Recreate` | Todos os Pods antigos terminados antes dos novos iniciarem — breve interrupção |
| `apt-get dist-upgrade` (breaking changes) | Depreciação de API — migração de `apiVersion` | Versões antigas de API removidas; manifests devem ser atualizados |
| `dpkg --configure -a` (corrigir upgrades quebrados) | `kubectl convert` / migração manual de manifests | Reparar manifests que referenciam versões de API removidas |
| Health checks do load balancer | `readinessProbe` + labels de selector do Service | Apenas Pods saudáveis e selecionados recebem tráfego |
| Pesos em `/etc/nginx/upstream.conf` | `backendRefs[].weight` no HTTPRoute | Roteamento ponderado nativo na Gateway API |

## Dicas

<details>
<summary>Dica 1: Blue/Green — Como verificar qual versão está ativa</summary>

Verifique quais Pods o Service está selecionando atualmente:

```bash
kubectl get endpoints webapp-svc -o yaml
```

A lista `addresses` mostra os IPs dos Pods recebendo tráfego. Cruze com:

```bash
kubectl get pods -l app=webapp --show-labels -o wide
```

Para fazer rollback para blue após mudar para green:

```bash
kubectl patch svc webapp-svc -p '{"spec":{"selector":{"version":"blue"}}}'
```

</details>

<details>
<summary>Dica 2: NGINX Ingress não está roteando tráfego no Kind</summary>

Kind requer um manifest específico do NGINX Ingress que mapeia as portas corretamente. Certifique-se de usar o manifest específico para Kind:

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
```

Se a porta 80 não estiver acessível no localhost, use port-forward:

```bash
kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80
```

Então teste com:

```bash
curl -s -H "Host: myapp.local" http://localhost:8080
```

Também verifique se ambos os recursos Ingress existem e compartilham o mesmo `host`:

```bash
kubectl get ingress
```

</details>

<details>
<summary>Dica 3: Peso canary não está tendo efeito</summary>

O Ingress canary **deve** usar o mesmo `host` e `path` que o Ingress principal. Se eles diferirem, o NGINX os trata como rotas separadas em vez de aplicar o peso canary.

Também garanta que a annotation `canary: "true"` está presente — sem ela, a annotation `canary-weight` é ignorada:

```bash
kubectl get ingress myapp-canary -o yaml | grep -A5 annotations
```

</details>

<details>
<summary>Dica 4: Entendendo a matemática de maxSurge e maxUnavailable</summary>

Dado `replicas: 6`, `maxSurge: 2`, `maxUnavailable: 1`:

- **Máximo de Pods durante o rollout:** 6 + 2 = **8**
- **Mínimo de Pods disponíveis:** 6 − 1 = **5**

O Kubernetes irá:
1. Criar até 2 novos Pods (surge)
2. Uma vez que os novos Pods estejam Ready, terminar até 1 Pod antigo
3. Repetir até que todos os Pods antigos sejam substituídos

Definir `maxUnavailable: 0` significa "nunca tenha menos Pods que o desejado" — a opção mais segura mas mais lenta.

</details>

<details>
<summary>Dica 5: Pods da Gateway API não estão iniciando</summary>

Se os Pods do Contour não estiverem prontos, verifique o namespace:

```bash
kubectl get pods -n projectcontour
```

Os CRDs da Gateway API devem ser instalados antes do Contour:

```bash
kubectl get crds | grep gateway
```

Você deve ver `gatewayclasses.gateway.networking.k8s.io`, `gateways.gateway.networking.k8s.io` e `httproutes.gateway.networking.k8s.io`.

</details>

<details>
<summary>Dica 6: kubectl-convert não encontrado</summary>

`kubectl-convert` é um plugin separado, não integrado ao kubectl. Instale-o via:

**Krew (recomendado):**

```bash
kubectl krew install convert
```

**Download direto:**

```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl-convert"
chmod +x kubectl-convert
sudo mv kubectl-convert /usr/local/bin/
```

Se você não puder instalá-lo, converta manifests manualmente consultando o [Guia de Migração de API Depreciada do Kubernetes](https://kubernetes.io/docs/reference/using-api/deprecation-guide/).

</details>

## Recursos de Aprendizado

- [Kubernetes Deployments — strategies](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#strategy)
- [Rolling Update tutorial](https://kubernetes.io/docs/tutorials/kubernetes-basics/update/update-intro/)
- [NGINX Ingress Controller — Canary annotations](https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/#canary)
- [Gateway API — HTTPRoute traffic splitting](https://gateway-api.sigs.k8s.io/guides/traffic-splitting/)
- [Gateway API — HTTPRoute reference](https://gateway-api.sigs.k8s.io/reference/spec/#gateway.networking.k8s.io/v1.HTTPRoute)
- [Kubernetes Deprecated API Migration Guide](https://kubernetes.io/docs/reference/using-api/deprecation-guide/)
- [kubectl-convert plugin](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/#install-kubectl-convert-plugin)
- [CKAD Curriculum — Deployment strategies](https://github.com/cncf/curriculum)

## Quebra & Conserta 🔧

Tente cada cenário, diagnostique o problema e corrija-o.

### Cenário 1 — Troca Blue/Green não funcionou

Aplique este Service e ambos os Deployments da Tarefa 1:

```yaml
# Salve como broken-bg-svc.yaml
apiVersion: v1
kind: Service
metadata:
  name: broken-bg-svc
spec:
  selector:
    app: webapp
    version: teal
  ports:
    - port: 80
      targetPort: 5678
```

```bash
kubectl apply -f blue-green.yaml
kubectl apply -f broken-bg-svc.yaml
kubectl run curl-test --image=curlimages/curl --restart=Never --rm -it -- curl -s --max-time 5 http://broken-bg-svc
```

**O que você verá:** O curl dá timeout ou retorna um erro de connection refused.

**Diagnostique:**

```bash
kubectl get endpoints broken-bg-svc
kubectl describe svc broken-bg-svc
```

A lista de Endpoints está vazia — nenhum Pod corresponde ao selector.

**Causa raiz:** O selector do Service usa `version: teal`, mas nenhum Deployment tem essa label. Blue usa `version: blue`, green usa `version: green`.

**Correção:** Faça patch no selector para uma versão real:

```bash
kubectl patch svc broken-bg-svc -p '{"spec":{"selector":{"version":"blue"}}}'
```

**Analogia com Linux:** É como configurar um VIP para apontar para um pool de servidores backend que não existe — nenhum servidor responde os health checks, então o load balancer não tem para onde enviar o tráfego.

**Limpe:**

```bash
kubectl delete svc broken-bg-svc
```

---

### Cenário 2 — Ingress Canary envia 100% para o canary em vez de 20%

Aplique o app canary e este Ingress:

```yaml
# Salve como broken-canary-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: broken-canary
  annotations:
    nginx.ingress.kubernetes.io/canary-weight: "20"
spec:
  ingressClassName: nginx
  rules:
    - host: broken.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: myapp-canary
                port:
                  number: 80
```

```bash
kubectl apply -f canary-app.yaml
kubectl apply -f broken-canary-ingress.yaml

for i in $(seq 1 10); do
  curl -s -H "Host: broken.local" http://localhost:80
done
```

**O que você verá:** 100% das respostas são `CANARY v2`, não os 20% esperados.

**Diagnostique:** Observe as annotations:

```bash
kubectl get ingress broken-canary -o yaml | grep -A5 annotations
```

**Causa raiz:** A annotation `nginx.ingress.kubernetes.io/canary: "true"` está **faltando**. Sem ela, a annotation `canary-weight` é ignorada e o Ingress atua como uma rota standalone — enviando todo o tráfego que corresponde a `broken.local` diretamente para o backend canary.

**Correção:** Adicione a annotation canary que está faltando:

```bash
kubectl annotate ingress broken-canary nginx.ingress.kubernetes.io/canary="true"
```

Mas isso ainda não funcionará corretamente porque não há um Ingress **principal** para `broken.local`. O Ingress canary precisa de um Ingress estável correspondente para dividir o tráfego.

**Limpe:**

```bash
kubectl delete ingress broken-canary
```

---

### Cenário 3 — Rolling update preso em progresso

Aplique este Deployment:

```yaml
# Salve como broken-rolling.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: broken-rolling
spec:
  replicas: 4
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: broken-rolling
  template:
    metadata:
      labels:
        app: broken-rolling
    spec:
      containers:
        - name: app
          image: nginx:1.27
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 3
```

```bash
kubectl apply -f broken-rolling.yaml
kubectl rollout status deployment broken-rolling --timeout=60s

# Dispare uma atualização
kubectl set image deployment/broken-rolling app=nginx:1.28
kubectl rollout status deployment/broken-rolling --timeout=60s
```

**O que você verá:** O rollout trava. Novos Pods são criados mas nunca ficam Ready.

**Diagnostique:**

```bash
kubectl get pods -l app=broken-rolling
kubectl describe pod -l app=broken-rolling | grep -A5 "Readiness"
```

**Causa raiz:** A `readinessProbe` verifica a porta `8080` no path `/healthz`, mas o nginx escuta na porta `80` e não tem um endpoint `/healthz`. Os novos Pods nunca passam na verificação de readiness, então com `maxUnavailable: 0`, o Kubernetes não pode terminar nenhum Pod antigo — o rollout está preso.

**Correção:** Corrija a readiness probe para corresponder à aplicação real:

```bash
kubectl patch deployment broken-rolling --type=json -p '[
  {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/port","value":80},
  {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/"}
]'
```

**Analogia com Linux:** É como ter um health check do load balancer verificando a porta errada — os novos servidores nunca entram no pool, então o LB mantém todo o tráfego nos servidores antigos.

**Limpe:**

```bash
kubectl delete deployment broken-rolling
```
