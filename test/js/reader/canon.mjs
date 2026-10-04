// test/js/reader/canon.mjs — one canonical printing of reader output.
// BEAM's pr-str prints an Erlang list of 2-tuples as a keyword list
// (`[symbol: "ns"]`) and a tuple as `{:symbol, "ns"}`; the JS runtime prints
// `({:symbol "ns"})`. Both sides print through `canon` instead, so the
// differential compares STRUCTURE.
export function canon(R, x) {
  if (x === null || x === undefined) return "nil";
  if (x instanceof R.Tup) return "{" + x.items.map((e) => canon(R, e)).join(" ") + "}";
  if (x === R.EMPTY || x instanceof R.Cons) {
    const a = []; for (let p = x; p instanceof R.Cons; p = p.t) a.push(canon(R, p.h));
    return "(" + a.join(" ") + ")";
  }
  if (x instanceof R.Vec) return "[" + x.toArray().map((e) => canon(R, e)).join(" ") + "]";
  // strings by their codepoints: escaping is a printer choice, not reader output
  if (typeof x === "string") return '"' + [...x].map((c) => c.codePointAt(0)).join(",") + '"';
  if (x instanceof R.HMap) return "{" + x.entries().map(([k, v]) => canon(R, k) + " " + canon(R, v)).sort().join(", ") + "}";
  return R.printStr(x);
}
