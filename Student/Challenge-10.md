# Desafio 10 — Autoscaling

[< Desafio Anterior](Challenge-09.md) | **[Início](../README.md)** | [Próximo Desafio >](Challenge-11.md)

## Introdução

Em um servidor Linux, você observa a carga do sistema com `top` ou `htop` e reage conforme necessário. Se a CPU dispara, você pode criar processos worker adicionais, redimensionar a máquina, ou ter um cron job que escala as coisas durante o horário comercial. Todos estes são formas de **autoscaling** — ajustar a capacidade para atender a demanda.

O Kubernetes automatiza os mesmos padrões:

| Estratégia | Equivalente Linux | Equivalente Kubernetes |
|---|---|---|
| Adicionar mais processos worker | `fork()` / criar mais instâncias | **HPA** — Horizontal Pod Autoscaler |
| Dar mais CPU/RAM a um processo | Redimensionar a VM ou aumentar `ulimit` | **VPA** — Vertical Pod Autoscaler |
| Escalar baseado em sinal externo (profundidade de fila, cron) | Cron job + script que inicia workers | **KEDA** — Event-Driven Autoscaler |

Neste desafio você vai instalar o **Metrics Server** no seu cluster Kind (o equivalente a tornar `/proc/stat` e `/proc/meminfo` disponíveis para o cluster), criar um HPA que automaticamente ajusta o número de réplicas de Pod baseado na utilização de CPU, gerar carga sintética para vê-lo escalar, e depois observar o cool-down quando a carga para. Você também vai aprender os conceitos por trás do VPA e KEDA para entender quando usar cada ferramenta.

> **Requisito do cluster:** Todos os exercícios usam um cluster local [Kind](https://kind.sigs.k8s.io/) — nenhuma conta cloud é necessária. Se você ainda não criou um, execute:
> ```bash
> kind create cluster --name fasthack
> ```

## Descrição

### Tarefa 1 — Instalar Metrics Server no Kind

O controlador HPA precisa de métricas de CPU e memória em tempo real para tomar decisões de escalonamento. Em uma máquina Linux esses dados vêm de `/proc/stat`; no Kubernetes eles vêm da API do **Metrics Server**.

Instale o Metrics Server e aplique um patch para que funcione no Kind (que usa certificados kubelet auto-assinados):

```bash
# Instalar Metrics Server
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Patch para aceitar certificados kubelet auto-assinados do Kind
kubectl patch -n kube-system deployment metrics-server \
  --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

Aguarde o Pod do Metrics Server ficar `Running`, depois verifique se está coletando dados:

```bash
kubectl -n kube-system rollout status deployment metrics-server
kubectl top nodes
kubectl top pods -A
```

Você deve ver valores de CPU e memória — não erros. Se `kubectl top` ainda falhar, dê mais 30–60 segundos para o Metrics Server coletar seu primeiro scrape.

### Tarefa 2 — Implantar uma aplicação intensiva em CPU

Crie um Deployment com um request de CPU explícito (o HPA precisa disso para calcular percentuais de utilização). Salve isso como `php-apache.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: php-apache
spec:
  replicas: 1
  selector:
    matchLabels:
      app: php-apache
  template:
    metadata:
      labels:
        app: php-apache
    spec:
      containers:
        - name: php-apache
          image: registry.k8s.io/hpa-example
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 200m
            limits:
              cpu: 500m
---
apiVersion: v1
kind: Service
metadata:
  name: php-apache
spec:
  selector:
    app: php-apache
  ports:
    - port: 80
      targetPort: 80
```

Aplique:

```bash
kubectl apply -f php-apache.yaml
kubectl rollout status deployment php-apache
```

### Tarefa 3 — Criar um HPA com alvo de 50% de CPU

Crie um Horizontal Pod Autoscaler que mantém a utilização média de CPU em 50%, escalando entre 1 e 10 réplicas:

```bash
kubectl autoscale deployment php-apache \
  --cpu-percent=50 \
  --min=1 \
  --max=10
```

Verifique se o HPA foi criado e está lendo métricas (não `<unknown>`):

```bash
kubectl get hpa php-apache
```

Você deve ver algo como:

```
NAME         REFERENCE               TARGETS   MINPODS   MAXPODS   REPLICAS   AGE
php-apache   Deployment/php-apache   0%/50%    1         10        1          30s
```

> **Se você vir `<unknown>/50%`:** O Metrics Server não está executando ou o Pod não tem o campo `resources.requests.cpu`. Veja o Cenário 1 do Quebra & Conserta abaixo.

### Tarefa 4 — Gerar carga e observar o scale-up

Abra um **segundo terminal** e inicie um gerador de carga — um Pod BusyBox que bombardeia o Service em um loop apertado:

```bash
kubectl run load-generator \
  --image=busybox:stable \
  --restart=Never \
  -- /bin/sh -c "while true; do wget -q -O- http://php-apache; done"
```

No seu primeiro terminal, observe o HPA reagir:

```bash
kubectl get hpa php-apache --watch
```

Em 1–2 minutos você deve ver o alvo de CPU subir acima de 50% e a contagem de réplicas aumentar. Observe também os Pods:

```bash
kubectl get pods -l app=php-apache --watch
```

### Tarefa 5 — Parar a carga e observar o scale-down

Delete o gerador de carga:

```bash
kubectl delete pod load-generator
```

Continue observando o HPA. Após a **janela de estabilização** (padrão de 5 minutos para scale-down), o HPA vai gradualmente reduzir a contagem de réplicas de volta para 1.

```bash
kubectl get hpa php-apache --watch
```

> **Por que o scale-down demora tanto?** O HPA tem uma janela padrão `--horizontal-pod-autoscaler-downscale-stabilization` de 5 minutos. Isso previne flapping — a mesma razão pela qual você adicionaria histerese a um alerta de monitoramento em um servidor Linux.

### Tarefa 6 — Explorar o manifesto HPA (YAML)

Exporte o HPA que você criou imperativamente e estude sua estrutura:

```bash
kubectl get hpa php-apache -o yaml
```

Agora crie o HPA equivalente de forma declarativa. Salve isso como `php-apache-hpa.yaml`:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: php-apache
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: php-apache
  minReplicas: 1
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 60
```

Aplique:

```bash
kubectl apply -f php-apache-hpa.yaml
```

Note o `behavior.scaleDown.stabilizationWindowSeconds` — definido para 60 segundos aqui para feedback mais rápido em um ambiente de laboratório. Em produção você manteria o padrão (300s) ou ajustaria baseado no padrão de tráfego da sua carga de trabalho.

### Tarefa 7 — Introdução ao VPA (Vertical Pod Autoscaler)

O HPA adiciona ou remove Pods (escalonamento horizontal). O **Vertical Pod Autoscaler (VPA)** ajusta `requests` e `limits` em Pods existentes — como redimensionar uma VM ou mudar valores de `ulimit` para um processo em execução.

**Quando usar VPA em vez de HPA:**

- Sua carga de trabalho não pode ser escalada horizontalmente (ex: um banco de dados singleton stateful).
- Você não sabe os requests de recurso corretos para uma nova aplicação e quer que o VPA recomende valores.
- Você quer dimensionar corretamente os Pods para que não estejam super ou sub-provisionados.

> **Nota:** O VPA não é instalado por padrão e é um projeto separado. Você **não** precisa instalá-lo para este desafio — entender o conceito é suficiente. VPA e HPA geralmente **não** devem ter como alvo a mesma métrica (CPU) no mesmo Deployment, pois podem conflitar.

Leia o README do VPA para entender seus três modos:

| Modo VPA | Comportamento |
|---|---|
| `Off` | Apenas recomenda — não altera Pods |
| `Initial` | Define requests/limits apenas no momento de criação do Pod |
| `Auto` | Despeja e recria Pods com requests/limits atualizados |

### Tarefa 8 — Introdução ao KEDA (Event-Driven Autoscaling)

**KEDA** (Kubernetes Event-Driven Autoscaling) estende o HPA para escalar baseado em sinais além de CPU e memória — como profundidade de fila de mensagens, taxa de requisições HTTP, agendamentos cron, ou métricas Prometheus.

**Analogia Linux:** Imagine um cron job que verifica uma fila RabbitMQ a cada minuto e cria workers quando mensagens se acumulam. O KEDA faz a mesma coisa, mas como um controlador nativo do Kubernetes.

KEDA usa recursos **ScaledObject** que definem:

- **O que** escalar (um Deployment ou Job)
- **Qual trigger** observar (Prometheus, cron, Kafka, etc.)
- **Quando** escalar para zero (scale-to-zero é um recurso chave do KEDA)

Exemplo — um ScaledObject baseado em cron (cloud-agnostic):

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: cron-scaler
spec:
  scaleTargetRef:
    name: php-apache
  minReplicaCount: 0
  maxReplicaCount: 10
  triggers:
    - type: cron
      metadata:
        timezone: America/New_York
        start: "0 8 * * *"
        end: "0 18 * * *"
        desiredReplicas: "5"
```

Isso escala `php-apache` para 5 réplicas durante o horário comercial e volta para 0 fora dele — como um cron job mais inteligente.

> **Nota:** Você **não** precisa instalar o KEDA para este desafio. Entender o conceito e saber quando usá-lo é suficiente.

### Limpeza

```bash
kubectl delete -f php-apache.yaml
kubectl delete hpa php-apache 2>/dev/null
kubectl delete -f php-apache-hpa.yaml 2>/dev/null
kubectl delete pod load-generator 2>/dev/null
```

## Critérios de Sucesso

- [ ] O Metrics Server está executando no seu cluster Kind e `kubectl top nodes` retorna dados de CPU/memória.
- [ ] Você implantou a aplicação `php-apache` com `requests` de CPU explícitos.
- [ ] Você criou um HPA com alvo de 50% de utilização de CPU com min=1 e max=10 réplicas.
- [ ] `kubectl get hpa` mostra o percentual real de CPU (não `<unknown>`).
- [ ] Você gerou carga e observou o HPA escalar o Deployment acima de 1 réplica.
- [ ] Após parar a carga, você observou o HPA escalar o Deployment de volta para baixo.
- [ ] Você consegue explicar a diferença entre o manifesto YAML `autoscaling/v2` e o comando imperativo `kubectl autoscale`.
- [ ] Você consegue explicar quando usaria VPA em vez de HPA.
- [ ] Você consegue explicar o que o KEDA faz e dar um exemplo de trigger event-driven.

## Referência Linux ↔ Kubernetes

| Conceito Linux | Equivalente Kubernetes | Notas |
|---|---|---|
| `top` / `htop` | `kubectl top pods` | Uso de CPU e memória em tempo real por Pod |
| `/proc/stat` (contadores de CPU) | API do Metrics Server | A fonte de dados que o controlador HPA lê |
| `ulimit` (limites por processo) | `resources.requests` / `resources.limits` | Limites de CPU e memória no nível do Pod |
| Criar workers baseado em carga | HPA (Horizontal Pod Autoscaler) | Adiciona/remove réplicas de Pod automaticamente |
| Redimensionar VM / adicionar RAM | VPA (Vertical Pod Autoscaler) | Ajusta requests/limits em Pods existentes |
| Cron + script para escalar workers | KEDA (event-driven autoscaling) | Escala baseado em profundidade de fila, Prometheus, cron, etc. |
| `monit` / `supervisord` | Controlador HPA (kube-controller-manager) | O loop de controle que observa métricas e ajusta réplicas |
| Load average → criar workers | Threshold `averageUtilization` | Métrica alvo do HPA que aciona o escalonamento |

## Dicas

<details>
<summary>Dica 1: Metrics Server leva um minuto para aquecer</summary>

Após instalar o Metrics Server e aplicar o patch `--kubelet-insecure-tls`, o Deployment fará rollout de um novo Pod. Aguarde:

```bash
kubectl -n kube-system rollout status deployment metrics-server
```

Depois dê 30–60 segundos antes de executar `kubectl top`. O primeiro scrape precisa de tempo para coletar dados de todos os kubelets.

Se `kubectl top nodes` retornar `error: metrics not available yet`, apenas aguarde e tente novamente.

</details>

<details>
<summary>Dica 2: Por que o HPA mostra &lt;unknown&gt;?</summary>

O HPA calcula a utilização como: `(uso atual de CPU) / (CPU solicitada)`.

Se os Pods alvo **não têm `resources.requests.cpu`** definido, o HPA não pode calcular um percentual e mostra `<unknown>`.

**Correção:** Adicione um campo `resources.requests.cpu` a todo container no template de Pod do Deployment. Para este laboratório, `200m` (200 millicores) é um bom valor inicial.

Verifique também se o Metrics Server está saudável:

```bash
kubectl -n kube-system get pods -l k8s-app=metrics-server
kubectl top pods
```

</details>

<details>
<summary>Dica 3: O gerador de carga não está elevando a CPU o suficiente</summary>

Certifique-se de que o gerador de carga está acessando o **nome do Service**, não um IP de Pod:

```bash
kubectl run load-generator \
  --image=busybox:stable \
  --restart=Never \
  -- /bin/sh -c "while true; do wget -q -O- http://php-apache; done"
```

Se o Service `php-apache` não existir, as requisições wget falharão silenciosamente. Verifique:

```bash
kubectl get svc php-apache
```

Você também pode executar múltiplos geradores de carga em paralelo para resultados mais rápidos:

```bash
for i in 1 2 3; do
  kubectl run load-generator-$i \
    --image=busybox:stable \
    --restart=Never \
    -- /bin/sh -c "while true; do wget -q -O- http://php-apache; done"
done
```

</details>

<details>
<summary>Dica 4: O scale-down é lento — isso é normal?</summary>

Sim. A janela de estabilização padrão do HPA para scale-down é de **5 minutos** (`--horizontal-pod-autoscaler-downscale-stabilization=5m0s`). Isso previne que a contagem de réplicas fique oscilando se a carga flutuar.

Você pode acelerar isso em um laboratório definindo `behavior.scaleDown.stabilizationWindowSeconds` na spec do HPA:

```yaml
behavior:
  scaleDown:
    stabilizationWindowSeconds: 30
```

Em produção, mantenha o padrão ou aumente — scale-down prematuro pode causar indisponibilidade durante tráfego em rajadas.

</details>

<details>
<summary>Dica 5: Visualizando eventos e decisões do HPA</summary>

O controlador HPA registra suas decisões de escalonamento como eventos Kubernetes. Visualize-os com:

```bash
kubectl describe hpa php-apache
```

Observe as seções **Conditions** e **Events**. Você verá entradas como:

```
AbleToScale     True    ReadyForNewScale   recommended size matches current size
ScalingActive   True    ValidMetricFound   the HPA was able to successfully calculate a replica count
ScalingLimited  False   DesiredWithinRange  the desired count is within the acceptable range
```

Este é o equivalente Kubernetes de ler logs do sistema (`journalctl`) para entender por que o `monit` reiniciou um serviço.

</details>

## Recursos de Aprendizado

- [Horizontal Pod Autoscaling — Kubernetes official docs](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)
- [HPA Walkthrough](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale-walkthrough/)
- [Metrics Server](https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/#metrics-server)
- [Resource Management for Pods and Containers](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)
- [autoscaling/v2 API Reference](https://kubernetes.io/docs/reference/kubernetes-api/workload-resources/horizontal-pod-autoscaler-v2/)
- [Vertical Pod Autoscaler — Kubernetes docs](https://kubernetes.io/docs/concepts/workloads/autoscaling/#scaling-workloads-vertically)
- [KEDA — Kubernetes Event-Driven Autoscaling](https://keda.sh/docs/latest/concepts/)

## Quebra & Conserta 🔧

Tente cada cenário, diagnostique o problema e corrija.

### Cenário 1 — HPA mostra `<unknown>/50%` para CPU

Aplique este Deployment e HPA — o HPA não vai funcionar:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: broken-hpa-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: broken-hpa-app
  template:
    metadata:
      labels:
        app: broken-hpa-app
    spec:
      containers:
        - name: nginx
          image: nginx:stable
          ports:
            - containerPort: 80
          # BUG: nenhum resources.requests definido!
```

```bash
kubectl apply -f broken-hpa-app.yaml
kubectl autoscale deployment broken-hpa-app --cpu-percent=50 --min=1 --max=5
kubectl get hpa broken-hpa-app
```

**O que você verá:** `TARGETS` mostra `<unknown>/50%` mesmo com o Metrics Server executando.

**Diagnostique:** `kubectl describe hpa broken-hpa-app` — procure o evento: `FailedGetResourceMetric ... missing request for cpu`.

**Causa raiz:** O HPA calcula utilização como `atual / solicitado`. Sem `requests.cpu`, não há nada para dividir.

**Correção:** Adicione `resources.requests.cpu: 200m` à spec do container, re-aplique e verifique:

```bash
kubectl get hpa broken-hpa-app --watch
```

**Limpeza:**

```bash
kubectl delete deployment broken-hpa-app
kubectl delete hpa broken-hpa-app
```

---

### Cenário 2 — HPA não escala sob carga

Aplique o Deployment e HPA corretos de `php-apache` das Tarefas 2–3, depois inicie este gerador de carga:

```bash
kubectl run bad-load \
  --image=busybox:stable \
  --restart=Never \
  -- /bin/sh -c "while true; do wget -q -O- http://wrong-service-name; done"
```

**O que você verá:** O HPA permanece em 1 réplica — a CPU nunca sobe.

**Diagnostique:**

```bash
# Verificar logs do gerador de carga — wget está falhando
kubectl logs bad-load

# Verificar HPA — CPU permanece perto de 0%
kubectl get hpa php-apache
```

**Causa raiz:** O gerador de carga está acessando `wrong-service-name`, que não existe. As requisições nunca chegam ao `php-apache`, então sua CPU permanece ociosa.

**Correção:** Delete o gerador de carga quebrado e crie um apontando para o Service correto:

```bash
kubectl delete pod bad-load
kubectl run good-load \
  --image=busybox:stable \
  --restart=Never \
  -- /bin/sh -c "while true; do wget -q -O- http://php-apache; done"
```

**Analogia Linux:** É como executar um teste de carga contra `localhost:9999` quando sua aplicação está na porta `8080` — seu monitoramento mostra zero carga porque nada está realmente acessando o servidor.

**Limpeza:**

```bash
kubectl delete pod good-load
```

---

### Cenário 3 — Pods escalaram mas não voltam

Execute o teste de carga completo das Tarefas 4–5. Uma vez que o HPA escalou para várias réplicas, delete o gerador de carga e verifique as réplicas imediatamente:

```bash
kubectl delete pod load-generator
kubectl get hpa php-apache
```

**O que você verá:** Mesmo com a CPU caindo para 0%, a contagem de réplicas permanece elevada por vários minutos.

**Diagnostique:**

```bash
kubectl describe hpa php-apache
```

Procure a condição:

```
ScalingLimited  True  TooFewReplicas  the desired replica count is less than the minimum replica count
```

Ou mais provavelmente:

```
AbleToScale  True  ReadyForNewScale  recommended size matches current size
```

O HPA está **esperando a janela de estabilização** antes de escalar para baixo.

**Causa raiz:** O `stabilizationWindowSeconds` padrão para scale-down é 300 segundos (5 minutos). Isso é por design — previne flapping se a carga voltar rapidamente.

**Correção (apenas para laboratório — não para produção):** Aplique patch no HPA para usar uma janela de estabilização mais curta:

```bash
kubectl patch hpa php-apache --type=merge -p '{
  "spec": {
    "behavior": {
      "scaleDown": {
        "stabilizationWindowSeconds": 30
      }
    }
  }
}'
```

Após ~30 segundos de CPU baixa, as réplicas vão escalar para baixo.

**Analogia Linux:** Isso é histerese — como definir um cooldown de 5 minutos em um alerta de monitoramento para que não te avise a cada pico breve. O mesmo princípio se aplica ao contrário: não desaloque workers no instante em que a carga cai, caso ela volte rapidamente.
