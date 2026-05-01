# Desafio 06 — Ingress e Gateway API

[< Desafio Anterior](Challenge-05.md) | **[Início](../README.md)** | [Próximo Desafio >](Challenge-07.md)

## Introdução

Se você já configurou **nginx** ou **Apache** como um proxy reverso — escrevendo blocos `server` com `server_name`, diretivas `location` e regras `proxy_pass` — você já entende o problema que Ingress e Gateway API resolvem.

Em um servidor Linux tradicional, você expõe múltiplas aplicações web atrás de um único IP configurando virtual hosts e roteamento baseado em caminho na configuração do seu proxy reverso. No Kubernetes, **Ingress** e a mais recente **Gateway API** são os equivalentes declarativos: você descreve _qual_ tráfego deve ir _para onde_, e um controller (o proxy reverso em execução) faz acontecer.

**Ingress** é o padrão desde o Kubernetes 1.1, mas tem limitações bem conhecidas — nenhuma forma padrão de lidar com tráfego TCP/UDP, extensibilidade limitada, e um único recurso tentando servir tanto operadores de cluster quanto desenvolvedores de aplicações. **Gateway API** é o sucessor oficial: é mais expressivo, orientado a papéis, e já está GA desde o Kubernetes 1.29. Neste desafio, você aprenderá ambos.

## Descrição

Sua missão é:

1. **Recriar seu cluster Kind com suporte a Ingress**

   Seu cluster Kind atual provavelmente não tem os mapeamentos de porta necessários para Ingress. Delete-o e crie um novo usando esta configuração:

   ```yaml
   # kind-ingress.yaml
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
   kind delete cluster --name fasthack
   kind create cluster --name fasthack --config kind-ingress.yaml
   ```

2. **Instalar o NGINX Ingress Controller**

   Faça deploy do NGINX Ingress Controller usando o manifesto específico para Kind:

   ```bash
   kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
   ```

   Aguarde até estar pronto:

   ```bash
   kubectl wait --namespace ingress-nginx \
     --for=condition=ready pod \
     --selector=app.kubernetes.io/component=controller \
     --timeout=90s
   ```

3. **Fazer deploy de duas aplicações backend**

   Crie duas aplicações web simples para rotear tráfego:

   ```yaml
   # app1.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: app1
     namespace: default
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
     namespace: default
   spec:
     selector:
       app: app1
     ports:
     - port: 80
       targetPort: 5678
   ```

   Crie um manifesto similar para `app2` (com `"-text=Hello from App2"`), e então aplique ambos.

4. **Criar um Ingress com roteamento baseado em host**

   Escreva um recurso Ingress que roteia:
   - `app1.localhost` → `app1-svc`
   - `app2.localhost` → `app2-svc`

   Verifique com:

   ```bash
   curl http://app1.localhost/
   curl http://app2.localhost/
   ```

   > **Nota:** Na maioria dos sistemas, `*.localhost` resolve para `127.0.0.1` automaticamente. Se não funcionar no seu, adicione entradas no `/etc/hosts` (Linux/Mac) ou `C:\Windows\System32\drivers\etc\hosts` (Windows).

5. **Criar um Ingress com roteamento baseado em caminho**

   Escreva um _segundo_ recurso Ingress (ou modifique o primeiro) que roteia por caminho em um único hostname:
   - `localhost/app1` → `app1-svc`
   - `localhost/app2` → `app2-svc`

   Use `pathType: Prefix` e verifique com:

   ```bash
   curl http://localhost/app1
   curl http://localhost/app2
   ```

6. **Instalar Gateway API e criar um HTTPRoute**

   Instale os CRDs da Gateway API:

   ```bash
   kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
   ```

   O NGINX Ingress Controller que você já instalou suporta Gateway API. Habilite-o adicionando a flag `--enable-gateway-api`, ou instale um controller dedicado para Gateway API. Para este laboratório, use o NGINX Gateway Fabric:

   ```bash
   kubectl apply -f https://github.com/nginx/nginx-gateway-fabric/releases/download/v1.6.2/nginx-gateway-fabric.yaml
   ```

   Em seguida, crie um **Gateway** e **HTTPRoute**:

   ```yaml
   # gateway.yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: Gateway
   metadata:
     name: my-gateway
     namespace: default
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

   ```yaml
   # httproute.yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: HTTPRoute
   metadata:
     name: app-routes
     namespace: default
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

   Inspecione os recursos:

   ```bash
   kubectl get gateways
   kubectl get httproutes
   kubectl describe httproute app-routes
   ```

7. **Comparar Ingress vs Gateway API**

   Estude as diferenças e esteja preparado para explicar:
   - Como Gateway API separa responsabilidades (dono da infraestrutura → `Gateway`, desenvolvedor da aplicação → `HTTPRoute`)
   - Quais funcionalidades Gateway API adiciona (divisão de tráfego, correspondência de headers, espelhamento de requisições)
   - Por que Gateway API é o caminho recomendado para novos projetos

## Critérios de Sucesso

- [ ] Seu cluster Kind foi criado com `extraPortMappings` para as portas 80 e 443
- [ ] O NGINX Ingress Controller está rodando no namespace `ingress-nginx`
- [ ] Você consegue acessar `app1` e `app2` via **roteamento baseado em host** (`app1.localhost`, `app2.localhost`)
- [ ] Você consegue acessar `app1` e `app2` via **roteamento baseado em caminho** (`localhost/app1`, `localhost/app2`)
- [ ] Os CRDs da Gateway API estão instalados (`kubectl get crds | grep gateway`)
- [ ] Um recurso `Gateway` existe e mostra status `Accepted` ou `Programmed`
- [ ] Um `HTTPRoute` está vinculado ao Gateway e roteia tráfego para seus Services backend
- [ ] Você consegue explicar pelo menos três diferenças entre Ingress e Gateway API

## Referência Linux ↔ Kubernetes

| Conceito Linux | Equivalente Kubernetes |
|---|---|
| nginx / Apache como proxy reverso | Ingress Controller (ex: NGINX Ingress) |
| Blocos `server { }` / VirtualHosts | Campo `rules[].host` do recurso Ingress |
| `location /path { proxy_pass ... }` | Roteamento baseado em caminho do Ingress (`rules[].http.paths[]`) |
| `server_name app1.example.com` | Roteamento baseado em host (`rules[].host`) |
| Modelo frontend/backend do HAProxy | Gateway API: `Gateway` (frontend) + `HTTPRoute` (backend) |
| Terminação SSL (certbot / Let's Encrypt) | Seção TLS no Ingress ou `listeners[].tls` do Gateway |
| `nginx -t` (teste de configuração) | `kubectl describe ingress` / `kubectl describe httproute` |
| `/etc/nginx/sites-enabled/` | `ingressClassName` seleciona qual controller trata o recurso |

## Dicas

<details>
<summary>Dica 1: Recurso Ingress baseado em host</summary>

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: host-routing
  namespace: default
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

O campo `ingressClassName: nginx` diz ao Kubernetes qual Ingress Controller deve tratar este recurso.
</details>

<details>
<summary>Dica 2: Recurso Ingress baseado em caminho</summary>

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: path-routing
  namespace: default
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

**Importante:** `pathType` pode ser `Exact` ou `Prefix`. Com `Prefix`, `/app1` corresponde a `/app1`, `/app1/` e `/app1/qualquer-coisa`.
</details>

<details>
<summary>Dica 3: Depurando problemas de Ingress</summary>

Se seu Ingress não está funcionando:

```bash
# Check the Ingress has an ADDRESS assigned
kubectl get ingress

# If ADDRESS is blank, the controller isn't processing it.
# Verify the controller is running:
kubectl get pods -n ingress-nginx

# Check for errors in the Ingress Controller logs:
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=50

# Verify your ingressClassName matches what the controller expects:
kubectl get ingressclass
```

Problema comum: se você vê `<none>` sob ADDRESS, ou o controller não está instalado ou o `ingressClassName` não corresponde.
</details>

<details>
<summary>Dica 4: Gateway API — verificando sua configuração</summary>

```bash
# Verify CRDs are installed
kubectl get crds | grep gateway.networking.k8s.io

# Check GatewayClass is available
kubectl get gatewayclass

# Check Gateway status — look for "Accepted" or "Programmed"
kubectl get gateway my-gateway -o yaml | grep -A 5 conditions

# Check HTTPRoute status — look for "Accepted" under parentRefs
kubectl describe httproute app-routes
```

Se o Gateway permanecer em `Pending`, o controller da GatewayClass pode não estar rodando. Verifique se os pods do controller estão ativos.
</details>

<details>
<summary>Dica 5: Ingress vs Gateway API — diferenças principais</summary>

| Aspecto | Ingress | Gateway API |
|---|---|---|
| **Separação de papéis** | Recurso único para toda a configuração | `Gateway` (infra) + `HTTPRoute` (dev da aplicação) |
| **Suporte a protocolos** | Apenas HTTP/HTTPS (pela especificação) | HTTP, gRPC, TCP, UDP, TLS via rotas tipadas |
| **Extensibilidade** | Annotations (não portáveis) | Objetos de política tipados e versionados |
| **Divisão de tráfego** | Não nativo | Divisão nativa baseada em peso |
| **Correspondência de headers** | Dependente de annotations | `matches` de primeira classe no HTTPRoute |
| **Status** | Estável mas congelado | GA e evoluindo ativamente |
| **Recomendação** | Workloads existentes | Novos projetos daqui em diante |

</details>

## Recursos de Aprendizado

- [Kubernetes Ingress](https://kubernetes.io/docs/concepts/services-networking/ingress/)
- [Kubernetes Ingress Controllers](https://kubernetes.io/docs/concepts/services-networking/ingress-controllers/)
- [Kubernetes Gateway API](https://kubernetes.io/docs/concepts/services-networking/gateway/)
- [Gateway API Official Site](https://gateway-api.sigs.k8s.io/)
- [Kind — Ingress Setup](https://kind.sigs.k8s.io/docs/user/ingress/)
- [NGINX Ingress Controller — Kind Guide](https://kubernetes.github.io/ingress-nginx/deploy/#quick-start)

## Quebra & Conserta 🔧

Após completar o desafio, tente estes cenários de diagnóstico:

### Cenário 1: Ingress sem ADDRESS

Um recurso Ingress foi criado mas `kubectl get ingress` mostra a coluna ADDRESS em branco:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: broken-ingress
  namespace: default
spec:
  rules:
  - host: broken.localhost
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: app1-svc
            port:
              number: 80
```

Aplique e investigue. Por que não há ADDRESS? Como você corrige?

> 💡 **Causa raiz:** O campo `ingressClassName` está faltando. Sem ele, nenhum Ingress Controller reivindica o recurso. Adicione `ingressClassName: nginx` à seção `spec`.

### Cenário 2: ingressClassName errado

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: wrong-class
  namespace: default
spec:
  ingressClassName: traefik
  rules:
  - host: wrong.localhost
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: app1-svc
            port:
              number: 80
```

Aplique isso e tente `curl http://wrong.localhost/`. O que acontece? Como você diagnostica e corrige?

> 💡 **Causa raiz:** `ingressClassName: traefik` não corresponde a nenhum controller instalado. Execute `kubectl get ingressclass` para ver as classes disponíveis e altere para `nginx`.

### Cenário 3: Service backend não existe

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: missing-backend
  namespace: default
spec:
  ingressClassName: nginx
  rules:
  - host: ghost.localhost
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: does-not-exist
            port:
              number: 80
```

Aplique isso e `curl http://ghost.localhost/`. Qual código de status HTTP você recebe? Verifique os logs do Ingress Controller para entender o porquê.

> 💡 **Causa raiz:** O Service `does-not-exist` não foi encontrado. O NGINX Ingress Controller retorna um **503 Service Temporarily Unavailable**. Verifique os logs com `kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=20` e crie o Service que está faltando.
