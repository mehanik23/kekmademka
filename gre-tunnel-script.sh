#!/bin/bash

# ANSI цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

# Определение роли устройства
get_device_role() {
  hostname=$(hostname)
  case $hostname in
    HQ-RTR|hq-rtr)
      echo "HQ-RTR"
      ;;
    BR-RTR|br-rtr)
      echo "BR-RTR"
      ;;
    *)
      error "Неизвестное устройство: $hostname"
      exit 1
      ;;
  esac
}

# Настройка GRE туннеля для HQ-RTR
configure_gre_hq() {
  log "Настройка GRE туннеля на HQ-RTR..."
  
  # Включение IP forwarding
  echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-forwarding.conf
  sysctl -p /etc/sysctl.d/99-forwarding.conf
  
  # Создание GRE туннеля
  cat > /etc/network/interfaces.d/gre0 << EOF
# GRE Tunnel HQ-RTR to BR-RTR
auto gre0
iface gre0 inet static
    address 10.0.0.1
    netmask 255.255.255.252
    pre-up ip tunnel add gre0 mode gre remote 172.16.5.2 local 172.16.4.2 ttl 255
    up ip link set gre0 up
    up ip route add 192.168.200.0/24 via 10.0.0.2
    post-down ip tunnel del gre0
EOF
  
  log "Перезапуск сетевых интерфейсов..."
  ifdown gre0 2>/dev/null
  ifup gre0
  
  log "GRE туннель настроен: 10.0.0.1/30"
}

# Настройка GRE туннеля для BR-RTR
configure_gre_br() {
  log "Настройка GRE туннеля на BR-RTR..."
  
  # Включение IP forwarding
  echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-forwarding.conf
  sysctl -p /etc/sysctl.d/99-forwarding.conf
  
  # Создание GRE туннеля
  cat > /etc/network/interfaces.d/gre0 << EOF
# GRE Tunnel BR-RTR to HQ-RTR
auto gre0
iface gre0 inet static
    address 10.0.0.2
    netmask 255.255.255.252
    pre-up ip tunnel add gre0 mode gre remote 172.16.4.2 local 172.16.5.2 ttl 255
    up ip link set gre0 up
    up ip route add 192.168.100.0/24 via 10.0.0.1
    post-down ip tunnel del gre0
EOF
  
  log "Перезапуск сетевых интерфейсов..."
  ifdown gre0 2>/dev/null
  ifup gre0
  
  log "GRE туннель настроен: 10.0.0.2/30"
}

# Установка FRR (Free Range Routing) для OSPF
install_frr() {
  log "Установка FRR для OSPF..."
  
  # Добавление репозитория FRR
  curl -s https://deb.frrouting.org/frr/keys.asc | apt-key add -
  echo "deb https://deb.frrouting.org/frr $(lsb_release -s -c) frr-stable" > /etc/apt/sources.list.d/frr.list
  
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
  
  cat > /etc/frr/frr.conf << EOF
frr version 8.1
frr defaults traditional
hostname HQ-RTR
!
router ospf
 ospf router-id 1.1.1.1
 network 192.168.100.0/24 area 0
 network 10.0.0.0/30 area 0
 passive-interface eth1
!
interface gre0
 ip ospf cost 10
!
line vty
!
EOF

  systemctl restart frr
  log "OSPF настроен на HQ-RTR"
}

# Настройка OSPF для BR-RTR
configure_ospf_br() {
  log "Настройка OSPF на BR-RTR..."
  
  cat > /etc/frr/frr.conf << EOF
frr version 8.1
frr defaults traditional
hostname BR-RTR
!
router ospf
 ospf router-id 2.2.2.2
 network 192.168.200.0/24 area 0
 network 10.0.0.0/30 area 0
 passive-interface eth1
!
interface gre0
 ip ospf cost 10
!
line vty
!
EOF

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
  iptables -A FORWARD -i eth1 -o gre0 -j ACCEPT
  iptables -A FORWARD -i gre0 -o eth1 -j ACCEPT
  
  # Разрешение трафика из локальной сети в интернет
  iptables -A FORWARD -i eth1 -o eth0 -j ACCEPT
  
  # NAT для доступа в интернет
  iptables -t nat -A POSTROUTING -o eth0 -s 192.168.100.0/24 -j MASQUERADE
  
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
  iptables -A FORWARD -i eth1 -o gre0 -j ACCEPT
  iptables -A FORWARD -i gre0 -o eth1 -j ACCEPT
  
  # Разрешение трафика из локальной сети в интернет
  iptables -A FORWARD -i eth1 -o eth0 -j ACCEPT
  
  # NAT для доступа в интернет
  iptables -t nat -A POSTROUTING -o eth0 -s 192.168.200.0/24 -j MASQUERADE
  
  # Сохранение правил
  iptables-save > /etc/iptables/rules.v4
  
  log "Правила iptables настроены"
}

# Проверка GRE туннеля
check_gre_tunnel() {
  log "Проверка GRE туннеля..."
  
  if ip link show gre0 &> /dev/null; then
    log "GRE туннель создан"
    ip addr show gre0
    
    # Проверка связности
    device_role=$(get_device_role)
    if [ "$device_role" = "HQ-RTR" ]; then
      ping -c 3 10.0.0.2
    else
      ping -c 3 10.0.0.1
    fi
  else
    error "GRE туннель не найден!"
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

# Главное меню
main_menu() {
  device_role=$(get_device_role)
  
  while true; do
    clear
    echo "=========================================="
    echo "   Настройка GRE и OSPF для $device_role"
    echo "=========================================="
    echo "1. Полная настройка (GRE + OSPF + Firewall)"
    echo "2. Настроить только GRE туннель"
    echo "3. Настроить только OSPF"
    echo "4. Настроить только Firewall"
    echo "5. Проверить GRE туннель"
    echo "6. Проверить OSPF"
    echo "7. Показать текущие маршруты"
    echo "8. Выход"
    echo "=========================================="
    
    read -p "Выберите пункт меню (1-8): " choice
    
    case $choice in
      1)
        if [ "$device_role" = "HQ-RTR" ]; then
          configure_gre_hq
          install_frr
          configure_ospf_hq
          configure_iptables_hq
        else
          configure_gre_br
          install_frr
          configure_ospf_br
          configure_iptables_br
        fi
        ;;
      2)
        if [ "$device_role" = "HQ-RTR" ]; then
          configure_gre_hq
        else
          configure_gre_br
        fi
        ;;
      3)
        install_frr
        if [ "$device_role" = "HQ-RTR" ]; then
          configure_ospf_hq
        else
          configure_ospf_br
        fi
        ;;
      4)
        if [ "$device_role" = "HQ-RTR" ]; then
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
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}   Скрипт настройки GRE туннеля и OSPF${NC}"
echo -e "${BLUE}========================================${NC}"
main_menu