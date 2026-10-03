import type {Metadata} from 'next';
import RegistrationForm from '../../components/registration-form';
export const metadata:Metadata={title:'Sorteio — FUTPB',description:'Cadastre-se no sorteio da FUTPB e conte para nós qual camisa você gostaria de ganhar.'};
export default function Page(){return <RegistrationForm/>;}
