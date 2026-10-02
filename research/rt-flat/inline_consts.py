"""Inline every constant `def` (a keyword literal, or
`(erlang/binary_to_atom "X" :utf8)`) at its use sites and delete the def.

A namespace `def` VALUE has no link row, so every read is an `Env.fetch!` —
two ETS lookups — on every call. A literal atom costs nothing."""
import sys, re
sys.path.insert(0, '/tmp/merge')
from decore import parse, emit, sig, is_list_form

p = sys.argv[1]
tree = parse(open(p).read())

consts = {}
keep = []
for n in tree:
    if n[0] == 'form' and is_list_form(n, 'def'):
        s = sig(n)
        # skip metadata
        i = 1
        while i < len(s) and s[i][1] == '^':
            i += 2
        name = s[i][1]
        rest = s[i + 1:]
        if len(rest) == 2 and rest[0][1].startswith('"'):
            rest = rest[1:]          # a docstring
        val = rest[0] if len(rest) == 1 else None
        if val is not None:
            if val[0] == 'atom' and val[1].startswith(':') and not val[1].startswith(':"Elixir.BeamLisp.Fns'):
                consts[name] = val[1]
                continue
            if is_list_form(val, 'erlang/binary_to_atom'):
                vs = sig(val)
                if vs[1][0] == 'atom' and vs[1][1].startswith('"'):
                    consts[name] = ':' + vs[1][1]
                    continue
    keep.append(n)

# drop the trivia (comment/blank) that immediately preceded a removed def? keep it — harmless.
count = 0


def sub(n):
    global count
    if n[0] == 'atom' and n[2] == 'sym' and n[1] in consts:
        count += 1
        return ['atom', consts[n[1]], 'kw']
    if n[0] == 'form':
        n[2] = [sub(c) for c in n[2]]
    return n


out = emit([sub(n) for n in keep])
open(p, 'w').write(out)
print(f'inlined {len(consts)} constants at {count} sites:', ' '.join(sorted(consts)))
