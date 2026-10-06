// Rota do botão "Finalizar Autorização" (produto.html).
import { Router } from 'express';
import * as autorizacoes from '../services/autorizacoes';
import { criarAutorizacao } from '../schemas';

export const rotasAutorizacoes = Router();

// 201 = autorização finalizada e estoque debitado.
// 200 = o mesmo uuidCliente já tinha sido processado (nada é debitado de novo).
// 409 = estoque insuficiente: nada é debitado e a resposta traz "faltantes".
rotasAutorizacoes.post('/', async (req, res) => {
  const dados = criarAutorizacao.parse(req.body);
  const { resultado, autorizacao } = await autorizacoes.finalizar(dados);
  res.status(resultado === 'JA_PROCESSADA' ? 200 : 201).json({ resultado, autorizacao });
});
