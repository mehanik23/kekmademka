#!/bin/bash

# Скрипт настройки HQ-SRV
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
    echo -e "${GREEN}    Настройка HQ-SRV${NC}"
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

# 1. Настройка NFS сервера (вместо RAID)
setup_nfs_server() {
    show_header
    echo -e "${YELLOW}=== Настройка NFS сервера ===${NC}"
    echo ""
    
    # Установка NFS
    log "Установка NFS сервера..."
    apt-get update
    apt-get install -y nfs-kernel-server nfs-common
    
    # Создание директории для NFS
    log "Создание директории для NFS..."
    mkdir -p /raid5/nfs
    chmod 777 /raid5/nfs
    
    # Настройка экспорта
    log "Настройка экспорта NFS..."
    cat > /etc/exports << EOF
# NFS exports for HQ network
/raid5/nfs 192.168.100.0/24(rw,sync,no_subtree_check,no_root_squash)
EOF
    
    # Применение настроек
    exportfs -ra
    
    # Запуск и включение NFS
    systemctl restart nfs-kernel-server
    systemctl enable nfs-kernel-server
    
    # Настройка firewall (если установлен)
    if command -v ufw &> /dev/null; then
        ufw allow from 192.168.100.0/24 to any port nfs
        ufw allow 111/tcp
        ufw allow 111/udp
        ufw allow 2049/tcp
        ufw allow 2049/udp
    fi
    
    log "NFS сервер настроен"
    echo ""
    echo -e "${CYAN}Параметры NFS сервера:${NC}"
    echo "Экспортируемая директория: /raid5/nfs"
    echo "Доступ: 192.168.100.0/24 (rw,sync,no_subtree_check,no_root_squash)"
    echo "Протокол: NFSv4"
    echo ""
    
    # Проверка экспортов
    echo -e "${CYAN}Текущие экспорты:${NC}"
    showmount -e localhost
}

# 2. Настройка Apache и Moodle
setup_moodle() {
    show_header
    echo -e "${YELLOW}=== Настройка Apache и Moodle ===${NC}"
    echo ""
    
    # Установка Apache и PHP
    log "Установка Apache, PHP и зависимостей..."
    apt-get update
    apt-get install -y apache2 \
        php libapache2-mod-php \
        php-mysql php-xml php-mbstring php-curl \
        php-zip php-gd php-intl php-xmlrpc php-soap \
        mariadb-server mariadb-client
    
    # Настройка MySQL для Moodle
    log "Настройка базы данных для Moodle..."
    mysql -e "CREATE DATABASE IF NOT EXISTS moodle DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    mysql -e "CREATE USER IF NOT EXISTS 'moodleuser'@'localhost' IDENTIFIED BY 'MoodleP@ss123';"
    mysql -e "GRANT ALL PRIVILEGES ON moodle.* TO 'moodleuser'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"
    
    # Создание директории для Moodle
    log "Подготовка директории для Moodle..."
    mkdir -p /var/www/html/moodle
    mkdir -p /var/moodledata
    chown -R www-data:www-data /var/moodledata
    chmod 755 /var/moodledata
    
    # Создание заглушки для Moodle
    cat > /var/www/html/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Moodle - HQ-SRV</title>
    <meta charset="UTF-8">
    <style>
        body {
            font-family: Arial, sans-serif;
            background-color: #f4f4f4;
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
            margin: 0;
        }
        .container {
            text-align: center;
            background: white;
            padding: 40px;
            border-radius: 10px;
            box-shadow: 0 0 10px rgba(0,0,0,0.1);
        }
        h1 { color: #ff7043; }
        p { color: #666; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Moodle - HQ-SRV</h1>
        <p>Сервис Moodle на сервере HQ-SRV</p>
        <p>IP: 192.168.100.2</p>
        <p>Порт: 80</p>
    </div>
</body>
</html>
EOF
    
    # Настройка Apache
    log "Настройка Apache..."
    a2enmod rewrite
    
    # Настройка виртуального хоста
    cat > /etc/apache2/sites-available/moodle.conf << EOF
<VirtualHost *:80>
    ServerAdmin admin@au-team.irpo
    DocumentRoot /var/www/html
    ServerName moodle.au-team.irpo
    
    <Directory /var/www/html>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    
    ErrorLog \${APACHE_LOG_DIR}/moodle-error.log
    CustomLog \${APACHE_LOG_DIR}/moodle-access.log combined
</VirtualHost>
EOF
    
    # Активация сайта
    a2dissite 000-default
    a2ensite moodle
    
    # Перезапуск Apache
    systemctl restart apache2
    systemctl enable apache2
    
    log "Apache и заглушка Moodle настроены"
    echo ""
    echo -e "${CYAN}Информация о Moodle:${NC}"
    echo "URL: http://moodle.au-team.irpo или http://192.168.100.2"
    echo "База данных: moodle"
    echo "Пользователь БД: moodleuser"
    echo "Пароль БД: MoodleP@ss123"
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
# Chrony client configuration for HQ-SRV
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

# 4. Настройка портов для NAT (информационная функция)
show_nat_info() {
    show_header
    echo -e "${YELLOW}=== Информация о настройке NAT ===${NC}"
    echo ""
    
    echo -e "${CYAN}На маршрутизаторе HQ-RTR необходимо настроить:${NC}"
    echo "1. Проброс порта 80 -> 192.168.100.2:80 (Moodle)"
    echo "2. Проброс порта 2024 -> 192.168.100.2:2024"
    echo ""
    echo -e "${YELLOW}Пример команд для iptables на HQ-RTR:${NC}"
    echo "iptables -t nat -A PREROUTING -p tcp --dport 80 -j DNAT --to-destination 192.168.100.2:80"
    echo "iptables -t nat -A PREROUTING -p tcp --dport 2024 -j DNAT --to-destination 192.168.100.2:2024"
    echo "iptables -t nat -A POSTROUTING -j MASQUERADE"
    echo ""
    echo -e "${YELLOW}Для сохранения правил:${NC}"
    echo "iptables-save > /etc/iptables/rules.v4"
}

# 5. Создание тестовых файлов в NFS
create_test_files() {
    show_header
    echo -e "${YELLOW}=== Создание тестовых файлов в NFS ===${NC}"
    echo ""
    
    log "Создание тестовых файлов..."
    
    # Создание тестовых файлов
    echo "Тестовый файл NFS от HQ-SRV" > /raid5/nfs/test_from_hq_srv.txt
    echo "Дата создания: $(date)" >> /raid5/nfs/test_from_hq_srv.txt
    
    # Создание директории для общих документов
    mkdir -p /raid5/nfs/shared_docs
    echo "Общие документы офиса HQ" > /raid5/nfs/shared_docs/readme.txt
    
    chmod -R 777 /raid5/nfs
    
    log "Тестовые файлы созданы"
    ls -la /raid5/nfs/
}

# Главное меню
main_menu() {
    while true; do
        show_header
        echo "Выберите действие:"
        echo ""
        echo "1) Настроить NFS сервер"
        echo "2) Настроить Apache и Moodle"
        echo "3) Настроить Chrony клиент"
        echo "4) Показать информацию о NAT"
        echo "5) Создать тестовые файлы в NFS"
        echo "6) Выполнить полную настройку"
        echo "7) Выход"
        echo ""
        
        read -p "Ваш выбор (1-7): " choice
        
        case $choice in
            1) setup_nfs_server ;;
            2) setup_moodle ;;
            3) setup_chrony_client ;;
            4) show_nat_info ;;
            5) create_test_files ;;
            6) 
                setup_nfs_server
                setup_moodle
                setup_chrony_client
                create_test_files
                show_nat_info
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