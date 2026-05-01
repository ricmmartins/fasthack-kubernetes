# Desafio 09 — RBAC e Segurança

[< Desafio Anterior](Challenge-08.md) | **[Início](../README.md)** | [Próximo Desafio >](Challenge-10.md)

## Introdução

Em um servidor Linux, a segurança é em camadas: você cria **usuários** em `/etc/passwd`, organiza-os em **grupos** em `/etc/group`, concede privilégios elevados com o arquivo **sudoers**, define acesso em nível de arquivo com **chmod**, e aplica controle de acesso mandatório com **SELinux** ou **AppArmor**. Se um processo não tem o UID correto, a associação de grupo correta, ou o contexto de segurança correto — acesso negado.

O Kubernetes segue exatamente a mesma filosofia, apenas com nomes diferentes:

| Camada Linux | Camada Kubernetes |
|---|---|
| "Quem é você?" (`/etc/passwd`) | "Qual **ServiceAccount** este Pod está executando?" |
| "Em qual grupo você está?" (`/etc/group`) | "Qual **Role** ou **ClusterRole** define este conjunto de permissões?" |
| "Você está no sudoers?" | "Existe um **RoleBinding** ou **ClusterRoleBinding** concedendo a esta identidade estas permissões?" |
| "Seu UID tem leitura/escrita/execução?" (`chmod`) | "A política RBAC inclui os **verbs** corretos (`get`, `list`, `create`, `delete`)?" |
| "O SELinux/AppArmor permite esta ação?" | "A política de **Pod Security Admission (PSA)** do namespace permite esta configuração de Pod?" |
| "Qual usuário está executando este processo?" (`runuser`, `su`) | "O que o **SecurityContext** do Pod (`runAsUser`, `runAsNonRoot`) impõe?" |

Toda requisição ao servidor da API do Kubernetes passa por três portões — **Autenticação** (quem é você?), **Autorização** (você tem permissão?), e **Controle de Admissão** (esta requisição está em conformidade com a política?). Neste desafio, você vai configurar todas as três camadas usando RBAC, ServiceAccounts, Pod Security Admission e SecurityContext.

> 📝 **Nota histórica**: Tutoriais antigos podem referenciar **PodSecurityPolicy (PSP)**. PSP foi depreciada no Kubernetes v1.21 e **removida completamente na v1.25**. A substituição é o **Pod Security Admission (PSA)**, que é o que usamos neste desafio. Se você encontrar PSP em produção, é legado — migre para PSA.

> 🆕 **Kubernetes v1.36**: **User Namespaces** agora estão GA (geralmente disponíveis). Este recurso mapeia UIDs de container para UIDs não privilegiados no host, similar a containers rootless no Podman. Embora não coberto nas tarefas deste desafio, esteja ciente deste poderoso recurso de segurança para defesa em profundidade — veja `pod.spec.hostUsers: false` nos recursos de aprendizado.

## Descrição

Sua missão é:

1. **Criar uma ServiceAccount e usá-la em um Pod** — ServiceAccounts são o equivalente Kubernetes de usuários de serviço Linux (como `www-data` para Apache ou `postgres` para PostgreSQL). Crie uma ServiceAccount chamada `app-reader` em um namespace chamado `secure-ns`, depois lance um Pod que a utilize.

   ```bash
   kubectl create namespace secure-ns
   kubectl create serviceaccount app-reader -n secure-ns
   ```

   Crie um manifesto de Pod que referencia esta ServiceAccount:

   ```yaml
   # reader-pod.yaml
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

   Aplique e verifique se a ServiceAccount está montada:

   ```bash
   kubectl apply -f reader-pod.yaml
   kubectl exec -n secure-ns reader-pod -- cat /var/run/secrets/kubernetes.io/serviceaccount/token
   ```

2. **Criar uma Role e RoleBinding para conceder acesso somente leitura a Pods em um namespace** — Uma Role define *quais* ações são permitidas em *quais* recursos dentro de um único namespace. Um RoleBinding conecta uma Role a um sujeito (ServiceAccount, User ou Group). Isso é como escrever uma entrada no sudoers que diz "usuário `app-reader` pode executar `cat` e `ls` em arquivos em `/var/log` mas nada mais."

   Crie uma Role que permite ler Pods:

   ```yaml
   # pod-reader-role.yaml
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

   Vincule-a à ServiceAccount `app-reader`:

   ```yaml
   # pod-reader-binding.yaml
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

   Aplique ambos e teste de dentro do Pod:

   ```bash
   kubectl apply -f pod-reader-role.yaml
   kubectl apply -f pod-reader-binding.yaml

   # Isso deve ter sucesso (listar Pods)
   kubectl exec -n secure-ns reader-pod -- kubectl get pods -n secure-ns

   # Isso deve FALHAR (sem permissão para listar Secrets)
   kubectl exec -n secure-ns reader-pod -- kubectl get secrets -n secure-ns
   ```

3. **Criar uma ClusterRole e ClusterRoleBinding para permissões em todo o cluster** — Enquanto Roles têm escopo de namespace (como permissões por diretório), ClusterRoles se aplicam a *todos* os namespaces (como uma regra global no sudoers). Crie uma ClusterRole que pode listar Nodes (um recurso com escopo de cluster) e vincule-a à ServiceAccount `app-reader`.

   ```yaml
   # node-viewer-clusterrole.yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: node-viewer
   rules:
   - apiGroups: [""]
     resources: ["nodes"]
     verbs: ["get", "list"]
   ```

   ```yaml
   # node-viewer-binding.yaml
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

   Aplique e verifique:

   ```bash
   kubectl apply -f node-viewer-clusterrole.yaml
   kubectl apply -f node-viewer-binding.yaml

   # Isso deve ter sucesso agora
   kubectl exec -n secure-ns reader-pod -- kubectl get nodes
   ```

4. **Usar `kubectl auth can-i` para verificar permissões** — Este é o equivalente Kubernetes de `sudo -l` (listar o que um usuário pode fazer). Use-o para verificar o que a ServiceAccount `app-reader` pode e não pode fazer.

   ```bash
   # Verificar se app-reader pode listar Pods em secure-ns (deve ser: yes)
   kubectl auth can-i list pods -n secure-ns --as=system:serviceaccount:secure-ns:app-reader

   # Verificar se app-reader pode deletar Pods em secure-ns (deve ser: no)
   kubectl auth can-i delete pods -n secure-ns --as=system:serviceaccount:secure-ns:app-reader

   # Verificar se app-reader pode listar Nodes em todo o cluster (deve ser: yes)
   kubectl auth can-i list nodes --as=system:serviceaccount:secure-ns:app-reader

   # Listar TODAS as permissões do app-reader em secure-ns
   kubectl auth can-i --list -n secure-ns --as=system:serviceaccount:secure-ns:app-reader
   ```

5. **Aplicar labels de Pod Security Admission (PSA) a um namespace** — PSA aplica padrões de segurança no nível do namespace usando labels. Existem três níveis de política — `privileged` (sem restrições), `baseline` (previne escalações de privilégio conhecidas), e `restricted` (altamente restritivo). Este é o equivalente Kubernetes dos modos de aplicação do SELinux (`disabled`, `permissive`, `enforcing`).

   Crie um namespace com a política `restricted` aplicada:

   ```bash
   kubectl create namespace psa-restricted
   kubectl label namespace psa-restricted \
     pod-security.kubernetes.io/enforce=restricted \
     pod-security.kubernetes.io/warn=restricted \
     pod-security.kubernetes.io/audit=restricted
   ```

   Tente implantar um Pod privilegiado neste namespace — ele deve ser rejeitado:

   ```yaml
   # privileged-pod.yaml
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
   # Isso deve ser REJEITADO pelo PSA
   kubectl apply -f privileged-pod.yaml
   ```

   Agora crie um namespace com enforcement `baseline` e verifique que Pods não privilegiados são aceitos:

   ```bash
   kubectl create namespace psa-baseline
   kubectl label namespace psa-baseline \
     pod-security.kubernetes.io/enforce=baseline \
     pod-security.kubernetes.io/warn=restricted
   ```

   O label `warn=restricted` significa que o Kubernetes vai **avisar** você (mas não bloquear) quando um Pod não atende ao padrão `restricted` — útil para adoção progressiva.

6. **Configurar SecurityContext em um Pod** — SecurityContext é como você define a "identidade de usuário" e as capabilities de um container, assim como usar `runuser` para trocar UIDs ou `capsh` para remover capabilities Linux.

   Crie um Pod hardened que segue as melhores práticas de segurança:

   ```yaml
   # hardened-pod.yaml
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

   Aplique e verifique:

   ```bash
   kubectl apply -f hardened-pod.yaml

   # Verificar se o Pod está executando
   kubectl get pod hardened-pod -n psa-restricted

   # Confirmar que executa como UID 1000 (não root)
   kubectl exec -n psa-restricted hardened-pod -- id

   # Confirmar que o sistema de arquivos raiz é somente leitura
   kubectl exec -n psa-restricted hardened-pod -- touch /test-file
   # Deve falhar com "Read-only file system"

   # Confirmar que as capabilities foram removidas
   kubectl exec -n psa-restricted hardened-pod -- cat /proc/1/status | grep Cap
   ```

## Critérios de Sucesso

- [ ] Uma ServiceAccount chamada `app-reader` existe no namespace `secure-ns` e um Pod está executando com essa ServiceAccount
- [ ] Uma Role chamada `pod-reader` concede `get`, `list`, `watch` em Pods em `secure-ns`, e um RoleBinding a conecta ao `app-reader`
- [ ] O `reader-pod` pode listar Pods em `secure-ns` mas **não pode** listar Secrets
- [ ] Uma ClusterRole chamada `node-viewer` concede `get`, `list` em Nodes, e o `reader-pod` pode listar Nodes
- [ ] `kubectl auth can-i` reporta corretamente `yes` para ações permitidas e `no` para ações negadas
- [ ] O namespace `psa-restricted` rejeita um Pod com `privileged: true`
- [ ] O namespace `psa-baseline` aceita um Pod não privilegiado e **avisa** quando um Pod não atende ao `restricted`
- [ ] Um Pod hardened executa como não-root (UID 1000), tem sistema de arquivos raiz somente leitura, e remove todas as capabilities
- [ ] Você consegue explicar a diferença entre Role/RoleBinding (escopo de namespace) e ClusterRole/ClusterRoleBinding (escopo de cluster)

## Referência Linux ↔ Kubernetes

| Conceito Linux | Equivalente Kubernetes | Exemplo |
|---|---|---|
| Usuários (`/etc/passwd`) | ServiceAccounts | `kubectl create sa app-reader` |
| Grupos (`/etc/group`) | Roles / ClusterRoles | `rules: [{resources: ["pods"], verbs: ["get"]}]` |
| Arquivo sudoers | RoleBinding / ClusterRoleBinding | Vincula uma Role a uma ServiceAccount |
| `chmod` / permissões de arquivo | Verbs RBAC | `get`, `list`, `watch`, `create`, `update`, `delete` |
| `sudo -l` (listar privilégios) | `kubectl auth can-i --list` | Verificar o que uma ServiceAccount pode fazer |
| Perfis SELinux / AppArmor | Pod Security Admission (PSA) | `pod-security.kubernetes.io/enforce=restricted` |
| `runuser` / `su` (trocar usuário) | `securityContext.runAsUser` | `runAsUser: 1000` |
| `chroot` (restringir visão do filesystem) | `readOnlyRootFilesystem: true` | Prevenir escritas no rootfs do container |
| `capsh --print` (capabilities) | `securityContext.capabilities.drop` | `drop: ["ALL"]` |
| `/etc/security/limits.conf` | `allowPrivilegeEscalation: false` | Prevenir escalação via setuid/setgid |

## Dicas

<details>
<summary>Dica 1: Entendendo a montagem do token da ServiceAccount</summary>

Quando um Pod executa com uma ServiceAccount, o Kubernetes automaticamente monta um **volume de token projetado** em `/var/run/secrets/kubernetes.io/serviceaccount/`. Este diretório contém:

- `token` — um JWT (JSON Web Token) com tempo limitado que identifica a ServiceAccount
- `ca.crt` — o certificado CA do cluster (para que o Pod possa verificar a identidade do servidor da API)
- `namespace` — o namespace em que o Pod está executando

Isso é similar a como o encaminhamento do agente SSH injeta credenciais em uma sessão. O binário `kubectl` dentro do container automaticamente usa esses arquivos ao se comunicar com o servidor da API.

```bash
# Inspecionar o token montado
kubectl exec -n secure-ns reader-pod -- ls -la /var/run/secrets/kubernetes.io/serviceaccount/

# Decodificar o payload do JWT (segundo segmento, decodificado de base64)
kubectl exec -n secure-ns reader-pod -- cat /var/run/secrets/kubernetes.io/serviceaccount/token | \
  cut -d'.' -f2 | base64 -d 2>/dev/null | python3 -m json.tool
```

</details>

<details>
<summary>Dica 2: Verbs RBAC explicados — mapeamento para REST e Linux</summary>

Toda regra RBAC especifica **verbs** (ações) em **resources**. Estes mapeiam tanto para métodos HTTP quanto para operações de arquivo Linux:

| Verb RBAC | Método HTTP | Equivalente Linux |
|---|---|---|
| `get` | GET (recurso único) | `cat /path/to/file` |
| `list` | GET (coleção) | `ls /path/to/directory` |
| `watch` | GET com `?watch=true` | `inotifywait -m /path` |
| `create` | POST | `touch /path/to/file` |
| `update` | PUT | `echo "new content" > /path/to/file` |
| `patch` | PATCH | `sed -i 's/old/new/' /path/to/file` |
| `delete` | DELETE | `rm /path/to/file` |

Para acesso somente leitura, conceda apenas `get`, `list` e `watch`. O `apiGroups: [""]` em uma regra se refere ao grupo de API **core** (Pods, Services, Secrets, ConfigMaps). Outros recursos vivem em grupos nomeados como `apps` (Deployments) ou `rbac.authorization.k8s.io` (Roles).

</details>

<details>
<summary>Dica 3: Níveis PSA — o que cada um restringe</summary>

Pod Security Admission define três níveis, cada um progressivamente mais restrito:

**`privileged`** — Sem restrições. Como executar SELinux em modo `disabled`.

**`baseline`** — Bloqueia as configurações mais perigosas:
- Sem containers `privileged: true`
- Sem `hostNetwork`, `hostPID`, `hostIPC`
- Sem volumes `hostPath`
- Faixas de porta restritas

**`restricted`** — Aplica melhores práticas de segurança:
- Tudo do `baseline`, mais:
- Deve ter `runAsNonRoot: true`
- Deve remover `ALL` capabilities (apenas `NET_BIND_SERVICE` pode ser adicionada de volta)
- Deve definir `allowPrivilegeEscalation: false`
- Deve definir `seccompProfile.type: RuntimeDefault` ou `Localhost`
- Filesystem raiz não gravável é *recomendado* mas não obrigatório

Cada namespace pode definir três **modos** independentemente:

| Modo | Comportamento |
|---|---|
| `enforce` | Rejeita Pods que violam a política |
| `warn` | Aceita o Pod mas mostra um aviso ao usuário |
| `audit` | Registra violações no log de auditoria do servidor da API |

Um padrão comum de rollout progressivo:
```bash
# Começar com warn + audit em restricted, enforce baseline
kubectl label namespace my-ns \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted
```

</details>

<details>
<summary>Dica 4: Debugando negações RBAC</summary>

Quando uma requisição falha com `Error from server (Forbidden)`, veja como debugar:

```bash
# 1. Verificar o que a ServiceAccount PODE fazer
kubectl auth can-i --list -n secure-ns --as=system:serviceaccount:secure-ns:app-reader

# 2. Verificar uma permissão específica
kubectl auth can-i get secrets -n secure-ns --as=system:serviceaccount:secure-ns:app-reader
# Output: no

# 3. Listar todos os RoleBindings no namespace para ver o que está vinculado
kubectl get rolebindings -n secure-ns -o wide

# 4. Descrever um RoleBinding específico para ver os sujeitos e roleRef
kubectl describe rolebinding read-pods-binding -n secure-ns

# 5. Listar todos os ClusterRoleBindings (atenção a bindings excessivamente permissivos)
kubectl get clusterrolebindings -o wide | grep app-reader
```

**Erros comuns:**
- Esquecer o campo `namespace` na seção `subjects` do RoleBinding
- Usar `Role` em um `ClusterRoleBinding` (você pode vincular uma ClusterRole com um RoleBinding para limitá-la a um namespace, mas não o inverso)
- Erros de digitação no nome da ServiceAccount — RBAC silenciosamente não faz nada se o sujeito não corresponder

</details>

<details>
<summary>Dica 5: SecurityContext no nível do Pod vs nível do Container</summary>

SecurityContext pode ser definido em **dois níveis**, e eles se comportam como padrões Linux vs substituições:

| Nível | Escopo | Analogia Linux |
|---|---|---|
| `spec.securityContext` (nível do Pod) | Aplica a TODOS os containers | `/etc/login.defs` (padrões do sistema) |
| `spec.containers[].securityContext` (nível do Container) | Aplica a UM container | `runuser -u appuser -- ./myapp` (por processo) |

Configurações no nível do container **substituem** configurações no nível do Pod quando ambas são especificadas.

**Campos comuns no nível do Pod:**
```yaml
spec:
  securityContext:
    runAsNonRoot: true    # Rejeitar containers que executariam como root
    runAsUser: 1000       # UID padrão para todos os containers
    runAsGroup: 1000      # GID padrão para todos os containers
    fsGroup: 2000         # GID aplicado a todos os volumes montados
    seccompProfile:
      type: RuntimeDefault
```

**Campos comuns no nível do Container:**
```yaml
containers:
- name: app
  securityContext:
    allowPrivilegeEscalation: false   # Sem setuid/setgid
    readOnlyRootFilesystem: true      # Como montar / como somente leitura
    capabilities:
      drop: ["ALL"]                   # Remover todas as capabilities Linux
      add: ["NET_BIND_SERVICE"]       # Re-adicionar apenas o necessário
```

</details>

## Recursos de Aprendizado

- [Kubernetes RBAC — Using RBAC Authorization](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
- [Kubernetes — Configure Service Accounts for Pods](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/)
- [Kubernetes — Pod Security Admission](https://kubernetes.io/docs/concepts/security/pod-security-admission/)
- [Kubernetes — Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [Kubernetes — Configure a Security Context for a Pod or Container](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)
- [Kubernetes — Checking API Access with kubectl auth can-i](https://kubernetes.io/docs/reference/access-authn-authz/authorization/#checking-api-access)
- [Kubernetes — User Namespaces](https://kubernetes.io/docs/concepts/workloads/pods/user-namespaces/)

## Quebra & Conserta 🔧

Após completar o desafio, tente estes cenários para aprofundar seu entendimento:

### Cenário 1: Pod não consegue acessar a API — RoleBinding ausente

Implante este Pod e tente listar Pods de dentro dele:

```yaml
# broken-reader.yaml
apiVersion: v1
kind: Pod
metadata:
  name: broken-reader
  namespace: secure-ns
spec:
  serviceAccountName: lonely-sa
  containers:
  - name: shell
    image: bitnami/kubectl:latest
    command: ["sleep", "3600"]
```

```bash
kubectl create serviceaccount lonely-sa -n secure-ns
kubectl apply -f broken-reader.yaml
kubectl exec -n secure-ns broken-reader -- kubectl get pods -n secure-ns
# ERROR: pods is forbidden: User "system:serviceaccount:secure-ns:lonely-sa"
#        cannot list resource "pods" in API group "" in the namespace "secure-ns"
```

**Sua tarefa**: A ServiceAccount `lonely-sa` existe mas não tem permissões. Crie o RoleBinding ausente para conceder acesso à Role `pod-reader`. Verifique a correção re-executando o comando `kubectl get pods` de dentro do Pod.

*(Analogia Linux: Um usuário existe em `/etc/passwd` mas não tem associação a grupo nem entrada no sudoers — ele pode fazer login mas não consegue fazer nada útil.)*

### Cenário 2: Pod falha com "container has runAsNonRoot and image will run as root"

Tente aplicar este Pod:

```yaml
# broken-nonroot.yaml
apiVersion: v1
kind: Pod
metadata:
  name: broken-nonroot
  namespace: secure-ns
spec:
  securityContext:
    runAsNonRoot: true
  containers:
  - name: app
    image: nginx:1.27
    command: ["sleep", "3600"]
```

```bash
kubectl apply -f broken-nonroot.yaml
kubectl get pod broken-nonroot -n secure-ns
# STATUS: CreateContainerConfigError

kubectl describe pod broken-nonroot -n secure-ns
# Error: container has runAsNonRoot and image will run as root
```

**Sua tarefa**: A spec do Pod diz `runAsNonRoot: true`, mas o usuário padrão da imagem `nginx:1.27` é root (UID 0). Corrija isso adicionando `runAsUser: 1000` ao `securityContext` do container. Após corrigir, verifique se o Pod inicia e executa como UID 1000.

*(Analogia Linux: Você configurou `/etc/login.defs` para rejeitar logins root, mas o serviço é hardcoded para iniciar como root — você precisa adicionar uma diretiva `User=` no arquivo de unit do systemd.)*

### Cenário 3: Namespace rejeita um Pod — PSA enforce=restricted

Crie um namespace com enforcement PSA estrito e tente implantar um Pod que o viola:

```bash
kubectl create namespace psa-lockdown
kubectl label namespace psa-lockdown pod-security.kubernetes.io/enforce=restricted
```

```yaml
# broken-psa.yaml
apiVersion: v1
kind: Pod
metadata:
  name: broken-psa
  namespace: psa-lockdown
spec:
  containers:
  - name: app
    image: busybox:1.37
    command: ["sleep", "3600"]
    securityContext:
      privileged: true
```

```bash
kubectl apply -f broken-psa.yaml
# Error from server (Forbidden): ...violates PodSecurity "restricted:latest":
#   privileged (container "app" must not set securityContext.privileged=true),
#   ...
```

**Sua tarefa**: Corrija a spec do Pod para estar em conformidade com o padrão PSA `restricted`. Você precisará: remover `privileged: true`, adicionar `runAsNonRoot: true` e `runAsUser: 1000` no nível do Pod, adicionar `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, e `capabilities.drop: ["ALL"]` no nível do container, e definir `seccompProfile.type: RuntimeDefault` no nível do Pod. Aplique o manifesto corrigido e verifique se o Pod inicia com sucesso.
