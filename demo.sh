#!/bin/bash
# =====================================================================
#  Демоэкзамен 09.02.06 (КИМ 1-2027), УП 02.02 — автонастройка ALT Linux
#  Запуск:   bash <(curl -fsSL RAW/demo.sh) <роль> <шаг>
#  Роли:     isp | br-fw | hq-srv | br-srv | hq-cli     (Linux, настраиваются скриптом)
#            hq-rtr | br-rtr                            (EcoRouter, скрипт печатает конфиг)
#  Шаги:     1 — Задание 1, 2 — Задание 2, либо отдельный подшаг (см. usage)
# =====================================================================

RAW="${RAW:-https://raw.githubusercontent.com/altlinuxPROsto/demo0202/main}"

# ---------------- Общие параметры (можно переопределить: VAR=... bash demo.sh ...) -------------
DOMAIN="${DOMAIN:-au-team.irpo}"
REALM="${REALM:-AU-TEAM.IRPO}"
WORKGROUP="${WORKGROUP:-AU-TEAM}"
TZONE="${TZONE:-Asia/Yekaterinburg}"        # Екатеринбург = UTC+5 (МСК+2)
PASS="${PASS:-P@ssw0rd}"
ADMIN_PASS="${ADMIN_PASS:-P@ssw0rd}"        # пароль administrator в Samba DC (для ввода HQ-CLI в домен)
VLAN_MODE="${VLAN_MODE:-access}"            # access — VLAN-тег стоит на сетевухе ВМ в Proxmox (tag=100/200)
                                            # host   — тег вешает сама ВМ (подинтерфейсы vlan100/vlan200)
DNS_FWD1="${DNS_FWD1:-77.88.8.7}"
DNS_FWD2="${DNS_FWD2:-77.88.8.3}"
NTP_UPSTREAM="${NTP_UPSTREAM:-ru.pool.ntp.org}"

# ---------------- План адресации ----------------
ISP_HQ=172.16.1.1;  HQ_RTR_WAN=172.16.1.2      # 172.16.1.0/28
ISP_BR=172.16.2.1;  BR_RTR_WAN=172.16.2.2      # 172.16.2.0/28
HQ_SRV_GW=192.168.1.1;   HQ_SRV_IP=192.168.1.2;   HQ_SRV_NET=192.168.1.0/27     # VLAN100, 32 адреса (192.168.100.0 не использовать!)
HQ_CLI_GW=192.168.200.1; HQ_CLI_IP=192.168.200.2; HQ_CLI_NET=192.168.200.0/28   # VLAN200, 16 адресов
HQ_MGMT_GW=192.168.99.1;                          HQ_MGMT_NET=192.168.99.0/29   # VLAN999, 8 адресов
BR_RTR_FW=192.168.10.1;  BR_FW_OUT=192.168.10.2;  FW_NET=192.168.10.0/30        # BR-RTR <-> BR-FW
BR_FW_IN=192.168.20.1;   BR_SRV_IP=192.168.20.2;  BR_NET=192.168.20.0/28        # BR-FW  <-> BR-SRV
TUN_HQ=10.10.10.1; TUN_BR=10.10.10.2                                            # GRE 10.10.10.0/30

# =====================================================================
#  Вспомогательные функции
# =====================================================================
log()  { echo -e "\e[1;32m[+] $*\e[0m"; }
warn() { echo -e "\e[1;33m[!] $*\e[0m"; }
die()  { echo -e "\e[1;31m[x] $*\e[0m"; exit 1; }

phys_ifaces() { for p in /sys/class/net/*; do [ -e "$p/device" ] && echo "${p##*/}"; done | sort -V; }
nth_if()      { phys_ifaces | sed -n "${1}p"; }

APT_DONE=
pkg() {
  [ -n "$APT_DONE" ] || { apt-get update </dev/null && APT_DONE=1; }
  apt-get install -y "$@" </dev/null
}
pkg_any() { for p in "$@"; do pkg "$p" && return 0; done; warn "не удалось поставить: $*"; return 1; }

set_hostname() {
  hostnamectl set-hostname "$1" 2>/dev/null || echo "$1" > /etc/hostname
  hostname "$1"
  sed -i "/[[:space:]]${1%%.*}\$/d;/[[:space:]]$1[[:space:]]/d" /etc/hosts
  echo "127.0.1.1 $1 ${1%%.*}" >> /etc/hosts
  [ -f /etc/sysconfig/network ] && sed -i "s/^HOSTNAME=.*/HOSTNAME=$1/" /etc/sysconfig/network
  log "hostname: $1"
}

set_tz() {
  timedatectl set-timezone "$TZONE" 2>/dev/null || ln -sf "/usr/share/zoneinfo/$TZONE" /etc/localtime
  log "timezone: $TZONE ($(date +%Z%z))"
}

# etcnet (ALT): etc_if DEV PROTO [ADDR/PFX] [GW] [HOST VID]
etc_if() {
  local dev=$1 proto=$2 addr=$3 gw=$4 host=$5 vid=$6 d=/etc/net/ifaces/$1
  mkdir -p "$d"
  rm -f "$d/ipv4address" "$d/ipv4route"
  {
    if [ -n "$host" ]; then echo "TYPE=vlan"; echo "HOST=$host"; echo "VID=$vid"; else echo "TYPE=eth"; fi
    echo "DISABLED=no"; echo "NM_CONTROLLED=no"; echo "BOOTPROTO=$proto"
    echo "CONFIG_IPV4=yes"; echo "CONFIG_IPV6=no"; echo "ONBOOT=yes"
  } > "$d/options"
  [ -n "$addr" ] && echo "$addr" > "$d/ipv4address"
  [ -n "$gw" ]   && echo "default via $gw" > "$d/ipv4route"
  log "etcnet: $dev $proto ${addr:-} ${gw:+gw $gw} ${host:+vlan $vid on $host}"
}
etc_dns() { local dev=$1; shift; mkdir -p "/etc/net/ifaces/$dev"; printf '%s\n' "$@" > "/etc/net/ifaces/$dev/resolv.conf"; printf '%s\n' "$@" > /etc/resolv.conf; }

# убрать временные адреса/подинтерфейсы от bootstrap и прошлых запусков
clean_if() {
  local IF=$1 v
  for v in 100 200 999; do ip link del "$IF.$v" 2>/dev/null; done
  ip addr flush dev "$IF" 2>/dev/null
}
drop_etc_if() { local d; for d in "$@"; do [ -d "/etc/net/ifaces/$d" ] && { ip link del "$d" 2>/dev/null; rm -rf "/etc/net/ifaces/$d"; log "удалён старый интерфейс $d"; }; done; }

forward_on() {
  local f=/etc/net/sysctl.conf
  [ -f $f ] || f=/etc/sysctl.conf
  if grep -q '^\s*net.ipv4.ip_forward' $f; then sed -i 's/^\s*net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' $f
  else echo 'net.ipv4.ip_forward = 1' >> $f; fi
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  log "ip_forward = 1"
}

net_restart() {
  log "перезапуск network..."
  systemctl restart network || service network restart
  sleep 3
}

wait_inet() {
  for _ in $(seq 1 15); do ping -c1 -W2 77.88.8.8 >/dev/null 2>&1 && { log "интернет есть"; return 0; }; sleep 2; done
  warn "нет пинга до 77.88.8.8 — проверь маршрутизаторы (NAT/маршрут). Продолжаю."
  return 1
}

set_pass() { echo "$1:$2" | chpasswd 2>/dev/null || usermod -p "$(openssl passwd -6 "$2")" "$1"; }

sudo_enable() {
  control sudo public 2>/dev/null
  grep -qE '^[@#]includedir\s+/etc/sudoers.d' /etc/sudoers || echo '@includedir /etc/sudoers.d' >> /etc/sudoers
  mkdir -p /etc/sudoers.d
}

ensure_sshuser() {
  if id sshuser >/dev/null 2>&1; then
    [ "$(id -u sshuser)" = 2027 ] || { usermod -u 2027 sshuser && chown -R sshuser /home/sshuser 2>/dev/null; }
  else
    useradd -m -u 2027 -s /bin/bash sshuser
  fi
  set_pass sshuser "$PASS"
}

mk_sshuser() {
  ensure_sshuser
  usermod -aG wheel sshuser 2>/dev/null
  sudo_enable
  echo 'sshuser ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/sshuser; chmod 440 /etc/sudoers.d/sshuser
  log "sshuser (uid $(id -u sshuser)) создан, sudo без пароля"
}

ssh_harden() {
  local dir=/etc/openssh; [ -d $dir ] || dir=/etc/ssh
  local f=$dir/sshd_config
  pkg_any openssh-server >/dev/null 2>&1
  echo "Authorized access only" > $dir/banner
  sed -i -E '/^\s*#?\s*(Port|AllowUsers|MaxAuthTries|Banner|PasswordAuthentication)\s/d' $f
  { printf 'Port 2027\nAllowUsers sshuser\nMaxAuthTries 2\nBanner %s/banner\nPasswordAuthentication yes\n' $dir; cat $f; } > $f.new && mv $f.new $f
  systemctl enable sshd >/dev/null 2>&1; systemctl restart sshd
  log "sshd: порт 2027, только sshuser, 2 попытки, баннер"
}

chrony_client() {
  pkg chrony
  sed -i -E '/^\s*(server|pool|peer)\s/d' /etc/chrony.conf
  echo "server $1 iburst prefer" >> /etc/chrony.conf
  systemctl enable chronyd >/dev/null 2>&1; systemctl restart chronyd
  sleep 3; chronyc sources 2>/dev/null
  log "chrony клиент -> $1"
}

mount_iso() {
  mkdir -p /mnt/add
  if ! mountpoint -q /mnt/add; then
    for d in /dev/sr0 /dev/sr1 /dev/sr2 /dev/cdrom; do
      [ -b "$d" ] || continue
      mount -o ro "$d" /mnt/add 2>/dev/null || continue
      find /mnt/add -maxdepth 2 -type d \( -iname docker -o -iname web \) | grep -q . && break
      umount /mnt/add
    done
  fi
  mountpoint -q /mnt/add || die "Additional.iso не найден — подключи его в CD-ROM ВМ"
  log "Additional.iso смонтирован в /mnt/add"
}

report() {
  local f=/root/report_${ROLE}_task${STEP}.txt
  {
    echo "=== $(hostname)  $(date '+%F %T %Z')"
    for c in "$@"; do echo; echo "### $c"; bash -c "$c" 2>&1; done
  } > "$f"
  log "Сведения для отчёта сохранены: $f"
}

# =====================================================================
#  ЗАДАНИЕ 1
# =====================================================================
isp_1() {
  local WAN HQ BR rest
  WAN=${WAN_IF:-$(ip route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')}
  [ -n "$WAN" ] || WAN=$(nth_if 1)
  mapfile -t rest < <(phys_ifaces | grep -vx "$WAN")
  HQ=${HQ_IF:-${rest[0]}}; BR=${BR_IF:-${rest[1]}}
  [ -n "$HQ" ] && [ -n "$BR" ] || die "нужно 3 интерфейса, найдено: $(phys_ifaces | xargs)"
  log "WAN=$WAN  ->HQ=$HQ  ->BR=$BR   (если не так: WAN_IF=.. HQ_IF=.. BR_IF=.. bash demo.sh isp 1)"

  set_hostname isp
  clean_if "$HQ"; clean_if "$BR"
  etc_if "$WAN" dhcp
  etc_if "$HQ" static "$ISP_HQ/28"
  etc_if "$BR" static "$ISP_BR/28"
  forward_on
  net_restart
  wait_inet

  pkg_any iptables
  iptables -t nat -C POSTROUTING -o "$WAN" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o "$WAN" -j MASQUERADE
  mkdir -p /etc/sysconfig
  iptables-save > /etc/sysconfig/iptables
  systemctl enable iptables >/dev/null 2>&1
  log "NAT (MASQUERADE) через $WAN сохранён в /etc/sysconfig/iptables"
  set_tz
  report "ip -br a" "ip r" "iptables -t nat -S" "sysctl net.ipv4.ip_forward" "timedatectl"
}

br_fw_1() {
  local OUT=${FW_OUT_IF:-$(nth_if 1)} IN=${FW_IN_IF:-$(nth_if 2)}
  [ -n "$IN" ] || die "нужно 2 интерфейса, найдено: $(phys_ifaces | xargs)"
  log "к BR-RTR: $OUT   к BR-SRV: $IN   (если не так: FW_OUT_IF=.. FW_IN_IF=.. bash demo.sh br-fw 1)"
  set_hostname "br-fw.$DOMAIN"
  clean_if "$OUT"; clean_if "$IN"
  etc_if "$OUT" static "$BR_FW_OUT/30" "$BR_RTR_FW"
  etc_if "$IN"  static "$BR_FW_IN/28"
  etc_dns "$OUT" "nameserver 77.88.8.8"
  forward_on
  net_restart
  wait_inet

  pkg frr
  sed -i -E 's/^ospfd=.*/ospfd=yes/' /etc/frr/daemons
  cat > /etc/frr/frr.conf <<EOF
frr defaults traditional
hostname br-fw
log syslog informational
!
router ospf
 ospf router-id 3.3.3.3
 redistribute connected
 network $FW_NET area 0
!
line vty
!
EOF
  chown frr:frr /etc/frr/frr.conf 2>/dev/null
  systemctl enable frr >/dev/null 2>&1; systemctl restart frr
  log "FRR OSPF: только интерфейс $OUT ($FW_NET), сеть BR-NET анонсируется через redistribute connected"

  etc_dns "$OUT" "nameserver $HQ_SRV_IP" "search $DOMAIN"
  set_tz
  sleep 5
  report "ip -br a" "ip r" "vtysh -c 'show running-config'" "vtysh -c 'show ip ospf neighbor'" "timedatectl"
}

hq_srv_1() {
  local IF=${SRV_IF:-$(nth_if 1)} DEV
  set_hostname "hq-srv.$DOMAIN"
  clean_if "$IF"
  if [ "$VLAN_MODE" = host ]; then
    etc_if "$IF" static
    etc_if vlan100 static "$HQ_SRV_IP/27" "$HQ_SRV_GW" "$IF" 100
    DEV=vlan100
  else
    drop_etc_if vlan100
    etc_if "$IF" static "$HQ_SRV_IP/27" "$HQ_SRV_GW"
    DEV=$IF
  fi
  etc_dns "$DEV" "nameserver 77.88.8.8"
  net_restart
  wait_inet

  mk_sshuser
  ssh_harden

  # --- DNS (dnsmasq) ---
  pkg dnsmasq bind-utils
  [ -f /etc/dnsmasq.conf.orig ] || cp /etc/dnsmasq.conf /etc/dnsmasq.conf.orig 2>/dev/null
  cat > /etc/dnsmasq.conf <<EOF
# DNS-сервер офиса HQ (зона $DOMAIN)
no-resolv
domain-needed
server=$DNS_FWD1
server=$DNS_FWD2
cache-size=1000
local-ttl=60
# A + PTR
host-record=hq-srv.$DOMAIN,$HQ_SRV_IP
host-record=br-srv.$DOMAIN,$BR_SRV_IP
# только A
address=/hq-rtr.$DOMAIN/$HQ_SRV_GW
address=/br-rtr.$DOMAIN/$BR_RTR_FW
address=/br-fw.$DOMAIN/$BR_FW_OUT
address=/hq-cli.$DOMAIN/$HQ_CLI_IP
address=/docker.$DOMAIN/$ISP_HQ
address=/web.$DOMAIN/$ISP_BR
EOF
  systemctl enable dnsmasq >/dev/null 2>&1; systemctl restart dnsmasq
  etc_dns "$DEV" "nameserver 127.0.0.1" "search $DOMAIN"
  set_tz
  sleep 2
  for n in hq-rtr br-rtr br-fw hq-srv hq-cli br-srv docker web; do echo "$n.$DOMAIN -> $(host -t A $n.$DOMAIN 127.0.0.1 | awk '/has address/{print $4}')"; done
  host "$HQ_SRV_IP" 127.0.0.1 | tail -1; host "$BR_SRV_IP" 127.0.0.1 | tail -1
  report "ip -br a" "ip r" "cat /etc/dnsmasq.conf" "host hq-srv.$DOMAIN 127.0.0.1" "host $HQ_SRV_IP 127.0.0.1" \
         "id sshuser" "cat /etc/sudoers.d/sshuser" "grep -E '^(Port|AllowUsers|MaxAuthTries|Banner)' /etc/openssh/sshd_config" "timedatectl"
}

br_srv_1() {
  local IF=${SRV_IF:-$(nth_if 1)}
  set_hostname "br-srv.$DOMAIN"
  clean_if "$IF"
  etc_if "$IF" static "$BR_SRV_IP/28" "$BR_FW_IN"
  etc_dns "$IF" "nameserver 77.88.8.8"
  net_restart
  wait_inet
  mk_sshuser
  ssh_harden
  etc_dns "$IF" "nameserver $HQ_SRV_IP" "search $DOMAIN"
  set_tz
  report "ip -br a" "ip r" "cat /etc/resolv.conf" "id sshuser" "cat /etc/sudoers.d/sshuser" \
         "grep -E '^(Port|AllowUsers|MaxAuthTries|Banner)' /etc/openssh/sshd_config" "timedatectl"
}

hq_cli_1() {
  local IF=${CLI_IF:-$(nth_if 1)} base
  set_hostname "hq-cli.$DOMAIN"
  pkill -f "dhcpcd.*$IF.200" 2>/dev/null; dhcpcd -k "$IF.200" >/dev/null 2>&1; ip link del "$IF.200" 2>/dev/null
  if command -v nmcli >/dev/null && systemctl is-active -q NetworkManager; then
    base=$(nmcli -g GENERAL.CONNECTION device show "$IF" 2>/dev/null)
    [ -z "$base" ] && { nmcli con add type ethernet con-name "$IF" ifname "$IF" >/dev/null; base=$IF; }
    if [ "$VLAN_MODE" = host ]; then
      nmcli con mod "$base" ipv4.method disabled ipv6.method ignore
      nmcli con up "$base" >/dev/null
      nmcli con delete vlan200 >/dev/null 2>&1
      nmcli con add type vlan con-name vlan200 ifname vlan200 dev "$IF" id 200 ipv4.method auto ipv6.method ignore >/dev/null
      nmcli con up vlan200
    else
      nmcli con delete vlan200 >/dev/null 2>&1
      nmcli con mod "$base" ipv4.method auto ipv4.addresses "" ipv4.gateway "" ipv4.dns "" ipv6.method ignore
      nmcli con down "$base" >/dev/null 2>&1; nmcli con up "$base"
    fi
  else
    if [ "$VLAN_MODE" = host ]; then etc_if "$IF" static; etc_if vlan200 dhcp "" "" "$IF" 200
    else drop_etc_if vlan200; etc_if "$IF" dhcp; fi
    ip addr flush dev "$IF" 2>/dev/null
    net_restart
  fi
  sleep 5
  ip -br a; ip r; cat /etc/resolv.conf
  wait_inet
  getent hosts ya.ru >/dev/null || warn "DNS не отвечает: HQ-SRV ещё не настроен (hq-srv 1). Временно: echo nameserver 77.88.8.8 > /etc/resolv.conf"
  set_tz
  report "ip -br a" "ip r" "cat /etc/resolv.conf" "timedatectl"
}

# =====================================================================
#  ЗАДАНИЕ 2
# =====================================================================
isp_2() { isp_ntp; }
isp_ntp() {
  pkg chrony
  [ -f /etc/chrony.conf.orig ] || cp /etc/chrony.conf /etc/chrony.conf.orig 2>/dev/null
  cat > /etc/chrony.conf <<EOF
pool $NTP_UPSTREAM iburst
local stratum 5
allow 172.16.0.0/12
allow 192.168.0.0/16
allow 10.0.0.0/8
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
EOF
  systemctl enable chronyd >/dev/null 2>&1; systemctl restart chronyd
  sleep 3; chronyc sources; chronyc tracking | grep -i stratum
  report "cat /etc/chrony.conf" "chronyc sources" "chronyc tracking"
}

hq_srv_2() { hq_srv_raid; hq_srv_nfs; hq_srv_ntp; hq_srv_web; hq_srv_dnsad
  report "cat /proc/mdstat" "mdadm --detail /dev/md0" "cat /etc/mdadm.conf" "lsblk" "grep raid /etc/fstab" "df -h /raid" \
         "cat /etc/exports" "exportfs -v" "chronyc sources" "ls -l /var/www/html" "mysql -e 'SHOW DATABASES; SELECT user,host FROM mysql.user;'" \
         "curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://localhost/"; }

hq_srv_raid() {
  pkg mdadm
  if [ ! -b /dev/md0 ] && grep -q '^md' /proc/mdstat; then   # после перезагрузки массив мог собраться как md127
    local old mem; old=$(awk '/^md/{print $1; exit}' /proc/mdstat)
    warn "найден /dev/$old — пересобираю как /dev/md0"
    mem=$(mdadm --detail "/dev/$old" | grep -oE '/dev/(sd|vd)[a-z]+$')
    mdadm --stop "/dev/$old" && mdadm --assemble /dev/md0 $mem
    sleep 1; partprobe /dev/md0 2>/dev/null; udevadm settle
  fi
  if [ -b /dev/md0 ]; then log "/dev/md0 уже есть — пропускаю создание"; else
    local disks=() d
    for d in $(lsblk -dnbo NAME,SIZE,TYPE | awk '$3=="disk" && $2>=500*1024*1024 && $2<=2*1024*1024*1024 {print $1}'); do
      [ "$(lsblk -no NAME "/dev/$d" | wc -l)" = 1 ] && ! grep -q "^/dev/$d" /proc/mounts && disks+=("/dev/$d")
    done
    [ ${#disks[@]} -ge 2 ] || die "не нашёл 2 чистых диска по 1 ГБ: $(lsblk -dno NAME,SIZE | xargs)"
    disks=("${disks[@]:0:2}")
    log "RAID0 из ${disks[*]}"
    mdadm --zero-superblock --force "${disks[@]}" 2>/dev/null
    yes | mdadm --create /dev/md0 --level=0 --raid-devices=2 "${disks[@]}" --run
  fi
  sed -i '/^ARRAY/d' /etc/mdadm.conf 2>/dev/null
  mdadm --detail --scan | sed -E 's#^ARRAY [^ ]+#ARRAY /dev/md0#' >> /etc/mdadm.conf
  if [ ! -b /dev/md0p1 ]; then
    printf 'label: dos\n,,L\n' | sfdisk /dev/md0
    partprobe /dev/md0 2>/dev/null; udevadm settle; sleep 1
  fi
  [ "$(blkid -s TYPE -o value /dev/md0p1)" = ext4 ] || mkfs.ext4 -F /dev/md0p1
  mkdir -p /raid
  local uuid; uuid=$(blkid -s UUID -o value /dev/md0p1)
  sed -i '\# /raid #d' /etc/fstab
  echo "UUID=$uuid /raid ext4 defaults 0 0" >> /etc/fstab
  mountpoint -q /raid || mount /raid
  df -h /raid
}

hq_srv_nfs() {
  pkg_any nfs-server nfs-utils
  mkdir -p /raid/nfs; chmod 777 /raid/nfs
  sed -i '\#^/raid/nfs#d' /etc/exports 2>/dev/null
  echo "/raid/nfs $HQ_CLI_NET(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
  systemctl enable --now nfs-server 2>/dev/null || systemctl enable --now nfs
  exportfs -ra; exportfs -v
}

hq_srv_ntp() { chrony_client "$ISP_HQ"; }

hq_srv_web() {
  mount_iso
  local w; w=$(find /mnt/add -maxdepth 2 -type d -iname web | head -1)
  [ -n "$w" ] || die "в ISO нет папки web"
  pkg lamp-server || pkg apache2 apache2-mod_php8.2 mariadb-server php8.2-mysqli
  local mi; mi=$(apt-cache pkgnames 2>/dev/null | grep -E '^php[0-9.]+-mysqli$' | sort -V | tail -1)
  [ -n "$mi" ] && pkg "$mi"
  for m in /etc/httpd2/conf/mods-available/php*.load; do [ -e "$m" ] && a2enmod "$(basename "$m" .load)" 2>/dev/null; done
  systemctl enable --now mariadb 2>/dev/null || systemctl enable --now mysqld
  sleep 2
  mysql -u root -e "CREATE DATABASE IF NOT EXISTS webdb; CREATE USER IF NOT EXISTS 'web'@'localhost' IDENTIFIED BY '$PASS'; ALTER USER 'web'@'localhost' IDENTIFIED BY '$PASS'; GRANT ALL PRIVILEGES ON webdb.* TO 'web'@'localhost'; FLUSH PRIVILEGES;"
  local dump; dump=$(find "$w" -iname 'dump.sql' | head -1)
  if [ -z "$dump" ]; then warn "dump.sql не найден в $w"
  elif [ "$(mysql -u root -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='webdb'")" -gt 0 ]; then
    log "в webdb уже есть таблицы — повторный импорт пропущен"
  else
    mysql -u root webdb < "$dump" && log "dump.sql импортирован в webdb"
  fi
  local root=/var/www/html; mkdir -p $root
  cp "$w"/index.php "$w"/logo.png $root/ 2>/dev/null || cp "$(find "$w" -iname index.php | head -1)" "$(find "$w" -iname logo.png | head -1)" $root/
  rm -f $root/index.html
  # подставляем учётные данные БД в index.php
  sed -i -E \
    -e "s/(\\\$(servername|host|dbhost|db_host|hostname)\s*=\s*)['\"][^'\"]*['\"]/\1'localhost'/" \
    -e "s/(\\\$(username|user|dbuser|db_user)\s*=\s*)['\"][^'\"]*['\"]/\1'web'/" \
    -e "s/(\\\$(password|pass|dbpass|db_pass|passwd)\s*=\s*)['\"][^'\"]*['\"]/\1'$PASS'/" \
    -e "s/(\\\$(dbname|database|db|db_name)\s*=\s*)['\"][^'\"]*['\"]/\1'webdb'/" $root/index.php
  echo "--- строки подключения в index.php (проверь!) ---"
  grep -nEi 'host|user|pass|dbname|database|mysqli|PDO' $root/index.php | head -20
  chown -R apache2:apache2 $root 2>/dev/null || chown -R apache:apache $root 2>/dev/null
  systemctl enable httpd2 >/dev/null 2>&1 && systemctl restart httpd2 || { systemctl enable --now apache2; systemctl restart apache2; }
  sleep 1
  curl -s -o /dev/null -w "веб-приложение: HTTP %{http_code}\n" http://localhost/
}

hq_srv_dnsad() {   # пересылка запросов домена Samba (SRV/Kerberos) на BR-SRV
  [ -f /etc/dnsmasq.conf ] || { warn "dnsmasq не настроен — пропускаю"; return; }
  sed -i "\#^server=/$DOMAIN/#d" /etc/dnsmasq.conf
  echo "server=/$DOMAIN/$BR_SRV_IP" >> /etc/dnsmasq.conf
  systemctl restart dnsmasq
  log "dnsmasq: неизвестные имена $DOMAIN (_ldap, _kerberos...) пересылаются на BR-SRV"
}

br_srv_2() { br_srv_ntp; br_srv_samba; br_srv_docker; br_srv_ansible
  report "samba-tool user list" "samba-tool group listmembers hq" "samba-tool domain passwordsettings show" \
         "chronyc sources" "docker ps" "docker images" "cat /etc/ansible/hosts" "cat /etc/ansible/ansible.cfg" \
         "cd /etc/ansible && ansible all -m ping"; }

br_srv_ntp() { chrony_client "$ISP_BR"; }

br_srv_samba() {
  command -v samba-tool >/dev/null || die "samba-tool не найден — DC на BR-SRV не установлен?"
  samba-tool domain passwordsettings set --min-pwd-length=8 --account-lockout-threshold=5
  samba-tool group show hq >/dev/null 2>&1 || samba-tool group add hq
  local i members; members=$(samba-tool group listmembers hq 2>/dev/null)
  for i in 1 2 3 4 5; do
    if samba-tool user show "hquser$i" >/dev/null 2>&1; then log "hquser$i уже есть"
    else samba-tool user create "hquser$i" "$PASS"; fi
    grep -qx "hquser$i" <<<"$members" || samba-tool group addmembers hq "hquser$i"
  done
  samba-tool group listmembers hq
  samba-tool domain passwordsettings show | grep -Ei 'length|lockout'
}

br_srv_docker() {
  mount_iso
  local d; d=$(find /mnt/add -maxdepth 2 -type d -iname docker | head -1)
  [ -n "$d" ] || die "в ISO нет папки docker"
  pkg docker-engine || pkg docker-ce
  pkg_any docker-compose-v2 docker-compose
  systemctl enable --now docker
  find "$d" -type f \( -iname '*.tar' -o -iname '*.tar.gz' -o -iname '*latest*' \) | while read -r f; do
    log "docker load $f"; docker load -i "$f"; done
  docker images
  mkdir -p /root/testapp
  cp "$(find /mnt/add -iname 'compose.y*ml' -o -iname 'docker-compose.y*ml' | head -1)" /root/testapp/compose.yaml
  cd /root/testapp || return
  if docker compose version >/dev/null 2>&1; then docker compose up -d; else docker-compose up -d; fi
  cd - >/dev/null
  sleep 10; docker ps
  curl -s -o /dev/null -w "testapp :8080 -> HTTP %{http_code}\n" http://localhost:8080/ \
    || warn "8080 не отвечает — посмотри /root/testapp/compose.yaml (ports: \"8080:...\")"
}

br_srv_ansible() {
  pkg ansible sshpass
  pkg_any python3-module-ansible-pylibssh python3-module-paramiko >/dev/null 2>&1
  mkdir -p /etc/ansible
  cat > /etc/ansible/hosts <<EOF
[hq]
hq-srv ansible_host=$HQ_SRV_IP ansible_port=2027 ansible_user=sshuser ansible_password=$PASS
hq-cli ansible_host=$HQ_CLI_IP ansible_port=22 ansible_user=sshuser ansible_password=$PASS

[routers]
hq-rtr ansible_host=$HQ_SRV_GW
br-rtr ansible_host=$BR_RTR_FW

[routers:vars]
ansible_connection=network_cli
ansible_network_os=ios
ansible_user=net_admin
ansible_password=$PASS
EOF
  cat > /etc/ansible/ansible.cfg <<EOF
[defaults]
inventory = /etc/ansible/hosts
host_key_checking = False
interpreter_python = auto_silent
deprecation_warnings = False
system_warnings = False
action_warnings = False
localhost_warning = False

[persistent_connection]
command_timeout = 30
connect_timeout = 30
EOF
  cd /etc/ansible && ansible all -m ping
  cd - >/dev/null
}

hq_cli_2() { hq_cli_ntp; hq_cli_ssh; hq_cli_domain; hq_cli_sudo; hq_cli_nfs; hq_cli_yandex
  report "realm list 2>/dev/null; cat /etc/krb5.conf | head -20" "id hquser1" "cat /etc/sudoers.d/hq" \
         "grep nfs /etc/fstab" "df -h /mnt/nfs" "chronyc sources" "rpm -qa | grep -i yandex"; }

hq_cli_ntp() { chrony_client "$ISP_HQ"; }

hq_cli_ssh() {   # чтобы ansible с BR-SRV мог зайти на HQ-CLI
  pkg_any openssh-server
  ensure_sshuser; sudo_enable
  echo 'sshuser ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/sshuser; chmod 440 /etc/sudoers.d/sshuser
  systemctl enable --now sshd
}

hq_cli_domain() {
  if system-auth status 2>/dev/null | grep -qi "^ad"; then log "HQ-CLI уже в домене: $(system-auth status | head -1)"; return; fi
  pkg task-auth-ad-sssd || pkg_any task-auth-ad-winbind
  host -t SRV "_ldap._tcp.${DOMAIN}" >/dev/null 2>&1 || warn "SRV-запись домена не резолвится — сначала выполни 'hq-srv dnsad' на HQ-SRV"
  system-auth write ad "$REALM" hq-cli "$WORKGROUP" administrator "$ADMIN_PASS" \
    && log "HQ-CLI введён в домен $REALM (нужна перезагрузка)" || warn "ввод в домен не удался — проверь ADMIN_PASS и DNS"
}

hq_cli_sudo() {
  sudo_enable
  local c g i
  c=$(command -v cat); g=$(command -v grep); i=$(command -v id)
  echo "%hq ALL=(ALL) NOPASSWD: $c, $g, $i" > /etc/sudoers.d/hq
  chmod 440 /etc/sudoers.d/hq
  visudo -c >/dev/null && log "sudo для группы hq: только cat, grep, id"
}

hq_cli_nfs() {
  pkg_any nfs-clients nfs-utils
  mkdir -p /mnt/nfs
  sed -i '\# /mnt/nfs #d' /etc/fstab
  echo "$HQ_SRV_IP:/raid/nfs /mnt/nfs nfs defaults,_netdev 0 0" >> /etc/fstab
  systemctl daemon-reload 2>/dev/null
  mountpoint -q /mnt/nfs || mount /mnt/nfs
  df -h /mnt/nfs
}

hq_cli_yandex() {
  rpm -qa | grep -qi yandex-browser && { log "Яндекс Браузер уже установлен"; return; }
  pkg yandex-browser-stable || pkg yandex-browser || {
    local f=/tmp/yandex.rpm
    curl -fL -o $f "https://repo.yandex.ru/yandex-browser/rpm/stable/x86_64/$(curl -fsL https://repo.yandex.ru/yandex-browser/rpm/stable/x86_64/ | grep -oE 'yandex-browser-stable-[^"]+\.rpm' | sort -V | tail -1)" \
      && apt-get install -y $f </dev/null; }
  rpm -qa | grep -i yandex && log "Яндекс Браузер установлен"
}

br_fw_2() { log "Для BR-FW в Задании 2 ничего настраивать не нужно"; }

# =====================================================================
show_router() {
  local f="ecorouter/$1-$2.txt" here; here=$(dirname "$(readlink -f "$0" 2>/dev/null)")
  if [ -f "$here/$f" ]; then cat "$here/$f"; else curl -fsSL "$RAW/$f" || die "нет файла $f"; fi
}

usage() {
cat <<EOF
Использование:  bash demo.sh <роль> <шаг>
  isp    1 | 2 | ntp
  br-fw  1
  hq-srv 1 | 2 | raid | nfs | ntp | web | dnsad
  br-srv 1 | 2 | ntp | samba | docker | ansible
  hq-cli 1 | 2 | ntp | ssh | domain | sudo | nfs | yandex
  hq-rtr 1 | 2      (EcoRouter — печатает команды для ввода)
  br-rtr 1 | 2
Переменные: VLAN_MODE=host|access  TZONE=$TZONE  ADMIN_PASS=...  WAN_IF/HQ_IF/BR_IF  FW_OUT_IF/FW_IN_IF
EOF
exit 1
}

main() {
  ROLE=$1; STEP=$2
  [ -n "$ROLE" ] && [ -n "$STEP" ] || usage
  case "$ROLE" in
    hq-rtr|br-rtr) show_router "$ROLE" "$STEP"; return ;;
    isp|br-fw|hq-srv|br-srv|hq-cli) ;;
    *) usage ;;
  esac
  [ "$(id -u)" = 0 ] || die "Запускай от root (su -)"
  local fn="${ROLE//-/_}_${STEP}"
  declare -F "$fn" >/dev/null || usage
  log "=== $ROLE : $STEP ==="
  "$fn" 2>&1 | tee -a "/root/demo_${ROLE}.log"
  log "=== готово: $ROLE $STEP  (лог: /root/demo_${ROLE}.log) ==="
}

main "$@"
