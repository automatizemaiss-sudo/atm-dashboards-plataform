import {normalizePhone} from './domain.ts';
export function validateRegistration(input:unknown,today=new Intl.DateTimeFormat('sv-SE',{timeZone:'America/Sao_Paulo'}).format(new Date())){
 if(!input||typeof input!=='object')throw new Error('Dados inválidos.');
 const data=input as Record<string,unknown>;
 const text=(key:string,max:number)=>{if(typeof data[key]!=='string')throw new Error('Preencha os campos obrigatórios.');const v=data[key].trim();if(!v||v.length>max)throw new Error('Confira os campos obrigatórios e o tamanho dos textos.');return v;};
 const name=text('name',150),phone=normalizePhone(text('phone',30)),desired_shirt=text('desired_shirt',200);
 const teams=[...new Set(text('teams',500).split(/[;,\n]/).map(v=>v.trim()).filter(Boolean))];if(!teams.length||teams.length>20||teams.some(v=>v.length>100))throw new Error('Informe os times separados por ponto e vírgula (;) ou vírgula (,).');
 const size=text('size',5);if(!['P','M','G','GG','XG'].includes(size))throw new Error('Selecione um tamanho válido.');
 const birthday=text('birthday',10);if(!/^\d{4}-\d{2}-\d{2}$/.test(birthday))throw new Error('Informe a data completa do aniversário.');
 const date=new Date(birthday+'T00:00:00Z');if(Number.isNaN(date.getTime())||date.toISOString().slice(0,10)!==birthday||birthday<'1900-01-01'||birthday>today)throw new Error('Confira a data do aniversário.');
 if(typeof data.has_purchased!=='boolean')throw new Error('Informe se já comprou com a FUTPB.');
 const purchase_intent=data.purchase_intent??null;
 if(purchase_intent!==null&&typeof purchase_intent!=='boolean')throw new Error('Resposta de intenção de compra inválida.');
 const purchase_details=purchase_intent===true?text('purchase_details',500):null;
 if(typeof data.can_receive_campaigns!=='boolean')throw new Error('Permissão de mensagens inválida.');
 const submission_id=text('submission_id',36);if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(submission_id))throw new Error('Recarregue a página e tente novamente.');
 return {submission_id,name,phone,desired_shirt,teams,size,birthday,has_purchased:data.has_purchased,has_referrals:null,purchase_intent,purchase_details,can_receive_campaigns:data.can_receive_campaigns};
}
