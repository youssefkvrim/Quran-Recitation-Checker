import { existsSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { acousticWordCount, ayahWords, splitUthmaniWords, startsWithBismillah, BISMILLAH_WORD_COUNT } from '../src/lib/quran-words';

it('preserves diacritics and stop marks without changing word indices', () => {
  const text = 'لَمْ يَلِدْ ۖ وَلَمْ يُولَدْ';
  const words = splitUthmaniWords(text);
  expect(words.map(w => w.text)).toEqual(['لَمْ', 'يَلِدْ ۖ', 'وَلَمْ', 'يُولَدْ']);
  expect(words.map(w => w.text).join(' ')).toBe(text);
});

it('accounts for display-only bismillah, including Uthmani alif wasla', () => {
  const text = 'بِسْمِ ٱللَّهِ ٱلرَّحْمَٰنِ ٱلرَّحِيمِ قُلْ هُوَ ٱللَّهُ أَحَدٌ';
  expect(startsWithBismillah(text)).toBe(true);
  expect(startsWithBismillah('قُلْ هُوَ ٱللَّهُ أَحَدٌ')).toBe(false);
  expect(splitUthmaniWords(text)[BISMILLAH_WORD_COUNT + 1].text).toBe('هُوَ');
  const words = ayahWords(112, 1, text);
  expect(words.slice(0, BISMILLAH_WORD_COUNT).every(w => w.first === -1 && w.count === 0)).toBe(true);
  expect(words.slice(BISMILLAH_WORD_COUNT).map(w => w.first)).toEqual([0, 1, 2, 3]);
});

it('keeps the rub el hizb and sajdah signs out of the word count', () => {
  // 2:44 opens a hizb quarter; 32:15 carries a sajdah sign.
  const hizb = '۞ أَتَأْمُرُونَ ٱلنَّاسَ بِٱلْبِرِّ';
  expect(splitUthmaniWords(hizb).map(w => w.text)).toEqual(['۞ أَتَأْمُرُونَ', 'ٱلنَّاسَ', 'بِٱلْبِرِّ']);
  expect(splitUthmaniWords(hizb).map(w => w.text).join(' ')).toBe(hizb);
  const sajdah = 'وَهُمْ لَا يَسْتَكْبِرُونَ ۩';
  expect(splitUthmaniWords(sajdah).map(w => w.text)).toEqual(['وَهُمْ', 'لَا', 'يَسْتَكْبِرُونَ ۩']);
});

it('maps a joined بَعْدَمَا onto the two acoustic words it covers', () => {
  const words = ayahWords(8, 6, 'يُجَٰدِلُونَكَ فِى ٱلْحَقِّ بَعْدَمَا تَبَيَّنَ');
  expect(words.map(w => [w.first, w.count])).toEqual([[0, 1], [1, 1], [2, 1], [3, 2], [5, 1]]);
  expect(acousticWordCount(words)).toBe(6);
});

const PUBLIC = fileURLToPath(new URL('../public/', import.meta.url));
const CORPUS = `${PUBLIC}zipformer_quran.json`;
describe.skipIf(!existsSync(CORPUS))('against the acoustic corpus', () => {
  it('every ayah\'s display words cover exactly the corpus words', () => {
    const corpus = JSON.parse(readFileSync(CORPUS, 'utf8')) as { surahs: { ayahs: { w: unknown[] }[] }[] };
    const quran = JSON.parse(readFileSync(`${PUBLIC}quran.json`, 'utf8')) as { surah: number; ayah: number; text_uthmani: string }[];
    const mismatched = quran.filter(v =>
      acousticWordCount(ayahWords(v.surah, v.ayah, v.text_uthmani)) !== corpus.surahs[v.surah - 1]!.ayahs[v.ayah - 1]!.w.length,
    ).map(v => `${v.surah}:${v.ayah}`);
    expect(quran).toHaveLength(6236);
    expect(mismatched).toEqual([]);
  });
});
