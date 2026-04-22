# GitOps com ArgoCD — Plataforma de Observabilidade no AWS EKS

Implementação de uma plataforma de entrega contínua baseada em GitOps para uma stack de observabilidade multi-linguagem rodando no AWS EKS. O repositório é a única fonte da verdade: toda mudança de infraestrutura e aplicação passa pelo git antes de chegar ao cluster.

---

## Índice

1. [Visão Geral](#1-visão-geral)
2. [Arquitetura](#2-arquitetura)
3. [Pré-requisitos](#3-pré-requisitos)
4. [Estrutura do Repositório](#4-estrutura-do-repositório)
5. [Parte 1 — Instalação do ArgoCD](#parte-1--instalação-do-argocd)
6. [Parte 2 — AppProject e Controle de Acesso](#parte-2--appproject-e-controle-de-acesso)
7. [Parte 3 — App of Apps Pattern](#parte-3--app-of-apps-pattern)
8. [Parte 4 — Stack de Monitoramento via ArgoCD](#parte-4--stack-de-monitoramento-via-argocd)
9. [Parte 5 — ApplicationSet para Workloads](#parte-5--applicationset-para-workloads)
10. [Parte 6 — Sync Waves: Ordem de Deploy](#parte-6--sync-waves-ordem-de-deploy)
11. [Parte 7 — ArgoCD Image Updater com ECR](#parte-7--argocd-image-updater-com-ecr)
12. [Parte 8 — Notificações](#parte-8--notificações)
13. [Parte 9 — Argo Rollouts com Análise via Prometheus](#parte-9--argo-rollouts-com-análise-via-prometheus)
14. [Verificação e Status](#14-verificação-e-status)
15. [Troubleshooting](#15-troubleshooting)

---

## 1. Visão Geral

### O que é GitOps?

GitOps é uma prática onde o estado desejado da infraestrutura e das aplicações é declarado em um repositório git. Uma ferramenta de reconciliação — neste caso, o ArgoCD — monitora esse repositório e garante que o cluster sempre reflita o que está no git. Qualquer desvio é detectado e corrigido automaticamente.

O fluxo é:
```
Desenvolvedor faz push → ArgoCD detecta mudança → ArgoCD aplica no cluster
```

Em vez de:
```
Desenvolvedor executa kubectl apply → (sem rastreabilidade, sem rollback automático)
```

### Stack da Plataforma

| Componente | Função |
|---|---|
| **AWS EKS** | Cluster Kubernetes gerenciado |
| **Terraform** | Provisionamento da infraestrutura (VPC, EKS, IAM) |
| **ArgoCD** | Operador GitOps — sincroniza git com o cluster |
| **ArgoCD ApplicationSet** | Gera Applications dinamicamente a partir de templates |
| **ArgoCD Image Updater** | Detecta novas imagens no ECR e atualiza o git |
| **Argo Rollouts** | Progressive delivery com canary e análise automática |
| **kube-prometheus-stack** | Prometheus + Grafana + Alertmanager |
| **Grafana Tempo** | Rastreamento distribuído (distributed tracing) |
| **OpenTelemetry Collector** | Pipeline de telemetria |

### Aplicações

Três serviços com instrumentação OpenTelemetry expondo métricas, traces e health checks:

- **java-app** — Spring Boot com OTel Java Agent
- **go-app** — Go com OTel SDK
- **python-app** — FastAPI com OTel auto-instrumentation

---

## 2. Arquitetura

### Fluxo GitOps Completo

```
┌─────────────────────────────────────────────────────────────────┐
│                         Git Repository                          │
│                                                                 │
│  argocd/root/root-app.yaml  →  argocd/apps/  (App of Apps)    │
│                                     ├── monitoring/             │
│                                     │   ├── namespaces-app      │
│                                     │   ├── kube-prometheus-stack│
│                                     │   ├── tempo               │
│                                     │   └── otel-collector      │
│                                     └── workloads/              │
│                                         ├── apps-applicationset │
│                                         ├── nginx-app           │
│                                         └── load-tester-app     │
└────────────────────┬────────────────────────────────────────────┘
                     │ monitora (polling a cada 3 min)
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│                           ArgoCD                                │
│                                                                 │
│   ┌─────────┐    ┌──────────────┐    ┌──────────────────────┐  │
│   │  root   │───▶│  monitoring  │    │  ApplicationSet      │  │
│   │  app    │    │  apps        │    │  (java/go/python)    │  │
│   └─────────┘    └──────────────┘    └──────────────────────┘  │
└────────────────────┬────────────────────────────────────────────┘
                     │ kubectl apply
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│                        AWS EKS Cluster                          │
│                                                                 │
│  namespace: monitoring          namespace: apps                 │
│  ┌──────────────────────────┐  ┌──────────────────────────┐    │
│  │ Prometheus  Grafana      │  │ java-app  go-app          │    │
│  │ Tempo       OTel         │  │ python-app  nginx         │    │
│  └──────────────────────────┘  └──────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

### Sync Waves (Ordem de Deploy)

```
Wave -1  →  namespaces (apps, monitoring)
Wave  0  →  kube-prometheus-stack (Prometheus + Grafana)
Wave  1  →  Tempo + OTel Collector (dependem do Prometheus)
Wave  2  →  java-app, go-app, python-app, nginx
Wave  3  →  load-tester (só faz sentido após as apps estarem no ar)
```

---

## 3. Pré-requisitos

Antes de começar, certifique-se de ter:

**Ferramentas instaladas:**
```bash
# Verificar versões
kubectl version --client    # >= 1.28
helm version                # >= 3.14
argocd version --client     # >= 2.10
aws --version               # >= 2.x
```

**Instalar o CLI do ArgoCD:**
```bash
# Linux
curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x argocd
sudo mv argocd /usr/local/bin/

# Verificar
argocd version --client
```

**Cluster EKS em execução:**
```bash
# O cluster deve estar provisionado via Terraform (ver terraform/)
# Configurar o kubeconfig
aws eks update-kubeconfig --name observability-cluster --region us-east-2

# Verificar conectividade
kubectl get nodes
```

**Repositório no GitHub:**

O ArgoCD precisa de acesso ao repositório git para sincronizar. Faça o push do código para o GitHub antes de prosseguir:

```bash
# Substitua SEU_USUARIO pelo seu usuário do GitHub
git remote add origin https://github.com/SEU_USUARIO/gitops-argocd.git
git push -u origin main
```

**Substituir placeholders em todos os arquivos:**

```bash
# Obter o Account ID
aws sts get-caller-identity --query Account --output text

# Substituir em todos os arquivos (execute na raiz do repositório)
GITHUB_USER="seu-usuario-github"
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

find argocd/ kubernetes/overlays/ -type f \
  -exec sed -i "s/SEU_USUARIO/${GITHUB_USER}/g" {} \; \
  -exec sed -i "s/SEU_ACCOUNT_ID/${AWS_ACCOUNT_ID}/g" {} \;

# Commit e push das alterações
git add -A && git commit -m "config: substitui placeholders de usuário e account ID"
git push
```

---

## 4. Estrutura do Repositório

```
gitops-argocd/
├── argocd/                          # Manifests do ArgoCD
│   ├── install/
│   │   └── values.yaml              # Helm values para instalar o ArgoCD
│   ├── projects/
│   │   └── portfolio.yaml           # AppProject — controla o que o ArgoCD pode acessar
│   ├── root/
│   │   └── root-app.yaml            # App of Apps — a Application raiz
│   ├── apps/
│   │   ├── monitoring/              # Applications da stack de monitoramento
│   │   │   ├── namespaces-app.yaml
│   │   │   ├── kube-prometheus-stack-app.yaml
│   │   │   ├── tempo-app.yaml
│   │   │   └── otel-collector-app.yaml
│   │   └── workloads/               # Applications das aplicações
│   │       ├── apps-applicationset.yaml
│   │       ├── nginx-app.yaml
│   │       └── load-tester-app.yaml
│   ├── rollouts/                    # Argo Rollouts (canary deployments)
│   │   ├── analysis/
│   │   │   └── success-rate-template.yaml
│   │   ├── java-rollout.yaml
│   │   ├── go-rollout.yaml
│   │   └── python-rollout.yaml
│   ├── image-updater/
│   │   └── values.yaml              # Helm values para o Image Updater
│   └── notifications/
│       └── values.yaml              # Configuração de notificações
│
├── kubernetes/
│   ├── apps/                        # Manifests base das aplicações
│   │   ├── java-app/
│   │   ├── go-app/
│   │   ├── python-app/
│   │   ├── nginx/
│   │   └── load-tester/
│   ├── monitoring/                  # Helm values da stack de monitoramento
│   │   ├── kube-prometheus-stack/
│   │   ├── tempo/
│   │   └── otel-collector/
│   ├── namespaces/
│   │   └── kustomization.yaml       # Agrupamento de namespaces para o ArgoCD
│   └── overlays/
│       └── production/              # Kustomize overlays — ArgoCD usa estes
│           ├── java-app/
│           ├── go-app/
│           ├── python-app/
│           ├── nginx/
│           └── load-tester/
│
└── terraform/                       # Infraestrutura AWS (VPC + EKS)
    ├── modules/
    │   ├── vpc/
    │   └── eks/
    └── *.tf
```

---

## Parte 1 — Instalação do ArgoCD

### Conceito

O ArgoCD é instalado no próprio cluster Kubernetes que ele vai gerenciar. Ele roda como um conjunto de pods no namespace `argocd` e fica constantemente checando se o estado do cluster bate com o que está no git. Quando detecta diferença, ele reconcilia — ou seja, aplica o que está no git no cluster.

### Passo 1.1 — Adicionar o repositório Helm

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
```

### Passo 1.2 — Instalar o ArgoCD

```bash
kubectl create namespace argocd

helm install argocd argo/argo-cd \
  --namespace argocd \
  --version ">=7.0.0" \
  --values argocd/install/values.yaml \
  --wait
```

**O que esperar:** O processo leva 2-3 minutos. Ao final, os seguintes pods devem estar `Running`:

```bash
kubectl get pods -n argocd
# NAME                                               READY   STATUS
# argocd-application-controller-0                   1/1     Running
# argocd-applicationset-controller-xxx              1/1     Running
# argocd-notifications-controller-xxx               1/1     Running
# argocd-redis-xxx                                  1/1     Running
# argocd-repo-server-xxx                            1/1     Running
# argocd-server-xxx                                 1/1     Running
```

### Passo 1.3 — Acessar a Interface Web

```bash
# Em um terminal separado, deixe este comando rodando:
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Acesse `https://localhost:8080` no navegador (aceite o certificado auto-assinado).

**Obter a senha inicial:**
```bash
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

Login: `admin` / senha obtida acima.

### Passo 1.4 — Login via CLI

```bash
argocd login localhost:8080 \
  --username admin \
  --password "$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d)" \
  --insecure
```

**Alterar a senha (recomendado):**
```bash
argocd account update-password
```

---

## Parte 2 — AppProject e Controle de Acesso

### Conceito

Um **AppProject** define os limites de segurança dentro do ArgoCD:
- Quais repositórios git podem ser usados como fonte
- Quais clusters e namespaces são destinos permitidos
- Quais recursos Kubernetes podem ser criados
- Quais usuários têm acesso

Sem um AppProject customizado, tudo usa o projeto `default` que tem acesso irrestrito. Criar um projeto específico é boa prática e demonstra compreensão de RBAC.

### Passo 2.1 — Registrar o repositório no ArgoCD

O ArgoCD precisa de credenciais para ler o repositório privado no GitHub.

**Via token de acesso pessoal:**
```bash
# Gere um token em: GitHub → Settings → Developer Settings → Personal Access Tokens
# Permissões necessárias: repo (read)

argocd repo add https://github.com/SEU_USUARIO/gitops-argocd \
  --username SEU_USUARIO \
  --password SEU_GITHUB_TOKEN
```

**Verificar:**
```bash
argocd repo list
# CONNECTION STATUS   TYPE   REPO
# Successful          git    https://github.com/SEU_USUARIO/gitops-argocd
```

### Passo 2.2 — Criar o AppProject

```bash
kubectl apply -f argocd/projects/portfolio.yaml
```

**Verificar:**
```bash
argocd proj list
# NAME       DESCRIPTION
# portfolio  Plataforma de observabilidade multi-linguagem no AWS EKS

argocd proj get portfolio
```

---

## Parte 3 — App of Apps Pattern

### Conceito

O **App of Apps** é o padrão central do GitOps com ArgoCD. A ideia é simples: existe uma **Application raiz** que, em vez de gerenciar recursos de aplicação (Deployments, Services), gerencia outras Applications do ArgoCD.

Isso resolve um problema fundamental: quando você tem dezenas de aplicações para gerenciar, não quer aplicar cada Application manualmente. Com o App of Apps, você aplica **apenas uma** Application raiz, e ela cria todas as outras automaticamente.

O fluxo é:

```
Você aplica: root-app.yaml (uma vez, manualmente)
     ↓
ArgoCD monitora: argocd/apps/ (diretório inteiro)
     ↓
ArgoCD cria automaticamente:
  namespaces-app, kube-prometheus-stack, tempo,
  otel-collector, apps-applicationset, nginx, load-tester
```

A partir daí, adicionar uma nova Application é só criar um arquivo YAML no diretório `argocd/apps/` e fazer push. O ArgoCD detecta e cria automaticamente.

### Passo 3.1 — Aplicar a Application raiz

Esta é a única Application que você aplica manualmente. Todas as outras são gerenciadas por ela.

```bash
kubectl apply -f argocd/root/root-app.yaml
```

**Verificar na UI:** Acesse `https://localhost:8080` e você verá a Application `root` criada. Em alguns minutos, ela detectará o diretório `argocd/apps/` e começará a criar as Applications filhas.

**Verificar via CLI:**
```bash
argocd app list
# NAME   CLUSTER                         NAMESPACE  STATUS
# root   https://kubernetes.default.svc  argocd     Syncing
```

```bash
# Acompanhar a sincronização em tempo real
argocd app get root --watch
```

---

## Parte 4 — Stack de Monitoramento via ArgoCD

### Conceito

A stack de monitoramento (Prometheus, Grafana, Tempo, OTel Collector) é gerenciada via Helm. O ArgoCD tem suporte nativo a Helm — você define o chart e os values no arquivo Application, e o ArgoCD faz o `helm install` por você.

Usamos o recurso **multi-source** do ArgoCD (disponível desde 2.6): o chart vem do repositório Helm público, mas os values ficam no seu repositório git. Isso significa que alterar os values no git dispara um redeploy automático.

As Applications de monitoramento já foram criadas pelo App of Apps na etapa anterior.

### Passo 4.1 — Verificar o status das Applications de monitoramento

```bash
argocd app list
# NAME                      STATUS    HEALTH
# namespaces                Synced    Healthy
# kube-prometheus-stack     Syncing   Progressing
# tempo                     OutOfSync Unknown
# otel-collector            OutOfSync Unknown
```

O `OutOfSync` inicial é esperado — o ArgoCD aguarda o `kube-prometheus-stack` terminar (sync wave 0) antes de instalar Tempo e OTel (sync wave 1).

```bash
# Acompanhar o kube-prometheus-stack
argocd app get kube-prometheus-stack --watch
```

**O que esperar:** O kube-prometheus-stack leva 3-5 minutos para estar `Healthy`. Após isso, Tempo e OTel sincronizam automaticamente.

### Passo 4.2 — Verificar os pods

```bash
kubectl get pods -n monitoring
# NAME                                                   READY   STATUS
# kube-prometheus-stack-prometheus-0                    2/2     Running
# kube-prometheus-stack-grafana-xxx                     3/3     Running
# tempo-0                                               1/1     Running
# opentelemetry-collector-xxx                           1/1     Running
```

### Passo 4.3 — Acessar o Grafana

```bash
# Em novo terminal
kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80
```

Acesse `http://localhost:3000` — login: `admin` / `observability123`.

---

## Parte 5 — ApplicationSet para Workloads

### Conceito

O **ApplicationSet** é um controlador que gera Applications dinamicamente a partir de um template. Em vez de criar três arquivos `java-app.yaml`, `go-app.yaml`, `python-app.yaml` quase idênticos, você define um template e uma lista de elementos.

O ApplicationSet deste projeto usa o generator `list`:

```yaml
generators:
  - list:
      elements:
        - app: java-app
        - app: go-app
        - app: python-app
```

Isso gera três Applications, cada uma apontando para `kubernetes/overlays/production/{app}`. Para adicionar uma nova aplicação no futuro, basta incluir um novo item na lista.

### Como o Kustomize Overlay funciona

Os manifests base em `kubernetes/apps/{app}/` têm imagens genéricas (`image: java-app:latest`). O Kustomize overlay transforma essas referências para o caminho completo no ECR:

```
Base:    image: java-app:latest
Overlay: image: SEU_ACCOUNT_ID.dkr.ecr.us-east-2.amazonaws.com/java-app:latest
```

Quando o Image Updater detecta uma nova imagem no ECR, ele atualiza o campo `newTag` no `kustomization.yaml` e faz commit no git. O ArgoCD detecta e sincroniza.

### Passo 5.1 — Verificar o ApplicationSet e as Applications geradas

```bash
# Ver o ApplicationSet
kubectl get applicationsets -n argocd

# Ver as Applications geradas
argocd app list
# NAME          STATUS    HEALTH
# java-app      Synced    Healthy
# go-app        Synced    Healthy
# python-app    Synced    Healthy
# nginx         Synced    Healthy
# load-tester   Synced    Healthy
```

### Passo 5.2 — Verificar os pods das aplicações

```bash
kubectl get pods -n apps
# NAME                          READY   STATUS    RESTARTS
# java-app-xxx                  1/1     Running   0
# go-app-xxx                    1/1     Running   0
# python-app-xxx                1/1     Running   0
# nginx-xxx                     2/2     Running   0
# load-tester-xxx               1/1     Running   0
```

---

## Parte 6 — Sync Waves: Ordem de Deploy

### Conceito

Por padrão, o ArgoCD sincroniza todos os recursos ao mesmo tempo. Mas em um sistema real, a ordem importa: o namespace deve existir antes dos pods, o Prometheus deve estar rodando antes do Tempo, e as aplicações antes do load tester.

**Sync Waves** resolvem isso com uma anotação simples:

```yaml
annotations:
  argocd.argoproj.io/sync-wave: "0"   # Wave 0 é aplicado primeiro
```

O ArgoCD processa as waves em ordem crescente e espera que todos os recursos de uma wave estejam `Healthy` antes de avançar para a próxima.

### Waves configuradas neste projeto

| Wave | Application | Justificativa |
|------|-------------|---------------|
| `-1` | `namespaces` | Namespaces devem existir antes de qualquer recurso |
| `0` | `kube-prometheus-stack` | Prometheus e Grafana primeiro |
| `1` | `tempo`, `otel-collector` | Dependem do Prometheus para remote write |
| `2` | `java-app`, `go-app`, `python-app`, `nginx` | Apps no ar |
| `3` | `load-tester` | Só faz sentido com as apps respondendo |

### Como verificar as waves em ação

```bash
# Ver a ordem em que as Applications foram criadas
kubectl get applications -n argocd --sort-by=.metadata.creationTimestamp

# Ver eventos de sincronização
argocd app get root -o json | jq '.status.operationState.syncResult'
```

### Alterar a ordem de deploy

Para mudar a wave de uma Application, edite a anotação no arquivo YAML e faça push:

```bash
# Exemplo: mover load-tester para wave 4
# Edite argocd/apps/workloads/load-tester-app.yaml:
#   annotations:
#     argocd.argoproj.io/sync-wave: "4"

git add argocd/apps/workloads/load-tester-app.yaml
git commit -m "config: move load-tester para sync wave 4"
git push
```

---

## Parte 7 — ArgoCD Image Updater com ECR

### Conceito

O **Image Updater** fecha o loop do GitOps para atualizações de imagens. Sem ele, ao fazer push de uma nova imagem para o ECR, é necessário atualizar manualmente o tag no manifesto do git. Com o Image Updater:

1. Você faz push da imagem `java-app:v1.2.0` para o ECR
2. O Image Updater detecta a nova tag
3. Ele atualiza o campo `newTag` no `kubernetes/overlays/production/java-app/kustomization.yaml`
4. Faz commit e push no git
5. O ArgoCD detecta o commit e faz deploy da nova versão automaticamente

O pipeline completo:
```
push (código) → CI build → ECR push → Image Updater → git commit → ArgoCD sync → deploy
```

### Passo 7.1 — Configurar IRSA para o Image Updater

O Image Updater precisa de permissões IAM para ler o ECR. Usamos IRSA (IAM Roles for Service Accounts) — o método seguro no EKS.

**Obter informações do cluster:**
```bash
CLUSTER_NAME="observability-cluster"
REGION="us-east-2"
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

OIDC_URL="$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$REGION" \
  --query 'cluster.identity.oidc.issuer' \
  --output text | sed 's|https://||')"

echo "OIDC URL: $OIDC_URL"
```

**Criar a IAM Policy:**
```bash
cat > /tmp/ecr-read-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:DescribeImages",
        "ecr:ListImages"
      ],
      "Resource": "*"
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name ArgocdImageUpdaterECRPolicy \
  --policy-document file:///tmp/ecr-read-policy.json
```

**Criar o IAM Role com trust policy para o OIDC do EKS:**
```bash
cat > /tmp/trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_URL}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_URL}:sub": "system:serviceaccount:argocd:argocd-image-updater",
          "${OIDC_URL}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

aws iam create-role \
  --role-name argocd-image-updater \
  --assume-role-policy-document file:///tmp/trust-policy.json

aws iam attach-role-policy \
  --role-name argocd-image-updater \
  --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/ArgocdImageUpdaterECRPolicy"
```

**Atualizar o values.yaml com o ARN do role:**
```bash
ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/argocd-image-updater"

sed -i "s|arn:aws:iam::SEU_ACCOUNT_ID:role/argocd-image-updater|${ROLE_ARN}|g" \
  argocd/image-updater/values.yaml

git add argocd/image-updater/values.yaml
git commit -m "config: adiciona ARN do IRSA role ao Image Updater"
git push
```

### Passo 7.2 — Configurar credenciais git para write-back

O Image Updater precisa de um token GitHub para commitar as atualizações de tag.

**Gerar token GitHub:**
1. GitHub → Settings → Developer Settings → Personal Access Tokens → Fine-grained tokens
2. Permissões: `Contents: Read and Write` no repositório `gitops-argocd`

**Criar o secret no cluster:**
```bash
kubectl create secret generic argocd-image-updater-secret \
  --from-literal=gitCredentials="https://SEU_USUARIO:SEU_GITHUB_TOKEN@github.com" \
  -n argocd
```

### Passo 7.3 — Instalar o Image Updater

```bash
helm install argocd-image-updater argo/argocd-image-updater \
  --namespace argocd \
  --values argocd/image-updater/values.yaml \
  --wait
```

### Passo 7.4 — Ativar o Image Updater nas Applications

Descomente o bloco de anotações em `argocd/apps/workloads/apps-applicationset.yaml` e substitua `SEU_ACCOUNT_ID`:

```yaml
metadata:
  annotations:
    argocd-image-updater.argoproj.io/image-list: >
      app=SEU_ACCOUNT_ID.dkr.ecr.us-east-2.amazonaws.com/{{app}}
    argocd-image-updater.argoproj.io/app.update-strategy: semver
    argocd-image-updater.argoproj.io/write-back-method: git
    argocd-image-updater.argoproj.io/git-branch: main
    argocd-image-updater.argoproj.io/app.kustomize.image-name: "{{app}}"
```

```bash
git add argocd/apps/workloads/apps-applicationset.yaml
git commit -m "feat: ativa Image Updater nas Applications de workload"
git push
```

### Passo 7.5 — Verificar o Image Updater

```bash
# Ver logs do Image Updater
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-image-updater -f

# Esperado:
# time="..." level=info msg="Considering application 'java-app' for update"
# time="..." level=info msg="Checking for updates to image 'java-app'"
```

---

## Parte 8 — Notificações

### Conceito

O controlador de Notificações do ArgoCD envia alertas sobre eventos das Applications: falha de sync, degradação de saúde, deploys bem-sucedidos. Configuramos notificações via Slack.

### Passo 8.1 — Criar um webhook no Slack

1. Acesse `https://api.slack.com/apps`
2. "Create New App" → "From scratch" → Nome: `ArgoCD`
3. "Incoming Webhooks" → ative → "Add New Webhook to Workspace"
4. Selecione o canal `#deployments`
5. Copie o token (começa com `xoxb-`)

### Passo 8.2 — Criar o secret do Slack

```bash
kubectl create secret generic argocd-notifications-secret \
  --from-literal=slack-token=xoxb-SEU-TOKEN \
  -n argocd
```

### Passo 8.3 — Aplicar a configuração de notificações

```bash
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-notifications-cm
  namespace: argocd
data:
  trigger.on-sync-failed: |
    - when: app.status.operationState.phase in ['Error', 'Failed']
      send: [slack-sync-failed]
  trigger.on-deployed: |
    - when: app.status.operationState.phase in ['Succeeded'] && app.status.health.status == 'Healthy'
      send: [slack-deployed]
  trigger.on-health-degraded: |
    - when: app.status.health.status == 'Degraded'
      send: [slack-health-degraded]
  template.slack-sync-failed: |
    message: |
      :x: *{{.app.metadata.name}}* falhou ao sincronizar
      Erro: {{.app.status.operationState.message}}
  template.slack-deployed: |
    message: |
      :rocket: *{{.app.metadata.name}}* deployado com sucesso
      Revisão: {{.app.status.sync.revision}}
  template.slack-health-degraded: |
    message: |
      :warning: *{{.app.metadata.name}}* com saúde degradada
  service.slack: |
    token: $slack-token
    username: ArgoCD
EOF
```

### Passo 8.4 — Adicionar subscriptions nas Applications

Adicione em `argocd/apps/workloads/apps-applicationset.yaml`:

```yaml
metadata:
  annotations:
    notifications.argoproj.io/subscribe.on-sync-failed.slack: deployments
    notifications.argoproj.io/subscribe.on-deployed.slack: deployments
    notifications.argoproj.io/subscribe.on-health-degraded.slack: deployments
```

---

## Parte 9 — Argo Rollouts com Análise via Prometheus

### Conceito

O **Argo Rollouts** substitui o `Deployment` pelo `Rollout`, adicionando estratégias de progressive delivery:

- **Canary**: tráfego enviado gradualmente para a nova versão
- **Com análise automática**: métricas do Prometheus decidem se avança ou reverte

Se a nova versão causar mais de 5% de erros, o Rollout **reverte automaticamente**.

**Fluxo do canary:**
```
Deploy nova versão
     ↓
20% do tráfego → nova versão | 80% → versão anterior
     ↓ aguarda 60s
Consulta Prometheus: taxa de sucesso >= 95%?
     ↓ SIM                    ↓ NÃO
50% → nova versão         Rollback automático
     ↓ aguarda 60s
100% → nova versão (promoção completa)
```

### Passo 9.1 — Instalar o Argo Rollouts

```bash
kubectl create namespace argo-rollouts

kubectl apply -n argo-rollouts \
  -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

# Instalar plugin kubectl
curl -LO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
chmod +x kubectl-argo-rollouts-linux-amd64
sudo mv kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts
```

**Verificar:**
```bash
kubectl get pods -n argo-rollouts
# NAME                              READY   STATUS
# argo-rollouts-xxx                 1/1     Running
```

### Passo 9.2 — Aplicar o AnalysisTemplate

O `AnalysisTemplate` consulta o Prometheus para decidir a saúde do deploy:

```bash
kubectl apply -f argocd/rollouts/analysis/success-rate-template.yaml
```

```bash
kubectl get analysistemplate -n apps
# NAME            AGE
# success-rate    30s
```

### Passo 9.3 — Migrar para Rollouts

```bash
# Deletar os Deployments existentes
kubectl delete deployment java-app go-app python-app -n apps

# Aplicar os Rollouts
kubectl apply -f argocd/rollouts/java-rollout.yaml
kubectl apply -f argocd/rollouts/go-rollout.yaml
kubectl apply -f argocd/rollouts/python-rollout.yaml
```

**Verificar o status:**
```bash
kubectl argo rollouts get rollout java-app -n apps --watch
# Name:            java-app
# Status:          ✔ Healthy
# Strategy:        Canary
#   Step:          6/6
#   SetWeight:     100
#   ActualWeight:  100
```

### Passo 9.4 — Testar um Rollout canary

```bash
# Atualizar a imagem para disparar um novo rollout
kubectl argo rollouts set image java-app \
  java-app=SEU_ACCOUNT_ID.dkr.ecr.us-east-2.amazonaws.com/java-app:v2.0.0 \
  -n apps

# Acompanhar em tempo real
kubectl argo rollouts get rollout java-app -n apps --watch
```

### Passo 9.5 — Controle manual

```bash
# Promover para o próximo step (quando pausado)
kubectl argo rollouts promote java-app -n apps

# Reverter para a versão anterior
kubectl argo rollouts abort java-app -n apps
kubectl argo rollouts undo java-app -n apps
```

### Passo 9.6 — Integrar Rollouts com o ArgoCD

Para que o ArgoCD entenda o status dos Rollouts:

```bash
kubectl patch configmap argocd-cm -n argocd --patch '
data:
  resource.customizations.health.argoproj.io_Rollout: |
    hs = {}
    if obj.status ~= nil then
      if obj.status.phase == "Degraded" then
        hs.status = "Degraded"
        hs.message = obj.status.message
      elseif obj.status.phase == "Paused" then
        hs.status = "Suspended"
        hs.message = "Rollout pausado"
      elseif obj.status.phase == "Healthy" then
        hs.status = "Healthy"
        hs.message = "Rollout completo"
      else
        hs.status = "Progressing"
        hs.message = "Rollout em progresso"
      end
    else
      hs.status = "Progressing"
    end
    return hs
'
```

---

## 14. Verificação e Status

### Checklist completo

```bash
# Cluster e nós
kubectl get nodes

# Pods do ArgoCD
kubectl get pods -n argocd

# Pods de monitoramento
kubectl get pods -n monitoring

# Pods das aplicações
kubectl get pods -n apps

# Todas as Applications do ArgoCD
argocd app list

# Detalhes de uma Application
argocd app get java-app

# Status dos Rollouts
kubectl argo rollouts list rollouts -n apps

# Events recentes (útil para debugging)
kubectl get events --all-namespaces --sort-by=.metadata.creationTimestamp | tail -20
```

### Verificar o ciclo GitOps completo

```bash
# Fazer uma mudança pequena e observar o ciclo
echo "# test $(date)" >> kubernetes/apps/go-app/deployment.yaml
git add kubernetes/apps/go-app/deployment.yaml
git commit -m "test: verifica ciclo GitOps"
git push

# Aguardar e monitorar (ArgoCD checa a cada ~3 minutos)
watch -n 15 'argocd app get go-app | grep -E "Status|Health|Revision"'
```

---

## 15. Troubleshooting

### Application em OutOfSync persistente

```bash
# Ver o diff entre git e cluster
argocd app diff java-app

# Forçar sincronização
argocd app sync java-app --force --wait
```

### Application em Unknown/Degraded

```bash
# Ver detalhes dos recursos com problema
argocd app get java-app --show-operation

# Ver eventos do Kubernetes
kubectl get events -n apps --sort-by=.metadata.creationTimestamp
```

### Image Updater não detecta novas imagens

```bash
# Ver logs detalhados
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-image-updater --tail=50

# Testar se IRSA está funcionando
kubectl exec -n argocd -it \
  $(kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-image-updater -o name) \
  -- aws ecr get-login-password --region us-east-2 | head -c 20
```

### Rollout preso em Paused

```bash
# Ver análises em execução
kubectl get analysisrun -n apps

# Ver resultado de uma análise específica
kubectl describe analysisrun -n apps

# Promover manualmente
kubectl argo rollouts promote java-app -n apps

# Ou abortar
kubectl argo rollouts abort java-app -n apps
```

### Erro de permissão no AppProject

```bash
# Ver as restrições do projeto
argocd proj get portfolio

# Ver logs de erros de autorização
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server --tail=50 \
  | grep -i "permission\|unauthorized"
```
