# Solução 02 — Do Container ao Pod

[< Voltar para o Desafio](../Student/Challenge-02.md) | **[Home](README.md)**

## Pré-verificação

Certifique-se de que os alunos tenham um cluster Kind em execução e o `kubectl` configurado:

```bash
kubectl cluster-info
```

Saída esperada:

```
Kubernetes control plane is running at https://127.0.0.1:XXXXX
CoreDNS is running at https://127.0.0.1:XXXXX/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy
```

Se o cluster não existir, crie um:

```bash
kind create cluster --name fasthack
```

---

## Tarefa 1: Crie um Pod a partir de um Manifesto YAML

### Passo a passo

Crie o arquivo de manifesto do Pod `nginx-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx
  labels:
    app: nginx
spec:
  containers:
    - name: nginx
      image: nginx:stable
      ports:
        - containerPort: 80
```

Aplique ao cluster:

```bash
kubectl apply -f nginx-pod.yaml
```

Saída esperada:

```
pod/nginx created
```

Acompanhe o Pod até atingir o status `Running`:

```bash
kubectl get pods -w
```

Saída esperada:

```
NAME    READY   STATUS              RESTARTS   AGE
nginx   0/1     ContainerCreating   0          2s
nginx   1/1     Running             0          5s
```

Pressione `Ctrl+C` para parar de acompanhar.

### Verificação

```bash
kubectl get pods
```

Saída esperada:

```
NAME    READY   STATUS    RESTARTS   AGE
nginx   1/1     Running   0          30s
```

O Pod mostra `1/1` Ready e status `Running`.

---

## Tarefa 2: Inspecione o Pod

### Passo a passo

**Liste os Pods com detalhes estendidos:**

```bash
kubectl get pods -o wide
```

Saída esperada:

```
NAME    READY   STATUS    RESTARTS   AGE   IP           NODE                     NOMINATED NODE   READINESS GATES
nginx   1/1     Running   0          1m    10.244.0.5   fasthack-control-plane   <none>           <none>
```

> **Nota para o Coach:** Explique cada coluna:
> - `READY` — containers prontos / total de containers (1/1 significa 1 container, 1 pronto)
> - `IP` — o IP interno do Pod no cluster (não acessível do host, apenas de dentro do cluster)
> - `NODE` — em qual nó do cluster o Pod foi agendado

**Descreva o Pod em detalhes:**

```bash
kubectl describe pod nginx
```

Saída esperada (seções principais):

```
Name:             nginx
Namespace:        default
Priority:         0
Service Account:  default
Node:             fasthack-control-plane/172.18.0.2
Start Time:       ...
Labels:           app=nginx
Status:           Running
IP:               10.244.0.5
Containers:
  nginx:
    Container ID:   containerd://abc123...
    Image:          nginx:stable
    Port:           80/TCP
    State:          Running
      Started:      ...
    Ready:          True
    Restart Count:  0
...
Events:
  Type    Reason     Age   From               Message
  ----    ------     ----  ----               -------
  Normal  Scheduled  1m    default-scheduler  Successfully assigned default/nginx to fasthack-control-plane
  Normal  Pulling    1m    kubelet            Pulling image "nginx:stable"
  Normal  Pulled     55s   kubelet            Successfully pulled image "nginx:stable"
  Normal  Created    55s   kubelet            Created container nginx
  Normal  Started    55s   kubelet            Started container nginx
```

> **Nota para o Coach:** A seção **Events** na parte inferior é a ferramenta de diagnóstico mais importante. Conduza os alunos pelo ciclo de vida: Scheduled → Pulling → Pulled → Created → Started.

**Visualize os logs do container:**

```bash
kubectl logs nginx
```

Saída esperada (o log de acesso do nginx pode estar vazio se nada o acessou ainda):

```
/docker-entrypoint.sh: /docker-entrypoint.d/ is not empty, will attempt to perform configuration
/docker-entrypoint.sh: Looking for shell scripts in /docker-entrypoint.d/
...
```

Para acompanhar os logs em tempo real (como `tail -f`):

```bash
kubectl logs nginx --follow
```

Pressione `Ctrl+C` para parar de acompanhar.

### Verificação

- `kubectl get pods -o wide` mostra IP, nó e status
- `kubectl describe pod nginx` mostra o ciclo de vida completo nos eventos
- `kubectl logs nginx` mostra o stdout do container

---

## Tarefa 3: Exec no Pod

### Passo a passo

Abra um shell interativo dentro do container:

```bash
kubectl exec -it nginx -- /bin/sh
```

> **Nota para o Coach:** O `--` separa os argumentos do kubectl do comando a ser executado dentro do container. É o mesmo padrão do `docker exec`.

Uma vez dentro, execute comandos de diagnóstico:

**Liste os processos (PID 1 é o master do nginx):**

```bash
ps aux
```

Saída esperada:

```
PID   USER     TIME  COMMAND
    1 root      0:00 nginx: master process nginx -g daemon off;
   29 nginx     0:00 nginx: worker process
   ...
```

> Se `ps` não for encontrado, use: `apt-get update && apt-get install -y procps` e tente novamente.

**Verifique o endereço IP do Pod:**

```bash
ip addr
```

Ou se `ip` não estiver disponível:

```bash
cat /proc/net/fib_trie | head -20
hostname -i
```

**Verifique o hostname (corresponde ao nome do Pod):**

```bash
cat /etc/hostname
```

Saída esperada:

```
nginx
```

**Verifique se o localhost está servindo tráfego:**

```bash
curl -s http://localhost:80 | head -5
```

> Se `curl` não estiver instalado: `apt-get update && apt-get install -y curl`

Saída esperada:

```html
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
<style>
```

Saia do shell:

```bash
exit
```

### Verificação

- Os alunos conseguem executar exec no Pod e rodar comandos
- Eles conseguem confirmar que o hostname corresponde ao nome do Pod
- Eles conseguem comparar a experiência com `docker exec` do Desafio 01

---

## Tarefa 4: Delete o Pod e Observe o Ciclo de Vida

### Passo a passo

Delete o Pod:

```bash
kubectl delete pod nginx
```

Saída esperada:

```
pod "nginx" deleted
```

> Isso pode levar alguns segundos — o Kubernetes envia SIGTERM, aguarda o período de graça (padrão 30s) e então envia SIGKILL.

Em um **terminal separado** (antes de deletar), você pode acompanhar o ciclo de vida:

```bash
kubectl get pods -w
```

Saída esperada:

```
NAME    READY   STATUS        RESTARTS   AGE
nginx   1/1     Terminating   0          5m
nginx   0/1     Terminating   0          5m
```

Após alguns segundos, o Pod desaparece completamente.

Confirme que ele foi removido:

```bash
kubectl get pods
```

Saída esperada:

```
No resources found in default namespace.
```

> **Nota para o Coach — Momento-chave de ensino:** O Pod **não** é recriado. Isso porque um Pod sem controller não tem nada gerenciando-o. É como executar `kill <pid>` em um processo que não tem uma unit do systemd para reiniciá-lo. No Desafio 04, os alunos aprenderão sobre Deployments, que **reiniciam** Pods automaticamente.

### Verificação

- O Pod passa por `Terminating` e é completamente removido
- `kubectl get pods` não mostra recursos no namespace default
- Os alunos entendem que Pods sem controller não se auto-recuperam

---

## Problemas Comuns

| Problema | Sintoma | Correção |
|---|---|---|
| Nenhum cluster em execução | `The connection to the server localhost:8080 was refused` | Crie um cluster: `kind create cluster --name fasthack` |
| Contexto errado selecionado | kubectl se comunica com o cluster errado | Verifique: `kubectl config current-context` — mude: `kubectl config use-context kind-fasthack` |
| ImagePullBackOff | Pod preso em `ErrImagePull` ou `ImagePullBackOff` | Verifique o nome/tag da imagem: `kubectl describe pod nginx` → veja os Events. Causa comum: erro de digitação no nome da imagem |
| `exec` falha com "pod not found" | O aluno deletou o Pod antes do exec | Recrie: `kubectl apply -f nginx-pod.yaml` |
| `ps` ou `curl` não encontrados dentro do container | Imagem base mínima | Instale as ferramentas: `apt-get update && apt-get install -y procps curl iproute2` |
| Alunos usam `kubectl create` e recebem "AlreadyExists" | Eles aplicaram o YAML duas vezes com `create` | Explique: use `kubectl apply` (idempotente) em vez de `kubectl create`. Ou delete primeiro: `kubectl delete pod nginx` |
| Alunos esperam que o Pod reinicie após deletar | Eles acham que Pods se auto-recuperam | Explique: Pods sem controller são como processos sem supervisor. Deployments (Desafio 04) fornecem auto-recuperação |

