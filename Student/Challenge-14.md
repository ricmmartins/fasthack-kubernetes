# Desafio 14 — Deploy na Nuvem

[< Desafio Anterior](Challenge-13.md) | **[Início](../README.md)** | [Próximo Desafio >](Challenge-15.md)

## Introdução

🎓 **Parabéns — você chegou ao desafio de formatura!**

Você começou este hackathon executando containers como processos Linux, construiu clusters locais com Kind, fez deploy de aplicações multi-camadas, configurou rede, protegeu workloads com RBAC e NetworkPolicies, configurou monitoramento com Prometheus e Grafana, e depurou falhas do mundo real. Tudo até agora foi executado na sua máquina local.

Agora é hora de pegar o que você construiu e fazer deploy na nuvem real.

Em um servidor Linux, o salto de "funciona na minha máquina" para "funciona em produção" significa provisionar VMs, configurar load balancers, instalar agentes de monitoramento e gerenciar drivers de armazenamento. Serviços gerenciados de Kubernetes cuidam de tudo isso para você — você traz os mesmos manifests YAML que escreveu ao longo de todo o curso, e o provedor de nuvem cuida do control plane, provisionamento de nodes e integrações.

Neste desafio, você escolherá um dos três principais provedores de nuvem — **Azure (AKS)**, **AWS (EKS)** ou **Google Cloud (GKE)** — criará um cluster gerenciado, fará deploy da sua aplicação multi-camadas do Desafio 05 e a exporá para a internet com um LoadBalancer real.

> ⚠️ **Este desafio é OPCIONAL.** Todos os 13 desafios anteriores funcionam inteiramente no Kind sem necessidade de conta na nuvem. Se você não tem uma conta na nuvem ou prefere não incorrer em custos, você já completou o hackathon principal. Volte a este desafio quando estiver pronto!

> 💰 **Consciência de custos:** Cada provedor de nuvem oferece opções gratuitas ou de baixo custo para aprendizado (veja as notas de preço abaixo). No entanto, **recursos na nuvem custam dinheiro quando deixados em execução**. Siga as instruções de limpeza no final cuidadosamente.

## Descrição

### Tarefa 0 — Pré-requisitos

Antes de começar, certifique-se de ter:

- Uma conta ativa no provedor de nuvem escolhido (Azure, AWS ou Google Cloud)
- A ferramenta CLI do provedor instalada e autenticada:

  | Provedor | Ferramenta CLI | Guia de Instalação |
  |----------|----------|---------------|
  | Azure | `az` | [Instalar Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) |
  | AWS | `aws` + `eksctl` | [Instalar AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) + [Instalar eksctl](https://eksctl.io/installation/) |
  | Google Cloud | `gcloud` | [Instalar gcloud CLI](https://cloud.google.com/sdk/docs/install) |

- `kubectl` instalado (você já tem dos desafios anteriores)

Verifique se sua CLI está autenticada:

```bash
# Azure
az login
az account show

# AWS
aws sts get-caller-identity

# Google Cloud
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
```

### Tarefa 1 — Criar um Cluster Kubernetes Gerenciado

Crie um cluster pequeno adequado para aprendizado. Use a contagem mínima de nodes e os menores tamanhos de instância para manter os custos baixos.

<details>
<summary><strong>Azure (AKS)</strong></summary>

```bash
# Create a resource group
az group create --name fasthack-rg --location eastus

# Create the AKS cluster (Free tier — no control plane charge)
az aks create \
  --resource-group fasthack-rg \
  --name fasthack-aks \
  --node-count 2 \
  --node-vm-size Standard_B2s \
  --generate-ssh-keys
```

> 💰 **AKS Free tier:** O control plane é gratuito. Você paga apenas pelas VMs dos worker nodes. `Standard_B2s` é um dos tamanhos de VM mais baratos disponíveis.

</details>

<details>
<summary><strong>AWS (EKS)</strong></summary>

```bash
# Create the EKS cluster with eksctl
eksctl create cluster \
  --name fasthack-eks \
  --region us-east-1 \
  --nodegroup-name fasthack-nodes \
  --node-type t3.small \
  --nodes 2
```

> 💰 **Preços EKS:** O control plane custa $0.10/hora (~$73/mês). Use instâncias `t3.small` para minimizar custos dos nodes. Delete o cluster prontamente após completar o desafio.

</details>

<details>
<summary><strong>Google Cloud (GKE)</strong></summary>

```bash
# Create the GKE cluster (zonal — eligible for free tier)
gcloud container clusters create fasthack-gke \
  --zone us-central1-a \
  --num-nodes 2 \
  --machine-type e2-small \
  --release-channel regular
```

> 💰 **GKE Free tier:** Um cluster zonal ou Autopilot por conta de faturamento recebe $74.40/mês em créditos gratuitos, o que cobre a taxa de gerenciamento do cluster. Você ainda paga pelo compute dos nodes.

</details>

A criação do cluster leva 5–15 minutos dependendo do provedor. Aguarde a conclusão antes de prosseguir.

### Tarefa 2 — Conectar kubectl ao Seu Cluster na Nuvem

Configure seu `kubectl` local para se comunicar com o novo cluster na nuvem.

<details>
<summary><strong>Azure (AKS)</strong></summary>

```bash
az aks get-credentials --resource-group fasthack-rg --name fasthack-aks
```

</details>

<details>
<summary><strong>AWS (EKS)</strong></summary>

```bash
aws eks update-kubeconfig --name fasthack-eks --region us-east-1
```

</details>

<details>
<summary><strong>Google Cloud (GKE)</strong></summary>

```bash
gcloud container clusters get-credentials fasthack-gke --zone us-central1-a
```

</details>

Verifique a conexão:

```bash
# Confirme que você está conectado ao cluster na nuvem (não ao seu Kind local)
kubectl config current-context

# Verifique os nodes — você deve ver VMs na nuvem, não containers Kind
kubectl get nodes -o wide
```

### Tarefa 3 — Deploy da Aplicação Multi-Camadas do Desafio 05

Pegue a aplicação frontend + backend que você construiu no Desafio 05 e faça deploy no seu cluster na nuvem. Use os mesmos manifests YAML — eles funcionam de forma idêntica em qualquer cluster Kubernetes.

Crie um arquivo chamado `cloud-app.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  labels:
    app: backend
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
            - "-text=Hello from the cloud! ☁️"
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
  labels:
    app: frontend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      containers:
        - name: nginx
          image: nginx:stable
          ports:
            - containerPort: 80
          volumeMounts:
            - name: config
              mountPath: /etc/nginx/conf.d/default.conf
              subPath: default.conf
      volumes:
        - name: config
          configMap:
            name: frontend-config
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: frontend-config
data:
  default.conf: |
    server {
        listen 80;
        location / {
            proxy_pass http://backend-svc:5678;
        }
    }
```

```bash
kubectl apply -f cloud-app.yaml

# Aguarde todos os Pods estarem rodando
kubectl get pods --watch
```

### Tarefa 4 — Expor a Aplicação com um Cloud LoadBalancer

No Kind, você usou `NodePort` para acessar services. Na nuvem, você pode usar um Service `LoadBalancer`, que provisiona automaticamente um load balancer real na nuvem com um IP público.

Crie um arquivo chamado `frontend-lb.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: frontend-lb
spec:
  type: LoadBalancer
  selector:
    app: frontend
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
```

```bash
kubectl apply -f frontend-lb.yaml

# Aguarde o IP externo ser atribuído (pode levar 1-3 minutos)
kubectl get svc frontend-lb --watch
```

Quando a coluna `EXTERNAL-IP` mostrar um endereço IP real (não `<pending>`), teste:

```bash
# Substitua pelo seu IP externo real
curl http://<EXTERNAL-IP>
```

Você deve ver: `Hello from the cloud! ☁️`

🎉 **Sua aplicação está agora ao vivo na internet, rodando em Kubernetes gerenciado!**

### Tarefa 5 — Explorar Armazenamento Cloud-Native (CSI Drivers)

Cada provedor de nuvem tem um driver CSI (Container Storage Interface) que permite ao Kubernetes provisionar discos na nuvem dinamicamente. Verifique quais StorageClasses estão disponíveis no seu cluster:

```bash
# Liste as StorageClasses disponíveis
kubectl get storageclass
```

Crie um PersistentVolumeClaim para testar o provisionamento dinâmico:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: cloud-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
```

```bash
kubectl apply -f cloud-pvc.yaml

# Verifique o status do PVC — deve ficar "Bound"
kubectl get pvc cloud-pvc
```

Compare o driver CSI em uso:

| Provedor | Driver CSI | StorageClass Padrão | Backend |
|----------|-----------|---------------------|---------|
| AKS | `disk.csi.azure.com` | `managed-csi` | Azure Managed Disk |
| EKS | `ebs.csi.aws.com` | `gp2` | EBS Volume |
| GKE | `pd.csi.storage.gke.io` | `standard-rwo` | Persistent Disk |

### Tarefa 6 — Configurar Monitoramento Básico

Habilite a solução de monitoramento cloud-native para o seu cluster. Cada provedor tem uma opção integrada que requer configuração mínima.

<details>
<summary><strong>Azure (AKS) — Azure Monitor Container Insights</strong></summary>

```bash
az aks enable-addons \
  --resource-group fasthack-rg \
  --name fasthack-aks \
  --addons monitoring
```

After a few minutes, go to the Azure Portal → your AKS cluster → **Insights** to see container metrics, logs, and node health.

</details>

<details>
<summary><strong>AWS (EKS) — CloudWatch Container Insights</strong></summary>

Instale o add-on CloudWatch Observability:

```bash
aws eks create-addon \
  --cluster-name fasthack-eks \
  --addon-name amazon-cloudwatch-observability
```

After installation, verify the agent pods are running:

```bash
kubectl get pods -n amazon-cloudwatch
```

Veja as métricas no AWS Console → CloudWatch → Container Insights.

</details>

<details>
<summary><strong>Google Cloud (GKE) — Cloud Monitoring</strong></summary>

Clusters GKE têm o Cloud Monitoring habilitado por padrão. Nenhum passo extra necessário!

Verifique indo ao Google Cloud Console → Kubernetes Engine → seu cluster → aba **Observability**.

Para verificar se as métricas estão fluindo:

```bash
# Confirme que os pods de monitoramento estão rodando no kube-system
kubectl get pods -n kube-system -l k8s-app=gke-metrics-agent
```

</details>

### Tarefa 7 — Limpar Recursos na Nuvem ⚠️

> 🔴 **IMPORTANTE: Faça este passo AGORA. Não deixe recursos na nuvem em execução — eles incorrerão em custos!**

<details>
<summary><strong>Azure (AKS) — Deletar tudo</strong></summary>

```bash
# Delete the resource group (this removes the cluster, VMs, disks, load balancer, and all associated resources)
az group delete --name fasthack-rg --yes --no-wait
```

Verifique a exclusão no Azure Portal ou com:

```bash
az group show --name fasthack-rg 2>/dev/null || echo "Resource group deleted successfully"
```

</details>

<details>
<summary><strong>AWS (EKS) — Deletar tudo</strong></summary>

```bash
# Delete os recursos Kubernetes primeiro (libera o cloud load balancer)
kubectl delete svc frontend-lb
kubectl delete pvc cloud-pvc

# Delete o cluster EKS e todos os recursos associados
eksctl delete cluster --name fasthack-eks --region us-east-1
```

Verifique no AWS Console que nenhuma instância EC2, volume EBS ou Elastic Load Balancer permanece.

</details>

<details>
<summary><strong>Google Cloud (GKE) — Deletar tudo</strong></summary>

```bash
# Delete the GKE cluster
gcloud container clusters delete fasthack-gke --zone us-central1-a --quiet
```

Verifique no Google Cloud Console que nenhuma instância Compute Engine ou Load Balancer permanece.

</details>

Após a limpeza, mude o contexto do kubectl de volta para o seu cluster Kind local:

```bash
kubectl config use-context kind-fasthack
```

## Critérios de Sucesso

- [ ] Você criou um cluster Kubernetes gerenciado no provedor de nuvem escolhido (AKS, EKS ou GKE).
- [ ] `kubectl get nodes` mostra nodes de VMs na nuvem (não containers Kind).
- [ ] Os Deployments backend e frontend estão rodando com todos os Pods em estado `Ready`.
- [ ] Um Service `LoadBalancer` recebeu um endereço IP externo real.
- [ ] Você pode fazer `curl` no IP externo e receber uma resposta do backend através do frontend.
- [ ] Um PersistentVolumeClaim provisionou dinamicamente um disco na nuvem e está em estado `Bound`.
- [ ] O monitoramento na nuvem está habilitado e você pode ver métricas básicas no console do provedor.
- [ ] **Todos os recursos na nuvem foram deletados** e o contexto do kubectl está de volta ao seu cluster Kind local.

## Referência de Provedores de Nuvem

| Operação | AKS (Azure) | EKS (AWS) | GKE (Google Cloud) |
|-----------|-------------|-----------|---------------------|
| **Ferramenta CLI** | `az` | `aws` + `eksctl` | `gcloud` |
| **Criar cluster** | `az aks create` | `eksctl create cluster` | `gcloud container clusters create` |
| **Obter credenciais** | `az aks get-credentials` | `aws eks update-kubeconfig` | `gcloud container clusters get-credentials` |
| **Driver de armazenamento CSI** | `disk.csi.azure.com` | `ebs.csi.aws.com` | `pd.csi.storage.gke.io` |
| **Monitoramento** | Azure Monitor + Container Insights | CloudWatch Container Insights | Cloud Monitoring (habilitado por padrão) |
| **Custo do control plane** | Gratuito (Free tier) | $0.10/hora (~$73/mês) | Gratuito ($74.40/mês crédito para 1 cluster zonal) |
| **Deletar cluster** | `az group delete` | `eksctl delete cluster` | `gcloud container clusters delete` |

## Dicas

<details>
<summary>Dica 1: Azure (AKS) — Passo a passo completo</summary>

```bash
# 1. Login
az login

# 2. Create resource group
az group create --name fasthack-rg --location eastus

# 3. Create AKS cluster (Free tier, 2 small nodes)
az aks create \
  --resource-group fasthack-rg \
  --name fasthack-aks \
  --node-count 2 \
  --node-vm-size Standard_B2s \
  --generate-ssh-keys

# 4. Get credentials
az aks get-credentials --resource-group fasthack-rg --name fasthack-aks

# 5. Verify
kubectl get nodes

# 6. Deploy the app
kubectl apply -f cloud-app.yaml
kubectl apply -f frontend-lb.yaml

# 7. Wait for external IP
kubectl get svc frontend-lb --watch

# 8. Test
curl http://<EXTERNAL-IP>

# 9. Enable monitoring
az aks enable-addons --resource-group fasthack-rg --name fasthack-aks --addons monitoring

# 10. LIMPE quando terminar!
az group delete --name fasthack-rg --yes --no-wait
```

</details>

<details>
<summary>Dica 2: AWS (EKS) — Passo a passo completo</summary>

```bash
# 1. Verify credentials
aws sts get-caller-identity

# 2. Create EKS cluster (this takes ~15 minutes)
eksctl create cluster \
  --name fasthack-eks \
  --region us-east-1 \
  --nodegroup-name fasthack-nodes \
  --node-type t3.small \
  --nodes 2

# 3. eksctl automatically configures kubectl — verify
kubectl get nodes

# 4. Deploy the app
kubectl apply -f cloud-app.yaml
kubectl apply -f frontend-lb.yaml

# 5. Wait for external IP (AWS creates a Classic Load Balancer — the EXTERNAL-IP will be a hostname)
kubectl get svc frontend-lb --watch

# 6. Test (use the hostname, not an IP)
curl http://<EXTERNAL-HOSTNAME>

# 7. Enable monitoring
aws eks create-addon \
  --cluster-name fasthack-eks \
  --addon-name amazon-cloudwatch-observability

# 8. LIMPE quando terminar!
kubectl delete svc frontend-lb
kubectl delete pvc cloud-pvc
eksctl delete cluster --name fasthack-eks --region us-east-1
```

> **Nota:** No AWS, o `EXTERNAL-IP` do LoadBalancer é um hostname DNS (ex: `abc123.us-east-1.elb.amazonaws.com`), não um endereço IP. Use-o da mesma forma — `curl http://<hostname>`.

</details>

<details>
<summary>Dica 3: Google Cloud (GKE) — Passo a passo completo</summary>

```bash
# 1. Login and set project
gcloud auth login
gcloud config set project YOUR_PROJECT_ID

# 2. Create GKE cluster
gcloud container clusters create fasthack-gke \
  --zone us-central1-a \
  --num-nodes 2 \
  --machine-type e2-small \
  --release-channel regular

# 3. Get credentials
gcloud container clusters get-credentials fasthack-gke --zone us-central1-a

# 4. Verify
kubectl get nodes

# 5. Deploy the app
kubectl apply -f cloud-app.yaml
kubectl apply -f frontend-lb.yaml

# 6. Wait for external IP
kubectl get svc frontend-lb --watch

# 7. Test
curl http://<EXTERNAL-IP>

# 8. Monitoring is enabled by default — check the GKE console

# 9. LIMPE quando terminar!
gcloud container clusters delete fasthack-gke --zone us-central1-a --quiet
```

</details>

<details>
<summary>Dica 4: Alternando contexto do kubectl entre Kind e nuvem</summary>

```bash
# List all contexts
kubectl config get-contexts

# Switch to your cloud cluster
kubectl config use-context <cloud-context-name>

# Switch back to Kind
kubectl config use-context kind-fasthack

# Rename a context for convenience
kubectl config rename-context <long-cloud-name> cloud
```

Nomes de contexto comuns:
- **AKS:** `fasthack-aks`
- **EKS:** `<arn>:cluster/fasthack-eks` (use `kubectl config get-contexts` para encontrar o nome exato)
- **GKE:** `gke_<project>_<zone>_fasthack-gke`

</details>

<details>
<summary>Dica 5: Troubleshooting — LoadBalancer preso em "pending"</summary>

Se `EXTERNAL-IP` permanece `<pending>` por mais de 5 minutos:

```bash
# Verifique eventos para problemas
kubectl describe svc frontend-lb

# Verifique o status dos nodes
kubectl get nodes

# Verifique se a integração com o provedor de nuvem está funcionando
kubectl get events --sort-by='.lastTimestamp'
```

Causas comuns:
- **AKS:** Cota insuficiente para IPs públicos na região. Execute `az network public-ip list --resource-group MC_fasthack-rg_fasthack-aks_eastus`.
- **EKS:** Permissões IAM ausentes para o AWS Load Balancer Controller. Verifique a saída do `eksctl` para avisos.
- **GKE:** Regras de firewall bloqueando health checks. Verifique `gcloud compute firewall-rules list`.

</details>

## Recursos de Aprendizado

### Azure Kubernetes Service (AKS)
- [AKS Documentation](https://learn.microsoft.com/azure/aks/)
- [Quickstart: Deploy an AKS cluster](https://learn.microsoft.com/azure/aks/learn/quick-kubernetes-deploy-cli)
- [AKS Pricing Tiers](https://learn.microsoft.com/azure/aks/free-standard-pricing-tiers)
- [Azure Monitor Container Insights](https://learn.microsoft.com/azure/azure-monitor/containers/container-insights-overview)

### Amazon Elastic Kubernetes Service (EKS)
- [EKS Documentation](https://docs.aws.amazon.com/eks/latest/userguide/)
- [Getting Started with eksctl](https://eksctl.io/getting-started/)
- [EKS Pricing](https://aws.amazon.com/eks/pricing/)
- [CloudWatch Container Insights for EKS](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Container-Insights-setup-EKS-quickstart.html)

### Google Kubernetes Engine (GKE)
- [GKE Documentation](https://cloud.google.com/kubernetes-engine/docs)
- [Quickstart: Deploy an app to GKE](https://cloud.google.com/kubernetes-engine/docs/deploy-app-cluster)
- [GKE Pricing](https://cloud.google.com/kubernetes-engine/pricing)
- [GKE Observability](https://cloud.google.com/stackdriver/docs/managed-prometheus)

### Geral
- [Kubernetes Documentation — Cloud Providers](https://kubernetes.io/docs/concepts/cluster-administration/cloud-providers/)
- [CNCF Landscape — Certified Kubernetes](https://landscape.cncf.io/)

## O Que Vem Depois?

🎉 **Você conseguiu!** Você completou todo o hackathon **Kubernetes para Sysadmins Linux** — desde executar seu primeiro container até fazer deploy em infraestrutura de nuvem em produção.

Aqui está o caminho de aprendizado que você seguiu e para onde ir a seguir:

```
┌─────────────────────────┐     ┌─────────────────────────────────┐     ┌──────────────────────────────┐
│  🐧 Linux FUNdamentals  │ ──▶ │  ☸️ Kubernetes for Linux Sysadmins │ ──▶ │  🤖 AI for Infra Professionals │
│  linuxhackathon.com     │     │  (Você está aqui — COMPLETO! ✅)  │     │  ai4infra.com                │
└─────────────────────────┘     └─────────────────────────────────┘     └──────────────────────────────┘
```

### Próximos passos recomendados

1. **[AI for Infrastructure Professionals](https://ai4infra.com/)** — Aprenda a executar workloads de IA na infraestrutura que você acabou de dominar.

2. **Obtenha Certificação** — Você agora está preparado para buscar:
   ```
   KCNA → CKA → CKAD → CKS
   ```

3. **Explore mais em [ricardomartins.com.br](https://ricardomartins.com.br)** — Mais conteúdo cloud-native e recursos de aprendizado.

4. **Contribua** — Encontrou um bug ou quer melhorar um desafio? [Abra uma issue](https://github.com/ricmmartins/fasthack-kubernetes/issues) ou envie um PR!

> **"Você começou conhecendo Linux. Agora você o orquestra em escala."** 🚀
