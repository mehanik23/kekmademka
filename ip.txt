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

# Установка Apache и необходимых утилит
function install_apache() {
    PM=$(detect_package_manager)
    echo "Установка Apache и зависимостей..."
    
    case $PM in
        "apt")
            apt update && apt install -y apache2 curl
            ;;
        "yum"|"dnf")
            $PM install -y httpd curl
            systemctl enable httpd
            ;;
    esac
}

# Настройка виртуального хоста
function configure_vhost() {
    echo "Настройка виртуального хоста..."
    IP_ADDRESS=$(hostname -I | awk '{print $1}')
    DOMAIN_NAME=${1:-$IP_ADDRESS}
    
    # Создаем конфиг виртуального хоста
    cat > /etc/apache2/sites-available/000-default.conf << EOF
<VirtualHost *:80>
    ServerAdmin admin@$DOMAIN_NAME
    DocumentRoot /var/www/html
    ServerName $DOMAIN_NAME
    ServerAlias www.$DOMAIN_NAME
    <Directory /var/www/html>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF

    # Включаем модуль перезаписи URL
    a2enmod rewrite
}

# Создание страницы с редиректом
function create_website() {
    echo "Создание веб-страницы..."
    cat > /var/www/html/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Добро пожаловать</title>
    <meta http-equiv="refresh" content="0; url='https://www.wildberries.ru'"> 
</head>
<body>
    <p>Переход на сайт <a href="https://www.wildberries.ru">Wildberries</a></p> 
</body>
</html>
EOF
}

# Настройка фаервола
function configure_firewall() {
    echo "Настройка фаервола..."
    if command -v ufw &> /dev/null; then
        ufw allow 'Apache Full' 2>/dev/null || ufw allow 80 2>/dev/null
        ufw reload
    fi
}

# Проверка работы сервера
function check_server() {
    echo "Перезапуск Apache..."
    systemctl restart apache2 || systemctl restart httpd
    
    echo "Проверка доступности сайта:"
    curl -s http://localhost | grep -i "wildberries" &> /dev/null
    [[ $? -eq 0 ]] && echo "✓ Сайт работает" || echo "✗ Сайт не доступен"
}

# Основное меню
function main_menu() {
    clear
    echo "================ Настройка веб-сервера ================"
    read -p "Введите доменное имя (или оставьте пустым для использования IP): " DOMAIN
    echo "1. Настроить веб-сервер"
    echo "2. Выход"
    read -p "Выберите действие (1-2): " choice

    case $choice in
        1)
            install_apache
            configure_vhost "$DOMAIN"
            create_website
            configure_firewall
            check_server
            echo "Сервер настроен! Доступен по http://$DOMAIN"
            ;;
        2)
            echo "Выход..."
            exit 0
            ;;
        *)
            echo "Неверный выбор!"
            sleep 2
            main_menu
            ;;
    esac
}

main_menu
