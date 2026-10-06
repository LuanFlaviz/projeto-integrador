// Rotas da tela PRODUTOS (produto.html): lista, criação com receita e exclusão.
import { Router } from 'express';
import * as produtos from '../services/produtos';
import { criarProduto, exclusao, idDaRota } from '../schemas';

export const rotasProdutos = Router();

rotasProdutos.get('/', async (_req, res) => {
  res.json(await produtos.listar());
});

rotasProdutos.get('/:id', async (req, res) => {
  const { id } = idDaRota.parse(req.params);
  const produto = await produtos.buscar(id);
  if (!produto) {
    res.status(404).json({ erro: 'Produto não encontrado.', codigo: 'NAO_ENCONTRADO' });
    return;
  }
  res.json(produto);
});

// "Salvar produto" do modal. Ingredientes da receita que ainda não existem são criados
// automaticamente (com estoque zero) pela procedure.
rotasProdutos.post('/', async (req, res) => {
  const dados = criarProduto.parse(req.body);
  const { resultado, produto } = await produtos.criar(dados);
  res.status(resultado === 'ATUALIZADO' ? 200 : 201).json({ resultado, produto });
});

rotasProdutos.delete('/:id', async (req, res) => {
  const { id } = idDaRota.parse(req.params);
  const dados = exclusao.parse(req.body ?? {});
  res.json(await produtos.excluir(id, dados));
});
