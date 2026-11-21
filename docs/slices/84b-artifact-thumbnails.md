# 84b — Artifact thumbnails

Specced 2026-11-19 from [84](84-the-windows-structure.md)'s fork 4, after a rough
version in its spike.

**Problem.** An artifact's row in the sidebar shows its media type's symbol, which
says little when most artifacts are scans. A thumbnail of the scan says which one it is.

**Layer.** App, and the engine's browse summary. Not a format change: the index is a
rebuildable cache.

## What the spike settled

- **Drawn in-process**, as the preview pane is: ImageIO for images (it downsamples a
  large scan without decoding all of it, and uses an embedded thumbnail when there is
  one), Core Graphics for a PDF's first page. Not Quick Look, whose generators fail or
  stall in the sandbox (`FilePreviewContent`). Anything else keeps its symbol.
- **Never a file that isn't on this Mac.** Reading a dataless file downloads it (57b),
  so scrolling the sidebar of a synced archive would download every scan. Such a file,
  or a missing or damaged one, keeps the symbol.
- **Which file:** the first image or PDF, an access copy before a preservation master
  (smaller, and the master is the file most likely to be left in iCloud), then a
  derivative.
- **The whole page, scaled to fit** a square, not cropped (agreed 2026-11-19).
- **Lazily, per visible row**, the symbol showing until the thumbnail arrives, and
  cached in memory.

## Design forks (agreed 2026-11-21)

1. **How the row learns its file.** The spike decoded each visible artifact's record.
   **Agreed:** the browse summary carries the chosen file's path, from the index,
   so a row reads nothing it doesn't draw. *Built without the index schema change this
   expected: the summary is already made from the record the index holds.*
2. **A disk cache.** **Agreed: none, until measured.** If needed, the app's own
   Caches folder keyed by the file's checksum, never inside the archive.

## Out of scope

Thumbnails anywhere else (the Review rows, a person's sources): the same loader can
serve them later.

## Verification

Engine tests for the summary's chosen file (role order, no drawable file, after a
replace). On both platforms, since the summary is the engine's. **Hand-test** on the
real archive, read-only: scrolling a long list stays smooth; a synced archive with files
left in iCloud downloads nothing; a missing file keeps its symbol.
