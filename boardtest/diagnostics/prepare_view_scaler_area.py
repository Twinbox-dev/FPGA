#!/usr/bin/env python3
"""Prepare a synthesis-only TD resource measurement of the multiview scaler."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
run = ROOT / "boardtest/captures/view_scaler_area/syn_1"
run.mkdir(parents=True, exist_ok=True)
original = ROOT / "board_display/td_project/lab_ex5_i2s_v1.0_Runs/syn_1"
project = (original / "lab_ex5_i2s_v1.0.prj").read_text(encoding="utf-8")
files = []
for order, name in enumerate(("view_scale_geometry.v", "view_bilinear_shrink.v"), 1):
    source = ROOT / "board_display/user_source/hdl_source/ETH" / name
    files.append(f'<File Path="{source.as_posix()}"><FileInfo><Attr Name="UsedInSyn" Val="true"/>'
                 f'<Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/>'
                 f'<Attr Name="CompileOrder" Val="{order}"/></FileInfo></File>')
project = re.sub(r"<Source_Files>.*?</Source_Files>",
                 "<Source_Files><Verilog>"+"\n".join(files)+"</Verilog></Source_Files>",
                 project, flags=re.S)
project = project.replace("lab_ex5_i2s_v1.0", "view_scaler").replace("<LABEL>top</LABEL>",
          "<LABEL>view_bilinear_shrink</LABEL>").replace("<MODULE>top</MODULE>",
          "<MODULE>view_bilinear_shrink</MODULE>")
(run / "view_scaler.prj").write_text(project, encoding="utf-8")
(run / "clock.sdc").write_text("create_clock -period 8.000 [get_ports clk]\n", encoding="utf-8")
(run / "settings.cfg").write_text(f'''set ADCList {{}}
set IpSDCList {{}}
set SDCList {{"{(run / 'clock.sdc').as_posix()}"}}
set area_option -packarea
set device_name eagle_s20.db
set package_name EG4S20BG256
set prj_name {{view_scaler}}
set run_type syn
set start_step read_design
set end_step opt_gate
set top_model_name {{view_bilinear_shrink}}
''', encoding="utf-8")
(run / "run.bat").write_bytes((original / "run.bat").read_bytes())
print(run)
