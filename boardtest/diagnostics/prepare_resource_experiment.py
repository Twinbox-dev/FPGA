#!/usr/bin/env python3
"""Freeze a complete TD candidate without overwriting product bit/reports.

The directory layout mirrors the board, so generated project and constraint
paths retain their meaning. Each named experiment is immutable: choose a new
name for new RTL. TD is run separately, in its syn_1 then phy_1 directory.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--board", choices=("display", "media"), required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--output-root", type=Path,
                        default=ROOT / "boardtest/captures/resource_experiments",
                        help="experiment parent directory, restricted to boardtest/captures")
    parser.add_argument("--display-diagnostics", action="store_true",
                        help="enable optional display scan/cursor probes only in the frozen copy")
    args = parser.parse_args()
    if args.display_diagnostics and args.board != "display":
        parser.error("--display-diagnostics requires --board display")
    if not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", args.name):
        parser.error("name must contain lowercase letters, digits, '-' or '_'")
    board = f"board_{args.board}"
    project = "media_net" if args.board == "media" else "lab_ex5_i2s_v1.0"
    output_root = args.output_root.resolve()
    try:
        output_root.relative_to((ROOT / "boardtest/captures").resolve())
    except ValueError:
        parser.error("output root must be inside boardtest/captures")
    destination = output_root / args.name
    if destination.exists():
        raise SystemExit(f"Refusing to overwrite existing experiment: {destination}")
    source_board = ROOT / board
    target_board = destination / board
    shutil.copytree(source_board / "user_source", target_board / "user_source",
                    ignore=shutil.ignore_patterns("*.log", "*.logw", ".lock.f"))
    if args.display_diagnostics:
        top = target_board / "user_source/hdl_source/top_tf_hdmi_audio.v"
        text, count = re.subn(r"parameter DISPLAY_DIAGNOSTICS = [01];",
                             "parameter DISPLAY_DIAGNOSTICS = 1;",
                             top.read_text(encoding="utf-8"))
        if count != 1:
            raise SystemExit("Display diagnostic parameter missing or ambiguous")
        top.write_text(text, encoding="utf-8")
    source_project = source_board / "td_project"
    target_project = target_board / "td_project"
    target_project.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source_project / f"{project}.al", target_project)
    run_name = f"{project}_Runs"
    for stage in ("syn_1", "phy_1"):
        source_stage = source_project / run_name / stage
        target_stage = target_project / run_name / stage
        target_stage.mkdir(parents=True)
        for filename in (f"{project}.prj", "settings.cfg"):
            shutil.copy2(source_stage / filename, target_stage / filename)
    hashes = {p.relative_to(destination).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in target_board.rglob("*") if p.is_file()}
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT,
                                       text=True).strip()
    (destination / "manifest.json").write_text(json.dumps(
        {"base_revision": revision, "board": args.board, "files": hashes},
        indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(destination)


if __name__ == "__main__":
    main()
