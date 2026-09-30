// Display words of an ayah, mapped onto the SDK's acoustic word indices
// (`word_progress.word_index`, `CorrectionIssue.word`). The acoustic corpus
// splits an ayah into words its own way, so every display word records which
// acoustic words it covers. Anything else would shift every index after it.

/** Rub el hizb (quarter marker). Written before the first word of a quarter. */
const RUB_EL_HIZB = "۞";
const LETTER = /[ء-يٱ-ۓۺ-ۿ]/;
const DIACRITICS = /[ؐ-ًؚ-ٰٟۖ-ۭـ]/g;

/**
 * Words the Uthmani text writes joined but the acoustic corpus splits, keyed
 * by bare letters. بَعْدَمَا (2:181, 8:6, 13:37) is بَعْدَ + مَا there.
 */
const FUSED: ReadonlyMap<string, number> = new Map([["بعدما", 2]]);

export interface WordToken {
  /** Display text, including any attached stop, sajdah or hizb sign. */
  text: string;
  /** How many acoustic words this display word covers (usually 1). */
  words: number;
}

function letters(token: string): string {
  return token.replace(DIACRITICS, "").replace(/ٱ/g, "ا");
}

/**
 * Split Uthmani text into display words. Sign-only tokens (waqf marks ۖ…ۜ,
 * sajdah ۩) stay with the word before them; a rub el hizb ۞ stays with the
 * word after it. None of them is a word of its own.
 */
export function splitUthmaniWords(text: string): WordToken[] {
  const result: WordToken[] = [];
  let prefix = "";
  for (const token of text.split(/\s+/)) {
    if (!token) continue;
    if (!LETTER.test(token)) {
      if (token.includes(RUB_EL_HIZB) || result.length === 0) prefix += `${token} `;
      else result[result.length - 1]!.text += ` ${token}`;
      continue;
    }
    result.push({ text: prefix + token, words: FUSED.get(letters(token)) ?? 1 });
    prefix = "";
  }
  if (prefix && result.length) result[result.length - 1]!.text += ` ${prefix.trim()}`;
  return result;
}

export const BISMILLAH_WORD_COUNT = 4;
const BISMILLAH_BASE = "بسم الله الرحمن الرحيم";

function stripDiacritics(s: string): string {
  return s.replace(/[ؐ-ًؚ-ٰٟۖ-ۜ۟-۪ۤۧۨ-ۭ]/g, "");
}

export function startsWithBismillah(text: string): boolean {
  const stripped = stripDiacritics(text).replace(/ٱ/g, "ا");
  return stripped.startsWith(BISMILLAH_BASE) || stripped.startsWith(stripDiacritics(BISMILLAH_BASE));
}

export interface AyahWord {
  text: string;
  /** First acoustic word index covered, or -1 for the display-only bismillah. */
  first: number;
  /** Acoustic words covered (0 for the display-only bismillah). */
  count: number;
}

/**
 * The ayah's display words with the acoustic word range each one covers. The
 * bismillah printed at the top of ayah 1 (every surah but 1 and 9) is not part
 * of the recited ayah the SDK tracks, so it covers no acoustic words.
 */
export function ayahWords(surah: number, ayah: number, text: string): AyahWord[] {
  const tokens = splitUthmaniWords(text);
  const skip = ayah === 1 && surah !== 1 && surah !== 9 && startsWithBismillah(text) ? BISMILLAH_WORD_COUNT : 0;
  let next = 0;
  return tokens.map((t, i) => {
    if (i < skip) return { text: t.text, first: -1, count: 0 };
    const word = { text: t.text, first: next, count: t.words };
    next += t.words;
    return word;
  });
}

/** Acoustic words the ayah's display words cover in total. */
export function acousticWordCount(words: readonly AyahWord[]): number {
  return words.reduce((n, w) => n + w.count, 0);
}
