const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const DAYS90=90*86400;
const allowedOrigin = origin => origin === 'https://py-killer.github.io' || /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(origin||'');
export function isOwner(request,env) {
 const email=request.headers.get('oai-authenticated-user-email');
 return !!env.ADMIN_EMAIL && !!email && email.trim().toLowerCase()===env.ADMIN_EMAIL.trim().toLowerCase();
}
function response(value,status=200,origin='') {
 const headers={'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store','X-Content-Type-Options':'nosniff','Vary':'Origin'};
 if(allowedOrigin(origin)){headers['Access-Control-Allow-Origin']=origin;headers['Access-Control-Allow-Methods']='GET, POST, OPTIONS';headers['Access-Control-Allow-Headers']='Content-Type';headers['Access-Control-Max-Age']='600';}
 return new Response(JSON.stringify(value),{status,headers});
}
const bad=(message,status=400)=>Object.assign(new Error(message),{status});
function dataset(value) { if(!['production','qa'].includes(value))throw bad('Invalid dataset.');return value; }
function uuid(value) { if(typeof value!=='string'||!UUID.test(value))throw bad('Invalid request identifier.');return value.toLowerCase(); }
async function hash(value) { return [...new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(value)))].map(x=>x.toString(16).padStart(2,'0')).join(''); }
async function body(request) {
 if(!request.headers.get('content-type')?.toLowerCase().startsWith('application/json'))throw bad('Use application/json.',415);
 const reader=request.body?.getReader();if(!reader)throw bad('Missing message.');let chunks=[],length=0;
 while(true){const {done,value}=await reader.read();if(done)break;length+=value.length;if(length>18000){await reader.cancel();throw bad('Message is too large.',413);}chunks.push(value);}
 const bytes=new Uint8Array(length);let offset=0;for(const c of chunks){bytes.set(c,offset);offset+=c.length;}
 try{const value=JSON.parse(new TextDecoder().decode(bytes));if(!value||Array.isArray(value)||typeof value!=='object')throw 0;return value;}catch{throw bad('Invalid JSON.');}
}
function source(value) {try{const u=new URL(value);if(!['http:','https:'].includes(u.protocol))return 'direct';return ['py-killer.github.io','lantern-vnc-mac.fts227.chatgpt.site'].includes(u.hostname)?'internal':u.hostname.slice(0,100);}catch{return 'direct';}}
function path(value){if(typeof value!=='string')return '/';return value.split(/[?#]/)[0].replace(/[^a-zA-Z0-9/_.-]/g,'').slice(0,150)||'/';}
function campaign(value){return typeof value==='string'?value.replace(/[^a-zA-Z0-9_. -]/g,'').slice(0,80):'';}
async function rows(db,sql,args=[]) {return (await db.prepare(sql).bind(...args).all()).results||[];}
async function count(db,sql,args=[]) {return Number((await db.prepare(sql).bind(...args).first())?.n||0);}
async function limit(db,table,visitor,ds,now,max){const n=await count(db,`SELECT COUNT(*) n FROM ${table} WHERE visitor=? AND dataset=? AND created>=?`,[visitor,ds,now-86400]);if(n>=max)throw bad('Too many submissions. Please try again tomorrow.',429);}
export async function handleApi(request,env) {
 const url=new URL(request.url),origin=request.headers.get('origin')||'';
 const sameOrigin=origin===url.origin;
 if(request.method==='OPTIONS')return allowedOrigin(origin)||sameOrigin?response({ok:true},200,origin):response({error:'Origin not allowed.'},403);
 try{
  if(!env.DB)throw bad('The service is temporarily unavailable.',503);
  if(request.method==='GET' && ['/api/stats','/api/inbox'].includes(url.pathname)){
   if(!isOwner(request,env))throw bad('Owner sign-in required.',403);
   const ds=dataset(url.searchParams.get('dataset')||'production'),now=Math.floor(Date.now()/1000),since=now-DAYS90;
   if(url.pathname==='/api/inbox')return response({items:await rows(env.DB,'SELECT id,kind,message,created,status,github_url FROM feedback WHERE dataset=? ORDER BY created DESC LIMIT 100',[ds])});
   const totals={visits:0,visitors:0,supportClicks:0,downloads:0,responses:0,feedback:0};
   const counts=await rows(env.DB,'SELECT type,COUNT(*) n FROM events WHERE dataset=? AND created>=? GROUP BY type',[ds,since]);
   for(const row of counts){if(row.type==='visit')totals.visits=row.n;if(row.type==='support_open')totals.supportClicks=row.n;if(row.type==='download')totals.downloads=row.n;}
   totals.visitors=await count(env.DB,"SELECT COUNT(DISTINCT visitor) n FROM events WHERE dataset=? AND type='visit' AND created>=?",[ds,since]);
   totals.responses=await count(env.DB,'SELECT COUNT(*) n FROM votes WHERE dataset=?',[ds]);
   totals.feedback=await count(env.DB,'SELECT COUNT(*) n FROM feedback WHERE dataset=?',[ds]);
   const usefulness={yes:0,partly:0,not_yet:0},intent={yes:0,maybe:0,no:0},feedbackKinds={thanks:0,idea:0,bug:0};
   for(const row of await rows(env.DB,'SELECT usefulness,intent,COUNT(*) n FROM votes WHERE dataset=? GROUP BY usefulness,intent',[ds])){usefulness[row.usefulness]+=row.n;intent[row.intent]+=row.n;}
   for(const row of await rows(env.DB,'SELECT kind,COUNT(*) n FROM feedback WHERE dataset=? GROUP BY kind',[ds]))feedbackKinds[row.kind]=row.n;
   const sources=await rows(env.DB,"SELECT source,COUNT(*) visits FROM events WHERE dataset=? AND type='visit' AND created>=? GROUP BY source ORDER BY visits DESC LIMIT 20",[ds,since]);
   const countries=await rows(env.DB,"SELECT country,COUNT(*) visits FROM events WHERE dataset=? AND type='visit' AND created>=? GROUP BY country ORDER BY visits DESC LIMIT 30",[ds,since]);
   const campaigns=await rows(env.DB,"SELECT campaign,COUNT(*) visits FROM events WHERE dataset=? AND type='visit' AND created>=? AND campaign!='' GROUP BY campaign ORDER BY visits DESC LIMIT 20",[ds,since]);
   const daily=await rows(env.DB,"SELECT date(created,'unixepoch') date,COUNT(*) visits FROM events WHERE dataset=? AND type='visit' AND created>=? GROUP BY date ORDER BY date",[ds,since]);
   return response({updatedAt:new Date().toISOString(),windowDays:90,totals,usefulness,intent,feedbackKinds,sources,countries,campaigns,daily});
  }
  if(request.method!=='POST'||!['/api/events','/api/poll','/api/feedback'].includes(url.pathname))throw bad('Not found.',404);
  if(!allowedOrigin(origin)&&!sameOrigin)throw bad('Origin not allowed.',403);
  const b=await body(request),ds=dataset(b.dataset),id=uuid(b.eventId),visitor=await hash(uuid(b.visitorId)),now=Math.floor(Date.now()/1000);
  await env.DB.prepare('DELETE FROM events WHERE created<?').bind(now-DAYS90).run();
  if(url.pathname==='/api/events'){
   if(!['visit','support_open','download'].includes(b.type))throw bad('Invalid event.');
   const existing=await env.DB.prepare('SELECT id FROM events WHERE id=?').bind(id).first();if(existing)return response({ok:true},200,origin);
   await limit(env.DB,'events',visitor,ds,now,500);
   const country=/^[A-Z]{2}$/.test(request.cf?.country||'')?request.cf.country:'unknown';
   await env.DB.prepare('INSERT OR IGNORE INTO events(id,dataset,visitor,type,path,source,country,campaign,created) VALUES(?,?,?,?,?,?,?,?,?)').bind(id,ds,visitor,b.type,path(b.path),campaign(b.campaign?.source)||source(b.referrer),country,campaign(b.campaign?.campaign),now).run();
  } else if(url.pathname==='/api/poll'){
   if(!['yes','partly','not_yet'].includes(b.usefulness)||!['yes','maybe','no'].includes(b.intent))throw bad('Choose both poll answers.');
   await env.DB.prepare('INSERT INTO votes(dataset,visitor,event_id,usefulness,intent,created) VALUES(?,?,?,?,?,?) ON CONFLICT(dataset,visitor) DO UPDATE SET event_id=excluded.event_id,usefulness=excluded.usefulness,intent=excluded.intent,created=excluded.created').bind(ds,visitor,id,b.usefulness,b.intent,now).run();
  }else{
   if(!['thanks','idea','bug'].includes(b.kind)||typeof b.message!=='string'||b.message.trim().length<3||b.message.length>4000)throw bad('Choose a feedback type and write 3–4,000 characters.');
   const existing=await env.DB.prepare('SELECT id FROM feedback WHERE id=? AND dataset=? AND visitor=?').bind(id,ds,visitor).first();if(existing)return response({ok:true,id},200,origin);
   await limit(env.DB,'feedback',visitor,ds,now,10);
   await env.DB.prepare('INSERT INTO feedback(id,dataset,visitor,kind,message,created) VALUES(?,?,?,?,?,?)').bind(id,ds,visitor,b.kind,b.message.trim(),now).run();
   return response({ok:true,id},200,origin);
  }
  return response({ok:true},200,origin);
 }catch(error){return response({error:error.status?error.message:'The service is temporarily unavailable. Please try again.'},error.status||503,origin);}
}
