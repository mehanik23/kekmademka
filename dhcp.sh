#!/bin/bash

# Скрипт установки DHCP сервера для Debian 10
# Используется ISC DHCP Server

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
    interfaces=()
    # Получаем все интерфейсы, включая обычные и VLAN
    for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep -v lo); do
        interfaces+=("$iface")
    done
    echo "${interfaces[@]}"
}

# Функция получения VLAN интерфейсов
get_vlan_interfaces() {
    vlans=()
    # Ищем VLAN интерфейсы (формат vlanXXX)
    for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep -E '^vlan[0-9]+'); do
        vlans+=("$iface")
    done
    echo "${vlans[@]}"
}

# Функция вычисления сетевой маски из CIDR
cidr_to_netmask() {
    cidr=$1
    value=$(( 0xffffffff ^ ((1 << (32 - $cidr)) - 1) ))
    echo "$(( (value >> 24) & 0xff )).$(( (value >> 16) & 0xff )).$(( (value >> 8) & 0xff )).$(( value & 0xff ))"
}

# Функция вычисления сети из IP и CIDR
get_network() {
    ip=$1
    cidr=$2
    IFS='.'
    read -r i1 i2 i3 i4 <<< "$ip"
    mask=$(( 0xffffffff ^ ((1 << (32 - $cidr)) - 1) ))
    m1=$(( (mask >> 24) & 0xff ))
    m2=$(( (mask >> 16) & 0xff ))
    m3=$(( (mask >> 8) & 0xff ))
    m4=$(( mask & 0xff ))
    
    echo "$((i1 & m1)).$((i2 & m2)).$((i3 & m3)).$((i4 & m4))"
}

# Функция выбора интерфейсов
select_interfaces() {
    interfaces=($(get_interfaces))
    selected=()
    ip=""
    
    print_color $GREEN "\nДоступные сетевые интерфейсы:"
    for i in "${!interfaces[@]}"; do
        ip=$(ip -4 addr show ${interfaces[$i]} | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || echo "нет IP")
        echo "$((i+1)). ${interfaces[$i]} (IP: $ip)"
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
print_color $GREEN "=== Используется ISC DHCP Server ==="
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

print_color $YELLOW "Установка ISC DHCP Server..."
apt-get install -y isc-dhcp-server

# Временно остановить службу
systemctl stop isc-dhcp-server

# Резервное копирование оригинальной конфигурации
if [ -f /etc/dhcp/dhcpd.conf ]; then
    cp /etc/dhcp/dhcpd.conf /etc/dhcp/dhcpd.conf.backup.$(date +%Y%m%d_%H%M%S)
    print_color $GREEN "Оригинальная конфигурация сохранена"
fi

# Начало настройки
print_color $GREEN "\n=== Настройка DHCP ==="

# Выбор интерфейса с интернетом
print_color $YELLOW "\nСначала выберите интерфейс с доступом в интернет (для указания маршрута по умолчанию):"
interfaces_array=($(get_interfaces))
for i in "${!interfaces_array[@]}"; do
    ip=$(ip -4 addr show ${interfaces_array[$i]} | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || echo "нет IP")
    echo "$((i+1)). ${interfaces_array[$i]} (IP: $ip)"
done

while true; do
    read -p "Выберите интерфейс с интернетом (1-${#interfaces_array[@]}): " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ $choice -ge 1 ] && [ $choice -le ${#interfaces_array[@]} ]; then
        internet_interface=${interfaces_array[$((choice-1))]}
        # Получаем шлюз для этого интерфейса
        default_gateway=$(ip route | grep "default via" | grep "$internet_interface" | awk '{print $3}' | head -1)
        if [[ -z $default_gateway ]]; then
            print_color $YELLOW "Не найден шлюз по умолчанию для $internet_interface"
            read -p "Введите шлюз по умолчанию вручную: " default_gateway
            while ! validate_ip "$default_gateway"; do
                print_color $RED "Неверный формат IP!"
                read -p "Введите шлюз по умолчанию: " default_gateway
            done
        fi
        print_color $GREEN "Выбран интерфейс с интернетом: $internet_interface (шлюз: $default_gateway)"
        break
    else
        print_color $RED "Неверный выбор!"
    fi
done

# Проверка наличия VLAN интерфейсов
vlan_interfaces=($(get_vlan_interfaces))
if [ ${#vlan_interfaces[@]} -gt 0 ]; then
    print_color $YELLOW "\nОбнаружены VLAN интерфейсы:"
    for vlan in "${vlan_interfaces[@]}"; do
        ip=$(ip -4 addr show $vlan | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || echo "нет IP")
        echo "  - $vlan (IP: $ip)"
    done
    
    read -p "Хотите настроить DHCP на VLAN интерфейсах? (да/нет): " use_vlan
    use_vlan=$(echo $use_vlan | tr '[:upper:]' '[:lower:]')
    
    if [[ $use_vlan == "да" ]] || [[ $use_vlan == "yes" ]]; then
        print_color $YELLOW "\nВыберите VLAN интерфейсы для настройки DHCP:"
        selected_interfaces=()
        
        # Показываем VLAN интерфейсы для выбора
        for i in "${!vlan_interfaces[@]}"; do
            ip=$(ip -4 addr show ${vlan_interfaces[$i]} | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || echo "нет IP")
            echo "$((i+1)). ${vlan_interfaces[$i]} (IP: $ip)"
        done
        
        while true; do
            read -p "Выберите номер VLAN интерфейса (или 'готово' для завершения): " choice
            if [[ $choice == "готово" ]] || [[ $choice == "done" ]]; then
                break
            elif [[ $choice =~ ^[0-9]+$ ]] && [ $choice -ge 1 ] && [ $choice -le ${#vlan_interfaces[@]} ]; then
                selected_interfaces+=("${vlan_interfaces[$((choice-1))]}")
                print_color $GREEN "Добавлен: ${vlan_interfaces[$((choice-1))]}"
            else
                print_color $RED "Неверный выбор!"
            fi
        done
        
        # Если выбрали VLAN интерфейсы, спросить про дополнительные обычные интерфейсы
        if [ ${#selected_interfaces[@]} -gt 0 ]; then
            read -p "Хотите добавить обычные (не VLAN) интерфейсы? (да/нет): " add_regular
            if [[ $add_regular == "да" ]] || [[ $add_regular == "yes" ]]; then
                print_color $YELLOW "\nВыберите дополнительные интерфейсы:"
                # Получаем обычные интерфейсы (исключая уже выбранные VLAN)
                all_interfaces=($(get_interfaces))
                available_interfaces=()
                
                # Фильтруем доступные интерфейсы
                for iface in "${all_interfaces[@]}"; do
                    if [[ ! ${iface} =~ ^vlan[0-9]+ ]] && [[ ! " ${selected_interfaces[@]} " =~ " ${iface} " ]]; then
                        available_interfaces+=("$iface")
                    fi
                done
                
                # Показываем только доступные интерфейсы
                for i in "${!available_interfaces[@]}"; do
                    ip=$(ip -4 addr show ${available_interfaces[$i]} | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || echo "нет IP")
                    echo "$((i+1)). ${available_interfaces[$i]} (IP: $ip)"
                done
                
                while true; do
                    read -p "Выберите номер интерфейса (или 'готово' для завершения): " choice
                    if [[ $choice == "готово" ]] || [[ $choice == "done" ]]; then
                        break
                    elif [[ $choice =~ ^[0-9]+$ ]] && [ $choice -ge 1 ] && [ $choice -le ${#available_interfaces[@]} ]; then
                        selected_interfaces+=("${available_interfaces[$((choice-1))]}")
                        print_color $GREEN "Добавлен: ${available_interfaces[$((choice-1))]}"
                    else
                        print_color $RED "Неверный выбор!"
                    fi
                done
            fi
        fi
        
        # Если не выбрали ни одного интерфейса
        if [ ${#selected_interfaces[@]} -eq 0 ]; then
            print_color $YELLOW "Вы не выбрали ни одного интерфейса."
            print_color $YELLOW "\nВыберите интерфейсы для DHCP сервиса из всех доступных:"
            selected_interfaces=($(select_interfaces))
        fi
    else
        print_color $YELLOW "\nВыберите интерфейсы для DHCP сервиса:"
        selected_interfaces=($(select_interfaces))
    fi
else
    print_color $YELLOW "\nВыберите интерфейсы для DHCP сервиса:"
    selected_interfaces=($(select_interfaces))
fi

# Показать выбранные интерфейсы
if [ ${#selected_interfaces[@]} -gt 0 ]; then
    print_color $GREEN "\nВыбранные интерфейсы для DHCP:"
    for iface in "${selected_interfaces[@]}"; do
        echo "  - $iface"
    done
fi

if [ ${#selected_interfaces[@]} -eq 0 ]; then
    print_color $RED "Интерфейсы не выбраны! Выход."
    exit 1
fi

# Создание новой конфигурации
cat > /etc/dhcp/dhcpd.conf << EOF
# Конфигурация ISC DHCP Server
# Создано скриптом dhcp.sh $(date)

# Глобальные параметры
authoritative;
log-facility local7;

# Время аренды по умолчанию
default-lease-time 43200;  # 12 часов
max-lease-time 86400;      # 24 часа

# Глобальные DNS серверы (могут быть переопределены для каждой подсети)
option domain-name-servers 8.8.8.8, 8.8.4.4;

EOF

# Настройка каждого интерфейса
declare -A interface_configs
for iface in "${selected_interfaces[@]}"; do
    print_color $GREEN "\n=== Настройка интерфейса: $iface ==="
    
    # Получить текущий IP интерфейса, если есть
    current_ip=$(ip -4 addr show $iface | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -1 || true)
    if [[ -n $current_ip ]]; then
        print_color $YELLOW "Текущая настройка на $iface: $current_ip"
        ip_only=$(echo $current_ip | cut -d'/' -f1)
        cidr=$(echo $current_ip | cut -d'/' -f2)
        
        read -p "Использовать текущие настройки для DHCP? (да/нет): " use_current
        if [[ $use_current == "да" ]] || [[ $use_current == "yes" ]]; then
            # Вычисляем сеть из текущих настроек
            network=$(get_network $ip_only $cidr)
            netmask=$(cidr_to_netmask $cidr)
            gateway=$ip_only
            
            # Предлагаем диапазон по умолчанию
            IFS='.' read -r n1 n2 n3 n4 <<< "$ip_only"
            suggested_start="$n1.$n2.$n3.100"
            suggested_end="$n1.$n2.$n3.200"
            
            print_color $YELLOW "Предлагаемый диапазон: $suggested_start - $suggested_end"
            read -p "Использовать предложенный диапазон? (да/нет): " use_suggested
            
            if [[ $use_suggested == "да" ]] || [[ $use_suggested == "yes" ]]; then
                range_start=$suggested_start
                range_end=$suggested_end
            else
                # Запрос диапазона вручную
                while true; do
                    read -p "Введите начальный IP диапазона DHCP: " range_start
                    if validate_ip $range_start; then
                        break
                    else
                        print_color $RED "Неверный IP адрес!"
                    fi
                done
                
                while true; do
                    read -p "Введите конечный IP диапазона DHCP: " range_end
                    if validate_ip $range_end; then
                        break
                    else
                        print_color $RED "Неверный IP адрес!"
                    fi
                done
            fi
        else
            # Ручной ввод всех параметров
            while true; do
                read -p "Введите сеть (например, 192.168.100.0): " network
                if validate_ip $network; then
                    break
                else
                    print_color $RED "Неверный IP адрес!"
                fi
            done
            
            while true; do
                read -p "Введите маску сети (например, 255.255.255.0): " netmask
                if validate_ip $netmask; then
                    break
                else
                    print_color $RED "Неверный формат маски!"
                fi
            done
            
            while true; do
                read -p "Введите шлюз для этой подсети: " gateway
                if validate_ip $gateway; then
                    break
                else
                    print_color $RED "Неверный IP адрес!"
                fi
            done
            
            while true; do
                read -p "Введите начальный IP диапазона DHCP: " range_start
                if validate_ip $range_start; then
                    break
                else
                    print_color $RED "Неверный IP адрес!"
                fi
            done
            
            while true; do
                read -p "Введите конечный IP диапазона DHCP: " range_end
                if validate_ip $range_end; then
                    break
                else
                    print_color $RED "Неверный IP адрес!"
                fi
            done
        fi
    else
        # Интерфейс без IP - полный ручной ввод
        print_color $YELLOW "Интерфейс $iface не имеет IP адреса. Необходима ручная настройка."
        
        while true; do
            read -p "Введите сеть (например, 192.168.100.0): " network
            if validate_ip $network; then
                break
            else
                print_color $RED "Неверный IP адрес!"
            fi
        done
        
        while true; do
            read -p "Введите маску сети (например, 255.255.255.0): " netmask
            if validate_ip $netmask; then
                break
            else
                print_color $RED "Неверный формат маски!"
            fi
        done
        
        while true; do
            read -p "Введите шлюз для этой подсети: " gateway
            if validate_ip $gateway; then
                break
            else
                print_color $RED "Неверный IP адрес!"
            fi
        done
        
        while true; do
            read -p "Введите начальный IP диапазона DHCP: " range_start
            if validate_ip $range_start; then
                break
            else
                print_color $RED "Неверный IP адрес!"
            fi
        done
        
        while true; do
            read -p "Введите конечный IP диапазона DHCP: " range_end
            if validate_ip $range_end; then
                break
            else
                print_color $RED "Неверный IP адрес!"
            fi
        done
    fi
    
    # Проверка конфликтов
    if check_ip_conflict $range_start; then
        print_color $YELLOW "Внимание: IP $range_start уже используется!"
    fi
    if check_ip_conflict $range_end; then
        print_color $YELLOW "Внимание: IP $range_end уже используется!"
    fi
    
    # Запрос DNS серверов
    dns_servers=""
    print_color $YELLOW "Настройка DNS серверов для подсети $network"
    read -p "Использовать DNS серверы по умолчанию (8.8.8.8, 8.8.4.4)? (да/нет): " use_default_dns
    
    if [[ $use_default_dns != "да" ]] && [[ $use_default_dns != "yes" ]]; then
        while true; do
            read -p "Введите DNS сервер (или 'готово' для завершения): " dns
            if [[ $dns == "готово" ]] || [[ $dns == "done" ]]; then
                break
            elif validate_ip $dns; then
                if [[ -z $dns_servers ]]; then
                    dns_servers=$dns
                else
                    dns_servers="$dns_servers, $dns"
                fi
                print_color $GREEN "Добавлен DNS: $dns"
            else
                print_color $RED "Неверный IP адрес!"
            fi
        done
    fi
    
    # Запрос доменного имени
    read -p "Введите доменное имя (необязательно, нажмите Enter для пропуска): " domain_name
    
    # Запись конфигурации подсети
    echo "" >> /etc/dhcp/dhcpd.conf
    echo "# Конфигурация для интерфейса $iface" >> /etc/dhcp/dhcpd.conf
    echo "subnet $network netmask $netmask {" >> /etc/dhcp/dhcpd.conf
    echo "    range $range_start $range_end;" >> /etc/dhcp/dhcpd.conf
    echo "    option routers $gateway;" >> /etc/dhcp/dhcpd.conf
    
    # Если это не интерфейс с интернетом и указан глобальный шлюз
    if [[ $iface != $internet_interface ]] && [[ -n $default_gateway ]]; then
        echo "    # Маршрут по умолчанию через интерфейс с интернетом" >> /etc/dhcp/dhcpd.conf
        echo "    option routers $gateway, $default_gateway;" >> /etc/dhcp/dhcpd.conf
    fi
    
    if [[ -n $dns_servers ]]; then
        echo "    option domain-name-servers $dns_servers;" >> /etc/dhcp/dhcpd.conf
    fi
    
    if [[ -n $domain_name ]]; then
        echo "    option domain-name \"$domain_name\";" >> /etc/dhcp/dhcpd.conf
    fi
    
    echo "}" >> /etc/dhcp/dhcpd.conf
    
    # Сохраняем интерфейс для конфигурации сервиса
    interface_configs[$iface]=1
done

# Запрос статических резерваций IP
print_color $GREEN "\n=== Статические резервирования IP ==="
read -p "Хотите добавить статические резервирования IP? (да/нет): " add_static
add_static=$(echo $add_static | tr '[:upper:]' '[:lower:]')

if [[ $add_static == "да" ]] || [[ $add_static == "yes" ]]; then
    echo "" >> /etc/dhcp/dhcpd.conf
    echo "# Статические резервирования IP" >> /etc/dhcp/dhcpd.conf
    
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
        
        # Получение имени хоста
        read -p "Введите имя хоста для этого устройства: " hostname
        
        # Запись статического резервирования
        echo "" >> /etc/dhcp/dhcpd.conf
        echo "host $hostname {" >> /etc/dhcp/dhcpd.conf
        echo "    hardware ethernet $mac_addr;" >> /etc/dhcp/dhcpd.conf
        echo "    fixed-address $static_ip;" >> /etc/dhcp/dhcpd.conf
        echo "}" >> /etc/dhcp/dhcpd.conf
        
        print_color $GREEN "Статическое резервирование добавлено!"
    done
fi

# Настройка интерфейсов для DHCP сервера
print_color $YELLOW "\n=== Настройка интерфейсов для DHCP сервера ==="

# Обновление конфигурации интерфейсов
if [ -f /etc/default/isc-dhcp-server ]; then
    cp /etc/default/isc-dhcp-server /etc/default/isc-dhcp-server.backup.$(date +%Y%m%d_%H%M%S)
fi

# Формируем строку интерфейсов
interfaces_string="${selected_interfaces[@]}"

cat > /etc/default/isc-dhcp-server << EOF
# Defaults for isc-dhcp-server
# Настроено скриптом dhcp.sh

# Интерфейсы для IPv4
INTERFACESv4="$interfaces_string"

# Интерфейсы для IPv6 (не используется)
INTERFACESv6=""
EOF

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

# Проверка конфигурации
print_color $YELLOW "\n=== Проверка конфигурации ==="
if dhcpd -t -cf /etc/dhcp/dhcpd.conf; then
    print_color $GREEN "Конфигурация корректна!"
else
    print_color $RED "Ошибка в конфигурации!"
    print_color $YELLOW "Проверьте файл /etc/dhcp/dhcpd.conf"
    exit 1
fi

# Включение и запуск службы
print_color $YELLOW "\n=== Запуск DHCP сервиса ==="
systemctl enable isc-dhcp-server
systemctl restart isc-dhcp-server

# Проверка статуса службы
if systemctl is-active --quiet isc-dhcp-server; then
    print_color $GREEN "DHCP сервер успешно запущен!"
else
    print_color $RED "Не удалось запустить DHCP сервер!"
    print_color $YELLOW "Проверьте логи командой: journalctl -xe"
    exit 1
fi

# Показать итоговую информацию
print_color $GREEN "\n=== Итоговая информация ==="
echo "Файл конфигурации: /etc/dhcp/dhcpd.conf"
echo "Файл настроек интерфейсов: /etc/default/isc-dhcp-server"
echo "Статус службы: $(systemctl is-active isc-dhcp-server)"
echo "Настроенные интерфейсы: ${selected_interfaces[@]}"
echo "Интерфейс с интернетом: $internet_interface (шлюз: $default_gateway)"
echo ""
print_color $GREEN "Установка DHCP сервера завершена успешно!"
print_color $YELLOW "\nПолезные команды:"
echo "- Просмотр выданных IP адресов: cat /var/lib/dhcp/dhcpd.leases"
echo "- Перезапуск службы: systemctl restart isc-dhcp-server"
echo "- Просмотр логов: journalctl -u isc-dhcp-server -f"
echo "- Редактирование конфигурации: nano /etc/dhcp/dhcpd.conf"
echo "- Проверка конфигурации: dhcpd -t -cf /etc/dhcp/dhcpd.conf"
