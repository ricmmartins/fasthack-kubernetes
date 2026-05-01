# Desafio 02 — De Container para Pod

[< Desafio Anterior](Challenge-01.md) | **[Início](../README.md)** | [Próximo Desafio >](Challenge-03.md)

## Introdução

No Desafio 01 você construiu e executou containers com Docker — o equivalente a iniciar processos individuais em uma máquina Linux. Agora é hora de entregar esses containers ao Kubernetes.

No Linux, processos relacionados são frequentemente agrupados em um **grupo de processos** para que o kernel possa gerenciá-los como uma unidade (pense em um processo pai e seus filhos compartilhando uma sessão). Kubernetes tem a mesma ideia: um **Pod** é a menor unidade implantável e ele envolve **um ou mais containers** que compartilham:

| Recurso compartilhado | O que significa |
|---|---|
| **Network namespace** | Todos os containers no Pod compartilham o mesmo endereço IP e espaço de portas — assim como processos no mesmo network namespace no Linux. |
| **Volumes de armazenamento** | Containers em um Pod podem montar os mesmos volumes — similar a processos lendo/escrevendo no mesmo caminho do sistema de arquivos. |
| **Ciclo de vida** | Containers em um Pod são agendados, iniciados e parados juntos — como um grupo de processos recebendo o mesmo sinal. |

Um Pod **não** é uma VM e **não** é um container. É um invólucro fino que diz ao Kubernetes: *"execute esses containers juntos no mesmo node e deixe-os se comunicar via localhost."*

Neste desafio você vai criar seu primeiro Pod usando um manifesto YAML, inspecioná-lo da mesma forma que inspecionaria um processo Linux, fazer exec nele assim como faria com `docker exec`, e observar o que acontece quando um Pod é deletado.

> **Requisito de cluster:** Todos os exercícios usam um cluster local [Kind](https://kind.sigs.k8s.io/) — nenhuma conta de nuvem necessária. Se ainda não criou um, execute:
> ```bash
> kind create cluster --name fasthack
> ```

## Descrição

1. **Criar um Pod a partir de um manifesto YAML**
   Escreva um arquivo chamado `nginx-pod.yaml` que defina um único Pod executando a imagem `nginx:stable`. Aplique-o ao seu cluster Kind com `kubectl apply`.

2. **Inspecionar o Pod**
   Use `kubectl get`, `kubectl describe` e `kubectl logs` para examinar o status do Pod, eventos, endereço IP e saída do container — da mesma forma que você usaria `ps`, `journalctl` ou `cat /proc` no Linux.

3. **Fazer exec no Pod**
   Abra um shell interativo dentro do container em execução com `kubectl exec`. Compare a experiência com `docker exec` do Desafio 01. Execute alguns comandos de diagnóstico dentro do Pod para provar que o container é apenas um processo Linux com seus próprios namespaces.

4. **Deletar o Pod e observar o ciclo de vida**
   Delete o Pod com `kubectl delete` e observe o que acontece. Diferente de um Deployment (que você conhecerá depois), um Pod isolado **não** é reiniciado automaticamente — assim como um processo que você mata com `kill` sem um daemon supervisor para reiniciá-lo.

## Critérios de Sucesso

- [ ] Você criou um Pod usando um manifesto YAML e ele atinge o estado `Running`.
- [ ] Você consegue obter detalhes do Pod com `kubectl get pods -o wide` e explicar as colunas de saída.
- [ ] Você consegue fazer exec no Pod e executar comandos dentro do container.
- [ ] Você consegue visualizar logs do container com `kubectl logs`.
- [ ] Você consegue articular a diferença entre um **container** e um **Pod** (um Pod pode conter múltiplos containers que compartilham rede e armazenamento; um container é um único processo/imagem).
- [ ] Após deletar o Pod, você observa que ele **não** é recriado automaticamente.

## Referência Linux ↔ Kubernetes

| Conceito Linux | Equivalente Kubernetes | Notas |
|---|---|---|
| Processo / grupo de processos | Pod | Um Pod é um grupo de um ou mais containers agendados juntos. |
| PID | Nome do Pod | O identificador único usado para interagir com o workload. |
| `ps aux` | `kubectl get pods` | Listar workloads em execução e seu status. |
| `ps aux -o pid,stat,cmd` | `kubectl get pods -o wide` | Saída expandida com node, IP e mais. |
| `kill <pid>` | `kubectl delete pod <name>` | Termina o workload (SIGTERM → SIGKILL após período de graça). |
| `docker exec -it <ctr> sh` | `kubectl exec -it <pod> -- /bin/sh` | Abre um shell interativo dentro do container em execução. |
| `docker logs <ctr>` | `kubectl logs <pod>` | Transmite stdout/stderr do container. |
| `/proc/<pid>/status` | `kubectl describe pod <name>` | Status detalhado, eventos e informações de recursos. |

## Dicas

<details>
<summary>Dica 1: Criando um manifesto YAML de Pod</summary>

Crie um arquivo chamado `nginx-pod.yaml`:

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

Aplique-o:

```bash
kubectl apply -f nginx-pod.yaml
```

Verifique:

```bash
kubectl get pods
```

Você deve ver o Pod transicionar de `ContainerCreating` para `Running`.

</details>

<details>
<summary>Dica 2: Inspecionando o Pod</summary>

**Listar Pods com detalhes extras (como `ps aux` no Linux):**

```bash
kubectl get pods -o wide
```

Isso mostra o IP do Pod, o node onde está rodando e o status do container.

**Descrever o Pod (como ler `/proc/<pid>/status`):**

```bash
kubectl describe pod nginx
```

Procure a seção **Events** na parte inferior — ela mostra o scheduler atribuindo o Pod a um node, o kubelet puxando a imagem e o container iniciando.

**Visualizar logs do container (como `docker logs` ou `journalctl`):**

```bash
kubectl logs nginx
```

Para seguir logs em tempo real (como `tail -f`):

```bash
kubectl logs nginx --follow
```

</details>

<details>
<summary>Dica 3: Fazer exec no Pod</summary>

Abra um shell dentro do container em execução:

```bash
kubectl exec -it nginx -- /bin/sh
```

Uma vez dentro, explore — assim como faria em qualquer máquina Linux:

```bash
# What processes are running? (PID 1 is nginx master)
ps aux

# What IP address does this Pod have?
ip addr

# What is the hostname? (it matches the Pod name)
cat /etc/hostname

# Can you reach localhost:80?
curl -s http://localhost:80 | head -5

# Exit the shell
exit
```

Compare isso com `docker exec -it <container_id> /bin/sh` do Desafio 01 — a experiência é quase idêntica porque por baixo dos panos, `kubectl exec` faz a mesma coisa: conecta-se aos namespaces do container.

</details>

<details>
<summary>Dica 4: Deletando um Pod e observando o ciclo de vida</summary>

Delete o Pod:

```bash
kubectl delete pod nginx
```

Observe-o desaparecer:

```bash
kubectl get pods --watch
```

O Pod passa por `Terminating` e depois é removido. **Ele não volta** — não há um controller (como um Deployment) monitorando-o. Isso é equivalente a executar `kill <pid>` em um processo que não tem unit do systemd ou supervisor para reiniciá-lo.

</details>

## Recursos de Aprendizado

- [Pods — Documentação oficial Kubernetes](https://kubernetes.io/docs/concepts/workloads/pods/)
- [Referência Rápida kubectl](https://kubernetes.io/docs/reference/kubectl/)
- [kubectl exec](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_exec/)
- [kubectl logs](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_logs/)
- [Ciclo de Vida do Pod](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/)
- [Kind — Quick Start](https://kind.sigs.k8s.io/docs/user/quick-start/)

## Break & Fix 🔧

Tente cada cenário, diagnostique o problema e corrija-o.

### Cenário 1 — ImagePullBackOff

Crie um Pod com um nome de imagem deliberadamente incorreto:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: broken-image
spec:
  containers:
    - name: web
      image: nginx:this-tag-does-not-exist
```

```bash
kubectl apply -f broken-image.yaml
kubectl get pods --watch
```

**O que você verá:** O Pod fica em `ErrImagePull` e depois `ImagePullBackOff`.

**Diagnostique:** `kubectl describe pod broken-image` — procure na seção Events o erro de pull.

**Corrija:** Edite o YAML para usar uma tag válida (ex: `nginx:stable`), delete o Pod quebrado e re-aplique.

---

### Cenário 2 — CrashLoopBackOff

Crie um Pod cujo comando termina imediatamente:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: crash-loop
spec:
  containers:
    - name: app
      image: busybox:stable
      command: ["sh", "-c", "echo 'goodbye'; exit 1"]
```

```bash
kubectl apply -f crash-loop.yaml
kubectl get pods --watch
```

**O que você verá:** O Pod entra em `CrashLoopBackOff` — o Kubernetes continua reiniciando o container, com intervalos de back-off crescentes.

**Diagnostique:** `kubectl logs crash-loop` mostra a saída antes do crash. `kubectl describe pod crash-loop` mostra a contagem de reinicializações subindo.

**Analogia Linux:** Isso é como um processo que dá segfault na inicialização enquanto o systemd continua tentando reiniciá-lo (`Restart=always`).

**Corrija:** Mude o comando para algo que continue rodando (ex: `["sh", "-c", "echo 'hello'; sleep 3600"]`), delete o Pod e re-aplique.

---

### Cenário 3 — Nome de Pod duplicado

Tente criar dois Pods com o mesmo nome:

```bash
kubectl apply -f nginx-pod.yaml
kubectl apply -f nginx-pod.yaml
```

**O que você verá:** O segundo `apply` **não** falha — ele atualiza o Pod existente (operação idempotente). Agora tente com `kubectl create`:

```bash
kubectl delete pod nginx
kubectl create -f nginx-pod.yaml
kubectl create -f nginx-pod.yaml
```

**O que você verá:** O segundo `create` falha com: `Error from server (AlreadyExists): pods "nginx" already exists`.

**Lição:** `kubectl apply` é declarativo e idempotente (como `ansible`). `kubectl create` é imperativo e falha se o recurso já existe. Na prática, prefira `apply`.

**Analogia Linux:** É como a diferença entre `mkdir -p /data` (idempotente, sem erro se já existe) e `mkdir /data` (falha se já existe).
