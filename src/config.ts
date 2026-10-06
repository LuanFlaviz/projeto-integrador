// Lê as configurações do arquivo .env (veja o .env.example).
// Centralizar tudo aqui evita espalhar process.env pelo projeto.
import dotenv from 'dotenv';

dotenv.config({ quiet: true });

function numero(nome: string, padrao: number): number {
  const bruto = process.env[nome];
  if (bruto === undefined || bruto === '') return padrao;

  const valor = Number(bruto);
  if (!Number.isFinite(valor)) {
    throw new Error(`A variável ${nome} do .env precisa ser um número (valor atual: "${bruto}").`);
  }
  return valor;
}

export const config = {
  porta: numero('PORT', 3000),

  // Quem pode chamar a API a partir de outro endereço (ex.: o front aberto
  // pelo Live Server em http://127.0.0.1:5500). "*" libera todos — ótimo
  // para desenvolver, troque pelo endereço real em produção.
  corsOrigin: process.env.CORS_ORIGIN || '*',

  // Pasta com painel.html, estoque.html e produto.html. Se existir, o próprio
  // backend entrega essas páginas. Se não existir, ele só responde a API.
  pastaFrontend: process.env.FRONTEND_DIR || 'public',

  // Fuso usado para gravar as datas que o navegador manda (dataEventoCliente)
  // e para o NOW() do banco. Os dois precisam concordar, senão o histórico
  // mistura horários.
  fusoHorario: process.env.APP_TIMEZONE || 'America/Cuiaba',

  banco: {
    host: process.env.DB_HOST || 'localhost',
    porta: numero('DB_PORT', 3306),
    usuario: process.env.DB_USER || 'root',
    senha: process.env.DB_PASSWORD ?? '',
    nome: process.env.DB_NAME || 'luana_salgadinhos',
  },
};
