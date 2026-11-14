# Gibb

A cosy home for [KOReader](https://github.com/koreader/koreader): a dashboard,
book pages with ratings and reviews, a library, your highlights, and a cleaner
set of in-book menus. Made for e-ink, in black and white, with nothing running
in the background.

> **Early version.** Gibb has only been tried on one Kindle so far. Expect rough
> edges, and please open an issue when you find one.

<!-- Add screenshots here once you have them, for example:
![Dashboard](screenshots/home.png)
KOReader takes a screenshot when you swipe diagonally across the screen;
the files land in koreader/screenshots/. -->

## What it does

**Dashboard**, four pages you swipe between:

- **Home**: a greeting, a Continue reading card for your last book, the books
  you're reading, a highlight picked from across your books each day, the moon
  phase, today's pages against your daily goal, and tiles for other plugins.
- **Shelf**: how many books you're reading, have finished or put on hold, a
  strip of recently added books, the authors on your shelf, and your genres.
- **Notes**: your ratings and reviews.
- **Stats**: pages per day this week, all-time totals, streaks, and a yearly
  book goal.

**Book pages**: every book gets a page with its cover, status, star rating,
your review, progress, reading time, and description.

**Rate and review**: when you reach the end of a book, Gibb asks for a rating
out of five and an optional written review.

**Library**: your books as a cover grid or a list, with search, status
filters, sorting, and views narrowed to one author or genre.

**Highlights**: every highlight from every book in one list. Tap one to read
it in full or jump to it in the book.

**In a book**:

- **Reader menu**: tap the bottom of the page for progress, eight shortcuts,
  and the other books you're reading.
- **Quick panel**: swipe down from the top for Wi-Fi, airplane mode, night
  mode, rotation, brightness, warmth, sleep, restart and exit. Switches are
  circles (filled when on), one-shot actions are squares.
- **Header and footer**: small stats in the page margins. Six slots, each
  showing what you choose: progress, page, time left, chapter, clock, battery
  and more, plus a progress line with chapter marks.
- **Auto-highlight**: select a long passage and it is saved as a highlight
  straight away, with a small bar to add a note, restyle, copy or undo.

**Customisable**: show, hide and reorder every dashboard card, set your name
and goals, choose the app tiles, and switch each in-book feature on or off.

## Install

1. Download this repository (Code, then Download ZIP) and unzip it.
2. Make sure the folder is named exactly `gibb.koplugin`. GitHub's ZIP adds
   `-main` to the name, and KOReader ignores folders that don't end in
   `.koplugin`.
3. Copy the folder into `koreader/plugins/` on your device.
4. Restart KOReader.
5. Open the top menu, the tools icon, then **Gibb**.

Check that `koreader/plugins/gibb.koplugin/main.lua` exists, with no second
`gibb.koplugin` folder nested inside.

## Updating

If you use the [Storefront](https://github.com/ultimatejimmy/storefront.koplugin)
plugin, Gibb can be updated from the device:

1. Turn Wi-Fi on.
2. Open the tools menu, **Gibb**, **Get updates through Storefront**.
3. Storefront confirms the link and from then on lists Gibb with your other
   installed plugins and offers new releases.

Without Storefront, download the newest release, replace the
`gibb.koplugin` folder, and restart KOReader. Your settings are kept.

## Requirements

Turn these KOReader plugins on (they ship with KOReader):

| Plugin | Used for |
|---|---|
| Reading statistics | Reading time, pages, streaks, time-left estimates |
| Cover browser | Book covers |
| Gestures | Opening Gibb with a tap or swipe |

Optional. Each one only powers its own tile on the Home page, and you can hide
any tile in the settings:

| Plugin | Folder name Gibb looks for |
|---|---|
| Z-library | `zlibrary.koplugin` |
| AO3 Downloader | `AO3Downloader.koplugin` |
| Storefront | `storefront.koplugin` |
| Crossword | `crossword.koplugin` |

## Other home-screen plugins

Gibb replaces the same menus and pop-ups as **Aleph** (and likely Zen UI and
Simple UI), so only one should be on at a time.

While Aleph is on, Gibb pauses its reader menu, quick panel, header and footer,
and auto-highlight so nothing is drawn twice. The dashboard, library, book
pages and highlights list work either way. To switch over, open **Gibb** in the
tools menu and tap **Turn Aleph off**. Nothing of Aleph's is deleted, and you
can turn it back on in Plugin management.

## Using it

| To | Do this |
|---|---|
| Open the dashboard | Tools menu, **Gibb**, **Open dashboard**. It also opens when KOReader starts, unless you turn that off |
| Change dashboard page | Swipe left or right, or tap the arrows |
| Open the quick panel | Tap the top of the screen, or swipe down from the top edge |
| Open the reader menu | Tap the bottom of a page |
| Reach KOReader's text settings | Swipe up from the bottom, or **Text style** in the reader menu |
| Reach KOReader's full menu | **More** in the quick panel |
| Carry on with your last book | Tap the **Continue reading** card on the Home page |
| See a book's page | Tap a book on the dashboard or in the library |
| Open a book directly | Hold a book on the dashboard or in the library |

### Gestures

Gibb adds these actions to KOReader's gesture manager (top menu, gear icon,
**Taps and gestures**, **Gesture manager**):

- Gibb: open dashboard
- Gibb: library
- Gibb: all highlights
- Gibb: quick panel
- Gibb: this book's page
- Gibb: reader menu

## Settings

Tools menu, **Gibb**:

- **Dashboard settings**: your name, show or hide cards, arrange cards, books
  shown on Home, daily page goal, yearly book goal, app tiles, how often the
  highlight quote changes, the cat theme (paws, whiskers and fish in place of
  the ♥ ✿ ★ symbols), and opening at startup.
- **In-book settings**: reader menu, quick panel, auto-highlight and how many
  words count as long, the finish prompt, header and footer.
- **Rescan library folder**: run this after adding books.

The library reads KOReader's home folder, including subfolders. To use a
different folder, open the library, tap **Sort**, then **Choose library
folder**.

## Your data

Gibb does not keep its own copy of your reading data. Ratings, reviews, book
status, progress and highlights are stored by KOReader in each book's own
settings, so they stay with you if you remove Gibb, and they show up in
KOReader's Book status screen too.

Gibb itself saves two things:

- `settings/gibb_index.lua`: a list of your books, so folders are not walked
  every time. Safe to delete; it is rebuilt.
- a `gibb` entry in KOReader's settings file: your preferences.

It reads KOReader's `statistics.sqlite3` and never writes to it.

## Battery and privacy

- Nothing runs in the background, and there are no repeating timers. Screens
  read their data when they open.
- The header and footer redraw only when the page does, so the clock shows the
  time of your last page turn.
- Gibb never goes online. Only the optional Z-library, AO3 and Storefront
  plugins do, when you open them.
- Airplane mode turns Wi-Fi off and asks KOReader not to switch it back on by
  itself. Other plugins may not respect that.

## Troubleshooting

- **A tile says it could not find a plugin**: check that plugin is turned on in
  Plugin management and that its folder has the name in the table above.
- **Two footers, or two menus opening**: another home-screen plugin is on. See
  "Other home-screen plugins".
- **No covers**: covers come from the Cover browser plugin's cache. Browse to
  the book in KOReader's file browser once and its cover will appear.
- **No stats**: turn on Reading statistics and read a few pages.
- **Genres are empty**: genres come from the tags inside each book file.
- **Something crashed**: look in `koreader/crash.log` for lines mentioning
  `gibb` and include them in your issue, along with your device and KOReader
  version. Check the log for private file paths before sharing it.

## Files

| File | What it holds |
|---|---|
| `main.lua` | Plugin entry point, settings menu, gestures, app tiles |
| `gibb_ui.lua` | Shared drawing: cards, buttons, icons, the moon, page and pop-up bases |
| `gibb_data.lua` | Reading books, the library index, statistics, highlights |
| `gibb_views.lua` | Dashboard, book page, library, highlights, rating pop-up |
| `gibb_reader.lua` | Reader menu, quick panel, header and footer, auto-highlight |
| `icons/` | Gibb's own line icons, each in black and in white |

## Licence

Copyright (C) 2026 yasmin-tazi

Gibb is free software under the GNU Affero General Public License, version 3,
the same licence as KOReader. See [LICENSE](LICENSE). It comes with no
warranty.

Gibb is not affiliated with KOReader, Aleph, or any of the plugins it can open.
