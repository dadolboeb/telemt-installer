# telemt-installer

Интерактивный установщик **telemt** (скачивает **последний релиз** с GitHub Releases), генерирует конфиг и поднимает сервис через **systemd**.

## Что делает скрипт

* Скачивает **latest release** telemt и устанавливает бинарь в: `/usr/local/bin/telemt`
* Создаёт конфиг: `/etc/telemt/telemt.toml`

  * `show_link = ["tgproxy"]`
  * создаёт пользователя `tgproxy` и **генерирует ключ** (`openssl rand -hex 16`)
  * все дефолтные параметры выставлены как в стандартном конфиге
* Создаёт systemd unit: `/etc/systemd/system/telemt.service`
* Запускает сервис и в конце **печатает tg:// ссылку** из логов (`journalctl`)

## Установка

```bash
curl -fsSL https://raw.githubusercontent.com/dadolboeb/telemt-installer/main/telemt-installer.sh -o telemt-installer.sh
chmod +x telemt-installer.sh
sudo ./telemt-installer.sh
```

## Что спросит при установке

Минимальный набор:

* `server.port` (по умолчанию `443`)
* `announce_ip` (внешний IP сервера)
* `tls_domain` (домен faketls для маскировки)
* включать ли метрики (если да — `metrics_port` и `metrics_whitelist`, обывателю абсолютно не надо,  Prometheus'ом собирать удобно)

## Полезные команды

### Статус сервиса

```bash
systemctl status telemt --no-pager
```

### Логи

```bash
journalctl -u telemt -f
```

### Перезапуск после изменения конфига

```bash
sudo systemctl restart telemt
```

## Файлы и пути

* Бинарь: `/usr/local/bin/telemt`
* Конфиг: `/etc/telemt/telemt.toml`
* Systemd unit: `/etc/systemd/system/telemt.service`

## Примечания

* Если на сервере включён firewall — открой TCP-порт, который указал в `server.port`.
* Если включаешь метрики — доступ ограничивается `metrics_whit
