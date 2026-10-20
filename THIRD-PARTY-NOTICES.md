# Third-party notices

Glance for Mac is MIT licensed (see `LICENSE`). It includes the following third-party code.

## mediaremote-adapter

- Source: https://github.com/ungive/mediaremote-adapter
- Version: commit 797729d9b16316dc313844476c153d7a107ca0df, vendored unmodified in `Vendor/mediaremote-adapter`
- Used for: reading and controlling Now Playing media through macOS's private MediaRemote framework
- Licence: BSD 3-Clause. The full text is below and in `Vendor/mediaremote-adapter/LICENSE`. A copy is
  also placed inside the app at `Glance.app/Contents/Resources/mediaremote/LICENSE-mediaremote-adapter.txt`.

```
BSD 3-Clause License

Copyright (c) 2025, Jonas van den Berg and contributors

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Sparkle

- Source: https://github.com/sparkle-project/Sparkle
- Version: 2.10.0, the official Swift Package Manager binary (`Package.swift`), copied into the app at
  `Glance.app/Contents/Frameworks/Sparkle.framework` (its XPC services are left out; Glance is not sandboxed)
- Used for: in-app updates (checking the update feed, the update window, installing signed updates)
- Licence: MIT, with the external licences listed in Sparkle's own LICENSE file. A copy is placed inside
  the app at `Glance.app/Contents/Resources/LICENSE-Sparkle.txt`.

## Services used at runtime (no code included)

These are called over the network while the app runs. No code or data from them is stored in this repository.

- Open-Meteo (weather and geocoding): https://open-meteo.com
- LRCLIB (synced lyrics): https://lrclib.net
- ESPN public site API (Football mode scores). This is an unofficial, undocumented feed. It is not
  affiliated with or endorsed by ESPN and may change or stop working at any time. See the Football
  section of the README.
- Yahoo Finance (optional Stocks feature, off by default)

## Trademarks

Club names, crests and badges shown in Football mode belong to their owners. Glance does not ship
any of them. Badges are downloaded at runtime from the data source and cached on your Mac only.
Apple, Mac, macOS, Touch Bar and SF Symbols are trademarks of Apple Inc. Chrome is a trademark of
Google LLC. Claude and Claude Code are trademarks of Anthropic.
