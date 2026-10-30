# 0.32 — upcoming release copy / черновик заметок

**Historical editorial draft / исторический черновик.** Текущие RU/EN заметки кандидата: [releases/0.32.0-notes.md](../releases/0.32.0-notes.md). Current RU/EN candidate copy is maintained there and is used by the release workflow. The older preparation-only descriptions below predate PR A–C and must not be published as the current candidate state. Public download remains v0.31.0.

Editorial baseline: merged source `d88c57d34967107614aa11fed47b72b256e1b7e9`, tree `3e4e9d1c86f302b6ab92a25bd0e119dfcfd1237e`. This document prepares copy for Owner review. It does not establish release, deployment, signing, migration or acceptance. Recheck the final candidate and gates before publication.

## Long release notes — RU

Selective Remote 0.32 готовится соединить рабочее пространство Mac с Cloud. Personal Vault и Team Vaults дополняют локальные SSH, SFTP, RDP и туннели. Содержимое Vault шифруется на устройстве; для локальной работы аккаунт не требуется.

- **Личное и командное пространство.** Personal Vault предназначен для личных Hosts, Credentials и Snippets. Team Vaults дают командам общие данные, роли, приглашения и проверку устройств.
- **Копия Host для команды.** Личный Host можно скопировать в зашифрованный Team Vault. Копия получает новую идентичность, а исходный Host сохраняется. Это копирование не завершает настройку доступа к отдельным ресурсам.
- **Доступ с предварительным просмотром.** Для зарегистрированных ресурсов в подготавливаемом Vault доступны управление доступом, просмотр его участников и проверка эффективной политики. Перед изменением показывается влияние; сервер повторно проверяет текущие полномочия и подтверждённый просмотр. Политика пользователя и наличие ключа на конкретном устройстве отображаются отдельно. Неизвестное состояние ключа не выдаётся за подтверждённое расшифрование.
- **Центр синхронизации.** Состояние личного и командных Vaults показано раздельно, с последним подтверждением на этом Mac, когда оно доступно, и переходами к повтору или проверке. Доступность сеанса Cloud не означает, что все данные синхронизированы.
- **Уведомления о нужном действии.** Устройства, приглашения, ошибки и конфликты ведут к существующим экранам проверки. Прочтение и решение различаются: событие закрывается после подтверждения источника. Прочтение остаётся локальным; одновременная доставка всем устройствам не обещается.

**Границы 0.32.** Управление доступом к отдельным ресурсам и выбор зарегистрированного ресурса работают только при подготовке Vault. У существующих записей ещё нет готового сквозного соответствия реестру ресурсов. Изменения доступа к криптографически опубликованным ресурсам блокируются до безопасной публикации новой генерации ключей. Автоматическая миграция, реальная доставка ключей отдельных ресурсов и подтверждённое применение этих ресурсов получателем остаются незавершёнными сценариями. Восстановление корня доверия находится в плане **после 0.32**.

Смена пароля аккаунта временно недоступна для сохранения доступа к зашифрованным личным данным. Пароль и другие сессии остаются прежними.

Это описание будущего выпуска. Проверки кандидата, приёмка Cloud и официальной загрузки должны завершиться перед публикацией. Сейчас доступна **v0.31.0**.

## Long release notes — EN

Selective Remote 0.32 is being prepared to connect the Mac workspace with Cloud. Personal Vault and Team Vaults extend local SSH, SFTP, RDP and tunnel workflows. Vault content is encrypted on the device; local work does not require an account.

- **Personal and Team workspaces.** Personal Vault is for your Hosts, Credentials and Snippets. Team Vaults add shared data, roles, invitations and device review.
- **A Host copy for your Team.** Copy a Personal Host into an encrypted Team Vault with a new identity while keeping the original. Copying does not complete resource-specific access setup.
- **Access with a preview.** For registered resources in a Vault being prepared, access tools show recipients and effective policy. Changes show their impact first; the server rechecks current authority and the approved preview. User policy and key availability on a specific device are displayed separately. An unknown key state is not presented as verified decryption.
- **Sync Center.** Personal and Team state are shown separately, with the last confirmation on this Mac when available and routes to retry or review. An available Cloud session does not mean that every Vault is synchronized.
- **Notifications that lead to a decision.** Devices, invitations, errors and conflicts open existing review screens. Reading and resolving are distinct: the source must confirm resolution. Read state remains local; delivery to every device is not promised.

**0.32 boundaries.** Resource access management and the registered-resource picker work only while a Vault is being prepared. Legacy records do not yet have a complete authoritative resource registry mapping. Changes to access for cryptographically published resources remain blocked until safe publication of a new key generation is available. Automatic migration, real resource-key delivery and verified recipient materialization remain unfinished workflows. Trust-root recovery is planned **after 0.32**.

Account password changes are temporarily unavailable to preserve access to existing encrypted Personal Vault data. The password and other sessions remain unchanged.

This describes an upcoming release. Candidate, Cloud and official download acceptance must complete before publication. **v0.31.0** is the current download.

## Short release notes — RU

Будущая 0.32 объединяет Mac и Cloud: Personal Vault, Team Vaults, роли, приглашения и зашифрованное копирование личного Host с сохранением оригинала. Центр синхронизации разделяет состояние Vaults, а уведомления ведут к нужной проверке. Доступ к отдельным зарегистрированным ресурсам настраивается только при подготовке Vault; изменения опубликованного доступа блокируются. Миграция и доставка ключей отдельных ресурсов пока не готовы. Восстановление корня доверия — после 0.32. Доступная загрузка остаётся v0.31.0.

## Short release notes — EN

Upcoming 0.32 connects Mac and Cloud through Personal Vault, Team Vaults, roles, invitations and an encrypted Personal Host copy that keeps the original. Sync Center separates Vault state; notifications open the relevant review. Registered resource access is managed only during Vault preparation; published-access changes stay blocked. Migration and resource-key delivery remain unfinished. Trust-root recovery follows after 0.32. The current download remains v0.31.0.

## What's New — RU

- Mac и Cloud: личные и командные Vaults с шифрованием на устройстве.
- Роли, приглашения и копирование личного Host в Team Vault с сохранением оригинала.
- Предварительный просмотр доступа к зарегистрированным ресурсам при подготовке Vault; политика и ключ устройства показаны отдельно.
- Центр синхронизации и уведомления для перехода к проверке или повтору. Прочтение не закрывает проблему.

0.32 ещё не выпущена. Опубликованный доступ защищён от неподготовленных изменений; миграция и доставка ключей отдельных ресурсов не завершены. Восстановление корня доверия — после 0.32. Сейчас доступна v0.31.0.

## What's New — EN

- Mac and Cloud: Personal and Team Vaults with encryption on the device.
- Roles, invitations and a Personal Host copy to Team Vault that keeps the original.
- Preview access changes for registered resources during Vault preparation; user policy and device keys stay distinct.
- Sync Center and notifications that open review or retry. Reading does not resolve an issue.

0.32 is upcoming. Published access is protected from unsupported changes; migration and resource-key delivery remain unfinished. Trust-root recovery follows after 0.32. v0.31.0 is available now.

## GitHub release body — RU

### Selective Remote 0.32 — предварительное описание

0.32 готовит интеграцию Mac ↔ Cloud с личным Personal Vault и общими Team Vaults. Данные Vault шифруются на устройстве; локальные подключения доступны без аккаунта.

В выпуск входят роли и приглашения, зашифрованная копия личного Host для команды с сохранением оригинала, раздельное состояние личной и командной синхронизации и уведомления, которые ведут к проверке устройств, приглашений или ошибок. Для зарегистрированных ресурсов при подготовке Vault доступны просмотр доступа и подтверждение изменения после просмотра влияния. Политика доступа не заменяет ключ на конкретном устройстве.

**Ограничения:** Access Manager и выбор зарегистрированного ресурса работают только на этапе подготовки; у старых записей ещё требуется подтверждённое соответствие реестру ресурсов. Для опубликованных Vaults заблокированы изменения доступа до готовности безопасной публикации ключей. Автоматическая миграция, доставка ключей отдельных ресурсов и их подтверждённое применение получателем не завершены. Восстановление корня доверия запланировано после 0.32.

Это черновик будущего выпуска, а не объявление о публикации. До завершения приёмки продолжает действовать [загрузка v0.31.0](https://github.com/PastFly/Selective-Remote/releases/tag/v0.31.0). Локальные демонстрационные снимки не подтверждают работу реального Cloud или расшифрование на втором устройстве.

## GitHub release body — EN

### Selective Remote 0.32 — release preview

0.32 prepares Mac ↔ Cloud integration with a Personal Vault and shared Team Vaults. Vault data is encrypted on the device; local connections work without an account.

The release brings roles and invitations, an encrypted Personal Host copy for the Team that keeps the original, separate Personal and Team sync state, and notifications that lead to device, invitation or error review. Registered resources in a Vault being prepared have access review and impact preview before confirmation. Access policy does not replace a usable key on a specific device.

**Limits:** Access Manager and the registered-resource picker work only in the preparation stage; legacy records still need authoritative resource registry mapping. Published Vaults block access changes until safe key publication is available. Automatic migration, resource-key delivery and verified recipient materialization remain unfinished. Trust-root recovery is planned after 0.32.

This is upcoming release copy, not a publication announcement. The [v0.31.0 download](https://github.com/PastFly/Selective-Remote/releases/tag/v0.31.0) remains current until acceptance completes. Local synthetic captures do not establish real Cloud acceptance or decryption on a second device.

## Website summary — RU

Скоро в 0.32: Mac ↔ Cloud, Personal Vault, Team Vaults, зашифрованная копия Host, Центр синхронизации и уведомления. Доступ к отдельным ресурсам настраивается при подготовке Vault; миграция и доставка их ключей пока не готовы. Восстановление корня доверия — после 0.32. Доступная загрузка — v0.31.0.

## Website summary — EN

Coming in 0.32: Mac ↔ Cloud, Personal Vault, Team Vaults, an encrypted Host copy, Sync Center and notifications. Individual resource access is managed during Vault preparation; migration and resource-key delivery remain unfinished. Trust-root recovery follows after 0.32. v0.31.0 is the current download.

## Internal acceptance and publication gates

This checklist records unresolved proof requirements, not claims that runtime checks failed. The release coordinator owns current evidence. Owner retained full0.32 scope on2026-10-01; RC is blocked until mapping/publication/materialization and real migration acceptance complete.

| Gate | Required evidence or decision |
| --- | --- |
| Final candidate | Final immutable source/tree, bounded fix review, required local/CI checks and formal Security result for that candidate; earlier results do not cover later edits. |
| First public Cloud/Teams acceptance | Authorized authenticated HTTPS staging with a clean test account/profile; existing-account and v0.31 upgrade behavior; second device, reload/restart, rejection/revoke/rotation, conflict and source-resolution checks. Local synthetic UI is insufficient. |
| Deployment | Confirm environment ownership, protected backup, complete schema/upgrade dry run, rollback/controller fence, asset/schema/health compatibility and fresh Owner approval before a runtime mutation. |
| V2 scope decision | If public claims include ordinary legacy resource ACL, production V2 migration, READY/ACTIVE access mutation or usable resource-key delivery, the missing mapping/publication/materialization path is a release blocker. Owner retained the full scope on2026-10-01: RC remains BLOCKED until these real flows complete; preparation-only delivery is not an accepted release substitute. |
| Native accessibility | Human keyboard and VoiceOver acceptance of the final candidate; synthetic screenshots or AX names do not establish speech acceptance. |
| Official distribution | Verify Developer ID availability, signing/notarization and the downloaded official DMG. An ad-hoc acceptance RC is not an official release asset. |
| Publication | Fresh Owner authorization for public main mutation/release operations; verified official asset before advancing public feed/download/version metadata. This copy does not grant approval. |

### Claim reconciliation

- The governing Access composition spec and [local QA scope](qa/access-sharing-production.md#production-gates-still-open) explicitly retain PREPARING-only management, no legacy mapping and no real production resource-key delivery. These notes preserve those limits.
- The accepted 1 October release-convergence plan includes Sync/Notifications in the 0.32 candidate. Historical `notification-center-033.md` and post-0.32 plan names are not promises of a second future feature release.
- The linked Cloud architecture document's historical Scope still says full Mac encryption/sync/UI are remaining milestones, although merged main now has those client implementations. Treat that section as stale milestone history and reconcile it before using it as current completion evidence. This document does not edit that architecture contract.
- The older PR #210 audit/spec/QA pages refer to an open Draft. Parent-provided verified state is closed after #220 merge; their crypto/migration leads remain design history, not implemented features.
- Root recovery remains **AFTER032** under the Owner roadmap. Do not substitute guided SSH Known Hosts review for Root recovery or describe Root recovery as implemented.

### Source anchors for editorial claims

| Claim | Inspected source or governing evidence |
| --- | --- |
| Preparation-only registry and writes | `cloud/src/access-surface-store.mjs:32`, `:100`, `:129`; `cloud/src/access-store.mjs:44`; approved Access spec lifecycle/identity sections. |
| Current signed preview / scope / receipt | `cloud/src/service.mjs:329`; `cloud/src/access-store.mjs:88`, `:1100`, `:1114`; `cloud/src/access-surface-store.mjs:381`, `:439`. |
| Policy versus explicit device | `cloud/src/access-store.mjs:719`, `:721`, `:765`, `:780`: wrapper presence is unverified, not decryption proof. |
| Personal Host original retained / encrypted copy | `Sources/SelectiveRemote/PersonalTeamCopyIdentity.swift:18`; `CloudProfileShareView.swift:330`; `CloudTeamVaultSyncCoordinator.swift:429`, `:477`. |
| Scoped sync confirmation | `Sources/SelectiveRemote/SyncPresentation.swift:196`; `SyncCenterView.swift:56`; `cloud/public/app.js` scoped sync presentation and unchecked-Team note. |
| Read versus source resolution | `Sources/SelectiveRemote/NotificationProjection.swift:61`, `:103`, `:109`; `cloud/public/notification-projection.js` reconciliation/read/counts. |

These anchors describe inspected merged-source behavior. Working convergence fixes, final validation, authenticated deployment and distribution evidence must be supplied separately.
