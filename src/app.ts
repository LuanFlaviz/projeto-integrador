// Monta o app Express: middlewares, rotas e o tratador de erros.
// Separado do server.ts para os testes conseguirem subir o app sem precisar de porta fixa.
import path from 'node:path';
import cors from 'cors';
import express, { type ErrorRequestHandler } from 'express';
import { ZodError } from 'zod';
import { config } from './config';
import { ErroApi, traduzirErroMysql } from './errors';
import { rotasApoio } from './routes/apoio';
import { rotasAutorizacoes } from './routes/autorizacoes';
import { rotasIngredientes } from './routes/ingredientes';
import { rotasProdutos } from './routes/produtos';

export function criarApp() {
  const app = express();

  app.use(cors({ origin: config.corsOrigin }));
  app.use(express.json({ limit: '100kb' }));

  // Log simples: método, caminho, status e duração.
  if (process.env.NODE_ENV !== 'test') {
    app.use((req, res, next) => {
      const inicio = Date.now();
      res.on('finish', () => console.log(`${req.method} ${req.originalUrl} -> ${res.statusCode} (${Date.now() - inicio}ms)`));
      next();
    });
  }

  const api = express.Router();
  api.use(rotasApoio);
  api.use('/ingredientes', rotasIngredientes);
  api.use('/produtos', rotasProdutos);
  api.use('/autorizacoes', rotasAutorizacoes);
  api.use((req, _res, next) => next(new ErroApi(404, `Rota não encontrada: ${req.method} ${req.originalUrl}`, 'ROTA_NAO_ENCONTRADA')));
  app.use('/api', api);

  // Opcional: se a pasta public/ tiver o front (painel.html, estoque.html, produto.html),
  // o próprio backend entrega as páginas. Assim front e API ficam na mesma origem.
  const pastaFront = path.resolve(config.pastaFrontend);
  app.use(express.static(pastaFront, { index: 'painel.html' }));

  app.use(tratarErros);
  return app;
}

const tratarErros: ErrorRequestHandler = (erro, _req, res, _next) => {
  if (erro instanceof ZodError) {
    res.status(400).json({
      erro: 'Dados inválidos.',
      codigo: 'DADOS_INVALIDOS',
      campos: erro.issues.map((i) => ({ campo: i.path.join('.') || '(corpo)', mensagem: i.message })),
    });
    return;
  }

  // JSON malformado ou grande demais (erros do express.json).
  const e = erro as { type?: string; status?: number };
  if (e.type === 'entity.parse.failed') {
    res.status(400).json({ erro: 'O corpo da requisição não é um JSON válido.', codigo: 'JSON_INVALIDO' });
    return;
  }
  if (e.type === 'entity.too.large') {
    res.status(413).json({ erro: 'Corpo da requisição grande demais.', codigo: 'CORPO_GRANDE' });
    return;
  }

  const tratado = traduzirErroMysql(erro);
  if (tratado instanceof ErroApi) {
    res.status(tratado.status).json({ erro: tratado.message, codigo: tratado.codigo, ...tratado.extras });
    return;
  }

  console.error('Erro inesperado:', erro);
  res.status(500).json({ erro: 'Erro interno do servidor.', codigo: 'ERRO_INTERNO' });
};
