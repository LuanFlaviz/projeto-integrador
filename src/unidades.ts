// Unidades de medida. Os ids são os mesmos que o script do banco insere na tabela
// unidades_medida (você também consegue vê-los em GET /api/unidades).
//
//   estoque = pode ser a unidade em que o estoque do ingrediente é guardado
//   Receitas aceitam todas; g e ml são convertidos para Kg e L ao dar baixa.

export type Sigla = 'Kg' | 'g' | 'L' | 'ml' | 'Un';

export const UNIDADES: Record<Sigla, { id: number; estoque: boolean }> = {
  Kg: { id: 1, estoque: true },
  g: { id: 2, estoque: false },
  L: { id: 3, estoque: true },
  ml: { id: 4, estoque: false },
  Un: { id: 5, estoque: true },
};

// O front usa "kg", "un", "l" em minúsculas em alguns lugares e "Kg", "Un", "L" em outros.
// Aqui aceitamos qualquer capitalização e devolvemos a sigla oficial.
export function normalizarSigla(texto: string): Sigla | null {
  const procurada = texto.trim().toLowerCase();
  const achada = (Object.keys(UNIDADES) as Sigla[]).find((s) => s.toLowerCase() === procurada);
  return achada ?? null;
}
