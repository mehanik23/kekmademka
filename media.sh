#!/bin/bash

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
   echo "Ошибка: Скрипт должен запускаться с правами root"
   exit 1
fi

# Примеры популярных доменов
DOMAIN_EXAMPLES=(
    "wikipedia.org"
    "wildberries.ru"
    "ozon.ru"
    "custom"
)

# Пользовательские названия для ссылок
declare -A LINK_NAMES=(
    ["wikipedia.org"]="Википедия"
    ["wildberries.ru"]="Wildberries"
    ["ozon.ru"]="Ozon"
)

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
    
    # Создаем конфиг виртуального хоста
    cat > /etc/apache2/sites-available/000-default.conf << EOF
<VirtualHost *:80>
    ServerAdmin admin@$DOMAIN
    DocumentRoot /var/www/html
    ServerName $DOMAIN
    ServerAlias www.$DOMAIN
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
    cat > /var/www/html/index.html << EOF
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Добро пожаловать</title>
    <meta http-equiv="refresh" content="0; url='https://$DOMAIN'"> 
</head>
<body>
    <p>Переход на сайт <a href="https://$DOMAIN">$LINK_NAME</a></p> 
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
    curl -s http://localhost | grep -i "$LINK_NAME" &> /dev/null
    [[ $? -eq 0 ]] && echo "✓ Сайт работает" || echo "✗ Сайт не доступен"
}

# Меню выбора домена
function select_domain() {
    while true; do
        clear
        echo "================ Выбор домена ================"
        echo "Выберите пример домена или введите свой:"
        
        for i in ${!DOMAIN_EXAMPLES[@]}; do
            echo "$((i+1)). ${DOMAIN_EXAMPLES[$i]}"
        done
        
        read -p "Введите номер (1-${#DOMAIN_EXAMPLES[@]}) или свой домен: " choice
        
        if [[ $choice =~ ^[0-9]+$ && $choice -ge 1 && $choice -le ${#DOMAIN_EXAMPLES[@]} ]]; then
            SELECTED=${DOMAIN_EXAMPLES[$((choice-1))]}
            
            if [[ $SELECTED == "custom" ]]; then
                while true; do
                    read -p "Введите свой домен (например, wikibebra.org): " CUSTOM_DOMAIN
                    if [[ $CUSTOM_DOMAIN =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                        DOMAIN=$CUSTOM_DOMAIN
                        break
                    else
                        echo "Неверный формат домена!"
                    fi
                done
            else
                DOMAIN=$SELECTED
            fi
            
            # Запрашиваем название ссылки
            read -p "Введите отображаемое название ссылки (по умолчанию: ${LINK_NAMES[$DOMAIN]}): " USER_LINK
            LINK_NAME=${USER_LINK:-${LINK_NAMES[$DOMAIN]}}
            
            return
        else
            echo "Неверный выбор!"
            sleep 2
        fi
    done
}

# Основное меню
function main_menu() {
    clear
    echo "================ Настройка веб-сервера ================"
    select_domain
    
    echo "1. Настроить веб-сервер"
    echo "2. Выход"
    read -p "Выберите действие (1-2): " choice

    case $choice in
        1)
            install_apache
            configure_vhost
            create_website
            configure_firewall
            check_server
            echo "Сервер настроен! Доступен по http://$DOMAIN"
            echo "Сайт будет перенаправлять на https://$DOMAIN  с названием '$LINK_NAME'"
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
