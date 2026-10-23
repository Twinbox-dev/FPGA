from __future__ import annotations

import re
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
RUNS=ROOT/'board_media/td_project/media_net_Runs'
OUT=ROOT/'boardtest/captures/multiview_live/media_source_diag'
SOURCES=OUT/'sources'
SOURCES.mkdir(parents=True,exist_ok=True)

source_path=(ROOT/'board_media/user_source/hdl_source/media_image_source.v').resolve()
control_path=(ROOT/'board_media/user_source/hdl_source/media_control_core.v').resolve()
source=source_path.read_text(encoding='utf-8')
control=control_path.read_text(encoding='utf-8')

def once(text,old,new):
    if text.count(old)!=1: raise ValueError(f'patch anchor count {text.count(old)}: {old!r}')
    return text.replace(old,new,1)

source=once(source,'reg [2:0] state;','reg [2:0] state;\n    reg [1:0] debug_error_reason;')
source=once(source,'assign source_status={error,state,file_done_seen,format_done_seen,img_ok,format_error};',
    "assign source_status=error ? {1'b1,debug_error_reason,index_latched} :\n                          {error,state,file_done_seen,format_done_seen,img_ok,format_error};")
source=once(source,'state<=IDLE;index_latched<=0;audio_index_latched<=0;pair_scan_index<=0;',
    'state<=IDLE;index_latched<=0;audio_index_latched<=0;pair_scan_index<=0;debug_error_reason<=0;')
source=once(source,'index_latched<=file_index;busy<=1;error<=0;frame_clear<=1;',
    'index_latched<=file_index;busy<=1;error<=0;debug_error_reason<=0;frame_clear<=1;')
source=once(source,'end else begin error<=1;busy<=0;done_toggle<=~done_toggle;state<=IDLE;end\n                end\n                PAIR_SCAN:',
    'end else begin error<=1;debug_error_reason<=2\'d1;busy<=0;done_toggle<=~done_toggle;state<=IDLE;end\n                end\n                PAIR_SCAN:')
source=source.replace("debug_error_reason<=2'd1;busy<=0;done_toggle<=~done_toggle;state<=IDLE;end\n                end\n                PAIR_SCAN:",
    "debug_error_reason<=!pl_valid ? 2'd1 : 2'd2;busy<=0;done_toggle<=~done_toggle;state<=IDLE;end\n                end\n                PAIR_SCAN:",1)
source=once(source,'end else begin error<=1;busy<=0;done_toggle<=~done_toggle;state<=IDLE;end\n                end else if(fat_error) begin error<=1;busy<=0;done_toggle<=~done_toggle;state<=IDLE;end',
    'end else begin error<=1;debug_error_reason<=2\'d2;busy<=0;done_toggle<=~done_toggle;state<=IDLE;end\n                end else if(fat_error) begin error<=1;debug_error_reason<=2\'d3;busy<=0;done_toggle<=~done_toggle;state<=IDLE;end')
source=once(source,'if(img_error || fat_error || format_error) begin error<=1;state<=CANCEL;end',
    'if(img_error || fat_error || format_error) begin error<=1;debug_error_reason<=2\'d3;state<=CANCEL;end')

control=once(control,'else if(image_source_busy) begin',
    'else if(image_source_busy || image_source_status[7]) begin')
control=control.replace("else if(image_source_busy || image_source_status[7]) begin\n                last_field={4'hF,image_source_status,fat_state[3:0]};\n                middle_field=sd_stream_debug;",
    "else if(image_source_busy || image_source_status[7]) begin\n                last_field={4'hF,image_source_status,fat_state[3:0]};\n                middle_field={26'd0,first_bmp};",1)

overrides={source_path:SOURCES/'media_image_source.v',control_path:SOURCES/'media_control_core.v'}
overrides[source_path].write_text(source,encoding='utf-8')
overrides[control_path].write_text(control,encoding='utf-8')

project_root=ROOT/'board_media/td_project'
project_al=(project_root/'media_net.al').read_text(encoding='utf-8')
# Preserve the original project Path so every unchanged relative source and
# constraint resolves exactly as the product build; override only the two files.
project_al=project_al.replace('../user_source/hdl_source/media_image_source.v',
                              overrides[source_path].as_posix())
project_al=project_al.replace('../user_source/hdl_source/media_control_core.v',
                              overrides[control_path].as_posix())
(OUT/'media_net.al').write_text(project_al,encoding='utf-8')
# The TD-generated run.bat resolves %RUN_DIR%..\..\media_net.al. Here the
# isolated run directory is OUT/<stage>, so that path is OUT.parent.
(OUT.parent/'media_net.al').write_text(project_al,encoding='utf-8')

for stage in ('syn_1','phy_1'):
    original=RUNS/stage; destination=OUT/stage;destination.mkdir(exist_ok=True)
    project=(original/'media_net.prj').read_text(encoding='utf-8')
    def relocate(match):
        path=(original/match.group(1)).resolve()
        return '<File Path="'+overrides.get(path,path).as_posix()+'">'
    project=re.sub(r'<File Path="([^"]+)">',relocate,project)
    (destination/'media_net.prj').write_text(project,encoding='utf-8')
    cfg=(original/'settings.cfg').read_text(encoding='utf-8')
    cfg=cfg.replace('../../../user_source/',(ROOT/'board_media/user_source').as_posix()+'/')
    (destination/'settings.cfg').write_text(cfg,encoding='utf-8')
    (destination/'run.bat').write_bytes((original/'run.bat').read_bytes())
print(OUT)
print('media diagnostic source status: on image-source error, expose {reason,index} through I/0x0047')
