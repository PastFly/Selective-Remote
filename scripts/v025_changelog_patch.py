#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sections = {
    "CHANGELOG.md": """## 0.25.0

- Панель Snippets в локальном и SSH-терминале больше не закрывается после выполнения или вставки сниппета; панель остаётся открытой до явного закрытия пользователем.
- Во время ручной проверки обновлений окно «Настройки» временно нельзя закрыть; возможность закрытия автоматически возвращается после завершения проверки.
- Размер и визуальный масштаб кнопок правой панели локального терминала приведены к SSH-интерфейсу.
- Добавлено индивидуальное цветовое оформление каждой локальной и SSH-панели терминала с возможностью оставить глобальную тему или выбрать отдельную палитру.
- Индивидуальная палитра использует уже сохраняемый цвет панели, поэтому выбор восстанавливается вместе с Terminal Workspace.
- Добавлены регрессионные тесты для Snippets, блокировки окна обновлений, размеров локального toolbar и per-pane тем.

""",
    "CHANGELOG_EN.md": """## 0.25.0

- The Snippets panel in local and SSH terminals no longer closes after running or inserting a snippet; it stays open until the user explicitly closes it.
- While a manual update check is running, the Settings window cannot be closed; closing is restored automatically when the check finishes.
- Local Terminal right-side controls now match the SSH toolbar's visual scale.
- Added per-pane terminal color styling for both local and SSH terminals, with either the shared global theme or an individual palette.
- Per-pane palettes reuse the workspace's persisted pane color, so the choice is restored with the Terminal Workspace.
- Added regression coverage for Snippets persistence, update-window locking, local toolbar sizing, and per-pane themes.

""",
}

for relative, section in sections.items():
    path = root / relative
    current = path.read_text(encoding="utf-8")
    if current.startswith("## 0.25.0\n"):
        continue
    path.write_text(section + current, encoding="utf-8")

print("v0.25.0 changelog sections added")
