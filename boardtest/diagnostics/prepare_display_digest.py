#!/usr/bin/env python3
"""Derive an isolated display acceptance build; production sources stay intact.

Run from the repo root, then run generated syn_1/run.bat and phy_1/run.bat.
The passive 0x0047 diagnostic replies go to PC .1:4; product traffic stays .3:1.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HDL = ROOT / "board_display/user_source/hdl_source"
RUNS = ROOT / "board_display/td_project/lab_ex5_i2s_v1.0_Runs"
PROJECT = "lab_ex5_i2s_v1.0"

def replace_once(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise ValueError(f"diagnostic patch anchor changed: {old!r}")
    return text.replace(old, new, 1)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path,
                        default=ROOT / "boardtest/captures/display_digest_stage1")
    parser.add_argument("--scan-only", action="store_true", help="prune all three write-side diagnostic records")
    parser.add_argument("--write-scan-only", action="store_true",
                        help="keep SDRAM Appwrite and scan records; prune the two producer records")
    parser.add_argument("--bypass-cv", action="store_true",
                        help="isolated acceptance build only: free CV resources; SDRAM/video reader is unchanged")
    parser.add_argument("--test-cursor", action="store_true",
                        help="isolated V1 004B x/y injection for unattended window-focus coverage")
    args = parser.parse_args()
    out = args.output.resolve()
    out.relative_to((ROOT / "boardtest/captures").resolve())
    sources = out / "sources"
    sources.mkdir(parents=True, exist_ok=True)
    top_source = HDL / "top_tf_hdmi_audio.v"
    eth_source = HDL / "ETH/eth_subsys.v"
    top = top_source.read_text(encoding="utf-8")
    eth = eth_source.read_text(encoding="utf-8")
    top = replace_once(top, "eth_subsys #(.MEDIA_PEER_IP", """wire digest_req, digest_valid, digest_ready, digest_ack;
wire [7:0] digest_data;
wire [15:0] digest_length;
eth_subsys #(.MEDIA_PEER_IP""")
    top = replace_once(top, ".media_packet_ready  (media_packet_ready)", """.media_packet_ready  (media_packet_ready),
    .digest_req(digest_req), .digest_valid(digest_valid), .digest_data(digest_data),
    .digest_length(digest_length), .digest_ready(digest_ready), .digest_ack(digest_ack)""")
    top = replace_once(top, "transition_line_read transition_line_read_m0 (", """display_frame_digest u_acceptance_digest (
    .mem_clk(ext_mem_clk), .app_clk(eth_app_clk), .producer_clk(sd_card_clk), .rst(rst_all),
    .video_ack(video_read_req_ack), .video_valid(frame_sdr_rd_valid),
    .video_audio(mem_rd_audio), .video_data(Sdr_rd_dout),
    .video_bank(view_video_layout==0 ? disp_buf_idx : {1'b0,view_video_buffer}),
    .write_valid(App_wr_en), .write_addr(App_wr_addr), .write_data(App_wr_din),
    .image_begin(media_frame_begin_valid), .source_words(media_write_len),
    .producer_start(media_write_req && !write_buf_idx[1]),
    .raw_valid(media_write_en && !write_buf_idx[1]), .raw_data(media_write_data),
    .padded_valid(media_padded_stream_valid && media_padded_stream_ready && !media_padded_stream_audio),
    .padded_data(media_padded_stream_data),
    .rx_data(eth_rx_data), .rx_valid(eth_rx_valid),
    .tx_request(digest_req), .tx_valid(digest_valid), .tx_data(digest_data),
    .tx_length(digest_length), .tx_ready(digest_ready), .tx_ack(digest_ack)
);
transition_line_read transition_line_read_m0 (""")
    if ".DIRECT_STREAM(1)" in top:
        top=replace_once(top,".producer_clk(sd_card_clk)",".producer_clk(eth_app_clk)")
    top += "\n" + (Path(__file__).parent / "display_frame_digest.v").read_text(encoding="utf-8")
    if args.scan_only or args.write_scan_only:
        pruned = [
            (".image_begin(media_frame_begin_valid)", ".image_begin(1'b0)"),
            (".producer_start(media_write_req && !write_buf_idx[1])", ".producer_start(1'b0)"),
            (".raw_valid(media_write_en && !write_buf_idx[1])", ".raw_valid(1'b0)"),
            (".padded_valid(media_padded_stream_valid && media_padded_stream_ready && !media_padded_stream_audio)",
             ".padded_valid(1'b0)")]
        if args.scan_only:
            pruned.append((".write_valid(App_wr_en)", ".write_valid(1'b0)"))
        for before, after in pruned:
            top=replace_once(top,before,after)
    if args.bypass_cv:
        top,count=re.subn(r"cv_pixel_effects_runtime\s*#\(.*?\)\s*u_cv_pixel_effects\s*\(.*?\);",
            "// Isolated memory-scan acceptance only; product CV RTL stays intact.\n"
            "assign cv_data=vout_data_raw;assign cv_de=de;assign cv_vs=vs;",top,flags=re.S)
        if count!=1:raise ValueError("CV diagnostic bypass anchor changed")
    if args.test_cursor:
        top=replace_once(top,"wire digest_req, digest_valid, digest_ready, digest_ack;",
            "wire diagnostic_cursor_enabled;wire [10:0] diagnostic_cursor_x;wire [9:0] diagnostic_cursor_y;\n"
            "display_test_cursor u_test_cursor(.clk(eth_app_clk),.rst(rst_all),.data(eth_rx_data),.valid(eth_rx_valid),\n"
            "    .enabled(diagnostic_cursor_enabled),.x(diagnostic_cursor_x),.y(diagnostic_cursor_y));\n"
            "wire digest_req, digest_valid, digest_ready, digest_ack;")
        top=replace_once(top,".cursor_x(view_cursor_x1),.cursor_y(view_cursor_y1)",
            ".cursor_x(diagnostic_cursor_enabled ? diagnostic_cursor_x : view_cursor_x1),"
            ".cursor_y(diagnostic_cursor_enabled ? diagnostic_cursor_y : view_cursor_y1)")
        top+="\n"+(Path(__file__).parent / "display_test_cursor.v").read_text(encoding="utf-8")
    eth = replace_once(eth, "output wire        media_packet_ready\n", """output wire        media_packet_ready,
    input wire digest_req, digest_valid,
    input wire [7:0] digest_data,
    input wire [15:0] digest_length,
    output wire digest_ready, digest_ack
""")
    eth = replace_once(eth, "wire [31:0] tx_dst_ip = MEDIA_PEER_IP;", """wire digest_chunk_active;
    wire [31:0] tx_dst_ip = digest_chunk_active ? MEDIA_PEER_IP : 32'hc0a88901;""")
    eth = replace_once(eth, "wire [15:0] tx_dst_port = MEDIA_PEER_UDP_PORT;",
                       "wire [15:0] tx_dst_port = digest_chunk_active ? MEDIA_PEER_UDP_PORT : 16'd4;")
    eth = replace_once(eth, ".ctrl_req     (1'b0), .ctrl_valid(1'b0),", ".ctrl_req     (digest_req), .ctrl_valid(digest_valid),")
    eth = replace_once(eth, ".ctrl_data    (8'd0), .ctrl_length(16'd0),", ".ctrl_data    (digest_data), .ctrl_length(digest_length),")
    eth = replace_once(eth, ".ctrl_ready   (), .ctrl_ack(),", ".ctrl_ready   (digest_ready), .ctrl_ack(digest_ack),")
    eth = replace_once(eth, ".chunk_active(), .chunk_owner(),", ".chunk_active(), .chunk_owner(digest_chunk_active),")
    overrides = {top_source.resolve(): sources / "top_tf_hdmi_audio.v",
                 eth_source.resolve(): sources / "eth_subsys.v"}
    overrides[top_source.resolve()].write_text(top, encoding="utf-8")
    overrides[eth_source.resolve()].write_text(eth, encoding="utf-8")
    source_project = (RUNS / "syn_1" / (PROJECT + ".prj")).read_text(encoding="utf-8")
    for source_name in re.findall(r'<File Path="([^"]+)">', source_project):
        source_path = (RUNS / "syn_1" / source_name).resolve()
        if source_path.suffix.lower() not in (".v", ".sv", ".vh") or source_path in overrides:
            continue
        raw = source_path.read_bytes()
        if b'`include' not in raw and not re.search(rb'"[^"\r\n]+\.(?:mem|hex|mif|coe)"', raw):
            continue
        def resolve_asset(name):
            candidates = (source_path.parent / name, ROOT / "board_display/td_project" / name,
                          HDL / "include" / name)
            target = next((p.resolve() for p in candidates if p.is_file()), None)
            if target is None:
                raise ValueError(f"cannot relocate include {name!r} from {source_path}")
            return target.as_posix().encode("utf-8")
        def relocate_include(match):
            return b'`include "' + resolve_asset(match.group(1).decode("utf-8")) + b'"'
        patched = re.sub(rb'`include\s+"([^"]+)"', relocate_include, raw)
        patched = re.sub(rb'"([^"\r\n]+\.(?:mem|hex|mif|coe))"',
                         lambda m: b'"' + resolve_asset(m.group(1).decode("utf-8")) + b'"', patched)
        copy = sources / ("include_" + source_path.name)
        copy.write_bytes(patched)
        overrides[source_path] = copy
    for stage in ("syn_1", "phy_1"):
        destination = out / stage
        destination.mkdir(exist_ok=True)
        original = RUNS / stage
        # TD's XML-like project contains unescaped UsedInP&R attributes, so
        # relocate only File Path strings rather than using a strict XML parser.
        project = (original / (PROJECT + ".prj")).read_text(encoding="utf-8")
        def relocate(match):
            path = (original / match.group(1)).resolve()
            return '<File Path="' + overrides.get(path, path).as_posix() + '">'
        project = re.sub(r'<File Path="([^"]+)">', relocate, project)
        (destination / (PROJECT + ".prj")).write_text(project, encoding="utf-8")
        cfg = (original / "settings.cfg").read_text(encoding="utf-8")
        cfg = cfg.replace("../../../user_source/", (ROOT / "board_display/user_source").as_posix() + "/")
        (destination / "settings.cfg").write_text(cfg, encoding="utf-8")
        (destination / "run.bat").write_bytes((original / "run.bat").read_bytes())
    manifest = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in (top_source, eth_source, Path(__file__).parent / "display_frame_digest.v")}
    (out / "source_manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(out)
    print("SRAM candidate:", out / "phy_1" / (PROJECT + ".bit"))

if __name__ == "__main__":
    main()
