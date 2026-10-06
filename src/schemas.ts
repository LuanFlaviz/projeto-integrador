// Validação do que chega do front. Cada schema descreve o formato esperado do JSON;
// se algo estiver fora do padrão, o zod gera a lista de erros que o tratador (app.ts)
// devolve ao front como HTTP 400, em português.
import { z } from 'zod';
import { normalizarSigla, UNIDADES, type Sigla } from './unidades';

// ---------- peças reutilizáveis ----------

// Mensagem padrão: campo ausente x campo com tipo errado.
const obrigatorio = (esperado: string) => ({
  error: (i: { input?: unknown }) => (i.input === undefined ? 'Campo obrigatório.' : `Valor inválido: esperado ${esperado}.`),
});

const nome = z
  .string(obrigatorio('texto'))
  .trim()
  .min(1, 'O nome é obrigatório.')
  .max(150, 'O nome pode ter no máximo 150 caracteres.');

// Aceita 12, "12" e "12,5" (o front faz parseFloat com troca de vírgula por ponto).
function comoNumero(valor: unknown): unknown {
  if (typeof valor !== 'string') return valor;
  const texto = valor.trim().replace(',', '.');
  return texto === '' ? Number.NaN : Number(texto);
}

const LIMITE = 99_999_999; // cabe no DECIMAL(12,4) do banco

const quantidadePositiva = (mensagem: string) =>
  z.preprocess(comoNumero, z.number(obrigatorio('número')).positive(mensagem).max(LIMITE, 'Valor grande demais.'));

const quantidadeNaoNegativa = (mensagem: string) =>
  z.preprocess(comoNumero, z.number(obrigatorio('número')).min(0, mensagem).max(LIMITE, 'Valor grande demais.'));

// Unidade do ESTOQUE: só Kg, L ou Un (em qualquer capitalização).
const unidadeEstoque = z
  .string(obrigatorio('Kg, L ou Un'))
  .refine((v) => {
    const sigla = normalizarSigla(v);
    return sigla !== null && UNIDADES[sigla].estoque;
  }, 'Unidade inválida para estoque. Use Kg, L ou Un.')
  .transform((v) => normalizarSigla(v) as Sigla);

// Unidade da RECEITA: g, Kg, ml, L ou Un.
const unidadeReceita = z
  .string(obrigatorio('g, kg, ml, L ou un'))
  .refine((v) => normalizarSigla(v) !== null, 'Unidade inválida. Use g, kg, ml, L ou un.')
  .transform((v) => normalizarSigla(v) as Sigla);

// Campos opcionais que o front offline pode mandar (veja README, "Modo offline"):
const uuidCliente = z.uuid('uuidCliente precisa ser um UUID válido.').optional();
const dataEventoCliente = z.iso
  .datetime({ offset: true, error: 'dataEventoCliente precisa ser uma data ISO, ex.: 2026-09-15T12:00:00.000Z.' })
  .optional();

// ---------- schemas das rotas ----------

export const idDaRota = z.object({
  id: z.coerce.number({ error: 'O id precisa ser um número.' }).int('O id precisa ser inteiro.').positive('O id precisa ser positivo.'),
});

export const exclusao = z.object({ dataEventoCliente }).default({});

export const criarIngrediente = z.object({
  nome,
  quantidade: quantidadeNaoNegativa('A quantidade inicial não pode ser negativa.').default(0),
  unidade: unidadeEstoque,
  dataEventoCliente,
});

export const reposicao = z.object({
  quantidade: quantidadePositiva('Insira uma quantidade positiva.'),
  uuidCliente,
  dataEventoCliente,
});

export const criarProduto = z.object({
  nome,
  receita: z
    .array(
      z.object({
        ingrediente: nome,
        quantidade: quantidadePositiva('A quantidade do ingrediente precisa ser maior que zero.'),
        unidade: unidadeReceita,
      }),
      obrigatorio('lista de ingredientes'),
    )
    .min(1, 'É necessário cadastrar pelo menos um ingrediente.'),
  dataEventoCliente,
});

export const criarAutorizacao = z.object({
  itens: z
    .array(
      z.object({
        produtoId: z.coerce.number({ error: 'produtoId precisa ser um número.' }).int().positive(),
        quantidade: quantidadePositiva('Informe uma quantidade válida de produtos.'),
      }),
      obrigatorio('lista de produtos'),
    )
    .min(1, 'Não há itens para autorizar.'),
  observacao: z.string().trim().max(500, 'A observação pode ter no máximo 500 caracteres.').optional(),
  uuidCliente,
  dataEventoCliente,
});
