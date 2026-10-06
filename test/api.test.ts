// Testes de ponta a ponta: sobem a API de verdade e conversam com o MySQL de teste.
// Rodar: npm test   (precisa do banco "luana_salgadinhos_teste", veja o README)
import './setup';
import assert from 'node:assert/strict';
import type { Server } from 'node:http';
import { after, before, describe, it } from 'node:test';
import { criarApp } from '../src/app';
import { pool } from '../src/db';

let servidor: Server;
let base = '';

async function chamar(metodo: string, caminho: string, corpo?: unknown) {
  const resposta = await fetch(base + caminho, {
    method: metodo,
    headers: corpo === undefined ? undefined : { 'Content-Type': 'application/json' },
    body: corpo === undefined ? undefined : typeof corpo === 'string' ? corpo : JSON.stringify(corpo),
  });
  const texto = await resposta.text();
  return { status: resposta.status, corpo: texto ? JSON.parse(texto) : null };
}

const get = (c: string) => chamar('GET', c);
const post = (c: string, b: unknown) => chamar('POST', c, b);
const del = (c: string, b?: unknown) => chamar('DELETE', c, b);

async function limparBanco() {
  const conexao = await pool.getConnection();
  try {
    await conexao.query('SET FOREIGN_KEY_CHECKS = 0');
    for (const tabela of [
      'movimentacoes_estoque', 'autorizacao_itens', 'autorizacoes_producao',
      'receita_itens', 'eventos_produto', 'produtos', 'ingredientes',
    ]) {
      await conexao.query(`DELETE FROM ${tabela}`);
    }
    await conexao.query('SET FOREIGN_KEY_CHECKS = 1');
  } finally {
    conexao.release();
  }
}

const quantidadeDe = async (nome: string) => {
  const lista = (await get('/api/ingredientes')).corpo as { nome: string; quantidade: number }[];
  return lista.find((i) => i.nome === nome)?.quantidade;
};

before(async () => {
  await limparBanco();
  servidor = criarApp().listen(0);
  await new Promise((ok) => servidor.once('listening', ok));
  base = `http://127.0.0.1:${(servidor.address() as { port: number }).port}`;
});

after(async () => {
  await new Promise((ok) => servidor.close(ok));
  await pool.end();
});

describe('apoio', () => {
  it('saúde responde ok com o banco conectado', async () => {
    const r = await get('/api/saude');
    assert.equal(r.status, 200);
    assert.deepEqual(r.corpo, { api: 'ok', banco: 'ok' });
  });

  it('lista as unidades', async () => {
    const r = await get('/api/unidades');
    assert.equal(r.status, 200);
    assert.equal(r.corpo.length, 5);
  });

  it('rota inexistente devolve 404 em JSON', async () => {
    const r = await get('/api/nao-existe');
    assert.equal(r.status, 404);
    assert.equal(r.corpo.codigo, 'ROTA_NAO_ENCONTRADA');
  });

  it('JSON malformado devolve 400', async () => {
    const r = await chamar('POST', '/api/ingredientes', '{ quebrado');
    assert.equal(r.status, 400);
    assert.equal(r.corpo.codigo, 'JSON_INVALIDO');
  });

  it('o banco usa o fuso do app (-04:00)', async () => {
    const [[linha]] = (await pool.query('SELECT @@session.time_zone AS fuso')) as any;
    assert.equal(linha.fuso, '-04:00');
  });
});

describe('ingredientes (estoque.html)', () => {
  let farinhaId: number;

  it('cadastra ingrediente novo (201)', async () => {
    const r = await post('/api/ingredientes', { nome: 'farinha de trigo', quantidade: 10, unidade: 'kg' });
    assert.equal(r.status, 201);
    assert.equal(r.corpo.resultado, 'CRIADO');
    assert.equal(r.corpo.ingrediente.quantidade, 10);
    assert.equal(r.corpo.ingrediente.unidade, 'Kg');
    farinhaId = r.corpo.ingrediente.id;
  });

  it('cadastro repetido não duplica (200 JA_EXISTIA)', async () => {
    const r = await post('/api/ingredientes', { nome: 'FARINHA DE TRIGO', quantidade: 99, unidade: 'Kg' });
    assert.equal(r.status, 200);
    assert.equal(r.corpo.resultado, 'JA_EXISTIA');
    assert.equal(r.corpo.ingrediente.id, farinhaId);
    assert.equal(r.corpo.ingrediente.quantidade, 10);
  });

  it('valida os dados (400 com lista de campos)', async () => {
    const r = await post('/api/ingredientes', { nome: '  ', quantidade: -1, unidade: 'g' });
    assert.equal(r.status, 400);
    assert.equal(r.corpo.codigo, 'DADOS_INVALIDOS');
    const campos = r.corpo.campos.map((c: { campo: string }) => c.campo).sort();
    assert.deepEqual(campos, ['nome', 'quantidade', 'unidade']);
  });

  it('aceita quantidade com vírgula em texto', async () => {
    const r = await post('/api/ingredientes', { nome: 'leite', quantidade: '2,5', unidade: 'L' });
    assert.equal(r.status, 201);
    assert.equal(r.corpo.ingrediente.quantidade, 2.5);
  });

  it('repõe estoque e soma', async () => {
    const r = await post(`/api/ingredientes/${farinhaId}/reposicoes`, { quantidade: 5 });
    assert.equal(r.status, 200);
    assert.equal(r.corpo.resultado, 'REGISTRADA');
    assert.equal(r.corpo.ingrediente.quantidade, 15);
  });

  it('reposição repetida com o mesmo uuidCliente não soma duas vezes', async () => {
    const uuidCliente = '3f0c5a4e-8a71-4c3a-9d55-6a1e3b2f7c10';
    const a = await post(`/api/ingredientes/${farinhaId}/reposicoes`, { quantidade: 1, uuidCliente });
    const b = await post(`/api/ingredientes/${farinhaId}/reposicoes`, { quantidade: 1, uuidCliente });
    assert.equal(a.corpo.resultado, 'REGISTRADA');
    assert.equal(b.corpo.resultado, 'JA_PROCESSADA');
    assert.equal(b.corpo.ingrediente.quantidade, 16);
  });

  it('reposição com quantidade zero é recusada (400)', async () => {
    const r = await post(`/api/ingredientes/${farinhaId}/reposicoes`, { quantidade: 0 });
    assert.equal(r.status, 400);
    assert.equal(r.corpo.campos[0].mensagem, 'Insira uma quantidade positiva.');
  });

  it('reposição em ingrediente inexistente dá 404', async () => {
    const r = await post('/api/ingredientes/999999/reposicoes', { quantidade: 1 });
    assert.equal(r.status, 404);
  });

  it('id inválido na rota dá 400', async () => {
    const r = await get('/api/ingredientes/abc');
    assert.equal(r.status, 400);
  });

  it('converte dataEventoCliente (UTC) para o fuso do app', async () => {
    const r = await post(`/api/ingredientes/${farinhaId}/reposicoes`, {
      quantidade: 1,
      dataEventoCliente: '2026-09-15T12:00:00.000Z',
    });
    assert.equal(r.status, 200);
    const [[linha]] = (await pool.query(
      `SELECT data_evento_cliente AS d FROM movimentacoes_estoque WHERE uuid_cliente = ?`,
      [r.corpo.uuidCliente],
    )) as any;
    assert.equal(linha.d, '2026-09-15 08:00:00');
  });
});

describe('produtos e autorizações (produto.html)', () => {
  let coxinhaId: number;

  it('cria produto com receita em g/ml e converte para Kg/L; ingrediente novo nasce zerado', async () => {
    await limparBanco();
    await post('/api/ingredientes', { nome: 'FARINHA', quantidade: 10, unidade: 'Kg' });
    await post('/api/ingredientes', { nome: 'LEITE', quantidade: 5, unidade: 'L' });

    const r = await post('/api/produtos', {
      nome: 'Coxinha',
      receita: [
        { ingrediente: 'FARINHA', quantidade: 500, unidade: 'g' },
        { ingrediente: 'LEITE', quantidade: 250, unidade: 'ml' },
        { ingrediente: 'ÓLEO', quantidade: 2, unidade: 'L' },
      ],
    });
    assert.equal(r.status, 201);
    assert.equal(r.corpo.resultado, 'CRIADO');
    assert.equal(r.corpo.produto.receita.length, 3);
    coxinhaId = r.corpo.produto.id;
    assert.equal(await quantidadeDe('ÓLEO'), 0);
  });

  it('lista produtos já com a receita', async () => {
    const r = await get('/api/produtos');
    assert.equal(r.status, 200);
    assert.equal(r.corpo.length, 1);
    assert.equal(r.corpo[0].nome, 'Coxinha');
    assert.equal(r.corpo[0].receita.length, 3);
  });

  it('receita vazia é recusada (400)', async () => {
    const r = await post('/api/produtos', { nome: 'Nada', receita: [] });
    assert.equal(r.status, 400);
  });

  it('unidade incompatível com a do estoque dá 422', async () => {
    const r = await post('/api/produtos', {
      nome: 'Pastel',
      receita: [{ ingrediente: 'FARINHA', quantidade: 1, unidade: 'L' }],
    });
    assert.equal(r.status, 422);
  });

  it('estoque insuficiente: 409, devolve faltantes e NÃO debita nada', async () => {
    // 100 coxinhas precisam de 50 Kg de farinha (há 10) e 200 L de óleo (há 0).
    const r = await post('/api/autorizacoes', { itens: [{ produtoId: coxinhaId, quantidade: 100 }] });
    assert.equal(r.status, 409);
    assert.equal(r.corpo.codigo, 'ESTOQUE_INSUFICIENTE');
    assert.ok(r.corpo.faltantes.length >= 2);
    assert.equal(await quantidadeDe('FARINHA'), 10);
    assert.equal(await quantidadeDe('LEITE'), 5);
  });

  it('finaliza autorização (201) e debita o estoque convertendo as unidades', async () => {
    await post('/api/ingredientes/' + (await idPorNome('ÓLEO')) + '/reposicoes', { quantidade: 30 });
    const uuidCliente = 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d';
    const r = await post('/api/autorizacoes', {
      uuidCliente,
      observacao: 'Pedido do sábado',
      itens: [{ produtoId: coxinhaId, quantidade: 10 }],
    });
    assert.equal(r.status, 201);
    assert.equal(r.corpo.resultado, 'FINALIZADA');
    assert.equal(r.corpo.autorizacao.status, 'FINALIZADA');
    assert.equal(r.corpo.autorizacao.produtos[0].quantidade, 10);
    assert.equal(r.corpo.autorizacao.consumo.length, 3);

    // 10 coxinhas gastam 5 Kg de farinha, 2,5 L de leite e 20 L de óleo.
    assert.equal(await quantidadeDe('FARINHA'), 5);
    assert.equal(await quantidadeDe('LEITE'), 2.5);
    assert.equal(await quantidadeDe('ÓLEO'), 10);
  });

  it('reenviar a mesma autorização (mesmo uuidCliente) não debita de novo', async () => {
    const antes = await quantidadeDe('FARINHA');
    const r = await post('/api/autorizacoes', {
      uuidCliente: 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d',
      itens: [{ produtoId: coxinhaId, quantidade: 10 }],
    });
    assert.equal(r.status, 200);
    assert.equal(r.corpo.resultado, 'JA_PROCESSADA');
    assert.equal(await quantidadeDe('FARINHA'), antes);
  });

  it('produto inexistente na autorização dá 404', async () => {
    const r = await post('/api/autorizacoes', { itens: [{ produtoId: 999999, quantidade: 1 }] });
    assert.equal(r.status, 404);
  });

  it('não deixa excluir ingrediente usado em receita (409)', async () => {
    const r = await del(`/api/ingredientes/${await idPorNome('FARINHA')}`);
    assert.equal(r.status, 409);
  });

  it('exclui produto, depois o ingrediente; repetir dá JA_EXCLUIDO', async () => {
    const p = await del(`/api/produtos/${coxinhaId}`);
    assert.equal(p.corpo.resultado, 'EXCLUIDO');
    assert.equal((await del(`/api/produtos/${coxinhaId}`)).corpo.resultado, 'JA_EXCLUIDO');
    assert.equal((await get('/api/produtos')).corpo.length, 0);

    const id = await idPorNome('FARINHA');
    assert.equal((await del(`/api/ingredientes/${id}`)).corpo.resultado, 'EXCLUIDO');
    assert.equal((await del(`/api/ingredientes/${id}`)).corpo.resultado, 'JA_EXCLUIDO');
    assert.equal((await get(`/api/ingredientes/${id}`)).status, 404);
  });

  it('recadastrar ingrediente excluído o reativa', async () => {
    const r = await post('/api/ingredientes', { nome: 'FARINHA', quantidade: 3, unidade: 'Kg' });
    assert.equal(r.status, 201);
    assert.equal(r.corpo.resultado, 'REATIVADO');
  });
});

async function idPorNome(nome: string): Promise<number> {
  const lista = (await get('/api/ingredientes')).corpo as { id: number; nome: string }[];
  const achado = lista.find((i) => i.nome === nome);
  assert.ok(achado, `ingrediente ${nome} não encontrado`);
  return achado.id;
}
