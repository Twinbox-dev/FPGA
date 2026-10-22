#!/usr/bin/env python3
"""Extract independent WAV PCM goldens from the existing card image for RTL tests."""
import json
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT / "scripts"))
from pc_media_display_stub import read_fat32_wavs, pcm_from_wav_bytes

output=ROOT / "boardtest/captures/card_pcm"
output.mkdir(parents=True,exist_ok=True)
records={}
for name,wav in read_fat32_wavs(ROOT / "img/card_user_real.img").items():
    pcm=pcm_from_wav_bytes(wav)
    (output / (Path(name).stem.upper()+".pcm")).write_bytes(pcm)
    records[name]=len(pcm)
(output / "manifest.json").write_text(json.dumps(records,indent=2),encoding="utf-8")
print("PCM goldens:",records)
