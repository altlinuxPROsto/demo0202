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
| HQ-RTR | 172.16.1.2/28 (isp), 192.168.0.1/27 (vl100), 192.168.1.1/28 (vl200), 192.168.2.1/29 (vl999), 10.10.10.1/30 (tunnel.0) | 172.16.1.1 |
| BR-RTR | 172.16.2.2/28 (isp), 192.168.3.1/30 (к BR-FW), 10.10.10.2/30 (tunnel.0) | 172.16.2.1 |
| HQ-SRV | 192.168.0.2/27 (VLAN 100) | 192.168.0.1 |
| HQ-CLI | 192.168.1.2/28 (VLAN 200, DHCP) | 192.168.1.1 |
| BR-SRV | 192.168.4.2/28 | 192.168.4.1 |
| BR-FW | 192.168.3.2/30 (к BR-RTR), 192.168.4.1/28 (к BR-SRV) | 192.168.3.1 |

> Сети взяты как на стенде преподавателя. 192.168.100.0/24 не используем: это сеть колледжа,
> из неё ISP получает адрес по DHCP. Туннель оставлен в 10.10.10.0/30, как требует задание.

## Повторный запуск

Любой шаг можно запускать сколько угодно раз: скрипт сам убирает временные адреса от bootstrap и старые
VLAN-подынтерфейсы, не создаёт пользователей повторно, не пересоздаёт RAID и не заливает `dump.sql` второй раз.
Если что-то пошло не так, исправьте причину и просто запустите ту же команду ещё раз.

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
(интерфейс `ens18`, проверить: `ip a`). VLAN-теги стоят в Proxmox (tag=100 у HQ-SRV, tag=200 у HQ-CLI),
поэтому на самих машинах VLAN-подинтерфейсы не создаём.

HQ-SRV:
```bash
ip l del ens18.100 2>/dev/null; ip a flush dev ens18; ip l set ens18 up; ip a add 192.168.0.2/27 dev ens18; ip r replace default via 192.168.0.1; echo nameserver 77.88.8.8 > /etc/resolv.conf
```
BR-FW:
```bash
ip a flush dev ens18; ip l set ens18 up; ip a add 192.168.3.2/30 dev ens18; ip r replace default via 192.168.3.1; echo nameserver 77.88.8.8 > /etc/resolv.conf
```
BR-SRV (только после BR-FW):
```bash
ip a flush dev ens18; ip l set ens18 up; ip a add 192.168.4.2/28 dev ens18; ip r replace default via 192.168.4.1; echo nameserver 77.88.8.8 > /etc/resolv.conf
```
HQ-CLI (адрес приходит по DHCP от HQ-RTR, DNS временно ставим публичный, пока HQ-SRV не настроен):
```bash
nmcli con down "$(nmcli -g GENERAL.CONNECTION dev show ens18)"; nmcli con up "$(nmcli -g GENERAL.CONNECTION dev show ens18)"; echo nameserver 77.88.8.8 > /etc/resolv.conf
```
(первые две команды заново берут адрес по DHCP, если HQ-RTR уже раздаёт новую сеть)

> Если в Proxmox теги НЕ стоят, запускайте с `VLAN_MODE=host`, тогда скрипт сам создаст
> подинтерфейсы `vlan100`/`vlan200`: `VLAN_MODE=host bash <(curl ...) hq-srv 1`.

### Роутеры уже настроены со старыми адресами?

Если HQ-RTR и BR-RTR вводили по прошлой версии (192.168.100.x / 192.168.1.0/27 / 192.168.200.x / 192.168.10.x / 192.168.20.x),
введите поверх:

- HQ-RTR: [ecorouter/hq-rtr-fix.txt](ecorouter/hq-rtr-fix.txt): VLAN 100/200/999, OSPF, NAT, DHCP
- BR-RTR: [ecorouter/br-rtr-fix.txt](ecorouter/br-rtr-fix.txt): сеть к BR-FW, OSPF, NAT

Затем на машинах: bootstrap-строка (из списка выше) и та же команда `... 1` ещё раз:
`br-fw 1`, `hq-srv 1`, `br-srv 1`, `hq-cli 1`. Скрипт сам уберёт старые адреса.

## Задание 2: порядок

| # | Машина | Команда |
|---|---|---|
| 1 | ISP | `isp 2` (chrony, stratum 5) |
| 2 | HQ-RTR | [ecorouter/hq-rtr-2.txt](ecorouter/hq-rtr-2.txt) (проброс 8080 и 2027) |
| 3 | BR-RTR | [ecorouter/br-rtr-2.txt](ecorouter/br-rtr-2.txt) (проброс 8080 и 2027, NTP) |
| 4 | HQ-SRV | `hq-srv 2` (RAID0 md0 → /raid, NFS, chrony, apache+mariadb, DNS для домена) |
| 5 | HQ-CLI | `hq-cli 2` (домен, sudo для hq, NFS, chrony, Яндекс Браузер), затем `reboot` |
| 6 | BR-SRV | `br-srv 2` (пользователи и группа в Samba, docker testapp, ansible) |

Задание 2 делается на отдельном стенде преподавателя, где сеть уже настроена (bootstrap не нужен).
Адреса машин скрипт берёт сам: свой с интерфейса, остальные через DNS стенда (`hq-srv.au-team.irpo` и т.д.)
и печатает их в начале. Если DNS не ответит, подставляются адреса стенда:

| Машина | Адрес на стенде Задания 2 |
|---|---|
| ISP | 172.16.1.1 (к HQ), 172.16.2.1 (к BR), WAN 192.168.100.x по DHCP |
| HQ-RTR | isp 172.16.1.2, hq.100 192.168.0.1/27, hq.200 192.168.1.1/28, hq.999 192.168.2.1/29, tunnel 172.16.0.1/30 |
| BR-RTR | isp 172.16.2.2, br 192.168.3.1/30, tunnel 172.16.0.2/30 |
| HQ-SRV | 192.168.0.2 |
| HQ-CLI | 192.168.1.4 (DHCP, сеть 192.168.1.0/28) |
| BR-FW | 192.168.3.2/30, 192.168.4.1/28 |
| BR-SRV | 192.168.4.2/28, Samba DC `au-team.irpo` / `AU-TEAM` |

Если нужно задать адрес вручную: `T2_HQ_SRV=... T2_BR_SRV=... T2_HQ_CLI=... T2_HQ_CLI_NET=...`.

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
