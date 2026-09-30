#!/usr/bin/env python3
"""Compact display text for the app: Uthmani text per ayah plus surah names.

  git worktree add /tmp/v0.1 v0.1
  python3 tools/make-quran-text.py /tmp/v0.1/web/frontend/public/quran.json \
    > App/QuranRecitationChecker/Resources/quran-text.json

Source: the web demo's quran.json, which lives in the v0.1 tree only. Text is
kept verbatim except a leading byte-order mark on 1:1.
"""
import json, sys

rows = json.load(open(sys.argv[1], encoding="utf-8"))
surahs = {}
for r in rows:
    s = surahs.setdefault(r["surah"], {"n": r["surah"], "name": r["surah_name"], "nameEn": r["surah_name_en"], "ayahs": []})
    assert r["ayah"] == len(s["ayahs"]) + 1, (r["surah"], r["ayah"])
    s["ayahs"].append(r["text_uthmani"].lstrip("﻿"))
out = {"source": "v0.1 web/frontend/public/quran.json (Uthmani)", "surahs": [surahs[n] for n in sorted(surahs)]}
assert len(out["surahs"]) == 114 and sum(len(s["ayahs"]) for s in out["surahs"]) == 6236
json.dump(out, sys.stdout, ensure_ascii=False, separators=(",", ":"))
