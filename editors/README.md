# Editors

beam-lisp meets an editor on three surfaces:

- **Syntax** — the tree-sitter grammar in `tree-sitter-beamlisp/` highlights
  `.bl` files and powers structural navigation.
- **Intelligence** — `bl lsp serve` is a language server: diagnostics, hover
  (with the compiler's proof card), go-to-definition, references, document
  symbols, completion, signature help, inlay hints, document highlights, code
  actions. It speaks LSP over stdin/stdout, so any LSP client reaches it.
- **Facts** — `bl mcp` serves the codebase as a fact database over the Model
  Context Protocol: `code/ask`, `code/query`, `code/verify`, and friends.

`bl` must be on the editor's `PATH`. Inside the beam-lisp checkout, replace
`"bl"` with `"mix", "bl"` in any command below.

## Emacs

`emacs/beamlisp-ts-mode.el` is the major mode; it registers `eglot` against
`bl lsp serve`, so no separate LSP setup is needed.

```elisp
(add-to-list 'load-path "~/code/undefine/beam-lisp/editors/emacs")
(require 'beamlisp-ts-mode)
```

Install the grammar once (see `emacs/README.md`), open a `.bl` file, and run
`M-x eglot`. Completion (`company`/`corfu` via `completion-at-point`), flymake
diagnostics, `xref-find-definitions`, imenu, and inlay hints all go live.

To point eglot at a specific binary:

```elisp
(add-to-list 'eglot-server-programs
             '(beamlisp-ts-mode . ("bl" "lsp" "serve")))
```

## Neovim

Register the filetype and start the server with `nvim-lspconfig`:

```lua
vim.filetype.add({ extension = { bl = "beamlisp" } })

local lspconfig = require('lspconfig')
local configs = require('lspconfig.configs')

if not configs.beamlisp then
  configs.beamlisp = {
    default_config = {
      cmd = { 'bl', 'lsp', 'serve' },
      filetypes = { 'beamlisp' },
      root_dir = lspconfig.util.root_pattern('.git'),
    },
  }
end

lspconfig.beamlisp.setup({
  on_attach = function(_, bufnr)
    vim.keymap.set('n', 'gd', vim.lsp.buf.definition, { buffer = bufnr })
    vim.keymap.set('n', 'gr', vim.lsp.buf.references, { buffer = bufnr })
    vim.keymap.set('n', 'K',  vim.lsp.buf.hover, { buffer = bufnr })
  end,
})
```

Neovim 0.11+ can configure the same server without `lspconfig`:

```lua
vim.lsp.config('beamlisp', { cmd = { 'bl', 'lsp', 'serve' }, filetypes = { 'beamlisp' } })
vim.lsp.enable('beamlisp')
```

## VS Code

VS Code reaches any language server through a small extension built on
`vscode-languageclient`. A minimal `package.json` contribution:

```json
{
  "name": "beamlisp",
  "engines": { "vscode": "^1.80.0" },
  "activationEvents": ["onLanguage:beamlisp"],
  "contributes": {
    "languages": [{ "id": "beamlisp", "extensions": [".bl"] }]
  },
  "main": "./extension.js"
}
```

```js
const { LanguageClient } = require('vscode-languageclient/node');

exports.activate = () => {
  const server = { command: 'bl', args: ['lsp', 'serve'] };
  const client = new LanguageClient('beamlisp', 'beam-lisp', server, {
    documentSelector: [{ scheme: 'file', language: 'beamlisp' }],
  });
  client.start();
};
```

Any other generic LSP client (Helix, Zed, Sublime, Kate) takes the same
`bl lsp serve` command over stdio.

## MCP clients

An MCP-capable client — Claude Desktop, an agent runtime, an editor plugin —
starts `bl mcp` and exchanges one JSON-RPC object per line. A `mcpServers`
entry:

```json
{
  "mcpServers": {
    "beam-lisp": { "command": "bl", "args": ["mcp"] }
  }
}
```

The server exposes `code/list`, `code/query`, `code/ask`, `code/verify`,
`code/subscribe`, and `code/poll`. Answers cross the wire, never whole files.

## The protocol, by hand

The language server frames each message with a `Content-Length` header, so a
request goes out as bytes and the response comes back the same way:

```sh
python3 - <<'PY' | bl lsp serve
import json, sys
m = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}).encode()
sys.stdout.buffer.write(("Content-Length: %d\r\n\r\n" % len(m)).encode() + m)
PY
```

The response carries `capabilities` for every feature the server answers.
Beyond the standard requests, the `$/beamlisp/` namespace exposes the
proof-backed queries directly: `$/beamlisp/proof`, `$/beamlisp/nativeEligible`,
`$/beamlisp/impact`, and `$/beamlisp/deadCode`.
