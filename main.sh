#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Функции для логирования
log() {
    echo -e "${CYAN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}
error() {
    echo -e "${RED}[ERROR] $1${NC}"
}
warn() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}
info() {
    echo -e "${MAGENTA}[INFO] $1${NC}"
}
prompt() {
    echo -e "${YELLOW}[INPUT] $1${NC}"
}

# Проверка прав root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Этот скрипт должен быть запущен с правами root"
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

# Функция валидации CIDR маски
validate_cidr() {
    local cidr=$1
    if [[ $cidr =~ ^[0-9]+$ ]] && [[ $cidr -ge 0 ]] && [[ $cidr -le 32 ]]; then
        return 0
    else
        return 1
    fi
}

# Проверка состояния интерфейса
check_interface_state() {
    local interface=$1
    if ip link show $interface &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Создание резервной копии конфигурации
backup_config() {
    local config_file=$1
    if [ -f "$config_file" ]; then
        cp "$config_file" "${config_file}.backup.$(date +%Y%m%d_%H%M%S)"
        log "Создана резервная копия: ${config_file}.backup.$(date +%Y%m%d_%H%M%S)"
    fi
}

# Отключение NetworkManager
disable_networkmanager() {
    if systemctl is-active NetworkManager &>/dev/null; then
        warn "NetworkManager активен. Отключение может прервать сетевое соединение!"
        read -p "Продолжить отключение NetworkManager? (да/нет): " confirm
        if [[ $confirm == "да" ]] || [[ $confirm == "yes" ]]; then
            log "Отключение NetworkManager..."
            systemctl stop NetworkManager
            systemctl disable NetworkManager
            systemctl mask NetworkManager
            log "NetworkManager полностью отключен"
            
            # Включение systemd-networkd
            systemctl unmask systemd-networkd
            systemctl enable systemd-networkd
            systemctl start systemd-networkd
            log "systemd-networkd включен"
        else
            log "Отключение NetworkManager отменено"
        fi
    else
        log "NetworkManager уже отключен"
    fi
}

# Получение списка сетевых интерфейсов
get_interfaces() {
    interfaces=($(ip link show | awk -F: '$0 !~ "lo|vir|wl|^[^0-9]"{print $2}' | sed 's/^ *//'))
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        error "Не найдено сетевых интерфейсов"
        exit 1
    fi
}

# Сохранение сетевых настроек через systemd-networkd
save_network_config() {
    local interface=$1
    local ip_address=$2
    local netmask=$3
    local gateway=$4
    local dns1=$5
    local dns2=$6

    log "Сохранение сетевых настроек для интерфейса $interface..."

    # Создание директории если не существует
    mkdir -p /etc/systemd/network

    # Создание конфигурации systemd-networkd
    cat > /etc/systemd/network/10-static-$interface.network << EOF
[Match]
Name=$interface

[Network]
Address=$ip_address/$netmask
Gateway=$gateway
DNS=$dns1
EOF

    # Добавление второго DNS, если он указан
    if [[ -n "$dns2" ]]; then
        echo "DNS=$dns2" >> /etc/systemd/network/10-static-$interface.network
    fi

    # Включение и перезапуск systemd-networkd
    systemctl enable systemd-networkd
    systemctl restart systemd-networkd

    log "Настройки для интерфейса $interface сохранены и будут применены при перезагрузке."
}

# Настройка статического IP
configure_static_ip() {
    # Проверка и отключение NetworkManager при первой настройке сети
    if systemctl is-active NetworkManager &>/dev/null; then
        warn "Для корректной работы статических настроек рекомендуется отключить NetworkManager"
        disable_networkmanager
    fi
    
    get_interfaces
    echo ""
    info "Доступные сетевые интерфейсы:"
    for i in "${!interfaces[@]}"; do
        echo "  $((i+1))) ${interfaces[$i]}"
    done
    
    while true; do
        prompt "Выберите интерфейс для настройки (1-${#interfaces[@]}): "
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#interfaces[@]} ]]; then
            selected_interface=${interfaces[$((choice-1))]}
            break
        else
            error "Неверный выбор. Введите число от 1 до ${#interfaces[@]}"
        fi
    done
    
    # Ввод и валидация IP адреса
    while true; do
        read -p "Введите IP адрес: " ip
        if validate_ip "$ip"; then
            break
        else
            error "Неверный формат IP адреса. Пример: 192.168.1.100"
        fi
    done
    
    # Ввод и валидация маски
    while true; do
        read -p "Введите маску (CIDR, например, 24): " mask
        if validate_cidr "$mask"; then
            break
        else
            error "Неверный формат маски. Введите число от 0 до 32"
        fi
    done
    
    # Ввод и валидация шлюза
    while true; do
        read -p "Введите шлюз: " gateway
        if validate_ip "$gateway"; then
            break
        else
            error "Неверный формат IP адреса шлюза"
        fi
    done
    
    # Ввод и валидация DNS
    while true; do
        read -p "Введите основной DNS сервер: " dns1
        if validate_ip "$dns1"; then
            break
        else
            error "Неверный формат IP адреса DNS"
        fi
    done
    
    read -p "Введите дополнительный DNS сервер (необязательно, Enter для пропуска): " dns2
    if [[ -n "$dns2" ]] && ! validate_ip "$dns2"; then
        warn "Неверный формат дополнительного DNS, будет использован только основной"
        dns2=""
    fi
    
    log "Применение настроек для интерфейса $selected_interface..."
    
    # Применение настроек
    ip addr flush dev $selected_interface
    ip addr add ${ip}/${mask} dev $selected_interface
    ip link set $selected_interface up
    
    # Удаление старого маршрута по умолчанию и добавление нового
    ip route del default 2>/dev/null
    ip route add default via $gateway
    
    # Настройка DNS
    echo "nameserver $dns1" > /etc/resolv.conf
    if [[ -n "$dns2" ]]; then
        echo "nameserver $dns2" >> /etc/resolv.conf
    fi

    # Сохранение настроек
    save_network_config "$selected_interface" "$ip" "$mask" "$gateway" "$dns1" "$dns2"

    log "Настройка завершена!"
}

# Настройка OpenVSwitch
configure_openvswitch() {
    info "Настройка виртуального коммутатора OpenVSwitch"
    
    # Проверка установки OpenVSwitch
    if ! command -v ovs-vsctl &> /dev/null; then
        log "OpenVSwitch не установлен. Устанавливаю..."
        apt update
        apt install -y openvswitch-switch
    fi
    
    # Включение и запуск OpenVSwitch
    systemctl enable openvswitch-switch
    systemctl start openvswitch-switch
    
    # Параметры по умолчанию
    local default_bridge="switch1"
    local default_vlans=("vlan100" "vlan200" "vlan999")
    local default_ips=("192.168.100.1/26" "192.168.100.65/28" "192.168.100.81/29")
    
    # Запрос имени моста
    read -p "Введите имя виртуального коммутатора (по умолчанию: $default_bridge): " bridge_name
    bridge_name=${bridge_name:-$default_bridge}
    
    # Проверка существования моста
    if ovs-vsctl br-exists $bridge_name 2>/dev/null; then
        warn "Мост $bridge_name уже существует!"
        read -p "Удалить существующий мост и создать заново? (да/нет): " recreate
        if [[ $recreate == "да" ]] || [[ $recreate == "yes" ]]; then
            ovs-vsctl del-br $bridge_name
        else
            return
        fi
    fi
    
    # Создание моста
    log "Создание моста $bridge_name..."
    ovs-vsctl add-br $bridge_name
    
    # Получение списка интерфейсов для добавления в мост
    get_interfaces
    local bridge_interfaces=()
    
    echo ""
    info "Выберите интерфейсы для добавления в виртуальный коммутатор"
    info "Введите 'готово' когда закончите выбор"
    
    while true; do
        echo ""
        echo "Доступные интерфейсы:"
        for i in "${!interfaces[@]}"; do
            echo "  $((i+1))) ${interfaces[$i]}"
        done
        
        prompt "Выберите интерфейс (или 'готово'): "
        read -r choice
        
        if [[ $choice == "готово" ]] || [[ $choice == "done" ]]; then
            break
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#interfaces[@]} ]]; then
            bridge_interfaces+=("${interfaces[$((choice-1))]}")
            log "Добавлен интерфейс: ${interfaces[$((choice-1))]}"
        else
            error "Неверный выбор"
        fi
    done
    
    # Настройка VLAN
    echo ""
    info "Настройка VLAN интерфейсов"
    read -p "Использовать настройки VLAN по умолчанию? (да/нет): " use_defaults
    
    local vlans=()
    local vlan_ips=()
    
    if [[ $use_defaults == "да" ]] || [[ $use_defaults == "yes" ]]; then
        vlans=("${default_vlans[@]}")
        vlan_ips=("${default_ips[@]}")
    else
        # Пользовательские VLAN
        while true; do
            read -p "Введите имя VLAN (например, vlan100) или 'готово': " vlan_name
            if [[ $vlan_name == "готово" ]] || [[ $vlan_name == "done" ]]; then
                break
            fi
            
            # Запрос IP для VLAN
            while true; do
                read -p "Введите IP адрес с маской для $vlan_name (например, 192.168.100.1/24): " vlan_ip
                if [[ $vlan_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
                    vlans+=("$vlan_name")
                    vlan_ips+=("$vlan_ip")
                    break
                else
                    error "Неверный формат. Используйте формат: IP/маска"
                fi
            done
        done
    fi
    
    # Добавление интерфейсов в мост с назначением VLAN
    for i in "${!bridge_interfaces[@]}"; do
        if [ $i -lt ${#vlans[@]} ]; then
            local tag="${vlans[$i]##vlan}"  # Извлекаем номер из имени VLAN
            log "Добавление ${bridge_interfaces[$i]} в $bridge_name с тегом $tag..."
            ovs-vsctl add-port $bridge_name ${bridge_interfaces[$i]} tag=$tag
        else
            log "Добавление ${bridge_interfaces[$i]} в $bridge_name как trunk..."
            ovs-vsctl add-port $bridge_name ${bridge_interfaces[$i]}
        fi
    done
    
    # Создание внутренних VLAN интерфейсов
    for i in "${!vlans[@]}"; do
        local vlan_name="${vlans[$i]}"
        local vlan_tag="${vlan_name##vlan}"
        local vlan_ip="${vlan_ips[$i]}"
        
        log "Создание внутреннего интерфейса $vlan_name..."
        ovs-vsctl add-port $bridge_name $vlan_name tag=$vlan_tag -- set interface $vlan_name type=internal
        
        # Применение IP настроек
        ip link set $vlan_name up
        ip addr add $vlan_ip dev $vlan_name
        
        # Сохранение настроек через systemd-networkd
        cat > /etc/systemd/network/10-ovs-$vlan_name.network << EOF
[Match]
Name=$vlan_name

[Network]
Address=$vlan_ip
EOF
    done
    
    # Включение моста
    ip link set $bridge_name up
    
    # Создание systemd службы для восстановления OVS после перезагрузки
    create_ovs_restore_service "$bridge_name" "${bridge_interfaces[@]}" "${vlans[@]}" "${vlan_ips[@]}"
    
    # Перезапуск systemd-networkd
    systemctl restart systemd-networkd
    
    log "Настройка виртуального коммутатора завершена!"
    log "Для просмотра конфигурации используйте: ovs-vsctl show"
}

# Создание службы для восстановления OVS конфигурации
create_ovs_restore_service() {
    local bridge_name=$1
    shift
    local interfaces=()
    local vlans=()
    local ips=()
    
    # Разбор аргументов
    while [[ $# -gt 0 ]]; do
        if [[ $1 == vlan* ]]; then
            vlans+=("$1")
            shift
            if [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
                ips+=("$1")
                shift
            fi
        else
            interfaces+=("$1")
            shift
        fi
    done
    
    log "Создание службы автозапуска для OVS..."
    
    cat > /etc/systemd/system/ovs-restore.service << EOF
[Unit]
Description=Restore OpenVSwitch Configuration
After=network.target openvswitch-switch.service
Requires=openvswitch-switch.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/ovs-restore.sh

[Install]
WantedBy=multi-user.target
EOF

    # Создание скрипта восстановления
    cat > /usr/local/bin/ovs-restore.sh << 'SCRIPT'
#!/bin/bash

# Ждем запуска OVS
sleep 5

# Восстановление конфигурации
BRIDGE_NAME="BRIDGE_PLACEHOLDER"

# Проверка существования моста
if ! ovs-vsctl br-exists $BRIDGE_NAME 2>/dev/null; then
    ovs-vsctl add-br $BRIDGE_NAME
fi

# Включение моста
ip link set $BRIDGE_NAME up

# Восстановление VLAN интерфейсов
VLAN_CONFIG
SCRIPT

    # Замена плейсхолдеров
    sed -i "s/BRIDGE_PLACEHOLDER/$bridge_name/g" /usr/local/bin/ovs-restore.sh
    
    # Добавление конфигурации VLAN
    local vlan_config=""
    for i in "${!vlans[@]}"; do
        local vlan_name="${vlans[$i]}"
        local vlan_tag="${vlan_name##vlan}"
        local vlan_ip="${ips[$i]}"
        
        vlan_config+="
# Настройка $vlan_name
if ! ovs-vsctl port-to-br $vlan_name >/dev/null 2>&1; then
    ovs-vsctl add-port $bridge_name $vlan_name tag=$vlan_tag -- set interface $vlan_name type=internal
fi
ip link set $vlan_name up
ip addr add $vlan_ip dev $vlan_name 2>/dev/null
"
    done
    
    # Вставка конфигурации VLAN
    sed -i "s|VLAN_CONFIG|$vlan_config|g" /usr/local/bin/ovs-restore.sh
    
    # Делаем скрипт исполняемым
    chmod +x /usr/local/bin/ovs-restore.sh
    
    # Включение службы
    systemctl enable ovs-restore.service
    systemctl start ovs-restore.service
    
    log "Служба автозапуска OVS создана и включена"
}

# Изменение имени хоста
change_hostname_menu() {
    while true; do
        local hostnames=("isp.au-team.irpo" "hq-rtr.au-team.irpo" "br-rtr.au-team.irpo" "hq-srv.au-team.irpo" "hq-cli.au-team.irpo" "br-srv.au-team.irpo")
        echo ""
        info "Доступные варианты имени хоста:"
        for i in "${!hostnames[@]}"; do
            echo "  $((i+1))) ${hostnames[$i]}"
        done
        echo "  $((${#hostnames[@]}+1))) Ввести своё имя"
        echo "  $((${#hostnames[@]}+2))) Вернуться в главное меню"
        prompt "Выберите вариант (1-$(( ${#hostnames[@]}+2 ))): "
        read -r choice
        
        if [[ "$choice" -eq $((${#hostnames[@]}+2)) ]]; then
            break
        elif [[ "$choice" -le ${#hostnames[@]} ]] && [[ "$choice" -ge 1 ]]; then
            new_hostname=${hostnames[$((choice-1))]}
        elif [[ "$choice" -eq $((${#hostnames[@]}+1)) ]]; then
            read -p "Введите новое имя хоста: " new_hostname
        else
            error "Неверный выбор"
            continue
        fi
        
        if [[ -n "$new_hostname" ]]; then
            log "Установка нового имени хоста: $new_hostname"
            hostnamectl set-hostname "$new_hostname"
            # Обновление /etc/hosts
            sed -i "s/127.0.1.1.*/127.0.1.1\t$new_hostname/g" /etc/hosts
            log "Имя хоста изменено на: $new_hostname"
            break
        fi
    done
}

# Меню создания/удаления пользователей
create_user_menu() {
    while true; do
        echo ""
        info "Меню управления пользователями:"
        echo "1) Создать нового пользователя"
        echo "2) Удалить существующего пользователя"
        echo "3) Просмотреть список пользователей"
        echo "4) Изменить пароль пользователя"
        echo "5) Вернуться в главное меню"
        prompt "Выберите действие (1-5): "
        read -r choice
        
        case $choice in
            1)
                prompt "Введите имя нового пользователя: "
                read -r username
                if id "$username" &>/dev/null; then
                    warn "Пользователь '$username' уже существует."
                else
                    log "Создание пользователя '$username'..."
                    useradd -m -s /bin/bash "$username"
                    passwd "$username"
                    
                    read -p "Добавить пользователя в группу sudo? (да/нет): " add_sudo
                    if [[ $add_sudo == "да" ]] || [[ $add_sudo == "yes" ]]; then
                        usermod -aG sudo "$username"
                        log "Пользователь добавлен в группу sudo"
                    fi
                    
                    log "Пользователь '$username' успешно создан!"
                fi
                ;;
            2)
                prompt "Введите имя пользователя для удаления: "
                read -r username
                if [[ "$username" == "root" ]]; then
                    error "Нельзя удалить пользователя root!"
                elif id "$username" &>/dev/null; then
                    warn "Будут удалены пользователь и его домашняя директория!"
                    read -p "Вы уверены? (да/нет): " confirm
                    if [[ $confirm == "да" ]] || [[ $confirm == "yes" ]]; then
                        log "Удаление пользователя '$username'..."
                        userdel -r "$username"
                        log "Пользователь '$username' успешно удален!"
                    fi
                else
                    warn "Пользователь '$username' не существует."
                fi
                ;;
            3)
                log "Список пользователей (с UID >= 1000):"
                awk -F: '$3 >= 1000 {print $1 " (UID: " $3 ")"}' /etc/passwd
                ;;
            4)
                prompt "Введите имя пользователя для смены пароля: "
                read -r username
                if id "$username" &>/dev/null; then
                    passwd "$username"
                else
                    warn "Пользователь '$username' не существует."
                fi
                ;;
            5) break ;;
            *) warn "Неверный выбор. Введите число от 1 до 5." ;;
        esac
    done
}

# SSH подключение
ssh_connection() {
    # Установлен фиксированный пользователь для подключения
    local ssh_user="sshuser"
    
    while true; do
        prompt "Введите IP-адрес для SSH: "
        read -r ssh_ip
        if validate_ip "$ssh_ip"; then
            break
        else
            error "Неверный формат IP адреса"
        fi
    done

    # Вывод баннера (локальное сообщение)
    echo -e "\e[33mAuthorized access only\e[0m"
    
    log "Подключение к $ssh_user@$ssh_ip:2024 через SSH..."
    ssh -o ConnectTimeout=10 \
        -o NumberOfPasswordPrompts=2 \
        -p 2024 \
        "${ssh_user}@${ssh_ip}"
}

# Сброс настроек
reset_settings_menu() {
    while true; do
        echo ""
        info "Меню сброса настроек:"
        echo "1) Сброс сетевых настроек интерфейса"
        echo "2) Сброс имени хоста"
        echo "3) Удаление пользователей"
        echo "4) Сброс конфигурации OpenVSwitch"
        echo "5) Полный сброс сетевых настроек"
        echo "6) Вернуться в главное меню"
        prompt "Выберите действие (1-6): "
        read -r choice
        
        case $choice in
            1)
                get_interfaces
                echo ""
                info "Доступные сетевые интерфейсы:"
                for i in "${!interfaces[@]}"; do
                    echo "  $((i+1))) ${interfaces[$i]}"
                done
                
                while true; do
                    prompt "Выберите интерфейс для сброса (1-${#interfaces[@]}): "
                    read -r choice
                    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#interfaces[@]} ]]; then
                        interface=${interfaces[$((choice-1))]}
                        break
                    else
                        error "Неверный выбор"
                    fi
                done
                
                log "Сброс настроек для интерфейса $interface..."
                ip addr flush dev $interface
                ip link set $interface down
                rm -f /etc/systemd/network/10-static-$interface.network
                systemctl restart systemd-networkd
                log "Настройки интерфейса $interface сброшены!"
                ;;
            2)
                log "Сброс имени хоста..."
                hostnamectl set-hostname "localhost"
                sed -i "s/127.0.1.1.*/127.0.1.1\tlocalhost/g" /etc/hosts
                log "Имя хоста сброшено на 'localhost'."
                ;;
            3)
                prompt "Введите имя пользователя для удаления: "
                read -r username
                if [[ "$username" == "root" ]]; then
                    error "Нельзя удалить пользователя root!"
                elif id "$username" &>/dev/null; then
                    log "Удаление пользователя '$username'..."
                    userdel -r "$username"
                    log "Пользователь '$username' успешно удален!"
                else
                    warn "Пользователь '$username' не существует."
                fi
                ;;
            4)
                if command -v ovs-vsctl &> /dev/null; then
                    log "Получение списка мостов OVS..."
                    bridges=$(ovs-vsctl list-br)
                    if [[ -n "$bridges" ]]; then
                        echo "Существующие мосты:"
                        echo "$bridges"
                        read -p "Удалить все мосты OVS? (да/нет): " confirm
                        if [[ $confirm == "да" ]] || [[ $confirm == "yes" ]]; then
                            for bridge in $bridges; do
                                log "Удаление моста $bridge..."
                                ovs-vsctl del-br $bridge
                            done
                            systemctl disable ovs-restore.service 2>/dev/null
                            rm -f /etc/systemd/system/ovs-restore.service
                            rm -f /usr/local/bin/ovs-restore.sh
                            log "Конфигурация OVS сброшена"
                        fi
                    else
                        info "Мосты OVS не найдены"
                    fi
                else
                    info "OpenVSwitch не установлен"
                fi
                ;;
            5)
                warn "Это удалит ВСЕ сетевые настройки!"
                read -p "Вы уверены? (да/нет): " confirm
                if [[ $confirm == "да" ]] || [[ $confirm == "yes" ]]; then
                    log "Полный сброс сетевых настроек..."
                    rm -f /etc/systemd/network/*.network
                    systemctl restart systemd-networkd
                    log "Все сетевые настройки сброшены"
                fi
                ;;
            6) break ;;
            *) warn "Неверный выбор. Введите число от 1 до 6." ;;
        esac
    done
}

# Настройка маскарадинга
configure_masquerade() {
    get_interfaces
    echo ""
    info "Доступные сетевые интерфейсы:"
    for i in "${!interfaces[@]}"; do
        echo "  $((i+1))) ${interfaces[$i]}"
    done
    
    # Также показать OVS VLAN интерфейсы если есть
    if command -v ovs-vsctl &> /dev/null; then
        ovs_interfaces=$(ovs-vsctl list-ifaces $(ovs-vsctl list-br 2>/dev/null) 2>/dev/null | grep -E '^vlan[0-9]+' || true)
        if [[ -n "$ovs_interfaces" ]]; then
            info "Доступные VLAN интерфейсы:"
            echo "$ovs_interfaces"
            interfaces+=($ovs_interfaces)
        fi
    fi
    
    while true; do
        prompt "Выберите внешний интерфейс для маскарадинга (1-${#interfaces[@]}): "
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#interfaces[@]} ]]; then
            external_interface=${interfaces[$((choice-1))]}
            break
        else
            error "Неверный выбор"
        fi
    done
    
    while true; do
        prompt "Выберите внутренний интерфейс для локальной сети (1-${#interfaces[@]}): "
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#interfaces[@]} ]]; then
            internal_interface=${interfaces[$((choice-1))]}
            if [[ "$internal_interface" == "$external_interface" ]]; then
                error "Внутренний и внешний интерфейсы не могут совпадать!"
                continue
            fi
            break
        else
            error "Неверный выбор"
        fi
    done
    
    log "Настройка IP-форвардинга и маскарадинга..."
    
    # Включение IP форвардинга
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-ipforward.conf
    sysctl -p /etc/sysctl.d/99-ipforward.conf
    
    # Проверка установки iptables
    if ! command -v iptables &> /dev/null; then
        log "Установка iptables..."
        apt update
        apt install -y iptables
    fi
    
    # Очистка старых правил
    iptables -F
    iptables -t nat -F
    
    # Настройка правил маскарадинга
    iptables -t nat -A POSTROUTING -o $external_interface -j MASQUERADE
    iptables -A FORWARD -i $external_interface -o $internal_interface -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -A FORWARD -i $internal_interface -o $external_interface -j ACCEPT
    
    # Установка и сохранение правил iptables
    log "Установка и сохранение правил iptables..."
    DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent
    netfilter-persistent save
    
    log "Маскарадинг настроен для: $internal_interface -> $external_interface"
}

# Проверка интернета
test_internet_connection() {
    log "Проверка подключения к интернету..."
    
    # Проверка DNS
    echo -n "Проверка DNS (google.com)... "
    if nslookup google.com >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗${NC}"
    fi
    
    # Проверка ping
    echo -n "Проверка ping 8.8.8.8... "
    if ping -c 3 -W 2 8.8.8.8 &>/dev/null; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗${NC}"
    fi
    
    # Проверка HTTP
    echo -n "Проверка HTTP соединения... "
    if curl -s --connect-timeout 5 http://example.com >/dev/null; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗${NC}"
    fi
}

# Меню NetworkManager
networkmanager_menu() {
    while true; do
        echo ""
        info "Управление NetworkManager:"
        
        # Проверка статуса NetworkManager
        if systemctl is-active NetworkManager &>/dev/null; then
            status="${GREEN}Активен${NC}"
        else
            status="${RED}Отключен${NC}"
        fi
        
        echo -e "Текущий статус: $status"
        echo ""
        echo "1) Отключить NetworkManager"
        echo "2) Включить NetworkManager"
        echo "3) Вернуться в главное меню"
        
        prompt "Выберите действие (1-3): "
        read -r choice
        
        case $choice in
            1)
                disable_networkmanager
                ;;
            2)
                log "Включение NetworkManager..."
                systemctl unmask NetworkManager
                systemctl enable NetworkManager
                systemctl start NetworkManager
                
                # Отключение systemd-networkd если включаем NetworkManager
                systemctl stop systemd-networkd
                systemctl disable systemd-networkd
                
                log "NetworkManager включен"
                ;;
            3) break ;;
            *) warn "Неверный выбор" ;;
        esac
    done
}

# Главное меню
main_menu() {
    while true; do
        echo ""
        info "===== Главное меню ====="
        echo "1) Настройка статического IP"
        echo "2) Изменение имени хоста"
        echo "3) Настройка маскарадинга (NAT)"
        echo "4) Проверка интернета"
        echo "5) Управление пользователями"
        echo "6) SSH подключение"
        echo "7) Настройка виртуального коммутатора (OpenVSwitch)"
        echo "8) Управление NetworkManager"
        echo "9) Сброс настроек"
        echo "10) Выход"
        prompt "Выберите действие (1-10): "
        read -r choice
        
        case $choice in
            1) configure_static_ip ;;
            2) change_hostname_menu ;;
            3) configure_masquerade ;;
            4) test_internet_connection ;;
            5) create_user_menu ;;
            6) ssh_connection ;;
            7) configure_openvswitch ;;
            8) networkmanager_menu ;;
            9) reset_settings_menu ;;
            10) 
                log "Выход из программы"
                break 
                ;;
            *) warn "Неверный выбор. Введите число от 1 до 10." ;;
        esac
    done
}

# Запуск скрипта
clear
echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     Скрипт настройки сетевой конфигурации  ║${NC}"
echo -e "${CYAN}║              Версия 2.0                    ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}"
echo ""

check_root
main_menu
