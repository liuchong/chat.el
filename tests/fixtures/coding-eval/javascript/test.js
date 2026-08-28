const assert = require("node:assert");
const sample = require("./sample");

const test = process.argv[2];

if (test === "divide") {
  assert.equal(sample.divide(5, 2), 2.5);
  assert.throws(() => sample.divide(1, 0), /zero/i);
} else if (test === "label") {
  assert.equal(sample.label("alpha"), "entry:alpha");
} else if (test === "normalize") {
  assert.equal(sample.normalizeName("  Alpha   BETA "), "alpha beta");
} else if (test === "active") {
  assert.equal(sample.active({ state: "active" }), true);
  assert.equal(sample.active({ state: "paused" }), false);
} else {
  throw new Error(`unknown test: ${test}`);
}
