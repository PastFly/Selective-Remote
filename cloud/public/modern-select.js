let modernSelectSequence = 0;
const modernSelectControllers = new WeakMap();
const modernSelectDocumentObservers = new WeakMap();

export function modernSelectOptionSnapshot(select) {
  return Array.from(select?.options ?? []).map((option, index) => ({
    index,
    value: String(option.value ?? ""),
    label: String(option.label || option.textContent || "").trim(),
    disabled: Boolean(option.disabled),
    selected: index === select.selectedIndex,
  }));
}

export function modernSelectNextIndex(options, currentIndex, direction) {
  if (!Array.isArray(options) || options.length === 0) return -1;
  const step = direction < 0 ? -1 : 1;
  let index = Number.isInteger(currentIndex) ? currentIndex : step > 0 ? -1 : 0;
  for (let attempt = 0; attempt < options.length; attempt += 1) {
    index = (index + step + options.length) % options.length;
    if (!options[index]?.disabled) return index;
  }
  return -1;
}

export function modernSelectMenuPlacement({
  triggerRect,
  viewportWidth,
  viewportHeight,
  menuHeight,
  contentWidth = 0,
  gap = 8,
  edge = 16,
}) {
  const availableWidth = Math.max(0, viewportWidth - edge * 2);
  const width = Math.min(
    Math.max(triggerRect.width, Math.min(contentWidth, 420), 170),
    availableWidth,
  );
  const below = Math.max(0, viewportHeight - triggerRect.bottom - gap - edge);
  const above = Math.max(0, triggerRect.top - gap - edge);
  const preferredHeight = Math.min(menuHeight, 300);
  const openUp = below < preferredHeight && above > below;
  const maxHeight = Math.max(48, Math.min(300, openUp ? above : below));
  const renderedHeight = Math.min(menuHeight, maxHeight);
  const left = Math.min(
    Math.max(edge, triggerRect.left),
    Math.max(edge, viewportWidth - edge - width),
  );
  const top = openUp
    ? Math.max(edge, triggerRect.top - gap - renderedHeight)
    : Math.min(viewportHeight - edge, triggerRect.bottom + gap);

  return { left, top, width, maxHeight, openUp };
}

function selectAccessibleName(select) {
  const explicit = select.getAttribute("aria-label");
  if (explicit) return explicit.trim();
  const label = select.labels?.[0];
  if (!label) return "Выбор";
  const clone = label.cloneNode(true);
  clone.querySelectorAll("select").forEach((control) => control.remove());
  return clone.textContent.trim() || "Выбор";
}

function schedule(documentValue, callback) {
  const requestFrame = documentValue.defaultView?.requestAnimationFrame;
  if (requestFrame) requestFrame(callback);
  else queueMicrotask(callback);
}

export function enhanceModernSelect(select, {
  documentValue = select?.ownerDocument,
  MutationObserverValue = globalThis.MutationObserver,
} = {}) {
  if (!select || !documentValue || modernSelectControllers.has(select)) {
    return modernSelectControllers.get(select) ?? null;
  }

  const wrapper = documentValue.createElement("div");
  const trigger = documentValue.createElement("button");
  const value = documentValue.createElement("span");
  const chevron = documentValue.createElement("span");
  const menu = documentValue.createElement("div");
  const listboxID = `modern-select-${++modernSelectSequence}`;
  let open = false;
  let activeIndex = -1;
  let typeahead = "";
  let typeaheadTimer = null;

  wrapper.className = "modern-select";
  trigger.type = "button";
  trigger.className = "modern-select-trigger";
  trigger.setAttribute("role", "combobox");
  trigger.setAttribute("aria-haspopup", "listbox");
  trigger.setAttribute("aria-expanded", "false");
  trigger.setAttribute("aria-controls", listboxID);
  value.className = "modern-select-value";
  chevron.className = "modern-select-chevron";
  chevron.setAttribute("aria-hidden", "true");
  menu.id = listboxID;
  menu.className = "modern-select-menu";
  menu.setAttribute("role", "listbox");
  menu.hidden = true;
  trigger.append(value, chevron);

  select.parentNode.insertBefore(wrapper, select);
  wrapper.append(trigger, select, menu);
  select.classList.add("modern-select-native");
  select.tabIndex = -1;
  select.setAttribute("aria-hidden", "true");
  select.dataset.modernSelectEnhanced = "true";

  function options() {
    return modernSelectOptionSnapshot(select);
  }

  function positionMenu() {
    if (!open) return;
    const windowValue = documentValue.defaultView;
    const placement = modernSelectMenuPlacement({
      triggerRect: trigger.getBoundingClientRect(),
      viewportWidth: windowValue?.innerWidth ?? documentValue.documentElement?.clientWidth ?? 0,
      viewportHeight: windowValue?.innerHeight ?? documentValue.documentElement?.clientHeight ?? 0,
      menuHeight: menu.scrollHeight,
      contentWidth: menu.scrollWidth,
    });
    menu.classList.toggle("open-up", placement.openUp);
    menu.style.left = `${placement.left}px`;
    menu.style.top = `${placement.top}px`;
    menu.style.width = `${placement.width}px`;
    menu.style.maxHeight = `${placement.maxHeight}px`;
  }

  function focusOption(index) {
    const items = [...menu.querySelectorAll(".modern-select-option")];
    const item = items.find((candidate) => Number(candidate.dataset.index) === index && !candidate.disabled);
    if (!item) return;
    activeIndex = index;
    item.focus({ preventScroll: true });
    item.scrollIntoView({ block: "nearest" });
  }

  function closeMenu({ restoreFocus = false } = {}) {
    if (!open) return;
    open = false;
    wrapper.classList.remove("open");
    trigger.setAttribute("aria-expanded", "false");
    menu.hidden = true;
    menu.classList.remove("open-up");
    menu.removeAttribute("style");
    if (menu.parentNode !== wrapper) wrapper.append(menu);
    if (restoreFocus) trigger.focus({ preventScroll: true });
  }

  function choose(index) {
    const entry = options().find((option) => option.index === index && !option.disabled);
    if (!entry) return;
    select.selectedIndex = entry.index;
    const EventValue = documentValue.defaultView?.Event ?? globalThis.Event;
    select.dispatchEvent(new EventValue("change", { bubbles: true }));
    sync();
    closeMenu({ restoreFocus: true });
  }

  function optionKeydown(event) {
    const entries = options();
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      focusOption(modernSelectNextIndex(entries, activeIndex, event.key === "ArrowDown" ? 1 : -1));
      return;
    }
    if (event.key === "Home" || event.key === "End") {
      event.preventDefault();
      focusOption(modernSelectNextIndex(entries, event.key === "Home" ? -1 : 0, event.key === "Home" ? 1 : -1));
      return;
    }
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      choose(activeIndex);
      return;
    }
    if (event.key === "Escape") {
      event.preventDefault();
      closeMenu({ restoreFocus: true });
      return;
    }
    if (event.key === "Tab") closeMenu();
  }

  function typeaheadSearch(character) {
    if (!character || character.length !== 1 || /\s/u.test(character)) return false;
    typeahead += character.toLocaleLowerCase();
    clearTimeout(typeaheadTimer);
    typeaheadTimer = setTimeout(() => { typeahead = ""; }, 650);
    const entries = options();
    const match = entries.find((entry) => !entry.disabled && entry.label.toLocaleLowerCase().startsWith(typeahead));
    if (!match) return false;
    if (!open) choose(match.index);
    else focusOption(match.index);
    return true;
  }

  function renderOptions(entries) {
    const fragment = documentValue.createDocumentFragment();
    for (const entry of entries) {
      const option = documentValue.createElement("button");
      const check = documentValue.createElement("span");
      const label = documentValue.createElement("span");
      option.type = "button";
      option.className = "modern-select-option";
      option.dataset.index = String(entry.index);
      option.setAttribute("role", "option");
      option.setAttribute("aria-selected", String(entry.selected));
      option.disabled = entry.disabled;
      option.tabIndex = -1;
      check.className = "modern-select-check";
      check.textContent = entry.selected ? "✓" : "";
      check.setAttribute("aria-hidden", "true");
      label.textContent = entry.label || "—";
      option.append(check, label);
      option.addEventListener("click", () => choose(entry.index));
      option.addEventListener("keydown", optionKeydown);
      option.addEventListener("keydown", (event) => {
        if (typeaheadSearch(event.key)) event.preventDefault();
      });
      fragment.append(option);
    }
    menu.replaceChildren(fragment);
  }

  function sync() {
    const entries = options();
    const selected = entries.find((entry) => entry.selected) ?? entries.find((entry) => !entry.disabled);
    value.textContent = selected?.label || (documentValue.documentElement?.lang === "en" ? "Select…" : "Выберите…");
    trigger.disabled = Boolean(select.disabled) || !selected;
    trigger.setAttribute("aria-label", `${selectAccessibleName(select)}: ${value.textContent}`);
    activeIndex = selected?.index ?? -1;
    renderOptions(entries);
    if (open) schedule(documentValue, positionMenu);
  }

  function openMenu(preferredDirection = 1) {
    if (trigger.disabled) return;
    sync();
    open = true;
    wrapper.classList.add("open");
    trigger.setAttribute("aria-expanded", "true");
    documentValue.body.append(menu);
    menu.hidden = false;
    schedule(documentValue, () => {
      positionMenu();
      const entries = options();
      const selected = entries.find((entry) => entry.selected && !entry.disabled);
      const index = selected?.index ?? modernSelectNextIndex(entries, preferredDirection > 0 ? -1 : 0, preferredDirection);
      focusOption(index);
    });
  }

  trigger.addEventListener("click", () => open ? closeMenu() : openMenu());
  trigger.addEventListener("pointerenter", sync);
  trigger.addEventListener("focus", sync);
  trigger.addEventListener("keydown", (event) => {
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      if (!open) openMenu(event.key === "ArrowDown" ? 1 : -1);
      return;
    }
    if (event.key === "Escape" && open) {
      event.preventDefault();
      closeMenu();
      return;
    }
    if (typeaheadSearch(event.key)) event.preventDefault();
  });
  select.addEventListener("change", () => {
    trigger.removeAttribute("aria-invalid");
    sync();
  });
  select.addEventListener("invalid", (event) => {
    event.preventDefault();
    trigger.setAttribute("aria-invalid", "true");
    trigger.focus({ preventScroll: true });
  });
  select.form?.addEventListener("reset", () => schedule(documentValue, sync));
  const closeFromOutsidePointer = (event) => {
    if (open && !wrapper.contains(event.target) && !menu.contains(event.target)) closeMenu();
  };
  documentValue.addEventListener("pointerdown", closeFromOutsidePointer);
  documentValue.defaultView?.addEventListener("resize", positionMenu);
  documentValue.defaultView?.addEventListener("scroll", positionMenu, true);

  const observedProperties = ["value", "selectedIndex"].flatMap((property) => {
    let prototype = Object.getPrototypeOf(select);
    let descriptor = null;
    while (prototype && !descriptor) {
      descriptor = Object.getOwnPropertyDescriptor(prototype, property);
      prototype = Object.getPrototypeOf(prototype);
    }
    if (!descriptor?.get || !descriptor?.set) return [];
    Object.defineProperty(select, property, {
      configurable: true,
      enumerable: descriptor.enumerable,
      get() { return descriptor.get.call(this); },
      set(nextValue) {
        descriptor.set.call(this, nextValue);
        schedule(documentValue, sync);
      },
    });
    return [property];
  });

  const observer = MutationObserverValue ? new MutationObserverValue(sync) : null;
  observer?.observe(select, {
    childList: true,
    subtree: true,
    characterData: true,
    attributes: true,
    attributeFilter: ["disabled", "selected", "label"],
  });

  const controller = {
    sync,
    close: closeMenu,
    destroy: () => {
      closeMenu();
      observer?.disconnect();
      documentValue.removeEventListener("pointerdown", closeFromOutsidePointer);
      documentValue.defaultView?.removeEventListener("resize", positionMenu);
      documentValue.defaultView?.removeEventListener("scroll", positionMenu, true);
      for (const property of observedProperties) delete select[property];
    },
  };
  modernSelectControllers.set(select, controller);
  sync();
  return controller;
}

function modernSelectCandidates(node) {
  if (!node || node.nodeType !== 1) return [];
  const candidates = node.matches?.("select") ? [node] : [];
  candidates.push(...(node.querySelectorAll?.("select") ?? []));
  return candidates;
}

export function initializeModernSelects({
  documentValue = document,
  MutationObserverValue = documentValue.defaultView?.MutationObserver ?? globalThis.MutationObserver,
  enhance = enhanceModernSelect,
} = {}) {
  const enhanceSelect = (select) => enhance(select, { documentValue, MutationObserverValue });
  const controllers = [...documentValue.querySelectorAll("select")]
    .map(enhanceSelect)
    .filter(Boolean);

  if (MutationObserverValue && !modernSelectDocumentObservers.has(documentValue)) {
    const observer = new MutationObserverValue((records) => {
      for (const record of records) {
        for (const node of record.addedNodes ?? []) {
          modernSelectCandidates(node).forEach(enhanceSelect);
        }
      }
    });
    observer.observe(documentValue.documentElement, { childList: true, subtree: true });
    modernSelectDocumentObservers.set(documentValue, observer);
    documentValue.addEventListener?.("selective-remote:locale-changed", () => {
      for (const select of documentValue.querySelectorAll("select[data-modern-select-enhanced='true']")) {
        modernSelectControllers.get(select)?.sync();
      }
    });
  }

  return controllers;
}
