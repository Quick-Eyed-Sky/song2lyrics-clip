#!/usr/bin/env python3
"""song-lyrics - the sung words of a song with their timing, and the videos that show them (macOS, Apple Silicon).

Commands (SONG = .wav .mp3 .flac .m4a ...; LYRICS = .lrc or .srt, from this tool, karadeo or edited by hand):
  lyrics.py doctor                                   what is installed, what is missing
  lyrics.py transcribe SONG [--stems] [--lang auto] [--out DIR]
  lyrics.py quicktime  SONG [LYRICS] [--image IMG] [--out DIR]     MP4 with a subtitle track (QuickTime, VLC)
  lyrics.py overlay    SONG [LYRICS] [--key green|blue] [--prores] [--out DIR]   iMovie green-screen overlay
  lyrics.py burn       SONG [LYRICS] [--image IMG] [--out DIR]     lyric video, words drawn over a picture
  lyrics.py all        SONG [--stems] [--image IMG] [--lang auto] [--out DIR]

Without LYRICS, the video commands use <out>/<song>.lrc, which `transcribe` writes. Everything lands in
~/Movies/Lyrics/<song>/ unless --out says otherwise (the song's own folder is never written to).

Engine: whisper.cpp (`whisper-cli`, Homebrew) with ggml-large-v3-turbo, `-mc 0` (no text carried between windows:
without it Whisper loops on music, "M.A.'s whisper, it shines" x 60) and DTW word timestamps (`-nfa -dtw`: line
starts within ~0.3 s of a karaoke tool's). `--stems` first isolates the voice with BS-Roformer (audio-separator).
Nothing is ever downloaded by this script.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HOME = Path.home()
WHISPER_DIR = HOME / '.cache' / 'whisper.cpp'
MODEL = Path(os.environ.get('SONG_LYRICS_MODEL', WHISPER_DIR / 'ggml-large-v3-turbo.bin'))
VAD_MODEL = WHISPER_DIR / 'ggml-silero-v5.1.2.bin'
SEPARATOR_DIR = HOME / '.cache' / 'audio-separator'
SEPARATOR_MODEL = 'model_bs_roformer_ep_317_sdr_12.9755.ckpt'
SEPARATOR_CANDIDATES = [os.environ.get('SONG_LYRICS_SEPARATOR'), shutil.which('audio-separator'),
                        str(HOME / '.local' / 'bin' / 'audio-separator')]
PILLOW_PYTHONS = [os.environ.get('SONG_LYRICS_PYTHON'), '/opt/homebrew/bin/python3', '/usr/bin/python3']
OUT_ROOT = HOME / 'Movies' / 'Lyrics'
STANDIN = Path(__file__).resolve().parent / 'numba_standin'
FONTS = [('/System/Library/Fonts/Avenir Next.ttc', 2), ('/System/Library/Fonts/Helvetica.ttc', 1)]
KEYS = {'green': (0, 255, 0), 'blue': (0, 0, 255)}
# what Whisper writes over music when nobody sings (dropped from the lyrics)
HALLUCINATIONS = re.compile(r'^(thank you( for watching)?|thanks for watching|subtitles? by.*|amara\.org.*|'
                            r'\W*(music|applause|instrumental|silence)\W*|♪+)[.!]*$', re.IGNORECASE)


def tool(name):
    found = shutil.which(name) or (f'/opt/homebrew/bin/{name}' if Path(f'/opt/homebrew/bin/{name}').exists() else None)
    if not found:
        sys.exit(f'{name} is not installed (Homebrew: brew install {"whisper.cpp" if name == "whisper-cli" else name}).')
    return found


def run(cmd, quiet=True, env=None):
    result = subprocess.run([str(c) for c in cmd], capture_output=True, text=True, env=env)
    if result.returncode != 0:
        tail = (result.stderr or result.stdout).strip().splitlines()[-12:]
        sys.exit(f'Failed: {Path(str(cmd[0])).name}\n' + '\n'.join(tail))
    if not quiet:
        print(result.stdout)
    return result


def out_dir(song, out):
    folder = Path(out).expanduser() if out else OUT_ROOT / Path(song).stem
    folder.mkdir(parents=True, exist_ok=True)
    return folder


def duration(path):
    r = run([tool('ffprobe'), '-v', 'error', '-show_entries', 'format=duration', '-of', 'default=nw=1:nk=1', path])
    return float(r.stdout.strip())


def stamp_lrc(t):
    t = max(0.0, t)
    return f'{int(t // 60):02d}:{t % 60:05.2f}'


def stamp_srt(t):
    t = max(0.0, t)
    ms = int(round(t * 1000))
    return f'{ms // 3600000:02d}:{ms // 60000 % 60:02d}:{ms // 1000 % 60:02d},{ms % 1000:03d}'


# ------------------------------------------------------------------------------------------ the voice --

def separator():
    for candidate in SEPARATOR_CANDIDATES:
        if candidate and Path(candidate).exists():
            return Path(candidate)
    return None


def isolate_vocals(song, folder):
    """The vocal stem (BS-Roformer), as <song>.vocals.flac in the output folder. None (and a note) if impossible."""
    sep = separator()
    if sep is None:
        print('  (no audio-separator found: transcribing the full mix)')
        return None
    if not (SEPARATOR_DIR / SEPARATOR_MODEL).exists():
        print(f'  (vocal model {SEPARATOR_MODEL} is not in {SEPARATOR_DIR}: transcribing the full mix)')
        return None
    target = folder / (Path(song).stem + '.vocals.flac')
    if target.exists():
        return target
    # a GPU allocation fails rather than starving the Mac (the low mark must stay under the high one, default 1.4)
    env = dict(os.environ, PYTORCH_MPS_HIGH_WATERMARK_RATIO='0.7', PYTORCH_MPS_LOW_WATERMARK_RATIO='0.5')
    python = sep.parent / 'python'
    probe = subprocess.run([str(python), '-c', 'import numba'], capture_output=True, text=True)
    if probe.returncode != 0 and 'NumPy' in (probe.stderr + probe.stdout):
        # the environment's numba refuses its NumPy; librosa only needs numba's decorators on this path
        env['PYTHONPATH'] = str(STANDIN) + os.pathsep + env.get('PYTHONPATH', '')
    with tempfile.TemporaryDirectory() as tmp:
        print('  isolating the voice (BS-Roformer)...')
        run([sep, song, '-m', SEPARATOR_MODEL, '--model_file_dir', SEPARATOR_DIR, '--output_dir', tmp,
             '--output_format', 'WAV', '--single_stem', 'Vocals'], env=env)
        stems = sorted(Path(tmp).glob('*Vocals*'))
        if not stems:
            print('  (the separation produced no vocal file: transcribing the full mix)')
            return None
        run([tool('ffmpeg'), '-v', 'error', '-y', '-i', stems[0], '-c:a', 'flac', target])
    return target


# ---------------------------------------------------------------------------------------- transcribe --

def dtw_preset(model):
    name = re.sub(r'-q\d.*$', '', Path(model).stem.removeprefix('ggml-'))
    return name.replace('-', '.') if name.startswith(('large', 'medium', 'small', 'base', 'tiny')) else None


def words_of(segment):
    """[(word, start seconds)] from whisper.cpp's full JSON: DTW times when present, token offsets otherwise."""
    words = []
    for token in segment.get('tokens', []):
        text = token.get('text', '')
        if not text or text.startswith('[_') or text.startswith('<|'):
            continue
        t = token.get('t_dtw', -1)
        t = t / 100 if isinstance(t, (int, float)) and t >= 0 else token['offsets']['from'] / 1000
        if text.startswith(' ') or not words:
            words.append([text.strip(), t])
        else:
            words[-1][0] += text
    return [(w, t) for w, t in words if w]


def lines_of(segments, max_chars=44, gap=3.0):
    """Lyric lines: a new line after . ? !, after a pause of `gap` seconds, or before `max_chars` is exceeded."""
    lines = []
    for segment in segments:
        current, start, previous = [], None, None
        for word, t in words_of(segment):
            if current and (len(' '.join(current + [word])) > max_chars or (t - previous) > gap):
                lines.append((start, ' '.join(current)))
                current = []
            if not current:
                start = t
            current.append(word)
            previous = t
            if word[-1:] in '.?!':
                lines.append((start, ' '.join(current)))
                current = []
        if current:
            lines.append((start, ' '.join(current)))
    out = []
    for start, text in lines:
        text = re.sub(r'\*[^*]*(\*|$)|\([^)]*\)|\[[^\]]*\]', '', text)     # *cough*, (laughs), [Music]
        text = re.sub(r'\s{2,}', ' ', text).strip().strip('"').rstrip(',;:.').strip()
        if text and re.search(r'[^\W\d_]', text) and not HALLUCINATIONS.match(text):
            out.append((round(start, 2), text))
    return out


def cues_from_lines(lines, total):
    """(start, end, text): a line stays until the next one, but not longer than its reading time allows."""
    cues = []
    for i, (start, text) in enumerate(lines):
        nxt = lines[i + 1][0] if i + 1 < len(lines) else total
        show = min(7.0, max(3.0, 2.0 + 0.09 * len(text)))
        cues.append((start, max(start + 0.5, min(nxt - 0.05, start + show, total)), text))
    return cues


def was_edited(folder, name):
    """True when <name>.lrc is newer than the transcription that wrote it (edited by hand or in an app).
    Asked BEFORE the new .words.json is written: afterwards the .lrc would always look older."""
    lrc, words = folder / (name + '.lrc'), folder / (name + '.words.json')
    return lrc.exists() and words.exists() and lrc.stat().st_mtime > words.stat().st_mtime + 1


def write_lyrics(folder, name, lines, total, engine, edited=False):
    lrc, srt, txt = (folder / (name + ext) for ext in ('.lrc', '.srt', '.txt'))
    if edited:
        # never overwrite an edit: the new lyrics go to <name>.whisper.* and the edited files stay as they are
        lrc, srt, txt = (folder / (name + '.whisper' + ext) for ext in ('.lrc', '.srt', '.txt'))
        print(f'  {name}.lrc was edited since the last transcription: the new one is {lrc.name}')
    lrc.write_text(f'[ti:{name}]\n[re:song-lyrics · {engine}]\n'
                   + ''.join(f'[{stamp_lrc(t)}]{text}\n' for t, text in lines), encoding='utf-8')
    cues = cues_from_lines(lines, total)
    srt.write_text(''.join(f'{i}\n{stamp_srt(a)} --> {stamp_srt(b)}\n{text}\n\n' for i, (a, b, text) in enumerate(cues, 1)),
                   encoding='utf-8')
    txt.write_text(''.join(text + '\n' for _, text in lines), encoding='utf-8')
    return lrc, srt, txt


def transcribe(song, out=None, stems=False, lang='auto'):
    song = Path(song).expanduser().resolve()
    folder = out_dir(song, out)
    if not MODEL.exists():
        sys.exit(f'The Whisper model is missing: {MODEL}')
    total = duration(song)
    source = isolate_vocals(song, folder) if stems else None
    with tempfile.TemporaryDirectory() as tmp:
        wav16 = Path(tmp) / 'in16k.wav'
        run([tool('ffmpeg'), '-v', 'error', '-y', '-i', source or song, '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le', wav16])
        base = Path(tmp) / 'whisper'
        cmd = [tool('whisper-cli'), '-m', MODEL, '-f', wav16, '-l', lang, '-mc', '0', '-ojf', '-of', base, '-np']
        preset = dtw_preset(MODEL)
        if preset:
            cmd += ['-nfa', '-dtw', preset]             # DTW needs flash attention off
        # no --vad: on a mix it hears no speech, and on a vocal stem it shifts the DTW word times (tested 5 Oct)
        print(f'  transcribing {song.name} ({total:.0f} s) with {MODEL.name}{" on the vocal stem" if source else ""}...')
        run(cmd)
        data = json.loads(base.with_suffix('.json').read_text(encoding='utf-8', errors='replace'))
    segments = data.get('transcription', [])
    lines = lines_of(segments)
    name = song.stem
    edited = was_edited(folder, name)
    engine = MODEL.stem.removeprefix('ggml-') + (' on the BS-Roformer vocal stem' if source else '')
    (folder / (name + '.words.json')).write_text(json.dumps(dict(
        song=str(song), engine=engine, language=data.get('result', {}).get('language'),
        segments=[dict(text=s.get('text', '').strip(), words=words_of(s)) for s in segments]),
        ensure_ascii=False, indent=1), encoding='utf-8')
    lrc, srt, txt = write_lyrics(folder, name, lines, total, engine, edited)
    print(f'  language: {data.get("result", {}).get("language")} · {len(lines)} lines\n')
    print(lrc.read_text(encoding='utf-8'))
    print(f'Written: {lrc}\n         {srt}\n         {txt}')
    return lrc


# -------------------------------------------------------------------------------------------- cues --

LRC_STAMP = re.compile(r'\[(\d+):(\d{1,2}(?:[.:]\d{1,3})?)\]')


def read_cues(path, total):
    path = Path(path).expanduser()
    text = path.read_text(encoding='utf-8', errors='replace').lstrip('﻿')
    if path.suffix.lower() == '.srt':
        cues = []
        for block in re.split(r'\n\s*\n', text.strip()):
            rows = block.strip().splitlines()
            m = next((re.match(r'(\d+):(\d+):(\d+)[,.](\d+)\s*-->\s*(\d+):(\d+):(\d+)[,.](\d+)', r) for r in rows if '-->' in r), None)
            if not m:
                continue
            g = [int(x) for x in m.groups()]
            a = g[0] * 3600 + g[1] * 60 + g[2] + g[3] / 1000
            b = g[4] * 3600 + g[5] * 60 + g[6] + g[7] / 1000
            body = ' '.join(r.strip() for r in rows[rows.index(m.string) + 1:] if r.strip())
            if body:
                cues.append((a, b, re.sub(r'<[^>]+>', '', body)))
        return cues
    offset = 0.0
    found = re.search(r'\[offset:\s*([+-]?\d+)\]', text, re.IGNORECASE)
    if found:
        offset = int(found[1]) / 1000              # LRC: a positive offset shows the words earlier
    lines = []
    for row in text.splitlines():
        stamps = LRC_STAMP.findall(row)
        words = LRC_STAMP.sub('', row).strip()
        for minutes, seconds in stamps:
            lines.append((int(minutes) * 60 + float(seconds.replace(':', '.')) - offset, words))
    lines = sorted((t, w) for t, w in lines if w)
    return cues_from_lines(lines, total)


def lyrics_for(song, lyrics, folder):
    path = Path(lyrics).expanduser() if lyrics else folder / (Path(song).stem + '.lrc')
    if not path.exists():
        sys.exit(f'No lyrics file: {path} (run `transcribe` first, or give an .lrc / .srt).')
    return path


# ------------------------------------------------------------------------------------------ pictures --

def ensure_pillow():
    try:
        import PIL  # noqa: F401
        return
    except ImportError:
        pass
    for python in PILLOW_PYTHONS:
        if python and Path(python).exists() and subprocess.run([python, '-c', 'import PIL'], capture_output=True).returncode == 0:
            os.execv(python, [python, __file__] + sys.argv[1:])
    sys.exit('Pillow is needed to draw the words (pip install pillow, or set SONG_LYRICS_PYTHON).')


def font(size):
    from PIL import ImageFont
    for path, index in FONTS:
        if Path(path).exists():
            try:
                return ImageFont.truetype(path, size, index=index)
            except OSError:
                continue
    return ImageFont.load_default()


def wrap(draw, text, face, width):
    rows, current = [], ''
    for word in text.split():
        trial = (current + ' ' + word).strip()
        if current and draw.textlength(trial, font=face) > width:
            rows.append(current)
            current = word
        else:
            current = trial
    return rows + ([current] if current else [])


def draw_words(img, text):
    """White words with a black outline in the lower third; up to two rows, smaller type if needed."""
    from PIL import ImageDraw
    W, H = img.size
    draw = ImageDraw.Draw(img)
    size = int(H * 0.062)
    while True:
        face = font(size)
        rows = wrap(draw, text, face, W * 0.86)
        if len(rows) <= 2 or size <= H * 0.038:
            break
        size = int(size * 0.9)
    stroke = max(2, round(size * 0.09))
    step = int(size * 1.18)
    y = H - int(H * 0.085) - step * len(rows)
    for row in rows:
        x = (W - draw.textlength(row, font=face)) / 2
        draw.text((x, y), row, font=face, fill=(255, 255, 255), stroke_width=stroke, stroke_fill=(0, 0, 0))
        y += step
    return img


def backdrop(size, image=None, colour=(0, 0, 0)):
    from PIL import Image, ImageDraw
    W, H = size
    if not image:
        return Image.new('RGB', size, colour)
    src = Image.open(Path(image).expanduser()).convert('RGB')
    scale = max(W / src.width, H / src.height)                    # cover the frame, crop the excess
    src = src.resize((round(src.width * scale), round(src.height * scale)), Image.LANCZOS)
    left, top = (src.width - W) // 2, (src.height - H) // 2
    img = src.crop((left, top, left + W, top + H))
    shade = Image.new('L', size, 0)                                # a soft dark band under the words
    ImageDraw.Draw(shade).rectangle((0, int(H * 0.62), W, H), fill=150)
    from PIL import ImageFilter
    shade = shade.filter(ImageFilter.GaussianBlur(H * 0.06))
    return Image.composite(Image.new('RGB', size, (0, 0, 0)), img, shade)


def sequence(cues, total, size, base, folder, tmp):
    """PNG frames + an ffconcat list: one picture per lyric line, the bare picture in between."""
    blank = Path(tmp) / 'blank.png'
    base.save(blank)
    entries, clock = [], 0.0
    for i, (a, b, text) in enumerate(cues):
        a, b = max(a, clock), min(b, total)
        if b <= a:
            continue
        if a > clock:
            entries.append((blank, a - clock))
        frame = Path(tmp) / f'line{i:03d}.png'
        draw_words(base.copy(), text).save(frame)
        entries.append((frame, b - a))
        clock = b
    if total > clock:
        entries.append((blank, total - clock))
    listing = Path(tmp) / 'frames.ffconcat'
    body = 'ffconcat version 1.0\n' + ''.join(f"file '{p}'\nduration {d:.3f}\n" for p, d in entries)
    listing.write_text(body + f"file '{entries[-1][0]}'\n", encoding='utf-8')   # the last picture is listed twice
    return listing


def parse_size(text):
    w, h = (int(x) for x in text.lower().split('x'))
    return w, h


# -------------------------------------------------------------------------------------------- videos --

def quicktime(song, lyrics=None, image=None, out=None, size='1920x1080'):
    song = Path(song).expanduser().resolve()
    folder = out_dir(song, out)
    total = duration(song)
    cues = read_cues(lyrics_for(song, lyrics, folder), total)
    target = folder / (song.stem + '_quicktime.mp4')
    W, H = parse_size(size)
    with tempfile.TemporaryDirectory() as tmp:
        srt = Path(tmp) / 'words.srt'
        srt.write_text(''.join(f'{i}\n{stamp_srt(a)} --> {stamp_srt(b)}\n{t}\n\n' for i, (a, b, t) in enumerate(cues, 1)),
                       encoding='utf-8')
        picture = (['-loop', '1', '-i', Path(image).expanduser()] if image
                   else ['-f', 'lavfi', '-i', f'color=c=black:s={W}x{H}:r=25'])
        fit = f'scale={W}:{H}:force_original_aspect_ratio=increase,crop={W}:{H},format=yuv420p'
        run([tool('ffmpeg'), '-v', 'error', '-y', *picture, '-i', song, '-i', srt, '-map', '0:v', '-map', '1:a', '-map', '2:s',
             '-vf', fit, '-r', '25', '-c:v', 'libx264', '-tune', 'stillimage', '-crf', '20', '-pix_fmt', 'yuv420p',
             '-c:a', 'aac', '-b:a', '256k', '-c:s', 'mov_text', '-metadata:s:s:0', 'language=eng',
             '-disposition:s:0', 'default', '-t', f'{total:.3f}', target])     # not -shortest: it stops at the last line
    print(f'Written: {target}\n  QuickTime shows the words (Présentation › Sous-titres if they are hidden); VLC too.')
    return target


def overlay(song, lyrics=None, key='green', prores=False, out=None, size='1920x1080'):
    ensure_pillow()
    song = Path(song).expanduser().resolve()
    folder = out_dir(song, out)
    total = duration(song)
    cues = read_cues(lyrics_for(song, lyrics, folder), total)
    W, H = parse_size(size)
    target = folder / (song.stem + f'_imovie_{key}screen' + ('.mov' if prores else '.mp4'))
    with tempfile.TemporaryDirectory() as tmp:
        listing = sequence(cues, total, (W, H), backdrop((W, H), colour=KEYS[key]), folder, tmp)
        codec = (['-c:v', 'prores_ks', '-profile:v', '1', '-pix_fmt', 'yuv422p10le'] if prores
                 else ['-c:v', 'libx264', '-crf', '12', '-preset', 'medium', '-pix_fmt', 'yuv420p'])
        run([tool('ffmpeg'), '-v', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', listing,
             '-vf', 'fps=25', *codec, '-t', f'{total:.3f}', target])
    print(f'Written: {target}\n'
          '  iMovie: put the song and your pictures or clips in the timeline, drag this file ABOVE them at 0:00,\n'
          f'  then Video overlay settings › {"Green" if key == "green" else "Blue"}/Blue Screen. Mute nothing: the overlay has no sound.')
    return target


def burn(song, lyrics=None, image=None, out=None, size='1920x1080'):
    ensure_pillow()
    song = Path(song).expanduser().resolve()
    folder = out_dir(song, out)
    total = duration(song)
    cues = read_cues(lyrics_for(song, lyrics, folder), total)
    W, H = parse_size(size)
    target = folder / (song.stem + '_lyric_video.mp4')
    with tempfile.TemporaryDirectory() as tmp:
        listing = sequence(cues, total, (W, H), backdrop((W, H), image), folder, tmp)
        run([tool('ffmpeg'), '-v', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', listing, '-i', song,
             '-map', '0:v', '-map', '1:a', '-vf', 'fps=25,format=yuv420p', '-c:v', 'libx264', '-crf', '18',
             '-c:a', 'aac', '-b:a', '256k', '-t', f'{total:.3f}', target])
    print(f'Written: {target}')
    return target


def doctor():
    rows = [('ffmpeg', shutil.which('ffmpeg')), ('whisper-cli', shutil.which('whisper-cli')),
            ('Whisper model', MODEL if MODEL.exists() else None), ('VAD model', VAD_MODEL if VAD_MODEL.exists() else None),
            ('audio-separator', separator()),
            ('BS-Roformer model', SEPARATOR_DIR / SEPARATOR_MODEL if (SEPARATOR_DIR / SEPARATOR_MODEL).exists() else None)]
    try:
        import PIL
        rows.append(('Pillow', f'{sys.executable} ({PIL.__version__})'))
    except ImportError:
        found = next((p for p in PILLOW_PYTHONS if p and Path(p).exists() and
                      subprocess.run([p, '-c', 'import PIL'], capture_output=True).returncode == 0), None)
        rows.append(('Pillow', f'via {found}' if found else None))
    for name, value in rows:
        print(f'{"ok " if value else "-- "} {name:18s} {value or "missing"}')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('doctor')
    for name in ('transcribe', 'quicktime', 'overlay', 'burn', 'all'):
        p = sub.add_parser(name)
        p.add_argument('song')
        if name in ('quicktime', 'overlay', 'burn'):
            p.add_argument('lyrics', nargs='?')
        if name in ('transcribe', 'all'):
            p.add_argument('--stems', action='store_true', help='isolate the voice first (BS-Roformer)')
            p.add_argument('--lang', default='auto')
        if name in ('quicktime', 'burn', 'all'):
            p.add_argument('--image')
        if name == 'overlay':
            p.add_argument('--key', choices=sorted(KEYS), default='green')
            p.add_argument('--prores', action='store_true', help='ProRes 422 LT .mov (cleaner keying, larger file)')
        p.add_argument('--size', default='1920x1080')
        p.add_argument('--out')
    args = parser.parse_args()
    if args.command == 'doctor':
        return doctor()
    if args.command == 'transcribe':
        return transcribe(args.song, args.out, args.stems, args.lang)
    if args.command == 'quicktime':
        return quicktime(args.song, args.lyrics, args.image, args.out, args.size)
    if args.command == 'overlay':
        return overlay(args.song, args.lyrics, args.key, args.prores, args.out, args.size)
    if args.command == 'burn':
        return burn(args.song, args.lyrics, args.image, args.out, args.size)
    if args.command == 'all':
        ensure_pillow()
        lrc = transcribe(args.song, args.out, args.stems, args.lang)
        quicktime(args.song, lrc, args.image, args.out, args.size)
        overlay(args.song, lrc, out=args.out, size=args.size)
        if args.image:
            burn(args.song, lrc, args.image, args.out, args.size)


if __name__ == '__main__':
    main()
