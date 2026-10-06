// Prepara o ambiente de teste: usa o banco de TESTE (.env.test) e nunca o de verdade.
// Este arquivo precisa ser o PRIMEIRO import do teste, antes de qualquer código da API.
import dotenv from 'dotenv';

process.env.NODE_ENV = 'test';
dotenv.config({ path: '.env.test', override: true, quiet: true });

if (!process.env.DB_NAME?.endsWith('_teste')) {
  throw new Error('Segurança: os testes só rodam em um banco cujo nome termina com "_teste". Veja o .env.test.');
}
