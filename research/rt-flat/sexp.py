"""Minimal beam-lisp source tokenizer: top-level forms and symbol tokens.

Enough of the reader to split a file into top-level forms and to find SYMBOL
tokens (for renaming) without touching strings, comments, char literals,
keywords or regexes."""
import re

DELIMS = set('()[]{}')
WS = set(' \t\r\n,')


def tokens(src):
    """Yield (kind, start, end) over src. kinds: ws comment string char open
    close sym kw other."""
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c in WS:
            j = i
            while j < n and src[j] in WS:
                j += 1
            yield ('ws', i, j); i = j; continue
        if c == ';':
            j = src.find('\n', i)
            j = n if j < 0 else j
            yield ('comment', i, j); i = j; continue
        if c == '"' or (c == '#' and i + 1 < n and src[i+1] == '"'):
            j = i + (2 if c == '#' else 1)
            while j < n and src[j] != '"':
                j += 2 if src[j] == '\\' else 1
            yield ('string', i, j + 1); i = j + 1; continue
        if c == '\\':
            # char literal: \a \newline \( \space
            j = i + 2
            while j < n and src[j] not in WS and src[j] not in DELIMS:
                j += 1
            yield ('char', i, j); i = j; continue
        if c in '([{':
            yield ('open', i, i + 1); i += 1; continue
        if c in ')]}':
            yield ('close', i, i + 1); i += 1; continue
        if c == '#' and i + 1 < n and src[i+1] in '{(_\'':
            yield ('other', i, i + 1); i += 1; continue
        if c in "'`~@^":
            j = i + 1
            if c == '~' and j < n and src[j] == '@':
                j += 1
            yield ('other', i, j); i = j; continue
        j = i
        if c == ':' and i + 1 < n and src[i+1] == '"':
            j = i + 2
            while j < n and src[j] != '"':
                j += 2 if src[j] == '\\' else 1
            yield ('kw', i, j + 1); i = j + 1; continue
        while j < n and src[j] not in WS and src[j] not in DELIMS and src[j] != ';' and src[j] != '"':
            j += 1
        tok = src[i:j]
        yield ('kw' if tok.startswith(':') else 'sym', i, j)
        i = j


def top_forms(src):
    """[(start, end)] of top-level forms, with the comments/blank lines that
    precede each form attached to it (so moving a form moves its comment)."""
    forms, depth, start, lead = [], 0, None, 0
    for kind, a, b in tokens(src):
        if kind == 'open':
            if depth == 0 and start is None:
                start = a
            depth += 1
        elif kind == 'close':
            depth -= 1
            if depth == 0 and start is not None:
                forms.append((lead, start, b)); start = None; lead = b
        elif depth == 0 and kind in ('sym', 'kw', 'string') and start is None:
            forms.append((lead, a, b)); lead = b
    return forms, src[lead:]


def head_and_name(form_text):
    toks = [(k, form_text[a:b]) for k, a, b in tokens(form_text) if k not in ('ws', 'comment')]
    if len(toks) < 3 or toks[0][0] != 'open':
        return None, None
    head = toks[1][1]
    # skip metadata: ^:private / ^private / ^{...}
    i = 2
    while i < len(toks) and toks[i][1] == '^':
        i += 2
    name = toks[i][1] if i < len(toks) else None
    return head, name


def rename_syms(text, fn):
    """Rewrite each symbol token s to fn(s) (None = unchanged)."""
    out, last = [], 0
    for kind, a, b in tokens(text):
        if kind == 'sym':
            new = fn(text[a:b])
            if new is not None and new != text[a:b]:
                out.append(text[last:a]); out.append(new); last = b
    out.append(text[last:])
    return ''.join(out)
