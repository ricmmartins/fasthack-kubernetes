# Solução 16 — Container Image Engineering

[< Solução Anterior](Solution-15.md) - **[Home](README.md)** - [Próxima Solução >](Solution-17.md)

---

> **Nota do Coach:** Este desafio aborda tópicos críticos para o CKAD: escrita de Dockerfiles, multi-stage builds, otimização de imagens, registries e carregamento de imagens no Kind. Os alunos devem ter o Docker (ou Podman) instalado desde a configuração do Desafio 01. A Tarefa 6 (Podman) é opcional caso não esteja instalado. Todas as outras tarefas são essenciais.

## Configuração

Certifique-se de que os alunos têm o Docker rodando e um cluster Kind chamado `fasthack`:

```bash
docker info >/dev/null 2>&1 && echo "Docker OK" || echo "Docker not running"
kind get clusters | grep fasthack && echo "Kind cluster OK" || echo "No fasthack cluster"
```

Crie o diretório de trabalho:

```bash
mkdir -p ~/image-lab && cd ~/image-lab
```

---

## Tarefa 1: Escrever um Dockerfile para uma Aplicação Web Simples

### Passo a passo

Crie o arquivo da aplicação:

```bash
cat <<'PYEOF' > app.py
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
PYEOF
```

Crie o arquivo de requisitos:

```bash
cat <<'EOF' > requirements.txt
# No external dependencies — stdlib only
EOF
```

Crie o Dockerfile:

```bash
cat <<'DOCKERFILE' > Dockerfile
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

EXPOSE 8080

CMD ["python", "app.py"]
DOCKERFILE
```

Faça o build da imagem:

```bash
docker build -t myapp:v1 .
```

Saída esperada (linhas principais):

```
[+] Building 12.3s (10/10) FINISHED
 => [1/5] FROM docker.io/library/python:3.12-slim@sha256:...
 => [2/5] WORKDIR /app
 => [3/5] COPY requirements.txt .
 => [4/5] RUN pip install --no-cache-dir -r requirements.txt
 => [5/5] COPY app.py .
 => exporting to image
 => => naming to docker.io/library/myapp:v1
```

### Verificação

```bash
# Run the container
docker run --rm -d -p 8080:8080 --name myapp-test myapp:v1

# Test it
curl http://localhost:8080
```

Esperado:

```
Hello from my custom image!
```

```bash
# Check the image size
docker images myapp:v1
```

Esperado (aproximadamente):

```
REPOSITORY   TAG   IMAGE ID       CREATED          SIZE
myapp        v1    abc123def456   30 seconds ago   155MB
```

Limpeza:

```bash
docker stop myapp-test
```

> **Dica para o Coach:** Se os alunos virem `155MB` para uma aplicação Python "hello world", pergunte: "De onde vem esse tamanho?" Resposta: A imagem base `python:3.12-slim` em si tem ~150MB. Isso motiva a Tarefa 2 e a Tarefa 3.

---

## Tarefa 2: Otimizar com Multi-Stage Builds

### Passo a passo

Crie a aplicação em Go:

```bash
cat <<'GOEOF' > main.go
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
GOEOF
```

Crie o arquivo do módulo Go:

```bash
cat <<'EOF' > go.mod
module myapp

go 1.22
EOF
```

Crie o Dockerfile **single-stage**:

```bash
cat <<'DOCKERFILE' > Dockerfile.single
FROM golang:1.22

WORKDIR /src

COPY go.mod main.go ./

RUN go build -o /app

EXPOSE 8080

CMD ["/app"]
DOCKERFILE
```

Crie o Dockerfile **multi-stage**:

```bash
cat <<'DOCKERFILE' > Dockerfile.multi
# Stage 1: Build (like your build VM with all compilers)
FROM golang:1.22 AS builder

WORKDIR /src

COPY go.mod main.go ./

RUN CGO_ENABLED=0 go build -o /app

# Stage 2: Runtime (like your minimal production server)
FROM alpine:3.20

COPY --from=builder /app /app

EXPOSE 8080

CMD ["/app"]
DOCKERFILE
```

Faça o build de ambos:

```bash
docker build -t myapp:single -f Dockerfile.single .
docker build -t myapp:multi -f Dockerfile.multi .
```

### Verificação

```bash
docker images | grep myapp
```

Esperado (tamanhos aproximados):

```
REPOSITORY   TAG      IMAGE ID       CREATED          SIZE
myapp        multi    abc123def456   10 seconds ago   13.5MB
myapp        single   def456abc789   30 seconds ago   1.12GB
myapp        v1       789abc123def   2 minutes ago    155MB
```

**Observação principal:** A imagem multi-stage (`~13.5MB`) é aproximadamente **80x menor** que a imagem single-stage (`~1.12GB`).

Teste a imagem multi-stage:

```bash
docker run --rm -d -p 8080:8080 --name multi-test myapp:multi
curl http://localhost:8080
```

Esperado:

```
Hello from Go multi-stage build!
```

```bash
docker stop multi-test
```

Inspecione as camadas para entender a diferença:

```bash
# Single-stage: many layers from the Go SDK
docker history myapp:single --no-trunc --format "{{.Size}}\t{{.CreatedBy}}" | head -5

# Multi-stage: only the alpine base + your binary
docker history myapp:multi --no-trunc --format "{{.Size}}\t{{.CreatedBy}}" | head -5
```

> **Dica para o Coach:** Pergunte aos alunos: "Por que `CGO_ENABLED=0` é importante?" Resposta: Ele produz um binário linkado estaticamente que não precisa do glibc. Sem ele, o binário precisa da biblioteca C da imagem de build e não rodará no Alpine (que usa musl, não glibc) ou no distroless (que não tem biblioteca C alguma).

---

## Tarefa 3: Comparar Tamanhos de Imagens Base

### Passo a passo

Crie três Dockerfiles para diferentes imagens base:

**Baseado em Ubuntu:**

```bash
cat <<'DOCKERFILE' > Dockerfile.ubuntu
FROM golang:1.22 AS builder
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -o /app

FROM ubuntu:24.04
COPY --from=builder /app /app
EXPOSE 8080
CMD ["/app"]
DOCKERFILE
```

**Baseado em Alpine** (já criado como `Dockerfile.multi`):

```bash
# Already exists from Task 2
```

**Distroless:**

```bash
cat <<'DOCKERFILE' > Dockerfile.distroless
FROM golang:1.22 AS builder
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -o /app

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /app /app
EXPOSE 8080
CMD ["/app"]
DOCKERFILE
```

Faça o build dos três:

```bash
docker build -t myapp:ubuntu -f Dockerfile.ubuntu .
docker build -t myapp:alpine -f Dockerfile.multi .
docker build -t myapp:distroless -f Dockerfile.distroless .
```

### Verificação

```bash
docker images | grep myapp | sort -k7 -h
```

Esperado (aproximado):

```
REPOSITORY   TAG          IMAGE ID       CREATED          SIZE
myapp        distroless   aaa111bbb222   10 seconds ago   7.68MB
myapp        alpine       bbb222ccc333   30 seconds ago   13.5MB
myapp        ubuntu       ccc333ddd444   45 seconds ago   85.8MB
myapp        single       ddd444eee555   2 minutes ago    1.12GB
```

Verifique que os três funcionam:

```bash
# Test Ubuntu variant
docker run --rm -d -p 8080:8080 --name test-ubuntu myapp:ubuntu
curl http://localhost:8080 && docker stop test-ubuntu

# Test Alpine variant
docker run --rm -d -p 8080:8080 --name test-alpine myapp:alpine
curl http://localhost:8080 && docker stop test-alpine

# Test Distroless variant
docker run --rm -d -p 8080:8080 --name test-distroless myapp:distroless
curl http://localhost:8080 && docker stop test-distroless
```

Todos os três devem retornar: `Hello from Go multi-stage build!`

Teste o acesso ao shell:

```bash
# Ubuntu — has a full shell
docker run --rm -it myapp:ubuntu /bin/bash -c "whoami && ls /app"
# Output: root, /app

# Alpine — has a minimal shell
docker run --rm -it myapp:alpine /bin/sh -c "whoami && ls /app"
# Output: root, /app

# Distroless — NO shell
docker run --rm -it myapp:distroless /bin/sh
# Error: exec: "/bin/sh": stat /bin/sh: no such file or directory
```

### Tabela Comparativa

| Imagem Base | Tamanho | Shell? | Gerenciador de Pacotes? | Melhor Para |
|---|---|---|---|---|
| `ubuntu:24.04` | ~85MB | ✅ bash | ✅ apt | Desenvolvimento, debugging, apps que precisam de bibliotecas do sistema |
| `alpine:3.20` | ~13MB | ✅ sh | ✅ apk | Bom equilíbrio entre tamanho e capacidade de debug |
| `distroless/static` | ~8MB | ❌ | ❌ | Produção — menor superfície de ataque |
| `golang:1.22` (single) | ~1.1GB | ✅ bash | ✅ apt | Nunca use como base de runtime |

> **Dica para o Coach:** Pergunte aos alunos qual escolheriam em um cenário de exame CKAD. Resposta: Para o exame, use `alpine` — é pequeno e ainda permite exec para dentro do container. Para questões de segurança em produção, a resposta é `distroless`.

---

## Tarefa 4: Criar um Arquivo .dockerignore

### Passo a passo

Crie arquivos que NÃO devem acabar na imagem:

```bash
cd ~/image-lab
echo "SECRET_KEY=supersecret" > .env
mkdir -p .git && echo "git data" > .git/HEAD
dd if=/dev/zero of=large-test-data.bin bs=1M count=50
```

Faça o build sem `.dockerignore` e observe o contexto:

```bash
docker build -t myapp:no-ignore -f Dockerfile .
```

Esperado — observe a transferência do contexto de build (BuildKit mostra diferente, mas o contexto ainda é enviado):

```
 => [internal] load build context
 => => transferring context: 52.43MB
```

Agora crie o `.dockerignore`:

```bash
cat <<'EOF' > .dockerignore
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
EOF
```

Refaça o build:

```bash
docker build -t myapp:with-ignore -f Dockerfile .
```

Esperado:

```
 => [internal] load build context
 => => transferring context: 1.23kB
```

### Verificação

Verifique que os arquivos excluídos não estão na imagem:

```bash
docker run --rm myapp:with-ignore ls -la /app/
```

Esperado — apenas `app.py` e `requirements.txt` devem estar presentes:

```
total 8
drwxr-xr-x 1 root root 4096 ... .
drwxr-xr-x 1 root root 4096 ... ..
-rw-r--r-- 1 root root  ...  app.py
-rw-r--r-- 1 root root  ...  requirements.txt
```

**Sem `.env`, sem `.git`, sem `large-test-data.bin`, sem `Dockerfile`.**

Limpe os arquivos de teste:

```bash
rm -f .env large-test-data.bin
rm -rf .git
```

> **Dica para o Coach:** Enfatize o aspecto de segurança: sem `.dockerignore`, arquivos `.env` com segredos, diretórios `.git` com histórico completo de commits e outros arquivos sensíveis são incluídos na imagem. Qualquer pessoa que fizer pull da imagem pode extraí-los.

---

## Tarefa 5: Taguear e Fazer Push para um Registry Local

### Passo a passo

Inicie o registry local:

```bash
docker run -d -p 5000:5000 --name local-registry registry:2
```

Esperado:

```
Unable to find image 'registry:2' locally
2: Pulling from library/registry
...
Status: Downloaded newer image for registry:2
<container-id>
```

Verifique que está rodando:

```bash
docker ps | grep registry
curl http://localhost:5000/v2/
```

Esperado do curl:

```
{}
```

Taguear e fazer push das imagens:

```bash
docker tag myapp:multi localhost:5000/myapp:v1
docker tag myapp:multi localhost:5000/myapp:latest
docker push localhost:5000/myapp:v1
docker push localhost:5000/myapp:latest
```

Saída esperada do push:

```
The push refers to repository [localhost:5000/myapp]
abc123: Pushed
def456: Pushed
v1: digest: sha256:... size: 739
```

### Verificação

Consulte a API do registry:

```bash
# List all repositories
curl http://localhost:5000/v2/_catalog
```

Esperado:

```json
{"repositories":["myapp"]}
```

```bash
# List tags
curl http://localhost:5000/v2/myapp/tags/list
```

Esperado:

```json
{"name":"myapp","tags":["v1","latest"]}
```

Prove que o ciclo completo funciona — delete a imagem local e faça pull do registry:

```bash
docker rmi localhost:5000/myapp:v1
docker pull localhost:5000/myapp:v1
docker run --rm -d -p 8080:8080 --name registry-test localhost:5000/myapp:v1
curl http://localhost:8080
```

Esperado:

```
Hello from Go multi-stage build!
```

```bash
docker stop registry-test
```

Limpe o container do registry (opcional — mantenha para outros experimentos):

```bash
docker stop local-registry && docker rm local-registry
```

---

## Tarefa 6: Build com Podman (Rootless)

> **Nota do Coach:** Esta tarefa é opcional. Se os alunos não têm o Podman instalado e não podem instalá-lo facilmente, eles devem documentar os comandos e anotar as diferenças.

### Passo a passo

Verifique se o Podman está instalado:

```bash
podman --version
```

Esperado (a versão pode variar):

```
podman version 5.x.x
```

Faça o build da mesma imagem com Podman:

```bash
cd ~/image-lab
podman build -t myapp:podman -f Dockerfile.multi .
```

Saída esperada — quase idêntica à saída do Docker:

```
STEP 1/7: FROM golang:1.22 AS builder
STEP 2/7: WORKDIR /src
STEP 3/7: COPY go.mod main.go ./
STEP 4/7: RUN CGO_ENABLED=0 go build -o /app
STEP 5/7: FROM alpine:3.20
STEP 6/7: COPY --from=builder /app /app
STEP 7/7: CMD ["/app"]
COMMIT myapp:podman
--> abc123def456
Successfully tagged localhost/myapp:podman
```

### Verificação

```bash
podman images | grep myapp
```

Esperado:

```
REPOSITORY                TAG       IMAGE ID      CREATED        SIZE
localhost/myapp            podman    abc123def456  30 seconds ago  13.5 MB
```

Execute a imagem:

```bash
podman run --rm -d -p 8081:8080 --name podman-test myapp:podman
curl http://localhost:8081
```

Esperado:

```
Hello from Go multi-stage build!
```

```bash
podman stop podman-test
```

Verifique a execução rootless:

```bash
# Podman runs as the current user — no root needed
whoami
podman info | grep rootless
```

Esperado:

```
<your-username>
    rootless: true
```

### Comparações Importantes para os Alunos

| Funcionalidade | Docker | Podman |
|---------|--------|--------|
| Comando de build | `docker build -t img .` | `podman build -t img .` |
| Daemon necessário | Sim (`dockerd`) | Não |
| Usuário padrão para builds | root | Usuário atual (rootless) |
| Compatibilidade de imagem | Formato OCI/Docker | Formato OCI/Docker |
| Sintaxe do Dockerfile | Padrão | Igual — nenhuma alteração necessária |

> **Dica para o Coach:** Se um aluno perguntar "por que eu usaria Podman?", a resposta é segurança. Em ambientes corporativos, executar um daemon Docker com privilégios de root é uma preocupação de segurança. O Podman elimina isso executando inteiramente no espaço do usuário. Algumas organizações exigem Podman por esse motivo.

---

## Tarefa 7: Carregar uma Imagem Customizada no Kind e Fazer Deploy

### Passo a passo

Carregue a imagem multi-stage no cluster Kind:

```bash
kind load docker-image myapp:multi --name fasthack
```

Esperado:

```
Image: "myapp:multi" with ID "sha256:abc123..." not yet present on node "fasthack-control-plane", loading...
```

Verifique se a imagem está disponível dentro do node Kind:

```bash
docker exec -it fasthack-control-plane crictl images | grep myapp
```

Esperado:

```
docker.io/library/myapp    multi    abc123def456   13.5MB
```

Crie o manifesto do Pod:

```bash
cat <<'EOF' > custom-image-pod.yaml
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
EOF
```

Faça o deploy do Pod:

```bash
kubectl apply -f custom-image-pod.yaml
```

Esperado:

```
pod/custom-app created
```

### Verificação

```bash
kubectl get pod custom-app
```

Esperado:

```
NAME         READY   STATUS    RESTARTS   AGE
custom-app   1/1     Running   0          10s
```

Teste a aplicação via port-forward:

```bash
kubectl port-forward pod/custom-app 8080:8080 &
sleep 2
curl http://localhost:8080
```

Esperado:

```
Hello from my custom Kind image!
```

Pare o port-forward:

```bash
# Kill the background port-forward process
kill %1 2>/dev/null
```

Verifique os detalhes da imagem no Pod:

```bash
kubectl describe pod custom-app | grep -A 2 "Image:"
```

Esperado:

```
    Image:          myapp:multi
    Image ID:       docker.io/library/myapp@sha256:...
```

```bash
kubectl describe pod custom-app | grep "Pull"
```

Esperado — sem eventos de pull porque `imagePullPolicy: Never`:

```
# No "Pulling image" events — the image was already on the node
```

### Bônus: Deploy com um Deployment (não apenas um Pod)

```bash
cat <<'EOF' > custom-image-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: custom-app-deploy
spec:
  replicas: 3
  selector:
    matchLabels:
      app: custom-app
  template:
    metadata:
      labels:
        app: custom-app
    spec:
      containers:
        - name: app
          image: myapp:multi
          imagePullPolicy: Never
          ports:
            - containerPort: 8080
          env:
            - name: APP_MESSAGE
              value: "Hello from replica!"
---
apiVersion: v1
kind: Service
metadata:
  name: custom-app-svc
spec:
  selector:
    app: custom-app
  ports:
    - port: 80
      targetPort: 8080
EOF

kubectl apply -f custom-image-deployment.yaml
kubectl get pods -l app=custom-app
```

Esperado:

```
NAME                                READY   STATUS    RESTARTS   AGE
custom-app-deploy-xxxxxxxxx-aaaaa   1/1     Running   0          10s
custom-app-deploy-xxxxxxxxx-bbbbb   1/1     Running   0          10s
custom-app-deploy-xxxxxxxxx-ccccc   1/1     Running   0          10s
```

---

## Soluções Break & Fix

### Cenário 1: Confusão entre `RUN` e `CMD`

**Dockerfile com problema:**

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY app.py .
EXPOSE 8080
RUN python app.py
```

**Comandos de diagnóstico:**

```bash
docker build -t broken-cmd .
docker run --rm broken-cmd
# Container exits immediately with no output
```

```bash
docker inspect broken-cmd --format='{{.Config.Cmd}}'
# Output: [] or null — no CMD set
```

**Causa raiz:** `RUN python app.py` é executado durante o build. O servidor inicia mas ou trava o build ou encerra. Não há `CMD` definido para o runtime.

**Correção:**

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY app.py .
EXPOSE 8080
CMD ["python", "app.py"]
```

**Verificação:**

```bash
docker build -t fixed-cmd .
docker run --rm -d -p 8080:8080 --name test-cmd fixed-cmd
curl http://localhost:8080
# Output: Hello from my custom image!
docker stop test-cmd
```

---

### Cenário 2: Multi-stage build ainda enorme — base de runtime errada

**Dockerfile com problema:**

```dockerfile
FROM golang:1.22 AS builder
WORKDIR /src
COPY go.mod main.go ./
RUN go build -o /app

FROM golang:1.22
COPY --from=builder /app /app
EXPOSE 8080
CMD ["/app"]
```

**Comandos de diagnóstico:**

```bash
docker build -t bloated-multi .
docker images bloated-multi
# SIZE: ~1.12GB
```

```bash
# Inspect both stages — the runtime image is the full Go SDK
docker history bloated-multi | head -3
```

**Causa raiz:** Ambos os estágios usam `golang:1.22`. O estágio de runtime deveria usar uma imagem mínima como `alpine:3.20`.

**Correção:**

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

**Verificação:**

```bash
docker build -t fixed-multi .
docker images fixed-multi
# SIZE: ~13.5MB
```

---

### Cenário 3: ErrImagePull com Kind — imagePullPolicy ausente

**Configuração:**

```bash
kind load docker-image myapp:latest --name fasthack
```

**Manifesto com problema:**

```yaml
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
```

**Comandos de diagnóstico:**

```bash
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
# STATUS: ErrImagePull or ImagePullBackOff

kubectl describe pod pull-fail
```

Eventos importantes:

```
Warning  Failed   Failed to pull image "myapp:latest": ... not found
Warning  Failed   Error: ErrImagePull
```

**Causa raiz:** A tag `:latest` faz o Kubernetes usar `imagePullPolicy: Always` por padrão, então ele tenta fazer pull de um registry remoto em vez de usar a imagem carregada localmente.

**Correção:**

```bash
kubectl delete pod pull-fail

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: pull-fail
spec:
  containers:
    - name: app
      image: myapp:latest
      imagePullPolicy: Never
      ports:
        - containerPort: 8080
EOF
```

**Verificação:**

```bash
kubectl get pod pull-fail
# STATUS: Running
```

---

## Limpeza

Após o desafio, limpe todos os recursos:

```bash
# Delete Kubernetes resources
kubectl delete pod custom-app pull-fail 2>/dev/null
kubectl delete -f custom-image-deployment.yaml 2>/dev/null

# Clean up Docker resources
docker stop local-registry 2>/dev/null && docker rm local-registry 2>/dev/null
docker rmi myapp:v1 myapp:single myapp:multi myapp:alpine myapp:ubuntu myapp:distroless 2>/dev/null
docker rmi myapp:no-ignore myapp:with-ignore 2>/dev/null
docker rmi localhost:5000/myapp:v1 localhost:5000/myapp:latest 2>/dev/null
docker rmi broken-cmd fixed-cmd bloated-multi fixed-multi 2>/dev/null

# Clean up Podman images (if applicable)
podman rmi myapp:podman 2>/dev/null

# Remove working directory
rm -rf ~/image-lab
```

---

## Problemas Comuns

| Problema | Causa | Correção |
|---------|-------|-----|
| `docker build` falha com "no such file" | O source do `COPY` não existe ou está excluído pelo `.dockerignore` | Verifique se o arquivo existe e não está no `.dockerignore` |
| Imagem multi-stage ainda grande (>100MB) | Estágio de runtime usa a imagem base de build | Mude o segundo `FROM` para `alpine:3.20` ou `distroless` |
| `CGO_ENABLED=0` não definido e binário crasha | Linkagem dinâmica contra glibc, mas Alpine usa musl | Adicione `CGO_ENABLED=0` ao comando `go build` |
| `kind load docker-image` falha | Imagem não existe no cache local do Docker | Execute `docker images \| grep myapp` para verificar se a tag existe |
| Pod em `ErrImagePull` após `kind load` | `imagePullPolicy` não definido como `Never` ou `IfNotPresent` | Adicione `imagePullPolicy: Never` à spec do container |
| Tag `:latest` causa pull do registry | K8s usa `Always` por padrão para `:latest` | Use uma tag específica (`:v1`) ou defina `imagePullPolicy: Never` |
| `docker push` para `localhost:5000` falha | Container do registry local não está rodando | `docker ps \| grep registry` — reinicie se necessário |
| `podman build` falha no macOS | Máquina Podman não inicializada | Execute `podman machine init && podman machine start` |
| Contexto de build muito grande | `.dockerignore` ausente | Crie `.dockerignore` excluindo `.git`, `*.bin`, `node_modules`, etc. |
| `EXPOSE` não torna a porta acessível | `EXPOSE` é apenas documentação — não publica portas | Use `-p 8080:8080` com `docker run` ou `port-forward` no K8s |
