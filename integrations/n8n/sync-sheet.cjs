// Included in Code nodes by generate-sync.cjs. No credentials in this module.
const HEADERS=['Nome Completo','Telefone','Camisa Desejado Sorteio','Time(s)','Tamanho','Data de aniversário','Já comprou?','Aceita Mensagens?','ID Cliente','Versão Sync','Possui Indicações?','Total Comprado','Número de Pedidos','Última Compra','Excluído?','Tipos de camisa'];
function numeric(value,integer=false){
 const raw=String(value??'').trim(); if(!raw)return null;
 const normalized=raw.includes(',')?raw.replace(/\./g,'').replace(',','.'):raw;
 const n=Number(normalized);if(!Number.isFinite(n)||n<0||(integer&&!Number.isInteger(n)))throw new Error('Valor de compra/pedidos inválido.');return n;
}
function purchaseDate(value){
 const v=String(value??'').trim();if(!v)return null;
 let year,month,day;
 let match=/^(\d{4})-(\d{2})-(\d{2})$/.exec(v);
 if(match){year=+match[1];month=+match[2];day=+match[3];}
 else {
  match=/^(\d{1,2})\/(\d{1,2})\/(\d{2}|\d{4})$/.exec(v);
  if(!match)throw new Error('Última Compra: use DD/MM/AAAA, DD/MM/AA ou AAAA-MM-DD.');
  day=+match[1];month=+match[2];year=+match[3];
 }
 // Anos abreviados de compra pertencem a 2000–2099, inclusive 0026 vindo do Sheets.
 if(year<100)year+=2000;
 const date=new Date(Date.UTC(year,month-1,day));
 if(year<1900||date.getUTCFullYear()!==year||date.getUTCMonth()!==month-1||date.getUTCDate()!==day)
  throw new Error('Última Compra: data inválida.');
 if(date.toISOString().slice(0,10)>new Intl.DateTimeFormat('sv-SE',{timeZone:'America/Sao_Paulo'}).format(new Date()))throw new Error('Última Compra: a data não pode estar no futuro.');
 return date.toISOString().slice(0,10);
}
function rowIdentity(cells){
 const customer_id=String(cells[8]??'').trim();
 let phone=String(cells[1]??'').replace(/\D/g,'');
 if(phone.length===10||phone.length===11)phone='55'+phone;
 return {customer_id:customer_id||null,phone:/^55\d{10,11}$/.test(phone)?'+'+phone:null};
}
function parseGrid(grid,issues=null){
 if(!Array.isArray(grid)||!grid.length)throw new Error('Planilha sem cabeçalhos.');
 const headerNames=grid[0].slice(0,16).map(h=>String(h).trim());
 headerNames[2]=headerNames[2]==='Camisa Preferida'?'Camisa Desejado Sorteio':headerNames[2];
 headerNames[5]=headerNames[5]==='Data'?'Data de aniversário':headerNames[5];
 if(headerNames.join('|')!==HEADERS.join('|'))throw new Error('Cabeçalhos diferentes. Confira A1:P1 no guia de sincronização.');
 if(grid.length>=10001)throw new Error('Limite de leitura atingido; ampliar/paginar antes de sincronizar.');
 // Count identities before validation: every duplicate stays out, including the first row.
 const phones=new Map(),ids=new Map();
 for(const cells of grid.slice(1)){
  if(!cells.some(v=>String(v??'').trim()))continue;
  const identity=rowIdentity(cells);
  if(identity.phone)phones.set(identity.phone,(phones.get(identity.phone)??0)+1);
  if(identity.customer_id)ids.set(identity.customer_id.toLowerCase(),(ids.get(identity.customer_id.toLowerCase())??0)+1);
 }
 return grid.slice(1).flatMap((cells,index)=>{
  if(!cells.some(v=>String(v??'').trim()))return [];
  const row=Object.fromEntries(HEADERS.map((h,i)=>[h,cells[i]??'']));
  const identity=rowIdentity(cells);
  try{
   if(identity.phone&&phones.get(identity.phone)>1)throw new Error('Telefone duplicado na planilha.');
   if(identity.customer_id&&ids.get(identity.customer_id.toLowerCase())>1)throw new Error('ID Cliente duplicado na planilha.');
   const normalized=normalizeRow(row);
   const allowedTypes={jogador:'Jogador',torcedor:'Torcedor',retro:'Retrô',feminina:'Feminina',nba:'NBA',infantil:'Infantil'};
   const shirt_types=[...new Set(String(row['Tipos de camisa']).split(/[;,\n]/).map(v=>v.trim()).filter(Boolean).map(v=>{const key=v.normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase();const canonical=allowedTypes[key];if(!canonical)throw new Error(`Tipo de camisa inválido: ${v}. Use Jogador, Torcedor, Retrô, Feminina, NBA ou Infantil.`);return canonical;}))].sort();
   const value={shirt_types,...normalized.customer,archived:booleanValue(row['Excluído?'],'Excluído?')===true,has_referrals:booleanValue(row['Possui Indicações?'],'Possui Indicações?'),total_spent:numeric(row['Total Comprado']),order_count:numeric(row['Número de Pedidos'],true),last_purchase_at:purchaseDate(row['Última Compra']),teams:normalized.teams.sort()};delete value.last_update_source;
   const id=identity.customer_id;
   if(id&&!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id))throw new Error('ID Cliente inválido.');
   return [{customer_id:id?.toLowerCase()||null,row_number:index+2,value,cells}];
  }catch(e){
   if(!issues)throw new Error(`Linha ${index+2}: ${e.message}`);
   const message=e.message;
   const field=message.includes('Última Compra')?'Última Compra':/aniversário/i.test(message)?'Data de aniversário':/telefone/i.test(message)?'Telefone':/ID Cliente/.test(message)?'ID Cliente':/tipo de camisa/i.test(message)?'Tipos de camisa':/Nome Completo/.test(message)?'Nome Completo':HEADERS.find(h=>message.startsWith(h+':'))??'Cadastro';
   issues.push({row_number:index+2,contact_name:row['Nome Completo'],...identity,field,value:field==='Cadastro'?null:String(row[field]??''),message});
   return [];
  }
 });
}
function validateGrid(grid){
 const issues=[];
 try{const rows=parseGrid(grid,issues);return {rows,issues,valid:issues.length===0,can_sync:true};}
 catch(e){return {rows:[],issues:[{row_number:1,contact_name:null,field:'Estrutura da planilha',value:null,message:e.message}],valid:false,can_sync:false};}
}
function stable(value){if(Array.isArray(value))return JSON.stringify(value);if(value&&typeof value==='object')return JSON.stringify(Object.fromEntries(Object.keys(value).sort().map(k=>[k,value[k]])));return JSON.stringify(value);}
function booleanCell(v){return v===null?'':v?'Sim':'Não';}
function sheetCells(w){const v=w.value;return [v.name,v.phone,v.desired_shirt??'',(v.teams??[]).join('; '),v.size??'',v.birthday??'',booleanCell(v.has_purchased),booleanCell(v.can_receive_campaigns),w.customer_id,String(w.version),booleanCell(v.has_referrals),v.total_spent??'',v.order_count??'',v.last_purchase_at??'',booleanCell(v.archived??false),(v.shirt_types??[]).join('; ')];}
function guardedWrites(plan,grid){
 const report=validateGrid(grid);
 if(!report.can_sync)throw new Error(report.issues[0].message);
 const latest=report.rows,data=[];let nextRow=grid.length+1;
 const rawIdentities=grid.slice(1).map(rowIdentity);
 const blocked=w=>report.issues.some(i=>(i.customer_id&&i.customer_id.toLowerCase()===w.customer_id.toLowerCase())||(i.phone&&(i.phone===w.value.phone||i.phone===w.expected?.phone)));

 for(const w of plan.writes){
  // A planned contact becoming invalid after reconciliation requires a new plan/ACK.
  if(blocked(w))throw new Error('Cadastro planejado ficou inválido antes da gravação; execute novamente para registrar a pendência.');
  let matches=latest.filter(r=>r.customer_id===w.customer_id);
  if(!matches.length&&w.expected!==null)matches=latest.filter(r=>!r.customer_id&&r.value.phone===w.expected.phone);
  if(matches.length>1)throw new Error('Identidade duplicada antes da gravação.');
  const existing=matches[0];
  if(w.expected===null){if(existing){if(stable(existing.value)!==stable(w.value))throw new Error('Linha criada durante o processamento; executar novamente.');}else if(rawIdentities.some(r=>r.phone===w.value.phone||r.customer_id?.toLowerCase()===w.customer_id.toLowerCase()))throw new Error('Telefone apareceu na planilha durante o processamento; executar novamente.');}
  else if(!existing||stable(existing.value)!==stable(w.expected))throw new Error('Planilha alterada durante o processamento; nenhuma gravação foi preparada. Aguarde o lease expirar e execute novamente.');
  const values=sheetCells(w),row=existing?.row_number??nextRow++;
  if(!existing||stable(values)!==stable(HEADERS.map((_,i)=>existing.cells[i]??'')))data.push({range:`'Página1'!A${row}:P${row}`,values:[values]});
 }
 return {run_id:plan.run_id,has_writes:data.length>0,body:{valueInputOption:'RAW',data},conflicts:plan.conflicts};
}
module.exports={HEADERS,parseGrid,validateGrid,guardedWrites,sheetCells};
