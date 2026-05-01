# Desafio 13 — Troubleshooting

[< Desafio Anterior](Challenge-12.md) | **[Início](../README.md)** | [Próximo Desafio >](Challenge-14.md)

## Introdução

Se você é um administrador Linux, já tem um playbook de troubleshooting gravado na memória muscular: algo quebra, você verifica `dmesg` para mensagens do kernel, `journalctl -xe` para logs de serviço, `strace` para rastrear um processo com mau comportamento, `netstat` para verificar listeners, e `free -h` quando suspeita de pressão de memória. Você trabalha sistematicamente dos sintomas à causa raiz.

O troubleshooting no Kubernetes segue a **mesma filosofia** — ferramentas diferentes, mesmo modelo mental. Em vez de `dmesg`, você lê eventos do cluster. Em vez de `journalctl`, você faz `kubectl describe` em um Pod. Em vez de `strace`, você anexa um container de debug. Os comandos são diferentes, mas o processo de pensamento é idêntico: **observar sintomas → formar hipótese → verificar → corrigir → confirmar**.

Este desafio é **diferente de todos os desafios anteriores**. Não há conceitos novos para aprender. Em vez disso, você recebe **oito deployments quebrados** — cada um com um bug deliberado — e sua tarefa é diagnosticar e corrigir cada um. É aqui que tudo que você aprendeu nos Desafios 01–12 se junta.

## Descrição

Este desafio é **inteiramente break & fix**. Aplique cada manifest quebrado abaixo (Cenários 1–8 na seção Break & Fix), diagnostique o problema e corrija-o. Os cenários estão ordenados do mais fácil ao mais difícil.

Sua missão é:

1. **Criar um namespace para este desafio**

   ```bash
   kubectl create namespace troubleshooting
   ```

2. **Trabalhar através de todos os 8 cenários** na seção [Break & Fix](#break--fix-) abaixo — aplique cada manifest quebrado, observe os sintomas, diagnostique a causa raiz e aplique uma correção.

3. **Para cada cenário, siga esta abordagem sistemática** (o mesmo loop toda vez):
   - Aplique o manifest quebrado
   - Observe: `kubectl get pods -n troubleshooting` — que status você vê?
   - Investigue: `kubectl describe pod <name> -n troubleshooting` — leia a seção de Events
   - Investigue mais: `kubectl logs <name> -n troubleshooting` — verifique a saída do container
   - Visão mais ampla: `kubectl get events -n troubleshooting --sort-by='.lastTimestamp'` — eventos a nível de cluster
   - Corrija o manifest e re-aplique

4. **Mantenha anotações** — para cada cenário, escreva:
   - O sintoma que você observou
   - O comando `kubectl` que revelou a causa raiz
   - A correção que você aplicou

## Critérios de Sucesso

- [ ] Todos os 8 cenários foram diagnosticados e corrigidos
- [ ] Cenário 1: Pod `broken-image` está Running com a imagem nginx correta
- [ ] Cenário 2: Pod `crashloop-app` está Running e não reiniciando
- [ ] Cenário 3: Pod `hungry-pod` está Running (não preso em Pending)
- [ ] Cenário 4: Service `web-svc` tem pelo menos um Endpoint
- [ ] Cenário 5: PVC `data-pvc` está Bound
- [ ] Cenário 6: ServiceAccount `pod-reader` pode listar pods (`kubectl auth can-i list pods --as=system:serviceaccount:troubleshooting:pod-reader -n troubleshooting` retorna `yes`)
- [ ] Cenário 7: Ingress `broken-ingress` roteia tráfego para o backend com sucesso (sem 503)
- [ ] Cenário 8: Pod `leaky-app` está Running e permanece Running (não OOMKilled)
- [ ] Você consegue explicar o comando de diagnóstico que revelou cada causa raiz

## Referência Linux ↔ Kubernetes

| Comando Linux | Equivalente Kubernetes | O Que Ele Diz |
|---|---|---|
| `dmesg` | `kubectl get events --sort-by='.lastTimestamp'` | Eventos de todo o cluster: falhas de agendamento, pulls de imagem, OOM kills |
| `journalctl -xe` | `kubectl describe pod <name>` | Status detalhado de um único recurso — condições, eventos, estado |
| `strace -p <PID>` | `kubectl debug -it <pod> --image=busybox --target=<container>` | Anexar um container de debug para inspecionar um processo em execução |
| `systemctl status <svc>` | `kubectl get pods -o wide` | Verificação rápida de status — está em execução, onde, qual IP? |
| `netstat -tlnp` / `ss -tlnp` | `kubectl get svc,endpoints` | Verificar listeners e targets de backend |
| `/var/log/messages` | `kubectl logs <pod> [-c container]` | Saída stdout/stderr da aplicação |
| `free -h` | `kubectl top nodes` / `kubectl top pods` | Consumo de memória e CPU |
| `lsof -i :<port>` | `kubectl exec <pod> -- netstat -tlnp` | Verificar qual processo é dono de uma porta dentro de um Pod |

## Dicas

<details>
<summary>Dica 1: O loop universal de troubleshooting</summary>

Para **todo** Pod quebrado, comece com estes três comandos nesta ordem:

```bash
# 1. Em que status o Pod está?
kubectl get pods -n troubleshooting

# 2. POR QUE está nesse status? (leia os Events no final)
kubectl describe pod <pod-name> -n troubleshooting

# 3. O que o container imprimiu antes de morrer?
kubectl logs <pod-name> -n troubleshooting
```

A seção `Events` no final do `kubectl describe` é a informação mais útil. Leia-a **toda vez**.
</details>

<details>
<summary>Dica 2: ImagePullBackOff — o nome da imagem está errado</summary>

Quando você vê `ImagePullBackOff` ou `ErrImagePull`, o Kubernetes não consegue baixar a imagem do container. Causas comuns:

- Erro de digitação no nome da imagem (verifique a ortografia com cuidado!)
- Tag errada (`:lastest` vs `:latest`)
- Registry privado sem `imagePullSecrets`

Para verificar: `kubectl describe pod <name> -n troubleshooting` mostrará a mensagem de erro exata, como `manifest unknown` ou `repository does not exist`.

Para corrigir um deployment em execução:
```bash
kubectl set image deployment/<name> <container>=<correct-image> -n troubleshooting
```
</details>

<details>
<summary>Dica 3: CrashLoopBackOff — o container continua morrendo</summary>

`CrashLoopBackOff` significa que o container inicia, encerra, e o Kubernetes o reinicia — repetidamente com backoff exponencial.

Verifique **por que** ele encerra:
```bash
kubectl logs <pod-name> -n troubleshooting
# Se o container já reiniciou, verifique a instância ANTERIOR:
kubectl logs <pod-name> -n troubleshooting --previous
```

Causas comuns:
- Comando/entrypoint ruim — o processo encerra imediatamente
- Variável de ambiente ausente que a aplicação requer
- Aplicação crasha na inicialização (segfault, exceção não capturada)
</details>

<details>
<summary>Dica 4: Pods Pending — falhas de agendamento</summary>

Um Pod preso em `Pending` nunca foi agendado em um node. Verifique por quê:

```bash
kubectl describe pod <name> -n troubleshooting
```

Procure por eventos como:
- `FailedScheduling` — `Insufficient memory` ou `Insufficient cpu`
- `0/1 nodes are available: 1 Insufficient memory`

Em um cluster Kind, verifique a capacidade do node:
```bash
kubectl describe node | grep -A 5 "Allocatable"
```

Se o Pod requisita mais recursos do que qualquer node tem, reduza o request.
</details>

<details>
<summary>Dica 5: Service não roteando — selector mismatch</summary>

Se um Service não tem Endpoints, o tráfego não vai a lugar nenhum. Verifique:

```bash
# O service tem endpoints?
kubectl get endpoints <svc-name> -n troubleshooting

# Qual selector o service está usando?
kubectl describe svc <svc-name> -n troubleshooting

# Quais labels os pods têm?
kubectl get pods -n troubleshooting --show-labels
```

O selector do Service deve corresponder **exatamente** aos labels do Pod. Até `app: web` vs `app: Web` é um mismatch!
</details>

<details>
<summary>Dica 6: PVC Pending e RBAC Forbidden</summary>

**PVC Pending:**
```bash
kubectl describe pvc <name> -n troubleshooting
```
Procure por: `storageclass.storage.k8s.io "<name>" not found`. Liste as StorageClasses disponíveis:
```bash
kubectl get storageclass
```
No Kind, a StorageClass padrão é `standard`.

**RBAC Forbidden:**
Teste permissões explicitamente:
```bash
kubectl auth can-i list pods --as=system:serviceaccount:troubleshooting:pod-reader -n troubleshooting
```
Se disser `no`, você precisa de um Role + RoleBinding. Verifique o que existe:
```bash
kubectl get roles,rolebindings -n troubleshooting
```
</details>

## Recursos de Aprendizado

- [Kubernetes — Troubleshooting Applications](https://kubernetes.io/docs/tasks/debug/debug-application/)
- [Kubernetes — Troubleshooting Clusters](https://kubernetes.io/docs/tasks/debug/debug-cluster/)
- [Kubernetes — Debug Pods](https://kubernetes.io/docs/tasks/debug/debug-application/debug-pods/)
- [Kubernetes — Debug Services](https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/)
- [Kubernetes — Debug Running Pods (ephemeral containers)](https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/)
- [Kubernetes — Resource Management](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)
- [Kubernetes — RBAC Authorization](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
- [Kubernetes — Events](https://kubernetes.io/docs/reference/kubernetes-api/cluster-resources/event-v1/)

---

## Break & Fix 🔧

Trabalhe através de cada cenário em ordem. Eles ficam progressivamente mais difíceis.

---

### Cenário 1: ImagePullBackOff 🖼️

**Aplique o manifest quebrado:**

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

**Sintomas que você verá:**
```
NAME                            READY   STATUS             RESTARTS   AGE
broken-image-xxxxxxxxx-xxxxx   0/1     ImagePullBackOff   0          30s
```

**Sua tarefa:** Diagnostique por que a imagem não pode ser puxada e corrija o Deployment.

<details>
<summary>💡 Solução</summary>

**Diagnóstico:**
```bash
kubectl describe pod -l app=broken-image -n troubleshooting
```
In the Events section you'll see:
```
Failed to pull image "ngnix:latest": ... manifest unknown
```

**Causa raiz:** O nome da imagem é `ngnix` — deveria ser `nginx` (letras transpostas).

**Correção:**
```bash
kubectl set image deployment/broken-image web=nginx:latest -n troubleshooting
```

**Verificação:**
```bash
kubectl get pods -n troubleshooting -l app=broken-image
# STATUS deve ser Running
```
</details>

---

### Cenário 2: CrashLoopBackOff 💥

**Aplique o manifest quebrado:**

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

**Sintomas que você verá:**
```
NAME             READY   STATUS             RESTARTS      AGE
crashloop-app    0/1     CrashLoopBackOff   3 (20s ago)   60s
```

**Sua tarefa:** Descubra por que o container continua crashando e corrija para que ele permaneça em execução.

<details>
<summary>💡 Solução</summary>

**Diagnóstico:**
```bash
kubectl logs crashloop-app -n troubleshooting
```
Output:
```
cat: can't open '/config/app.conf': No such file or directory
```

**Causa raiz:** O container executa `cat /config/app.conf`, mas esse arquivo não existe. O comando encerra imediatamente com um erro, causando o loop de reinício.

**Correção:** Delete o Pod quebrado e crie um com um comando que permanece em execução:

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

**Verificação:**
```bash
kubectl get pod crashloop-app -n troubleshooting
# STATUS: Running, RESTARTS: 0
```
</details>

---

### Cenário 3: Pod Pending (Recursos Insuficientes) ⏳

**Aplique o manifest quebrado:**

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

**Sintomas que você verá:**
```
NAME         READY   STATUS    RESTARTS   AGE
hungry-pod   0/1     Pending   0          45s
```

O Pod fica em `Pending` para sempre — ele nunca é agendado.

**Sua tarefa:** Diagnostique por que o Pod não pode ser agendado e corrija-o.

<details>
<summary>💡 Solução</summary>

**Diagnóstico:**
```bash
kubectl describe pod hungry-pod -n troubleshooting
```
In the Events section:
```
Warning  FailedScheduling  0/1 nodes are available: 1 Insufficient memory.
```

Verifique quanta memória seu node Kind realmente tem:
```bash
kubectl describe node | grep -A 5 "Allocatable:"
```
Um node Kind típico tem 8–16Gi. O Pod requisita 64Gi — impossível de agendar.

**Correção:** Delete e recrie com um request de memória razoável:

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

**Verificação:**
```bash
kubectl get pod hungry-pod -n troubleshooting
# STATUS: Running
```
</details>

---

### Cenário 4: Service Não Roteando (Label Mismatch) 🏷️

**Aplique o manifest quebrado:**

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

**Sintomas que você verá:**

Os Pods estão Running, o Service existe, mas:
```bash
kubectl get endpoints web-svc -n troubleshooting
# ENDPOINTS: <none>
```
Qualquer requisição ao Service expira ou retorna connection refused.

**Sua tarefa:** Descubra por que o Service não tem endpoints e corrija-o.

<details>
<summary>💡 Solução</summary>

**Diagnóstico:**
```bash
# Verifique o selector do service
kubectl describe svc web-svc -n troubleshooting
# Selector: app=web-backend

# Verifique os labels dos pods
kubectl get pods -n troubleshooting --show-labels
# Labels incluem: app=web-frontend
```

**Causa raiz:** O Service seleciona `app: web-backend`, mas os Pods estão rotulados como `app: web-frontend`. O selector não corresponde, então o Service tem zero endpoints.

**Correção:** Faça patch no selector do Service para corresponder aos labels dos Pods:

```bash
kubectl patch svc web-svc -n troubleshooting -p '{"spec":{"selector":{"app":"web-frontend"}}}'
```

**Verificação:**
```bash
kubectl get endpoints web-svc -n troubleshooting
# ENDPOINTS: 10.244.x.x:80,10.244.x.x:80
```
</details>

---

### Cenário 5: PVC Preso em Pending 💾

**Aplique o manifest quebrado:**

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

**Sintomas que você verá:**
```bash
kubectl get pvc -n troubleshooting
# NAME       STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS   AGE
# data-pvc   Pending                                       premium-fast   30s

kubectl get pod data-pod -n troubleshooting
# NAME       READY   STATUS    RESTARTS   AGE
# data-pod   0/1     Pending   0          30s
```

Tanto o PVC quanto o Pod ficam presos em Pending.

**Sua tarefa:** Diagnostique por que o PVC não pode ser vinculado e corrija-o.

<details>
<summary>💡 Solução</summary>

**Diagnóstico:**
```bash
kubectl describe pvc data-pvc -n troubleshooting
```
In the Events section:
```
Warning  ProvisioningFailed  storageclass.storage.k8s.io "premium-fast" not found
```

Verifique quais StorageClasses estão disponíveis:
```bash
kubectl get storageclass
# NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
# standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer
```

**Causa raiz:** O PVC referencia a StorageClass `premium-fast`, que não existe. O Kind usa `standard` como sua StorageClass padrão.

**Correção:** Delete e recrie com a StorageClass correta:

```bash
kubectl delete pod data-pod -n troubleshooting
kubectl delete pvc data-pvc -n troubleshooting
```

Edite o manifest para alterar `storageClassName: premium-fast` para `storageClassName: standard` (ou remova o campo `storageClassName` completamente para usar o padrão), e então reaplique.

**Verificação:**
```bash
kubectl get pvc -n troubleshooting
# STATUS: Bound

kubectl get pod data-pod -n troubleshooting
# STATUS: Running
```
</details>

---

### Cenário 6: RBAC Forbidden 🔐

**Aplique o manifest quebrado:**

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

**Sintomas que você verá:**

O ServiceAccount existe, o Role existe, mas:

```bash
kubectl auth can-i list pods --as=system:serviceaccount:troubleshooting:pod-reader -n troubleshooting
# no
```

O ServiceAccount é **proibido** de listar Pods, mesmo existindo um Role que concede essa permissão.

**Sua tarefa:** Diagnostique por que o ServiceAccount não pode listar Pods e corrija-o.

<details>
<summary>💡 Solução</summary>

**Diagnóstico:**
```bash
# O Role existe com as permissões corretas:
kubectl describe role pod-reader-role -n troubleshooting
# Resources: pods — Verbs: get, list, watch  ✓

# Mas existe um RoleBinding conectando o ServiceAccount ao Role?
kubectl get rolebindings -n troubleshooting
# No resources found
```

**Causa raiz:** Existe um Role, e existe um ServiceAccount, mas **não existe um RoleBinding** conectando-os. Sem o binding, a permissão nunca é concedida.

**Correção:** Crie o RoleBinding ausente:

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

**Verificação:**
```bash
kubectl auth can-i list pods --as=system:serviceaccount:troubleshooting:pod-reader -n troubleshooting
# yes
```
</details>

---

### Cenário 7: Ingress Retorna 503 🌐

> **Pré-requisito:** Este cenário requer o NGINX Ingress Controller do Desafio 06. Se você não o tem instalado, execute:
> ```bash
> kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
> kubectl wait --namespace ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=90s
> ```

**Aplique o manifest quebrado:**

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

**Sintomas que você verá:**

```bash
curl http://scenario7.localhost/
# <html><body><h1>503 Service Temporarily Unavailable</h1></body></html>
```

O Ingress está configurado, o Pod está Running, o Service tem endpoints — mas você recebe 503.

**Sua tarefa:** Diagnostique por que o Ingress retorna 503 e corrija-o.

<details>
<summary>💡 Solução</summary>

**Diagnóstico:**
```bash
# Pod está rodando — ok
kubectl get pods -l app=backend -n troubleshooting

# Service tem endpoints — ok
kubectl get endpoints backend-svc -n troubleshooting
# ENDPOINTS: 10.244.x.x:9999

# Espere — a porta do endpoint é 9999, mas o container escuta na 5678!
kubectl describe svc backend-svc -n troubleshooting
# TargetPort: 9999
```

O Service encaminha tráfego para a porta 9999, mas o `http-echo` escuta na porta **5678**. A conexão é recusada no nível do Pod, e o Ingress Controller traduz isso para um 503.

**Causa raiz:** O `targetPort` do Service é `9999` — deveria ser `5678` para corresponder à porta de escuta do container.

**Correção:**
```bash
kubectl patch svc backend-svc -n troubleshooting -p '{"spec":{"ports":[{"port":80,"targetPort":5678}]}}'
```

**Verificação:**
```bash
curl http://scenario7.localhost/
# Scenario 7 works!
```
</details>

---

### Cenário 8: OOMKilled 💀

**Aplique o manifest quebrado:**

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

**Sintomas que você verá:**
```bash
kubectl get pods -n troubleshooting
# NAME        READY   STATUS      RESTARTS      AGE
# leaky-app   0/1     OOMKilled   3 (20s ago)   60s
```

O Pod continua reiniciando com status `OOMKilled`.

**Sua tarefa:** Diagnostique o que está acontecendo e corrija para que o Pod continue rodando.

<details>
<summary>💡 Solução</summary>

**Diagnóstico:**
```bash
kubectl describe pod leaky-app -n troubleshooting
```
In the container status section:
```
Last State:  Terminated
  Reason:    OOMKilled
  Exit Code: 137
```

A ferramenta `stress` está configurada para alocar 256M de memória (`--vm-bytes 256M`), mas o container tem um limite de memória rígido de 64Mi. Quando o processo excede 64Mi, o OOM killer do kernel Linux o termina (exit code 137 = SIGKILL).

**Causa raiz:** O limite de memória (64Mi) está muito abaixo do que o processo precisa (256M).

**Correção:** Aumente o limite de memória para acomodar a carga de trabalho, ou reduza o consumo de memória. Delete e recrie:

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

**Verificação:**
```bash
kubectl get pod leaky-app -n troubleshooting
# STATUS: Running, RESTARTS: 0

# Confirme que está realmente usando memória:
kubectl top pod leaky-app -n troubleshooting
```
</details>

---

## 🏆 Bônus: Debug Como um Profissional

Após completar todos os 8 cenários, tente estas técnicas avançadas:

**Containers de debug efêmeros** — anexe um container de troubleshooting a um Pod em execução sem modificá-lo:
```bash
kubectl debug -it <pod-name> -n troubleshooting --image=busybox:1.37 --target=<container-name>
```

**Debug em nível de node** — obtenha um shell no próprio node Kind:
```bash
kubectl debug node/<node-name> -it --image=busybox:1.37
```

**Monitoramento rápido de eventos** — observe eventos em tempo real enquanto aplica manifests quebrados:
```bash
kubectl get events -n troubleshooting --watch
```

---

> **🎉 Parabéns!** Se você completou todos os 8 cenários, você construiu um verdadeiro kit de ferramentas de troubleshooting. Estes são os mesmos modos de falha que você verá em produção — agora você sabe como diagnosticá-los sistematicamente.
