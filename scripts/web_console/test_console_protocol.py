#!/usr/bin/env python3
"""Protocol checks for the Flask console controls and SD diagnostic reply."""

import unittest

from app import CMDS, app, decode_dump, decode_pkt, send_bytes


class ConsoleProtocolTests(unittest.TestCase):
    def test_sd_diagnostic_success_and_failure_decode(self):
        good = bytes((0xA6, 0xF0)) + (100_000_000).to_bytes(4, "little") + (800).to_bytes(2, "little")
        text = decode_dump(good)
        self.assertIn("初始化=完成", text)
        self.assertIn("SDHC/SDXC", text)
        self.assertIn("High Speed=已启用", text)
        self.assertIn("最近图片读卡 2.000s", text)
        self.assertIn("扇区事务 8.00us", text)

        failed = bytes((0xA6, 0x01)) + bytes(4) + (0xFCFF).to_bytes(2, "little")
        text = decode_dump(failed)
        self.assertIn("初始化=失败", text)
        self.assertIn("命令响应起始超时", text)
        self.assertIn("CMD55 发送线首个不匹配=无", text)
        self.assertIn("响应末八次采样=0xFF", text)

        # During CMD17 wait, status carries the full host state and CMD trace.
        live_wait = bytes((0xA6, 0xFF)) + bytes(4) + (0x70FF).to_bytes(2, "little")
        text = decode_dump(live_wait)
        self.assertIn("host-state=31", text)
        self.assertIn("CMD=WAIT_REPLY", text)
        self.assertIn("error=1", text)
        self.assertIn("response-tail=0x7F", text)

    def test_i_command_uses_existing_complement_frame(self):
        self.assertEqual(CMDS["i"], 0x49)
        self.assertEqual(send_bytes("i"), bytes((0x49, 0xB6)))

    def test_cv_mode_aliases_use_complement_frame(self):
        expected = {"r": 0x52, "g": 0x47, "b": 0x42,
                    "e": 0x45, "h": 0x48, "w": 0x57}
        for key, command in expected.items():
            self.assertEqual(CMDS[key], command)
            self.assertEqual(send_bytes(key), bytes((command, command ^ 0xFF)))

    def test_cv_mode_is_reported_in_status_and_ack(self):
        status = bytes((0xA5, 0x00, 0x00, 0x00, 0x00, 0x00, 0x64, 0x00))
        self.assertIn("CV=sobel", decode_pkt(status))
        ack = bytes((0x5A, 0x45, 0, 1, 0x64, 0, 0, 0))
        self.assertIn("CV=sobel", __import__("app").decode_ack(ack))

    def test_status_explains_audio_reject_reason(self):
        status = bytes((0xA5, 0x75, 0x08, 0x02, 0x00, 0x00, 0x07, 0x00))
        text = decode_pkt(status)
        self.assertIn("audio rejected: PCM checksum mismatch", text)

    def test_api_keeps_control_and_snapshot_actions(self):
        response = app.test_client().get("/api/keys")
        self.assertEqual(response.status_code, 200)
        result = response.get_json()
        keys = {item["key"] for item in result["keys"]}
        self.assertTrue(set("npa012345rgb ehw+-<>[]s,.q;'ldi".replace(" ", "")).issubset(keys))
        groups = {group["name"]: group["keys"] for group in result["groups"]}
        self.assertIn("d", keys)  # D is a dedicated button beside the preview.
        self.assertIn("图像效果", groups)
        self.assertEqual(set(groups["调试"]), {"i", "l"})


if __name__ == "__main__":
    unittest.main(verbosity=2)
