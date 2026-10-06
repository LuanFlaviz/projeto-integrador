// Erros "esperados" da API, já com o status HTTP certo e uma mensagem em português
// que o front pode mostrar direto para o usuário.

export class ErroApi extends Error {
  constructor(
    public readonly status: number,
    mensagem: string,
    public readonly codigo?: string,
    public readonly extras?: Record<string, unknown>,
  ) {
    super(mensagem);
    this.name = 'ErroApi';
  }
}

// As procedures do banco avisam erros de regra de negócio com SIGNAL SQLSTATE '45000'
// (o MySQL entrega isso como errno 1644). Aqui descobrimos o status HTTP pela mensagem.
function statusDaMensagem(mensagem: string): number {
  if (mensagem.includes('não encontrado')) return 404;
  if (mensagem.startsWith('Ingrediente usado na receita')) return 409;
  return 422;
}

// Converte erros crus do driver MySQL em ErroApi. Se não reconhecer, devolve o erro
// original (e aí o tratador geral responde 500 sem vazar detalhes internos).
export function traduzirErroMysql(erro: unknown): unknown {
  if (erro instanceof ErroApi) return erro;

  const e = erro as { errno?: number; code?: string; sqlMessage?: string };

  switch (e?.errno) {
    case 1644: {
      const mensagem = e.sqlMessage ?? 'Regra de negócio violada.';
      return new ErroApi(statusDaMensagem(mensagem), mensagem, 'REGRA_DE_NEGOCIO');
    }
    case 1062:
      return new ErroApi(409, 'Já existe um registro com esses dados.', 'DUPLICADO');
    case 1205: // tempo esgotado esperando outra operação
    case 1213: // deadlock
      return new ErroApi(503, 'O banco estava ocupado com outra operação. Tente novamente.', 'BANCO_OCUPADO');
  }

  if (e?.code === 'ECONNREFUSED' || e?.code === 'ER_ACCESS_DENIED_ERROR' || e?.code === 'ER_BAD_DB_ERROR') {
    return new ErroApi(503, 'Não foi possível acessar o banco de dados.', 'BANCO_INDISPONIVEL');
  }

  return erro;
}
