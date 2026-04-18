# Observability Portfolio - Implementation Summary

## Project Overview

A complete, production-ready observability demonstration using open-source tools deployed to AWS EKS. This portfolio project demonstrates:

- **Infrastructure as Code** with Terraform
- **Kubernetes** orchestration and deployment patterns
- **Prometheus** metrics collection and storage
- **Grafana** visualization and dashboarding
- **Distributed Tracing** with OpenTelemetry and Grafana Tempo
- **Multi-language instrumentation** (Java, Go, Python)
- **APM-like experience** equivalent to Datadog APM using only OSS tools

## What Was Built

### 1. Infrastructure (AWS EKS)

**File:** `terraform/`

- VPC with 3 availability zones (3 public + 3 private subnets)
- Single NAT Gateway for cost optimization
- EKS cluster with 3 t3.medium SPOT nodes
- Managed node groups with auto-scaling (min 2, desired 3, max 5)
- OIDC provider for IRSA (IAM Roles for Service Accounts)
- Security groups and network policies
- AWS EBS CSI driver for persistent volumes

**Cost: ~$27/month nodes + $72/month control plane**

### 2. Observability Stack

**Files:** `kubernetes/monitoring/`

#### Prometheus
- 20 GiB persistent storage (gp2 EBS)
- Exemplar storage enabled (for trace ↔ metric linking)
- 30-second scrape interval
- 30-day retention

#### Grafana
- Admin UI at `localhost:3000` (admin/observability123)
- 5 GiB persistent storage
- Pre-configured Prometheus datasource
- Pre-configured Tempo datasource
- 4 pre-built dashboards auto-loaded from ConfigMaps

#### Grafana Tempo
- Single-binary mode (lightweight)
- 5 GiB local storage
- OTLP receiver (gRPC port 4317, HTTP port 4318)
- Integrated trace search in Grafana

#### OpenTelemetry Collector
- Central OTLP ingestion point
- Memory limiter processor (prevents OOM)
- Batch processor (reduces egress load)
- Exports traces to Tempo
- Pod annotations for Prometheus scraping

### 3. Applications

**Files:** `apps/` and `kubernetes/apps/`

#### Java App (Spring Boot)
- Micrometer + Prometheus registry (`/actuator/prometheus`)
- OTel Java Agent for zero-code instrumentation
- Micrometer Tracing Bridge for exemplar support
- 2 replicas with pod anti-affinity

#### Go App
- Prometheus client library
- OTel SDK with HTTP middleware
- Native histogram with exemplar support
- 2 replicas

#### Python App (FastAPI)
- prometheus_client for metrics
- OTel auto-instrumentation via CLI
- Uvicorn ASGI server
- 2 replicas

#### Nginx
- Reverse proxy (optional)
- nginx-prometheus-exporter sidecar
- stub_status endpoint enabled
- 1 replica

#### Load Tester (Go)
- Sends 10 requests/sec per pod to all target services
- Distributes load: 70% `/health`, 20% `/simulate-slow`, 10% `/simulate-error`
- Auto-scales with replica count
- Exposes its own Prometheus metrics
- 1 replica (scale to 3+ to increase load)

### 4. Endpoints (All Apps)

- `GET /health` → 200 OK (baseline latency ~5ms)
- `GET /simulate-slow` → 200 OK with 1-3s sleep (generates P99 latency)
- `GET /simulate-error` → 50% chance 500 (generates error rate)
- `GET /metrics` → Prometheus endpoint
- `GET /actuator/prometheus` → Java app metrics endpoint

### 5. Grafana Dashboards

**Files:** `kubernetes/monitoring/dashboards/`

#### APM Overview
- Request rate by service (5m average)
- Error rate % by service
- Latency percentiles (P50, P95, P99) by service
- RED metrics in single view
- One-click drill-down to service detail

#### Service Detail
- RED metrics time series
- Error breakdown by status code
- Latency heatmap (histogram)
- Top error types
- Recent traces from Tempo (with Tempo datasource)
- Exemplar dots on latency graph that link to traces

#### JVM Metrics (Java Only)
- Heap memory (used/max/committed)
- GC pause duration (P99)
- Thread count (live/daemon/peak)
- Process CPU usage

#### Load Tester Activity
- Requests/sec sent per target
- Observed response latencies (P95, P99)
- Active requests gauge
- Observed error rate

### 6. Deployment Automation

**Files:** `scripts/` and `Makefile`

```bash
make help              # Show all available targets
make all               # One-command full deploy
make infra-up          # Create AWS infrastructure (15 min)
make cluster-config    # Configure kubectl
make stack-up          # Install monitoring stack (10 min)
make push              # Build and push Docker images
make apps-up           # Deploy applications (5 min)
make port-forward      # Access local UI at localhost:3000
make status            # Show all pods/services
make destroy           # Delete all AWS resources
```

## Technical Highlights

### Exemplar-Driven APM

The defining feature of the project:

1. **Request gets trace ID** (OTel)
2. **Histogram observation is tagged with trace ID** (Micrometer/prometheus_client exemplar)
3. **Prometheus stores trace ID with metric** (exemplar storage enabled)
4. **Grafana detects exemplar in histogram** (native support)
5. **User clicks latency spike dot → opens trace in Tempo** (exemplar linking)

This recreates the "jump from metric spike to distributed trace" feature that makes Datadog APM powerful, entirely with OSS.

### Cost Optimization

- **SPOT instances** instead of on-demand (~60% savings)
- **Single NAT Gateway** instead of 3 (~$32/month savings)
- **t3.medium nodes** (smallest reasonable for this stack)
- **Minimal resource requests** in deployments
- **30-day Prometheus retention** instead of longer

Total: ~$100/month vs ~$300+/month for on-demand equivalents

### Production Patterns

- **Multi-stage Dockerfile** builds (smaller images, faster deploys)
- **Non-root user** in all containers
- **Resource requests and limits** (QoS guarantees)
- **Liveness and readiness probes** (health checks)
- **Pod anti-affinity** (spread across nodes)
- **OIDC provider** for future fine-grained IAM

### Observability Best Practices

- **Consistent metric names** across languages (http_requests_total, http_request_duration_seconds)
- **Consistent histogram buckets** (0.005s to 10s) for comparable P99
- **Exemplars enabled** for trace linking
- **OpenTelemetry standardization** (OTLP protocol, SDK usage)
- **Graceful shutdown** (terminationGracePeriodSeconds configured)

## Files Structure

```
observability-prometheus-grafana/
├── Makefile                           # Single-command orchestration
├── README.md                          # Architecture overview
├── DEPLOY.md                          # Step-by-step deployment guide
├── SUMMARY.md                         # This file
│
├── terraform/                         # Infrastructure as Code
│   ├── main.tf                        # Root module
│   ├── versions.tf                    # Provider versions
│   ├── variables.tf                   # Input variables
│   ├── outputs.tf                     # Outputs (cluster endpoint, etc)
│   ├── terraform.tfvars.example       # Template for variables
│   └── modules/
│       ├── vpc/                       # VPC, subnets, NAT, security groups
│       └── eks/                       # EKS cluster, node group, add-ons
│
├── kubernetes/                        # Kubernetes configuration
│   ├── monitoring/
│   │   ├── namespace.yaml
│   │   ├── kube-prometheus-stack/
│   │   │   ├── values.yaml            # Prometheus + Grafana + Alertmanager Helm values
│   │   │   └── (scrapers, datasources configured here)
│   │   ├── tempo/
│   │   │   └── values.yaml            # Tempo single-binary Helm values
│   │   ├── otel-collector/
│   │   │   └── values.yaml            # OTel Collector Helm values
│   │   └── dashboards/
│   │       ├── apm-overview.yaml      # APM overview dashboard ConfigMap
│   │       ├── service-detail.yaml    # Service drill-down dashboard ConfigMap
│   │       ├── jvm-metrics.yaml       # Java internals dashboard ConfigMap
│   │       └── load-tester.yaml       # Load tester metrics dashboard ConfigMap
│   │
│   └── apps/                          # Application deployments
│       ├── namespace.yaml
│       ├── java-app/
│       ├── go-app/
│       ├── python-app/
│       ├── nginx/
│       └── load-tester/
│
├── apps/                              # Application source code
│   ├── java-app/
│   │   ├── Dockerfile                 # Multi-stage build
│   │   ├── pom.xml                    # Maven dependencies
│   │   ├── src/main/java/com/obs/
│   │   │   ├── Application.java       # Spring Boot entry point
│   │   │   └── MetricsController.java # /health, /simulate-* endpoints
│   │   └── src/main/resources/
│   │       └── application.properties # Spring Boot config
│   │
│   ├── go-app/
│   │   ├── Dockerfile
│   │   ├── go.mod / go.sum
│   │   └── main.go                    # HTTP server + OTel + Prometheus
│   │
│   ├── python-app/
│   │   ├── Dockerfile
│   │   ├── requirements.txt
│   │   └── main.py                    # FastAPI + OTel auto-instrumentation
│   │
│   └── load-tester/
│       ├── Dockerfile
│       ├── go.mod / go.sum
│       └── main.go                    # Load generator + metrics exporter
│
└── scripts/                           # Automation scripts
    ├── 03-install-monitoring.sh       # Helm installs
    ├── 04-deploy-apps.sh              # kubectl apply
    ├── 05-port-forward.sh             # Local access
    └── teardown.sh                    # Cleanup
```

## Deployment Flow

```
1. Clone repo
   ↓
2. `make infra-up` (Terraform: VPC + EKS)
   ↓
3. `make cluster-config` (kubectl credentials)
   ↓
4. `make push` (Docker: build + ECR push)
   ↓
5. `make stack-up` (Helm: Prometheus, Grafana, Tempo, OTel)
   ↓
6. `make apps-up` (kubectl: Java, Go, Python, Nginx, Load Tester)
   ↓
7. `make port-forward` (local access)
   ↓
8. Open http://localhost:3000 → Grafana dashboard
   ↓
9. `make destroy` (cleanup when done)
```

**Total Time: ~45-60 minutes (mostly AWS resource provisioning)**

## Learning Outcomes

After completing this project, you'll understand:

- ✅ **Terraform modules** for reusable infrastructure
- ✅ **EKS architecture** (control plane, node groups, add-ons, networking)
- ✅ **Prometheus scrape config** and ServiceMonitor CRDs
- ✅ **Grafana datasources** and dashboard JSON
- ✅ **OpenTelemetry instrumentation** in 3 languages
- ✅ **Distributed tracing** concepts (spans, trace context, sampling)
- ✅ **Exemplar support** in modern observability stacks
- ✅ **Multi-language apps** in Kubernetes
- ✅ **Helm charts** usage and customization
- ✅ **Cost optimization** strategies for AWS

## Next Steps (Beyond Portfolio)

1. **Production Hardening**
   - TLS between components
   - RBAC and network policies
   - Pod security policies
   - Secrets management (Sealed Secrets, External Secrets Operator)

2. **Advanced Features**
   - Alerting rules (PrometheusRule CRDs)
   - Thanos for long-term storage
   - Custom metrics from applications
   - Logs with Loki/Grafana Loki
   - SLOs via Prometheus recording rules

3. **Scaling**
   - Multi-replica Prometheus with remote storage
   - Cortex or Mimir for metric federation
   - Jaeger or Tempo with object storage (S3)
   - Custom dashboards for your services

4. **Automation**
   - GitOps with Flux or ArgoCD
   - Automated dashboard generation
   - Metric-driven scaling (KEDA)
   - Automatic troubleshooting (Zebra, ML-based anomaly detection)

## Cost Management

### Monthly Costs (3x t3.medium SPOT)

| Resource | Cost |
|----------|------|
| EKS Control | $72 |
| EC2 Nodes | $27 |
| Storage | $3 |
| **Total** | **~$100** |

### Cost Reduction

- **Stop cluster**: `make destroy` (~$100 saved)
- **Reduce nodes to 2**: `-$9/month`
- **Smaller Prometheus**: 10GiB instead of 20GiB (`-$1/month`)
- **On-demand instead of SPOT**: `+$54/month` (avoid!)

---

**Project Status: Complete** ✅

All components are functional and ready for deployment. See [DEPLOY.md](DEPLOY.md) for step-by-step instructions.
