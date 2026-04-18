#!/bin/bash

set -e

# Setup prerequisites for any Linux distribution
# Detects distro and installs required tools

source "$(dirname "$0")/01-detect-distro.sh"

echo "=========================================="
echo "SETUP DE PRÉ-REQUISITOS"
echo "=========================================="
echo ""

DISTRO=$(detect_distro)
PM=$(get_package_manager $DISTRO)

echo "✓ Distribuição detectada: $DISTRO"
echo "✓ Gerenciador de pacotes: $PM"
echo ""

# Check if tools are already installed
check_tool() {
    local tool=$1
    local cmd=${2:-$tool}

    if command -v $cmd &> /dev/null; then
        echo "✅ $tool já está instalado"
        return 0
    else
        echo "📦 Instalando $tool..."
        return 1
    fi
}

echo "Verificando e instalando ferramentas necessárias..."
echo ""

# 1. Check/Install Terraform
if ! check_tool "Terraform" "terraform"; then
    if [ "$PM" = "apt-get" ]; then
        curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
        sudo apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
        install_package terraform
    elif [ "$PM" = "dnf" ]; then
        sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/fedora/hashicorp.repo
        install_package terraform
    elif [ "$PM" = "zypper" ]; then
        install_package terraform
    else
        echo "❌ Por favor, instale Terraform manualmente em: https://www.terraform.io/downloads.html"
    fi
fi

# 2. Check/Install kubectl
if ! check_tool "kubectl"; then
    echo "   Baixando kubectl..."
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm -f kubectl
fi

# 3. Check/Install Helm
if ! check_tool "Helm" "helm"; then
    echo "   Baixando Helm..."
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# 4. Check/Install Docker
if ! check_tool "Docker" "docker"; then
    if [ "$DISTRO" = "ubuntu" ] || [ "$DISTRO" = "debian" ]; then
        sudo apt-get update
        install_packages_multiple docker.io docker-compose
        sudo usermod -aG docker $USER
    elif [ "$DISTRO" = "fedora" ]; then
        install_packages_multiple docker docker-compose
        sudo usermod -aG docker $USER
    elif [ "$DISTRO" = "rhel" ] || [ "$DISTRO" = "centos" ]; then
        install_packages_multiple docker docker-compose
        sudo usermod -aG docker $USER
    else
        echo "❌ Por favor, instale Docker manualmente"
    fi
    echo "⚠️  Você precisa fazer logout/login para Docker funcionar sem sudo"
fi

# 5. Check/Install Git
if ! check_tool "Git" "git"; then
    install_package git
fi

# 6. Check/Install Make (para Fedora/RHEL)
if ! check_tool "Make" "make"; then
    if [ "$PM" = "dnf" ]; then
        install_package make
    elif [ "$PM" = "apt-get" ]; then
        install_package make
    else
        install_package make
    fi
fi

# 7. Check AWS CLI
if ! check_tool "AWS CLI" "aws"; then
    echo "   Baixando AWS CLI..."
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip awscliv2.zip
    sudo ./aws/install
    rm -rf aws awscliv2.zip
fi

echo ""
echo "=========================================="
echo "✅ PRÉ-REQUISITOS INSTALADOS"
echo "=========================================="
echo ""
echo "Próximos passos:"
echo "1. Configure credenciais AWS:"
echo "   aws configure"
echo ""
echo "2. Configure Terraform:"
echo "   cp terraform/terraform.tfvars.example terraform/terraform.tfvars"
echo ""
echo "3. Execute o deploy:"
echo "   make all"
echo ""
