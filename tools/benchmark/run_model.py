# Run the Zipformer over dumped windows with state carry-over (spec section 2); write log-probs.
import sys, json, numpy as np, onnxruntime as ort
model, io_path, win_path, out_path = sys.argv[1:5]
io = json.load(open(io_path))
so = ort.SessionOptions(); so.intra_op_num_threads = 2
s = ort.InferenceSession(model, so, providers=["CPUExecutionProvider"])
dt = {"float32": np.float32, "int64": np.int64}
states = {i["name"]: np.zeros(i["dims"], dt[i["dtype"]]) for i in io["inputs"] if i["name"] != "x"}
w = np.fromfile(win_path, np.float32).reshape(-1, 61, 80)
names = ["log_probs"] + ["new_" + k for k in states]
outs = []
for x in w:
    r = s.run(names, {"x": x[None], **states})
    outs.append(r[0][0])
    for k, v in zip(states, r[1:]): states[k] = v
np.concatenate(outs).astype(np.float32).tofile(out_path) if outs else open(out_path, "wb").close()
