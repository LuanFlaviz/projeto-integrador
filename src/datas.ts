// O navegador manda datas em ISO ("2026-09-15T12:00:00.000Z") e o banco guarda DATETIME
// sem fuso ("2026-09-15 08:00:00"). Estas funções fazem a ponte usando o fuso do .env.
import { config } from './config';

const FORMATO = {
  hourCycle: 'h23',
  year: 'numeric',
  month: '2-digit',
  day: '2-digit',
  hour: '2-digit',
  minute: '2-digit',
  second: '2-digit',
} as const;

function partesNoFuso(data: Date, fuso: string): Record<string, string> {
  const partes = new Intl.DateTimeFormat('en-CA', { ...FORMATO, timeZone: fuso }).formatToParts(data);
  return Object.fromEntries(partes.map((p) => [p.type, p.value]));
}

// "2026-09-15T12:00:00.000Z" -> "2026-09-15 08:00:00" (no fuso America/Cuiaba)
// Sem data (o front não mandou), devolve null e o banco usa a hora em que o pedido chegou.
export function paraDataHoraMysql(iso: string | null | undefined, fuso: string = config.fusoHorario): string | null {
  if (!iso) return null;
  const data = new Date(iso);
  if (Number.isNaN(data.getTime())) return null;

  const p = partesNoFuso(data, fuso);
  return `${p.year}-${p.month}-${p.day} ${p.hour}:${p.minute}:${p.second}`;
}

// Deslocamento do fuso em relação ao UTC no formato que o MySQL aceita ("-04:00").
// Usado para o banco usar o mesmo fuso do app no NOW().
export function deslocamentoUtc(fuso: string, quando: Date = new Date()): string {
  const comoUtc = (p: Record<string, string>) =>
    Date.UTC(Number(p.year), Number(p.month) - 1, Number(p.day), Number(p.hour), Number(p.minute), Number(p.second));

  const minutos = Math.round((comoUtc(partesNoFuso(quando, fuso)) - comoUtc(partesNoFuso(quando, 'UTC'))) / 60000);
  const sinal = minutos < 0 ? '-' : '+';
  const absoluto = Math.abs(minutos);
  const hh = String(Math.floor(absoluto / 60)).padStart(2, '0');
  const mm = String(absoluto % 60).padStart(2, '0');
  return `${sinal}${hh}:${mm}`;
}
