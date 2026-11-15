import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {PGlite} from '@electric-sql/pglite';
test('connection status restricts writes and isolates organization reads',async()=>{
 const db=new PGlite();
 try{
 await db.exec(`create role anon;create role authenticated;create role service_role;create schema auth;create function auth.uid() returns uuid language sql stable as $$select null::uuid$$;create table whatsapp_instances(id uuid primary key,organization_id uuid);create function is_member(org uuid) returns boolean language sql stable as $$select org='11111111-1111-1111-1111-111111111111'::uuid$$;grant select on whatsapp_instances to authenticated;`);
 await db.exec(readFileSync('supabase/migrations/021_whatsapp_connection.sql','utf8'));
 await db.exec(`insert into whatsapp_instances values('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','11111111-1111-1111-1111-111111111111'),('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','22222222-2222-2222-2222-222222222222');set role service_role;select record_whatsapp_connection('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','disconnected');select record_whatsapp_connection('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','connected');`);
 await assert.rejects(db.exec(`select record_whatsapp_connection('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','invalid')`));
 await db.exec(`select record_whatsapp_connection('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','connected');set role authenticated;`);
 const result=await db.query<{status:string}>('select * from whatsapp_connection_status');assert.equal(result.rows.length,1);assert.equal(result.rows[0].status,'connected');
 await assert.rejects(db.exec(`select record_whatsapp_connection('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','disconnected')`));
 await assert.rejects(db.exec(`update whatsapp_connection_status set status='disconnected'`));
 }finally{await db.close()}
});
test('monitor persists every observation independently of WhatsApp notification throttling',()=>{
 const flow=JSON.parse(readFileSync('integrations/n8n/07-monitorar-conexao.json','utf8'));
 const branches=flow.connections['Consultar instância monitorada'].main[0].map((n:{node:string})=>n.node);
 assert.deepEqual(branches,['Verificar conexão','Salvar conexão no dashboard']);
 const verify=flow.nodes.find((n:{name:string})=>n.name==='Verificar conexão');
 const state={lastAlertAt:Date.now()};
 const run=(status:string)=>new Function('$input','$getWorkflowStaticData',verify.parameters.jsCode)({first:()=>({json:{status}})},()=>state);
 assert.deepEqual(run('connected'),[]);assert.equal(state.lastAlertAt,0);assert.equal(run('disconnected').length,1);
});
