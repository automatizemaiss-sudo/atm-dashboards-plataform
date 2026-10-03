import test from 'node:test';
import assert from 'node:assert/strict';
import {validateRegistration} from '../lib/registration.ts';
const data={submission_id:'11111111-1111-1111-1111-111111111111',name:' Maria ',phone:'(42) 99988-3017',desired_shirt:'Barcelona',teams:'Barcelona; Palmeiras; Barcelona',size:'M',birthday:'1990-01-01',has_purchased:false,has_referrals:null,can_receive_campaigns:false};
test('formulário normaliza contato e mantém autorização explícita',()=>{
 const v=validateRegistration(data,'2026-10-03');assert.equal(v.name,'Maria');assert.equal(v.phone,'+5542999883017');assert.deepEqual(v.teams,['Barcelona','Palmeiras']);assert.equal(v.can_receive_campaigns,false);
});
test('formulário rejeita campos obrigatórios, datas impossíveis e opções inválidas',()=>{
 for(const patch of [{name:''},{phone:'123'},{teams:';'},{birthday:'2026-02-30'},{birthday:'2026-10-04'},{size:'errado'},{has_purchased:null},{can_receive_campaigns:undefined},{submission_id:'bad'}])assert.throws(()=>validateRegistration({...data,...patch},'2026-10-03'));
});
