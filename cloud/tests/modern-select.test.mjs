import assert from "node:assert/strict";
import test from "node:test";

import {
  initializeModernSelects,
  modernSelectMenuPlacement,
  modernSelectNextIndex,
  modernSelectOptionSnapshot,
} from "../public/modern-select.js";

test("modern selects enhance controls added after initial render", () => {
  const initial = { nodeType: 1 };
  const addedSelect = {
    nodeType: 1,
    matches: (selector) => selector === "select",
    querySelectorAll: () => [],
  };
  const nestedSelect = { nodeType: 1 };
  const addedPanel = {
    nodeType: 1,
    matches: () => false,
    querySelectorAll: (selector) => selector === "select" ? [nestedSelect] : [],
  };
  let additions;
  let observation;
  class Observer {
    constructor(callback) { additions = callback; }
    observe(target, options) { observation = { target, options }; }
  }
  const root = {};
  const documentValue = {
    documentElement: root,
    querySelectorAll: (selector) => selector === "select" ? [initial] : [],
  };
  const enhanced = [];

  const controllers = initializeModernSelects({
    documentValue,
    MutationObserverValue: Observer,
    enhance: (select) => {
      enhanced.push(select);
      return { select };
    },
  });
  additions([{ addedNodes: [addedSelect, addedPanel, { nodeType: 3 }] }]);

  assert.equal(controllers.length, 1);
  assert.deepEqual(enhanced, [initial, addedSelect, nestedSelect]);
  assert.deepEqual(observation, {
    target: root,
    options: { childList: true, subtree: true },
  });
});

test("modern select menu stays inside the viewport and opens upward near the bottom", () => {
  assert.deepEqual(modernSelectMenuPlacement({
    triggerRect: { left: 900, top: 700, right: 1100, bottom: 744, width: 200 },
    viewportWidth: 1024,
    viewportHeight: 768,
    menuHeight: 220,
    contentWidth: 260,
  }), {
    left: 748,
    top: 472,
    width: 260,
    maxHeight: 300,
    openUp: true,
  });
});

test("modern select menu opens downward with a bounded height when space is available", () => {
  assert.deepEqual(modernSelectMenuPlacement({
    triggerRect: { left: 24, top: 100, right: 224, bottom: 144, width: 200 },
    viewportWidth: 800,
    viewportHeight: 600,
    menuHeight: 520,
    contentWidth: 180,
  }), {
    left: 24,
    top: 152,
    width: 200,
    maxHeight: 300,
    openUp: false,
  });
});

test("modern select snapshots labels and selected state from a native select", () => {
  const select = {
    selectedIndex: 1,
    options: [
      { value: "owner", label: "Владелец", disabled: false },
      { value: "editor", textContent: " Редактор ", disabled: false },
    ],
  };

  assert.deepEqual(modernSelectOptionSnapshot(select), [
    { index: 0, value: "owner", label: "Владелец", disabled: false, selected: false },
    { index: 1, value: "editor", label: "Редактор", disabled: false, selected: true },
  ]);
});

test("modern select keyboard navigation wraps and skips disabled options", () => {
  const options = [
    { disabled: false },
    { disabled: true },
    { disabled: false },
  ];

  assert.equal(modernSelectNextIndex(options, 0, 1), 2);
  assert.equal(modernSelectNextIndex(options, 2, 1), 0);
  assert.equal(modernSelectNextIndex(options, 0, -1), 2);
  assert.equal(modernSelectNextIndex([{ disabled: true }], 0, 1), -1);
});
