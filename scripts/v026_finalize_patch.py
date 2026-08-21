#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

build = ROOT / "scripts/build_app.sh"
text = build.read_text(encoding="utf-8")
if 'VERSION="0.25.0"' not in text or 'BUILD_NUMBER="136"' not in text:
    raise SystemExit("unexpected build version before v0.26.0 finalization")
text = text.replace('VERSION="0.25.0"', 'VERSION="0.26.0"', 1)
text = text.replace('BUILD_NUMBER="136"', 'BUILD_NUMBER="137"', 1)
build.write_text(text, encoding="utf-8")

ru = '''## 0.26.0

- Добавлен Host Insights поверх Server Context: hostname, uptime, load average, RAM, корневой диск, доступные обновления, listening ports и активные пользователи; метрики используют реальные данные удалённого Linux-хоста и дают быстрый переход к диагностическим командам.
- Автодополнение Terminal стало контекстным: учитывает текущий аргумент команды, `sudo`, историю, избранное, Snippets, Server Commands, systemd-службы и Docker/Podman-контейнеры конкретного сервера.
- SSH-профили получили Startup Snippets с режимами «выключено», «спросить» и «автоматически», а также отдельной настройкой запуска после Smart Reconnect.
- Добавлены безопасные Terminal Variables: встроенные `${HOST}`, `${USER}`, `${PORT}`, `${PROFILE}`, `${GROUP}`, `${OS}`, `${OS_ID}` и пользовательские переменные; имена, похожие на PASSWORD/TOKEN/SECRET/API_KEY, намеренно запрещены — секреты остаются в Keychain.
- Группы SSH теперь могут наследовать отдельные параметры: username, порт, Jump Host, keepalive, Startup Snippet и переменные; каждый параметр можно независимо переопределить в конкретном профиле.
- Добавлены Named Workspaces для SSH и локального Terminal: сохраняются вкладки, их порядок, split/grid, подключения или рабочие папки и полное индивидуальное оформление каждой панели.
- Загрузка Named Workspace безопасна: она разрешена только при отсутствии активных терминальных сессий, восстанавливает структуру в отключённом состоянии и никогда не инициирует SSH-подключения автоматически.
- Добавлены regression-тесты для Host Insights, контекстного autocomplete, Startup Snippets, переменных, группового наследования, persistence и безопасного восстановления Named Workspaces.

'''
en = '''## 0.26.0

- Added Host Insights on top of Server Context: hostname, uptime, load average, RAM, root disk, available updates, listening ports, and logged-in users, using live data from the remote Linux host with quick diagnostic commands.
- Terminal autocomplete is now context-aware: it understands the current command argument and `sudo`, and combines history, favorites, Snippets, Server Commands, systemd services, and Docker/Podman containers from the active host.
- SSH profiles now support Startup Snippets with Disabled, Ask, and Automatic modes plus a separate option for running after Smart Reconnect.
- Added safe Terminal Variables: built-ins `${HOST}`, `${USER}`, `${PORT}`, `${PROFILE}`, `${GROUP}`, `${OS}`, `${OS_ID}` plus user variables; names resembling PASSWORD/TOKEN/SECRET/API_KEY are intentionally rejected so secrets stay in Keychain.
- SSH groups can now inherit selected settings independently: username, port, Jump Host, keepalive, Startup Snippet, and variables, while each profile can override individual fields.
- Added Named Workspaces for SSH and Local Terminal, preserving tabs, order, split/grid layout, connections or working directories, and the complete individual appearance of every pane.
- Named Workspace loading is deliberately safe: it is available only when terminal sessions are stopped, restores a disconnected structure, and never starts SSH connections automatically.
- Added regression coverage for Host Insights, context-aware autocomplete, Startup Snippets, variables, group inheritance, persistence, and safe Named Workspace restoration.

'''

for filename, header in [("CHANGELOG.md", ru), ("CHANGELOG_EN.md", en)]:
    path = ROOT / filename
    body = path.read_text(encoding="utf-8")
    if body.startswith("## 0.26.0"):
        continue
    path.write_text(header + body, encoding="utf-8")

print("v0.26.0 build 137 finalized")
