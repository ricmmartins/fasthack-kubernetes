# Desafio 19 — Cluster Security & Hardening

[< Desafio Anterior](Challenge-18.md) - **[Início](../README.md)** - [Próximo Desafio >](Challenge-20.md)

## Introdução

Em um servidor Linux, hardening de segurança é uma disciplina que você já conhece. Você executa **Lynis** ou **OpenSCAP** para auditar o sistema contra benchmarks CIS e corrigir as descobertas uma por uma. Você bloqueia o SSH com `/etc/ssh/sshd_config` — desabilitando login root, forçando autenticação apenas por chave. Você usa **iptables** ou **firewalld** para restringir quais IPs podem alcançar quais portas. Você audita privilégios com `visudo` e o princípio do menor privilégio. Você criptografa discos com **LUKS/dm-crypt** para que dados em repouso sejam ilegíveis sem a chave. Você configura **auditd** para rastrear quem fez o quê e quando. E antes de confiar em um binário baixado, você verifica seu `sha256sum` contra o checksum do publicador.

Kubernetes tem análogos diretos para cada uma dessas práticas. O exame **Certified Kubernetes Security Specialist (CKS)** testa sua capacidade de aplicá-las em um contexto de cluster. Neste desafio, você vai endurecer um cluster kubeadm de ponta a ponta — desde benchmarking contra padrões CIS e bloqueio do API server, até criptografia de Secrets em repouso e habilitação de audit logging.

| Prática Linux | Equivalente Kubernetes |
|---|---|
| Lynis / OpenSCAP CIS audit | **kube-bench** — CIS Kubernetes Benchmark |
| Nginx + Let's Encrypt TLS certs | **cert-manager** + Ingress TLS termination |
| `iptables -A OUTPUT -d 169.254.169.254 -j DROP` | **NetworkPolicy** bloqueando endpoint de metadata na nuvem |
| `sha256sum` / `gpg --verify` em pacotes baixados | Verificação de checksum SHA256 de binários K8s |
| `visudo` — auditar sudoers, menor privilégio | **RBAC** — auditar ClusterRoleBindings, minimizar permissões |
| Desabilitar login root + usar usuários específicos por serviço | **ServiceAccount hardening** — desabilitar automount, SAs dedicados |
| `iptables` / `firewalld` restringindo acesso SSH | Flags do API server restringindo acesso |
| `auditd` — rastrear chamadas de sistema e ações de usuários | **Kubernetes audit logging** — audit policy + log backend |
| LUKS / dm-crypt criptografia de disco | **EncryptionConfiguration** — criptografia de Secrets em repouso |

> **Requisito de cluster:** Este desafio requer um **cluster kubeadm** (VMs ou bare-metal). Se você completou o Desafio 18, use esse cluster. Caso contrário, configure um cluster kubeadm mínimo com um control-plane e um worker node. Algumas tarefas (NetworkPolicy, RBAC, ServiceAccount) também podem ser praticadas em um cluster Kind, mas kube-bench, audit logging e criptografia em repouso requerem acesso ao control-plane para manifestos de static Pod e flags do API server.
>
> **Limitações do Kind:** As Tarefas 1 (kube-bench), 6 (audit logging) e 7 (criptografia em repouso) requerem acesso direto a `/etc/kubernetes/manifests/kube-apiserver.yaml` e ao filesystem do control-plane node — estas **não podem** ser feitas no Kind.

## Descrição

### Tarefa 1 — CIS Kubernetes Benchmark com kube-bench

No Linux você executaria `lynis audit system` ou `oscap xccdf eval` para verificar seu servidor contra benchmarks CIS. O equivalente Kubernetes é o **kube-bench** da Aqua Security — ele avalia seu cluster contra o CIS Kubernetes Benchmark e reporta PASS/FAIL/WARN para cada controle.

**Passo 1:** Conecte via SSH ao seu node **control-plane** e baixe o kube-bench:

```bash
# Baixe e extraia o kube-bench
curl -L https://github.com/aquasecurity/kube-bench/releases/latest/download/kube-bench_0.10.7_linux_amd64.tar.gz -o kube-bench.tar.gz
tar xzf kube-bench.tar.gz
```

**Passo 2:** Execute o kube-bench no node control-plane (master):

```bash
sudo ./kube-bench run --targets master
```

**Passo 3:** Revise a saída. Você verá resultados organizados por seções CIS:

```
[INFO] 1 Control Plane Security Configuration
[INFO] 1.1 Control Plane Node Configuration Files
[PASS] 1.1.1 Ensure that the API server pod specification file permissions are set to 600 or more restrictive
[FAIL] 1.1.2 Ensure that the API server pod specification file ownership is set to root:root
...
== Summary master ==
42 checks PASS
12 checks FAIL
10 checks WARN
```

**Passo 4:** Escolha as **5 principais descobertas FAIL** da sua saída e corrija-as. Descobertas comuns em um cluster kubeadm recém-criado incluem:

- Permissões de arquivo em `/etc/kubernetes/manifests/*.yaml` sendo muito permissivas
- Flag `--audit-log-path` ausente no API server (você corrigirá isso na Tarefa 6)
- `--encryption-provider-config` ausente (você corrigirá isso na Tarefa 7)
- Porta insegura ou configurações de autenticação anônima
- Admission controllers ausentes

Para cada descoberta, o kube-bench fornece uma seção de **Remediation** — siga suas instruções.

**Passo 5:** Execute o kube-bench no **worker** node também:

```bash
sudo ./kube-bench run --targets node
```

**Passo 6:** Re-execute o kube-bench após suas correções para confirmar a melhoria:

```bash
sudo ./kube-bench run --targets master 2>&1 | tail -5
```

> **Alternativamente**, você pode executar o kube-bench como um Job Kubernetes (útil quando você não pode conectar via SSH diretamente):
> ```bash
> kubectl apply -f https://raw.githubusercontent.com/aquasecurity/kube-bench/main/job.yaml
> kubectl wait --for=condition=complete job/kube-bench --timeout=300s
> kubectl logs job/kube-bench
> ```

### Tarefa 2 — Ingress com TLS Usando cert-manager

No Linux, você configuraria Nginx com Let's Encrypt usando `certbot` para obter e renovar certificados TLS automaticamente. No Kubernetes, o **cert-manager** automatiza o gerenciamento de certificados. Para este laboratório, usaremos um ClusterIssuer auto-assinado (produção usaria Let's Encrypt ou uma CA interna).

**Passo 1:** Instale o cert-manager usando seus manifestos estáticos:

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

# Aguarde o cert-manager ficar pronto
kubectl wait --for=condition=available deployment/cert-manager -n cert-manager --timeout=120s
kubectl wait --for=condition=available deployment/cert-manager-webhook -n cert-manager --timeout=120s
```

**Passo 2:** Crie um ClusterIssuer auto-assinado. Salve como `self-signed-issuer.yaml`:

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
kubectl get clusterissuer selfsigned-issuer
```

**Passo 3:** Crie uma aplicação de teste e um Service. Salve como `tls-demo-app.yaml`:

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

**Passo 4:** Crie um recurso Certificate que diz ao cert-manager para emitir um certificado auto-assinado. Salve como `tls-demo-cert.yaml`:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: tls-demo-cert
  namespace: default
spec:
  secretName: tls-demo-tls
  duration: 2160h    # 90 days
  renewBefore: 360h  # 15 days before expiry
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

**Passo 5:** Verifique se o certificado foi emitido e o Secret TLS foi criado:

```bash
kubectl get certificate tls-demo-cert
kubectl describe certificate tls-demo-cert
kubectl get secret tls-demo-tls
```

O status do certificado deve mostrar `Ready: True`.

**Passo 6:** Crie um Ingress que usa o Secret TLS. Salve como `tls-demo-ingress.yaml`:

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

**Passo 7:** Teste a conectividade TLS (o cert é auto-assinado, então use `-k` para pular a verificação):

```bash
# Se você tem um Ingress controller rodando:
curl -k -H "Host: tls-demo.local" https://localhost

# Ou inspecione os detalhes do certificado:
kubectl get secret tls-demo-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout
```

> **Alternativa (Secret TLS manual):** Se o cert-manager não estiver disponível, você pode criar Secrets TLS manualmente:
> ```bash
> openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
>   -keyout tls.key -out tls.crt \
>   -subj "/CN=tls-demo.local"
> kubectl create secret tls tls-demo-tls --cert=tls.crt --key=tls.key
> ```

### Tarefa 3 — NetworkPolicy de Egress Default-Deny

No Desafio 9, você criou NetworkPolicies para filtragem de **ingress**. Agora você implementará controles de **egress** — o equivalente a regras de firewall de saída. Uma policy de egress default-deny impede que Pods chamem qualquer coisa a menos que explicitamente permitido — como definir a chain padrão `iptables OUTPUT` para `DROP`.

**Passo 1:** Crie um namespace para este exercício:

```bash
kubectl create namespace egress-lab
```

**Passo 2:** Crie uma NetworkPolicy de **egress default-deny**. Salve como `default-deny-egress.yaml`:

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

Isso bloqueia **todo** tráfego de saída de cada Pod no namespace — incluindo consultas DNS.

```bash
kubectl apply -f default-deny-egress.yaml
```

**Passo 3:** Implante um Pod de teste e confirme que o egress está bloqueado:

```bash
kubectl run test-pod --image=busybox --namespace=egress-lab --restart=Never -- sleep 3600
kubectl exec -n egress-lab test-pod -- wget -qO- --timeout=5 http://google.com 2>&1 || echo "Egress blocked as expected"
```

**Passo 4:** Agora crie uma policy que permite **apenas egress DNS** (porta 53 para kube-dns) e egress para um Service específico. Salve como `allow-dns-and-api.yaml`:

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
    # Permitir resolução DNS
    - to:
        - namespaceSelector: {}
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    # Permitir egress para Pods com label app=backend na porta 8080
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

**Passo 5:** Teste a policy — crie um Pod com label e verifique que DNS funciona mas internet geral ainda está bloqueada:

```bash
kubectl run labeled-pod --image=busybox --namespace=egress-lab --labels="role=api-consumer" --restart=Never -- sleep 3600

# DNS deve funcionar agora
kubectl exec -n egress-lab labeled-pod -- nslookup kubernetes.default

# Internet deve continuar bloqueada
kubectl exec -n egress-lab labeled-pod -- wget -qO- --timeout=5 http://google.com 2>&1 || echo "Internet still blocked - correct!"
```

> **Nota:** NetworkPolicies de Egress requerem um plugin CNI que as suporte (Calico, Cilium, Weave). O `kubenet` padrão NÃO aplica NetworkPolicies. Se estiver usando kubeadm, certifique-se de que instalou Calico ou Cilium.

### Tarefa 4 — Verificar Checksums de Binários Kubernetes

No Linux, você executaria `sha256sum` após baixar um pacote para verificar que não foi adulterado — como verificar assinaturas GPG em um RPM ou DEB. Para binários Kubernetes, o projeto publica checksums SHA256 para cada release.

**Passo 1:** Encontre as versões dos seus binários kubectl e kubelet:

```bash
kubectl version --client --output=yaml | grep gitVersion
kubelet --version
```

**Passo 2:** Obtenha o checksum SHA256 do seu binário kubectl da release oficial:

```bash
# Substitua v1.32.0 pela sua versão real
KUBE_VERSION=$(kubectl version --client -o json | grep -oP '"gitVersion": "\K[^"]+')
echo "Verifying kubectl version: $KUBE_VERSION"

# Baixe o checksum oficial
curl -sLO "https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/amd64/kubectl.sha256"

# Calcule o checksum do binário local e compare
echo "$(cat kubectl.sha256)  $(which kubectl)" | sha256sum --check
```

**Passo 3:** Faça o mesmo para o kubelet:

```bash
KUBELET_VERSION=$(kubelet --version | awk '{print $2}')
echo "Verifying kubelet version: $KUBELET_VERSION"

# Baixe o checksum oficial
curl -sLO "https://dl.k8s.io/release/${KUBELET_VERSION}/bin/linux/amd64/kubelet.sha256"

# Calcule e compare
echo "$(cat kubelet.sha256)  $(which kubelet)" | sha256sum --check
```

**Passo 4:** Para o kubeadm:

```bash
KUBEADM_VERSION=$(kubeadm version -o short)
echo "Verifying kubeadm version: $KUBEADM_VERSION"

curl -sLO "https://dl.k8s.io/release/${KUBEADM_VERSION}/bin/linux/amd64/kubeadm.sha256"
echo "$(cat kubeadm.sha256)  $(which kubeadm)" | sha256sum --check
```

Cada comando deve imprimir `OK` se o binário corresponder. Uma incompatibilidade significa que o binário foi adulterado ou corrompido.

> **Por que isso importa no exame CKS:** Um atacante que ganha acesso a um node poderia substituir kubectl ou kubelet por uma versão trojanizada. Verificar checksums é uma prática fundamental de segurança de cadeia de suprimentos.

### Tarefa 5 — Hardening de ServiceAccount

No Linux, você desabilita o login root em `sshd_config`, cria usuários específicos por serviço (`www-data`, `postgres`), e dá a cada um as permissões mínimas necessárias. No Kubernetes, o equivalente é **hardening de ServiceAccount**: desabilitar a montagem automática de token, criar ServiceAccounts dedicados e minimizar suas permissões RBAC.

**Passo 1:** Veja como o ServiceAccount padrão funciona — cada Pod recebe um token montado automaticamente:

```bash
kubectl create namespace sa-lab

# Crie um Pod sem especificar um ServiceAccount
kubectl run default-sa-test --image=busybox --namespace=sa-lab --restart=Never -- sleep 3600

# Verifique o token montado
kubectl exec -n sa-lab default-sa-test -- ls /var/run/secrets/kubernetes.io/serviceaccount/
kubectl exec -n sa-lab default-sa-test -- cat /var/run/secrets/kubernetes.io/serviceaccount/token
```

Esse token concede acesso à API — qualquer comprometimento de container o vaza.

**Passo 2:** Desabilite a montagem automática no ServiceAccount **default**. Isso é como definir `PermitRootLogin no` em `sshd_config`:

```bash
kubectl patch serviceaccount default -n sa-lab \
  -p '{"automountServiceAccountToken": false}'
```

**Passo 3:** Verifique o patch — novos Pods usando o SA default não receberão mais tokens:

```bash
kubectl delete pod default-sa-test -n sa-lab
kubectl run no-token-test --image=busybox --namespace=sa-lab --restart=Never -- sleep 3600

# Isso deve falhar — nenhum token montado
kubectl exec -n sa-lab no-token-test -- ls /var/run/secrets/kubernetes.io/serviceaccount/ 2>&1 || echo "No token mounted - correct!"
```

**Passo 4:** Crie um **ServiceAccount dedicado** com permissões mínimas para uma aplicação que só precisa ler ConfigMaps. Salve como `app-sa.yaml`:

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
```

**Passo 5:** Implante um Pod usando o ServiceAccount dedicado e verifique que ele só pode fazer o que é permitido:

```bash
kubectl create configmap test-config -n sa-lab --from-literal=key1=value1
```

```yaml
# Salve como sa-test-pod.yaml
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
kubectl wait --for=condition=ready pod/sa-test -n sa-lab --timeout=60s

# Isso deve funcionar — ler configmaps é permitido
kubectl exec -n sa-lab sa-test -- kubectl get configmaps -n sa-lab

# Isso deve falhar — listar Secrets NÃO é permitido
kubectl exec -n sa-lab sa-test -- kubectl get secrets -n sa-lab 2>&1 || echo "Access denied - correct!"

# Isso deve falhar — listar Pods NÃO é permitido
kubectl exec -n sa-lab sa-test -- kubectl get pods -n sa-lab 2>&1 || echo "Access denied - correct!"
```

**Passo 6:** Audite ClusterRoleBindings existentes para acesso excessivamente amplo — procure por bindings para `cluster-admin`:

```bash
# Encontre todos os ClusterRoleBindings que referenciam cluster-admin
kubectl get clusterrolebindings -o json | \
  jq -r '.items[] | select(.roleRef.name=="cluster-admin") | .metadata.name + " -> " + (.subjects[]? | .kind + "/" + .name)'
```

### Tarefa 6 — Kubernetes Audit Logging

No Linux, `auditd` registra chamadas de sistema, acesso a arquivos e ações de usuários. O Kubernetes audit logging faz o mesmo para o API server — registrando quem solicitou o quê, quando e a resposta. Isso é essencial para resposta a incidentes e conformidade.

**Passo 1:** Crie um arquivo de audit policy no node **control-plane**. Salve como `/etc/kubernetes/audit-policy.yaml`:

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  # Não registrar requisições somente-leitura para healthz, readyz, livez
  - level: None
    nonResourceURLs:
      - /healthz*
      - /readyz*
      - /livez*

  # Não registrar eventos do grupo system:nodes para evitar ruído
  - level: None
    users:
      - "system:kube-proxy"
    verbs:
      - watch

  # Registrar acesso a Secrets no nível Metadata (não registrar os valores dos Secrets!)
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets"]

  # Registrar alterações em configmap e RBAC no nível RequestResponse
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["configmaps"]
      - group: "rbac.authorization.k8s.io"
        resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
    verbs: ["create", "update", "patch", "delete"]

  # Registrar todos os exec/attach em Pods no nível Request
  - level: Request
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach"]

  # Catch-all — registrar todo o resto no nível Metadata
  - level: Metadata
    omitStages:
      - RequestReceived
```

```bash
sudo cp audit-policy.yaml /etc/kubernetes/audit-policy.yaml
```

**Passo 2:** Crie o diretório de audit log:

```bash
sudo mkdir -p /var/log/kubernetes/audit
```

**Passo 3:** Edite o manifesto de static Pod do API server para habilitar audit logging. Edite `/etc/kubernetes/manifests/kube-apiserver.yaml` e adicione estas flags à seção `command`:

```yaml
    - --audit-policy-file=/etc/kubernetes/audit-policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit/audit.log
    - --audit-log-maxage=30
    - --audit-log-maxbackup=10
    - --audit-log-maxsize=100
```

**Passo 4:** Adicione montagens de volume para que o container do API server possa acessar o arquivo de policy e escrever logs:

```yaml
    volumeMounts:
    # ... montagens existentes ...
    - mountPath: /etc/kubernetes/audit-policy.yaml
      name: audit-policy
      readOnly: true
    - mountPath: /var/log/kubernetes/audit
      name: audit-log
```

```yaml
  volumes:
  # ... volumes existentes ...
  - name: audit-policy
    hostPath:
      path: /etc/kubernetes/audit-policy.yaml
      type: File
  - name: audit-log
    hostPath:
      path: /var/log/kubernetes/audit
      type: DirectoryOrCreate
```

**Passo 5:** Salve o arquivo. O kubelet detectará a mudança e reiniciará o Pod do API server automaticamente. Aguarde ele voltar:

```bash
# Aguarde o API server reiniciar (pode levar 30-60 segundos)
kubectl wait --for=condition=ready pod -l component=kube-apiserver -n kube-system --timeout=120s
```

Se kubectl parar de responder, aguarde — o API server está reiniciando. Verifique com:

```bash
sudo crictl ps | grep kube-apiserver
```

**Passo 6:** Gere alguma atividade na API e verifique se os audit logs estão sendo escritos:

```bash
kubectl create namespace audit-test
kubectl create secret generic test-secret -n audit-test --from-literal=password=supersecret
kubectl get secrets -n audit-test
kubectl delete namespace audit-test

# Verifique o audit log
sudo tail -20 /var/log/kubernetes/audit/audit.log | jq .
```

Você deve ver entradas JSON com campos `verb`, `user`, `resource`, `responseStatus` e `requestReceivedTimestamp`.

### Tarefa 7 — Criptografia de Secrets em Repouso

Por padrão, Kubernetes Secrets são armazenados **codificados em base64 mas não criptografados** no etcd — qualquer pessoa com acesso ao etcd pode lê-los. Isso é como armazenar senhas em texto puro em um filesystem Linux. **EncryptionConfiguration** criptografa Secrets antes de gravar no etcd — o equivalente do LUKS/dm-crypt para criptografia de disco.

**Passo 1:** Gere uma chave de criptografia de 32 bytes:

```bash
ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)
echo "Your encryption key: $ENCRYPTION_KEY"
```

> **Mantenha esta chave segura** — perdê-la significa que você não poderá descriptografar seus Secrets.

**Passo 2:** Crie o arquivo EncryptionConfiguration no node control-plane. Salve como `/etc/kubernetes/encryption-config.yaml`:

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
              secret: <INSERT_YOUR_BASE64_KEY_HERE>
      - identity: {}
```

Substitua `<INSERT_YOUR_BASE64_KEY_HERE>` pela chave do Passo 1.

```bash
# Crie o arquivo com a chave real substituída
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

> **A ordem dos providers importa:** O primeiro provider (`aescbc`) é usado para **criptografar** novos Secrets. O fallback `identity` é usado para **descriptografar** Secrets existentes não criptografados. Sem `identity: {}`, Secrets pré-existentes tornam-se ilegíveis.

**Passo 3:** Edite o manifesto de static Pod do API server `/etc/kubernetes/manifests/kube-apiserver.yaml` para adicionar a flag de criptografia:

```yaml
    - --encryption-provider-config=/etc/kubernetes/encryption-config.yaml
```

Adicione a montagem de volume e o volume:

```yaml
    volumeMounts:
    # ... montagens existentes ...
    - mountPath: /etc/kubernetes/encryption-config.yaml
      name: encryption-config
      readOnly: true
```

```yaml
  volumes:
  # ... volumes existentes ...
  - name: encryption-config
    hostPath:
      path: /etc/kubernetes/encryption-config.yaml
      type: File
```

**Passo 4:** Aguarde o API server reiniciar:

```bash
kubectl wait --for=condition=ready pod -l component=kube-apiserver -n kube-system --timeout=120s
```

**Passo 5:** Crie um novo Secret e verifique se está criptografado no etcd:

```bash
kubectl create namespace encryption-test
kubectl create secret generic encrypted-secret -n encryption-test --from-literal=mykey=mydata
```

**Passo 6:** Leia o Secret diretamente do etcd para confirmar a criptografia:

```bash
# No node control-plane, leia os dados brutos do etcd
sudo ETCDCTL_API=3 etcdctl get /registry/secrets/encryption-test/encrypted-secret \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  | hexdump -C | head -20
```

Você deve ver o prefixo `k8s:enc:aescbc:v1:key1:` seguido de dados criptografados — NÃO texto puro.

**Passo 7:** Re-criptografe todos os Secrets existentes (aqueles criados antes da criptografia ser habilitada):

```bash
kubectl get secrets --all-namespaces -o json | kubectl replace -f -
```

Isso lê cada Secret (descriptografando-o) e grava de volta (criptografando-o com o novo provider).

### Tarefa 8 — Bloquear Endpoint de Metadata na Nuvem com NetworkPolicy

Provedores de nuvem expõem metadata de instância em `169.254.169.254`. Se um atacante comprometer um Pod, ele pode acessar este endpoint para roubar credenciais IAM, tokens de identidade de instância e outros dados sensíveis. No Linux, você bloquearia com `iptables -A OUTPUT -d 169.254.169.254 -j DROP`. No Kubernetes, você usa uma **NetworkPolicy**.

**Passo 1:** Crie um namespace e uma policy de egress default-deny que também bloqueia o endpoint de metadata. Salve como `block-metadata.yaml`:

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
    # Permitir todo egress EXCETO para o endpoint de metadata
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 169.254.169.254/32
```

```bash
kubectl apply -f block-metadata.yaml
```

> **Nota:** Esta policy substitui o default-deny da Tarefa 3 para este namespace. Ela permite todo egress **exceto** para o IP de metadata — um padrão comum em ambientes de nuvem.

**Passo 2:** Teste a policy:

```bash
# Isso deve ser bloqueado (timeout de conexão)
kubectl exec -n egress-lab test-pod -- wget -qO- --timeout=5 http://169.254.169.254/ 2>&1 || echo "Metadata blocked - correct!"

# Egress geral deve continuar funcionando (se DNS estiver disponível)
kubectl exec -n egress-lab test-pod -- wget -qO- --timeout=5 http://kubernetes.default.svc.cluster.local/healthz 2>&1 || echo "Cluster egress works"
```

**Passo 3:** Para segurança extra, combine o bloqueio de metadata com a policy de egress restritiva da Tarefa 3 adicionando a cláusula `except` às regras específicas de egress.

### Tarefa 9 — Containers Isolados com RuntimeClass

No Linux, você usaria `chroot` ou `unshare` para isolar um processo — mas estes compartilham o kernel do host e um único exploit pode escapar do sandbox. **Runtimes de container sandboxed** como [gVisor](https://gvisor.dev/) (runsc) interceptam todas as chamadas de sistema via um kernel em espaço de usuário, fornecendo uma camada adicional de isolamento além de containers padrão. Kubernetes usa o recurso **RuntimeClass** para direcionar Pods específicos a um runtime sandboxed.

> **Domínio CKS:** Minimizar Vulnerabilidades de Microserviços → Entender e implementar técnicas de isolamento (multi-tenancy, containers sandboxed, etc.)

**Passo 1:** Configure o containerd para suportar o handler de runtime gVisor. Em cada node, instale o binário `runsc` do gVisor:

```bash
# Adicione o repositório do gVisor
curl -fsSL https://gvisor.dev/archive.key | sudo gpg --dearmor -o /usr/share/keyrings/gvisor-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/gvisor-archive-keyring.gpg] https://storage.googleapis.com/gvisor/releases release main" | sudo tee /etc/apt/sources.list.d/gvisor.list > /dev/null
sudo apt-get update && sudo apt-get install -y runsc
```

**Passo 2:** Adicione o handler `runsc` à configuração do containerd (`/etc/containerd/config.toml`):

```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
```

Depois reinicie o containerd:

```bash
sudo systemctl restart containerd
```

**Passo 3:** Crie um recurso RuntimeClass que referencia o handler `runsc`:

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

**Passo 4:** Implante um Pod que usa o runtime sandboxed:

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

**Passo 5:** Verifique se o Pod está rodando dentro do gVisor checando o kernel:

```bash
kubectl exec -n sandbox-lab sandboxed-pod -- dmesg | head -5
kubectl exec -n sandbox-lab sandboxed-pod -- uname -r
```

> No gVisor, a saída do `dmesg` mostra "Starting gVisor..." e `uname -r` retorna uma string de versão de kernel específica do gVisor (ex: `4.4.0`), não o kernel do host.

**Passo 6:** Compare com um Pod padrão para ver a diferença de isolamento:

```bash
kubectl run standard-pod -n sandbox-lab --image=nginx:1.27 --restart=Never
kubectl exec -n sandbox-lab standard-pod -- uname -r
```

> O Pod padrão retorna a versão real do kernel do host. O Pod gVisor retorna uma versão sintética — prova de sandboxing.

### Tarefa 10 — Criptografia Pod-to-Pod com Cilium WireGuard

No Linux, você configuraria túneis WireGuard ou IPsec entre hosts para criptografar tráfego. No Kubernetes, o **Cilium** pode criptografar transparentemente todo o tráfego pod-to-pod entre nodes usando WireGuard — sem mudanças na aplicação, sem sidecar proxies, sem modificações no código. Cada node cria um par de chaves WireGuard e distribui chaves públicas via CRDs CiliumNode.

> **Domínio CKS:** Minimizar Vulnerabilidades de Microserviços → Implementar criptografia Pod-to-Pod (Cilium, Istio)

**Passo 1:** Instale o Cilium CLI (se ainda não estiver instalado):

```bash
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
```

**Passo 2:** Instale o Cilium como CNI com criptografia WireGuard habilitada:

> ⚠️ **Importante:** Cilium substitui o CNI existente (ex: Calico). Você deve remover o CNI atual primeiro. Faça isso apenas em um cluster de teste dedicado.

```bash
# Remova o CNI existente (ex: Calico)
kubectl delete -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.0/manifests/calico.yaml 2>/dev/null

# Instale Cilium com criptografia WireGuard
cilium install --version 1.19.3 \
  --set encryption.enabled=true \
  --set encryption.type=wireguard
```

**Passo 3:** Aguarde o Cilium ficar pronto e verifique o status da criptografia:

```bash
cilium status --wait

# Verifique se a criptografia está ativa
cilium status | grep Encryption
```

Saída esperada:

```
Encryption:   Wireguard [cilium_wg0 (Pubkey: <key>, Port: 51871, Peers: N)]
```

**Passo 4:** Implante uma carga de trabalho de teste entre nodes e verifique se o tráfego está criptografado:

```bash
kubectl create namespace encryption-test
kubectl run client -n encryption-test --image=busybox:1.36 --restart=Never -- sleep 3600
kubectl run server -n encryption-test --image=nginx:1.27 --restart=Never --labels="app=server"
kubectl expose pod server -n encryption-test --port=80
```

**Passo 5:** Verifique se o tráfego flui pelo túnel WireGuard:

```bash
# De dentro de um pod do agente Cilium, capture tráfego na interface WireGuard
kubectl -n kube-system exec -ti ds/cilium -- bash -c "apt-get update -qq && apt-get install -y -qq tcpdump > /dev/null 2>&1 && tcpdump -c 10 -n -i cilium_wg0"
```

Em um segundo terminal, gere tráfego:

```bash
kubectl exec -n encryption-test client -- wget -qO- http://server.encryption-test.svc.cluster.local
```

> Se pacotes aparecem em `cilium_wg0`, o tráfego está criptografado via WireGuard. Pacotes em `eth0` entre nodes são pacotes UDP WireGuard criptografados na porta 51871.

**Passo 6:** Execute o teste de conectividade integrado do Cilium para validar a criptografia de ponta a ponta:

```bash
cilium connectivity test
```

### Limpe

```bash
kubectl delete namespace egress-lab 2>/dev/null
kubectl delete namespace sa-lab 2>/dev/null
kubectl delete namespace encryption-test 2>/dev/null
kubectl delete namespace sandbox-lab 2>/dev/null
kubectl delete namespace encryption-test 2>/dev/null
kubectl delete runtimeclass gvisor 2>/dev/null
kubectl delete -f tls-demo-app.yaml 2>/dev/null
kubectl delete -f tls-demo-ingress.yaml 2>/dev/null
kubectl delete -f tls-demo-cert.yaml 2>/dev/null
kubectl delete -f self-signed-issuer.yaml 2>/dev/null
kubectl delete job kube-bench 2>/dev/null
```

## Critérios de Sucesso

- [ ] Você executou o kube-bench nos nodes control-plane e worker, identificou descobertas FAIL e corrigiu pelo menos 5.
- [ ] Re-executar o kube-bench mostra menos FAILs que a execução inicial.
- [ ] Você instalou o cert-manager, criou um ClusterIssuer auto-assinado e emitiu um certificado TLS.
- [ ] O Secret TLS (`tls-demo-tls`) contém dados válidos de certificado e chave.
- [ ] Um recurso Ingress referencia o Secret TLS e termina TLS.
- [ ] Você criou uma NetworkPolicy de egress default-deny e verificou que Pods não conseguem alcançar a internet.
- [ ] Você criou uma policy de egress seletiva permitindo apenas DNS e backends específicos.
- [ ] Você verificou checksums SHA256 de kubectl, kubelet e kubeadm contra checksums oficiais da release.
- [ ] Você desabilitou automountServiceAccountToken no SA default e confirmou que Pods não recebem mais tokens.
- [ ] Você criou um ServiceAccount dedicado com um Role limitado a ler ConfigMaps e provou que ele não pode acessar Secrets ou Pods.
- [ ] Você consegue identificar ClusterRoleBindings com privilégios excessivos (ex: bindings para `cluster-admin`).
- [ ] Kubernetes audit logging está habilitado — você pode ver eventos de auditoria JSON em `/var/log/kubernetes/audit/audit.log`.
- [ ] A audit policy usa níveis apropriados (None para health checks, Metadata para Secrets, RequestResponse para mudanças RBAC).
- [ ] Criptografia de Secrets em repouso está configurada com provider `aescbc`.
- [ ] Leituras brutas do etcd mostram o prefixo `k8s:enc:aescbc:v1:key1:`, confirmando a criptografia.
- [ ] Você re-criptografou todos os Secrets existentes com `kubectl get secrets --all-namespaces -o json | kubectl replace -f -`.
- [ ] Uma NetworkPolicy bloqueia egress para `169.254.169.254/32` (endpoint de metadata na nuvem).
- [ ] Você criou uma RuntimeClass para gVisor (handler `runsc`) e implantou um Pod usando `runtimeClassName: gvisor`.
- [ ] Dentro do Pod gVisor, `dmesg` ou `uname -r` confirma o kernel sandboxed (não o kernel do host).
- [ ] Você instalou Cilium com criptografia WireGuard habilitada (`encryption.enabled=true`, `encryption.type=wireguard`).
- [ ] `cilium status | grep Encryption` mostra WireGuard ativo com peers.
- [ ] Tráfego pod-to-pod entre nodes flui pelo dispositivo de túnel `cilium_wg0` (verificado via tcpdump).

## Referência Rápida Linux ↔ Kubernetes

| Conceito Linux | Equivalente Kubernetes | Notas |
|---|---|---|
| `lynis audit system` / OpenSCAP | `kube-bench run --targets master` | Auditoria CIS benchmark para nodes K8s |
| Nginx + `certbot` + Let's Encrypt | cert-manager + ClusterIssuer + Certificate CRD | Gerenciamento automatizado do ciclo de vida TLS |
| `openssl req -x509 -newkey` (auto-assinado) | `kubectl create secret tls` (manual) ou cert-manager self-signed issuer | TLS manual vs. automatizado |
| `iptables -P OUTPUT DROP` | NetworkPolicy com `policyTypes: [Egress]` e `egress` vazio | Default-deny de saída |
| `iptables -A OUTPUT -d X -j ACCEPT` | Regra `egress` de NetworkPolicy com `to` e `ports` | Whitelist de egress específico |
| `iptables -A OUTPUT -d 169.254.169.254 -j DROP` | NetworkPolicy com `ipBlock.except: [169.254.169.254/32]` | Bloquear metadata na nuvem |
| `sha256sum --check file.sha256` | `sha256sum --check` em binários kubectl/kubelet/kubeadm | Verificação de cadeia de suprimentos |
| `/etc/ssh/sshd_config: PermitRootLogin no` | `automountServiceAccountToken: false` no SA default | Desabilitar credenciais padrão |
| Criar usuários `www-data`, `postgres` com permissões limitadas | ServiceAccount dedicado + Role + RoleBinding | Menor privilégio por carga de trabalho |
| `visudo` — auditar sudoers | `kubectl get clusterrolebindings` — auditar bindings cluster-admin | Auditoria de privilégios |
| `/etc/audit/auditd.conf` + regras de auditoria | `--audit-policy-file` + `--audit-log-path` no API server | Quem fez o quê, quando |
| `auditctl -w /etc/shadow -p rwa` | Regra de audit policy: `level: Metadata` para Secrets | Monitorar acesso a recursos sensíveis |
| LUKS / dm-crypt criptografia de disco | EncryptionConfiguration com provider `aescbc` | Secrets criptografados antes de gravar no etcd |
| `cryptsetup luksFormat /dev/sda1` | `--encryption-provider-config` no API server | Habilitar criptografia em repouso |
| `chroot` / `unshare --mount --pid` | RuntimeClass + gVisor (`runsc`) | Isolamento de processo sandboxed no nível do kernel |
| Túneis WireGuard / IPsec entre hosts | Criptografia transparente Cilium WireGuard | Tráfego pod-to-pod criptografado sem mudanças na aplicação |

## Dicas

<details>
<summary>Dica 1: kube-bench falha ao executar ou mostra "unable to determine benchmark version"</summary>

O kube-bench auto-detecta sua versão do Kubernetes e a mapeia para uma versão de benchmark CIS. Se a detecção falhar:

```bash
# Especifique o benchmark manualmente
sudo ./kube-bench run --targets master --benchmark cis-2.0
```

Se estiver executando como Job e os Pods não conseguem montar host paths, use a abordagem de container:

```bash
# Execute no node diretamente
sudo docker run --rm --pid=host \
  -v /etc:/etc:ro -v /var:/var:ro \
  aquasec/kube-bench:latest run --targets master
```

</details>

<details>
<summary>Dica 2: Certificate do cert-manager permanece "Not Ready"</summary>

Verifique os logs do cert-manager para erros:

```bash
kubectl logs -n cert-manager -l app.kubernetes.io/name=cert-manager
kubectl describe certificate tls-demo-cert
kubectl get certificaterequests -o wide
```

Problemas comuns:
- O nome do ClusterIssuer no Certificate não corresponde: `issuerRef.name` deve ser exatamente `selfsigned-issuer`
- O webhook do cert-manager ainda não está pronto — aguarde um minuto e tente novamente
- CRDs não estão instalados — verifique `kubectl get crds | grep cert-manager`

</details>

<details>
<summary>Dica 3: Egress default-deny bloqueia DNS também</summary>

Quando você aplica uma policy de egress default-deny, ela bloqueia **tudo** — incluindo DNS (porta 53). Pods não conseguirão resolver nenhum hostname.

Para permitir DNS enquanto ainda bloqueia outro egress:

```yaml
egress:
  - to:
      - namespaceSelector: {}
    ports:
      - protocol: UDP
        port: 53
      - protocol: TCP
        port: 53
```

Isso permite DNS para o kube-dns em qualquer namespace. Sem isso, até mesmo `nslookup` dentro do Pod terá timeout.

</details>

<details>
<summary>Dica 4: API server não inicia após editar o manifesto de static Pod</summary>

Causas comuns:
- **Erro de sintaxe YAML** — Valide com `python3 -c "import yaml; yaml.safe_load(open('/etc/kubernetes/manifests/kube-apiserver.yaml'))"`
- **Caminho de volume mount errado** — O `mountPath` deve corresponder exatamente ao que a flag referencia
- **Arquivo não existe** — Certifique-se de que o arquivo de audit policy ou encryption config realmente existe no hostPath
- **Permissões de arquivo** — O arquivo deve ser legível pelo processo do apiserver

Verifique os logs do kubelet para detalhes do erro:

```bash
sudo journalctl -u kubelet --since "5 minutes ago" | grep -i apiserver
sudo crictl ps -a | grep kube-apiserver
sudo crictl logs <container-id>
```

**Recuperação de emergência:** Se o API server estiver travado, reverta suas alterações no manifesto de static Pod:

```bash
sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml
```

Sempre faça um backup **antes** de editar: `sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml{,.bak}`

</details>

<details>
<summary>Dica 5: etcdctl não encontrado ou "permission denied"</summary>

Em clusters kubeadm, etcdctl pode não estar instalado no host. Use o Pod do etcd:

```bash
kubectl exec -n kube-system etcd-<node-name> -- etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/encryption-test/encrypted-secret | hexdump -C | head
```

Ou instale etcdctl no host:

```bash
sudo apt-get install -y etcd-client
```

</details>

<details>
<summary>Dica 6: Token do ServiceAccount ainda montado após desabilitar automount</summary>

A configuração `automountServiceAccountToken: false` em um ServiceAccount afeta apenas Pods **recém-criados**. Pods existentes mantêm seus tokens até serem recriados.

Observe também a precedência de override:
1. `automountServiceAccountToken` no nível do Pod sobrescreve a configuração do ServiceAccount
2. Se o spec do Pod define explicitamente `automountServiceAccountToken: true`, ele monta independentemente da configuração do SA

Verifique ambos os níveis:

```bash
kubectl get sa default -n sa-lab -o yaml | grep automount
kubectl get pod <name> -n sa-lab -o yaml | grep automount
```

</details>

<details>
<summary>Dica 7: Problemas de formato da chave de criptografia</summary>

A chave de criptografia deve ter exatamente 32 bytes, codificada em base64. Erros comuns:

```bash
# ERRADO — isso gera uma string aleatória, não 32 bytes brutos
echo "mysecretkey" | base64

# CORRETO — 32 bytes aleatórios, depois codificados em base64
head -c 32 /dev/urandom | base64
```

Se o API server falhar ao iniciar após adicionar a configuração de criptografia, verifique os logs:

```bash
sudo journalctl -u kubelet --since "2 minutes ago" | grep -i encrypt
```

Procure por mensagens "invalid key length" ou "failed to parse encryption config".

</details>

<details>
<summary>Dica 8: NetworkPolicy não parece bloquear endpoint de metadata</summary>

NetworkPolicies requerem um plugin CNI que as aplique. Verifique seu CNI:

```bash
kubectl get pods -n kube-system | grep -E "calico|cilium|weave"
```

Se você está usando `flannel` ou `kubenet` padrão, NetworkPolicies são aceitas pela API mas **não aplicadas**. Instale Calico:

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.0/manifests/calico.yaml
```

Além disso, teste de dentro de um Pod **dentro** do cluster, não a partir do node. A NetworkPolicy só afeta tráfego de Pods.

</details>

<details>
<summary>Dica 9: Pod gVisor preso em ContainerCreating ou CrashLoopBackOff</summary>

Causas comuns:
- **runsc não instalado no node** — Verifique com `which runsc` no node
- **containerd não reiniciado** — Após editar `/etc/containerd/config.toml`, você deve executar `sudo systemctl restart containerd`
- **Nome do handler não corresponde** — O campo `handler` do RuntimeClass deve corresponder exatamente à chave `[runtimes.NAME]` na configuração do containerd
- **Clusters multi-node** — runsc e a configuração do containerd devem ser configurados em **cada node** que possa escalonar Pods gVisor

Verifique os eventos do Pod preso:

```bash
kubectl describe pod sandboxed-pod -n sandbox-lab
sudo journalctl -u containerd --since "5 minutes ago" | grep runsc
```

Se apenas alguns nodes têm gVisor, adicione `scheduling.nodeSelector` ao RuntimeClass para restringir Pods a esses nodes.

</details>

<details>
<summary>Dica 10: Cilium WireGuard mostra 0 peers ou criptografia não ativa</summary>

Causas comuns:
- **Módulo de kernel WireGuard não carregado** — Verifique: `lsmod | grep wireguard`. No Ubuntu 20.04+, WireGuard está integrado ao kernel (5.6+). Em kernels mais antigos: `sudo apt install wireguard`
- **Cluster de node único** — WireGuard só criptografa tráfego entre nodes. Você precisa de pelo menos 2 worker nodes
- **Cilium não totalmente pronto** — Execute `cilium status --wait` e verifique se todos os componentes estão OK
- **Firewall bloqueando UDP 51871** — WireGuard usa porta UDP 51871 entre nodes

Comandos de debug:

```bash
cilium status | grep Encryption
kubectl -n kube-system exec ds/cilium -- cilium-dbg debuginfo --output json | jq .encryption
```

</details>

## Recursos de Aprendizado

- [CIS Kubernetes Benchmark (kube-bench)](https://github.com/aquasecurity/kube-bench)
- [Kubernetes — Encrypting Confidential Data at Rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)
- [Kubernetes — Auditing](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/)
- [Kubernetes — Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [cert-manager Documentation](https://cert-manager.io/docs/)
- [Kubernetes — RBAC Authorization](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
- [Kubernetes — Configure Service Accounts for Pods](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/)
- [Kubernetes — Verify Signed Kubernetes Artifacts](https://kubernetes.io/docs/tasks/administer-cluster/verify-signed-artifacts/)
- [CKS Curriculum](https://github.com/cncf/curriculum)
- [Kubernetes — Restrict Access to Kubernetes API](https://kubernetes.io/docs/concepts/security/controlling-access/)
- [Kubernetes — RuntimeClass](https://kubernetes.io/docs/concepts/containers/runtime-class/)
- [gVisor — Kubernetes Quick Start](https://gvisor.dev/docs/user_guide/quick_start/kubernetes/)
- [Cilium — Transparent Encryption](https://docs.cilium.io/en/stable/security/network/encryption/)
- [Cilium — WireGuard Encryption](https://docs.cilium.io/en/stable/security/network/encryption-wireguard/)

## Quebra & Conserta 🔧

Tente cada cenário, diagnostique o problema e corrija-o.

### Cenário 1 — Audit logs estão vazios após habilitar audit logging

Aplique estas alterações no API server (no node control-plane, edite `/etc/kubernetes/manifests/kube-apiserver.yaml`):

```yaml
    - --audit-policy-file=/etc/kubernetes/audit-policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit/audit.log
```

Mas "esqueça" de adicionar as montagens de volume:

```bash
# Após o API server reiniciar, verifique os logs
sudo tail /var/log/kubernetes/audit/audit.log
```

**O que você verá:** O Pod do API server continua reiniciando (CrashLoopBackOff) ou o arquivo de audit log não existe.

**Diagnostique:**

```bash
sudo crictl ps -a | grep kube-apiserver
sudo crictl logs <container-id> 2>&1 | grep audit
sudo journalctl -u kubelet --since "5 minutes ago" | grep -i error
```

**Causa raiz:** O container do API server não consegue acessar `/etc/kubernetes/audit-policy.yaml` ou escrever em `/var/log/kubernetes/audit/` porque as entradas de **volume e volumeMount** estão faltando. O container tem seu próprio filesystem — ele só vê caminhos do host que são explicitamente montados.

**Correção:** Adicione os volumes e volumeMounts como mostrado na Tarefa 6, Passos 3–4.

**Analogia com Linux:** Como configurar `auditd` para escrever em `/var/log/audit/audit.log` mas esquecer de criar o diretório ou definir permissões — auditd não iniciará.

---

### Cenário 2 — Novos Secrets não estão criptografados apesar da EncryptionConfiguration

A configuração de criptografia existe e é referenciada pelo API server, mas novos Secrets ainda aparecem como texto puro no etcd:

```yaml
# /etc/kubernetes/encryption-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - identity: {}
      - aescbc:
          keys:
            - name: key1
              secret: dGhpcyBpcyBhIHRlc3Qga2V5MTIzNDU2Nzg5MDEyMzQ=
```

```bash
kubectl create secret generic broken-secret -n default --from-literal=data=sensitive
sudo ETCDCTL_API=3 etcdctl get /registry/secrets/default/broken-secret \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
```

**O que você verá:** Os dados brutos do etcd mostram texto puro — sem prefixo `k8s:enc:aescbc:`.

**Diagnostique:** Observe a ordem dos providers na EncryptionConfiguration.

**Causa raiz:** O provider `identity: {}` está listado **primeiro**. Kubernetes usa o **primeiro provider** para criptografia. Como `identity` significa "sem criptografia", Secrets são armazenados em texto puro. O provider `aescbc` é usado apenas como fallback de descriptografia.

**Correção:** Troque a ordem dos providers — `aescbc` deve vir primeiro:

```yaml
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: dGhpcyBpcyBhIHRlc3Qga2V5MTIzNDU2Nzg5MDEyMzQ=
      - identity: {}
```

Reinicie o API server e recrie o Secret. Depois re-criptografe os Secrets existentes:

```bash
kubectl get secrets --all-namespaces -o json | kubectl replace -f -
```

**Analogia com Linux:** Como configurar dm-crypt mas montar a partição não criptografada primeiro em `/etc/fstab` — a partição criptografada existe mas nunca é usada.

---

### Cenário 3 — Pod ainda consegue alcançar o endpoint de metadata apesar da NetworkPolicy

Aplique esta NetworkPolicy:

```yaml
# Salve como broken-metadata-policy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: block-metadata-broken
  namespace: egress-lab
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 169.254.169.254/32
```

```bash
kubectl apply -f broken-metadata-policy.yaml
kubectl exec -n egress-lab test-pod -- wget -qO- --timeout=5 http://169.254.169.254/latest/meta-data/ 2>&1
```

**O que você verá:** O endpoint de metadata ainda está acessível.

**Diagnostique:**

```bash
kubectl get networkpolicy block-metadata-broken -n egress-lab -o yaml
```

**Causa raiz:** A policy restringe **Ingress** (tráfego de entrada), não **Egress** (tráfego de saída). O endpoint de metadata é uma chamada de **saída** do Pod. Policies de Ingress controlam quem pode falar **para** o Pod, não para onde o Pod pode chamar.

**Correção:** Altere `policyTypes` para `Egress` e use regras `egress` ao invés de `ingress`:

```yaml
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

**Analogia com Linux:** Como adicionar uma regra na chain `INPUT` do iptables quando você queria adicionar na `OUTPUT` — bloquear conexões de entrada do IP de metadata não impede seu servidor de acessá-lo.

---

### Cenário 4 — Token do ServiceAccount ainda montado apesar de `automountServiceAccountToken: false`

Aplique este Pod:

```yaml
# Salve como broken-sa-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: broken-sa-pod
  namespace: sa-lab
spec:
  serviceAccountName: configmap-reader
  automountServiceAccountToken: true
  containers:
    - name: test
      image: busybox
      command: ["sleep", "3600"]
      resources:
        requests:
          cpu: 50m
          memory: 32Mi
```

Mesmo que o ServiceAccount tenha `automountServiceAccountToken: false`, verifique o Pod:

```bash
kubectl apply -f broken-sa-pod.yaml
kubectl exec -n sa-lab broken-sa-pod -- ls /var/run/secrets/kubernetes.io/serviceaccount/
```

**O que você verá:** O token está montado!

**Causa raiz:** O spec do Pod tem `automountServiceAccountToken: true`, que **sobrescreve** a configuração do ServiceAccount. Configurações no nível do Pod sempre vencem.

**Correção:** Remova o override no nível do Pod ou defina-o como `false`:

```bash
kubectl delete pod broken-sa-pod -n sa-lab
# Edite o YAML para remover automountServiceAccountToken: true, depois re-aplique
```

**Analogia com Linux:** Como definir `PermitRootLogin no` em `sshd_config` mas depois adicionar `Match User root` com `PermitRootLogin yes` — o override específico vence.
