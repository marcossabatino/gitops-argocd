#!/bin/bash

# Universal deployment script that works on any Linux distribution
# Detects distro and installs prerequisites if needed

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================="
echo "Observability Stack - Deployment Script"
echo "=========================================="
echo ""

# Source distro detection
source "$SCRIPT_DIR/scripts/01-detect-distro.sh"

DISTRO=$(detect_distro)
PM=$(get_package_manager $DISTRO)

echo "🐧 Distribuição Linux: $DISTRO"
echo "📦 Gerenciador: $PM"
echo ""

# Check if make is installed, install if not
if ! command -v make &> /dev/null; then
    echo "⚠️  Make não encontrado. Instalando..."
    install_package make
fi

# Check if AWS credentials are configured
if ! aws sts get-caller-identity &>/dev/null; then
    echo "❌ AWS credentials não configurados"
    echo ""
    echo "Configure com: aws configure"
    exit 1
fi

# Check if terraform.tfvars exists
if [ ! -f "$SCRIPT_DIR/terraform/terraform.tfvars" ]; then
    echo "⚠️  terraform.tfvars não encontrado"
    echo "Criando a partir do template..."
    cp "$SCRIPT_DIR/terraform/terraform.tfvars.example" "$SCRIPT_DIR/terraform/terraform.tfvars"
    echo "✓ Arquivo criado em: terraform/terraform.tfvars"
    echo ""
fi

echo "=========================================="
echo "INICIANDO DEPLOY COMPLETO"
echo "=========================================="
echo ""
echo "Isto vai:"
echo "  1. Build das imagens Docker"
echo "  2. Push para ECR"
echo "  3. Criar infraestrutura AWS (VPC + EKS)"
echo "  4. Configurar kubectl"
echo "  5. Instalar stack de monitoramento"
echo "  6. Deploy das aplicações"
echo ""
echo "⏱️  Tempo estimado: 60-70 minutos"
echo "💰 Custo estimado: ~$0.60 USD para 3 horas"
echo ""

read -p "Deseja prosseguir? (s/n) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Ss]$ ]]; then
    echo "Operação cancelada"
    exit 0
fi

echo ""
echo "Iniciando..."
echo ""

# Run make all from the project directory
cd "$SCRIPT_DIR"
make all

echo ""
echo "=========================================="
echo "✅ DEPLOY COMPLETO"
echo "=========================================="
echo ""
echo "Próximas ações:"
echo "  1. Verificar status:"
echo "     make status"
echo ""
echo "  2. Acessar Grafana:"
echo "     make port-forward"
echo "     Browser: http://localhost:3000"
echo "     User: admin"
echo "     Password: observability123"
echo ""
echo "  3. Destruir recursos (quando terminar):"
echo "     make destroy"
echo ""
