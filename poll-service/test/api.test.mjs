import {test} from 'node:test';
import assert from 'node:assert/strict';
import {DatabaseSync} from 'node:sqlite';
import {readFileSync,readdirSync} from 'node:fs';
import {handleApi} from '../service/api.mjs';
const db=new DatabaseSync(':memory:');
for(const file of readdirSync('drizzle').filter(f=>f.endsWith('.sql')).sort()) db.exec(readFileSync('drizzle/'+file,'utf8').replaceAll('--> statement-breakpoint',''));
const DB={
 prepare(sql){
  return {bind(...args){
   return {
    async run(){return db.prepare(sql).run(...args);},
    async first(){return db.prepare(sql).get(...args);},
    async all(){return {results:db.prepare(sql).all(...args)};}
   };
  }};
 }
};
const env={DB,ADMIN_EMAIL:'owner@example.test'},visitorId=crypto.randomUUID(),origin='https://py-killer.github.io';
function req(path,body,headers={}){return new Request('https://service.example'+path,body?{method:'POST',headers:{origin,'content-type':'application/json',...headers},body:JSON.stringify(body)}:{headers});}
const base=()=>({dataset:'qa',eventId:crypto.randomUUID(),visitorId});
const owner={'oai-authenticated-user-email':env.ADMIN_EMAIL};
async function stats(){const r=await handleApi(req('/api/stats?dataset=qa',null,owner),env);assert.equal(r.status,200);return r.json();}
test('anonymous metrics are private and bad origins blocked',async()=>{
 assert.equal((await handleApi(req('/api/stats'),env)).status,403);
 assert.equal((await handleApi(req('/api/inbox'),env)).status,403);
 assert.equal((await handleApi(req('/api/events',{...base(),type:'visit'},{origin:'https://evil.test'}),env)).status,403);
 const pre=await handleApi(new Request('https://service.example/api/events',{method:'OPTIONS',headers:{origin}}),env);assert.equal(pre.headers.get('Access-Control-Allow-Origin'),origin);
});
test('idempotent events, source sanitization, anonymous totals',async()=>{
 const event={...base(),type:'visit',path:'/lantern-vnc/?private=secret',referrer:'https://example.com/private?secret=1',campaign:{campaign:'launch'}};
 for(let i=0;i<2;i++)assert.equal((await handleApi(req('/api/events',event),env)).status,200);
 const s=await stats();assert.equal(s.totals.visits,1);assert.equal(s.totals.visitors,1);assert.equal(s.sources[0].source,'example.com');
 const stored=db.prepare('SELECT * FROM events').get();assert.equal(stored.path,'/lantern-vnc/');assert.notEqual(stored.visitor,visitorId);assert.equal(stored.visitor.length,64);assert.ok(!JSON.stringify(stored).includes('secret'));
 const utm={...base(),type:'visit',campaign:{source:'newsletter',campaign:'launch'}};assert.equal((await handleApi(req('/api/events',utm),env)).status,200);assert.ok((await stats()).sources.some(r=>r.source==='newsletter'));
});
test('poll changes replace browser response rather than inflate it',async()=>{
 const b={...base(),usefulness:'yes',intent:'yes'};for(let i=0;i<2;i++)assert.equal((await handleApi(req('/api/poll',b),env)).status,200);
 assert.equal((await handleApi(req('/api/poll',{...base(),usefulness:'partly',intent:'maybe'}),env)).status,200);
 const s=await stats();assert.equal(s.totals.responses,1);assert.equal(s.intent.yes,0);assert.equal(s.intent.maybe,1);
 assert.equal((await handleApi(req('/api/poll',{...base(),usefulness:'?',intent:'yes'}),env)).status,400);
});
test('feedback receipt survives retry; text only in owner inbox',async()=>{
 const b={...base(),kind:'thanks',message:'<script>hello</script>'};for(let i=0;i<2;i++){const r=await handleApi(req('/api/feedback',b),env);assert.equal(r.status,200);assert.equal((await r.json()).id,b.eventId);}
 const s=await stats();assert.equal(s.totals.feedback,1);assert.equal(s.feedbackKinds.thanks,1);assert.ok(!JSON.stringify(s).includes('script'));
 const inbox=await (await handleApi(req('/api/inbox?dataset=qa',null,owner),env)).json();assert.equal(inbox.items[0].message,b.message);
 assert.equal((await handleApi(req('/api/feedback',{...base(),kind:'bug',message:'a'.repeat(4001)}),env)).status,400);
});
test('QA isolated, server errors truthful, oversize rejected',async()=>{
 const production=await (await handleApi(req('/api/stats',null,owner),env)).json();assert.equal(production.totals.visits,0);assert.equal(production.totals.feedback,0);
 assert.equal((await handleApi(req('/api/events',{...base(),type:'visit'}),{})).status,503);
 assert.equal((await handleApi(req('/api/feedback',{...base(),kind:'bug',message:'a'.repeat(20000)}),env)).status,413);
 assert.equal((await handleApi(req('/api/events',{...base(),dataset:'invented',type:'visit'}),env)).status,400);
});
