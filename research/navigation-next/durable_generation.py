"""SQLite-backed publication experiment. Not a Fjall implementation or power-loss proof."""
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

CHUNK=17

def open_db(path):
    c=sqlite3.connect(path)
    c.execute('PRAGMA journal_mode=WAL')
    c.execute('PRAGMA synchronous=FULL')
    return c

def setup(c):
    c.executescript('''
    CREATE TABLE meta(basis INTEGER, epoch INTEGER, start INTEGER, cursor INTEGER,
                      through INTEGER, stage_epoch INTEGER, published INTEGER);
    INSERT INTO meta VALUES(0,1,0,0,0,1,0);
    CREATE TABLE history(e INTEGER,b INTEGER,v INTEGER,deleted INTEGER,PRIMARY KEY(b));
    CREATE INDEX entity_history ON history(e,b);
    CREATE TABLE staged(e INTEGER PRIMARY KEY,v INTEGER);
    ''')
    c.commit()

def write(c,e,v):
    with c:
        c.execute('UPDATE meta SET basis=basis+1,published=0')
        b=c.execute('SELECT basis FROM meta').fetchone()[0]
        c.execute('INSERT INTO history VALUES(?,?,?,?)',(e,b,v,int(v is None)))

def begin(c):
    with c:
        c.execute('DELETE FROM staged')
        c.execute('UPDATE meta SET start=basis,cursor=0,through=basis,stage_epoch=epoch,published=0')

def asof(c,basis,after=0,limit=None):
    sql='''SELECT h.e,h.v,h.deleted FROM history h WHERE h.b<=? AND h.e>?
       AND NOT EXISTS(SELECT 1 FROM history newer WHERE newer.e=h.e
                      AND newer.b<=? AND newer.b>h.b) ORDER BY h.e'''
    args=[basis,after,basis]
    if limit is not None:sql+=' LIMIT ?';args.append(limit)
    return c.execute(sql,args).fetchall()

def copy(c,crash=False):
    start,cursor=c.execute('SELECT start,cursor FROM meta').fetchone()
    rows=asof(c,start,cursor,CHUNK)
    if not rows:return 0
    c.execute('BEGIN IMMEDIATE')
    for e,v,deleted in rows:
        if not deleted:c.execute('INSERT OR REPLACE INTO staged VALUES(?,?)',(e,v))
    if crash:os._exit(7)  # Actual process death before checkpoint/commit.
    c.execute('UPDATE meta SET cursor=?',(rows[-1][0],))
    c.commit()
    return len(rows)

def catchup(c):
    basis,start,cursor,through=c.execute('SELECT basis,start,cursor,through FROM meta').fetchone()
    if asof(c,start,cursor,1):raise RuntimeError('snapshot copy incomplete')
    rows=c.execute('SELECT e,b,v,deleted FROM history WHERE b>? AND b<=? ORDER BY b LIMIT ?',
                   (through,basis,CHUNK)).fetchall()
    with c:
        for e,b,v,deleted in rows:
            if deleted:c.execute('DELETE FROM staged WHERE e=?',(e,))
            else:c.execute('INSERT OR REPLACE INTO staged VALUES(?,?)',(e,v))
        if rows:c.execute('UPDATE meta SET through=?',(rows[-1][1],))
    return len(rows)

def publish(c):
    c.execute('BEGIN IMMEDIATE')
    basis,epoch,start,cursor,through,stage_epoch,_=c.execute('SELECT * FROM meta').fetchone()
    ready=(not asof(c,start,cursor,1) and through==basis and stage_epoch==epoch)
    if ready:c.execute('UPDATE meta SET published=1')
    c.commit()
    return ready

class Tests(unittest.TestCase):
    def test_crash_and_concurrent_source_changes(self):
        with tempfile.TemporaryDirectory(prefix='navigation-generation-') as d:
            path=str(Path(d)/'generation.sqlite');c=open_db(path);setup(c)
            for e in range(1,1101):write(c,e,e*10)
            begin(c);self.assertEqual(copy(c),CHUNK)
            checkpoint=c.execute('SELECT cursor FROM meta').fetchone()[0]
            p=subprocess.run([sys.executable,__file__,'crash',path],capture_output=True)
            self.assertEqual(p.returncode,7)
            c.close();c=open_db(path)
            self.assertEqual(c.execute('SELECT cursor FROM meta').fetchone()[0],checkpoint)
            self.assertEqual(c.execute('SELECT count(*) FROM staged').fetchone()[0],CHUNK)
            write(c,1,999);write(c,2,None);write(c,1101,11010)
            self.assertFalse(publish(c))
            copied=CHUNK;max_batch=CHUNK
            while (n:=copy(c)):copied+=n;max_batch=max(max_batch,n)
            self.assertFalse(publish(c))  # copied snapshot but still missing deltas
            while (n:=catchup(c)):max_batch=max(max_batch,n)
            self.assertTrue(publish(c))
            expected=[(e,v) for e,v,deleted in asof(c,c.execute('SELECT basis FROM meta').fetchone()[0]) if not deleted]
            self.assertEqual(c.execute('SELECT e,v FROM staged ORDER BY e').fetchall(),expected)
            # Later writes invalidate publication; epoch changes fence old generation.
            write(c,3,888);self.assertFalse(publish(c));catchup(c)
            with c:c.execute('UPDATE meta SET epoch=epoch+1,published=0')
            self.assertFalse(publish(c))
            print(json.dumps({'durable_snapshot_rows':copied,'current_rows':len(expected),
                              'max_batch':max_batch,'crash_exit':p.returncode,
                              'checkpoint_after_crash':checkpoint,'schema_epoch_fence':True,
                              'power_loss_tested':False,'backend':'SQLite prototype'}))
            c.close()

if __name__=='__main__':
    if len(sys.argv)>1 and sys.argv[1]=='crash':copy(open_db(sys.argv[2]),crash=True)
    else:unittest.main(verbosity=2)
