# Sofian kuvat AVI fixtures

- Source: user-owned family photos under
  `~/Desktop/OneDrive/Perheen kuvat/Sofian kuvat/`
- Device / format: Motion-JPEG AVI (RIFF), 1440×1080, 30 fps, PCM audio
- Rights: user-owned; redistributed here only as a header-only extract with no
  video or audio sample payloads (no JPEG frames)
- Privacy review: the committed bytes are the AVI `LIST.hdrl` tree only
  (`avih`, `strl`/`strh`/`strf`/`indx`, `odml`/`dmlh`). No image content,
  GPS, names, or other personal metadata tags are present.
- Intended coverage: AVI main-header / stream-header duration, frame rate,
  Motion-JPEG codec (`MJPG`), and pixel dimensions

| Fixture | Origin file | Notes |
|---|---|---|
| `avi-mjpg-hdrl-duration.avi` | `2026/05/20260514_195430.avi` | Header-only rebuild of the source `hdrl` (≈11 KiB). Source disk copy was a truncated OneDrive stub; `hdrl` was intact and matches other clips from the same camera. |
