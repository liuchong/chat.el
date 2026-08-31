import assert from "node:assert/strict";
import test from "node:test";

import { active, divide, label, normalizeName } from "../sample.ts";

test("divide", () => {
  assert.equal(divide(5, 2), 2.5);
  assert.throws(() => divide(1, 0), RangeError);
});

test("label", () => {
  assert.equal(label("alpha"), "entry:alpha");
});

test("normalize", () => {
  assert.equal(normalizeName("  Alpha   BETA "), "alpha beta");
});

test("active", () => {
  assert.equal(active({ state: "active" }), true);
  assert.equal(active({ state: "paused" }), false);
});
