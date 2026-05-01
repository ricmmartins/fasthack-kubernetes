# Desafio 12 — Observabilidade

[< Desafio Anterior](Challenge-11.md) | **[Início](../README.md)** | [Próximo Desafio >](Challenge-13.md)

## Introdução

Em um servidor Linux você já conhece o kit de ferramentas de observabilidade: `journalctl -u nginx` para ler logs de serviços, `tail -f /var/log/syslog` para acompanhá-los em tempo real, `top` ou `htop` para uso de CPU e memória, `sar` e `vmstat` para métricas históricas, e Nagios ou Zabbix para alertas de health-check. Sua aplicação escreve no stdout/stderr (ou em arquivos sob `/var/log`), o systemd monitora seu processo e o reinicia se morrer, e você conecta Grafana ou Cacti contra Prometheus ou collectd para ter dashboards.

O Kubernetes segue o **mesmo modelo de três pilares** — Logs, Métricas e Traces — mas substitui as ferramentas específicas do Linux por equivalentes que entendem o cluster:

| Pilar | O que responde | Ferramenta Linux | Ferramenta Kubernetes |
|---|---|---|---|
| **Logs** | "O que aconteceu?" | `journalctl`, `tail -f`, `/var/log` | `kubectl logs`, stdout/stderr do container |
| **Métricas** | "Como está o desempenho?" | `top`, `sar`, `vmstat`, Prometheus em bare-metal | `kubectl top`, Metrics Server, Prometheus |
| **Traces** | "Onde o tempo foi gasto entre serviços?" | `strace`, tracing a nível de aplicação | OpenTelemetry, Jaeger (apenas conceito neste lab) |

Além disso, o Linux usa **watchdogs do systemd** e **health checks do Nagios** para saber se um processo está vivo e saudável. O Kubernetes substitui esses por **Liveness, Readiness e Startup Probes** — health checks integrados que rodam dentro do cluster e controlam decisões automatizadas de reinício e tráfego.

Neste desafio, você coletará logs, inspecionará métricas de recursos, implantará uma stack completa de monitoramento (Prometheus + Grafana) e configurará health probes — tudo no seu cluster Kind local.

> **Requisito de cluster:** Todos os exercícios usam um cluster local [Kind](https://kind.sigs.k8s.io/) — nenhuma conta em nuvem necessária. Se você ainda não criou um, execute:
> ```bash
> kind create cluster --name fasthack
> ```

## Descrição

### Tarefa 1 — Logs de container com `kubectl logs`

Os logs de container no Kubernetes são o equivalente ao `journalctl` e `/var/log` no Linux. O stdout e stderr de cada container são capturados pelo kubelet e disponibilizados através da API.

**1a.** Implante um Pod multi-container para praticar:

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

**1b.** Pratique cada padrão de recuperação de logs:

```bash
# Container único (quando o Pod tem apenas um container, ou especifique -c)
kubectl logs pod/logging-demo -c webapp

# Modo follow — como tail -f /var/log/syslog
kubectl logs -f pod/logging-demo -c webapp

# Pressione Ctrl+C para parar de acompanhar

# Todos os containers em um Pod
kubectl logs pod/logging-demo --all-containers=true

# Apenas as últimas 10 linhas — como tail -n 10
kubectl logs pod/logging-demo -c webapp --tail=10

# Logs dos últimos 30 segundos
kubectl logs pod/logging-demo -c webapp --since=30s

# Logs de um Deployment (escolhe um Pod)
kubectl create deployment nginx-log-test --image=nginx:stable --replicas=2
kubectl logs deployment/nginx-log-test
```

**1c.** Veja os logs do **container anterior** (crítico para depurar crashes):

```bash
# Force the webapp container to restart by killing the Pod
kubectl delete pod logging-demo
kubectl apply -f logging-pod.yaml
kubectl wait --for=condition=Ready pod/logging-demo --timeout=60s

# Simular um crash — exec no container e sair com erro
kubectl exec logging-demo -c webapp -- /bin/sh -c "kill 1"

# Aguarde um momento para o container reiniciar, depois veja os logs anteriores
sleep 5
kubectl logs pod/logging-demo -c webapp --previous
```

A flag `--previous` recupera os logs da **última instância encerrada** do container — como ler um arquivo de log rotacionado no Linux.

### Tarefa 2 — Métricas de recursos com `kubectl top`

O comando `kubectl top` é o equivalente Kubernetes do `top` / `htop`. Ele requer o **Metrics Server** que você instalou no Desafio 10.

```bash
# Verificar se o Metrics Server está em execução (instalado no Desafio 10)
kubectl -n kube-system get pods -l k8s-app=metrics-server

# Métricas a nível de node — como executar top em cada servidor
kubectl top nodes

# Métricas a nível de Pod — como ps aux ordenado por CPU
kubectl top pods -A

# Ordenar por uso de CPU
kubectl top pods -A --sort-by=cpu

# Ordenar por memória
kubectl top pods -A --sort-by=memory

# Namespace específico
kubectl top pods -n kube-system
```

> **Se `kubectl top` retornar um erro:** Certifique-se de que o Metrics Server está instalado e configurado para o Kind. Consulte o Desafio 10, Tarefa 1, ou execute:
> ```bash
> kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
> kubectl patch -n kube-system deployment metrics-server \
>   --type=json \
>   -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
> kubectl -n kube-system rollout status deployment metrics-server
> ```

### Tarefa 3 — Implantar Prometheus e Grafana com Helm

No Linux, você pode instalar o Prometheus a partir de um tarball e configurar o Grafana manualmente. No Kubernetes, o chart Helm **kube-prometheus-stack** empacota tudo: Prometheus, Grafana, Alertmanager, node-exporter e kube-state-metrics — com dashboards pré-configurados.

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

> As duas flags `--set` dizem ao Prometheus para descobrir **todos** os ServiceMonitors e PodMonitors no cluster, não apenas aqueles com o label da release Helm. Isso é importante para a Tarefa 7 (Cenário Break & Fix 3).

**3b.** Verifique se tudo está em execução:

```bash
kubectl -n monitoring get pods
```

Você deve ver Pods para: `prometheus-kube-prometheus-stack-prometheus-0`, `kube-prometheus-stack-grafana-*`, `alertmanager-*`, `kube-prometheus-stack-kube-state-metrics-*`, `kube-prometheus-stack-prometheus-node-exporter-*` e o `kube-prometheus-stack-operator-*`.

**3c.** Recupere a senha de admin do Grafana:

```bash
kubectl -n monitoring get secret kube-prometheus-stack-grafana \
  -o jsonpath="{.data.admin-password}" | base64 --decode; echo
```

O nome de usuário padrão é `admin`.

**3d.** Acesse o Grafana via port-forward:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

Abra [http://localhost:3000](http://localhost:3000) no seu navegador e faça login com as credenciais acima.

### Tarefa 4 — Explorar os dashboards integrados do Grafana

O kube-prometheus-stack vem com dezenas de dashboards pré-configurados.

**4a.** No Grafana, navegue até **Dashboards** (barra lateral esquerda) → **Browse**. Procure estes dashboards:

- **Kubernetes / Compute Resources / Cluster** — uso geral de CPU e memória
- **Kubernetes / Compute Resources / Namespace (Pods)** — detalhamento por namespace
- **Kubernetes / Compute Resources / Pod** — drill into em um Pod específico
- **Node Exporter / Nodes** — métricas de SO a nível de node (como `sar` no Linux)
- **CoreDNS** — taxas de consulta DNS e latência

**4b.** Gere alguma atividade no cluster para ver os dashboards se popularem:

```bash
# Em um terminal separado, crie um gerador de carga
kubectl run metrics-load --image=busybox:stable --restart=Never \
  -- /bin/sh -c "while true; do echo 'working'; done"
```

Observe o dashboard **Kubernetes / Compute Resources / Cluster** — você deve ver o uso de CPU subir.

```bash
# Limpe o gerador de carga quando terminar de observar
kubectl delete pod metrics-load
```

**4c.** (Opcional) Acesse a UI do Prometheus diretamente:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

Abra [http://localhost:9090](http://localhost:9090), vá em **Status → Targets** para ver o que o Prometheus está coletando. Isso é análogo a verificar se todos os seus agentes Nagios NRPE estão reportando.

### Tarefa 5 — Os três pilares: Logs, Métricas, Traces

Antes de prosseguir, certifique-se de que você entende o framework conceitual:

| Pilar | Pergunta que responde | Ferramentas Kubernetes | Analogia Linux |
|---|---|---|---|
| **Logs** | Quais eventos discretos aconteceram? | `kubectl logs`, Fluentd/Fluent Bit, Loki | `journalctl`, `/var/log`, rsyslog |
| **Métricas** | Como os indicadores numéricos estão tendendo ao longo do tempo? | Metrics Server, Prometheus, Grafana | `sar`, `vmstat`, `top`, collectd |
| **Traces** | Como uma única requisição flui entre serviços? | OpenTelemetry, Jaeger, Zipkin | `strace`, agentes APM de aplicação |

> **Nota:** Tracing distribuído (Jaeger/OpenTelemetry) é um tópico apenas conceitual neste desafio. Configurar um pipeline completo de tracing está além do escopo deste lab, mas você deve entender onde ele se encaixa no cenário de observabilidade.

### Tarefa 6 — Liveness, Readiness e Startup Probes

No Linux, o `systemd` reinicia um processo que crashou e o Nagios verifica se um serviço está saudável. O Kubernetes usa **probes** para o mesmo propósito:

| Probe | Propósito | Analogia Linux | O que acontece na falha |
|---|---|---|---|
| **Liveness** | O processo do container está vivo? | systemd `Restart=always` | Container é morto e reiniciado |
| **Readiness** | O container pode servir tráfego? | Nagios/Zabbix health check | Pod removido dos endpoints do Service (sem tráfego) |
| **Startup** | O container terminou de iniciar? | systemd verificação `ExecStartPre` | Liveness/readiness probes são pausados até o startup ter sucesso |

**6a.** Implante um Pod com os três probes configurados:

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

**6b.** Verifique se os probes estão funcionando:

```bash
kubectl describe pod -l app=probed-app | grep -A 5 "Liveness\|Readiness\|Startup"
```

**6c.** Observe o **comportamento do liveness probe** — simule um processo travado:

```bash
# Exec no Pod e delete a página padrão do nginx
POD_NAME=$(kubectl get pods -l app=probed-app -o jsonpath='{.items[0].metadata.name}')
kubectl exec "$POD_NAME" -- rm /usr/share/nginx/html/index.html

# Observe o Pod — o liveness probe vai falhar e reiniciar o container
kubectl get pods -l app=probed-app --watch
```

Dentro de 30 segundos você deve ver a contagem de `RESTARTS` aumentar. O liveness probe retornou um 404, o Kubernetes matou o container e o reinício restaurou o `index.html` padrão.

```bash
# Verificar eventos como prova
kubectl describe pod "$POD_NAME" | grep -A 5 "Events"
```

**6d.** Observe o **comportamento do readiness probe** — o Pod continua em execução mas para de receber tráfego:

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

O Pod vai mostrar `0/1 READY` porque `/ready` não existe na imagem padrão do nginx (retorna 404). O Pod está em execução mas o Service tem **zero endpoints**:

```bash
kubectl get endpoints unready-app
```

A lista de endpoints estará vazia — nenhum tráfego chega a este Pod. Este é o equivalente Kubernetes de um check do Nagios marcando um servidor como "down" para que o load balancer pare de rotear para ele.

### Limpeza

```bash
kubectl delete -f logging-pod.yaml 2>/dev/null
kubectl delete deployment nginx-log-test 2>/dev/null
kubectl delete -f probed-app.yaml 2>/dev/null
kubectl delete -f unready-app.yaml 2>/dev/null
kubectl delete pod metrics-load 2>/dev/null
# Mantenha o kube-prometheus-stack instalado — você o usará em desafios posteriores
# Para removê-lo depois: helm uninstall kube-prometheus-stack -n monitoring
```

## Critérios de Sucesso

- [ ] Você consegue recuperar logs de um único container, de um container específico em um Pod multi-container e da instância anterior (crasheada).
- [ ] Você usou `kubectl logs -f` para acompanhar logs em tempo real (como `tail -f`).
- [ ] `kubectl top nodes` e `kubectl top pods` exibem métricas de CPU e memória.
- [ ] Prometheus e Grafana estão em execução no namespace `monitoring` via chart Helm kube-prometheus-stack.
- [ ] Você fez login no Grafana e visualizou pelo menos dois dashboards integrados mostrando dados de saúde do cluster.
- [ ] Você consegue acessar a UI do Prometheus e ver targets de scrape saudáveis em **Status → Targets**.
- [ ] Você consegue explicar os três pilares da observabilidade (Logs, Métricas, Traces) e nomear uma ferramenta Kubernetes para cada.
- [ ] Você implantou um Pod com liveness, readiness e startup probes e consegue explicar o que cada um faz.
- [ ] Você observou uma falha de liveness probe causar um reinício de container.
- [ ] Você observou uma falha de readiness probe causar um Pod a mostrar `0/1 READY` e não receber tráfego.

## Referência Linux ↔ Kubernetes

| Conceito Linux | Equivalente Kubernetes | Notas |
|---|---|---|
| `journalctl -u nginx` | `kubectl logs deployment/webapp` | Ver logs de um workload específico |
| `tail -f /var/log/syslog` | `kubectl logs -f pod/webapp` | Acompanhar logs em tempo real |
| `top` / `htop` | `kubectl top pods` | CPU e memória em tempo real por Pod |
| `/var/log/*.log` | stdout/stderr do container | Containers devem logar no stdout; o kubelet captura |
| `nagios` / `zabbix` health checks | Liveness / Readiness Probes | Health checks integrados que controlam reinício e decisões de tráfego |
| `systemd` watchdog / `Restart=always` | Startup Probe + Liveness Probe | Startup probe condiciona o liveness probe durante inicializações lentas |
| `sar` / `vmstat` | Métricas do Prometheus | Coleta e armazenamento de métricas em séries temporais |
| Cacti / Grafana no Linux | Dashboards Grafana no Kubernetes | Mesma ferramenta, implantada como Pod, pré-configurada pelo Helm |

## Dicas

<details>
<summary>Dica 1: O Metrics Server deve estar saudável antes do kubectl top funcionar</summary>

`kubectl top` depende do Metrics Server (instalado no Desafio 10). Se ele não estiver em execução, você receberá:

```
error: Metrics API not available
```

Verifique o status:

```bash
kubectl -n kube-system get pods -l k8s-app=metrics-server
kubectl -n kube-system logs deployment/metrics-server --tail=20
```

No Kind, o problema mais comum é a falta de `--kubelet-insecure-tls`. O Metrics Server não consegue verificar o certificado autoassinado do kubelet e se recusa a coletar. Reaplique o patch do Desafio 10 se necessário.

</details>

<details>
<summary>Dica 2: Pods do kube-prometheus-stack presos em Pending ou CrashLoopBackOff</summary>

Clusters Kind têm recursos limitados. Se Pods estiverem presos em `Pending`, verifique a pressão de recursos:

```bash
kubectl -n monitoring describe pod <pod-name> | grep -A 5 "Events"
kubectl top nodes
```

Se o node estiver no limite de capacidade, você pode reduzir as requisições de recursos da stack:

```bash
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set prometheus.prometheusSpec.resources.requests.memory=256Mi \
  --set prometheus.prometheusSpec.resources.requests.cpu=100m \
  --reuse-values
```

Também certifique-se de que seu cluster Kind tem memória suficiente alocada (pelo menos 4 GB recomendado para este desafio).

</details>

<details>
<summary>Dica 3: Como encontrar a senha do Grafana</summary>

A senha de admin do Grafana está armazenada em um Secret do Kubernetes:

```bash
kubectl -n monitoring get secret kube-prometheus-stack-grafana \
  -o jsonpath="{.data.admin-password}" | base64 --decode; echo
```

O nome de usuário é sempre `admin`. Se você definiu um nome de release customizado, substitua `kube-prometheus-stack` pelo nome da sua release.

</details>

<details>
<summary>Dica 4: Entendendo os parâmetros de tempo dos probes</summary>

Cada probe tem quatro ajustes de tempo:

| Parâmetro | Padrão | Significado |
|---|---|---|
| `initialDelaySeconds` | 0 | Segundos para aguardar após o container iniciar antes de probar |
| `periodSeconds` | 10 | Com que frequência probar |
| `failureThreshold` | 3 | Quantas falhas consecutivas antes de tomar ação |
| `timeoutSeconds` | 1 | Quanto tempo esperar por uma resposta do probe |

O tempo total antes do Kubernetes tomar ação na falha é aproximadamente:

```
initialDelaySeconds + (periodSeconds × failureThreshold)
```

Para o liveness probe com padrões: `0 + (10 × 3) = 30 segundos` antes do container ser morto.

**Startup probes** usam `failureThreshold × periodSeconds` como o orçamento total de inicialização. Na Tarefa 6a: `30 × 2 = 60 segundos` para o nginx iniciar antes do Kubernetes desistir.

</details>

<details>
<summary>Dica 5: Por que usar um Startup Probe?</summary>

Sem um startup probe, o liveness probe começa imediatamente. Se sua aplicação leva 60 segundos para inicializar (ex: uma aplicação Java carregando um classpath grande), o liveness probe vai matá-la antes de terminar de iniciar — criando um loop infinito de reinício.

O startup probe **pausa** os liveness e readiness probes até ter sucesso. Uma vez que o startup probe passa, o Kubernetes muda para os liveness e readiness probes para verificação de saúde contínua.

**Analogia com Linux:** É como dizer ao `systemd` para esperar o `ExecStartPre` ter sucesso antes de iniciar o timer do watchdog. Você não quer que o watchdog mate um processo que ainda está inicializando.

</details>

## Recursos de Aprendizado

- [Logging Architecture — Kubernetes official docs](https://kubernetes.io/docs/concepts/cluster-administration/logging/)
- [kubectl logs reference](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_logs/)
- [Resource Metrics Pipeline (Metrics Server)](https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/)
- [Configure Liveness, Readiness and Startup Probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)
- [kube-prometheus-stack Helm chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Prometheus Operator — ServiceMonitor](https://prometheus-operator.dev/docs/developer/api-resources/servicemonitor/)
- [Grafana Documentation](https://grafana.com/docs/grafana/latest/)

## Break & Fix 🔧

Tente cada cenário, diagnostique o problema e corrija-o.

### Cenário 1 — Liveness probe com caminho errado → CrashLoopBackOff

Aplique este Deployment — o liveness probe aponta para um caminho que não existe:

```yaml
# Save as broken-liveness.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: broken-liveness
spec:
  replicas: 1
  selector:
    matchLabels:
      app: broken-liveness
  template:
    metadata:
      labels:
        app: broken-liveness
    spec:
      containers:
        - name: nginx
          image: nginx:stable
          ports:
            - containerPort: 80
          livenessProbe:
            httpGet:
              path: /healthzz
              port: 80
            initialDelaySeconds: 2
            periodSeconds: 3
            failureThreshold: 2
```

```bash
kubectl apply -f broken-liveness.yaml
```

**O que você verá:** Após ~10 segundos o Pod entra em um loop de reinício. Execute:

```bash
kubectl get pods -l app=broken-liveness --watch
```

A contagem de `RESTARTS` sobe rapidamente e o status alterna entre `Running` e `CrashLoopBackOff`.

**Diagnostique:**

```bash
kubectl describe pod -l app=broken-liveness | grep -A 10 "Events"
```

Procure por eventos como:

```
Unhealthy  Liveness probe failed: HTTP probe failed with statuscode: 404
Killing    Container nginx failed liveness probe, will be restarted
```

**Causa raiz:** O caminho do liveness probe `/healthzz` não existe. O Nginx retorna um 404, que não é um sucesso (2xx). Após 2 falhas (`failureThreshold: 2`) a cada 3 segundos (`periodSeconds: 3`), o Kubernetes mata o container.

**Correção:** Altere o caminho do probe para `/` (ou qualquer caminho que o nginx realmente sirva):

```bash
kubectl patch deployment broken-liveness --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/path","value":"/"}]'

kubectl rollout status deployment broken-liveness
kubectl get pods -l app=broken-liveness
```

O Pod agora deve estar `Running` com `1/1 READY` e zero reinícios.

**Analogia com Linux:** É como configurar o Nagios para verificar `http://localhost/healthzz` — se o endpoint não existe, o health check sempre falha e o Nagios marca o serviço como crítico.

**Limpeza:**

```bash
kubectl delete -f broken-liveness.yaml
```

---

### Cenário 2 — Readiness probe falhando → 0/1 READY, sem tráfego

Aplique este Deployment — o readiness probe verifica uma porta onde nada está ouvindo:

```yaml
# Save as broken-readiness.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: broken-readiness
spec:
  replicas: 2
  selector:
    matchLabels:
      app: broken-readiness
  template:
    metadata:
      labels:
        app: broken-readiness
    spec:
      containers:
        - name: nginx
          image: nginx:stable
          ports:
            - containerPort: 80
          readinessProbe:
            tcpSocket:
              port: 8081
            periodSeconds: 5
            failureThreshold: 1
---
apiVersion: v1
kind: Service
metadata:
  name: broken-readiness
spec:
  selector:
    app: broken-readiness
  ports:
    - port: 80
      targetPort: 80
```

```bash
kubectl apply -f broken-readiness.yaml
sleep 15
```

**O que você verá:** Ambos os Pods mostram `Running` mas `0/1 READY`:

```bash
kubectl get pods -l app=broken-readiness
```

```
NAME                                READY   STATUS    RESTARTS   AGE
broken-readiness-xxxx-aaaa          0/1     Running   0          20s
broken-readiness-xxxx-bbbb          0/1     Running   0          20s
```

**Diagnostique:**

```bash
# O Service tem zero endpoints — nenhum Pod está recebendo tráfego
kubectl get endpoints broken-readiness

# Os eventos mostram o readiness probe falhando
kubectl describe pod -l app=broken-readiness | grep -A 5 "Readiness"
```

Você verá: `Readiness probe failed: dial tcp ...:8081: connect: connection refused`

**Causa raiz:** O Nginx ouve na porta 80, mas o readiness probe verifica a porta 8081. A conexão TCP é recusada, então o probe falha. O Kubernetes remove o Pod dos endpoints do Service — ele está em execução mas **não está recebendo nenhum tráfego**.

**Correção:** Altere o readiness probe para a porta correta:

```bash
kubectl patch deployment broken-readiness --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/tcpSocket/port","value":80}]'

kubectl rollout status deployment broken-readiness
kubectl get pods -l app=broken-readiness
kubectl get endpoints broken-readiness
```

Agora ambos os Pods devem mostrar `1/1 READY` e os endpoints devem listar dois endereços IP.

**Analogia com Linux:** É como configurar um health check de load balancer contra a porta 8081 quando sua aplicação está na porta 80 — o LB marca todos os backends como down e o site fica offline, mesmo que todos os processos de backend estejam funcionando bem.

**Limpeza:**

```bash
kubectl delete -f broken-readiness.yaml
```

---

### Cenário 3 — Prometheus não consegue coletar métricas (ServiceMonitor com mismatch)

Neste cenário, você implanta uma aplicação que expõe métricas do Prometheus, cria um ServiceMonitor, mas o Prometheus nunca descobre o target.

**3a.** Implante uma aplicação simples que exporta métricas:

```yaml
# Save as metrics-app.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: metrics-app
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: metrics-app
  template:
    metadata:
      labels:
        app: metrics-app
    spec:
      containers:
        - name: exporter
          image: quay.io/prometheus/node-exporter:latest
          ports:
            - containerPort: 9100
              name: metrics
---
apiVersion: v1
kind: Service
metadata:
  name: metrics-app
  namespace: default
  labels:
    app: metrics-app
spec:
  selector:
    app: metrics-app
  ports:
    - port: 9100
      targetPort: 9100
      name: metrics
```

```bash
kubectl apply -f metrics-app.yaml
kubectl rollout status deployment metrics-app
```

**3b.** Crie um ServiceMonitor com um **label selector errado**:

```yaml
# Save as broken-servicemonitor.yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: metrics-app-monitor
  namespace: monitoring
spec:
  namespaceSelector:
    matchNames:
      - default
  selector:
    matchLabels:
      app: metrics-app-TYPO
  endpoints:
    - port: metrics
      interval: 15s
```

```bash
kubectl apply -f broken-servicemonitor.yaml
```

**O que você verá:** Na UI do Prometheus ([http://localhost:9090](http://localhost:9090) via port-forward), vá em **Status → Targets**. O target `metrics-app` **não** aparece. O Prometheus não tem ideia de que este Service existe.

**Diagnostique:**

```bash
# Verificar o selector do ServiceMonitor
kubectl -n monitoring get servicemonitor metrics-app-monitor -o yaml | grep -A 3 "selector"

# Comparar com os labels reais do Service
kubectl get svc metrics-app --show-labels
```

O ServiceMonitor procura por `app: metrics-app-TYPO` mas o Service tem `app: metrics-app`.

**Causa raiz:** O `selector.matchLabels` do ServiceMonitor não corresponde a nenhum label de Service. O Prometheus Operator usa este selector para descobrir quais Services coletar — sem correspondência, não há target de coleta.

**Correção:** Corrija o label no ServiceMonitor:

```bash
kubectl -n monitoring patch servicemonitor metrics-app-monitor --type=json \
  -p '[{"op":"replace","path":"/spec/selector/matchLabels/app","value":"metrics-app"}]'
```

Aguarde 30–60 segundos, depois verifique **Status → Targets** do Prometheus novamente. O target `metrics-app` deve agora aparecer e mostrar como `UP`.

**Analogia com Linux:** Isso é como configurar incorretamente uma definição de host no Nagios — se o hostname no seu `check_command` não corresponde a nenhum host real, o Nagios nunca faz polling e você pensa que está tudo bem porque não há alertas. A ausência de dados é em si um problema.

**Limpeza:**

```bash
kubectl delete -f broken-servicemonitor.yaml
kubectl delete -f metrics-app.yaml
```
