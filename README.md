# GitOps with ArgoCD — Multi-Language Observability Platform on AWS EKS

A complete GitOps implementation for a multi-language observability stack running on AWS EKS. The repository is the single source of truth: every infrastructure and application change goes through git before reaching the cluster.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Prerequisites](#3-prerequisites)
4. [Repository Structure](#4-repository-structure)
5. [Part 1 — ArgoCD Installation](#part-1--argocd-installation)
6. [Part 2 — AppProject and Access Control](#part-2--appproject-and-access-control)
7. [Part 3 — App of Apps Pattern](#part-3--app-of-apps-pattern)
8. [Part 4 — Monitoring Stack via ArgoCD](#part-4--monitoring-stack-via-argocd)
9. [Part 5 — ApplicationSet for Workloads](#part-5--applicationset-for-workloads)
10. [Part 6 — Sync Waves: Deployment Order](#part-6--sync-waves-deployment-order)
11. [Part 7 — ArgoCD Image Updater with ECR](#part-7--argocd-image-updater-with-ecr)
12. [Part 8 — Notifications](#part-8--notifications)
13. [Part 9 — Argo Rollouts with Prometheus Analysis](#part-9--argo-rollouts-with-prometheus-analysis)
14. [Verification and Status](#14-verification-and-status)
15. [Troubleshooting](#15-troubleshooting)

---

## 1. Overview

### What is GitOps?

GitOps is a practice where the desired state of infrastructure and applications is declared in a git repository. A reconciliation tool — in this case, ArgoCD — monitors that repository and ensures the cluster always reflects what's in git. Any deviation is detected and automatically corrected.

The flow is:
```
Developer pushes → ArgoCD detects change → ArgoCD applies to cluster
```

Instead of:
```
Developer runs kubectl apply → (no traceability, no automatic rollback)
```

### Platform Stack

| Component | Function |
|---|---|
| **AWS EKS** | Managed Kubernetes cluster |
| **Terraform** | Infrastructure provisioning (VPC, EKS, IAM) |
| **ArgoCD** | GitOps operator — syncs git with cluster |
| **ArgoCD ApplicationSet** | Dynamically generates Applications from templates |
| **ArgoCD Image Updater** | Detects new ECR images and updates git |
| **Argo Rollouts** | Progressive delivery with canary and automatic analysis |
| **kube-prometheus-stack** | Prometheus + Grafana + Alertmanager |
| **Grafana Tempo** | Distributed tracing (APM) |
| **OpenTelemetry Collector** | Telemetry pipeline |

### Applications

Three services with OpenTelemetry instrumentation exposing metrics, traces, and health checks:

- **java-app** — Spring Boot with OTel Java Agent
- **go-app** — Go with OTel SDK
- **python-app** — FastAPI with OTel auto-instrumentation

---

## 2. Architecture

### Complete GitOps Flow

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
                     │ monitors (polling every ~3 min)
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

### Sync Waves (Deployment Order)

```
Wave -1  →  namespaces (apps, monitoring)
Wave  0  →  kube-prometheus-stack (Prometheus + Grafana)
Wave  1  →  Tempo + OTel Collector (depend on Prometheus)
Wave  2  →  java-app, go-app, python-app, nginx
Wave  3  →  load-tester (only makes sense with apps running)
```

---

## 3. Prerequisites

Before starting, ensure you have:

**Tools installed:**
```bash
# Check versions
kubectl version --client    # >= 1.28
helm version                # >= 3.14
argocd version --client     # >= 2.10
aws --version               # >= 2.x
```

**Install ArgoCD CLI:**
```bash
# Linux
curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x argocd
sudo mv argocd /usr/local/bin/

# Verify
argocd version --client
```

**Running EKS cluster:**
```bash
# Cluster must be provisioned via Terraform (see terraform/)
# Configure kubeconfig
aws eks update-kubeconfig --name observability-cluster --region us-east-2

# Verify connectivity
kubectl get nodes
```

**GitHub repository:**

ArgoCD needs access to the git repository to sync. Push code to GitHub first:

```bash
# Replace YOUR_USERNAME with your GitHub username
git remote add origin https://github.com/YOUR_USERNAME/gitops-argocd.git
git push -u origin main
```

**Replace placeholders in all files:**

```bash
# Get Account ID
aws sts get-caller-identity --query Account --output text

# Replace in all files (run from repository root)
GITHUB_USER="your-github-username"
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

find argocd/ kubernetes/overlays/ -type f \
  -exec sed -i "s/SEU_USUARIO/${GITHUB_USER}/g" {} \; \
  -exec sed -i "s/SEU_ACCOUNT_ID/${AWS_ACCOUNT_ID}/g" {} \;

# Commit and push changes
git add -A && git commit -m "config: replace username and account ID placeholders"
git push
```

---

## 4. Repository Structure

```
gitops-argocd/
├── argocd/                          # ArgoCD manifests
│   ├── install/
│   │   └── values.yaml              # Helm values for ArgoCD installation
│   ├── projects/
│   │   └── portfolio.yaml           # AppProject — controls ArgoCD access
│   ├── root/
│   │   └── root-app.yaml            # Root application (App of Apps)
│   ├── apps/
│   │   ├── monitoring/              # Monitoring stack applications
│   │   │   ├── namespaces-app.yaml
│   │   │   ├── kube-prometheus-stack-app.yaml
│   │   │   ├── tempo-app.yaml
│   │   │   └── otel-collector-app.yaml
│   │   └── workloads/               # Workload applications
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
│   │   └── values.yaml              # Image Updater Helm values
│   └── notifications/
│       └── values.yaml              # Notifications configuration
│
├── kubernetes/
│   ├── apps/                        # Base application manifests
│   │   ├── java-app/
│   │   ├── go-app/
│   │   ├── python-app/
│   │   ├── nginx/
│   │   └── load-tester/
│   ├── monitoring/                  # Monitoring stack Helm values
│   │   ├── kube-prometheus-stack/
│   │   ├── tempo/
│   │   └── otel-collector/
│   ├── namespaces/
│   │   └── kustomization.yaml       # Namespace aggregation for ArgoCD
│   └── overlays/
│       └── production/              # Kustomize overlays — used by ArgoCD
│           ├── java-app/
│           ├── go-app/
│           ├── python-app/
│           ├── nginx/
│           └── load-tester/
│
└── terraform/                       # AWS infrastructure (VPC + EKS)
    ├── modules/
    │   ├── vpc/
    │   └── eks/
    └── *.tf
```

---

## Part 1 — ArgoCD Installation

### Concept

ArgoCD is installed on the same Kubernetes cluster it manages. It runs as a set of pods in the `argocd` namespace and continuously checks if the cluster state matches what's in git. When it detects a difference, it reconciles — applying what's in git to the cluster.

### Step 1.1 — Add the Helm repository

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
```

### Step 1.2 — Install ArgoCD

```bash
kubectl create namespace argocd

helm install argocd argo/argo-cd \
  --namespace argocd \
  --version ">=7.0.0" \
  --values argocd/install/values.yaml \
  --wait
```

**What to expect:** The process takes 2-3 minutes. After completion, these pods should be `Running`:

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

### Step 1.3 — Access the Web UI

```bash
# In a separate terminal, keep this running:
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Access `https://localhost:8080` in your browser (accept the self-signed certificate).

**Get initial password:**
```bash
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

Login: `admin` / password from above.

### Step 1.4 — CLI Login

```bash
argocd login localhost:8080 \
  --username admin \
  --password "$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d)" \
  --insecure
```

**Change password (recommended):**
```bash
argocd account update-password
```

---

## Part 2 — AppProject and Access Control

### Concept

An **AppProject** defines security boundaries within ArgoCD:
- Which git repositories can be sources
- Which clusters and namespaces are allowed as destinations
- Which Kubernetes resources can be created
- Which users have access

Without a custom AppProject, everything uses the `default` project with unrestricted access. Creating a specific project is best practice and demonstrates RBAC understanding.

### Step 2.1 — Register the repository

ArgoCD needs credentials to read the GitHub repository.

**Using personal access token:**
```bash
# Generate token at: GitHub → Settings → Developer Settings → Personal Access Tokens
# Required permissions: repo (read)

argocd repo add https://github.com/YOUR_USERNAME/gitops-argocd \
  --username YOUR_USERNAME \
  --password YOUR_GITHUB_TOKEN
```

**Verify:**
```bash
argocd repo list
# CONNECTION STATUS   TYPE   REPO
# Successful          git    https://github.com/YOUR_USERNAME/gitops-argocd
```

### Step 2.2 — Create the AppProject

```bash
kubectl apply -f argocd/projects/portfolio.yaml
```

**Verify:**
```bash
argocd proj list
# NAME       DESCRIPTION
# portfolio  Multi-language observability platform on AWS EKS

argocd proj get portfolio
```

---

## Part 3 — App of Apps Pattern

### Concept

The **App of Apps** is the central GitOps pattern with ArgoCD. A single **root Application** manages other ArgoCD Applications instead of managing application resources (Deployments, Services) directly.

This solves a fundamental problem: when managing dozens of applications, you don't want to apply each Application manually. With App of Apps, you apply **only one** root Application, and it automatically creates all others.

The flow is:

```
You apply: root-app.yaml (once, manually)
     ↓
ArgoCD monitors: argocd/apps/ (entire directory)
     ↓
ArgoCD automatically creates:
  namespaces-app, kube-prometheus-stack, tempo,
  otel-collector, apps-applicationset, nginx, load-tester
```

Adding a new Application is simple: create a YAML file in `argocd/apps/` and push. ArgoCD detects and creates it automatically.

### Step 3.1 — Apply the root Application

This is the only Application you apply manually. All others are managed by it.

```bash
kubectl apply -f argocd/root/root-app.yaml
```

**Check in the UI:** Access `https://localhost:8080` and you'll see the `root` Application. Within a few minutes, it will detect the `argocd/apps/` directory and automatically create all child Applications.

**Check via CLI:**
```bash
argocd app list
# NAME   CLUSTER                         NAMESPACE  STATUS
# root   https://kubernetes.default.svc  argocd     Syncing
```

```bash
# Watch synchronization in real time
argocd app get root --watch
```

---

## Part 4 — Monitoring Stack via ArgoCD

### Concept

The monitoring stack (Prometheus, Grafana, Tempo, OTel Collector) is managed via Helm. ArgoCD has native Helm support — you define the chart and values in the Application file, and ArgoCD runs `helm install` for you.

We use ArgoCD's **multi-source** feature (available since 2.6): the chart comes from a public Helm repository, but values are in your git repository. Changing values in git triggers automatic re-deployment.

The monitoring Applications were created by the App of Apps in the previous step.

### Step 4.1 — Check monitoring Applications status

```bash
argocd app list
# NAME                      STATUS    HEALTH
# namespaces                Synced    Healthy
# kube-prometheus-stack     Syncing   Progressing
# tempo                     OutOfSync Unknown
# otel-collector            OutOfSync Unknown
```

The `OutOfSync` initially is expected — ArgoCD waits for `kube-prometheus-stack` (sync wave 0) to complete before installing Tempo and OTel (sync wave 1).

```bash
# Watch kube-prometheus-stack
argocd app get kube-prometheus-stack --watch
```

**What to expect:** kube-prometheus-stack takes 3-5 minutes to reach `Healthy` status (Prometheus and Grafana need initialization). After that, Tempo and OTel automatically sync.

### Step 4.2 — Check pods

```bash
kubectl get pods -n monitoring
# NAME                                                   READY   STATUS
# kube-prometheus-stack-prometheus-0                    2/2     Running
# kube-prometheus-stack-grafana-xxx                     3/3     Running
# tempo-0                                               1/1     Running
# opentelemetry-collector-xxx                           1/1     Running
```

### Step 4.3 — Access Grafana

```bash
# In a new terminal
kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80
```

Access `http://localhost:3000` — login: `admin` / `observability123`.

---

## Part 5 — ApplicationSet for Workloads

### Concept

The **ApplicationSet** controller generates Applications dynamically from a template. Instead of creating three similar files (java-app.yaml, go-app.yaml, python-app.yaml), you define a template and a list of elements, and the controller auto-generates the Applications.

This project's ApplicationSet uses the `list` generator:

```yaml
generators:
  - list:
      elements:
        - app: java-app
        - app: go-app
        - app: python-app
```

This generates three Applications, each pointing to `kubernetes/overlays/production/{app}`. To add a new application, just add an item to the list.

### How Kustomize Overlay works

Base manifests in `kubernetes/apps/{app}/` have generic image names (`image: java-app:latest`). The Kustomize overlay transforms these to the full ECR path:

```
Base:    image: java-app:latest
Overlay: image: YOUR_ACCOUNT_ID.dkr.ecr.us-east-2.amazonaws.com/java-app:latest
```

When Image Updater detects a new ECR image, it updates the `newTag` field in `kustomization.yaml` and commits to git. ArgoCD detects and syncs.

### Step 5.1 — Check the ApplicationSet and generated Applications

```bash
# View the ApplicationSet
kubectl get applicationsets -n argocd

# View generated Applications
argocd app list
# NAME          STATUS    HEALTH
# java-app      Synced    Healthy
# go-app        Synced    Healthy
# python-app    Synced    Healthy
# nginx         Synced    Healthy
# load-tester   Synced    Healthy
```

### Step 5.2 — Check application pods

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

## Part 6 — Sync Waves: Deployment Order

### Concept

By default, ArgoCD syncs all resources simultaneously. But in real systems, order matters: namespaces must exist before pods, Prometheus must run before Tempo (which writes metrics to it), and apps before the load tester.

**Sync Waves** solve this with a simple annotation:

```yaml
annotations:
  argocd.argoproj.io/sync-wave: "0"   # Wave 0 applies first
```

ArgoCD processes waves in ascending order and waits for all resources in a wave to reach `Healthy` before moving to the next.

### Waves in this project

| Wave | Application | Reason |
|------|-------------|--------|
| `-1` | `namespaces` | Namespaces must exist before any resource |
| `0` | `kube-prometheus-stack` | Prometheus and Grafana first |
| `1` | `tempo`, `otel-collector` | Depend on Prometheus for remote write |
| `2` | `java-app`, `go-app`, `python-app`, `nginx` | Apps running |
| `3` | `load-tester` | Only makes sense with apps responding |

### How to verify waves

```bash
# View Applications in creation order
kubectl get applications -n argocd --sort-by=.metadata.creationTimestamp

# Check sync events
argocd app get root -o json | jq '.status.operationState.syncResult'
```

### Change deployment order

To change an Application's wave, edit the annotation and push:

```bash
# Example: move load-tester to wave 4
# Edit argocd/apps/workloads/load-tester-app.yaml:
#   annotations:
#     argocd.argoproj.io/sync-wave: "4"

git add argocd/apps/workloads/load-tester-app.yaml
git commit -m "config: move load-tester to sync wave 4"
git push
```

---

## Part 7 — ArgoCD Image Updater with ECR

### Concept

The **Image Updater** closes the GitOps loop for image updates. Without it, pushing a new image to ECR requires manually updating the tag in git. With Image Updater:

1. Push image `java-app:v1.2.0` to ECR
2. Image Updater detects the new tag
3. Updates `newTag` field in `kubernetes/overlays/production/java-app/kustomization.yaml`
4. Commits and pushes to git
5. ArgoCD detects the commit and auto-deploys

Complete pipeline:
```
push (code) → CI build → ECR push → Image Updater → git commit → ArgoCD sync → deploy
```

### Step 7.1 — Configure IRSA for Image Updater

Image Updater needs IAM permissions to read ECR. We use IRSA (IAM Roles for Service Accounts) — the secure method on EKS.

**Get cluster information:**
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

**Create IAM Policy:**
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

**Create IAM Role with OIDC trust policy:**
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

**Update Image Updater values with the role ARN:**
```bash
ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/argocd-image-updater"

sed -i "s|arn:aws:iam::SEU_ACCOUNT_ID:role/argocd-image-updater|${ROLE_ARN}|g" \
  argocd/image-updater/values.yaml

git add argocd/image-updater/values.yaml
git commit -m "config: add IRSA role ARN to Image Updater"
git push
```

### Step 7.2 — Configure git credentials for write-back

Image Updater needs a GitHub token to commit tag updates.

**Generate GitHub token:**
1. GitHub → Settings → Developer Settings → Personal Access Tokens → Fine-grained tokens
2. Permissions: `Contents: Read and Write` on `gitops-argocd` repository

**Create the secret:**
```bash
kubectl create secret generic argocd-image-updater-secret \
  --from-literal=gitCredentials="https://YOUR_USERNAME:YOUR_GITHUB_TOKEN@github.com" \
  -n argocd
```

### Step 7.3 — Install Image Updater

```bash
helm install argocd-image-updater argo/argocd-image-updater \
  --namespace argocd \
  --values argocd/image-updater/values.yaml \
  --wait
```

### Step 7.4 — Enable Image Updater on Applications

Uncomment the annotations block in `argocd/apps/workloads/apps-applicationset.yaml` and replace `SEU_ACCOUNT_ID`:

```yaml
metadata:
  annotations:
    argocd-image-updater.argoproj.io/image-list: >
      app=YOUR_ACCOUNT_ID.dkr.ecr.us-east-2.amazonaws.com/{{app}}
    argocd-image-updater.argoproj.io/app.update-strategy: semver
    argocd-image-updater.argoproj.io/write-back-method: git
    argocd-image-updater.argoproj.io/git-branch: main
    argocd-image-updater.argoproj.io/app.kustomize.image-name: "{{app}}"
```

```bash
git add argocd/apps/workloads/apps-applicationset.yaml
git commit -m "feat: enable Image Updater on workload Applications"
git push
```

### Step 7.5 — Verify Image Updater

```bash
# View Image Updater logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-image-updater -f

# Expected output:
# time="..." level=info msg="Considering application 'java-app' for update"
# time="..." level=info msg="Checking for updates to image 'java-app'"
```

---

## Part 8 — Notifications

### Concept

ArgoCD's Notifications controller sends alerts about Application events: sync failures, health degradation, successful deployments. We configure Slack notifications.

### Step 8.1 — Create Slack webhook

1. Access `https://api.slack.com/apps`
2. "Create New App" → "From scratch" → Name: `ArgoCD`
3. "Incoming Webhooks" → enable → "Add New Webhook to Workspace"
4. Select `#deployments` channel
5. Copy the token (starts with `xoxb-`)

### Step 8.2 — Create Slack secret

```bash
kubectl create secret generic argocd-notifications-secret \
  --from-literal=slack-token=xoxb-YOUR-TOKEN \
  -n argocd
```

### Step 8.3 — Apply notifications configuration

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
      :x: *{{.app.metadata.name}}* failed to sync
      Error: {{.app.status.operationState.message}}
  template.slack-deployed: |
    message: |
      :rocket: *{{.app.metadata.name}}* deployed successfully
      Revision: {{.app.status.sync.revision}}
  template.slack-health-degraded: |
    message: |
      :warning: *{{.app.metadata.name}}* health degraded
  service.slack: |
    token: $slack-token
    username: ArgoCD
EOF
```

### Step 8.4 — Add subscriptions to Applications

Add annotations in `argocd/apps/workloads/apps-applicationset.yaml`:

```yaml
metadata:
  annotations:
    notifications.argoproj.io/subscribe.on-sync-failed.slack: deployments
    notifications.argoproj.io/subscribe.on-deployed.slack: deployments
    notifications.argoproj.io/subscribe.on-health-degraded.slack: deployments
```

---

## Part 9 — Argo Rollouts with Prometheus Analysis

### Concept

**Argo Rollouts** replaces the `Deployment` resource with `Rollout`, adding advanced progressive delivery strategies:

- **Canary**: gradually send traffic to the new version
- **With automatic analysis**: Prometheus metrics decide whether to advance or rollback

If the new version causes more than 5% errors, the Rollout **automatically reverts**.

**Canary flow:**
```
Deploy new version
     ↓
20% traffic → new version | 80% → previous version
     ↓ waits 60s
Query Prometheus: success rate >= 95%?
     ↓ YES                    ↓ NO
50% → new version         Auto-rollback
     ↓ waits 60s
100% → new version (full promotion)
```

### Step 9.1 — Install Argo Rollouts

```bash
kubectl create namespace argo-rollouts

kubectl apply -n argo-rollouts \
  -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

# Install kubectl plugin
curl -LO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
chmod +x kubectl-argo-rollouts-linux-amd64
sudo mv kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts
```

**Verify:**
```bash
kubectl get pods -n argo-rollouts
# NAME                              READY   STATUS
# argo-rollouts-xxx                 1/1     Running
```

### Step 9.2 — Apply the AnalysisTemplate

The `AnalysisTemplate` queries Prometheus to decide deployment health:

```bash
kubectl apply -f argocd/rollouts/analysis/success-rate-template.yaml
```

```bash
kubectl get analysistemplate -n apps
# NAME            AGE
# success-rate    30s
```

### Step 9.3 — Migrate to Rollouts

```bash
# Delete existing Deployments
kubectl delete deployment java-app go-app python-app -n apps

# Apply Rollouts
kubectl apply -f argocd/rollouts/java-rollout.yaml
kubectl apply -f argocd/rollouts/go-rollout.yaml
kubectl apply -f argocd/rollouts/python-rollout.yaml
```

**Check status:**
```bash
kubectl argo rollouts get rollout java-app -n apps --watch
# Name:            java-app
# Status:          ✔ Healthy
# Strategy:        Canary
#   Step:          6/6
#   SetWeight:     100
#   ActualWeight:  100
```

### Step 9.4 — Test a canary rollout

```bash
# Update the image to trigger a new rollout
kubectl argo rollouts set image java-app \
  java-app=YOUR_ACCOUNT_ID.dkr.ecr.us-east-2.amazonaws.com/java-app:v2.0.0 \
  -n apps

# Watch in real time
kubectl argo rollouts get rollout java-app -n apps --watch
```

### Step 9.5 — Manual control

```bash
# Promote to next step (when paused)
kubectl argo rollouts promote java-app -n apps

# Revert to previous version
kubectl argo rollouts abort java-app -n apps
kubectl argo rollouts undo java-app -n apps
```

### Step 9.6 — Integrate Rollouts with ArgoCD

For ArgoCD to understand Rollout status:

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
        hs.message = "Rollout paused"
      elseif obj.status.phase == "Healthy" then
        hs.status = "Healthy"
        hs.message = "Rollout complete"
      else
        hs.status = "Progressing"
        hs.message = "Rollout in progress"
      end
    else
      hs.status = "Progressing"
    end
    return hs
'
```

---

## 14. Verification and Status

### Complete checklist

```bash
# Cluster and nodes
kubectl get nodes

# ArgoCD pods
kubectl get pods -n argocd

# Monitoring pods
kubectl get pods -n monitoring

# Application pods
kubectl get pods -n apps

# All ArgoCD Applications
argocd app list

# Details of a specific Application
argocd app get java-app

# Rollout status
kubectl argo rollouts list rollouts -n apps

# Recent events (useful for debugging)
kubectl get events --all-namespaces --sort-by=.metadata.creationTimestamp | tail -20
```

### Verify complete GitOps cycle

```bash
# Make a small change and observe the cycle
echo "# test $(date)" >> kubernetes/apps/go-app/deployment.yaml
git add kubernetes/apps/go-app/deployment.yaml
git commit -m "test: verify GitOps cycle"
git push

# Wait and monitor (ArgoCD checks every ~3 minutes)
watch -n 15 'argocd app get go-app | grep -E "Status|Health|Revision"'
```

---

## 15. Troubleshooting

### Application stuck OutOfSync

```bash
# View diff between git and cluster
argocd app diff java-app

# Force synchronization
argocd app sync java-app --force --wait
```

### Application Unknown/Degraded

```bash
# View resource details with issues
argocd app get java-app --show-operation

# View Kubernetes events
kubectl get events -n apps --sort-by=.metadata.creationTimestamp
```

### Image Updater not detecting new images

```bash
# View detailed logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-image-updater --tail=50

# Test IRSA is working
kubectl exec -n argocd -it \
  $(kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-image-updater -o name) \
  -- aws ecr get-login-password --region us-east-2 | head -c 20
```

### Rollout stuck Paused

```bash
# View running analyses
kubectl get analysisrun -n apps

# View specific analysis result
kubectl describe analysisrun -n apps

# Promote manually
kubectl argo rollouts promote java-app -n apps

# Or abort
kubectl argo rollouts abort java-app -n apps
```

### AppProject permission error

```bash
# View project restrictions
argocd proj get portfolio

# View authorization errors
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server --tail=50 \
  | grep -i "permission\|unauthorized"
```
