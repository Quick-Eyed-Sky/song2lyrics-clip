# Song2Lyrics Clip — user guide

*Version 0.9 · macOS 14 or later · Apple Silicon*

Song2Lyrics Clip is a small Mac app. Drop a song on its window and it writes down the
**sung words with their timing**, as `.lrc`, `.srt` and `.txt` files, in a few
seconds. Then, if you like, it turns the song into a **lyric video**: one picture
or a hundred, cut where the lyrics change and on the beat, with a slow Ken Burns
movement, in nine shapes from landscape 16:9 to vertical 9:16 for TikTok.

Everything runs on your Mac. No account, no upload, no subscription.

---

## Contents

1. [What it does](#1-what-it-does)
2. [Installation](#2-installation)
3. [Quick start](#3-quick-start)
4. [The window](#4-the-window)
5. [Transcription settings](#5-transcription-settings)
6. [Checking and correcting the lyrics](#6-checking-and-correcting-the-lyrics)
7. [The files](#7-the-files)
8. [Lyric videos](#8-lyric-videos)
9. [Other videos](#9-other-videos)
10. [Tempo detection](#10-tempo-detection)
11. [Tips](#11-tips)
12. [Troubleshooting](#12-troubleshooting)
13. [How it works](#13-how-it-works)
14. [Credits and licences](#14-credits-and-licences)

---

## 1. What it does

| You give it | You get |
|---|---|
| A song (WAV, MP3, FLAC, M4A, AIFF), or a folder of songs | Its lyrics with a time for each line: `.lrc` (karaoke players, VLC), `.srt` (subtitles), `.txt` |
| The same song and one or more pictures | A lyric video: the pictures follow each other in time with the song, the words appear as they are sung |
| A song without vocals | A clip with the pictures and the sound |

It is especially at home with **AI-generated songs** (Suno, Udio, YuE…), whose
lyrics are often unknown or partly invented, and with your own demos.

## 2. Installation

### 2.1 What the app needs

The app itself is one file, `Song2Lyrics Clip.app`. It relies on free tools that do
the heavy lifting:

| Tool | Why | How to install |
|---|---|---|
| **Homebrew** | installs the two tools below | see [brew.sh](https://brew.sh) |
| **ffmpeg** | reads every audio format, writes the videos | `brew install ffmpeg` |
| **whisper.cpp** | listens to the song (speech recognition, accelerated by the Mac's graphics chip) | `brew install whisper.cpp` |
| **Whisper large-v3-turbo model** (1.6 GB) | the "ears": the best quality / speed balance | see below |
| **Python 3 with numpy and Pillow** | draws the video frames, measures the tempo | `/usr/bin/python3 -m pip install --user numpy pillow` |

Download the model once:

```bash
mkdir -p ~/.cache/whisper.cpp
curl -L -o ~/.cache/whisper.cpp/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```

### 2.2 First launch

Download `Song2Lyrics-Clip-0.9-macos-arm64.zip` from the [Releases page](https://github.com/Quick-Eyed-Sky/song2lyrics-clip/releases/latest), unzip it, drag `Song2Lyrics Clip.app` into your Applications folder and double-click it. The
app is not notarised by Apple, so the first time macOS may refuse to open it:
open **System Settings › Privacy & Security** and click **Open Anyway**. You
only do this once ([why, and other ways](macos-security.md)).

To keep it at hand, drag it to the Dock. Closing the window quits the app.

## 3. Quick start

1. Drop a song on the window.
2. A few seconds later, its lyrics appear in the middle, one line per row, each
   with its start time.
3. Press the **space bar** to listen; the line being sung is highlighted.
4. Fix a word if needed, press **⌘S**.
5. Click the green **Show in Finder** button: your `.lrc`, `.srt` and `.txt` are
   there.
6. For a video: in the right column, choose a format, click **Choose
   Pictures…**, select your pictures, then **Make the Video**.

## 4. The window

The window has three columns.

**Left: settings and songs.** The transcription settings (section 5), then the
list of songs you dropped, with their state: waiting, listening, done, failed.
A blue dot marks a song edited but not saved yet. Right-click a song to
transcribe it again, show it in the Finder or remove it from the list (its
files stay where they are). *Clear Finished* empties the list of finished songs.
While songs are being transcribed, a **Stop** button appears at the bottom.

**Middle: the lyrics of the selected song.** Its name, a **Lyrics in …** link to
its folder, the player with the song's **tempo**, then the timed lines.

**Right: post-processing.** The big green **Show in Finder** button, then the
lyrics buttons, the lyric video and its settings, the other videos, and
*Transcribe Again*.

Three ways to give songs: **drop them on the window** (a folder includes its
sub-folders), **drop them on the app's icon** in the Dock or the Finder, or
**⌘O**. Songs are transcribed one after the other, about **5 seconds each** on
an idle Mac. A song transcribed earlier is simply reopened, not transcribed
again.

## 5. Transcription settings

All settings are remembered from one launch to the next.

| Setting | What it does |
|---|---|
| **Language** | *Detect* works for most songs. Choose the language if a song comes back in the wrong one. |
| **Isolate the voice first** | Separates the voice from the instruments before listening (BS-Roformer model, about a minute per song). It helps when the voice is buried under loud instruments; on airy, reverberant voices it is often *worse*. Optional: only available when the separation tool is installed. |
| **Lyrics folder** | *Movies › Lyrics* (default): one folder per song in your Movies folder. *Next to each song*: beside the audio file. *Other folder*: anywhere you like. The song itself is never modified. |
| **Text file** | *With times*: the `.txt` reads `00:20.74  words`, one line each. *Words only*: just the words. The `.lrc` and `.srt` always carry the times. |

## 6. Checking and correcting the lyrics

**About accuracy.** The words are what the speech recogniser *hears*. On clear
singing they are usually right. On AI songs that sing invented syllables, they
are a best guess (other tools guess almost the same thing). **The timing is
reliable**: line starts land within about 0.3 s.

Each line has, from left to right:

| Control | Use |
|---|---|
| **▶** | Play the song from this line |
| **Time** (`01:20.50`) | Type a new start time, then Return |
| **− / +** | Move the line 0.1 s earlier or later |
| **↧** | Set the line's start to the moment playing now: listen, click when the line begins |
| **Words** | Click and type |

Right-click a line to **insert a line below** or **delete** it. While playing,
the list follows the song. **Space** plays and pauses (except while typing),
**⌘←** and **⌘→** jump 5 seconds.

**⌘S** (or *Save Changes*) rewrites the three files. If you quit with unsaved
edits, the app asks first.

**Your corrections are never lost.** If you transcribe an edited song again,
the new transcription goes to separate files (`song.whisper.lrc`, `.srt`,
`.txt`) and your edited files stay as they are.

The right column also has **Copy Lyrics**, **Copy with Times** (LRC style, to
paste anywhere) and **Open in TextEdit** (the `.lrc` is plain text).

## 7. The files

For a song called `Ice.wav`, in `Movies/Lyrics/Ice/`:

| File | Content |
|---|---|
| `Ice.lrc` | `[00:20.74]Again the light of day` — read by VLC, most music players and karaoke apps |
| `Ice.srt` | Subtitles: each line with its start and end, for video editors and QuickTime |
| `Ice.txt` | The lyrics, with or without times |
| `Ice.words.json` | The time of every single word |
| `Ice_lyric_video_16x9.mp4` (or `.mov`) | A lyric video, and its `.txt` with every setting |

## 8. Lyric videos

The **Lyric Video** section of the right column turns the song into a clip,
in three steps:

1. **Choose Pictures…** — one picture, several, or a folder. Nothing starts
   yet: the panel shows how many pictures are chosen (*Clear* to start again).
   A file chosen twice counts once.
2. **Number of videos** — appears when the pictures are drawn at random (*Pick
   at random* or *Shuffle*): several videos in a row, each with its own draw.
   A draw never uses the same picture twice.
3. **Make the Video** (or *Make 3 Videos*) — progress is shown under the button,
   with a **Stop** button.

### 8.1 The settings

| Setting | What it does |
|---|---|
| **Format** (small icons, two rows) | Top row, landscape: 16:9 (YouTube, iMovie), 3:2 (photo cameras), 4:3, 5:4 and square 1:1. Bottom row, portrait: 9:16 (TikTok, Reels, Shorts), 2:3, 3:4, 4:5 (Instagram feed). The short side is always 1080 pixels (16:9 is 1920 × 1080). The crop or black-bar rule is the same for every format. In portrait formats the words sit higher, clear of the apps' buttons. |
| **Crop pictures to fill the frame** | On: each picture is cropped to fill the frame. Off: each picture is shown whole, with black bars (ideal for square pictures in a 16:9 video). |
| **Ken Burns effect** | Each picture slowly zooms (in, then out on the next one) while drifting in a straight line at a steady speed. The slider goes from *Very light* (4 % zoom) to *Pronounced* (25 %). Takes longer to make: about 1 min 40 for a 2-minute song. |
| **Ken Burns › On N % of the pictures** | Only a share of the pictures move (20 % by default), drawn at random; the others stay still. 100 % moves them all. |
| **Crossfades › On N % of the cuts** | A share of the cuts (10 % by default) become a one-second dissolve (shorter between quick pictures); the other cuts stay sharp. |
| **Show the words** | Off: pictures and sound only, to finish the montage in iMovie or another editor with your own titles. |
| **Keep the original sound** | On (default): the song's own sound, untouched. From a WAV the video is a `.mov` (QuickTime, iMovie and Final Cut read it); from an MP3 the MP3 is copied as is. Off: AAC at 320 kb/s in an `.mp4`, smaller and readable everywhere. |
| **Also in MP4** | Shown with *Keep the original sound*. A WAV song makes a `.mov`, which Discord and some sites refuse: this adds an `.mp4` beside it (the same picture, AAC sound). On by default. |
| **Pick at random: N pictures** | Select many pictures (200, say): the app draws N of them at random, a new draw every time. |
| **Shuffle the order** | The pictures come in a random order. Without it, they follow **the order of their file names** (`1-`, `2-` … `10-` comes after `9-`), so you can prepare a sequence by naming the files. |
| **Cut on the beat** | Each change of picture lands on a beat. |

### 8.2 Where the cuts fall

With 3 pictures on a 60-second song, the app aims at 0, 20 and 40 seconds. Then
each cut moves to **the nearest start of a lyric line**, if one is close
enough, and with *Cut on the beat*, onto **the nearest beat**. The result
follows the song: pictures change as a new line begins, on the beat.

Because cuts follow the lyrics, two neighbouring pictures may last a little more
or less than the others. With many pictures (50 on a two-minute song, one every
2 to 3 seconds), the clip becomes a kaleidoscope.

### 8.3 Nothing is left to chance (even chance)

A `.txt` is written next to every video: the format, every setting, the tempo,
the seed of the random draw, and **the start time of each picture**, marked
*KB* when it moves and *fade* when it arrives with a crossfade. You can
always tell how a video was made, and make it again.

### 8.4 Instrumentals

A song with no vocals has no lyrics: the video is made all the same, with the
pictures and the sound, and the cuts fall evenly or on the beat.

## 9. Other videos

| Button | Result |
|---|---|
| **QuickTime Video** | The song over a black picture, with the lyrics as a subtitle track. Handy to check the timing. In QuickTime, turn the subtitles on in *View › Subtitles* if they are hidden; VLC shows them too. |
| **iMovie Green Screen** | White words with a black outline on pure green, the length of the song, without sound. In iMovie, put the song and your pictures or clips in the timeline, drag this video **above** them at 0:00, then *Video Overlay Settings › Green/Blue Screen*: the words float over your footage. |

Unsaved corrections are saved first, so every video shows the right words.

## 10. Tempo detection

Above the lyrics, next to the player, the app shows the song's tempo (for
example **100 BPM**). It is measured from the beats over the whole song in half
a second. Tested on ten generated songs whose tempo was known from their score:
all ten within 2 %, most of them exactly. It is meant for songs with a steady
tempo; it is used by *Cut on the beat*.

## 11. Tips

- **Name your pictures** `01-`, `02-`… to tell a story in order; use *Shuffle*
  and *Pick at random* to be surprised.
- **Square pictures in a 16:9 video**: untick *Crop* to keep them whole.
- **TikTok**: 9:16, words on, Ken Burns light, *Cut on the beat*.
- **Your own titles in iMovie**: untick *Show the words*, then add the
  *iMovie Green Screen* video above it, or your own titles.
- **Wrong language**: choose it in *Language* and use *Transcribe Again*.
- **Words lost under loud instruments**: try *Isolate the voice first*.

## 12. Troubleshooting

| Problem | What to do |
|---|---|
| macOS will not open the app | *System Settings › Privacy & Security › Open Anyway* (once). |
| "The lyrics could not be made" | The message under it says why. Most often a missing tool: check section 2. |
| The words come back in the wrong language | Choose the language, then *Transcribe Again*. |
| The same sentence repeated many times | Should not happen (the app is set against it); if it does, tell us with the song. |
| The sound of a video crackles | Tick *Keep the original sound*. If it still crackles, the crackle is in the song itself (check its level: a song mastered right up to 0 dB can distort). |
| Ken Burns videos take long | They are drawn frame by frame for a smooth movement: about 1 min 40 for a 2-minute song. Without Ken Burns: about 15 seconds. |
| A song does not appear when dropped | Only audio files are taken (WAV, MP3, FLAC, M4A, AIFF, AAC, OGG, CAF). |

## 13. How it works

- **Listening**: [whisper.cpp](https://github.com/ggml-org/whisper.cpp) with the
  *large-v3-turbo* model, on the Mac's graphics chip. Two settings make it work
  on music: no text is carried from one 30-second window to the next (otherwise
  Whisper starts repeating one sentence over the music), and word times come
  from the model's attention (*DTW*), which places line starts within about
  0.3 s. Lines are rebuilt from the word times: a new line after `. ? !`, after
  a pause of 3 seconds, or before 44 characters. Lines such as "Thank you." or
  "[Music]", which Whisper writes when nobody sings, are dropped.
- **Videos**: every frame is drawn with Pillow (sub-pixel smooth movement),
  then encoded by ffmpeg (H.264).
- **Tempo**: an onset envelope (where new sounds start), its autocorrelation for
  a first guess, then a fine search of the beat period and phase that best
  match the whole song.

## 14. Credits and licences

- whisper.cpp — MIT licence, by Georgi Gerganov and contributors.
- Whisper models — MIT licence, by OpenAI.
- ffmpeg — LGPL / GPL, by the FFmpeg developers.
- Pillow (HPND licence) and numpy (BSD licence).
- BS-Roformer vocal separation (optional) — via
  [python-audio-separator](https://github.com/nomadkaraoke/python-audio-separator), MIT licence.

Song2Lyrics Clip © 2026 Jean-Pascal (Quick-Eyed Sky), MIT licence. [← Back to the README](../README.md)
