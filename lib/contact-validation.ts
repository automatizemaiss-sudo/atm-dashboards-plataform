export function todayInBrazil(){return new Intl.DateTimeFormat('sv-SE',{timeZone:'America/Sao_Paulo'}).format(new Date());}
export function validateContactDates(data:{birthday?:unknown;last_purchase_at?:unknown},today=todayInBrazil()){
 for(const [key,label] of [['birthday','Aniversário'],['last_purchase_at','Última compra']] as const){
  const value=data[key];if(value==null||value==='')continue;
  const v=String(value),date=new Date(v+'T00:00:00Z');
  if(!/^\d{4}-\d{2}-\d{2}$/.test(v)||Number.isNaN(date.getTime())||date.toISOString().slice(0,10)!==v||v<'1900-01-01')throw new Error(`${label}: informe uma data válida com ano completo.`);
  if(v>today)throw new Error(`${label}: a data não pode estar no futuro.`);
 }
}
