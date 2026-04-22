#!/bin/bash

set -e

echo "Deploying applications..."

REGISTRY="${REGISTRY:-$(aws sts get-caller-identity --query Account --output text).dkr.ecr.us-east-2.amazonaws.com}"

# Substitui o nome simples da imagem (ex: java-app:latest) pelo caminho completo do ECR
replace_registry() {
    local file=$1
    local app_name
    app_name=$(basename "$(dirname "$file")")
    sed "s|image: ${app_name}:latest|image: ${REGISTRY}/${app_name}:latest|g" "${file}" | kubectl apply -f -
}

# Create apps namespace
echo "Creating apps namespace..."
kubectl apply -f kubernetes/apps/namespace.yaml

# Deploy Java app
echo "Deploying Java app..."
replace_registry kubernetes/apps/java-app/deployment.yaml
kubectl apply -f kubernetes/apps/java-app/service.yaml
kubectl apply -f kubernetes/apps/java-app/servicemonitor.yaml

# Deploy Go app
echo "Deploying Go app..."
replace_registry kubernetes/apps/go-app/deployment.yaml
kubectl apply -f kubernetes/apps/go-app/service.yaml
kubectl apply -f kubernetes/apps/go-app/servicemonitor.yaml

# Deploy Python app
echo "Deploying Python app..."
replace_registry kubernetes/apps/python-app/deployment.yaml
kubectl apply -f kubernetes/apps/python-app/service.yaml
kubectl apply -f kubernetes/apps/python-app/servicemonitor.yaml

# Deploy Nginx
echo "Deploying Nginx..."
kubectl apply -f kubernetes/apps/nginx/configmap.yaml
replace_registry kubernetes/apps/nginx/deployment.yaml
kubectl apply -f kubernetes/apps/nginx/service.yaml
kubectl apply -f kubernetes/apps/nginx/servicemonitor.yaml

# Deploy Load Tester
echo "Deploying Load Tester..."
replace_registry kubernetes/apps/load-tester/deployment.yaml
kubectl apply -f kubernetes/apps/load-tester/service.yaml

# Wait for deployments
echo "Waiting for applications to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/java-app -n apps || true
kubectl wait --for=condition=available --timeout=300s deployment/go-app -n apps || true
kubectl wait --for=condition=available --timeout=300s deployment/python-app -n apps || true
kubectl wait --for=condition=available --timeout=300s deployment/nginx -n apps || true
kubectl wait --for=condition=available --timeout=300s deployment/load-tester -n apps || true

echo "✓ Applications deployed successfully!"
echo ""
echo "To check app status:"
echo "  kubectl get pods -n apps"
echo ""
echo "To check metrics in Prometheus:"
echo "  kubectl port-forward -n monitoring svc/prometheus-operated 9090:9090"
echo "  Then visit http://localhost:9090 and search for 'http_requests_total'"
