// Ponto de entrada: confere o banco e começa a escutar na porta.
import { criarApp } from './app';
import { config } from './config';
import { pool } from './db';

async function iniciar() {
  try {
    await pool.query('SELECT 1');
  } catch (erro) {
    const e = erro as { code?: string; message?: string };
    console.error(`\nNão consegui conectar ao MySQL (${config.banco.host}:${config.banco.porta}, banco "${config.banco.nome}").`);
    console.error(`Motivo: ${e.code ?? e.message}`);
    console.error('Confira o arquivo .env (DB_HOST, DB_USER, DB_PASSWORD, DB_NAME) e se o MySQL está rodando.');
    process.exit(1);
  }

  const servidor = criarApp().listen(config.porta, () => {
    console.log(`API no ar: http://localhost:${config.porta}/api/saude`);
  });

  // Ctrl+C: termina as requisições em andamento e fecha as conexões.
  const encerrar = () => {
    servidor.close(async () => {
      await pool.end();
      process.exit(0);
    });
  };
  process.on('SIGINT', encerrar);
  process.on('SIGTERM', encerrar);
}

void iniciar();
