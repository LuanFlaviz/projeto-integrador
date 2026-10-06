// AUTORIZAÇÃO DE PRODUÇÃO ("Finalizar Autorização" do produto.html).
// A procedure sp_sincronizar_autorizacao_producao faz tudo numa transação só:
// soma o consumo por ingrediente, converte g->Kg e ml->L, confere o saldo e debita.
import { randomUUID } from 'node:crypto';
import { chamarProcedure, consultar } from '../db';
import { paraDataHoraMysql } from '../datas';
import { ErroApi } from '../errors';

interface Faltante {
  ingrediente: string;
  unidade: string;
  disponivel: number;
  necessario: number;
  faltante: number;
}

// O MySQL devolve o JSON já convertido; o MariaDB devolve texto. Cobrimos os dois.
function lerFaltantes(valor: unknown): Faltante[] {
  if (!valor) return [];
  return (typeof valor === 'string' ? JSON.parse(valor) : valor) as Faltante[];
}

async function detalhar(autorizacaoId: number) {
  const [cabecalho] = await consultar<{
    id: number;
    uuidCliente: string;
    status: string;
    dataEventoCliente: string | null;
    dataFinalizacao: string | null;
  }>(
    `SELECT autorizacao_id AS id, uuid_cliente AS uuidCliente, status_autorizacao AS status,
            data_evento_cliente AS dataEventoCliente, data_finalizacao AS dataFinalizacao
     FROM autorizacoes_producao WHERE autorizacao_id = ?`,
    [autorizacaoId],
  );

  const produtos = await consultar<{ produto: string; quantidade: number }>(
    `SELECT p.nome AS produto, ai.quantidade_produzida AS quantidade
     FROM autorizacao_itens ai
     INNER JOIN produtos p ON p.produto_id = ai.produto_id
     WHERE ai.autorizacao_id = ?
     ORDER BY ai.autorizacao_item_id`,
    [autorizacaoId],
  );

  // O que saiu do estoque (o "Ingredientes Totais Necessários" que o front mostrava no alert).
  const consumo = await consultar<{ ingrediente: string; quantidade: number; unidade: string }>(
    `SELECT i.nome AS ingrediente, m.quantidade, um.sigla AS unidade
     FROM movimentacoes_estoque m
     INNER JOIN ingredientes i ON i.ingrediente_id = m.ingrediente_id
     INNER JOIN unidades_medida um ON um.unidade_id = i.unidade_medida_id
     WHERE m.autorizacao_id = ? AND m.origem_tipo = 'PRODUCAO'
     ORDER BY i.nome`,
    [autorizacaoId],
  );

  return { ...cabecalho, produtos, consumo };
}

// resultado: FINALIZADA | JA_PROCESSADA. Faltando insumo, lança ErroApi 409 com a lista do que falta.
export async function finalizar(dados: {
  itens: { produtoId: number; quantidade: number }[];
  observacao?: string;
  uuidCliente?: string;
  dataEventoCliente?: string;
}) {
  // A procedure identifica o produto pelo NOME, então traduzimos os ids que o front manda.
  const ids = [...new Set(dados.itens.map((i) => i.produtoId))];
  const produtos = await consultar<{ id: number; nome: string }>(
    'SELECT produto_id AS id, nome FROM produtos WHERE produto_id IN (?) AND ativo = TRUE',
    [ids],
  );
  const nomePorId = new Map(produtos.map((p) => [p.id, p.nome]));

  const inexistentes = ids.filter((id) => !nomePorId.has(id));
  if (inexistentes.length > 0) {
    throw new ErroApi(404, `Produto não encontrado (ou excluído): id ${inexistentes.join(', ')}.`, 'NAO_ENCONTRADO');
  }

  const uuidCliente = dados.uuidCliente ?? randomUUID();
  const itensParaProcedure = dados.itens.map((i) => ({
    nome_produto: nomePorId.get(i.produtoId),
    quantidade_produzida: i.quantidade,
  }));

  const saida = await chamarProcedure(
    'sp_sincronizar_autorizacao_producao',
    [uuidCliente, dados.observacao ?? null, JSON.stringify(itensParaProcedure), paraDataHoraMysql(dados.dataEventoCliente), null],
    ['autorizacao_id', 'resultado', 'faltantes'],
  );

  if (saida.resultado === 'ESTOQUE_INSUFICIENTE') {
    throw new ErroApi(409, 'Estoque insuficiente para finalizar a autorização de produção.', 'ESTOQUE_INSUFICIENTE', {
      faltantes: lerFaltantes(saida.faltantes),
    });
  }

  return {
    resultado: saida.resultado as string,
    autorizacao: await detalhar(saida.autorizacao_id),
  };
}
