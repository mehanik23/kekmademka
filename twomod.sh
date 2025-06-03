#!/bin/bash

# ВТОРОЙ МОДУЛЬ
# Скрипт для настройки системы

# Цвета для красивого вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Функция для отображения заголовка
show_header() {
    clear
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${GREEN}       ВТОРОЙ МОДУЛЬ${NC}"
    echo -e "${BLUE}=====================================${NC}"
    echo ""
}

# Функция настройки SSH сервера
setup_ssh_server() {
    show_header
    echo -e "${YELLOW}=== Настройка SSH сервера ===${NC}"
    echo ""
    
    # Проверка наличия SSH
    if ! command -v sshd &> /dev/null; then
        echo -e "${RED}SSH сервер не установлен${NC}"
        if [ "$EUID" -eq 0 ]; then
            read -p "Установить OpenSSH сервер? (y/n): " install_ssh
            if [ "$install_ssh" = "y" ]; then
                apt-get update && apt-get install -y openssh-server
            else
                return
            fi
        else
            echo "Для установки выполните: sudo apt-get install openssh-server"
            read -p "Нажмите Enter для продолжения..."
            return
        fi
    fi
    
    # Запрос параметров
    echo "Текущий порт SSH: $(grep -E "^Port|^#Port" /etc/ssh/sshd_config | head -1)"
    read -p "Введите порт SSH (по умолчанию 22): " ssh_port
    ssh_port=${ssh_port:-22}
    
    echo ""
    read -p "Максимальное количество попыток входа (по умолчанию 3): " max_auth_tries
    max_auth_tries=${max_auth_tries:-3}
    
    echo ""
    read -p "Создать пользователя для SSH? (y/n): " create_ssh_user
    if [ "$create_ssh_user" = "y" ]; then
        read -p "Имя пользователя: " ssh_username
        if [ "$EUID" -eq 0 ]; then
            if ! id "$ssh_username" &>/dev/null; then
                useradd -m -s /bin/bash $ssh_username
                echo "Установите пароль для $ssh_username:"
                passwd $ssh_username
            else
                echo -e "${YELLOW}Пользователь $ssh_username уже существует${NC}"
            fi
        fi
    fi
    
    echo ""
    read -p "Создать баннер SSH? (y/n): " create_banner
    if [ "$create_banner" = "y" ]; then
        banner_file="/etc/ssh/banner"
        cat << 'EOF' > /tmp/ssh_banner
*************************************************
*                                               *
*         Authorized access only                *
*                                               *
*************************************************
EOF
        
        if [ "$EUID" -eq 0 ]; then
            cp /tmp/ssh_banner $banner_file
            echo -e "${GREEN}Баннер создан в $banner_file${NC}"
        else
            echo -e "${YELLOW}Баннер сохранен в /tmp/ssh_banner${NC}"
            echo "Для установки выполните: sudo cp /tmp/ssh_banner $banner_file"
        fi
    fi
    
    # Создание конфигурации
    if [ "$EUID" -eq 0 ]; then
        # Резервная копия
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.$(date +%Y%m%d_%H%M%S)
        
        # Применение настроек
        sed -i "s/^#\?Port.*/Port $ssh_port/" /etc/ssh/sshd_config
        sed -i "s/^#\?MaxAuthTries.*/MaxAuthTries $max_auth_tries/" /etc/ssh/sshd_config
        
        if [ "$create_banner" = "y" ]; then
            sed -i "s|^#\?Banner.*|Banner $banner_file|" /etc/ssh/sshd_config
        fi
        
        echo -e "${GREEN}Конфигурация SSH обновлена${NC}"
        echo ""
        read -p "Перезапустить SSH сервис? (y/n): " restart_ssh
        if [ "$restart_ssh" = "y" ]; then
            systemctl restart sshd
            echo -e "${GREEN}SSH сервис перезапущен${NC}"
        fi
    else
        echo -e "${YELLOW}Для применения настроек требуются права root${NC}"
    fi
    
    echo ""
    read -p "Нажмите Enter для продолжения..."
}

# Функция расширенного управления пользователями
manage_users_advanced() {
    show_header
    echo -e "${YELLOW}=== Расширенное управление пользователями ===${NC}"
    echo ""
    
    echo "1) Создать пользователя"
    echo "2) Добавить пользователя в группу"
    echo "3) Настроить sudo для пользователя"
    echo "4) Создать группу с ограниченными правами"
    echo "5) Показать информацию о пользователе"
    echo "6) Назад"
    echo ""
    
    read -p "Выберите действие (1-6): " user_choice
    
    case $user_choice in
        1) # Создание пользователя
            read -p "Имя пользователя: " new_user
            read -p "Создать домашний каталог? (y/n): " create_home
            read -p "Оболочка (по умолчанию /bin/bash): " user_shell
            user_shell=${user_shell:-/bin/bash}
            
            if [ "$EUID" -eq 0 ]; then
                if [ "$create_home" = "y" ]; then
                    useradd -m -s $user_shell $new_user
                else
                    useradd -M -s $user_shell $new_user
                fi
                
                if [ $? -eq 0 ]; then
                    echo "Установите пароль для $new_user:"
                    passwd $new_user
                    echo -e "${GREEN}Пользователь $new_user создан${NC}"
                else
                    echo -e "${RED}Ошибка создания пользователя${NC}"
                fi
            else
                echo -e "${YELLOW}Команда для создания:${NC}"
                if [ "$create_home" = "y" ]; then
                    echo "sudo useradd -m -s $user_shell $new_user"
                else
                    echo "sudo useradd -M -s $user_shell $new_user"
                fi
            fi
            ;;
            
        2) # Добавление в группу
            read -p "Имя пользователя: " username
            read -p "Имя группы: " groupname
            
            if [ "$EUID" -eq 0 ]; then
                if ! getent group $groupname > /dev/null 2>&1; then
                    read -p "Группа $groupname не существует. Создать? (y/n): " create_group
                    if [ "$create_group" = "y" ]; then
                        groupadd $groupname
                    else
                        return
                    fi
                fi
                
                usermod -a -G $groupname $username
                echo -e "${GREEN}Пользователь $username добавлен в группу $groupname${NC}"
            else
                echo -e "${YELLOW}Команда для добавления:${NC}"
                echo "sudo usermod -a -G $groupname $username"
            fi
            ;;
            
        3) # Настройка sudo
            read -p "Имя пользователя: " username
            echo "Опции sudo:"
            echo "1) Полные права с запросом пароля"
            echo "2) Полные права БЕЗ запроса пароля"
            echo "3) Ограниченные команды"
            read -p "Выберите опцию (1-3): " sudo_option
            
            case $sudo_option in
                1)
                    sudo_line="$username ALL=(ALL:ALL) ALL"
                    ;;
                2)
                    sudo_line="$username ALL=(ALL:ALL) NOPASSWD: ALL"
                    ;;
                3)
                    read -p "Введите разрешенные команды (через запятую): " allowed_cmds
                    sudo_line="$username ALL=(ALL:ALL) NOPASSWD: $allowed_cmds"
                    ;;
                *)
                    sudo_line="$username ALL=(ALL:ALL) ALL"
                    ;;
            esac
            
            if [ "$EUID" -eq 0 ]; then
                echo "$sudo_line" > /etc/sudoers.d/$username
                chmod 440 /etc/sudoers.d/$username
                echo -e "${GREEN}Права sudo настроены для $username${NC}"
            else
                echo -e "${YELLOW}Для настройки sudo выполните:${NC}"
                echo "echo '$sudo_line' | sudo tee /etc/sudoers.d/$username"
                echo "sudo chmod 440 /etc/sudoers.d/$username"
            fi
            ;;
            
        4) # Создание группы с ограниченными правами
            read -p "Имя группы: " groupname
            read -p "Разрешенные команды (через запятую): " allowed_cmds
            
            if [ "$EUID" -eq 0 ]; then
                groupadd $groupname 2>/dev/null
                echo "%$groupname ALL=(ALL:ALL) NOPASSWD: $allowed_cmds" > /etc/sudoers.d/group_$groupname
                chmod 440 /etc/sudoers.d/group_$groupname
                echo -e "${GREEN}Группа $groupname создана с ограниченными правами${NC}"
            else
                echo -e "${YELLOW}Команды для создания:${NC}"
                echo "sudo groupadd $groupname"
                echo "echo '%$groupname ALL=(ALL:ALL) NOPASSWD: $allowed_cmds' | sudo tee /etc/sudoers.d/group_$groupname"
            fi
            ;;
            
        5) # Информация о пользователе
            read -p "Имя пользователя: " username
            if id "$username" &>/dev/null; then
                echo ""
                echo -e "${CYAN}=== Информация о пользователе $username ===${NC}"
                id $username
                echo ""
                echo "Группы:"
                groups $username
                echo ""
                echo "Последний вход:"
                lastlog -u $username
            else
                echo -e "${RED}Пользователь $username не найден${NC}"
            fi
            ;;
            
        6) return ;;
    esac
    
    echo ""
    read -p "Нажмите Enter для продолжения..."
    manage_users_advanced
}

# Функция настройки Samba
setup_samba() {
    show_header
    echo -e "${YELLOW}=== Настройка Samba сервера ===${NC}"
    echo ""
    
    # Проверка установки Samba
    if ! command -v smbd &> /dev/null; then
        echo -e "${RED}Samba не установлена${NC}"
        if [ "$EUID" -eq 0 ]; then
            read -p "Установить Samba? (y/n): " install_samba
            if [ "$install_samba" = "y" ]; then
                apt-get update && apt-get install -y samba samba-common-bin
            else
                return
            fi
        else
            echo "Для установки выполните: sudo apt-get install samba samba-common-bin"
            read -p "Нажмите Enter для продолжения..."
            return
        fi
    fi
    
    echo "Выберите действие:"
    echo "1) Создать общую папку"
    echo "2) Создать приватную папку"
    echo "3) Добавить пользователя Samba"
    echo "4) Показать текущую конфигурацию"
    echo "5) Назад"
    echo ""
    
    read -p "Ваш выбор (1-5): " samba_choice
    
    case $samba_choice in
        1) # Общая папка
            read -p "Путь к папке: " share_path
            read -p "Имя общего ресурса: " share_name
            read -p "Описание: " share_comment
            
            if [ "$EUID" -eq 0 ]; then
                # Создание папки
                mkdir -p "$share_path"
                chmod 777 "$share_path"
                
                # Добавление в конфигурацию
                cat << EOF >> /etc/samba/smb.conf

[$share_name]
   comment = $share_comment
   path = $share_path
   browseable = yes
   read only = no
   guest ok = yes
   create mask = 0777
   directory mask = 0777
EOF
                
                # Перезапуск Samba
                systemctl restart smbd nmbd
                echo -e "${GREEN}Общая папка создана${NC}"
            else
                echo -e "${YELLOW}Требуются права root${NC}"
            fi
            ;;
            
        2) # Приватная папка
            read -p "Путь к папке: " share_path
            read -p "Имя общего ресурса: " share_name
            read -p "Описание: " share_comment
            read -p "Группа с доступом: " share_group
            
            if [ "$EUID" -eq 0 ]; then
                # Создание папки
                mkdir -p "$share_path"
                chmod 770 "$share_path"
                
                # Создание группы если не существует
                groupadd $share_group 2>/dev/null
                chgrp $share_group "$share_path"
                
                # Добавление в конфигурацию
                cat << EOF >> /etc/samba/smb.conf

[$share_name]
   comment = $share_comment
   path = $share_path
   browseable = yes
   read only = no
   guest ok = no
   valid users = @$share_group
   create mask = 0770
   directory mask = 0770
EOF
                
                # Перезапуск Samba
                systemctl restart smbd nmbd
                echo -e "${GREEN}Приватная папка создана${NC}"
            else
                echo -e "${YELLOW}Требуются права root${NC}"
            fi
            ;;
            
        3) # Добавление пользователя
            read -p "Имя пользователя: " samba_user
            
            if [ "$EUID" -eq 0 ]; then
                if id "$samba_user" &>/dev/null; then
                    echo "Установите пароль Samba для $samba_user:"
                    smbpasswd -a $samba_user
                    smbpasswd -e $samba_user
                    echo -e "${GREEN}Пользователь $samba_user добавлен в Samba${NC}"
                else
                    echo -e "${RED}Пользователь $samba_user не существует в системе${NC}"
                fi
            else
                echo -e "${YELLOW}Команда для добавления:${NC}"
                echo "sudo smbpasswd -a $samba_user"
            fi
            ;;
            
        4) # Показать конфигурацию
            echo -e "${CYAN}=== Текущие общие ресурсы ===${NC}"
            if [ "$EUID" -eq 0 ]; then
                smbstatus --shares
            else
                echo -e "${YELLOW}Для просмотра выполните: sudo smbstatus --shares${NC}"
            fi
            ;;
            
        5) return ;;
    esac
    
    echo ""
    read -p "Нажмите Enter для продолжения..."
    setup_samba
}

# Функция настройки Chrony сервера
setup_chrony_server() {
    show_header
    echo -e "${YELLOW}=== Настройка Chrony сервера ===${NC}"
    echo ""
    
    # Проверка установки Chrony
    if ! command -v chronyd &> /dev/null; then
        echo -e "${RED}Chrony не установлен${NC}"
        if [ "$EUID" -eq 0 ]; then
            read -p "Установить Chrony? (y/n): " install_chrony
            if [ "$install_chrony" = "y" ]; then
                apt-get update && apt-get install -y chrony
            else
                return
            fi
        else
            echo "Для установки выполните: sudo apt-get install chrony"
            read -p "Нажмите Enter для продолжения..."
            return
        fi
    fi
    
    echo "Настройка Chrony сервера времени"
    echo ""
    
    # Выбор источников времени
    echo "Выберите источники времени:"
    echo "1) Российские NTP серверы"
    echo "2) Международные NTP серверы"
    echo "3) Локальные часы (автономный режим)"
    echo "4) Пользовательские серверы"
    
    read -p "Ваш выбор (1-4): " time_source
    
    case $time_source in
        1) 
            ntp_servers="server 0.ru.pool.ntp.org iburst
server 1.ru.pool.ntp.org iburst
server 2.ru.pool.ntp.org iburst
server 3.ru.pool.ntp.org iburst"
            ;;
        2)
            ntp_servers="server 0.pool.ntp.org iburst
server 1.pool.ntp.org iburst
server 2.pool.ntp.org iburst
server 3.pool.ntp.org iburst"
            ;;
        3)
            ntp_servers="local stratum 10"
            ;;
        4)
            read -p "Введите NTP серверы (через пробел): " custom_servers
            ntp_servers=""
            for server in $custom_servers; do
                ntp_servers="${ntp_servers}server $server iburst\n"
            done
            ;;
    esac
    
    # Настройка разрешенных клиентов
    read -p "Разрешить доступ локальной сети? (y/n): " allow_local
    if [ "$allow_local" = "y" ]; then
        read -p "Введите подсеть (например, 192.168.1.0/24): " allowed_network
        allow_config="allow $allowed_network"
    else
        allow_config="# allow 192.168.0.0/16"
    fi
    
    if [ "$EUID" -eq 0 ]; then
        # Резервная копия
        cp /etc/chrony/chrony.conf /etc/chrony/chrony.conf.backup.$(date +%Y%m%d_%H%M%S)
        
        # Создание новой конфигурации
        cat << EOF > /etc/chrony/chrony.conf
# Chrony server configuration
# Generated by setup script

# Источники времени
$ntp_servers

# Файл дрейфа
driftfile /var/lib/chrony/drift

# Разрешить клиентам
$allow_config

# Логирование
log tracking measurements statistics

# Директория логов
logdir /var/log/chrony

# Разрешить большие корректировки времени
makestep 1.0 3

# Ключи для аутентификации
keyfile /etc/chrony/chrony.keys

# Отключить управление через chronyc для внешних хостов
bindcmdaddress 127.0.0.1
bindcmdaddress ::1

# Режим RTC
rtcsync
EOF
        
        # Перезапуск службы
        systemctl restart chrony
        echo -e "${GREEN}Chrony сервер настроен${NC}"
        
        # Проверка статуса
        echo ""
        echo -e "${CYAN}Статус Chrony:${NC}"
        chronyc sources
    else
        echo -e "${YELLOW}Конфигурация сохранена в /tmp/chrony.conf${NC}"
        echo "Для применения выполните с правами root"
    fi
    
    echo ""
    read -p "Нажмите Enter для продолжения..."
}

# Функция настройки Chrony клиента
setup_chrony_client() {
    show_header
    echo -e "${YELLOW}=== Настройка Chrony клиента ===${NC}"
    echo ""
    
    # Проверка установки Chrony
    if ! command -v chronyd &> /dev/null; then
        echo -e "${RED}Chrony не установлен${NC}"
        if [ "$EUID" -eq 0 ]; then
            read -p "Установить Chrony? (y/n): " install_chrony
            if [ "$install_chrony" = "y" ]; then
                apt-get update && apt-get install -y chrony
            else
                return
            fi
        else
            echo "Для установки выполните: sudo apt-get install chrony"
            read -p "Нажмите Enter для продолжения..."
            return
        fi
    fi
    
    echo "Настройка Chrony клиента"
    echo ""
    
    read -p "Введите IP адрес или имя Chrony сервера: " chrony_server
    read -p "Добавить резервные серверы? (y/n): " add_backup
    
    ntp_config="server $chrony_server iburst prefer"
    
    if [ "$add_backup" = "y" ]; then
        read -p "Введите резервные серверы (через пробел): " backup_servers
        for server in $backup_servers; do
            ntp_config="${ntp_config}\nserver $server iburst"
        done
    fi
    
    if [ "$EUID" -eq 0 ]; then
        # Резервная копия
        cp /etc/chrony/chrony.conf /etc/chrony/chrony.conf.backup.$(date +%Y%m%d_%H%M%S)
        
        # Создание конфигурации клиента
        cat << EOF > /etc/chrony/chrony.conf
# Chrony client configuration
# Generated by setup script

# NTP серверы
$ntp_config

# Файл дрейфа
driftfile /var/lib/chrony/drift

# Логирование
log tracking measurements statistics

# Директория логов
logdir /var/log/chrony

# Разрешить большие корректировки времени при запуске
makestep 1.0 3

# Ключи для аутентификации
keyfile /etc/chrony/chrony.keys

# Отключить сервер NTP (только клиент)
port 0

# Режим RTC
rtcsync
EOF
        
        # Перезапуск службы
        systemctl restart chrony
        echo -e "${GREEN}Chrony клиент настроен${NC}"
        
        # Проверка синхронизации
        echo ""
        echo -e "${CYAN}Проверка синхронизации:${NC}"
        sleep 2
        chronyc tracking
    else
        echo -e "${YELLOW}Требуются права root для настройки${NC}"
    fi
    
    echo ""
    read -p "Нажмите Enter для продолжения..."
}

# Функция настройки Ansible сервера
setup_ansible_server() {
    show_header
    echo -e "${YELLOW}=== Настройка Ansible сервера ===${NC}"
    echo ""
    
    # Проверка установки Ansible
    if ! command -v ansible &> /dev/null; then
        echo -e "${RED}Ansible не установлен${NC}"
        if [ "$EUID" -eq 0 ]; then
            read -p "Установить Ansible? (y/n): " install_ansible
            if [ "$install_ansible" = "y" ]; then
                apt-get update
                apt-get install -y python3-pip
                pip3 install ansible
            else
                return
            fi
        else
            echo "Для установки выполните:"
            echo "sudo apt-get update && sudo apt-get install -y python3-pip"
            echo "sudo pip3 install ansible"
            read -p "Нажмите Enter для продолжения..."
            return
        fi
    fi
    
    # Выбор директории
    read -p "Директория для Ansible (по умолчанию /etc/ansible): " ansible_dir
    ansible_dir=${ansible_dir:-/etc/ansible}
    
    if [ "$EUID" -eq 0 ]; then
        # Создание структуры директорий
        mkdir -p $ansible_dir/{playbooks,roles,group_vars,host_vars}
        
        # Создание ansible.cfg
        cat << EOF > $ansible_dir/ansible.cfg
[defaults]
inventory = $ansible_dir/inventory
host_key_checking = False
remote_user = ansible
private_key_file = ~/.ssh/id_rsa
roles_path = $ansible_dir/roles
log_path = /var/log/ansible.log

[inventory]
enable_plugins = host_list, script, yaml, ini

[privilege_escalation]
become = True
become_method = sudo
become_user = root
become_ask_pass = False

[ssh_connection]
ssh_args = -o ControlMaster=auto -o ControlPersist=60s
pipelining = True
EOF
        
        # Создание inventory файла
        cat << EOF > $ansible_dir/inventory
# Ansible Inventory File
# Группы хостов

[all:vars]
ansible_python_interpreter=/usr/bin/python3

# Пример группы веб-серверов
[webservers]
# web1 ansible_host=192.168.1.10
# web2 ansible_host=192.168.1.11

# Пример группы баз данных
[databases]
# db1 ansible_host=192.168.1.20
# db2 ansible_host=192.168.1.21

# Пример локального хоста
[local]
localhost ansible_connection=local
EOF
        
        # Создание примера playbook
        cat << EOF > $ansible_dir/playbooks/site.yml
---
# Основной playbook
- name: Базовая настройка серверов
  hosts: all
  become: yes
  tasks:
    - name: Обновление apt кэша
      apt:
        update_cache: yes
        cache_valid_time: 3600
      when: ansible_os_family == "Debian"
    
    - name: Установка базовых пакетов
      apt:
        name:
          - vim
          - htop
          - git
          - curl
        state: present
      when: ansible_os_family == "Debian"
    
    - name: Создание пользователя ansible
      user:
        name: ansible
        shell: /bin/bash
        groups: sudo
        append: yes
        create_home: yes
EOF
        
        echo -e "${GREEN}Ansible сервер настроен в $ansible_dir${NC}"
        
        # Создание SSH ключа для ansible
        read -p "Создать SSH ключ для Ansible? (y/n): " create_key
        if [ "$create_key" = "y" ]; then
            if [ ! -f ~/.ssh/id_rsa ]; then
                ssh-keygen -t rsa -b 2048 -f ~/.ssh/id_rsa -N ""
                echo -e "${GREEN}SSH ключ создан${NC}"
            else
                echo -e "${YELLOW}SSH ключ уже существует${NC}"
            fi
        fi
        
        echo ""
        echo -e "${CYAN}=== Инструкция по добавлению хостов ===${NC}"
        echo "1. Отредактируйте файл $ansible_dir/inventory"
        echo "2. Добавьте хосты в соответствующие группы"
        echo "3. Скопируйте SSH ключ на целевые хосты:"
        echo "   ssh-copy-id ansible@<ip_адрес_хоста>"
        echo ""
        echo "Пример команд Ansible:"
        echo "- Проверка связи: ansible all -m ping"
        echo "- Выполнение playbook: ansible-playbook $ansible_dir/playbooks/site.yml"
        
    else
        echo -e "${YELLOW}Требуются права root для настройки${NC}"
    fi
    
    echo ""
    read -p "Нажмите Enter для продолжения..."
}

# Функция настройки Ansible клиента
setup_ansible_client() {
    show_header
    echo -e "${YELLOW}=== Настройка Ansible клиента ===${NC}"
    echo ""
    
    echo "Для работы с Ansible клиентом требуется:"
    echo "1. Python установлен на клиенте"
    echo "2. SSH доступ с сервера Ansible"
    echo "3. Пользователь с правами sudo (опционально)"
    echo ""
    
    if [ "$EUID" -eq 0 ]; then
        # Установка Python если отсутствует
        if ! command -v python3 &> /dev/null; then
            read -p "Python3 не найден. Установить? (y/n): " install_python
            if [ "$install_python" = "y" ]; then
                apt-get update && apt-get install -y python3 python3-pip
            fi
        fi
        
        # Создание пользователя ansible
        read -p "Создать пользователя 'ansible'? (y/n): " create_ansible_user
        if [ "$create_ansible_user" = "y" ]; then
            if ! id "ansible" &>/dev/null; then
                useradd -m -s /bin/bash ansible
                echo -e "${GREEN}Пользователь ansible создан${NC}"
                
                # Настройка sudo без пароля
                read -p "Настроить sudo без пароля для ansible? (y/n): " setup_sudo
                if [ "$setup_sudo" = "y" ]; then
                    echo "ansible ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/ansible
                    chmod 440 /etc/sudoers.d/ansible
                    echo -e "${GREEN}Sudo настроен для пользователя ansible${NC}"
                fi
                
                # Создание .ssh директории
                mkdir -p /home/ansible/.ssh
                chmod 700 /home/ansible/.ssh
                chown -R ansible:ansible /home/ansible/.ssh
                
                echo ""
                echo -e "${CYAN}=== Дальнейшие шаги ===${NC}"
                echo "1. На сервере Ansible выполните:"
                echo "   ssh-copy-id ansible@$(hostname -I | awk '{print $1}')"
                echo "2. Добавьте этот хост в inventory файл на сервере Ansible"
                echo ""
            else
                echo -e "${YELLOW}Пользователь ansible уже существует${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}Для настройки клиента требуются права root${NC}"
        echo ""
        echo "Выполните следующие команды с правами root:"
        echo "1. sudo useradd -m -s /bin/bash ansible"
        echo "2. echo 'ansible ALL=(ALL:ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/ansible"
        echo "3. sudo chmod 440 /etc/sudoers.d/ansible"
    fi
    
    echo ""
    read -p "Нажмите Enter для продолжения..."
}

# Функция настройки GRE туннеля (оригинальная)
setup_gre_tunnel() {
    show_header
    echo -e "${YELLOW}=== Настройка GRE туннеля ===${NC}"
    echo ""
    
    # Запрос параметров
    read -p "Введите локальный IP адрес: " local_ip
    read -p "Введите удаленный IP адрес: " remote_ip
    read -p "Введите название туннеля (например, gre1): " tunnel_name
    read -p "Введите IP адрес для туннеля (например, 10.0.0.1/30): " tunnel_ip
    
    echo ""
    echo -e "${GREEN}Создание GRE туннеля...${NC}"
    
    # Создание туннеля
    cat << EOF > /tmp/gre_setup.sh
# Загрузка модуля GRE
modprobe ip_gre

# Создание туннеля
ip tunnel add $tunnel_name mode gre remote $remote_ip local $local_ip ttl 255

# Поднятие интерфейса
ip link set $tunnel_name up

# Назначение IP адреса
ip addr add $tunnel_ip dev $tunnel_name

# Добавление в автозагрузку
echo "ip tunnel add $tunnel_name mode gre remote $remote_ip local $local_ip ttl 255" >> /etc/rc.local
echo "ip link set $tunnel_name up" >> /etc/rc.local
echo "ip addr add $tunnel_ip dev $tunnel_name" >> /etc/rc.local
EOF
    
    # Выполнение настройки
    if [ "$EUID" -ne 0 ]; then 
        echo -e "${RED}Ошибка: Требуются права root для настройки туннеля${NC}"
        echo "Скрипт сохранен в /tmp/gre_setup.sh"
    else
        bash /tmp/gre_setup.sh
        echo -e "${GREEN}GRE туннель настроен успешно!${NC}"
    fi
    
    echo ""
    read -p "Нажмите Enter для продолжения..."
}

# Функция настройки временной зоны (оригинальная)
setup_timezone() {
    show_header
    echo -e "${YELLOW}=== Настройка временной зоны ===${NC}"
    echo ""
    
    echo "Текущая временная зона:"
    if command -v timedatectl &> /dev/null; then
        timedatectl | grep "Time zone" || echo "Не удалось определить"
    else
        echo "timedatectl не найден"
    fi
    echo ""
    
    echo "Доступные варианты:"
    echo "1) Asia/Krasnoyarsk (Красноярск)"
    echo "2) Europe/Moscow (Москва)"
    echo "3) Asia/Novosibirsk (Новосибирск)"
    echo "4) Asia/Yekaterinburg (Екатеринбург)"
    echo "5) Asia/Vladivostok (Владивосток)"
    echo "6) Другая"
    
    read -p "Выберите вариант (1-6): " tz_choice
    
    case $tz_choice in
        1) timezone="Asia/Krasnoyarsk";;
        2) timezone="Europe/Moscow";;
        3) timezone="Asia/Novosibirsk";;
        4) timezone="Asia/Yekaterinburg";;
        5) timezone="Asia/Vladivostok";;
        6) read -p "Введите временную зону: " timezone;;
        *) timezone="Asia/Krasnoyarsk";;
    esac
    
    if [ "$EUID" -eq 0 ]; then
        if command -v timedatectl &> /dev/null; then
            timedatectl set-timezone $timezone
            echo -e "${GREEN}Временная зона установлена: $timezone${NC}"
        else
            # Альтернативный метод
            ln -sf /usr/share/zoneinfo/$timezone /etc/localtime
            echo $timezone > /etc/timezone
            echo -e "${GREEN}Временная зона установлена: $timezone${NC}"
        fi
    else
        echo -e "${YELLOW}Команда для установки временной зоны:${NC}"
        echo "sudo timedatectl set-timezone $timezone"
    fi
    
    echo ""
    read -p "Нажмите Enter для продолжения..."
}

# Функция настройки SELinux (оригинальная)
setup_selinux() {
    show_header
    echo -e "${YELLOW}=== Настройка SELinux ===${NC}"
    echo ""
    
    # Проверка наличия SELinux
    echo "Проверка состояния SELinux..."
    
    if ! command -v getenforce &> /dev/null; then
        echo -e "${YELLOW}SELinux не установлен в системе${NC}"
        echo ""
        
        if [ "$EUID" -eq 0 ]; then
            read -p "Установить SELinux? (y/n): " install_selinux
            
            if [ "$install_selinux" = "y" ]; then
                echo -e "${GREEN}Установка SELinux...${NC}"
                
                # Определение дистрибутива
                if [ -f /etc/redhat-release ]; then
                    # RHEL/CentOS/Fedora
                    yum install -y selinux-policy selinux-policy-targeted policycoreutils
                elif [ -f /etc/debian_version ]; then
                    # Debian/Ubuntu
                    apt-get update
                    apt-get install -y selinux-basics selinux-policy-default auditd
                    selinux-activate
                else
                    echo -e "${RED}Неподдерживаемый дистрибутив${NC}"
                fi
                
                echo -e "${YELLOW}Требуется перезагрузка для активации SELinux${NC}"
            fi
        else
            echo -e "${YELLOW}Для установки SELinux выполните скрипт с правами root${NC}"
        fi
    else
        echo "Текущий статус SELinux: $(getenforce)"
    fi
    
    echo ""
    echo -e "${PURPLE}=== Описание режимов SELinux ===${NC}"
    echo ""
    echo -e "${GREEN}1) Enforcing (Принудительный)${NC}"
    echo "   - SELinux активен и блокирует запрещенные действия"
    echo "   - Все нарушения политики безопасности блокируются и логируются"
    echo "   - Рекомендуется для production-серверов"
    echo ""
    echo -e "${YELLOW}2) Permissive (Разрешающий)${NC}"
    echo "   - SELinux активен, но НЕ блокирует действия"
    echo "   - Только логирует нарушения политики безопасности"
    echo "   - Используется для отладки и тестирования"
    echo ""
    echo -e "${RED}3) Disabled (Отключен)${NC}"
    echo "   - SELinux полностью отключен"
    echo "   - Никакой защиты и логирования не происходит"
    echo "   - НЕ рекомендуется для production-серверов"
    echo ""
    
    if command -v getenforce &> /dev/null; then
        echo "Выберите режим SELinux:"
        echo "1) Enforcing"
        echo "2) Permissive"
        echo "3) Disabled"
        echo "4) Не менять"
        
        read -p "Ваш выбор (1-4): " selinux_choice
        
        case $selinux_choice in
            1) selinux_mode="enforcing";;
            2) selinux_mode="permissive";;
            3) selinux_mode="disabled";;
            4) 
                echo "Настройки SELinux не изменены"
                read -p "Нажмите Enter для продолжения..."
                return
                ;;
            *) selinux_mode="enforcing";;
        esac
        
        if [ "$EUID" -eq 0 ]; then
            # Временное изменение
            case $selinux_mode in
                "enforcing") 
                    setenforce 1 2>/dev/null || echo "Невозможно установить enforcing (возможно, SELinux отключен)"
                    ;;
                "permissive") 
                    setenforce 0 2>/dev/null || echo "Невозможно установить permissive (возможно, SELinux отключен)"
                    ;;
            esac
            
            # Постоянное изменение
            if [ -f /etc/selinux/config ]; then
                sed -i "s/^SELINUX=.*/SELINUX=$selinux_mode/" /etc/selinux/config
                echo -e "${GREEN}SELinux настроен в режим: $selinux_mode${NC}"
                
                if [ "$selinux_mode" = "disabled" ]; then
                    echo -e "${YELLOW}Требуется перезагрузка для полного отключения SELinux${NC}"
                fi
            else
                echo -e "${RED}Файл конфигурации SELinux не найден${NC}"
            fi
        else
            echo -e "${YELLOW}Требуются права root для изменения SELinux${NC}"
            echo "Команды для изменения:"
            echo "sudo setenforce 0/1  # временное изменение"
            echo "sudo sed -i 's/^SELINUX=.*/SELINUX=$selinux_mode/' /etc/selinux/config  # постоянное"
        fi
    fi
    
    echo ""
    read -p "Нажмите Enter для продолжения..."
}

# Функция настройки пользователей (оригинальная)
setup_users() {
    show_header
    echo -e "${YELLOW}=== Юзеры+ ===${NC}"
    echo ""
    
    # Создание группы hq
    echo -e "${GREEN}1. Создание группы 'hq'${NC}"
    
    if [ "$EUID" -eq 0 ]; then
        if ! getent group hq > /dev/null 2>&1; then
            groupadd hq
            echo -e "${GREEN}Группа 'hq' создана${NC}"
        else
            echo -e "${YELLOW}Группа 'hq' уже существует${NC}"
        fi
    else
        echo -e "${YELLOW}Команда для создания группы:${NC}"
        echo "sudo groupadd hq"
    fi
    
    echo ""
    echo -e "${GREEN}2. Добавление пользователей в группу 'hq'${NC}"
    read -p "Введите имена пользователей через пробел: " users_list
    
    for user in $users_list; do
        if [ "$EUID" -eq 0 ]; then
            if id "$user" &>/dev/null; then
                usermod -a -G hq $user
                echo -e "${GREEN}Пользователь $user добавлен в группу hq${NC}"
            else
                echo -e "${RED}Пользователь $user не существует${NC}"
            fi
        else
            echo -e "${YELLOW}Команда для добавления $user в группу:${NC}"
            echo "sudo usermod -a -G hq $user"
        fi
    done
    
    echo ""
    echo -e "${GREEN}3. Настройка ограниченных прав${NC}"
    echo "Создание ограниченной оболочки для пользователей..."
    echo "Разрешенные команды: grep, cat, id"
    echo ""
    
    # Создание скрипта ограниченной оболочки
    restricted_shell="/usr/local/bin/restricted_shell.sh"
    
    cat << 'EOF' > /tmp/restricted_shell.sh
#!/bin/bash
# Ограниченная оболочка

# Разрешенные команды
ALLOWED_COMMANDS="grep cat id"

echo "Добро пожаловать в ограниченную оболочку"
echo "Доступные команды: $ALLOWED_COMMANDS"
echo "Для выхода введите 'exit'"
echo ""

while true; do
    read -p "$ " cmd args
    
    case $cmd in
        exit|quit)
            echo "До свидания!"
            exit 0
            ;;
        grep|cat|id)
            $cmd $args
            ;;
        "")
            continue
            ;;
        *)
            echo "Команда '$cmd' не разрешена"
            echo "Доступные команды: $ALLOWED_COMMANDS"
            ;;
    esac
done
EOF
    
    if [ "$EUID" -eq 0 ]; then
        # Копирование и настройка прав
        cp /tmp/restricted_shell.sh $restricted_shell
        chmod 755 $restricted_shell
        
        echo ""
        read -p "Применить ограниченную оболочку к пользователям? (y/n): " apply_restricted
        
        if [ "$apply_restricted" = "y" ]; then
            read -p "Введите имена пользователей для ограничения (через пробел): " restricted_users
            
            for user in $restricted_users; do
                if id "$user" &>/dev/null; then
                    usermod -s $restricted_shell $user
                    echo -e "${GREEN}Ограниченная оболочка применена к $user${NC}"
                else
                    echo -e "${RED}Пользователь $user не существует${NC}"
                fi
            done
        fi
    else
        echo -e "${YELLOW}Скрипт ограниченной оболочки сохранен в /tmp/restricted_shell.sh${NC}"
        echo "Для установки выполните с правами root:"
        echo "sudo cp /tmp/restricted_shell.sh $restricted_shell"
        echo "sudo chmod 755 $restricted_shell"
        echo "sudo usermod -s $restricted_shell username"
    fi
    
    echo ""
    read -p "Нажмите Enter для продолжения..."
}

# Главное меню
main_menu() {
    while true; do
        show_header
        echo "Выберите действие:"
        echo ""
        echo "1) Настройка GRE туннеля"
        echo "2) Настройка временной зоны"
        echo "3) Настройка SELinux"
        echo "4) Юзеры+ (базовые)"
        echo "5) Настройка SSH сервера"
        echo "6) Управление пользователями (расширенное)"
        echo "7) Настройка Samba"
        echo "8) Настройка Chrony сервера"
        echo "9) Настройка Chrony клиента"
        echo "10) Настройка Ansible сервера"
        echo "11) Настройка Ansible клиента"
        echo "12) Выход"
        echo ""
        
        read -p "Ваш выбор (1-12): " choice
        
        case $choice in
            1) setup_gre_tunnel;;
            2) setup_timezone;;
            3) setup_selinux;;
            4) setup_users;;
            5) setup_ssh_server;;
            6) manage_users_advanced;;
            7) setup_samba;;
            8) setup_chrony_server;;
            9) setup_chrony_client;;
            10) setup_ansible_server;;
            11) setup_ansible_client;;
            12) 
                echo -e "${GREEN}До свидания!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Неверный выбор!${NC}"
                sleep 1
                ;;
        esac
    done
}

# Проверка прав
if [ "$EUID" -ne 0 ]; then 
    echo -e "${YELLOW}Внимание: Скрипт запущен без прав root.${NC}"
    echo -e "${YELLOW}Некоторые функции будут недоступны.${NC}"
    echo ""
    read -p "Продолжить? (y/n): " continue_choice
    if [ "$continue_choice" != "y" ]; then
        exit 0
    fi
fi

# Запуск главного меню
main_menu