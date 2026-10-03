# Decode the benchmark recordings to 16 kHz mono float32 (soxr), one .f32 per clip.
import av, numpy as np, soxr, sys, os, json
src, dst = sys.argv[1], sys.argv[2]
os.makedirs(dst, exist_ok=True)
for f in sorted(os.listdir(src)):
    if f.endswith('.json'): continue
    c = av.open(os.path.join(src, f)); chunks=[]; sr=None
    for frame in c.decode(audio=0):
        a = frame.to_ndarray().astype(np.float32); sr = frame.sample_rate
        if a.dtype.kind == 'i': a = a / 32768
        if frame.format.is_planar: a = a.mean(axis=0)
        else: a = a.reshape(-1, len(frame.layout.channels)).mean(axis=1)
        chunks.append(a)
    x = np.concatenate(chunks)
    if np.abs(x).max() > 2: x = x / 32768
    y = soxr.resample(x, sr, 16000).astype(np.float32)
    y.tofile(os.path.join(dst, os.path.splitext(f)[0] + '.f32'))
print(len(os.listdir(dst)), 'clips decoded')
