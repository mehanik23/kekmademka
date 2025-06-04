#!/bin/bash

# Скрипт настройки HQ-CLI
# Согласно заданию модуля №2

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Функция для отображения заголовка
show_header() {
    clear
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${GREEN}    Настройка HQ-CLI${NC}"
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

# 1. Присоединение к домену Samba
join_domain() {
    show_header
    echo -e "${YELLOW}=== Присоединение к домену ===${NC}"
    echo ""
    
    # Параметры домена
    DOMAIN="AU-TEAM"
    REALM="AU-TEAM.IRPO"
    DC_IP="192.168.200.2"  # BR-SRV
    
    # Установка необходимых пакетов
    log "Установка пакетов для работы с доменом..."
    apt-get update
    apt-get install -y samba winbind libpam-winbind libnss-winbind krb5-user \
                       samba-common-bin libpam-krb5 cifs-utils
    
    # Настройка DNS
    log "Настройка DNS..."
    cat > /etc/resolv.conf << EOF
search $REALM
nameserver $DC_IP
nameserver 8.8.8.8
EOF
    
    # Настройка Kerberos
    log "Настройка Kerberos..."
    cat > /etc/krb5.conf << EOF
[libdefaults]
    default_realm = $REALM
    dns_lookup_realm = false
    dns_lookup_kdc = true

[realms]
    $REALM = {
        kdc = $DC_IP
        admin_server = $DC_IP
        default_domain = ${REALM,,}
    }

[domain_realm]
    .${REALM,,} = $REALM
    ${REALM,,} = $REALM
EOF
    
    # Настройка Samba
    log "Настройка Samba..."
    cat > /etc/samba/smb.conf << EOF
[global]
    workgroup = $DOMAIN
    realm = $REALM
    security = ADS
    
    idmap config * : backend = tdb
    idmap config * : range = 10000-20000
    idmap config $DOMAIN : backend = rid
    idmap config $DOMAIN : range = 100000-999999
    
    winbind use default domain = yes
    winbind enum users = yes
    winbind enum groups = yes
    winbind refresh tickets = yes
    
    template homedir = /home/%U
    template shell = /bin/bash
    
    # Отключаем принтеры
    load printers = no
    printing = bsd
    printcap name = /dev/null
    disable spoolss = yes
EOF
    
    # Настройка NSS
    log "Настройка NSS..."
    sed -i 's/^passwd:.*/passwd:         compat winbind/' /etc/nsswitch.conf
    sed -i 's/^group:.*/group:          compat winbind/' /etc/nsswitch.conf
    
    # Настройка PAM для sudo
    log "Настройка PAM..."
    cat > /etc/pam.d/common-session << EOF
session [default=1]     pam_permit.so
session requisite       pam_deny.so
session required        pam_permit.so
session optional        pam_umask.so
session required        pam_unix.so
session optional        pam_winbind.so
session optional        pam_systemd.so
session required        pam_mkhomedir.so skel=/etc/skel umask=0077
EOF
    
    # Попытка присоединения к домену
    log "Присоединение к домену..."
    echo -e "${YELLOW}Введите пароль администратора домена (P@ssw0rd123):${NC}"
    net ads join -U Administrator
    
    if [ $? -eq 0 ]; then
        log "Успешно присоединились к домену"
        
        # Перезапуск сервисов
        systemctl restart smbd nmbd winbind
        systemctl enable smbd nmbd winbind
        
        # Проверка
        echo -e "${CYAN}Проверка подключения к домену:${NC}"
        wbinfo -t
        echo ""
        echo -e "${CYAN}Пользователи домена:${NC}"
        wbinfo -u | head -10
    else
        error "Ошибка присоединения к домену"
    fi
}

# 2. Настройка автомонтирования NFS
setup_nfs_mount() {
    show_header
    echo -e "${YELLOW}=== Настройка автомонтирования NFS ===${NC}"
    echo ""
    
    NFS_SERVER="192.168.100.2"
    NFS_SHARE="/raid5/nfs"
    MOUNT_POINT="/mnt/nfs"
    
    # Установка NFS клиента
    log "Установка NFS клиента..."
    apt-get update
    apt-get install -y nfs-common
    
    # Создание точки монтирования
    log "Создание точки монтирования..."
    mkdir -p $MOUNT_POINT
    
    # Добавление в fstab для автомонтирования
    log "Настройка автомонтирования..."
    
    # Проверка, не добавлена ли уже запись
    if ! grep -q "$NFS_SERVER:$NFS_SHARE" /etc/fstab; then
        echo "$NFS_SERVER:$NFS_SHARE $MOUNT_POINT nfs defaults,_netdev,auto 0 0" >> /etc/fstab
        log "Запись добавлена в /etc/fstab"
    else
        warning "Запись уже существует в /etc/fstab"
    fi
    
    # Монтирование
    log "Монтирование NFS..."
    mount -a
    
    # Проверка монтирования
    if mountpoint -q $MOUNT_POINT; then
        log "NFS успешно смонтирован"
        echo ""
        echo -e "${CYAN}Содержимое NFS:${NC}"
        ls -la $MOUNT_POINT
    else
        error "Ошибка монтирования NFS"
        echo "Попытка ручного монтирования..."
        mount -t nfs $NFS_SERVER:$NFS_SHARE $MOUNT_POINT -v
    fi
}

# 3. Настройка Chrony клиента
setup_chrony_client() {
    show_header
    echo -e "${YELLOW}=== Настройка Chrony клиента ===${NC}"
    echo ""
    
    # Установка chrony
    log "Установка chrony..."
    apt-get update
    apt-get install -y chrony
    
    # Резервная копия конфига
    cp /etc/chrony/chrony.conf /etc/chrony/chrony.conf.backup
    
    # Настройка клиента
    log "Настройка chrony клиента..."
    cat > /etc/chrony/chrony.conf << EOF
# Chrony client configuration for HQ-CLI
# NTP сервер - HQ-RTR
server 192.168.100.1 iburst prefer

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

# 4. Проверка прав пользователей группы hq
test_hq_permissions() {
    show_header
    echo -e "${YELLOW}=== Проверка прав группы hq ===${NC}"
    echo ""
    
    # Проверка sudo прав
    log "Проверка настройки sudo для группы hq..."
    
    if [ -f /etc/sudoers.d/hq_users ]; then
        echo -e "${GREEN}Файл sudo настроен${NC}"
        cat /etc/sudoers.d/hq_users
    else
        warning "Создание локального файла sudo для группы hq..."
        cat > /etc/sudoers.d/hq_users << EOF
# Ограниченные команды для группы hq
%hq ALL=(ALL) NOPASSWD: /bin/cat, /bin/grep, /usr/bin/id
%AU-TEAM\\\\hq ALL=(ALL) NOPASSWD: /bin/cat, /bin/grep, /usr/bin/id
EOF
        chmod 440 /etc/sudoers.d/hq_users
    fi
    
    echo ""
    log "Тестирование прав..."
    echo "Попробуйте войти под пользователем user1.hq и выполнить:"
    echo "  sudo cat /etc/passwd     - должно работать"
    echo "  sudo grep root /etc/passwd - должно работать"
    echo "  sudo id                  - должно работать"
    echo "  sudo apt update          - НЕ должно работать"
}

# 5. Информация о системе
show_system_info() {
    show_header
    echo -e "${YELLOW}=== Информация о системе ===${NC}"
    echo ""
    
    echo -e "${CYAN}Сетевые настройки:${NC}"
    ip addr show | grep "inet "
    
    echo ""
    echo -e "${CYAN}Монтирование:${NC}"
    mount | grep nfs
    
    echo ""
    echo -e "${CYAN}Домен:${NC}"
    if command -v wbinfo &> /dev/null; then
        wbinfo -D AU-TEAM 2>/dev/null || echo "Не подключен к домену"
    fi
    
    echo ""
    echo -e "${CYAN}Время:${NC}"
    if command -v chronyc &> /dev/null; then
        chronyc tracking | grep "System time"
    fi
}

# Главное меню
main_menu() {
    while true; do
        show_header
        echo "Выберите действие:"
        echo ""
        echo "1) Присоединиться к домену"
        echo "2) Настроить автомонтирование NFS"
        echo "3) Настроить Chrony клиент"
        echo "4) Проверить права группы hq"
        echo "5) Показать информацию о системе"
        echo "6) Выполнить полную настройку"
        echo "7) Выход"
        echo ""
        
        read -p "Ваш выбор (1-7): " choice
        
        case $choice in
            1) join_domain ;;
            2) setup_nfs_mount ;;
            3) setup_chrony_client ;;
            4) test_hq_permissions ;;
            5) show_system_info ;;
            6) 
                join_domain
                setup_nfs_mount
                setup_chrony_client
                test_hq_permissions
                echo ""
                log "Полная настройка завершена!"
                ;;
            7) 
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