export type Customer = {id:string; version:number; name:string; phone:string; size:string|null; desired_shirt:string|null; birthday:string|null; has_purchased:boolean|null; can_receive_campaigns:boolean|null; has_referrals:boolean|null; total_spent:number|null; order_count:number|null; last_purchase_at:string|null; created_at:string; updated_at:string; customer_teams?:{teams:{name:string}}[]};
export type Rule = {field:string; op:'eq'|'gte'|'lte'|'contains'; value:string|number|boolean};
export type Rules = {operator:'and'|'or'; conditions:(Rule|Rules)[]};
export function normalizePhone(value:string) {let n=value.replace(/\D/g,''); if(n.length===10||n.length===11)n='55'+n; if(!/^55\d{10,11}$/.test(n))throw new Error('Informe telefone brasileiro com DDD.'); return '+'+n;}
export function eligible(customer:Pick<Customer,'can_receive_campaigns'>) {return customer.can_receive_campaigns !== false;}
export function rate(part:number,total:number) {return total ? `${(part/total*100).toFixed(1)}%` : '—';}
