(() => {
  "use strict";

  const STORAGE_KEY = "selective-remote.locale.v1";
  const SUPPORTED_LOCALES = new Set(["ru", "en"]);
  const metadata = {
    ru: {
      title: "Selective Remote Cloud",
      description: "Selective Remote Cloud — защищённая синхронизация Hosts, Credentials, Snippets и Team Vaults с клиентским шифрованием.",
    },
    en: {
      title: "Selective Remote Cloud",
      description: "Selective Remote Cloud — secure synchronization for Hosts, Credentials, Snippets, and Team Vaults with client-side encryption.",
    },
  };

  const en = new Map(Object.entries({
    "Загрузка Selective Remote Cloud": "Loading Selective Remote Cloud",
    "Открываем защищённое пространство…": "Opening your secure workspace…",
    "Разделы страницы": "Page sections",
    "Возможности": "Features",
    "Безопасность": "Security",
    "Для команд": "For teams",
    "Аккаунт": "Account",
    "Тема": "Theme",
    "Тема оформления": "Appearance",
    "Графит": "Graphite",
    "Изумруд": "Emerald",
    "Светлая": "Light",
    "Войти": "Sign in",
    "Создать аккаунт": "Create account",
    "Проверяем доступность Cloud": "Checking Cloud availability",
    "Проверка": "Checking",
    "ПОДТВЕРЖДЕНИЕ EMAIL": "EMAIL VERIFICATION",
    "Проверяем ссылку…": "Checking the link…",
    "Это займёт несколько секунд.": "This will take a few seconds.",
    "Вернуться на главную": "Return home",
    "СБРОС ПАРОЛЯ": "PASSWORD RESET",
    "Задайте новый пароль": "Set a new password",
    "Минимум 12 символов.": "At least 12 characters.",
    "Новый пароль": "New password",
    "Повторите пароль": "Repeat password",
    "Сохранить пароль": "Save password",
    "Ваши подключения — на ваших устройствах": "Your connections — on your devices",
    "Удалённый доступ.": "Remote access.",
    "Без компромиссов.": "Without compromise.",
    "Hosts, Credentials, Snippets и Team Vaults синхронизируются между вашими устройствами. Cloud хранит только зашифрованные ревизии и не видит содержимое.": "Hosts, Credentials, Snippets, and Team Vaults stay synchronized across your devices. Cloud stores encrypted revisions only and cannot see their contents.",
    "Скачать для macOS": "Download for macOS",
    "Начать работу": "Get started",
    "У меня есть аккаунт": "I have an account",
    "Свойства безопасности": "Security properties",
    "✓ Клиентское шифрование": "✓ Client-side encryption",
    "✓ Personal и Team Vaults": "✓ Personal and Team Vaults",
    "Возможности Cloud": "Cloud features",
    "Всё нужное — в одном защищённом пространстве": "Everything you need in one secure workspace",
    "Интерактивная демонстрация возможностей": "Interactive feature demo",
    "Личные и Team": "Personal and Team",
    "Команды": "Commands",
    "Под вашим контролем": "Under your control",
    "Открыть": "Open",
    "← Обзор": "← Overview",
    "Тип Vault в демонстрации": "Vault type in demo",
    "Интерактивная демонстрация": "Interactive demo",
    "Разделы демонстрации": "Demo sections",
    "Демонстрация Hosts": "Hosts demo",
    "Подключения готовы": "Connections ready",
    "· зашифровано": "· encrypted",
    "Демонстрация Credentials": "Credentials demo",
    "Секреты остаются секретами": "Secrets stay secret",
    "· расшифровка на устройстве": "· decrypted on device",
    "Демонстрация Snippets": "Snippets demo",
    "Команды всегда под рукой": "Commands within reach",
    "· параметры локальны": "· parameters stay local",
    "✓ Выполнено локально · секреты не отправлены": "✓ Run locally · secrets were not sent",
    "Демонстрация Devices": "Devices demo",
    "Ваш Vault — ваши устройства": "Your Vault — your devices",
    "· каждый ключ отзывается": "· every key can be revoked",
    "Сейчас · доверенное": "Now · trusted",
    "Синхронизировано": "Synchronized",
    "← На главную": "← Home",
    "Добро пожаловать": "Welcome",
    "Аккаунт Cloud": "Cloud account",
    "Регистрация": "Registration",
    "Проверяем доступность Cloud…": "Checking Cloud availability…",
    "Электронная почта": "Email",
    "Пароль Selective Remote": "Selective Remote password",
    "Минимум 12 символов": "At least 12 characters",
    "Войти в Cloud": "Sign in to Cloud",
    "Не удаётся войти?": "Having trouble signing in?",
    "Ваше имя": "Your name",
    "Как к вам обращаться": "How should we address you?",
    "Логин": "Username",
    "например, leonid": "for example, leonid",
    "Участники команд увидят имя и @логин. Электронная почта останется скрытой.": "Team members will see your name and @username. Your email remains private.",
    "На неё придёт подтверждение": "A confirmation will be sent here",
    "Новый пароль Selective Remote": "New Selective Remote password",
    "Мы отправим одноразовую ссылку подтверждения. Пароли по почте не отправляются и не сохраняются в браузере.": "We will send a one-time confirmation link. Passwords are never emailed or stored in the browser.",
    "Проверьте почту": "Check your inbox",
    "Одноразовая ссылка": "One-time link",
    "Код из одноразовой ссылки": "Code from the one-time link",
    "Создать одноразовую ссылку": "Create one-time link",
    "Вернуться ко входу": "Back to sign in",
    "Отправить ссылку для смены пароля": "Send password reset link",
    "ВАША РАБОЧАЯ ОБЛАСТЬ": "YOUR WORKSPACE",
    "Разделы Cloud": "Cloud sections",
    "Обзор": "Overview",
    "Ресурсы": "Resources",
    "Хосты": "Hosts",
    "Учётные данные": "Credentials",
    "Сниппеты": "Snippets",
    "Туннели и правила": "Tunnels and rules",
    "Командные хранилища": "Team Vaults",
    "Управление командами": "Team management",
    "Настройки": "Settings",
    "О проекте": "About",
    "Навигация по ресурсам": "Resource navigation",
    "Оформление": "Appearance",
    "Выйти": "Sign out",
    "Выйти из Cloud": "Sign out of Cloud",
    "СТАТУС": "STATUS",
    "E2EE активно на этом устройстве": "E2EE is active on this device",
    "Личный Vault": "Personal Vault",
    "Personal Vault заблокирован": "Personal Vault is locked",
    "Войдите в аккаунт, чтобы увидеть личные подключения.": "Sign in to view your personal connections.",
    "Открыть Personal Vault": "Open Personal Vault",
    "Откройте Vault, чтобы увидеть личные подключения.": "Open the Vault to view your personal connections.",
    "Проверяем локальное хранилище…": "Checking local storage…",
    "Заблокировать": "Lock",
    "Синхронизировать": "Synchronize",
    "Новая запись": "New record",
    "Выберите тип и заполните поля. Всё шифруется в браузере.": "Choose a type and complete the fields. Everything is encrypted in the browser.",
    "Тип записи": "Record type",
    "Название": "Name",
    "Адрес": "Address",
    "Дополнительные данные не требуются": "No additional data required",
    "Зашифровать и сохранить": "Encrypt and save",
    "Отменить изменение": "Cancel changes",
    "Поиск": "Search",
    "Название, адрес или папка": "Name, address, or folder",
    "Папка": "Folder",
    "Все папки": "All folders",
    "Типы записей": "Record types",
    "Все": "All",
    "Сортировка": "Sort",
    "Сначала изменённые": "Recently changed first",
    "По названию": "By name",
    "По типу": "By type",
    "Папки команды": "Team folders",
    "Создать папку": "Create folder",
    "Название папки": "Folder name",
    "Например, Работа/Production": "For example, Work/Production",
    "Командные": "Team",
    "Личные": "Personal",
    "Командные хосты": "Team hosts",
    "Доступные команды": "Available teams",
    "Загрузка Teams…": "Loading Teams…",
    "Командное пространство": "Team workspace",
    "Войдите, чтобы открыть командное пространство.": "Sign in to open the team workspace.",
    "Новые приглашения": "New invitations",
    "Приглашения для вашего @username": "Invitations for your @username",
    "Принять": "Accept",
    "Управление Team": "Team management",
    "Участники": "Members",
    "Устройства": "Devices",
    "Управление": "Management",
    "ПАПКИ": "FOLDERS",
    "Создать Team": "Create Team",
    "Роль": "Role",
    "Владелец": "Owner",
    "Администратор": "Administrator",
    "Редактор": "Editor",
    "Просмотр": "Viewer",
    "Добавить участника": "Add member",
    "Имя или @username": "Name or @username",
    "Все роли": "All roles",
    "Участники не найдены.": "No members found.",
    "Сохранить роль": "Save role",
    "Допустить устройства": "Approve devices",
    "Активные приглашения": "Active invitations",
    "Пригласить по @username": "Invite by @username",
    "Отправить по email": "Send by email",
    "Роль в команде": "Team role",
    "Архивировать Team": "Archive Team",
    "Передать владение": "Transfer ownership",
    "Новый Owner": "New Owner",
    "Введите точное название Team": "Enter the exact Team name",
    "Переименовать": "Rename",
    "Новое название": "New name",
    "Сохранить название": "Save name",
    "Устройства доступа": "Access devices",
    "Обновить устройства": "Refresh devices",
    "Одобряйте только свои устройства и сравнивайте SHA-256 отпечаток на обоих экранах.": "Approve only your own devices and compare the SHA-256 fingerprint on both screens.",
    "Отзыв устройства немедленно завершает связанные сессии. Для Shared Vaults после отзыва потребуется ротация ключа.": "Revoking a device immediately ends its sessions. Shared Vault keys must be rotated afterward.",
    "Обновить": "Refresh",
    "Завершить ротацию": "Complete rotation",
    "Настройки аккаунта": "Account settings",
    "Управление аккаунтом Selective Remote Cloud.": "Manage your Selective Remote Cloud account.",
    "Публичный username": "Public username",
    "Используется для приглашений в команды. Username должен быть уникальным.": "Used for team invitations. Your username must be unique.",
    "Новый username": "New username",
    "Текущий пароль": "Current password",
    "Изменить username": "Change username",
    "Изменить пароль": "Change password",
    "Повторите новый пароль": "Repeat new password",
    "После изменения остальные активные сессии будут завершены.": "Other active sessions will end after the change.",
    "Удалить аккаунт": "Delete account",
    "Будут безвозвратно удалены Personal Vault, устройства и все сессии. Доступ к Team Vaults будет отозван.": "Your Personal Vault, devices, and all sessions will be permanently deleted. Team Vault access will be revoked.",
    "Если вы Owner активной Team, сначала передайте владение другому участнику или архивируйте Team.": "If you own an active Team, transfer ownership or archive it first.",
    "Введите точный email аккаунта": "Enter the account email exactly",
    "Я понимаю, что Personal Vault и аккаунт восстановить нельзя.": "I understand that the Personal Vault and account cannot be recovered.",
    "Удалить аккаунт безвозвратно": "Delete account permanently",
    "О проекте": "About",
    "Возможности проекта": "Project features",
    "Все удалённые подключения в одном приложении": "All remote connections in one app",
    "Selective Remote объединяет RDP, SSH, SFTP, туннели, команды и зашифрованные Vaults — без передачи открытых данных серверу.": "Selective Remote combines RDP, SSH, SFTP, tunnels, commands, and encrypted Vaults without sending plaintext data to the server.",
    "Нативное управление подключениями": "Native connection management",
    "Нативно на Mac.": "Native on Mac.",
    "Сквозное шифрование": "End-to-end encryption",
    "Шифрование на устройстве": "Encryption on device",
    "Раздельные Vaults": "Separate Vaults",
    "Для личной работы и команды": "For personal and team work",
    "Поддержка автора": "Support the author",
    "Помогите проекту развиваться": "Help the project grow",
    "Поддержка помогает оплачивать инфраструктуру Cloud и уделять больше времени новым функциям, стабильности и безопасности.": "Your support helps cover Cloud infrastructure and makes more time for new features, stability, and security.",
    "Любая сумма добровольна. Основные возможности Selective Remote остаются открытыми.": "Every contribution is optional. The core Selective Remote features remain open.",
    "Перевод через банк": "Bank transfer",
    "Разовый перевод": "One-time contribution",
    "Открыть проект на GitHub ↗": "Open project on GitHub ↗",
    "НОВОСТИ И ОБРАТНАЯ СВЯЗЬ": "NEWS AND FEEDBACK",
    "Selective Remote в Telegram": "Selective Remote on Telegram",
    "Анонсы новых версий, важные обновления и связь с автором проекта — в официальном канале.": "Release announcements, important updates, and direct contact with the author are available in the official channel.",
    "Перейти ↗": "Open ↗",
    "Ваше рабочее пространство уже ждёт": "Your workspace is ready",
    "Начните с личного Vault и подключите командные возможности, когда они понадобятся.": "Start with your Personal Vault and enable team features when you need them.",
    "ПРОВЕРКА ДЕЙСТВИЯ": "ACTION CHECK",
    "Подтвердите действие": "Confirm action",
    "Отмена": "Cancel",
    "Подтвердить": "Confirm",
    "Закрыть": "Close",
    "Изменить": "Edit",
    "Удалить": "Delete",
    "Создать": "Create",
    "Сохранить выбранные версии": "Save selected versions",
    "Конфликт Team-ревизий": "Team revision conflict",
    "Выберите одну версию каждой записи. Секреты и содержимое здесь не отображаются.": "Choose one version for each record. Secrets and record contents are not shown here.",
    "Протокол": "Protocol",
    "Порт": "Port",
    "Пароль": "Password",
    "Удалить пароль": "Remove password",
    "Теги": "Tags",
    "Описание": "Description",
    "Пусто — оставить существующий пароль": "Leave empty to keep the existing password",
    "Например, Production": "For example, Production",
    "Назначение и примечания для команды": "Purpose and notes for the team",
    "Зашифровать локально": "Encrypt locally",
    "Название, адрес, тег или описание": "Name, address, tag, or description",
    "Добавить запись": "Add record",
    "Добавить Host": "Add Host",
    "＋ Добавить Host": "＋ Add Host",
    "＋ Новый Host": "＋ New Host",
    "Копировать адрес": "Copy address",
    "Копировать пароль": "Copy password",
    "Открыть SSH": "Open SSH",
    "Открыть SFTP": "Open SFTP",
    "⌕ Поиск по Production": "⌕ Search Production",
    "● Зашифровано": "● Encrypted",
    "★ Все подключения": "★ All connections",
    "3 из 4 Hosts": "3 of 4 Hosts",
    "3 подключения": "3 connections",
    "Автоматический допуск": "Automatic approval",
    "Агент выполнения ещё не подключён": "Execution agent is not connected yet",
    "Адрес, папка и настройки подключения сохраняются в вашем Vault.": "The address, folder, and connection settings are stored in your Vault.",
    "Включено по умолчанию. Owner принимает риск входа участника с нового устройства.": "Enabled by default. The Owner accepts the risk of a member signing in from a new device.",
    "Выберите одну версию для каждой записи. Секретные поля и содержимое записей здесь не показываются.": "Choose one version for each record. Secret fields and record contents are not shown here.",
    "Данные превращаются в зашифрованную ревизию на вашем устройстве. Сервер управляет сессиями, устройствами и версиями — но не получает открытое содержимое Vault.": "Data becomes an encrypted revision on your device. The server manages sessions, devices, and versions, but never receives plaintext Vault contents.",
    "Два полноценных интерфейса одного Vault. Все адреса и названия ниже вымышлены и существуют только для демонстрации.": "Two complete interfaces for one Vault. All addresses and names below are fictional and used only for this demo.",
    "Для запуска Snippet потребуется доверенный онлайн‑Mac. Cloud не получает SSH‑пароль или приватный ключ.": "Running a Snippet requires a trusted Mac that is online. Cloud never receives the SSH password or private key.",
    "До отправки в Cloud": "Before sending to Cloud",
    "Доверенный браузер получает ревизию и открывает её своим локальным ключом.": "A trusted browser receives the revision and opens it with its local key.",
    "ДОВЕРИЕ К УСТРОЙСТВАМ": "DEVICE TRUST",
    "Допускать новые устройства автоматически": "Approve new devices automatically",
    "Доступно в Cloud.": "Available in Cloud.",
    "Другие способы": "Other options",
    "Другие устройства получают ревизию": "Other devices receive the revision",
    "Загружаем команды…": "Loading teams…",
    "Закрыть карточку Host": "Close Host card",
    "И расшифровывают локально": "And decrypt it locally",
    "ИЗБРАННОЕ": "FAVORITES",
    "Изменён": "Changed",
    "Изменения синхронизируются автоматически. Дополнительные действия появятся только при устранимой ошибке доступа.": "Changes synchronize automatically. Additional actions appear only when an access issue can be resolved.",
    "Как работает защищённая синхронизация": "How secure synchronization works",
    "Командный доступ из браузера": "Team access from the browser",
    "Локальный режим": "Local mode",
    "На Mac или в браузере": "On Mac or in the browser",
    "Название, адрес, логин или папка": "Name, address, username, or folder",
    "Новые устройства активных участников автоматически получают доступ к текущему членству в Team. Доверенный браузер или приложение с доступом к Vault автоматически выдаст им wrapper — открывать папку вручную не требуется, ключ хранилища не передаётся серверу.": "New devices belonging to active members automatically gain access for the current Team membership. A trusted browser or app with Vault access issues the wrapper automatically; the folder does not need to be opened manually, and the Vault key is never sent to the server.",
    "Область ресурсов": "Resource area",
    "Обновлено сейчас": "Updated now",
    "Общие Vaults, папки, роли и приглашения для безопасной совместной работы.": "Shared Vaults, folders, roles, and invitations for secure collaboration.",
    "ОДИН VAULT · ДВА ИНТЕРФЕЙСА": "ONE VAULT · TWO INTERFACES",
    "ОДНО ДЕЙСТВИЕ · ДВА УСТРОЙСТВА": "ONE ACTION · TWO DEVICES",
    "ОДНО ПРОСТРАНСТВО": "ONE WORKSPACE",
    "Открытый профиль не покидает ваше устройство: в Cloud отправляется только зашифрованная ревизия, которую второе доверенное устройство расшифровывает локально.": "The open profile never leaves your device. Only an encrypted revision is sent to Cloud, and another trusted device decrypts it locally.",
    "Открыть команды": "Open teams",
    "ПАПКА": "FOLDER",
    "Папка команды": "Team folder",
    "Папка Hosts": "Hosts folder",
    "По @username": "By @username",
    "Повторить безопасную выдачу wrappers": "Retry secure wrapper provisioning",
    "Повторить безопасную синхронизацию": "Retry secure synchronization",
    "ПОДДЕРЖАТЬ РАЗРАБОТКУ": "SUPPORT DEVELOPMENT",
    "Подключения": "Connections",
    "Подключения и файлы": "Connections and files",
    "Подключения и Vaults": "Connections and Vaults",
    "Подойдёт, если вы хотите передать ссылку самостоятельно.": "Use this when you want to share the link yourself.",
    "Показать ещё": "Show more",
    "Потом синхронизация.": "Then synchronization.",
    "Приглашение можно принять в течение 48 часов. Затем оно автоматически истечёт.": "The invitation can be accepted within 48 hours and then expires automatically.",
    "Принять приглашение по ссылке": "Accept invitation by link",
    "Продолжили в браузере.": "Continued in the browser.",
    "Публичный @username": "Public @username",
    "Роли и ключи проверяются сервером независимо от зашифрованного содержимого.": "The server validates roles and keys independently of encrypted content.",
    "Сбер": "Sber",
    "Секреты и учётные записи": "Secrets and credentials",
    "Сервер проверяет аккаунт отдельно от зашифрованного содержимого Vault.": "The server validates the account separately from encrypted Vault contents.",
    "Синтетический макет Selective Remote для macOS": "Synthetic Selective Remote mockup for macOS",
    "Синтетический макет Selective Remote Cloud": "Synthetic Selective Remote Cloud mockup",
    "Синхронизировано сейчас": "Synchronized now",
    "Скопировать ссылку": "Copy link",
    "Сначала шифрование.": "Encryption first.",
    "Создаёте подключение": "Create a connection",
    "Создаёте Host": "Create a Host",
    "Создали Host на Mac.": "Created a Host on Mac.",
    "Сортировка⌄": "Sort⌄",
    "Сохранённые команды": "Saved commands",
    "Сохранить выбранные версии локально": "Save selected versions locally",
    "Сценарий синхронизации Host": "Host synchronization flow",
    "Типы командных ресурсов": "Team resource types",
    "Только Owner может переименовать Team, передать владение или архивировать её.": "Only the Owner can rename the Team, transfer ownership, or archive it.",
    "Требуется разрешить конфликты": "Conflicts must be resolved",
    "Удалённое выполнение": "Remote execution",
    "Устройство шифрует": "The device encrypts",
    "Устройство шифрует Vault": "The device encrypts the Vault",
    "ШАГ 01 · macOS": "STEP 01 · macOS",
    "ШАГ 02 · E2EE": "STEP 02 · E2EE",
    "ШАГ 03 · Browser": "STEP 03 · Browser",
    "Электронная почта аккаунта": "Account email",
    "ЮMoney": "YooMoney",
    "Cloud остаётся дополнением: приложение продолжает полноценно работать автономно.": "Cloud remains optional: the app continues to work fully offline.",
    "Cloud получает новую версию ciphertext, но не Host и не его Credentials.": "Cloud receives a new ciphertext version, but not the Host or its Credentials.",
    "Host появляется рядом": "The Host appears on the other device",
    "Hosts, пароли, SSH-настройки и Snippets синхронизируются между вашими устройствами.": "Hosts, passwords, SSH settings, and Snippets synchronize across your devices.",
    "Mac и браузеры": "Mac and browsers",
    "Personal и Team": "Personal and Team",
    "postgres · только Personal": "postgres · Personal only",
    "RDP и SSH": "RDP and SSH",
    "RDP и SSH подключения": "RDP and SSH connections",
    "root · обновлено сейчас": "root · updated now",
    "Selective Remote объединяет подключения и автоматизацию, не заставляя отдавать серверу ключи от вашей инфраструктуры.": "Selective Remote combines connections and automation without requiring you to give the server the keys to your infrastructure.",
    "Selective Remote Cloud — защищённая синхронизация Hosts, Credentials, Snippets и Team Vaults с клиентским шифрованием.": "Selective Remote Cloud — secure synchronization for Hosts, Credentials, Snippets, and Team Vaults with client-side encryption.",
    "Vault заблокирован.": "Vault is locked."
  }));

  for (const [source, translation] of Object.entries({
    "Автоматически обновляем ключ и доступы оставшихся участников…": "Updating the key and access for remaining members automatically…",
    "Автоматически обновляем ключи командных папок перед приглашением…": "Updating Team folder keys before creating the invitation…",
    "Автоматический режим активен. Ручная проверка остаётся доступна в меню участника.": "Automatic mode is active. Manual review remains available in the member menu.",
    "Автоматический режим включён владельцем Team.": "Automatic mode was enabled by the Team Owner.",
    "Автоматический режим выключен. Новые устройства потребуют ручного допуска.": "Automatic mode is off. New devices will require manual approval.",
    "Автосинхронизация временно недоступна; локальные данные сохранены, повторим автоматически.": "Automatic synchronization is temporarily unavailable. Local data is safe and the operation will retry automatically.",
    "Адрес Host скопирован без передачи в Cloud.": "The Host address was copied without being sent to Cloud.",
    "Аккаунт создан. Пароль не отправлялся по почте и не был сохранён в браузере.": "Account created. The password was neither emailed nor stored in the browser.",
    "Аккаунт удалён. Все Cloud-сессии завершены.": "Account deleted. All Cloud sessions have ended.",
    "Активных приглашений нет.": "There are no active invitations.",
    "Архивировать": "Archive",
    "Архивировать Team?": "Archive Team?",
    "Без названия": "Untitled",
    "Без папки": "No folder",
    "Браузер не разрешил доступ к буферу обмена.": "The browser denied clipboard access.",
    "Браузер не смог сохранить локальную зашифрованную копию.": "The browser could not save the local encrypted copy.",
    "Включить": "Enable",
    "Включить автоматический допуск?": "Enable automatic approval?",
    "Владелец Team выбрал ручной допуск устройств.": "The Team Owner selected manual device approval.",
    "Владение не передано: проверьте пароль, участника и полномочия Owner.": "Ownership was not transferred. Check the password, member, and Owner permissions.",
    "Владение передано. Ваша роль изменена на Admin.": "Ownership transferred. Your role is now Admin.",
    "Войдите в аккаунт, затем примите одноразовое Team-приглашение в разделе «Команды».": "Sign in, then accept the one-time Team invitation in the Teams section.",
    "Войдите в аккаунт, чтобы открыть Personal Vault на этом устройстве.": "Sign in to open Personal Vault on this device.",
    "Все актуальные авторизованные устройства уже имеют wrapper этой генерации.": "All current authorized devices already have a wrapper for this generation.",
    "Все прежние сессии отозваны. Теперь войдите с новым паролем.": "All previous sessions were revoked. Sign in with the new password.",
    "Вход выполнен. Сессия защищена HttpOnly cookie; пароль не сохранён.": "Signed in. The session is protected by an HttpOnly cookie; the password was not stored.",
    "Вход выполнен. Team-ключ недоступен в этом браузере; личный Vault продолжает работать.": "Signed in. The Team key is unavailable in this browser; Personal Vault remains available.",
    "Вход выполнен. Team-раздел временно недоступен; личный Vault и сессия продолжают работать.": "Signed in. The Team area is temporarily unavailable; Personal Vault and the session remain active.",
    "Выбранный участник станет Owner, а ваша роль изменится на Admin.": "The selected member will become Owner and your role will change to Admin.",
    "Данные команды обновлены.": "Team data updated.",
    "Данные расшифрованы локально только для этой вкладки.": "Data was decrypted locally for this tab only.",
    "Для этого браузера пока нет wrapper ключа. Оставьте доверенный браузер или приложение участника с доступом к Team Vault подключённым к Cloud.": "This browser does not have a key wrapper yet. Keep a trusted browser or member app with Team Vault access connected to Cloud.",
    "Для этого устройства пока нет wrapper ключа. Ожидаем автоматическую выдачу от любого активного участника с текущим ключом.": "This device does not have a key wrapper yet. Waiting for automatic provisioning by an active member with the current key.",
    "Добавить Credential": "Add Credential",
    "Добавить Forwarding": "Add Forwarding",
    "Добавить Snippet": "Add Snippet",
    "Допуск устройств отменён; ключи и wrappers не изменены.": "Device approval was cancelled; keys and wrappers were not changed.",
    "Допустимы латинские буквы, цифры, точка, дефис и подчёркивание.": "Latin letters, digits, dots, hyphens, and underscores are allowed.",
    "Допустить устройство": "Approve device",
    "Допустить устройство участника?": "Approve member device?",
    "Доступ не отозван: проверьте полномочия и правило последнего Owner.": "Access was not revoked. Check permissions and the last-Owner rule.",
    "Доступ отозван.": "Access revoked.",
    "Если аккаунт существует, ссылка для смены пароля уже отправлена.": "If the account exists, a password reset link has been sent.",
    "Завершить ротацию ключа?": "Complete key rotation?",
    "Загружаем зашифрованную Team-ревизию…": "Loading the encrypted Team revision…",
    "Записей этого типа пока нет.": "There are no records of this type yet.",
    "Запись временно приостановлена. Ключ и доступы оставшихся участников обновляются автоматически…": "The write is temporarily paused while keys and access for remaining members update automatically…",
    "Запись локально зашифрована и сохранена.": "The record was encrypted and saved locally.",
    "Запись не сохранена. Проверьте поля и роль.": "The record was not saved. Check the fields and your role.",
    "Запись удалена. Tombstone сохранён в зашифрованном Vault.": "The record was deleted. Its tombstone is stored in the encrypted Vault.",
    "Изменение зашифровано локально и будет синхронизировано автоматически.": "The change was encrypted locally and will synchronize automatically.",
    "Изменение отменено.": "Changes cancelled.",
    "Изменения зашифрованы и сохранены.": "Changes encrypted and saved.",
    "Измените нужные поля и сохраните новую зашифрованную версию записи.": "Update the required fields and save a new encrypted record version.",
    "Измените Host и сохраните зашифрованную запись.": "Edit the Host and save the encrypted record.",
    "Имя пользователя": "Username",
    "Ключ не одобрен: требуется уже одобренное текущее устройство и совпадающий отпечаток.": "The key was not approved. An already approved current device and matching fingerprint are required.",
    "Ключ устройства одобрен. Любой активный участник с текущим Team Vault key автоматически выдаст недостающий wrapper.": "The device key was approved. Any active member with the current Team Vault key will automatically provision the missing wrapper.",
    "Ключ Shared Vault удалён из памяти. Откройте выбранный Vault снова для локального unlock.": "The Shared Vault key was removed from memory. Open the selected Vault again to unlock it locally.",
    "Ключи командных папок ещё обновляются. Приглашение будет доступно автоматически после завершения; повторите через несколько секунд.": "Team folder keys are still updating. The invitation will become available automatically; try again in a few seconds.",
    "Команд пока нет. Создайте Team или примите приглашение.": "There are no teams yet. Create a Team or accept an invitation.",
    "Командный Vault": "Team Vault",
    "Конфликты разрешены локально. Повторите безопасную ротацию.": "Conflicts were resolved locally. Retry secure rotation.",
    "Конфликты разрешены локально. Условная запись будет синхронизирована автоматически.": "Conflicts were resolved locally. The conditional write will synchronize automatically.",
    "Локальная зашифрованная копия несовместима или повреждена; серверная версия не перезаписана.": "The local encrypted copy is incompatible or damaged; the server version was not overwritten.",
    "Локальная зашифрованная копия сохранена. Синхронизация продолжится автоматически.": "The local encrypted copy is safe. Synchronization will continue automatically.",
    "Локальное защищённое хранилище недоступно в этом браузере.": "Secure local storage is unavailable in this browser.",
    "Локальные данные сохранены. Синхронизация продолжится автоматически.": "Local data is safe. Synchronization will continue automatically.",
    "Минимум 3 символа.": "At least 3 characters.",
    "Мы отправим одноразовую ссылку для смены пароля, если аккаунт существует.": "If the account exists, we will send a one-time password reset link.",
    "Набор конфликтов устарел или выбран не полностью. Запустите синхронизацию ещё раз.": "The conflict set is outdated or incomplete. Start synchronization again.",
    "Набор конфликтов устарел. Запустите синхронизацию ещё раз.": "The conflict set is outdated. Start synchronization again.",
    "Название Team обновлено.": "Team name updated.",
    "Назначение": "Destination",
    "Не все wrappers подтверждены. Автоматический цикл безопасно повторит выдачу.": "Not all wrappers were confirmed. The automatic cycle will retry provisioning safely.",
    "Не сохранён": "Not saved",
    "Не удалось войти. Проверьте соединение и повторите попытку.": "Could not sign in. Check the connection and try again.",
    "Не удалось выполнить поиск участников.": "Could not search for members.",
    "Не удалось загрузить следующую страницу участников.": "Could not load the next page of members.",
    "Не удалось загрузить список для передачи владения.": "Could not load the ownership transfer list.",
    "Не удалось загрузить Team.": "Could not load the Team.",
    "Не удалось запросить восстановление. Повторите позже.": "Could not request recovery. Try again later.",
    "Не удалось изменить пароль. Ссылка могла истечь или уже была использована.": "Could not change the password. The link may have expired or already been used.",
    "Не удалось обновить данные команды. Повторим автоматически.": "Could not update Team data. The operation will retry automatically.",
    "Не удалось применить фильтр роли.": "Could not apply the role filter.",
    "Не удалось скопировать автоматически. Скопируйте выделенную ссылку вручную.": "Could not copy automatically. Copy the selected link manually.",
    "Не удалось создать аккаунт. Проверьте поля и повторите попытку.": "Could not create the account. Check the fields and try again.",
    "Не удалось сохранить запись. Заполните обязательные поля.": "Could not save the record. Complete the required fields.",
    "Не удалось сохранить удаление.": "Could not save the deletion.",
    "Не удалось удалить ключ доверенного браузера. Vault оставлен открытым.": "Could not remove the trusted browser key. The Vault remains open.",
    "Неверная электронная почта или пароль.": "Incorrect email or password.",
    "НЕОБРАТИМОЕ ДЕЙСТВИЕ": "IRREVERSIBLE ACTION",
    "Новая запись. Заполните поля и сохраните зашифрованную версию.": "New record. Complete the fields and save the encrypted version.",
    "НОВОЕ УСТРОЙСТВО": "NEW DEVICE",
    "Новые зарегистрированные устройства активных участников будут допускаться к текущему членству автоматически. Вход участника на новом устройстве считается достаточным сигналом доверия.": "New registered devices belonging to active members will be approved for the current membership automatically. A member signing in on a new device is treated as sufficient trust.",
    "Новые пароли не совпадают.": "The new passwords do not match.",
    "Новый пароль должен содержать не менее 12 символов.": "The new password must contain at least 12 characters.",
    "Новых приглашений нет.": "There are no new invitations.",
    "Обновляем…": "Updating…",
    "Одноразовая ссылка не создана. Проверьте роль и полномочия.": "The one-time link was not created. Check the role and permissions.",
    "Одноразовая ссылка недействительна, уже использована, отозвана или истекла.": "The one-time link is invalid, used, revoked, or expired.",
    "Одноразовая ссылка приглашения недействительна.": "The one-time invitation link is invalid.",
    "Одноразовая ссылка скопирована.": "The one-time link was copied.",
    "Одноразовая ссылка создана на 48 часов. Передайте её только нужному участнику.": "A one-time link was created for 48 hours. Share it only with the intended member.",
    "Одобрить ключ": "Approve key",
    "Одобрить ключ устройства?": "Approve device key?",
    "Одобрить устройство": "Approve device",
    "Ожидаем, пока устройство с текущим Team Vault key автоматически выдаст wrapper этому браузеру.": "Waiting for a device with the current Team Vault key to provision a wrapper for this browser automatically.",
    "Она могла истечь или уже была использована.": "It may have expired or already been used.",
    "Она могла истечь или уже была использована. Запросите новое письмо позже.": "It may have expired or already been used. Request another email later.",
    "Основные поля и организация Host синхронизируются с приложением. Расширенные SSH/RDP-параметры сохраняются без изменений.": "Core Host fields and organization synchronize with the app. Advanced SSH/RDP settings remain unchanged.",
    "Отменить": "Cancel",
    "Отменить создание": "Cancel creation",
    "Отозвать": "Revoke",
    "Отозвать доступ": "Revoke access",
    "Отозвать доступ участника?": "Revoke member access?",
    "Отозвать приглашение?": "Revoke invitation?",
    "Отозвать устройство?": "Revoke device?",
    "Папка команды пока пуста.": "The Team folder is empty.",
    "Папка команды создана. Перейдите в «Хосты команд», чтобы добавить или открыть Host.": "The Team folder was created. Open Team Hosts to add or open a Host.",
    "Папки команд": "Team folders",
    "Параметры": "Parameters",
    "Пароли не совпадают.": "Passwords do not match.",
    "Пароль изменён": "Password changed",
    "Пароль изменён. Остальные сессии завершены.": "Password changed. Other sessions have ended.",
    "Пароль Host скопирован локально. Cloud plaintext не получал.": "The Host password was copied locally. Cloud did not receive plaintext.",
    "Передать владение Team?": "Transfer Team ownership?",
    "Подтвердите действие.": "Confirm the action.",
    "Поколение ключа изменилось. Повторно откройте Team Vault после синхронизации доверенного устройства.": "The key generation changed. Reopen Team Vault after a trusted device synchronizes.",
    "Политика не изменена. Обновите страницу и повторите попытку.": "The policy was not changed. Refresh the page and try again.",
    "ПОЛИТИКА TEAM": "TEAM POLICY",
    "Полная текущая Team-ревизия будет зашифрована новым ключом, а wrappers получат только актуальные авторизованные устройства.": "The complete current Team revision will be encrypted with a new key, and wrappers will be issued only to current authorized devices.",
    "Полный профиль создан в приложении: в браузере можно менять папку, теги и описание.": "The full profile was created in the app. You can edit its folder, tags, and description in the browser.",
    "Почтовый сервис временно не настроен.": "The email service is temporarily unavailable.",
    "Прежнее email-приглашение": "Legacy email invitation",
    "Приглашение не отозвано. Обновите список и повторите попытку.": "The invitation was not revoked. Refresh the list and try again.",
    "Приглашение не создано. Проверьте @username, роль и полномочия.": "The invitation was not created. Check the @username, role, and permissions.",
    "Приглашение недействительно, уже использовано, отозвано или истекло.": "The invitation is invalid, used, revoked, or expired.",
    "Приглашение отменено: не удалось заранее подготовить доступ ко всем папкам команды. Синхронизируйте их и повторите.": "The invitation was cancelled because access to every Team folder could not be prepared. Synchronize them and try again.",
    "Приглашение отозвано.": "Invitation revoked.",
    "Приглашение по @username создано на 48 часов.": "The @username invitation was created for 48 hours.",
    "Приглашение принято.": "Invitation accepted.",
    "Приглашение создано. Доступ к текущим Team Vault подготовлен заранее — приглашающий может выйти.": "Invitation created. Access to current Team Vaults was prepared in advance, so the inviter can go offline.",
    "Приглашение уже отозвано, использовано или истекло.": "The invitation was already revoked, used, or expired.",
    "Проверить доступ снова": "Check access again",
    "Проверьте формат username.": "Check the username format.",
    "Регистрационное окно уже закрыто. Обновите страницу позже.": "The registration window has closed. Refresh the page later.",
    "Регистрация временно закрыта. Обновите страницу после открытия регистрационного окна.": "Registration is temporarily closed. Refresh the page when the registration window opens.",
    "Регистрация временно закрыта. Уже подтверждённые аккаунты могут войти.": "Registration is temporarily closed. Verified accounts can still sign in.",
    "Редактировать Host": "Edit Host",
    "Роль не изменена: проверьте полномочия и правило последнего Owner.": "The role was not changed. Check permissions and the last-Owner rule.",
    "Роль участника обновлена.": "Member role updated.",
    "Ротация не подтверждена. Локальный snapshot не заменён; безопасно повторите операцию.": "Rotation was not confirmed. The local snapshot was not replaced; retry safely.",
    "РУЧНОЙ РЕЖИМ": "MANUAL MODE",
    "Ручной режим активен. Новые устройства допускает Owner или Admin.": "Manual mode is active. New devices are approved by an Owner or Admin.",
    "Секрет": "Secret",
    "Сессия восстанавливается защищённой HttpOnly cookie; пароль в браузере не сохраняется.": "The session is restored using a secure HttpOnly cookie; the password is not stored in the browser.",
    "Сессия восстановлена. Для Team Vault может потребоваться одобрение устройства.": "Session restored. Team Vault may require device approval.",
    "Сессия восстановлена. Team-раздел готов к работе.": "Session restored. The Team area is ready.",
    "Сессия завершена; cookie и ключ доверенного браузера удалены.": "Session ended; the cookie and trusted browser key were removed.",
    "Сессия истекла. Войдите снова.": "The session expired. Sign in again.",
    "Сессия Cloud истекла. Войдите снова.": "The Cloud session expired. Sign in again.",
    "Синхронизация временно приостановлена: ключ обновляется автоматически.": "Synchronization is temporarily paused while the key updates automatically.",
    "Синхронизация завершена.": "Synchronization complete.",
    "Синхронизация заморожена до безопасной ротации ключа.": "Synchronization is frozen until the key is rotated securely.",
    "Слишком много попыток входа. Повторите позже.": "Too many sign-in attempts. Try again later.",
    "Слишком много попыток. Повторите позже.": "Too many attempts. Try again later.",
    "Сначала передайте владение активной Team или архивируйте её.": "Transfer ownership of the active Team or archive it first.",
    "Сначала подтвердите почту по ссылке из письма.": "Verify your email using the link in the message first.",
    "Сначала создайте локальный Vault.": "Create a local Vault first.",
    "Сниппеты команд": "Team Snippets",
    "Создайте аккаунт по приглашению. После подтверждения email войдите и снова откройте ссылку приглашения.": "Create an account through the invitation. After verifying your email, sign in and open the invitation link again.",
    "Создайте пароль Selective Remote — на почту придёт только одноразовая ссылка подтверждения.": "Create a Selective Remote password. Only a one-time verification link will be emailed.",
    "Создайте первую команду или примите приглашение.": "Create your first Team or accept an invitation.",
    "Сохранён в E2EE Team Vault": "Stored in the E2EE Team Vault",
    "Сохранить изменения": "Save changes",
    "Сохраняем политику Team…": "Saving Team policy…",
    "Сравните SHA-256 отпечаток с новым устройством. После подтверждения оно сможет получать ключи аккаунта.": "Compare the SHA-256 fingerprint with the new device. Once approved, it can receive account keys.",
    "Ссылка недействительна": "Invalid link",
    "Текущий пароль неверен.": "The current password is incorrect.",
    "Теперь можно вернуться в Selective Remote и войти в аккаунт.": "You can now return to Selective Remote and sign in.",
    "У вас есть новое приглашение в команду.": "You have a new Team invitation.",
    "Удаление зашифровано локально и будет синхронизировано автоматически.": "The deletion was encrypted locally and will synchronize automatically.",
    "Удалить аккаунт?": "Delete account?",
    "Удалить запись?": "Delete record?",
    "Укажите email участника.": "Enter the member's email.",
    "Управление командой": "Team management",
    "Управляется приложением": "Managed by the app",
    "Устройства не допущены: проверьте полномочия, отпечаток и доступность Team Vault key.": "Devices were not approved. Check permissions, the fingerprint, and Team Vault key availability.",
    "Устройство не отозвано: операция разрешена только с одобренного текущего устройства.": "The device was not revoked. This operation is allowed only from an approved current device.",
    "Устройство отозвано. Завершите ротацию отмеченных Shared Vaults.": "Device revoked. Complete rotation for the affected Shared Vaults.",
    "Участники команд": "Team members",
    "Учётные данные команд": "Team Credentials",
    "Хосты команд": "Team Hosts",
    "Это устройство ещё не одобрено для Team Vault.": "This device has not been approved for Team Vault yet.",
    "Этот пользователь уже состоит в команде.": "This user is already a Team member.",
    "Этот username уже занят.": "This username is already taken.",
    "Cloud вернул более старую ревизию; запись остановлена для защиты данных.": "Cloud returned an older revision, so the write was stopped to protect your data.",
    "Cloud не подтвердил ожидаемую следующую ревизию; локальная копия сохранена.": "Cloud did not confirm the expected next revision; the local copy is safe.",
    "Cloud недоступен": "Cloud is unavailable",
    "Email должен точно совпадать с адресом текущего аккаунта.": "The email must exactly match the current account address.",
    "Email не совпадает с адресом аккаунта.": "The email does not match the account address.",
    "Email подтверждён": "Email verified",
    "Email-приглашение не отправлено. Проверьте адрес, роль и настройки почты.": "The email invitation was not sent. Check the address, role, and email settings.",
    "Forwarding команд": "Team Forwarding",
    "Personal Vault восстановлен на этом доверенном браузере. Синхронизируем изменения…": "Personal Vault was restored in this trusted browser. Synchronizing changes…",
    "Personal Vault заблокирован. Ищем открытую вкладку этого аккаунта…": "Personal Vault is locked. Looking for an open tab for this account…",
    "Personal Vault открыт паролем аккаунта и синхронизируется автоматически.": "Personal Vault was opened with the account password and synchronizes automatically.",
    "Personal Vault пока недоступен. Войдите в аккаунт ещё раз.": "Personal Vault is currently unavailable. Sign in again.",
    "Personal Vault пока недоступен. Повторите вход или синхронизацию.": "Personal Vault is currently unavailable. Retry sign-in or synchronization.",
    "Personal Vault пока пуст. Данные появятся после первой синхронизации с Mac или ручного добавления.": "Personal Vault is empty. Data will appear after the first Mac synchronization or manual addition.",
    "Personal Vault разблокирован активной вкладкой и синхронизируется автоматически.": "Personal Vault was unlocked by an active tab and synchronizes automatically.",
    "SHA-256: ключ не зарегистрирован": "SHA-256: key not registered",
    "Shared Vault не создан или не инициализирован. Проверьте роль и одобрение устройства.": "Shared Vault has not been created or initialized. Check your role and device approval.",
    "SSH-ключи": "SSH keys",
    "Team архивирована, но локальную очистку или обновление списка не удалось завершить.": "The Team was archived, but local cleanup or list refresh could not be completed.",
    "Team архивирована; локальные зашифрованные снимки удалены.": "Team archived; local encrypted snapshots were removed.",
    "Team не архивирована: точное название, пароль или полномочия Owner не подтверждены.": "The Team was not archived. The exact name, password, or Owner permissions were not confirmed.",
    "Team не переименована: проверьте название и полномочия Owner.": "The Team was not renamed. Check the name and Owner permissions.",
    "Team не создан. Проверьте название и повторите попытку.": "The Team was not created. Check the name and try again.",
    "Team создан. Вы назначены Owner.": "Team created. You are the Owner.",
    "Username уже установлен для этого аккаунта.": "A username is already set for this account.",
    "Vault заблокирован. Войдите в аккаунт снова, чтобы открыть его.": "Vault is locked. Sign in again to open it.",
    "Wrapper ещё недоступен. Любой активный участник с текущим ключом выдаст его автоматически.": "The wrapper is not available yet. Any active member with the current key will provision it automatically.",
    "Wrapper создаёт только доверенный клиент с Team Vault key. Сервер не получает и не расшифровывает ключ хранилища.": "Only a trusted client with the Team Vault key creates the wrapper. The server never receives or decrypts the Vault key."
  })) en.set(source, translation);

  const patterns = [
    [/^Автоматически выдано недостающих wrappers: (\d+)\.$/u, "Missing wrappers provisioned automatically: $1."],
    [/^Автоматически разрешено конфликтов: (\d+)\.$/u, "Conflicts resolved automatically: $1."],
    [/^«(.+)» будет закрыта для всех участников\.$/u, "“$1” will be closed for all members."],
    [/^«(.+)»: сессии завершатся, а затронутые Shared Vaults будут заморожены до ротации\.$/u, "“$1”: sessions will end, and affected Shared Vaults will be frozen until rotation."],
    [/^«(.+)» будет удалена из Vault на всех устройствах\.$/u, "“$1” will be deleted from the Vault on all devices."],
    [/^«(.+)» больше нельзя будет использовать\.$/u, "“$1” will no longer be usable."],
    [/^@(.+) потеряет доступ\. Ключи командных папок будут автоматически обновлены для оставшихся участников\.$/u, "@$1 will lose access. Team folder keys will update automatically for remaining members."],
    [/^@(.+) свободен$/u, "@$1 is available"],
    [/^@(.+) уже занят$/u, "@$1 is already taken"],
    [/^@(.+) — ваш текущий username\.$/u, "@$1 is your current username."],
    [/^(.+) и Personal Vault будут удалены без возможности восстановления\.$/u, "$1 and Personal Vault will be permanently deleted."],
    [/^(.+) · секрет скрыт$/u, "$1 · secret hidden"],
    [/^(\d+) конфликт\(а\) разрешено локально\. Синхронизируйте ещё раз для условной загрузки\.$/u, "$1 conflict(s) resolved locally. Synchronize again for the conditional upload."],
    [/^В выбранном Team Vault пока нет (.+)\.$/u, "The selected Team Vault does not contain any $1 yet."],
    [/^Действия для @(.+)$/u, "Actions for @$1"],
    [/^Допущено устройств: (\d+)\. Для открытого Team Vault выдано wrappers: (\d+)\.$/u, "Devices approved: $1. Wrappers provisioned for the open Team Vault: $2."],
    [/^Допущено устройств: (\d+)\. Wrapper выдаст любой активный клиент, уже владеющий ключом Team Vault\.$/u, "Devices approved: $1. Any active client that already owns the Team Vault key will provision the wrapper."],
    [/^Доступ отозван\. Автоматически обновляем ключи папок: (\d+)\.$/u, "Access revoked. Updating folder keys automatically: $1."],
    [/^Доступ отозван\. Ключи обновлены автоматически: (\d+)\.$/u, "Access revoked. Keys updated automatically: $1."],
    [/^Доступ отозван\. Обновление ключей продолжится автоматически; осталось папок: (\d+)\.$/u, "Access revoked. Key updates will continue automatically; folders remaining: $1."],
    [/^Зашифрованная ревизия (\d+) загружена и объединена локально\.$/u, "Encrypted revision $1 was downloaded and merged locally."],
    [/^Зашифрованная ревизия (\d+) загружена\.$/u, "Encrypted revision $1 downloaded."],
    [/^Зашифрованная Team-ревизия (\d+) загружена\.$/u, "Encrypted Team revision $1 downloaded."],
    [/^Команда «(.+)» · выберите папку для просмотра (.+)\.$/u, "Team “$1” · select a folder to view $2."],
    [/^Команда «(.+)» · папка «(.+)»\.$/u, "Team “$1” · folder “$2”."],
    [/^Конфликт (\d+)$/u, "Conflict $1"],
    [/^Обнаружено конфликтов: (\d+)\. Выберите версии явно\.$/u, "Conflicts found: $1. Choose each version explicitly."],
    [/^Одноразовая ссылка отправлена на (.+)\. Подтвердите адрес, затем войдите с созданным паролем\.$/u, "A one-time link was sent to $1. Verify the address, then sign in with the password you created."],
    [/^Открыть Host (.+)$/u, "Open Host $1"],
    [/^Перед ротацией разрешите конфликтов: (\d+)\. Секреты не отображаются\.$/u, "Resolve $1 conflict(s) before rotation. Secrets are not shown."],
    [/^Приглашение в Team «(.+)» принято\.$/u, "Invitation to Team “$1” accepted."],
    [/^Приглашение отправлено на (.+)\. Оно действует 48 часов\.$/u, "Invitation sent to $1. It is valid for 48 hours."],
    [/^Ревизия (\d+) загружена; новые локальные изменения останутся для следующего цикла\.$/u, "Revision $1 downloaded; new local changes remain for the next cycle."],
    [/^Ревизия (\d+) загружена; появились новые локальные изменения — синхронизируйте ещё раз\.$/u, "Revision $1 downloaded; new local changes appeared, so synchronize again."],
    [/^Редактирование: (.+)\.$/u, "Editing: $1."],
    [/^Роль: (.+) · до (.+)$/u, "Role: $1 · until $2"],
    [/^Ротация завершена атомарно · ревизия (\d+) · поколение ключа (\d+)\.$/u, "Rotation completed atomically · revision $1 · key generation $2."],
    [/^У @(.+) нет новых недоверенных устройств\. Недостающие wrappers безопасно проверены\.$/u, "@$1 has no new untrusted devices. Missing wrappers were checked securely."],
    [/^Удалённый Vault изменился до ревизии (\d+)\. Повторите синхронизацию для безопасного merge\.$/u, "The remote Vault changed to revision $1. Synchronize again for a safe merge."],
    [/^Cloud API v(.+) доступен$/u, "Cloud API v$1 is available"],
    [/^Shared Vault инициализирован · ревизия (\d+)\.$/u, "Shared Vault initialized · revision $1."],
    [/^Shared Vault синхронизирован · ревизия (\d+)\.$/u, "Shared Vault synchronized · revision $1."],
    [/^Team архивирована, но (\d+) локальных зашифрованных снимков не удалось удалить\.$/u, "The Team was archived, but $1 local encrypted snapshot(s) could not be removed."],
    [/^Team Vault изменился до ревизии (\d+)\. Следующий цикл повторит синхронизацию\.$/u, "Team Vault changed to revision $1. The next cycle will retry synchronization."],
    [/^Team-ревизия (\d+) загружена и объединена локально\.$/u, "Team revision $1 was downloaded and merged locally."],
    [/^Username изменён на @(.+)\.$/u, "Username changed to @$1."],
    [/^Vault уже синхронизирован на ревизии (\d+)\.$/u, "Vault is already synchronized at revision $1."],
    [/^Последняя синхронизация: —$/u, "Last synchronization: —"],
    [/^Последняя синхронизация: (.+) · r(\d+)\.$/u, "Last synchronization: $1 · r$2."],
    [/^Изменено: (.+)$/u, "Changed: $1"],
    [/^Редактирование (.+)$/u, "Editing $1"],
    [/^Команд: (\d+)\. Новых приглашений: (\d+)\.$/u, "Teams: $1. New invitations: $2."],
    [/^Team «(.+)» · участников: (\d+)\.$/u, "Team “$1” · members: $2."],
    [/^Команда «(.+)» · участники и приглашения\.$/u, "Team “$1” · members and invitations."],
    [/^Команда «(.+)» · управление\.$/u, "Team “$1” · management."],
    [/^Команда «(.+)» · папок: (\d+)\.$/u, "Team “$1” · folders: $2."],
    [/^(\d+) из (\d+)$/u, "$1 of $2"],
    [/^Участников: (\d+)$/u, "Members: $1"],
    [/^Удалено · (.+)$/u, "Deleted · $1"],
  ];

  const originalText = new WeakMap();
  const originalAttributes = new WeakMap();
  let locale = resolveInitialLocale();
  let observer;

  function resolveInitialLocale() {
    const requested = new URLSearchParams(location.search).get("lang")?.toLowerCase();
    if (SUPPORTED_LOCALES.has(requested)) return requested;
    try {
      const stored = localStorage.getItem(STORAGE_KEY);
      if (SUPPORTED_LOCALES.has(stored)) return stored;
    } catch {}
    return String(navigator.language || "ru").toLowerCase().startsWith("ru") ? "ru" : "en";
  }

  function translate(value) {
    if (locale !== "en" || typeof value !== "string") return value;
    const direct = en.get(value.trim());
    if (direct) return value.replace(value.trim(), direct);
    for (const [pattern, replacement] of patterns) {
      if (pattern.test(value.trim())) return value.replace(value.trim(), value.trim().replace(pattern, replacement));
    }
    return value;
  }

  function translateTextNode(node) {
    if (!originalText.has(node)) originalText.set(node, node.nodeValue);
    const source = originalText.get(node);
    node.nodeValue = locale === "ru" ? source : translate(source);
  }

  function translateElement(element) {
    if (!(element instanceof Element)) return;
    const attributes = ["aria-label", "title", "placeholder"];
    let saved = originalAttributes.get(element);
    if (!saved) {
      saved = {};
      originalAttributes.set(element, saved);
    }
    for (const name of attributes) {
      if (!element.hasAttribute(name)) continue;
      if (!(name in saved)) saved[name] = element.getAttribute(name);
      element.setAttribute(name, locale === "ru" ? saved[name] : translate(saved[name]));
    }
    for (const child of element.childNodes) {
      if (child.nodeType === Node.TEXT_NODE) translateTextNode(child);
      else if (child.nodeType === Node.ELEMENT_NODE) translateElement(child);
    }
  }

  function updateMetadata() {
    document.documentElement.lang = locale;
    document.title = metadata[locale].title;
    const description = document.querySelector('meta[name="description"]');
    if (description) description.setAttribute("content", metadata[locale].description);
  }

  function switchMarkup(scope) {
    const control = document.createElement("div");
    control.className = "locale-switch";
    control.dataset.localeSwitch = scope;
    control.setAttribute("role", "group");
    control.setAttribute("aria-label", locale === "ru" ? "Язык" : "Language");
    for (const value of ["ru", "en"]) {
      const button = document.createElement("button");
      button.type = "button";
      button.dataset.locale = value;
      button.textContent = value.toUpperCase();
      button.setAttribute("aria-pressed", String(locale === value));
      button.addEventListener("click", () => setLocale(value));
      control.append(button);
    }
    return control;
  }

  function mountSwitches() {
    const publicActions = document.querySelector("#public-actions");
    const workspaceFooter = document.querySelector("#workspace-sidebar-footer");
    const workspaceLogo = document.querySelector(".workspace-logo");
    if (publicActions && !publicActions.querySelector('[data-locale-switch="public"]')) {
      publicActions.prepend(switchMarkup("public"));
    }
    if (workspaceFooter && !workspaceFooter.querySelector('[data-locale-switch="workspace"]')) {
      workspaceFooter.prepend(switchMarkup("workspace"));
    }
    if (workspaceLogo && !workspaceLogo.querySelector('[data-locale-switch="workspace-mobile"]')) {
      const mobileSwitch = switchMarkup("workspace-mobile");
      mobileSwitch.classList.add("workspace-locale-mobile");
      workspaceLogo.append(mobileSwitch);
    }
  }

  function refreshSwitches() {
    for (const control of document.querySelectorAll("[data-locale-switch]")) {
      control.setAttribute("aria-label", locale === "ru" ? "Язык" : "Language");
      for (const button of control.querySelectorAll("[data-locale]")) {
        button.setAttribute("aria-pressed", String(button.dataset.locale === locale));
      }
    }
  }

  function apply() {
    observer?.disconnect();
    updateMetadata();
    translateElement(document.body);
    mountSwitches();
    refreshSwitches();
    observer?.observe(document.body, { subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ["aria-label", "title", "placeholder"] });
    document.dispatchEvent(new CustomEvent("selective-remote:locale-changed", { detail: { locale } }));
  }

  function setLocale(nextLocale) {
    if (!SUPPORTED_LOCALES.has(nextLocale) || nextLocale === locale) return;
    locale = nextLocale;
    try { localStorage.setItem(STORAGE_KEY, locale); } catch {}
    const url = new URL(location.href);
    url.searchParams.set("lang", locale);
    history.replaceState(history.state, "", url);
    apply();
  }

  document.addEventListener("DOMContentLoaded", () => {
    observer = new MutationObserver((mutations) => {
      observer.disconnect();
      for (const mutation of mutations) {
        if (mutation.type === "characterData") {
          originalText.set(mutation.target, mutation.target.nodeValue);
          translateTextNode(mutation.target);
        }
        if (mutation.type === "attributes") {
          const saved = originalAttributes.get(mutation.target) ?? {};
          saved[mutation.attributeName] = mutation.target.getAttribute(mutation.attributeName);
          originalAttributes.set(mutation.target, saved);
          translateElement(mutation.target);
        }
        for (const node of mutation.addedNodes) {
          if (node.nodeType === Node.TEXT_NODE) translateTextNode(node);
          else if (node.nodeType === Node.ELEMENT_NODE) translateElement(node);
        }
      }
      observer.observe(document.body, { subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ["aria-label", "title", "placeholder"] });
    });
    apply();
  }, { once: true });

  window.SelectiveRemoteI18n = Object.freeze({
    get locale() { return locale; },
    setLocale,
    t(value) { return translate(value); },
  });
})();
