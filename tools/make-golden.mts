// Golden session streams from the v0.1 TypeScript engine, for the Swift port.
//
//   git worktree add /tmp/v0.1 v0.1          # the TS SDK lives there
//   cd /tmp/v0.1/web/frontend && npm ci      # for tsx
//   TS_SRC=/tmp/v0.1/packages/core/src CORPUS=assets/zipformer_quran.json \
//     npx tsx <repo>/tools/make-golden.mts > <repo>/RecitationKit/Tests/RecitationKitTests/Fixtures/sessions.json
//
// A scripted model stands in for ONNX: each CTC frame is one token id (250 =
// blank) scored log(0.9), the next class log(0.05), everything else log(0.001).
import { readFileSync } from "node:fs";

const SRC = process.env.TS_SRC!;
const { ZipformerSession } = await import(`${SRC}/recitation/session.ts`);
const { QuranCorpus } = await import(`${SRC}/recitation/corpus.ts`);
const { TOKENS } = await import(`${SRC}/recitation/tokens.ts`);
const corpusJson = JSON.parse(readFileSync(process.env.CORPUS!, "utf8"));
const corpus = new QuranCorpus(corpusJson);

const VOCAB = 251, BLANK = 250, FRAMES_PER_RUN = 12, CHUNK = 7680;
const HIGH = Math.fround(Math.log(0.9)), SECOND = Math.fround(Math.log(0.05)), LOW = Math.fround(Math.log(0.001));
const TOKEN = new Map<string, number>();
TOKENS.forEach((s: string, id: number) => { if (s.length === 1 && !TOKEN.has(s)) TOKEN.set(s, id); });

class Tensor { constructor(public type: string, public data: any, public dims: readonly number[]) {} }
class ScriptedOrt {
  pos = 0;
  constructor(private frames: number[]) {}
  get done() { return this.pos >= this.frames.length; }
  async run(feeds: Record<string, any>) {
    const out: Record<string, any> = {};
    for (const [name, t] of Object.entries(feeds)) if (name !== "x") out[`new_${name}`] = t;
    const data = new Float32Array(FRAMES_PER_RUN * VOCAB).fill(LOW);
    for (let f = 0; f < FRAMES_PER_RUN; f++) {
      const id = this.frames[this.pos++] ?? BLANK;
      data[f * VOCAB + id] = HIGH;
      data[f * VOCAB + ((id + 1) % VOCAB)] = SECOND;
    }
    out.log_probs = new Tensor("float32", data, [1, FRAMES_PER_RUN, VOCAB]);
    return out;
  }
}

function rng(seed: number) { let s = seed >>> 0 || 1; return () => { s = (Math.imul(s, 1664525) + 1013904223) >>> 0; return s / 2 ** 32; }; }
const ph = (s: number, a: number) => corpus.ayahPhonemes(s, a);
const range = (s: number, a: number, b: number) => { let t = ""; for (let i = a; i <= b; i++) t += ph(s, i); return t; };
const words = (s: number, a: number) => { const f = corpus.ayahFirstWord(s, a); return Array.from({ length: corpus.ayahWordCount(s, a) }, (_, i) => corpus.wordPhonemes(f + i)); };
function frames(text: string, o: { perChar?: number; seed?: number; sub?: number; del?: number; ins?: number; pause?: number } = {}): number[] {
  const r = rng(o.seed ?? 1); const out: number[] = [];
  for (const ch of text) {
    const id = TOKEN.get(ch)!;
    if (o.del && r() < o.del) continue;
    out.push(o.sub && r() < o.sub ? Math.floor(r() * 250) : id);
    for (let k = 1; k < (o.perChar ?? 2); k++) out.push(BLANK);
    if (o.ins && r() < o.ins) out.push(Math.floor(r() * 250), BLANK);
    if (o.pause && r() < o.pause) for (let k = 0; k < 20 + Math.floor(r() * 40); k++) out.push(BLANK);
  }
  return out;
}
const silence = (n: number) => Array(n).fill(BLANK);
const ISTIADHA = "ءَعُۥۥذُبِللَااهِمِنَششَييطَاانِررَجِۦۦم";

type Scenario = { name: string; frames: number[]; mode?: "tracking" | "correction" };
const scenarios: Scenario[] = [];
scenarios.push({ name: "fatiha", frames: frames(range(1, 1, 7)) });
scenarios.push({ name: "baqarah 1-12 with pauses", frames: frames(range(2, 1, 12), { pause: 0.02 }) });
for (let seed = 1; seed <= 3; seed++) scenarios.push({ name: `mulk perturbed seed ${seed}`, frames: frames(range(67, 1, 12), { seed, sub: 0.06 * (seed % 3), del: 0.03 * (seed % 2), ins: 0.03, pause: 0.01 }) });
{
  const w = words(36, 3), w2 = words(36, 4);
  const t = range(36, 1, 2) + w.slice(0, 2).join("") + w.slice(0, 3).join("") + w.slice(3).join("") + w2.filter((_, i) => i !== 1).join("") + range(36, 6, 9);
  scenarios.push({ name: "yasin repeats and skips", frames: frames(t) });
  scenarios.push({ name: "yasin repeats and skips (correction)", frames: frames(t), mode: "correction" });
}
scenarios.push({ name: "surah switch yasin to mulk", frames: [...frames(range(36, 1, 6)), ...frames(range(67, 1, 6))] });
scenarios.push({ name: "long pause goes idle", frames: [...frames(range(55, 1, 10)), ...silence(400), ...frames(range(55, 11, 20))] });
scenarios.push({ name: "garbage then quran", frames: [...frames("سشصضطظعغفقكلمنهوي".repeat(12), { sub: 0.5, seed: 9 }), ...frames(range(78, 1, 10))] });
scenarios.push({ name: "istiadha basmala ikhlas falaq nas", frames: frames(ISTIADHA + ph(1, 1) + range(112, 1, 4) + range(113, 1, 5) + range(114, 1, 6)) });
scenarios.push({ name: "alafasy pace", frames: frames(range(1, 1, 7) + range(2, 1, 5), { perChar: 5, pause: 0.02 }) });
for (let seed = 1; seed <= 4; seed++) {
  const w = words(104, 3);
  const text = seed % 2 ? ph(104, 1) + ph(104, 2) + [w[0], "", w[2], w[3]].join("") + range(104, 4, 9) : ph(104, 1) + ph(104, 3) + range(104, 4, 9);
  scenarios.push({ name: `humazah mistakes seed ${seed} (correction)`, frames: frames(text, { seed, sub: 0.02 * seed }), mode: "correction" });
}
scenarios.push({ name: "kahf 1-30 perturbed (correction)", frames: frames(range(18, 1, 30), { seed: 3, sub: 0.03, del: 0.02, ins: 0.02, pause: 0.01 }), mode: "correction" });
scenarios.push({ name: "baqarah 1-25 perturbed", frames: frames(range(2, 1, 25), { seed: 5, sub: 0.04, del: 0.02, ins: 0.02, pause: 0.01 }) });
scenarios.push({ name: "near silence only", frames: silence(600) });

function normalize(m: any): any {
  switch (m.type) {
    case "verse_match": return { type: m.type, surah: m.surah, ayah: m.ayah, confidence: m.confidence };
    case "raw_transcript": return { type: m.type, length: m.text.length, confidence: m.confidence };
    case "correction": return { type: m.type, state: m.state, totalWords: m.totalWords };
    case "debug": { const { at: _at, ...rest } = m; return rest; }
    default: return m;
  }
}

async function run(s: Scenario) {
  const ort = new ScriptedOrt(s.frames);
  const session = await ZipformerSession.create({ session: ort as any, Tensor: Tensor as any, corpus: corpusJson, debug: true });
  if (s.mode) session.setMode(s.mode);
  const out: any[] = [];
  const push = (ms: any[]) => { for (const m of ms) out.push(normalize(m)); };
  const audio = new Float32Array(CHUNK);
  let flags = 0, retryChunks = 0;
  while (!ort.done) {
    push(await session.feed(audio));
    const phase = session.correction.state.phase;
    if (phase === "error") { flags++; push(session.correct(flags % 3 === 1 ? "retry" : flags % 3 === 2 ? "dismiss" : "review_later")); retryChunks = 0; }
    else if (phase === "retrying" && ++retryChunks > 15) push(session.correct("stop_retry"));
    else if (phase === "corrected") push(session.correct("continue"));
    out.push({ type: "probe", verdicts: session.verdicts().length, state: session.engineState });
  }
  push(await session.stop());
  out.push({ type: "end", transcript: session.transcript, tallies: session.tallies, verses: session.verses });
  return out;
}

const result = [];
for (const s of scenarios) {
  result.push({ name: s.name, mode: s.mode ?? "tracking", frames: s.frames, messages: await run(s) });
}
process.stdout.write(JSON.stringify({ generatedFrom: "v0.1 @tilawa/core ZipformerSession", logProbs: { high: HIGH, second: SECOND, low: LOW }, chunkSamples: CHUNK, scenarios: result }));
