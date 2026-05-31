# DropUnzip

A native macOS drag-and-drop app for extracting and compressing files.

![macOS](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/license-MIT-green)

## Features

- **Drop an archive** → extracts it automatically next to the original file
- **Drop any file or folder** → prompts you to choose a compression format
- Real **progress bar** with per-file tracking
- Supports: `.zip` · `.tar` · `.tar.gz` · `.tar.bz2` · `.tar.xz` · `.7z` · `.rar` · `.gz` · `.bz2` · `.xz`
- RAR falls back to **The Unarchiver** if installed (no Homebrew needed)
- Dark themed UI with brand colours

## Compression formats

| Format | Tool | Notes |
|--------|------|-------|
| `.zip` | `/usr/bin/zip` | Best compatibility |
| `.tar.gz` | `/usr/bin/tar` | Fast, good compression |
| `.tar.bz2` | `/usr/bin/tar` | Smaller, slower |
| `.tar.xz` | `/usr/bin/tar` | Best compression ratio |

## Requirements

- macOS 13 Ventura or later
- Xcode 15+ (to build from source)

## Build

```bash
git clone https://github.com/dhd822/DropUnzip.git
cd DropUnzip
open DropUnzip.xcodeproj
```

Press **⌘R** in Xcode to build and run.

Or build from the command line:

```bash
xcodebuild -project DropUnzip.xcodeproj -scheme DropUnzip -configuration Release build
```

## Install

Download the latest `DropUnzip-Installer.dmg` from [Releases](../../releases), open it, and drag **DropUnzip.app** to your Applications folder.

## Optional tools

- **RAR extraction without a GUI app**: `brew install unar`
- **7z support**: `brew install p7zip`
- **xz support**: `brew install xz`

## License

MIT
