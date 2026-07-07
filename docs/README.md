# Документация FleetOS

Индекс всего, что лежит в `docs/`. Английская краткая версия - в
[корневом README.md](../README.md).

## С чего начать

| Файл | Зачем |
|---|---|
| [quickstart.html](quickstart.html) | 4 шага: поднять мост, поставить на первый компьютер. Начните отсюда. |
| [fleetos_guide.html](fleetos_guide.html) | Полный гайд: мост, установка, дашборд, API-ключ, `fleetctl.py`, разбор проблем. |
| [hardening_guide.html](hardening_guide.html) | Админ/безопасность: read-only ключ, `/health`/`/metrics`, бэкап флота, откат ядра, подпись Raytower. |
| [guide.html](guide.html) | Отдельный гайд именно по триангуляции вышек (Raytower) - калибровка, `raytower.lua`. |

## Техническая документация

| Файл | Зачем |
|---|---|
| [ARCHITECTURE_GATEWAY_CLUSTER.md](ARCHITECTURE_GATEWAY_CLUSTER.md) | Дизайн-документ (не реализовано), кластер шлюзов с выбором лидера, устраняющий мост как единую точку отказа. |

## Смежное

- Разработка своих приложений под ядро: [`../game/apps/README.md`](../game/apps/README.md).
- Спецификация HTTP API моста: [`../windows/openapi.yaml`](../windows/openapi.yaml).
- Конфиги статического анализа: [`../.luacheckrc`](../.luacheckrc) (Lua), [`../windows/setup.cfg`](../windows/setup.cfg) (Python).
