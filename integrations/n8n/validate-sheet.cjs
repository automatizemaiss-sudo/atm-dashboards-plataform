// Used by the n8n Code node. Read-only: no API calls or writes.
function booleanValue(value, label) {
  const normalized=String(value ?? '').trim().toLowerCase();
  if(!normalized)return null;
  if(['sim','s','true','1','yes'].includes(normalized))return true;
  if(['não','nao','n','false','0','no'].includes(normalized))return false;
  throw new Error(`${label}: use Sim, Não ou vazio.`);
}
function birthdayValue(value) {
  const v=String(value??'').trim();
  if(!v)return null;
  let year,month,day;
  let match=/^(\d{4})-(\d{2})-(\d{2})$/.exec(v);
  if(match){year=+match[1];month=+match[2];day=+match[3];}
  else {match=/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/.exec(v);if(!match)throw new Error('Data de aniversário: use DD/MM/AAAA ou AAAA-MM-DD.');day=+match[1];month=+match[2];year=+match[3];}
  if(year<1900||year>new Date().getUTCFullYear())throw new Error('Ano de aniversário inválido.');
  const date=new Date(Date.UTC(year,month-1,day));
  if(date.getUTCFullYear()!==year||date.getUTCMonth()!==month-1||date.getUTCDate()!==day||date>new Date())throw new Error('Data de aniversário inválida.');
  return date.toISOString().slice(0,10);
}
function normalizeRow(row){
  const name=String(row['Nome Completo']??'').trim();
  if(!name)throw new Error('Nome Completo obrigatório.');
  let phone=String(row.Telefone??'').replace(/\D/g,'');
  if(phone.length===10||phone.length===11)phone='55'+phone;
  if(!/^55\d{10,11}$/.test(phone))throw new Error('Telefone inválido: use DDD e número.');
  const teams=[...new Set(String(row['Time(s)']??'').split(/[;,\n]/).map(t=>t.trim()).filter(Boolean))];
  return {customer:{name,phone:'+'+phone,size:String(row.Tamanho??'').trim()||null,desired_shirt:String(row['Camisa Desejado Sorteio']??row['Camisa Preferida']??'').trim()||null,birthday:birthdayValue(row['Data de aniversário']??row.Data),has_purchased:booleanValue(row['Já comprou?'],'Já comprou?'),can_receive_campaigns:booleanValue(row['Aceita Mensagens?'],'Aceita Mensagens?'),last_update_source:'google_sheets'},teams,can_send:booleanValue(row['Aceita Mensagens?'],'Aceita Mensagens?')!==false};
}
function validateRows(rows){
 const seen=new Set();
 return rows.map((row,index)=>{
  try{const result=normalizeRow(row);if(seen.has(result.customer.phone))throw new Error('Telefone duplicado nesta leitura.');seen.add(result.customer.phone);return {json:{valid:true,source_row:row.row_number??index+2,...result}};}
  catch(error){return {json:{valid:false,source_row:row.row_number??index+2,error:error.message}};}
 });
}
module.exports={normalizeRow,validateRows,birthdayValue};
