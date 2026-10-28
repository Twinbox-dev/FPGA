"""Sender regressions using localhost UDP only; no FPGA or NIC changes."""
import binascii
import json
import select
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

if __package__:
    from . import direct_video_sender as video
else:
    import direct_video_sender as video


class SenderTests(unittest.TestCase):
    def setUp(self):
        self.receiver = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.receiver.bind(("127.0.0.1", 0))
        self.sender = video.Sender("127.0.0.1", "127.0.0.1", 65520, True,
                                   data_port=self.receiver.getsockname()[1], feedback_port=0,
                                   feedback_timeout=1.0)

    def tearDown(self):
        self.sender.close()
        self.receiver.close()

    def feedback(self, sequence, opcode=video.CREDIT):
        self.receiver.sendto(video.FEEDBACK_HEADER.pack(b"VA", 1, opcode, sequence, 32, 0),
                             self.sender.sock.getsockname())
        self.assertTrue(select.select([self.sender.sock], [], [], 1)[0])
        self.sender.process_feedback()


    def test_ready_rejects_wrong_identity_and_does_not_rewind_progress(self):
        self.sender.require_ready=True;self.sender.initial_frame=123
        def reply(op,seq,fid=0):
            self.receiver.sendto(video.FEEDBACK_HEADER.pack(b'VA',1,op,seq,fid&255,fid>>8),self.sender.sock.getsockname())
            self.assertTrue(select.select([self.sender.sock],[],[],1)[0]);self.sender.process_feedback()
        reply(video.CREDIT,65524)
        self.assertFalse(self.sender.have_credit)
        reply(video.READY,65520,124);reply(video.READY,65521,123)
        self.assertFalse(self.sender.ready_received)
        reply(video.READY,65520,123)
        self.assertTrue(self.sender.ready_received);self.assertTrue(self.sender.have_credit)
        reply(video.CREDIT,65525)
        reply(video.READY,65520,123)
        self.assertEqual(self.sender.consumed_sequence,65525)

    def test_only_session_row_retries_while_receiver_takes_memory(self):
        self.sender.require_ready=True;self.sender.width=2;self.sender.height=4
        self.sender.row_bytes=4;self.sender.frame_bytes=16;errors=[]
        def board():
            try:
                self.receiver.settimeout(1)
                first,peer=self.receiver.recvfrom(2048)
                seq=struct.unpack_from('<H',first,8)[0]
                self.assertEqual(seq,65520);self.assertEqual(first[3],1)
                # Deliberately lose the first request/READY and wait for retry.
                second,_=self.receiver.recvfrom(2048);self.assertEqual(first,second)
                self.receiver.sendto(video.FEEDBACK_HEADER.pack(b'VA',1,video.READY,65520,16380&255,16380>>8),peer)
                for n in range(1,4):
                    packet,_=self.receiver.recvfrom(2048)
                    self.assertEqual(struct.unpack_from('<H',packet,8)[0],65520+n)
            except BaseException as error:errors.append(error)
        t=threading.Thread(target=board);t.start()
        try:self.sender.send_frame(16380,bytes(16),True)
        finally:t.join(2)
        self.assertFalse(t.is_alive());self.assertFalse(errors,errors)
        self.assertTrue(self.sender.ready_received);self.assertGreaterEqual(self.sender.retries,1)

    def test_audio_packet_and_receiver_statistics(self):
        pcm=bytes(n%256 for n in range(396));packet=video.make_audio_packet(65535,pcm)
        self.assertEqual(packet[:8],b'AD\x01\x00\xff\xff\x8c\x01')
        self.assertEqual(len(packet),406);self.assertEqual(packet[8:404],pcm)
        self.assertEqual(struct.unpack_from('<H',packet,404)[0],binascii.crc_hqx(packet[:404],0xffff))
        with self.assertRaises(ValueError):video.make_audio_packet(0,bytes(395))
        for value in (65534,2):
            message=video.FEEDBACK_HEADER.pack(b'VA',1,10,0,0,16)+struct.pack('<6I',value,0,value,0,0,0)
            self.receiver.sendto(message,self.sender.sock.getsockname())
            self.assertTrue(select.select([self.sender.sock],[],[],1)[0]);self.sender.process_feedback()
        self.assertEqual(self.sender.receiver_audio['accepted'],65538)
        self.assertEqual(self.sender.receiver_audio['good_blocks'],65538)
        self.assertFalse(self.sender.have_credit)

    def test_audio_follows_session_row_and_ready_before_next_video_row(self):
        from unittest import mock
        self.sender.width=2;self.sender.height=4;self.sender.row_bytes=4;self.sender.frame_bytes=16
        self.sender.initial_sequence=0;self.sender.require_ready=True
        sent=[]
        def ready():
            self.assertEqual(len(sent),1);self.assertEqual(sent[0][:2],b'VD')
            self.sender.ready_received=True;self.sender.have_credit=True
        with mock.patch.object(self.sender,'_send',side_effect=lambda p:sent.append(p)),mock.patch.object(self.sender,'wait_for_ready',side_effect=ready):
            self.sender.send_frame(0,bytes(16),True,bytes(396))
        self.assertEqual([p[:2] for p in sent],[b'VD',b'AD',b'VD',b'VD',b'VD'])
        self.assertEqual(self.sender.sent_audio_blocks,1)

    def test_large_window_uses_absolute_sequence_not_advisory_byte(self):
        self.sender.window=512
        start=self.sender.initial_sequence
        self.assertTrue(self.sender.can_send((start+511)&65535))
        self.assertFalse(self.sender.can_send((start+512)&65535))
        packet=video.FEEDBACK_HEADER.pack(b'VA',1,video.CREDIT,(start+256)&65535,255,0)
        self.receiver.sendto(packet,self.sender.sock.getsockname())
        self.assertTrue(select.select([self.sender.sock],[],[],1)[0]);self.sender.process_feedback()
        self.assertEqual(self.sender.reported_free,255)
        self.assertTrue(self.sender.can_send((start+767)&65535))
        self.assertFalse(self.sender.can_send((start+768)&65535))

    def test_hybrid_readback_status_wraps_but_does_not_grant_credit(self):
        for value in (65534,2):
            for op in (7,8):
                values=[value]*6 if op==7 else [value,0,12,13,14,0]
                packet=video.FEEDBACK_HEADER.pack(b'VA',1,op,0,255,16)+struct.pack('<6I',*values)
                self.receiver.sendto(packet,self.sender.sock.getsockname())
                self.assertTrue(select.select([self.sender.sock],[],[],1)[0]);self.sender.process_feedback()
        self.assertEqual(self.sender.receiver_hybrid['spills'],65538)
        self.assertEqual(self.sender.receiver_readback['good'],65538)
        self.assertEqual(self.sender.receiver_readback['bad'],0)
        self.assertEqual(self.sender.receiver_readback['last_sequence'],14)
        self.assertFalse(self.sender.have_credit)

    def test_send_backpressure_retries_same_datagram(self):
        from unittest import mock
        packet=b'wire payload'
        with mock.patch.object(self.sender,'process_feedback',return_value=False), \
             mock.patch.object(video.select,'select',return_value=([],[self.sender.sock],[])), \
             mock.patch.object(self.sender,'sock') as sock:
            sock.sendto.side_effect=[BlockingIOError(),len(packet)]
            self.sender._send(packet)
            self.assertEqual(sock.sendto.call_args_list,[mock.call(packet,self.sender.board)]*2)
        self.assertEqual(self.sender.send_would_block,1)

    def test_internal_source_credit_is_not_external_permission(self):
        packet=video.FEEDBACK_HEADER.pack(b'VA',1,1,65524,32,1)
        self.receiver.sendto(packet,self.sender.sock.getsockname())
        self.assertTrue(select.select([self.sender.sock],[],[],1)[0]);self.sender.process_feedback()
        self.assertEqual(self.sender.diagnostic_mode,1);self.assertFalse(self.sender.have_credit)
        self.feedback(65524)
        self.assertEqual(self.sender.diagnostic_mode,0);self.assertTrue(self.sender.have_credit)

    def test_mode_flag_preserves_u16_status_format(self):
        packet=video.FEEDBACK_HEADER.pack(b'VA',1,3,0,79,144)+struct.pack('<6I',*([100]*6))
        self.receiver.sendto(packet,self.sender.sock.getsockname())
        self.assertTrue(select.select([self.sender.sock],[],[],1)[0]);self.sender.process_feedback()
        self.assertEqual(self.sender.diagnostic_mode,1)
        self.assertEqual(self.sender.receiver_stats['counter_bits'],16)

    def test_expired_row_is_skipped_and_wrap_is_forward(self):
        self.feedback(65535)
        self.assertFalse(self.sender.wait_for_window(65534))
        self.assertTrue(self.sender.wait_for_window(0))
        self.feedback(0)
        self.assertFalse(self.sender.wait_for_window(65535))

    def test_expired_row_never_polls_or_packetizes(self):
        from unittest import mock
        self.sender.have_credit=True;self.sender.consumed_sequence=3
        self.sender.width=2;self.sender.height=4;self.sender.row_bytes=4;self.sender.frame_bytes=16
        with mock.patch.object(self.sender,'process_feedback',side_effect=AssertionError('obsolete row polled')), \
             mock.patch.object(self.sender,'_send') as send, \
             mock.patch.object(video,'make_row_packet',wraps=video.make_row_packet) as packetize:
            self.sender.send_frame(0,bytes(16))
        self.assertEqual(self.sender.skipped_rows,3)
        self.assertEqual(self.sender.sent_rows,1)
        self.assertEqual(packetize.call_count,1)
        self.assertEqual(packetize.call_args.args[1],3)
        self.assertEqual(send.call_count,1)

    def test_reason_status_wraps_without_granting_credit(self):
        for value in (65534,2):
            packet=video.FEEDBACK_HEADER.pack(b'VA',1,4,0,32,16)+struct.pack('<6I',*([value]*6))
            self.receiver.sendto(packet,self.sender.sock.getsockname())
            self.assertTrue(select.select([self.sender.sock],[],[],1)[0])
            self.sender.process_feedback()
        self.assertEqual(self.sender.receiver_reasons['late_begin'],65538)
        self.assertEqual(self.sender.receiver_reason_initial['late_begin'],65534)
        self.assertFalse(self.sender.have_credit)

    def test_credit_clock_wrap_and_delivery_jitter(self):
        self.sender._record_credit_clock(0xffffff00,100.,0)
        self.sender._record_credit_clock(0x100,100.+512/125000000,4)
        self.assertEqual(self.sender.credit_clock['elapsed_ticks'],512)
        self.assertAlmostEqual(self.sender.credit_clock['max_offset_ms'],0.,places=5)
        self.sender._record_credit_clock(0x200,100.+768/125000000+.002,8)
        self.assertAlmostEqual(self.sender.credit_clock['largest_transitions'][0]['extra_delay_ms'],2.,places=5)

    def test_timestamp_credit_grants_normal_credit(self):
        packet=video.FEEDBACK_HEADER.pack(b'VA',1,1,65524,32,4)+struct.pack('<I',123456)
        self.receiver.sendto(packet,self.sender.sock.getsockname())
        self.assertTrue(select.select([self.sender.sock],[],[],1)[0])
        self.sender.process_feedback()
        self.assertEqual(self.sender.consumed_sequence,65524)
        self.assertEqual(self.sender.credit_clock['samples'],1)
        self.assertTrue(self.sender.have_credit)

    def test_reordered_credit_and_expired_nack_are_ignored(self):
        self.feedback(2)
        self.feedback(65535)
        self.assertEqual(self.sender.consumed_sequence, 2)
        self.feedback(1, video.NACK)
        self.assertEqual(self.sender.missing_cache, 0)

    def test_initial_window_is_retried_until_real_credit(self):
        self.sender.initial_sequence=100
        self.sender.window=4
        self.sender.cache[100]=b"initial session row"
        self.sender.last_bootstrap_retry=time.monotonic()-1
        self.sender.last_credit_progress=time.monotonic()
        observed=[]
        def receiver():
            packet,source=self.receiver.recvfrom(2048)
            observed.append(packet)
            self.receiver.sendto(video.FEEDBACK_HEADER.pack(b"VA",1,video.CREDIT,101,4,0),source)
        worker=threading.Thread(target=receiver,daemon=True);worker.start()
        try:
            self.assertTrue(self.sender.wait_for_window(104))
            worker.join(timeout=1)
            self.assertEqual(observed,[b"initial session row"])
            self.assertEqual(self.sender.retries,1)
            self.assertTrue(self.sender.have_credit)
        finally:
            worker.join(timeout=1)

    def test_credit_timing_distinguishes_active_stall_from_vertical_blank(self):
        self.sender.trace_timing=True
        from unittest import mock
        with mock.patch.object(video.time,"perf_counter",return_value=100):self.feedback((65520+4)&65535)
        with mock.patch.object(video.time,"perf_counter",return_value=100.002):self.feedback((65520+8)&65535)
        self.assertEqual(self.sender.credit_timing["active_samples"],1)
        self.assertAlmostEqual(self.sender.credit_timing["max_gap_ms"],2.0)
        event=self.sender.credit_timing["outliers"][-1]
        self.assertEqual(event["lines"],4)
        self.assertAlmostEqual(event["ideal_line_ms"],0.088)
        before=self.sender.credit_timing["gap_over_1ms"]
        with mock.patch.object(video.time,"perf_counter",return_value=100.01):self.feedback((65520+360)&65535)
        with mock.patch.object(video.time,"perf_counter",return_value=100.03):self.feedback((65520+364)&65535)
        self.assertEqual(self.sender.credit_timing["gap_over_1ms"],before)

    def test_stalled_credit_has_bounded_timeout(self):
        self.sender.have_credit = True
        self.sender.consumed_sequence = 65520
        self.sender.last_credit_progress = time.monotonic() - 2
        self.feedback(65520)  # Duplicate feedback must not renew the deadline.
        with self.assertRaisesRegex(TimeoutError, "No advancing display credit"):
            self.sender.wait_for_window(16)

    def test_read_only_receiver_status_counters(self):
        packet=video.FEEDBACK_HEADER.pack(b"VA",1,video.STATUS,1234,17,0)+struct.pack("<6I",100,2,90,10,3,12)
        self.receiver.sendto(packet,self.sender.sock.getsockname())
        self.assertTrue(select.select([self.sender.sock],[],[],1)[0])
        self.sender.process_feedback()
        self.assertEqual(self.sender.receiver_stats,dict(parser_accepted=100,parser_rejected=2,
            store_accepted=90,store_rejected=10,duplicates=3,underflows=12,consumed_sequence=1234,free_rows=17,counter_bits=32))
        self.assertFalse(self.sender.have_credit)  # Statistics never grant send credit.

    def test_duplicate_nacks_are_coalesced_after_latest_credit(self):
        self.sender.have_credit=True;self.sender.consumed_sequence=65520
        self.sender.cache[65520]=b"test row"
        for _ in range(5):
            self.receiver.sendto(video.FEEDBACK_HEADER.pack(b"VA",1,video.NACK,65520,32,0),self.sender.sock.getsockname())
        self.assertTrue(select.select([self.sender.sock],[],[],1)[0])
        self.sender.process_feedback()
        self.assertEqual(self.sender.retries,1)
        self.assertEqual(self.receiver.recvfrom(2048)[0],b"test row")

    def test_receiver_u16_counters_unwrap_without_granting_credit(self):
        for value in (65534,2):
            packet=video.FEEDBACK_HEADER.pack(b"VA",1,video.STATUS,0,32,16)+struct.pack("<6I",*([value]*6))
            self.receiver.sendto(packet,self.sender.sock.getsockname())
            self.assertTrue(select.select([self.sender.sock],[],[],1)[0])
            self.sender.process_feedback()
        self.assertEqual(self.sender.receiver_stats["underflows"],65538)
        self.assertEqual(self.sender.receiver_stats["parser_accepted"],65538)
        self.assertFalse(self.sender.have_credit)

    def test_two_real_udp_frames_with_sequence_wrap_and_crc(self):
        self.check_udp_frames(720,360,182)

    def test_small_udp_frames_with_sequence_wrap_and_crc(self):
        self.sender.close()
        self.sender=video.Sender("127.0.0.1","127.0.0.1",65520,True,
            data_port=self.receiver.getsockname()[1],feedback_port=0,
            width=180,height=90,feedback_timeout=1.0)
        self.check_udp_frames(180,90,728)

    def test_deep_small_window_and_wire_frames(self):
        self.sender.close()
        self.sender=video.Sender("127.0.0.1","127.0.0.1",65520,True,
            data_port=self.receiver.getsockname()[1],feedback_port=0,
            width=180,height=90,window=64,feedback_timeout=1.0)
        self.assertTrue(self.sender.can_send((65520+63)&65535))
        self.assertFalse(self.sender.can_send((65520+64)&65535))
        self.check_udp_frames(180,90,728)

    def check_udp_frames(self,width,height,first_frame):
        errors = []
        done = threading.Event()
        self.receiver.settimeout(3)

        def receive():
            try:
                for i in range(height*2):
                    packet, address = self.receiver.recvfrom(2048)
                    self.assertEqual(len(packet), 14+2*width)
                    magic, version, flags, frame, row, seq, wire_width = video.ROW_HEADER.unpack_from(packet)
                    self.assertEqual((magic, version, frame, row, seq, wire_width),
                                     (b"VD", 1, first_frame+i//height, i%height, (65520+i)&65535, width))
                    self.assertEqual(flags, 1 if i == 0 else 0)
                    self.assertEqual(packet[12:-2], struct.pack("<H", 0x1234+i//height)*width)
                    self.assertEqual(struct.unpack_from("<H", packet, len(packet)-2)[0],
                                     binascii.crc_hqx(packet[:-2], 65535))
                    self.receiver.sendto(video.FEEDBACK_HEADER.pack(b"VA", 1, 1, (seq+1)&65535, 32, 0), address)
            except BaseException as exc:
                errors.append(exc)
            finally:
                done.set()

        thread = threading.Thread(target=receive, daemon=True)
        thread.start()
        try:
            for frame in range(first_frame, first_frame+2):
                self.sender.send_frame(frame, struct.pack("<H", 0x1234+frame-first_frame)*width*height,
                                       start_session=(frame == first_frame))
            self.assertTrue(done.wait(3))
            if errors:
                raise errors[0]
            self.assertEqual(self.sender.sent_rows, height*2)
            self.assertEqual(self.sender.skipped_rows, 0)
        except Exception:
            if errors:
                raise errors[0]
            raise
        finally:
            thread.join(timeout=4)


class DecoderProcessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ffmpeg = shutil.which("ffmpeg")
        if not cls.ffmpeg:
            raise unittest.SkipTest("FFmpeg unavailable")
        root = Path(__file__).resolve().parents[1] / "boardtest" / "captures"
        root.mkdir(parents=True, exist_ok=True)
        cls.temp = tempfile.TemporaryDirectory(dir=root)
        cls.path = Path(cls.temp.name) / "sample.avi"
        subprocess.run([cls.ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "lavfi",
                        "-i", "color=c=red:s=64x32:r=60", "-frames:v", "2", "-c:v", "mpeg4", str(cls.path)],
                       check=True, timeout=15)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_actual_ffmpeg_frame(self):
        source = video.ffmpeg_frames(self.path, self.ffmpeg)
        try:
            frame = next(source)
            self.assertEqual(len(frame), video.FRAME_BYTES)
        finally:
            source.close()

    def test_actual_ffmpeg_small_frame(self):
        source=video.ffmpeg_frames(self.path,self.ffmpeg,180,90)
        try:
            self.assertEqual(len(next(source)),180*90*2)
        finally:
            source.close()

    def test_single_playback_reaches_eof(self):
        source = video.ffmpeg_frames(self.path, self.ffmpeg, 180, 90, prefetch=4, loop=False)
        try:
            frames = list(source)
        finally:
            source.close()
        self.assertEqual(len(frames), 2)
        self.assertTrue(all(len(frame) == 180 * 90 * 2 for frame in frames))

    def test_single_playback_pads_short_audio_with_silence(self):
        audio_path = Path(self.temp.name) / "short.wav"
        subprocess.run([self.ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
                        "-i", "sine=frequency=1000:sample_rate=24000:duration=0.005",
                        "-c:a", "pcm_u8", str(audio_path)], check=True, timeout=15)
        source = video.ffmpeg_audio_frames(audio_path, self.ffmpeg, loop=False)
        try:
            first, second = next(source), next(source)
        finally:
            source.close()
        self.assertEqual(len(first), video.AUDIO_SAMPLES)
        self.assertNotEqual(first, b'\x80' * video.AUDIO_SAMPLES)
        self.assertEqual(second, b'\x80' * video.AUDIO_SAMPLES)

    def test_audio_option_reports_missing_track(self):
        source = video.ffmpeg_audio_frames(self.path, self.ffmpeg, loop=False)
        try:
            with self.assertRaisesRegex(RuntimeError, 'audio track or disable audio'):
                next(source)
        finally:
            source.close()

    def test_prefetch_preserves_pixels_and_closes_child(self):
        from unittest import mock
        direct=video.ffmpeg_frames(self.path,self.ffmpeg,180,90)
        try:expected=next(direct)
        finally:direct.close()
        children=[]
        original=subprocess.Popen
        def spawn(*args,**kwargs):
            child=original(*args,**kwargs);children.append(child);return child
        with mock.patch.object(video.subprocess,"Popen",side_effect=spawn):
            source=video.ffmpeg_frames(self.path,self.ffmpeg,180,90,prefetch=4)
            try:self.assertEqual(next(source),expected)
            finally:source.close()
        self.assertEqual(len(children),1)
        self.assertIsNotNone(children[0].poll())

    def test_prefetch_propagates_bad_input_error(self):
        bad=Path(self.temp.name)/"bad.mp4"
        bad.write_bytes(b"invalid media input")
        source=video.ffmpeg_frames(bad,self.ffmpeg,180,90,prefetch=2)
        try:
            with self.assertRaisesRegex(RuntimeError,"FFmpeg decoding failed"):
                next(source)
        finally:source.close()

    def test_real_sender_without_feedback_fails_and_writes_reason(self):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as receiver:
            receiver.bind(("127.0.0.1", 0))
            status = Path(self.temp.name) / "timeout.json"
            result = subprocess.run([sys.executable, video.__file__, "--input", str(self.path),
                                     "--ffmpeg", self.ffmpeg, "--frames", "2", "--bind-ip", "127.0.0.1",
                                     "--board-ip", "127.0.0.1", "--data-port", str(receiver.getsockname()[1]),
                                     "--feedback-port", "0", "--feedback-timeout", "0.2", "--startup-timeout", "0.2", "--quiet",
                                     "--status-file", str(status), "--status-interval", "0", "--width", "720", "--height", "360", "--window", "32"], capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 1, result.stderr)
        state = json.loads(status.read_text())
        self.assertEqual(state["state"], "error")
        self.assertIn("No advancing display credit", state["error"])
        self.assertEqual(state["rows"], 32)


if __name__ == "__main__":
    unittest.main()
