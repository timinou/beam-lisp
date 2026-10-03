// test/js/diff/canon.mjs — normalize a printed BL value for comparison.
//
// BEAM prints a small map's entries in its flatmap key order, which depends on
// the ATOM TABLE (keywords sort by creation index; FUP-141). No other host can
// reproduce it, and it is not a semantic property of the value. So both sides'
// printed output is re-read here and every map and set is printed with its
// entries SORTED by their own printed text. Everything else — vector/list
// order, numbers, strings, nesting — is compared exactly.

export function canon(text) {
  let i = 0;
  const peek = () => text[i];
  const ws = () => { while (i < text.length && /[\s,]/.test(text[i])) i++; };
  function atom() {
    let j = i;
    if (text[i] === '"') {
      i++;
      while (i < text.length && text[i] !== '"') { if (text[i] === "\\") i++; i++; }
      i++;
      return text.slice(j, i);
    }
    while (i < text.length && !/[\s,()\[\]{}]/.test(text[i])) i++;
    return text.slice(j, i);
  }
  function seqOf(close) {
    const items = [];
    for (;;) { ws(); if (peek() === close) { i++; return items; } if (i >= text.length) return items; items.push(form()); }
  }
  function form() {
    ws();
    const c = peek();
    if (c === "(") { i++; return "(" + seqOf(")").join(" ") + ")"; }
    if (c === "[") { i++; return "[" + seqOf("]").join(" ") + "]"; }
    if (c === "{") {
      i++;
      const xs = seqOf("}"); const pairs = [];
      for (let k = 0; k < xs.length; k += 2) pairs.push(xs[k] + " " + xs[k + 1]);
      return "{" + pairs.sort().join(", ") + "}";
    }
    if (c === "#" && text[i + 1] === "{") { i += 2; return "#{" + seqOf("}").sort().join(" ") + "}"; }
    if (c === "#" && text.startsWith("#error", i)) { const rest = text.slice(i); i = text.length; return "#error"; }
    return atom();
  }
  const outs = [];
  while (i < text.length) { ws(); if (i >= text.length) break; outs.push(form()); }
  return outs.join(" ");
}
