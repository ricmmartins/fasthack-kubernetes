# Desafio 01 — Seu Primeiro Container

[< Desafio Anterior](../README.md) | **[Início](../README.md)** | [Próximo Desafio >](Challenge-02.md)

## Introdução

Antes de entender Kubernetes, você precisa entender o que ele gerencia: **containers**.

Como profissional Linux, você já conhece processos, namespaces e cgroups. Um container é simplesmente um processo com isolamento extra — não é uma mini máquina virtual.

Neste desafio, você vai construir, executar e inspecionar containers para entender a fundação que o Kubernetes orquestra.

## Descrição

Sua missão é:

1. Executar seu primeiro container a partir de uma imagem pública
2. Construir uma imagem de container customizada a partir de um Dockerfile
3. Inspecionar os processos, rede e sistema de arquivos do container
4. Entender a relação entre primitivas Linux e o isolamento de containers

## Critérios de Sucesso

- [ ] Você consegue executar um container `nginx` e acessá-lo em `http://localhost:8080`
- [ ] Você construiu uma imagem customizada a partir de um Dockerfile e a executou
- [ ] Você consegue fazer exec em um container em execução e listar seus processos (`ps aux`)
- [ ] Você consegue explicar a diferença entre um container e uma máquina virtual
- [ ] Você entende como namespaces e cgroups do Linux se relacionam com o isolamento de containers

## Referência Linux ↔ Container

| Conceito Linux | Equivalente Container |
|---|---|
| Processo (`ps aux`) | Processo do container (PID 1) |
| `chroot` | Sistema de arquivos do container (rootfs) |
| Namespaces (PID, NET, MNT) | Isolamento do container |
| cgroups | Limites de recursos (CPU, memória) |
| `/etc/hosts`, DNS | Bridge de rede do container |
| Repositórios `apt` / `yum` | Registries de containers (Docker Hub, GHCR) |

## Dicas

<details>
<summary>Dica 1: Executando um container</summary>

```bash
docker run -d --name web -p 8080:80 nginx
```

Isso mapeia a porta 8080 do seu host para a porta 80 dentro do container.
</details>

<details>
<summary>Dica 2: Construindo uma imagem customizada</summary>

Crie um arquivo chamado `Dockerfile`:
```dockerfile
FROM nginx:alpine
COPY index.html /usr/share/nginx/html/
```

Construa:
```bash
echo "<h1>Hello from my container!</h1>" > index.html
docker build -t myapp:v1 .
docker run -d -p 8081:80 myapp:v1
```
</details>

<details>
<summary>Dica 3: Inspecionando processos dentro de um container</summary>

```bash
docker exec -it web sh
ps aux
ip addr
cat /etc/hostname
exit
```

Observe: PID 1 é o nginx — o container tem seu próprio namespace de processos.
</details>

## Recursos de Aprendizado

- [Documentação Docker — Primeiros Passos](https://docs.docker.com/get-started/)
- [O que é um Container? (Docker)](https://www.docker.com/resources/what-container/)
- [Linux Namespaces — man7.org](https://man7.org/linux/man-pages/man7/namespaces.7.html)
- [cgroups — Documentação do Kernel](https://docs.kernel.org/admin-guide/cgroup-v2.html)

## Break & Fix 🔧

Após completar o desafio, tente isto:

1. Execute um container com `--memory=32m` e veja o que acontece quando o processo ultrapassa esse limite
2. Execute um container com `--read-only` e tente escrever um arquivo dentro dele
3. Execute dois containers e tente fazer `ping` entre eles — qual rede eles compartilham?
