# Desafio 07 — Volumes e Persistência

[< Desafio Anterior](Challenge-06.md) | **[Início](../README.md)** | [Próximo Desafio >](Challenge-08.md)

## Introdução

Em um servidor Linux você gerencia armazenamento todos os dias — editando `/etc/fstab` para declarar sistemas de arquivos, executando `mount` para anexar dispositivos de bloco, agrupando discos em volume groups LVM, e usando `/tmp` para espaço temporário descartável. Quando um processo morre, `/tmp` desaparece, mas os dados em um volume montado sobrevivem.

O Kubernetes segue exatamente a mesma filosofia. Containers são **efêmeros por padrão** — quando um Pod é deletado, tudo dentro da sua camada gravável desaparece. Para manter dados entre reinicializações você precisa de volumes, assim como um processo Linux precisa de um sistema de arquivos montado para persistir qualquer coisa além do seu próprio tempo de vida.

Neste desafio você trabalhará por todo o ciclo de vida de armazenamento: ver dados desaparecerem com armazenamento efêmero, criar volumes persistentes, anexá-los a Pods e StatefulSets, explorar provisionamento dinâmico via StorageClasses, e compartilhar dados entre containers usando `emptyDir`.

## Descrição

Sua missão é:

1. **Provar que o armazenamento de container é efêmero**

   Crie um Pod que escreve um arquivo, delete o Pod, recrie-o e confirme que o arquivo desapareceu.

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: ephemeral-demo
   spec:
     containers:
       - name: writer
         image: busybox:1.37
         command: ["sh", "-c", "mkdir -p /data && echo 'hello from ephemeral storage' > /data/message.txt && sleep 3600"]
   ```

   ```bash
   kubectl apply -f ephemeral-demo.yaml
   kubectl exec ephemeral-demo -- cat /data/message.txt
   kubectl delete pod ephemeral-demo
   kubectl apply -f ephemeral-demo.yaml
   kubectl exec ephemeral-demo -- cat /data/message.txt   # file is gone!
   ```

2. **Criar um PersistentVolume (PV) e PersistentVolumeClaim (PVC) manualmente**

   Defina um PV do tipo `hostPath` (adequado para clusters Kind de nó único) e um PVC correspondente. Em seguida, inicie um Pod que monta o PVC, escreve dados, é deletado, e um novo Pod prova que os dados sobrevivem.

   Crie o PV:
   ```yaml
   apiVersion: v1
   kind: PersistentVolume
   metadata:
     name: manual-pv
   spec:
     capacity:
       storage: 256Mi
     accessModes:
       - ReadWriteOnce
     persistentVolumeReclaimPolicy: Retain
     hostPath:
       path: /tmp/k8s-manual-pv
       type: DirectoryOrCreate
   ```

   Crie o PVC:
   ```yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: manual-pvc
   spec:
     accessModes:
       - ReadWriteOnce
     resources:
       requests:
         storage: 256Mi
     storageClassName: ""   # empty string prevents dynamic provisioning
   ```

   Faça deploy de um Pod que usa o PVC:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: pvc-demo
   spec:
     containers:
       - name: writer
         image: busybox:1.37
         command: ["sh", "-c", "echo 'persistent data' > /data/message.txt && sleep 3600"]
         volumeMounts:
           - name: my-storage
             mountPath: /data
     volumes:
       - name: my-storage
         persistentVolumeClaim:
           claimName: manual-pvc
   ```

   Teste a persistência:
   ```bash
   kubectl apply -f manual-pv.yaml
   kubectl apply -f manual-pvc.yaml
   kubectl apply -f pvc-demo.yaml
   kubectl exec pvc-demo -- cat /data/message.txt
   kubectl delete pod pvc-demo
   kubectl apply -f pvc-demo.yaml
   kubectl exec pvc-demo -- cat /data/message.txt   # data survives!
   ```

   Inspecione a vinculação:
   ```bash
   kubectl get pv,pvc
   kubectl describe pv manual-pv
   ```

3. **Fazer deploy de um StatefulSet com volumeClaimTemplates**

   StatefulSets dão a cada Pod um hostname estável (`redis-0`, `redis-1`, …) e seu próprio PVC. Faça deploy de um StatefulSet Redis e verifique que cada réplica tem armazenamento persistente independente.

   ```yaml
   apiVersion: apps/v1
   kind: StatefulSet
   metadata:
     name: redis
   spec:
     serviceName: redis
     replicas: 2
     selector:
       matchLabels:
         app: redis
     template:
       metadata:
         labels:
           app: redis
       spec:
         containers:
           - name: redis
             image: redis:7-alpine
             ports:
               - containerPort: 6379
             volumeMounts:
               - name: redis-data
                 mountPath: /data
     volumeClaimTemplates:
       - metadata:
           name: redis-data
         spec:
           accessModes: ["ReadWriteOnce"]
           resources:
             requests:
               storage: 128Mi
   ```

   Você também precisa de um Service headless para o StatefulSet:
   ```yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: redis
   spec:
     clusterIP: None
     selector:
       app: redis
     ports:
       - port: 6379
   ```

   Verifique:
   ```bash
   kubectl apply -f redis-headless-svc.yaml
   kubectl apply -f redis-statefulset.yaml
   kubectl get pods -l app=redis -w                 # watch pods come up in order
   kubectl get pvc                                   # one PVC per replica
   kubectl exec redis-0 -- redis-cli SET mykey "hello from redis-0"
   kubectl exec redis-0 -- redis-cli GET mykey
   kubectl delete pod redis-0                        # StatefulSet recreates it
   kubectl exec redis-0 -- redis-cli GET mykey       # data survives!
   ```

4. **Explorar StorageClasses e provisionamento dinâmico**

   O Kind vem com uma StorageClass padrão chamada `standard` sustentada pelo provisioner `rancher.io/local-path`. Quando um PVC referencia esta StorageClass, um PV é criado automaticamente — nenhum PV manual necessário.

   ```bash
   kubectl get storageclass
   ```

   Crie um PVC que usa provisionamento dinâmico:
   ```yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: dynamic-pvc
   spec:
     accessModes:
       - ReadWriteOnce
     resources:
       requests:
         storage: 128Mi
     storageClassName: standard
   ```

   Faça deploy de um Pod que o usa:
   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: dynamic-demo
   spec:
     containers:
       - name: app
         image: busybox:1.37
         command: ["sh", "-c", "echo 'dynamically provisioned!' > /data/hello.txt && sleep 3600"]
         volumeMounts:
           - name: dynamic-vol
             mountPath: /data
     volumes:
       - name: dynamic-vol
         persistentVolumeClaim:
           claimName: dynamic-pvc
   ```

   ```bash
   kubectl apply -f dynamic-pvc.yaml
   kubectl apply -f dynamic-demo.yaml
   kubectl get pv    # a PV was created automatically!
   kubectl get pvc   # dynamic-pvc is Bound
   kubectl exec dynamic-demo -- cat /data/hello.txt
   ```

   > **Nota:** A StorageClass `standard` no Kind usa `volumeBindingMode: WaitForFirstConsumer`, o que significa que o PV só é criado quando um Pod realmente reivindica o PVC. Isso evita conflitos de agendamento em clusters multi-nó.

5. **Usar emptyDir para compartilhar dados entre containers (padrão sidecar)**

   Um volume `emptyDir` é criado quando um Pod é atribuído a um node e existe enquanto o Pod estiver rodando — ambos os containers podem ler e escrever nele. Este é o equivalente Kubernetes de um diretório `/tmp` compartilhado.

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: sidecar-demo
   spec:
     containers:
       - name: producer
         image: busybox:1.37
         command: ["sh", "-c", "while true; do date >> /shared/log.txt; sleep 5; done"]
         volumeMounts:
           - name: shared-data
             mountPath: /shared
       - name: consumer
         image: busybox:1.37
         command: ["sh", "-c", "tail -f /shared/log.txt"]
         volumeMounts:
           - name: shared-data
             mountPath: /shared
     volumes:
       - name: shared-data
         emptyDir: {}
   ```

   ```bash
   kubectl apply -f sidecar-demo.yaml
   kubectl logs sidecar-demo -c consumer -f   # see live timestamps from producer
   kubectl delete pod sidecar-demo              # emptyDir data is gone
   ```

## Critérios de Sucesso

- [ ] Você demonstrou que dados escritos dentro de um container são perdidos quando o Pod é deletado (Tarefa 1)
- [ ] Você criou um PV e PVC manualmente, montou-os em um Pod e provou que os dados sobrevivem à exclusão do Pod (Tarefa 2)
- [ ] Você fez deploy de um StatefulSet Redis onde cada réplica tem seu próprio PVC e os dados persistem entre reinicializações de Pod (Tarefa 3)
- [ ] Você usou a StorageClass `standard` para provisionamento dinâmico e um PV foi criado automaticamente (Tarefa 4)
- [ ] Você fez deploy de um Pod multi-container usando `emptyDir` e observou dados fluindo entre os containers sidecar (Tarefa 5)
- [ ] Você consegue executar `kubectl get pv,pvc` e explicar o Status, Modo de Acesso e StorageClass de cada entrada
- [ ] Você consegue explicar quando usar `emptyDir` vs PVC, e por que StatefulSets são necessários para bancos de dados

## Referência Linux ↔ Kubernetes

| Conceito Linux | Equivalente Kubernetes |
|---|---|
| `/etc/fstab` (declarar sistemas de arquivos) | PersistentVolume (PV) — declara um recurso de armazenamento |
| `mount /dev/sdb1 /mnt/data` | Vinculação de PersistentVolumeClaim (PVC) — requisita e anexa armazenamento |
| LVM / volume groups | StorageClass — define *como* provisionar armazenamento |
| `/tmp` (efêmero, desaparece no reboot) | Volume `emptyDir` — existe apenas enquanto o Pod existir |
| Montagem NFS (`mount -t nfs ...`) | PersistentVolume NFS ou driver CSI NFS |
| `df -h` (listar sistemas de arquivos montados) | `kubectl get pv,pvc` |
| `blkid` / `lsblk` (inspecionar dispositivos de bloco) | `kubectl describe pv <nome>` |
| `fsck` (verificação de saúde do sistema de arquivos) | Monitoramento de saúde de volume (drivers CSI) |

## Dicas

<details>
<summary>Dica 1: PVC preso em Pending?</summary>

Verifique se existe um PV que corresponde à solicitação do PVC:
```bash
kubectl describe pvc manual-pvc
```

Veja a seção `Events`. Problemas comuns:
- O PVC solicita mais armazenamento do que o PV oferece
- O `storageClassName` no PVC não corresponde ao PV (use `storageClassName: ""` para vinculação manual)
- Os `accessModes` não correspondem entre PV e PVC

</details>

<details>
<summary>Dica 2: Qual a diferença entre as políticas de reclaim Retain e Delete?</summary>

- **Retain** — Quando o PVC é deletado, o PV e seus dados são mantidos. Um administrador deve recuperá-lo manualmente. Use para dados importantes.
- **Delete** — Quando o PVC é deletado, o PV e seu armazenamento subjacente são removidos automaticamente. Este é o padrão para a maioria dos provisioners dinâmicos (incluindo a StorageClass `standard` do Kind).

Verifique a política de reclaim de um PV:
```bash
kubectl get pv -o custom-columns=NAME:.metadata.name,RECLAIM:.spec.persistentVolumeReclaimPolicy
```

</details>

<details>
<summary>Dica 3: Por que o StatefulSet precisa de um Service headless?</summary>

Um Service headless (um com `clusterIP: None`) dá a cada Pod um nome DNS estável como `redis-0.redis.default.svc.cluster.local`. StatefulSets requerem isso para identidade ordenada de Pods. Sem ele, o controller do StatefulSet não pode atribuir identidades de rede estáveis.

</details>

<details>
<summary>Dica 4: Como eu vejo onde o Kind armazena dados no host?</summary>

O Kind roda dentro de containers Docker. Para encontrar onde o local-path-provisioner armazena dados de PV:
```bash
kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.hostPath.path}{"\n"}{end}'
```

Você pode executar exec no container do node Kind para inspecionar o diretório:
```bash
docker exec -it kind-control-plane ls -la /var/local-path-provisioner/
```

</details>

<details>
<summary>Dica 5: O que é o OCI VolumeSource? (novo no v1.36)</summary>

O Kubernetes v1.36 promoveu o **OCI VolumeSource** para GA. Isso permite montar conteúdo de qualquer registro compatível com OCI diretamente como um volume somente leitura — sem necessidade de PVC. É útil para pesos de modelos ML, assets estáticos ou pacotes de configuração publicados como artefatos OCI.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: oci-volume-demo
spec:
  volumes:
    - name: model-data
      oci:
        image: registry.example.com/models/my-model:v1
  containers:
    - name: app
      image: busybox:1.37
      command: ["sh", "-c", "ls -la /model && sleep 3600"]
      volumeMounts:
        - name: model-data
          mountPath: /model
```

</details>

<details>
<summary>Dica 6: StorageClasses equivalentes em nuvem (para referência)</summary>

Em produção você usará drivers CSI em vez do provisioner local-path do Kind:

| Nuvem | Driver CSI | Exemplo de StorageClass |
|---|---|---|
| AKS (Azure) | `disk.csi.azure.com` | `managed-csi` |
| EKS (AWS) | `ebs.csi.aws.com` | `gp3` |
| GKE (Google) | `pd.csi.storage.gke.io` | `standard-rwo` |

> **Importante:** Os antigos provisioners in-tree (`kubernetes.io/azure-disk`, `kubernetes.io/aws-ebs`, `kubernetes.io/gce-pd`) estão **deprecados**. Sempre use drivers CSI em produção.

</details>

## Recursos de Aprendizado

- [Volumes — kubernetes.io](https://kubernetes.io/docs/concepts/storage/volumes/)
- [Persistent Volumes — kubernetes.io](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)
- [Storage Classes — kubernetes.io](https://kubernetes.io/docs/concepts/storage/storage-classes/)
- [StatefulSets — kubernetes.io](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/)
- [Configure a Pod to Use a PersistentVolume — kubernetes.io](https://kubernetes.io/docs/tasks/configure-pod-container/configure-persistent-volume-storage/)
- [Dynamic Volume Provisioning — kubernetes.io](https://kubernetes.io/docs/concepts/storage/dynamic-provisioning/)
- [OCI VolumeSource (v1.36 GA) — kubernetes.io](https://kubernetes.io/docs/concepts/storage/volumes/#oci)
- [local-path-provisioner — GitHub](https://github.com/rancher/local-path-provisioner)

## Quebra & Conserta 🔧

Após completar o desafio, tente diagnosticar estes cenários quebrados:

**1. PVC preso em Pending — nenhum PV correspondente**

Aplique este PVC e descubra por que ele nunca se vincula:
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: broken-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: "nonexistent-class"
```
```bash
kubectl apply -f broken-pvc.yaml
kubectl get pvc broken-pvc            # Stuck in Pending
kubectl describe pvc broken-pvc       # Read the Events section
```
> **Correção:** O `storageClassName` referencia uma classe que não existe. Altere para `standard` (padrão do Kind) ou `""` e forneça um PV correspondente.

**2. Pod preso em ContainerCreating — problema de montagem de volume**

Aplique este Pod e diagnostique por que ele não inicia:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: broken-mount
spec:
  containers:
    - name: app
      image: busybox:1.37
      command: ["sleep", "3600"]
      volumeMounts:
        - name: my-data
          mountPath: /data
  volumes:
    - name: my-data
      persistentVolumeClaim:
        claimName: does-not-exist
```
```bash
kubectl apply -f broken-mount.yaml
kubectl get pod broken-mount          # ContainerCreating (stuck)
kubectl describe pod broken-mount     # Look for "persistentvolumeclaim not found"
```
> **Correção:** O PVC `does-not-exist` nunca foi criado. Crie o PVC primeiro, ou corrija o `claimName` para referenciar um PVC existente.

**3. Dados perdidos após exclusão do Pod — usou emptyDir em vez de PVC**

Um desenvolvedor reclama que seus dados continuam desaparecendo. Você consegue identificar o bug?
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: broken-persistence
spec:
  containers:
    - name: db
      image: redis:7-alpine
      volumeMounts:
        - name: redis-data
          mountPath: /data
  volumes:
    - name: redis-data
      emptyDir: {}
```
```bash
kubectl apply -f broken-persistence.yaml
kubectl exec broken-persistence -- redis-cli SET important "critical-data"
kubectl delete pod broken-persistence
kubectl apply -f broken-persistence.yaml
kubectl exec broken-persistence -- redis-cli GET important   # returns (nil)!
```
> **Correção:** `emptyDir` é efêmero — é destruído quando o Pod é deletado. Substitua o volume `emptyDir` por uma referência `persistentVolumeClaim`, e crie um PVC correspondente. Para bancos de dados, use um StatefulSet com `volumeClaimTemplates` para que cada réplica tenha seu próprio armazenamento durável.
