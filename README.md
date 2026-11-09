# BugOS

A Windows 11-style taskbar, File Explorer and screenshot tool for your Mac, in one app.

- **Taskbar**: app buttons with live window previews (with play, pause and skip under Spotify and Music), Aero Peek, what's playing, and All apps. Size, alignment, background, colour, shape, all yours. Hides for full-screen apps and Mission Control.
- **Quick Corner and Quick Access**: point at the bottom-right corner for a fan of shortcuts, or swipe two fingers in from the right edge of the trackpad (or press your own shortcut) for Quick Access. Each has its own list: apps, files, folders, your music app, browser, AI app, and Recent to flip between your last two apps.
- **File Explorer**: tabs, breadcrumbs, Quick access, Details and icon views, and Save/Open dialogs from other apps. Folders open in it instead of Finder. Windows 11, Mica or Liquid Glass themes.
- **Squiggle**: snip an area, a window or the screen (frozen the instant you press the key, menus and all), draw on it, or record the screen. Every shortcut can be changed.

Turn any of the three off in BugOS › Features.

Needs a Mac with Apple silicon on macOS 15 Sequoia or newer.

## Install

1. Download **BugOS.dmg** from the [latest release](https://github.com/Haydebug/BugOS/releases/latest).
2. Drag BugOS onto Applications and open it.
3. macOS says it can't check BugOS for malicious software (it isn't from the App Store). Click **Done**, open **System Settings › Privacy & Security**, scroll down and click **Open Anyway** next to BugOS, then open it again.
4. The BugOS page opens at Permissions. Click **Turn On…** next to each one.

BugOS checks for new versions once a day (General › Updates) and installs them for you. Your settings and permissions stay.

## Uninstall

BugOS › General › Uninstall puts your Mac back how it was: Dock, hot corner, Finder for folders, no login item, no permission entries.

## Building

```bash
./build.sh install        # build and install on this Mac
./build.sh dmg            # dist/BugOS.dmg
./build.sh release 1.2.0  # publish a version (notes in release-notes/1.2.0.md)
```

Builds are signed with a local code-signing certificate named "BugDock Local Signing" (or `SIGN_ID=<identity>`). Updates are only installed when they're signed with the same certificate as the copy that's running.

Every commit, push and release runs `tools/privacy-check.py`, which refuses anything personal (home-folder paths, email addresses, private IPs, keys, and your own list in `~/.config/bugos/private-patterns`). Turn the git hooks on once with `git config core.hooksPath .githooks`.
