// Included in Code nodes by generate-sync.cjs. No credentials in this module.
const HEADERS=['Nome Completo','Telefone','Camisa Desejado Sorteio','Time(s)','Tamanho','Data de aniversário','Já comprou?','Aceita Mensagens?','ID Cliente','Versão Sync','Possui Indicações?','Total Comprado','Número de Pedidos','Última Compra','Excluído?','Tipos de camisa'];
function numeric(value,integer=false){
 const raw=String(value??'').trim(); if(!raw)return null;
 const normalized=raw.includes(',')?raw.replace(/\./g,'').replace(',','.'):raw;
 const n=Number(normalized);if(!Number.isFinite(n)||n<0||(integer&&!Number.isInteger(n)))throw new Error('Valor de compra/pedidos inválido.');return n;
}
function purchaseDate(value){const v=String(value??'').trim();if(!v)return null;return birthdayValue(v);}
function parseGrid(grid){
 if(!Array.isArray(grid)||!grid.length)throw new Error('Planilha sem cabeçalhos.');
 const headerNames=grid[0].slice(0,16).map(h=>String(h).trim());
 headerNames[2]=headerNames[2]==='Camisa Preferida'?'Camisa Desejado Sorteio':headerNames[2];
 headerNames[5]=headerNames[5]==='Data'?'Data de aniversário':headerNames[5];
 if(headerNames.join('|')!==HEADERS.join('|'))throw new Error('Cabeçalhos diferentes. Confira A1:P1 no guia de sincronização.');
 if(grid.length>=10001)throw new Error('Limite de leitura atingido; ampliar/paginar antes de sincronizar.');
 const phones=new Set(),ids=new Set();
 return grid.slice(1).flatMap((cells,index)=>{
  if(!cells.some(v=>String(v??'').trim()))return [];
  const row=Object.fromEntries(HEADERS.map((h,i)=>[h,cells[i]??'']));
  let normalized;try{normalized=normalizeRow(row)}catch(e){throw new Error(`Linha ${index+2}: ${e.message}`)}
  const allowedTypes={jogador:'Jogador',torcedor:'Torcedor',retro:'Retrô',feminina:'Feminina'};
  const shirt_types=[...new Set(String(row['Tipos de camisa']).split(/[;,\n]/).map(v=>v.trim()).filter(Boolean).map(v=>{const key=v.normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase();const canonical=allowedTypes[key];if(!canonical)throw new Error(`Linha ${index+2}: tipo de camisa inválido: ${v}. Use Jogador, Torcedor, Retrô ou Feminina.`);return canonical;}))].sort();
  const value={shirt_types,...normalized.customer,archived:booleanValue(row['Excluído?'],'Excluído?')===true,has_referrals:booleanValue(row['Possui Indicações?'],'Possui Indicações?'),total_spent:numeric(row['Total Comprado']),order_count:numeric(row['Número de Pedidos'],true),last_purchase_at:purchaseDate(row['Última Compra']),teams:normalized.teams.sort()};delete value.last_update_source;
  const id=String(row['ID Cliente']).trim();
  if(id&&!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id))throw new Error(`Linha ${index+2}: ID Cliente inválido.`);
  if(phones.has(value.phone))throw new Error(`Telefone duplicado na linha ${index+2}.`);phones.add(value.phone);
  if(id&&ids.has(id))throw new Error(`ID Cliente duplicado na linha ${index+2}.`);if(id)ids.add(id);
  return [{customer_id:id||null,row_number:index+2,value,cells}];
 });
}
function stable(value){if(Array.isArray(value))return JSON.stringify(value);if(value&&typeof value==='object')return JSON.stringify(Object.fromEntries(Object.keys(value).sort().map(k=>[k,value[k]])));return JSON.stringify(value);}
function booleanCell(v){return v===null?'':v?'Sim':'Não';}
function sheetCells(w){const v=w.value;return [v.name,v.phone,v.desired_shirt??'',(v.teams??[]).join('; '),v.size??'',v.birthday??'',booleanCell(v.has_purchased),booleanCell(v.can_receive_campaigns),w.customer_id,String(w.version),booleanCell(v.has_referrals),v.total_spent??'',v.order_count??'',v.last_purchase_at??'',booleanCell(v.archived??false),(v.shirt_types??[]).join('; ')];}
function guardedWrites(plan,grid){
 const latest=parseGrid(grid),data=[];let nextRow=grid.length+1;
 for(const w of plan.writes){
  let matches=latest.filter(r=>r.customer_id===w.customer_id);
  if(!matches.length&&w.expected!==null)matches=latest.filter(r=>!r.customer_id&&r.value.phone===w.expected.phone);
  if(matches.length>1)throw new Error('Identidade duplicada antes da gravação.');
  const existing=matches[0];
  if(w.expected===null){if(existing){if(stable(existing.value)!==stable(w.value))throw new Error('Linha criada durante o processamento; executar novamente.');}else if(latest.some(r=>r.value.phone===w.value.phone))throw new Error('Telefone apareceu na planilha durante o processamento; executar novamente.');}
  else if(!existing||stable(existing.value)!==stable(w.expected))throw new Error('Planilha alterada durante o processamento; nenhuma gravação foi preparada. Aguarde o lease expirar e execute novamente.');
  const values=sheetCells(w),row=existing?.row_number??nextRow++;
  if(!existing||stable(values)!==stable(HEADERS.map((_,i)=>existing.cells[i]??'')))data.push({range:`'Página1'!A${row}:P${row}`,values:[values]});
 }
 return {run_id:plan.run_id,has_writes:data.length>0,body:{valueInputOption:'RAW',data},conflicts:plan.conflicts};
}
module.exports={HEADERS,parseGrid,guardedWrites,sheetCells};
