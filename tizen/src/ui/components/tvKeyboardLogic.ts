/**
 * Logic of the on-screen keyboard of the TV (no DOM): the layout and what each key does to the text.
 * The Samsung system keyboard is not reliable with a remote on every model, so the Sources forms use this one,
 * which the D-pad drives completely.
 */

export type KeyKind = 'char' | 'insert' | 'backspace' | 'space' | 'shift' | 'clear' | 'reveal' | 'ok' | 'cancel';

export interface KeyDef {
  id: string;
  kind: KeyKind;
  label: string;
  /** What `char` and `insert` keys add. */
  text?: string;
  wide?: boolean;
}

const chars = (row: string): string[] => row.split('');

const CHAR_ROWS: string[][] = [
  chars('1234567890'),
  chars('azertyuiop'),
  chars('qsdfghjklm'),
  chars('wxcvbn.-_/'),
  chars(':@?=&%#+~,'),
];

/** Typed in one press: the parts of an IPTV address that take the longest on a remote. */
const SHORTCUTS: Array<[string, string]> = [
  ['http://', 'http://'],
  ['https://', 'https://'],
  ['.com', '.com'],
  [':8080', ':8080'],
  ['/get.php', '/get.php'],
];

export function keyboardRows(): KeyDef[][] {
  const rows: KeyDef[][] = CHAR_ROWS.map((row, r) =>
    row.map((c, i) => ({ id: `kb-${r}-${i}`, kind: 'char' as const, label: c, text: c }))
  );
  rows.push(SHORTCUTS.map(([label, text], i) => ({ id: `kb-s-${i}`, kind: 'insert' as const, label, text, wide: true })));
  rows.push([
    { id: 'kb-shift', kind: 'shift', label: 'Maj', wide: true },
    { id: 'kb-space', kind: 'space', label: 'Espace', wide: true },
    { id: 'kb-back', kind: 'backspace', label: '⌫ Effacer', wide: true },
    { id: 'kb-clear', kind: 'clear', label: 'Tout effacer', wide: true },
  ]);
  rows.push([
    { id: 'kb-reveal', kind: 'reveal', label: 'Afficher', wide: true },
    { id: 'kb-ok', kind: 'ok', label: 'Valider', wide: true },
    { id: 'kb-cancel', kind: 'cancel', label: 'Annuler', wide: true },
  ]);
  return rows;
}

export const MAX_FIELD_LENGTH = 2048;

/** The text after pressing a key. Keys that do not change the text (shift, ok…) return it unchanged. */
export function applyKey(value: string, key: KeyDef, shift: boolean): string {
  switch (key.kind) {
    case 'char': {
      const c = shift ? (key.text ?? '').toUpperCase() : key.text ?? '';
      return (value + c).slice(0, MAX_FIELD_LENGTH);
    }
    case 'insert':
      return (value + (key.text ?? '')).slice(0, MAX_FIELD_LENGTH);
    case 'space':
      return (value + ' ').slice(0, MAX_FIELD_LENGTH);
    case 'backspace':
      return value.slice(0, -1);
    case 'clear':
      return '';
    default:
      return value;
  }
}

/** What the screen shows of the text: hidden characters for a password until the user asks to see it. */
export function displayValue(value: string, secret: boolean, revealed: boolean): string {
  if (!secret || revealed) return value;
  return '•'.repeat(value.length);
}
