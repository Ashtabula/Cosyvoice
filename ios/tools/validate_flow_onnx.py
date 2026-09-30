# validate_flow_onnx.py
# Requirement: use the released ONNX estimator as an independent numerical oracle.
import json
from pathlib import Path
import numpy as np
import onnxruntime as ort
import torch
ROOT=Path(__file__).resolve().parents[2]
options=ort.SessionOptions(); options.intra_op_num_threads=4
session=ort.InferenceSession(str(ROOT/'pretrained_models/Fun-CosyVoice3-0.5B-2512/flow.decoder.estimator.fp32.onnx'),sess_options=options,providers=['CPUExecutionProvider'])
names=[x.name for x in session.get_inputs()]; rows=[]
for i in range(10):
    r=torch.load(ROOT/f'ios/validation/phase0/run-002/tensors/estimator_{i:02d}.pt',weights_only=True)
    y=session.run(None,{n:t.numpy() for n,t in zip(names,r['args'])})[0]
    expected=r['output'].numpy().astype(np.float64); diff=y.astype(np.float64)-expected
    m={'step':i,'max_abs':float(np.abs(diff).max()),'rmse':float(np.sqrt((diff**2).mean())),'relative_l2':float(np.linalg.norm(diff)/np.linalg.norm(expected))}
    rows.append(m); print(m,flush=True)
report={'provider':'CPUExecutionProvider','rows':rows,'all_pass':all(r['max_abs']<=0.005 and r['relative_l2']<=0.001 for r in rows),'scope':'official ONNX vs frozen PyTorch; not Core ML or device validation'}
(ROOT/'ios/validation/flow/official-onnx.json').write_text(json.dumps(report,indent=2)+'\n')
# Purpose: independent released estimator check; upstream: pinned official FP32 ONNX.
# Environment: .venv-upstream CPU; generated 2026-09-29 America/New_York; new file.
