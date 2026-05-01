# Solução 06 — Ingress e Gateway API

[< Voltar para o Desafio](../Student/Challenge-06.md) | **[Home](README.md)**

## Pré-requisitos

Este desafio requer um cluster Kind novo com mapeamentos de porta específicos. Os alunos **devem** deletar qualquer cluster existente e iniciar com a configuração pronta para Ingress.

---

## Tarefa 1: Recrie o Cluster Kind com Suporte a Ingress

### Passo a passo

Salve como `kind-ingress.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
```

```bash
# Delete qualquer cluster existente
kind delete cluster --name fasthack

# Crie o novo cluster com mapeamentos de porta para Ingress
kind create cluster --name fasthack --config kind-ingress.yaml
```

Saída esperada:

```
Creating cluster "fasthack" ...
 ✓ Ensuring node image (kindest/node:v1.36.x) 🖼
 ✓ Preparing nodes 📦
 ✓ Writing configuration 📜
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI ��
 ✓ Installing StorageClass 💾
Set kubectl context to "kind-fasthack"
```

### Verificação

```bash
# Confirme que o nó tem o label ingress-ready
kubectl get nodes --show-labels | grep ingress-ready
```

Saída esperada: `ingress-ready=true` aparece nos labels.

```bash
# Confirme os mapeamentos de porta do lado do Docker
docker port fasthack-control-plane
```

Saída esperada:

```
80/tcp -> 0.0.0.0:80
443/tcp -> 0.0.0.0:443
6443/tcp -> 127.0.0.1:XXXXX
```

> **Dica do Coach:** Se as portas 80/443 já estiverem em uso no host (Apache, nginx, IIS, outro container), a criação do cluster Kind falhará. Peça aos alunos para parar quaisquer serviços conflitantes primeiro.

---

## Tarefa 2: Instale o NGINX Ingress Controller

### Passo a passo

```bash
# Instale o manifesto do NGINX Ingress Controller específico para Kind
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
```

Saída esperada: múltiplos recursos criados (namespace, serviceaccount, configmap, roles, deployment, service, etc.).

```bash
# Aguarde o Pod do controller ficar pronto
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
```

Saída esperada:

```
pod/ingress-nginx-controller-xxxxx condition met
```

### Verificação

```bash
# Confirme que o controller está em execução
kubectl get pods -n ingress-nginx
```

Saída esperada:

```
NAME                                        READY   STATUS    RESTARTS   AGE
ingress-nginx-controller-xxxxxxxxxx-xxxxx   1/1     Running   0          30s
```

```bash
# Confirme que a IngressClass foi criada
kubectl get ingressclass
```

Saída esperada:

```
NAME    CONTROLLER                      PARAMETERS   AGE
nginx   k8s.io/ingress-nginx            <none>       30s
```

> **Dica do Coach:** O manifesto específico para Kind inclui uma configuração de DaemonSet com `hostPort` em vez de um Service LoadBalancer. Isso é o que torna `localhost:80` acessível — o Pod do controller se vincula diretamente às portas 80 e 443 do nó via `hostPort`.

---

## Tarefa 3: Implante Duas Aplicações Backend

### Passo a passo

Salve como `app1.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app1
spec:
  replicas: 1
  selector:
    matchLabels:
      app: app1
  template:
    metadata:
      labels:
        app: app1
    spec:
      containers:
      - name: app1
        image: hashicorp/http-echo:latest
        args:
        - "-text=Hello from App1"
        ports:
        - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: app1-svc
spec:
  selector:
    app: app1
  ports:
  - port: 80
    targetPort: 5678
```

Salve como `app2.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app2
spec:
  replicas: 1
  selector:
    matchLabels:
      app: app2
  template:
    metadata:
      labels:
        app: app2
    spec:
      containers:
      - name: app2
        image: hashicorp/http-echo:latest
        args:
        - "-text=Hello from App2"
        ports:
        - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: app2-svc
spec:
  selector:
    app: app2
  ports:
  - port: 80
    targetPort: 5678
```

```bash
kubectl apply -f app1.yaml
kubectl apply -f app2.yaml
```

### Verificação

```bash
kubectl wait --for=condition=ready pod -l app=app1 --timeout=60s
kubectl wait --for=condition=ready pod -l app=app2 --timeout=60s
kubectl get pods -l 'app in (app1,app2)'
```

Saída esperada:

```
NAME                    READY   STATUS    RESTARTS   AGE
app1-xxxxxxxxxx-xxxxx   1/1     Running   0          15s
app2-xxxxxxxxxx-xxxxx   1/1     Running   0          15s
```

```bash
# Verifique se os Services têm Endpoints
kubectl get endpoints app1-svc app2-svc
```

Saída esperada: cada Service mostra um IP de Pod na porta 5678.

---

## Tarefa 4: Roteamento Ingress Baseado em Host

### Passo a passo

Salve como `host-ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: host-routing
spec:
  ingressClassName: nginx
  rules:
  - host: app1.localhost
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: app1-svc
            port:
              number: 80
  - host: app2.localhost
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: app2-svc
            port:
              number: 80
```

```bash
kubectl apply -f host-ingress.yaml
```

Saída esperada:

```
ingress.networking.k8s.io/host-routing created
```

### Verificação

```bash
# Verifique se o Ingress tem um ADDRESS
kubectl get ingress host-routing
```

Saída esperada:

```
NAME           CLASS   HOSTS                          ADDRESS     PORTS   AGE
host-routing   nginx   app1.localhost,app2.localhost   localhost   80      10s
```

> **Nota:** O ADDRESS pode levar 10-30 segundos para aparecer. Se ficar em branco, verifique se `ingressClassName: nginx` está definido.

```bash
# Teste roteamento baseado em host
curl -s http://app1.localhost/
```

Saída esperada:

```
Hello from App1
```

```bash
curl -s http://app2.localhost/
```

Saída esperada:

```
Hello from App2
```

> **Dica do Coach:** Na maioria dos sistemas, `*.localhost` resolve para `127.0.0.1` automaticamente. Se não funcionar na máquina do aluno (especialmente Windows), eles precisam adicionar entradas no arquivo hosts:
> - **Linux/Mac:** `echo "127.0.0.1 app1.localhost app2.localhost" | sudo tee -a /etc/hosts`
> - **Windows:** Adicione `127.0.0.1 app1.localhost` e `127.0.0.1 app2.localhost` em `C:\Windows\System32\drivers\etc\hosts`
>
> Alternativamente, use a flag `-H` com curl: `curl -s -H "Host: app1.localhost" http://localhost/`

---

## Tarefa 5: Roteamento Ingress Baseado em Path

### Passo a passo

Salve como `path-ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: path-routing
spec:
  ingressClassName: nginx
  rules:
  - host: localhost
    http:
      paths:
      - path: /app1
        pathType: Prefix
        backend:
          service:
            name: app1-svc
            port:
              number: 80
      - path: /app2
        pathType: Prefix
        backend:
          service:
            name: app2-svc
            port:
              number: 80
```

```bash
kubectl apply -f path-ingress.yaml
```

Saída esperada:

```
ingress.networking.k8s.io/path-routing created
```

### Verificação

```bash
kubectl get ingress path-routing
```

Saída esperada:

```
NAME           CLASS   HOSTS       ADDRESS     PORTS   AGE
path-routing   nginx   localhost   localhost   80      10s
```

```bash
curl -s http://localhost/app1
```

Saída esperada:

```
Hello from App1
```

```bash
curl -s http://localhost/app2
```

Saída esperada:

```
Hello from App2
```

> **Dica do Coach:** `pathType: Prefix` significa que `/app1` corresponde a `/app1`, `/app1/` e `/app1/anything`. Se os alunos usarem `pathType: Exact`, apenas o caminho exato `/app1` corresponderia (sem barra final ou sub-caminhos). Este é um ponto comum de confusão — pergunte aos alunos: "O que aconteceria se vocês mudassem para `Exact`?"

---

## Tarefa 6: Gateway API com HTTPRoute

### Passo a passo

**6a. Instale as CRDs da Gateway API**

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
```

Saída esperada: múltiplas CRDs criadas (gateways, gatewayclasses, httproutes, referencegrants, etc.).

```bash
# Verifique se as CRDs estão instaladas
kubectl get crds | grep gateway.networking.k8s.io
```

Saída esperada:

```
gatewayclasses.gateway.networking.k8s.io          2025-xx-xxTxx:xx:xxZ
gateways.gateway.networking.k8s.io                2025-xx-xxTxx:xx:xxZ
grpcroutes.gateway.networking.k8s.io              2025-xx-xxTxx:xx:xxZ
httproutes.gateway.networking.k8s.io              2025-xx-xxTxx:xx:xxZ
referencegrants.gateway.networking.k8s.io         2025-xx-xxTxx:xx:xxZ
```

**6b. Instale o NGINX Gateway Fabric**

```bash
kubectl apply -f https://github.com/nginx/nginx-gateway-fabric/releases/download/v1.6.2/nginx-gateway-fabric.yaml
```

Saída esperada: namespace, serviceaccount, clusterroles, deployment e GatewayClass criados.

```bash
# Aguarde o controller do Gateway Fabric ficar pronto
kubectl wait --namespace nginx-gateway \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/instance=nginx-gateway-fabric \
  --timeout=120s
```

Saída esperada:

```
pod/nginx-gateway-fabric-xxxxxxxxxx-xxxxx condition met
```

```bash
# Verifique se a GatewayClass existe
kubectl get gatewayclass
```

Saída esperada:

```
NAME    CONTROLLER                          ACCEPTED   AGE
nginx   gateway.nginx.org/nginx-gateway-fabric-controller   True       30s
```

**6c. Crie o recurso Gateway**

Salve como `gateway.yaml`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: my-gateway
spec:
  gatewayClassName: nginx
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: Same
```

```bash
kubectl apply -f gateway.yaml
```

**6d. Crie o HTTPRoute**

Salve como `httproute.yaml`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: app-routes
spec:
  parentRefs:
  - name: my-gateway
  hostnames:
  - "demo.localhost"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /app1
    backendRefs:
    - name: app1-svc
      port: 80
  - matches:
    - path:
        type: PathPrefix
        value: /app2
    backendRefs:
    - name: app2-svc
      port: 80
```

```bash
kubectl apply -f httproute.yaml
```

### Verificação

```bash
# Verifique o status do Gateway — procure por Accepted/Programmed
kubectl get gateway my-gateway
```

Saída esperada:

```
NAME         CLASS   ADDRESS   PROGRAMMED   AGE
my-gateway   nginx   ...       True         30s
```

```bash
# Verifique o status do HTTPRoute
kubectl get httproute app-routes
```

Saída esperada:

```
NAME         HOSTNAMES            AGE
app-routes   ["demo.localhost"]   15s
```

```bash
# Inspecione detalhes
kubectl describe httproute app-routes
```

Procure por `Accepted: True` na seção de status dos `parentRefs`.

> **Dica do Coach:** Testar o HTTPRoute via `curl http://demo.localhost/app1` depende do tipo de Service do controller Gateway e da porta. O NGINX Gateway Fabric cria um Service LoadBalancer, que fica em `Pending` no Kind. Para testar, os alunos podem fazer port-forward para o gateway:
>
> ```bash
> # Encontre o service do gateway
> kubectl -n nginx-gateway get svc
>
> # Port-forward para o service do NGINX Gateway Fabric
> kubectl -n nginx-gateway port-forward svc/nginx-gateway-fabric 8080:80 &
>
> # Teste (use -H para definir o header Host já que estamos passando via localhost:8080)
> curl -s -H "Host: demo.localhost" http://localhost:8080/app1
> curl -s -H "Host: demo.localhost" http://localhost:8080/app2
> ```
>
> Saída esperada: `Hello from App1` e `Hello from App2` respectivamente.

---

## Tarefa 7: Compare Ingress vs Gateway API

Esta é uma tarefa de discussão/conhecimento. Pontos-chave que os alunos devem conseguir articular:

| Aspecto | Ingress | Gateway API |
|--------|---------|-------------|
| **Separação de funções** | Recurso Ingress único para tudo | `GatewayClass` (provedor de infra) → `Gateway` (operador do cluster) → `HTTPRoute` (desenvolvedor da app) |
| **Suporte a protocolos** | Apenas HTTP/HTTPS (pela spec) | HTTP, gRPC, TCP, UDP, TLS via recursos de rota tipados |
| **Extensibilidade** | Annotations específicas do vendor (não portáveis) | Recursos de policy tipados e versionados (portáveis entre implementações) |
| **Divisão de tráfego** | Não nativo (depende de annotations) | Divisão nativa baseada em peso nos `backendRefs` |
| **Correspondência de headers** | Depende de annotations | `matches` de primeira classe nas regras do HTTPRoute |
| **Feedback de status** | Mínimo | Condições de status ricas em cada recurso |
| **Maturidade** | Estável mas congelado — sem novos recursos | GA desde K8s 1.29, evoluindo ativamente |

> **Dica do Coach:** Enquadre assim: "Ingress é como um único arquivo nginx.conf que uma pessoa edita. Gateway API é como dividir essa configuração em: a equipe de infraestrutura gerenciando o bloco `server` (Gateway) e a equipe da app gerenciando os blocos `location` (HTTPRoute). Quem gerencia o quê agora é explícito."

---

## Problemas Comuns

| Problema | Causa Provável | Correção |
|---------|-------------|-----|
| `curl: (7) Failed to connect to localhost port 80` | Cluster Kind não criado com `extraPortMappings` | Delete o cluster e recrie com a configuração `kind-ingress.yaml` |
| ADDRESS do Ingress é `<none>` | `ingressClassName: nginx` ausente | Adicione `ingressClassName: nginx` à spec do Ingress |
| `curl app1.localhost` retorna 404 | Path ou host errado nas regras do Ingress | Verifique `kubectl describe ingress host-routing` para as regras |
| `*.localhost` não resolve | SO não faz auto-resolução de `*.localhost` | Adicione entradas no arquivo hosts ou use `curl -H "Host: app1.localhost" http://localhost/` |
| Gateway fica em `Pending` | Controller da GatewayClass não está em execução | Verifique `kubectl get pods -n nginx-gateway` |
| Pod do NGINX Gateway Fabric em CrashLoopBackOff | Conflito de porta 80 com o Ingress controller | Eles compartilham a porta 80 — remova o Ingress controller ou use uma porta diferente para o Gateway |
| Porta 80/443 já em uso no host | Outro serviço (Apache, IIS, etc.) usando a porta | Pare o serviço conflitante antes de criar o cluster Kind |
| CRDs da Gateway API não encontradas | `kubectl apply` das CRDs falhou silenciosamente | Re-execute o comando de instalação das CRDs e verifique `kubectl get crds | grep gateway` |
