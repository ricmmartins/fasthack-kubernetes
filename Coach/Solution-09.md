# Solução 09 — RBAC e Segurança

[< Voltar para o Desafio](../Student/Challenge-09.md) | **[Home](README.md)**

## Notas para os Coaches

Este é um dos desafios conceitualmente mais densos. A analogia com Linux funciona muito bem aqui — apoie-se nela. A mensagem-chave: RBAC são apenas usuários, grupos e permissões com nomes diferentes; PSA são níveis de enforcement do SELinux.

**Importante:** PodSecurityPolicy (PSP) foi **removida** no Kubernetes v1.25. Se os alunos mencionarem PSP, redirecione-os para Pod Security Admission (PSA). User Namespaces estão GA no v1.36 mas não são necessários para este desafio.

Tempo estimado: **60 minutos**

---

## Tarefa 1: Criar uma ServiceAccount

### Passo a passo

```bash
kubectl create namespace secure-ns
kubectl create serviceaccount app-reader -n secure-ns
```

Salve `reader-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: reader-pod
  namespace: secure-ns
spec:
  serviceAccountName: app-reader
  containers:
  - name: kubectl-shell
    image: bitnami/kubectl:latest
    command: ["sleep", "3600"]
```

```bash
kubectl apply -f reader-pod.yaml
kubectl wait --for=condition=Ready pod/reader-pod -n secure-ns --timeout=120s
```

### Verificação

```bash
kubectl get pod reader-pod -n secure-ns -o jsonpath='{.spec.serviceAccountName}'
```

Saída esperada:

```
app-reader
```

Verifique se o token projetado está montado:

```bash
kubectl exec -n secure-ns reader-pod -- ls /var/run/secrets/kubernetes.io/serviceaccount/
```

Saída esperada:

```
ca.crt
namespace
token
```

> **Dica do Coach:** Explique que desde o Kubernetes v1.24, o token neste caminho é um token projetado **vinculado e com tempo limitado** — não um secret estático de longa duração como em versões anteriores. O kubelet o rotaciona automaticamente.

---

## Tarefa 2: Criar uma Role e RoleBinding (Escopo de Namespace)

### Passo a passo

Salve `pod-reader-role.yaml`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: secure-ns
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
```

Salve `pod-reader-binding.yaml`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: read-pods-binding
  namespace: secure-ns
subjects:
- kind: ServiceAccount
  name: app-reader
  namespace: secure-ns
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f pod-reader-role.yaml
kubectl apply -f pod-reader-binding.yaml
```

### Verificação

**Teste: listar Pods (deve ter sucesso):**

```bash
kubectl exec -n secure-ns reader-pod -- kubectl get pods -n secure-ns
```

Saída esperada:

```
NAME         READY   STATUS    RESTARTS   AGE
reader-pod   1/1     Running   0          ...
```

**Teste: listar Secrets (deve FALHAR):**

```bash
kubectl exec -n secure-ns reader-pod -- kubectl get secrets -n secure-ns
```

Saída esperada:

```
Error from server (Forbidden): secrets is forbidden: User "system:serviceaccount:secure-ns:app-reader" cannot list resource "secrets" in API group "" in the namespace "secure-ns"
```

> **Dica do Coach:** O `apiGroups: [""]` refere-se ao grupo de API **core** (Pods, Services, Secrets, ConfigMaps). Deployments estão no grupo `apps`. Se um aluno esquecer de incluir o apiGroup correto, a regra não corresponderá.

---

## Tarefa 3: Criar um ClusterRole e ClusterRoleBinding (Escopo de Cluster)

### Passo a passo

Salve `node-viewer-clusterrole.yaml`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: node-viewer
rules:
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list"]
```

Salve `node-viewer-binding.yaml`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: view-nodes-binding
subjects:
- kind: ServiceAccount
  name: app-reader
  namespace: secure-ns
roleRef:
  kind: ClusterRole
  name: node-viewer
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f node-viewer-clusterrole.yaml
kubectl apply -f node-viewer-binding.yaml
```

### Verificação

```bash
kubectl exec -n secure-ns reader-pod -- kubectl get nodes
```

Saída esperada:

```
NAME                     STATUS   ROLES           AGE   VERSION
fasthack-control-plane   Ready    control-plane   ...   v1.36.x
```

> **Dica do Coach:** Enfatize a diferença: uma **Role + RoleBinding** concede permissões em um único namespace (como permissões de arquivo por diretório). Um **ClusterRole + ClusterRoleBinding** concede permissões em todo o cluster (como acesso root). Nodes são um recurso com escopo de cluster — eles não existem em nenhum namespace — então você deve usar um ClusterRole.

---

## Tarefa 4: Verificar Permissões com `kubectl auth can-i`

### Passo a passo

```bash
# Deve ser: yes
kubectl auth can-i list pods -n secure-ns \
  --as=system:serviceaccount:secure-ns:app-reader

# Deve ser: no
kubectl auth can-i delete pods -n secure-ns \
  --as=system:serviceaccount:secure-ns:app-reader

# Deve ser: yes (do ClusterRoleBinding)
kubectl auth can-i list nodes \
  --as=system:serviceaccount:secure-ns:app-reader

# Deve ser: no
kubectl auth can-i list secrets -n secure-ns \
  --as=system:serviceaccount:secure-ns:app-reader
```

### Verificação

Saídas esperadas em ordem:

```
yes
no
yes
no
```

**Liste TODAS as permissões para a ServiceAccount:**

```bash
kubectl auth can-i --list -n secure-ns \
  --as=system:serviceaccount:secure-ns:app-reader
```

Esperado: uma tabela mostrando os verbos e recursos permitidos, incluindo `get`, `list`, `watch` em `pods` no `secure-ns` e `get`, `list` em `nodes` em todo o cluster.

> **Dica do Coach:** `kubectl auth can-i` é o equivalente Kubernetes do `sudo -l`. É a primeira ferramenta a usar ao debugar erros "Forbidden".

---

## Tarefa 5: Labels de Pod Security Admission (PSA)

### Passo a passo

**5a — Crie namespace com enforcement `restricted`:**

```bash
kubectl create namespace psa-restricted
kubectl label namespace psa-restricted \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted
```

**5b — Tente fazer deploy de um Pod privilegiado (deve ser REJEITADO):**

Salve `privileged-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: bad-pod
  namespace: psa-restricted
spec:
  containers:
  - name: shell
    image: busybox:1.37
    command: ["sleep", "3600"]
    securityContext:
      privileged: true
```

```bash
kubectl apply -f privileged-pod.yaml
```

### Verificação

Saída de erro esperada:

```
Error from server (Forbidden): error when creating "privileged-pod.yaml": pods "bad-pod" is forbidden: violates PodSecurity "restricted:latest": privileged (container "shell" must not set securityContext.privileged=true), ...
```

**5c — Crie um namespace `baseline` com warnings `restricted`:**

```bash
kubectl create namespace psa-baseline
kubectl label namespace psa-baseline \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/warn=restricted
```

**5d — Faça deploy de um Pod não privilegiado no namespace baseline (deve ter sucesso com warnings):**

```bash
kubectl run test-baseline --image=busybox:1.37 -n psa-baseline -- sleep 3600
```

Esperado: o Pod é criado, mas você verá **warnings** (não erros) sobre violações do restricted. Algo como:

```
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "test-baseline" must set securityContext.allowPrivilegeEscalation=false), ...
```

> **Dica do Coach:** Este é o padrão de adoção progressiva — `enforce=baseline` bloqueia os piores ofensores, enquanto `warn=restricted` mostra aos alunos o que ainda precisam corrigir para conformidade total. Isso é análogo a executar o SELinux em modo permissivo para coletar violações antes de mudar para enforcing.

---

## Tarefa 6: SecurityContext (Pod Hardened)

### Passo a passo

Salve `hardened-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hardened-pod
  namespace: psa-restricted
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: app
    image: busybox:1.37
    command: ["sleep", "3600"]
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop:
          - ALL
```

```bash
kubectl apply -f hardened-pod.yaml
kubectl wait --for=condition=Ready pod/hardened-pod -n psa-restricted --timeout=60s
```

### Verificação

**Verifique o UID:**

```bash
kubectl exec -n psa-restricted hardened-pod -- id
```

Saída esperada:

```
uid=1000 gid=1000 groups=1000
```

**Verifique o sistema de arquivos raiz somente-leitura:**

```bash
kubectl exec -n psa-restricted hardened-pod -- touch /test-file
```

Saída esperada:

```
touch: /test-file: Read-only file system
command terminated with exit code 1
```

**Verifique que as capabilities foram removidas:**

```bash
kubectl exec -n psa-restricted hardened-pod -- cat /proc/1/status | grep -i cap
```

Esperado: todas as bitmasks de capability devem ser `0000000000000000` (todos zeros), indicando que todas as capabilities foram removidas.

```
CapInh: 0000000000000000
CapPrm: 0000000000000000
CapEff: 0000000000000000
CapBnd: 0000000000000000
CapAmb: 0000000000000000
```

> **Dica do Coach:** Percorra cada campo do SecurityContext e seu equivalente Linux:
>
> | Campo | Equivalente Linux |
> |-------|------------------|
> | `runAsNonRoot: true` | Recusa iniciar se UID for 0 |
> | `runAsUser: 1000` | `runuser -u uid1000 -- ...` |
> | `readOnlyRootFilesystem: true` | `mount -o ro /` |
> | `capabilities.drop: ["ALL"]` | `capsh --drop=all` |
> | `allowPrivilegeEscalation: false` | `prctl(PR_SET_NO_NEW_PRIVS, 1)` — bloqueia setuid/setgid |
> | `seccompProfile.type: RuntimeDefault` | Filtro seccomp padrão (bloqueia syscalls perigosas) |

---

## Problemas Comuns

| Problema | Causa | Correção |
|----------|-------|----------|
| `Forbidden` ao executar kubectl dentro do Pod | ServiceAccount não tem RoleBinding | Crie um RoleBinding que vincule a Role apropriada à ServiceAccount |
| `auth can-i` diz `yes` mas Pod ainda não consegue acessar | A flag `--as` usa formato `system:serviceaccount:NAMESPACE:NAME` — verifique erros de digitação | Verifique o formato exato: `--as=system:serviceaccount:secure-ns:app-reader` |
| Pod privilegiado não é rejeitado | Namespace não tem labels PSA | Verifique com `kubectl get namespace psa-restricted --show-labels` |
| Pod falha com "container has runAsNonRoot and image will run as root" | Imagem padrão é root mas spec do Pod exige non-root | Adicione `runAsUser: 1000` ao securityContext |
| Erro PSA lista múltiplas violações | O profile `restricted` exige MUITOS campos | Você precisa de TODOS: `runAsNonRoot`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`, e `seccompProfile` |
| ClusterRoleBinding não funciona | Esqueceu campo `namespace` na seção `subjects` | Subjects de ServiceAccount em ClusterRoleBindings DEVEM especificar o namespace |
| Regra RBAC corresponde a recursos errados | Valor `apiGroups` incorreto | Recursos core (Pods, Services, Secrets) usam `""`, Deployments usam `"apps"`, recursos RBAC usam `"rbac.authorization.k8s.io"` |

---

## Limpeza

```bash
kubectl delete namespace secure-ns psa-restricted psa-baseline psa-lockdown 2>/dev/null
kubectl delete clusterrole node-viewer 2>/dev/null
kubectl delete clusterrolebinding view-nodes-binding 2>/dev/null
rm -f reader-pod.yaml pod-reader-role.yaml pod-reader-binding.yaml \
  node-viewer-clusterrole.yaml node-viewer-binding.yaml \
  privileged-pod.yaml hardened-pod.yaml
```
