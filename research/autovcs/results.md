Warning: This setting will only impact future commits.
The author of the working copy will stay " <>".
To change the working copy author, use "jj metaedit --update-author".
Warning: This setting will only impact future commits.
The author of the working copy will stay " <>".
To change the working copy author, use "jj metaedit --update-author".

== the floor: what a bare process costs before any work happens
  a bare VM, nothing loaded: 4305 ms
  the same VM with the probe and datom loaded, no requests: 19792 ms

== session: five mutations, then the mirror is asked what happened
{"ok":true,"request":"r1","op":"194118419975fa535dbfc8c3b1153ff3dc02f930144d862fa16a054076eff2715391378833328ae7ac5b902e1cb4c34a30af43bdeafbf6a5cc88fa
{"ok":true,"request":"r2","op":"03caf48124ffb2aa5673278b964bce939e15e1a21f4b70a4f4bf8df2b3922695f15c3e38bb729d6737409650d89ce4a8643e661b746e66d8ce701d
{"ok":true,"request":"r3","op":"efd62c5fc082e37af5ab2f2c62483acae83f8f8fd54d5c6bdf8901909731d891ac7bace143b8b38373a527b75b31e14ff0daaaf54730e3356ec95f
{"ok":true,"request":"r4","op":"6a794a18a706821133de59dc5fe0242d220334477e20960ce766987f1f480895a1628cccdddddc19fee8f5b353e7ef2c0aae4979af7d369d30a44a
{"ok":true,"request":"r5","op":"ef8ddd39d7e68c6a85cafad5120aa081b11b802a9433af83eb76cd65b16fe8e49483284d5edbfec1cb8beac005c76e44c9b5a8db008f5c97ed0715
{"ok":true,"jj":{"version":"jj 0.45.1-7c41cdeb16b6b321c64e789a966b6adf723816a5","head_commit":"46c484531763fdea07cb48a886aa629d7c525c0c","head_change"
{"ok":true,"history":[{"at":1789234481816,"request":"r1","path":"app.bl","op":"194118419975fa535dbfc8c3b1153ff3dc02f930144d862fa16a054076eff2715391378
{"ok":true,"path":"app.bl","requests":[{"at":1789234481816,"request":"r1","op":"194118419975fa535dbfc8c3b1153ff3dc02f930144d862fa16a054076eff271539137
:ok
   r1   1519 ms total   863 ms mirror  op 194118419975…  commit 2fa3eb7711db…  ['app.bl']
   r2   1703 ms total   969 ms mirror  op 03caf48124ff…  commit 3193ff057195…  ['data/points.json']
   r3   1373 ms total   717 ms mirror  op efd62c5fc082…  commit 7a7a9c65caf8…  ['notes.md']
   r4   1521 ms total   690 ms mirror  op 6a794a18a706…  commit d0f0a64d55fd…  ['app.bl']
   r5   1611 ms total  1008 ms mirror  op ef8ddd39d7e6…  commit 907fe26c3b09…  ['notes.md']
  history rows: 5
     r1 agent:probe    first cut of the answer fn         app.bl             op 1941184199…
     r2 agent:probe    seed the fixture data              data/points.json   op 03caf48124…
     r3 human:you      record the open question           notes.md           op efd62c5fc0…
     r4 agent:probe    make it 2, per BUG-9               app.bl             op 6a794a18a7…
     r5 agent:probe    the question is answered; drop the note notes.md           op ef8ddd39d7…
  touched app.bl: ['r1', 'r4']

== the tree's own history (jj log, jj's words)
xkrsnlsl  autovcs probe  
omrqzxuy  autovcs probe  agent:probe: the question is answered; drop the note

zlnrpkmp  autovcs probe  agent:probe: make it 2, per BUG-9

srsvksuz  autovcs probe  human:you: record the open question

rqkxzpzz  autovcs probe  agent:probe: seed the fixture data

moppkplq  autovcs probe  agent:probe: first cut of the answer fn

zzzzzzzz    

== the colocated git repo sees the same history (interop)
907fe26 agent:probe: the question is answered; drop the note
d0f0a64 agent:probe: make it 2, per BUG-9
7a7a9c6 human:you: record the open question
3193ff0 agent:probe: seed the fixture data
2fa3eb7 agent:probe: first cut of the answer fn

== the files on disk after the session
.:
.
..
app.bl
.autovcs
_build
data
.git
.gitignore
.jj
README.md

./.autovcs:
.
..
empty.jsonl
mirror.fjall
mirror.fjall.blobs
replies.jsonl
requests.jsonl

./.autovcs/mirror.fjall:
.
..
  the working copy is clean: everything the daemon did is a change

== undo: restore to the operation recorded after r3 (efd62c5fc082…) — two later changes vanish
{"ok":true,"mirror":{"ops":2,"commits":0,"skipped":false},"restored_to":"efd62c5fc082e37af5ab2f2c62483acae83f8f8fd54d5c6bdf8901909731d891ac7bace143b8b
{"ok":true,"jj":{"version":"jj 0.45.1-7c41cdeb16b6b321c64e789a966b6adf723816a5","head_commit":"7a7a9c65caf8c6bb8f7037b3e9c665ca1e1562a7","head_change"
{"ok":true,"history":[{"at":1789234481816,"request":"r1","path":"app.bl","op":"194118419975fa535dbfc8c3b1153ff3dc02f930144d862fa16a054076eff2715391378
:ok
  both files are back: app.bl says 1 again, notes.md exists

== measured
  bare cold VM                             : 4305 ms
  cold VM + probe + datom, zero requests   : 19792 ms   <- why this belongs in the daemon
  checkpoint total, per request            : [1519, 1703, 1373, 1521, 1611]  spread 1373–1703
    of which the jj->datom mirror          : [863, 969, 717, 690, 1008]  spread 690–1008
  the whole script pass (5 mutations + 3 queries + process): 28057 ms

== OK — the daemon's work is a history, not a state
