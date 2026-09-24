#!/bin/sh
# Fetches LÖVE 11.5 into ./.love (nothing is installed system-wide).
# Needs curl, and an x86_64 glibc system with SDL2 installed.
set -e

here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

if [ -x .love/squashfs-root/AppRun ]; then
	echo "LÖVE is already set up in .love/"
	exit 0
fi

mkdir -p .love
cd .love
curl -fSL -o love.AppImage https://github.com/love2d/love/releases/download/11.5/love-11.5-x86_64.AppImage
chmod +x love.AppImage
# Extracting avoids needing FUSE to run the AppImage.
./love.AppImage --appimage-extract >/dev/null
rm love.AppImage

# The bundled SDL2 only supports X11; set it aside so the system SDL2
# (with native Wayland) is used instead.
mv squashfs-root/lib/libSDL2-2.0.so.0 squashfs-root/lib/libSDL2-2.0.so.0.bundled-x11only

echo "Done. Start luareader with ./run.sh"
