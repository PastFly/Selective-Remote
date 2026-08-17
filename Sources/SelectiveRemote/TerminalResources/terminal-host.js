(() => {
    "use strict";

    const terminalHost = document.getElementById("terminal");
    const terminalShell = document.getElementById("terminal-shell");
    const inputHighlightElement = document.getElementById("terminal-input-highlight");
    const terminalSearchPanel = document.getElementById("terminal-search");
    const terminalSearchQuery = document.getElementById("terminal-search-query");
    const terminalSearchCount = document.getElementById("terminal-search-count");
    const terminalSearchPrevious = document.getElementById("terminal-search-previous");
    const terminalSearchNext = document.getElementById("terminal-search-next");
    const terminalSearchClose = document.getElementById("terminal-search-close");
    const suggestionsElement = document.getElementById("terminal-suggestions");
    const historyPanel = document.getElementById("terminal-history");
    const historyQuery = document.getElementById("history-query");
    const historyList = document.getElementById("history-list");
    const historyEmpty = document.getElementById("history-empty");
    const historyEnabledInput = document.getElementById("history-enabled");
    const historyClearButton = document.getElementById("history-clear");
    const historyCloseButton = document.getElementById("history-close");
    const historyOptions = document.getElementById("history-options");
    const templateOptions = document.getElementById("template-options");
    const templateAddButton = document.getElementById("template-add");
    const templateDialog = document.getElementById("template-dialog");
    const templateForm = document.getElementById("template-form");
    const templateID = document.getElementById("template-id");
    const templateTitle = document.getElementById("template-title");
    const templateCategory = document.getElementById("template-category");
    const templateCommand = document.getElementById("template-command");
    const templateCancel = document.getElementById("template-cancel");
    const commandPanelTitle = document.getElementById("command-panel-title");
    const commandPanelSubtitle = document.getElementById("command-panel-subtitle");
    const commandEmptyTitle = document.getElementById("command-empty-title");
    const commandEmptyMessage = document.getElementById("command-empty-message");
    const remoteContextRetryButton = document.getElementById("remote-context-retry");
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


    const postSmartLink = (kind, value) => {
        window.webkit?.messageHandlers?.terminalSmartLink?.postMessage({
            kind,
            value
        });
    };

    const trimmedSmartLink = (raw) => {
        let value = raw;
        while (value.length > 0 && /[.,;!?)\]}]$/.test(value)) {
            value = value.slice(0, -1);
        }
        return value;
    };

    const terminalSmartLinksForLine = (text) => {
        const candidates = [];

        const appendMatches = (kind, regex, captureIndex = 0) => {
            regex.lastIndex = 0;
            let match;
            while ((match = regex.exec(text)) !== null) {
                const raw = match[captureIndex];
                if (!raw) {
                    if (match[0].length === 0) {
                        regex.lastIndex += 1;
                    }
                    continue;
                }
                const offset = captureIndex === 0
                    ? 0
                    : match[0].lastIndexOf(raw);
                const value = trimmedSmartLink(raw);
                if (!value) {
                    continue;
                }
                const start = match.index + Math.max(0, offset);
                candidates.push({
                    kind,
                    value,
                    start,
                    end: start + value.length
                });
            }
        };

        appendMatches("url", /https?:\/\/[^\s<>"'`]+/gi);
        appendMatches(
            "path",
            /(?:^|\s)((?:~\/|\/|\.\/|\.\.\/)[^\s<>"'`]+)/g,
            1
        );
        appendMatches(
            "host",
            /\b(?:(?:\d{1,3}\.){3}\d{1,3}|(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}|[A-Za-z0-9-]+\.local)(?::\d{1,5})?\b/g
        );

        const priority = { url: 0, path: 1, host: 2 };
        candidates.sort((left, right) => {
            if (priority[left.kind] !== priority[right.kind]) {
                return priority[left.kind] - priority[right.kind];
            }
            return left.start - right.start;
        });

        const accepted = [];
        candidates.forEach((candidate) => {
            const overlaps = accepted.some((existing) => (
                candidate.start < existing.end
                && candidate.end > existing.start
            ));
            if (!overlaps) {
                accepted.push(candidate);
            }
        });
        return accepted.sort((left, right) => left.start - right.start);
    };

    if (typeof terminal.registerLinkProvider === "function") {
        terminal.registerLinkProvider({
            provideLinks(lineNumber, callback) {
                if (terminal.buffer.active.type === "alternate") {
                    callback([]);
                    return;
                }
                const line = terminal.buffer.active.getLine(lineNumber - 1);
                if (!line) {
                    callback([]);
                    return;
                }
                const text = line.translateToString(true);
                const links = terminalSmartLinksForLine(text).map((link) => ({
                    text: link.value,
                    range: {
                        start: { x: link.start + 1, y: lineNumber },
                        end: { x: link.end, y: lineNumber }
                    },
                    activate: () => postSmartLink(link.kind, link.value),
                    decorations: {
                        pointerCursor: true,
                        underline: true
                    }
                }));
                callback(links);
            }
        });
    }

    const builtInCommandCatalog = (window.selectiveTerminalCommandCatalog || [])
        .map((entry, index) => ({
        ...entry,
        id: `catalog-${index}`,
        source: "catalog",
        useCount: 0,
        lastUsedAt: 0
    }));

    let historyEntries = [];
    let historyEnabled = true;
    let favoriteCommands = new Set();
    let commandTemplates = [];
    let remoteCommandEntries = [];
    let remoteContextMessage = "Подключите SSH и обновите сведения о сервере";
    let remoteSystemLabel = "";
    let remoteContextCanRetry = false;
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
    let syntaxHighlightingEnabled = true;
    let syntaxHighlightScope = "visibleCommands";
    let syntaxHistoryOpacity = 0.82;
    let syntaxBoldCommands = true;
    let inputHighlightOrigin = null;
    let knownPromptPrefixes = [];
    let recentVisibleOutput = "";
    let activePanelSection = "history";
    let alternateScreenWasActive = false;
    let terminalSearchResults = [];
    let terminalSearchIndex = -1;
    const outputTextDecoder = new TextDecoder("utf-8");

    const postHistory = (payload) => {
        window.webkit?.messageHandlers?.terminalHistory?.postMessage(payload);
    };
    const notifyHostFocus = () => {
        window.webkit?.messageHandlers?.terminalFocus?.postMessage(true);
    };

    const isAlternateScreen = () => terminal.buffer.active.type === "alternate";

    const clearInputHighlight = () => {
        inputHighlightOrigin = null;
        inputHighlightElement.replaceChildren();
        inputHighlightElement.hidden = true;
    };

    const captureInputHighlightOrigin = () => {
        const buffer = terminal.buffer.active;
        const row = buffer.baseY + buffer.cursorY;
        const line = buffer.getLine(row);
        inputHighlightOrigin = {
            x: buffer.cursorX,
            y: buffer.cursorY,
            baseY: buffer.baseY,
            bufferType: buffer.type,
            promptPrefix: line?.translateToString(false, 0, buffer.cursorX) || ""
        };
    };

    /*
     * readline/zsh can redraw or expand the command without sending the same
     * editing bytes back to our local tracker (Tab completion, Delete,
     * Option/Meta editing, asynchronous shell redraws). In that case the xterm
     * buffer is the source of truth. Recover only when the visible prompt
     * prefix is exactly the one captured when input started.
     */
    const recoverTrackedLineFromTerminal = () => {
        if (!inputHighlightOrigin || isAlternateScreen()) {
            return false;
        }

        const buffer = terminal.buffer.active;
        if (buffer.type !== inputHighlightOrigin.bufferType
            || buffer.cursorX < inputHighlightOrigin.x) {
            return false;
        }

        const row = buffer.baseY + buffer.cursorY;
        const line = buffer.getLine(row);
        if (!line || line.isWrapped === true) {
            return false;
        }

        const promptPrefix = line.translateToString(
            false,
            0,
            inputHighlightOrigin.x
        );
        if (promptPrefix !== inputHighlightOrigin.promptPrefix) {
            return false;
        }

        const visibleCommand = line.translateToString(
            true,
            inputHighlightOrigin.x
        );
        const recoveredLine = Array.from(visibleCommand);
        const recoveredCursor = Math.max(
            0,
            Math.min(
                recoveredLine.length,
                buffer.cursorX - inputHighlightOrigin.x
            )
        );

        currentLine = recoveredLine;
        inputCursor = recoveredCursor;
        lineTrackingReliable = true;
        lineInputStarted = recoveredLine.length > 0;
        lineStartedAtShellPrompt = true;
        inputHighlightOrigin = {
            ...inputHighlightOrigin,
            y: buffer.cursorY,
            baseY: buffer.baseY
        };
        return true;
    };

    const shellControlOperators = new Set(["|", "||", "&&", ";", "("]);
    const shellCommandWrappers = new Set([
        "sudo", "command", "env", "exec", "nohup", "time", "builtin"
    ]);

    const classifyShellWord = (word, commandExpected) => {
        if (/^-{1,2}\S+/.test(word) && !/^-\d/.test(word)) {
            return { type: "option", commandExpected };
        }
        if (commandExpected) {
            return {
                type: "command",
                commandExpected: shellCommandWrappers.has(word)
            };
        }
        if (/^[+-]?\d+(?:\.\d+)?$/.test(word)) {
            return { type: "number", commandExpected: false };
        }
        if (/^(?:\/|~\/|\.{1,2}\/)/.test(word) || word.includes("/")) {
            return { type: "path", commandExpected: false };
        }
        return { type: "plain", commandExpected: false };
    };

    const tokenizeShellSyntax = (text) => {
        const tokens = [];
        let index = 0;
        let commandExpected = true;

        const push = (value, type = "plain") => {
            if (value) {
                tokens.push({ text: value, type });
            }
        };

        while (index < text.length) {
            const character = text[index];

            if (/\s/.test(character)) {
                let end = index + 1;
                while (end < text.length && /\s/.test(text[end])) {
                    end += 1;
                }
                push(text.slice(index, end));
                index = end;
                continue;
            }

            if (character === "#"
                && (index === 0 || /\s/.test(text[index - 1]))) {
                push(text.slice(index), "comment");
                break;
            }

            if (character === "'" || character === "\"") {
                const quote = character;
                let end = index + 1;
                while (end < text.length) {
                    if (quote === "\"" && text[end] === "\\" && end + 1 < text.length) {
                        end += 2;
                        continue;
                    }
                    if (text[end] === quote) {
                        end += 1;
                        break;
                    }
                    end += 1;
                }
                push(text.slice(index, end), "string");
                commandExpected = false;
                index = end;
                continue;
            }

            if (character === "$") {
                if (text.startsWith("$(", index)) {
                    push("$(", "operator");
                    commandExpected = true;
                    index += 2;
                    continue;
                }
                if (text.startsWith("${", index)) {
                    const close = text.indexOf("}", index + 2);
                    const end = close >= 0 ? close + 1 : text.length;
                    push(text.slice(index, end), "variable");
                    commandExpected = false;
                    index = end;
                    continue;
                }
                const match = text.slice(index).match(
                    /^\$(?:[A-Za-z_][A-Za-z0-9_]*|[0-9]+|[?@#*$!_-])/
                );
                if (match) {
                    push(match[0], "variable");
                    commandExpected = false;
                    index += match[0].length;
                    continue;
                }
            }

            const doubleOperator = text.slice(index, index + 2);
            if (["&&", "||", ">>", "<<"].includes(doubleOperator)) {
                push(doubleOperator, "operator");
                if (shellControlOperators.has(doubleOperator)) {
                    commandExpected = true;
                }
                index += 2;
                continue;
            }

            if ("|;<>()".includes(character)) {
                push(character, "operator");
                if (shellControlOperators.has(character)) {
                    commandExpected = true;
                }
                index += 1;
                continue;
            }

            let end = index + 1;
            while (end < text.length
                && !/\s/.test(text[end])
                && !"|&;<>()'\"".includes(text[end])) {
                if (text[end] === "#"
                    && (end === 0 || /\s/.test(text[end - 1]))) {
                    break;
                }
                end += 1;
            }

            const word = text.slice(index, end);
            const assignment = word.match(/^([A-Za-z_][A-Za-z0-9_]*)(=)(.*)$/);
            if (assignment) {
                push(assignment[1], "variable");
                push(assignment[2], "operator");
                if (assignment[3]) {
                    const classified = classifyShellWord(assignment[3], false);
                    push(assignment[3], classified.type);
                }
                index = end;
                continue;
            }

            const classified = classifyShellWord(word, commandExpected);
            push(word, classified.type);
            commandExpected = classified.commandExpected;
            index = end;
        }

        return tokens;
    };

    /*
     * Syntax highlighting is rendered as a visual overlay over xterm.
     * Only lines that confidently look like shell command lines are touched.
     * Remote output and its ANSI colors remain xterm-owned.
     */
    const rememberPromptPrefix = (prefix) => {
        if (typeof prefix !== "string") {
            return;
        }
        const normalized = prefix.slice(0, 160);
        if (!normalized || knownPromptPrefixes.includes(normalized)) {
            return;
        }
        knownPromptPrefixes = [normalized, ...knownPromptPrefixes].slice(0, 24);
    };

    const detectedPromptLength = (visibleLine, isActive) => {
        const capturedPrefix = inputHighlightOrigin?.promptPrefix;
        if (isActive
            && typeof capturedPrefix === "string"
            && capturedPrefix.length > 0
            && visibleLine.startsWith(capturedPrefix)) {
            rememberPromptPrefix(capturedPrefix);
            return capturedPrefix.length;
        }

        const remembered = knownPromptPrefixes
            .filter((prefix) => visibleLine.startsWith(prefix))
            .sort((left, right) => right.length - left.length)[0];
        if (remembered) {
            return remembered.length;
        }

        const patterns = [
            /^PS\s+[^\r\n]{1,120}>\s*/,
            /^[A-Za-z]:\\[^>\r\n]{0,120}>\s*/,
            /^(?:\([^)\r\n]{1,40}\)\s*)?[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+(?::[^\s#$%\r\n]{0,100})?[#$%]\s*/,
            /^(?:\([^)\r\n]{1,40}\)\s*)?[❯➜]\s*/
        ];
        for (const pattern of patterns) {
            const match = visibleLine.match(pattern);
            if (match) {
                rememberPromptPrefix(match[0]);
                return match[0].length;
            }
        }
        return -1;
    };

    const shellCommandRegionsFromBuffer = () => {
        if (isAlternateScreen()) {
            return [];
        }

        const buffer = terminal.buffer.active;
        const viewportY = buffer.viewportY;
        const activeBufferRow = buffer.baseY + buffer.cursorY;
        const regions = [];

        for (let viewportRow = 0; viewportRow < terminal.rows; viewportRow += 1) {
            const bufferRow = viewportY + viewportRow;
            const isActive = bufferRow === activeBufferRow;
            if (syntaxHighlightScope === "currentLine" && !isActive) {
                continue;
            }

            const line = buffer.getLine(bufferRow);
            if (!line || line.isWrapped === true) {
                continue;
            }

            const visibleLine = line.translateToString(true);
            if (!visibleLine) {
                continue;
            }

            const commandStartX = detectedPromptLength(visibleLine, isActive);
            if (commandStartX < 0 || commandStartX >= visibleLine.length) {
                continue;
            }

            const command = visibleLine.slice(commandStartX).replace(/\s+$/, "");
            if (!command) {
                continue;
            }

            regions.push({
                text: command,
                startX: commandStartX,
                viewportRow,
                isActive
            });
        }

        return regions;
    };

    const renderInputHighlight = () => {
        if (!syntaxHighlightingEnabled || isAlternateScreen()) {
            inputHighlightElement.replaceChildren();
            inputHighlightElement.hidden = true;
            return;
        }

        const screen = terminal.element?.querySelector(".xterm-screen");
        if (!screen || terminal.cols <= 0 || terminal.rows <= 0) {
            inputHighlightElement.replaceChildren();
            inputHighlightElement.hidden = true;
            return;
        }

        const regions = shellCommandRegionsFromBuffer();
        if (regions.length === 0) {
            inputHighlightElement.replaceChildren();
            inputHighlightElement.hidden = true;
            return;
        }

        const screenRect = screen.getBoundingClientRect();
        const shellRect = terminalShell.getBoundingClientRect();
        const cellWidth = screenRect.width / terminal.cols;
        const cellHeight = screenRect.height / terminal.rows;
        if (!Number.isFinite(cellWidth)
            || !Number.isFinite(cellHeight)
            || cellWidth <= 0
            || cellHeight <= 0) {
            inputHighlightElement.replaceChildren();
            inputHighlightElement.hidden = true;
            return;
        }

        const fragment = document.createDocumentFragment();
        regions.forEach((region) => {
            const row = document.createElement("div");
            row.className = region.isActive
                ? "terminal-syntax-row is-active"
                : "terminal-syntax-row is-history";
            row.style.left = `${
                screenRect.left - shellRect.left + region.startX * cellWidth
            }px`;
            row.style.top = `${
                screenRect.top - shellRect.top + region.viewportRow * cellHeight
            }px`;
            row.style.width = `${
                Math.max(0, screenRect.width - region.startX * cellWidth)
            }px`;
            row.style.height = `${cellHeight}px`;
            row.style.lineHeight = `${cellHeight}px`;

            tokenizeShellSyntax(region.text).forEach((token) => {
                const span = document.createElement("span");
                span.className = `syntax-${token.type}`;
                span.textContent = token.text;
                row.append(span);
            });
            fragment.append(row);
        });

        inputHighlightElement.replaceChildren(fragment);
        inputHighlightElement.hidden = false;
    };

    let syntaxRenderFrame = 0;
    const scheduleInputHighlightRender = () => {
        if (syntaxRenderFrame !== 0) {
            return;
        }
        syntaxRenderFrame = window.requestAnimationFrame(() => {
            syntaxRenderFrame = 0;
            renderInputHighlight();
        });
    };

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
        const visibleText = visibleOutputText(text);
        if (lineInputStarted
            && lineStartedAtShellPrompt
            && /[\r\n]/.test(visibleText)) {
            lineTrackingReliable = false;
            inputHighlightElement.replaceChildren();
            inputHighlightElement.hidden = true;
        }
        if (lineInputStarted) {
            echoCapture = (echoCapture + text).slice(-16_384);
        }
        pendingHistoryCandidates.forEach((candidate) => {
            candidate.output = (candidate.output + text).slice(-16_384);
        });
        recentVisibleOutput = (recentVisibleOutput + visibleText).slice(-16_384);
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

    const normalizedSearchTokens = (value) => value
        .trim()
        .toLocaleLowerCase()
        // Treat common shell path spelling as equivalent for command discovery:
        // `nano .ssh`, `nano ~/.ssh` and `authorized_key` should find the same row.
        .replaceAll("~/", "")
        .replace(/[\/._~=-]+/g, " ")
        .split(/\s+/)
        .filter(Boolean);

    const matchingCatalog = (query, limit = Number.POSITIVE_INFINITY) => {
        const normalized = query.trim().toLocaleLowerCase();
        if (!normalized) {
            return builtInCommandCatalog.slice(0, limit);
        }
        const queryTokens = normalizedSearchTokens(normalized);
        return builtInCommandCatalog
            .map((entry, order) => {
                const command = entry.command.toLocaleLowerCase();
                const details = `${entry.description} ${entry.category} ${entry.keywords}`
                    .toLocaleLowerCase();
                const combined = `${command} ${details}`;
                const commandIndex = command.indexOf(normalized);
                const detailsIndex = details.indexOf(normalized);
                const searchableTokens = normalizedSearchTokens(combined);
                const fuzzyTokenMatch = queryTokens.length > 0
                    && queryTokens.every((token) => searchableTokens.some(
                        (candidate) => candidate === token
                            || candidate.startsWith(token)
                            || token.startsWith(candidate)
                    ));
                let rank = 5;
                if (commandIndex === 0) {
                    rank = 0;
                } else if (commandIndex > 0) {
                    rank = 1;
                } else if (detailsIndex === 0) {
                    rank = 2;
                } else if (detailsIndex > 0) {
                    rank = 3;
                } else if (fuzzyTokenMatch) {
                    rank = 4;
                }
                return { entry, order, rank };
            })
            .filter((candidate) => candidate.rank < 5)
            .sort((left, right) => left.rank - right.rank || left.order - right.order)
            .slice(0, limit)
            .map((candidate) => candidate.entry);
    };

    const matchingEntries = (entries, query, limit = Number.POSITIVE_INFINITY) => {
        const normalized = query.trim().toLocaleLowerCase();
        if (!normalized) {
            return entries.slice(0, limit);
        }
        return entries
            .map((entry, order) => {
                const command = entry.command.toLocaleLowerCase();
                const details = `${entry.title || ""} ${entry.description || ""} ${entry.category || ""} ${entry.keywords || ""}`
                    .toLocaleLowerCase();
                const commandIndex = command.indexOf(normalized);
                const detailsIndex = details.indexOf(normalized);
                const rank = commandIndex === 0 ? 0
                    : commandIndex > 0 ? 1
                        : detailsIndex === 0 ? 2
                            : detailsIndex > 0 ? 3 : 4;
                return { entry, order, rank };
            })
            .filter((candidate) => candidate.rank < 4)
            .sort((left, right) => left.rank - right.rank || left.order - right.order)
            .slice(0, limit)
            .map((candidate) => candidate.entry);
    };

    const favoriteEntries = () => {
        const sources = [
            ...historyEntries,
            ...commandTemplates,
            ...remoteCommandEntries,
            ...builtInCommandCatalog
        ];
        const known = new Map(sources.map((entry) => [entry.command, entry]));
        return Array.from(favoriteCommands).map((command, index) => ({
            ...(known.get(command) || {}),
            id: known.get(command)?.id || `favorite-${index}`,
            command,
            source: "favorite",
            category: known.get(command)?.category || "Избранное",
            description: known.get(command)?.description || "Сохранённая команда"
        }));
    };

    const matchingSuggestions = (query, limit = 6) => {
        const combined = [];
        matchingEntries(favoriteEntries(), query).forEach((entry) => combined.push(entry));
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
        matchingEntries(remoteCommandEntries, query).forEach((entry) => combined.push(entry));
        matchingEntries(commandTemplates, query).forEach((entry) => combined.push(entry));
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

    const resolveTemplate = (command) => {
        const names = Array.from(new Set(
            Array.from(command.matchAll(/\$\{([A-Za-z][A-Za-z0-9_-]{0,39})\}/g))
                .map((match) => match[1])
        ));
        let resolved = command;
        for (const name of names) {
            const value = window.prompt(`Значение для ${name}:`, "");
            if (value === null) {
                return null;
            }
            resolved = resolved.replaceAll(`\${${name}}`, value);
        }
        return resolved;
    };

    const useCommandEntry = (entry, closeHistory = false) => {
        const command = /\$\{[A-Za-z][A-Za-z0-9_-]{0,39}\}/.test(entry.command)
            ? resolveTemplate(entry.command)
            : entry.command;
        if (command !== null) {
            replaceCurrentLine(command, closeHistory);
        }
    };

    const renderSuggestions = () => {
        if (!lineTrackingReliable) {
            recoverTrackedLineFromTerminal();
        }
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
            symbol.textContent = entry.source === "history" ? "◷"
                : entry.source === "favorite" ? "★"
                    : entry.source === "remote" ? "⌁"
                        : entry.source === "template" ? "◆" : "›";
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
                : `${entry.category} · ${entry.description || entry.title || "Команда"}`;
            content.append(command, description);
            row.append(symbol, content);
            row.addEventListener("pointerdown", (event) => event.preventDefault());
            row.addEventListener("click", () => useCommandEntry(entry));
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

    const openTemplateEditor = (entry = null) => {
        templateID.value = entry?.id || "";
        templateTitle.value = entry?.title || "";
        templateCategory.value = entry?.category || "Мои команды";
        templateCommand.value = entry?.command || "";
        templateDialog.showModal();
        window.setTimeout(() => templateTitle.focus(), 0);
    };

    const renderHistoryPanel = () => {
        const query = historyQuery.value;
        const sections = {
            history: {
                title: "История команд",
                subtitle: "Сохранена только на этом Mac",
                entries: matchingHistory(query),
                emptyTitle: "История пока пуста",
                emptyMessage: "Выполненные команды появятся здесь автоматически."
            },
            catalog: {
                title: "Общие команды",
                subtitle: `${builtInCommandCatalog.length} готовых команд и шаблонов`,
                entries: matchingCatalog(query),
                emptyTitle: "Команды не найдены",
                emptyMessage: "Измените запрос или выберите другой раздел."
            },
            remote: {
                title: "Команды сервера",
                subtitle: remoteSystemLabel || remoteContextMessage,
                entries: matchingEntries(remoteCommandEntries, query),
                emptyTitle: "Контекст сервера пока пуст",
                emptyMessage: remoteContextMessage
            },
            favorites: {
                title: "Избранное",
                subtitle: "Часто используемые команды этого подключения",
                entries: matchingEntries(favoriteEntries(), query),
                emptyTitle: "В избранном пока пусто",
                emptyMessage: "Нажмите звезду рядом с любой командой."
            },
            templates: {
                title: "Мои шаблоны",
                subtitle: "Параметризованные команды этого подключения",
                entries: matchingEntries(commandTemplates, query),
                emptyTitle: "Шаблонов пока нет",
                emptyMessage: "Создайте команду с параметрами вида ${service}."
            }
        };
        const section = sections[activePanelSection] || sections.history;
        const filtered = section.entries;
        commandPanelTitle.textContent = section.title;
        commandPanelSubtitle.textContent = section.subtitle;
        historyOptions.hidden = activePanelSection !== "history";
        templateOptions.hidden = activePanelSection !== "templates";
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
            if (activePanelSection === "history") {
                const used = entry.useCount > 1 ? ` · запусков: ${entry.useCount}` : "";
                meta.textContent = `${formatHistoryDate(entry.lastUsedAt)}${used}`;
            } else if (activePanelSection === "templates") {
                meta.textContent = `${entry.category} · ${entry.title}`;
            } else {
                meta.textContent = `${entry.category} · ${entry.description}`;
            }
            useButton.append(command, meta);
            useButton.addEventListener("click", () => useCommandEntry(entry, true));

            const actions = document.createElement("span");
            actions.className = "history-actions";
            const favoriteButton = document.createElement("button");
            favoriteButton.type = "button";
            favoriteButton.className = "history-action favorite-action";
            const isFavorite = favoriteCommands.has(entry.command);
            favoriteButton.textContent = isFavorite ? "★" : "☆";
            favoriteButton.title = isFavorite ? "Убрать из избранного" : "Добавить в избранное";
            favoriteButton.setAttribute("aria-label", favoriteButton.title);
            favoriteButton.addEventListener("click", () => {
                postHistory({ action: "toggleFavorite", command: entry.command });
            });
            actions.append(favoriteButton);

            if (activePanelSection === "history") {
                const removeButton = document.createElement("button");
                removeButton.type = "button";
                removeButton.className = "history-action";
                removeButton.title = "Удалить из истории";
                removeButton.setAttribute("aria-label", `Удалить команду ${entry.command}`);
                removeButton.textContent = "×";
                removeButton.addEventListener("click", () => {
                    postHistory({ action: "remove", id: entry.id });
                });
                actions.append(removeButton);
            } else if (activePanelSection === "templates") {
                const editButton = document.createElement("button");
                editButton.type = "button";
                editButton.className = "history-action";
                editButton.textContent = "✎";
                editButton.title = "Изменить шаблон";
                editButton.addEventListener("click", () => openTemplateEditor(entry));
                const removeButton = document.createElement("button");
                removeButton.type = "button";
                removeButton.className = "history-action";
                removeButton.textContent = "×";
                removeButton.title = "Удалить шаблон";
                removeButton.addEventListener("click", () => {
                    if (window.confirm(`Удалить шаблон «${entry.title}»?`)) {
                        postHistory({ action: "removeTemplate", id: entry.id });
                    }
                });
                actions.append(editButton, removeButton);
            }
            row.append(useButton, actions);
            historyList.append(row);
        });

        const empty = filtered.length === 0;
        commandEmptyTitle.textContent = section.emptyTitle;
        commandEmptyMessage.textContent = section.emptyMessage;
        historyList.hidden = empty;
        historyEmpty.hidden = !empty;
        remoteContextRetryButton.hidden = !(
            activePanelSection === "remote" && empty && remoteContextCanRetry
        );
        historyClearButton.disabled = historyEntries.length === 0;
        historyEnabledInput.checked = historyEnabled;
    };

    const updateTerminalSearchCount = () => {
        const total = terminalSearchResults.length;
        const current = total > 0 && terminalSearchIndex >= 0
            ? terminalSearchIndex + 1
            : 0;
        terminalSearchCount.textContent = `${current} из ${total}`;
        terminalSearchPrevious.disabled = total === 0;
        terminalSearchNext.disabled = total === 0;
    };

    const selectTerminalSearchResult = (index) => {
        const total = terminalSearchResults.length;
        if (total === 0) {
            terminalSearchIndex = -1;
            terminal.clearSelection();
            updateTerminalSearchCount();
            return;
        }
        terminalSearchIndex = ((index % total) + total) % total;
        const result = terminalSearchResults[terminalSearchIndex];
        terminal.select(result.column, result.row, result.length);
        terminal.scrollToLine(result.row);
        updateTerminalSearchCount();
    };

    const refreshTerminalSearch = (preserveIndex = true) => {
        const query = terminalSearchQuery.value.trim();
        const previousIndex = terminalSearchIndex;
        terminalSearchResults = [];
        if (!query) {
            terminalSearchIndex = -1;
            terminal.clearSelection();
            updateTerminalSearchCount();
            return;
        }

        const normalized = query.toLocaleLowerCase();
        const buffer = terminal.buffer.active;
        for (let row = 0; row < buffer.length; row += 1) {
            const line = buffer.getLine(row)?.translateToString(true) || "";
            const lower = line.toLocaleLowerCase();
            let from = 0;
            while (from <= lower.length - normalized.length) {
                const column = lower.indexOf(normalized, from);
                if (column < 0) {
                    break;
                }
                terminalSearchResults.push({ row, column, length: query.length });
                from = column + Math.max(1, normalized.length);
            }
        }

        if (terminalSearchResults.length === 0) {
            terminalSearchIndex = -1;
            terminal.clearSelection();
            updateTerminalSearchCount();
            return;
        }
        selectTerminalSearchResult(
            preserveIndex && previousIndex >= 0
                ? Math.min(previousIndex, terminalSearchResults.length - 1)
                : 0
        );
    };

    const openTerminalSearch = () => {
        hideSuggestions();
        if (!historyPanel.hidden) {
            window.selectiveTerminalSetHistoryVisible(false, true, false);
        }
        terminalSearchPanel.hidden = false;
        refreshTerminalSearch(false);
        window.setTimeout(() => {
            terminalSearchQuery.focus();
            terminalSearchQuery.select();
        }, 0);
    };

    const closeTerminalSearch = () => {
        terminalSearchPanel.hidden = true;
        terminalSearchResults = [];
        terminalSearchIndex = -1;
        terminal.clearSelection();
        updateTerminalSearchCount();
        terminal.focus();
    };

    const moveTerminalSearch = (delta) => {
        if (terminalSearchResults.length === 0) {
            refreshTerminalSearch(false);
            return;
        }
        selectTerminalSearchResult(terminalSearchIndex + delta);
    };

    const resetTrackedLine = () => {
        currentLine = [];
        inputCursor = 0;
        lineTrackingReliable = true;
        echoCapture = "";
        lineInputStarted = false;
        lineStartedAtShellPrompt = false;
        clearInputHighlight();
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
            renderInputHighlight();
            return;
        }
        if (["\u001b[H", "\u001bOH", "\u0001"].includes(data)) {
            inputCursor = 0;
            renderSuggestions();
            renderInputHighlight();
            return;
        }
        if (["\u001b[F", "\u001bOF", "\u0005"].includes(data)) {
            inputCursor = currentLine.length;
            renderSuggestions();
            renderInputHighlight();
            return;
        }
        if (data.startsWith("\u001b")) {
            lineTrackingReliable = false;
            inputHighlightElement.replaceChildren();
            inputHighlightElement.hidden = true;
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
                        if (lineStartedAtShellPrompt) {
                            captureInputHighlightOrigin();
                        }
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
        renderInputHighlight();
    };

    terminal.attachCustomKeyEventHandler((event) => {
        if (event.type !== "keydown") {
            return true;
        }
        if (event.metaKey && event.key.toLocaleLowerCase() === "f") {
            openTerminalSearch();
            return false;
        }
        if (event.metaKey && /^[1-8]$/.test(event.key)) {
            window.webkit?.messageHandlers?.terminalNavigation?.postMessage(
                Number.parseInt(event.key, 10) - 1
            );
            return false;
        }
        if (event.ctrlKey && event.key === "Tab") {
            window.webkit?.messageHandlers?.terminalNavigation?.postMessage(
                event.shiftKey ? -2 : -1
            );
            return false;
        }
        if (!terminalSearchPanel.hidden && event.key === "Escape") {
            closeTerminalSearch();
            return false;
        }
        if (event.metaKey && event.shiftKey && event.key.toLocaleLowerCase() === "y") {
            if (!terminalSearchPanel.hidden) {
                closeTerminalSearch();
            }
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
            selectedSuggestionIndex = currentSuggestions.length === 0
                ? -1
                : (selectedSuggestionIndex + 1 + currentSuggestions.length)
                    % currentSuggestions.length;
            updateSelectedSuggestion();
            return false;
        }
        if (event.key === "ArrowUp") {
            selectedSuggestionIndex = currentSuggestions.length === 0
                ? -1
                : (selectedSuggestionIndex < 0
                    ? currentSuggestions.length - 1
                    : (selectedSuggestionIndex - 1 + currentSuggestions.length)
                        % currentSuggestions.length);
            updateSelectedSuggestion();
            return false;
        }
        if (event.key === "Tab" && currentSuggestions.length > 0) {
            const index = selectedSuggestionIndex >= 0
                ? selectedSuggestionIndex
                : 0;
            useCommandEntry(currentSuggestions[index]);
            return false;
        }
        if (event.key === "Enter" && selectedSuggestionIndex >= 0) {
            useCommandEntry(currentSuggestions[selectedSuggestionIndex]);
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
                    renderInputHighlight();
                });
            });
        }, 60);
    };

    terminal.onData((data) => {
        trackTerminalInput(data);
        window.webkit.messageHandlers.terminalInput.postMessage(data);
    });
    terminal.onResize(() => {
        reportSize();
        scheduleInputHighlightRender();
    });
    terminal.onWriteParsed(() => {
        scheduleInputHighlightRender();
    });
    terminal.onScroll(() => {
        scheduleInputHighlightRender();
    });
    terminalHost.addEventListener("pointerdown", notifyHostFocus, true);
    terminalHost.addEventListener("focusin", notifyHostFocus, true);

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
                inputHighlightElement.replaceChildren();
                inputHighlightElement.hidden = true;
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
            if (!terminalSearchPanel.hidden && terminalSearchQuery.value.trim()) {
                refreshTerminalSearch(true);
            }

            const recoveredTrackedLine = (
                lineInputStarted
                && lineStartedAtShellPrompt
                && inputHighlightOrigin
            ) ? recoverTrackedLineFromTerminal() : false;

            if (recoveredTrackedLine) {
                renderSuggestions();
            }
            scheduleInputHighlightRender();
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
            document.documentElement.style.setProperty(
                "--terminal-font-family",
                settings.fontFamily
            );
        }
        if (Number.isFinite(settings.fontSize)) {
            terminal.options.fontSize = Math.min(28, Math.max(10, settings.fontSize));
            document.documentElement.style.setProperty(
                "--terminal-font-size",
                `${terminal.options.fontSize}px`
            );
        }
        if (Number.isFinite(settings.lineHeight)) {
            terminal.options.lineHeight = Math.min(1.6, Math.max(1.0, settings.lineHeight));
        }
        if (["block", "bar", "underline"].includes(settings.cursorStyle)) {
            terminal.options.cursorStyle = settings.cursorStyle;
        }
        terminal.options.cursorBlink = settings.cursorBlink !== false;
        syntaxHighlightingEnabled = settings.syntaxHighlighting !== false;
        syntaxHighlightScope = ["currentLine", "visibleCommands"].includes(settings.syntaxScope)
            ? settings.syntaxScope
            : "visibleCommands";
        syntaxHistoryOpacity = Number.isFinite(settings.syntaxHistoryOpacity)
            ? Math.min(1.0, Math.max(0.45, settings.syntaxHistoryOpacity))
            : 0.82;
        syntaxBoldCommands = settings.syntaxBoldCommands !== false;
        document.documentElement.style.setProperty(
            "--syntax-history-opacity",
            String(syntaxHistoryOpacity)
        );
        document.documentElement.style.setProperty(
            "--syntax-command-weight",
            syntaxBoldCommands ? "600" : "400"
        );
        if (!syntaxHighlightingEnabled) {
            inputHighlightElement.replaceChildren();
            inputHighlightElement.hidden = true;
        }
        if (settings.theme && typeof settings.theme === "object") {
            terminal.options.theme = settings.theme;
            const theme = settings.theme;
            const rootStyle = document.documentElement.style;
            if (typeof theme.foreground === "string") {
                rootStyle.setProperty("--terminal-foreground", theme.foreground);
            }
            rootStyle.setProperty("--syntax-command", theme.brightBlue || theme.blue || theme.foreground);
            rootStyle.setProperty("--syntax-option", theme.cyan || theme.foreground);
            rootStyle.setProperty("--syntax-string", theme.green || theme.foreground);
            rootStyle.setProperty("--syntax-path", theme.blue || theme.foreground);
            rootStyle.setProperty("--syntax-variable", theme.magenta || theme.foreground);
            rootStyle.setProperty("--syntax-number", theme.yellow || theme.foreground);
            rootStyle.setProperty("--syntax-operator", theme.brightMagenta || theme.magenta || theme.foreground);
            rootStyle.setProperty("--syntax-comment", theme.brightBlack || theme.foreground);
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
        if (settings.syntaxPalette && typeof settings.syntaxPalette === "object") {
            const syntax = settings.syntaxPalette;
            const rootStyle = document.documentElement.style;
            const syntaxVariables = {
                command: "--syntax-command",
                option: "--syntax-option",
                string: "--syntax-string",
                path: "--syntax-path",
                variable: "--syntax-variable",
                number: "--syntax-number",
                operation: "--syntax-operator",
                comment: "--syntax-comment"
            };
            Object.entries(syntaxVariables).forEach(([key, variable]) => {
                if (typeof syntax[key] === "string" && syntax[key].length > 0) {
                    rootStyle.setProperty(variable, syntax[key]);
                }
            });
        }
        if (Number.isFinite(settings.padding)) {
            const padding = Math.min(28, Math.max(0, settings.padding));
            document.documentElement.style.setProperty(
                "--terminal-padding",
                `${padding}px`
            );
        }
        renderInputHighlight();
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
        favoriteCommands = new Set(
            Array.isArray(payload.favorites)
                ? payload.favorites.filter((command) => typeof command === "string")
                : []
        );
        commandTemplates = Array.isArray(payload.templates)
            ? payload.templates
                .filter((entry) => entry && typeof entry.command === "string")
                .map((entry) => ({
                    ...entry,
                    source: "template",
                    description: entry.title || "Пользовательский шаблон",
                    keywords: `${entry.title || ""} ${entry.category || ""}`
                }))
            : [];
        const remote = payload.remote && typeof payload.remote === "object"
            ? payload.remote
            : {};
        remoteCommandEntries = Array.isArray(remote.suggestions)
            ? remote.suggestions
                .filter((entry) => entry && typeof entry.command === "string")
                .map((entry) => ({ ...entry, source: "remote" }))
            : [];
        remoteContextMessage = typeof remote.message === "string"
            ? remote.message
            : "Подключите SSH и обновите сведения о сервере";
        remoteSystemLabel = typeof remote.systemLabel === "string"
            ? remote.systemLabel
            : "";
        remoteContextCanRetry = remote.canRetry === true;
        renderHistoryPanel();
        renderSuggestions();
    };

    window.selectiveTerminalSetHistoryVisible = (
        visible,
        notifySwift = false,
        restoreTerminalFocus = true
    ) => {
        const nextVisible = Boolean(visible);
        historyPanel.hidden = !nextVisible;
        hideSuggestions();
        if (nextVisible) {
            renderHistoryPanel();
            window.setTimeout(() => historyQuery.focus(), 0);
        } else if (restoreTerminalFocus) {
            terminal.focus();
        }
        if (notifySwift) {
            postHistory({ action: "visibility", visible: nextVisible });
        }
    };

    terminalSearchQuery.addEventListener("input", () => refreshTerminalSearch(false));
    terminalSearchQuery.addEventListener("keydown", (event) => {
        if (event.key === "Escape") {
            event.preventDefault();
            closeTerminalSearch();
        } else if (event.key === "Enter") {
            event.preventDefault();
            moveTerminalSearch(event.shiftKey ? -1 : 1);
        }
    });
    terminalSearchPrevious.addEventListener("click", () => moveTerminalSearch(-1));
    terminalSearchNext.addEventListener("click", () => moveTerminalSearch(1));
    terminalSearchClose.addEventListener("click", closeTerminalSearch);

    historyQuery.addEventListener("input", renderHistoryPanel);
    remoteContextRetryButton.addEventListener("click", () => {
        postHistory({ action: "retryRemoteContext" });
    });
    commandTabs.forEach((button) => {
        button.addEventListener("click", () => {
            activePanelSection = button.dataset.section || "history";
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
    templateAddButton.addEventListener("click", () => openTemplateEditor());
    templateCancel.addEventListener("click", () => templateDialog.close());
    templateForm.addEventListener("submit", (event) => {
        event.preventDefault();
        postHistory({
            action: "saveTemplate",
            id: templateID.value || null,
            title: templateTitle.value,
            category: templateCategory.value,
            command: templateCommand.value
        });
        templateDialog.close();
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
    window.selectiveTerminalFit = () => {
        fitAndReport();
        window.setTimeout(fitAndReport, 120);
        window.setTimeout(fitAndReport, 320);
    };

    const resizeObserver = new ResizeObserver(fitAndReport);
    resizeObserver.observe(terminalHost);
    window.addEventListener("resize", fitAndReport);
    window.visualViewport?.addEventListener("resize", fitAndReport);
    document.fonts?.ready.then(fitAndReport);
    fitAndReport();
    terminal.focus();
})();
