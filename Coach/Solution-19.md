# Solução 19 — Segurança e Hardening do Cluster

[< Solução Anterior](Solution-18.md) - **[Home](README.md)** - [Próxima Solução >](Solution-20.md)

---

> **Nota do Coach:** Este é um desafio focado no CKS cobrindo segurança de configuração do cluster, hardening do cluster, audit logging e criptografia em repouso. As Tarefas 1, 6 e 7 **requerem** acesso ao cluster kubeadm (SSH no node control-plane, edição de manifestos de Pod estáticos). As Tarefas 2–5, 8 podem ser adaptadas para Kind com limitações. Reserve tempo extra para as Tarefas 6 e 7 — editar manifestos do API server é propenso a erros e os alunos podem precisar de ajuda para recuperação.

Tempo estimado: **90–120 minutos**

---

## Tarefa 1: CIS Kubernetes Benchmark com kube-bench

### Passo a passo

**Conecte via SSH no node control-plane:**

```bash
ssh user@control-plane-ip
```

**Baixe o kube-bench:**

```bash
curl -L https://github.com/aquasecurity/kube-bench/releases/latest/download/kube-bench_0.10.7_linux_amd64.tar.gz -o kube-bench.tar.gz
tar xzf kube-bench.tar.gz
```

**Execute contra o control-plane:**

```bash
sudo ./kube-bench run --targets master
```

### Saída esperada (abreviada)

```
[INFO] 1 Control Plane Security Configuration
[INFO] 1.1 Control Plane Node Configuration Files
[PASS] 1.1.1 Ensure that the API server pod specification file permissions are set to 600 or more restrictive
[PASS] 1.1.2 Ensure that the API server pod specification file ownership is set to root:root
...
[FAIL] 1.2.15 Ensure that the admission control plugin NamespaceLifecycle is set
[FAIL] 1.2.17 Ensure that the --audit-log-path argument is set
[FAIL] 1.2.18 Ensure that the --audit-log-maxage argument is set
...
== Summary master ==
42 checks PASS
12 checks FAIL
10 checks WARN
0 checks INFO
```

### Remediações comuns

**Correção 1 — Permissões de arquivo muito permissivas:**

```bash
sudo chmod 600 /etc/kubernetes/manifests/kube-apiserver.yaml
sudo chmod 600 /etc/kubernetes/manifests/kube-controller-manager.yaml
sudo chmod 600 /etc/kubernetes/manifests/kube-scheduler.yaml
sudo chmod 600 /etc/kubernetes/manifests/etcd.yaml
sudo chmod 600 /etc/kubernetes/admin.conf
```

**Correção 2 — Audit logging não configurado (1.2.17–1.2.20):**

Isso será completamente abordado na Tarefa 6. Por agora, note que a correção requer:
- `--audit-log-path`
- `--audit-log-maxage`
- `--audit-log-maxbackup`
- `--audit-log-maxsize`

**Correção 3 — Encryption provider não configurado (1.2.29):**

Isso será abordado na Tarefa 7. Requer `--encryption-provider-config`.

**Correção 4 — Admission controllers:**

Se o kube-bench reportar admission controllers ausentes, edite `/etc/kubernetes/manifests/kube-apiserver.yaml` e garanta que a flag `--enable-admission-plugins` inclua os plugins necessários:

```bash
# Check current admission plugins
sudo grep admission /etc/kubernetes/manifests/kube-apiserver.yaml
```

Conjunto padrão recomendado:

```yaml
    - --enable-admission-plugins=NodeRestriction,NamespaceLifecycle,LimitRanger,ServiceAccount,DefaultStorageClass,ResourceQuota
```

**Correção 5 — kubelet anonymous auth (4.2.1):**

Verifique a configuração do kubelet:

```bash
sudo cat /var/lib/kubelet/config.yaml | grep -A2 authentication
```

Garanta que:

```yaml
authentication:
  anonymous:
    enabled: false
```

Se estiver `true`, edite o arquivo e reinicie o kubelet:

```bash
sudo systemctl restart kubelet
```

### Execute no worker node

```bash
ssh user@worker-node-ip
sudo ./kube-bench run --targets node
```

### Re-execute após as correções

```bash
sudo ./kube-bench run --targets master 2>&1 | tail -10
```

Esperado: menos FAILs do que na execução inicial.

> **Dica para o Coach:** Não deixe os alunos gastarem muito tempo perseguindo cada FAIL. O objetivo é entender o processo — auditar, identificar, remediar, verificar. 5 correções são suficientes. As Tarefas 6 e 7 corrigirão achados adicionais automaticamente.

### Alternativa — Executar como Job

```bash
kubectl apply -f https://raw.githubusercontent.com/aquasecurity/kube-bench/main/job.yaml
kubectl wait --for=condition=complete job/kube-bench --timeout=300s
kubectl logs job/kube-bench
```

> **Dica para o Coach:** A abordagem via Job pode não detectar todos os achados porque não consegue acessar todos os caminhos no nível do host. Executar diretamente no node é mais completo.

---

## Tarefa 2: Ingress com TLS Usando cert-manager

### Passo a passo

**Instale o cert-manager:**

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
```

Aguarde todos os componentes:

```bash
kubectl wait --for=condition=available deployment/cert-manager -n cert-manager --timeout=120s
kubectl wait --for=condition=available deployment/cert-manager-webhook -n cert-manager --timeout=120s
kubectl wait --for=condition=available deployment/cert-manager-cainjector -n cert-manager --timeout=120s
```

Esperado:

```
deployment.apps/cert-manager condition met
deployment.apps/cert-manager-webhook condition met
deployment.apps/cert-manager-cainjector condition met
```

**Crie o ClusterIssuer:**

Salve `self-signed-issuer.yaml`:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
```

```bash
kubectl apply -f self-signed-issuer.yaml
```

### Verificação — ClusterIssuer pronto

```bash
kubectl get clusterissuer selfsigned-issuer
```

Esperado:

```
NAME                READY   AGE
selfsigned-issuer   True    10s
```

**Crie o app de teste:**

Salve `tls-demo-app.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tls-demo
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: tls-demo
  template:
    metadata:
      labels:
        app: tls-demo
    spec:
      containers:
        - name: web
          image: hashicorp/http-echo
          args:
            - "-text=Hello from TLS-secured app!"
          ports:
            - containerPort: 5678
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 64Mi
---
apiVersion: v1
kind: Service
metadata:
  name: tls-demo-svc
  namespace: default
spec:
  selector:
    app: tls-demo
  ports:
    - port: 80
      targetPort: 5678
```

```bash
kubectl apply -f tls-demo-app.yaml
```

**Crie o Certificate:**

Salve `tls-demo-cert.yaml`:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: tls-demo-cert
  namespace: default
spec:
  secretName: tls-demo-tls
  duration: 2160h
  renewBefore: 360h
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
  commonName: tls-demo.local
  dnsNames:
    - tls-demo.local
```

```bash
kubectl apply -f tls-demo-cert.yaml
```

### Verificação — Certificate emitido

```bash
kubectl get certificate tls-demo-cert
```

Esperado:

```
NAME            READY   SECRET         AGE
tls-demo-cert   True    tls-demo-tls   30s
```

```bash
kubectl get secret tls-demo-tls
```

Esperado:

```
NAME           TYPE                DATA   AGE
tls-demo-tls   kubernetes.io/tls   3      30s
```

**Inspecione o certificado:**

```bash
kubectl get secret tls-demo-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout | head -20
```

A saída esperada inclui:

```
        Issuer: CN = tls-demo.local
        Subject: CN = tls-demo.local
        ...
        X509v3 Subject Alternative Name:
            DNS:tls-demo.local
```

**Crie o Ingress:**

Salve `tls-demo-ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: tls-demo-ingress
  namespace: default
  annotations:
    cert-manager.io/cluster-issuer: selfsigned-issuer
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - tls-demo.local
      secretName: tls-demo-tls
  rules:
    - host: tls-demo.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: tls-demo-svc
                port:
                  number: 80
```

```bash
kubectl apply -f tls-demo-ingress.yaml
```

### Verificação — Ingress com TLS

```bash
kubectl get ingress tls-demo-ingress
kubectl describe ingress tls-demo-ingress
```

A seção `TLS` deve mostrar o host e o nome do Secret.

**Teste (se o Ingress Controller estiver em execução):**

```bash
curl -k -H "Host: tls-demo.local" https://localhost
```

Esperado: `Hello from TLS-secured app!`

> **Dica para o Coach:** Se nenhum Ingress Controller estiver instalado, o aprendizado principal é o pipeline Certificate → Secret → Ingress TLS. O teste HTTPS real é um bônus. Os alunos devem verificar que o Secret foi criado com dados TLS válidos.

### Alternativa — Secret TLS Manual

Se a instalação do cert-manager travar:

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key -out tls.crt \
  -subj "/CN=tls-demo.local"
kubectl create secret tls tls-demo-tls --cert=tls.crt --key=tls.key
```

---

## Tarefa 3: NetworkPolicy de Egress Default-Deny

### Passo a passo

```bash
kubectl create namespace egress-lab
```

**Aplique o egress default-deny:**

Salve `default-deny-egress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: egress-lab
spec:
  podSelector: {}
  policyTypes:
    - Egress
```

```bash
kubectl apply -f default-deny-egress.yaml
```

### Verificação — Todo egress bloqueado

```bash
kubectl run test-pod --image=busybox --namespace=egress-lab --restart=Never -- sleep 3600
kubectl wait --for=condition=ready pod/test-pod -n egress-lab --timeout=60s
```

```bash
kubectl exec -n egress-lab test-pod -- wget -qO- --timeout=5 http://google.com 2>&1
```

Esperado: `wget: bad address 'google.com'` ou timeout — a resolução DNS falha porque todo egress (incluindo porta 53) está bloqueado.

```bash
kubectl exec -n egress-lab test-pod -- nslookup kubernetes.default 2>&1
```

Esperado: timeout ou `nslookup: write to '10.96.0.10': Operation not permitted`

**Aplique egress seletivo:**

Salve `allow-dns-and-api.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-and-api
  namespace: egress-lab
spec:
  podSelector:
    matchLabels:
      role: api-consumer
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector: {}
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - to:
        - podSelector:
            matchLabels:
              app: backend
      ports:
        - protocol: TCP
          port: 8080
```

```bash
kubectl apply -f allow-dns-and-api.yaml
```

### Verificação — Egress seletivo

```bash
kubectl run labeled-pod --image=busybox --namespace=egress-lab --labels="role=api-consumer" --restart=Never -- sleep 3600
kubectl wait --for=condition=ready pod/labeled-pod -n egress-lab --timeout=60s
```

DNS deve funcionar:

```bash
kubectl exec -n egress-lab labeled-pod -- nslookup kubernetes.default
```

Esperado:

```
Server:    10.96.0.10
Address 1: 10.96.0.10 kube-dns.kube-system.svc.cluster.local

Name:      kubernetes.default
Address 1: 10.96.0.1 kubernetes.default.svc.cluster.local
```

Internet ainda bloqueada:

```bash
kubectl exec -n egress-lab labeled-pod -- wget -qO- --timeout=5 http://google.com 2>&1
```

Esperado: timeout (o DNS resolve, mas a política de egress não permite HTTP para IPs externos).

> **Dica para o Coach:** Os alunos frequentemente esquecem que o default-deny bloqueia o DNS também. Esta é a fonte #1 de confusão. Enfatize que o DNS deve ser explicitamente permitido nas regras de egress. O `test-pod` sem labels ainda não tem nenhum egress — apenas Pods que correspondem a `role: api-consumer` recebem a exceção de DNS.

---

## Tarefa 4: Verificar Checksums dos Binários do Kubernetes

### Passo a passo

**Obtenha as versões:**

```bash
kubectl version --client --output=yaml | grep gitVersion
kubelet --version
kubeadm version -o short
```

Exemplo de saída:

```
  gitVersion: v1.32.0
Kubernetes v1.32.0
v1.32.0
```

**Verifique o kubectl:**

```bash
KUBE_VERSION=$(kubectl version --client -o json | grep -oP '"gitVersion": "\K[^"]+')
echo "Verifying kubectl ${KUBE_VERSION}"

curl -sLO "https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/amd64/kubectl.sha256"
echo "$(cat kubectl.sha256)  $(which kubectl)" | sha256sum --check
```

Esperado:

```
/usr/local/bin/kubectl: OK
```

**Verifique o kubelet:**

```bash
KUBELET_VERSION=$(kubelet --version | awk '{print $2}')
echo "Verifying kubelet ${KUBELET_VERSION}"

curl -sLO "https://dl.k8s.io/release/${KUBELET_VERSION}/bin/linux/amd64/kubelet.sha256"
echo "$(cat kubelet.sha256)  $(which kubelet)" | sha256sum --check
```

Esperado:

```
/usr/bin/kubelet: OK
```

**Verifique o kubeadm:**

```bash
KUBEADM_VERSION=$(kubeadm version -o short)
echo "Verifying kubeadm ${KUBEADM_VERSION}"

curl -sLO "https://dl.k8s.io/release/${KUBEADM_VERSION}/bin/linux/amd64/kubeadm.sha256"
echo "$(cat kubeadm.sha256)  $(which kubeadm)" | sha256sum --check
```

Esperado:

```
/usr/bin/kubeadm: OK
```

> **Dica para o Coach:** Se o checksum de um aluno não corresponder, pode significar: (1) ele instalou de uma fonte diferente (gerenciador de pacotes vs. download direto — o caminho do binário pode diferir), (2) o binário foi compilado localmente, ou (3) o download foi corrompido. Em clusters kubeadm instalados via apt, os binários devem corresponder aos checksums upstream.

> **Nota sobre SHA512 vs SHA256:** O exame CKS referencia checksums SHA512. Os artefatos de release do Kubernetes publicam arquivos `.sha256`. Ambos verificam integridade — SHA256 é o padrão para releases do K8s. Se o aluno quiser SHA512 especificamente:
> ```bash
> sha512sum $(which kubectl)
> ```
> Então compare manualmente com os checksums da página de releases do Kubernetes no GitHub.

---

## Tarefa 5: Hardening de ServiceAccount

### Passo a passo

```bash
kubectl create namespace sa-lab
```

**Demonstre a montagem padrão do token:**

```bash
kubectl run default-sa-test --image=busybox --namespace=sa-lab --restart=Never -- sleep 3600
kubectl wait --for=condition=ready pod/default-sa-test -n sa-lab --timeout=60s
```

```bash
kubectl exec -n sa-lab default-sa-test -- ls /var/run/secrets/kubernetes.io/serviceaccount/
```

Esperado:

```
ca.crt
namespace
token
```

O arquivo token contém um JWT que pode autenticar no API server:

```bash
kubectl exec -n sa-lab default-sa-test -- cat /var/run/secrets/kubernetes.io/serviceaccount/token
```

**Desabilite o automount no SA default:**

```bash
kubectl patch serviceaccount default -n sa-lab \
  -p '{"automountServiceAccountToken": false}'
```

### Verificação — Sem token em novos Pods

```bash
kubectl delete pod default-sa-test -n sa-lab
kubectl run no-token-test --image=busybox --namespace=sa-lab --restart=Never -- sleep 3600
kubectl wait --for=condition=ready pod/no-token-test -n sa-lab --timeout=60s
```

```bash
kubectl exec -n sa-lab no-token-test -- ls /var/run/secrets/kubernetes.io/serviceaccount/ 2>&1
```

Esperado:

```
ls: /var/run/secrets/kubernetes.io/serviceaccount/: No such file or directory
```

**Crie um ServiceAccount dedicado:**

Salve `app-sa.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: configmap-reader
  namespace: sa-lab
automountServiceAccountToken: true
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: configmap-read-role
  namespace: sa-lab
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: configmap-read-binding
  namespace: sa-lab
subjects:
  - kind: ServiceAccount
    name: configmap-reader
    namespace: sa-lab
roleRef:
  kind: Role
  name: configmap-read-role
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f app-sa.yaml
kubectl create configmap test-config -n sa-lab --from-literal=key1=value1
```

**Teste o SA dedicado:**

Salve `sa-test-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: sa-test
  namespace: sa-lab
spec:
  serviceAccountName: configmap-reader
  containers:
    - name: test
      image: bitnami/kubectl:latest
      command: ["sleep", "3600"]
      resources:
        requests:
          cpu: 50m
          memory: 32Mi
```

```bash
kubectl apply -f sa-test-pod.yaml
kubectl wait --for=condition=ready pod/sa-test -n sa-lab --timeout=120s
```

### Verificação — Privilégio mínimo

ConfigMaps permitidos:

```bash
kubectl exec -n sa-lab sa-test -- kubectl get configmaps -n sa-lab
```

Esperado:

```
NAME               DATA   AGE
kube-root-ca.crt   1      5m
test-config        1      2m
```

Secrets negados:

```bash
kubectl exec -n sa-lab sa-test -- kubectl get secrets -n sa-lab 2>&1
```

Esperado:

```
Error from server (Forbidden): secrets is forbidden: User "system:serviceaccount:sa-lab:configmap-reader" cannot list resource "secrets" in API group "" in the namespace "sa-lab"
```

Pods negados:

```bash
kubectl exec -n sa-lab sa-test -- kubectl get pods -n sa-lab 2>&1
```

Esperado:

```
Error from server (Forbidden): pods is forbidden: User "system:serviceaccount:sa-lab:configmap-reader" cannot list resource "pods" in API group "" in the namespace "sa-lab"
```

**Audite bindings cluster-admin:**

```bash
kubectl get clusterrolebindings -o json | \
  jq -r '.items[] | select(.roleRef.name=="cluster-admin") | .metadata.name + " -> " + (.subjects[]? | .kind + "/" + .name)'
```

Saída esperada (pode variar conforme o cluster):

```
cluster-admin -> User/kubernetes-admin
kubeadm:cluster-admins -> Group/kubeadm:cluster-admins
```

> **Dica para o Coach:** Os alunos devem entender que cada binding `cluster-admin` é um risco potencial de segurança. Em produção, minimize-os. Os bindings de bootstrap do kubeadm são esperados — procure por ServiceAccounts ou Users inesperados com acesso cluster-admin.

---

## Tarefa 6: Audit Logging do Kubernetes

### Passo a passo

> **Importante:** Sempre faça backup do manifesto do API server antes de editar!
> ```bash
> sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/manifests/kube-apiserver.yaml.bak
> ```

**Crie a política de auditoria:**

Salve como `/etc/kubernetes/audit-policy.yaml`:

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  - level: None
    nonResourceURLs:
      - /healthz*
      - /readyz*
      - /livez*

  - level: None
    users:
      - "system:kube-proxy"
    verbs:
      - watch

  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets"]

  - level: RequestResponse
    resources:
      - group: ""
        resources: ["configmaps"]
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
    verbs: ["create", "update", "patch", "delete"]

  - level: Request
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach"]

  - level: Metadata
    omitStages:
      - RequestReceived
```

```bash
sudo tee /etc/kubernetes/audit-policy.yaml <<'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  - level: None
    nonResourceURLs:
      - /healthz*
      - /readyz*
      - /livez*
  - level: None
    users:
      - "system:kube-proxy"
    verbs:
      - watch
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets"]
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["configmaps"]
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
    verbs: ["create", "update", "patch", "delete"]
  - level: Request
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach"]
  - level: Metadata
    omitStages:
      - RequestReceived
EOF
```

**Crie o diretório de logs:**

```bash
sudo mkdir -p /var/log/kubernetes/audit
```

**Edite o kube-apiserver.yaml:**

```bash
sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
```

Adicione em `spec.containers[0].command`:

```yaml
    - --audit-policy-file=/etc/kubernetes/audit-policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit/audit.log
    - --audit-log-maxage=30
    - --audit-log-maxbackup=10
    - --audit-log-maxsize=100
```

Adicione em `spec.containers[0].volumeMounts`:

```yaml
    - mountPath: /etc/kubernetes/audit-policy.yaml
      name: audit-policy
      readOnly: true
    - mountPath: /var/log/kubernetes/audit
      name: audit-log
```

Adicione em `spec.volumes`:

```yaml
  - name: audit-policy
    hostPath:
      path: /etc/kubernetes/audit-policy.yaml
      type: File
  - name: audit-log
    hostPath:
      path: /var/log/kubernetes/audit
      type: DirectoryOrCreate
```

### Verificação — API server reinicia

```bash
# Wait for API server to come back (may take up to 60 seconds)
sleep 30
kubectl get nodes
```

Se o `kubectl` travar, verifique com:

```bash
sudo crictl ps | grep kube-apiserver
```

Esperado: um container kube-apiserver em execução com um horário de início recente.

### Verificação — Logs de auditoria são gerados

Gere alguma atividade:

```bash
kubectl create namespace audit-test
kubectl create secret generic test-secret -n audit-test --from-literal=password=supersecret
kubectl get secrets -n audit-test
kubectl delete namespace audit-test
```

Verifique os logs de auditoria:

```bash
sudo tail -5 /var/log/kubernetes/audit/audit.log | jq .
```

Esperado: entradas JSON como:

```json
{
  "kind": "Event",
  "apiVersion": "audit.k8s.io/v1",
  "level": "Metadata",
  "auditID": "xxxx-xxxx-xxxx",
  "stage": "ResponseComplete",
  "requestURI": "/api/v1/namespaces/audit-test/secrets",
  "verb": "create",
  "user": {
    "username": "kubernetes-admin",
    "groups": ["kubeadm:cluster-admins", "system:authenticated"]
  },
  "objectRef": {
    "resource": "secrets",
    "namespace": "audit-test",
    "name": "test-secret",
    "apiVersion": "v1"
  },
  "responseStatus": {
    "metadata": {},
    "code": 201
  },
  "requestReceivedTimestamp": "2025-01-15T10:30:00.000000Z",
  "stageTimestamp": "2025-01-15T10:30:00.100000Z"
}
```

**Verifique os comportamentos principais da política de auditoria:**

```bash
# Secrets logged at Metadata level (no request/response body)
sudo grep '"resource":"secrets"' /var/log/kubernetes/audit/audit.log | jq '.level' | head -3
```

Esperado: `"Metadata"`

```bash
# Health checks NOT logged
sudo grep 'healthz' /var/log/kubernetes/audit/audit.log | wc -l
```

Esperado: `0`

> **Dica para o Coach:** Se o API server falhar ao iniciar após a edição, as causas mais comuns são:
> 1. Erro de indentação YAML no manifesto do Pod estático
> 2. Volume mount ausente (o container não consegue ver o arquivo de política)
> 3. Erro de sintaxe no YAML da política de auditoria
>
> Recuperação: `sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml`
>
> Para depurar: `sudo journalctl -u kubelet --since "5 minutes ago" | grep -i error`

---

## Tarefa 7: Criptografia de Secrets em Repouso

### Passo a passo

> **Importante:** Faça backup do manifesto do API server primeiro!
> ```bash
> sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/manifests/kube-apiserver.yaml.bak
> ```

**Gere a chave de criptografia:**

```bash
ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)
echo "Encryption key: $ENCRYPTION_KEY"
```

**Crie o EncryptionConfiguration:**

```bash
cat <<EOF | sudo tee /etc/kubernetes/encryption-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${ENCRYPTION_KEY}
      - identity: {}
EOF

sudo chmod 600 /etc/kubernetes/encryption-config.yaml
```

### Verificação — Arquivo de configuração válido

```bash
sudo cat /etc/kubernetes/encryption-config.yaml
```

Esperado:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: <base64-encoded-32-byte-key>
      - identity: {}
```

**Edite o kube-apiserver.yaml:**

Adicione em `spec.containers[0].command`:

```yaml
    - --encryption-provider-config=/etc/kubernetes/encryption-config.yaml
```

Adicione em `spec.containers[0].volumeMounts`:

```yaml
    - mountPath: /etc/kubernetes/encryption-config.yaml
      name: encryption-config
      readOnly: true
```

Adicione em `spec.volumes`:

```yaml
  - name: encryption-config
    hostPath:
      path: /etc/kubernetes/encryption-config.yaml
      type: File
```

**Aguarde o restart do API server:**

```bash
sleep 30
kubectl get nodes
```

### Verificação — Novos Secrets estão criptografados

```bash
kubectl create namespace encryption-test
kubectl create secret generic encrypted-secret -n encryption-test --from-literal=mykey=mydata
```

Leia os dados brutos do etcd:

```bash
sudo ETCDCTL_API=3 etcdctl get /registry/secrets/encryption-test/encrypted-secret \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  | hexdump -C | head -20
```

Esperado: A saída contém `k8s:enc:aescbc:v1:key1:` seguido de dados binários criptografados:

```
00000000  2f 72 65 67 69 73 74 72  79 2f 73 65 63 72 65 74  |/registry/secret|
00000010  73 2f 65 6e 63 72 79 70  74 69 6f 6e 2d 74 65 73  |s/encryption-tes|
00000020  74 2f 65 6e 63 72 79 70  74 65 64 2d 73 65 63 72  |t/encrypted-secr|
00000030  65 74 0a 6b 38 73 3a 65  6e 63 3a 61 65 73 63 62  |et.k8s:enc:aescb|
00000040  63 3a 76 31 3a 6b 65 79  31 3a ...                |c:v1:key1:...|
```

O prefixo `k8s:enc:aescbc:v1:key1:` confirma que a criptografia está ativa.

**Verifique que o Secret ainda é legível via kubectl (descriptografia transparente):**

```bash
kubectl get secret encrypted-secret -n encryption-test -o jsonpath='{.data.mykey}' | base64 -d
```

Esperado: `mydata`

### Re-criptografe Secrets existentes

```bash
kubectl get secrets --all-namespaces -o json | kubectl replace -f -
```

Esperado: Cada Secret é lido (descriptografado) e reescrito (criptografado). Você pode ver `replaced` para cada Secret.

> **Dica para o Coach:** Problemas comuns:
> 1. **API server não inicia:** Verifique `sudo journalctl -u kubelet --since "5 min ago" | grep encrypt` — geralmente um config malformado ou volume mount ausente
> 2. **"invalid key length":** A chave deve ter exatamente 32 bytes (resultado em base64 de `head -c 32 /dev/urandom`)
> 3. **etcdctl não encontrado:** Use `sudo apt install etcd-client` ou execute dentro do Pod etcd:
>    ```bash
>    kubectl exec -n kube-system etcd-<node-name> -- etcdctl \
>      --cacert=/etc/kubernetes/pki/etcd/ca.crt \
>      --cert=/etc/kubernetes/pki/etcd/server.crt \
>      --key=/etc/kubernetes/pki/etcd/server.key \
>      get /registry/secrets/encryption-test/encrypted-secret
>    ```

---

## Tarefa 8: Bloquear Endpoint de Metadata da Cloud

### Passo a passo

Garanta que o namespace `egress-lab` e os Pods de teste da Tarefa 3 existam.

**Aplique a política de bloqueio de metadata:**

Salve `block-metadata.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-cloud-metadata
  namespace: egress-lab
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 169.254.169.254/32
```

```bash
# First, remove the default-deny from Task 3 to test this policy in isolation
kubectl delete networkpolicy default-deny-egress -n egress-lab 2>/dev/null
kubectl delete networkpolicy allow-dns-and-api -n egress-lab 2>/dev/null

kubectl apply -f block-metadata.yaml
```

### Verificação — Metadata bloqueado

```bash
kubectl exec -n egress-lab test-pod -- wget -qO- --timeout=5 http://169.254.169.254/ 2>&1
```

Esperado: timeout ou conexão recusada — o endpoint de metadata está bloqueado.

```bash
kubectl exec -n egress-lab test-pod -- wget -qO- --timeout=5 http://kubernetes.default.svc.cluster.local/healthz 2>&1
```

Esperado: `ok` — o egress geral ainda funciona (exceto para `169.254.169.254`).

> **Dica para o Coach:** Em uma VM não-cloud (VMs locais, bare metal), `169.254.169.254` não é realmente alcançável de qualquer forma. O objetivo de aprendizado é o padrão de NetworkPolicy. Em um ambiente cloud real (AWS, GCP, Azure), esta política previne roubo de credenciais no nível do Pod a partir do serviço de metadata da instância. O teste pode mostrar "connection refused" ou "network unreachable" em vez de um bloqueio limpo — ambos indicam que a política está funcionando.

### Verificação — Detalhes da política

```bash
kubectl describe networkpolicy deny-cloud-metadata -n egress-lab
```

Esperado:

```
Name:         deny-cloud-metadata
Namespace:    egress-lab
...
Spec:
  PodSelector:     <none> (Coverage: all pods in the namespace)
  Allowing egress traffic:
    To Port: <any> (traffic allowed to all ports)
    To:
      IPBlock:
        CIDR: 0.0.0.0/0
        Except: 169.254.169.254/32
  Policy Types: Egress
```

---

## Tarefa 9: Containers Isolados com RuntimeClass

### Passo a passo

**Instale o gVisor em cada node:**

```bash
# Add gVisor repo
curl -fsSL https://gvisor.dev/archive.key | sudo gpg --dearmor -o /usr/share/keyrings/gvisor-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/gvisor-archive-keyring.gpg] https://storage.googleapis.com/gvisor/releases release main" | sudo tee /etc/apt/sources.list.d/gvisor.list > /dev/null
sudo apt-get update && sudo apt-get install -y runsc
```

**Configure o containerd:**

```bash
# Add the runsc runtime handler
cat <<EOF | sudo tee -a /etc/containerd/config.toml

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
EOF

sudo systemctl restart containerd
```

**Crie o RuntimeClass:**

Salve `gvisor-runtimeclass.yaml`:

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
```

```bash
kubectl apply -f gvisor-runtimeclass.yaml
```

**Faça deploy de um Pod isolado (sandboxed):**

Salve `sandboxed-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: sandboxed-pod
  namespace: sandbox-lab
spec:
  runtimeClassName: gvisor
  containers:
    - name: app
      image: nginx:1.27
      ports:
        - containerPort: 80
```

```bash
kubectl create namespace sandbox-lab
kubectl apply -f sandboxed-pod.yaml
```

### Verificação — gVisor em execução

```bash
kubectl exec -n sandbox-lab sandboxed-pod -- dmesg 2>&1 | head -5
```

Esperado: A saída inclui "Starting gVisor..." — este é o kernel user-space do gVisor, não o do host.

```bash
kubectl exec -n sandbox-lab sandboxed-pod -- uname -r
```

Esperado: Uma versão de kernel sintética como `4.4.0` — NÃO a versão do kernel do host.

**Compare com um Pod padrão:**

```bash
kubectl run standard-pod -n sandbox-lab --image=nginx:1.27 --restart=Never
kubectl exec -n sandbox-lab standard-pod -- uname -r
```

Esperado: Retorna o kernel real do host (ex.: `6.8.0-xxx`). A diferença comprova que o sandboxing do gVisor está ativo.

> **Dica para o Coach:** O gVisor adiciona latência às syscalls (elas passam pelo user-space em vez de ir diretamente ao kernel). Este é o tradeoff segurança-performance. Algumas cargas de trabalho (alto I/O, GPU) podem não funcionar bem no gVisor. O exame CKS testa o entendimento de quando e por que usar runtimes isolados (sandboxed), não o tuning profundo do gVisor.

---

## Tarefa 10: Criptografia Pod-to-Pod com Cilium WireGuard

### Passo a passo

**Instale o Cilium CLI:**

```bash
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
```

**Remova o CNI existente e instale o Cilium com WireGuard:**

```bash
# Remove Calico (if installed)
kubectl delete -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.0/manifests/calico.yaml 2>/dev/null

# Wait for Calico pods to terminate
kubectl -n kube-system wait --for=delete pod -l k8s-app=calico-node --timeout=60s 2>/dev/null

# Install Cilium with WireGuard encryption
cilium install --version 1.19.3 \
  --set encryption.enabled=true \
  --set encryption.type=wireguard
```

**Aguarde o Cilium ficar pronto:**

```bash
cilium status --wait
```

### Verificação — Criptografia ativa

```bash
cilium status | grep Encryption
```

Esperado:

```
Encryption:   Wireguard [cilium_wg0 (Pubkey: <key>, Port: 51871, Peers: N)]
```

Onde N = número de outros nodes no cluster.

**Faça deploy da carga de trabalho de teste:**

```bash
kubectl create namespace encryption-test
kubectl run client -n encryption-test --image=busybox:1.36 --restart=Never -- sleep 3600
kubectl run server -n encryption-test --image=nginx:1.27 --restart=Never --labels="app=server"
kubectl expose pod server -n encryption-test --port=80

# Wait for pods to be ready
kubectl wait -n encryption-test --for=condition=Ready pod --all --timeout=60s
```

### Verificação — Tráfego no túnel WireGuard

Em um terminal, capture o tráfego na interface WireGuard:

```bash
kubectl -n kube-system exec -ti ds/cilium -- bash -c "apt-get update -qq && apt-get install -y -qq tcpdump > /dev/null 2>&1 && tcpdump -c 10 -n -i cilium_wg0"
```

Em um segundo terminal, gere tráfego:

```bash
kubectl exec -n encryption-test client -- wget -qO- http://server.encryption-test.svc.cluster.local
```

Esperado: O tcpdump mostra tráfego TCP em `cilium_wg0` — significando que os pacotes estão sendo roteados pelo túnel WireGuard criptografado.

### Verificação — Teste de conectividade

```bash
cilium connectivity test
```

Esperado: Todos os testes passam. O teste de conectividade valida criptografia, network policies e resolução DNS.

> **Dica para o Coach:** O Cilium substitui todo o CNI. Se os alunos tinham NetworkPolicies baseadas em Calico de tarefas anteriores, essas políticas continuam funcionando porque o Cilium também aplica NetworkPolicy. Porém, o motor de enforcement de políticas agora é o Cilium, não o Calico. Para o exame CKS, os alunos devem entender que o Cilium fornece tanto networking CNI QUANTO criptografia — não é apenas um enforcer de NetworkPolicy.

> **Dica para o Coach:** Se o cluster tiver apenas um único node, o WireGuard mostra 0 peers e não há tráfego cross-node para criptografar. Os alunos precisam de um cluster kubeadm multi-node (pelo menos 2 nodes) para ver a criptografia WireGuard em ação. Isso é esperado.

---

## Limpeza

```bash
kubectl delete namespace egress-lab 2>/dev/null
kubectl delete namespace sa-lab 2>/dev/null
kubectl delete namespace encryption-test 2>/dev/null
kubectl delete namespace sandbox-lab 2>/dev/null
kubectl delete runtimeclass gvisor 2>/dev/null
kubectl delete -f tls-demo-app.yaml 2>/dev/null
kubectl delete -f tls-demo-ingress.yaml 2>/dev/null
kubectl delete -f tls-demo-cert.yaml 2>/dev/null
kubectl delete -f self-signed-issuer.yaml 2>/dev/null
kubectl delete job kube-bench 2>/dev/null
```

No node control-plane, opcionalmente reverta as alterações do API server:

```bash
# Only if you want to remove audit logging and encryption for subsequent challenges
sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml
```

> **Dica para o Coach:** Se os alunos forem continuar para o Desafio 20, eles podem querer **manter** as alterações de audit logging e criptografia — são práticas boas para produção. Reverta apenas para um ambiente limpo.
