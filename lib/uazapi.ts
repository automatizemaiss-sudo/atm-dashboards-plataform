// Only return fields needed by the connection screen; provider payloads contain secrets.
export function connectionView(raw: unknown) {
 const data=raw as {instance?:{status?:string;qrcode?:string};status?:{jid?:{user?:string}}};
 const status=data?.instance?.status;
 if(!status||!['connected','connecting','disconnected','hibernated'].includes(status))throw new Error('Resposta de conexão inválida.');
 const qr=data.instance?.qrcode;
 const qrcode=status==='connecting'&&typeof qr==='string'&&/^data:image\/png;base64,[A-Za-z0-9+/=\r\n]+$/.test(qr)?qr:null;
 const phone=data.status?.jid?.user;
 return {status,qrcode,phone:status==='connected'&&typeof phone==='string'&&/^\d{10,15}$/.test(phone)?phone:null,checked_at:new Date().toISOString()};
}
export function instanceConfig(id:string,raw=process.env.UAZAPI_INSTANCES) {
 if(!raw)return null;
 const configs=JSON.parse(raw) as Record<string,{url:string;token:string}>;
 const config=Object.hasOwn(configs,id)?configs[id]:null;
 if(!config)return null;
 const url=new URL(config.url);
 if(url.protocol!=='https:'||url.username||url.password||url.pathname!=='/'||url.search||url.hash||!config.token)throw new Error('Configuração Uazapi inválida.');
 return {url:url.origin,token:config.token};
}
