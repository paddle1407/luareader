#!/bin/sh
# Generates luareader.desktop for wherever this checkout lives. Desktop entries
# need absolute paths, so the file in git is a template (luareader.desktop.in)
# and the generated one stays local (it's in .gitignore).
#
#   ./desktop.sh           write ./luareader.desktop
#   ./desktop.sh --link    also symlink it into ~/.local/share/applications,
#                          so app launchers like rofi can find it
set -e

here=$(cd "$(dirname "$0")" && pwd)

# Paths with spaces are valid in desktop entries but have to be quoted in Exec.
case "$here" in
*" "*) execpath="\"$here/run.sh\"" ;;
*) execpath="$here/run.sh" ;;
esac

sed -e "s|^Exec=@DIR@/run.sh|Exec=$execpath|" -e "s|@DIR@|$here|g" \
	"$here/luareader.desktop.in" > "$here/luareader.desktop"
echo "Wrote $here/luareader.desktop"

if [ "$1" = "--link" ]; then
	apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
	mkdir -p "$apps"
	ln -sfn "$here/luareader.desktop" "$apps/luareader.desktop"
	echo "Linked $apps/luareader.desktop"
fi
