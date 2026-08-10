# cadence

One pipewire capture, one fft, many consumers.

Replaces the two cava processes the Alpenglow shell runs against the same
monitor source. Both of them were reading the default sink, both at 30fps,
differing only in band count and smoothing, and each doing its own fft of the
same audio.

```
cadence --format packed                          # what the shell reads
cadence --format jsonl                           # the same, readable
cadence --format cava --bands 44                 # drop-in for a cava pipe
cadence --format amp                             # just the scalar
```

## Why it exists

The shell's audio feed was cava. cava is fine, but as a client of somebody
else's process the two things that mattered were not reachable:

- **the buffer and the window were not ours.** `alpenglow.md` writes off the
  remaining lag as "pipewire's monitor buffer and the fft window, which are
  not ours to remove". As the pipewire client, both are ours. cadence asks
  for a 256 frame quantum and runs a 2048 point window on a 480 sample hop,
  so a frame lands every 10ms with 42.7ms of lookback
- **there was no onset, only loudness.** cava reports level. An aurora driven
  by level swells with volume. An aurora driven by onset hits on the kick,
  which is a visibly different thing

The process itself is 0.55-0.65% of a core for 44 bands, against the two
cavas' combined 1.0%. **The whole-shell picture is a wash**, not a win - the
consumer now reads 60 frames a second instead of 30, and that costs about
what the second cava did. What it buys is the rate and the onset, not
cycles. There is a fuller account in the shell's own docs, including the
±3% sampling noise that makes single measurements here worthless.

## Output

`--format cava` is cava's raw ascii, one integer per band, semicolon
separated. Anything already parsing a cava pipe takes it unchanged.

`--format amp` is one float per line, for a consumer that only wants the
scalar.

`--format packed` is jsonl's data as `;`-separated integers, `amp;flux;
onset;b0;...;bN`, everything 0..1000 and onset 0 or 1:

```
851;1000;0;1000;906;874;542;482;408;411;244
```

It exists because `JSON.parse` per frame is too expensive in a QML consumer
to run at 60fps, and because the scalars can be read off the front of the
line without touching the bands at all.

`--format jsonl` is the one cava has no way to express:

```json
{"amp":0.34,"flux":0.15,"onset":false,"bands":[0.10,0.29,0.84,...]}
```

- `amp` is the whole mix, 0..1, weighted towards the bottom third. A flat
  mean over 44 bands is mostly hiss and barely moves on a kick
- `flux` is positive spectral flux against its own running peak
- `onset` is a bass transient, see below

## Onset is not beat

Onsets come from flux below `--onset-hz` (200 by default), not the full
spectrum. Full-spectrum flux fires on every hi-hat, which is correct onset
detection and useless for driving something that should look like it follows
the music.

What comes out is still every bass transient, not every beat. On a busy
bassline that is 3 or more a second. Turning onsets into beats needs a tempo
model on top, which is the obvious next thing and is not here yet. The three
knobs to tune in the meantime are `--onset-hz`, `--onset-threshold` and
`--onset-refractory`.

## Scaling

Bands are dB by default over a 45dB floor. `--scale linear` is the raw
magnitude, and it looks like this:

```
 75 100  91  93  55  10   8  14  43  18  11  11   6  11   7   4   3   4
```

Bass carries almost all the energy in music, so two thirds of the graph sits
in the single digits. In dB the same frame is:

```
 95 100  96  89  72  67  64  52  45  45  46  57  46  43  34  36  34  33
```

`--floor` moves the point that reads as zero. Lower is punchier at the top
and saturates the bass, higher lifts the whole graph and flattens it.

## Layout

- `src/fft.zig`, `src/analysis.zig`, `src/output.zig` are the dsp half. No
  system dependencies, so `zig build test` runs without pipewire installed
- `src/capture.c` is the pipewire client. It is C on purpose: zig's
  translate-c cannot parse `spa/utils/json-core.h`, and the pod builder and
  the `_events` version fields are macro soup it handles badly even when it
  does parse. `src/capture.h` mentions no pipewire type, so zig only ever
  sees floats
- the process callback runs on pipewire's data thread and does nothing but
  copy into a lock free ring. The fft and the writes happen on the main
  thread, so a stalled reader cannot block audio

A reader that falls behind gets the newest samples, not the oldest. A
visualiser that catches up by replaying history is worse than one that skips.
Anything dropped is counted and reported on exit.

## Notes

- `--target` takes a sink name. A trailing `.monitor` is stripped, since
  cadence attaches to the sink itself rather than naming its monitor node
- a `--target` that matches nothing falls back to the default sink instead of
  failing. That is pipewire's autoconnect, not a check cadence skipped
- needs zig 0.16 and `pipewire-devel`

## Build

```sh
zig build -Doptimize=ReleaseFast
zig build test
```
