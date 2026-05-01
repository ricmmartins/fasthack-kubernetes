# Guia do Coach

Este diretório contém soluções e orientações para coaches conduzindo o Hackathon Kubernetes para Sysadmins Linux.

## Diretrizes para Coaches

1. **Não dê respostas imediatamente** — deixe os estudantes se esforçarem e descobrirem. É aí que o aprendizado acontece.
2. **Use a analogia com Linux** — quando um estudante estiver travado, relacione o conceito K8s com Linux. "Lembra do iptables? NetworkPolicy é a mesma ideia."
3. **Incentive o `kubectl describe`** — a maioria das respostas está na seção de eventos da saída do `describe`.
4. **Deixe-os quebrar coisas** — as seções Break & Fix são os momentos de aprendizado mais valiosos.
5. **Valide, não memorize** — os estudantes devem consultar a [documentação oficial](https://kubernetes.io/docs/) durante o hackathon.

## Soluções

- [Solução 01: Seu Primeiro Container](Solution-01.md)
- [Solução 02: De Container para Pod](Solution-02.md)
- [Solução 03: Criando um Cluster Local](Solution-03.md)
- [Solução 04: Deployments e Rolling Updates](Solution-04.md)
- [Solução 05: Services e Rede](Solution-05.md)
- [Solução 06: Ingress e Gateway API](Solution-06.md)
- [Solução 07: Volumes e Persistência](Solution-07.md)
- [Solução 08: ConfigMaps e Secrets](Solution-08.md)
- [Solução 09: Segurança: RBAC e Pod Security](Solution-09.md)
- [Solução 10: Autoscaling e Gerenciamento de Recursos](Solution-10.md)
- [Solução 11: Helm, Kustomize e GitOps](Solution-11.md)
- [Solução 12: Observabilidade: Prometheus e Grafana](Solution-12.md)
- [Solução 13: Troubleshooting: Break and Fix](Solution-13.md)
- [Solução 14: Deploy na Nuvem](Solution-14.md)
- [Solução 15: Agendamento de Pods e Gerenciamento de Recursos](Solution-15.md)
- [Solução 16: Engenharia de Imagens de Container](Solution-16.md)
- [Solução 17: Estratégias Avançadas de Deployment](Solution-17.md)
- [Solução 18: Administração de Cluster com kubeadm](Solution-18.md)
- [Solução 19: Segurança e Hardening de Cluster](Solution-19.md)
- [Solução 20: Supply Chain e Segurança em Runtime](Solution-20.md)

## Recomendações de Tempo

| Desafio | Tempo Estimado | Notas |
|-----------|---------------|-------|
| 01 | 30 min | Rápido se já tiver experiência com Docker |
| 02 | 30 min | Primeira experiência com kubectl |
| 03 | 45 min | Setup do cluster pode variar |
| 04 | 45 min | Conceitos principais de deployment |
| 05 | 60 min | Rede leva tempo |
| 06 | 60 min | Setup do Ingress é ponto de dificuldade comum |
| 07 | 45 min | Conceitos de storage são rápidos para pessoal de Linux |
| 08 | 30 min | Direto ao ponto |
| 09 | 60 min | RBAC é conceitualmente complexo |
| 10 | 45 min | Setup do Metrics Server necessário |
| 11 | 60 min | Helm tem curva de aprendizado |
| 12 | 60 min | Instalação da stack leva tempo |
| 13 | 90 min | Desafio mais valioso |
| 14 | 60+ min | Depende do acesso à nuvem |
| 15 | 90 min | Muitos conceitos de agendamento; cluster de 3 nodes necessário |
| 16 | 60 min | Familiaridade com Docker/Podman ajuda |
| 17 | 75 min | Múltiplos padrões de deployment para praticar |
| 18 | 120 min | Setup de VMs adiciona overhead; kubeadm é complexo |
| 19 | 120–150 min | Nível CKS; algumas tarefas precisam de acesso ao node + setup gVisor/Cilium |
| 20 | 90–120 min | Muitas ferramentas para instalar (Trivy, Falco, cosign) |

**Total: ~18-22 horas** (ideal para um hackathon de 3 dias ou ritmo individual em 1-2 semanas)
