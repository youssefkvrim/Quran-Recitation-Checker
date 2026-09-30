/**
 * The tracker DP, verdict trace and relocation check are computed
 * incrementally for speed (single allocation-free DP pass, cached verdicts,
 * lazy relocation search). These tests pin them to the plain spec definitions
 * (lab/docs/specs/recitation-engine-spec.md §8-§10) on perturbed recitations.
 */
import { readFileSync } from "node:fs";
import { describe, expect, it, vi } from "vitest";
import { requireCorpus } from "./paths";
import { QuranCorpus } from "../../src/recitation/corpus";
import { QuranIndex } from "../../src/recitation/search";
import { Tracker } from "../../src/recitation/tracker";
import { VerdictTracer } from "../../src/recitation/verdicts";
import { RecitationEngine } from "../../src/recitation/engine";
import { DEFAULT_CONFIG } from "../../src/recitation/config";
import { costTable } from "../../src/recitation/phonemeCost";
import type { CtcToken, HeardChar } from "../../src/recitation/types";

const corpus = new QuranCorpus(JSON.parse(readFileSync(requireCorpus(), "utf8")));
const table = costTable();
const cfg = DEFAULT_CONFIG;

function rng(seed: number): () => number {
  let s = seed >>> 0 || 1;
  return () => {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
    return s / 2 ** 32;
  };
}

const LETTERS = [..."بتثجحخدذرزسشصضطظعغفقكلمنهوي"];

/** A recitation of `text` with substitutions, deletions, insertions, repeats and pauses. */
function perturbed(text: string, seed: number): HeardChar[] {
  const r = rng(seed);
  const chars = [...text];
  const out: HeardChar[] = [];
  let frame = 0;
  for (let i = 0; i < chars.length; i++) {
    const roll = r();
    if (roll < 0.04) continue;
    const ch = roll < 0.1 ? LETTERS[Math.floor(r() * LETTERS.length)]! : chars[i]!;
    frame += r() < 0.03 ? 30 : 2;
    out.push({ ch, frame, margin: 0.3 + 0.7 * r() });
    if (r() < 0.03) out.push({ ch: LETTERS[Math.floor(r() * LETTERS.length)]!, frame: ++frame, margin: 0.4 });
    if (r() < 0.01 && i > 12) i -= 12; // repeat a stretch: the cursor moves back
  }
  return out;
}

/** Spec §8 feed, written as the spec states it: sweep, restart floor, argmin. */
function referenceStep(
  t: Tracker,
  s: { column: Float32Array; cursorCell: number; cursorLocalWord: number },
  h: HeardChar,
): number {
  const prev = s.column;
  const next = new Float32Array(t.len + 1);
  let colMin = prev[0]!;
  for (let m = 1; m <= t.len; m++) if (prev[m]! < colMin) colMin = prev[m]!;
  const jump = colMin + cfg.jumpCost;
  const repeat = colMin + cfg.repeatCost;
  const cursorAyah = s.cursorLocalWord < 0 ? -1 : corpus.wordAyah[t.firstWord + s.cursorLocalWord]!;
  const hid = table.id(h.ch);
  next[0] = prev[0]! + 1;
  for (let m = 1; m <= t.len; m++) {
    next[m] = prev[m - 1]! + table.cost(hid, t.ref[m - 1]!);
    if (prev[m]! + 1 < next[m]!) next[m] = prev[m]! + 1;
    if (next[m - 1]! + 1 < next[m]!) next[m] = next[m - 1]! + 1;
  }
  for (let i = 0; i < t.wordStarts.length; i++) {
    const m = t.wordStarts[i]!;
    const restart = m <= s.cursorCell && t.ayahAtStart[i] === cursorAyah ? repeat : jump;
    if (restart < next[m]!) {
      next[m] = restart;
      for (let j = m + 1; j <= t.len && next[j - 1]! + 1 < next[j]!; j++) next[j] = next[j - 1]! + 1;
    }
  }
  let best = 0;
  for (let m = 1; m <= t.len; m++) {
    const c = next[m]!;
    const b = next[best]!;
    if (c < b || (c === b && Math.abs(m - s.cursorCell) < Math.abs(best - s.cursorCell))) best = m;
  }
  s.column = next;
  s.cursorCell = best;
  s.cursorLocalWord = best === 0 ? 0 : t.localWordOfPos[Math.min(best, t.len) - 1]!;
  return next[best]!;
}

/** Index of the first cell that is not bit-identical, or -1. */
function firstDiff(a: Float32Array, b: Float32Array): number {
  if (a.length !== b.length) return 0;
  for (let i = 0; i < a.length; i++) if (!Object.is(a[i], b[i])) return i;
  return -1;
}

function recitation(surah: number, from: number, to: number): string {
  let text = "";
  for (let a = from; a <= to; a++) text += corpus.ayahPhonemes(surah, a);
  return text;
}

describe("tracker DP", () => {
  it.each([
    [1, 1, 7, 1],
    [112, 1, 4, 2],
    [36, 1, 12, 3],
    [2, 1, 3, 4],
  ])("matches the spec definition bit for bit (surah %i:%i-%i, seed %i)", (surah, from, to, seed) => {
    const chars = perturbed(recitation(surah, from, to), seed);
    const tracker = new Tracker(corpus, table, surah, corpus.wordIndex(surah, from, 0), cfg);
    const ref = { column: tracker.column.slice(), cursorCell: tracker.cursorCell, cursorLocalWord: -1 };
    for (const h of chars) {
      const cost = referenceStep(tracker, ref, h);
      tracker.feed([h]);
      expect(tracker.cursorCell).toBe(ref.cursorCell);
      expect(tracker.cursorLocalWord).toBe(ref.cursorLocalWord);
      expect(tracker.cursorCost).toBe(cost);
      expect(firstDiff(tracker.column, ref.column)).toBe(-1);
    }
  });

  it("retract(n) is the tracker that never heard the last n chars", () => {
    const chars = perturbed(recitation(67, 1, 6), 5);
    const start = corpus.wordIndex(67, 1, 0);
    const tracker = new Tracker(corpus, table, 67, start, cfg);
    tracker.feed(chars);
    for (const n of [7, 40, 0, 1000]) {
      const keep = Math.max(0, tracker.heard.length - n);
      const kept = tracker.heard.slice(0, keep);
      tracker.retract(n);
      const fresh = new Tracker(corpus, table, 67, start, cfg);
      fresh.feed(kept);
      expect(tracker.heard).toEqual(fresh.heard);
      expect(tracker.trail).toEqual(fresh.trail);
      expect(tracker.costs).toEqual(fresh.costs);
      expect(firstDiff(tracker.column, fresh.column)).toBe(-1);
      expect([tracker.cursorCell, tracker.cursorCost, tracker.lost]).toEqual([fresh.cursorCell, fresh.cursorCost, fresh.lost]);
      tracker.feed(chars.slice(keep, keep + 25));
      fresh.feed(chars.slice(keep, keep + 25));
      expect(firstDiff(tracker.column, fresh.column)).toBe(-1);
    }
  });
});

describe("verdict trace caching", () => {
  it.each([
    [67, 1, 14, 11],
    [18, 1, 12, 12],
    [104, 1, 9, 13],
  ])("returns what an uncached trace would, at every step (surah %i:%i-%i, seed %i)", (surah, from, to, seed) => {
    const chars = perturbed(recitation(surah, from, to), seed);
    expect(chars.length).toBeGreaterThan(300); // crosses a segment cut
    const tracker = new Tracker(corpus, table, surah, corpus.wordIndex(surah, from, 0), cfg);
    const tracer = new VerdictTracer(tracker, table, cfg);
    let runs = 0;
    for (let i = 0; i < chars.length; i++) {
      tracker.feed([chars[i]!]);
      if (tracker.trail.length > 1 && tracker.trail.at(-1)! < tracker.trail.at(-2)!) runs++;
      if (i % 5 && i !== chars.length - 1) continue;
      for (const settled of [false, true]) {
        const got = tracer.verdicts(settled);
        expect(tracer.verdicts(settled)).toBe(got); // memoised until the tracker moves
        expect(got).toEqual(new VerdictTracer(tracker, table, cfg).verdicts(settled));
      }
    }
    expect(runs).toBeGreaterThan(0); // the recitation really did jump back
  });

  it("drops its caches when the tracker retracts", () => {
    const chars = perturbed(recitation(112, 1, 4), 21);
    const tracker = new Tracker(corpus, table, 112, corpus.wordIndex(112, 1, 0), cfg);
    const tracer = new VerdictTracer(tracker, table, cfg);
    tracker.feed(chars);
    tracer.verdicts(true);
    tracker.retract(20);
    tracker.feed(chars.slice(chars.length - 20, chars.length - 10));
    expect(tracer.verdicts(true)).toEqual(new VerdictTracer(tracker, table, cfg).verdicts(true));
  });
});

describe("relocation", () => {
  function tokens(text: string, startFrame: number): CtcToken[] {
    return [...text].map((sym, i) => ({ sym, frame: startFrame + 2 * i, margin: 0.95 }));
  }

  it("moves to a different surah, searching only on ticks that could relocate", () => {
    const index = new QuranIndex(corpus, cfg);
    const search = vi.spyOn(index, "search");
    const engine = new RecitationEngine(corpus, index, cfg);
    engine.startSearch();
    const events: string[] = [];
    let frame = 0;
    const feedText = (text: string) => {
      for (let i = 0; i < text.length; i += 6) {
        const chunk = text.slice(i, i + 6);
        frame += 12;
        for (const ev of engine.feed(tokens(chunk, frame - 12), frame)) {
          events.push(ev.type === "relocated" ? `relocated:${ev.to.surah}` : ev.type === "located" ? `located:${ev.surah}` : ev.type);
        }
      }
    };
    feedText(recitation(36, 1, 12));
    expect(events).toContain("located:36");
    const searchesWhileTracking = search.mock.calls.length;
    feedText(recitation(36, 13, 20));
    // Healthy tracking: the relocation tick no longer searches every 37 frames.
    expect(search.mock.calls.length).toBe(searchesWhileTracking);
    feedText(recitation(67, 1, 12));
    expect(events).toContain("relocated:67");
    expect(engine.tracker?.surah).toBe(67);
  });
});
