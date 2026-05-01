# Desafio 05 — Services e Networking

[< Desafio Anterior](Challenge-04.md) | **[Início](../README.md)** | [Próximo Desafio >](Challenge-06.md)

## Introdução

Em um servidor Linux, você expõe um daemon para a rede vinculando-o a uma porta e depois gerencia o acesso com regras `iptables`. Se outros serviços precisam encontrá-lo, você adiciona entradas no `/etc/hosts` ou depende do DNS. O port forwarding com `ssh -L` permite alcançar coisas atrás de um firewall. E quando você quer restringir o tráfego, `ufw` ou regras `iptables` puras atuam como seu firewall.

O Kubernetes segue as mesmas ideias, mas as automatiza no nível do cluster:

- **Services** substituem regras manuais de `iptables` — eles fornecem um IP e porta estáveis para um conjunto de Pods, fazendo balanceamento de carga automático entre réplicas saudáveis.
- **CoreDNS** substitui o `/etc/hosts` — cada Service recebe um nome DNS (`service-name.namespace.svc.cluster.local`) que qualquer Pod no cluster pode resolver.
- **`kubectl port-forward`** substitui o `ssh -L` — ele cria um túnel de uma porta local para um Pod ou Service dentro do cluster.
- **NetworkPolicies** substituem regras de firewall — elas controlam quais Pods podem se comunicar com quais, usando seletores de labels em vez de endereços IP.

Neste desafio você vai expor Pods com diferentes tipos de Service, usar DNS para conectar uma aplicação multi-camadas e restringir o tráfego com uma NetworkPolicy — tudo no seu cluster Kind local.

> **Requisito de cluster:** Todos os exercícios usam um cluster [Kind](https://kind.sigs.k8s.io/) local. Se você ainda não criou um:
> ```bash
> kind create cluster --name fasthack
> ```

## Descrição

1. **Criar um Service ClusterIP para expor um Deployment internamente**

   Crie um Deployment chamado `web` executando `nginx:stable` com **3 réplicas**. Em seguida, crie um Service ClusterIP chamado `web-svc` que roteia tráfego na porta 80 para os Pods do Deployment. Verifique se o Service tem Endpoints e se você consegue acessá-lo de dentro do cluster.

2. **Criar um Service NodePort para acessar a aplicação de fora do cluster**

   Crie um segundo Service chamado `web-nodeport` do tipo `NodePort` que expõe o mesmo Deployment `web` em uma porta do node. Verifique se você consegue acessar a aplicação da sua máquina host fazendo curl no IP do node e na porta atribuída.

3. **Usar resolução DNS para descobrir Services pelo nome**

   A partir de um Pod temporário, use `nslookup` ou `dig` para resolver `web-svc.default.svc.cluster.local`. Em seguida, verifique o `/etc/resolv.conf` do Pod para ver como o Kubernetes configura o DNS automaticamente. Confirme que você consegue fazer `curl http://web-svc` de dentro do mesmo namespace, e `curl http://web-svc.default.svc.cluster.local` de um namespace diferente.

4. **Criar uma aplicação multi-camadas: frontend + backend conectados via Services**

   - Crie um Deployment chamado `backend` executando `hashicorp/http-echo` com o argumento `-text=Hello from backend`.
   - Crie um Service ClusterIP chamado `backend-svc` expondo-o na porta 5678.
   - Crie um Deployment chamado `frontend` executando `curlimages/curl` com um comando que executa em loop infinito, fazendo curl em `http://backend-svc:5678` a cada 5 segundos.
   - Verifique se o frontend consegue alcançar o backend verificando os logs do Pod frontend.

5. **Explorar NetworkPolicy para restringir comunicação Pod-a-Pod**

   > **Nota:** O CNI padrão do Kind (`kindnet`) **não** suporta NetworkPolicies. Para esta tarefa, recrie seu cluster com Calico como CNI, ou instale o Calico no seu cluster existente (veja a Dica 4 para instruções).

   - Primeiro, verifique que todos os Pods podem se comunicar livremente entre si (o padrão).
   - Crie uma NetworkPolicy que **nega todo ingress** para os Pods `backend`.
   - Confirme que o frontend **não consegue mais** alcançar o backend.
   - Atualize a NetworkPolicy para permitir ingress **apenas** de Pods com o label `app: frontend` na porta 5678.
   - Confirme que o frontend consegue alcançar o backend novamente, mas outros Pods ainda não conseguem.

## Critérios de Sucesso

- [ ] O Service ClusterIP `web-svc` tem 3 Endpoints correspondentes aos Pods do Deployment `web`.
- [ ] Você consegue alcançar `web-svc` de dentro do cluster usando um Pod temporário (`kubectl run --rm -it` com `curl`).
- [ ] O Service NodePort `web-nodeport` está acessível a partir da sua máquina host.
- [ ] A resolução DNS para `web-svc.default.svc.cluster.local` retorna o ClusterIP correto.
- [ ] Os logs do Pod `frontend` mostram respostas bem-sucedidas repetidas do Service `backend`.
- [ ] Após aplicar a NetworkPolicy deny-all, o frontend **não consegue** alcançar o backend.
- [ ] Após aplicar a NetworkPolicy allow-frontend, o frontend **consegue** alcançar o backend, mas um Pod de teste sem o label `app: frontend` **não consegue**.

## Referência Linux ↔ Kubernetes

| Conceito Linux | Equivalente Kubernetes | Notas |
|---|---|---|
| Regras `iptables` | Service (ClusterIP/NodePort) | O kube-proxy programa regras iptables (ou IPVS) para rotear tráfego para IPs de Pods. |
| `/etc/hosts` | CoreDNS | DNS automático para cada Service — nenhuma entrada manual necessária. |
| Resolução DNS (`dig`, `nslookup`) | `service.namespace.svc.cluster.local` | Cada Service recebe um nome de domínio totalmente qualificado. Dentro do mesmo namespace, o nome curto funciona. |
| Port forwarding (`ssh -L`) | `kubectl port-forward` | Cria túnel de uma porta local para um Pod ou Service — útil para debug sem expor NodePorts. |
| Regras de firewall (`ufw` / `iptables`) | NetworkPolicy | Controla ingress/egress por Pod usando seletores de labels em vez de IPs. |
| `netstat -tlnp` / `ss -tlnp` | `kubectl get endpoints` | Mostra os IPs e portas reais dos Pods que sustentam um Service. |
| `/etc/resolv.conf` | `/etc/resolv.conf` do Pod (auto-configurado) | O kubelet injeta entradas de nameserver apontando para o CoreDNS para que os Pods possam resolver Services. |

## Dicas

<details>
<summary>Dica 1: Criando o Deployment e o Service ClusterIP</summary>

Crie um arquivo chamado `web-deployment.yaml`:

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

Crie um arquivo chamado `web-svc.yaml`:

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

Aplique ambos e verifique:

```bash
kubectl apply -f web-deployment.yaml
kubectl apply -f web-svc.yaml

# Check the Service exists and has a ClusterIP
kubectl get svc web-svc

# Check that Endpoints are populated (should list 3 Pod IPs)
kubectl get endpoints web-svc

# Test from inside the cluster using a temporary Pod
kubectl run tmp-curl --rm -it --restart=Never --image=curlimages/curl -- curl -s http://web-svc
```

</details>

<details>
<summary>Dica 2: Service NodePort e descoberta DNS</summary>

Crie um arquivo chamado `web-nodeport.yaml`:

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

# See the assigned NodePort (30000–32767 range)
kubectl get svc web-nodeport

# Get the node's internal IP
kubectl get nodes -o wide

# In Kind, use the container IP to reach the NodePort
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
NODE_PORT=$(kubectl get svc web-nodeport -o jsonpath='{.spec.ports[0].nodePort}')
curl -s http://${NODE_IP}:${NODE_PORT}
```

**Descoberta DNS — verifique a resolução de dentro do cluster:**

```bash
# Launch a temporary DNS debugging Pod
kubectl run tmp-dns --rm -it --restart=Never --image=busybox:stable -- sh

# Inside the Pod:
nslookup web-svc
nslookup web-svc.default.svc.cluster.local
cat /etc/resolv.conf
wget -qO- http://web-svc
exit
```

Note que `/etc/resolv.conf` contém `search default.svc.cluster.local svc.cluster.local cluster.local` — é assim que o nome curto `web-svc` resolve automaticamente dentro do mesmo namespace.

</details>

<details>
<summary>Dica 3: Aplicação multi-camadas (frontend + backend)</summary>

Crie um arquivo chamado `multi-tier.yaml`:

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

# Wait for all Pods to be ready
kubectl get pods -l 'app in (frontend,backend)' --watch

# Check the frontend logs — you should see periodic responses from the backend
kubectl logs -l app=frontend --follow
```

Você deve ver uma saída como:
```
Mon Jun 16 12:00:00 UTC 2025 - Hello from backend
Mon Jun 16 12:00:05 UTC 2025 - Hello from backend
```

</details>

<details>
<summary>Dica 4: NetworkPolicy (incluindo setup do Calico para Kind)</summary>

**Passo 1 — Instale um CNI que suporte NetworkPolicy no Kind:**

O CNI padrão do Kind (`kindnet`) não aplica NetworkPolicies. Você tem duas opções:

**Opção A — Criar um novo cluster com Calico:**

```bash
# Delete existing cluster
kind delete cluster --name fasthack

# Create a cluster without the default CNI
cat <<EOF | kind create cluster --name fasthack --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true
  podSubnet: 192.168.0.0/16
EOF

# Install Calico
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.0/manifests/calico.yaml

# Wait for Calico Pods to be ready
kubectl -n kube-system get pods -l k8s-app=calico-node --watch
```

**Opção B — Se você quiser manter seu cluster, instale o Calico junto com o kindnet** (não recomendado para produção, mas funciona para aprendizado):

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.0/manifests/calico.yaml
kubectl -n kube-system get pods -l k8s-app=calico-node --watch
```

Após o Calico estar rodando, reaplique seus Deployments e Services das tarefas anteriores se você recriou o cluster.

**Passo 2 — Verificar comunicação aberta (antes de qualquer política):**

```bash
# Test from a pod without the frontend label
kubectl run tmp-test --rm -it --restart=Never --image=curlimages/curl -- curl -s --max-time 5 http://backend-svc:5678
# Expected: "Hello from backend"
```

**Passo 3 — Negar todo ingress para os Pods backend:**

Crie um arquivo chamado `deny-all-backend.yaml`:

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

# Test — this should now time out
kubectl run tmp-test --rm -it --restart=Never --image=curlimages/curl -- curl -s --max-time 5 http://backend-svc:5678
# Expected: timeout / connection refused

# Check frontend logs — requests should also be failing
kubectl logs -l app=frontend --tail=5
```

**Passo 4 — Permitir ingress apenas do frontend:**

Crie um arquivo chamado `allow-frontend-to-backend.yaml`:

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
# Remove the deny-all policy first
kubectl delete networkpolicy deny-all-backend

# Apply the selective allow policy
kubectl apply -f allow-frontend-to-backend.yaml

# Frontend should work again
kubectl logs -l app=frontend --tail=5
# Expected: "Hello from backend"

# But a Pod without app=frontend label should still be blocked
kubectl run tmp-test --rm -it --restart=Never --image=curlimages/curl -- curl -s --max-time 5 http://backend-svc:5678
# Expected: timeout
```

</details>

## Recursos de Aprendizado

- [Service — Kubernetes official docs](https://kubernetes.io/docs/concepts/services-networking/service/)
- [DNS for Services and Pods](https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/)
- [Connecting Applications with Services](https://kubernetes.io/docs/tutorials/services/connect-applications-service/)
- [NetworkPolicies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [kubectl port-forward](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_port-forward/)
- [Debugging DNS Resolution](https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/)
- [Kind — Configuration](https://kind.sigs.k8s.io/docs/user/configuration/)

## Quebra & Conserta 🔧

Tente cada cenário, diagnostique o problema e corrija.

### Cenário 1 — Seletor do Service não corresponde aos labels dos Pods (Endpoints vazios)

Crie um Service com um seletor incompatível:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: broken-svc
spec:
  selector:
    app: webapp
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
```

```bash
kubectl apply -f broken-svc.yaml
kubectl get endpoints broken-svc
```

**O que você verá:** A lista de Endpoints é `<none>` — nenhum Pod corresponde ao seletor `app: webapp` porque o Deployment usa `app: web`.

**Diagnostique:**

```bash
# Compare the Service selector with actual Pod labels
kubectl describe svc broken-svc | grep Selector
kubectl get pods --show-labels
```

**Analogia Linux:** É como escrever uma regra `iptables` DNAT que encaminha para um endereço IP onde nada está escutando — os pacotes chegam mas ninguém responde.

<details>
<summary>Correção</summary>

Atualize o seletor do Service para corresponder aos labels dos Pods:

```bash
kubectl patch svc broken-svc -p '{"spec":{"selector":{"app":"web"}}}'
# Or edit the YAML and re-apply
kubectl get endpoints broken-svc
```

Agora você deve ver os IPs dos Pods listados como Endpoints.

</details>

---

### Cenário 2 — `targetPort` errado no Service (conexão recusada)

Crie um Service que aponta para a porta errada:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: wrong-port-svc
spec:
  selector:
    app: web
  ports:
    - protocol: TCP
      port: 80
      targetPort: 8080
```

```bash
kubectl apply -f wrong-port-svc.yaml

# Endpoints exist but the port is wrong
kubectl get endpoints wrong-port-svc

# Try to connect — this will fail
kubectl run tmp-curl --rm -it --restart=Never --image=curlimages/curl -- curl -s --max-time 5 http://wrong-port-svc
```

**O que você verá:** A lista de Endpoints mostra IPs de Pods na porta 8080, mas o nginx escuta na porta 80. Conexões recebem "connection refused."

**Diagnostique:**

```bash
# Check what port the Endpoints are actually using
kubectl get endpoints wrong-port-svc -o yaml

# Check what port the container is actually listening on
kubectl exec deploy/web -- ss -tlnp
```

**Analogia Linux:** É como configurar um port-forward para `localhost:8080` quando o daemon está realmente escutando em `localhost:80`.

<details>
<summary>Correção</summary>

Altere `targetPort` para corresponder à porta do container:

```bash
kubectl patch svc wrong-port-svc -p '{"spec":{"ports":[{"port":80,"targetPort":80,"protocol":"TCP"}]}}'

# Verify
kubectl run tmp-curl --rm -it --restart=Never --image=curlimages/curl -- curl -s http://wrong-port-svc
```

</details>

---

### Cenário 3 — NetworkPolicy negando todo tráfego (aplicação inacessível)

Aplique uma NetworkPolicy que nega todo ingress para todos os Pods no namespace:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all
spec:
  podSelector: {}
  policyTypes:
    - Ingress
```

```bash
kubectl apply -f deny-all.yaml

# Try to reach the backend — should fail
kubectl run tmp-curl --rm -it --restart=Never --image=curlimages/curl -- curl -s --max-time 5 http://backend-svc:5678

# Check frontend logs — also failing
kubectl logs -l app=frontend --tail=3
```

**O que você verá:** Toda comunicação entre Pods no namespace está bloqueada. O `podSelector: {}` vazio seleciona **todos** os Pods, e o tipo de política `Ingress` sem regras `ingress` significa "negar toda entrada."

**Diagnostique:**

```bash
# List all NetworkPolicies in the namespace
kubectl get networkpolicy

# Inspect the deny-all policy
kubectl describe networkpolicy deny-all
```

**Analogia Linux:** É como executar `iptables -P INPUT DROP` sem adicionar nenhuma regra ACCEPT — tudo fica bloqueado.

<details>
<summary>Correção</summary>

Ou delete a política de negação geral:

```bash
kubectl delete networkpolicy deny-all
```

Ou substitua por uma política mais direcionada que restringe apenas Pods específicos enquanto permite o tráfego necessário (como a política `allow-frontend-to-backend` da Tarefa 5).

</details>
