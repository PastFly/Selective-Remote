(() => {
    "use strict";

    const terminalHost = document.getElementById("terminal");
    const terminalShell = document.getElementById("terminal-shell");
    const suggestionsElement = document.getElementById("terminal-suggestions");
    const historyPanel = document.getElementById("terminal-history");
    const historyQuery = document.getElementById("history-query");
    const historyList = document.getElementById("history-list");
    const historyEmpty = document.getElementById("history-empty");
    const historyEnabledInput = document.getElementById("history-enabled");
    const historyClearButton = document.getElementById("history-clear");
    const historyCloseButton = document.getElementById("history-close");
    const historyOptions = document.getElementById("history-options");
    const commandPanelTitle = document.getElementById("command-panel-title");
    const commandPanelSubtitle = document.getElementById("command-panel-subtitle");
    const commandEmptyTitle = document.getElementById("command-empty-title");
    const commandEmptyMessage = document.getElementById("command-empty-message");
    const commandTabs = Array.from(document.querySelectorAll("#command-tabs button"));

    const terminal = new Terminal({
        allowProposedApi: false,
        convertEol: false,
        cursorBlink: true,
        cursorStyle: "block",
        fontFamily: '"SF Mono", SFMono-Regular, Menlo, monospace',
        fontSize: 14,
        lineHeight: 1.15,
        macOptionIsMeta: true,
        scrollback: 10000,
        theme: {
            background: "#101421",
            foreground: "#DCE6F5",
            cursor: "#36D399",
            cursorAccent: "#101421",
            selectionBackground: "#32527B99",
            black: "#101421",
            red: "#FF6B7A",
            green: "#36D399",
            yellow: "#F9C74F",
            blue: "#61AFEF",
            magenta: "#C678DD",
            cyan: "#56D4DD",
            white: "#DCE6F5",
            brightBlack: "#6F7A91",
            brightRed: "#FF8793",
            brightGreen: "#64E6B8",
            brightYellow: "#FFE08A",
            brightBlue: "#8CCBFF",
            brightMagenta: "#E0A5F3",
            brightCyan: "#88EDF2",
            brightWhite: "#FFFFFF"
        }
    });
    const fitAddon = new FitAddon.FitAddon();
    terminal.loadAddon(fitAddon);
    terminal.open(terminalHost);

    const builtInCommandCatalog = [
        { command: "sudo systemctl status ", description: "Показать состояние службы", category: "Службы", keywords: "service состояние статус" },
        { command: "sudo systemctl restart ", description: "Перезапустить службу", category: "Службы", keywords: "service рестарт перезапуск" },
        { command: "sudo systemctl start ", description: "Запустить службу", category: "Службы", keywords: "service запуск" },
        { command: "sudo systemctl stop ", description: "Остановить службу", category: "Службы", keywords: "service остановка" },
        { command: "sudo systemctl enable --now ", description: "Включить автозапуск и запустить службу", category: "Службы", keywords: "service автозапуск" },
        { command: "sudo systemctl daemon-reload", description: "Перечитать unit-файлы systemd", category: "Службы", keywords: "systemd units reload" },
        { command: "journalctl -u  -n 100 --no-pager", description: "Последние записи журнала службы", category: "Журналы", keywords: "service logs логи журнал" },
        { command: "journalctl -u  -f", description: "Следить за журналом службы", category: "Журналы", keywords: "service logs follow логи" },
        { command: "journalctl -p err -b --no-pager", description: "Ошибки с момента загрузки", category: "Журналы", keywords: "errors ошибки boot" },
        { command: "tail -f /var/log/", description: "Следить за файлом журнала", category: "Журналы", keywords: "logs логи файл" },
        { command: "sudo apt update", description: "Обновить индекс пакетов", category: "Пакеты", keywords: "debian ubuntu пакеты" },
        { command: "sudo apt upgrade", description: "Установить доступные обновления", category: "Пакеты", keywords: "debian ubuntu обновить" },
        { command: "sudo apt install ", description: "Установить пакет", category: "Пакеты", keywords: "debian ubuntu package" },
        { command: "sudo apt remove ", description: "Удалить пакет", category: "Пакеты", keywords: "debian ubuntu package" },
        { command: "sudo dnf update", description: "Обновить пакеты системы", category: "Пакеты", keywords: "fedora rocky alma" },
        { command: "sudo dnf install ", description: "Установить пакет", category: "Пакеты", keywords: "fedora rocky alma" },
        { command: "ip addr", description: "Показать сетевые адреса", category: "Сеть", keywords: "network интерфейсы ip" },
        { command: "ip route", description: "Показать таблицу маршрутизации", category: "Сеть", keywords: "network маршруты gateway" },
        { command: "ss -tulpn", description: "Показать слушающие порты", category: "Сеть", keywords: "network ports сокеты" },
        { command: "ping -c 4 ", description: "Проверить доступность узла", category: "Сеть", keywords: "network host сеть" },
        { command: "curl -I ", description: "Получить HTTP-заголовки", category: "Сеть", keywords: "http headers сайт" },
        { command: "dig +short ", description: "Проверить DNS-запись", category: "Сеть", keywords: "dns domain домен" },
        { command: "ls -la", description: "Подробный список файлов", category: "Файлы", keywords: "directory каталог" },
        { command: "cd /etc/", description: "Перейти в каталог конфигурации", category: "Файлы", keywords: "directory config каталог" },
        { command: "nano /etc/ssh/sshd_config", description: "Открыть конфигурацию SSH-сервера", category: "Файлы", keywords: "editor редактор ssh" },
        { command: "nano /etc/hosts", description: "Открыть локальные имена узлов", category: "Файлы", keywords: "editor редактор dns" },
        { command: "nano /etc/fstab", description: "Открыть настройки монтирования", category: "Файлы", keywords: "editor редактор disks" },
        { command: "find / -name \"имя\" 2>/dev/null", description: "Найти файл по имени", category: "Файлы", keywords: "search поиск" },
        { command: "grep -Rni \"текст\" /etc/", description: "Найти текст в конфигурации", category: "Файлы", keywords: "search поиск" },
        { command: "df -h", description: "Показать свободное место", category: "Система", keywords: "disk диск место" },
        { command: "du -sh *", description: "Показать размеры объектов", category: "Система", keywords: "disk каталог размер" },
        { command: "free -h", description: "Показать использование памяти", category: "Система", keywords: "memory ram память" },
        { command: "uptime", description: "Показать время работы и нагрузку", category: "Система", keywords: "load нагрузка" },
        { command: "ps aux --sort=-%mem | head", description: "Процессы с наибольшим расходом памяти", category: "Система", keywords: "process memory процессы" },
        { command: "docker ps --format \"table {{.Names}}\\t{{.Status}}\\t{{.Ports}}\"", description: "Показать запущенные контейнеры", category: "Docker", keywords: "containers контейнеры" },
        { command: "docker compose ps", description: "Состояние сервисов Compose", category: "Docker", keywords: "containers контейнеры" },
        { command: "docker compose logs --tail 100 -f", description: "Следить за журналом Compose", category: "Docker", keywords: "containers logs логи" },
        { command: "docker compose restart ", description: "Перезапустить сервис Compose", category: "Docker", keywords: "containers service рестарт" }
    ].map((entry, index) => ({
        ...entry,
        id: `catalog-${index}`,
        source: "catalog",
        useCount: 0,
        lastUsedAt: 0
    }));

    let historyEntries = [];
    let historyEnabled = true;
    let currentLine = [];
    let inputCursor = 0;
    let lineTrackingReliable = true;
    let currentSuggestions = [];
    let selectedSuggestionIndex = -1;
    let echoCapture = "";
    let lineInputStarted = false;
    let pendingHistoryCandidates = [];
    let shellPromptReady = false;
    let lineStartedAtShellPrompt = false;
    let recentVisibleOutput = "";
    let activePanelSection = "history";
    let alternateScreenWasActive = false;
    const outputTextDecoder = new TextDecoder("utf-8");

    const postHistory = (payload) => {
        window.webkit?.messageHandlers?.terminalHistory?.postMessage(payload);
    };

    const isAlternateScreen = () => terminal.buffer.active.type === "alternate";

    const visibleOutputText = (value) => value
        .replace(/\u001b\][^\u0007]*(?:\u0007|\u001b\\)/g, "")
        .replace(/\u001b\[[0-?]*[ -/]*[@-~]/g, "")
        .replace(/\u001b[@-_]/g, "");

    const outputContainsEchoedCommand = (output, command) => {
        if (command.length < 2) {
            return false;
        }
        return visibleOutputText(output)
            .split(/[\r\n]+/)
            .some((line) => line.trimEnd().endsWith(command));
    };

    const outputEndsInShellPrompt = (output) => {
        const lines = visibleOutputText(output).split(/[\r\n]+/);
        const lastLine = (lines.at(-1) || "").trimEnd();
        return /[$#%❯➜]\s*$/.test(lastLine)
            || /^PS\s+.+>\s*$/.test(lastLine);
    };

    const finishHistoryCandidate = (candidate) => {
        window.clearTimeout(candidate.timeout);
        pendingHistoryCandidates = pendingHistoryCandidates.filter(
            (item) => item !== candidate
        );
        postHistory({ action: "record", command: candidate.command });
    };

    const inspectPendingHistoryCandidates = () => {
        pendingHistoryCandidates.slice().forEach((candidate) => {
            if (outputContainsEchoedCommand(candidate.output, candidate.command)) {
                finishHistoryCandidate(candidate);
            }
        });
    };

    const observeTerminalOutput = (bytes) => {
        const text = outputTextDecoder.decode(bytes, { stream: true });
        if (!text) {
            return;
        }
        if (lineInputStarted) {
            echoCapture = (echoCapture + text).slice(-16_384);
        }
        pendingHistoryCandidates.forEach((candidate) => {
            candidate.output = (candidate.output + text).slice(-16_384);
        });
        recentVisibleOutput = (recentVisibleOutput + visibleOutputText(text)).slice(-16_384);
        shellPromptReady = outputEndsInShellPrompt(recentVisibleOutput);
        inspectPendingHistoryCandidates();
    };

    const queueHistoryCandidate = (command) => {
        const candidate = {
            command,
            output: echoCapture,
            timeout: 0
        };
        pendingHistoryCandidates.push(candidate);
        candidate.timeout = window.setTimeout(() => {
            pendingHistoryCandidates = pendingHistoryCandidates.filter(
                (item) => item !== candidate
            );
        }, 1_500);
        inspectPendingHistoryCandidates();
    };

    const appendHighlightedText = (target, text, query) => {
        const normalizedQuery = query.trim().toLocaleLowerCase();
        if (!normalizedQuery) {
            target.textContent = text;
            return;
        }
        const index = text.toLocaleLowerCase().indexOf(normalizedQuery);
        if (index < 0) {
            target.textContent = text;
            return;
        }
        target.append(document.createTextNode(text.slice(0, index)));
        const match = document.createElement("span");
        match.className = "match";
        match.textContent = text.slice(index, index + normalizedQuery.length);
        target.append(match, document.createTextNode(text.slice(index + normalizedQuery.length)));
    };

    const matchingHistory = (query, limit = Number.POSITIVE_INFINITY) => {
        const normalized = query.trim().toLocaleLowerCase();
        if (!normalized) {
            return historyEntries.slice(0, limit);
        }
        return historyEntries
            .map((entry, order) => {
                const command = entry.command.toLocaleLowerCase();
                const matchIndex = command.indexOf(normalized);
                return { entry, order, matchIndex };
            })
            .filter((candidate) => candidate.matchIndex >= 0)
            .sort((left, right) => {
                const leftPrefix = left.matchIndex === 0 ? 0 : 1;
                const rightPrefix = right.matchIndex === 0 ? 0 : 1;
                if (leftPrefix !== rightPrefix) {
                    return leftPrefix - rightPrefix;
                }
                if (left.entry.useCount !== right.entry.useCount) {
                    return right.entry.useCount - left.entry.useCount;
                }
                return left.order - right.order;
            })
            .slice(0, limit)
            .map((candidate) => candidate.entry);
    };

    const matchingCatalog = (query, limit = Number.POSITIVE_INFINITY) => {
        const normalized = query.trim().toLocaleLowerCase();
        if (!normalized) {
            return builtInCommandCatalog.slice(0, limit);
        }
        return builtInCommandCatalog
            .map((entry, order) => {
                const command = entry.command.toLocaleLowerCase();
                const details = `${entry.description} ${entry.category} ${entry.keywords}`
                    .toLocaleLowerCase();
                const commandIndex = command.indexOf(normalized);
                const detailsIndex = details.indexOf(normalized);
                let rank = 4;
                if (commandIndex === 0) {
                    rank = 0;
                } else if (commandIndex > 0) {
                    rank = 1;
                } else if (detailsIndex === 0) {
                    rank = 2;
                } else if (detailsIndex > 0) {
                    rank = 3;
                }
                return { entry, order, rank };
            })
            .filter((candidate) => candidate.rank < 4)
            .sort((left, right) => left.rank - right.rank || left.order - right.order)
            .slice(0, limit)
            .map((candidate) => candidate.entry);
    };

    const matchingSuggestions = (query, limit = 6) => {
        const combined = [];
        if (historyEnabled) {
            matchingHistory(query).forEach((entry) => {
                combined.push({
                    ...entry,
                    source: "history",
                    description: entry.useCount > 1
                        ? `Из истории · запусков: ${entry.useCount}`
                        : "Из истории",
                    category: "История"
                });
            });
        }
        matchingCatalog(query).forEach((entry) => combined.push(entry));

        const unique = [];
        const commands = new Set();
        combined.forEach((entry) => {
            const key = entry.command.trimEnd();
            if (!commands.has(key)) {
                commands.add(key);
                unique.push(entry);
            }
        });
        return unique.slice(0, limit);
    };

    const inputPrefix = () => currentLine.slice(0, inputCursor).join("").trimStart();

    const hideSuggestions = () => {
        suggestionsElement.hidden = true;
        currentSuggestions = [];
        selectedSuggestionIndex = -1;
    };

    const positionSuggestions = () => {
        const screen = terminalHost.querySelector(".xterm-screen");
        if (!screen || terminal.rows <= 0 || terminal.cols <= 0) {
            return;
        }
        const shellRect = terminalShell.getBoundingClientRect();
        const screenRect = screen.getBoundingClientRect();
        const cellWidth = screenRect.width / terminal.cols;
        const cellHeight = screenRect.height / terminal.rows;
        const desiredLeft = screenRect.left - shellRect.left
            + terminal.buffer.active.cursorX * cellWidth;
        const left = Math.max(12, Math.min(desiredLeft, terminalShell.clientWidth - 220));
        const belowCursor = screenRect.top - shellRect.top
            + (terminal.buffer.active.cursorY + 1) * cellHeight + 7;
        const estimatedHeight = Math.min(268, currentSuggestions.length * 54 + 16);
        const top = belowCursor + estimatedHeight < terminalShell.clientHeight
            ? belowCursor
            : Math.max(8, belowCursor - estimatedHeight - cellHeight - 8);
        suggestionsElement.style.left = `${left}px`;
        suggestionsElement.style.top = `${top}px`;
    };

    const updateSelectedSuggestion = () => {
        suggestionsElement.querySelectorAll(".suggestion-row").forEach((row, index) => {
            const selected = index === selectedSuggestionIndex;
            row.classList.toggle("is-selected", selected);
            row.setAttribute("aria-selected", selected ? "true" : "false");
            if (selected) {
                row.scrollIntoView({ block: "nearest" });
            }
        });
    };

    const replaceCurrentLine = (command, closeHistory = false) => {
        if (isAlternateScreen()) {
            return;
        }
        const startedAtPrompt = lineStartedAtShellPrompt || shellPromptReady;
        window.webkit.messageHandlers.terminalInput.postMessage(`\u0015${command}`);
        currentLine = Array.from(command);
        inputCursor = currentLine.length;
        lineTrackingReliable = true;
        echoCapture = "";
        lineInputStarted = true;
        lineStartedAtShellPrompt = startedAtPrompt;
        hideSuggestions();
        if (closeHistory) {
            window.selectiveTerminalSetHistoryVisible(false, true);
        }
        terminal.focus();
    };

    const renderSuggestions = () => {
        const prefix = inputPrefix();
        if (!lineTrackingReliable
            || isAlternateScreen()
            || prefix.length < 2) {
            hideSuggestions();
            return;
        }

        currentSuggestions = matchingSuggestions(prefix, 6)
            .filter((entry) => entry.command !== currentLine.join(""));
        selectedSuggestionIndex = -1;
        suggestionsElement.replaceChildren();
        if (currentSuggestions.length === 0) {
            hideSuggestions();
            return;
        }

        currentSuggestions.forEach((entry, index) => {
            const row = document.createElement("button");
            row.type = "button";
            row.className = "suggestion-row";
            row.setAttribute("role", "option");
            row.setAttribute("aria-selected", "false");

            const symbol = document.createElement("span");
            symbol.className = "history-symbol";
            symbol.textContent = entry.source === "history" ? "◷" : "›";
            symbol.setAttribute("aria-hidden", "true");
            const content = document.createElement("span");
            content.className = "suggestion-content";
            const command = document.createElement("span");
            command.className = "command";
            appendHighlightedText(command, entry.command, prefix);
            const description = document.createElement("span");
            description.className = "suggestion-description";
            description.textContent = entry.source === "history"
                ? entry.description
                : `${entry.category} · ${entry.description}`;
            content.append(command, description);
            row.append(symbol, content);
            row.addEventListener("pointerdown", (event) => event.preventDefault());
            row.addEventListener("click", () => replaceCurrentLine(entry.command));
            row.addEventListener("mousemove", () => {
                selectedSuggestionIndex = index;
                updateSelectedSuggestion();
            });
            suggestionsElement.append(row);
        });
        suggestionsElement.hidden = false;
        positionSuggestions();
    };

    const formatHistoryDate = (milliseconds) => {
        const date = new Date(milliseconds);
        if (Number.isNaN(date.valueOf())) {
            return "";
        }
        return new Intl.DateTimeFormat("ru-RU", {
            day: "numeric",
            month: "short",
            hour: "2-digit",
            minute: "2-digit"
        }).format(date);
    };

    const renderHistoryPanel = () => {
        const query = historyQuery.value;
        const showsCatalog = activePanelSection === "catalog";
        const filtered = showsCatalog
            ? matchingCatalog(query)
            : matchingHistory(query);
        commandPanelTitle.textContent = showsCatalog ? "Общие команды" : "История команд";
        commandPanelSubtitle.textContent = showsCatalog
            ? "Готовые команды и шаблоны"
            : "Сохранена только на этом Mac";
        historyOptions.hidden = showsCatalog;
        commandTabs.forEach((button) => {
            button.classList.toggle(
                "is-selected",
                button.dataset.section === activePanelSection
            );
        });
        historyList.replaceChildren();

        filtered.forEach((entry) => {
            const row = document.createElement("div");
            row.className = "history-row";
            row.setAttribute("role", "listitem");

            const useButton = document.createElement("button");
            useButton.type = "button";
            useButton.className = "history-use";
            useButton.title = "Подставить команду в терминал";
            const command = document.createElement("span");
            command.className = "history-command";
            appendHighlightedText(command, entry.command, query);
            const meta = document.createElement("span");
            meta.className = "history-meta";
            if (showsCatalog) {
                meta.textContent = `${entry.category} · ${entry.description}`;
            } else {
                const used = entry.useCount > 1 ? ` · запусков: ${entry.useCount}` : "";
                meta.textContent = `${formatHistoryDate(entry.lastUsedAt)}${used}`;
            }
            useButton.append(command, meta);
            useButton.addEventListener("click", () => replaceCurrentLine(entry.command, true));

            if (showsCatalog) {
                row.append(useButton);
                row.classList.add("catalog-row");
            } else {
                const removeButton = document.createElement("button");
                removeButton.type = "button";
                removeButton.className = "history-remove";
                removeButton.title = "Удалить из истории";
                removeButton.setAttribute("aria-label", `Удалить команду ${entry.command}`);
                removeButton.textContent = "×";
                removeButton.addEventListener("click", () => {
                    postHistory({ action: "remove", id: entry.id });
                });
                row.append(useButton, removeButton);
            }
            historyList.append(row);
        });

        const empty = filtered.length === 0;
        commandEmptyTitle.textContent = showsCatalog
            ? "Команды не найдены"
            : "История пока пуста";
        commandEmptyMessage.textContent = showsCatalog
            ? "Измените запрос или выберите другой раздел."
            : "Выполненные команды появятся здесь автоматически.";
        historyList.hidden = empty;
        historyEmpty.hidden = !empty;
        historyClearButton.disabled = historyEntries.length === 0;
        historyEnabledInput.checked = historyEnabled;
    };

    const resetTrackedLine = () => {
        currentLine = [];
        inputCursor = 0;
        lineTrackingReliable = true;
        echoCapture = "";
        lineInputStarted = false;
        lineStartedAtShellPrompt = false;
        hideSuggestions();
    };

    const removeWordBeforeCursor = () => {
        while (inputCursor > 0 && /\s/.test(currentLine[inputCursor - 1])) {
            currentLine.splice(inputCursor - 1, 1);
            inputCursor -= 1;
        }
        while (inputCursor > 0 && !/\s/.test(currentLine[inputCursor - 1])) {
            currentLine.splice(inputCursor - 1, 1);
            inputCursor -= 1;
        }
    };

    const recordTrackedLine = () => {
        if (lineTrackingReliable) {
            const command = currentLine.join("");
            if (command.trim().length > 0) {
                if (lineStartedAtShellPrompt) {
                    postHistory({ action: "record", command });
                } else {
                    queueHistoryCandidate(command);
                }
            }
        }
        shellPromptReady = false;
        resetTrackedLine();
    };

    const trackTerminalInput = (data) => {
        if (isAlternateScreen()) {
            resetTrackedLine();
            lineTrackingReliable = false;
            return;
        }

        const navigation = {
            "\u001b[D": -1,
            "\u001bOD": -1,
            "\u001b[C": 1,
            "\u001bOC": 1
        };
        if (Object.hasOwn(navigation, data)) {
            inputCursor = Math.max(0, Math.min(currentLine.length, inputCursor + navigation[data]));
            renderSuggestions();
            return;
        }
        if (["\u001b[H", "\u001bOH", "\u0001"].includes(data)) {
            inputCursor = 0;
            renderSuggestions();
            return;
        }
        if (["\u001b[F", "\u001bOF", "\u0005"].includes(data)) {
            inputCursor = currentLine.length;
            renderSuggestions();
            return;
        }
        if (data.startsWith("\u001b")) {
            lineTrackingReliable = false;
            hideSuggestions();
            return;
        }

        for (const character of Array.from(data)) {
            switch (character) {
            case "\r":
            case "\n":
                recordTrackedLine();
                break;
            case "\u0003":
                resetTrackedLine();
                break;
            case "\u0001":
                inputCursor = 0;
                break;
            case "\u0005":
                inputCursor = currentLine.length;
                break;
            case "\u0015":
                currentLine.splice(0, inputCursor);
                inputCursor = 0;
                break;
            case "\u000b":
                currentLine.splice(inputCursor);
                break;
            case "\u0017":
                removeWordBeforeCursor();
                break;
            case "\b":
            case "\u007f":
                if (inputCursor > 0) {
                    currentLine.splice(inputCursor - 1, 1);
                    inputCursor -= 1;
                }
                break;
            case "\t":
                lineTrackingReliable = false;
                break;
            default:
                if (character >= " " && character !== "\u007f") {
                    if (!lineInputStarted) {
                        echoCapture = "";
                        lineInputStarted = true;
                        lineStartedAtShellPrompt = shellPromptReady;
                    }
                    currentLine.splice(inputCursor, 0, character);
                    inputCursor += 1;
                } else {
                    lineTrackingReliable = false;
                }
                break;
            }
        }
        renderSuggestions();
    };

    terminal.attachCustomKeyEventHandler((event) => {
        if (event.type !== "keydown") {
            return true;
        }
        if (event.metaKey && event.shiftKey && event.key.toLocaleLowerCase() === "y") {
            window.selectiveTerminalSetHistoryVisible(historyPanel.hidden, true);
            return false;
        }
        if (!historyPanel.hidden && event.key === "Escape") {
            window.selectiveTerminalSetHistoryVisible(false, true);
            return false;
        }
        if (suggestionsElement.hidden) {
            return true;
        }
        if (event.key === "Escape") {
            hideSuggestions();
            return false;
        }
        if (event.key === "ArrowDown") {
            selectedSuggestionIndex = Math.min(
                currentSuggestions.length - 1,
                selectedSuggestionIndex + 1
            );
            updateSelectedSuggestion();
            return false;
        }
        if (event.key === "ArrowUp") {
            selectedSuggestionIndex = selectedSuggestionIndex < 0
                ? currentSuggestions.length - 1
                : Math.max(0, selectedSuggestionIndex - 1);
            updateSelectedSuggestion();
            return false;
        }
        if (event.key === "Enter" && selectedSuggestionIndex >= 0) {
            replaceCurrentLine(currentSuggestions[selectedSuggestionIndex].command);
            return false;
        }
        return true;
    });

    let resizeTimer = 0;
    let lastColumns = 0;
    let lastRows = 0;
    const reportSize = () => {
        const columns = terminal.cols;
        const rows = terminal.rows;
        if (columns < 20 || rows < 5) {
            return;
        }
        if (columns === lastColumns && rows === lastRows) {
            return;
        }
        lastColumns = columns;
        lastRows = rows;
        window.webkit.messageHandlers.terminalResize.postMessage({
            columns,
            rows
        });
    };
    const fitAndReport = () => {
        window.clearTimeout(resizeTimer);
        resizeTimer = window.setTimeout(() => {
            window.requestAnimationFrame(() => {
                fitAddon.fit();
                window.requestAnimationFrame(() => {
                    reportSize();
                    if (!suggestionsElement.hidden) {
                        positionSuggestions();
                    }
                });
            });
        }, 60);
    };

    terminal.onData((data) => {
        trackTerminalInput(data);
        window.webkit.messageHandlers.terminalInput.postMessage(data);
    });
    terminal.onResize(reportSize);

    const outputQueue = [];
    let outputWriteActive = false;
    const drainOutputQueue = () => {
        if (outputWriteActive || outputQueue.length === 0) {
            return;
        }
        outputWriteActive = true;
        const bytes = outputQueue.shift();
        observeTerminalOutput(bytes);
        terminal.write(bytes, () => {
            outputWriteActive = false;
            const alternateScreenActive = isAlternateScreen();
            if (alternateScreenActive) {
                alternateScreenWasActive = true;
                hideSuggestions();
            } else {
                if (alternateScreenWasActive) {
                    alternateScreenWasActive = false;
                    resetTrackedLine();
                    shellPromptReady = outputEndsInShellPrompt(recentVisibleOutput);
                }
                if (!suggestionsElement.hidden) {
                    positionSuggestions();
                }
            }
            drainOutputQueue();
        });
    };

    window.selectiveTerminalWriteBase64 = (base64) => {
        const binary = window.atob(base64);
        const bytes = new Uint8Array(binary.length);
        for (let index = 0; index < binary.length; index += 1) {
            bytes[index] = binary.charCodeAt(index);
        }
        outputQueue.push(bytes);
        drainOutputQueue();
    };

    window.selectiveTerminalApplySettings = (settings) => {
        if (!settings || typeof settings !== "object") {
            return;
        }
        if (typeof settings.fontFamily === "string" && settings.fontFamily.length > 0) {
            terminal.options.fontFamily = settings.fontFamily;
        }
        if (Number.isFinite(settings.fontSize)) {
            terminal.options.fontSize = Math.min(28, Math.max(10, settings.fontSize));
        }
        if (Number.isFinite(settings.lineHeight)) {
            terminal.options.lineHeight = Math.min(1.6, Math.max(1.0, settings.lineHeight));
        }
        if (["block", "bar", "underline"].includes(settings.cursorStyle)) {
            terminal.options.cursorStyle = settings.cursorStyle;
        }
        terminal.options.cursorBlink = settings.cursorBlink !== false;
        if (settings.theme && typeof settings.theme === "object") {
            terminal.options.theme = settings.theme;
            if (typeof settings.theme.background === "string") {
                const hex = settings.theme.background.replace("#", "");
                if (/^[0-9a-fA-F]{6}$/.test(hex)) {
                    const red = Number.parseInt(hex.slice(0, 2), 16);
                    const green = Number.parseInt(hex.slice(2, 4), 16);
                    const blue = Number.parseInt(hex.slice(4, 6), 16);
                    const luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue;
                    document.documentElement.classList.toggle(
                        "terminal-theme-light",
                        luminance > 160
                    );
                    document.documentElement.style.colorScheme =
                        luminance > 160 ? "light" : "dark";
                }
                document.documentElement.style.setProperty(
                    "--terminal-background",
                    settings.theme.background
                );
            }
        }
        if (Number.isFinite(settings.padding)) {
            const padding = Math.min(28, Math.max(0, settings.padding));
            document.documentElement.style.setProperty(
                "--terminal-padding",
                `${padding}px`
            );
        }
        fitAndReport();
    };

    window.selectiveTerminalSetHistory = (payload) => {
        if (!payload || typeof payload !== "object") {
            return;
        }
        historyEnabled = payload.enabled !== false;
        historyEntries = Array.isArray(payload.entries)
            ? payload.entries.filter((entry) => (
                entry
                && typeof entry.id === "string"
                && typeof entry.command === "string"
            ))
            : [];
        renderHistoryPanel();
        renderSuggestions();
    };

    window.selectiveTerminalSetHistoryVisible = (visible, notifySwift = false) => {
        const nextVisible = Boolean(visible);
        historyPanel.hidden = !nextVisible;
        hideSuggestions();
        if (nextVisible) {
            renderHistoryPanel();
            window.setTimeout(() => historyQuery.focus(), 0);
        } else {
            terminal.focus();
        }
        if (notifySwift) {
            postHistory({ action: "visibility", visible: nextVisible });
        }
    };

    historyQuery.addEventListener("input", renderHistoryPanel);
    commandTabs.forEach((button) => {
        button.addEventListener("click", () => {
            activePanelSection = button.dataset.section === "catalog"
                ? "catalog"
                : "history";
            renderHistoryPanel();
            historyQuery.focus();
        });
    });
    historyEnabledInput.addEventListener("change", () => {
        postHistory({ action: "setEnabled", enabled: historyEnabledInput.checked });
    });
    historyClearButton.addEventListener("click", () => {
        if (historyEntries.length > 0
            && window.confirm("Очистить историю команд для этого подключения?")) {
            postHistory({ action: "clear" });
        }
    });
    historyCloseButton.addEventListener("click", () => {
        window.selectiveTerminalSetHistoryVisible(false, true);
    });
    historyPanel.addEventListener("keydown", (event) => {
        if (event.key === "Escape") {
            event.preventDefault();
            window.selectiveTerminalSetHistoryVisible(false, true);
        }
    });

    window.selectiveTerminalClear = () => terminal.clear();
    window.selectiveTerminalFocus = () => terminal.focus();
    window.selectiveTerminalFit = fitAndReport;

    const resizeObserver = new ResizeObserver(fitAndReport);
    resizeObserver.observe(terminalHost);
    window.addEventListener("resize", fitAndReport);
    window.visualViewport?.addEventListener("resize", fitAndReport);
    document.fonts?.ready.then(fitAndReport);
    fitAndReport();
    terminal.focus();
})();
