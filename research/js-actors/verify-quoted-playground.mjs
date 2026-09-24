// Focused integration: the editable fence's accepted data enters the compiled
// BL actor through a bounded typed event; BL, not JavaScript, renders the frame.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import * as H from './host.mjs';
import { fenceQuotedForm, isKeyword } from './quoted-form.mjs';
import { decodeViewFrame } from './quoted-view-frame.mjs';

const bundle = new URL('./out/quoted-playground.mjs', import.meta.url);
assert.ok(existsSync(bundle), 'build the quoted-playground BL bundle first');
const source = '[:card {:id "today"} [:heading {:level 2 :text "Today"}] [:field :unread] [:button {:label "Refresh" :intent [:intent :increment]}] [:text "local data"]]';
const fenced = fenceQuotedForm(source);
assert.equal(fenced.ok, true);
const toBL = v => Array.isArray(v) ? H.vec(v.map(toBL)) :
  v instanceof Map ? H.bmap([...v].map(([k, x]) => [toBL(k), toBL(x)])) :
  isKeyword(v) ? H.kw(v.keyword) : v;
const form = toBL(fenced.form);
assert.throws(() => H.enqueueInput('preview', form), /string/, 'ordinary browser input remains string-only');
assert.throws(() => H.enqueueQuotedForm(H.vec([() => 1])), /closed data/, 'function never enters typed transport');
const cycle = H.vec([]);
H.vecItems(cycle).push(cycle);
assert.throws(() => H.enqueueQuotedForm(cycle), /cyclic/, 'cycle never enters typed transport');
console.log('PASS typed transport refuses functions/cycles and keeps ordinary input string-only');

const child = spawnSync(process.execPath, ['--input-type=module', '-e', `
import * as H from './host.mjs';
import { fenceQuotedForm, isKeyword } from './quoted-form.mjs';
const toBL = v => Array.isArray(v) ? H.vec(v.map(toBL)) :
  v instanceof Map ? H.bmap([...v].map(([k,x]) => [toBL(k), toBL(x)])) :
  isKeyword(v) ? H.kw(v.keyword) : v;
const lines = [];
console.log = (...args) => lines.push(args.join(' '));
H.enqueueQuotedForm(toBL(fenceQuotedForm(${JSON.stringify(source)}).form));
H.enqueueInput('version', '8');
H.enqueueInput('version', '8');
H.enqueueQuotedForm(toBL(fenceQuotedForm(${JSON.stringify(source)}).form));
H.enqueueQuotedForm(H.vec([H.kw('unknown')]));
H.enqueueInput('stop', '');
await import('./out/quoted-playground.mjs');
process.stdout.write(lines.join('\\n')+'\\n');
`], { cwd: new URL('.', import.meta.url), encoding: 'utf8', timeout: 60000, maxBuffer: 1024 * 1024 });
assert.equal(child.status, 0, child.stderr || child.error?.message);
assert.equal(child.stderr, '');
const lines = child.stdout.trim().split('\n');
assert.equal(lines.length, 7, child.stdout);
assert.equal(lines[0], 'QV-PLAY READY');
const result = decodeViewFrame(lines[1]);
assert.equal(result.ok, true, lines[1]);
assert.equal(result.view.heading.text, 'Today');
assert.equal(result.view.field.value, '7');
assert.equal(result.view.button.label, 'Refresh');
assert.equal(result.view.text, 'local data');
const advanced = decodeViewFrame(lines[2]);
assert.equal(advanced.ok, true, lines[2]);
assert.equal(advanced.view.field.value, '8', 'only a new server version updates the BL env');
assert.equal(lines[3], 'QV-PLAY REFUSED invalid-server-version', 'a replay cannot advance the actor');
assert.equal(decodeViewFrame(lines[4]).view.field.value, '8', 'rejected replay keeps confirmed version');
assert.match(lines[5], /^QV-PLAY REFUSED \[:refused /);
assert.equal(lines[6], 'QV-PLAY STOP');
console.log('PASS compiled BL actor rendered, advanced confirmed version, refused replay and stopped');
console.log('js-actors: QUOTED-PLAYGROUND PASS');
