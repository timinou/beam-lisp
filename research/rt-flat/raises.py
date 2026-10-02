"""(erlang/error (tuple2 :"ArgumentError" MSG)) → (raise-argument MSG)
and the pop/sorted-dissoc {:"$error" …}/bare-binary raises likewise, so every
refusal is the SAME exception RT raises (`%ArgumentError{message: …}`)."""
import sys
sys.path.insert(0, '/tmp/merge')
from decore import parse, emit, sig, is_list_form

n = 0


def rw(node):
    global n
    if node[0] != 'form':
        return node
    node[2] = [rw(c) for c in node[2]]
    if not is_list_form(node, 'erlang/error'):
        return node
    s = sig(node)
    if len(s) != 2:
        return node
    arg = s[1]
    if is_list_form(arg, 'tuple2') and len(sig(arg)) == 3:
        tag = sig(arg)[1]
        if tag[0] == 'atom' and tag[1] in (':"ArgumentError"', ':"$error"'):
            n += 1
            return ['atom', f'(raise-argument {emit([sig(arg)[2]])})', 'sym']
    if is_list_form(arg, 'erlang/iolist_to_binary'):
        n += 1
        return ['atom', f'(raise-argument {emit([arg])})', 'sym']
    return node


p = sys.argv[1]
t = parse(open(p).read())
open(p, 'w').write(emit([rw(x) for x in t]))
print('raises', n)
