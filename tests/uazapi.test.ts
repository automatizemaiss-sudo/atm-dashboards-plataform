import test from 'node:test';
import assert from 'node:assert/strict';
import {connectionView,instanceConfig} from '../lib/uazapi.ts';

test('connection response excludes provider secrets and clears QR after connecting',()=>{
 const result=connectionView({instance:{status:'connected',token:'secret',qrcode:'data:image/png;base64,YQ=='},status:{jid:{user:'5511999999999'}},admintoken:'secret'});
 assert.equal(result.phone,'5511999999999');assert.equal(result.qrcode,null);
 assert.equal('token' in result,false);assert.equal(JSON.stringify(result).includes('secret'),false);
});
test('only PNG data URIs can be displayed as QR codes',()=>{
 for(const qrcode of ['https://example.com/tracker','data:image/svg+xml;base64,YQ==','javascript:alert(1)'])assert.equal(connectionView({instance:{status:'connecting',qrcode}}).qrcode,null);
 assert.equal(connectionView({instance:{status:'connecting',qrcode:'data:image/png;base64,YQ=='}}).qrcode,'data:image/png;base64,YQ==');
 assert.throws(()=>connectionView({instance:{status:'unexpected'}}));assert.throws(()=>connectionView(null));
});
test('credentials are selected only from configured instance IDs and require HTTPS',()=>{
 const raw=JSON.stringify({local:{url:'https://example.uazapi.com',token:'private'}});
 assert.deepEqual(instanceConfig('local',raw),{url:'https://example.uazapi.com',token:'private'});
 assert.equal(instanceConfig('other',raw),null);assert.equal(instanceConfig('__proto__',raw),null);
 for(const url of ['http://example.com','https://user:pass@example.com','https://example.com/path'])assert.throws(()=>instanceConfig('local',JSON.stringify({local:{url,token:'private'}})));
});
