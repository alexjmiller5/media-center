import {expect,test} from 'bun:test';
import {resolve} from 'node:path';

// Explicit development checkouts. No installed user state or credentials.
const life=process.env.CONTRACT_LIFE_DATA;
const synapse=process.env.CONTRACT_SYNAPSE;
const python=process.env.CONTRACT_PYTHON;
if(!life||!synapse||!python)throw Error('Set CONTRACT_LIFE_DATA, CONTRACT_SYNAPSE and CONTRACT_PYTHON to dependency checkouts/interpreter');
const {default:worker}=await import(resolve(life,'worker/src/index.js'));
const {captureGateway}=await import(resolve(life,'worker/src/capture-gateway.js'));
const {D1Shim}=await import(resolve(life,'worker/test/d1shim.js'));
const {ensureAuthReady,hashToken}=await import(resolve(life,'worker/src/auth.js'));

test('native-shaped capture crosses gateway, resolver and real hub without losing user state',async()=>{
 const DB=new D1Shim(),AUTH_DB=new D1Shim();
 DB.db.exec(`
 CREATE TABLE articles(id TEXT PRIMARY KEY,title TEXT,status TEXT,saved INTEGER DEFAULT 0,note TEXT,tags TEXT,date_read TEXT,created_at TEXT,updated_at TEXT,deleted_at TEXT,hub_at TEXT);
 CREATE TABLE catalog_tables(id TEXT PRIMARY KEY,kind TEXT,deleted_at TEXT);
 INSERT INTO catalog_tables VALUES('articles','table',NULL);
 CREATE TABLE catalog_properties(id TEXT PRIMARY KEY,tbl TEXT,col TEXT,type TEXT,required INTEGER,sort INTEGER,options TEXT,options_sql TEXT,ref_table TEXT,derived_by TEXT,inputs TEXT,deleted_at TEXT);
 CREATE TABLE catalog_rules(id TEXT PRIMARY KEY,tbl TEXT,col TEXT,kind TEXT,enforce INTEGER,scope TEXT,sql TEXT,text TEXT,deleted_at TEXT);
 CREATE TABLE history(id TEXT PRIMARY KEY,tbl TEXT,row_id TEXT,col TEXT,old TEXT,new TEXT,origin TEXT,created_at TEXT,updated_at TEXT,deleted_at TEXT,hub_at TEXT);
 CREATE TABLE provenance(id TEXT PRIMARY KEY,to_kind TEXT,to_ref TEXT,field TEXT,from_kind TEXT,from_ref TEXT,rel TEXT,asserted_by TEXT,inputs_hash TEXT,value_hash TEXT,produced_at TEXT,updated_at TEXT,deleted_at TEXT,hub_at TEXT);
 INSERT INTO catalog_properties(id,tbl,col,type) VALUES ('articles.title','articles','title','text'),('articles.saved','articles','saved','bool'),('articles.status','articles','status','text');
 `);
 await ensureAuthReady(AUTH_DB);
 AUTH_DB.db.query('INSERT INTO _tokens(hash,name,scopes) VALUES (?,?,?)').run(await hashToken('synthetic-writer'),'writer','tables:read:articles,tables:write:articles');
 let race:string|undefined,dropReply=false,writes=0;
 const insertExisting=(id:string,deleted:string|null=null)=>DB.db.query('INSERT INTO articles(id,title,status,note,tags,updated_at,hub_at,deleted_at) VALUES (?,?,?,?,?,?,?,?)').run(id,'Original','Finished','Keep this','["kept"]','2026-01-01T00:00:00.000Z','2026-01-01T00:00:00.000Z',deleted);
 const server=Bun.serve({hostname:'127.0.0.1',port:0,async fetch(request){
  const path=new URL(request.url).pathname;
  if(path.endsWith('/insert')&&race){insertExisting(race);race=undefined;}
  const response=await worker.fetch(request,{DB,AUTH_DB,HUB_TOKEN:'synthetic-root'},{waitUntil(){}});
  if(path.endsWith('/patch')||path.endsWith('/insert')){writes++;if(dropReply){dropReply=false;return new Response('unavailable',{status:503});}}
  return response;
 }});
 const child=Bun.spawn([resolve(python),resolve(import.meta.dir,'capture_service.py'),server.url.href],{cwd:synapse,env:{PATH:process.env.PATH!,PYTHONPATH:resolve(synapse,'src'),PYTHONUNBUFFERED:'1'},stdin:'pipe',stdout:'pipe',stderr:'pipe'});
 const reader=child.stdout.getReader();let pending='';
 const adapter=async(_url:string,init:RequestInit)=>{
  child.stdin.write(String(init.body)+'\n');await child.stdin.flush();
  while(!pending.includes('\n')){const part=await reader.read();if(part.done)throw Error(await new Response(child.stderr).text());pending+=new TextDecoder().decode(part.value);}
  const end=pending.indexOf('\n'),result=JSON.parse(pending.slice(0,end));pending=pending.slice(end+1);
  return Response.json(result.body,{status:result.status});
 };
 const env={CAPTURE_ADAPTERS:JSON.stringify({media:{url:'https://resolver.test/capture',credential:'synthetic-gateway',fields:{saved:['tables:patch:articles:saved'],status:['tables:patch:articles:status']}}})};
 const tenant={hash:'device-one',scopes:['captures:read:media','captures:submit:media','tables:patch:articles:saved','tables:patch:articles:status']};
 let seq=0;
 const submit=async(url:string,text=false)=>{
  const request_id=`11111111-1111-4111-8111-${String(++seq).padStart(12,'0')}`;
  const payload={request_id,input:text?{text:url}:{url},intent:'save'};
  const make=()=>new Request('https://hub.test/v1/captures/media',{method:'POST',body:JSON.stringify(payload)});
  const result=await captureGateway(make(),tenant,env,adapter);expect(result.status).toBe(202);
  const get=()=>new Request('https://hub.test/v1/captures/media/'+request_id);
  const receipt=await (await captureGateway(get(),tenant,env,adapter)).json();
  return {receipt,make,get,payload};
 };
 const row=(id:string)=>DB.db.query('SELECT * FROM articles WHERE id=?').get(id);
 try{
  const fresh=await submit('https://example.test/new');expect(fresh.receipt.state).toBe('saved');expect(row('https://example.test/new').saved).toBe(1);
  const before=writes;expect((await captureGateway(fresh.make(),tenant,env,adapter)).status).toBe(200);expect(writes).toBe(before);
  expect((await captureGateway(fresh.get(),{...tenant,hash:'other-device'},env,adapter)).status).toBe(404);
  const changed=new Request('https://hub.test/v1/captures/media',{method:'POST',body:JSON.stringify({...fresh.payload,intent:'record_consumption'})});
  expect((await captureGateway(changed,tenant,env,adapter)).status).toBe(409);
  for(const racing of [false,true]){
   const url='https://example.test/'+(racing?'racing':'existing');if(racing)race=url;else insertExisting(url);
   expect((await submit(url)).receipt.state).toBe('saved');expect(row(url)).toMatchObject({status:'Finished',saved:1,note:'Keep this',tags:'["kept"]'});
  }
  const feature='https://www.google.com/chrome/whats-new/archive/#feature-one';insertExisting(feature);
  const capturedFeature=await submit(feature);expect(capturedFeature.receipt.item.id).toBe(feature);expect(row(feature)).toMatchObject({status:'Finished',saved:1,note:'Keep this'});expect(row('https://www.google.com/chrome/whats-new/archive')).toBeNull();
  const outage=await submit('https://example.test/resolver-outage');expect(outage.receipt.state).toBe('uncertain');
  await captureGateway(outage.make(),tenant,env,adapter);expect((await (await captureGateway(outage.get(),tenant,env,adapter)).json()).state).toBe('saved');
  const deleted='https://example.test/deleted';insertExisting(deleted,'2026-01-02');expect((await submit(deleted)).receipt.state).toBe('needs_review');expect(row(deleted).saved).toBe(0);
  const writeCount=writes;expect((await submit('make a task',true)).receipt.state).toBe('needs_review');expect(writes).toBe(writeCount);
  dropReply=true;const lost=await submit('https://example.test/lost');expect(lost.receipt.state).toBe('uncertain');const afterLost=writes;
  await captureGateway(lost.make(),tenant,env,adapter);expect((await (await captureGateway(lost.get(),tenant,env,adapter)).json()).state).toBe('saved');expect(writes).toBe(afterLost);
 }finally{child.stdin.end();await child.exited;await server.stop(true);DB.db.close();AUTH_DB.db.close();}
},30000);
