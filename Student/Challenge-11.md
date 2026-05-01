# Desafio 11 — Helm e Kustomize

[< Desafio Anterior](Challenge-10.md) | **[Início](../README.md)** | [Próximo Desafio >](Challenge-12.md)

## Introdução

Em um servidor Linux, raramente você compila cada software a partir do código-fonte. Em vez disso, você usa **gerenciadores de pacotes** — `apt`, `yum`, `dnf` — para instalar, atualizar e remover software com um único comando. O gerenciador de pacotes cuida das dependências, versionamento e rollback. Quando você precisa sobrescrever a configuração padrão, você coloca arquivos em diretórios como `/etc/default/` ou `/etc/nginx/conf.d/` — sobrepondo suas customizações às configurações padrão originais sem editar os arquivos originais.

O Kubernetes tem seus próprios equivalentes:

| Conceito Linux | Equivalente Kubernetes | O Que Faz |
|---|---|---|
| `apt` / `yum` / `dnf` (gerenciador de pacotes) | **Helm** | Empacota, instala, atualiza e faz rollback de aplicações Kubernetes completas |
| `/etc/apt/sources.list` (repositórios de pacotes) | `helm repo add` | Aponta o Helm para um repositório de charts |
| `/etc/default/nginx` (sobrescrita de configuração) | **Kustomize** overlays | Sobrepõe patches específicos de ambiente sobre os manifests base |

**Helm** é o gerenciador de pacotes do Kubernetes. Um **chart** do Helm agrupa todos os manifests YAML que uma aplicação Kubernetes precisa — Deployments, Services, ConfigMaps, Ingress — em um único pacote versionado e parametrizável. Você instala com um comando, customiza com values e faz rollback se algo der errado.

**Kustomize** adota uma abordagem diferente. Em vez de templates com placeholders, o Kustomize usa **overlays** — pequenos arquivos de patch que modificam um conjunto de manifests base. Ele é integrado ao `kubectl` (nenhuma ferramenta extra necessária) e segue um modelo puramente declarativo: você descreve o estado final desejado e o Kustomize faz o merge para você.

Neste desafio, você aprenderá ambas as ferramentas, entenderá quando usar cada uma e ganhará habilidades práticas para gerenciar aplicações Kubernetes como um sysadmin gerencia pacotes.

> **Requisito de cluster:** Todos os exercícios usam um cluster local [Kind](https://kind.sigs.k8s.io/) — nenhuma conta em nuvem necessária. Se você ainda não criou um, execute:
> ```bash
> kind create cluster --name fasthack
> ```

## Descrição

### Tarefa 1 — Instalar o Helm e Adicionar o Repositório Bitnami

Assim como o `apt` precisa do `/etc/apt/sources.list` para saber onde encontrar pacotes, o Helm precisa de **repositórios de charts** para saber onde encontrar charts.

Primeiro, verifique se o Helm está instalado:

```bash
helm version
```

Se o Helm não estiver instalado, instale-o:

```bash
# Linux / macOS (via script)
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Ou via gerenciador de pacotes
# macOS:  brew install helm
# Ubuntu: sudo snap install helm --classic
```

Agora adicione o repositório de charts Bitnami — uma das maiores coleções de Helm charts curados e prontos para produção:

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
```

Explore o que está disponível:

```bash
# Listar todos os charts no repositório Bitnami
helm search repo bitnami | head -20

# Buscar um chart específico
helm search repo bitnami/nginx
```

Isso é o equivalente a executar `apt update && apt search nginx` no Debian/Ubuntu.

### Tarefa 2 — Implantar um Chart com Valores Padrão

Instale o chart Bitnami NGINX com configurações padrão:

```bash
helm install my-nginx bitnami/nginx
```

Inspecione o que o Helm criou:

```bash
# Listar todas as releases
helm list

# Ver os recursos Kubernetes que o chart criou
kubectl get all -l app.kubernetes.io/instance=my-nginx

# Verificar o status da release
helm status my-nginx
```

Agora veja os **valores padrão** que o chart usa — isso é o equivalente a `apt show nginx` ou ler a configuração padrão:

```bash
helm show values bitnami/nginx | head -50
```

### Tarefa 3 — Customizar uma Release com `--set` e `values.yaml`

Os charts Helm são parametrizados via **values**. Você pode sobrescrever os padrões de duas formas:

**Método 1 — Inline com `--set`** (rápido, ad hoc):

```bash
helm upgrade my-nginx bitnami/nginx \
  --set replicaCount=3 \
  --set service.type=ClusterIP
```

**Método 2 — Com um arquivo `values.yaml`** (repetível, versionável):

Crie um arquivo chamado `my-nginx-values.yaml`:

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

Verifique se as alterações foram aplicadas:

```bash
kubectl get pods -l app.kubernetes.io/instance=my-nginx
kubectl get svc -l app.kubernetes.io/instance=my-nginx
```

> **Analogia com Linux:** `--set` é como passar flags `-o` para um comando; um `values.yaml` é como editar `/etc/default/nginx` — um arquivo de configuração persistente que sobrevive a atualizações.

### Tarefa 4 — Atualizar e Fazer Rollback de uma Release Helm

O Helm rastreia cada alteração como uma **revisão**. Isso é como ter snapshots do `apt` para os quais você pode reverter.

Verifique o histórico da release:

```bash
helm history my-nginx
```

Atualize para uma configuração diferente:

```bash
helm upgrade my-nginx bitnami/nginx \
  --set replicaCount=4 \
  --set service.type=ClusterIP
```

Verifique se uma nova revisão foi criada:

```bash
helm history my-nginx
```

Algo deu errado? **Faça rollback** para a revisão anterior:

```bash
# Fazer rollback para a revisão anterior
helm rollback my-nginx 1
```

Verifique o rollback:

```bash
helm history my-nginx
kubectl get pods -l app.kubernetes.io/instance=my-nginx
```

> **Analogia com Linux:** `helm rollback` é como `apt install nginx=1.18.0-0ubuntu1` — fixando em uma versão sabidamente boa. O Helm torna isso ainda mais fácil porque rastreia o estado completo, não apenas a versão do pacote.

### Tarefa 5 — Criar um Chart Helm do Zero

Agora crie seu próprio chart. Isso é como escrever seu próprio pacote `.deb` ou `.rpm`.

```bash
helm create myapp
```

Explore a estrutura gerada:

```
myapp/
├── Chart.yaml          # Metadados do chart (nome, versão, descrição)
├── values.yaml         # Valores de configuração padrão
├── charts/             # Dependências (sub-charts)
├── templates/          # Templates de manifests Kubernetes
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   ├── hpa.yaml
│   ├── serviceaccount.yaml
│   ├── _helpers.tpl    # Funções auxiliares de template
│   ├── NOTES.txt       # Mensagem pós-instalação
│   └── tests/
│       └── test-connection.yaml
└── .helmignore         # Arquivos a excluir do empacotamento
```

Edite `myapp/values.yaml` para customizar os padrões:

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

Valide e instale seu chart:

```bash
# Verificar erros no chart
helm lint myapp/

# Dry-run para ver o que seria criado (sem realmente aplicar)
helm install myapp-release myapp/ --dry-run

# Instalar de verdade
helm install myapp-release myapp/
```

Verifique se está em execução:

```bash
helm list
kubectl get all -l app.kubernetes.io/instance=myapp-release
```

Limpe a release do Helm quando terminar:

```bash
helm uninstall myapp-release
```

### Tarefa 6 — Introdução ao Kustomize: Base + Overlays

O Kustomize adota uma abordagem fundamentalmente diferente do Helm. Em vez de templates com placeholders `{{ .Values.x }}`, o Kustomize usa **YAML puro** com **patches** sobrepostos. Ele é integrado diretamente ao `kubectl` — nenhum binário extra necessário.

**Conceito:** Você define um conjunto **base** de manifests, depois cria **overlays** (dev, staging, prod) que modificam apenas o que precisa mudar.

Crie a seguinte estrutura de diretórios:

```
kustom-demo/
├── base/
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   └── service.yaml
└── overlays/
    ├── dev/
    │   └── kustomization.yaml
    └── prod/
        └── kustomization.yaml
```

**Passo 1 — Criar os manifests base:**

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

**Passo 2 — Criar o overlay de dev:**

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

**Passo 3 — Criar o overlay de prod:**

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

**Passo 4 — Visualizar e aplicar:**

Visualize o que cada overlay produz (sem aplicar):

```bash
# Visualizar o overlay de dev
kubectl kustomize kustom-demo/overlays/dev/

# Visualizar o overlay de prod
kubectl kustomize kustom-demo/overlays/prod/
```

Note como os manifests base são idênticos, mas os overlays alteram o prefixo do nome, labels e contagem de réplicas. Aplique ambos em namespaces diferentes:

```bash
# Criar namespaces
kubectl create namespace dev
kubectl create namespace prod

# Aplicar overlay de dev
kubectl apply -k kustom-demo/overlays/dev/ -n dev

# Aplicar overlay de prod
kubectl apply -k kustom-demo/overlays/prod/ -n prod
```

Verifique ambos os ambientes:

```bash
kubectl get all -n dev
kubectl get all -n prod
```

Você deve ver `dev-web-app` com 1 réplica no namespace `dev` e `prod-web-app` com 3 réplicas em `prod`.

> **Analogia com Linux:** A base é como a configuração padrão do pacote upstream (`/etc/nginx/nginx.conf`). Os overlays são como suas sobrescritas específicas do site em `/etc/nginx/conf.d/` — você nunca edita o original, você sobrepõe por cima.

### Tarefa 7 — Comparar Helm vs Kustomize: Quando Usar Qual

Agora que você usou ambas as ferramentas, vamos entender quando usar cada uma:

| Aspecto | Helm | Kustomize |
|---|---|---|
| **Abordagem** | Templating (`{{ .Values.x }}`) | Patching (overlay sobre YAML puro) |
| **Empacotamento** | Charts (arquivos versionados e distribuíveis) | Diretórios de arquivos YAML |
| **Distribuição** | Repositórios de charts (como repositórios `apt`) | Repositórios Git |
| **Gestão de ciclo de vida** | Install, upgrade, rollback, uninstall | Apenas apply (use Git para rollback) |
| **Dependências** | Suporte nativo a sub-charts | Manual (listar em `resources`) |
| **Curva de aprendizado** | Mais íngreme (templates Go, estrutura de chart) | Mais suave (YAML puro + patches) |
| **Melhor para** | Distribuir apps para outros; parametrização complexa | Apps internas; promoção entre ambientes (dev→prod) |
| **Integrado ao kubectl** | Não (binário separado) | Sim (`kubectl apply -k`) |

**Regra geral:**

- **Use Helm** quando estiver consumindo aplicações de terceiros (bancos de dados, stacks de monitoramento, ingress controllers) ou empacotando sua própria aplicação para distribuição a múltiplos times/clusters.
- **Use Kustomize** quando você é dono dos manifests, quer mantê-los como YAML puro e precisa promover a mesma aplicação entre ambientes (dev → staging → prod).
- **Você pode usar ambos juntos** — instale um chart Helm, depois sobreponha patches Kustomize sobre a saída renderizada.

### Limpeza

```bash
# Remover releases do Helm
helm uninstall my-nginx 2>/dev/null

# Remover recursos do Kustomize
kubectl delete -k kustom-demo/overlays/dev/ -n dev 2>/dev/null
kubectl delete -k kustom-demo/overlays/prod/ -n prod 2>/dev/null
kubectl delete namespace dev prod 2>/dev/null

# Remover arquivos locais (opcional)
rm -rf myapp/ kustom-demo/ my-nginx-values.yaml
```

## Critérios de Sucesso

- [ ] O Helm está instalado e `helm version` retorna uma versão v3.x.
- [ ] Você adicionou o repositório Bitnami e consegue executar `helm search repo bitnami/nginx` com sucesso.
- [ ] Você implantou `bitnami/nginx` com `helm install` e verificou que os Pods e o Service estão em execução.
- [ ] Você customizou a release usando tanto flags `--set` quanto um arquivo `values.yaml`.
- [ ] Você realizou um `helm upgrade` seguido de um `helm rollback` e verificou que o histórico da release mostra múltiplas revisões.
- [ ] Você criou um chart Helm do zero com `helm create`, fez lint e instalou com sucesso.
- [ ] Você criou uma base Kustomize com um Deployment e Service.
- [ ] Você criou overlays de dev e prod que alteram o prefixo do nome, labels e contagem de réplicas.
- [ ] `kubectl kustomize` mostra a saída renderizada correta para cada overlay.
- [ ] Você implantou ambos os overlays em namespaces separados e verificou as diferenças (contagem de réplicas, prefixo do nome, labels).
- [ ] Você consegue explicar quando usar Helm vs Kustomize e dar um exemplo concreto de cada.

## Referência Linux ↔ Kubernetes

| Conceito Linux | Equivalente Kubernetes | Notas |
|---|---|---|
| `apt install nginx` | `helm install my-nginx bitnami/nginx` | Instalar uma aplicação empacotada com um comando |
| `apt upgrade nginx` | `helm upgrade my-nginx bitnami/nginx` | Atualizar para uma nova versão ou novos valores de configuração |
| `apt remove nginx` | `helm uninstall my-nginx` | Remover todos os recursos associados a uma release |
| `/etc/apt/sources.list` | `helm repo add` | Registrar um repositório de pacotes/charts |
| `dpkg -l` / `rpm -qa` | `helm list` | Listar todos os pacotes/releases instalados |
| `apt show nginx` | `helm show values bitnami/nginx` | Ver metadados do pacote e configuração padrão |
| `/etc/default/nginx` (sobrescrita de config) | Kustomize overlays | Sobrepor alterações específicas de ambiente sobre os padrões |
| `apt-cache policy nginx` (fixação de versão) | `helm rollback my-nginx 1` | Reverter para uma revisão de release sabidamente boa |
| `dpkg -L nginx` (listar arquivos do pacote) | `helm get manifest my-nginx` | Mostrar todos os manifests Kubernetes instalados por uma release |

## Dicas

<details>
<summary>Dica 1: Helm install trava — chart está aguardando um LoadBalancer</summary>

Muitos charts Bitnami usam `service.type=LoadBalancer` como padrão. No Kind, não há load balancer cloud, então o Service ficará no estado `Pending` para sempre.

**Correção:** Sobrescreva o tipo de service durante a instalação:

```bash
helm install my-nginx bitnami/nginx --set service.type=ClusterIP
```

Or if you already installed it:

```bash
helm upgrade my-nginx bitnami/nginx --set service.type=ClusterIP
```

Este é um problema comum ao executar charts Helm projetados para ambientes cloud em um cluster local.

</details>

<details>
<summary>Dica 2: helm repo update — sempre execute antes de install/upgrade</summary>

O Helm armazena o índice de charts localmente em cache. Se você adicionou o repositório dias atrás, o cache pode estar desatualizado. Sempre execute:

```bash
helm repo update
```

Este é o equivalente do Helm ao `apt update` — ele atualiza a lista de versões de charts disponíveis antes de você instalar ou atualizar.

</details>

<details>
<summary>Dica 3: Depurando Kustomize — visualize antes de aplicar</summary>

Nunca aplique um overlay Kustomize às cegas. Sempre visualize a saída renderizada primeiro:

```bash
# Apenas visualizar — não aplica nada
kubectl kustomize kustom-demo/overlays/dev/
```

Isso imprime o YAML completamente mesclado no stdout. Passe por pipe para `less` ou redirecione para um arquivo para inspecionar com cuidado:

```bash
kubectl kustomize kustom-demo/overlays/dev/ | less
```

Se você vir um erro como `accumulating resources`, geralmente significa que um caminho na lista `resources` do `kustomization.yaml` está errado. Verifique novamente os caminhos relativos — eles são relativos ao diretório que contém o arquivo `kustomization.yaml`.

</details>

<details>
<summary>Dica 4: Helm dry-run — teste antes de implantar</summary>

Antes de instalar ou atualizar um chart Helm, renderize os templates localmente para ver exatamente quais manifests Kubernetes serão criados:

```bash
# Ver o que seria instalado (sem aplicar)
helm install my-release bitnami/nginx --dry-run

# Ou para um upgrade
helm upgrade my-nginx bitnami/nginx --dry-run -f my-nginx-values.yaml
```

Isso é o equivalente a `apt install --simulate` — mostra o que aconteceria sem realmente fazer. Se você vir erros de renderização de template, corrija seus values antes de implantar.

</details>

<details>
<summary>Dica 5: Entendendo os números de revisão do Helm</summary>

Cada `helm install`, `helm upgrade` e `helm rollback` cria uma nova **revisão**. Visualize-as com:

```bash
helm history my-nginx
```

Você verá uma saída como:

```
REVISION  UPDATED                   STATUS      CHART         APP VERSION  DESCRIPTION
1         2025-01-15 10:00:00       superseded  nginx-18.3.1  1.27.3       Install complete
2         2025-01-15 10:05:00       superseded  nginx-18.3.1  1.27.3       Upgrade complete
3         2025-01-15 10:10:00       deployed    nginx-18.3.1  1.27.3       Rollback to 1
```

Note que um rollback cria uma **nova** revisão (3) que restaura o estado de uma revisão antiga (1). Os números de revisão sempre aumentam — eles nunca são reutilizados.

</details>

## Recursos de Aprendizado

- [Helm — Getting Started Guide](https://helm.sh/docs/intro/quickstart/)
- [Helm — Using Helm (install, upgrade, rollback)](https://helm.sh/docs/intro/using_helm/)
- [Helm — Creating Your First Chart](https://helm.sh/docs/chart_template_guide/getting_started/)
- [Helm — Values Files](https://helm.sh/docs/chart_template_guide/values_files/)
- [Helm — Chart Best Practices](https://helm.sh/docs/chart_best_practices/)
- [Kustomize — Declarative Management of Kubernetes Objects](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/)
- [Kustomize — Official Documentation](https://kubectl.docs.kubernetes.io/references/kustomize/)
- [Kubernetes — Managing Kubernetes Objects Using Kustomize](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/)

## Break & Fix 🔧

Try each scenario, diagnose the problem, and fix it.

### Scenario 1 — Helm install fails: chart not found

Run this command:

```bash
helm install my-redis fakerepo/redis
```

**What you'll see:**

```
Error: INSTALLATION FAILED: repo fakerepo not found
```

**Diagnose:** Helm doesn't know about a repository called `fakerepo`. Check what repos are configured:

```bash
helm repo list
```

**Root cause:** You must add a chart repository before you can install charts from it. This is exactly like trying to `apt install` a package when its PPA hasn't been added to `sources.list`.

**Fix:**

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm install my-redis bitnami/redis --set architecture=standalone --set auth.enabled=false
```

Verify it's running:

```bash
helm list
kubectl get pods -l app.kubernetes.io/instance=my-redis
```

**Clean up:**

```bash
helm uninstall my-redis
```

---

### Scenario 2 — Kustomize overlay references a missing resource

Create the following broken overlay. First, set up the base:

```bash
mkdir -p kustom-broken/base kustom-broken/overlays/dev
```

Create `kustom-broken/base/deployment.yaml`:

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
```

Create `kustom-broken/base/kustomization.yaml`:

```yaml
resources:
  - deployment.yaml
```

Now create a broken dev overlay that references a resource not in the base. Create `kustom-broken/overlays/dev/kustomization.yaml`:

```yaml
resources:
  - ../../base
  - extra-configmap.yaml
```

Try to build it:

```bash
kubectl kustomize kustom-broken/overlays/dev/
```

**What you'll see:**

```
Error: accumulating resources: accumulating resources from 'extra-configmap.yaml': ...
```

**Root cause:** The overlay's `kustomization.yaml` references `extra-configmap.yaml`, but that file doesn't exist. Unlike Helm (which fails at template render time), Kustomize fails at resource accumulation time.

**Fix:** Either create the missing file, or remove the reference from `kustomization.yaml`:

Option A — Remove the reference:

```yaml
resources:
  - ../../base
```

Option B — Create the missing resource. Create `kustom-broken/overlays/dev/extra-configmap.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  LOG_LEVEL: debug
```

Then rebuild:

```bash
kubectl kustomize kustom-broken/overlays/dev/
```

**Clean up:**

```bash
rm -rf kustom-broken/
```

---

### Scenario 3 — Helm values.yaml has wrong indentation: template rendering error

Create a broken values file called `broken-values.yaml`:

```yaml
replicaCount: 2
service:
  type: ClusterIP
port: 8080
```

Notice the bug: `port` is at the **root level** instead of nested under `service`. Now try to upgrade:

```bash
helm upgrade my-nginx bitnami/nginx -f broken-values.yaml --dry-run
```

**What you'll see:** Depending on the chart, you may get a template rendering error, or worse — the chart may render successfully but produce unexpected results because `service.port` was never overridden (the `port: 8080` at root level was simply ignored, and the Service still uses the default port).

**Diagnose:**

```bash
# Render the templates and check the Service definition
helm template my-nginx bitnami/nginx -f broken-values.yaml | grep -A 10 "kind: Service"
```

**Root cause:** YAML is indentation-sensitive. `port: 8080` at the root level is a completely different key from `service.port: 8080`. Helm doesn't warn about unused values in your file — they are silently ignored.

**Fix:** Correct the indentation in `broken-values.yaml`:

```yaml
replicaCount: 2
service:
  type: ClusterIP
  port: 8080
```

Verify the fix:

```bash
helm template my-nginx bitnami/nginx -f broken-values.yaml | grep -A 10 "kind: Service"
```

> **Lesson learned:** Always use `helm template` or `helm install --dry-run` to preview rendered manifests before applying. Silent misconfiguration from bad YAML indentation is one of the most common Helm mistakes — like a typo in `/etc/default/nginx` that the service silently ignores.

**Clean up:**

```bash
rm -f broken-values.yaml
```
