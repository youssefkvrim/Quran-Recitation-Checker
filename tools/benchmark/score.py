# Score replayed sessions against the manifest: final sequence == expected (or also_accept).
import json, sys, collections
man = {s["file"].rsplit(".",1)[0]: s for s in json.load(open(sys.argv[1]))["samples"]}
rows = collections.defaultdict(list)
for line in open(sys.argv[2]):
    n, m, v, j = line.split(" ", 3); r = json.loads(j); s = man.get(n)
    if not s: continue
    exp = [f'{e["surah"]}:{e["ayah"]}' for e in s["expected_verses"]]
    alts = [[f'{e["surah"]}:{e["ayah"]}' for e in a] for a in s.get("also_accept", [])]
    ok = r["final"] == exp or r["final"] in alts
    rows[(m, v)].append((n, ok, r, exp))
for k, rs in rows.items():
    oks = sum(ok for _, ok, _, _ in rs)
    locs = sorted(r["located"] for _, _, r, _ in rs if r["located"] >= 0)
    print(f"{k[0]:6} {k[1]:8} correct {oks}/{len(rs)}  located {len(locs)}  time-to-locate p50 {locs[len(locs)//2]:.1f}s p90 {locs[len(locs)*9//10]:.1f}s")
    if "-v" in sys.argv:
        for n, ok, r, exp in rs:
            if not ok: print("   MISS", n, "want", exp, "got", r["final"], "loc", r["located"])
