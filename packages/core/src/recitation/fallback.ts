import { DEFAULT_CONFIG } from "./config.js";
import { QuranCorpus } from "./corpus.js";
import { normalizedDistance } from "./alignment.js";
import { costTable, type CostTable } from "./phonemeCost.js";
import { stripPreambles } from "./search.js";
import type { FallbackHit } from "./types.js";

interface EncodedAyah {
  surah: number;
  ayah: number;
  ids: Uint8Array;
}

// Encoding is table-independent (ids come from the fixed alphabet), so one
// copy per corpus serves every session and every call.
const encodedByCorpus = new WeakMap<QuranCorpus, EncodedAyah[]>();

function encodedAyahs(corpus: QuranCorpus, table: CostTable): EncodedAyah[] {
  let list = encodedByCorpus.get(corpus);
  if (!list) {
    list = [];
    for (const s of corpus.surahs) {
      for (let a = 1; a <= s.ayahCount; a++) {
        list.push({ surah: s.n, ayah: a, ids: table.encode(corpus.ayahPhonemes(s.n, a)) });
      }
    }
    encodedByCorpus.set(corpus, list);
  }
  return list;
}

/** Nearest whole ayah to a transcript, for when nothing passed the gate (spec §11). */
export function wholeAyahFallback(
  text: string,
  corpus: QuranCorpus,
  table: CostTable = costTable(),
  minChars = DEFAULT_CONFIG.searchMinChars,
  maxDistance = 0.5,
): FallbackHit | null {
  if (!text) return null;
  const stripped = stripPreambles(text, table);
  const rest = text.slice(stripped.offset);
  if (stripped.basmala && rest.length < minChars) {
    return { surah: 1, ayah: 1, distance: 0, how: "basmala" };
  }
  const q = table.encode(rest.length >= 3 ? rest : text);
  let best: FallbackHit | null = null;
  for (const a of encodedAyahs(corpus, table)) {
    if (a.ids.length > 2.5 * q.length + 8 || q.length > 2.5 * a.ids.length + 8) continue;
    const d = normalizedDistance(q, a.ids, table);
    if (!best || d < best.distance) {
      best = { surah: a.surah, ayah: a.ayah, distance: d, how: "whole-ayah" };
    }
  }
  if (!best || best.distance > maxDistance) return null;
  return best;
}
