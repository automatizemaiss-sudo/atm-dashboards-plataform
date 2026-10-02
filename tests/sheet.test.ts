import test from 'node:test';
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
const {normalizeRow,validateRows}=createRequire(import.meta.url)('../integrations/n8n/validate-sheet.cjs');
const row={'Nome Completo':'Teste','Telefone':'(83) 99999-1111','Time(s)':'Barcelona; Corinthians; Barcelona','Aceita Mensagens?':'Não','Data':'15/04/1990','Camisa Preferida':'Barcelona Home'};
test('mapeia múltiplos times, aniversário e camiseta desejada',()=>{const r=normalizeRow(row);assert.deepEqual(r.teams,['Barcelona','Corinthians']);assert.equal(r.can_send,false);assert.equal(r.customer.phone,'+5583999991111');assert.equal(r.customer.birthday,'1990-04-15');assert.equal(r.customer.desired_shirt,'Barcelona Home')});
test('aceite vazio permite; entradas inválidas e duplicatas são reportadas',()=>{assert.equal(normalizeRow({...row,'Aceita Mensagens?':''}).can_send,true);const rows=validateRows([row,row,{...row,Telefone:'123'}]);assert.equal(rows[0].json.valid,true);assert.equal(rows[1].json.valid,false);assert.equal(rows[2].json.valid,false)});

test('datas impossíveis e sem ano não são importadas',()=>{assert.throws(()=>normalizeRow({...row,Data:'31/02/1990'}));assert.throws(()=>normalizeRow({...row,Data:'15/04'}));assert.equal(normalizeRow({...row,Data:''}).customer.birthday,null)});
