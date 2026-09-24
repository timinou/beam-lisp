// Research-only differential corpus. Run from the repository root with
// `node research/js-actors-future/numeric-spike.mjs`. No runtime API is exported.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../', import.meta.url));
const native = `
  Code.require_file("lib/beam_lisp/ex_info.ex")
  Code.require_file("lib/beam_lisp/decimal.ex")
  alias BeamLisp.Decimal, as: D
  a = D.new("1.50")
  b = D.new("1.5")
  IO.puts("big-add=i:" <> Integer.to_string(9007199254740993 + 1))
  IO.puts("decimal-a=d:" <> Integer.to_string(a.unscaled) <> ":" <> Integer.to_string(a.scale))
  IO.puts("decimal-b=d:" <> Integer.to_string(b.unscaled) <> ":" <> Integer.to_string(b.scale))
  IO.puts("scale-equality=" <> to_string(a == b))
  IO.puts("numeric-equality=" <> to_string(D.eq?(a, b)))
  IO.puts("decimal-add=" <> D.to_literal(D.add(a, D.new("2.2"))))
  IO.puts("decimal-mul=" <> D.to_literal(D.mul(a, D.new("2.0"))))
  IO.puts("decimal-map-keys=" <> Integer.to_string(map_size(%{a => :a, b => :b})))
  IO.puts("int-float-map-keys=" <> Integer.to_string(map_size(%{1 => :int, 1.0 => :float})))
  IO.puts("negative-zero=f:" <> Base.encode16(<<(-0.0)::float-big>>))
  IO.puts("negative-int-div=i:" <> Integer.to_string(Kernel.div(-7, 3)))
  IO.puts("negative-int-rem=i:" <> Integer.to_string(Kernel.rem(-7, 3)))
  IO.puts("decimal-half-even=" <> D.to_literal(D.div(D.new("1"), D.new("8"), 2, :"half-even")))
  IO.puts("decimal-half-up=" <> D.to_literal(D.div(D.new("1"), D.new("8"), 2, :"half-up")))
  try do
    D.new(0.1)
    IO.puts("float-to-decimal=missing-error")
  rescue
    e in BeamLisp.ExInfo -> IO.puts("float-to-decimal=" <> Atom.to_string(e.data.type))
  end
  IO.puts("decimal-div=" <> D.to_literal(D.div(D.new("1"), D.new("4"))))
  try do
    D.div(D.new("1"), D.new("3"))
    IO.puts("decimal-nonterminating=missing-error")
  rescue
    e in BeamLisp.ExInfo -> IO.puts("decimal-nonterminating=" <> Atom.to_string(e.data.type))
  end
`;
const result = spawnSync('elixir', ['-pa', 'build', '-e', native], {
  cwd: root, encoding: 'utf8', timeout: 30000,
  env: { ...process.env, ELIXIR_ERL_OPTIONS: '+S 4:4 +SDcpu 2:2 +SDio 8' },
});
assert.ifError(result.error);
assert.equal(result.status, 0, result.stderr);
const observed = new Map(result.stdout.trim().split('\n').map(line => {
  const i = line.indexOf('=');
  return [line.slice(0, i), line.slice(i + 1)];
}));

// Candidate only: a tagged BigInt integer and unscaled/scale decimal. These
// are NOT a second public BL arithmetic implementation. The target currently
// lacks a BigInt host leaf, so BL source cannot construct this representation.
const decimal = (digits, scale) => ({ tag: 'decimal', digits: BigInt(digits), scale });
const align = (a, b) => {
  const scale = Math.max(a.scale, b.scale);
  return [a.digits * 10n ** BigInt(scale - a.scale), b.digits * 10n ** BigInt(scale - b.scale), scale];
};
const add = (a, b) => {
  const [x, y, scale] = align(a, b);
  return decimal(x + y, scale);
};
const mul = (a, b) => decimal(a.digits * b.digits, a.scale + b.scale);
const literal = d => {
  const sign = d.digits < 0n ? '-' : '';
  const digits = (d.digits < 0n ? -d.digits : d.digits).toString().padStart(d.scale + 1, '0');
  const cut = digits.length - d.scale;
  return sign + (d.scale ? digits.slice(0, cut) + '.' + digits.slice(cut) : digits) + 'M';
};
const a = decimal(150, 2), b = decimal(15, 1);
const floatBits = x => {
  const bits = new DataView(new ArrayBuffer(8));
  bits.setFloat64(0, x, false);
  return [...new Uint8Array(bits.buffer)].map(v => v.toString(16).padStart(2, '0')).join('').toUpperCase();
};
const candidates = new Map([
  ['big-add', 'i:' + (9007199254740993n + 1n)],
  ['decimal-a', `d:${a.digits}:${a.scale}`],
  ['decimal-b', `d:${b.digits}:${b.scale}`],
  ['scale-equality', String(a.digits === b.digits && a.scale === b.scale)],
  ['numeric-equality', String(align(a, b)[0] === align(a, b)[1])],
  ['decimal-add', literal(add(a, decimal(22, 1)))],
  ['decimal-mul', literal(mul(a, decimal(20, 1)))],
  ['decimal-map-keys', String(new Set([`d:${a.digits}:${a.scale}`, `d:${b.digits}:${b.scale}`]).size)],
  ['int-float-map-keys', String(new Set(['i:1', 'f:' + floatBits(1.0)]).size)],
  ['negative-zero', 'f:' + floatBits(-0.0)],
  ['negative-int-div', 'i:' + (-7n / 3n)],
  ['negative-int-rem', 'i:' + (-7n % 3n)],
  ['decimal-half-even', '0.12M'], // Candidate rounding not implemented here.
  ['decimal-half-up', '0.13M'],
  ['float-to-decimal', 'decimal/inexact-operand'],
  ['decimal-div', literal(decimal(25, 2))], // Corpus expectation, not a division implementation.
  ['decimal-nonterminating', 'decimal/non-terminating'], // Ditto: native exception shape.
]);
for (const [name, expected] of candidates) {
  assert.equal(observed.get(name), expected, `${name}: native BL and tagged candidate differ`);
  console.log(`PASS ${name}: ${expected}`);
}
assert.equal(observed.size, candidates.size, 'unexpected native corpus rows');
assert.equal(Number(9007199254740993n), 9007199254740992);
assert.equal(Number.isInteger(1.0), true); // Host cannot recover the BL float tag.

// One-run, environment-specific relative cost. This is not a performance claim.
const runs = 100000;
function bench(label, fn) {
  const start = process.hrtime.bigint();
  let value;
  for (let i = 0; i < runs; i++) value = fn(i);
  const ms = Number(process.hrtime.bigint() - start) / 1e6;
  console.log(`MEASURE ${label}: ${ms.toFixed(2)} ms / ${runs} ops; last=${String(value).slice(0, 25)}`);
}
bench('Number add', i => i + 1);
bench('BigInt add', i => BigInt(i) + 1n);
bench('tagged decimal add', i => add(a, decimal(i, 2)).digits);
console.log(`MEASURE spike script: ${statSync(fileURLToPath(import.meta.url)).size} bytes`);
console.log('numeric-spike: RESEARCH PASS (17 differential cases; no parity claim)');
