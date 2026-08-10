(() => {
    "use strict";

    const terminalHost = document.getElementById("terminal");
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
            // Waiting for two animation frames makes the measurement happen
            // after SwiftUI, WKWebView and the selected terminal font have all
            // settled on their final geometry.
            window.requestAnimationFrame(() => {
                fitAddon.fit();
                window.requestAnimationFrame(reportSize);
            });
        }, 60);
    };

    terminal.onData((data) => {
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
        terminal.write(bytes, () => {
            outputWriteActive = false;
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
