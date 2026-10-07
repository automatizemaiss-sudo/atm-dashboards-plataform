import test from 'node:test';
import assert from 'node:assert/strict';
import {validateRegistration} from '../lib/registration.ts';
const data={submission_id:'11111111-1111-1111-1111-111111111111',name:' Maria ',phone:'(42) 99988-3017',desired_shirt:'Barcelona',teams:'Barcelona; Palmeiras; Barcelona',size:'M',birthday:'1990-01-01',has_purchased:false,purchase_intent:false,has_referrals:null,can_receive_campaigns:false};
test('formulário normaliza contato e mantém autorização explícita',()=>{
 const v=validateRegistration(data,'2026-10-03');assert.equal(v.name,'Maria');assert.equal(v.phone,'+5542999883017');assert.deepEqual(v.teams,['Barcelona','Palmeiras']);assert.equal(v.can_receive_campaigns,false);
});
test('formulário rejeita campos obrigatórios, datas impossíveis e opções inválidas',()=>{
 for(const patch of [{name:''},{phone:'123'},{teams:';'},{birthday:'2026-02-30'},{birthday:'2026-10-04'},{size:'errado'},{has_purchased:null},{can_receive_campaigns:undefined},{submission_id:'bad'}])assert.throws(()=>validateRegistration({...data,...patch},'2026-10-03'));
});

test('times aceitam vírgula e ponto e vírgula juntos',()=>{
 assert.deepEqual(validateRegistration({...data,teams:'Barcelona, Real Madrid; Barcelona,,;'},'2026-10-03').teams,['Barcelona','Real Madrid']);
});
test('intenção de compra exige detalhes apenas quando a resposta é sim',()=>{
 const result=validateRegistration({...data,purchase_intent:true,purchase_details:' Barcelona I 2026/27, em dezembro '});
 assert.equal(result.purchase_intent,true);assert.equal(result.purchase_details,'Barcelona I 2026/27, em dezembro');assert.equal(result.has_referrals,null);
 for(const purchase_details of ['',undefined,'a'.repeat(501)])assert.throws(()=>validateRegistration({...data,purchase_intent:true,purchase_details}));
 assert.throws(()=>validateRegistration({...data,purchase_intent:'sim'}));
 assert.equal(validateRegistration({...data,purchase_intent:false,purchase_details:'antigo'}).purchase_details,null);
});

test('formulário aceita tamanhos ampliados e exige intenção Sim ou Não',()=>{
 for(const size of ['3XL','4XL','Infantil 2','Infantil 4','Infantil 6','Infantil 8','Infantil 10','Infantil 12','Infantil 14','Infantil 16'])assert.equal(validateRegistration({...data,size}).size,size);
 for(const purchase_intent of [null,undefined,''])assert.throws(()=>validateRegistration({...data,purchase_intent}));
});
