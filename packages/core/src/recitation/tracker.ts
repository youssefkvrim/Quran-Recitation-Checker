import { DEFAULT_CONFIG, type EngineConfig } from "./config.js";
import type { QuranCorpus } from "./corpus.js";
import type { CostTable } from "./phonemeCost.js";
import type { HeardChar } from "./types.js";

const RATE_MIN_N = 24;

function columnMin(column: Float32Array): number {
  let min = column[0]!;
  for (let m = 1; m < column.length; m++) if (column[m]! < min) min = column[m]!;
  return min;
}

export class Tracker {
  readonly corpus: QuranCorpus;
  readonly table: CostTable;
  readonly cfg: EngineConfig;
  readonly surah: number;
  readonly firstWord: number;
  readonly endWord: number;
  readonly len: number;
  readonly surahStart: number;
  readonly ref: Uint8Array;
  readonly wordStarts: Int32Array;
  readonly ayahAtStart: Int32Array;
  readonly localWordOfPos: Int32Array;
  readonly startLocal: number;

  column: Float32Array;
  cursorCell: number;
  cursorLocalWord: number;
  cursorCost: number;
  revision = 0;
  readonly trail: number[] = [];
  readonly costs: number[] = [];
  readonly heard: HeardChar[] = [];
  lost = false;
  /** Second column buffer: `feedOne` writes here, then swaps it with `column`. */
  private spare: Float32Array;
  /** min(column). After a feed this is the new cursorCost (the column argmin). */
  private colMin: number;

  constructor(
    corpus: QuranCorpus,
    table: CostTable,
    surah: number,
    startWordIndex: number,
    cfg: EngineConfig = DEFAULT_CONFIG,
  ) {
    this.corpus = corpus;
    this.table = table;
    this.cfg = cfg;
    this.surah = surah;
    const rec = corpus.surahs[surah - 1]!;
    this.firstWord = rec.firstWord;
    this.endWord = rec.endWord;
    this.surahStart = corpus.wordStart[rec.firstWord]!;
    const surahEnd = corpus.wordStart[rec.endWord]!;
    this.len = surahEnd - this.surahStart;
    this.ref = table.encode(corpus.text.slice(this.surahStart, surahEnd));
    const nWords = rec.endWord - rec.firstWord;
    this.wordStarts = new Int32Array(nWords);
    this.ayahAtStart = new Int32Array(nWords);
    for (let i = 0; i < nWords; i++) {
      const w = rec.firstWord + i;
      this.wordStarts[i] = corpus.wordStart[w]! - this.surahStart;
      this.ayahAtStart[i] = corpus.wordAyah[w]!;
    }
    this.localWordOfPos = new Int32Array(this.len);
    for (let i = 0; i < nWords; i++) {
      const a = this.wordStarts[i]!;
      const b = i + 1 < nWords ? this.wordStarts[i + 1]! : this.len;
      for (let p = a; p < b; p++) this.localWordOfPos[p] = i;
    }
    this.startLocal = Math.max(
      0,
      corpus.wordStart[startWordIndex]! - this.surahStart,
    );
    // Float32 store: events_ea_alafasy_multi cursor.cost / alignment.json.
    this.column = new Float32Array(this.len + 1);
    this.spare = new Float32Array(this.len + 1);
    this.cursorCell = this.startLocal;
    this.cursorLocalWord = -1;
    this.cursorCost = 0;
    this.colMin = 0;
    this.resetColumn();
  }

  get cursorWordIndex(): number {
    return this.firstWord + Math.max(0, this.cursorLocalWord);
  }

  get reachedEnd(): boolean {
    return this.cursorCell >= this.len - 1;
  }

  feed(chars: readonly HeardChar[]): void {
    for (const h of chars) this.feedOne(h);
  }

  costRate(window: number = this.cfg.lostWindow): number | null {
    const n = this.costs.length;
    if (n < RATE_MIN_N) return null;
    const w = Math.min(window, n);
    const before = n - w > 0 ? this.costs[n - w - 1]! : 0;
    return (this.costs[n - 1]! - before) / w;
  }

  /**
   * Forget the last `n` heard chars: the result is the tracker that never fed
   * them (spec §8). The shipped host never retracts CTC output, so this replays
   * the kept prefix from the initial column rather than paying for periodic
   * column snapshots on every feed.
   */
  retract(n: number): void {
    if (n <= 0) return;
    this.revision++;
    const target = Math.max(0, this.heard.length - n);
    const replay = this.heard.slice(0, target);
    this.resetColumn();
    this.heard.length = 0;
    this.trail.length = 0;
    this.costs.length = 0;
    this.feed(replay);
  }

  private resetColumn(): void {
    const jump = this.cfg.jumpCost;
    this.column.fill(Number.POSITIVE_INFINITY);
    for (let i = 0; i < this.wordStarts.length; i++) {
      const m = this.wordStarts[i]!;
      this.column[m] = m === this.startLocal ? 0 : jump;
    }
    for (let m = 1; m <= this.len; m++) {
      this.column[m] = Math.min(this.column[m]!, this.column[m - 1]! + 1);
    }
    this.cursorCell = this.startLocal;
    this.cursorLocalWord = -1;
    this.cursorCost = 0;
    this.lost = false;
    this.colMin = columnMin(this.column);
  }

  /**
   * One column of the surah-wide edit-distance DP (spec §8), in a single pass
   * with no allocation. The spec describes it as a sweep, then a restart floor
   * at every word start with forward delete-propagation, then an argmin. Doing
   * all three per cell in order is the same computation: a cell's final value is
   * the float32 of the cheapest of {substitute, insert, delete from the final
   * left neighbour, restart}, whatever order those candidates are compared in,
   * and no later step revisits a cell. So each cell is final when written and
   * the argmin can scan it straight away. `colMin` is the previous argmin cost.
   */
  private feedOne(h: HeardChar): void {
    const prev = this.column;
    const next = this.spare;
    const len = this.len;
    const colMin = this.colMin;
    const jump = colMin + this.cfg.jumpCost;
    const repeat = colMin + this.cfg.repeatCost;
    const cursorAyah = this.cursorLocalWord < 0 ? -1 : this.corpus.wordAyah[this.firstWord + this.cursorLocalWord]!;
    const cursorPos = this.cursorCell;
    const matrix = this.table.matrix;
    const row = this.table.id(h.ch) * this.table.size;
    const ref = this.ref;
    const starts = this.wordStarts;
    const ayahAt = this.ayahAtStart;
    const nStarts = starts.length;
    let si = 0;

    let v = Math.fround(prev[0]! + 1);
    while (si < nStarts && starts[si] === 0) {
      const r = ayahAt[si] === cursorAyah ? repeat : jump;
      if (r < v) v = Math.fround(r);
      si++;
    }
    next[0] = v;
    let left = v;
    let bestCell = 0;
    let bestCost = v;
    let bestDist = cursorPos;
    for (let m = 1; m <= len; m++) {
      v = Math.fround(prev[m - 1]! + matrix[row + ref[m - 1]!]!);
      const ins = prev[m]! + 1;
      if (ins < v) v = Math.fround(ins);
      const del = left + 1;
      if (del < v) v = Math.fround(del);
      while (si < nStarts && starts[si] === m) {
        const restart = m <= cursorPos && ayahAt[si] === cursorAyah ? repeat : jump;
        if (restart < v) v = Math.fround(restart);
        si++;
      }
      next[m] = v;
      left = v;
      if (v <= bestCost) {
        const d = m > cursorPos ? m - cursorPos : cursorPos - m;
        if (v < bestCost || d < bestDist) {
          bestCost = v;
          bestCell = m;
          bestDist = d;
        }
      }
    }
    this.spare = prev;
    this.column = next;
    this.colMin = bestCost;
    this.cursorCell = bestCell;
    this.cursorLocalWord = bestCell === 0 ? 0 : this.localWordOfPos[Math.min(bestCell, this.len) - 1]!;
    this.cursorCost = bestCost;
    this.trail.push(bestCell);
    this.costs.push(bestCost);
    this.heard.push(h);
    const rate = this.costRate(this.cfg.lostWindow);
    this.lost = rate !== null && rate >= this.cfg.lostRate;
  }
}
