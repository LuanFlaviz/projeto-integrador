// Rotas da tela ESTOQUE (estoque.html).
import { Router } from 'express';
import * as ingredientes from '../services/ingredientes';
import { criarIngrediente, exclusao, idDaRota, reposicao } from '../schemas';

export const rotasIngredientes = Router();

// Lista o estoque (tabela da tela). O front usa "alertaEstoqueBaixo" para destacar o item.
rotasIngredientes.get('/', async (_req, res) => {
  res.json(await ingredientes.listar());
});

rotasIngredientes.get('/:id', async (req, res) => {
  const { id } = idDaRota.parse(req.params);
  const ingrediente = await ingredientes.buscar(id);
  if (!ingrediente) {
    res.status(404).json({ erro: 'Ingrediente não encontrado.', codigo: 'NAO_ENCONTRADO' });
    return;
  }
  res.json(ingrediente);
});

// "Adicionar ingrediente". 201 = criado ou reativado; 200 = já existia (nada mudou).
rotasIngredientes.post('/', async (req, res) => {
  const dados = criarIngrediente.parse(req.body);
  const { resultado, ingrediente } = await ingredientes.cadastrar(dados);
  res.status(resultado === 'JA_EXISTIA' ? 200 : 201).json({ resultado, ingrediente });
});

// "Repor estoque". Mandar o mesmo uuidCliente de novo NÃO soma duas vezes (JA_PROCESSADA).
rotasIngredientes.post('/:id/reposicoes', async (req, res) => {
  const { id } = idDaRota.parse(req.params);
  const dados = reposicao.parse(req.body);
  res.json(await ingredientes.reporEstoque(id, dados));
});

// "Excluir ingrediente". Exclusão lógica; recusa se alguma receita ainda usa o ingrediente (409).
rotasIngredientes.delete('/:id', async (req, res) => {
  const { id } = idDaRota.parse(req.params);
  const dados = exclusao.parse(req.body ?? {});
  res.json(await ingredientes.excluir(id, dados));
});
