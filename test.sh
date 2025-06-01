#!/bin/bash

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
   echo "Ошибка: Скрипт должен запускаться с правами root"
   exit 1
fi

# Определение пакетного менеджера
function detect_package_manager() {
    if command -v apt &> /dev/null; then
        echo "apt"
    elif command -v yum &> /dev/null; then
        echo "yum"
    elif command -v dnf &> /dev/null; then
        echo "dnf"
    else
        echo "Не найден поддерживаемый пакетный менеджер"
        exit 1
    fi
}

# Установка необходимых пакетов
function install_packages() {
    PM=$(detect_package_manager)
    echo "Установка необходимых пакетов..."
    
    case $PM in
        "apt")
            apt update && apt install -y iptables-persistent dnsutils curl
            ;;
        "yum"|"dnf")
            $PM install -y iptables-services bind-utils curl
            systemctl enable iptables
            ;;
    esac
}

# Настройка сети
function configure_network() {
    echo "Настройка сетевых параметров..."
    
    # Определение основного интерфейса
    ETH_INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5}' | head -n1)
    
    # Настройка IP и DNS через systemd-networkd
    cat > /etc/systemd/network/00-$ETH_INTERFACE.network << EOF
[Match]
Name=$ETH_INTERFACE

[Network]
Address=192.168.1.1/24
DNS=8.8.8.8
EOF
    
    systemctl restart systemd-networkd
}

# Настройка NAT и форвардинга
function configure_nat() {
    echo "Настройка NAT и форвардинга..."
    
    # Включение IP Forwarding
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ipforward.conf
    sysctl -p /etc/sysctl.d/99-ipforward.conf

    # Настройка iptables
    ETH_INTERFACE=$(ip route get 8.8.8.8 | awk '{print $5}' | head -n1)
    iptables -t nat -A POSTROUTING -o $ETH_INTERFACE -j MASQUERADE
    iptables -A FORWARD -i $ETH_INTERFACE -o lo -j ACCEPT
    iptables-save > /etc/iptables/rules.v4
}

# Изменение хостнейма
function set_hostname() {
    echo "Изменение имени хоста..."
    hostnamectl set-hostname isp.au-team.irpo
    exec bash
}

# Проверка интернета
function check_internet() {
    echo "Проверка подключения:"
    
    check_ping() {
        ping -c 4 $1 &> /dev/null
        echo -n "$1: "
        [[ $? -eq 0 ]] && echo "✓" || echo "✗"
    }

    check_https() {
        curl -Is https://example.com  | head -n 1 | grep "200 OK" &> /dev/null
        echo -n "HTTPS: "
        [[ $? -eq 0 ]] && echo "✓" || echo "✗"
    }

    check_ping "8.8.8.8"
    check_ping "8.8.4.4"
    check_https
}

# Основное меню
function main_menu() {
    while true; do
        clear
        echo "================ ISP на изи ================"
        echo "1. LET'S GOO"
        echo "2. Выход"
        read -p "Выберите действие (1-2): " choice

        case $choice in
            1)
                install_packages
                configure_network
                configure_nat
                set_hostname
                check_internet
                echo "Настройка завершена!"
                sleep 5
                ;;
            2)
                echo "Выход..."
                exit 0
                ;;
            *)
                echo "Неверный выбор!"
                sleep 2
                ;;
        esac
    done
}

main_menu
