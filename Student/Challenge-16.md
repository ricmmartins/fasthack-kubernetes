# Desafio 16 — Engenharia de Imagens de Container

[< Desafio Anterior](Challenge-15.md) - **[Início](../README.md)** - [Próximo Desafio >](Challenge-17.md)

## Introdução

Se você já provisionou um servidor Linux do zero, conhece o ritual: começar com uma instalação mínima (talvez um ISO netinstall), executar um shell script que instala pacotes (`apt-get install -y nginx curl`), copia arquivos de configuração para o lugar certo, abre portas no firewall e define o comando de inicialização (`systemctl enable nginx`). Esse shell script **é** a receita de construção do seu servidor — execute-o em uma VM nova e você obtém uma máquina idêntica toda vez.

Um **Dockerfile** é exatamente esse shell script, mas para containers. Cada instrução (`FROM`, `RUN`, `COPY`, `CMD`) mapeia diretamente para um passo no seu script de provisionamento. A diferença é que o Docker captura cada passo como uma **camada de imagem imutável**, então você obtém cache, reprodutibilidade e portabilidade que shell scripts em bare metal só podem sonhar.

No mundo Linux, você provavelmente também já fez isso: compilou software em um chroot de build ou uma VM de build robusta (com `gcc`, `make`, arquivos header), depois copiou apenas o binário final para um servidor de produção mínimo que não tem nenhuma ferramenta de build. Isso é exatamente o que **multi-stage builds** fazem — compilar em um estágio, copiar o artefato para um estágio de runtime mínimo.

E assim como você escolheria entre Ubuntu Server (completo, grande) e Alpine Linux (mínimo, pequeno) como seu sistema operacional base, você escolherá entre imagens base `ubuntu`, `alpine` e `distroless` dependendo se precisa de um shell para depuração ou quer a menor superfície de ataque possível.

Neste desafio, você escreverá Dockerfiles do zero, otimizará imagens com multi-stage builds, comparará estratégias de imagem base, trabalhará com registries (como fazer push de RPMs para um repositório yum) e carregará imagens personalizadas no seu cluster Kind para deployment.

## Descrição

### Tarefa 1 — Escrever um Dockerfile para uma Aplicação Web Simples

Assim como escrever um shell script que provisiona uma VM nova, você escreverá um Dockerfile que constrói uma imagem de container para uma aplicação web Python simples.

Crie um diretório de projeto e os arquivos da aplicação:

```bash
mkdir -p ~/image-lab && cd ~/image-lab
```

Crie uma aplicação web Python simples:

```python
# app.py
from http.server import HTTPServer, BaseHTTPRequestHandler
import os

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        msg = os.getenv("APP_MESSAGE", "Hello from my custom image!")
        self.wfile.write(f"{msg}\n".encode())

    def log_message(self, format, *args):
        print(f"[request] {args[0]}")

if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", 8080), Handler)
    print("Server running on port 8080...")
    server.serve_forever()
```

Crie um `requirements.txt` (vazio para esta aplicação, mas é boa prática):

```
# requirements.txt
# Sem dependências externas — apenas stdlib
```

Agora escreva um `Dockerfile` que:
- Começa da imagem base `python:3.12-slim`
- Define um diretório de trabalho (`/app`)
- Copia o arquivo de requirements e instala dependências
- Copia o código da aplicação
- Expõe a porta 8080
- Define o comando de inicialização para executar a aplicação

Construa e teste:

```bash
docker build -t myapp:v1 .
docker run --rm -p 8080:8080 myapp:v1
# Em outro terminal:
curl http://localhost:8080
```

> **Analogia com Linux:** `FROM python:3.12-slim` = escolher seu sistema operacional base. `RUN pip install` = executar seu script de provisionamento. `COPY . .` = implantar seus arquivos de aplicação. `CMD` = definir o serviço padrão para iniciar.

### Tarefa 2 — Otimizar com Multi-Stage Builds

Multi-stage builds são como compilar em um chroot de build (com todos os compiladores e headers), depois copiar apenas o binário final para um rootfs mínimo para produção.

Crie uma aplicação web Go para demonstrar o poder dos multi-stage builds:

```go
// main.go
package main

import (
	"fmt"
	"net/http"
	"os"
)

func main() {
	msg := os.Getenv("APP_MESSAGE")
	if msg == "" {
		msg = "Hello from Go multi-stage build!"
	}
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "%s\n", msg)
	})
	fmt.Println("Server running on port 8080...")
	http.ListenAndServe(":8080", nil)
}
```

Inicialize o módulo Go:

```bash
go mod init myapp
```

> **Nota:** Se você não tem Go instalado localmente, tudo bem — o Docker usará o toolchain Go dentro do estágio de build. Você pode criar `go.mod` manualmente:
> ```
> module myapp
> go 1.22
> ```

Escreva primeiro um Dockerfile de **estágio único** (`Dockerfile.single`):
- Use `golang:1.22` como imagem base
- Copie o código fonte, compile com `go build` e execute

Depois escreva um Dockerfile **multi-stage** (`Dockerfile.multi`):
- **Estágio 1 (builder):** Use `golang:1.22` — copie o fonte, execute `CGO_ENABLED=0 go build -o /app`
- **Estágio 2 (runtime):** Use `alpine:3.20` — copie apenas o binário compilado do Estágio 1, exponha a porta 8080, defina o CMD

Construa ambos e compare os tamanhos das imagens:

```bash
docker build -t myapp:single -f Dockerfile.single .
docker build -t myapp:multi -f Dockerfile.multi .
docker images | grep myapp
```

A imagem multi-stage deve ser **dramaticamente** menor (megabytes vs gigabytes).

> **Analogia com Linux:** O Estágio 1 é sua VM de build com `gcc`, `make` e todos os headers de desenvolvimento. O Estágio 2 é seu servidor de produção — você faz `scp` apenas do binário compilado e nada mais.

### Tarefa 3 — Comparar Tamanhos de Imagem Base

Assim como escolher entre Ubuntu Server (completo) vs Alpine (mínimo) vs um rootfs busybox reduzido, sua escolha de imagem base afeta dramaticamente o tamanho da imagem e a superfície de ataque.

Construa a mesma aplicação Go com três bases de runtime diferentes:

1. **Baseada em Ubuntu:** Use `ubuntu:24.04` como estágio de runtime
2. **Baseada em Alpine:** Use `alpine:3.20` como estágio de runtime
3. **Distroless:** Use `gcr.io/distroless/static-debian12:nonroot` como estágio de runtime

Escreva três Dockerfiles (ou parametrize usando build args) e compare:

```bash
docker images | grep myapp
```

Crie uma tabela comparativa dos resultados — observe os tamanhos das imagens e pense sobre os trade-offs:
- Qual imagem tem um shell no qual você pode fazer `exec` para depuração?
- Qual imagem tem a menor superfície de ataque?
- Qual você usaria em produção vs desenvolvimento?

### Tarefa 4 — Criar um Arquivo .dockerignore

Assim como `.gitignore` impede que arquivos indesejados entrem no seu repositório, `.dockerignore` impede que arquivos indesejados entrem no seu contexto de build.

Primeiro, observe o contexto de build **sem** um `.dockerignore`. Crie alguns arquivos que não deveriam estar na sua imagem:

```bash
# Crie arquivos que NÃO devem estar na imagem
echo "SECRET_KEY=supersecret" > .env
mkdir -p .git && echo "git data" > .git/HEAD
dd if=/dev/zero of=large-test-data.bin bs=1M count=50
```

Construa e verifique o tamanho do contexto de build na saída:

```bash
docker build -t myapp:no-ignore .
```

Procure pela linha: `Sending build context to Docker daemon  XX.XXB` (ou progresso equivalente no BuildKit).

Agora crie um arquivo `.dockerignore`:

```
# .dockerignore
.git
.env
*.bin
*.md
Dockerfile*
.dockerignore
__pycache__
*.pyc
.venv
node_modules
```

Reconstrua e compare o tamanho do contexto de build:

```bash
docker build -t myapp:with-ignore .
```

O contexto de build deve ser significativamente menor. Verifique que os arquivos excluídos não estão na imagem:

```bash
docker run --rm myapp:with-ignore ls -la /app/
```

### Tarefa 5 — Tag e Push para um Registry Local

Trabalhar com registries é como fazer push de pacotes para um repositório apt/yum para que outras máquinas possam instalá-los.

Inicie um registry local (imagem oficial `registry:2` do Docker):

```bash
docker run -d -p 5000:5000 --name local-registry registry:2
```

Adicione uma tag à sua imagem para o registry local e faça push:

```bash
docker tag myapp:multi localhost:5000/myapp:v1
docker tag myapp:multi localhost:5000/myapp:latest
docker push localhost:5000/myapp:v1
docker push localhost:5000/myapp:latest
```

Verifique que a imagem está no registry:

```bash
curl http://localhost:5000/v2/_catalog
curl http://localhost:5000/v2/myapp/tags/list
```

Agora delete a cópia local e faça pull do registry para provar que funciona:

```bash
docker rmi localhost:5000/myapp:v1
docker pull localhost:5000/myapp:v1
docker run --rm -p 8080:8080 localhost:5000/myapp:v1
```

> **Analogia com Linux:** `docker push` = `rpm --addsign && createrepo` (assinar e publicar no seu repositório). `docker pull` = `yum install` (baixar do repositório). O registry é seu mirror privado de pacotes.

### Tarefa 6 — Build com Podman (Rootless)

No Linux, executar builds como root é um risco de segurança — assim como você evitaria executar `make install` como root quando pode usar `fakeroot` ou user namespaces. Podman constrói imagens **sem root** por padrão — sem daemon, sem privilégios de root.

Construa a mesma imagem com Podman:

```bash
podman build -t myapp:podman -f Dockerfile.multi .
podman images | grep myapp
```

Compare a experiência:
- A sintaxe do Dockerfile muda? (Não — Podman usa o mesmo formato de Dockerfile)
- Podman precisa de um daemon em execução? (Não — é daemonless)
- Você pode executar builds do Podman como usuário não-root? (Sim — por padrão)

Execute a imagem construída com Podman:

```bash
podman run --rm -p 8081:8080 myapp:podman
curl http://localhost:8081
```

> **Nota:** Se Podman não está instalado no seu sistema, instale-o:
> - **Ubuntu/Debian:** `sudo apt-get install -y podman`
> - **Fedora/RHEL:** `sudo dnf install -y podman`
> - **macOS:** `brew install podman && podman machine init && podman machine start`
>
> Se você não conseguir instalar o Podman, documente os comandos que executaria e anote as diferenças em relação ao Docker nas suas notas. Esta tarefa é opcional mas recomendada.

### Tarefa 7 — Carregar uma Imagem Personalizada no Kind e Fazer Deploy

Clusters Kind executam dentro de containers Docker, então não podem fazer pull do seu cache local de imagens Docker diretamente. Você precisa carregar imagens explicitamente no cluster.

Carregue sua imagem multi-stage no cluster Kind:

```bash
kind load docker-image myapp:multi --name fasthack
```

Verifique que a imagem está disponível dentro do node Kind:

```bash
docker exec -it fasthack-control-plane crictl images | grep myapp
```

Agora faça deploy como um Pod:

```yaml
# custom-image-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: custom-app
spec:
  containers:
    - name: app
      image: myapp:multi
      imagePullPolicy: Never
      ports:
        - containerPort: 8080
      env:
        - name: APP_MESSAGE
          value: "Hello from my custom Kind image!"
```

```bash
kubectl apply -f custom-image-pod.yaml
kubectl get pod custom-app
kubectl port-forward pod/custom-app 8080:8080
# Em outro terminal:
curl http://localhost:8080
```

> **Crítico:** `imagePullPolicy: Never` diz ao Kubernetes para não tentar puxar a imagem de um registry — ela já deve existir no node. Sem isso, o Pod falhará com `ErrImagePull` porque `myapp:multi` não existe em nenhum registry.

## Critérios de Sucesso

- [ ] Você escreveu um Dockerfile do zero com `FROM`, `COPY`, `RUN`, `EXPOSE` e `CMD` — e a imagem construída executa corretamente (Tarefa 1)
- [ ] Você construiu um Dockerfile multi-stage e a imagem de runtime é significativamente menor que a imagem de estágio único (Tarefa 2)
- [ ] Você comparou tamanhos de imagem entre bases `ubuntu`, `alpine` e `distroless` e consegue explicar os trade-offs (Tarefa 3)
- [ ] Você criou um arquivo `.dockerignore` e confirmou que o tamanho do contexto de build diminuiu (Tarefa 4)
- [ ] Você fez push de uma imagem para um `registry:2` local e fez pull de volta com sucesso (Tarefa 5)
- [ ] Você construiu uma imagem com Podman e confirmou que produz o mesmo resultado que o Docker (Tarefa 6 — opcional se Podman não estiver disponível)
- [ ] Você carregou uma imagem personalizada no Kind com `kind load docker-image` e fez deploy como um Pod com `imagePullPolicy: Never` (Tarefa 7)
- [ ] O Pod está Running e responde ao `curl` via `port-forward` (Tarefa 7)

## Referência Linux ↔ Kubernetes

| Conceito Linux | Equivalente Container/Kubernetes |
|---|---|
| Shell script de provisionamento (`setup.sh`) | Dockerfile (`FROM`, `RUN`, `COPY`, `CMD`) |
| `chroot` + `debootstrap` (criar um rootfs mínimo) | Imagem base `FROM` (ex: `alpine:3.20`, `ubuntu:24.04`) |
| Compilar em VM de build, copiar binário para servidor de produção | Multi-stage build (estágio de build → estágio de runtime) |
| Repositório de pacotes RPM/DEB (`yum repo`, `apt repo`) | Container registry (`registry:2`, Docker Hub, GHCR) |
| Versões de pacotes (`nginx-1.27.0-1.el9.x86_64`) | Tags de imagem (`myapp:v1`, `myapp:latest`, `myapp:v1.2.3`) |
| `.gitignore` (excluir arquivos do repo) | `.dockerignore` (excluir arquivos do contexto de build) |
| `su` / `sudo` para builds (executar como root) | Podman rootless (build sem privilégios de root) |
| `scp binary user@prod:/usr/local/bin/` | `COPY --from=builder /app /app` (copiar do estágio de build) |
| `rpm -qa \| wc -l` (contar pacotes instalados) | `docker images` / `docker history` (verificar camadas e tamanhos de imagem) |
| Instalação mínima (ISO netinstall) | Imagens distroless (sem shell, sem gerenciador de pacotes) |

## Dicas

<details>
<summary>Dica 1: Estrutura básica do Dockerfile</summary>

Um Dockerfile segue este padrão — pense nele como seu script de provisionamento de servidor:

```dockerfile
# Passo 1: Escolha seu SO base (como escolher um ISO Linux)
FROM python:3.12-slim

# Passo 2: Defina onde você vai trabalhar (como cd /opt/myapp)
WORKDIR /app

# Passo 3: Instale dependências primeiro (para cache de camadas)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Passo 4: Copie o código da sua aplicação
COPY app.py .

# Passo 5: Documente a porta (como abrir uma porta no firewall)
EXPOSE 8080

# Passo 6: Defina o comando de inicialização (como systemctl start)
CMD ["python", "app.py"]
```

**Otimização chave:** Copie `requirements.txt` e instale dependências **antes** de copiar o código da aplicação. Dessa forma, o Docker faz cache da camada de dependências e só a reconstrói quando `requirements.txt` muda — não toda vez que você edita `app.py`.

</details>

<details>
<summary>Dica 2: Padrão de multi-stage build</summary>

A sintaxe chave é nomear estágios com `AS` e copiar entre eles com `COPY --from=`:

```dockerfile
# Estágio 1: Ambiente de build (como sua VM de build)
FROM golang:1.22 AS builder
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -o /app

# Estágio 2: Ambiente de runtime (como seu servidor de produção)
FROM alpine:3.20
COPY --from=builder /app /app
EXPOSE 8080
CMD ["/app"]
```

`CGO_ENABLED=0` produz um binário estaticamente linkado que não precisa de glibc — isso é o que permite executá-lo no `alpine` ou até em `distroless` (que não tem biblioteca C).

</details>

<details>
<summary>Dica 3: Imagens distroless — sem shell, sem gerenciador de pacotes</summary>

Imagens distroless do Google contêm **apenas** sua aplicação e suas dependências de runtime. Sem shell, sem `ls`, sem `cat`, sem gerenciador de pacotes.

```dockerfile
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /app /app
EXPOSE 8080
CMD ["/app"]
```

**Trade-off:**
- ✅ Menor tamanho de imagem, menor superfície de ataque
- ✅ Sem shell significa que atacantes não podem obter uma sessão interativa
- ❌ Você não pode fazer `kubectl exec` no container para depuração
- ❌ Depuração requer containers de debug efêmeros: `kubectl debug -it <pod> --image=busybox --target=app`

Use distroless em produção, use alpine em desenvolvimento/staging.

</details>

<details>
<summary>Dica 4: Carregando imagens no Kind</summary>

Kind executa como containers Docker, então tem seu próprio armazém de imagens separado do seu host. Você deve carregar imagens explicitamente:

```bash
# Carregar do cache local de imagens Docker
kind load docker-image myapp:multi --name fasthack

# Verificar que está lá
docker exec -it fasthack-control-plane crictl images | grep myapp
```

**Configuração crítica do Pod:** Ao fazer deploy de imagens carregadas desta forma, defina `imagePullPolicy: Never` — caso contrário o Kubernetes tenta puxar de um registry e falha:

```yaml
containers:
  - name: app
    image: myapp:multi
    imagePullPolicy: Never
```

Se você usar a tag `:latest`, o Kubernetes usa como padrão `imagePullPolicy: Always` — então use uma tag específica ou defina explicitamente `Never`.

</details>

<details>
<summary>Dica 5: Fundamentos do registry</summary>

O registry local executa como um container:

```bash
docker run -d -p 5000:5000 --name local-registry registry:2
```

Para fazer push de uma imagem, você deve tagueá-la com o endereço do registry:

```bash
docker tag myapp:multi localhost:5000/myapp:v1
docker push localhost:5000/myapp:v1
```

Consulte a API do registry:
```bash
# Listar todos os repositórios
curl http://localhost:5000/v2/_catalog

# Listar tags de uma imagem específica
curl http://localhost:5000/v2/myapp/tags/list
```

</details>

<details>
<summary>Dica 6: Podman vs Docker — diferenças principais</summary>

| Recurso | Docker | Podman |
|---------|--------|--------|
| Daemon necessário | Sim (`dockerd`) | Não (daemonless) |
| Root necessário para builds | Sim (por padrão) | Não (rootless por padrão) |
| Compatível com Dockerfile | Sim | Sim (mesma sintaxe) |
| CLI compatível | Sim | Sim (substituto direto) |
| Formato de imagem | OCI / Docker | OCI / Docker |

Os comandos são quase idênticos:

```bash
# Docker
docker build -t myapp:v1 .
docker run --rm myapp:v1

# Podman
podman build -t myapp:v1 .
podman run --rm myapp:v1
```

Algumas pessoas fazem alias `alias docker=podman` e nunca percebem a diferença.

</details>

## Recursos de Aprendizado

- [Dockerfile reference — Docker docs](https://docs.docker.com/reference/dockerfile/)
- [Multi-stage builds — Docker docs](https://docs.docker.com/build/building/multi-stage/)
- [Best practices for writing Dockerfiles — Docker docs](https://docs.docker.com/build/building/best-practices/)
- [.dockerignore file — Docker docs](https://docs.docker.com/build/concepts/context/#dockerignore-files)
- [Deploy a registry server — Distribution docs](https://distribution.github.io/distribution/about/deploying/)
- [Podman — Getting Started](https://podman.io/get-started)
- [Distroless container images — GitHub](https://github.com/GoogleContainerTools/distroless)
- [Kind — Loading an image into your cluster](https://kind.sigs.k8s.io/docs/user/quick-start/#loading-an-image-into-your-cluster)
- [CKAD curriculum — Application Design and Build](https://github.com/cncf/curriculum)

---

## Quebra & Conserta 🔧

Após completar o desafio, tente diagnosticar estes cenários quebrados:

---

### Cenário 1: Dockerfile compila mas container encerra imediatamente

Um desenvolvedor escreve um Dockerfile, compila com sucesso, mas o container encerra imediatamente no `docker run`:

```dockerfile
# broken-cmd/Dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY app.py .
EXPOSE 8080
RUN python app.py
```

```bash
docker build -t broken-cmd .
docker run --rm broken-cmd
# Container encerra imediatamente — sem saída, sem servidor
```

**Sua tarefa:** Por que o container encerra? Corrija o Dockerfile.

<details>
<summary>💡 Causa raiz & correção</summary>

**Causa raiz:** O desenvolvedor usou `RUN python app.py` em vez de `CMD ["python", "app.py"]`. `RUN` executa durante a fase de **build** — o servidor inicia, o build trava (ou o processo executa brevemente), e a camada resultante não tem comando de inicialização. Em runtime não há nada para executar.

**Correção:** Substitua `RUN` por `CMD`:

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY app.py .
EXPOSE 8080
CMD ["python", "app.py"]
```

> **Regra:** `RUN` = executa no tempo de build (como instalar pacotes). `CMD` = executa no tempo de início do container (como o comando start do seu serviço).

</details>

---

### Cenário 2: Imagem é enorme apesar do multi-stage build

Um desenvolvedor afirma usar multi-stage build, mas a imagem ainda tem mais de 1GB:

```dockerfile
# bloated-multi/Dockerfile
FROM golang:1.22 AS builder
WORKDIR /src
COPY go.mod main.go ./
RUN go build -o /app

FROM golang:1.22
COPY --from=builder /app /app
EXPOSE 8080
CMD ["/app"]
```

```bash
docker build -t bloated-multi .
docker images bloated-multi
# SIZE: ~1.1GB — não é o que você esperaria de multi-stage!
```

**Sua tarefa:** Identifique o erro e corrija.

<details>
<summary>💡 Causa raiz & correção</summary>

**Causa raiz:** O estágio de runtime também usa `golang:1.22` — a imagem completa do SDK Go (~1.1GB). O desenvolvedor esqueceu de trocar para uma imagem base mínima no segundo estágio.

**Correção:** Use `alpine:3.20` ou `distroless` para o estágio de runtime, e compile um binário estático:

```dockerfile
FROM golang:1.22 AS builder
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -o /app

FROM alpine:3.20
COPY --from=builder /app /app
EXPOSE 8080
CMD ["/app"]
```

Agora a imagem deve ter ~15MB em vez de 1.1GB.

</details>

---

### Cenário 3: Pod travado em ErrImagePull após carregar no Kind

Um desenvolvedor carrega uma imagem no Kind e cria um Pod, mas falha:

```bash
kind load docker-image myapp:latest --name fasthack
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: pull-fail
spec:
  containers:
    - name: app
      image: myapp:latest
      ports:
        - containerPort: 8080
EOF
kubectl get pod pull-fail
# STATUS: ErrImagePull
```

**Sua tarefa:** A imagem foi carregada — por que o Kubernetes não a encontra?

<details>
<summary>💡 Causa raiz & correção</summary>

**Causa raiz:** A tag da imagem é `:latest`. O Kubernetes usa como padrão `imagePullPolicy: Always` para tags `:latest`, o que significa que ele tenta puxar de um registry remoto em vez de usar a imagem local no node.

**Correção:** Defina `imagePullPolicy: Never`:

```yaml
spec:
  containers:
    - name: app
      image: myapp:latest
      imagePullPolicy: Never
```

Ou melhor ainda, use uma tag de versão específica em vez de `:latest`:

```bash
docker tag myapp:latest myapp:v1.0.0
kind load docker-image myapp:v1.0.0 --name fasthack
```

```yaml
image: myapp:v1.0.0
imagePullPolicy: IfNotPresent
```

> **Melhor prática:** Evite `:latest` em manifestos Kubernetes — torna deployments imprevisíveis e causa problemas com `imagePullPolicy`.

</details>
