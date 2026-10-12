import {expect,test} from 'bun:test';
import {mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';

// Explicit development checkouts. No installed user state or credentials.
const soma=process.env.CONTRACT_SOMA;
const python=process.env.CONTRACT_PYTHON;
if(!soma||!python)throw Error('Set CONTRACT_SOMA to a Soma checkout and CONTRACT_PYTHON to a Python with the poller dependencies');
const {default:worker}=await import(resolve(soma,'worker/src/index.js'));
const {D1Shim}=await import(resolve(soma,'worker/test/d1shim.js'));
const {ensureAuthReady,hashToken}=await import(resolve(soma,'worker/src/auth.js'));
const {enrollmentProfile}=await import(resolve(soma,'worker/src/enrollment-profile.js'));
const profiles=await Bun.file(resolve(import.meta.dir,'../../docs/poller-profile.json')).json();
const [profileId]=Object.keys(profiles);

const at='2026-10-01T00:00:00.000Z';
const columns:Record<string,string>={
 tv_shows:'title TEXT,status TEXT,follow INTEGER,feed_since TEXT,franchise_id TEXT,franchise_order INTEGER,saved INTEGER DEFAULT 0',
 tv_episodes:'show_id TEXT,season INTEGER,episode INTEGER,title TEXT,air_date TEXT,runtime_min INTEGER,status TEXT,saved INTEGER DEFAULT 0',
 youtube_channels:'title TEXT,uploads_playlist_id TEXT,backfilled INTEGER DEFAULT 0,follow INTEGER,feed_since TEXT',
 youtube_videos:'channel_id TEXT,title TEXT,published_at TEXT,duration_s INTEGER,thumbnail_url TEXT,is_short INTEGER,status TEXT,saved INTEGER DEFAULT 0',
 feeds:'title TEXT,fetch TEXT,scrape_pattern TEXT,follow INTEGER,feed_since TEXT',
 articles:'feed_id TEXT,title TEXT,published_at TEXT,content TEXT,status TEXT,saved INTEGER DEFAULT 0',
 provenance:'to_kind TEXT,to_ref TEXT,field TEXT,from_kind TEXT,from_ref TEXT,rel TEXT,detail TEXT,asserted_by TEXT,inputs_hash TEXT,value_hash TEXT,produced_at TEXT',
 history:'tbl TEXT,row_id TEXT,col TEXT,old TEXT,new TEXT,origin TEXT',
};
const status='[{"v":"Not Started"},{"v":"Finished"}]';
// [table, column, type, required, options, ref table, derived by]
const properties:(string|number|null)[][]=[
 ['tv_shows','title','text',null,null,null,'http:tmdb_tv'],['tv_shows','status','select',1,status,null,null],
 ['tv_shows','follow','bool',null,null,null,null],['tv_shows','feed_since','datetime',null,null,null,null],
 ['tv_shows','franchise_id','text',null,null,null,null],['tv_shows','franchise_order','int',null,null,null,null],
 ['tv_episodes','show_id','ref',1,null,'tv_shows',null],['tv_episodes','season','int',1,null,null,null],
 ['tv_episodes','episode','int',1,null,null,null],['tv_episodes','title','text',null,null,null,null],
 ['tv_episodes','air_date','date',null,null,null,null],['tv_episodes','runtime_min','int',null,null,null,null],
 ['tv_episodes','status','select',1,status,null,null],['tv_episodes','saved','bool',null,null,null,null],
 ['youtube_channels','uploads_playlist_id','text',null,null,null,null],['youtube_channels','backfilled','bool',1,null,null,null],
 ['youtube_channels','follow','bool',1,null,null,null],['youtube_channels','feed_since','datetime',null,null,null,null],
 ['youtube_videos','channel_id','ref',1,null,'youtube_channels',null],['youtube_videos','published_at','datetime',null,null,null,null],
 ['youtube_videos','duration_s','int',null,null,null,null],['youtube_videos','is_short','bool',null,null,null,null],
 ['youtube_videos','status','select',1,status,null,null],['youtube_videos','saved','bool',null,null,null,null],
 ['feeds','fetch','select',1,'[{"v":"rss"}]',null,null],['feeds','follow','bool',1,null,null,null],
 ['feeds','feed_since','datetime',null,null,null,null],
 ['articles','feed_id','ref',null,null,'feeds',null],['articles','published_at','datetime',null,null,null,null],
 ['articles','content','json',null,null,null,null],['articles','status','select',1,status,null,null],
 ['articles','saved','bool',null,null,null,null],
 ['provenance','from_kind','select',1,'[{"v":"tv_shows"},{"v":"youtube_channels"},{"v":"feeds"}]',null,null],
 ['provenance','to_kind','select',1,null,null,null],['provenance','from_ref','text',1,null,null,null],
 ['provenance','to_ref','text',1,null,null,null],['provenance','field','text',null,null,null,null],
 ['provenance','rel','select',1,'[{"v":"imported_from"},{"v":"evidence_of"},{"v":"derived_from"}]',null,null],
 ['provenance','detail','json',null,null,null,null],['provenance','asserted_by','text',1,null,null,null],
];
// Soma's origin option queries, which the narrow edge check admits exactly.
const originOptions={
 from_kind:"SELECT DISTINCT derived_by FROM catalog_properties WHERE derived_by IS NOT NULL AND deleted_at IS NULL",
 to_kind:"SELECT name FROM sqlite_master WHERE type = 'table' AND substr(name, 1, 1) != '_' AND name NOT LIKE 'catalog!_%' ESCAPE '!' AND name NOT LIKE 'sqlite%' AND name != 'provenance'",
};

function hubDb() {
 const DB=new D1Shim();
 DB.db.exec(`CREATE TABLE catalog_tables(id TEXT PRIMARY KEY,kind TEXT,deleted_at TEXT);
  CREATE TABLE catalog_properties(id TEXT PRIMARY KEY,tbl TEXT,col TEXT,type TEXT,sort INTEGER,required INTEGER,options TEXT,options_sql TEXT,ref_table TEXT,default_value TEXT,derived_by TEXT,inputs TEXT,deleted_at TEXT);
  CREATE TABLE catalog_rules(id TEXT PRIMARY KEY,tbl TEXT,col TEXT,kind TEXT,enforce INTEGER,scope TEXT,sql TEXT,text TEXT,deleted_at TEXT);`);
 for(const [table,cols] of Object.entries(columns)){
  DB.db.exec(`CREATE TABLE "${table}"(id TEXT PRIMARY KEY,${cols},created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),deleted_at TEXT,hub_at TEXT);
   CREATE TRIGGER "${table}_updated_at" AFTER UPDATE ON "${table}" FOR EACH ROW WHEN NEW.updated_at = OLD.updated_at BEGIN UPDATE "${table}" SET updated_at = (strftime('%Y-%m-%dT%H:%M:%fZ','now')) WHERE rowid = NEW.rowid; END`);
  if(table!=='history')DB.db.query("INSERT INTO catalog_tables VALUES (?,'table',NULL)").run(table);
 }
 const property=DB.db.query('INSERT INTO catalog_properties(id,tbl,col,type,required,options,ref_table,derived_by,inputs) VALUES (?,?,?,?,?,?,?,?,?)');
 for(const [t,c,type,required,options,ref,derived] of properties)property.run(`${t}.${c}`,t,c,type,required,options,ref,derived,derived?'["id"]':null);
 for(const [col,sql] of Object.entries(originOptions))DB.db.query('UPDATE catalog_properties SET options_sql=? WHERE id=?').run(sql,`provenance.${col}`);
 // A confined enforced invariant, like the estate's source tables carry.
 DB.db.query("INSERT INTO catalog_rules(id,tbl,kind,enforce,scope,sql) VALUES ('franchise-order','tv_shows','invariant',1,'table',?)")
  .run('SELECT id FROM changed WHERE deleted_at IS NULL AND franchise_order IS NOT NULL AND (franchise_id IS NULL OR franchise_order < 1)');
 const row=(table:string,values:Record<string,unknown>)=>{
  const all={...values,updated_at:at,hub_at:at},keys=Object.keys(all);
  DB.db.query(`INSERT INTO "${table}"(${keys.join(',')}) VALUES (${keys.map(()=>'?').join(',')})`).run(...Object.values(all) as any[]);
 };
 row('tv_shows',{id:'show1',title:'Show',status:'Not Started',follow:1});
 row('youtube_channels',{id:'UC1',uploads_playlist_id:'UU1',backfilled:1,follow:1});
 row('feeds',{id:'https://feed.test/rss',fetch:'rss',follow:1});
 const items=[['tv_episodes','tv_shows','show_id','show1','ep'],['youtube_videos','youtube_channels','channel_id','UC1','vid'],
  ['articles','feeds','feed_id','https://feed.test/rss','https://feed.test/a']];
 for(const [table,source,parent,owner,prefix] of items){
  for(const kind of ['linked','unlinked'])row(table,{id:`${prefix}-${kind}`,[parent]:owner,status:'Finished',title:'Kept',
   ...(table==='tv_episodes'?{season:1,episode:kind==='linked'?1:2}:{})});
  // The poller's older three-part edge id, which stays as stored.
  row('provenance',{id:`${source}:${owner}:${prefix}-linked`,from_kind:source,from_ref:owner,to_kind:table,to_ref:`${prefix}-linked`,
   rel:'imported_from',detail:'{"created_row":1}',asserted_by:'script:media-center'});
 }
 // Another writer's edge inside the poller's ID range.
 row('provenance',{id:'tv_shows:show1:title',from_kind:'http:tmdb_tv',from_ref:'tmdb:tv/show1',to_kind:'tv_shows',to_ref:'show1',rel:'derived_from',asserted_by:'hub'});
 return DB;
}

test('the poller profile authorizes every poller call without duplicating stored edges',async()=>{
 const profile=await enrollmentProfile({ENROLLMENT_PROFILES:JSON.stringify(profiles)},profileId);
 expect(profile?.scopes).toEqual([...profiles[profileId].scopes].sort());
 const DB=hubDb(),AUTH_DB=new D1Shim();
 await ensureAuthReady(AUTH_DB);
 const mint=async(token:string,scopes:string[])=>AUTH_DB.db.query('INSERT INTO _tokens(hash,name,scopes) VALUES (?,?,?)').run(await hashToken(token),token,scopes.join(','));
 await mint('synthetic-poller',profiles[profileId].scopes);
 await mint('synthetic-broad',['tables:read','tables:write']);
 const calls:{token:string,path:string,tables:string[],status:number}[]=[];
 const server=Bun.serve({hostname:'127.0.0.1',port:0,async fetch(request){
  const body=JSON.parse(await request.clone().text());
  const response=await worker.fetch(request,{DB,AUTH_DB,HUB_TOKEN:'synthetic-root'},{waitUntil(){}});
  calls.push({token:request.headers.get('authorization')!.slice(7),path:new URL(request.url).pathname,
   tables:body.tables ?? (body.batch ? body.batch.map((b:any)=>b.table) : [body.table]),status:response.status});
  return response;
 }});
 const dir=mkdtempSync(join(tmpdir(),'poller-grants-')),state=join(dir,'hub-cache.json.gz');
 const run=async(token:string,suffix:string)=>{
  calls.length=0;
  const child=Bun.spawn([python,resolve(import.meta.dir,'poller_run.py'),server.url.href.replace(/\/$/,''),token,state,suffix],
   {env:{PATH:process.env.PATH!,PYTHONPATH:resolve(import.meta.dir,'../../src')},stdout:'pipe',stderr:'pipe'});
  const [out,err,code]=await Promise.all([new Response(child.stdout).text(),new Response(child.stderr).text(),child.exited]);
  if(code!==0)throw Error(err);
  return JSON.parse(out);
 };
 const edges=()=>(DB.db.query("SELECT id,from_kind,from_ref,to_kind,to_ref,detail FROM provenance WHERE asserted_by='script:media-center' ORDER BY to_ref").all() as any[])
  .map(e=>({...e,detail:JSON.parse(e.detail)}));
 const legacy=edges();
 const created=(suffix:string,row:number)=>[['tv_shows','show1','tv_episodes','ep'],['youtube_channels','UC1','youtube_videos','vid'],
  ['feeds','https://feed.test/rss','articles','https://feed.test/a']].map(([from,ref,to,prefix])=>({
   id:`${from}:${ref}:${to}:${prefix}-${suffix}`,from_kind:from,from_ref:ref,to_kind:to,to_ref:`${prefix}-${suffix}`,detail:{created_row:row}}));
 const sorted=(rows:any[])=>[...rows].sort((a,b)=>a.to_ref<b.to_ref?-1:1);
 try{
  // Cold state: soma refuses the provenance ID read, so only this run's new items gain edges.
  const cold=await run('synthetic-poller','r1');
  expect(cold.boundaries).toEqual({started:3,conflicts:0,failed:0});
  expect([cold.tv,cold.youtube,cold.feeds].map(k=>[k.failed,k.rejected])).toEqual([[1,0],[1,0],[1,0]]);
  expect([cold.tv.episodes,cold.youtube.videos,cold.feeds.articles]).toEqual([1,1,1]);
  expect(calls.filter(c=>c.status!==200)).toEqual(['tv_shows','youtube_channels','feeds'].map(()=>
   expect.objectContaining({path:'/v1/rows/pull',tables:['provenance'],status:403})));
  expect(edges()).toEqual(sorted([...legacy,...created('r1',1)]));
  // One run with broad reads saves every kind's edge IDs and repairs the older items.
  const seeded=await run('synthetic-broad','r2');
  expect([seeded.tv,seeded.youtube,seeded.feeds].map(k=>k.failed+k.rejected)).toEqual([0,0,0]);
  expect(edges()).toEqual(sorted([...legacy,...created('r1',1),...created('r2',1),
   ...created('unlinked',0)]));
  // Saved edges: the narrow credential needs no provenance read and nothing is refused.
  const warm=await run('synthetic-poller','r3');
  expect([warm.tv,warm.youtube,warm.feeds].map(k=>[k.failed,k.rejected])).toEqual([[0,0],[0,0],[0,0]]);
  expect(calls.length).toBeGreaterThan(0);
  expect(calls.filter(c=>c.status!==200||c.tables.includes('provenance')&&c.path!=='/v1/rows/insert')).toEqual([]);
  expect(edges()).toEqual(sorted([...legacy,...created('r1',1),...created('r2',1),...created('unlinked',0),...created('r3',1)]));
  expect(DB.db.query("SELECT to_ref FROM provenance WHERE asserted_by='script:media-center' GROUP BY to_ref HAVING count(*)>1").all()).toEqual([]);
  // The grants stop there: legacy-shaped edges, provenance reads and source-row pushes are refused.
  const call=(path:string,body:unknown)=>fetch(server.url.href+path.slice(1),{method:'POST',
   headers:{Authorization:'Bearer synthetic-poller'},body:JSON.stringify(body)}).then(r=>r.status);
  const edge={from_kind:'tv_shows',from_ref:'show1',to_kind:'tv_episodes',to_ref:'ep-r3',rel:'imported_from',asserted_by:'script:media-center',updated_at:at};
  expect(await call('/v1/rows/insert',{table:'provenance',columns:['id',...Object.keys(edge)],rows:[{id:'tv_shows:show1:ep-r3',...edge}]})).toBe(403);
  expect(await call('/v1/rows/pull',{batch:[{table:'provenance',columns:['id'],since:'',limit:10}]})).toBe(403);
  expect(await call('/v1/rows/push',{table:'tv_shows',columns:['id','follow','updated_at'],rows:[{id:'show1',follow:0,updated_at:'2026-10-13T00:00:00.000Z'}]})).toBe(403);
 }finally{await server.stop(true);rmSync(dir,{recursive:true,force:true});DB.db.close();AUTH_DB.db.close();}
},60000);
