#!/usr/bin/env python3
"""Render actual fixture evidence as a self-contained, offline interactive report."""
import json
from pathlib import Path
root=Path(__file__).resolve().parents[2]
proof=root/'docs/proof/runtime-observation/milestone-1'
data=json.loads((proof/'native.json').read_text())
page='''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Milestone 1 · Bounded owner observations</title>
<style>body{font:16px/1.6 system-ui;margin:3rem auto;padding:0 1rem;max-width:960px;background:#f5f3ee;color:#243431}h1{font-size:2.4rem;line-height:1.1}small{color:#52645e}.cards{display:flex;gap:1rem;flex-wrap:wrap}.card{background:white;border:1px solid #b4c4ba;padding:1rem;flex:1;min-width:160px}.card b{display:block;font-size:2rem}button{padding:.7rem 1rem;border:1px solid #426b5a;background:white;color:#243431;cursor:pointer}button[aria-pressed=true]{background:#245741;color:white}table{width:100%;border-collapse:collapse;margin-top:1rem}th,td{text-align:left;border-bottom:1px solid #c9d5ce;padding:.5rem}code{font-size:.85rem}pre{white-space:pre-wrap;max-height:420px;overflow:auto}svg{width:100%;height:150px}button:focus-visible{outline:3px solid #b95b12;outline-offset:3px}</style>
<small>BEAM LISP / MILESTONE 1</small><h1>A small read stays small.</h1><p>Actual private fixture: 256 owned processes and 512 processes in another realm. These are runtime observations, not UI mock data.</p>
<div class="cards"><div class="card"><b>256</b>exact owned total</div><div class="card"><b>0</b>foreign rows exposed</div><div class="card"><b id="examined"></b>candidates examined</div></div>
<p><button data-view="small" aria-pressed="true">8-row sample</button> <button data-view="large" aria-pressed="false">128-row sample</button></p>
<p id="summary" role="status"></p><table><thead><tr><th>Process</th><th>Role</th><th>Status</th><th>Mailbox length</th></tr></thead><tbody id="rows"></tbody></table>
<h2>50 sequential reads</h2><p id="timing"></p><svg id="plot" viewBox="0 0 900 150" role="img" aria-label="Native snapshot durations in microseconds"></svg><p>Includes native snapshot collection and physical VM counters. One finite run, with uncontrolled host load. This does not measure audio/video latency.</p>
<details><summary>Raw evidence and exact scopes</summary><pre id="raw"></pre></details><p>Reproduce: <code>bin/bl --cold run test/js/build-native-observation-report.bl</code>, then <code>python3 test/js/render-native-observation-report.py</code>.</p>
<script type="application/json" id="evidence">DATA</script><script>
const d=JSON.parse(document.getElementById('evidence').textContent),el=id=>document.getElementById(id);
function show(name){const s=d[name];el('examined').textContent=s.query.examined;el('summary').textContent=`${s.resources.length} of ${s.total} processes · ${s.truncated?'truncated':'complete'} · captured realm only`;el('rows').replaceChildren(...s.resources.map(r=>{const tr=document.createElement('tr');for(const value of [r.id,r.role,r.status,r.message_queue_len]){const td=document.createElement('td');td.textContent=value??'Unavailable';tr.append(td);}return tr;}));document.querySelectorAll('[data-view]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.view===name)));}
document.querySelectorAll('[data-view]').forEach(b=>b.onclick=()=>show(b.dataset.view));show('small');
const values=d['raw-duration-us'],ordered=[...values].sort((a,b)=>a-b),pct=q=>ordered[Math.floor((ordered.length-1)*q)];el('timing').textContent=`P50 ${pct(.5)} µs · P95 ${pct(.95)} µs · P99 ${pct(.99)} µs`;
const max=Math.max(...values,1),ns='http://www.w3.org/2000/svg';values.forEach((v,i)=>{const bar=document.createElementNS(ns,'rect');for(const [k,x] of Object.entries({x:i*18,y:150-v/max*140,width:14,height:v/max*140,fill:'#33735a'}))bar.setAttribute(k,x);const title=document.createElementNS(ns,'title');title.textContent=`Read ${i+1}: ${v} µs`;bar.append(title);el('plot').append(bar);});el('raw').textContent=JSON.stringify(d,null,2);
</script></html>'''
(proof/'report.html').write_text(page.replace('DATA',json.dumps(data).replace('</','<\\/')))
