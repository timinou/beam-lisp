// Browser glue only: BL owns commands, state, and rendered view fragments.
'use strict';
let token = '';
let editor = null;
let editorDirty = false;
let editorEpoch = 0;
let activeBuffer = null;
let activeTab = 'buffer';
let appliedRevision = 0;
const fragments = {};
window.playInit = value => { token = value; };

function showError(message) {
  const el = document.getElementById('play-error');
  if (!el) return;
  el.textContent = String(message);
  el.style.display = 'block';
  clearTimeout(el.hideTimer);
  el.hideTimer = setTimeout(() => { el.style.display = 'none'; }, 9000);
}

async function sendCmd(cmd, args = {}) {
  try {
    const response = await fetch('/play/command', {
      method: 'POST', headers: {'content-type': 'application/json', 'x-bl-token': token},
      body: JSON.stringify({cmd, args})
    });
    const result = await response.json();
    if (!response.ok || result.ok === false) showError(result.error || `Request failed: ${response.status}`);
    if (result.state) applyState(result.state);
    if (result.needs_dialog) {
      switchTab('buffer');
      document.querySelector('[name="path"]')?.focus();
    }
    return result;
  } catch (error) {
    showError(`Connection: ${error.message}`);
    return {ok: false};
  }
}
window.sendCmd = sendCmd;

function restoreInputs(panel, saved) {
  for (const [id, value, start, end] of saved) {
    const input = document.getElementById(id);
    if (!input || !panel.contains(input)) continue;
    input.value = value;
    if (start !== null) {
      input.focus();
      try { input.setSelectionRange(start, end); } catch (_) {}
    }
  }
}

function applyState(state) {
  if (Number(state.rev) < appliedRevision) return;
  appliedRevision = Number(state.rev) || appliedRevision;
  const nextBuffer = state.active_buffer?.id || null;
  const namespaceLabel = document.querySelector('.repl-ns');
  if (namespaceLabel && state.repl_ns) namespaceLabel.textContent = state.repl_ns;
  const focused = document.activeElement;
  for (const [name, html] of Object.entries(state.fragments || {})) {
    if (html === fragments[name]) continue;
    if (name === 'buffer' && editorDirty && nextBuffer === activeBuffer) continue;
    const panel = name === 'rail' ? document.querySelector('.rail') : document.querySelector(`.tab-panel[data-tab="${name}"]`);
    if (!panel) continue;
    const saved = [...panel.querySelectorAll('input[id], textarea[id], select[id]')]
      .filter(input => input.id !== 'buffer-source')
      .map(input => [input.id, input.value, input === focused ? input.selectionStart : null, input.selectionEnd]);
    if (name === 'buffer') {
      editorEpoch++;
      if (editor) editor.destroy();
      editor = null;
      editorDirty = false;
      activeBuffer = nextBuffer;
    }
    panel.innerHTML = html; // HTML is escaped and authored by the BL view renderer.
    fragments[name] = html;
    restoreInputs(panel, saved);
    if (name === 'buffer') initEditor();
  }
  const theme = state.view?.theme;
  if (theme === 'snow' || theme === 'carbon') {
    document.body.classList.toggle('theme-snow', theme === 'snow');
    document.body.classList.toggle('theme-carbon', theme === 'carbon');
    localStorage.setItem('bl-play-theme', theme);
  }
  // Panels stay under the user's focus; a background run never steals the tab.
  setTabDom(activeTab);
  const ae = state.active_experience;
  if (ae) document.querySelectorAll('[data-exp-status]').forEach(el => { el.textContent = ae.status; });
}

async function pollState() {
  try {
    const response = await fetch('/play/state');
    if (response.ok) applyState(await response.json());
  } catch (_) { /* reconnect via the next snapshot; no model call */ }
}

async function initEditor() {
  const textarea = document.getElementById('buffer-source');
  if (!textarea) return;
  textarea.addEventListener('input', () => { editorDirty = true; });
  const epoch = ++editorEpoch;
  try {
    const cm = await import('/repl/editor.bundle.js?v=1');
    if (epoch !== editorEpoch || !textarea.isConnected) return;
    const host = document.createElement('div');
    host.className = 'cm-host';
    textarea.after(host);
    editor = new cm.EditorView({
      doc: textarea.value,
      extensions: [
        cm.keymap.of([{key: 'Mod-s', run: () => { window.saveBuffer(document.querySelector('[data-buf-id]')); return true; }}]),
        cm.basicSetup, cm.StreamLanguage.define(cm.clojure),
        cm.syntaxHighlighting(cm.HighlightStyle.define([
          {tag: cm.tags.keyword, color: 'var(--syntax-keyword)'},
          {tag: cm.tags.string, color: 'var(--syntax-string)'},
          {tag: [cm.tags.number, cm.tags.bool, cm.tags.atom], color: 'var(--syntax-number)'},
          {tag: cm.tags.comment, color: 'var(--syntax-comment)'},
          {tag: [cm.tags.variableName, cm.tags.propertyName], color: 'var(--text)'},
          {tag: [cm.tags.operator, cm.tags.punctuation], color: 'var(--syntax-punctuation)'},
          {tag: [cm.tags.typeName, cm.tags.className], color: 'var(--syntax-type)'}
        ])),
        cm.EditorView.updateListener.of(update => {
          if (update.docChanged) { editorDirty = true; textarea.value = update.state.doc.toString(); }
        }),
        cm.EditorView.theme({
          '&': {backgroundColor: 'var(--surface)', color: 'var(--text)', minHeight: '340px'},
          '.cm-content': {fontFamily: 'var(--font-mono, monospace)', fontSize: '14px'},
          '.cm-gutters': {backgroundColor: 'var(--surface)', color: 'var(--muted)', borderRight: '1px solid var(--border)'},
          '.cm-cursor': {borderLeftColor: 'var(--text)'},
          '.cm-activeLine': {backgroundColor: 'var(--surface-2)'},
          '.cm-activeLineGutter': {backgroundColor: 'var(--surface-3)', color: 'var(--text)'}
        })
      ], parent: host
    });
    textarea.hidden = true;
    textarea.style.display = 'none';
    document.getElementById('editor-fallback-note')?.setAttribute('hidden', '');
  } catch (error) {
    console.warn('CodeMirror unavailable; editable textarea retained.', error.message);
  }
}
window.getEditorValue = () => editor ? editor.state.doc.toString() : (document.getElementById('buffer-source')?.value || '');
window.setEditorValue = value => {
  if (editor) editor.dispatch({changes: {from: 0, to: editor.state.doc.length, insert: value}});
  else { const ta = document.getElementById('buffer-source'); if (ta) ta.value = value; editorDirty = true; }
};

async function keepDraft() {
  if (!editorDirty) return true;
  const id = document.querySelector('[data-buf-id]')?.dataset.bufId;
  if (!id) return false;
  const result = await sendCmd('edit-buffer', {id, source: window.getEditorValue()});
  if (!result.ok) return false;
  editorDirty = false;
  return true;
}

function setTabDom(tab) {
  document.querySelectorAll('.tab-panel').forEach(el => el.classList.toggle('active', el.dataset.tab === tab));
  document.querySelectorAll('.tab-btn').forEach(el => {
    el.classList.toggle('active', el.dataset.tab === tab);
    el.setAttribute('aria-selected', String(el.dataset.tab === tab));
  });
}
function switchTab(tab) { activeTab = tab; setTabDom(tab); }
window.switchTab = switchTab;
window.openInRepl = async el => {
  const result = await sendCmd('inspect', {kind: el.dataset.kind, id: el.dataset.id});
  if (result.ok) {
    switchTab('repl');
    const input = document.getElementById('repl-input');
    input.value = `(dev.workspace/snapshot ${el.dataset.binding})`;
    input.focus();
    showReceipt(result.result);
  }
};
window.newFileDialog = async () => { if (await keepDraft()) await sendCmd('new-file-dialog'); };
window.openFile = async el => { if (await keepDraft()) { const r = await sendCmd('open-file', {path: el.dataset.path}); if (r.ok) switchTab('buffer'); } };
window.switchBuffer = async el => { if (await keepDraft()) { await sendCmd('switch-buffer', {id: el.dataset.id}); switchTab('buffer'); } };
window.saveBuffer = async el => {
  if (!el) return;
  const id = el.dataset.bufId || el.dataset.id;
  const result = await sendCmd('edit-buffer', {id, source: window.getEditorValue()});
  if (!result.ok) return;
  editorDirty = false;
  const saved = await sendCmd('save-buffer', {id});
  if (saved.ok) { const note = document.getElementById('save-indicator'); if (note) note.textContent = 'saved'; }
};
window.closeBuffer = async el => { if (await keepDraft()) await sendCmd('close-buffer', {id: el.dataset.bufId}); };
window.submitNewFile = async event => {
  event.preventDefault();
  if (!await keepDraft()) return;
  const form = event.target;
  const result = await sendCmd('new-file', {path: form.elements.path.value.trim(), source: form.elements.source.value});
  if (result.ok) switchTab('buffer');
};
for (const [name, command] of Object.entries({verifyProposal: 'verify-proposal', tryProposal: 'try-proposal', saveProposal: 'save-proposal', makeLive: 'make-live', undoProposal: 'undo-proposal'})) {
  window[name] = async el => { const result = await sendCmd(command, {id: el.dataset.propId}); if (result.result) showReceipt(result.result); };
}
function showReceipt(text) { const out = document.getElementById('repl-output'); if (out) out.textContent = String(text); }
window.replEval = async event => {
  event?.preventDefault();
  const source = document.getElementById('repl-input')?.value;
  if (!source?.trim()) return;
  showReceipt('Evaluating…');
  const result = await sendCmd('eval', {source});
  showReceipt(result.ok ? (result.result ?? result.data ?? '') : (result.error || 'Evaluation failed'));
};
window.startGen = async el => {
  const prompt = document.getElementById('gen-prompt')?.value.trim();
  if (!prompt) { showError('Tell us what you would like to build.'); return; }
  const provider = document.getElementById('gen-provider')?.value || 'fake';
  const result = await sendCmd('gen-ns', {source_path: el.dataset.sourcePath || 'src/playground.bl', prompt, provider});
  if (result.ok) switchTab('experience');
};
window.refineExp = async el => {
  const prompt = document.getElementById(`refine-prompt-${el.dataset.expId}`)?.value.trim();
  if (!prompt) return showError('A follow-up needs a prompt.');
  await sendCmd('refine', {id: el.dataset.expId, prompt});
};
window.cancelExp = el => sendCmd('cancel-gen', {id: el.dataset.expId});
window.acceptGen = el => sendCmd('accept-gen', {id: el.dataset.expId});
window.inspectVersion = async el => { await sendCmd('switch-proposal', {id: el.dataset.propId}); switchTab('proposal'); };
window.focusExp = async el => { await sendCmd('focus', {id: el.dataset.id}); switchTab('experience'); };
window.collapseExp = async el => { await sendCmd('collapse', {id: el.dataset.id}); switchTab('buffer'); };
window.toggleTheme = () => {
  const snow = !document.body.classList.contains('theme-snow');
  document.body.classList.toggle('theme-snow', snow);
  document.body.classList.toggle('theme-carbon', !snow);
  localStorage.setItem('bl-play-theme', snow ? 'snow' : 'carbon');
  sendCmd('theme', {theme: snow ? 'snow' : 'carbon'});
};
window.copyForm = async text => {
  try {
    await navigator.clipboard.writeText(text);
    const flash = document.createElement('span'); flash.className = 'copy-flash'; flash.textContent = 'copied';
    document.body.appendChild(flash); setTimeout(() => flash.remove(), 1200);
  } catch (_) { showError('Clipboard unavailable. Select and copy the visible form.'); }
};
window.addEventListener('beforeunload', event => { if (editorDirty) { event.preventDefault(); event.returnValue = ''; } });
document.addEventListener('DOMContentLoaded', () => {
  if (localStorage.getItem('bl-play-theme') === 'snow') { document.body.classList.add('theme-snow'); document.body.classList.remove('theme-carbon'); }
  activeBuffer = document.querySelector('[data-buf-id]')?.dataset.bufId || null;
  activeTab = document.querySelector('.tab-panel.active')?.dataset.tab || 'buffer';
  initEditor(); pollState(); setInterval(pollState, 1200);
  document.getElementById('repl-input')?.addEventListener('keydown', event => { if ((event.ctrlKey || event.metaKey) && event.key === 'Enter') window.replEval(event); });
  document.addEventListener('keydown', event => { if (event.key === 'Enter' && document.activeElement.classList.contains('file-item')) window.openFile(document.activeElement); });
});
