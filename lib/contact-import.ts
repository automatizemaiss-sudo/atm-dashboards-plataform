import {normalizePhone} from './domain.ts';
export function parseCSV(text:string):string[][] {
 const source=text.replace(/^\uFEFF/,'');
 const first=source.split(/\r?\n/)[0];
 const delimiter=[',',';','\t'].sort((a,b)=>first.split(b).length-first.split(a).length)[0];
 const rows:string[][]=[];let row:string[]=[],cell='',quoted=false;
 for(let i=0;i<source.length;i++) {const c=source[i];
  if(c==='"'){if(quoted&&source[i+1]==='"'){cell+='"';i++;}else quoted=!quoted;}
  else if(!quoted&&(c===delimiter||c==='\n'||c==='\r')){row.push(cell.trim());cell='';if(c!==delimiter){if(c==='\r'&&source[i+1]==='\n')i++;if(row.some(Boolean))rows.push(row);row=[];}}
  else cell+=c;
 }
 if(quoted)throw new Error('CSV com aspas não fechadas.');
 row.push(cell.trim());if(row.some(Boolean))rows.push(row);
 if(rows.length<2)throw new Error('O arquivo precisa ter cabeçalho e contatos.');
 if(rows[0].some(h=>!h)||new Set(rows[0]).size!==rows[0].length)throw new Error('Use cabeçalhos preenchidos e únicos.');
 if(rows.slice(1).some(r=>r.length!==rows[0].length))throw new Error('Existem linhas com quantidade de colunas diferente do cabeçalho.');
 if(rows.length>2001)throw new Error('Limite de 2000 linhas por arquivo.');
 return rows;
}
export function prepareContacts(rows:string[][],name:number,phone:number,label:number,fallback:string,mapping:Record<string,string>){
 const contacts=new Map<string,{name:string;phone:string;tags:string[]}>();const errors:string[]=[];
 rows.forEach((r,i)=>{try{const number=normalizePhone(r[phone]??'');const person=(r[name]??'').trim()||number;
 const labels=(label<0?fallback:r[label]??'').split(/[;,|\n]/).map(v=>v.trim()).filter(Boolean);
 const tags=labels.map(v=>mapping[v]?.trim()).filter((v):v is string=>Boolean(v));
 const previous=contacts.get(number);contacts.set(number,{name:previous?.name??person,phone:number,tags:[...new Set([...(previous?.tags??[]),...tags])]});
 }catch{errors.push(`Linha ${i+2}: telefone inválido (${r[phone]??''}).`);}});
 return {contacts:[...contacts.values()],errors,duplicates:rows.length-contacts.size-errors.length};
}
export function downloadCSV(filename:string,rows:string[][]){
 const csv='\uFEFF'+rows.map(r=>r.map(v=>'"'+(/^[=+@-]/.test(v)?"'":'')+v.replaceAll('"','""')+'"').join(';')).join('\r\n');
 const url=URL.createObjectURL(new Blob([csv],{type:'text/csv;charset=utf-8'}));const a=document.createElement('a');a.href=url;a.download=filename;a.click();URL.revokeObjectURL(url);
}
