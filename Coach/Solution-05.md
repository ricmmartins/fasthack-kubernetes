# Solução 05 — Services e Rede

[< Voltar para o Desafio](../Student/Challenge-05.md) | **[Home](README.md)**

## Pré-requisitos

Os alunos devem ter um cluster Kind em execução. Se completaram o cluster do Desafio 06 (com mapeamentos de porta para Ingress), este também funciona — é um superset. Se estiverem começando do zero:

```bash
kind create cluster --name fasthack
```

---

## Tarefa 1: Service ClusterIP

### Passo a passo

**1a. Crie o Deployment**

Salve como `web-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: nginx
          image: nginx:stable
          ports:
            - containerPort: 80
```

```bash
kubectl apply -f web-deployment.yaml
```

Saída esperada:

```
deployment.apps/web created
```

**1b. Crie o Service ClusterIP**

Salve como `web-svc.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-svc
spec:
  selector:
    app: web
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
```

```bash
kubectl apply -f web-svc.yaml
```

Saída esperada:

```
service/web-svc created
```

### Verificação

```bash
# Confirme que o Service existe e tem um ClusterIP
kubectl get svc web-svc
```

Saída esperada:

```
NAME      TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
web-svc   ClusterIP   10.96.x.x     <none>        80/TCP    5s
```

```bash
# Confirme os Endpoints (deve listar 3 IPs de Pods)
kubectl get endpoints web-svc
```

Saída esperada:

```
NAME      ENDPOINTS                                    AGE
web-svc   10.244.0.5:80,10.244.0.6:80,10.244.0.7:80   10s
```

```bash
# Teste conectividade de dentro do cluster
kubectl run tmp-curl --rm -it --restart=Never --image=curlimages/curl -- curl -s http://web-svc
```

Saída esperada: o HTML da página de boas-vindas padrão do nginx. A linha `<title>Welcome to nginx!</title>` confirma que funciona.

> **Dica do Coach:** Se os alunos virem `<none>` para Endpoints, peça que comparem `kubectl get svc web-svc -o yaml | grep -A2 selector` com `kubectl get pods --show-labels`. Labels incompatíveis são a causa #1.

---

## Tarefa 2: Service NodePort

### Passo a passo

Salve como `web-nodeport.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-nodeport
spec:
  type: NodePort
  selector:
    app: web
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
```

```bash
kubectl apply -f web-nodeport.yaml
```

### Verificação

```bash
# Veja a NodePort atribuída (faixa 30000–32767)
kubectl get svc web-nodeport
```

Saída esperada:

```
NAME           TYPE       CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE
web-nodeport   NodePort   10.96.x.x     <none>        80:3XXXX/TCP   5s
```

```bash
# Obtenha o IP do nó e a NodePort, então faça curl do host
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
NODE_PORT=$(kubectl get svc web-nodeport -o jsonpath='{.spec.ports[0].nodePort}')
echo "Curling http://${NODE_IP}:${NODE_PORT}"
curl -s http://${NODE_IP}:${NODE_PORT} | head -5
```

Saída esperada: primeiras linhas do HTML da página de boas-vindas do nginx.

> **Dica do Coach:** No Kind, o "nó" é um container Docker. `docker ps` o mostra. O InternalIP do nó é acessível do host porque o Kind configura a rede Docker. Se o curl travar, peça aos alunos para verificar `docker ps` para confirmar que o container do nó Kind está em execução.

---

## Tarefa 3: Resolução DNS

### Passo a passo

```bash
# Inicie um Pod temporário de depuração
kubectl run tmp-dns --rm -it --restart=Never --image=busybox:stable -- sh
```

Dentro do Pod, execute:

```sh
# Resolva o nome curto (funciona dentro do mesmo namespace)
nslookup web-svc
```

Saída esperada:

```
Server:    10.96.0.10
Address:   10.96.0.10:53

Name:      web-svc.default.svc.cluster.local
Address:   10.96.X.X
```

```sh
# Resolva o FQDN
nslookup web-svc.default.svc.cluster.local
```

Saída esperada: mesmo ClusterIP acima.

```sh
# Inspecione a configuração DNS
cat /etc/resolv.conf
```

Saída esperada:

```
search default.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5
```

```sh
# Acesse o service pelo nome
wget -qO- http://web-svc
```

Saída esperada: página de boas-vindas do nginx.

```sh
exit
```

**Teste cross-namespace:**

```bash
# Crie um segundo namespace e teste a resolução FQDN
kubectl create namespace other
kubectl run tmp-cross --rm -it --restart=Never --namespace=other --image=curlimages/curl \
  -- curl -s http://web-svc.default.svc.cluster.local
```

Saída esperada: página de boas-vindas do nginx. Isso prova que o FQDN funciona entre namespaces.

```bash
# Limpeza
kubectl delete namespace other
```

### Verificação

- `nslookup web-svc` retorna o ClusterIP
- `/etc/resolv.conf` mostra os domínios de busca (`default.svc.cluster.local`, etc.)
- Resolução FQDN cross-namespace funciona

> **Dica do Coach:** Explique a opção `ndots:5` — qualquer nome com menos de 5 pontos recebe os domínios de busca antes de tentar como está. Por isso `web-svc` (0 pontos) resolve automaticamente para `web-svc.default.svc.cluster.local`.

---

## Tarefa 4: App Multi-Camada (Frontend + Backend)

### Passo a passo

Salve como `multi-tier.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
    spec:
      containers:
        - name: echo
          image: hashicorp/http-echo
          args:
            - "-text=Hello from backend"
          ports:
            - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: backend-svc
spec:
  selector:
    app: backend
  ports:
    - protocol: TCP
      port: 5678
      targetPort: 5678
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      containers:
        - name: curl
          image: curlimages/curl
          command: ["sh", "-c"]
          args:
            - |
              while true; do
                echo "$(date) - $(curl -s http://backend-svc:5678)"
                sleep 5
              done
```

```bash
kubectl apply -f multi-tier.yaml
```

Saída esperada:

```
deployment.apps/backend created
service/backend-svc created
deployment.apps/frontend created
```

### Verificação

```bash
# Aguarde os Pods ficarem prontos
kubectl wait --for=condition=ready pod -l app=backend --timeout=60s
kubectl wait --for=condition=ready pod -l app=frontend --timeout=60s

# Verifique os logs do frontend
kubectl logs -l app=frontend --tail=5
```

Saída esperada:

```
Mon Jun 16 12:00:00 UTC 2025 - Hello from backend
Mon Jun 16 12:00:05 UTC 2025 - Hello from backend
Mon Jun 16 12:00:10 UTC 2025 - Hello from backend
```

```bash
# Confirme também que os Endpoints do backend estão populados
kubectl get endpoints backend-svc
```

Saída esperada: mostra 2 IPs de Pods na porta 5678.

> **Dica do Coach:** Se os alunos virem `curl: (6) Could not resolve host: backend-svc`, o nome do Service ou a porta está errada. Peça que verifiquem com `kubectl get svc backend-svc`.

---

## Tarefa 5: NetworkPolicy

### Passo a passo

**5a. Instale o Calico CNI (necessário para aplicação de NetworkPolicy)**

O CNI padrão do Kind (`kindnet`) **não** aplica NetworkPolicies. Os alunos precisam instalar o Calico.

**Opção A — Recrie o cluster com Calico (recomendado, início limpo):**

```bash
kind delete cluster --name fasthack

cat <<'EOF' | kind create cluster --name fasthack --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
  podSubnet: 192.168.0.0/16
EOF
```

```bash
# Instale o Calico
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.0/manifests/calico.yaml

# Aguarde o Calico ficar pronto (leva 1-2 minutos)
kubectl -n kube-system wait --for=condition=ready pod -l k8s-app=calico-node --timeout=120s
```

Saída esperada:

```
pod/calico-node-xxxxx condition met
```

Após o Calico estar pronto, reaplique todos os recursos das Tarefas 1-4:

```bash
kubectl apply -f web-deployment.yaml
kubectl apply -f web-svc.yaml
kubectl apply -f multi-tier.yaml
```

**Opção B — Instale o Calico no cluster existente (mais rápido, menos limpo):**

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.0/manifests/calico.yaml
kubectl -n kube-system wait --for=condition=ready pod -l k8s-app=calico-node --timeout=120s
```

**5b. Verifique comunicação aberta (antes de qualquer policy)**

```bash
# Teste de um pod sem o label frontend — deve funcionar
kubectl run tmp-test --rm -it --restart=Never --image=curlimages/curl \
  -- curl -s --max-time 5 http://backend-svc:5678
```

Saída esperada:

```
Hello from backend
```

**5c. Negue todo ingress para os Pods backend**

Salve como `deny-all-backend.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-backend
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
    - Ingress
```

```bash
kubectl apply -f deny-all-backend.yaml
```

Saída esperada:

```
networkpolicy.networking.k8s.io/deny-all-backend created
```

### Verificação (deny-all)

```bash
# Isso agora deve timeout
kubectl run tmp-test --rm -it --restart=Never --image=curlimages/curl \
  -- curl -s --max-time 5 http://backend-svc:5678
```

Saída esperada:

```
curl: (28) Connection timed out after 5001 milliseconds
pod "tmp-test" deleted
pod default/tmp-test terminated (Error)
```

```bash
# Os logs do frontend também devem mostrar falhas
kubectl logs -l app=frontend --tail=3
```

Saída esperada: erros de curl (timeouts ou connection refused).

**5d. Permita ingress apenas dos Pods frontend**

Salve como `allow-frontend-to-backend.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: frontend
      ports:
        - protocol: TCP
          port: 5678
```

```bash
# Remova a policy deny-all
kubectl delete networkpolicy deny-all-backend

# Aplique a policy de permissão seletiva
kubectl apply -f allow-frontend-to-backend.yaml
```

### Verificação (permissão seletiva)

```bash
# O frontend deve funcionar novamente
kubectl logs -l app=frontend --tail=5
```

Saída esperada:

```
... Hello from backend
... Hello from backend
```

```bash
# Um Pod SEM o label app=frontend ainda deve ser bloqueado
kubectl run tmp-test --rm -it --restart=Never --image=curlimages/curl \
  -- curl -s --max-time 5 http://backend-svc:5678
```

Saída esperada:

```
curl: (28) Connection timed out after 5001 milliseconds
```

Isso confirma: apenas Pods com `app: frontend` conseguem alcançar o backend na porta 5678.

---

## Problemas Comuns

| Problema | Causa Provável | Correção |
|---------|-------------|-----|
| Endpoints mostram `<none>` | O selector do Service não corresponde aos labels dos Pods | Compare `kubectl describe svc <name>` selector com `kubectl get pods --show-labels` |
| Curl na NodePort trava | Container do nó Kind não está em execução ou IP errado | Execute `docker ps` e use o InternalIP do nó |
| Resolução DNS falha no Pod | CoreDNS não está em execução | `kubectl -n kube-system get pods -l k8s-app=kube-dns` |
| NetworkPolicy não tem efeito | Usando kindnet (sem enforcement) | Instale o Calico ou recrie o cluster com `disableDefaultCNI: true` |
| Pods `tmp-*` remanescentes | Pod `--rm` anterior não foi limpo | `kubectl delete pod tmp-test tmp-curl tmp-dns --ignore-not-found` |
| Logs do frontend mostram `curl: (6) Could not resolve host` | Erro de digitação no nome do Service ou Service não criado | `kubectl get svc backend-svc` |
| NetworkPolicy bloqueia tudo | `podSelector: {}` vazio seleciona todos os Pods | Use seletores de label específicos |

> **Dica de coaching:** A tarefa de NetworkPolicy é onde os alunos mais têm dificuldade. Conduza-os pelo modelo mental: "Uma NetworkPolicy é como iptables — assim que você cria QUALQUER policy que seleciona um Pod, esse Pod muda de default-allow para default-deny para os policyTypes especificados. Então você adiciona regras `ingress` explícitas para liberar o tráfego."
