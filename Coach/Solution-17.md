# Solução 17 — Estratégias Avançadas de Deployment

[< Solução Anterior](Solution-16.md) - **[Home](README.md)** - [Próxima Solução >](Solution-18.md)

---

> **Nota do Coach:** Este desafio cobre cinco padrões de deployment relevantes para o CKAD. As Tarefas 1 (Blue/Green), 4 (Rolling Update) e 5 (Recreate) funcionam diretamente. As Tarefas 2 e 3 requerem a instalação do NGINX Ingress Controller e Gateway API + Contour — ajude os alunos se a instalação travar. A Tarefa 6 (depreciação de API) é conceitual com um exercício prático.

Tempo estimado: **60–75 minutos**

---

## Tarefa 1: Blue/Green Deployment

### Passo a passo

Salve `blue-green.yaml`:

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

Salve `webapp-svc.yaml`:

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

Aplique:

```bash
kubectl apply -f blue-green.yaml
kubectl apply -f webapp-svc.yaml
```

### Verificação — Blue está ativo

```bash
kubectl get deployments -l app=webapp
```

Saída esperada:

```
NAME           READY   UP-TO-DATE   AVAILABLE   AGE
webapp-blue    3/3     3            3           30s
webapp-green   3/3     3            3           30s
```

```bash
kubectl run curl-test --image=curlimages/curl --restart=Never --rm -it -- curl -s http://webapp-svc
```

Saída esperada:

```
v1 - BLUE
```

Verifique se os endpoints do Service apontam apenas para os Pods blue:

```bash
kubectl get endpoints webapp-svc
```

Esperado: 3 endereços IP, todos correspondendo aos Pods blue.

```bash
kubectl get pods -l app=webapp,version=blue -o wide
```

Compare os IPs — eles devem corresponder.

### Mudar para Green

```bash
kubectl patch svc webapp-svc -p '{"spec":{"selector":{"version":"green"}}}'
```

### Verificação — Green está ativo

```bash
kubectl run curl-test --image=curlimages/curl --restart=Never --rm -it -- curl -s http://webapp-svc
```

Saída esperada:

```
v2 - GREEN
```

```bash
kubectl get endpoints webapp-svc
```

Esperado: 3 IPs agora correspondendo aos Pods green.

### Rollback para Blue

```bash
kubectl patch svc webapp-svc -p '{"spec":{"selector":{"version":"blue"}}}'
kubectl run curl-test --image=curlimages/curl --restart=Never --rm -it -- curl -s http://webapp-svc
```

Esperado: `v1 - BLUE` — rollback instantâneo, sem necessidade de recriar Pods.

> **Dica para o Coach:** Enfatize que o rollback é instantâneo porque ambos os Deployments estão rodando. Você está apenas mudando quais Pods o Service seleciona — sem pull de imagens, sem agendamento de Pods. O trade-off é o custo de recursos: você está rodando 2x o número de Pods.

---

## Tarefa 2: Canary Deployment com NGINX Ingress Controller

### Passo a passo

**Instale o NGINX Ingress Controller (manifesto específico para Kind):**

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
```

Aguarde a conclusão:

```bash
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
```

Saída esperada:

```
pod/ingress-nginx-controller-xxxxx condition met
```

> **Dica para o Coach:** Se o cluster Kind não foi criado com `extraPortMappings` para as portas 80/443, o controller NGINX não será acessível diretamente no localhost. Nesse caso, use port-forward:
> ```bash
> kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80 &
> ```
> E teste com `http://localhost:8080`.

**Crie os recursos da aplicação canary:**

Salve `canary-app.yaml`:

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

Salve `canary-ingress.yaml`:

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

Aplique tudo:

```bash
kubectl apply -f canary-app.yaml
kubectl apply -f canary-ingress.yaml
```

### Verificação

Verifique os recursos Ingress:

```bash
kubectl get ingress
```

Saída esperada:

```
NAME           CLASS   HOSTS         ADDRESS     PORTS   AGE
myapp-canary   nginx   myapp.local   localhost   80      10s
myapp-main     nginx   myapp.local   localhost   80      10s
```

Verifique as annotations do canary:

```bash
kubectl describe ingress myapp-canary | grep -A5 Annotations
```

Saída esperada:

```
Annotations:  nginx.ingress.kubernetes.io/canary: true
              nginx.ingress.kubernetes.io/canary-weight: 20
```

**Teste a divisão de tráfego (20 requisições):**

```bash
for i in $(seq 1 20); do
  curl -s -H "Host: myapp.local" http://localhost:80
done | sort | uniq -c
```

Saída esperada (aproximada — aleatoriedade se aplica):

```
     16 STABLE v1
      4 CANARY v2
```

> **Dica para o Coach:** A divisão não será exata em amostras pequenas. Com 20 requisições, os alunos podem ver 14-18 stable e 2-6 canary. Execute 100 requisições para uma correspondência mais próxima de 80/20.

**Aumente o peso do canary para 50%:**

```bash
kubectl annotate ingress myapp-canary \
  nginx.ingress.kubernetes.io/canary-weight="50" --overwrite
```

Re-teste:

```bash
for i in $(seq 1 20); do
  curl -s -H "Host: myapp.local" http://localhost:80
done | sort | uniq -c
```

Esperado: aproximadamente 10 STABLE / 10 CANARY.

**Promoção completa — defina o peso para 100%:**

```bash
kubectl annotate ingress myapp-canary \
  nginx.ingress.kubernetes.io/canary-weight="100" --overwrite
```

Agora 100% do tráfego vai para o canary. Neste ponto você faria:
1. Atualizar a imagem do Deployment stable para v2
2. Remover o Ingress e o Deployment canary

---

## Tarefa 3: Canary Deployment com Gateway API HTTPRoute

### Passo a passo

**Instale os CRDs da Gateway API:**

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/latest/download/standard-install.yaml
```

Saída esperada:

```
customresourcedefinition.apiextensions.k8s.io/gatewayclasses.gateway.networking.k8s.io created
customresourcedefinition.apiextensions.k8s.io/gateways.gateway.networking.k8s.io created
customresourcedefinition.apiextensions.k8s.io/httproutes.gateway.networking.k8s.io created
...
```

**Instale o Contour como controller do Gateway:**

```bash
kubectl apply -f https://projectcontour.io/quickstart/contour.yaml
```

Aguarde o Contour ficar pronto:

```bash
kubectl wait --namespace projectcontour \
  --for=condition=ready pod \
  --selector=app=contour \
  --timeout=120s
```

Saída esperada:

```
pod/contour-xxxxx condition met
```

Verifique se o proxy Envoy está rodando:

```bash
kubectl get pods -n projectcontour
```

Esperado: pods `contour-*` e `envoy-*` todos Running.

**Crie os recursos do Gateway:**

Salve `gateway.yaml`:

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

Salve `canary-httproute.yaml`:

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

Aplique:

```bash
kubectl apply -f gateway.yaml
kubectl apply -f canary-httproute.yaml
```

### Verificação

Verifique o status do Gateway:

```bash
kubectl get gateway -n projectcontour
```

Saída esperada:

```
NAME               CLASS     ADDRESS   PROGRAMMED   AGE
contour-gateway    contour             True         30s
```

Verifique o HTTPRoute:

```bash
kubectl get httproute
```

Saída esperada:

```
NAME                 HOSTNAMES          PARENTREFS                                AGE
myapp-canary-route   ["myapp.local"]    [{"name":"contour-gateway",...}]           10s
```

**Teste a divisão de tráfego através do Gateway:**

```bash
# Obtenha a porta do serviço Envoy
ENVOY_PORT=$(kubectl get svc -n projectcontour envoy -o jsonpath='{.spec.ports[0].nodePort}')
echo "Envoy NodePort: ${ENVOY_PORT}"

# Envie 20 requisições
for i in $(seq 1 20); do
  curl -s -H "Host: myapp.local" http://localhost:${ENVOY_PORT}
done | sort | uniq -c
```

Esperado (aproximado):

```
     16 STABLE v1
      4 CANARY v2
```

> **Dica para o Coach:** Se o NodePort não estiver acessível, use port-forward:
> ```bash
> kubectl port-forward -n projectcontour svc/envoy 9080:80 &
> ```
> Então use curl em `http://localhost:9080`.

**Direcione todo o tráfego para o canary:**

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

Re-teste — 100% agora deve ser CANARY v2.

> **Dica para o Coach — Ingress vs Gateway API:** Destaque a diferença principal:
> - Ingress usa **annotations** para divisão de tráfego — não-padronizado, específico do controller
> - Gateway API usa **campos nativos do YAML** (`backendRefs[].weight`) — padronizado entre controllers
>
> Gateway API é o futuro; annotations de Ingress são o padrão estabelecido. Os alunos devem conhecer ambos.

---

## Tarefa 4: Rolling Update em Profundidade

### Passo a passo

Salve `rolling-deep.yaml`:

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

Aplique:

```bash
kubectl apply -f rolling-deep.yaml
kubectl rollout status deployment rolling-app --timeout=120s
```

### Verificação — Estado inicial

```bash
kubectl get deployment rolling-app
```

Saída esperada:

```
NAME          READY   UP-TO-DATE   AVAILABLE   AGE
rolling-app   6/6     6            6           30s
```

### Disparar o rolling update

```bash
kubectl set image deployment/rolling-app app=nginx:1.28
```

**Acompanhe o rollout em tempo real:**

```bash
kubectl rollout status deployment/rolling-app
```

Saída esperada (saída em scroll):

```
Waiting for deployment "rolling-app" rollout to finish: 2 out of 6 new replicas have been updated...
Waiting for deployment "rolling-app" rollout to finish: 3 out of 6 new replicas have been updated...
...
deployment "rolling-app" successfully rolled out
```

**Observe os Pods durante o rollout** (execute isso em um terminal separado antes de disparar a atualização):

```bash
kubectl get pods -l app=rolling-app --watch
```

Os alunos devem ver:
1. Novos Pods sendo criados (surge — até 8 no total)
2. Pods antigos sendo terminados (mas nunca mais de 1 por vez)
3. Em nenhum momento menos de 5 Pods existem no estado Ready

### Inspecionar histórico de rollout

```bash
kubectl rollout history deployment/rolling-app
```

Saída esperada:

```
REVISION  CHANGE-CAUSE
1         initial deployment v1
2         <none>
```

### Experimentar com diferentes configurações

**Rollout rápido (agressivo):**

```bash
kubectl patch deployment rolling-app -p '{
  "spec": {"strategy": {"rollingUpdate": {"maxSurge": 3, "maxUnavailable": 2}}}
}'
kubectl set image deployment/rolling-app app=nginx:1.27
kubectl rollout status deployment/rolling-app
```

Isso é mais rápido — até 9 Pods de uma vez, mínimo de 4 disponíveis. O rollout se completa em menos rodadas.

**Rollout lento e seguro (zero indisponível):**

```bash
kubectl patch deployment rolling-app -p '{
  "spec": {"strategy": {"rollingUpdate": {"maxSurge": 1, "maxUnavailable": 0}}}
}'
kubectl set image deployment/rolling-app app=nginx:1.28
kubectl rollout status deployment/rolling-app
```

Este é o mais seguro — sempre 6 Pods disponíveis, um novo Pod por vez. Leva mais tempo.

> **Tabela de referência do Coach:**
>
> | Configuração | Max Pods | Mín Disponíveis | Velocidade | Segurança |
> |---|---|---|---|---|
> | `maxSurge: 2, maxUnavailable: 1` | 8 | 5 | Média | Média |
> | `maxSurge: 3, maxUnavailable: 2` | 9 | 4 | Rápida | Menor |
> | `maxSurge: 1, maxUnavailable: 0` | 7 | 6 | Lenta | Máxima |
> | `maxSurge: "50%", maxUnavailable: "25%"` | 9 | 4 | Rápida | Média |

---

## Tarefa 5: Estratégia Recreate

### Passo a passo

Salve `recreate-app.yaml`:

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

Aplique:

```bash
kubectl apply -f recreate-app.yaml
kubectl rollout status deployment recreate-app --timeout=60s
```

### Verificação — Estado inicial

```bash
kubectl get pods -l app=recreate-app
```

Esperado: 4 Pods, todos `1/1 Running`.

### Disparar a atualização e observar o downtime

**No Terminal 1 — Observe os Pods:**

```bash
kubectl get pods -l app=recreate-app --watch
```

**No Terminal 2 — Dispare a atualização:**

```bash
kubectl set image deployment/recreate-app app=nginx:1.28
```

**O que os alunos devem ver no Terminal 1:**

```
NAME                            READY   STATUS        RESTARTS   AGE
recreate-app-7c9d4f8b5-abc12   1/1     Terminating   0          2m
recreate-app-7c9d4f8b5-def34   1/1     Terminating   0          2m
recreate-app-7c9d4f8b5-ghi56   1/1     Terminating   0          2m
recreate-app-7c9d4f8b5-jkl78   1/1     Terminating   0          2m
recreate-app-7c9d4f8b5-abc12   0/1     Terminating   0          2m
...
(todos os Pods terminados — intervalo onde zero Pods estão rodando)
...
recreate-app-5f8c7d9a1-mno90   0/1     Pending       0          0s
recreate-app-5f8c7d9a1-pqr12   0/1     Pending       0          0s
recreate-app-5f8c7d9a1-stu34   0/1     Pending       0          0s
recreate-app-5f8c7d9a1-vwx56   0/1     Pending       0          0s
recreate-app-5f8c7d9a1-mno90   1/1     Running       0          3s
...
```

A observação principal: **há um intervalo onde zero Pods estão rodando**. Esta é a janela de downtime.

### Verificar via eventos do Deployment

```bash
kubectl describe deployment recreate-app | grep -A20 Events
```

Eventos esperados:

```
Events:
  Type    Reason             Age   From                   Message
  ----    ------             ----  ----                   -------
  Normal  ScalingReplicaSet  2m    deployment-controller  Scaled down replica set recreate-app-7c9d4f8b5 to 0 from 4
  Normal  ScalingReplicaSet  1m    deployment-controller  Scaled up replica set recreate-app-5f8c7d9a1 to 4 from 0
```

Nota: O ReplicaSet antigo escala para **0 primeiro**, depois o novo ReplicaSet escala para 4. Isso confirma o intervalo de downtime.

> **Dica para o Coach:** Pergunte aos alunos: "Quando vocês escolheriam Recreate em vez de RollingUpdate?" Boas respostas:
> - Migrações de schema de banco de dados onde versões antiga e nova do código são incompatíveis
> - Workloads singleton que mantêm locks exclusivos (ex: um cron runner que não pode ter instâncias concorrentes)
> - Workloads GPU onde apenas um Pod pode reivindicar o dispositivo
> - A aplicação em si crasha quando duas versões rodam simultaneamente

---

## Tarefa 6: Tratamento de Depreciação de API

### Passo a passo

**Verifique as versões de API disponíveis:**

```bash
kubectl api-versions | sort
```

Os alunos devem ver uma lista incluindo `apps/v1`, `networking.k8s.io/v1`, etc. mas **não** `extensions/v1beta1`.

**Crie o manifesto legado:**

Salve `old-ingress.yaml`:

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

**Tente aplicá-lo:**

```bash
kubectl apply -f old-ingress.yaml
```

Erro esperado:

```
error: resource mapping not found for name: "legacy-ingress" namespace: "" from "old-ingress.yaml": no matches for kind "Ingress" in version "extensions/v1beta1"
ensure CRDs are installed first
```

> **Dica para o Coach:** Isto é exatamente o que acontece quando você faz upgrade de um cluster e versões antigas da API foram removidas. O API server não reconhece mais `extensions/v1beta1`.

**Instale o kubectl-convert (se disponível):**

```bash
# Opção 1: Via Krew
kubectl krew install convert

# Opção 2: Download direto
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl-convert"
chmod +x kubectl-convert
sudo mv kubectl-convert /usr/local/bin/
```

**Converta o manifesto:**

```bash
kubectl convert -f old-ingress.yaml --output-version networking.k8s.io/v1
```

Saída esperada (YAML com a nova versão da API e nomes de campos atualizados).

> **Dica para o Coach:** Se `kubectl-convert` não estiver disponível ou não funcionar no ambiente do lab, tudo bem — a migração manual no próximo passo é o resultado de aprendizado importante.

**Migração manual — crie o manifesto atualizado:**

Salve `new-ingress.yaml`:

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

**Mudanças principais a destacar:**

| Antigo (`extensions/v1beta1`) | Novo (`networking.k8s.io/v1`) |
|---|---|
| `apiVersion: extensions/v1beta1` | `apiVersion: networking.k8s.io/v1` |
| `backend.serviceName: legacy-svc` | `backend.service.name: legacy-svc` |
| `backend.servicePort: 80` | `backend.service.port.number: 80` |
| `pathType` não obrigatório | `pathType: Prefix` **obrigatório** |

**Explore outras ferramentas de detecção de depreciação:**

```bash
# Liste todos os recursos de API com suas versões preferidas
kubectl api-resources -o wide | head -20

# Consulte o guia de depreciação do Kubernetes
echo "Reference: https://kubernetes.io/docs/reference/using-api/deprecation-guide/"
```

> **Dica para o Coach:** Outras ferramentas para detectar APIs depreciadas em produção:
> - **kubent** (kube-no-trouble): Escaneia clusters em execução para APIs depreciadas
> - **pluto**: Escaneia releases Helm e arquivos de manifesto
> - **kubepug**: Verificador pré-upgrade para depreciações de API do Kubernetes
>
> Essas são boas de mencionar mas não são obrigatórias para este lab.

---

## Limpeza

```bash
# Task 1
kubectl delete -f blue-green.yaml 2>/dev/null
kubectl delete -f webapp-svc.yaml 2>/dev/null

# Task 2
kubectl delete -f canary-app.yaml 2>/dev/null
kubectl delete -f canary-ingress.yaml 2>/dev/null

# Task 3
kubectl delete -f canary-httproute.yaml 2>/dev/null
kubectl delete -f gateway.yaml 2>/dev/null

# Task 4
kubectl delete -f rolling-deep.yaml 2>/dev/null

# Task 5
kubectl delete -f recreate-app.yaml 2>/dev/null

# Task 6
kubectl delete -f old-ingress.yaml 2>/dev/null
kubectl delete -f new-ingress.yaml 2>/dev/null

# Break & Fix
kubectl delete -f broken-bg-svc.yaml 2>/dev/null
kubectl delete -f broken-canary-ingress.yaml 2>/dev/null
kubectl delete -f broken-rolling.yaml 2>/dev/null

# Opcional: Remova o NGINX Ingress Controller e o Contour (apenas se não forem necessários para outros desafios)
# kubectl delete -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
# kubectl delete -f https://projectcontour.io/quickstart/contour.yaml
# kubectl delete -f https://github.com/kubernetes-sigs/gateway-api/releases/latest/download/standard-install.yaml
```

---

## Problemas Comuns

| Problema | Causa | Correção |
|---------|-------|-----|
| `curl: (7) Failed to connect to localhost port 80` | Cluster Kind não configurado com mapeamentos de porta para o NGINX Ingress | Use `kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80` e curl em `:8080` |
| Peso do canary não tem efeito | Faltando a annotation `canary: "true"` | Adicione `nginx.ingress.kubernetes.io/canary: "true"` ao Ingress canary |
| 100% do tráfego vai para o canary em vez de 20% | Não existe Ingress principal para o mesmo host | Crie um Ingress não-canary para o mesmo host apontando para o Service stable |
| CRDs da Gateway API não encontrados | CRDs não instalados antes do Contour | Execute `kubectl apply -f .../standard-install.yaml` primeiro, depois instale o Contour |
| Service Envoy não tem NodePort | Tipo de Service é ClusterIP por padrão | Use `kubectl port-forward -n projectcontour svc/envoy 9080:80` |
| Rolling update travado em rollout parcial | Readiness probe falhando nos novos Pods | Verifique a configuração da probe: `kubectl describe pod <new-pod>`, corrija porta/path da probe |
| `kubectl convert` não encontrado | Plugin não instalado | Instale via Krew (`kubectl krew install convert`) ou download direto |
| `extensions/v1beta1` rejeitado pelo API server | Versão da API removida no K8s 1.22+ | Migre o manifesto para `networking.k8s.io/v1` com nomes de campos atualizados |
| Service Blue/Green não retorna resposta | Selector não corresponde a nenhum label dos Pods | Verifique `kubectl get endpoints <svc>` — vazio significa que não há correspondência de labels |
| HPA do Desafio 10 conflita com réplicas manuais | HPA sobrescreve `spec.replicas` no Deployment | Delete o HPA antes de gerenciar réplicas manualmente: `kubectl delete hpa <name>` |

## Matriz de Decisão de Estratégia (Referência do Coach)

Use esta tabela para ajudar os alunos a escolher a estratégia correta para diferentes cenários:

| Cenário | Melhor Estratégia | Por quê |
|----------|--------------|-----|
| Upgrade de web app sem downtime | **RollingUpdate** | Substituição gradual, sempre disponível |
| Migração de banco de dados com mudanças de schema | **Recreate** | Não é possível rodar código antigo+novo contra schemas diferentes |
| Release de alto risco, rollback instantâneo necessário | **Blue/Green** | Ambas as versões rodando, a troca é instantânea |
| Validar nova versão com tráfego real | **Canary** | Pequena % dos usuários testa a nova versão |
| Workload GPU (acesso exclusivo ao dispositivo) | **Recreate** | Apenas um Pod pode reivindicar a GPU por vez |
| Rollout gradual com monitoramento | **Canary → RollingUpdate** | Canary primeiro (10%), depois rolling update para o restante |
| API stateless com bons health checks | **RollingUpdate** (`maxUnavailable: 0`) | Rolling update mais seguro — nunca menos Pods que o desejado |
