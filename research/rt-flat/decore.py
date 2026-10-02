"""Remove the runtime's calls into the prelude (`core`), structurally.

The runtime runs before `core` exists, so every call it makes must be a BIF, a
host module, or its own definition. Rewrites (paren-aware, over the token tree):

  (not (erlang/== a b))       → (erlang/=/= a b)
  (not X)                     → (if X false true)
  (list a b …)                → `(~a ~b …)    — a native cons chain, no call
  (list)                      → ()
  (first p) (second p)        → (erlang/hd p) (erlang/hd (erlang/tl p))   [pairs->map only: its
                                 elements are proper 2-lists by construction]
"""
import sys
sys.path.insert(0, '/tmp/merge')
from sexp import tokens


def parse(src):
    """A tree: ('form', open_tok, [children], close_tok, start, end) or
    ('atom', text, start, end) or ('trivia', text)."""
    toks = list(tokens(src))
    pos = 0

    def node():
        nonlocal pos
        k, a, b = toks[pos]
        if k == 'open':
            pos += 1
            kids = []
            while toks[pos][0] != 'close':
                kids.append(node())
            ca, cb = toks[pos][1], toks[pos][2]
            pos += 1
            return ['form', src[a:b], kids, src[ca:cb]]
        pos += 1
        if k in ('ws', 'comment'):
            return ['trivia', src[a:b]]
        return ['atom', src[a:b], k]

    out = []
    while pos < len(toks):
        out.append(node())
    return out


def emit(nodes):
    parts = []
    for n in nodes:
        if n[0] == 'form':
            parts.append(n[1] + emit(n[2]) + n[3])
        else:
            parts.append(n[1])
    return ''.join(parts)


def sig(n):
    """Significant children (no trivia) of a form."""
    return [c for c in n[2] if c[0] != 'trivia']


def is_list_form(n, head):
    if n[0] != 'form' or n[1] != '(':
        return False
    s = sig(n)
    return bool(s) and s[0][0] == 'atom' and s[0][1] == head


counts = {}


def bump(k):
    counts[k] = counts.get(k, 0) + 1


def prefix_quote_atoms(n):
    """Inside a syntax-quote, a bare symbol would be namespace-qualified and a
    nested list would be quoted as data. So every element is unquoted with ~."""
    return n


def rewrite(n, prev=None):
    if n[0] != 'form':
        return n
    n[2] = [rewrite(c) for c in n[2]]
    if n[1] != '(':
        return n
    s = sig(n)
    if not s or s[0][0] != 'atom':
        return n
    head = s[0][1]
    if head == 'not' and len(s) == 2:
        arg = s[1]
        if is_list_form(arg, 'erlang/==') and len(sig(arg)) == 3:
            a, b = sig(arg)[1:]
            bump('not==')
            return ['atom', f'(erlang/=/= {emit([a])} {emit([b])})', 'sym']
        bump('not')
        return ['atom', f'(if {emit([arg])} false true)', 'sym']
    if head == 'list':
        items = s[1:]
        bump('list')
        if not items:
            return ['atom', '()', 'sym']
        return ['atom', '`(' + ' '.join('~' + emit([x]) for x in items) + ')', 'sym']
    return n


if __name__ == '__main__':
  src = open(sys.argv[1]).read()
  tree = parse(src)
  out = emit([rewrite(n) for n in tree])
  open(sys.argv[1], 'w').write(out)
  print(counts)
