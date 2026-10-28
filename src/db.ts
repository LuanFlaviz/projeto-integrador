// Conexão com o MySQL. Usamos um "pool": um grupo de conexões reaproveitadas,
// em vez de abrir e fechar uma conexão a cada requisição.
import mysql from 'mysql2/promise';
import { config } from './config';
import { deslocamentoUtc } from './datas';
import { traduzirErroMysql } from './errors';

export const pool = mysql.createPool({
  host: config.banco.host,
  port: config.banco.porta,
  user: config.banco.usuario,
  password: config.banco.senha,
  database: config.banco.nome,
  charset: 'utf8mb4',
  waitForConnections: true,
  connectionLimit: 10,
   decimalNumbers: true, // DECIMAL chega como número (e não como texto "25.0000")
  dateStrings: true, //    DATETIME chega como texto, sem o JavaScript mexer no fuso
  ssl: config.banco.ssl ? { rejectUnauthorized: false } : undefined, // o Aiven exige conexão criptografada
});

// Toda conexão nova usa o mesmo fuso do app, para o NOW() e os DEFAULT CURRENT_TIMESTAMP
// do banco combinarem com as datas que o navegador manda (veja datas.ts).
pool.pool.on('connection', (conexao) => {
  conexao.query(`SET time_zone = '${deslocamentoUtc(config.fusoHorario)}'`);
});

// Consulta simples (SELECT). Os "?" são trocados pelos valores de forma segura —
// nunca monte SQL concatenando texto vindo do usuário.
export async function consultar<T>(sql: string, parametros: unknown[] = []): Promise<T[]> {
  const [linhas] = await pool.query(sql, parametros);
  return linhas as T[];
}

// Chama uma stored procedure que tem parâmetros OUT (p_resultado, p_produto_id...).
//
// O driver não devolve parâmetros OUT diretamente. O jeito é:
//   1) CALL nome(?, ?, @saida1, @saida2)   -> o MySQL guarda as saídas em variáveis de sessão
//   2) SELECT @saida1, @saida2             -> lemos essas variáveis
// Os dois passos precisam rodar na MESMA conexão, por isso o getConnection().
export async function chamarProcedure(
  nome: string,
  entradas: unknown[],
  saidas: string[],
): Promise<Record<string, any>> {
  const conexao = await pool.getConnection();
  try {
    const marcadores = [...entradas.map(() => '?'), ...saidas.map((s) => `@${s}`)].join(', ');
    await conexao.query(`CALL ${nome}(${marcadores})`, entradas);

    const colunas = saidas.map((s) => `@${s} AS ${s}`).join(', ');
    const [linhas] = await conexao.query(`SELECT ${colunas}`);
    return (linhas as Record<string, any>[])[0];
  } catch (erro) {
    throw traduzirErroMysql(erro);
  } finally {
    conexao.release();
  }
}
