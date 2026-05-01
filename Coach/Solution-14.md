# Solução 14 — Deploy na Cloud

[< Voltar para o Desafio](../Student/Challenge-14.md) | **[Home](README.md)**

---

> **Nota do Coach:** Este desafio é **OPCIONAL**. Os alunos precisam de uma conta na cloud com faturamento ativado. A parte mais crítica deste desafio é a **limpeza** — os alunos DEVEM excluir todos os recursos da cloud ao finalizar. Monitore isso ativamente.

## Tarefa 0: Pré-requisitos

Certifique-se de que os alunos possuem:
- Uma conta ativa no provedor de cloud escolhido
- A CLI do provedor instalada e autenticada
- `kubectl` instalado (dos desafios anteriores)

### Verificar Autenticação da CLI

**Azure:**

```bash
az login
az account show
```

Esperado: Exibe o nome da assinatura, ID e tenant.

**AWS:**

```bash
aws sts get-caller-identity
```

Esperado: Exibe Account ID, ARN e UserID.

**Google Cloud:**

```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
gcloud config get-value project
```

Esperado: Exibe o ID do projeto configurado.

> **Dica para o Coach:** Se os alunos não tiverem uma conta na cloud, eles podem fazer par com alguém que tenha, ou pular este desafio completamente — todo o aprendizado essencial está nos Desafios 01–13.

---

## Tarefa 1: Criar um Cluster Kubernetes Gerenciado

### Passo a passo

#### Azure (AKS)

```bash
# Create a resource group
az group create --name fasthack-rg --location eastus
```

Esperado:

```json
{
  "id": "/subscriptions/.../resourceGroups/fasthack-rg",
  "location": "eastus",
  "name": "fasthack-rg",
  "properties": { "provisioningState": "Succeeded" }
}
```

```bash
# Create the AKS cluster (Free tier — no control plane charge)
az aks create \
  --resource-group fasthack-rg \
  --name fasthack-aks \
  --node-count 2 \
  --node-vm-size Standard_B2s \
  --generate-ssh-keys
```

Leva de 5 a 10 minutos. Esperado: Saída JSON com `"provisioningState": "Succeeded"`.

> 💰 **AKS Free tier:** O control plane é gratuito. Você paga apenas pelos 2× Standard_B2s worker nodes (~$0.042/hora cada).

#### AWS (EKS)

```bash
eksctl create cluster \
  --name fasthack-eks \
  --region us-east-1 \
  --nodegroup-name fasthack-nodes \
  --node-type t3.small \
  --nodes 2
```

Leva de 10 a 15 minutos. O `eksctl` cria a VPC, subnets, security groups, IAM roles e node group automaticamente.

A saída esperada termina com:

```
EKS cluster "fasthack-eks" in "us-east-1" region is ready
```

> 💰 **Preço do EKS:** O control plane custa $0.10/hora (~$73/mês). Worker nodes são 2× t3.small (~$0.021/hora cada). Delete prontamente!

#### Google Cloud (GKE)

```bash
gcloud container clusters create fasthack-gke \
  --zone us-central1-a \
  --num-nodes 2 \
  --machine-type e2-small \
  --release-channel regular
```

Leva de 5 a 10 minutos. Esperado:

```
NAME           LOCATION       MASTER_VERSION  NUM_NODES  STATUS
fasthack-gke   us-central1-a  1.XX.XX-gke.XX  2          RUNNING
```

> 💰 **GKE Free tier:** Um cluster zonal por conta de faturamento recebe $74.40/mês em créditos gratuitos. Você ainda paga pelo compute dos nodes (2× e2-small ~$0.017/hora cada).

### Verificação

Após a criação do cluster:

```bash
kubectl get nodes -o wide
```

Esperado: 2 nodes com nomes do provedor de cloud (não `kind-control-plane`).

---

## Tarefa 2: Conectar o kubectl ao Cluster na Cloud

### Passo a passo

#### Azure (AKS)

```bash
az aks get-credentials --resource-group fasthack-rg --name fasthack-aks
```

Esperado:

```
Merged "fasthack-aks" as current context in /home/user/.kube/config
```

#### AWS (EKS)

```bash
aws eks update-kubeconfig --name fasthack-eks --region us-east-1
```

Esperado:

```
Updated context arn:aws:eks:us-east-1:XXXX:cluster/fasthack-eks in /home/user/.kube/config
```

> Nota: O `eksctl create cluster` configura o kubectl automaticamente, então este passo pode já estar concluído.

#### Google Cloud (GKE)

```bash
gcloud container clusters get-credentials fasthack-gke --zone us-central1-a
```

Esperado:

```
Fetching cluster endpoint and auth data.
kubeconfig entry generated for fasthack-gke.
```

### Verificação

```bash
# Confirm you're connected to the cloud cluster (not Kind)
kubectl config current-context
```

Esperado: O nome do contexto inclui o nome do cluster na cloud (ex.: `fasthack-aks`, `arn:aws:eks:...`, `gke_project_zone_fasthack-gke`).

```bash
# Verify cloud nodes
kubectl get nodes -o wide
```

Esperado: Os nodes mostram nomes de instância do provedor de cloud e IPs externos.

---

## Tarefa 3: Fazer Deploy da Aplicação Multi-Tier

### Passo a passo

Crie o arquivo `cloud-app.yaml`:

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

# Wait for all Pods to be running
kubectl get pods --watch
```

### Verificação

```bash
kubectl get pods
```

Esperado: 2 Pods de backend e 2 Pods de frontend, todos `1/1 Running`.

```bash
kubectl get svc
```

Esperado: `backend-svc` com `ClusterIP`, `kubernetes` com `ClusterIP`.

---

## Tarefa 4: Expor a Aplicação com um LoadBalancer na Cloud

### Passo a passo

Crie o arquivo `frontend-lb.yaml`:

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

# Wait for the external IP (1-3 minutes)
kubectl get svc frontend-lb --watch
```

Esperado: O `EXTERNAL-IP` transiciona de `<pending>` para um endereço IP real (ou hostname na AWS).

> **Nota sobre AWS:** No EKS, o `EXTERNAL-IP` é um hostname DNS (ex.: `abc123.us-east-1.elb.amazonaws.com`), não um endereço IP. Use-o da mesma forma.

### Verificação

```bash
# Replace <EXTERNAL-IP> with the actual IP/hostname
curl http://<EXTERNAL-IP>
```

Esperado:

```
Hello from the cloud! ☁️
```

🎉 **A aplicação está no ar na internet!**

> **Dica para o Coach:** Se o `EXTERNAL-IP` permanecer em `<pending>` por mais de 5 minutos, verifique: `kubectl describe svc frontend-lb` para ver os eventos, e certifique-se de que o provedor de cloud tem cota suficiente para IPs públicos.

---

## Tarefa 5: Armazenamento Cloud-Native (CSI Drivers)

### Passo a passo

Verifique as StorageClasses disponíveis:

```bash
kubectl get storageclass
```

A saída esperada varia por provedor:

| Provedor | StorageClass Padrão | CSI Driver |
|----------|---------------------|------------|
| AKS | `managed-csi` | `disk.csi.azure.com` |
| EKS | `gp2` | `ebs.csi.aws.com` |
| GKE | `standard-rwo` | `pd.csi.storage.gke.io` |

Crie um PVC de teste:

```yaml
# Save as cloud-pvc.yaml
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
kubectl get pvc cloud-pvc
```

### Verificação

```bash
kubectl get pvc cloud-pvc
```

Esperado:

```
NAME        STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
cloud-pvc   Bound    pvc-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   1Gi        RWO            <default-sc>   30s
```

O PVC deve estar com status `Bound` — o provedor de cloud provisionou dinamicamente um disco real.

> **Dica para o Coach:** Destaque a diferença em relação ao Kind — no Kind, `standard` usa `rancher.io/local-path` (diretório local). Na cloud, o CSI driver provisiona discos reais na cloud (Azure Managed Disk, AWS EBS, GCE Persistent Disk). Mesma API, backends diferentes.

---

## Tarefa 6: Configurar Monitoramento Básico

### Passo a passo

#### Azure (AKS) — Azure Monitor Container Insights

```bash
az aks enable-addons \
  --resource-group fasthack-rg \
  --name fasthack-aks \
  --addons monitoring
```

Após alguns minutos, visualize as métricas no Portal Azure → cluster AKS → **Insights**.

#### AWS (EKS) — CloudWatch Container Insights

```bash
aws eks create-addon \
  --cluster-name fasthack-eks \
  --addon-name amazon-cloudwatch-observability
```

Verifique:

```bash
kubectl get pods -n amazon-cloudwatch
```

Visualize as métricas no AWS Console → CloudWatch → Container Insights.

#### Google Cloud (GKE) — Cloud Monitoring

O GKE tem o Cloud Monitoring habilitado **por padrão** — nenhuma etapa extra é necessária.

Verifique:

```bash
kubectl get pods -n kube-system -l k8s-app=gke-metrics-agent
```

Visualize as métricas no Google Cloud Console → Kubernetes Engine → cluster → **Observability**.

### Verificação

- Os Pods do agente de monitoramento estão em execução no namespace correspondente
- O console do provedor de cloud exibe métricas básicas de container

---

## Tarefa 7: Limpeza dos Recursos na Cloud ⚠️

> 🔴 **ESTE É O PASSO MAIS IMPORTANTE. Os alunos DEVEM excluir todos os recursos na cloud AGORA.**
>
> **Coach: Verifique ativamente que todos os alunos realizaram a limpeza antes de saírem.**

### Azure (AKS)

```bash
# Delete the entire resource group — removes cluster, VMs, disks, LB, and all associated resources
az group delete --name fasthack-rg --yes --no-wait
```

Verifique a exclusão:

```bash
az group show --name fasthack-rg 2>/dev/null || echo "Resource group deleted successfully"
```

### AWS (EKS)

```bash
# Delete Kubernetes resources first (releases the cloud load balancer)
kubectl delete svc frontend-lb
kubectl delete pvc cloud-pvc

# Delete the EKS cluster and all associated resources
eksctl delete cluster --name fasthack-eks --region us-east-1
```

Isso leva de 5 a 10 minutos. Verifique no AWS Console que não restam instâncias EC2, volumes EBS ou Elastic Load Balancers.

> **⚠️ Verificação extra na AWS:** Se o `eksctl delete` falhar ou travar, verifique manualmente se há recursos remanescentes no AWS Console: EC2 Instances, Load Balancers, VPCs, NAT Gateways e EBS Volumes em `us-east-1`.

### Google Cloud (GKE)

```bash
# Delete the GKE cluster
gcloud container clusters delete fasthack-gke --zone us-central1-a --quiet
```

Verifique no Google Cloud Console que não restam instâncias do Compute Engine ou Load Balancers.

### Voltar para o Kind

Após a limpeza, alterne o kubectl de volta para o cluster Kind local:

```bash
kubectl config use-context kind-fasthack

# Verify
kubectl get nodes
```

Esperado: Mostra `fasthack-control-plane` (o node do Kind), não VMs na cloud.

### Verificação

- [ ] O cluster na cloud foi excluído (verifique no console web do provedor)
- [ ] Não há VMs, load balancers ou discos em execução
- [ ] O contexto do kubectl está de volta em `kind-fasthack`

---

## Próximos Passos — Trilha de Aprendizado 🎓

```
┌─────────────────────────┐     ┌─────────────────────────────────┐     ┌──────────────────────────────┐
│  🐧 Linux FUNdamentals  │ ──▶ │  ☸️ Kubernetes for Linux Sysadmins │ ──▶ │  🤖 AI for Infra Professionals │
│  linuxhackathon.com     │     │  (You are here — COMPLETE! ✅)   │     │  ai4infra.com                │
└─────────────────────────┘     └─────────────────────────────────┘     └──────────────────────────────┘
```

Próximos passos recomendados para os alunos:

1. **[AI for Infrastructure Professionals](https://ai4infra.com/)** — Aprenda como executar workloads de IA na infraestrutura que você acabou de dominar.
2. **Obtenha uma Certificação** — Os alunos agora estão preparados para: `KCNA → CKA → CKAD → CKS`
3. **[Linux FUNdamentals](https://linuxhackathon.com/)** — Se ainda não fizeram este hackathon, ele é a base de tudo que acabaram de aprender.
4. **Contribua** — [Abra issues](https://github.com/ricmmartins/fasthack-kubernetes/issues) ou envie PRs para melhorar o hackathon!

---

## Problemas Comuns

| Problema | Causa | Correção |
|----------|-------|----------|
| `az aks create` falha com erro de cota | A assinatura não tem cota suficiente de vCPU para a região | Tente uma região diferente: `--location westus2` ou solicite aumento de cota |
| `eksctl create cluster` leva mais de 20 minutos | A criação do cluster EKS é naturalmente lenta | Aguarde pacientemente — provisiona VPC, subnets, NAT gateways, IAM roles e nodes |
| `gcloud` exibe "billing not enabled" | O projeto GCP precisa de faturamento vinculado | Habilite o faturamento no Google Cloud Console → Billing |
| `EXTERNAL-IP` preso em `<pending>` | Atraso no provisionamento do Cloud LB ou permissões insuficientes | Aguarde 5 min; verifique `kubectl describe svc frontend-lb` para ver os eventos |
| Não consegue conectar ao cluster na cloud após a criação | O contexto do kubectl não foi atualizado | Execute novamente o comando get-credentials do seu provedor |
| `eksctl delete cluster` trava | Recursos de LoadBalancer remanescentes bloqueando a exclusão da VPC | Exclua manualmente o ELB no AWS Console e tente novamente |
| Aluno esqueceu de limpar e foi embora | Recursos em execução = custos acumulando | **O Coach deve verificar a limpeza.** Use o console da cloud para verificar recursos órfãos |
| PVC permanece Pending no EKS | EBS CSI driver não instalado | Execute: `eksctl create addon --name aws-ebs-csi-driver --cluster fasthack-eks` |

## Referência Rápida dos Provedores de Cloud

| Operação | AKS (Azure) | EKS (AWS) | GKE (Google Cloud) |
|----------|-------------|-----------|---------------------|
| **Ferramenta CLI** | `az` | `aws` + `eksctl` | `gcloud` |
| **Criar cluster** | `az aks create` | `eksctl create cluster` | `gcloud container clusters create` |
| **Obter credenciais** | `az aks get-credentials` | `aws eks update-kubeconfig` | `gcloud container clusters get-credentials` |
| **CSI driver** | `disk.csi.azure.com` | `ebs.csi.aws.com` | `pd.csi.storage.gke.io` |
| **StorageClass padrão** | `managed-csi` | `gp2` | `standard-rwo` |
| **Monitoramento** | Azure Monitor Container Insights | CloudWatch Container Insights | Cloud Monitoring (auto) |
| **Custo do control plane** | Gratuito (Free tier) | $0.10/hora (~$73/mês) | Gratuito (crédito $74.40/mês) |
| **Excluir cluster** | `az group delete --name fasthack-rg --yes` | `eksctl delete cluster --name fasthack-eks` | `gcloud container clusters delete fasthack-gke --quiet` |
