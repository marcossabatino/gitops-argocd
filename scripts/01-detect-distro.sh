#!/bin/bash

# Detect Linux distribution and provide package manager functions

detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    elif type lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si)
        VER=$(lsb_release -sr)
    elif [ -f /etc/lsb-release ]; then
        . /etc/lsb-release
        OS=$(echo $DISTRIB_ID | tr '[:upper:]' '[:lower:]')
        VER=$DISTRIB_RELEASE
    else
        OS=$(uname -s)
        VER=$(uname -r)
    fi

    echo $OS
}

get_package_manager() {
    local distro=$1

    case $distro in
        ubuntu|debian)
            echo "apt-get"
            ;;
        fedora)
            echo "dnf"
            ;;
        rhel|centos|rocky|almalinux)
            echo "dnf"
            ;;
        opensuse*)
            echo "zypper"
            ;;
        arch|manjaro)
            echo "pacman"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

install_package() {
    local package=$1
    local distro=$(detect_distro)
    local pm=$(get_package_manager $distro)

    case $pm in
        apt-get)
            sudo apt-get update -qq
            sudo apt-get install -y $package
            ;;
        dnf)
            sudo dnf install -y $package
            ;;
        yum)
            sudo yum install -y $package
            ;;
        zypper)
            sudo zypper install -y $package
            ;;
        pacman)
            sudo pacman -S --noconfirm $package
            ;;
        *)
            echo "❌ Distribuição Linux não suportada: $distro"
            echo "Por favor, instale '$package' manualmente"
            exit 1
            ;;
    esac
}

install_packages_multiple() {
    local distro=$(detect_distro)
    local pm=$(get_package_manager $distro)

    case $pm in
        apt-get)
            sudo apt-get update -qq
            sudo apt-get install -y "$@"
            ;;
        dnf)
            sudo dnf install -y "$@"
            ;;
        yum)
            sudo yum install -y "$@"
            ;;
        zypper)
            sudo zypper install -y "$@"
            ;;
        pacman)
            sudo pacman -S --noconfirm "$@"
            ;;
        *)
            echo "❌ Distribuição Linux não suportada: $distro"
            exit 1
            ;;
    esac
}

# Export functions if sourced
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    export -f detect_distro
    export -f get_package_manager
    export -f install_package
    export -f install_packages_multiple
fi
