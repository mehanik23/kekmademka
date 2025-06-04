#!/bin/bash

# ANSI цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BGREEN='\033[1;32m'
NC='\033[0m'

# Функции для вывода
log() { echo -e "${GREEN}[INFO]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
prompt() { echo -e "${YELLOW}$1${NC}"; }

# Проверка root
if [ "$EUID" -ne 0 ]; then
  error "Запустите скрипт с правами root!"
  exit 1
fi

# Глобальная переменная для роли устройства
DEVICE_ROLE=""

# Сетевые интерфейсы
WAN_INTERFACE="ens3"  # Внешний интерфейс (к ISP)
LAN_INTERFACE="ens4"  # Внутренний интерфейс (локальная сеть)

# Выбор роли устройства
select_device_role() {
  echo -e "${BGREEN}========================================${NC}"
  echo -e "${BGREEN}      Выберите устройство для настройки${NC}"
  echo -e "${BGREEN}========================================${NC}"
  echo -e "${GREEN}1.${NC} HQ-RTR (Главный офис)"
  echo -e "${GREEN}2.${NC} BR-RTR (Филиал)"
  echo -e "${BGREEN}========================================${NC}"
  
  while true; do
    read -p "Выберите устройство (1-2): " choice
    case $choice in
      1)
        DEVICE_ROLE="HQ-RTR"
        log "Выбрано устройство: HQ-RTR"
        break
        ;;
      2)
        DEVICE_ROLE="BR-RTR"
        log "Выбрано устройство: BR-RTR"
        break
        ;;
      *)
        error "Неверный выбор! Пожалуйста, выберите 1 или 2."
        ;;
    esac
  done
}

# Настройка GRE туннеля для HQ-RTR
configure_gre_hq() {
  log "Настройка GRE туннеля на HQ-RTR..."
  
  # Проверка внешних IP адресов
  if ! check_and_setup_external_ips; then
    return 1
  fi
  
  # Получение локального IP адреса
  local local_ip=$(ip addr show $WAN_INTERFACE | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+')
  
  if [[ -z "$local_ip" ]]; then
    error "Не удалось определить локальный IP адрес"
    return 1
  fi
  
  log "Используется локальный IP: $local_ip"
  
  # Включение IP forwarding
  echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-forwarding.conf
  sysctl -p /etc/sysctl.d/99-forwarding.conf
  
  # Загрузка модуля GRE
  modprobe ip_gre
  echo "ip_gre" >> /etc/modules-load.d/gre.conf
  
  # Создание GRE туннеля через systemd-networkd
  cat > /etc/systemd/network/25-gre0.netdev << EOF
[NetDev]
Name=gre0
Kind=gre

[Tunnel]
Local=$local_ip
Remote=172.16.5.2
TTL=255
EOF

  cat > /etc/systemd/network/25-gre0.network << 'EOF'
[Match]
Name=gre0

[Network]
Address=10.0.0.1/30

[Route]
Destination=192.168.200.0/24
Gateway=10.0.0.2
EOF
  
  # Перезапуск systemd-networkd
  systemctl restart systemd-networkd
  
  # Ожидание поднятия интерфейса
  sleep 3
  
  # Проверка статуса
  if ip link show gre0 &>/dev/null; then
    log "GRE туннель создан успешно"
    ip addr show gre0
  else
    error "Ошибка создания GRE туннеля"
  fi
}

# Настройка GRE туннеля для BR-RTR
configure_gre_br() {
  log "Настройка GRE туннеля на BR-RTR..."
  
  # Проверка внешних IP адресов
  if ! check_and_setup_external_ips; then
    return 1
  fi
  
  # Получение локального IP адреса
  local local_ip=$(ip addr show $WAN_INTERFACE | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+')
  
  if [[ -z "$local_ip" ]]; then
    error "Не удалось определить локальный IP адрес"
    return 1
  fi
  
  log "Используется локальный IP: $local_ip"
  
  # Включение IP forwarding
  echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-forwarding.conf
  sysctl -p /etc/sysctl.d/99-forwarding.conf
  
  # Загрузка модуля GRE
  modprobe ip_gre
  echo "ip_gre" >> /etc/modules-load.d/gre.conf
  
  # Создание GRE туннеля через systemd-networkd
  cat > /etc/systemd/network/25-gre0.netdev << EOF
[NetDev]
Name=gre0
Kind=gre

[Tunnel]
Local=$local_ip
Remote=172.16.4.2
TTL=255
EOF

  cat > /etc/systemd/network/25-gre0.network << 'EOF'
[Match]
Name=gre0

[Network]
Address=10.0.0.2/30

[Route]
Destination=192.168.100.0/24
Gateway=10.0.0.1
EOF
  
  # Перезапуск systemd-networkd
  systemctl restart systemd-networkd
  
  # Ожидание поднятия интерфейса
  sleep 3
  
  # Проверка статуса
  if ip link show gre0 &>/dev/null; then
    log "GRE туннель создан успешно"
    ip addr show gre0
  else
    error "Ошибка создания GRE туннеля"
  fi
}

# Установка FRR (Free Range Routing) для OSPF
install_frr() {
  log "Установка FRR для OSPF..."
  
  # Установка FRR через пакетный менеджер
  apt update
  apt install -y frr frr-pythontools
  
  # Включение OSPF демона
  sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
  
  systemctl restart frr
  systemctl enable frr
}

# Настройка OSPF для HQ-RTR
configure_ospf_hq() {
  log "Настройка OSPF на HQ-RTR..."
  
  cat > /etc/frr/frr.conf << "EOF"
frr version 8.1
frr defaults traditional
hostname HQ-RTR
!
router ospf
 ospf router-id 1.1.1.1
 network 192.168.100.0/24 area 0
 network 10.0.0.0/30 area 0
 passive-interface ${LAN_INTERFACE}
!
interface gre0
 ip ospf cost 10
!
line vty
!
EOF
  
  # Подставляем реальное имя интерфейса
  sed -i "s/\${LAN_INTERFACE}/$LAN_INTERFACE/" /etc/frr/frr.conf

  systemctl restart frr
  log "OSPF настроен на HQ-RTR"
}

# Настройка OSPF для BR-RTR
configure_ospf_br() {
  log "Настройка OSPF на BR-RTR..."
  
  cat > /etc/frr/frr.conf << "EOF"
frr version 8.1
frr defaults traditional
hostname BR-RTR
!
router ospf
 ospf router-id 2.2.2.2
 network 192.168.200.0/24 area 0
 network 10.0.0.0/30 area 0
 passive-interface ${LAN_INTERFACE}
!
interface gre0
 ip ospf cost 10
!
line vty
!
EOF
  
  # Подставляем реальное имя интерфейса
  sed -i "s/\${LAN_INTERFACE}/$LAN_INTERFACE/" /etc/frr/frr.conf

  systemctl restart frr
  log "OSPF настроен на BR-RTR"
}

# Настройка iptables для NAT и firewall
configure_iptables_hq() {
  log "Настройка iptables на HQ-RTR..."
  
  # Очистка текущих правил
  iptables -F
  iptables -t nat -F
  
  # Политики по умолчанию
  iptables -P INPUT DROP
  iptables -P FORWARD DROP
  iptables -P OUTPUT ACCEPT
  
  # Разрешение loopback
  iptables -A INPUT -i lo -j ACCEPT
  
  # Разрешение установленных соединений
  iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
  iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
  
  # Разрешение ICMP
  iptables -A INPUT -p icmp -j ACCEPT
  iptables -A FORWARD -p icmp -j ACCEPT
  
  # Разрешение SSH из внутренней сети
  iptables -A INPUT -p tcp --dport 22 -s 192.168.100.0/24 -j ACCEPT
  
  # Разрешение GRE
  iptables -A INPUT -p gre -j ACCEPT
  iptables -A FORWARD -i gre0 -j ACCEPT
  iptables -A FORWARD -o gre0 -j ACCEPT
  
  # Разрешение OSPF
  iptables -A INPUT -p ospf -j ACCEPT
  
  # Разрешение трафика между локальной сетью и туннелем
  iptables -A FORWARD -i $LAN_INTERFACE -o gre0 -j ACCEPT
  iptables -A FORWARD -i gre0 -o $LAN_INTERFACE -j ACCEPT
  
  # Разрешение трафика из локальной сети в интернет
  iptables -A FORWARD -i $LAN_INTERFACE -o $WAN_INTERFACE -j ACCEPT
  
  # NAT для доступа в интернет
  iptables -t nat -A POSTROUTING -o $WAN_INTERFACE -s 192.168.100.0/24 -j MASQUERADE
  
  # Установка iptables-persistent для сохранения правил
  DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent
  
  # Сохранение правил
  iptables-save > /etc/iptables/rules.v4
  
  log "Правила iptables настроены"
}

configure_iptables_br() {
  log "Настройка iptables на BR-RTR..."
  
  # Очистка текущих правил
  iptables -F
  iptables -t nat -F
  
  # Политики по умолчанию
  iptables -P INPUT DROP
  iptables -P FORWARD DROP
  iptables -P OUTPUT ACCEPT
  
  # Разрешение loopback
  iptables -A INPUT -i lo -j ACCEPT
  
  # Разрешение установленных соединений
  iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
  iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
  
  # Разрешение ICMP
  iptables -A INPUT -p icmp -j ACCEPT
  iptables -A FORWARD -p icmp -j ACCEPT
  
  # Разрешение SSH из внутренней сети
  iptables -A INPUT -p tcp --dport 22 -s 192.168.200.0/24 -j ACCEPT
  
  # Разрешение GRE
  iptables -A INPUT -p gre -j ACCEPT
  iptables -A FORWARD -i gre0 -j ACCEPT
  iptables -A FORWARD -o gre0 -j ACCEPT
  
  # Разрешение OSPF
  iptables -A INPUT -p ospf -j ACCEPT
  
  # Разрешение трафика между локальной сетью и туннелем
  iptables -A FORWARD -i $LAN_INTERFACE -o gre0 -j ACCEPT
  iptables -A FORWARD -i gre0 -o $LAN_INTERFACE -j ACCEPT
  
  # Разрешение трафика из локальной сети в интернет
  iptables -A FORWARD -i $LAN_INTERFACE -o $WAN_INTERFACE -j ACCEPT
  
  # NAT для доступа в интернет
  iptables -t nat -A POSTROUTING -o $WAN_INTERFACE -s 192.168.200.0/24 -j MASQUERADE
  
  # Установка iptables-persistent для сохранения правил
  DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent
  
  # Сохранение правил
  iptables-save > /etc/iptables/rules.v4
  
  log "Правила iptables настроены"
}

# Удаление GRE туннеля
remove_gre_tunnel() {
  log "Удаление GRE туннеля..."
  
  # Удаление файлов конфигурации
  rm -f /etc/systemd/network/25-gre0.netdev
  rm -f /etc/systemd/network/25-gre0.network
  
  # Перезапуск systemd-networkd
  systemctl restart systemd-networkd
  
  log "GRE туннель удален"
}

# Проверка и настройка внешних IP адресов
check_and_setup_external_ips() {
  log "Проверка внешних IP адресов..."
  
  # Проверка IP на внешнем интерфейсе
  local current_ip=$(ip addr show $WAN_INTERFACE 2>/dev/null | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+')
  
  if [[ -z "$current_ip" ]]; then
    error "IP адрес не настроен на интерфейсе $WAN_INTERFACE"
    echo "Для настройки GRE туннеля необходимо сначала настроить IP адреса на интерфейсах."
    echo ""
    
    if [ "$DEVICE_ROLE" = "HQ-RTR" ]; then
      echo "Для HQ-RTR необходимо настроить:"
      echo "  - IP адрес 172.16.4.2/28 на интерфейсе $WAN_INTERFACE"
      echo "  - IP адрес 192.168.100.1/24 на интерфейсе $LAN_INTERFACE"
    else
      echo "Для BR-RTR необходимо настроить:"
      echo "  - IP адрес 172.16.5.2/28 на интерфейсе $WAN_INTERFACE"
      echo "  - IP адрес 192.168.200.1/24 на интерфейсе $LAN_INTERFACE"
    fi
    
    echo ""
    echo "Используйте основной скрипт настройки сети (main.sh) для настройки IP адресов."
    return 1
  fi
  
  # Проверка соответствия IP адреса
  if [ "$DEVICE_ROLE" = "HQ-RTR" ]; then
    if [[ "$current_ip" != "172.16.4.2" ]]; then
      warn "Текущий IP адрес ($current_ip) не соответствует ожидаемому (172.16.4.2)"
      echo "Для корректной работы GRE туннеля рекомендуется использовать IP 172.16.4.2"
    fi
  else
    if [[ "$current_ip" != "172.16.5.2" ]]; then
      warn "Текущий IP адрес ($current_ip) не соответствует ожидаемому (172.16.5.2)"
      echo "Для корректной работы GRE туннеля рекомендуется использовать IP 172.16.5.2"
    fi
  fi
  
  return 0
}

# Проверка сетевых интерфейсов
check_interfaces() {
  log "Текущие сетевые интерфейсы:"
  echo ""
  ip -br addr show
  echo ""
  log "Проверьте соответствие:"
  echo "  - ${WAN_INTERFACE} должен иметь IP из сети ISP (172.16.x.x)"
  echo "  - ${LAN_INTERFACE} должен иметь IP из локальной сети (192.168.x.x)"
  echo ""
}

# Проверка GRE туннеля
check_gre_tunnel() {
  log "Проверка GRE туннеля..."
  
  # Проверка наличия интерфейса
  if ip link show gre0 &> /dev/null; then
    log "GRE туннель создан"
    echo ""
    echo "Информация об интерфейсе gre0:"
    ip addr show gre0
    echo ""
    
    # Проверка состояния интерфейса
    local state=$(ip link show gre0 | grep -oP '(?<=state\s)\w+')
    if [[ "$state" == "UP" ]]; then
      log "Интерфейс gre0 активен (UP)"
    else
      warn "Интерфейс gre0 не активен (состояние: $state)"
    fi
    
    # Проверка назначенного IP
    local gre_ip=$(ip addr show gre0 | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+/\d+')
    if [[ -n "$gre_ip" ]]; then
      log "IP адрес gre0: $gre_ip"
    else
      error "IP адрес не назначен на gre0"
    fi
    
    # Проверка связности
    echo ""
    log "Проверка связности через туннель..."
    if [ "$DEVICE_ROLE" = "HQ-RTR" ]; then
      echo "Ping 10.0.0.2 (BR-RTR):"
      ping -c 3 -W 2 10.0.0.2
    else
      echo "Ping 10.0.0.1 (HQ-RTR):"
      ping -c 3 -W 2 10.0.0.1
    fi
    
    # Показать файлы конфигурации
    echo ""
    log "Файлы конфигурации systemd-networkd:"
    ls -la /etc/systemd/network/25-gre0.*
    
  else
    error "GRE туннель не найден!"
    echo ""
    echo "Возможные причины:"
    echo "1. Туннель не был настроен"
    echo "2. systemd-networkd не запущен"
    echo "3. Проблемы с конфигурацией"
    echo ""
    echo "Проверьте статус systemd-networkd:"
    systemctl status systemd-networkd --no-pager | head -n 10
  fi
}

# Проверка OSPF
check_ospf() {
  log "Проверка OSPF..."
  
  if systemctl is-active --quiet frr; then
    log "FRR запущен"
    vtysh -c "show ip ospf neighbor"
    vtysh -c "show ip route ospf"
  else
    error "FRR не запущен!"
  fi
}

# Отладка systemd-networkd
debug_networkd() {
  log "Отладка systemd-networkd..."
  echo ""
  
  # Статус службы
  echo "=== Статус systemd-networkd ==="
  systemctl status systemd-networkd --no-pager | head -n 15
  echo ""
  
  # Логи службы
  echo "=== Последние логи systemd-networkd ==="
  journalctl -u systemd-networkd -n 20 --no-pager
  echo ""
  
  # Файлы конфигурации
  echo "=== Файлы конфигурации в /etc/systemd/network/ ==="
  ls -la /etc/systemd/network/
  echo ""
  
  # Состояние сетевых интерфейсов
  echo "=== Состояние сетевых интерфейсов ==="
  networkctl status --no-pager
}

# Главное меню
main_menu() {
  # Выбор устройства при первом запуске
  select_device_role
  
  # Показать текущие интерфейсы
  echo ""
  check_interfaces
  read -p "Нажмите Enter для продолжения..."
  
  while true; do
    clear
    echo -e "${BGREEN}=========================================${NC}"
    echo -e "${BGREEN}   Настройка GRE и OSPF для $DEVICE_ROLE${NC}"
    echo -e "${BGREEN}=========================================${NC}"
    echo -e "${GREEN}1.${NC} Полная настройка (GRE + OSPF + Firewall)"
    echo -e "${GREEN}2.${NC} Настроить только GRE туннель"
    echo -e "${GREEN}3.${NC} Настроить только OSPF"
    echo -e "${GREEN}4.${NC} Настроить только Firewall"
    echo -e "${GREEN}5.${NC} Проверить GRE туннель"
    echo -e "${GREEN}6.${NC} Проверить OSPF"
    echo -e "${GREEN}7.${NC} Показать текущие маршруты"
    echo -e "${GREEN}8.${NC} Показать сетевые интерфейсы"
    echo -e "${GREEN}9.${NC} Удалить GRE туннель"
    echo -e "${GREEN}10.${NC} Отладка systemd-networkd"
    echo -e "${GREEN}11.${NC} Сменить устройство"
    echo -e "${GREEN}0.${NC} Выход"
    echo -e "${BGREEN}=========================================${NC}"
    
    read -p "Выберите пункт меню: " choice
    
    case $choice in
      1)
        if [ "$DEVICE_ROLE" = "HQ-RTR" ]; then
          configure_gre_hq
          if [ $? -eq 0 ]; then
            install_frr
            configure_ospf_hq
            configure_iptables_hq
          fi
        else
          configure_gre_br
          if [ $? -eq 0 ]; then
            install_frr
            configure_ospf_br
            configure_iptables_br
          fi
        fi
        ;;
      2)
        if [ "$DEVICE_ROLE" = "HQ-RTR" ]; then
          configure_gre_hq
        else
          configure_gre_br
        fi
        ;;
      3)
        install_frr
        if [ "$DEVICE_ROLE" = "HQ-RTR" ]; then
          configure_ospf_hq
        else
          configure_ospf_br
        fi
        ;;
      4)
        if [ "$DEVICE_ROLE" = "HQ-RTR" ]; then
          configure_iptables_hq
        else
          configure_iptables_br
        fi
        ;;
      5)
        check_gre_tunnel
        ;;
      6)
        check_ospf
        ;;
      7)
        ip route show
        ;;
      8)
        ip addr show
        ;;
      9)
        remove_gre_tunnel
        ;;
      10)
        debug_networkd
        ;;
      11)
        select_device_role
        ;;
      0)
        echo "Выход..."
        exit 0
        ;;
      *)
        error "Неверный выбор!"
        ;;
    esac
    
    read -p $'\nНажмите Enter для продолжения...'
  done
}

# Запуск меню
echo -e "${BGREEN}========================================${NC}"
echo -e "${BGREEN}   Скрипт настройки GRE туннеля и OSPF${NC}"
echo -e "${BGREEN}========================================${NC}"
echo -e "${YELLOW}ВАЖНО: Убедитесь, что интерфейсы настроены:${NC}"
echo -e "${YELLOW}  ${WAN_INTERFACE} - внешний интерфейс (к ISP)${NC}"
echo -e "${YELLOW}  ${LAN_INTERFACE} - внутренний интерфейс (локальная сеть)${NC}"
echo ""
echo -e "${YELLOW}Требования для настройки GRE:${NC}"
echo -e "${YELLOW}  HQ-RTR: IP 172.16.4.2/28 на ${WAN_INTERFACE}${NC}"
echo -e "${YELLOW}  BR-RTR: IP 172.16.5.2/28 на ${WAN_INTERFACE}${NC}"
echo ""
echo -e "${CYAN}Для настройки IP используйте main.sh${NC}"
echo -e "${BGREEN}========================================${NC}"
echo ""
main_menu
