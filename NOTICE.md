# Notices

This repository is MIT-licensed (`LICENSE`). The model and phoneme corpus the app bundles are **not**, and neither is the Amiri font.

## Acknowledgements

- **Quran-Lab** ([`Quran-Lab/zipformer_p-arabic-v3`](https://huggingface.co/Quran-Lab/zipformer_p-arabic-v3), author Muno459 / Quran-Lab) provided these:
  - the streaming Zipformer2-CTC acoustic model,
  - the 251-token vocabulary,
  - the phoneme lexicon (`quran_text2phoneme.json`).

  NPL-1.2 §6 does not require attribution; we credit them anyway. Full text: [`licenses/NPL-1.2.txt`](licenses/NPL-1.2.txt).
- **alketab** ([ملقّن القرآن](https://prompter.alketab.app/), `@alketab/quran-engine`) is the design source for the recitation pipeline specified in `spec/recitation-engine-spec.md`.
  - The phoneme corpus (`zipformer_quran.json`) comes from alketab, which derived it from Quran-Lab's `quran_text2phoneme.json`.
  - Nothing from the recovered alketab engine remains in this repository. `RecitationKit/` is a clean-room MIT implementation built from that spec plus the oracle vectors in `spec/vectors/`, which were dumped from the original engine before its removal at `e172b79`.
  - The original engine's licence was unstated; we grant no licence to that recovered source.
- **k2 / icefall** (Apache-2.0) and **lhotse** (Apache-2.0) are the Zipformer training and export stack. The model was fine-tuned and blended in the research lab, which is available in history at v0.1.
- The fine-tune's training audio came from these sources. QuranTTS (`Quran-Lab/QuranTTS`, NPL-1.2) was excluded.
  - EveryAyah: `tarteel-ai/everyayah` and `greentechapps/everyayah_curated_1s_20s` (MIT)
  - QUA: `hetchyy/quranic-universal-ayahs` (CC-BY-4.0)
  - Iqra: `IqraEval/Iqra_train` (licence unstated)
  - RetaSy: `RetaSy/quranic_audio_dataset` (licence unstated)
  - TLOG: `tarteel-ai/tlog` (licence unstated)
- **ONNX Runtime** (MIT) runs on-device inference, via `microsoft/onnxruntime-swift-package-manager`.
- **Amiri** (SIL Open Font License 1.1, The Amiri Project Authors) provides the Quran typeface. Licence: `App/QuranRecitationChecker/Resources/Fonts/OFL-Amiri.txt`.
- **Display text** (`App/QuranRecitationChecker/Resources/quran-text.json`) is the Uthmani text of the v0/v0.1 web demo, repacked by `tools/make-quran-text.py`.

## Licensing of model artefacts

These artefacts are **NPL-1.2 Derivatives** of Quran-Lab's Work. NPL-1.2 §7 is share-alike: a Derivative includes models trained, fine-tuned, or *evaluated* with the Work, and datasets, lexicons, or label sets produced from it. They are **not** covered by this repository's MIT licence. They are fetched by `tools/fetch-assets.sh` into `assets/`, never committed, and bundled into the app:

- `zipformer_a0w_ep1_a05.int8.onnx`: the blended model `a0w-ep1-a0.5` (0.5 Quran-Lab v3 + 0.5 a fine-tune with waqf-2 labels and multi-ayah windows), from tilawa release `zipformer-a0w-ep1-a0.5`. It replaced `interp-gentle-a0.5` in v0.2; both use the same I/O manifest.
- `zipformer_quran.json`: the phoneme corpus
- the 251-token vocabulary, which is reproduced in `spec/vectors/tokens.json` and `RecitationKit/Sources/RecitationKit/Tokens.generated.swift`

NPL-1.2 §§3/5/9 impose two conditions:

- You may not charge for the Work or any feature it powers; hosted use is free or cost recovery only.
- Every Derivative must be distributed under NPL-1.2 (or a later Quran-Lab version).

For the App Store, this means an app that bundles these assets must be free and must not sell features they power. See [`licenses/NPL-1.2.txt`](licenses/NPL-1.2.txt).

Everything else in the repository remains MIT.
