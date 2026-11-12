const assert = require("node:assert/strict");
const test = require("node:test");

const { add } = require("../index.js");

test("adds numbers", () => {
  assert.equal(add(2, 3), 5);
});

test("rejects non-numbers", () => {
  assert.throws(() => add("two", 3), TypeError);
});
