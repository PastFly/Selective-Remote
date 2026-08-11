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
cd ~/Downloads/SelectiveRemote-0.18.0-source-public
git init
git add .
git commit -m "Initial public release"
git branch -M main
git remote add origin https://github.com/PastFly/Selective-Remote.git
git push -u origin main
```

Перед первым commit задайте публичную подпись только для этого репозитория.
Точный `noreply`-адрес скопируйте из **GitHub → Settings → Emails**:

```bash
git config user.name "PastFly"
git config user.email "ТОЧНЫЙ_NOREPLY_ИЗ_GITHUB"
```

Имя на странице commit берётся не из файлов проекта, а из полей Author и
Committer внутри истории Git. Если ранние commit уже опубликованы под прежним
именем и репозиторий ещё никто не клонировал, перепишите их после настройки
публичной подписи:

```bash
git rebase --root --exec 'git commit --amend --no-edit --reset-author'
git push --force-with-lease origin main
```

После переписывания истории создайте первый публичный тег. Для каждого
следующего выпуска используйте новый номер версии и новый тег:

```bash
git tag -a v0.18.0 -m "Selective Remote 0.18.0"
git push origin v0.18.0
```

Force push меняет commit ID. Не выполняйте его после того, как другие
разработчики начали работать со своими клонами репозитория.

После публикации включите **Settings → Security → Private vulnerability
reporting** и защиту ветки `main` с обязательным прохождением CI.
