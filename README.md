# Into

A small macOS menu-bar file converter. Drop a file onto the icon, pick or type a format, press Return. The result is saved next to the original and copied to the clipboard.

Images, PDFs, video, audio and text documents. Images and videos can be resized and compressed, with a size preview.

## Install

Requires Xcode command-line tools and [Homebrew](https://brew.sh).

```sh
brew install ffmpeg
git clone https://github.com/iSach/into.git
cd into
make install
open /Applications/Into.app
```

`make test` converts sample files through every format. MIT licensed.
