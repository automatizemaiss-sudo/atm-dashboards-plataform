import test from 'node:test';
import assert from 'node:assert/strict';
import {eligible,normalizePhone,rate} from '../lib/domain.ts';
test('bloqueio explícito exclui; ausência de informação permite',()=>{assert.equal(eligible({can_receive_campaigns:false}),false);assert.equal(eligible({can_receive_campaigns:true}),true);assert.equal(eligible({can_receive_campaigns:null}),true)});
test('telefone converge para chave única',()=>{assert.equal(normalizePhone('(83) 99999-1234'),'+5583999991234');assert.equal(normalizePhone('+55 83 99999-1234'),'+5583999991234');assert.throws(()=>normalizePhone('1234'))});
test('taxa sem denominador não informa zero',()=>{assert.equal(rate(0,0),'—');assert.equal(rate(1,4),'25.0%')});
