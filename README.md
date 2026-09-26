# luareader

A small novel and comic reader for `.txt`, `.epub` and `.cbz`, written in Lua on LÖVE 11.5.

    ./setup.sh               # once: fetches LÖVE 11.5 into .love/
    ./run.sh                 # library of recent books
    ./run.sh book.epub       # open a book (or comic) directly

Or drop a file onto the window. The cog (top right, or `s`) opens settings:
reading options, auto-scroll and the reading guide, and key bindings. `?` jumps
straight to the keys.

Mouse wheel and trackpad scrolling move through text smoothly, including partial
wheel steps. In Reading settings, **Text view → Book pages** switches TXT and EPUB
books to one page at a time. Wheel, arrow keys, page keys, and clicks turn whole
pages without vertical scrolling. The footer shows the current page and total;
the page count adapts when the window or text layout changes. Scroll view remains
the default and is used for auto-scroll.

Drop a `.ttf` or `.otf` font file onto the window to import it. Imported fonts
appear in Reading settings and are stored in `.data/share/love/luareader/customfonts/`.
A single imported font file is used for regular, italic, and bold text.

If the window looks wrong (content cut off or squeezed into a corner), run
`LUAREADER_DEBUG=1 ./run.sh` from a terminal: it prints the window sizes the
app sees, which helps track down display-scaling issues.

## Self-contained

Everything lives in this directory:

- `.love/` holds LÖVE 11.5, extracted from the official AppImage. Its bundled SDL2
  only supports X11, so it's renamed to `libSDL2-2.0.so.0.bundled-x11only` and the
  system SDL2 is used instead, which gives native Wayland.
- `.data/` holds everything LÖVE writes. `run.sh` points `HOME` and `XDG_*` there.
  Settings and reading positions are in `.data/share/love/luareader/state.lua`.
- `src/fonts/` has Noto Serif, Noto Sans (SIL OFL) and DejaVu Serif (free license);
  their licenses are next to them.

To launch it from rofi or another app launcher, run `./desktop.sh --link`. Desktop
entries need absolute paths, so git only has a template (`luareader.desktop.in`);
the script writes `luareader.desktop` for wherever this checkout lives and
symlinks it into `~/.local/share/applications/`. Run it again if you move the folder.

To remove everything, delete that symlink (if you made one) and this directory.

## Layout

    src/main.lua        app: library, reader, settings, auto-scroll, event-driven loop
    src/comic.lua       comic view: fitted pages, spreads, right-to-left, zoom, prefetch
    src/lib/ui.lua      small widgets: buttons, steppers, toggles, icons
    src/lib/keys.lua    rebindable actions and default keys
    src/lib/layout.lua  line breaking, justification, mixed italic and bold
    src/lib/epub.lua    EPUB 2/3: container → OPF → spine, TOC from nav/NCX
    src/lib/cbz.lua     CBZ comics: natural page order, folders as chapters, ComicInfo.xml
    src/lib/txt.lua     paragraphs, chapter detection, _italics_, Gutenberg cleanup
    src/lib/images.lua  background image decoding (worker threads) and texture cache
    src/lib/imgsize.lua reads PNG/JPEG/BMP sizes from headers without decoding
    src/lib/zip.lua     minimal zip reader (stored + deflate via love.data)
    src/lib/xml.lua     forgiving XML/XHTML parser
    src/lib/text.lua    UTF-8 checks, Windows-1252 fallback, HTML entities
    src/lib/store.lua   saves settings and positions
