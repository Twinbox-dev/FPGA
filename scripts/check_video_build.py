"""Verify that the current video bit was built from the current display sources."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def verify():
    manifest = json.loads((ROOT / "board_display/td_project/video_build_manifest.json").read_text(encoding="utf-8-sig"))
    if manifest["product_baseline"] != "dual-V3-beta":
        raise ValueError("unexpected video integration baseline")
    for entry in manifest["sources"] + [{"path": manifest["bit"], "sha256": manifest["bit_sha256"]}]:
        path = (ROOT / entry["path"]).resolve()
        if not path.is_relative_to(ROOT):
            raise ValueError("manifest path escapes repository")
        if hashlib.sha256(path.read_bytes()).hexdigest().upper() != entry["sha256"].upper():
            raise ValueError(f"source/bit changed since build: {entry['path']}")
    print(f"PASS: display source, project, flow configuration and bit match build {manifest['built_at']}")
    if manifest["profile"].get("link_diagnostics"):
        print("Profile: link diagnostics; 7-segment shows 8 sticky MAC/UDP/video stages and live lease/session state")
    print("Capabilities: CV=" + str(manifest["profile"].get("cv_enabled", True)) +
          ", neighborhood_cv=" + str(manifest["profile"].get("cv_neighborhood_enabled", True)) +
          ", spectrum=" + str(manifest["profile"].get("spectrum_enabled", True)))
    return manifest


if __name__ == "__main__":
    verify()
