# Первая публикация на GitHub

## Создание репозитория

На странице **Create a new repository** укажите:

- Repository name: `Selective-Remote`;
- Description: `Нативный RDP, SSH и SFTP клиент для macOS`;
- Visibility: **Public**;
- Add README: **Off**;
- Add .gitignore: **No .gitignore**;
- Add license: **No license**.

README, `.gitignore` и MIT License уже находятся в проекте. После создания
пустого репозитория выполните в Terminal:

```bash
cd ~/Downloads/SelectiveRemote-0.17.1-source-public-v9.2
git init
git add .
git commit -m "Initial public release"
git branch -M main
git remote add origin https://github.com/PastFly/Selective-Remote.git
git push -u origin main
```

Если Git попросит имя автора:

```bash
git config --global user.name "Leonid Kadaev"
git config --global user.email "EMAIL_ИЗ_GITHUB"
```

После публикации включите **Settings → Security → Private vulnerability
reporting** и защиту ветки `main` с обязательным прохождением CI.
