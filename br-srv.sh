#!/bin/bash

# Скрипт настройки BR-SRV
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
    echo -e "${GREEN}    Настройка BR-SRV${NC}"
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

# 1. Настройка Samba Domain Controller
setup_samba_dc() {
    show_header
    echo -e "${YELLOW}=== Настройка Samba Domain Controller ===${NC}"
    echo ""
    
    # Установка пакетов
    log "Установка необходимых пакетов..."
    apt-get update
    apt-get install -y samba smbclient winbind krb5-config krb5-user \
                       libpam-winbind libnss-winbind
    
    # Остановка сервисов
    systemctl stop samba smbd nmbd winbind
    systemctl disable samba smbd nmbd winbind
    
    # Резервная копия конфигов
    if [ -f /etc/samba/smb.conf ]; then
        mv /etc/samba/smb.conf /etc/samba/smb.conf.backup
    fi
    
    # Параметры домена
    REALM="AU-TEAM.IRPO"
    DOMAIN="AU-TEAM"
    ADMINPASS="P@ssw0rd123"
    
    # Провижининг домена
    log "Создание домена $DOMAIN..."
    samba-tool domain provision --use-rfc2307 \
        --realm=$REALM \
        --domain=$DOMAIN \
        --server-role=dc \
        --dns-backend=SAMBA_INTERNAL \
        --adminpass=$ADMINPASS
    
    # Копирование Kerberos конфига
    cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
    
    # Запуск Samba AD DC
    systemctl unmask samba-ad-dc
    systemctl enable samba-ad-dc
    systemctl start samba-ad-dc
    
    # Создание пользователей
    log "Создание пользователей офиса HQ..."
    for i in {1..5}; do
        username="user$i.hq"
        password="User${i}Pass!"
        
        samba-tool user create $username $password \
            --given-name="User$i" \
            --surname="HQ" \
            --mail-address="$username@$REALM"
        
        if [ $? -eq 0 ]; then
            log "Пользователь $username создан"
        else
            error "Ошибка создания пользователя $username"
        fi
    done
    
    # Создание группы hq
    log "Создание группы hq..."
    samba-tool group add hq --description="HQ Office Users"
    
    # Добавление пользователей в группу
    for i in {1..5}; do
        username="user$i.hq"
        samba-tool group addmembers hq $username
    done
    
    # Настройка sudo для группы hq
    cat > /etc/sudoers.d/hq_users << EOF
# Ограниченные команды для группы hq
%hq ALL=(ALL) NOPASSWD: /bin/cat, /bin/grep, /usr/bin/id
EOF
    chmod 440 /etc/sudoers.d/hq_users
    
    log "Samba Domain Controller настроен"
    echo ""
    echo -e "${CYAN}Информация о домене:${NC}"
    echo "Домен: $DOMAIN"
    echo "Realm: $REALM"
    echo "Administrator пароль: $ADMINPASS"
    echo ""
}

# 2. Импорт пользователей из CSV
import_users_csv() {
    show_header
    echo -e "${YELLOW}=== Импорт пользователей из CSV ===${NC}"
    echo ""
    
    CSV_FILE="/opt/users.csv"
    
    if [ ! -f "$CSV_FILE" ]; then
        warning "Файл $CSV_FILE не найден"
        # Создаем пример файла
        log "Создание примера CSV файла..."
        cat > $CSV_FILE << EOF
username,firstname,lastname,password,email
testuser1,Test,User1,TestPass1!,testuser1@au-team.irpo
testuser2,Test,User2,TestPass2!,testuser2@au-team.irpo
EOF
        log "Создан пример файла в $CSV_FILE"
    fi
    
    # Импорт пользователей
    log "Импорт пользователей из CSV..."
    while IFS=',' read -r username firstname lastname password email; do
        if [ "$username" != "username" ]; then  # Пропускаем заголовок
            samba-tool user create $username $password \
                --given-name="$firstname" \
                --surname="$lastname" \
                --mail-address="$email" 2>/dev/null
            
            if [ $? -eq 0 ]; then
                log "Пользователь $username импортирован"
            else
                warning "Пользователь $username уже существует или ошибка"
            fi
        fi
    done < "$CSV_FILE"
}

# 3. Настройка Docker и MediaWiki
setup_docker_mediawiki() {
    show_header
    echo -e "${YELLOW}=== Настройка Docker и MediaWiki ===${NC}"
    echo ""
    
    # Установка Docker
    log "Установка Docker..."
    apt-get update
    apt-get install -y docker.io docker-compose
    systemctl enable docker
    systemctl start docker
    
    # Создание директории для MediaWiki
    WIKI_DIR="/home/$(logname)/mediawiki"
    mkdir -p $WIKI_DIR
    cd $WIKI_DIR
    
    # Создание docker-compose файла
    log "Создание wiki.yml..."
    cat > wiki.yml << 'EOF'
version: '3'
services:
  wiki:
    image: mediawiki
    container_name: wiki
    restart: always
    ports:
      - 8080:80
    volumes:
      - ./LocalSettings.php:/var/www/html/LocalSettings.php
      - wiki_images:/var/www/html/images
    environment:
      - MEDIAWIKI_DB_HOST=mariadb
      - MEDIAWIKI_DB_USER=wiki
      - MEDIAWIKI_DB_PASSWORD=WikiP@ssw0rd
      - MEDIAWIKI_DB_NAME=mediawiki
    depends_on:
      - mariadb

  mariadb:
    image: mariadb
    container_name: mariadb
    restart: always
    environment:
      - MYSQL_DATABASE=mediawiki
      - MYSQL_USER=wiki
      - MYSQL_PASSWORD=WikiP@ssw0rd
      - MYSQL_ROOT_PASSWORD=RootP@ssw0rd
    volumes:
      - db_data:/var/lib/mysql

volumes:
  wiki_images:
  db_data:
EOF
    
    # Создание примера LocalSettings.php
    log "Создание LocalSettings.php..."
    cat > LocalSettings.php << 'EOF'
<?php
# This file was automatically generated by the MediaWiki installer.
# See includes/DefaultSettings.php for all configurable settings
# and their default values, but don't forget to make changes in _this_
# file, not there.

# Database settings
$wgDBtype = "mysql";
$wgDBserver = "mariadb";
$wgDBname = "mediawiki";
$wgDBuser = "wiki";
$wgDBpassword = "WikiP@ssw0rd";

# Site name
$wgSitename = "AU-Team Wiki";
$wgMetaNamespace = "AU-Team_Wiki";

# Site language
$wgLanguageCode = "ru";

# Site URLs
$wgScriptPath = "";
$wgArticlePath = "/wiki/$1";
$wgUsePathInfo = true;

# Uploads
$wgEnableUploads = true;
$wgUploadDirectory = "$IP/images";
$wgUploadPath = "$wgScriptPath/images";
EOF
    
    # Запуск контейнеров
    log "Запуск контейнеров..."
    docker-compose -f wiki.yml up -d
    
    # Ожидание запуска
    log "Ожидание запуска сервисов..."
    sleep 30
    
    # Проверка статуса
    if docker ps | grep -q wiki; then
        log "MediaWiki запущена на порту 8080"
    else
        error "Ошибка запуска MediaWiki"
    fi
    
    chown -R $(logname):$(logname) $WIKI_DIR
}

# 4. Настройка Ansible
setup_ansible() {
    show_header
    echo -e "${YELLOW}=== Настройка Ansible ===${NC}"
    echo ""
    
    # Установка Ansible
    log "Установка Ansible..."
    apt-get update
    apt-get install -y python3-pip sshpass
    pip3 install ansible
    
    # Создание структуры каталогов
    ANSIBLE_DIR="/etc/ansible"
    mkdir -p $ANSIBLE_DIR/{playbooks,roles,group_vars,host_vars}
    
    # Создание inventory файла
    log "Создание файла инвентаря..."
    cat > $ANSIBLE_DIR/inventory << EOF
[all:vars]
ansible_user=root
ansible_ssh_pass=P@ssw0rd
ansible_ssh_common_args='-o StrictHostKeyChecking=no'

[hq]
HQ-SRV ansible_host=192.168.100.2
HQ-CLI ansible_host=192.168.100.64
HQ-RTR ansible_host=192.168.100.1

[br]
BR-RTR ansible_host=192.168.200.1

[servers]
HQ-SRV
BR-SRV ansible_host=127.0.0.1 ansible_connection=local

[routers]
HQ-RTR
BR-RTR

[clients]
HQ-CLI
EOF
    
    # Создание ansible.cfg
    cat > $ANSIBLE_DIR/ansible.cfg << EOF
[defaults]
inventory = /etc/ansible/inventory
host_key_checking = False
deprecation_warnings = False
command_warnings = False
ansible_python_interpreter = /usr/bin/python3

[ssh_connection]
ssh_args = -o ControlMaster=auto -o ControlPersist=60s
pipelining = True
EOF
    
    # Создание примера playbook
    cat > $ANSIBLE_DIR/playbooks/ping_all.yml << EOF
---
- name: Проверка доступности всех хостов
  hosts: all
  gather_facts: no
  tasks:
    - name: Ping хостов
      ping:
      register: ping_result
    
    - name: Вывод результата
      debug:
        msg: "Host {{ inventory_hostname }} is reachable"
      when: ping_result is succeeded
EOF
    
    log "Ansible настроен"
    echo ""
    echo -e "${CYAN}Проверка инвентаря:${NC}"
    ansible-inventory --list
}

# 5. Настройка Chrony клиента
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
# Chrony client configuration for BR-SRV
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

# Главное меню
main_menu() {
    while true; do
        show_header
        echo "Выберите действие:"
        echo ""
        echo "1) Настроить Samba Domain Controller"
        echo "2) Импортировать пользователей из CSV"
        echo "3) Настроить Docker и MediaWiki"
        echo "4) Настроить Ansible"
        echo "5) Настроить Chrony клиент"
        echo "6) Выполнить полную настройку"
        echo "7) Выход"
        echo ""
        
        read -p "Ваш выбор (1-7): " choice
        
        case $choice in
            1) setup_samba_dc ;;
            2) import_users_csv ;;
            3) setup_docker_mediawiki ;;
            4) setup_ansible ;;
            5) setup_chrony_client ;;
            6) 
                setup_samba_dc
                import_users_csv
                setup_docker_mediawiki
                setup_ansible
                setup_chrony_client
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