import assert from "node:assert/strict";
import test from "node:test";

import {
  modernSelectNextIndex,
  modernSelectOptionSnapshot,
} from "../public/modern-select.js";

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
