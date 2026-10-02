import type { Metadata } from 'next';
import './globals.css';
export const metadata:Metadata={title:'FUTPB — Dashboard',description:'Gestão de clientes e campanhas FUTPB',icons:{icon:'/futpb-logo.png'}};
export default function Layout({children}:{children:React.ReactNode}) {return <html lang="pt-BR"><body>{children}</body></html>}
