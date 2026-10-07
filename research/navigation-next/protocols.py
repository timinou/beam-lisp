"""Executable design models, not production storage/compiler code.
Run: python3 research/navigation-next/protocols.py
"""
from dataclasses import dataclass, replace
from itertools import product
import json
import unittest

@dataclass(frozen=True)
class Generation:
    live: tuple = ((1, 10), (2, 20), (3, 30))
    rev: int = 0
    epoch: int = 1
    snapshot: tuple | None = None
    copied: int = 0
    staged: tuple = ()
    deltas: tuple = ()
    through: int = 0
    stage_epoch: int = 0
    published: tuple | None = None
    max_batch: int = 0

def migration(s, op, unsafe=False):
    """Snapshots and delta records are durable abstract state. Chunk limit=2.
    Delta capture is atomic with source commit; real backend must implement this.
    Old snapshots survive writes; live generation is unpublished on schema change.
    """
    if op == 'begin':
        return replace(s, snapshot=s.live, copied=0, staged=(), deltas=(),
                       through=s.rev, stage_epoch=s.epoch)
    if op == 'write':
        live = dict(s.live)
        live[1] = live.get(1, 0) + 1
        deltas = s.deltas
        if s.snapshot is not None:
            # Bounded journal experiment: refuse generation, never source write.
            if len(deltas) == 3:
                return replace(s, live=tuple(sorted(live.items())), rev=s.rev+1,
                               snapshot=None, staged=(), deltas=())
            deltas += ((s.rev+1, 1, live[1]),)
        return replace(s, live=tuple(sorted(live.items())), rev=s.rev+1,
                       deltas=deltas, published=None)
    if op == 'delete':
        live = dict(s.live)
        live.pop(2, None)
        deltas = s.deltas
        if s.snapshot is not None:
            if len(deltas) == 3:
                return replace(s, live=tuple(sorted(live.items())), rev=s.rev+1,
                               snapshot=None, staged=(), deltas=())
            deltas += ((s.rev+1, 2, None),)
        return replace(s, live=tuple(sorted(live.items())), rev=s.rev+1,
                       deltas=deltas, published=None)
    if op == 'copy' and s.snapshot is not None:
        batch = s.snapshot[s.copied:s.copied+2]
        staged = dict(s.staged)
        staged.update(batch)
        return replace(s, staged=tuple(sorted(staged.items())),
                       copied=s.copied+len(batch), max_batch=max(s.max_batch,len(batch)))
    if op == 'catchup' and s.snapshot is not None and s.copied == len(s.snapshot):
        staged = dict(s.staged)
        batch = s.deltas[:2]
        for revision, key, value in batch:
            if value is None:
                staged.pop(key, None)
            else:
                staged[key] = value
        return replace(s, staged=tuple(sorted(staged.items())), deltas=s.deltas[2:],
                       through=batch[-1][0] if batch else s.through,
                       max_batch=max(s.max_batch,len(batch)))
    if op == 'schema':
        return replace(s, epoch=s.epoch+1,published=None)
    if op == 'publish' and s.snapshot is not None:
        ready = (s.copied == len(s.snapshot) and not s.deltas
                 and s.through == s.rev and s.stage_epoch == s.epoch)
        if ready or (unsafe and s.copied == len(s.snapshot)):
            return replace(s,published=s.staged)
    # Crash drops only volatile process state, not committed checkpoints.
    return s

class Node:
    def __init__(self, key):
        self.key, self.left, self.right = key, None, None
        self.height, self.size = 1, 1

def height(n): return n.height if n else 0
def size(n): return n.size if n else 0

def refresh(n):
    n.height = 1+max(height(n.left),height(n.right))
    n.size = 1+size(n.left)+size(n.right)
    return n

def rotate(n, direction):
    if direction == 'left':
        p=n.right; n.right=p.left; p.left=refresh(n)
    else:
        p=n.left; n.left=p.right; p.right=refresh(n)
    return refresh(p)

def balance(n):
    refresh(n)
    if height(n.left)-height(n.right)>1:
        if height(n.left.right)>height(n.left.left): n.left=rotate(n.left,'left')
        return rotate(n,'right')
    if height(n.right)-height(n.left)>1:
        if height(n.right.left)>height(n.right.right): n.right=rotate(n.right,'right')
        return rotate(n,'left')
    return n

def insert(n,key):
    if not n: return Node(key)
    if key<n.key: n.left=insert(n.left,key)
    elif key>n.key: n.right=insert(n.right,key)
    return balance(n)

def remove(n,key):
    if not n: return None
    if key<n.key: n.left=remove(n.left,key)
    elif key>n.key: n.right=remove(n.right,key)
    else:
        if not n.left: return n.right
        if not n.right: return n.left
        successor=n.right
        while successor.left: successor=successor.left
        n.key=successor.key; n.right=remove(n.right,successor.key)
    return balance(n)

def rank_page(n, offset, limit, visits):
    """Subtree counts skip prefixes; output sorted by (negative timestamp,id).
    Purely in-memory experiment. Production needs durable snapshot generations.
    """
    if not n or limit<=0 or offset>=size(n): return []
    visits[0]+=1
    leftsize=size(n.left)
    rows=[]
    if offset<leftsize:
        rows=rank_page(n.left,offset,limit,visits)
    if offset<=leftsize and len(rows)<limit:
        rows.append(n.key)
    if len(rows)<limit:
        rows+=rank_page(n.right,max(0,offset-leftsize-1),limit-len(rows),visits)
    return rows

class Tests(unittest.TestCase):
    def test_migration_histories(self):
        # Deduplicated breadth-first exploration retains shortest counterexample.
        ops=('begin','copy','write','delete','catchup','schema','publish','crash')
        frontier={Generation(): ()}; seen=set(frontier); checked=0
        bad=None
        for depth in range(8):
            upcoming={}
            for s,trace in frontier.items():
                for op in ops:
                    n=migration(s,op); checked+=1
                    self.assertLessEqual(n.max_batch,2)
                    self.assertLessEqual(len(n.deltas),3)
                    if n.published is not None:
                        self.assertEqual(n.published,n.live)
                    if n not in seen: upcoming[n]=trace+(op,); seen.add(n)
            frontier=upcoming
        for trace in product(ops,repeat=5):
            s=Generation()
            for op in trace: s=migration(s,op,unsafe=True)
            if s.published is not None and s.published!=s.live:
                bad=trace;break
        self.assertIsNotNone(bad)
        # Replay after crash and a committed batch twice must not duplicate facts.
        s=Generation()
        for op in ('begin','copy','write','delete','copy','crash','catchup','catchup','publish'):
            s=migration(s,op)
        self.assertEqual(s.published,s.live)
        print(json.dumps({'migration_transitions':checked,'unique_states':len(seen),
                          'unsafe_counterexample':bad,'chunk_limit':2,'delta_cap':3}))

    def test_rank_projection(self):
        root=None
        for i in range(10000): root=insert(root,(-i,i))
        oracle=sorted((-i,i) for i in range(10000))
        probes=[]
        for offset in (0,50,5000,9950,10000):
            visits=[0]; actual=rank_page(root,offset,50,visits)
            self.assertEqual(actual,oracle[offset:offset+50])
            probes.append({'offset':offset,'returned':len(actual),'nodes':visits[0]})
        for i in range(0,10000,3): root=remove(root,(-i,i))
        oracle=[k for k in oracle if k[1]%3]
        self.assertEqual(size(root),len(oracle))
        for offset in (0,50,5000,6600):
            self.assertEqual(rank_page(root,offset,50,[0]),oracle[offset:offset+50])
        self.assertLess(height(root),20)
        print(json.dumps({'rank_population':10000,'page_size':50,'probes':probes,
                          'after_retractions':size(root),'height':height(root)}))

    def test_render_commit_boundary(self):
        def render(events, safe):
            current=1; effects=0; committed=False; rendered=[]
            for event in events:
                if event=='navigate':current=2
                if event=='model':
                    if current!=1 and safe:continue
                if event=='effect':
                    committed=True;effects+=1
                if event=='finish':
                    if current==1 or committed:rendered.append(1)
            return effects,rendered
        # Once the effect boundary is crossed, newer navigation cannot erase it.
        self.assertEqual(render(['effect','navigate','finish'],True),(1,[1]))
        # Work admission must branch before effect execution, not merely suppress output.
        def admission(generation,current,pure):return generation==current or not pure
        self.assertFalse(admission(1,2,True))
        self.assertTrue(admission(1,2,False))
        print(json.dumps({'cancellation':'pure-model discard only; committed effects drain'}))

if __name__=='__main__':unittest.main(verbosity=2)
