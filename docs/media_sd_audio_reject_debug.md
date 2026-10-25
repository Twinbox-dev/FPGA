# SD media transfer and audio rejection investigation

This note tracks the current board evidence for the native-SD media sender and
the dual-board audio receive result. All FPGA programming described here is
SRAM-only. `cable0` is the display board (`192.168.137.2`); `cable1` is the
media board (`192.168.137.3`).

## Media-side evidence

- The media board initialized the real card as SDHC/SDXC, 4-bit High Speed,
  50 MHz. The `I` diagnostic reported a full image-source read of about
  1.414 s and a latest CMD17 transaction near 347 us.
- A PC display stub received all six 460,800-word images from
  `card_user_real.img`, matched each frame against its BMP golden byte-for-byte,
  and returned successful image/audio results. Four paired WAVs were exact:
  IMG0=480,000 PCM bytes; IMG1, IMG2, IMG5=720,000 bytes each. IMG3 and IMG4
  completed zero-sample silent audio transactions.
- With the real display board, the D snapshots for IMG2, IMG3, IMG4 and IMG5
  were each 460,800 words, had zero gaps, and matched the correct BMP golden.
  IMG2 and IMG5 also showed paired audio in committed status. The next image,
  IMG0 after wrapping from IMG5, did not commit and exhausted audio retries.

The PC stub proves the media board's IMG0 image and PCM bytes are correct. The
real-display failure is an audio END rejection, not a media read or image
snapshot mismatch. The original sender status collapsed a received audio
rejection and a missing result into the same error. The sender now distinguishes
an explicit audio rejection from a result timeout.

## Audio result reason codes

The display receiver now returns `0x33` `AUDIO_RESULT` code `0` on success and
`0x11` through `0x17` on rejection. The low nibble identifies the first failed
END check:

| Code | Rejection reason |
| --- | --- |
| `0x11` | No active audio transaction |
| `0x12` | Audio frame ID mismatch |
| `0x13` | END length or reserved field |
| `0x14` | Received sample count differs from `AUDIO_BEGIN` |
| `0x15` | PCM byte checksum mismatch |
| `0x16` | An earlier audio DATA packet failed validation |
| `0x17` | Previous audio packet was still draining |

The media sender retries only the audio stream for any `0x1x` rejection. After
three rejected attempts it reports media error category 7 and carries the low
nibble reason in the status state field. The legacy display response code `1`
remains retryable and maps to generic reason 0.

## Simulation evidence

- `make -C boardtest media-display-path` verifies valid image/audio commit,
  image checksum reject, and the audio checksum reject path. Its PCM case sends
  1,024 samples in production-shaped DATA packets of 1,012 and 12 samples; a
  deliberately wrong checksum returns `AUDIO_RESULT=0x15`.
- `make -C boardtest media-image-tx` verifies reason retention after retries
  and compatibility with legacy `RESULT=1`.
- `python -m unittest test_console_protocol.py -v` verifies the web status text
  decodes a PCM checksum rejection correctly.

These tests prove the reason-code pipeline in RTL simulation. They do not yet
identify which reason the real display board returns for IMG0, because the
reason-code display bit has not been loaded.

## Current build and JTAG state

- Display reason-code bit: SHA-256
  `c7d36ef3ed297a43516e64c423862f17f816ceac3513b5741839e1866e7760c3`;
  13,182 LUT, 9,836 FF, 40 BRAM9K, 5 BRAM32K, 10 DSP, setup/hold WNS
  `-5.699/-3.188 ns`. P&R and bitgen completed; cable0 download attempts failed
  with TD `PRG-9505 USB device open error`.
- Media reason-aware bit: SHA-256
  `250ccabcf92fd4ba7d9e666ec389b0d99446a4e61400c14c7f37868a79178fd6`;
  14,251 LUT, 9,403 FF, 23 BRAM9K, 2 BRAM32K, 2 DSP, setup/hold WNS
  `-3.862/-2.991 ns`. P&R and bitgen completed; the most recent cable1 download
  also failed with the same USB open error.
- Both board IP addresses still reply to ping. Windows lists two connected
  Anlogic USB cable devices and the JTAGServer service. Attempting to restart
  that service failed with Windows “Access is denied”; no service or PC network
  setting was changed.

When JTAG access is available again, program the display bit to cable0 and the
media bit to cable1, then run the six-image acceptance. The expected next result
for IMG0 is a concrete `0x11`–`0x17` reason in the media status. Fix the specific
receive/count/checksum/drain condition and rerun the targeted simulation before
the board acceptance. Do not classify the audio path as fixed until the real
IMG0 transaction commits.

## Follow-up after the boards were power-cycled

At 13:52 local time both current SRAM images downloaded successfully: the
display reason-code bit over cable0 and the media reason-aware bit over cable1.
TD reported chip validation success for both. The new six-image acceptance run
then stopped at its first N request: the command ACK arrived, but the committed
index stayed at IMG1 for 45 seconds. Status reported media TX `LOAD_IMAGE`, FAT
state `S_STREAM`, and no reported TX error. A6 still reported SD initialized,
SDHC, and High Speed active; its last sector transaction was about 213.82 us.
The image-source timer had saturated at `0xFFFFFFFF` (about 85.9 s), so the
current issue is a stalled image-source/FAT stream after programming, before the
audio END result can be evaluated. The previous note about JTAG access being
blocked is obsolete; board download is available again. Resume with read-only
state inspection and targeted source-path diagnosis before another full sweep.

## Follow-up: six-image wrap fixed at 50 MHz

The 25 MHz bit used during this investigation was a diagnostic comparison build:
it still negotiated High Speed with the card but intentionally held SDCLK at
25 MHz. It was not the intended production clock and did not resolve the
wraparound failure. The production build below runs the card at High Speed
50 MHz.

The first complete loop on the diagnostic build transferred IMG2, IMG3, IMG4,
and IMG5 correctly, then stalled on IMG5 -> IMG0. Media status carried the
display's audio END rejection for reason `0x14`: received PCM byte count did
not match `AUDIO_BEGIN`. This was after the image END had passed; the display
keeps the previous frame selected until the optional audio transaction also
commits. Therefore the visible symptom was an image that appeared not to switch,
even though the card read and image packet stream were sound.

`media_protocol_rx` has one packet staging buffer and marks an incoming DATA
packet dropped if the preceding stream is still draining. Image DATA already
had a 100 us inter-packet drain window; audio DATA had none. The media sender
now uses that same 100 us window between non-final audio DATA packets. The
existing `media-tx-gap` regression checks both image and audio pacing. The
board acceptance script also supports targeted runs from one through six
images and now writes its pass report after the requested run succeeds.

The 50 MHz production media bit was programmed to cable1 SRAM on 2026-10-21.
Its SHA-256 is
`F9B4FF20D184173BD181A574D64270BCC82E7D94249890E94DF03779FD217A06`.
The P&R report lists 14,367 LUT, 9,625 registers, 23 BRAM9K, 2 BRAM32K, and 2
DSP, with setup/hold WNS `-4.351/-2.850 ns`. A6 reported SDHC, High Speed
supported and active, a full image-source time of about 1.414 s, and a last
sector transaction near 347 us. Two consecutive six-transition runs passed,
each covering IMG2 -> IMG3 -> IMG4 -> IMG5 -> IMG0 -> IMG1:

- Every D snapshot contained 460,800 words, zero sequence gaps, and matched its
  BMP golden frame byte-for-byte.
- All four paired-WAV images reported successful audio commit; the two images
  without WAV files committed as silent transactions.
- IMG5 -> IMG0 succeeded in both runs, including IMG0's 480,000-byte PCM
  transaction. The first run's measurements and per-image results are saved
  under ignored `boardtest/captures/20261021_171138_sd_board_acceptance.json`;
  the repeat is `20261021_171221_sd_board_acceptance.json`.

This confirms the missing audio packet pacing was the wraparound blocker. The
final candidate retains 50 MHz SD High Speed; the 25 MHz experiment is not a
production fallback. Boardtest continues to retain the native-SD card models
and prior SPI-era simulations.

## Follow-up: stalled image FIFO recovery (2026-10-26)

During the live PC upload regression, a small temporary image committed, the
next SD image committed, and the following previous-image request did not
finish. The display status returned to idle while media TX remained in
`LOAD_IMAGE`; the media status showed FAT state `0x09` and no source error. This
matches the sender's old `LOAD_IMAGE` logic: it advanced only when
`read_pending` was set, with no timeout or source-error exit if the production
FIFO stopped supplying words. The view scheduler could therefore unlock while
the media job stayed stuck.

`media_image_tx` now resets a two-second no-data timer for every consumed FIFO
word. A source error or a full timeout exits `LOAD_IMAGE`, reports media error
2, and toggles `source_abort_toggle`. `top_media_net` synchronizes that toggle
from the 125 MHz application clock into the 50 MHz SD/FAT clock and produces a
one-cycle abort pulse for `media_image_source`. The source cancels the active
file read after its in-flight FAT sector drains. The web status decoder names
error 2 as an image source/SD/FIFO failure or stall.

The targeted Verilator sender test covers both a permanently empty FIFO and an
explicit source error. The native-SD source test was extended to abort during
an active BMP stream, verify that the FAT/SD source returns idle without an
error, then read the same BMP completely. The test passes with all six BMPs and
four paired WAV PCM files compared against their existing golden data.

The updated media bit was built from the current RTL and downloaded to cable1
SRAM; TD validation succeeded in
`boardtest/captures/sram_download/program_media_20261026_015312.log`. Its
routed report lists 14,164 LUT, 7,877 slices, 19 BRAM9K, 2 BRAM32K and 5 DSP;
setup/hold WNS are `-4.330/-3.042 ns`.

Live regression then passed the original failure order (PC image upload, N,
P), N/P from the SD base after PC uploads, double- and four-window entry,
per-window N/P, PC image replacement in both layouts, and direct/fade/slide
transitions. D returned a complete 504x720 `IMG3.BMP` snapshot: 181,440 words,
zero packet gaps, and byte-for-byte equality with the BMP golden. A silent
2,400-sample PC audio transaction also committed, after which SD N/P still
worked. The board status query showed no latched video-underrun flag. That
status does not measure a one-frame HDMI color flash; the transition and
SDRAM-read RTL plus their unit tests were reviewed separately.
