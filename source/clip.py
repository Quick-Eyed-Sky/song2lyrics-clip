#!/usr/bin/env python3
"""The lyric video maker and the tempo detector (macOS; needs numpy and Pillow).

  clip.py bpm   SONG                                   the tempo and the first beat
  clip.py video SONG LYRICS|- --images A.png [B.jpg ...] [--size 1920x1080] [--fit fill|fit]
                [--kenburns 0..1] [--beats] [--pick N [--shuffle] --seed S] [--no-words]
                [--audio aac|original [--also-mp4]] [--kb-share 0..1] [--fades 0..1]
                [--end-fade S [--end-colour black|white]] [--sound-fade S] [--fade-in S [--fade-in-colour C]]
                [--title T [--subtitle T] [--title-start S] [--title-length S]] [--pulse 0..1 [--pulse-mode zoom|flash]
                [--pulse-every 1|2|4]] --out FILE.mp4

LYRICS "-" (or a lyrics file without lines, for an instrumental) makes a clip with pictures only; --no-words does
the same with a song that has lyrics, to finish the montage elsewhere (iMovie). --pick 50 takes 50 of the given
pictures at random (--seed makes the draw repeatable; --shuffle also mixes their order, otherwise they keep the
order of their names). --audio original puts the song's own sound in the video, untouched (WAV/AIFF: in a .mov;
MP3/AAC: copied into the .mp4; FLAC and others: Apple Lossless in a .mov) instead of AAC at 320 kb/s.

One picture or many. With several, they follow each other in the order given (the app sorts them by file name),
each for about the same time, but every cut moves to the nearest lyric line change when one is close, and onto the
nearest beat with --beats. --fit fill crops the picture to fill the frame; --fit fit keeps the whole picture with
black bars. --kenburns 0.3 slowly zooms and pans each picture (0 = still pictures, 1 = pronounced).

The words are drawn the way the song-lyrics skill draws them (its lyrics.py is imported: same font, same reading
of .lrc / .srt files, same timing rules). Frames are drawn with Pillow (sub-pixel smooth movement) and piped to
ffmpeg. Nothing is ever downloaded.
"""
from __future__ import annotations

import argparse
import json
import math
import random
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SKILL = Path.home() / '.claude' / 'skills' / 'song-lyrics' / 'scripts'
for folder in (SKILL, HERE):                      # the skill's own lyrics.py first, the app's copy as a fallback
    if (folder / 'lyrics.py').exists():
        sys.path.insert(0, str(folder))
        break
import lyrics as L                                # noqa: E402

FPS = 25


# ------------------------------------------------------------------------------------------------ tempo --

def mono(song, rate=22050):
    import numpy as np
    raw = subprocess.run([L.tool('ffmpeg'), '-v', 'error', '-i', str(song), '-ac', '1', '-ar', str(rate),
                          '-f', 'f32le', '-'], capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.float32), rate


def onset_envelope(signal, rate, hop=256, size=2048):
    """How much new sound starts in each frame (spectral flux on a log scale): peaks on drums, notes, syllables."""
    import numpy as np
    frames = 1 + (len(signal) - size) // hop
    window = np.hanning(size).astype(np.float32)
    flux = np.zeros(frames, dtype=np.float32)
    previous = None
    for start in range(0, frames, 2048):                         # in blocks, to keep memory small
        stop = min(frames, start + 2048)
        idx = np.arange(start, stop)[:, None] * hop + np.arange(size)[None, :]
        spec = np.log1p(1000 * np.abs(np.fft.rfft(signal[idx] * window, axis=1)[:, :size // 4]))
        joined = spec if previous is None else np.vstack([previous, spec])
        diff = np.maximum(0, np.diff(joined, axis=0)).sum(axis=1)
        flux[start + (1 if previous is None else 0):stop] = diff
        previous = spec[-1:]
    kernel = np.ones(int(0.4 * rate / hop)) / int(0.4 * rate / hop)
    flux = np.maximum(0, flux - np.convolve(flux, kernel, mode='same'))   # keep only what stands out locally
    return flux / (flux.max() or 1), rate / hop


def tempo(song):
    """(BPM, time of the first beat in seconds). Autocorrelation for a first guess, then a fine search of the
    beat period and phase that best line up with the onsets over the whole song (steady-tempo songs)."""
    import numpy as np
    signal, rate = mono(song)
    env, fps = onset_envelope(signal, rate)
    ac = np.correlate(env, env, mode='full')[len(env) - 1:]
    lags = np.arange(len(ac), dtype=float)
    with np.errstate(divide='ignore'):
        bpm_of_lag = 60 * fps / lags
    usable = (bpm_of_lag >= 55) & (bpm_of_lag <= 215)
    prior = np.exp(-0.5 * (np.log2(np.where(usable, bpm_of_lag, 1) / 115) / 0.9) ** 2)   # most songs: 70-170
    score = np.where(usable, ac * prior, 0)
    guess = bpm_of_lag[int(np.argmax(score))]

    times = np.arange(len(env)) / fps
    def fit(bpm):
        period = 60 / bpm
        best = (-1.0, 0.0)
        for phase in np.arange(0, period, 0.01):
            beats = np.arange(phase, times[-1], period)
            value = np.interp(beats, times, env).mean()
            if value > best[0]:
                best = (value, phase)
        return best
    candidates = []
    for factor in (1.0, 2.0, 0.5):                               # the right octave is the one beats agree with
        b = guess * factor
        if 55 <= b <= 215:
            fine = max(((fit(x), x) for x in np.arange(b * 0.97, b * 1.03, max(0.05, b * 0.0015))), key=lambda r: r[0][0])
            candidates.append((fine[0][0] * math.exp(-0.5 * (math.log2(fine[1] / 115) / 0.9) ** 2), fine[1], fine[0][1]))
    _, bpm, phase = max(candidates)
    return round(float(bpm), 1), round(float(phase), 3)


# ------------------------------------------------------------------------------------------------ cuts --

def cut_times(count, total, line_starts, beat=None):
    """When each picture starts. Even spacing first; each cut then moves to the nearest lyric line start within
    40 % of a picture's length, and onto the nearest beat if `beat` (bpm, first beat) is given."""
    if count <= 1:
        return [0.0]
    length = total / count
    cuts = [0.0]
    for k in range(1, count):
        target = k * length
        earliest = cuts[-1] + 0.3 * length                       # never two cuts too close together
        near = [t for t in line_starts if abs(t - target) <= 0.4 * length and t > earliest]
        t = min(near, key=lambda x: abs(x - target)) if near else target
        if beat:
            period, first = 60 / beat[0], beat[1]
            snapped = first + round((t - first) / period) * period
            if snapped <= earliest:
                snapped += period
            if 0 < snapped < total:
                t = snapped
        cuts.append(max(t, earliest))
    return [round(c, 3) for c in cuts]


# --------------------------------------------------------------------------------------------- pictures --

def open_picture(path):
    from PIL import Image, ImageOps
    img = Image.open(path)
    img = ImageOps.exif_transpose(img)
    if img.mode in ('RGBA', 'LA', 'P'):
        img = img.convert('RGBA')
        flat = Image.new('RGB', img.size, (0, 0, 0))
        flat.paste(img, mask=img.split()[-1])
        return flat
    return img.convert('RGB')


def canvas(path, size, fill):
    """The picture at `size`: cropped to fill it, or whole with black bars."""
    from PIL import Image
    W, H = size
    src = open_picture(path)
    scale = max(W / src.width, H / src.height) if fill else min(W / src.width, H / src.height)
    src = src.resize((max(1, round(src.width * scale)), max(1, round(src.height * scale))), Image.LANCZOS)
    out = Image.new('RGB', (W, H), (0, 0, 0))
    out.paste(src, ((W - src.width) // 2, (H - src.height) // 2))
    return out


# How the words look. Set once from the command line (style_from), read by words_layer and title_card.
STYLE = dict(font=None, index=0, scale=1.0, colour=(255, 255, 255), outline=(0, 0, 0), band=120, position='bottom')


def hex_colour(text, default):
    text = (text or '').lstrip('#')
    try:
        return tuple(int(text[i:i + 2], 16) for i in (0, 2, 4)) if len(text) == 6 else default
    except ValueError:
        return default


def style_from(args):
    STYLE.update(font=args.font or None, index=args.font_index, scale=max(0.3, min(3.0, args.text_scale)),
                 colour=hex_colour(args.text_colour, (255, 255, 255)), outline=hex_colour(args.outline_colour, (0, 0, 0)),
                 band=max(0, min(255, args.band)), position=args.position)


def face(px):
    """The chosen font at px pixels, or the skill's (Avenir Next) when none is chosen or it cannot be read."""
    from PIL import ImageFont
    if STYLE['font']:
        try:
            return ImageFont.truetype(STYLE['font'], px, index=STYLE['index'])
        except OSError:
            pass
    return L.font(px)


def words_layer(size, text):
    """A transparent layer: a soft dark band where the words go and, if any, the words with their outline."""
    from PIL import Image, ImageDraw, ImageFilter
    W, H = size
    vertical = H > W
    phone = H / W > 1.6               # 9:16: the words stay clear of the buttons TikTok and Reels draw at the bottom
    where = STYLE['position']
    layer = Image.new('RGBA', size, (0, 0, 0, 0))
    if STYLE['band']:
        shade = Image.new('L', size, 0)
        band = {'bottom': (0.58, 0.92) if phone else (0.64, 1.0), 'middle': (0.36, 0.64),
                'top': (0.08, 0.42) if vertical else (0.0, 0.38)}[where]
        ImageDraw.Draw(shade).rectangle((0, int(H * band[0]), W, int(H * band[1])), fill=STYLE['band'])
        layer.putalpha(shade.filter(ImageFilter.GaussianBlur(min(W, H) * 0.06)))
    if not text:
        return layer
    draw = ImageDraw.Draw(layer)
    size_px = int(min(W, H) * 0.062 * STYLE['scale'])
    while True:
        font = face(size_px)
        rows = L.wrap(draw, text, font, W * 0.86)
        if len(rows) <= (3 if vertical else 2) or size_px <= min(W, H) * 0.04 * STYLE['scale']:
            break
        size_px = int(size_px * 0.9)
    stroke = max(2, round(size_px * 0.09))
    step = int(size_px * 1.18)
    if where == 'bottom':
        y = H - int(H * (0.13 if phone else 0.06)) - step * len(rows)         # 9:16: above the apps' buttons
    elif where == 'middle':
        y = int(H / 2 - step * len(rows) / 2)
    else:
        y = int(H * (0.12 if vertical else 0.085))
    for row in rows:
        x = (W - draw.textlength(row, font=font)) / 2
        draw.text((x, y), row, font=font, fill=STYLE['colour'] + (255,), stroke_width=stroke,
                  stroke_fill=STYLE['outline'] + (255,))
        y += step
    return layer


def title_card(size, title, subtitle):
    """A transparent layer: the title, large, in the middle, and a smaller second line under it."""
    from PIL import Image, ImageDraw
    W, H = size
    layer = Image.new('RGBA', size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    blocks = []
    def fit(text, px, limit):
        """Rows that fit the width: smaller type first, then long words cut, then an ellipsis after `limit` rows."""
        while True:
            font = face(px)
            rows = []
            for row in L.wrap(draw, text, font, W * 0.86):
                while draw.textlength(row, font=font) > W * 0.86 and len(row) > 1:      # a word wider than the frame
                    cut = len(row)
                    while cut > 1 and draw.textlength(row[:cut], font=font) > W * 0.86:
                        cut -= 1
                    rows.append(row[:cut])
                    row = row[cut:]
                rows.append(row)
            if len(rows) <= limit or px <= min(W, H) * 0.03:
                break
            px = int(px * 0.9)
        if len(rows) > limit:
            rows = rows[:limit]
            while rows[-1] and draw.textlength(rows[-1] + '…', font=font) > W * 0.86:
                rows[-1] = rows[-1][:-1]
            rows[-1] = rows[-1].rstrip() + '…'
        return rows, font, px
    for text, share, limit in ((title, 0.095, 2), (subtitle, 0.05, 2)):
        if text:
            blocks.append(fit(text, int(min(W, H) * share), limit))
    height = sum(int(px * 1.2) * len(rows) for rows, _, px in blocks) + (int(min(W, H) * 0.02) if len(blocks) > 1 else 0)
    y = H * (0.28 if STYLE['position'] == 'middle' else 0.45) - height / 2     # clear of words in the middle
    for rows, font, px in blocks:
        for row in rows:
            x = (W - draw.textlength(row, font=font)) / 2
            draw.text((x, y), row, font=font, fill=STYLE['colour'] + (255,),
                      stroke_width=max(2, round(px * 0.07)), stroke_fill=STYLE['outline'] + (255,))
            y += int(px * 1.2)
        y += int(min(W, H) * 0.02)
    return layer


# ------------------------------------------------------------------------------------------------ video --

def audio_options(song, out, mode, fade=None):
    """(ffmpeg audio options, output path). The song's own sound when asked, else AAC 320 kb/s.
    `fade` = (start, length) fades the sound out at the end: the sound must then be re-encoded, losslessly when
    the song is lossless (WAV stays 16/24-bit PCM, FLAC becomes Apple Lossless), as AAC 320 kb/s otherwise."""
    filters = ['-af', f'afade=t=out:st={fade[0]:.3f}:d={fade[1]:.3f}'] if fade else []
    if mode != 'original':
        return filters + ['-c:a', 'aac', '-b:a', '320k'], out
    probe = subprocess.run([L.tool('ffprobe'), '-v', 'error', '-select_streams', 'a:0', '-show_entries',
                            'stream=codec_name', '-of', 'default=nw=1:nk=1', str(song)], capture_output=True, text=True)
    codec = probe.stdout.strip()
    if codec.startswith('pcm_'):                                  # an .mp4 cannot carry WAV sound; a .mov can
        return (filters + ['-c:a', 'pcm_s24le' if '24' in codec or '32' in codec else 'pcm_s16le'] if fade
                else ['-c:a', 'copy']), out.with_suffix('.mov')
    if codec in ('mp3', 'aac') and not fade:
        return ['-c:a', 'copy'], out
    if codec in ('mp3', 'aac'):
        return filters + ['-c:a', 'aac', '-b:a', '320k'], out
    return filters + ['-c:a', 'alac'], out.with_suffix('.mov')   # FLAC, Ogg, ALAC: lossless, as QuickTime reads it


def video(song, lyrics_file, images, out, size='1920x1080', fit='fill', kenburns=0.0, beats=False,
          pick=0, shuffle=False, seed=0, words=True, audio='aac', kb_share=1.0, fade_share=0.0, also_mp4=False,
          end_fade=0.0, end_colour='black', sound_fade=0.0, fade_in=0.0, fade_in_colour='black',
          title='', subtitle='', title_length=4.0, title_start=0.0, pulse_amount=0.0, pulse_mode='zoom', pulse_every=1):
    from PIL import Image
    song = Path(song).expanduser().resolve()
    total = L.duration(song)
    cues = L.read_cues(Path(lyrics_file), total) if lyrics_file and lyrics_file != '-' else []
    images = list(dict.fromkeys(str(Path(p).expanduser().resolve()) for p in images))   # each file once
    given = list(images)
    if pick and pick < len(images):
        chosen = random.Random(seed).sample(images, pick)
        images = chosen if shuffle else [p for p in images if p in chosen]      # keep the order of the names
    elif shuffle:
        images = random.Random(seed).sample(images, len(images))
    shown_cues = cues if words else []
    W, H = L.parse_size(size)
    beat = tempo(song) if beats else None
    starts = cut_times(len(images), total, [a for a, _, _ in cues], beat)     # cuts follow the lyrics even unshown
    ends = starts[1:] + [total]
    amount = 0.04 + 0.21 * max(0.0, min(1.0, kenburns)) if kenburns > 0 else 0.0
    count = len(images)
    # which pictures move (Ken Burns) and which cuts dissolve (crossfade): a share of them, drawn at random but
    # repeatably (from the seed), at least one as soon as the share is above zero
    draw = random.Random(seed * 7919 + 1)
    def some(population, share):
        if share <= 0 or not population:
            return set()
        return set(draw.sample(population, min(len(population), max(1, round(share * len(population))))))
    moving = some(list(range(count)), kb_share) if amount else set()
    fading = some(list(range(1, count)), fade_share)
    out = Path(out).expanduser()
    end_fade = min(max(0.0, end_fade), total)
    sound_fade = min(max(0.0, sound_fade), total)
    sound, out = audio_options(song, out, audio, (total - sound_fade, sound_fade) if sound_fade else None)
    fade_to = Image.new('RGB', (W, H), (255, 255, 255) if end_colour == 'white' else (0, 0, 0)) if end_fade else None
    out.parent.mkdir(parents=True, exist_ok=True)

    layers = {}
    def layer_at(t):
        """The words of the moment (or none), on their soft dark band. No band at all in a clip without words."""
        if not shown_cues:
            return -1, None
        index = next((i for i, (a, b, _) in enumerate(shown_cues) if a <= t < b), -1)
        if index not in layers:
            layers[index] = words_layer((W, H), shown_cues[index][2] if index >= 0 else '')
        return index, layers[index]

    def compose(frame, layer):
        return (Image.alpha_composite(frame.convert('RGBA'), layer).convert('RGB') if layer else frame).tobytes()

    # each picture prepared once, when it is first needed; only the last few are kept in memory
    prepared = {}
    def picture(k):
        if k not in prepared:
            if len(prepared) >= 3:
                prepared.pop(min(prepared))
            quality = 1.5 if k in moving else 1.0                 # a larger source keeps the zoom sharp
            source = canvas(images[k], (round(W * quality), round(H * quality)), fit == 'fill')
            boxes = None
            if k in moving:
                # Ken Burns: the frame window moves from a start box to an end box along a STRAIGHT line at a
                # STEADY speed, and its size changes at a steady zoom rate (geometric), so nothing weaves or speeds
                # up. Moving pictures zoom in and out in turn; the drift crosses the picture through its middle, in
                # a random direction. Both boxes stay inside the picture, hence every box in between does too.
                rnd = random.Random(k)
                zoom_lo, zoom_hi = 1.0 + 0.15 * amount, 1.0 + amount    # never exactly 1: room left to drift
                z0, z1 = (zoom_lo, zoom_hi) if sorted(moving).index(k) % 2 == 0 else (zoom_hi, zoom_lo)
                angle = rnd.uniform(0, 2 * math.pi)
                drift = (math.cos(angle) * 0.8, math.sin(angle) * 0.8)
                def box(z, side):                                     # side -1 = start of the drift, +1 = end
                    w, h = source.width / z, source.height / z
                    return (source.width / 2 + side * drift[0] * (source.width - w) / 2,
                            source.height / 2 + side * drift[1] * (source.height - h) / 2, w, h)
                boxes = (box(z0, -1), box(z1, 1))
            prepared[k] = (source, boxes)
        return prepared[k]

    def frame_of(k, t):
        """Picture k at time t (its Ken Burns position follows its own start and end)."""
        source, boxes = picture(k)
        if not boxes:
            return source
        b0, b1 = boxes
        p = min(1.0, max(0.0, (t - starts[k]) / max(0.04, ends[k] - starts[k])))
        cx, cy = b0[0] + (b1[0] - b0[0]) * p, b0[1] + (b1[1] - b0[1]) * p       # straight line, constant speed
        sw, sh = b0[2] * (b1[2] / b0[2]) ** p, b0[3] * (b1[3] / b0[3]) ** p     # constant zoom rate
        return source.transform((W, H), Image.EXTENT, (cx - sw / 2, cy - sh / 2, cx + sw / 2, cy + sh / 2),
                                Image.BILINEAR)

    # a crossfade lasts 1 s, centred on the cut, shorter if either picture is short
    fade_len = {k: min(1.0, 0.4 * min(ends[k - 1] - starts[k - 1], ends[k] - starts[k])) for k in fading}

    encoder = subprocess.Popen(
        [L.tool('ffmpeg'), '-v', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', f'{W}x{H}', '-r', str(FPS),
         '-i', '-', '-i', str(song), '-map', '0:v', '-map', '1:a', '-c:v', 'libx264', '-preset', 'medium', '-crf', '18',
         '-pix_fmt', 'yuv420p', *sound, '-t', f'{total:.3f}', '-movflags', '+faststart', str(out)],
        stdin=subprocess.PIPE)
    frames_total = round(total * FPS)

    # the start: a fade from a colour, and a title card
    fade_in = min(max(0.0, fade_in), total)
    fade_from = Image.new('RGB', (W, H), (255, 255, 255) if fade_in_colour == 'white' else (0, 0, 0)) if fade_in else None
    title_from = min(max(0.0, title_start), total)
    title_len = min(max(0.0, title_length), total - title_from) if (title or subtitle) else 0.0
    title_layer = title_card((W, H), title, subtitle) if title_len else None
    def showing_title(t):
        return title_len > 0 and title_from <= t < title_from + title_len
    def with_title(frame, t):
        ramp = min(0.8, title_len / 3)                            # fades in and out within its own time
        u = t - title_from
        strength = max(0.0, min(1.0, u / ramp, (title_len - u) / ramp))
        layer = title_layer.copy()
        layer.putalpha(title_layer.getchannel('A').point(lambda a: int(a * strength)))
        return Image.alpha_composite(frame.convert('RGBA'), layer).convert('RGB')

    # the beat pulse: on every beat, every second beat or every bar, a quick zoom (or flash) that dies away
    grid = (beat or tempo(song)) if pulse_amount > 0 else None
    def pulse_at(t):
        if not grid:
            return 0.0
        period = 60 / grid[0] * max(1, pulse_every)
        since = (t - grid[1]) % period if t >= grid[1] else 99.0
        return pulse_amount * math.exp(-since / 0.11)          # sharp attack, gone after about a third of a second
    def pulse(frame, strength):
        if strength <= 0.002:
            return frame
        if pulse_mode == 'flash':
            return Image.blend(frame, Image.new('RGB', frame.size, (255, 255, 255)), 0.45 * strength)
        z = 1 + 0.08 * strength                                   # zoom: up to 8 % at full strength
        w, h = W / z, H / z
        return frame.transform((W, H), Image.EXTENT, ((W - w) / 2, (H - h) / 2, (W + w) / 2, (H + h) / 2), Image.BILINEAR)

    cache = (None, None)
    k = 0
    for f in range(frames_total):
        t = f / FPS
        while k + 1 < count and t >= starts[k + 1]:
            k += 1
        key, layer = layer_at(t)
        # inside a crossfade? (the second half of the previous cut's, or the first half of the next one's)
        blend = None
        if k in fade_len and t < starts[k] + fade_len[k] / 2:
            blend = (k - 1, k, 0.5 + (t - starts[k]) / fade_len[k])
        elif k + 1 in fade_len and t >= starts[k + 1] - fade_len[k + 1] / 2:
            blend = (k, k + 1, 0.5 - (starts[k + 1] - t) / fade_len[k + 1])
        effects = pulse_at(t) > 0.002 or showing_title(t) or (fade_from is not None and t < fade_in)
        if blend:
            a, b, mix = blend
            picture_now = Image.blend(frame_of(a, t), frame_of(b, t), min(1.0, max(0.0, mix)))
        elif k in moving or effects:
            picture_now = frame_of(k, t)
        else:
            picture_now = None
        if picture_now is None:
            if cache[0] != (k, key):                              # a still picture only changes with the words
                cache = ((k, key), compose(frame_of(k, t), layer))
            data = cache[1]
        else:
            picture_now = pulse(picture_now, pulse_at(t))         # the beat: a short zoom or flash
            if showing_title(t):                                  # the title, over the picture, under the words
                picture_now = with_title(picture_now, t)
            if fade_from is not None and t < fade_in:             # the start: the picture comes in from a colour
                picture_now = Image.blend(fade_from, picture_now, max(0.0, t / fade_in))
            data = compose(picture_now, layer)
        if fade_to is not None and t > total - end_fade:          # the end: the picture (and words) fade out
            mix = min(1.0, (t - (total - end_fade)) / end_fade)
            data = Image.blend(Image.frombytes('RGB', (W, H), data), fade_to, mix).tobytes()
        encoder.stdin.write(data)
        if (f + 1) % FPS == 0:
            print(f'progress {(f + 1) / frames_total:.3f}', flush=True)
    encoder.stdin.close()
    if encoder.wait() != 0:
        sys.exit('ffmpeg could not write the video.')

    # every setting written next to the video, so that it can be made again exactly
    font_note = (Path(STYLE['font']).name + (f" (face {STYLE['index']})" if STYLE['index'] else '')) if STYLE['font'] else 'Avenir Next'
    notes = [f'Lyric video', f'Song: {song}', f'Lyrics: {lyrics_file}',
             f'Format: {W}x{H}, {"crop to fill" if fit == "fill" else "whole picture with black bars"}',
             f'Words: {"shown" if shown_cues else ("none (instrumental)" if not cues else "not shown")}',
             f'Sound: {"the song itself" + (", untouched" if not sound_fade else ", re-encoded for the fade") if audio == "original" else "AAC 320 kb/s"}',
             f'Start: {f"fades in from {fade_in_colour} over {fade_in:g} s" if fade_in else "no fade-in"}, '
             f'{f"title {title!r}" + (f" / {subtitle!r}" if subtitle else "") + f" from {title_start:g} s for {title_length:g} s" if (title or subtitle) else "no title"}',
             f'Words style: {font_note}, '
             f'size x{STYLE["scale"]:g}, colour #{"%02X%02X%02X" % STYLE["colour"]}, outline #{"%02X%02X%02X" % STYLE["outline"]}, '
             f'band {STYLE["band"]}, {STYLE["position"]}',
             f'Beat pulse: {f"{pulse_mode} at {pulse_amount * 100:.0f} %, every {pulse_every} beat(s), on {grid[0]} BPM" if grid else "off"}',
             f'Ending: {f"fades to {end_colour} over {end_fade:g} s" if end_fade else "no picture fade"}, '
             f'{f"sound fades out over {sound_fade:g} s" if sound_fade else "no sound fade"}',
             f'Pictures: {len(images)} of {len(given)}' + (f', drawn at random (seed {seed})' if pick and pick < len(given) else '')
             + (f', order shuffled (seed {seed})' if shuffle else ', in the order of their names'),
             f'Ken Burns: {"off" if not amount else f"{kenburns:.2f} (zoom {amount * 100:.0f} %), on {len(moving)} of {count} pictures ({kb_share * 100:.0f} % asked)"}',
             f'Crossfades: {f"{len(fading)} of {count - 1} cuts ({fade_share * 100:.0f} % asked), 1 s each or less" if fading else "none"}',
             f'Seed: {seed} (the same seed with the same settings and pictures makes the same video)',
             f'Tempo: {f"{beat[0]} BPM, first beat at {beat[1]} s, cuts on the beat" if beat else "cuts not tied to the beat"}',
             '', 'Pictures (start - end):']
    notes += [f'  {L.stamp_lrc(a)} - {L.stamp_lrc(b)}  {"KB " if i in moving else "   "}{"fade " if i in fading else "     "}{p}'
              for i, (p, a, b) in enumerate(zip(images, starts, ends))]
    notes.append('  (KB = Ken Burns on this picture; fade = it arrives with a crossfade)')
    out.with_suffix('.txt').write_text('\n'.join(notes) + '\n', encoding='utf-8')
    if also_mp4 and out.suffix == '.mov':
        # the same pictures (copied, not re-encoded) with AAC sound, for Discord and the web, which refuse .mov
        copy = out.with_suffix('.mp4')
        L.run([L.tool('ffmpeg'), '-v', 'error', '-y', '-i', out, '-c:v', 'copy', '-c:a', 'aac', '-b:a', '320k',
               '-movflags', '+faststart', copy])
        print(f'Also written: {copy}')
    print('progress 1.000')
    print(f'Written: {out}')


def still(song, lyrics_file, image, out, size='1920x1080', fit='fill', at=None, title='', subtitle=''):
    """One frame, as a PNG, to judge how the words look: the picture (or a grey gradient), the words of the line
    sung at `at` seconds (by default, the middle of the first line) and, if given, the title."""
    from PIL import Image
    W, H = L.parse_size(size)
    cues = []
    if lyrics_file and lyrics_file != '-':
        total = L.duration(Path(song).expanduser()) if song else 600.0
        cues = L.read_cues(Path(lyrics_file), total)
    if image:
        picture = canvas(image, (W, H), fit == 'fill')
    else:
        picture = Image.linear_gradient('L').resize((W, H)).convert('RGB')
    if at is None and cues:
        at = (cues[0][0] + cues[0][1]) / 2
    text = next((c[2] for c in cues if at is not None and c[0] <= at < c[1]), cues[0][2] if cues else 'The words, as they will look')
    frame = Image.alpha_composite(picture.convert('RGBA'), words_layer((W, H), text))
    if title or subtitle:
        frame = Image.alpha_composite(frame, title_card((W, H), title, subtitle))
    frame.convert('RGB').save(out)
    print(f'Written: {out}')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='command', required=True)
    b = sub.add_parser('bpm')
    b.add_argument('song')
    def style_args(p):
        p.add_argument('--font', default='', help='a .ttf / .otf / .ttc file for the words and the title')
        p.add_argument('--font-index', type=int, default=0, help='which font of a .ttc collection')
        p.add_argument('--text-scale', type=float, default=1.0, help='size of the words, 1 = normal')
        p.add_argument('--text-colour', default='#FFFFFF')
        p.add_argument('--outline-colour', default='#000000')
        p.add_argument('--band', type=int, default=120, help='darkness of the band behind the words, 0 = none, 255 = black')
        p.add_argument('--position', choices=('bottom', 'middle', 'top'), default='bottom')
    st = sub.add_parser('still')
    st.add_argument('song')
    st.add_argument('lyrics')
    st.add_argument('--image', default='')
    st.add_argument('--size', default='1920x1080')
    st.add_argument('--fit', choices=('fill', 'fit'), default='fill')
    st.add_argument('--at', type=float, default=None)
    st.add_argument('--title', default='')
    st.add_argument('--subtitle', default='')
    st.add_argument('--out', required=True)
    style_args(st)
    v = sub.add_parser('video')
    style_args(v)
    v.add_argument('song')
    v.add_argument('lyrics')
    v.add_argument('--images', nargs='+', required=True)
    v.add_argument('--size', default='1920x1080')
    v.add_argument('--fit', choices=('fill', 'fit'), default='fill')
    v.add_argument('--kenburns', type=float, default=0.0)
    v.add_argument('--beats', action='store_true')
    v.add_argument('--pick', type=int, default=0)
    v.add_argument('--shuffle', action='store_true')
    v.add_argument('--seed', type=int, default=0)
    v.add_argument('--no-words', action='store_true')
    v.add_argument('--audio', choices=('aac', 'original'), default='aac')
    v.add_argument('--kb-share', type=float, default=1.0, help='share of the pictures with Ken Burns, 0..1')
    v.add_argument('--fades', type=float, default=0.0, help='share of the cuts that crossfade, 0..1')
    v.add_argument('--also-mp4', action='store_true', help='when the video is a .mov, also write an .mp4 copy')
    v.add_argument('--end-fade', type=float, default=0.0, help='seconds: the picture fades out at the end')
    v.add_argument('--end-colour', choices=('black', 'white'), default='black')
    v.add_argument('--sound-fade', type=float, default=0.0, help='seconds: the sound fades out at the end')
    v.add_argument('--fade-in', type=float, default=0.0, help='seconds: the picture fades in at the start')
    v.add_argument('--fade-in-colour', choices=('black', 'white'), default='black')
    v.add_argument('--title', default='', help='a title shown at the start')
    v.add_argument('--subtitle', default='', help='a smaller second line under the title (artist...)')
    v.add_argument('--title-length', type=float, default=4.0, help='seconds the title stays')
    v.add_argument('--title-start', type=float, default=0.0, help='seconds into the video when the title appears')
    v.add_argument('--pulse', type=float, default=0.0, help='0..1: a short zoom or flash on the beat')
    v.add_argument('--pulse-mode', choices=('zoom', 'flash'), default='zoom')
    v.add_argument('--pulse-every', type=int, choices=(1, 2, 4), default=1, help='every beat, every 2nd, every bar of 4')
    v.add_argument('--out', required=True)
    args = parser.parse_args()
    if args.command in ('still', 'video'):
        style_from(args)
    if args.command == 'still':
        return still(args.song, args.lyrics, args.image, args.out, args.size, args.fit, args.at, args.title, args.subtitle)
    if args.command == 'bpm':
        bpm, first = tempo(args.song)
        print(json.dumps(dict(bpm=bpm, first_beat=first)))
    else:
        video(args.song, args.lyrics, args.images, args.out, args.size, args.fit, args.kenburns, args.beats,
              args.pick, args.shuffle, args.seed, not args.no_words, args.audio, args.kb_share, args.fades,
              args.also_mp4, args.end_fade, args.end_colour, args.sound_fade, args.fade_in, args.fade_in_colour,
              title=args.title, subtitle=args.subtitle, title_length=args.title_length, title_start=args.title_start,
              pulse_amount=args.pulse, pulse_mode=args.pulse_mode, pulse_every=args.pulse_every)


if __name__ == '__main__':
    main()
