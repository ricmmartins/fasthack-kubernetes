# Solução 11 — Helm e Kustomize

[< Voltar ao Desafio](../Student/Challenge-11.md) | **[Home](README.md)**

---

## Tarefa 1: Instalar o Helm e Adicionar o Repositório Bitnami

### Passo a passo

```bash
# Verify Helm is installed
helm version
```

Saída esperada (a versão pode variar):

```
version.BuildInfo{Version:"v3.17.x", ...}
```

Se o Helm não estiver instalado:

```bash
# Linux / macOS
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Or: brew install helm       (macOS)
# Or: sudo snap install helm --classic  (Ubuntu)
```

Adicione o repositório Bitnami e atualize:

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
```

Saída esperada:

```
"bitnami" has been added to your repositories
Hang tight while we grab the latest from your chart repositories...
...Successfully got an update from the "bitnami" chart repository
Update Complete. ⎈Happy Helming!⎈
```

Explore os charts disponíveis:

```bash
helm search repo bitnami | head -20
helm search repo bitnami/nginx
```

### Verificação

```bash
helm repo list
```

Esperado:

```
NAME    URL
bitnami https://charts.bitnami.com/bitnami
```

> **Dica para o Coach:** Se os alunos já tiverem o Helm e o repositório Bitnami, podem pular direto para a Tarefa 2. O comando `helm repo update` é o equivalente ao `apt update` — sempre execute antes de instalar.

---

## Tarefa 2: Implantar um Chart com Valores Padrão

### Passo a passo

```bash
helm install my-nginx bitnami/nginx
```

> **⚠️ Pegadinha do Kind:** O chart Bitnami do nginx usa `service.type=LoadBalancer` por padrão. No Kind não existe load balancer de nuvem, então o Service ficará em estado `Pending` para sempre. A instalação ainda será bem-sucedida, mas o Service não receberá um IP externo.

Verifique o que foi criado:

```bash
helm list
helm status my-nginx
kubectl get all -l app.kubernetes.io/instance=my-nginx
```

A saída esperada mostra um Deployment, ReplicaSet, Pod(s) e um Service. O `EXTERNAL-IP` do Service mostrará `<pending>` no Kind — isso é esperado.

Visualize os valores padrão:

```bash
helm show values bitnami/nginx | head -50
```

### Verificação

```bash
# Os Pods devem estar Running
kubectl get pods -l app.kubernetes.io/instance=my-nginx
```

Esperado:

```
NAME                        READY   STATUS    RESTARTS   AGE
my-nginx-xxxxxxxxx-xxxxx    1/1     Running   0          60s
```

Para realmente acessar o serviço nginx no Kind, use port-forward:

```bash
kubectl port-forward svc/my-nginx 8080:80
# In another terminal:
curl http://localhost:8080
```

> **Dica para o Coach:** Se a instalação travar, provavelmente os alunos encontraram o problema do LoadBalancer. Diga para pressionarem Ctrl+C e adicionarem `--set service.type=ClusterIP` ou usarem `--wait=false`.

---

## Tarefa 3: Personalizar um Release com `--set` e `values.yaml`

### Passo a passo

**Método 1 — Inline `--set`:**

```bash
helm upgrade my-nginx bitnami/nginx \
  --set replicaCount=3 \
  --set service.type=ClusterIP
```

Saída esperada:

```
Release "my-nginx" has been upgraded. Happy Helming!
```

**Método 2 — Arquivo de valores:**

Crie o arquivo `my-nginx-values.yaml`:

```yaml
replicaCount: 2
service:
  type: ClusterIP
  port: 8080
```

Aplique-o:

```bash
helm upgrade my-nginx bitnami/nginx -f my-nginx-values.yaml
```

### Verificação

```bash
kubectl get pods -l app.kubernetes.io/instance=my-nginx
```

Esperado: 2 pods em execução (correspondendo a `replicaCount: 2`).

```bash
kubectl get svc -l app.kubernetes.io/instance=my-nginx
```

Esperado: O tipo do Service é `ClusterIP` e a porta é `8080`.

> **Dica para o Coach:** Explique que `--set` é para mudanças rápidas e pontuais (como flags de linha de comando), enquanto `values.yaml` é a abordagem versionável e repetível (como editar `/etc/default/nginx`).

---

## Tarefa 4: Upgrade e Rollback de um Release Helm

### Passo a passo

Verifique o histórico atual do release:

```bash
helm history my-nginx
```

A saída esperada mostra as revisões 1, 2, 3 (das Tarefas 2 e 3).

Execute outro upgrade:

```bash
helm upgrade my-nginx bitnami/nginx \
  --set replicaCount=4 \
  --set service.type=ClusterIP
```

Verifique a nova revisão:

```bash
helm history my-nginx
```

Esperado: Uma nova revisão aparece com status `deployed`.

Agora faça o rollback:

```bash
helm rollback my-nginx 1
```

Saída esperada:

```
Rollback was a success! Happy Helming!
```

### Verificação

```bash
helm history my-nginx
```

Esperado: Uma nova revisão é criada (o rollback cria uma revisão futura, não reversa). A descrição diz "Rollback to 1".

```bash
kubectl get pods -l app.kubernetes.io/instance=my-nginx
```

Esperado: A quantidade de Pods corresponde à configuração original da revisão 1.

> **Dica para o Coach:** Enfatize que `helm rollback` cria uma **nova** revisão — os números de revisão sempre aumentam. Isso é diferente do `git revert`, que cria um novo commit.

---

## Tarefa 5: Criar um Chart Helm do Zero

### Passo a passo

```bash
helm create myapp
```

Estrutura de diretórios esperada:

```
myapp/
├── Chart.yaml
├── values.yaml
├── charts/
├── templates/
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   ├── hpa.yaml
│   ├── serviceaccount.yaml
│   ├── _helpers.tpl
│   ├── NOTES.txt
│   └── tests/
│       └── test-connection.yaml
└── .helmignore
```

Edite `myapp/values.yaml` para personalizar os valores padrão:

```yaml
replicaCount: 2

image:
  repository: nginx
  pullPolicy: IfNotPresent
  tag: "stable"

service:
  type: ClusterIP
  port: 80

resources:
  requests:
    cpu: 100m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 128Mi
```

Lint, dry-run e instalação:

```bash
# Lint the chart
helm lint myapp/

# Dry-run to preview generated manifests
helm install myapp-release myapp/ --dry-run

# Install for real
helm install myapp-release myapp/
```

### Verificação

```bash
helm list
```

Esperado:

```
NAME            NAMESPACE  REVISION  STATUS    CHART        APP VERSION
my-nginx        default    X         deployed  nginx-X.X.X  X.X.X
myapp-release   default    1         deployed  myapp-0.1.0  1.16.0
```

```bash
kubectl get all -l app.kubernetes.io/instance=myapp-release
```

Esperado: 2 pods em execução (de `replicaCount: 2`), um Service, um Deployment e um ReplicaSet.

Limpeza:

```bash
helm uninstall myapp-release
```

> **Dica para o Coach:** Guie os alunos pelo arquivo `templates/deployment.yaml` e mostre como `{{ .Values.replicaCount }}` mapeia para `values.yaml`. Este é o insight principal — templates Helm são templates Go que são renderizados em YAML do Kubernetes.

---

## Tarefa 6: Kustomize Base + Overlays

### Passo a passo

Crie a estrutura de diretórios:

```bash
mkdir -p kustom-demo/base kustom-demo/overlays/dev kustom-demo/overlays/prod
```

Crie `kustom-demo/base/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web-app
  template:
    metadata:
      labels:
        app: web-app
    spec:
      containers:
        - name: nginx
          image: nginx:stable
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
```

Crie `kustom-demo/base/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-app
spec:
  selector:
    app: web-app
  ports:
    - port: 80
      targetPort: 80
```

Crie `kustom-demo/base/kustomization.yaml`:

```yaml
resources:
  - deployment.yaml
  - service.yaml
```

Crie `kustom-demo/overlays/dev/kustomization.yaml`:

```yaml
resources:
  - ../../base

namePrefix: dev-

labels:
  - pairs:
      env: dev

replicas:
  - name: web-app
    count: 1
```

Crie `kustom-demo/overlays/prod/kustomization.yaml`:

```yaml
resources:
  - ../../base

namePrefix: prod-

labels:
  - pairs:
      env: prod

replicas:
  - name: web-app
    count: 3
```

Visualize a saída renderizada:

```bash
kubectl kustomize kustom-demo/overlays/dev/
kubectl kustomize kustom-demo/overlays/prod/
```

Esperado: A saída de dev mostra `dev-web-app` com 1 réplica e label `env: dev`. A saída de prod mostra `prod-web-app` com 3 réplicas e label `env: prod`.

Implante ambos os overlays:

```bash
kubectl create namespace dev
kubectl create namespace prod

kubectl apply -k kustom-demo/overlays/dev/ -n dev
kubectl apply -k kustom-demo/overlays/prod/ -n prod
```

### Verificação

```bash
kubectl get all -n dev
```

Esperado: deployment `dev-web-app` com 1 réplica.

```bash
kubectl get all -n prod
```

Esperado: deployment `prod-web-app` com 3 réplicas.

```bash
# Verifique as labels
kubectl get pods -n dev --show-labels
kubectl get pods -n prod --show-labels
```

Esperado: Os pods de dev têm `env=dev`, os pods de prod têm `env=prod`.

Limpeza:

```bash
kubectl delete -k kustom-demo/overlays/dev/ -n dev
kubectl delete -k kustom-demo/overlays/prod/ -n prod
kubectl delete namespace dev prod
```

> **Dica para o Coach:** O insight principal é que o Kustomize nunca modifica os arquivos base. A base é o "padrão upstream" e os overlays são suas "sobreposições locais." É a analogia com `/etc/default/nginx`.

---

## Tarefa 7: Comparação Helm vs Kustomize

Esta é uma tarefa de discussão/conceitual. Garanta que os alunos consigam articular:

| Aspecto | Helm | Kustomize |
|---|---|---|
| **Abordagem** | Templating (`{{ .Values.x }}`) | Patching (overlays sobre YAML puro) |
| **Empacotamento** | Charts (arquivos versionados e distribuíveis) | Diretórios de arquivos YAML |
| **Distribuição** | Repositórios de charts (como repositórios `apt`) | Repositórios Git |
| **Ciclo de vida** | Install, upgrade, rollback, uninstall | Apenas apply (use Git para rollback) |
| **Dependências** | Suporte nativo a sub-charts | Manual (listar em `resources`) |
| **Curva de aprendizado** | Mais íngreme (templates Go, estrutura de charts) | Mais suave (YAML puro + patches) |
| **Melhor para** | Apps de terceiros; parametrização complexa | Apps internas; promoção entre ambientes |
| **Integrado ao kubectl** | Não (binário separado) | Sim (`kubectl apply -k`) |

**Regra geral:**
- **Helm** → consumir apps de terceiros (bancos de dados, stacks de monitoramento) ou distribuir seu próprio app para outros
- **Kustomize** → você é dono dos manifests, quer YAML puro e precisa de promoção dev→staging→prod
- **Ambos juntos** → instale um chart Helm, depois aplique patches do Kustomize sobre a saída renderizada

---

## Limpeza Final

```bash
helm uninstall my-nginx 2>/dev/null
kubectl delete -k kustom-demo/overlays/dev/ -n dev 2>/dev/null
kubectl delete -k kustom-demo/overlays/prod/ -n prod 2>/dev/null
kubectl delete namespace dev prod 2>/dev/null
rm -rf myapp/ kustom-demo/ my-nginx-values.yaml
```

---

## Problemas Comuns

| Problema | Causa | Correção |
|---------|-------|-----|
| `helm install` trava indefinidamente | O chart usa `LoadBalancer` por padrão; Kind não tem provedor de LB | Adicione `--set service.type=ClusterIP` ou use `--wait=false` |
| `helm search repo` não retorna nada | O cache do repositório está desatualizado | Execute `helm repo update` primeiro |
| `kubectl kustomize` diz "accumulating resources" | Caminho relativo errado em `kustomization.yaml` | Os caminhos são relativos ao arquivo `kustomization.yaml` — verifique se `../../base` está correto |
| Pods presos em `Pending` após instalação do chart | Recursos insuficientes no nó do Kind | Verifique os eventos com `kubectl describe pod`; reduza os requests de recursos nos values |
| Chart criado com `helm create` falha no lint | Variáveis de template remanescentes referenciando valores indefinidos | Edite `values.yaml` para corresponder ao que os templates esperam |
| Overlay do Kustomize não altera réplicas | O campo `replicas` usa o `metadata.name` do Deployment, não o nome do overlay | Garanta que o nome no bloco `replicas` corresponda ao nome do Deployment **base** (antes de qualquer prefixo) |
