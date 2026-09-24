# luareader

A small novel reader for `.txt` and `.epub`, written in Lua on LÖVE 11.5.

    ./setup.sh               # once: fetches LÖVE 11.5 into .love/
    ./run.sh                 # library of recent books
    ./run.sh book.epub       # open a book directly

Or drop a file onto the window. The cog (top right, or `s`) opens settings:
reading options, auto-scroll and the reading guide, and key bindings. `?` jumps
straight to the keys.

## Self-contained

Everything lives in this directory:

- `.love/` holds LÖVE 11.5, extracted from the official AppImage. Its bundled SDL2
  only supports X11, so it's renamed to `libSDL2-2.0.so.0.bundled-x11only` and the
  system SDL2 is used instead, which gives native Wayland.
- `.data/` holds everything LÖVE writes. `run.sh` points `HOME` and `XDG_*` there.
  Settings and reading positions are in `.data/share/love/luareader/state.lua`.
- `src/fonts/` has Noto Serif, Noto Sans (SIL OFL) and DejaVu Serif (free license);
  their licenses are next to them.

To launch it from rofi or another app launcher, fix the paths in `luareader.desktop`
if the checkout isn't at `~/src/luareader`, then symlink it:
`ln -s "$PWD/luareader.desktop" ~/.local/share/applications/`.

To remove everything, delete that symlink (if you made one) and this directory.

## Layout

    src/main.lua        app: library, reader, settings, auto-scroll, event-driven loop
    src/lib/ui.lua      small widgets: buttons, steppers, toggles, icons
    src/lib/keys.lua    rebindable actions and default keys
    src/lib/layout.lua  line breaking, justification, mixed italic and bold
    src/lib/epub.lua    EPUB 2/3: container → OPF → spine, TOC from nav/NCX
    src/lib/txt.lua     paragraphs, chapter detection, _italics_, Gutenberg cleanup
    src/lib/images.lua  background image decoding (worker threads) and texture cache
    src/lib/imgsize.lua reads PNG/JPEG/BMP sizes from headers without decoding
    src/lib/zip.lua     minimal zip reader (stored + deflate via love.data)
    src/lib/xml.lua     forgiving XML/XHTML parser
    src/lib/text.lua    UTF-8 checks, Windows-1252 fallback, HTML entities
    src/lib/store.lua   saves settings and positions
