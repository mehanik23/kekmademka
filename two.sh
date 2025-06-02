#!/bin/bash

# Порванный проверяющий
# Скрипт для настройки системы

# Цвета для красивого вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функция для отображения заголовка
show_header() {
    clear
    echo -e "${BLUE}=====================================${NC}"
    echo -e "${GREEN}    ПОРВАННЫЙ ПРОВЕРЯЮЩИЙ${NC}"
    echo -e "${BLUE}=====================================${NC}"
    echo ""
}

# Функция настройки GRE туннеля
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

# Функция настройки временной зоны и SELinux
setup_timezone_selinux() {
    show_header
    echo -e "${YELLOW}=== Настройка временной зоны и SELinux ===${NC}"
    echo ""
    
    # Настройка временной зоны
    echo -e "${GREEN}1. Настройка временной зоны${NC}"
    echo "Текущая временная зона:"
    timedatectl | grep "Time zone" || echo "Не удалось определить"
    echo ""
    
    echo "Доступные варианты:"
    echo "1) Asia/Krasnoyarsk"
    echo "2) Europe/Moscow"
    echo "3) Asia/Novosibirsk"
    echo "4) Другая"
    
    read -p "Выберите вариант (1-4): " tz_choice
    
    case $tz_choice in
        1) timezone="Asia/Krasnoyarsk";;
        2) timezone="Europe/Moscow";;
        3) timezone="Asia/Novosibirsk";;
        4) read -p "Введите временную зону: " timezone;;
        *) timezone="Asia/Krasnoyarsk";;
    esac
    
    if [ "$EUID" -eq 0 ]; then
        timedatectl set-timezone $timezone
        echo -e "${GREEN}Временная зона установлена: $timezone${NC}"
    else
        echo -e "${YELLOW}Команда для установки временной зоны:${NC}"
        echo "sudo timedatectl set-timezone $timezone"
    fi
    
    echo ""
    echo -e "${GREEN}2. Настройка SELinux${NC}"
    echo "Текущий статус SELinux:"
    
    if command -v getenforce &> /dev/null; then
        getenforce
    else
        echo "SELinux не установлен"
    fi
    
    echo ""
    echo "Выберите режим SELinux:"
    echo "1) Enforcing (принудительный)"
    echo "2) Permissive (разрешающий)"
    echo "3) Disabled (отключен)"
    
    read -p "Выберите вариант (1-3): " selinux_choice
    
    case $selinux_choice in
        1) selinux_mode="enforcing";;
        2) selinux_mode="permissive";;
        3) selinux_mode="disabled";;
        *) selinux_mode="enforcing";;
    esac
    
    if [ "$EUID" -eq 0 ]; then
        if command -v setenforce &> /dev/null; then
            case $selinux_mode in
                "enforcing") setenforce 1;;
                "permissive") setenforce 0;;
            esac
            
            # Изменение конфигурации
            sed -i "s/^SELINUX=.*/SELINUX=$selinux_mode/" /etc/selinux/config
            echo -e "${GREEN}SELinux настроен в режим: $selinux_mode${NC}"
        else
            echo -e "${YELLOW}SELinux не установлен в системе${NC}"
        fi
    else
        echo -e "${YELLOW}Требуются права root для изменения SELinux${NC}"
    fi
    
    echo ""
    read -p "Нажмите Enter для продолжения..."
}

# Функция настройки пользователей
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
        echo "2) Временные зоны и SELinux"
        echo "3) Юзеры+"
        echo "4) Выход"
        echo ""
        
        read -p "Ваш выбор (1-4): " choice
        
        case $choice in
            1) setup_gre_tunnel;;
            2) setup_timezone_selinux;;
            3) setup_users;;
            4) 
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
