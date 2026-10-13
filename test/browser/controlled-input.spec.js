const {test,expect}=require('@playwright/test');
const fs=require('fs'),path=require('path');
const client=fs.readFileSync(process.env.LIVE_CLIENT_SOURCE||path.join(__dirname,'../../priv/lib/live/client.js'),'utf8');
async function boot(page,html,features={'input-ack':true}) {
  await page.setContent('<div id="live-root"></div>');
  await page.addScriptTag({content:`window.WebSocket=function(){this.readyState=1;this.sent=[];window.sock=this;setTimeout(()=>this.onopen?.(),0)};
    WebSocket.OPEN=1;WebSocket.CONNECTING=0;WebSocket.prototype.send=function(s){this.sent.push(JSON.parse(s))};`});
  await page.addScriptTag({content:client});
  await page.evaluate(({html,features})=>{
    Live.connect({root:document.getElementById('live-root'),url:'ws://fake',heartbeatMs:0,reconnect:false});
    sock.onmessage({data:JSON.stringify(['mount','<div>'+html+'</div>',features])});
  },{html,features});
}
async function frame(page,body){await page.evaluate(body=>sock.onmessage({data:JSON.stringify(body)}),body);}
async function ids(page){return page.evaluate(()=>sock.sent.filter(x=>x[0]==='event').map(x=>x[2]['live/input-id']));}
const input='<input id="field" value="A" data-ev-input=\'["assign","draft",["from","value"]]\'>';

test('dirty inputs show model resets and independent later edits',async({page})=>{
  await boot(page,input);await page.locator('#field').fill('B');const [id]=await ids(page);
  await frame(page,['patch',[['set-attr',[0],'value','B']]]);await frame(page,['input-ack',id]);
  await frame(page,['patch',[['set-attr',[0],'value','']]]);await expect(page.locator('#field')).toHaveValue('');
  await frame(page,['patch',[['set-attr',[0],'value','colleague']]]);await expect(page.locator('#field')).toHaveValue('colleague');
});

test('older echoes and acknowledgements cannot erase newer ABA input',async({page})=>{
  await boot(page,input);await page.locator('#field').fill('AB');await page.locator('#field').fill('A');
  const [first,last]=await ids(page);expect(first).toBeTruthy();expect(last).not.toBe(first);
  await frame(page,['patch',[['set-attr',[0],'value','AB']]]);await frame(page,['input-ack',first]);
  await expect(page.locator('#field')).toHaveValue('A');
  await frame(page,['patch',[['set-attr',[0],'value','A']]]);await frame(page,['input-ack',last]);
  await expect(page.locator('#field')).toHaveValue('A');
  await frame(page,['patch',[['set-attr',[0],'value','reset']]]);await expect(page.locator('#field')).toHaveValue('reset');
});

test('pending fields are independent and composition keeps its native draft',async({page})=>{
  await boot(page,input+'<input id="other" value="old">');await page.locator('#field').fill('typed');
  const [id]=await ids(page);
  await frame(page,['patch',[['set-attr',[0],'value','older'],['set-attr',[1],'value','independent']]]);
  await expect(page.locator('#field')).toHaveValue('typed');await expect(page.locator('#other')).toHaveValue('independent');
  await page.locator('#field').dispatchEvent('compositionstart');
  await frame(page,['patch',[['set-attr',[0],'value','composed']]]);await frame(page,['input-ack',id]);
  await expect(page.locator('#field')).toHaveValue('typed');
  await page.locator('#field').dispatchEvent('compositionend');await expect(page.locator('#field')).toHaveValue('composed');
});

test('checkbox and selected option properties follow acknowledged model state',async({page})=>{
  await boot(page,'<input id="check" type="checkbox" data-ev-change=\'["assign","flag",["from","checked"]]\'>'+
    '<select id="select" value="a" data-ev-change=\'["assign","choice",["from","value"]]\'><option value="a" selected>A</option><option value="b">B</option></select>');
  await page.locator('#check').check();await page.locator('#select').selectOption('b');const [check,select]=await ids(page);
  await frame(page,['patch',[['set-attr',[0],'checked',true],['set-attr',[1],'value','b']]]);
  await frame(page,['input-ack',check]);await frame(page,['input-ack',select]);
  await frame(page,['patch',[['remove-attr',[0],'checked'],['set-attr',[1],'value','a']]]);
  await expect(page.locator('#check')).not.toBeChecked();await expect(page.locator('#select')).toHaveValue('a');
});

test('an older server keeps its attribute-only editing contract',async({page})=>{
  await boot(page,input,null);await page.locator('#field').fill('local');
  expect((await ids(page))[0]).toBeUndefined();
  await frame(page,['patch',[['set-attr',[0],'value','old echo']]]);await expect(page.locator('#field')).toHaveValue('local');
});
