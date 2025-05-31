#!/bin/bash

# Скрипт установки DHCP сервера для Debian 10
# Используется dnsmasq в качестве DHCP сервера

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # Без цвета

# Функция для цветного вывода
print_color() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Функция проверки прав root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_color $RED "Этот скрипт должен быть запущен с правами root!"
        exit 1
    fi
}

# Функция валидации IP адреса
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        OIFS=$IFS
        IFS='.'
        ip=($ip)
        IFS=$OIFS
        [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
        return $?
    else
        return 1
    fi
}

# Функция валидации MAC адреса
validate_mac() {
    local mac=$1
    if [[ $mac =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Функция проверки конфликтов IP
check_ip_conflict() {
    local ip=$1
    if ping -c 1 -W 1 $ip &>/dev/null; then
        return 0  # IP используется
    else
        return 1  # IP свободен
    fi
}

# Функция получения сетевых интерфейсов
get_interfaces() {
    local interfaces=()
    for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep -v lo); do
        interfaces+=("$iface")
    done
    echo "${interfaces[@]}"
}

# Функция выбора интерфейсов
select_interfaces() {
    local interfaces=($(get_interfaces))
    local selected=()
    
    print_color $GREEN "\nДоступные сетевые интерфейсы:"
    for i in "${!interfaces[@]}"; do
        echo "$((i+1)). ${interfaces[$i]}"
    done
    
    while true; do
        read -p "Выберите номер интерфейса (или 'готово' для завершения): " choice
        if [[ $choice == "готово" ]] || [[ $choice == "done" ]]; then
            break
        elif [[ $choice =~ ^[0-9]+$ ]] && [ $choice -ge 1 ] && [ $choice -le ${#interfaces[@]} ]; then
            selected+=("${interfaces[$((choice-1))]}")
            print_color $GREEN "Добавлен: ${interfaces[$((choice-1))]}"
        else
            print_color $RED "Неверный выбор!"
        fi
    done
    
    echo "${selected[@]}"
}

# Основной скрипт начинается здесь
clear
print_color $GREEN "=== Скрипт установки DHCP сервера для Debian 10 ==="
print_color $GREEN "=== Используется dnsmasq ==="
echo

# Проверка прав root
check_root

# Спросить об обновлении системы
print_color $YELLOW "Хотите обновить систему перед установкой?"
print_color $YELLOW "Внимание: полное обновление может занять много времени!"
read -p "Обновить систему? (да/нет): " update_system
update_system=$(echo $update_system | tr '[:upper:]' '[:lower:]')

if [[ $update_system == "да" ]] || [[ $update_system == "yes" ]]; then
    print_color $YELLOW "Обновление системы..."
    apt-get update -y
    apt-get upgrade -y
    print_color $GREEN "Система обновлена!"
else
    print_color $YELLOW "Обновление списка пакетов..."
    apt-get update -y
fi

print_color $YELLOW "Установка dnsmasq..."
apt-get install -y dnsmasq

# Временно остановить службу dnsmasq
systemctl stop dnsmasq

# Резервное копирование оригинальной конфигурации
if [ -f /etc/dnsmasq.conf ]; then
    cp /etc/dnsmasq.conf /etc/dnsmasq.conf.backup.$(date +%Y%m%d_%H%M%S)
    print_color $GREEN "Оригинальная конфигурация сохранена"
fi

# Начало настройки
print_color $GREEN "\n=== Настройка DHCP ==="

# Вопрос об использовании VLAN
read -p "Используете ли вы VLAN интерфейсы? (да/нет): " use_vlan
use_vlan=$(echo $use_vlan | tr '[:upper:]' '[:lower:]')

# Выбор интерфейсов
if [[ $use_vlan == "да" ]] || [[ $use_vlan == "yes" ]]; then
    print_color $YELLOW "\nОбнаруженные VLAN интерфейсы:"
    vlan_interfaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^vlan[0-9]+' || true)
    if [[ -z $vlan_interfaces ]]; then
        print_color $RED "VLAN интерфейсы не найдены!"
    else
        echo "$vlan_interfaces"
    fi
fi

print_color $YELLOW "\nВыберите интерфейсы для DHCP сервиса:"
selected_interfaces=($(select_interfaces))

if [ ${#selected_interfaces[@]} -eq 0 ]; then
    print_color $RED "Интерфейсы не выбраны! Выход."
    exit 1
fi

# Создание новой конфигурации
cat > /etc/dnsmasq.conf << EOF
# Конфигурация Dnsmasq для DHCP сервера
# Создано скриптом dhcp.sh $(date)

# Отключить функцию DNS
port=0

# Включить логирование DHCP
log-dhcp

# Авторитетный режим DHCP
dhcp-authoritative

EOF

# Настройка каждого интерфейса
for iface in "${selected_interfaces[@]}"; do
    print_color $GREEN "\n=== Настройка интерфейса: $iface ==="
    
    # Получить текущий IP интерфейса, если есть
    current_ip=$(ip -4 addr show $iface | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || true)
    if [[ -n $current_ip ]]; then
        print_color $YELLOW "Текущий IP на $iface: $current_ip"
    fi
    
    # Запрос диапазона DHCP
    while true; do
        read -p "Введите начальный IP диапазона DHCP для $iface: " range_start
        if validate_ip $range_start; then
            if check_ip_conflict $range_start; then
                print_color $YELLOW "Внимание: IP $range_start уже используется!"
                read -p "Продолжить всё равно? (да/нет): " cont
                if [[ $cont == "да" ]] || [[ $cont == "yes" ]]; then
                    break
                fi
            else
                break
            fi
        else
            print_color $RED "Неверный IP адрес!"
        fi
    done
    
    while true; do
        read -p "Введите конечный IP диапазона DHCP для $iface: " range_end
        if validate_ip $range_end; then
            if check_ip_conflict $range_end; then
                print_color $YELLOW "Внимание: IP $range_end уже используется!"
                read -p "Продолжить всё равно? (да/нет): " cont
                if [[ $cont == "да" ]] || [[ $cont == "yes" ]]; then
                    break
                fi
            else
                break
            fi
        else
            print_color $RED "Неверный IP адрес!"
        fi
    done
    
    # Запрос шлюза
    while true; do
        read -p "Введите IP адрес шлюза для $iface: " gateway
        if validate_ip $gateway; then
            break
        else
            print_color $RED "Неверный IP адрес!"
        fi
    done
    
    # Запрос DNS серверов
    dns_servers=""
    while true; do
        read -p "Введите IP адрес DNS сервера (или 'готово' для завершения): " dns
        if [[ $dns == "готово" ]] || [[ $dns == "done" ]]; then
            break
        elif validate_ip $dns; then
            if [[ -z $dns_servers ]]; then
                dns_servers=$dns
            else
                dns_servers="$dns_servers,$dns"
            fi
            print_color $GREEN "Добавлен DNS: $dns"
        else
            print_color $RED "Неверный IP адрес!"
        fi
    done
    
    # Запрос доменного имени
    read -p "Введите доменное имя (необязательно, нажмите Enter для пропуска): " domain_name
    
    # Запись конфигурации интерфейса
    echo "" >> /etc/dnsmasq.conf
    echo "# Конфигурация для интерфейса $iface" >> /etc/dnsmasq.conf
    echo "interface=$iface" >> /etc/dnsmasq.conf
    echo "dhcp-range=$iface,$range_start,$range_end,12h" >> /etc/dnsmasq.conf
    
    if [[ -n $gateway ]]; then
        echo "dhcp-option=$iface,3,$gateway" >> /etc/dnsmasq.conf
    fi
    
    if [[ -n $dns_servers ]]; then
        echo "dhcp-option=$iface,6,$dns_servers" >> /etc/dnsmasq.conf
    fi
    
    if [[ -n $domain_name ]]; then
        echo "dhcp-option=$iface,15,$domain_name" >> /etc/dnsmasq.conf
    fi
done

# Запрос статических резерваций IP
print_color $GREEN "\n=== Статические резервирования IP ==="
read -p "Хотите добавить статические резервирования IP? (да/нет): " add_static
add_static=$(echo $add_static | tr '[:upper:]' '[:lower:]')

if [[ $add_static == "да" ]] || [[ $add_static == "yes" ]]; then
    echo "" >> /etc/dnsmasq.conf
    echo "# Статические резервирования IP" >> /etc/dnsmasq.conf
    
    while true; do
        read -p "\nДобавить статическое резервирование? (да/нет): " add_more
        add_more=$(echo $add_more | tr '[:upper:]' '[:lower:]')
        
        if [[ $add_more != "да" ]] && [[ $add_more != "yes" ]]; then
            break
        fi
        
        # Получение MAC адреса
        while true; do
            read -p "Введите MAC адрес (формат: AA:BB:CC:DD:EE:FF): " mac_addr
            if validate_mac $mac_addr; then
                break
            else
                print_color $RED "Неверный формат MAC адреса!"
            fi
        done
        
        # Получение IP адреса
        while true; do
            read -p "Введите IP адрес для этого устройства: " static_ip
            if validate_ip $static_ip; then
                if check_ip_conflict $static_ip; then
                    print_color $YELLOW "Внимание: IP $static_ip уже используется!"
                    read -p "Продолжить всё равно? (да/нет): " cont
                    if [[ $cont == "да" ]] || [[ $cont == "yes" ]]; then
                        break
                    fi
                else
                    break
                fi
            else
                print_color $RED "Неверный IP адрес!"
            fi
        done
        
        # Получение имени хоста (необязательно)
        read -p "Введите имя хоста для этого устройства (необязательно): " hostname
        
        # Запись статического резервирования
        if [[ -n $hostname ]]; then
            echo "dhcp-host=$mac_addr,$hostname,$static_ip" >> /etc/dnsmasq.conf
        else
            echo "dhcp-host=$mac_addr,$static_ip" >> /etc/dnsmasq.conf
        fi
        
        print_color $GREEN "Статическое резервирование добавлено!"
    done
fi

# Настройка firewall
print_color $YELLOW "\n=== Настройка правил firewall ==="
# Проверка установки iptables
if ! command -v iptables &> /dev/null; then
    apt-get install -y iptables
fi

# Добавление правил firewall для DHCP
iptables -A INPUT -p udp --dport 67:68 -j ACCEPT
iptables -A OUTPUT -p udp --sport 67:68 -j ACCEPT

# Сохранение правил iptables
if command -v netfilter-persistent &> /dev/null; then
    netfilter-persistent save
else
    # Установка iptables-persistent
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
    netfilter-persistent save
fi

print_color $GREEN "Правила firewall для DHCP добавлены"

# Включение и запуск dnsmasq
print_color $YELLOW "\n=== Запуск DHCP сервиса ==="
systemctl enable dnsmasq
systemctl start dnsmasq

# Проверка статуса службы
if systemctl is-active --quiet dnsmasq; then
    print_color $GREEN "DHCP сервер успешно запущен!"
else
    print_color $RED "Не удалось запустить DHCP сервер!"
    print_color $YELLOW "Проверьте логи командой: journalctl -xe"
    exit 1
fi

# Показать итоговую информацию
print_color $GREEN "\n=== Итоговая информация ==="
echo "Файл конфигурации: /etc/dnsmasq.conf"
echo "Статус службы: $(systemctl is-active dnsmasq)"
echo "Настроенные интерфейсы: ${selected_interfaces[@]}"
echo ""
print_color $GREEN "Установка DHCP сервера завершена успешно!"
print_color $YELLOW "\nПолезные команды:"
echo "- Просмотр выданных IP адресов: cat /var/lib/misc/dnsmasq.leases"
echo "- Перезапуск службы: systemctl restart dnsmasq"
echo "- Просмотр логов: journalctl -u dnsmasq -f"
echo "- Редактирование конфигурации: nano /etc/dnsmasq.conf"
