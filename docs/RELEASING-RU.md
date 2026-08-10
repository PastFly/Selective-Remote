# Публикация DMG и обновлений

## 1. Версия и канал обновлений

Перед каждым публичным релизом увеличьте `VERSION` в `scripts/build_app.sh`,
например `0.17.2` → `0.17.3`. `BUILD_NUMBER` тоже должен монотонно расти, но
это только внутренний идентификатор macOS: пользователь его не видит.
Синхронно обновите `version`, `build`, `downloadURL` и `releaseNotesURL` в
`Resources/updates.json`. Обычная сборка уже содержит адрес официального feed:

```text
https://raw.githubusercontent.com/PastFly/Selective-Remote/main/Resources/updates.json
```

## 2. Commit и тег

После успешного CI создайте тег на том же commit:

```bash
git tag -a v0.17.3 -m "Selective Remote 0.17.3"
git push origin v0.17.3
```

Для каждого выпуска создавайте новый тег. Не перемещайте опубликованный тег и
не перезаписывайте его DMG: Release должен оставаться воспроизводимым. GitHub
автоматически предложит архивы исходного кода, но пользователю нужен только
прикреплённый DMG.

## 3. Автоматический Release

Откройте на GitHub **Actions → Release DMG → Run workflow**, укажите существующий
тег и запустите workflow. ARM64 runner установит зависимости, выполнит все
проверки `build_app.sh`, соберёт DMG и SHA-256, создаст отдельный стабильный
Release и отметит его **Latest**. Существующий Release workflow не перезаписывает.

Пока Apple Secrets не настроены, создаётся ad-hoc подписанная preview-сборка:
её можно скачать одним DMG, но первый запуск нужно подтвердить в настройках
безопасности macOS.

## 4. Developer ID и нотариализация

Для обычного запуска на чужих Mac без обхода Gatekeeper нужен активный Apple
Developer Program, сертификат **Developer ID Application** и ключ App Store
Connect API. Добавьте в **Settings → Secrets and variables → Actions**:

- `DEVELOPER_ID_APPLICATION_P12_BASE64` — экспортированный сертификат `.p12`
  в Base64;
- `DEVELOPER_ID_APPLICATION_P12_PASSWORD` — пароль `.p12`;
- `APPLE_API_KEY_P8_BASE64` — содержимое `AuthKey_….p8` в Base64;
- `APPLE_API_KEY_ID` — Key ID;
- `APPLE_API_ISSUER_ID` — Issuer ID.

После этого `Release DMG` автоматически импортирует сертификат во временный
Keychain, включает Hardened Runtime, отправляет DMG через `notarytool`, выполняет
`stapler` и публикует уже нотариализованный файл. Секреты в DMG и журналах не
сохраняются.

Получить Base64 без переносов строк можно на Mac:

```bash
base64 -i DeveloperIDApplication.p12 | tr -d '\n' | pbcopy
base64 -i AuthKey_XXXXXXXXXX.p8 | tr -d '\n' | pbcopy
```

## Локальная проверка пакета

```bash
./scripts/build_app.sh
```

Результат находится в `dist/`. Для публичного распространения без системного
предупреждения macOS нужен сертификат **Developer ID Application** и
нотариализация Apple. Ad-hoc DMG помечайте как preview, а не как доверенный
production-релиз.

Перед релизом проверьте:

- `swift test` и GitHub Actions завершились успешно;
- публичная `VERSION` и внутренний `BUILD_NUMBER` увеличены в `scripts/build_app.sh`;
- приложение запускается на чистом профиле macOS;
- RDP, SSH, SFTP, туннели и отказы в необязательных разрешениях проверены;
- SHA-256 из `dist/*.sha256` приложен к релизу;
- `Resources/updates.json` ссылается ровно на опубликованный DMG;
- журналы, профили и реальные адреса серверов не попали в архив.
