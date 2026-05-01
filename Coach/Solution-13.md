# Solução 13 — Troubleshooting (Break & Fix)

[< Voltar ao Desafio](../Student/Challenge-13.md) | **[Home](README.md)**

---

> **Nota do Coach:** Este desafio é o capstone dos Desafios 01–12. Os alunos devem trabalhar em cada cenário de forma independente usando o loop de troubleshooting: **Observar → Investigar → Diagnosticar → Corrigir → Verificar**. Só forneça dicas se os alunos ficarem presos por mais de 10 minutos em um único cenário.

## Setup

Crie o namespace de troubleshooting:

```bash
kubectl create namespace troubleshooting
```

---

## Cenário 1: ImagePullBackOff 🖼️

### O Manifesto Quebrado

```yaml
# scenario-1-imagepull.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: broken-image
  namespace: troubleshooting
spec:
  replicas: 1
  selector:
    matchLabels:
      app: broken-image
  template:
    metadata:
      labels:
        app: broken-image
    spec:
      containers:
      - name: web
        image: ngnix:latest
        ports:
        - containerPort: 80
```

```bash
kubectl apply -f scenario-1-imagepull.yaml
```

### Comandos de Diagnóstico

```bash
# Passo 1: Observar o sintoma
kubectl get pods -n troubleshooting -l app=broken-image
```

Saída esperada:

```
NAME                            READY   STATUS             RESTARTS   AGE
broken-image-xxxxxxxxx-xxxxx   0/1     ImagePullBackOff   0          30s
```

```bash
# Passo 2: Investigar — ler a seção Events
kubectl describe pod -l app=broken-image -n troubleshooting
```

Evento chave na saída:

```
Warning  Failed   Failed to pull image "ngnix:latest": ... manifest unknown
Warning  Failed   Error: ErrImagePull
Warning  BackOff  Back-off pulling image "ngnix:latest"
```

### Causa Raiz

O nome da imagem é `ngnix` — as letras `i` e `n` estão trocadas. O correto é `nginx`.

### Correção

```bash
kubectl set image deployment/broken-image web=nginx:latest -n troubleshooting
```

### Verificação

```bash
kubectl get pods -n troubleshooting -l app=broken-image
```

Saída esperada:

```
NAME                            READY   STATUS    RESTARTS   AGE
broken-image-xxxxxxxxx-xxxxx   1/1     Running   0          15s
```

> **Dica para o Coach:** Este é o cenário mais fácil — um simples typo. A lição principal é que `kubectl describe pod` revela o erro exato de pull de imagem na seção Events.

---

## Cenário 2: CrashLoopBackOff 💥

### O Manifesto Quebrado

```yaml
# scenario-2-crashloop.yaml
apiVersion: v1
kind: Pod
metadata:
  name: crashloop-app
  namespace: troubleshooting
spec:
  containers:
  - name: app
    image: busybox:1.37
    command: ["cat", "/config/app.conf"]
```

```bash
kubectl apply -f scenario-2-crashloop.yaml
```

### Comandos de Diagnóstico

```bash
# Passo 1: Observar
kubectl get pods -n troubleshooting
```

Saída esperada:

```
NAME             READY   STATUS             RESTARTS      AGE
crashloop-app    0/1     CrashLoopBackOff   3 (20s ago)   60s
```

```bash
# Passo 2: Verificar logs do container — o que ele imprimiu antes de morrer?
kubectl logs crashloop-app -n troubleshooting
```

Saída esperada:

```
cat: can't open '/config/app.conf': No such file or directory
```

```bash
# Se o container já reiniciou, verificar a instância anterior:
kubectl logs crashloop-app -n troubleshooting --previous
```

### Causa Raiz

O container executa `cat /config/app.conf`, mas esse arquivo não existe. O comando termina imediatamente com um código de saída diferente de zero, causando o loop de reinicialização.

### Correção

Delete o Pod quebrado e crie um com um comando que permaneça em execução:

```bash
kubectl delete pod crashloop-app -n troubleshooting
```

```yaml
# scenario-2-fixed.yaml
apiVersion: v1
kind: Pod
metadata:
  name: crashloop-app
  namespace: troubleshooting
spec:
  containers:
  - name: app
    image: busybox:1.37
    command: ["sh", "-c", "echo 'App started' && sleep infinity"]
```

```bash
kubectl apply -f scenario-2-fixed.yaml
```

### Verificação

```bash
kubectl get pod crashloop-app -n troubleshooting
```

Saída esperada:

```
NAME             READY   STATUS    RESTARTS   AGE
crashloop-app    1/1     Running   0          10s
```

> **Dica para o Coach:** A lição principal é usar `kubectl logs` e `kubectl logs --previous` para ver o que o container imprimiu antes de morrer. Isso é o equivalente a `journalctl -u <service>` no Linux.

---

## Cenário 3: Pod Pending (Recursos Insuficientes) ⏳

### O Manifesto Quebrado

```yaml
# scenario-3-pending.yaml
apiVersion: v1
kind: Pod
metadata:
  name: hungry-pod
  namespace: troubleshooting
spec:
  containers:
  - name: hungry
    image: nginx:1.27
    resources:
      requests:
        memory: "64Gi"
        cpu: "100m"
```

```bash
kubectl apply -f scenario-3-pending.yaml
```

### Comandos de Diagnóstico

```bash
# Passo 1: Observar — Pod está preso em Pending
kubectl get pods -n troubleshooting
```

Saída esperada:

```
NAME         READY   STATUS    RESTARTS   AGE
hungry-pod   0/1     Pending   0          45s
```

```bash
# Passo 2: Investigar — POR QUE está Pending?
kubectl describe pod hungry-pod -n troubleshooting
```

Evento chave:

```
Warning  FailedScheduling  0/1 nodes are available: 1 Insufficient memory.
```

```bash
# Passo 3: Verificar capacidade do node
kubectl describe node | grep -A 5 "Allocatable:"
```

Esperado: Um node Kind normalmente tem 8–16Gi de memória alocável. O Pod solicita 64Gi — impossível de agendar.

### Causa Raiz

O Pod solicita 64Gi de memória, o que excede a memória alocável de qualquer node no cluster Kind.

### Correção

```bash
kubectl delete pod hungry-pod -n troubleshooting
```

```yaml
# scenario-3-fixed.yaml
apiVersion: v1
kind: Pod
metadata:
  name: hungry-pod
  namespace: troubleshooting
spec:
  containers:
  - name: hungry
    image: nginx:1.27
    resources:
      requests:
        memory: "128Mi"
        cpu: "100m"
```

```bash
kubectl apply -f scenario-3-fixed.yaml
```

### Verificação

```bash
kubectl get pod hungry-pod -n troubleshooting
```

Saída esperada:

```
NAME         READY   STATUS    RESTARTS   AGE
hungry-pod   1/1     Running   0          15s
```

> **Dica para o Coach:** Pods em `Pending` nunca foram agendados. A seção Events do `kubectl describe` sempre diz o motivo — geralmente `Insufficient memory`, `Insufficient cpu`, ou incompatibilidades de taint/toleration. Isso é o equivalente a um processo falhando ao iniciar porque o servidor ficou sem RAM.

---

## Cenário 4: Service Sem Roteamento (Label Mismatch) ��️

### O Manifesto Quebrado

```yaml
# scenario-4-labels.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-deploy
  namespace: troubleshooting
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web-frontend
  template:
    metadata:
      labels:
        app: web-frontend
    spec:
      containers:
      - name: nginx
        image: nginx:1.27
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: web-svc
  namespace: troubleshooting
spec:
  selector:
    app: web-backend
  ports:
  - port: 80
    targetPort: 80
```

```bash
kubectl apply -f scenario-4-labels.yaml
```

### Comandos de Diagnóstico

```bash
# Passo 1: Pods estão Running — parece ok à primeira vista
kubectl get pods -n troubleshooting -l app=web-frontend
```

Esperado: 2 pods Running.

```bash
# Passo 2: Verificar endpoints do Service — aqui o problema aparece
kubectl get endpoints web-svc -n troubleshooting
```

Saída esperada:

```
NAME      ENDPOINTS   AGE
web-svc   <none>      30s
```

**Sem endpoints!** O tráfego não vai a lugar nenhum.

```bash
# Passo 3: Comparar o selector do Service com as labels dos Pods
kubectl describe svc web-svc -n troubleshooting | grep Selector
# Selector: app=web-backend

kubectl get pods -n troubleshooting --show-labels
# app=web-frontend
```

### Causa Raiz

O Service seleciona `app: web-backend`, mas os Pods estão rotulados com `app: web-frontend`. O selector não corresponde, então o Service tem zero endpoints.

### Correção

```bash
kubectl patch svc web-svc -n troubleshooting \
  -p '{"spec":{"selector":{"app":"web-frontend"}}}'
```

### Verificação

```bash
kubectl get endpoints web-svc -n troubleshooting
```

Saída esperada:

```
NAME      ENDPOINTS                       AGE
web-svc   10.244.x.x:80,10.244.x.x:80   5s
```

> **Dica para o Coach:** Este é um dos erros mais comuns no mundo real. O padrão de debugging é: Service sem endpoints → comparar o selector do `kubectl describe svc` com `kubectl get pods --show-labels`. Isso é como verificar se o bloco `upstream` do Nginx aponta para os IPs corretos do backend.

---

## Cenário 5: PVC Preso em Pending 💾

### O Manifesto Quebrado

```yaml
# scenario-5-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-pvc
  namespace: troubleshooting
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: premium-fast
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: data-pod
  namespace: troubleshooting
spec:
  containers:
  - name: writer
    image: busybox:1.37
    command: ["sh", "-c", "echo hello > /data/test.txt && sleep infinity"]
    volumeMounts:
    - name: data-vol
      mountPath: /data
  volumes:
  - name: data-vol
    persistentVolumeClaim:
      claimName: data-pvc
```

```bash
kubectl apply -f scenario-5-pvc.yaml
```

### Comandos de Diagnóstico

```bash
# Passo 1: Observar — tanto o PVC quanto o Pod estão Pending
kubectl get pvc -n troubleshooting
```

Saída esperada:

```
NAME       STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
data-pvc   Pending                                       premium-fast   30s
```

```bash
kubectl get pod data-pod -n troubleshooting
# STATUS: Pending (aguardando PVC)
```

```bash
# Passo 2: Investigar o PVC
kubectl describe pvc data-pvc -n troubleshooting
```

Evento chave:

```
Warning  ProvisioningFailed  storageclass.storage.k8s.io "premium-fast" not found
```

```bash
# Passo 3: Verificar StorageClasses disponíveis
kubectl get storageclass
```

Saída esperada:

```
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      AGE
standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   1h
```

### Causa Raiz

O PVC referencia a StorageClass `premium-fast`, que não existe. O Kind usa `standard` como sua StorageClass padrão.

### Correção

```bash
kubectl delete pod data-pod -n troubleshooting
kubectl delete pvc data-pvc -n troubleshooting
```

Edite o manifesto: altere `storageClassName: premium-fast` para `storageClassName: standard` (ou remova o campo `storageClassName` inteiramente para usar o padrão):

```yaml
# scenario-5-fixed.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-pvc
  namespace: troubleshooting
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: standard
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: data-pod
  namespace: troubleshooting
spec:
  containers:
  - name: writer
    image: busybox:1.37
    command: ["sh", "-c", "echo hello > /data/test.txt && sleep infinity"]
    volumeMounts:
    - name: data-vol
      mountPath: /data
  volumes:
  - name: data-vol
    persistentVolumeClaim:
      claimName: data-pvc
```

```bash
kubectl apply -f scenario-5-fixed.yaml
```

### Verificação

```bash
kubectl get pvc -n troubleshooting
```

Saída esperada:

```
NAME       STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
data-pvc   Bound    pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   1Gi        RWO            standard       15s
```

```bash
kubectl get pod data-pod -n troubleshooting
```

Esperado: `Running`.

> **Dica para o Coach:** A lição é que PVCs dependem de StorageClasses. Sempre verifique `kubectl get storageclass` para ver o que está disponível. No Kind é `standard`; na nuvem é `managed-csi` (AKS), `gp2` (EKS), ou `standard-rwo` (GKE).

---

## Cenário 6: RBAC Forbidden 🔐

### O Manifesto Quebrado

```yaml
# scenario-6-rbac.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pod-reader
  namespace: troubleshooting
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader-role
  namespace: troubleshooting
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
```

```bash
kubectl apply -f scenario-6-rbac.yaml
```

### Comandos de Diagnóstico

```bash
# Passo 1: Testar permissões
kubectl auth can-i list pods \
  --as=system:serviceaccount:troubleshooting:pod-reader \
  -n troubleshooting
```

Saída esperada:

```
no
```

```bash
# Passo 2: O Role existe com as permissões corretas
kubectl describe role pod-reader-role -n troubleshooting
```

Esperado: Resources: pods, Verbs: get, list, watch ✓

```bash
# Passo 3: Verificar RoleBindings
kubectl get rolebindings -n troubleshooting
```

Saída esperada:

```
No resources found in troubleshooting namespace.
```

### Causa Raiz

Existe um Role com as permissões corretas, e existe um ServiceAccount, mas **não há RoleBinding** conectando-os. Sem o binding, a permissão nunca é concedida. RBAC requer todos os três: Role + RoleBinding + Subject.

### Correção

```yaml
# scenario-6-fix-rolebinding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pod-reader-binding
  namespace: troubleshooting
subjects:
- kind: ServiceAccount
  name: pod-reader
  namespace: troubleshooting
roleRef:
  kind: Role
  name: pod-reader-role
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f scenario-6-fix-rolebinding.yaml
```

### Verificação

```bash
kubectl auth can-i list pods \
  --as=system:serviceaccount:troubleshooting:pod-reader \
  -n troubleshooting
```

Saída esperada:

```
yes
```

> **Dica para o Coach:** A tríade RBAC é: **Role** (quais permissões) + **RoleBinding** (quem as recebe) + **Subject** (a identidade). Se qualquer um dos três estiver faltando, significa "sem acesso." Isso é o equivalente a criar uma regra no sudoers mas nunca adicionar o usuário ao grupo.

---

## Cenário 7: Ingress Retorna 503 🌐

### Pré-requisitos

Certifique-se de que o NGINX Ingress Controller está instalado:

```bash
kubectl get pods -n ingress-nginx
```

Se não estiver instalado:

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=90s
```

### O Manifesto Quebrado

```yaml
# scenario-7-ingress.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend-app
  namespace: troubleshooting
spec:
  replicas: 1
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
        image: hashicorp/http-echo:latest
        args:
        - "-text=Scenario 7 works!"
        ports:
        - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: backend-svc
  namespace: troubleshooting
spec:
  selector:
    app: backend
  ports:
  - port: 80
    targetPort: 9999
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: broken-ingress
  namespace: troubleshooting
spec:
  ingressClassName: nginx
  rules:
  - host: scenario7.localhost
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: backend-svc
            port:
              number: 80
```

```bash
kubectl apply -f scenario-7-ingress.yaml
```

### Comandos de Diagnóstico

```bash
# Passo 1: Testar o ingress
curl http://scenario7.localhost/
```

Saída esperada:

```html
<html><body><h1>503 Service Temporarily Unavailable</h1></body></html>
```

```bash
# Passo 2: Pod está Running — ok ✓
kubectl get pods -l app=backend -n troubleshooting

# Passo 3: Service tem endpoints — mas observe a PORTA
kubectl get endpoints backend-svc -n troubleshooting
```

Saída esperada:

```
NAME          ENDPOINTS          AGE
backend-svc   10.244.x.x:9999   30s
```

A porta do endpoint é **9999** — mas `http-echo` escuta na porta **5678**!

```bash
# Passo 4: Confirmar a incompatibilidade
kubectl describe svc backend-svc -n troubleshooting | grep -i targetport
# TargetPort: 9999
```

### Causa Raiz

O `targetPort` do Service é `9999`, mas o container `hashicorp/http-echo` escuta na porta **5678**. O Ingress Controller encaminha o tráfego para o Service → Service encaminha para a porta 9999 → conexão recusada no Pod → Ingress retorna 503.

### Correção

```bash
kubectl patch svc backend-svc -n troubleshooting \
  -p '{"spec":{"ports":[{"port":80,"targetPort":5678}]}}'
```

### Verificação

```bash
curl http://scenario7.localhost/
```

Saída esperada:

```
Scenario 7 works!
```

> **Dica para o Coach:** 503 de um Ingress geralmente significa que o backend está inacessível. O caminho de debugging é: verificar se endpoints existem → verificar se targetPort corresponde à porta em que o container está escutando → verificar se o container realmente está escutando. Isso é o mesmo que troubleshooting de Nginx → HAProxy → backend onde a configuração do proxy aponta para a porta errada.

---

## Cenário 8: OOMKilled 💀

### O Manifesto Quebrado

```yaml
# scenario-8-oomkilled.yaml
apiVersion: v1
kind: Pod
metadata:
  name: leaky-app
  namespace: troubleshooting
spec:
  containers:
  - name: stress
    image: polinux/stress:latest
    command: ["stress"]
    args: ["--vm", "1", "--vm-bytes", "256M", "--vm-hang", "0"]
    resources:
      limits:
        memory: "64Mi"
      requests:
        memory: "32Mi"
```

```bash
kubectl apply -f scenario-8-oomkilled.yaml
```

### Comandos de Diagnóstico

```bash
# Passo 1: Observar — status OOMKilled
kubectl get pods -n troubleshooting
```

Saída esperada:

```
NAME        READY   STATUS      RESTARTS      AGE
leaky-app   0/1     OOMKilled   3 (20s ago)   60s
```

```bash
# Passo 2: Investigar
kubectl describe pod leaky-app -n troubleshooting
```

Informação chave no status do container:

```
Last State:  Terminated
  Reason:    OOMKilled
  Exit Code: 137
```

```bash
# Passo 3: Entender a incompatibilidade
# A ferramenta stress tenta alocar 256M
# O limite de memória é apenas 64Mi
# O OOM killer do kernel termina o processo (exit code 137 = SIGKILL)
```

### Causa Raiz

A ferramenta `stress` está configurada para alocar 256M de memória (`--vm-bytes 256M`), mas o container tem um limite rígido de memória de 64Mi. Quando o processo excede 64Mi, o OOM killer do kernel Linux o termina (exit code 137 = SIGKILL).

### Correção

Aumente o limite de memória OU reduza o consumo de memória. A correção faz ambos para estabilidade:

```bash
kubectl delete pod leaky-app -n troubleshooting
```

```yaml
# scenario-8-fixed.yaml
apiVersion: v1
kind: Pod
metadata:
  name: leaky-app
  namespace: troubleshooting
spec:
  containers:
  - name: stress
    image: polinux/stress:latest
    command: ["stress"]
    args: ["--vm", "1", "--vm-bytes", "64M", "--vm-hang", "0"]
    resources:
      limits:
        memory: "256Mi"
      requests:
        memory: "128Mi"
```

```bash
kubectl apply -f scenario-8-fixed.yaml
```

### Verificação

```bash
kubectl get pod leaky-app -n troubleshooting
```

Saída esperada:

```
NAME        READY   STATUS    RESTARTS   AGE
leaky-app   1/1     Running   0          15s
```

```bash
# Confirmar que está realmente usando memória
kubectl top pod leaky-app -n troubleshooting
```

Esperado: Uso de memória em torno de 64Mi.

> **Dica para o Coach:** OOMKilled é o equivalente Kubernetes do OOM killer do Linux (`dmesg | grep -i oom`). Exit code 137 = 128 + 9 (SIGKILL). A lição: sempre defina limites de memória maiores que o pico de working set da aplicação, e defina requests para o uso típico.

---

## Limpeza

```bash
kubectl delete namespace troubleshooting
```

Isso remove todos os recursos no namespace de uma vez.

---

## Problemas Comuns

| Problema | Causa | Correção |
|----------|-------|----------|
| Aluno não consegue distinguir ImagePullBackOff de CrashLoopBackOff | Ambos mostram status de erro mas têm causas raiz diferentes | ImagePullBackOff = imagem não existe; CrashLoopBackOff = imagem existe mas o processo morre |
| `kubectl logs` retorna "no logs" para Pods em Pending | Pods em Pending nunca foram agendados, então nenhum container executou | Use `kubectl describe pod` em vez disso — verifique a seção Events para falhas de agendamento |
| No Cenário 7, curl retorna "connection refused" em vez de 503 | NGINX Ingress Controller não instalado | Instale-o: `kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml` |
| PVC continua Pending mesmo após corrigir StorageClass | Deve deletar e recriar o PVC — `storageClassName` é imutável | `kubectl delete pvc <name>` e depois re-aplicar com a StorageClass correta |
| Aluno faz patch no campo errado | Confusão com a sintaxe de JSON patch | Mostre o comando exato `kubectl patch` da solução |
| OOMKilled acontece rápido demais para observar | A ferramenta stress excede os limites em segundos | Peça aos alunos para executar `kubectl get pods --watch` em um terminal antes de aplicar o manifesto |

## Resumo do Loop de Troubleshooting (referência para o coach)

Para **todo** cenário quebrado, o loop é o mesmo:

```
1. kubectl get pods -n troubleshooting              → Qual status?
2. kubectl describe pod <name> -n troubleshooting    → Ler a seção Events
3. kubectl logs <name> -n troubleshooting            → O que o container imprimiu?
4. kubectl get events -n troubleshooting --sort-by='.lastTimestamp'  → Visão geral do cluster
5. Corrigir o manifesto e re-aplicar
6. Verificar a correção
```

A seção Events do `kubectl describe` é a informação mais útil. **Leia-a sempre.**
