# Демоэкзамен 09.02.06 — УП 02.02, Задания 1 и 2 (ALT Linux + EcoRouter)

Linux-машины (ISP, BR-FW, HQ-SRV, BR-SRV, HQ-CLI) настраиваются одной командой.
EcoRouter (HQ-RTR, BR-RTR) скриптом не настроить: команды для ввода лежат в [ecorouter/](ecorouter/).

Одна команда на машине (от root, `su -`):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/altlinuxPROsto/demo0202/main/demo.sh) <роль> <задание>
```

## План адресации (Таблица 2)

| Устройство | IP-адрес | Шлюз по умолчанию |
|---|---|---|
| ISP | DHCP (WAN), 172.16.1.1/28 (к HQ), 172.16.2.1/28 (к BR) | от DHCP |
| HQ-RTR | 172.16.1.2/28 (isp), 192.168.100.1/27 (vl100), 192.168.200.1/28 (vl200), 192.168.99.1/29 (vl999), 10.10.10.1/30 (tunnel.0) | 172.16.1.1 |
| BR-RTR | 172.16.2.2/28 (isp), 192.168.10.1/30 (к BR-FW), 10.10.10.2/30 (tunnel.0) | 172.16.2.1 |
| HQ-SRV | 192.168.100.2/27 (VLAN 100) | 192.168.100.1 |
| HQ-CLI | 192.168.200.2/28 (VLAN 200, DHCP) | 192.168.200.1 |
| BR-SRV | 192.168.20.2/28 | 192.168.20.1 |
| BR-FW | 192.168.10.2/30 (к BR-RTR), 192.168.20.1/28 (к BR-SRV) | 192.168.10.1 |

## Задание 1: порядок

| # | Машина | Что сделать |
|---|---|---|
| 1 | ISP | `... demo.sh) isp 1` (интернет уже есть по DHCP) |
| 2 | HQ-RTR | ввести [ecorouter/hq-rtr-1.txt](ecorouter/hq-rtr-1.txt) |
| 3 | BR-RTR | ввести [ecorouter/br-rtr-1.txt](ecorouter/br-rtr-1.txt) |
| 4 | BR-FW | bootstrap, затем `... demo.sh) br-fw 1` |
| 5 | HQ-SRV | bootstrap, затем `... demo.sh) hq-srv 1` |
| 6 | BR-SRV | bootstrap, затем `... demo.sh) br-srv 1` |
| 7 | HQ-CLI | bootstrap, затем `... demo.sh) hq-cli 1` |

Конфиг роутера можно вывести на экран ISP: `bash <(curl -fsSL .../demo.sh) hq-rtr 1`.

### Bootstrap: как дать машине сеть, чтобы она скачала скрипт

Пока скрипт не скачан, у машины нет адреса, поэтому сначала введи одну строку руками
(интерфейс `ens18`, проверить: `ip a`).

HQ-SRV:
```bash
ip l add link ens18 name ens18.100 type vlan id 100; ip l set ens18 up; ip l set ens18.100 up; ip a add 192.168.100.2/27 dev ens18.100; ip r replace default via 192.168.100.1; echo nameserver 77.88.8.8 > /etc/resolv.conf
```
BR-FW:
```bash
ip l set ens18 up; ip a add 192.168.10.2/30 dev ens18; ip r replace default via 192.168.10.1; echo nameserver 77.88.8.8 > /etc/resolv.conf
```
BR-SRV (только после BR-FW):
```bash
ip l set ens18 up; ip a add 192.168.20.2/28 dev ens18; ip r replace default via 192.168.20.1; echo nameserver 77.88.8.8 > /etc/resolv.conf
```
HQ-CLI:
```bash
ip l add link ens18 name ens18.200 type vlan id 200; ip l set ens18.200 up; dhcpcd ens18.200
```

> Если VLAN-теги уже проставлены на сетевых картах ВМ в Proxmox (tag=100 и tag=200),
> VLAN-подинтерфейс на машине не нужен: в bootstrap адрес вешается прямо на `ens18`,
> а скрипт запускается с `VLAN_MODE=access`, например
> `VLAN_MODE=access bash <(curl ...) hq-srv 1`.

## Задание 2: порядок

| # | Машина | Команда |
|---|---|---|
| 1 | ISP | `isp 2` (chrony, stratum 5) |
| 2 | HQ-RTR | [ecorouter/hq-rtr-2.txt](ecorouter/hq-rtr-2.txt) (проброс 8080 и 2027) |
| 3 | BR-RTR | [ecorouter/br-rtr-2.txt](ecorouter/br-rtr-2.txt) (проброс 8080 и 2027, NTP) |
| 4 | HQ-SRV | `hq-srv 2` (RAID0 md0 → /raid, NFS, chrony, apache+mariadb, DNS для домена) |
| 5 | HQ-CLI | `hq-cli 2` (домен, sudo для hq, NFS, chrony, Яндекс Браузер), затем `reboot` |
| 6 | BR-SRV | `br-srv 2` (пользователи и группа в Samba, docker testapp, ansible) |

Шаги можно запускать по отдельности, например `hq-srv web`, `br-srv ansible`, `hq-cli domain`.
Полный список выводит `bash demo.sh` без аргументов.

Пароль администратора Samba DC, если он не `P@ssw0rd`, передаётся так:
`ADMIN_PASS='...' bash <(curl ...) hq-cli 2`.

## Отчёт

После каждого шага в `/root/report_<роль>_task<N>.txt` сохраняются выводы команд
(`ip a`, маршруты, конфиги и т.п.). Их можно скопировать в отчёт. Полный лог лежит в `/root/demo_<роль>.log`.

## Что проверить руками

- Имена портов EcoRouter (`show port brief`): в конфигах указаны `te0` (к ISP) и `te1` (в локалку).
- Порядок сетевых карт на ISP и BR-FW: скрипт печатает, какую карту куда назначил. Если не так,
  передай переменные `WAN_IF/HQ_IF/BR_IF` или `FW_OUT_IF/FW_IN_IF`.
- `index.php` на HQ-SRV: скрипт подставляет `web / P@ssw0rd / webdb` и выводит строки подключения, их стоит проверить.
- `compose.yaml` из ISO: приложение должно публиковаться на порту `8080`.
