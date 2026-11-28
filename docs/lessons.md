# Lessons

## Rules learned

- Measure a parse's read pattern on real files before tuning I/O: on a 991-file corpus HEIF made
  138 reads for 1,533 bytes inside one 100 KB region, and TIFF 21 reads for 1,155 bytes inside
  44 KB. That is why the reader buffers internally and reports both read counts.
- Don't verify a preview's bytes before reporting it: over MTP it cost two extra round trips per
  RAW file, about 130 s across a 991-item card, to prove what the consumer's decode proves free.
- Don't follow a RAW's SubIFD to classify it: real ARWs keep it just past the first 128 KB, so
  following it costs a transport round trip per file. IFD0 evidence is enough.
- Don't require a preview's declared dimensions: Sony's ARW omits them in exactly the directories
  that carry previews. Order previews by byte length.
- Keep the extraction revision per family: a single global number made every JPEG look stale for
  a HEIF fix, and for a cloud library a re-read is a download.

## Open problems

- WAV `bext` origination dates (MM-050) have no unit test: issue #32.
- Matroska and standalone XMP are not read: issue #33.
