# sudoku-add-instance

Скрипт для управления несколькими инстансами Sudoku-сервера на одном хосте.

Требует установленную базовую конфигурацию (easy-install):

```
/usr/local/bin/sudoku
/etc/sudoku/config.json
```

Каждый новый инстанс получает:

- свою пару ключей (или split-ключ от `--master-key`)
- свой конфиг сервера `/etc/sudoku/config<N>.json`
- свой systemd-юнит `sudoku<N>.service`
- свою короткую ссылку `sudoku://` и YAML-ноду для Mihomo

Ключи клиентов сохраняются в `/etc/sudoku/instances/<name>.env`, чтобы ссылки можно было перегенерировать позже (`--list`).

## Использование

```bash
sudo ./add.sh [options]
```

## Основные команды (режимы)

| Команда | Описание |
|---|---|
| `--list` | Показать все установленные инстансы (ссылки + YAML-ноды), сохранить в файл |
| `--count N` | Создать N инстансов сразу (по умолчанию 1) |
| `--delete N` | Удалить инстанс N (можно повторять: `--delete 3 --delete 5`). База (config.json) не удаляется |
| `--delete-all` | Удалить все дополнительные инстансы (база остаётся) |
| `--delete-all --with-base` | Удалить всё: инстансы + базовую установку (сервисы, /etc/sudoku, правила firewall) |

## Опции

| Опция | Описание |
|---|---|
| `--port PORT` | Порт сервера (по умолчанию случайный свободный в 50001–65535) |
| `--name NAME` | Суффикс инстанса, например `3` → `config3.json` / `sudoku3.service` (только с `--count 1`) |
| `--server-ip HOST` | IP/хост в коротких ссылках (по умолчанию определяется автоматически) |
| `--client-port PORT` | Локальный порт клиентского прокси в ссылках (по умолчанию 10233) |
| `--http-path-root` | HTTP mask path_root (по умолчанию из базового config.json) |
| `--node-name NAME` | Имя ноды в экспортируемом YAML (по умолчанию `sudoku-<инстанс>`) |
| `--master-key HEX` | Деривация split-ключей через `sudoku -keygen -more HEX` |
| `--save FILE` | Сохранить вывод (ссылки + YAML) в FILE. С `--list` по умолчанию `/root/sudoku_saved_<N>.txt` |
| `--force` | Пропустить запрос подтверждения (с `--delete`) |
| `--help` | Показать справку |

## Примеры

Создать один инстанс на конкретном порту:

```bash
sudo ./add.sh --port 53123 --save /root/sudoku_links.txt
```

Создать 5 инстансов сразу:

```bash
sudo ./add.sh --count 5 --save /root/sudoku_bulk.txt
```

Показать все инстансы:

```bash
sudo ./add.sh --list
```

Удалить инстансы 3 и 5 без подтверждения:

```bash
sudo ./add.sh --delete 3 --delete 5 --force
```

Полное удаление вместе с базовой установкой:

```bash
sudo ./add.sh --delete-all --with-base --force
```

## Требования

- root (sudo)
- `jq`
- установленный бинарник `sudoku` и базовый `config.json`