# Solução 12 — Observability

[< Voltar ao Desafio](../Student/Challenge-12.md) | **[Home](README.md)**

---

## Tarefa 1: Logs de Container com `kubectl logs`

### Passo a passo

**1a.** Implante o Pod multi-container de logging:

```yaml
# Save as logging-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: logging-demo
  labels:
    app: logging-demo
spec:
  containers:
    - name: webapp
      image: busybox:stable
      command: ["/bin/sh", "-c"]
      args:
        - |
          i=0
          while true; do
            echo "[webapp] Request $i handled successfully"
            i=$((i+1))
            sleep 2
          done
    - name: sidecar
      image: busybox:stable
      command: ["/bin/sh", "-c"]
      args:
        - |
          while true; do
            echo "[sidecar] Health check passed at $(date)"
            sleep 5
          done
```

```bash
kubectl apply -f logging-pod.yaml
kubectl wait --for=condition=Ready pod/logging-demo --timeout=60s
```

**1b.** Pratique todos os padrões de recuperação de logs:

```bash
# Single container
kubectl logs pod/logging-demo -c webapp
```

Saída esperada:

```
[webapp] Request 0 handled successfully
[webapp] Request 1 handled successfully
[webapp] Request 2 handled successfully
...
```

```bash
# Follow mode — like tail -f
kubectl logs -f pod/logging-demo -c webapp
# Press Ctrl+C to stop

# All containers in a Pod
kubectl logs pod/logging-demo --all-containers=true

# Last 10 lines only
kubectl logs pod/logging-demo -c webapp --tail=10

# Logs from the last 30 seconds
kubectl logs pod/logging-demo -c webapp --since=30s
```

```bash
# Logs from a Deployment (picks one Pod automatically)
kubectl create deployment nginx-log-test --image=nginx:stable --replicas=2
kubectl logs deployment/nginx-log-test
```

**1c.** Visualize logs de containers anteriores (essencial para depurar crashes):

```bash
# Force the webapp container to crash
kubectl exec logging-demo -c webapp -- /bin/sh -c "kill 1"

# Wait a moment for the container to restart
sleep 5

# View previous (crashed) instance logs
kubectl logs pod/logging-demo -c webapp --previous
```

Esperado: Você verá a saída de logs da instância **terminada** do container — é como ler um arquivo de log rotacionado.

### Verificação

```bash
# Confirm the container restarted
kubectl get pod logging-demo
```

Esperado: Contagem de `RESTARTS` ≥ 1, status `Running`.

> **Dica para o Coach:** A flag `--previous` é a ferramenta de depuração nº 1 mais útil para CrashLoopBackOff. Certifique-se de que os alunos entendam isso — ela recupera os logs da última instância terminada do container.

---

## Tarefa 2: Métricas de Recursos com `kubectl top`

### Passo a passo

Verifique se o Metrics Server está em execução (instalado no Desafio 10):

```bash
kubectl -n kube-system get pods -l k8s-app=metrics-server
```

Esperado: Um pod `metrics-server-xxxx` no estado `Running`.

Se o Metrics Server NÃO estiver em execução, instale e aplique o patch para Kind:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl patch -n kube-system deployment metrics-server \
  --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl -n kube-system rollout status deployment metrics-server
```

> **Por que o patch?** O Kind usa certificados kubelet auto-assinados. Sem `--kubelet-insecure-tls`, o Metrics Server se recusa a coletar métricas e o `kubectl top` falha.

Agora execute os comandos de métricas:

```bash
# Node-level metrics — like running top on each server
kubectl top nodes
```

Saída esperada:

```
NAME                     CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
fasthack-control-plane   150m         7%     1200Mi          30%
```

```bash
# Pod-level metrics
kubectl top pods -A

# Sort by CPU
kubectl top pods -A --sort-by=cpu

# Sort by memory
kubectl top pods -A --sort-by=memory

# Specific namespace
kubectl top pods -n kube-system
```

### Verificação

```bash
kubectl top nodes && kubectl top pods -A --sort-by=memory | head -10
```

Ambos os comandos devem retornar dados sem erros.

> **Dica para o Coach:** Se `kubectl top` retornar `error: Metrics API not available`, o Metrics Server não está instalado ou falhou ao iniciar. Verifique os logs: `kubectl -n kube-system logs deployment/metrics-server --tail=20`. O problema mais comum no Kind é a ausência da flag `--kubelet-insecure-tls`.

---

## Tarefa 3: Implantar Prometheus e Grafana com Helm

### Passo a passo

**3a.** Adicione o repositório Helm e instale:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --wait --timeout 5m
```

> **Por que as duas flags `--set`?** Elas instruem o Prometheus a descobrir **todos** os ServiceMonitors e PodMonitors no cluster, não apenas aqueles rotulados com o release do Helm. Sem elas, o Prometheus não encontra monitors criados fora do release do Helm.

**3b.** Verifique se tudo está em execução:

```bash
kubectl -n monitoring get pods
```

Saída esperada (nomes podem variar):

```
NAME                                                      READY   STATUS    RESTARTS   AGE
alertmanager-kube-prometheus-stack-alertmanager-0          2/2     Running   0          2m
kube-prometheus-stack-grafana-xxxxxxxxx-xxxxx              3/3     Running   0          2m
kube-prometheus-stack-kube-state-metrics-xxxxxxxxx-xxxxx   1/1     Running   0          2m
kube-prometheus-stack-operator-xxxxxxxxx-xxxxx             1/1     Running   0          2m
kube-prometheus-stack-prometheus-node-exporter-xxxxx       1/1     Running   0          2m
prometheus-kube-prometheus-stack-prometheus-0              2/2     Running   0          2m
```

Todos os pods devem estar `Running`. Isso pode levar de 2 a 5 minutos no Kind.

**3c.** Recupere a senha admin do Grafana:

```bash
kubectl -n monitoring get secret kube-prometheus-stack-grafana \
  -o jsonpath="{.data.admin-password}" | base64 --decode; echo
```

Saída esperada:

```
prom-operator
```

O nome de usuário é `admin`.

**3d.** Acesse o Grafana via port-forward:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

Abra [http://localhost:3000](http://localhost:3000) e faça login com `admin` / `prom-operator`.

### Verificação

- A página de login do Grafana carrega em localhost:3000
- O login funciona com `admin` / `prom-operator`
- O menu de Dashboards mostra dashboards pré-configurados

> **Dica para o Coach:** Se os pods estiverem presos em `Pending`, provavelmente há pressão de recursos no node do Kind. Verifique com `kubectl -n monitoring describe pod <name>` para falhas de agendamento. Você pode reduzir os requests com `helm upgrade ... --set prometheus.prometheusSpec.resources.requests.memory=256Mi --reuse-values`.

---

## Tarefa 4: Explorar Dashboards Nativos do Grafana

### Passo a passo

**4a.** No Grafana, navegue até **Dashboards** → **Browse**. Procure por estes dashboards:

- **Kubernetes / Compute Resources / Cluster** — uso geral de CPU e memória
- **Kubernetes / Compute Resources / Namespace (Pods)** — detalhamento por namespace
- **Kubernetes / Compute Resources / Pod** — visualização detalhada de um Pod específico
- **Node Exporter / Nodes** — métricas de SO no nível do node (como `sar` no Linux)
- **CoreDNS** — taxas de consultas DNS e latência

**4b.** Gere carga para ver os dashboards se popularem:

```bash
# Create a CPU load generator
kubectl run metrics-load --image=busybox:stable --restart=Never \
  -- /bin/sh -c "while true; do echo 'working'; done"
```

Observe o dashboard **Kubernetes / Compute Resources / Cluster** — o uso de CPU deve subir.

```bash
# Clean up when done observing
kubectl delete pod metrics-load
```

**4c.** (Opcional) Acesse a UI do Prometheus diretamente:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

Abra [http://localhost:9090](http://localhost:9090) → **Status → Targets** para ver o que o Prometheus está coletando.

### Verificação

- Pelo menos 2 dashboards do Grafana mostram dados reais (gráficos de CPU, memória)
- A página de Targets do Prometheus mostra alvos de coleta saudáveis (status "UP" em verde)

> **Dica para o Coach:** Os alunos frequentemente têm dificuldade para encontrar os dashboards. Em versões mais novas do Grafana, navegue pelo menu hamburger → Dashboards. Os dashboards pré-instalados estão na pasta "General" ou podem ser encontrados pela busca por nome.

---

## Tarefa 5: Os Três Pilares — Logs, Métricas, Traces

Este é um checkpoint conceitual. Certifique-se de que os alunos consigam explicar:

| Pilar | Pergunta que responde | Ferramentas Kubernetes | Analogia Linux |
|---|---|---|---|
| **Logs** | Quais eventos discretos aconteceram? | `kubectl logs`, Fluentd/Fluent Bit, Loki | `journalctl`, `/var/log`, rsyslog |
| **Métricas** | Como os indicadores numéricos estão evoluindo? | Metrics Server, Prometheus, Grafana | `sar`, `vmstat`, `top`, collectd |
| **Traces** | Como uma requisição flui entre serviços? | OpenTelemetry, Jaeger, Zipkin | `strace`, agentes APM de aplicação |

> **Dica para o Coach:** Traces são apenas conceituais neste laboratório. Não é necessária nenhuma configuração prática de tracing. O ponto-chave é entender onde o tracing se encaixa — ele responde "onde o tempo foi gasto?" para uma única requisição atravessando múltiplos microsserviços.

---

## Tarefa 6: Probes de Liveness, Readiness e Startup

### Passo a passo

**6a.** Implante um Pod com os três probes:

```yaml
# Save as probed-app.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: probed-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: probed-app
  template:
    metadata:
      labels:
        app: probed-app
    spec:
      containers:
        - name: webapp
          image: nginx:stable
          ports:
            - containerPort: 80
          startupProbe:
            httpGet:
              path: /
              port: 80
            failureThreshold: 30
            periodSeconds: 2
          livenessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 0
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 0
            periodSeconds: 5
            failureThreshold: 3
---
apiVersion: v1
kind: Service
metadata:
  name: probed-app
spec:
  selector:
    app: probed-app
  ports:
    - port: 80
      targetPort: 80
```

```bash
kubectl apply -f probed-app.yaml
kubectl rollout status deployment probed-app
```

**6b.** Verifique se os probes estão configurados:

```bash
kubectl describe pod -l app=probed-app | grep -A 5 "Liveness\|Readiness\|Startup"
```

Esperado: Todos os três probes listados com seus caminhos HTTP GET e parâmetros de temporização.

**6c.** Observe a falha do liveness probe — simule um processo travado:

```bash
# Delete the default nginx page to make the liveness probe fail
POD_NAME=$(kubectl get pods -l app=probed-app -o jsonpath='{.items[0].metadata.name}')
kubectl exec "$POD_NAME" -- rm /usr/share/nginx/html/index.html

# Watch the Pod — liveness probe will fail and restart the container
kubectl get pods -l app=probed-app --watch
```

Esperado: Em aproximadamente 30 segundos, a contagem de `RESTARTS` aumenta. O probe retornou 404 (não 2xx), o Kubernetes matou e reiniciou o container, o que restaurou o `index.html` padrão.

```bash
# Check events for proof
kubectl describe pod "$POD_NAME" | tail -20
```

Eventos esperados:

```
Warning  Unhealthy  Liveness probe failed: HTTP probe failed with statuscode: 404
Normal   Killing    Container webapp failed liveness probe, will be restarted
```

**6d.** Observe a falha do readiness probe:

```yaml
# Save as unready-app.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: unready-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: unready-app
  template:
    metadata:
      labels:
        app: unready-app
    spec:
      containers:
        - name: webapp
          image: nginx:stable
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /ready
              port: 80
            periodSeconds: 5
            failureThreshold: 1
---
apiVersion: v1
kind: Service
metadata:
  name: unready-app
spec:
  selector:
    app: unready-app
  ports:
    - port: 80
      targetPort: 80
```

```bash
kubectl apply -f unready-app.yaml
sleep 10
kubectl get pods -l app=unready-app
```

Esperado: O Pod mostra `0/1 READY` — o caminho `/ready` não existe no nginx, então o readiness probe falha. O Pod continua em execução mas **não recebe tráfego**.

```bash
kubectl get endpoints unready-app
```

Esperado: `ENDPOINTS: <none>` — o Service não tem backends.

### Verificação

- Probed-app: container reiniciou após falha de liveness (RESTARTS ≥ 1)
- Unready-app: Pod está `0/1 READY`, lista de endpoints está vazia
- Os alunos conseguem explicar: liveness → reinicia, readiness → remove dos endpoints, startup → bloqueia liveness/readiness

> **Dica para o Coach:** O modelo mental principal:
> - **Startup probe** = "Ele terminou de inicializar?" (bloqueia os outros probes)
> - **Liveness probe** = "Ele ainda está vivo?" (como systemd Restart=always)
> - **Readiness probe** = "Ele pode atender tráfego?" (como health check do Nagios controlando o LB)

---

## Limpeza

```bash
kubectl delete -f logging-pod.yaml 2>/dev/null
kubectl delete deployment nginx-log-test 2>/dev/null
kubectl delete -f probed-app.yaml 2>/dev/null
kubectl delete -f unready-app.yaml 2>/dev/null
kubectl delete pod metrics-load 2>/dev/null
# Keep kube-prometheus-stack installed for later challenges
# To remove later: helm uninstall kube-prometheus-stack -n monitoring
```

---

## Problemas Comuns

| Problema | Causa | Correção |
|---------|-------|-----|
| `kubectl top` retorna "Metrics API not available" | Metrics Server não instalado ou não está em execução | Instale e aplique o patch para Kind com `--kubelet-insecure-tls` (veja Tarefa 2) |
| Pods do kube-prometheus-stack presos em `Pending` | Recursos insuficientes no node do Kind | Reduza os resource requests via `helm upgrade ... --set prometheus.prometheusSpec.resources.requests.memory=256Mi --reuse-values` |
| Port-forward do Grafana desconecta | Timeout por inatividade ou reinício do Pod | Execute novamente o comando `kubectl port-forward` |
| Não encontra dashboards no Grafana | Navegação da UI mudou em versões mais novas | Use a barra de busca (lupa) e digite "Kubernetes" |
| Flag `--previous` retorna "previous terminated container not found" | O container ainda não teve crash | Force um crash primeiro com `kubectl exec <pod> -- kill 1`, aguarde e tente novamente |
| Instalação do Helm excede o timeout | A flag `--wait` aguarda todos os pods ficarem Ready; pesado no Kind | Adicione `--timeout 10m` ou remova `--wait` e verifique manualmente |
