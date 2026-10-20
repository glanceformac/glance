# Glance for Mac

Glance puts a small black island at the top of your Mac's screen. You glance up and everything is there.

Hover over it and it opens into a panel with your music, weather, calendar, a focus timer, a clipboard history and a Shelf for files. Small peeks drop down for charging, timers and Claude Code. It is free and open source.

<!-- Demo GIF or video goes here, for example: ![Glance demo](docs/demo.gif) -->
*Demo GIF coming soon.*

## What it does

- **Now Playing** with artwork, controls, synced lyrics and a visualiser in the pill.
- **Cinema mode**: while a video plays in Chrome, the glow around the island takes the colours of the picture, like LED strips behind a TV. It can also light the Touch Bar.
- **Teleprompter** that sits under the camera and can follow your voice. Recognition runs on your Mac.
- **Football mode**: pick a team and get live scores in the pill, a Home card and a goal celebration.
- **Claude Code**: approve or deny Claude Code permission requests from the island, and see when a task is done.
- Clipboard history, a Shelf for files, a command palette, Keep Mac awake, a webcam mirror, system stats and more.

Everything is listed in the [feature guide](docs/FEATURES.md).

## Install

Glance needs macOS 14 (Sonoma) or later.

### With the install script

```sh
curl -fsSL https://raw.githubusercontent.com/glanceformac/glance/main/Scripts/install.sh | bash
```

The script downloads the latest release, checks its SHA-256 checksum and copies Glance to /Applications. It also sets up the Chrome connection for Cinema mode, then opens Glance. Read the script first if you like: it is short.

To uninstall, run it with `--uninstall`. Your settings stay unless you delete them.

```sh
curl -fsSL https://raw.githubusercontent.com/glanceformac/glance/main/Scripts/install.sh | bash -s -- --uninstall
```

### With Homebrew

```sh
brew install --cask glanceformac/tap/glance
```

### Why there is no notarisation

Glance is built without a paid Apple Developer account. So it is signed ad hoc and not notarised by Apple. The install script and the Homebrew cask remove the download quarantine flag from Glance.app only, so macOS opens it. If you download the zip by hand, right-click Glance.app and choose Open the first time, or run:

```sh
xattr -dr com.apple.quarantine /Applications/Glance.app
```

## Build from source

You need the Xcode Command Line Tools with Swift 6 (`xcode-select --install`). Full Xcode is not needed.

```sh
git clone https://github.com/glanceformac/glance.git
cd glance
./build.sh            # builds build/Glance.app for Apple silicon and Intel
./build.sh install    # also replaces /Applications/Glance.app and opens it
```

`ARCH=arm64 ./build.sh` builds for Apple silicon only, which is faster. `Scripts/package-release.sh 1.0.0` makes the release zip and checksum in `dist/`, signs the zip for in-app updates and adds it to `dist/appcast.xml`.

### Updates

From version 1.1, Glance updates itself with [Sparkle](https://sparkle-project.org): once a day it checks `https://glanceformac.vercel.app/appcast.xml`, and Settings and the menu bar icon have **Check for Updates…**. You can turn the daily check off in Settings › Updates. Every update is signed with an EdDSA key, and Glance refuses a download whose signature does not match the public key built into the app.

## Cinema mode (Chrome extension)

Cinema mode needs a small Chrome extension. It sends only colour numbers, sound levels and play state to Glance on your Mac. It sends no images, no page content and nothing to the internet.

1. Install Glance. The install script, the Homebrew cask and `./build.sh install` all copy the extension to `~/Library/Application Support/Glance/Chrome Extension` and connect it to Glance.
   If you copied Glance.app by hand, run `/Applications/Glance.app/Contents/Resources/install-chrome-host.sh` once.
2. Open `chrome://extensions` and turn on **Developer mode** (top right).
3. Click **Load unpacked**. Press Cmd+Shift+G, paste the folder path above and choose **Select**.
4. Play a video. If the extension popup says Glance is not reachable, restart Chrome once.

Chrome gives the extension an ID based on that folder, and the setup script allows exactly that ID. If you load the extension from another folder, run the setup script again with `--extension-id <the id Chrome shows>`.

Chromium, Brave, Edge and Vivaldi work the same way if they are installed.

## Claude Code hooks

Glance can show Claude Code permission requests with Allow and Deny buttons, and a Done peek when a turn ends. Glance never edits your Claude Code settings. You add the hooks yourself.

1. Open [INSTALL-HOOKS.md](INSTALL-HOOKS.md) and copy the JSON.
2. Merge it into `~/.claude/settings.json`. If the file already has a `"hooks"` key, add these events to it.
3. The hooks call `/Applications/Glance.app/Contents/MacOS/glance-hook`. Change the path if Glance lives somewhere else.

Glance never allows anything on its own. If you do not answer within about a minute, or Glance is not running, Claude Code asks in the terminal as usual.

## Permissions it asks for

Glance asks only when a feature needs it, and each prompt says why.

| Permission | When | Why |
|---|---|---|
| Location | First launch | Local weather. You can type a city instead. |
| Calendars | First launch | Your next event on the Calendar card. |
| Reminders | When you open Reminders in Tools | Show and tick your reminders. |
| Automation (System Events, Spotify, Music) | First theme switch, or if media control falls back | Switch Light and Dark mode, and control music. |
| Camera | When you open the Mirror | A live mirror. Nothing is recorded. |
| Microphone and Speech Recognition | When you turn on Voice follow in the Teleprompter | Follow your voice. It runs on your Mac only. |
| Accessibility | Only for optional features (paste into the front app, window snap zones, Knock, Clean keyboard) | Read modifier keys or move windows. |
| Input Monitoring | Only for optional Caps Lock peeks and activity rings | Count key presses. It never records which keys. |
| Login Items | If you turn on Launch at login or the Touch Bar button | Start Glance or its Touch Bar helper at login. |

Glance never uses screen capture. GitHub activity and the local git folder watch are off until you turn them on in Settings.

## Private APIs

Some features use macOS frameworks that Apple does not document. They work today but could break in a future macOS update.

- **Touch Bar**: the Control Strip button and the Touch Bar glow use the private DFRFoundation framework and private NSTouchBar methods.
- **Now Playing**: macOS 15.4 and later block apps from the private MediaRemote framework. Glance uses the vendored [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter), which runs it through `/usr/bin/perl`. If it stops working, Glance falls back to Spotify and Music.
- **Brightness**: the private DisplayServices framework. If it is missing, the brightness control hides itself.

Because of these, Glance cannot be on the Mac App Store.

## Football mode data

Scores come from ESPN's public site feed. It is unofficial and undocumented, it is not affiliated with ESPN, and it may change or stop working at any time. Use it for personal use. The data source is pluggable: see `Sources/Island/FootballSource.swift` to add another provider.

Club names and badges belong to their clubs. Glance ships no club badges. They are downloaded when shown and cached on your Mac only.

## Tested hardware

- 13 inch MacBook Pro, M1, 2020 (MacBookPro17,1), with a Touch Bar and no notch, on macOS 15.6.1.

Not yet tested on real hardware:

- MacBooks with a notch. Glance sizes the island around the notch it reads from macOS, but this needs checking on a real notch Mac.
- Intel Macs. The app is built for Intel too, but nobody has run it on one yet.
- External displays. The island sits on the main menu bar screen only.

Reports from other Macs are very welcome. Please open an issue.

## Licence

Glance for Mac is released under the [MIT licence](LICENSE). The vendored mediaremote-adapter keeps its BSD 3-Clause licence. See [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
