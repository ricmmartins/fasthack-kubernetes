# Solução 08 — ConfigMaps e Secrets

[< Voltar para o Desafio](../Student/Challenge-08.md) | **[Home](README.md)**

## Notas para os Coaches

Este desafio é conceitualmente simples, mas o comportamento de hot-reload (Tarefa 6) é o "momento aha". Certifique-se de que os alunos realmente **esperem** e observem a mudança do arquivo montado via volume enquanto a variável de ambiente permanece congelada. Esse contraste é o aprendizado mais valioso.

Tempo estimado: **30 minutos**

---

## Tarefa 1: Criar ConfigMaps (Literal + De Arquivo)

### Passo a passo

**1a — ConfigMap a partir de valores literais:**

```bash
kubectl create configmap app-config \
  --from-literal=APP_COLOR=blue \
  --from-literal=APP_MODE=production
```

**1b — Crie o arquivo de configuração e construa um ConfigMap a partir dele:**

```bash
cat <<'EOF' > nginx-custom.conf
server {
    listen       80;
    server_name  localhost;
    location / {
        root   /usr/share/nginx/html;
        index  index.html;
    }
    location /health {
        return 200 'OK';
        add_header Content-Type text/plain;
    }
}
EOF

kubectl create configmap nginx-config --from-file=default.conf=nginx-custom.conf
```

### Verificação

```bash
kubectl get configmap app-config -o yaml
```

Saída esperada (seção principal):

```yaml
data:
  APP_COLOR: blue
  APP_MODE: production
```

```bash
kubectl get configmap nginx-config -o yaml
```

Esperado: a seção `data` tem uma chave chamada `default.conf` cujo valor é o conteúdo completo do arquivo de configuração do nginx.

> **Dica do Coach:** Destaque que `--from-file=default.conf=nginx-custom.conf` define o nome da chave como `default.conf`. Sem o prefixo `key=`, a chave assume o nome do arquivo local (`nginx-custom.conf`). Esse é um erro comum.

---

## Tarefa 2: Montar ConfigMap como um Volume

### Passo a passo

Salve `nginx-with-config.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx-configured
spec:
  containers:
    - name: nginx
      image: nginx:1.27-alpine
      ports:
        - containerPort: 80
      volumeMounts:
        - name: config-volume
          mountPath: /etc/nginx/conf.d
  volumes:
    - name: config-volume
      configMap:
        name: nginx-config
```

```bash
kubectl apply -f nginx-with-config.yaml
kubectl wait --for=condition=Ready pod/nginx-configured --timeout=60s
```

### Verificação

```bash
kubectl exec nginx-configured -- cat /etc/nginx/conf.d/default.conf
```

Esperado: o arquivo completo de configuração do nginx é exibido.

```bash
kubectl exec nginx-configured -- wget -qO- http://localhost/health
```

Saída esperada:

```
OK
```

> **Dica do Coach:** Explique que montar um ConfigMap em um diretório **substitui todo o conteúdo do diretório**. Se o aluno precisar manter arquivos existentes naquele diretório, deve usar `subPath` — mas avise que montagens `subPath` não recebem atualizações automáticas.

---

## Tarefa 3: Usar ConfigMap como Variáveis de Ambiente

### Passo a passo

Salve `env-demo.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: env-demo
spec:
  containers:
    - name: app
      image: busybox:1.37
      command: ["sh", "-c", "echo Color=$APP_COLOR Mode=$APP_MODE && sleep 3600"]
      envFrom:
        - configMapRef:
            name: app-config
```

```bash
kubectl apply -f env-demo.yaml
kubectl wait --for=condition=Ready pod/env-demo --timeout=60s
kubectl logs env-demo
```

### Verificação

Saída esperada:

```
Color=blue Mode=production
```

> **Dica do Coach:** Explique a diferença entre `envFrom` (injeta TODAS as chaves como variáveis de ambiente) e `env[].valueFrom.configMapKeyRef` (injeta uma única chave, opcionalmente renomeando-a). Pergunte aos alunos: "Quando vocês usariam uma vs a outra?"

---

## Tarefa 4: Criar um Secret e Montá-lo

### Passo a passo

```bash
kubectl create secret generic db-creds \
  --from-literal=DB_USER=admin \
  --from-literal=DB_PASSWORD='S3cur3P@ss!'
```

Salve `secret-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secret-pod
spec:
  containers:
    - name: app
      image: busybox:1.37
      command: ["sh", "-c", "ls -la /etc/credentials/ && cat /etc/credentials/DB_USER && echo && sleep 3600"]
      volumeMounts:
        - name: secret-volume
          mountPath: /etc/credentials
          readOnly: true
  volumes:
    - name: secret-volume
      secret:
        secretName: db-creds
        defaultMode: 0400
```

```bash
kubectl apply -f secret-pod.yaml
kubectl wait --for=condition=Ready pod/secret-pod --timeout=60s
```

### Verificação

```bash
kubectl logs secret-pod
```

Esperado: você vê a listagem de arquivos com permissões `-r--------` (0400) e o conteúdo `admin`.

```bash
kubectl exec secret-pod -- ls -la /etc/credentials/
```

Saída esperada inclui:

```
-r--------    1 root     root             5 ...  DB_PASSWORD
-r--------    1 root     root             5 ...  DB_USER
```

> **Dica do Coach:** Enfatize `defaultMode: 0400` — este é o equivalente Kubernetes do `chmod 400`. Cada chave se torna um arquivo separado. O `readOnly: true` no volumeMount é uma camada adicional de proteção.

---

## Tarefa 5: Base64 NÃO É Criptografia

### Passo a passo

```bash
kubectl get secret db-creds -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
```

### Verificação

Saída esperada:

```
S3cur3P@ss!
```

Também demonstre `stringData` vs `data`. Salve `manual-secret.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: manual-secret
type: Opaque
stringData:
  API_KEY: my-super-secret-key
```

```bash
kubectl apply -f manual-secret.yaml
kubectl get secret manual-secret -o jsonpath='{.data.API_KEY}' | base64 -d
```

Saída esperada:

```
my-super-secret-key
```

> **Dica do Coach:** Esta é a discussão de segurança mais importante deste desafio. Pergunte aos alunos: "Se base64 não é criptografia, como realmente protegemos os Secrets?" Respostas esperadas: RBAC (restringir `get secret`), criptografia em repouso no etcd, gerenciadores de secrets externos (Sealed Secrets, external-secrets-operator), nunca commitar manifestos de Secret no controle de versão.

---

## Tarefa 6: Hot-Reload — Atualização via Volume vs Variável de Ambiente Congelada

Este é o momento-chave de aprendizado do desafio.

### Passo a passo

**6a — Crie o Pod observador:**

Salve `watch-config.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: watch-config
spec:
  containers:
    - name: watcher
      image: busybox:1.37
      command: ["sh", "-c", "while true; do cat /config/APP_COLOR 2>/dev/null; echo; sleep 5; done"]
      volumeMounts:
        - name: config-vol
          mountPath: /config
  volumes:
    - name: config-vol
      configMap:
        name: app-config
```

```bash
kubectl apply -f watch-config.yaml
kubectl wait --for=condition=Ready pod/watch-config --timeout=60s
```

**6b — Verifique o valor atual:**

```bash
kubectl logs watch-config --tail=3
```

Esperado: imprime `blue` repetidamente.

**6c — Atualize o ConfigMap:**

```bash
kubectl patch configmap app-config -p '{"data":{"APP_COLOR":"red"}}'
```

**6d — Observe o arquivo montado via volume sendo atualizado (aguarde 30–60 segundos):**

```bash
kubectl logs watch-config -f
```

Esperado: após 30–60 segundos a saída muda de `blue` para `red` — **sem reiniciar o Pod**.

**6e — Verifique o Pod com variável de ambiente — ele NÃO atualiza:**

```bash
kubectl exec env-demo -- sh -c 'echo $APP_COLOR'
```

Saída esperada:

```
blue
```

A variável de ambiente ainda é `blue` porque variáveis de ambiente são congeladas no início do container.

**6f — Reinicie para capturar as novas variáveis de ambiente:**

```bash
kubectl delete pod env-demo
kubectl apply -f env-demo.yaml
kubectl wait --for=condition=Ready pod/env-demo --timeout=60s
kubectl logs env-demo
```

Saída esperada:

```
Color=red Mode=production
```

### Verificação

| Teste | Resultado Esperado |
|-------|-------------------|
| `kubectl logs watch-config --tail=1` | `red` (atualizado automaticamente) |
| `kubectl exec env-demo -- sh -c 'echo $APP_COLOR'` | `red` (após reinício do Pod) |

> **Dica do Coach:** Pergunte ao aluno: "Se você usar um Deployment, como dispararia um rollout quando um ConfigMap mudar?" Resposta: anotar o template do Pod com um hash dos dados do ConfigMap, ou usar uma ferramenta como o Reloader. O Kubernetes NÃO reinicia automaticamente Deployments quando ConfigMaps referenciados mudam.

---

## Problemas Comuns

| Problema | Causa | Correção |
|----------|-------|----------|
| Pod preso em `ContainerCreating` | ConfigMap/Secret referenciado não existe | Crie o recurso faltante, ou adicione `optional: true` na spec do volume |
| Falha ao aplicar Secret com "illegal base64" | Usou campo `data:` com texto puro ao invés de base64 | Use `stringData:` ao invés, ou codifique o valor em base64 primeiro |
| Variável de ambiente não atualiza após mudança no ConfigMap | Variáveis de ambiente são congeladas no início do container | Reinicie o Pod (delete + recrie, ou `kubectl rollout restart deployment`) |
| Arquivo montado via volume não atualiza | Usando montagem `subPath` | Montagens `subPath` não recebem atualizações automáticas; use montagem de diretório completo |
| Chave do arquivo ConfigMap com nome errado | Não usou prefixo `key=` no `--from-file` | Use `--from-file=chave-desejada=nome-arquivo-local` |
| Montagem de volume oculta arquivos existentes no diretório | Volume de ConfigMap substitui o diretório inteiro | Use `subPath` para arquivos individuais (trade-off: sem atualização automática) |

---

## Limpeza

```bash
kubectl delete pod nginx-configured env-demo secret-pod watch-config 2>/dev/null
kubectl delete configmap app-config nginx-config 2>/dev/null
kubectl delete secret db-creds manual-secret 2>/dev/null
rm -f nginx-custom.conf nginx-with-config.yaml env-demo.yaml secret-pod.yaml watch-config.yaml manual-secret.yaml
```
