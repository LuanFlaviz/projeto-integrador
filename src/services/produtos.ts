// Acesso ao banco para PRODUTOS e suas RECEITAS (tela produto.html).
import { chamarProcedure, consultar } from '../db';
import { paraDataHoraMysql } from '../datas';
import { ErroApi } from '../errors';
import { UNIDADES, type Sigla } from '../unidades';

export interface ItemReceita {
  ingrediente: string;
  quantidade: number;
  unidade: string;
}

export interface Produto {
  id: number;
  nome: string;
  receita: ItemReceita[];
}

interface LinhaProduto {
  id: number;
  nome: string;
}

interface LinhaItem extends ItemReceita {
  produtoId: number;
}

// Monta os produtos já com a receita dentro (o tooltip do front não precisa de outra chamada).
async function montar(produtos: LinhaProduto[]): Promise<Produto[]> {
  if (produtos.length === 0) return [];

  const itens = await consultar<LinhaItem>(
    `SELECT produto_id AS produtoId, ingrediente, quantidade_necessaria AS quantidade, unidade_medida AS unidade
     FROM vw_receita_produto
     WHERE produto_id IN (?)
     ORDER BY produto_id, ingrediente_id`,
    [produtos.map((p) => p.id)],
  );

  const porProduto = new Map<number, ItemReceita[]>();
  for (const { produtoId, ...item } of itens) {
    porProduto.set(produtoId, [...(porProduto.get(produtoId) ?? []), item]);
  }
  return produtos.map((p) => ({ ...p, receita: porProduto.get(p.id) ?? [] }));
}

export async function listar(): Promise<Produto[]> {
  const produtos = await consultar<LinhaProduto>('SELECT produto_id AS id, nome FROM produtos WHERE ativo = TRUE ORDER BY produto_id');
  return montar(produtos);
}

export async function buscar(id: number): Promise<Produto | null> {
  const produtos = await consultar<LinhaProduto>('SELECT produto_id AS id, nome FROM produtos WHERE produto_id = ? AND ativo = TRUE', [id]);
  return (await montar(produtos))[0] ?? null;
}

// resultado: CRIADO | REATIVADO | ATUALIZADO (já existia: a receita enviada vira a receita do produto)
export async function criar(dados: {
  nome: string;
  receita: { ingrediente: string; quantidade: number; unidade: Sigla }[];
  dataEventoCliente?: string;
}) {
  // Formato que a procedure espera (JSON com nomes de campo do banco).
  const itens = dados.receita.map((i) => ({
    nome_ingrediente: i.ingrediente,
    quantidade_necessaria: i.quantidade,
    unidade_medida_id: UNIDADES[i.unidade].id,
  }));

  const saida = await chamarProcedure(
    'sp_sincronizar_produto_com_receita',
    [dados.nome, JSON.stringify(itens), paraDataHoraMysql(dados.dataEventoCliente), null],
    ['produto_id', 'resultado'],
  );
  const produto = await buscar(saida.produto_id);
  return { resultado: saida.resultado as string, produto: produto! };
}

// resultado: EXCLUIDO | JA_EXCLUIDO
export async function excluir(id: number, dados: { dataEventoCliente?: string }) {
  const [linha] = await consultar<{ nome: string }>('SELECT nome FROM produtos WHERE produto_id = ?', [id]);
  if (!linha) throw new ErroApi(404, 'Produto não encontrado.', 'NAO_ENCONTRADO');

  const saida = await chamarProcedure(
    'sp_excluir_produto',
    [linha.nome, paraDataHoraMysql(dados.dataEventoCliente), null],
    ['resultado'],
  );
  return { resultado: saida.resultado as string, id };
}
