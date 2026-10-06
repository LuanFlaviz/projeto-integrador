// Regras de acesso ao banco para INGREDIENTES (tela estoque.html).
// O trabalho pesado (transação, histórico, idempotência) está nas procedures do MySQL;
// aqui só traduzimos id -> nome (as procedures trabalham com nome) e montamos a resposta.
import { randomUUID } from 'node:crypto';
import { chamarProcedure, consultar } from '../db';
import { paraDataHoraMysql } from '../datas';
import { ErroApi } from '../errors';
import { UNIDADES, type Sigla } from '../unidades';

export interface Ingrediente {
  id: number;
  nome: string;
  quantidade: number;
  unidade: string;
  quantidadeMinima: number;
  alertaEstoqueBaixo: boolean;
}

type LinhaIngrediente = Omit<Ingrediente, 'alertaEstoqueBaixo'> & { alertaEstoqueBaixo: number };

const SELECT_INGREDIENTE = `
  SELECT ingrediente_id      AS id,
         nome,
         quantidade_atual    AS quantidade,
         unidade_medida      AS unidade,
         quantidade_minima   AS quantidadeMinima,
         alerta_estoque_baixo AS alertaEstoqueBaixo
  FROM vw_estoque_atual`;

function formatar(linha: LinhaIngrediente): Ingrediente {
  return { ...linha, alertaEstoqueBaixo: Boolean(linha.alertaEstoqueBaixo) };
}

export async function listar(): Promise<Ingrediente[]> {
  const linhas = await consultar<LinhaIngrediente>(`${SELECT_INGREDIENTE} WHERE ativo = TRUE ORDER BY nome`);
  return linhas.map(formatar);
}

// Só ingredientes ativos (não excluídos).
export async function buscar(id: number): Promise<Ingrediente | null> {
  const [linha] = await consultar<LinhaIngrediente>(`${SELECT_INGREDIENTE} WHERE ingrediente_id = ? AND ativo = TRUE`, [id]);
  return linha ? formatar(linha) : null;
}

async function exigir(id: number): Promise<Ingrediente> {
  const ingrediente = await buscar(id);
  if (!ingrediente) throw new ErroApi(404, 'Ingrediente não encontrado.', 'NAO_ENCONTRADO');
  return ingrediente;
}

// resultado: CRIADO | REATIVADO | JA_EXISTIA
export async function cadastrar(dados: { nome: string; quantidade: number; unidade: Sigla; dataEventoCliente?: string }) {
  const saida = await chamarProcedure(
    'sp_cadastrar_ingrediente',
    [dados.nome, UNIDADES[dados.unidade].id, dados.quantidade, paraDataHoraMysql(dados.dataEventoCliente), null],
    ['ingrediente_id', 'resultado'],
  );
  return { resultado: saida.resultado as string, ingrediente: await exigir(saida.ingrediente_id) };
}

// resultado: REGISTRADA | JA_PROCESSADA (mesmo uuidCliente enviado de novo)
export async function reporEstoque(id: number, dados: { quantidade: number; uuidCliente?: string; dataEventoCliente?: string }) {
  const atual = await exigir(id);
  const uuidCliente = dados.uuidCliente ?? randomUUID();

  const saida = await chamarProcedure(
    'sp_registrar_reposicao_estoque',
    [atual.nome, dados.quantidade, uuidCliente, paraDataHoraMysql(dados.dataEventoCliente), null],
    ['resultado'],
  );
  return { resultado: saida.resultado as string, uuidCliente, ingrediente: await exigir(id) };
}

// resultado: EXCLUIDO | JA_EXCLUIDO. Exclusão lógica: o histórico continua existindo.
export async function excluir(id: number, dados: { dataEventoCliente?: string }) {
  // Aqui NÃO usamos buscar(): se o front repetir o pedido de exclusão, queremos JA_EXCLUIDO e não 404.
  const [linha] = await consultar<{ nome: string }>('SELECT nome FROM ingredientes WHERE ingrediente_id = ?', [id]);
  if (!linha) throw new ErroApi(404, 'Ingrediente não encontrado.', 'NAO_ENCONTRADO');

  const saida = await chamarProcedure(
    'sp_excluir_ingrediente',
    [linha.nome, paraDataHoraMysql(dados.dataEventoCliente), null],
    ['resultado'],
  );
  return { resultado: saida.resultado as string, id };
}
