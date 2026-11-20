// Public service smoke checks. Uses the isolated QA dataset, never customer counts.
import assert from 'node:assert/strict';
const origin='https://lantern-vnc-mac.fts227.chatgpt.site';
const visitorId=crypto.randomUUID();
async function request(path,options={}) {
 const r=await fetch(origin+path,{...options,signal:AbortSignal.timeout(30000),redirect:'manual'});
 return r;
}
for(const [path,extra] of [['/api/events',{type:'visit',path:'/lantern-vnc/',referrer:'https://qa.example/'}],['/api/poll',{usefulness:'yes',intent:'maybe'}],['/api/feedback',{kind:'thanks',message:'QA ONLY: GitHub runner deployment smoke test. Not customer feedback.'}]]) {
 const body={dataset:'qa',eventId:crypto.randomUUID(),visitorId,...extra};
 const options={method:'POST',headers:{Origin:'https://py-killer.github.io','Content-Type':'application/json'},body:JSON.stringify(body)};
 for(let i=0;i<2;i++){const r=await request(path,options);assert.equal(r.status,200,`${path}: ${r.status} ${await r.clone().text()}`);const result=await r.json();assert.equal(result.ok,true);if(path==='/api/feedback')assert.equal(result.id,body.eventId);}
 console.log('PASS',path,'QA acknowledgment and safe retry');
}
for(const path of ['/api/stats','/api/inbox'])for(const headers of [{},{'oai-authenticated-user-email':'forged-owner@example.test'}]){
 const r=await request(path,{headers});assert.equal(r.status,403,`${path} must reject anonymous/forged identity`);console.log('PASS private endpoint',path);
}
const admin=await request('/admin');assert.equal(admin.status,302);assert.ok(admin.headers.get('location').includes('/signin-with-chatgpt'));
console.log('PASS owner dashboard requires sign-in');
