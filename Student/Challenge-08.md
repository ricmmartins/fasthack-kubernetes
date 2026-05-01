# Desafio 08 — ConfigMaps e Secrets

[< Desafio Anterior](Challenge-07.md) | **[Início](../README.md)** | [Próximo Desafio >](Challenge-09.md)

## Introdução

Em um servidor Linux, configuração está em todo lugar: `/etc/nginx/nginx.conf` controla seu servidor web, `export DB_HOST=10.0.0.5` injeta strings de conexão em um processo, e `/etc/shadow` mantém senhas em um arquivo legível apenas pelo root (`chmod 600`). Quando você quer que todo shell herde variáveis, você coloca um script em `/etc/profile.d/`, e se precisa reagir a uma mudança de arquivo de configuração você usa `inotifywait`.

O Kubernetes tem equivalentes diretos para tudo isso:

- **ConfigMaps** são os arquivos `/etc/*.conf` e variáveis de ambiente do cluster — eles armazenam dados de configuração não-sensíveis (feature flags, strings de conexão, arquivos de configuração completos).
- **Secrets** são o `/etc/shadow` e `/etc/ssl/private` do cluster — eles armazenam dados sensíveis (senhas, tokens, certificados TLS) e podem ser restritos com RBAC e permissões de arquivo (`defaultMode`).

Ambos podem ser injetados em um Pod como **variáveis de ambiente** (como `export`) ou **montados como arquivos** (como bind-mount de um arquivo de configuração em um container). A diferença crítica em relação ao Linux tradicional: volumes montados via ConfigMap são **atualizados automaticamente** pelo kubelet quando a fonte muda — como ter `inotifywait` embutido — mas variáveis de ambiente são **congeladas no início do Pod** e nunca mudam até você reiniciar o Pod.

Neste desafio você criará ConfigMaps e Secrets, os injetará de ambas as formas, e observará o comportamento de hot-reload que pega muitos iniciantes de surpresa.

## Descrição

Sua missão é:

1. **Criar um ConfigMap a partir de valores literais e de um arquivo**

   Primeiro, crie um ConfigMap usando `--from-literal`:

   ```bash
   kubectl create configmap app-config \
     --from-literal=APP_COLOR=blue \
     --from-literal=APP_MODE=production
   ```

   Em seguida, crie um arquivo de configuração local e construa um ConfigMap a partir dele:

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

   Inspecione o que foi criado:

   ```bash
   kubectl get configmap app-config -o yaml
   kubectl get configmap nginx-config -o yaml
   ```

   > **Nota:** `--from-file=default.conf=nginx-custom.conf` define o nome da chave como `default.conf` dentro do ConfigMap. Sem o prefixo `key=`, a chave assume o nome do arquivo.

2. **Montar um ConfigMap como volume em um Pod**

   Assim como fazer bind-mount de `/etc/nginx/conf.d/default.conf` em um host Linux, monte o ConfigMap `nginx-config` em um container NGINX:

   ```yaml
   # nginx-with-config.yaml
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
   kubectl exec nginx-configured -- cat /etc/nginx/conf.d/default.conf
   kubectl exec nginx-configured -- wget -qO- http://localhost/health
   ```

   O arquivo de configuração aparece dentro do container exatamente como se você o tivesse montado com `mount --bind`.

3. **Usar valores de ConfigMap como variáveis de ambiente**

   Este é o equivalente Kubernetes de `export VAR=val` ou `source /etc/profile.d/myapp.sh`:

   ```yaml
   # env-demo.yaml
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
   kubectl logs env-demo
   # Output: Color=blue Mode=production
   ```

   Você também pode selecionar chaves individuais usando `env[].valueFrom.configMapKeyRef`:

   ```yaml
   env:
     - name: COLOR
       valueFrom:
         configMapKeyRef:
           name: app-config
           key: APP_COLOR
   ```

4. **Criar um Secret e montá-lo em um Pod**

   Secrets são como `/etc/shadow` — eles armazenam dados sensíveis e devem ter permissões restritas. Crie um Secret opaco:

   ```bash
   kubectl create secret generic db-creds \
     --from-literal=DB_USER=admin \
     --from-literal=DB_PASSWORD='S3cur3P@ss!'
   ```

   Inspecione o Secret (valores são codificados em base64 na saída):

   ```bash
   kubectl get secret db-creds -o yaml
   ```

   Monte-o em um Pod como volume com permissões de arquivo restritas, assim como `chmod 0400`:

   ```yaml
   # secret-pod.yaml
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
   kubectl logs secret-pod
   kubectl exec secret-pod -- ls -la /etc/credentials/
   ```

   Cada chave no Secret se torna um arquivo. O `defaultMode: 0400` é o equivalente Kubernetes de `chmod 400` — somente leitura pelo proprietário.

   Você também pode injetar Secrets como variáveis de ambiente:

   ```yaml
   env:
     - name: DB_PASSWORD
       valueFrom:
         secretKeyRef:
           name: db-creds
           key: DB_PASSWORD
   ```

5. **Entender a codificação de Secrets — base64 NÃO é criptografia**

   Um equívoco comum: Secrets são **codificados** com base64, não **criptografados**. Qualquer pessoa com acesso a `kubectl get secret -o yaml` pode decodificá-los instantaneamente:

   ```bash
   kubectl get secret db-creds -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
   # Output: S3cur3P@ss!
   ```

   Verifique você mesmo — crie um Secret a partir de um manifesto YAML usando `stringData` (que lida com a codificação para você) vs `data` (que requer base64 pré-codificado):

   ```yaml
   # manual-secret.yaml
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

   **Melhores práticas de segurança:**
   - Use RBAC para restringir quem pode fazer `get` em Secrets
   - Habilite [criptografia em repouso](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/) para o datastore etcd
   - Considere gerenciamento externo de secrets (ex: Sealed Secrets, external-secrets-operator)
   - Nunca faça commit de manifestos Secret com valores `data:` no controle de versão
   - Marque Secrets como `immutable: true` quando eles nunca devem mudar

6. **Hot-reload: atualizar um ConfigMap e observar o comportamento de volume vs variável de ambiente**

   Esta é a tarefa que surpreende todo mundo. Atualize o ConfigMap e observe o que acontece:

   ```bash
   kubectl edit configmap app-config
   ```

   Altere `APP_COLOR` de `blue` para `red`, salve e saia.

   **Teste o Pod com volume montado** — crie um se ainda não tiver:

   ```yaml
   # watch-config.yaml
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
   kubectl logs watch-config -f
   ```

   Após editar o ConfigMap, o arquivo montado via volume atualiza automaticamente dentro de ~30–60 segundos (o período de sincronização do kubelet). Você verá a saída mudar de `blue` para `red` **sem reiniciar o Pod**.

   **Teste o Pod com variável de ambiente** — verifique `env-demo`:

   ```bash
   kubectl exec env-demo -- sh -c 'echo $APP_COLOR'
   # Still outputs: blue  (the OLD value!)
   ```

   **Variáveis de ambiente são definidas no início do container e nunca mudam.** Para receber novos valores você deve reiniciar o Pod:

   ```bash
   kubectl delete pod env-demo
   kubectl apply -f env-demo.yaml
   kubectl logs env-demo
   # Now outputs: Color=red Mode=production
   ```

   > **Conclusão principal:** Se sua aplicação lê configuração de **arquivos**, ela pode reagir a mudanças no ConfigMap sem reiniciar. Se ela lê de **variáveis de ambiente**, uma reinicialização do Pod é necessária.

## Critérios de Sucesso

- [ ] Você criou um ConfigMap a partir de `--from-literal` e verificou com `kubectl get configmap -o yaml` (Tarefa 1)
- [ ] Você criou um ConfigMap a partir de um arquivo (`--from-file`) e confirmou a estrutura chave/valor (Tarefa 1)
- [ ] Você montou um ConfigMap como volume e o arquivo de configuração aparece no caminho esperado dentro do container (Tarefa 2)
- [ ] Você injetou valores do ConfigMap como variáveis de ambiente usando `envFrom` e `configMapRef` (Tarefa 3)
- [ ] Você criou um Secret opaque e o montou como volume com `defaultMode: 0400` (Tarefa 4)
- [ ] Você decodificou o valor base64 de um Secret e consegue explicar por que base64 não é criptografia (Tarefa 5)
- [ ] Você atualizou um ConfigMap e observou o arquivo montado via volume mudar automaticamente (Tarefa 6)
- [ ] Você confirmou que variáveis de ambiente **não** atualizam após uma mudança no ConfigMap — uma reinicialização do Pod é necessária (Tarefa 6)
- [ ] Você consegue explicar quando usar montagens de volume vs variáveis de ambiente para configuração

## Referência Linux ↔ Kubernetes

| Conceito Linux | Equivalente Kubernetes |
|---|---|
| `/etc/nginx/nginx.conf` (arquivo de config) | ConfigMap montado como volume |
| `export VAR=val` (variável de ambiente) | ConfigMap/Secret como env vars (`envFrom` ou `valueFrom`) |
| `source /etc/profile.d/*.sh` (carregar todas as vars) | `envFrom: configMapRef` (injetar todas as chaves como env vars) |
| `/etc/shadow`, `/etc/ssl/private` (arquivos sensíveis) | Secret (opaque, TLS, docker-registry) |
| `chmod 600` (permissões restritas de arquivo) | Secret com `defaultMode: 0400` |
| `inotifywait` (observador de mudanças em arquivo) | Atualização automática de volume ConfigMap (~30–60s sincronização do kubelet) |
| `/etc/environment` (definido uma vez no boot) | Env vars do ConfigMap — congeladas no início do Pod |
| `echo 'password' \| base64` (codificação) | Campo `.data` do Secret — codificado em base64, **não criptografado** |

## Dicas

<details>
<summary>Dica 1: Qual é a diferença entre <code>data</code> e <code>stringData</code> em um manifesto Secret?</summary>

Ao escrever um Secret em YAML:

- **`data`** — os valores devem estar **codificados em base64** antes de colocá-los no manifesto:
  ```yaml
  data:
    password: UEBzc3cwcmQ=    # echo -n 'P@ssw0rd' | base64
  ```

- **`stringData`** — os valores são texto simples; o Kubernetes codifica para você:
  ```yaml
  stringData:
    password: P@ssw0rd
  ```

Ambos produzem o mesmo objeto Secret. Use `stringData` para legibilidade durante o desenvolvimento, mas lembre-se: o Secret ainda é apenas codificado em base64 no etcd, **não criptografado**.

</details>

<details>
<summary>Dica 2: Como montar apenas uma chave de um ConfigMap em vez de tudo?</summary>

Use o campo `items` para selecionar chaves específicas e controlar o nome do arquivo:

```yaml
volumes:
  - name: config-vol
    configMap:
      name: nginx-config
      items:
        - key: default.conf
          path: site.conf
```

Isso monta apenas a chave `default.conf` como um arquivo chamado `site.conf`. Sem `items`, toda chave no ConfigMap se torna um arquivo no diretório de montagem.

**Atenção:** Quando você monta um ConfigMap (ou Secret) em um diretório, ele **substitui todo o conteúdo do diretório**. Use `subPath` se precisar montar um único arquivo sem ocultar outros arquivos:

```yaml
volumeMounts:
  - name: config-vol
    mountPath: /etc/nginx/conf.d/custom.conf
    subPath: default.conf
```

> **Trade-off:** Montagens com `subPath` **não** recebem atualizações automáticas quando o ConfigMap muda.

</details>

<details>
<summary>Dica 3: Por que minhas alterações no ConfigMap não estão aparecendo no Pod?</summary>

Três razões comuns:

1. **Você está lendo de variáveis de ambiente** — env vars são definidas no início do container e nunca são atualizadas. Você deve deletar e recriar o Pod (ou usar um Deployment e acionar um rollout).

2. **Você usou `subPath`** — montagens de volume com `subPath` não recebem atualizações automáticas. Apenas montagens de ConfigMap em diretório completo são auto-atualizadas.

3. **Não passou tempo suficiente** — o kubelet sincroniza volumes de ConfigMap no seu período de sincronização (padrão ~60 segundos) mais um atraso de propagação de cache. Aguarde pelo menos 1–2 minutos após editar o ConfigMap.

Verifique os valores atuais dentro do Pod:
```bash
kubectl exec watch-config -- cat /config/APP_COLOR
kubectl exec env-demo -- printenv APP_COLOR
```

</details>

<details>
<summary>Dica 4: Como acionar um rollout de Deployment quando um ConfigMap muda?</summary>

O Kubernetes não reinicia automaticamente os Pods em um Deployment quando um ConfigMap referenciado muda. Um padrão comum é anotar o template do Pod com um hash dos dados do ConfigMap:

```bash
kubectl patch deployment my-app -p \
  "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"configmap-hash\":\"$(kubectl get configmap app-config -o jsonpath='{.data}' | md5sum | cut -d' ' -f1)\"}}}}}"
```

Isso altera o template do Pod, o que aciona uma atualização rolling. Algumas ferramentas (como Reloader do stakater) automatizam este padrão.

</details>

<details>
<summary>Dica 5: Como marcar um ConfigMap ou Secret como imutável?</summary>

Adicione `immutable: true` para prevenir quaisquer alterações futuras:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: release-config
immutable: true
data:
  VERSION: "2.5.0"
```

Uma vez definido, **você não pode alterar os dados ou remover a flag `immutable`** — você deve deletar e recriar o ConfigMap. Isso melhora a performance do cluster (o kubelet para de verificar atualizações) e protege contra alterações acidentais em produção.

O mesmo campo `immutable: true` funciona em Secrets.

</details>

## Recursos de Aprendizado

- [ConfigMaps — kubernetes.io](https://kubernetes.io/docs/concepts/configuration/configmap/)
- [Secrets — kubernetes.io](https://kubernetes.io/docs/concepts/configuration/secret/)
- [Configure a Pod to Use a ConfigMap — kubernetes.io](https://kubernetes.io/docs/tasks/configure-pod-container/configure-pod-configmap/)
- [Managing Secrets using kubectl — kubernetes.io](https://kubernetes.io/docs/tasks/configmap-secret/managing-secret-using-kubectl/)
- [Distribute Credentials Securely Using Secrets — kubernetes.io](https://kubernetes.io/docs/tasks/inject-data-application/distribute-credentials-secure/)
- [Encrypting Confidential Data at Rest — kubernetes.io](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)

## Quebra & Conserta 🔧

Após completar o desafio, tente diagnosticar estes cenários quebrados:

### Cenário 1: Pod preso em ContainerCreating — ConfigMap ausente

Um desenvolvedor implanta um Pod, mas ele nunca inicia:

```yaml
# broken-configmap-ref.yaml
apiVersion: v1
kind: Pod
metadata:
  name: broken-cm-pod
spec:
  containers:
    - name: app
      image: busybox:1.37
      command: ["sleep", "3600"]
      volumeMounts:
        - name: config
          mountPath: /config
  volumes:
    - name: config
      configMap:
        name: does-not-exist
```

```bash
kubectl apply -f broken-configmap-ref.yaml
kubectl get pod broken-cm-pod            # ContainerCreating (stuck)
kubectl describe pod broken-cm-pod       # Look at Events
```

<details>
<summary>💡 Causa raiz & correção</summary>

O Pod referencia um ConfigMap chamado `does-not-exist` que nunca foi criado. O kubelet não consegue montar o volume, então o container nunca inicia.

A seção Events mostrará:
```
Warning  FailedMount  ... configmap "does-not-exist" not found
```

**Correção:** Crie o ConfigMap ausente, ou corrija o nome na spec do Pod:
```bash
kubectl create configmap does-not-exist --from-literal=placeholder=value
```

> **Dica:** Você pode tornar a referência ao ConfigMap opcional usando `optional: true`:
> ```yaml
> volumes:
>   - name: config
>     configMap:
>       name: does-not-exist
>       optional: true
> ```
> Com `optional: true`, o Pod inicia mesmo se o ConfigMap não existir (o diretório de montagem ficará vazio).

</details>

### Cenário 2: Criação de Secret falha — valor não codificado em base64

Um desenvolvedor escreve um manifesto Secret manualmente mas recebe um erro:

```yaml
# broken-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: broken-secret
type: Opaque
data:
  password: NotBase64Encoded!@#
```

```bash
kubectl apply -f broken-secret.yaml
# Error: illegal base64 data at input byte ...
```

<details>
<summary>💡 Causa raiz & correção</summary>

O campo `data` requer valores **base64 válidos**. A string `NotBase64Encoded!@#` é texto simples, não base64.

**Opção de correção 1** — codifique o valor:
```bash
echo -n 'NotBase64Encoded!@#' | base64
# Output: Tm90QmFzZTY0RW5jb2RlZCFAIw==
```
Depois use o valor codificado em `data.password`.

**Opção de correção 2** — use `stringData` em vez de `data` (o Kubernetes codifica para você):
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: broken-secret
type: Opaque
stringData:
  password: "NotBase64Encoded!@#"
```

> **Regra geral:** Use `stringData` ao escrever manifestos manualmente. Use `data` apenas quando estiver gerando manifestos programaticamente e já tiver valores base64.

</details>

### Cenário 3: Variável de ambiente não atualiza após mudança no ConfigMap

Um desenvolvedor atualiza um ConfigMap e espera que o Pod em execução pegue a mudança, mas não pega:

```yaml
# env-no-refresh.yaml
apiVersion: v1
kind: Pod
metadata:
  name: env-no-refresh
spec:
  containers:
    - name: app
      image: busybox:1.37
      command: ["sh", "-c", "while true; do echo COLOR=$APP_COLOR; sleep 10; done"]
      env:
        - name: APP_COLOR
          valueFrom:
            configMapKeyRef:
              name: app-config
              key: APP_COLOR
```

```bash
kubectl apply -f env-no-refresh.yaml
kubectl logs env-no-refresh --tail=1         # COLOR=blue

kubectl patch configmap app-config -p '{"data":{"APP_COLOR":"green"}}'

kubectl logs env-no-refresh --tail=1         # Still COLOR=blue  ← not updated!
```

<details>
<summary>💡 Causa raiz & correção</summary>

**Variáveis de ambiente são injetadas no momento de início do container e nunca mudam.** Isso é idêntico a como processos Linux funcionam — se você faz `export VAR=val` e inicia um processo, alterar a variável no shell pai não afeta o processo filho em execução.

Diferente de ConfigMaps montados como volume (que o kubelet sincroniza automaticamente), env vars são estáticas durante toda a vida do container.

**Correção:** Reinicie o Pod para pegar os novos valores:
```bash
kubectl delete pod env-no-refresh
kubectl apply -f env-no-refresh.yaml
kubectl logs env-no-refresh --tail=1         # Agora: COLOR=green
```

**Padrão melhor:** Se você precisa de configuração hot-reloadable, monte o ConfigMap como volume e faça sua aplicação ler do arquivo. Ou use um Deployment e acione um rollout restart:
```bash
kubectl rollout restart deployment my-app
```

</details>
