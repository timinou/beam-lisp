"""Flatten research/rt-cutover/{rt.bl, rt/*.bl} into ONE namespace `rt`.

Rules:
  * rt.bl (the facade) keeps every name it defines — those are the contract.
  * A sub-namespace definition keeps its name when that name is defined
    nowhere else; otherwise it becomes `<group>-<name>`.
  * Inside a sub-file, an unqualified reference to one of ITS OWN definitions is
    renamed with it (the file's defs shadow everything else in that file).
  * `alias/name` → the renamed definition in the aliased group.
  * Sub-files are emitted in require (dependency) order, facade last, so every
    load-time `def` value sees the defs it reads.
"""
import sys, os, re, glob, collections
sys.path.insert(0, os.path.dirname(__file__))
from sexp import tokens, top_forms, head_and_name, rename_syms

root = sys.argv[1]
out = sys.argv[2]
DEF_HEADS = ('defn', 'defn-', 'def', 'defmacro', 'declare')

def group_of(path):
    b = os.path.basename(path)[:-3]
    return None if path.endswith('/rt.bl') and os.path.dirname(path) == root else b

files = [os.path.join(root, 'rt.bl')] + sorted(glob.glob(os.path.join(root, 'rt/*.bl')))
src = {f: open(f).read() for f in files}

def parse_ns(text):
    """(ns-form-span, {alias: group}, [required groups])"""
    forms, _ = top_forms(text)
    for lead, a, b in forms:
        h, n = head_and_name(text[a:b])
        if h == 'ns':
            body = text[a:b]
            aliases, reqs = {}, []
            for m in re.finditer(r'\[rt(?:\.([a-z-]+))?(?:\s+:as\s+([a-z-]+))?\s*\]', body):
                g = m.group(1)
                reqs.append(g)
                if m.group(2):
                    aliases[m.group(2)] = g
            return (lead, a, b), aliases, reqs
    raise SystemExit('no ns in file')

info = {}
defs_by_file = {}
for f in files:
    ns_span, aliases, reqs = parse_ns(src[f])
    forms, _ = top_forms(src[f])
    names = []
    for lead, a, b in forms:
        h, n = head_and_name(src[f][a:b])
        if h in DEF_HEADS and h != 'declare':
            names.append(n)
        if h == 'declare':
            pass
    info[f] = dict(ns_span=ns_span, aliases=aliases, reqs=[r for r in reqs if r], forms=forms)
    defs_by_file[f] = set(names)

facade = files[0]
count = collections.Counter()
for f in files:
    for n in defs_by_file[f]:
        count[n] += 1

rename = {}   # (group, name) -> new name
taken = set(defs_by_file[facade])
for f in files[1:]:
    g = group_of(f)
    for n in sorted(defs_by_file[f]):
        new = n if (count[n] == 1 and n not in defs_by_file[facade]) else f'{g}-{n}'
        while new in taken:
            new = f'{g}--{n}' if new == f'{g}-{n}' else new + '*'
        assert new not in taken, (g, n, new)
        taken.add(new)
        rename[(g, n)] = new

def resolver(f):
    g = group_of(f)
    own = defs_by_file[f]
    aliases = info[f]['aliases']
    def fn(sym):
        if '/' in sym and not sym.startswith('/') and sym != '/':
            pre, name = sym.split('/', 1)
            if pre in aliases:
                tg = aliases[pre]
                if tg is None:          # alias of the facade itself
                    return name
                if (tg, name) not in rename:
                    raise SystemExit(f'{f}: {sym} names nothing in rt.{tg}')
                return rename[(tg, name)]
            return None
        if g is not None and sym in own:
            return rename[(g, sym)]
        return None
    return fn

# dependency order over groups
order, seen = [], set()
by_group = {group_of(f): f for f in files[1:]}
def visit(g):
    if g in seen: return
    seen.add(g)
    for r in info[by_group[g]]['reqs']:
        if r in by_group: visit(r)
    order.append(g)
for g in sorted(by_group): visit(g)

def body_without_ns(f):
    text = src[f]
    lead, a, b = info[f]['ns_span']
    return text[:a] + text[b:]

chunks = []
for g in order:
    f = by_group[g]
    t = rename_syms(body_without_ns(f), resolver(f))
    chunks.append(f';; ════ rt.{g} ' + '═' * max(0, 70 - len(g)) + '\n' + t.strip() + '\n')

ft = src[facade]
lead, a, b = info[facade]['ns_span']
head_text, tail_text = ft[:a], ft[b:]
facade_body = rename_syms(tail_text, resolver(facade))

result = (head_text.rstrip() + '\n\n(ns rt)\n\n' + '\n\n'.join(chunks)
          + '\n;; ════ rt — the public surface ' + '═' * 44 + '\n' + facade_body.strip() + '\n')
open(out, 'w').write(result)
renamed = {k: v for k, v in rename.items() if k[1] != v}
print(f'groups {order}')
print(f'definitions {sum(len(v) for v in defs_by_file.values())}, renamed {len(renamed)}')
