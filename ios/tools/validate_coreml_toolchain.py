# validate_coreml_toolchain.py
# Requirement: prove isolated toolchain can convert, load and predict on local macOS.
import json
import platform
from pathlib import Path
import sys
import numpy as np
import torch
import coremltools as ct

ROOT=Path(__file__).resolve().parents[2]
torch.set_num_threads(2)
class Smoke(torch.nn.Module):
    def forward(self,x):
        return x*2+1

x=torch.tensor([[1.,2.,3.,4.]])
traced=torch.jit.trace(Smoke().eval(),x)
m=ct.convert(traced,inputs=[ct.TensorType(name='x',shape=x.shape)],outputs=[ct.TensorType(name='y')],
             convert_to='mlprogram',minimum_deployment_target=ct.target.iOS17,
             compute_precision=ct.precision.FLOAT32,compute_units=ct.ComputeUnit.CPU_ONLY)
p=ROOT/'ios/converted/toolchain-smoke.mlpackage'
p.parent.mkdir(exist_ok=True)
m.save(str(p))
y=m.predict({'x':x.numpy()})['y']
np.testing.assert_array_equal(y,x.numpy()*2+1)
r={'status':'MACOS_CPU_SMOKE_PASS','python':sys.version,'executable':sys.executable,
   'torch':torch.__version__,'coremltools':ct.__version__,'numpy':np.__version__,
   'platform':platform.platform(),'input':x.tolist(),'output':y.tolist(),
   'scope':'Toolchain smoke only, no CosyVoice conversion, iPhone execution, or ANE residency claim'}
(ROOT/'ios/validation/provenance/coreml-toolchain.json').write_text(json.dumps(r,indent=2)+'\n')
print(json.dumps(r,indent=2))
# Purpose: validate local conversion runtime; upstream: none, arithmetic diagnostic only.
# Environment: .venv-coreml; generated 2026-09-29 America/New_York; new file, all lines added.
