// Rotas de apoio: saúde da API e lista de unidades.
import { Router } from 'express';
import { consultar } from '../db';
import { UNIDADES } from '../unidades';

export const rotasApoio = Router();

// Para conferir se a API e o banco estão no ar.
rotasApoio.get('/saude', async (_req, res) => {
  try {
    await consultar('SELECT 1');
    res.json({ api: 'ok', banco: 'ok' });
  } catch {
    res.status(503).json({ api: 'ok', banco: 'indisponivel' });
  }
});

// Unidades para montar os <select> do front (estoque usa só as marcadas com estoque: true).
rotasApoio.get('/unidades', (_req, res) => {
  res.json(Object.entries(UNIDADES).map(([sigla, u]) => ({ id: u.id, sigla, estoque: u.estoque })));
});
