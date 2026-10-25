# Vaporwatch privacy policy

_Last updated: October 25, 2026_

Vaporwatch is a free, open-source Mac app that shows sales on your Steam wishlist. It has no
account, no server and no analytics. Everything it knows about you stays on your Mac.

Vaporwatch is not affiliated with, endorsed or sponsored by Valve Corporation. Steam and the Steam
logo are trademarks of Valve Corporation.

## What Vaporwatch reads

- **Your Steam profile ID**, which you give it (or which it reads from the Steam app's
  `loginusers.vdf` on your Mac, only when you click "Use this account").
- **Public Steam data**: your public wishlist, store prices, reviews, platforms, tags and artwork.
- **With an optional Steam Web API key you provide**: your owned games, recent playtime, your
  profile name and status, and which friends are online (if your friends list is public). This is
  the only non-public Steam data Vaporwatch uses, and it fetches it only for the account you
  connected, because you asked it to.

## Where it's stored

Only on your Mac:

- Your API key is stored in your **macOS Keychain**.
- Settings (your profile ID, preferences) are in macOS user defaults for the app.
- Price history, playtime samples, price limits, watched games, hidden and muted games, suggestions
  and a cache of the last reading are JSON files in
  `~/Library/Application Support/Vaporwatch/`.

Nothing is uploaded to the developer or anyone else. There is no telemetry or crash reporting.

## Who Vaporwatch talks to

- **Valve (Steam)**: `api.steampowered.com` and `store.steampowered.com` for the data above, and
  Steam's image servers (`steamstatic.com`) for game artwork. Requests that need your API key send
  it to `api.steampowered.com` only. Valve's own [privacy policy](https://store.steampowered.com/privacy_agreement/)
  applies to those requests.
- **GitHub**: once a day, `api.github.com` is checked for a new Vaporwatch release (you can turn
  this off in Settings → About), and updates are downloaded from GitHub Releases.

Links you click open in the Steam app or your browser.

## Your choices

- Remove your API key in Settings → General, or in Keychain Access (service "Vaporwatch"). If you
  used the app when it was called Steamwatch, an older copy may also be saved under "Steamwatch";
  macOS only lets the app that created it delete it, so remove that one in Keychain Access.
- Delete all data by quitting Vaporwatch and removing `~/Library/Application Support/Vaporwatch/`
  and the app. If you installed with Homebrew, `brew uninstall --cask --zap vaporwatch` does this.
- **Copy Diagnostics** (Settings → About) puts a summary on your clipboard for bug reports. It
  never includes your API key or Steam ID, and nothing is sent unless you paste it somewhere.

## Contact

Questions: [open an issue](https://github.com/mrte1122/Vaporwatch/issues/new/choose).
