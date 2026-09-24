#!/bin/sh
# Launch luareader. Everything LÖVE writes (saves, config, shader caches)
# is redirected into ./.data so nothing leaks into the real home directory.
#
#   ./run.sh [book.epub|book.txt]

here=$(cd "$(dirname "$0")" && pwd)
realhome=$HOME

# Resolve book paths before HOME changes, so relative paths still work.
for f do
	shift
	[ -e "$f" ] && f=$(realpath "$f")
	set -- "$@" "$f"
done

export HOME="$here/.data"
export XDG_DATA_HOME="$HOME/share"
export XDG_CONFIG_HOME="$HOME/config"
export XDG_CACHE_HOME="$HOME/cache"
export XDG_STATE_HOME="$HOME/state"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME"

# Still read (never write) the user's cursor theme.
export XCURSOR_PATH="${XCURSOR_PATH:-$realhome/.icons:$realhome/.local/share/icons:/usr/share/icons}"
[ -n "$WAYLAND_DISPLAY" ] && export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-wayland}"

exec "$here/.love/squashfs-root/AppRun" "$here/src" "$@"
