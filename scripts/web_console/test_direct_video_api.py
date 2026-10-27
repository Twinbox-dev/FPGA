import io
import binascii
import json
import socket
import struct
import threading
import time
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import app as web


class FakeProcess:
    pid = 12345

    def __init__(self):
        self.returncode = None

    def poll(self):
        return self.returncode

    def wait(self, timeout=None):
        self.returncode = 0
        return self.returncode

    def kill(self):
        self.returncode = -9


class DirectVideoApiTests(unittest.TestCase):
    def setUp(self):
        web.stop_video_sender()
        self.old_link = web.eth_link
        self.old_capture_dir = web.VIDEO_CAPTURE_DIR
        test_root = Path(__file__).resolve().parents[2] / "boardtest" / "captures"
        test_root.mkdir(parents=True, exist_ok=True)
        self.tempdir = tempfile.TemporaryDirectory(dir=test_root)
        web.VIDEO_CAPTURE_DIR = Path(self.tempdir.name)
        web.eth_link = type("Link", (), {"is_open": lambda _self: True,
                                          "image_upload_active": False})()
        self.client = web.app.test_client()

    def tearDown(self):
        with patch.object(web.subprocess, "run"):
            web.stop_video_sender()
        web.eth_link = self.old_link
        web.VIDEO_CAPTURE_DIR = self.old_capture_dir
        self.tempdir.cleanup()

    def test_start_status_rejects_still_upload_and_stop_cleans_source(self):
        fake = FakeProcess()
        with patch.dict(web.os.environ, {"VIDEO_FFMPEG": "ffmpeg"}), \
             patch.object(web.shutil, "which", return_value="C:/ffmpeg.exe"), \
             patch.object(web.subprocess, "Popen", return_value=fake):
            response = self.client.post("/api/eth/video/start", data={
                "video": (io.BytesIO(b"fake mp4 data"), "sample.mp4")
            }, content_type="multipart/form-data")
        self.assertEqual(response.status_code, 200, response.get_json())
        self.assertTrue(response.get_json()["ok"])
        saved_path = Path(web.VIDEO_PATH)
        self.assertTrue(saved_path.is_file())
        self.assertTrue(self.client.get("/api/eth/video/status").get_json()["active"])

        still = self.client.post("/api/eth/upload-image", data={})
        self.assertEqual(still.status_code, 409)

        with patch.object(web.subprocess, "run"):
            stopped = self.client.post("/api/eth/video/stop")
        self.assertEqual(stopped.status_code, 200)
        self.assertFalse(self.client.get("/api/eth/video/status").get_json()["active"])
        self.assertFalse(saved_path.exists())

    def test_start_requires_ethernet_connection(self):
        web.eth_link = type("Link", (), {"is_open": lambda _self: False,
                                          "image_upload_active": False})()
        response = self.client.post("/api/eth/video/start", data={
            "video": (io.BytesIO(b"fake"), "sample.mp4")
        }, content_type="multipart/form-data")
        self.assertEqual(response.status_code, 400)

    def test_video_busy_keeps_status_and_volume_and_rejects_other_controls(self):
        commands = []
        web.eth_link.send_key = lambda key: commands.append(key)
        with patch.object(web, "resolve_ffmpeg", return_value="ffmpeg"), \
             patch.object(web.subprocess, "Popen", return_value=FakeProcess()):
            started = self.client.post("/api/eth/video/start", data={
                "video": (io.BytesIO(b"fake"), "sample.mp4")
            }, content_type="multipart/form-data")
        self.assertEqual(started.status_code, 200)
        for key in ("n", "p", "a", "d", "6", "7", "8", "w"):
            self.assertEqual(self.client.post("/api/cmd", json={"mode": "eth", "key": key}).status_code, 409)
        for key in ("s", "+", "-"):
            self.assertEqual(self.client.post("/api/cmd", json={"mode": "eth", "key": key}).status_code, 200)
        self.assertEqual(commands, ["s", "+", "-"])
        self.assertEqual(self.client.post("/api/subtitle", json={"mode": "eth", "text": "hello"}).status_code, 409)

    def test_image_request_reservation_prevents_video_start(self):
        web.VIDEO_IMAGE_REQUEST_ACTIVE = True
        try:
            with patch.object(web, "resolve_ffmpeg", return_value="ffmpeg"), \
                 patch.object(web.subprocess, "Popen") as launch:
                response = self.client.post("/api/eth/video/start", data={
                    "video": (io.BytesIO(b"fake"), "sample.mp4")
                }, content_type="multipart/form-data")
            self.assertEqual(response.status_code, 409)
            launch.assert_not_called()
        finally:
            web.VIDEO_IMAGE_REQUEST_ACTIVE = False

    def test_first_stage_capabilities_are_visible_and_enforced(self):
        metadata = self.client.get("/api/keys").get_json()
        self.assertEqual(metadata["capabilities"], {"cv": False, "spectrum": False})
        available = {item["key"]: item["available"] for item in metadata["keys"]}
        for key in ("g", "b", "e", "h", "w", "q", ";", "'"):
            self.assertFalse(available[key])
            response = self.client.post("/api/cmd", json={"mode": "eth", "key": key})
            self.assertEqual(response.status_code, 409)
        self.assertTrue(available["r"])
        self.assertTrue(available["d"])
        web.eth_link.send_key = lambda key: None
        self.assertEqual(self.client.post("/api/cmd", json={"mode": "eth", "key": "r"}).status_code, 200)

    def test_running_process_reports_waiting_instead_of_playback(self):
        fake = FakeProcess()
        with patch.object(web, "resolve_ffmpeg", return_value="ffmpeg"), \
             patch.object(web.subprocess, "Popen", return_value=fake):
            response = self.client.post("/api/eth/video/start", data={
                "video": (io.BytesIO(b"fake"), "sample.mp4")
            }, content_type="multipart/form-data")
        self.assertEqual(response.get_json()["state"], "starting")
        Path(web.VIDEO_STATUS_PATH).write_text(json.dumps({
            "state": "waiting", "rows": 32, "credits": 0}), encoding="utf-8")
        state = self.client.get("/api/eth/video/status").get_json()
        self.assertTrue(state["active"])
        self.assertEqual(state["state"], "waiting")
        self.assertEqual(state["credits"], 0)

    def test_small_profile_is_passed_to_sender(self):
        fake=FakeProcess()
        with patch.dict(web.os.environ,{"VIDEO_WIDTH":"180","VIDEO_HEIGHT":"90","VIDEO_WINDOW":"128"}), \
             patch.object(web,"resolve_ffmpeg",return_value="ffmpeg"), \
             patch.object(web.subprocess,"Popen",return_value=fake) as launch:
            response=self.client.post("/api/eth/video/start",data={
                "video":(io.BytesIO(b"fake"),"sample.mp4")},content_type="multipart/form-data")
        self.assertEqual(response.status_code,200)
        self.assertIn("180x90",response.get_json()["format"])
        command=launch.call_args.args[0]
        self.assertEqual(command[command.index("--width")+1],"180")
        self.assertEqual(command[command.index("--height")+1],"90")
        self.assertIn("--require-ready",command);self.assertIn("--audio",command)
        self.assertEqual(command[command.index("--window")+1],"128")
        self.assertEqual(command[command.index("--prefetch")+1],"16")

    def test_actual_invalid_video_exposes_decoder_error_and_cleans_source(self):
        ffmpeg = web.resolve_ffmpeg()
        real_popen = web.subprocess.Popen
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as receiver:
            receiver.bind(("127.0.0.1", 0))
            def launch(command, **kwargs):
                command += ["--bind-ip", "127.0.0.1", "--board-ip", "127.0.0.1",
                            "--data-port", str(receiver.getsockname()[1]), "--feedback-port", "0"]
                return real_popen(command, **kwargs)
            with patch.object(web, "resolve_ffmpeg", return_value=ffmpeg), \
                 patch.object(web.subprocess, "Popen", side_effect=launch):
                response = self.client.post("/api/eth/video/start", data={
                    "video": (io.BytesIO(b"invalid video bytes"), "broken.mp4")
                }, content_type="multipart/form-data")
            self.assertEqual(response.status_code, 200, response.get_json())
            saved = Path(web.VIDEO_PATH)
            deadline = time.monotonic() + 10
            state = {}
            while time.monotonic() < deadline:
                state = self.client.get("/api/eth/video/status").get_json()
                if not state["active"]:
                    break
                time.sleep(0.05)
        self.assertFalse(state["active"], state)
        self.assertEqual(state["state"], "error")
        self.assertIn("FFmpeg decoding failed", state["error"])
        self.assertIn("Invalid data", state["details"])
        self.assertFalse(saved.exists())

    def test_actual_upload_decode_and_udp_feedback(self):
        ffmpeg = web.resolve_ffmpeg()
        source = Path(self.tempdir.name) / "valid.avi"
        web.subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "lavfi",
                            "-i", "color=c=red:s=64x32:r=60", "-frames:v", "2", "-c:v", "mpeg4", str(source)],
                           check=True, timeout=15)
        real_popen = web.subprocess.Popen
        failures, received, launched_commands = [], [], []
        stop = threading.Event()
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as receiver:
            receiver.bind(("127.0.0.1", 0))
            receiver.settimeout(0.1)
            def receive():
                while not stop.is_set():
                    try:
                        packet, address = receiver.recvfrom(2048)
                        self.assertEqual(len(packet), 1454)
                        self.assertEqual(packet[:3], b"VD\x01")
                        seq = struct.unpack_from("<H", packet, 8)[0]
                        self.assertEqual(struct.unpack_from("<H", packet, 1452)[0],
                                         binascii.crc_hqx(packet[:-2], 65535))
                        received.append(seq)
                        if packet[3]&1:
                            fid=struct.unpack_from('<H',packet,4)[0]
                            receiver.sendto(struct.pack('<2sBBHH',b'VA',1,9,seq,fid),address)
                        receiver.sendto(struct.pack("<2sBBHBB", b"VA", 1, 1, (seq+1)&65535, 32, 0), address)
                    except socket.timeout:
                        continue
                    except BaseException as exc:
                        failures.append(exc)
                        return
            thread = threading.Thread(target=receive, daemon=True)
            thread.start()
            def launch(command, **kwargs):
                launched_commands.append(list(command))
                command += ["--bind-ip", "127.0.0.1", "--board-ip", "127.0.0.1",
                            "--data-port", str(receiver.getsockname()[1]), "--feedback-port", "0"]
                return real_popen(command, **kwargs)
            try:
                # This loopback fixture uses a two-frame AVI and checks UDP
                # framing/credit handling; bypass the product's 16-frame warmup.
                with patch.dict(web.os.environ, {"VIDEO_PREFETCH": "0"}), \
                     patch.object(web, "resolve_ffmpeg", return_value=ffmpeg), \
                     patch.object(web.subprocess, "Popen", side_effect=launch), source.open("rb") as upload:
                    response = self.client.post("/api/eth/video/start", data={
                        "video": (upload, "valid.avi"),"audio":"0"
                    }, content_type="multipart/form-data")
                self.assertEqual(response.status_code, 200, response.get_json())
                deadline = time.monotonic() + 10
                state = {}
                while time.monotonic() < deadline:
                    state = self.client.get("/api/eth/video/status").get_json()
                    if not state["active"] or state.get("frames", 0) >= 2:
                        break
                    time.sleep(0.05)
                if failures:
                    raise failures[0]
                self.assertTrue(state["active"], state)
                sender_log = ""
                if web.VIDEO_LOG_PATH and Path(web.VIDEO_LOG_PATH).is_file():
                    sender_log = Path(web.VIDEO_LOG_PATH).read_text(encoding="utf-8", errors="replace")
                self.assertGreaterEqual(state.get("frames", 0), 2,
                                        {"status": state, "sender_log": sender_log,
                                         "received_packets": len(received), "failures": failures,
                                         "command": launched_commands})
                self.assertGreater(state["credits"], 0)
                self.assertGreaterEqual(len(received), 720)
                self.assertEqual(state["skipped_rows"], 0)
                saved = Path(web.VIDEO_PATH)
                self.client.post("/api/eth/video/stop")
                self.assertFalse(saved.exists())
                self.assertEqual(self.client.get("/api/eth/video/status").get_json()["state"], "stopped")
            finally:
                web.stop_video_sender()
                stop.set()
                thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
