# Solução 01 — Seu Primeiro Container

[< Voltar para o Desafio](../Student/Challenge-01.md) | **[Home](README.md)**

## Pré-verificação

Certifique-se de que os alunos tenham o Docker (ou Podman) instalado e em execução:

```bash
docker version
```

Saída esperada (os números de versão podem variar):

```
Client:
 Version:           27.x.x
 ...
Server:
 Engine:
  Version:          27.x.x
```

Se a seção **Server** estiver ausente, o daemon do Docker não está em execução — peça ao aluno para iniciá-lo (`sudo systemctl start docker` no Linux, ou inicie o Docker Desktop no macOS/Windows).

---

## Tarefa 1: Execute Seu Primeiro Container

### Passo a passo

Baixe e execute um container nginx, mapeando a porta 8080 do host para a porta 80 do container:

```bash
docker run -d --name web -p 8080:80 nginx
```

Saída esperada:

```
Unable to find image 'nginx:latest' locally
latest: Pulling from library/nginx
...
Status: Downloaded newer image for nginx:latest
a1b2c3d4e5f6...   # <- container ID
```

Verifique se o container está em execução:

```bash
docker ps
```

Saída esperada:

```
CONTAINER ID   IMAGE   COMMAND                  CREATED          STATUS          PORTS                  NAMES
a1b2c3d4e5f6   nginx   "/docker-entrypoint.…"   10 seconds ago   Up 9 seconds    0.0.0.0:8080->80/tcp   web
```

Teste se o nginx está servindo tráfego:

```bash
curl -s http://localhost:8080 | head -5
```

Saída esperada:

```html
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
<style>
```

### Verificação

- `docker ps` mostra o container `web` com status `Up`
- `curl http://localhost:8080` retorna a página de boas-vindas padrão do nginx

---

## Tarefa 2: Construa uma Imagem de Container Personalizada

### Passo a passo

Crie um diretório de projeto e os arquivos necessários:

```bash
mkdir -p ~/container-lab && cd ~/container-lab
```

Crie um arquivo HTML simples:

```bash
echo '<h1>Hello from my container!</h1>' > index.html
```

Crie o Dockerfile:

```bash
cat > Dockerfile <<'EOF'
FROM nginx:alpine
COPY index.html /usr/share/nginx/html/
EOF
```

Construa a imagem:

```bash
docker build -t myapp:v1 .
```

Saída esperada:

```
[+] Building 2.1s (7/7) FINISHED
 => [internal] load build definition from Dockerfile
 => [internal] load .dockerignore
 => [internal] load metadata for docker.io/library/nginx:alpine
 => [1/2] FROM docker.io/library/nginx:alpine
 => [2/2] COPY index.html /usr/share/nginx/html/
 => exporting to image
 => => naming to docker.io/library/myapp:v1
```

Execute a imagem personalizada:

```bash
docker run -d --name myapp -p 8081:80 myapp:v1
```

Teste:

```bash
curl -s http://localhost:8081
```

Saída esperada:

```html
<h1>Hello from my container!</h1>
```

Verifique se a imagem aparece no registro local:

```bash
docker images myapp
```

Saída esperada:

```
REPOSITORY   TAG   IMAGE ID       CREATED          SIZE
myapp        v1    abc123def456   30 seconds ago   ~50MB
```

### Verificação

- `docker images myapp` mostra `myapp:v1`
- `curl http://localhost:8081` retorna `<h1>Hello from my container!</h1>`

---

## Tarefa 3: Inspecione os Processos, Rede e Sistema de Arquivos do Container

### Passo a passo

Execute um shell dentro do container `web` (o nginx da Tarefa 1):

```bash
docker exec -it web sh
```

Uma vez dentro do container, execute estes comandos de diagnóstico:

**Liste os processos — PID 1 é o processo master do nginx:**

```bash
ps aux
```

Saída esperada:

```
PID   USER     TIME  COMMAND
    1 root      0:00 nginx: master process nginx -g daemon off;
   29 nginx     0:00 nginx: worker process
   ...
   35 root      0:00 sh
   36 root      0:00 ps aux
```

> **Nota para o Coach:** Destaque que o PID 1 é o nginx — não `init` ou `systemd`. O container possui seu próprio namespace de PID.

**Verifique a rede — o container tem seu próprio namespace de rede:**

```bash
ip addr
```

Saída esperada (o IP pode variar):

```
1: lo: <LOOPBACK,UP,LOWER_UP> ...
    inet 127.0.0.1/8 scope host lo
...
42: eth0@if43: <BROADCAST,MULTICAST,UP,LOWER_UP> ...
    inet 172.17.0.2/16 brd 172.17.255.255 scope global eth0
```

**Verifique o hostname:**

```bash
cat /etc/hostname
```

Saída esperada:

```
a1b2c3d4e5f6   # <- corresponde ao container ID
```

**Explore o sistema de arquivos:**

```bash
ls /usr/share/nginx/html/
cat /etc/os-release | head -3
```

Saia do shell do container:

```bash
exit
```

**Inspecione do lado do host — visualize os metadados do container como JSON:**

```bash
docker inspect web --format '{{.State.Pid}}'
```

Isto imprime o PID real do processo init do container no **host**. Os alunos podem verificar com:

```bash
# Apenas no Linux:
ps aux | grep <PID_from_above>
```

### Verificação

- Os alunos conseguem explicar que o PID 1 dentro do container é o processo da aplicação (nginx), não systemd/init
- Os alunos conseguem mostrar que o container tem seu próprio endereço IP (não o do host)
- Os alunos conseguem usar `docker inspect` para visualizar metadados do container a partir do host

---

## Tarefa 4: Explique Primitivas do Linux vs Containers

### Pontos de Discussão do Coach

Conduza os alunos por esta tabela e peça que confirmem cada conceito:

| Primitiva Linux | O Que Faz | Como os Containers Usam |
|---|---|---|
| **PID Namespace** | Isola a árvore de IDs de processo — o container vê o PID 1 como seu próprio processo init | `ps aux` dentro do container mostra apenas processos do container; o host vê o PID real |
| **NET Namespace** | Fornece ao container sua própria pilha de rede (IP, rotas, iptables) | `ip addr` mostra um IP diferente do host; a bridge `docker0` os conecta |
| **MNT Namespace** | Isola pontos de montagem — o container tem seu próprio sistema de arquivos raiz | `ls /` dentro do container mostra o sistema de arquivos da imagem, não o do host |
| **UTS Namespace** | Isola o hostname | `hostname` dentro do container mostra o ID do container, não o hostname do host |
| **cgroups** | Limita CPU, memória e I/O para um grupo de processos | `docker run --memory=128m --cpus=0.5` define limites de cgroup; exceder memória → OOMKill |

**Pergunta-chave para os alunos:** *"Qual é a diferença entre um container e uma máquina virtual?"*

**Resposta esperada:**
- Uma **VM** executa um sistema operacional completo com seu próprio kernel em um hypervisor. É pesada (GBs de memória, minutos para iniciar).
- Um **container** é um processo Linux normal com isolamento via namespaces e limites de cgroup. Ele compartilha o kernel do host. É leve (MBs de memória, milissegundos para iniciar).
- Containers **não** são VMs — são processos com limites extras de isolamento.

**Demo opcional — mostrando cgroups em ação:**

```bash
docker run -d --name limited --memory=32m --cpus=0.5 nginx
docker stats limited --no-stream
```

Saída esperada:

```
CONTAINER ID   NAME      CPU %   MEM USAGE / LIMIT   MEM %   ...
abc123def456   limited   0.00%   3.5MiB / 32MiB      10.94%  ...
```

> A coluna `LIMIT` mostra o limite de memória do cgroup.

### Verificação

- Os alunos conseguem articular que containers usam namespaces (PID, NET, MNT, UTS) para isolamento
- Os alunos conseguem articular que cgroups impõem limites de recursos
- Os alunos entendem que containers compartilham o kernel do host (diferente de VMs)

---

## Limpeza

```bash
docker stop web myapp limited 2>/dev/null
docker rm web myapp limited 2>/dev/null
docker rmi myapp:v1 2>/dev/null
```

---

## Problemas Comuns

| Problema | Sintoma | Correção |
|---|---|---|
| Daemon do Docker não está em execução | `Cannot connect to the Docker daemon` | Inicie o daemon: `sudo systemctl start docker` ou inicie o Docker Desktop |
| Porta 8080 já em uso | `Bind for 0.0.0.0:8080 failed: port is already allocated` | Use uma porta diferente (`-p 9090:80`) ou pare o que estiver usando a 8080 |
| Permissão negada no socket do Docker | `Got permission denied while trying to connect to the Docker daemon socket` | Adicione o usuário ao grupo docker: `sudo usermod -aG docker $USER` e faça logout/login |
| Comando `ps` não encontrado dentro do container | `sh: ps: not found` | A imagem base pode não ter procps. Instale: `apt-get update && apt-get install -y procps` (para imagens baseadas em Debian) |
| Comando `ip` não encontrado dentro do container | `sh: ip: not found` | Algumas imagens mínimas não incluem iproute2. Use `cat /proc/net/fib_trie` como alternativa, ou instale com `apt-get install -y iproute2` |
| Alunos confundem imagens e containers | Eles tentam `docker rm myapp:v1` | Explique: uma **imagem** é um modelo (como um `.iso`), um **container** é uma instância em execução. Use `docker rmi` para imagens, `docker rm` para containers |

