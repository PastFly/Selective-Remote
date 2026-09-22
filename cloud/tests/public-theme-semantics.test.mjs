import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const css = await readFile(new URL("../public/styles.css", import.meta.url), "utf8");

function lightThemeBlock() {
  const blocks = [...css.matchAll(/:root\[data-theme="light"\]\s*\{([^}]*)\}/gu)];
  assert.equal(blocks.length, 1, "Light theme must have one semantic token source of truth");
  return blocks[0][1];
}

function graphiteThemeBlock() {
  const block = css.match(/^:root\s*\{([^}]*)\}/u)?.[1];
  assert.ok(block, "Graphite theme tokens must be present");
  return block;
}

function token(block, name) {
  const value = block.match(new RegExp(`--${name}:(#[0-9a-f]{6})`, "iu"))?.[1];
  assert.ok(value, `missing --${name}`);
  return value;
}

function luminance(hex) {
  const channel = (offset) => {
    const value = Number.parseInt(hex.slice(offset, offset + 2), 16) / 255;
    return value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
  };
  return (0.2126 * channel(1)) + (0.7152 * channel(3)) + (0.0722 * channel(5));
}

function contrast(left, right) {
  const values = [luminance(left), luminance(right)].sort((a, b) => b - a);
  return (values[0] + 0.05) / (values[1] + 0.05);
}

test("Light theme exposes one coherent semantic color hierarchy", () => {
  const block = lightThemeBlock();
  for (const name of [
    "text-primary", "text-secondary", "text-muted", "text-interactive-inactive",
    "text-disabled", "text-danger", "text-danger-disabled", "placeholder",
    "control-surface", "control-surface-disabled", "selector-surface",
    "border", "border-disabled", "selector-border",
    "selected", "hover", "focus-ring",
  ]) token(block, name);

  const surface = token(block, "control-surface");
  assert.ok(contrast(token(block, "text-primary"), surface) >= 7, "primary text must be high contrast");
  assert.ok(contrast(token(block, "text-secondary"), surface) >= 4.5, "secondary text must stay readable");
  assert.ok(contrast(token(block, "text-muted"), surface) >= 4.5, "muted/help text must stay readable");
  assert.ok(contrast(token(block, "text-interactive-inactive"), surface) >= 4.5,
    "inactive interactive text must meet WCAG AA");
  assert.ok(contrast(token(block, "text-disabled"), token(block, "control-surface-disabled")) >= 3,
    "disabled text must remain legible");
  assert.ok(contrast(token(block, "text-danger"), surface) >= 4.5,
    "enabled destructive actions must meet WCAG AA");
  assert.ok(contrast(token(block, "text-danger-disabled"), token(block, "control-surface-disabled")) >= 3,
    "disabled destructive text must remain legible");
  assert.ok(contrast(token(block, "selector-border"), token(block, "selector-surface")) >= 3,
    "selector boundaries must remain distinguishable");
  assert.ok(contrast(token(block, "placeholder"), surface) >= 4.5, "placeholders must stay readable");
  assert.notEqual(token(block, "text-interactive-inactive"), token(block, "text-disabled"),
    "inactive interactive and disabled text must be separate semantic roles");
});

test("Light controls consume semantic disabled, placeholder, selection, hover, and focus tokens", () => {
  assert.match(css, /body\s*\{[^}]*color:var\(--text-primary\)/u);
  assert.match(css, /\.auth-form label\s*\{[^}]*color:var\(--text-secondary\)/u);
  assert.match(css, /:root\[data-theme="light"\][^{]*:is\(input,textarea\)::placeholder\s*\{[^}]*color:var\(--placeholder\)/u);
  assert.match(css, /:root\[data-theme="light"\][^{]*(?::disabled|\[aria-disabled="true"\])[^}]*color:var\(--text-disabled\)/u);
  assert.match(css, /:root\[data-theme="light"\] \.modern-select-menu>\.modern-select-option\[aria-selected="true"\]\s*\{[^}]*background:var\(--selected\)/u);
  assert.match(css, /:root\[data-theme="light"\][^{]*:focus-visible[^}]*var\(--focus-ring\)/u);
});

test("Graphite selector boundary does not regress below non-text contrast", () => {
  const block = graphiteThemeBlock();
  assert.ok(contrast(token(block, "selector-border"), token(block, "selector-surface")) >= 3,
    "Graphite selector boundary must remain distinguishable");
});

test("Navigation, selectors, and destructive actions consume semantic contrast roles", () => {
  assert.match(css, /\.site-nav a\s*\{[^}]*color:var\(--text-interactive-inactive\)/u);
  assert.match(css, /:root\[data-theme="light"\] \.site-nav a\s*\{[^}]*color:var\(--text-interactive-inactive\)/u);
  assert.match(css, /#cloud-workspace \.workspace-sidebar nav button\s*\{[^}]*color:var\(--text-interactive-inactive\)/u);
  assert.match(css, /\.locale-switch\s*\{[^}]*border:\s*1px solid var\(--selector-border\)[^}]*background:\s*var\(--selector-surface\)/u);
  assert.match(css, /\.locale-switch button\s*\{[^}]*color:\s*var\(--text-interactive-inactive\)/u);
  assert.match(css, /:root\[data-theme="light"\] \.locale-switch button\[aria-pressed="false"\]\s*\{[^}]*color:var\(--text-interactive-inactive\)/u);
  assert.match(css, /\.brand-actions button:not\(\[data-locale\]\):not\(\.secondary\)/u,
    "primary action styling must not capture locale options");
  assert.match(css, /\.workspace-devices button\.danger\s*\{[^}]*color:var\(--text-danger\)/u);
  assert.match(css, /:root\[data-theme="light"\][^{]*\.danger:disabled[^}]*color:var\(--text-danger-disabled\)/u);
});
