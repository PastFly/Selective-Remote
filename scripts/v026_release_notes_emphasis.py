#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def insert_after_heading(path: Path, heading: str, block: str) -> None:
    text = path.read_text(encoding="utf-8")
    marker = heading + "\n\n"
    if block.strip() in text:
        return
    if marker not in text:
        raise SystemExit(f"heading not found in {path}: {heading}")
    text = text.replace(marker, marker + block.rstrip() + "\n\n", 1)
    path.write_text(text, encoding="utf-8")


insert_after_heading(
    ROOT / "CHANGELOG.md",
    "## 0.26.0",
    """> **Важно после обновления — «Объединить пароли».** Если у вас уже есть сохранённые SSH/RDP-пароли, откройте **Связка ключей** и нажмите **«Объединить пароли»**. Selective Remote один раз переносит старые отдельные записи macOS Keychain в единый защищённый Vault. Во время первой миграции macOS ещё может попросить доступ к некоторым старым записям — это требуется только для их чтения. После переноса новые сборки используют одну Vault-запись, поэтому обновление приложения больше не должно превращаться в десятки запросов Keychain для десятков профилей. Расшифрованное содержимое Vault кэшируется только в памяти процесса и исчезает после закрытия приложения.""",
)

insert_after_heading(
    ROOT / "CHANGELOG_EN.md",
    "## 0.26.0",
    """> **Important after updating — Merge Passwords.** If you already have saved SSH/RDP passwords, open **Keychain** and click **Merge Passwords**. Selective Remote performs a one-time migration from the old per-profile macOS Keychain items into one protected unified Vault. macOS may still request access to some legacy items during the first migration because the app must read each old secret once. After migration, future builds use a single Vault item, preventing update-time storms of Keychain prompts across large profile collections. The decoded Vault is cached only in process memory and disappears when the app quits.""",
)

print("v0.26.0 release notes emphasis applied")
