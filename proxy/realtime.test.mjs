import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const source = await readFile(new URL('./realtime.js', import.meta.url), 'utf8');
const relayModule = `data:text/javascript;base64,${Buffer.from(source).toString('base64')}`;
const { clientFrame, serverFrame, relayTranscription } = await import(relayModule);
const workerSource = (await readFile(new URL('./worker.js', import.meta.url), 'utf8')).replace('"./realtime.js"', JSON.stringify(relayModule));
const { default: worker } = await import(`data:text/javascript;base64,${Buffer.from(workerSource).toString('base64')}`);
let n = 0;
function pass(fn) { fn(); n++; }
function denied(p) { pass(() => assert.throws(() => clientFrame(JSON.stringify(p)))); }
const session = { type:'session.update', event_id:'cfg-1', session:{ type:'transcription', audio:{ input:{format:{type:'audio/pcm',rate:24000}, transcription:{model:'gpt-live-transcribe',delay:'low',languages:['es'],keywords:['Tomás']},turn_detection:null} } } };
pass(() => assert.equal(clientFrame(JSON.stringify(session)).session.audio.input.transcription.model, 'gpt-live-transcribe'));
pass(() => assert.equal(clientFrame(JSON.stringify({type:'input_audio_buffer.append',audio:Buffer.alloc(4800).toString('base64'),event_id:'audio-1'})).audio.length,6400));
pass(() => assert.equal(clientFrame('{"type":"input_audio_buffer.commit","event_id":"commit-1"}').event_id,'commit-1'));
denied({ ...session, session:{...session.session, tools:[{type:'function'}]} });
denied({ ...session, session:{...session.session,type:'realtime'} });
for (const model of ['gpt-4o','gpt-6-luna','gpt-transcribe']) { const p=structuredClone(session);p.session.audio.input.transcription.model=model; denied(p); }
for (const extra of ['voice','instructions','response','modalities']) { const p=structuredClone(session);p.session[extra]='x';denied(p); }
const badVAD=structuredClone(session);badVAD.session.audio.input.turn_detection={type:'server_vad'};denied(badVAD);
const badRate=structuredClone(session);badRate.session.audio.input.format.rate=16000;denied(badRate);
denied({type:'response.create'}); denied({type:'input_audio_buffer.append',audio:'invalid'}); denied({type:'input_audio_buffer.append',audio:'AA=='});
denied({type:'input_audio_buffer.append',audio:Buffer.alloc(65536).toString('base64')});
denied({type:'input_audio_buffer.commit',event_id:'secret\nvalue'});
denied({type:'input_audio_buffer.clear',session:{}});
const badHints=structuredClone(session);badHints.session.audio.input.transcription.keywords=['bad\nkeyword'];denied(badHints);
pass(() => assert.deepEqual(serverFrame('{"type":"session.updated","session":{"secret":"must-not-forward"}}'), {type:'session.updated',session:{type:'transcription'}}));
pass(() => assert.equal(serverFrame('{"type":"error","error":{"code":"insufficient_quota","message":"private upstream","event_id":"commit-1"}}').error.code,'insufficient_quota'));
pass(() => assert.equal(JSON.stringify(serverFrame('{"type":"error","error":{"code":"unexpected_secret","message":"private upstream"}}')).includes('private'),false));
pass(() => assert.equal(serverFrame('{"type":"conversation.item.input_audio_transcription.completed","item_id":"i1","transcript":"Hola"}').transcript,'Hola'));
pass(() => assert.equal(serverFrame('{"type":"response.audio.delta","delta":"x"}'),null));
for (const code of ['credit_balance_exhausted','project_spend_limit_exceeded','organization_spend_limit_exceeded','organization_usage_limit_exceeded','insufficient_quota','rate_limit_exceeded','slow_down','invalid_api_key','billing_hard_limit_reached','account_deactivated','not_authenticated','access_denied','model_not_allowed','invalid_value','invalid_request','invalid_config']) {
  pass(() => assert.equal(serverFrame(JSON.stringify({type:'error',error:{code,type:'insufficient_quota',message:'must-not-forward'}})).error.code,code));
}
pass(() => assert.equal(serverFrame('{"type":"error","error":{"code":"unknown","type":"insufficient_quota"}}').error.type,'insufficient_quota'));
for (const type of ['session.created','session.updated','transcription_session.created','transcription_session.updated']) {
  pass(() => assert.deepEqual(serverFrame(JSON.stringify({type,session:{type:'transcription',expires_at:2000000000,client_secret:'must-not-forward'}})), {type,session:{type:'transcription',expires_at:2000000000}}));
}
pass(() => assert.deepEqual(serverFrame('{"type":"session.updated","session":{"expires_at":"private"}}').session,{type:'transcription'}));
pass(() => assert.throws(() => serverFrame('{"type":"session.updated","session":{"type":"realtime"}}')));
pass(() => assert.throws(() => serverFrame('{"type":"conversation.item.input_audio_transcription.delta","item_id":"i1","delta":{"private":"x"}}')));
pass(() => assert.equal(serverFrame('{"type":"input_audio_buffer.committed","item_id":"i1","previous_item_id":null}').previous_item_id,null));

// These fixtures replace every network/socket/timer dependency. No API call,
// credential lookup, live audio, clipboard operation or deployment is performed.
const RealResponse = globalThis.Response;
class FakeSocket {
  listeners = new Map(); sent = []; closes = []; accepted = false; failSend = false;
  accept() { this.accepted = true; }
  addEventListener(type, fn) { const list=this.listeners.get(type) ?? []; list.push(fn); this.listeners.set(type,list); }
  emit(type, event={}) { for (const fn of this.listeners.get(type) ?? []) fn(event); }
  message(p) { this.emit('message',{data:typeof p === 'string' ? p : JSON.stringify(p)}); }
  send(data) { if (this.failSend) throw new Error('fixture send failure'); this.sent.push(JSON.parse(data)); }
  close(code,reason) { this.closes.push({code,reason}); this.emit('close'); }
}
class FakeResponse {
  constructor(body,{status,headers={},webSocket}={}) { Object.assign(this,{body,status,headers,webSocket}); }
  async text() { return this.body ?? ''; }
  async json() { return JSON.parse(this.body); }
}
async function fixture(run) {
  const prior = {fetch:globalThis.fetch,Response:globalThis.Response,WebSocketPair:globalThis.WebSocketPair,setTimeout:globalThis.setTimeout,clearTimeout:globalThis.clearTimeout,now:Date.now};
  const remote=new FakeSocket(), timers=new Map(), calls=[];
  let pair, now=100000, nextTimer=0;
  const state={remote,timers,calls,env:{TEAM_TOKENS:'fixture:fixture-team-token',OPENAI_API_KEY:'fixture-upstream-key'},
    get socket(){return pair[1];}, advance(ms){now+=ms;},
    fetchResult:{status:101,webSocket:remote}, fetchFailure:false,
    request(query='?intent=transcription',auth='fixture-team-token'){return new Request('https://fixture.invalid/v1/realtime'+query,{headers:{Upgrade:'websocket',Authorization:'Bearer '+auth,'X-Fixture-Private':'not-forwarded'}});},
    configure(){state.socket.message(session);remote.message({type:'session.updated',session:{type:'transcription',expires_at:2000000000}});},
    fire(ms){for(const [id,t] of timers)if(t.ms===ms){timers.delete(id);t.fn();}}
  };
  globalThis.Response=FakeResponse;
  globalThis.WebSocketPair=class {constructor(){pair={0:new FakeSocket(),1:new FakeSocket()};return pair;}};
  globalThis.fetch=async (url,options)=>{calls.push({url,options});if(state.fetchFailure)throw new Error('fixture upstream internals');return state.fetchResult;};
  globalThis.setTimeout=(fn,ms)=>{const id=++nextTimer;timers.set(id,{fn,ms});return id;};
  globalThis.clearTimeout=id=>timers.delete(id);
  Date.now=()=>now;
  try {await run(state);n++;} finally {Object.assign(globalThis,{fetch:prior.fetch,Response:prior.Response,WebSocketPair:prior.WebSocketPair,setTimeout:prior.setTimeout,clearTimeout:prior.clearTimeout});Date.now=prior.now;}
}

await fixture(async f=>{const r=await worker.fetch(f.request(),f.env);assert.equal(r.status,101);assert.equal(f.calls.length,1);assert.equal(f.calls[0].url,'https://api.openai.com/v1/realtime?intent=transcription');assert.deepEqual(f.calls[0].options.headers,{Upgrade:'websocket',Authorization:'Bearer fixture-upstream-key'});assert.ok(f.calls[0].options.signal);f.configure();assert.equal(f.remote.sent[0].session.audio.input.turn_detection,null);assert.equal(f.socket.sent.at(-1).session.expires_at,2000000000);assert.equal(f.timers.size,1);f.socket.emit('close');assert.equal(f.remote.closes.length,1);assert.equal(f.socket.closes.length,1);assert.equal(f.timers.size,0);const count=f.remote.sent.length;f.socket.message(session);assert.equal(f.remote.sent.length,count);});
await fixture(async f=>{const r=await worker.fetch(f.request('?intent=transcription','wrong-fixture-token'),f.env);assert.equal(r.status,401);assert.equal(f.calls.length,0);});
await fixture(async f=>{const r=await worker.fetch(f.request('?intent=transcription&model=gpt-4o'),f.env);assert.equal(r.status,400);assert.equal(f.calls.length,0);});
await fixture(async f=>{f.fetchFailure=true;const r=await worker.fetch(f.request(),f.env);assert.equal(r.status,502);assert.deepEqual(await r.json(),{error:'upstream error'});});
await fixture(async f=>{await relayTranscription(f.request(),f.env);f.socket.message({type:'input_audio_buffer.append',audio:Buffer.alloc(4800).toString('base64')});assert.equal(f.remote.sent.length,0);assert.equal(f.remote.closes[0].code,1008);assert.equal(f.timers.size,0);});
await fixture(async f=>{await relayTranscription(f.request(),f.env);f.socket.message(session);f.socket.message({type:'input_audio_buffer.commit'});assert.equal(f.remote.sent.length,1);assert.equal(f.socket.closes[0].code,1008);});
await fixture(async f=>{await relayTranscription(f.request(),f.env);f.fire(10000);assert.equal(f.remote.closes[0].code,1011);assert.equal(f.timers.size,0);});
await fixture(async f=>{await relayTranscription(f.request(),f.env);f.configure();f.fire(50*60*1000);assert.equal(f.remote.closes[0].code,1000);assert.equal(f.timers.size,0);});
await fixture(async f=>{await relayTranscription(f.request(),f.env);f.configure();f.socket.message(session);assert.equal(f.socket.closes[0].code,1008);});
await fixture(async f=>{await relayTranscription(f.request(),f.env);f.configure();f.remote.failSend=true;f.socket.message({type:'input_audio_buffer.commit',event_id:'c1'});assert.equal(f.socket.closes.length,1);assert.equal(f.remote.closes.length,1);});
await fixture(async f=>{await relayTranscription(f.request(),f.env);f.configure();f.remote.message({type:'error',error:{code:'credit_balance_exhausted',message:'must-not-forward',event_id:'c1'}});assert.equal(f.socket.sent.at(-1).error.code,'credit_balance_exhausted');assert.equal(JSON.stringify(f.socket.sent).includes('must-not-forward'),false);assert.equal(f.remote.closes.length,1);});
await fixture(async f=>{await relayTranscription(f.request(),f.env);f.configure();f.remote.emit('error');assert.equal(f.socket.closes[0].code,1011);assert.equal(f.timers.size,0);});
await fixture(async f=>{await relayTranscription(f.request(),f.env);f.configure();for(let i=0;i<101;i++)f.socket.message({type:'input_audio_buffer.clear',event_id:'clear-'+i});assert.ok(f.socket.closes.length);assert.ok(f.remote.sent.length<=17);});
await fixture(async f=>{await relayTranscription(f.request(),f.env);f.configure();for(let i=0;i<100;i++){f.socket.message({type:'input_audio_buffer.clear',event_id:'clear-'+i});if(!f.socket.closes.length)f.remote.message({type:'input_audio_buffer.cleared'});}assert.equal(f.socket.closes[0].code,1008);assert.equal(f.remote.sent.length,100);});
await fixture(async f=>{await relayTranscription(f.request(),f.env);f.configure();for(let i=0;i<5;i++)f.socket.message({type:'input_audio_buffer.append',audio:Buffer.alloc(48000).toString('base64'),event_id:'a'+i});assert.equal(f.socket.closes[0].code,1008);assert.equal(f.remote.sent.length,5);});
await fixture(async f=>{await relayTranscription(f.request(),f.env);f.configure();const audio=Buffer.alloc(48000).toString('base64');for(let i=0;i<34;i++){f.advance(1000);f.socket.message({type:'input_audio_buffer.append',audio,event_id:'a'+i});}assert.equal(f.socket.closes[0].code,1008);assert.equal(f.remote.sent.length,33);});
await fixture(async f=>{await relayTranscription(f.request(),f.env);f.configure();const audio=Buffer.alloc(48000).toString('base64');for(let i=0;i<80;i++){f.advance(1000);f.socket.message({type:'input_audio_buffer.append',audio,event_id:'a'+i});f.socket.message({type:'input_audio_buffer.commit',event_id:'c'+i});f.remote.message({type:'input_audio_buffer.committed',item_id:'item-'+i,previous_item_id:i?'item-'+(i-1):null});}assert.equal(f.socket.closes.length,0);assert.equal(f.socket.sent.at(-1).item_id,'item-79');});
await fixture(async f=>{await relayTranscription(f.request(),f.env);f.configure();f.socket.message({type:'input_audio_buffer.append',audio:Buffer.alloc(4800).toString('base64')});f.socket.message({type:'input_audio_buffer.clear'});f.remote.message({type:'input_audio_buffer.cleared'});assert.equal(f.socket.closes.length,0);});
await fixture(async f=>{await relayTranscription(f.request(),f.env);f.configure();f.remote.message({type:'input_audio_buffer.committed',item_id:'unexpected',previous_item_id:null});assert.equal(f.socket.closes[0].code,1011);});
await fixture(async f=>{await relayTranscription(f.request(),f.env);f.configure();f.remote.message({type:'conversation.item.input_audio_transcription.delta',item_id:'i1',content_index:0,delta:'Hola'});f.remote.message({type:'conversation.item.input_audio_transcription.completed',item_id:'i1',content_index:0,transcript:'Hola'});assert.equal(f.socket.sent.at(-2).delta,'Hola');assert.equal(f.socket.sent.at(-1).transcript,'Hola');});
for(const [status,code,type,expected] of [[429,'credit_balance_exhausted','insufficient_quota',429],[429,'slow_down','insufficient_quota',429],[403,'permission_denied','invalid_request_error',403],[401,'invalid_api_key','invalid_request_error',403],[500,'unknown','server_error',502]]) {
  await fixture(async f=>{f.fetchResult=new RealResponse(JSON.stringify({error:{code,type,message:'must-not-forward'}}),{status});const r=await worker.fetch(f.request(),f.env);assert.equal(r.status,expected);const p=await r.json();assert.equal(p.error.code,code==='unknown'?'transcription_unavailable':code);assert.equal(p.error.type,type);assert.equal(JSON.stringify(p).includes('must-not-forward'),false);assert.equal(f.timers.size,0);});
}
await fixture(async f=>{f.fetchResult=new RealResponse(JSON.stringify({error:{code:'credit_balance_exhausted',message:'x'.repeat(20000)}}),{status:429});const r=await worker.fetch(f.request(),f.env);assert.equal((await r.json()).error.code,'rate_limit_exceeded');});
await fixture(async f=>{f.fetchResult=new RealResponse(JSON.stringify({error:{code:'unknown',type:'insufficient_quota'}}),{status:429});const r=await worker.fetch(f.request(),f.env);assert.deepEqual((await r.json()).error,{code:'transcription_unavailable',type:'insufficient_quota'});});
await fixture(async f=>{f.env.RATE={get:async()=> '120',put:async()=>assert.fail('must not write when limited')};const r=await worker.fetch(f.request(),f.env);assert.equal(r.status,429);assert.equal(f.calls.length,0);});
await fixture(async f=>{f.fetchResult=new RealResponse('{"ok":true}',{headers:{'Content-Type':'application/json'}});const r=await worker.fetch(new Request('https://fixture.invalid/v1/chat/completions',{method:'POST',headers:{Authorization:'Bearer fixture-team-token','Content-Type':'application/json','X-Fixture-Private':'not-forwarded'},body:JSON.stringify({model:'gpt-6-luna',messages:[]})}),f.env);assert.equal(r.status,200);assert.equal(f.calls[0].url,'https://api.openai.com/v1/chat/completions');assert.equal(f.calls[0].options.headers.get('Authorization'),'Bearer fixture-upstream-key');assert.equal(f.calls[0].options.headers.get('X-Fixture-Private'),null);});
console.log(`${n} offline transcription relay checks passed`);
