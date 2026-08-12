# XPointer external annotation overlay prototype

This implementation uses a plugin-owned annotation layer for reflowable
CREngine documents and synchronizes WeRead underlines and thoughts without
modifying the source book or KOReader notes.

## What it proves

- An underline can be projected from a saved XPointer range without changing
  the EPUB.
- The underline is painted through KOReader's supported
  `ReaderView:registerViewModule()` extension point, in the same paint pass as
  the page.
- Tap hit boxes remain separate from KOReader annotations and open the existing
  native WeRead thought popup.
- Page-mode projections are cached and invalidated by ReaderView layout resets
  or `DocumentRerendered`.

Each local book has an isolated SQLite database under
`<KOReader data>/weread/external-annotations/`. Records are not added to
`ui.annotation.annotations` and are not written to the book's `.sdr`
annotation list.

Synchronization checkpoints are stored in that same per-book database. Review
requests run one small batch per UI step; each completed batch is committed
independently, so cancellation normally waits only for the active network
request and resumes at the next batch. KOReader's standby guard is held for the
whole operation and released on success, cancellation, or failure.

## Manual test

1. Open a local EPUB or another reflowable CREngine document.
2. Open `Tools → WeRead → Local-book underlines and thoughts`.
3. Match the local book to its WeRead title and synchronize.
4. Close the menu. Synchronized ranges should have an underline.
5. Tap the underline outside the configured left/right page-turn edge. The
   normal WeRead thought popup should open.
6. Change font size, line spacing, margins and orientation. The underline
   should follow the same text after the document is rerendered.
7. Toggle `Show underlines and thoughts` in the main WeRead menu and verify it
   controls both downloaded WeRead books and local-book overlays.
8. Select `Clear data` and verify the source
   book and KOReader note list are unchanged.

## Prototype limits

- Only reflowable CREngine documents are supported. Fixed-layout PDF/DjVu
  coordinates are deliberately out of scope.
- Records are keyed by the current file path. Moving or replacing a book
  requires matching it again.
- Quote matching can miss ranges when the local edition differs from the
  WeRead edition.

## Performance gate for further work

Do not connect full-book WeRead sync until low-memory device testing confirms:

- no second e-ink refresh is caused by the overlay;
- a normal page with a handful of marks adds no perceptible page-turn latency;
- rapid page turns do not queue projection work;
- scroll mode remains responsive;
- layout changes invalidate stale screen rectangles correctly.
