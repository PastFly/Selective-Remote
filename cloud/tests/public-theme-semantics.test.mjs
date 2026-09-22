import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const css = await readFile(new URL("../public/styles.css", import.meta.url), "utf8");

function lightThemeBlock() {
  const blocks = [...css.matchAll(/:root\[data-theme="light"\]\s*\{([^}]*)\}/gu)];
  assert.equal(blocks.length, 1, "Light theme must have one semantic token source of truth");
  return blocks[0][1];
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
    "text-primary", "text-secondary", "text-muted", "text-disabled", "placeholder",
    "control-surface", "control-surface-disabled", "border", "border-disabled",
    "selected", "hover", "focus-ring",
  ]) token(block, name);

  const surface = token(block, "control-surface");
  assert.ok(contrast(token(block, "text-primary"), surface) >= 7, "primary text must be high contrast");
  assert.ok(contrast(token(block, "text-secondary"), surface) >= 4.5, "secondary text must stay readable");
  assert.ok(contrast(token(block, "text-muted"), surface) >= 4.5, "muted/help text must stay readable");
  assert.ok(contrast(token(block, "text-disabled"), token(block, "control-surface-disabled")) >= 3,
    "disabled text must remain legible");
  assert.ok(contrast(token(block, "placeholder"), surface) >= 4.5, "placeholders must stay readable");
});

test("Light controls consume semantic disabled, placeholder, selection, hover, and focus tokens", () => {
  assert.match(css, /body\s*\{[^}]*color:var\(--text-primary\)/u);
  assert.match(css, /\.auth-form label\s*\{[^}]*color:var\(--text-secondary\)/u);
  assert.match(css, /:root\[data-theme="light"\][^{]*:is\(input,textarea\)::placeholder\s*\{[^}]*color:var\(--placeholder\)/u);
  assert.match(css, /:root\[data-theme="light"\][^{]*(?::disabled|\[aria-disabled="true"\])[^}]*color:var\(--text-disabled\)/u);
  assert.match(css, /:root\[data-theme="light"\] \.modern-select-menu>\.modern-select-option\[aria-selected="true"\]\s*\{[^}]*background:var\(--selected\)/u);
  assert.match(css, /:root\[data-theme="light"\][^{]*:focus-visible[^}]*var\(--focus-ring\)/u);
});
