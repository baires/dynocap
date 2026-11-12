const isNumber = require("is-number");

/** Adds two numeric values, rejecting anything that is not a number. */
function add(a, b) {
  if (!isNumber(a) || !isNumber(b)) throw new TypeError("add expects numbers");
  return Number(a) + Number(b);
}

module.exports = { add };
