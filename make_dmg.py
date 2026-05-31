#!/usr/bin/env python3
"""
Builds a macOS DMG installer for DropUnzip.
Layout: DropUnzip.app on the left, Applications alias on the right,
        custom dark gradient background with instructions.
"""

import os, subprocess, shutil, struct, zlib, math
from PIL import Image, ImageDraw, ImageFont

# ── Config ────────────────────────────────────────────────────────────────────
APP_NAME      = "DropUnzip"
APP_SRC       = "build/Release/DropUnzip.app"
DMG_OUT       = f"../DropUnzip-Installer.dmg"   # lands on Desktop
DMG_TITLE     = "DropUnzip"
DMG_SIZE      = "80m"
WINDOW_W      = 560
WINDOW_H      = 340
ICON_SIZE     = 100
APP_X, APP_Y  = 150, 170
LINK_X, LINK_Y= 410, 170

WORK_DIR = "/tmp/dropunzip_dmg"
BG_PATH  = f"{WORK_DIR}/bg.png"
DMG_TMP  = "/tmp/dropunzip_rw.dmg"

# ── Brand colours (match the app) ────────────────────────────────────────────
BG_TOP    = (21,  21,  30)
BG_BOT    = (16,  16,  24)
YELLOW    = (255, 220, 120)
PINK      = (255, 160, 180)
BLUE      = (160, 200, 240)
WHITE     = (255, 255, 255)

def run(cmd, **kw):
    print(" $", " ".join(cmd) if isinstance(cmd, list) else cmd)
    result = subprocess.run(cmd, shell=isinstance(cmd, str), check=True, **kw)
    return result

def make_background():
    """Render the DMG window background image."""
    W, H = WINDOW_W * 2, WINDOW_H * 2   # @2x
    img = Image.new("RGB", (W, H))
    d   = ImageDraw.Draw(img)

    # Gradient background
    for y in range(H):
        t = y / H
        r = int(BG_TOP[0] + (BG_BOT[0] - BG_TOP[0]) * t)
        g = int(BG_TOP[1] + (BG_BOT[1] - BG_TOP[1]) * t)
        b = int(BG_TOP[2] + (BG_BOT[2] - BG_TOP[2]) * t)
        d.line([(0, y), (W, y)], fill=(r, g, b))

    # Subtle grid dots
    for gx in range(0, W, 40):
        for gy in range(0, H, 40):
            d.ellipse([gx-1, gy-1, gx+1, gy+1], fill=(255, 255, 255, 20))

    # Arrow between icons
    ax0, ay = (APP_X + 70) * 2, APP_Y * 2
    ax1     = (LINK_X - 70) * 2
    d.line([(ax0, ay), (ax1, ay)], fill=(*YELLOW, 180), width=3)
    # Arrowhead
    d.polygon([(ax1, ay), (ax1-16, ay-8), (ax1-16, ay+8)], fill=(*YELLOW, 200))

    # Label under app icon position
    try:
        font_lg = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 28)
        font_sm = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 22)
    except Exception:
        font_lg = ImageFont.load_default()
        font_sm = font_lg

    # "Drag to install" instruction
    msg = "Drag DropUnzip to Applications to install"
    bbox = d.textbbox((0, 0), msg, font=font_sm)
    tw = bbox[2] - bbox[0]
    d.text(((W - tw) // 2, H - 80), msg,
           fill=(255, 255, 255, 100), font=font_sm)

    # Version tag
    ver = "Version 1.0"
    bbox2 = d.textbbox((0, 0), ver, font=font_sm)
    tw2 = bbox2[2] - bbox2[0]
    d.text(((W - tw2) // 2, H - 52), ver,
           fill=(255, 255, 255, 50), font=font_sm)

    # Coloured accent line at top
    d.rectangle([0, 0, W, 6], fill=(*YELLOW, 255))
    d.rectangle([0, 0, W//3, 6], fill=(*PINK, 255))
    d.rectangle([W//3, 0, 2*W//3, 6], fill=(*YELLOW, 255))
    d.rectangle([2*W//3, 0, W, 6], fill=(*BLUE, 255))

    img.save(BG_PATH, "PNG")
    print(f"  Background saved → {BG_PATH}")

def build_dmg():
    # Clean up
    shutil.rmtree(WORK_DIR, ignore_errors=True)
    os.makedirs(WORK_DIR)
    if os.path.exists(DMG_TMP): os.remove(DMG_TMP)

    # Make background
    make_background()

    # Create a staging folder
    stage = f"{WORK_DIR}/stage"
    os.makedirs(stage)

    # Copy app
    shutil.copytree(APP_SRC, f"{stage}/{APP_NAME}.app", symlinks=True)

    # Applications symlink
    os.symlink("/Applications", f"{stage}/Applications")

    # Hidden background folder
    bg_dir = f"{stage}/.background"
    os.makedirs(bg_dir)
    shutil.copy(BG_PATH, f"{bg_dir}/bg.png")

    # Create writable DMG
    run(["hdiutil", "create",
         "-srcfolder", stage,
         "-volname", DMG_TITLE,
         "-fs", "HFS+",
         "-fsargs", "-c c=64,a=16,b=16",
         "-format", "UDRW",
         "-size", DMG_SIZE,
         DMG_TMP])

    # Mount it
    result = subprocess.run(
        ["hdiutil", "attach", "-readwrite", "-noverify", "-noautoopen", DMG_TMP],
        capture_output=True, text=True, check=True
    )
    # Find mount point
    mount_point = None
    for line in result.stdout.splitlines():
        if "/Volumes/" in line:
            mount_point = line.split("\t")[-1].strip()
    assert mount_point, "Could not find mount point"
    print(f"  Mounted at: {mount_point}")

    # AppleScript to set window appearance
    applescript = f"""
tell application "Finder"
    tell disk "{DMG_TITLE}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {{100, 100, {100 + WINDOW_W}, {100 + WINDOW_H}}}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to {ICON_SIZE}
        set background picture of viewOptions to file ".background:bg.png"
        set position of item "{APP_NAME}.app" of container window to {{{APP_X}, {APP_Y}}}
        set position of item "Applications" of container window to {{{LINK_X}, {LINK_Y}}}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
"""
    subprocess.run(["osascript", "-e", applescript], check=False)

    # Set volume icon (use the app icon)
    app_icon_src = f"{mount_point}/{APP_NAME}.app/Contents/Resources/AppIcon.icns"
    vol_icon_dst = f"{mount_point}/.VolumeIcon.icns"
    if os.path.exists(app_icon_src):
        shutil.copy(app_icon_src, vol_icon_dst)
        subprocess.run(["SetFile", "-a", "C", mount_point], check=False)  # optional

    # Sync and unmount
    run(["sync"])
    run(["hdiutil", "detach", mount_point])

    # Convert to compressed read-only DMG
    if os.path.exists(DMG_OUT):
        os.remove(DMG_OUT)
    run(["hdiutil", "convert", DMG_TMP,
         "-format", "UDZO",
         "-imagekey", "zlib-level=9",
         "-o", DMG_OUT])

    os.remove(DMG_TMP)
    shutil.rmtree(WORK_DIR)

    size_mb = os.path.getsize(DMG_OUT) / 1_048_576
    print(f"\n✅  DMG ready: {os.path.abspath(DMG_OUT)}  ({size_mb:.1f} MB)")

if __name__ == "__main__":
    build_dmg()
