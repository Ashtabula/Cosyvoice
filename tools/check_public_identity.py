#!/usr/bin/env python3
#@title check_public_identity.py
# Requirement: fail closed if the explicit public SDK snapshot scope contains retired personal submitter identities or if canonical actacomes identity files are missing.
from __future__ import annotations
import re,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]; IOS=ROOT/"ios"; PATHS=IOS/"public_snapshot_paths.txt"; SELF=Path(__file__).resolve()
def parts(*x): return "".join(x)
first=parts("zi","qi"); last=parts("zh","u"); compact=first+last; host=last+"z"; numbered=host+"0609"; dotted=parts("zi","gi",".",last)
patterns={
 "personal full name":re.compile(rf"\b{re.escape(first)}\s+{re.escape(last)}\b",re.I),
 "reversed personal full name":re.compile(rf"\b{re.escape(last)}\s+{re.escape(first)}\b",re.I),
 "legacy compact username":re.compile(rf"\b{re.escape(compact)}\b",re.I),
 "legacy numbered username":re.compile(rf"\b{re.escape(numbered)}\b",re.I),
 "legacy dotted username":re.compile(rf"\b{re.escape(dotted)}\b",re.I),
 "legacy host alias":re.compile(rf"\b{re.escape(host)}(?:[-_][A-Za-z0-9._-]+)?\b",re.I),
 "legacy personal Gmail":re.compile(rf"\b(?:{re.escape(first)}(?:\.{re.escape(last)})?|{re.escape(numbered)}|{re.escape(dotted)})@gmail\.com\b",re.I),
 "legacy macOS home":re.compile(rf"/Users/(?:{re.escape(first)}|{re.escape(compact)}|{re.escape(last)})\b",re.I),
 "legacy Linux home":re.compile(rf"/home/{re.escape(host)}\b",re.I),
}
def specs():
    return [x.strip() for x in PATHS.read_text().splitlines() if x.strip() and not x.lstrip().startswith("#")]
def files():
    tracked=subprocess.check_output(["git","-C",str(ROOT),"ls-files"],text=True).splitlines(); out=[]
    for spec in specs():
        prefix="ios/"+spec
        if spec.endswith("/"): out += [Path(x) for x in tracked if x.startswith(prefix)]
        elif prefix in tracked: out.append(Path(prefix))
        else: raise RuntimeError(f"public snapshot path is not tracked: {spec}")
    out += [Path("LICENSE"),Path("PUBLIC_RELEASE_IDENTITY.md")]
    return sorted(set(out))
def main():
    failures=[]; scanned=0
    for rel in files():
        path=ROOT/rel
        if path.resolve()==SELF: continue
        try: text=path.read_text(encoding="utf-8")
        except UnicodeDecodeError: continue
        scanned+=1
        for label,pattern in patterns.items():
            for m in pattern.finditer(text): failures.append(f"{rel}:{text.count(chr(10),0,m.start())+1}: {label}: {m.group(0)!r}")
    required={"PUBLIC_RELEASE_IDENTITY.md":["actacomes/Cosyvoice","actacomes/CosyVoice-assets","actacomes <developer@actacomes.com>"],".mailmap":["actacomes <developer@actacomes.com>"]}
    for rel,markers in required.items():
        p=ROOT/rel
        if not p.is_file(): failures.append(f"{rel}: missing"); continue
        text=p.read_text()
        for marker in markers:
            if marker not in text: failures.append(f"{rel}: missing marker {marker!r}")
    if failures:
        print("[COSYVOICE3-PUBLIC-IDENTITY] FAIL",flush=True)
        for x in failures: print("[COSYVOICE3-PUBLIC-IDENTITY] "+x,flush=True)
        return 1
    print(f"[COSYVOICE3-PUBLIC-IDENTITY] PASS scannedTextFiles={scanned} canonicalName=actacomes canonicalEmail=developer@actacomes.com",flush=True); return 0
if __name__=="__main__": raise SystemExit(main())
# Code purpose: exact public-snapshot-scope identity hygiene without rewriting SHA-bound private history.
# Upstream source: PUBLIC_RELEASE_IDENTITY.md, .mailmap and ios/public_snapshot_paths.txt.
# Runtime environment: Python 3 standard library + Git.
# Generated time: 2026-10-03 America/New_York.
