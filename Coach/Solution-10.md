# Solução 10 — Autoscaling

[< Voltar para o Desafio](../Student/Challenge-10.md) | **[Home](README.md)**

## Notas para os Coaches

O principal bloqueio neste desafio é o Metrics Server no Kind. Se `kubectl top` mostrar erros, não deixe os alunos travados — guie-os pelo patch `--kubelet-insecure-tls` imediatamente. A demo real do HPA é simples uma vez que as métricas estejam fluindo.

O teste de carga leva 1–2 minutos para scale-up e ~5 minutos para scale-down (janela de estabilização). Reduza a janela de estabilização para 60s na Tarefa 6 se o tempo estiver curto.

Tempo estimado: **45 minutos**

---

## Tarefa 1: Instalar Metrics Server no Kind

### Passo a passo

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

O Kind usa certificados kubelet auto-assinados, então o Metrics Server falhará na verificação TLS por padrão. Aplique o patch para pular a verificação TLS:

```bash
kubectl patch -n kube-system deployment metrics-server \
  --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

Aguarde o rollout completar:

```bash
kubectl -n kube-system rollout status deployment metrics-server --timeout=120s
```

### Verificação

Aguarde 30–60 segundos após o rollout completar para a primeira coleta de métricas, então:

```bash
kubectl top nodes
```

Saída esperada (valores irão variar):

```
NAME                     CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
fasthack-control-plane   150m         7%     800Mi           20%
```

```bash
kubectl top pods -A
```

Esperado: uma tabela mostrando uso de CPU e memória para pods do sistema (coredns, etcd, etc.). Se você vir `error: metrics not available yet`, aguarde mais 30 segundos e tente novamente.

> **Dica do Coach:** Se os pods do Metrics Server estão em crash-loop, verifique os logs:
> ```bash
> kubectl -n kube-system logs -l k8s-app=metrics-server --tail=20
> ```
> O erro mais comum é `x509: cannot validate certificate` — o que significa que o patch `--kubelet-insecure-tls` não foi aplicado ou o rollout não completou.

---

## Tarefa 2: Deploy de Aplicação CPU-Intensiva

### Passo a passo

Salve `php-apache.yaml`:

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

```bash
kubectl apply -f php-apache.yaml
kubectl rollout status deployment php-apache --timeout=120s
```

### Verificação

```bash
kubectl get deployment php-apache
```

Esperado:

```
NAME         READY   UP-TO-DATE   AVAILABLE   AGE
php-apache   1/1     1            1           ...
```

```bash
kubectl get svc php-apache
```

Esperado: um Service ClusterIP na porta 80.

> **Dica do Coach:** O `resources.requests.cpu: 200m` é **crítico** — sem ele, o HPA não consegue calcular uma porcentagem de utilização e mostrará `<unknown>`. Esta é a causa #1 de problemas "meu HPA não funciona".

---

## Tarefa 3: Criar HPA com Alvo de 50% de CPU

### Passo a passo

```bash
kubectl autoscale deployment php-apache \
  --cpu-percent=50 \
  --min=1 \
  --max=10
```

### Verificação

```bash
kubectl get hpa php-apache
```

Saída esperada:

```
NAME         REFERENCE               TARGETS   MINPODS   MAXPODS   REPLICAS   AGE
php-apache   Deployment/php-apache   0%/50%    1         10        1          30s
```

Se você vir `<unknown>/50%`, o Metrics Server não está em execução ou o Pod não tem requests de CPU. Aguarde 60 segundos e verifique novamente — pode levar um intervalo de coleta para as métricas aparecerem.

```bash
kubectl describe hpa php-apache
```

Esperado: em Conditions, `ScalingActive` deve mostrar `True` com razão `ValidMetricFound`.

> **Dica do Coach:** O comando imperativo `kubectl autoscale` cria um recurso HPA `autoscaling/v2`. Os alunos criarão o equivalente YAML declarativo na Tarefa 6.

---

## Tarefa 4: Gerar Carga e Observar Scale-Up

### Passo a passo

Inicie o gerador de carga:

```bash
kubectl run load-generator \
  --image=busybox:stable \
  --restart=Never \
  -- /bin/sh -c "while true; do wget -q -O- http://php-apache; done"
```

Observe o HPA em um terminal separado (ou use `--watch`):

```bash
kubectl get hpa php-apache --watch
```

### Verificação

Em 1–2 minutos você deve ver:

1. **Alvo de CPU sobe** acima de 50% (ex: `250%/50%`)
2. **Contagem de réplicas aumenta** (ex: de 1 → 4 → 7 → 10)

Progressão de exemplo:

```
NAME         REFERENCE               TARGETS    MINPODS   MAXPODS   REPLICAS   AGE
php-apache   Deployment/php-apache   0%/50%     1         10        1          2m
php-apache   Deployment/php-apache   250%/50%   1         10        1          3m
php-apache   Deployment/php-apache   250%/50%   1         10        5          3m30s
php-apache   Deployment/php-apache   48%/50%    1         10        7          4m
```

Observe também os Pods sendo criados:

```bash
kubectl get pods -l app=php-apache
```

Esperado: múltiplos pods em estado `Running`.

> **Dica do Coach:** Se a carga não está elevando CPU o suficiente, execute múltiplos geradores de carga:
> ```bash
> for i in 1 2 3; do
>   kubectl run load-generator-$i \
>     --image=busybox:stable \
>     --restart=Never \
>     -- /bin/sh -c "while true; do wget -q -O- http://php-apache; done"
> done
> ```

---

## Tarefa 5: Parar Carga e Observar Scale-Down

### Passo a passo

```bash
kubectl delete pod load-generator
# Se você iniciou múltiplos:
# kubectl delete pod load-generator-1 load-generator-2 load-generator-3
```

Continue observando o HPA:

```bash
kubectl get hpa php-apache --watch
```

### Verificação

1. O alvo de CPU cai para `0%/50%` em 1–2 minutos.
2. A contagem de réplicas permanece elevada por aproximadamente **5 minutos** (a janela de estabilização padrão).
3. Após a janela de estabilização, as réplicas gradualmente fazem scale-down de volta para `1`.

Progressão de exemplo:

```
NAME         REFERENCE               TARGETS   MINPODS   MAXPODS   REPLICAS   AGE
php-apache   Deployment/php-apache   0%/50%    1         10        7          10m
...aguarde ~5 minutos...
php-apache   Deployment/php-apache   0%/50%    1         10        1          16m
```

> **Dica do Coach:** Se os alunos estão impacientes, explique a janela de estabilização e pule para a Tarefa 6 onde eles reduzirão para 60 segundos. O cooldown padrão de 5 minutos existe para prevenir oscilações em produção.

---

## Tarefa 6: HPA Declarativo com `autoscaling/v2`

### Passo a passo

Primeiro, delete o HPA imperativo:

```bash
kubectl delete hpa php-apache
```

Salve `php-apache-hpa.yaml`:

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

```bash
kubectl apply -f php-apache-hpa.yaml
```

### Verificação

```bash
kubectl get hpa php-apache
```

Esperado: mesmo que Tarefa 3, mas agora o HPA foi criado a partir de um manifesto YAML.

```bash
kubectl get hpa php-apache -o yaml | grep -A3 behavior
```

Esperado:

```yaml
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 60
```

> **Dica do Coach:** Percorra as principais diferenças entre as abordagens imperativa e declarativa:
>
> | Característica | `kubectl autoscale` | YAML `autoscaling/v2` |
> |----------------|--------------------|-----------------------|
> | Versão da API | Cria `autoscaling/v2` | Declara explicitamente `autoscaling/v2` |
> | Comportamento personalizado | Não configurável | Controle total sobre políticas de scale-up/down |
> | Múltiplas métricas | Apenas CPU | CPU, memória, métricas customizadas, externas |
> | Compatível com GitOps | Não | Sim — armazenado no controle de versão |

---

## Tarefa 7: Conceito VPA (Apenas Discussão)

> Sem comandos práticos — este é um tópico de discussão.

### Pontos-Chave para os Coaches

Pergunte ao aluno: "Quando o escalonamento horizontal NÃO funcionaria?"

Respostas esperadas:
- **Singletons stateful** — um banco de dados que não pode ser sharded
- **Jobs em lote** — um único processo que precisa de mais CPU/RAM
- **Dimensionamento desconhecido** — novas aplicações onde você não sabe os requests de recursos corretos

Modos do VPA:

| Modo | Comportamento | Analogia |
|------|--------------|----------|
| `Off` | Recomenda mas não altera | `htop` — você vê os dados, você decide |
| `Initial` | Define recursos na criação do Pod | `ulimit` em `/etc/profile.d/` — aplica no login |
| `Auto` | Despeja e recria Pods com novos recursos | Resize de VM ao vivo com reboot |

> **Dica do Coach:** VPA e HPA NÃO devem ambos ter como alvo a CPU no mesmo Deployment — eles entrarão em conflito. Você pode usar VPA para memória e HPA para CPU na mesma carga de trabalho.

---

## Tarefa 8: Conceito KEDA (Apenas Discussão)

> Sem comandos práticos — este é um tópico de discussão.

### Pontos-Chave para os Coaches

Pergunte ao aluno: "E se você quiser escalar baseado em algo diferente de CPU ou memória?"

Exemplos:
- **Profundidade da fila de mensagens** — escalar workers quando mensagens RabbitMQ/Kafka acumulam
- **Agendamento cron** — escalar para 5 réplicas durante horário comercial, 0 à noite
- **Taxa de requisições HTTP** — escalar baseado em requisições por segundo do Prometheus
- **Conexões de banco de dados** — escalar baseado na contagem de conexões ativas

Percorra o ScaledObject cron do KEDA do desafio:

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

Principais funcionalidades do KEDA vs HPA:
- **Escalar para zero** — o mínimo do HPA é 1; KEDA pode escalar para 0
- **60+ tipos de triggers** — Prometheus, Kafka, RabbitMQ, Azure Queue, cron, HTTP, etc.
- **ScaledJobs** — criar Kubernetes Jobs sob demanda (não apenas escalar Deployments)

> **Dica do Coach:** KEDA na verdade cria e gerencia objetos HPA por baixo dos panos. É uma extensão do HPA, não um substituto.

---

## Problemas Comuns

| Problema | Causa | Correção |
|----------|-------|----------|
| `kubectl top` retorna "metrics not available yet" | Metrics Server não completou a primeira coleta | Aguarde 60 segundos após o rollout completar e tente novamente |
| Metrics Server em crash-loop com erro `x509` | Certificados kubelet auto-assinados do Kind | Aplique o patch `--kubelet-insecure-tls` e aguarde o rollout |
| HPA mostra `<unknown>/50%` | Faltando `resources.requests.cpu` no Pod | Adicione `resources.requests.cpu: 200m` na spec do container |
| HPA não escala sob carga | Gerador de carga acessando nome de Service errado | Verifique que `kubectl get svc php-apache` existe e o gerador usa `http://php-apache` |
| Scale-down leva 5+ minutos | Janela de estabilização padrão é 300s | Comportamento esperado; use `behavior.scaleDown.stabilizationWindowSeconds: 60` para labs |
| Pod do gerador de carga em `CrashLoopBackOff` | Usou `--restart=Never` mas o loop de wget não tem tratamento de erro | Delete e recrie; verifique `kubectl logs load-generator` para erros de DNS |
| HPA atinge máximo em `maxReplicas` mas CPU ainda está alta | Precisa de mais margem ou a app é CPU-bound | Aumente `maxReplicas` ou aumente `resources.requests.cpu` para que cada réplica processe mais |

---

## Limpeza

```bash
kubectl delete -f php-apache.yaml 2>/dev/null
kubectl delete -f php-apache-hpa.yaml 2>/dev/null
kubectl delete hpa php-apache 2>/dev/null
kubectl delete pod load-generator 2>/dev/null
kubectl delete pod load-generator-1 load-generator-2 load-generator-3 2>/dev/null
rm -f php-apache.yaml php-apache-hpa.yaml
```
