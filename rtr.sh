#!/bin/bash

# Скрипт настройки роутеров HQ-RTR и BR-RTR
# Согласно заданию модуля №2

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Определение типа роутера
HOSTNAME=$(hostname)

# Функция для отображения заголовка
show_header() {
    clear
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${GREEN}    Настройка $HOSTNAME${NC}"
    echo -e "${BLUE}=====================================${NC}"
    echo ""
}

# Функция логирования
log() { echo -e "${GREEN}[INFO]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

# Проверка root
check_root() {
    if [ "$EUID" -ne 0 ]; then 
        error "Запустите скрипт с правами root!"
        exit 1
    fi
}

# Настройка Chrony сервера (только для HQ-RTR)
setup_chrony_server() {
    show_header
    echo -e "${YELLOW}=== Настройка Chrony сервера ===${NC}"
    echo ""
    
    if [[ "$HOSTNAME" != "HQ-RTR" ]]; then
        warning "Chrony сервер настраивается только на HQ-RTR"
        return
    fi
    
    # Установка chrony
    log "Установка chrony..."
    apt-get update
    apt-get install -y chrony
    
    # Резервная копия конфига
    cp /etc/chrony/chrony.conf /etc/chrony/chrony.conf.backup
    
    # Настройка сервера с стратум 5
    log "Настройка chrony сервера (stratum 5)..."
    cat > /etc/chrony/chrony.conf << EOF
# Chrony server configuration for HQ-RTR
# Stratum 5 time server

# Внешние источники времени
server 0.ru.pool.ntp.org iburst
server 1.ru.pool.ntp.org iburst
server 2.ru.pool.ntp.org iburst

# Локальный источник времени как stratum 5
local stratum 5

# Файл дрейфа
driftfile /var/lib/chrony/drift

# Разрешить клиентам из локальных сетей
allow 192.168.100.0/24
allow 192.168.200.0/24
allow 10.10.0.0/30

# Логирование
logdir /var/log/chrony
log tracking measurements statistics

# Разрешить большие корректировки времени при запуске
makestep 1.0 3

# Ключи для аутентификации
keyfile /etc/chrony/chrony.keys

# Bind на всех интерфейсах
bindaddress 0.0.0.0

# RTC
rtcsync
EOF
    
    # Перезапуск chrony
    systemctl restart chrony
    systemctl enable chrony
    
    log "Chrony сервер настроен"
    
    # Проверка статуса
    sleep 5
    echo -e "${CYAN}Статус Chrony сервера:${NC}"
    chronyc sources
    echo ""
    chronyc clients
}

# Настройка Chrony клиента (для BR-RTR)
setup_chrony_client() {
    show_header
    echo -e "${YELLOW}=== Настройка Chrony клиента ===${NC}"
    echo ""
    
    if [[ "$HOSTNAME" != "BR-RTR" ]]; then
        warning "На HQ-RTR уже настроен Chrony сервер"
        return
    fi
    
    # Установка chrony
    log "Установка chrony..."
    apt-get update
    apt-get install -y chrony
    
    # Резервная копия конфига
    cp /etc/chrony/chrony.conf /etc/chrony/chrony.conf.backup
    
    # Настройка клиента
    log "Настройка chrony клиента..."
    cat > /etc/chrony/chrony.conf << EOF
# Chrony client configuration for BR-RTR
# NTP сервер - HQ-RTR через GRE туннель
server 10.10.0.1 iburst prefer

# Файл дрейфа
driftfile /var/lib/chrony/drift

# Логирование
logdir /var/log/chrony
log tracking measurements statistics

# Разрешить большие корректировки времени при запуске
makestep 1.0 3

# Ключи для аутентификации
keyfile /etc/chrony/chrony.keys

# Отключить сервер NTP
port 0

# RTC
rtcsync
EOF
    
    # Перезапуск chrony
    systemctl restart chrony
    systemctl enable chrony
    
    log "Chrony клиент настроен"
    
    # Проверка синхронизации
    sleep 5
    echo -e "${CYAN}Статус синхронизации:${NC}"
    chronyc sources
}

# Настройка NAT для HQ-RTR
setup_nat_hq() {
    show_header
    echo -e "${YELLOW}=== Настройка NAT для HQ-RTR ===${NC}"
    echo ""
    
    if [[ "$HOSTNAME" != "HQ-RTR" ]]; then
        warning "Эта настройка только для HQ-RTR"
        return
    fi
    
    # Включение форвардинга
    log "Включение IP форвардинга..."
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p
    
    # Установка iptables-persistent
    log "Установка iptables-persistent..."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
    
    # Очистка старых правил NAT
    log "Очистка старых правил NAT..."
    iptables -t nat -F
    
    # Настройка MASQUERADE для выхода в интернет
    log "Настройка MASQUERADE..."
    iptables -t nat -A POSTROUTING -o ens18 -j MASQUERADE
    
    # Проброс портов согласно заданию
    log "Настройка проброса портов..."
    
    # Moodle: внешний порт 80 -> HQ-SRV:80
    iptables -t nat -A PREROUTING -i ens18 -p tcp --dport 80 -j DNAT --to-destination 192.168.100.2:80
    iptables -t nat -A POSTROUTING -d 192.168.100.2 -p tcp --dport 80 -j SNAT --to-source 192.168.100.1
    
    # Порт 2024 -> HQ-SRV:2024
    iptables -t nat -A PREROUTING -i ens18 -p tcp --dport 2024 -j DNAT --to-destination 192.168.100.2:2024
    iptables -t nat -A POSTROUTING -d 192.168.100.2 -p tcp --dport 2024 -j SNAT --to-source 192.168.100.1
    
    # Разрешение форвардинга
    iptables -A FORWARD -d 192.168.100.2 -p tcp --dport 80 -j ACCEPT
    iptables -A FORWARD -s 192.168.100.2 -p tcp --sport 80 -j ACCEPT
    iptables -A FORWARD -d 192.168.100.2 -p tcp --dport 2024 -j ACCEPT
    iptables -A FORWARD -s 192.168.100.2 -p tcp --sport 2024 -j ACCEPT
    
    # Сохранение правил
    log "Сохранение правил iptables..."
    iptables-save > /etc/iptables/rules.v4
    
    # Вывод текущих правил NAT
    echo -e "${CYAN}Текущие правила NAT:${NC}"
    iptables -t nat -L -n -v
    
    log "NAT настроен для HQ-RTR"
}

# Настройка NAT для BR-RTR
setup_nat_br() {
    show_header
    echo -e "${YELLOW}=== Настройка NAT для BR-RTR ===${NC}"
    echo ""
    
    if [[ "$HOSTNAME" != "BR-RTR" ]]; then
        warning "Эта настройка только для BR-RTR"
        return
    fi
    
    # Включение форвардинга
    log "Включение IP форвардинга..."
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p
    
    # Установка iptables-persistent
    log "Установка iptables-persistent..."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
    
    # Очистка старых правил NAT
    log "Очистка старых правил NAT..."
    iptables -t nat -F
    
    # Настройка MASQUERADE для выхода в интернет
    log "Настройка MASQUERADE..."
    iptables -t nat -A POSTROUTING -o ens18 -j MASQUERADE
    
    # Проброс портов согласно заданию
    log "Настройка проброса портов..."
    
    # Wiki: внешний порт 80 -> BR-SRV:8080
    iptables -t nat -A PREROUTING -i ens18 -p tcp --dport 80 -j DNAT --to-destination 192.168.200.2:8080
    iptables -t nat -A POSTROUTING -d 192.168.200.2 -p tcp --dport 8080 -j SNAT --to-source 192.168.200.1
    
    # Порт 2024 -> BR-SRV:2024
    iptables -t nat -A PREROUTING -i ens18 -p tcp --dport 2024 -j DNAT --to-destination 192.168.200.2:2024
    iptables -t nat -A POSTROUTING -d 192.168.200.2 -p tcp --dport 2024 -j SNAT --to-source 192.168.200.1
    
    # Разрешение форвардинга
    iptables -A FORWARD -d 192.168.200.2 -p tcp --dport 8080 -j ACCEPT
    iptables -A FORWARD -s 192.168.200.2 -p tcp --sport 8080 -j ACCEPT
    iptables -A FORWARD -d 192.168.200.2 -p tcp --dport 2024 -j ACCEPT
    iptables -A FORWARD -s 192.168.200.2 -p tcp --sport 2024 -j ACCEPT
    
    # Сохранение правил
    log "Сохранение правил iptables..."
    iptables-save > /etc/iptables/rules.v4
    
    # Вывод текущих правил NAT
    echo -e "${CYAN}Текущие правила NAT:${NC}"
    iptables -t nat -L -n -v
    
    log "NAT настроен для BR-RTR"
}

# Проверка GRE туннеля
check_gre_tunnel() {
    show_header
    echo -e "${YELLOW}=== Проверка GRE туннеля ===${NC}"
    echo ""
    
    # Проверка интерфейса gre1
    if ip link show gre1 &> /dev/null; then
        log "GRE туннель найден"
        echo -e "${CYAN}Информация о туннеле:${NC}"
        ip addr show gre1
        echo ""
        
        # Пинг другого конца туннеля
        if [[ "$HOSTNAME" == "HQ-RTR" ]]; then
            echo "Проверка связи с BR-RTR (10.10.0.2)..."
            ping -c 3 10.10.0.2
        else
            echo "Проверка связи с HQ-RTR (10.10.0.1)..."
            ping -c 3 10.10.0.1
        fi
    else
        error "GRE туннель не настроен"
        echo "Настройте GRE туннель перед продолжением"
    fi
}

# Информация о системе
show_system_info() {
    show_header
    echo -e "${YELLOW}=== Информация о системе ===${NC}"
    echo ""
    
    echo -e "${CYAN}Hostname:${NC} $HOSTNAME"
    echo ""
    
    echo -e "${CYAN}IP адреса:${NC}"
    ip -4 addr show | grep inet | grep -v "127.0.0.1"
    
    echo ""
    echo -e "${CYAN}Маршруты:${NC}"
    ip route
    
    echo ""
    echo -e "${CYAN}NAT правила:${NC}"
    iptables -t nat -L PREROUTING -n -v | grep -E "dpt:(80|2024)"
    
    if command -v chronyc &> /dev/null; then
        echo ""
        echo -e "${CYAN}Chrony статус:${NC}"
        if [[ "$HOSTNAME" == "HQ-RTR" ]]; then
            chronyc clients | head -5
        else
            chronyc sources
        fi
    fi
}

# Главное меню
main_menu() {
    while true; do
        show_header
        echo "Выберите действие:"
        echo ""
        
        if [[ "$HOSTNAME" == "HQ-RTR" ]]; then
            echo "1) Настроить Chrony сервер (stratum 5)"
            echo "2) Настроить NAT и проброс портов"
        else
            echo "1) Настроить Chrony клиент"
            echo "2) Настроить NAT и проброс портов"
        fi
        
        echo "3) Проверить GRE туннель"
        echo "4) Показать информацию о системе"
        echo "5) Выполнить полную настройку"
        echo "6) Выход"
        echo ""
        
        read -p "Ваш выбор (1-6): " choice
        
        case $choice in
            1) 
                if [[ "$HOSTNAME" == "HQ-RTR" ]]; then
                    setup_chrony_server
                else
                    setup_chrony_client
                fi
                ;;
            2) 
                if [[ "$HOSTNAME" == "HQ-RTR" ]]; then
                    setup_nat_hq
                else
                    setup_nat_br
                fi
                ;;
            3) check_gre_tunnel ;;
            4) show_system_info ;;
            5) 
                if [[ "$HOSTNAME" == "HQ-RTR" ]]; then
                    setup_chrony_server
                    setup_nat_hq
                else
                    setup_chrony_client
                    setup_nat_br
                fi
                check_gre_tunnel
                echo ""
                log "Полная настройка завершена!"
                ;;
            6) 
                echo -e "${GREEN}До свидания!${NC}"
                exit 0
                ;;
            *)
                error "Неверный выбор!"
                sleep 1
                ;;
        esac
        
        echo ""
        read -p "Нажмите Enter для продолжения..."
    done
}

# Проверка и запуск
check_root
main_menu