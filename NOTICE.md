# Notice

**Song2Lyrics Clip** — Copyright (c) 2026 Jean-Pascal (Quick-Eyed Sky). Released under
the MIT licence, see [LICENSE](LICENSE).

## What it runs, without including it

Song2Lyrics Clip contains no third-party code. It starts these programs, which you
install yourself (see the README), and talks to them only through files and
their command line:

| Program | Licence | Role |
|---|---|---|
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (`whisper-cli`) | MIT | speech recognition |
| [Whisper large-v3-turbo](https://github.com/openai/whisper), as converted for whisper.cpp | MIT | the model |
| [FFmpeg](https://ffmpeg.org) (`ffmpeg`, `ffprobe`) | LGPL 2.1+ / GPL 2+ depending on the build | audio decoding, video encoding |
| [Python 3](https://www.python.org) with [numpy](https://numpy.org) and [Pillow](https://python-pillow.org) | PSF, BSD, HPND | drawing the frames, tempo detection |
| [python-audio-separator](https://github.com/nomadkaraoke/python-audio-separator) with a BS-Roformer model (optional) | MIT (models: see their own terms) | separating the voice |

## Fonts

The words in the videos are drawn with fonts that come with macOS (Avenir Next,
or Helvetica). They are not included in this repository.
