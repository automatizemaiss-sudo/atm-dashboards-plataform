// Included by generate-sales.cjs. No credentials.
const HEADERS=['ID Venda','Referência','ID Contato','Contato','Telefone','ID Campanha','Campanha','Valor','Data da Venda','Observações','Cancelada?','Versão Sync'];
function uuid(value,label,required=false){const v=String(value??'').trim().toLowerCase();if(!v&&!required)return null;if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(v))throw new Error(label+': ID inválido.');return v;}
function parseGrid(grid){
 if(!Array.isArray(grid)||!grid.length||grid[0].slice(0,12).map(v=>String(v).trim()).join('|')!==HEADERS.join('|'))throw new Error('Confira os cabeçalhos Vendas!A1:L1.');
 if(grid.length>=10001)throw new Error('Limite de leitura de vendas atingido.');
 const references=new Set(),ids=new Set();
 return grid.slice(1).flatMap((cells,index)=>{
 if(!cells.some(v=>String(v??'').trim()))return [];
 try{
 const reference=String(cells[1]??'').trim();if(!reference)throw new Error('Referência obrigatória.');if(references.has(reference))throw new Error('Referência duplicada.');references.add(reference);
 const sale_id=uuid(cells[0],'ID Venda');if(sale_id&&ids.has(sale_id))throw new Error('ID Venda duplicado.');if(sale_id)ids.add(sale_id);
 const raw=String(cells[7]??'').trim();const amount=raw?Number(raw.includes(',')?raw.replace(/\./g,'').replace(',','.'):raw):null;if(amount!==null&&(!Number.isFinite(amount)||amount<0||Math.abs(amount*100-Math.round(amount*100))>1e-7))throw new Error('Valor inválido.');
 const value={reference,customer_id:uuid(cells[2],'ID Contato',true),campaign_id:uuid(cells[5],'ID Campanha'),amount,purchased_on:birthdayValue(cells[8]),notes:String(cells[9]??'').trim()||null,voided:booleanValue(cells[10],'Cancelada?')===true};
 return [{sale_id,row_number:index+2,value,cells}];
 }catch(e){throw new Error(`Vendas, linha ${index+2}: ${e.message}`)}
 });
}
function stable(value){return JSON.stringify(value&&typeof value==='object'&&!Array.isArray(value)?Object.fromEntries(Object.keys(value).sort().map(k=>[k,value[k]])):value);}
function sheetCells(w){const v=w.value,l=w.labels??{};return [w.sale_id,v.reference,v.customer_id,l.contact_name??'',l.phone??'',v.campaign_id??'',l.campaign_name??'',v.amount??'',v.purchased_on??'',v.notes??'',v.voided?'Sim':'Não',String(w.version)];}
function guardedWrites(plan,grid){
 const rows=parseGrid(grid),data=[];let next=grid.length+1;
 for(const w of plan.writes){
 let matches=rows.filter(r=>r.sale_id===w.sale_id);if(!matches.length)matches=rows.filter(r=>!r.sale_id&&r.value.reference===w.value.reference);
 if(matches.length>1)throw new Error('Venda duplicada antes da gravação.');const existing=matches[0];
 if(w.expected===null){if(existing&&stable(existing.value)!==stable(w.value))throw new Error('Venda inserida durante a execução.');if(!existing&&rows.some(r=>r.value.reference===w.value.reference))throw new Error('Referência apareceu durante a execução.');}
 else if(!existing||stable(existing.value)!==stable(w.expected))throw new Error('Venda alterada durante a sincronização; aguarde a reserva expirar e tente novamente.');
 const row=existing?.row_number??next++,values=sheetCells(w);if(!existing||stable(values)!==stable(HEADERS.map((_,i)=>existing.cells[i]??'')))data.push({range:`'Vendas'!A${row}:L${row}`,values:[values]});
 }
 return {run_id:plan.run_id,has_writes:data.length>0,body:{valueInputOption:'RAW',data},conflicts:plan.conflicts};
}
module.exports={HEADERS,parseGrid,sheetCells,guardedWrites};
