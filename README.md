# Steamwatch

A macOS menu-bar app that watches your Steam wishlist for sales. The menu bar shows how many
wishlisted games are discounted right now; the dropdown lists them (target hits first, then
first-ever sales and new lows), tracks the lowest price seen for each, shows your playtime this
week, and tells you which friends are online. It notifies you when a game drops to the price you
set.

![Popover](docs/popover-light.png)

## Setup

1. Build and install (see below) or download a release, then launch Steamwatch.
2. In Settings, paste your Steam profile URL (`https://steamcommunity.com/profiles/7656…` or
   `https://steamcommunity.com/id/yourname`) and click Connect.
3. Your wishlist must be public: on Steam, Profile → Edit Profile → Privacy Settings → set
   **Game details** to Public. The wishlist and store prices are read without signing in.
4. Optional: paste a [Steam Web API key](https://steamcommunity.com/dev/apikey) to unlock playtime
   and friends online. Steam issues one to any account that has made a purchase. The key is stored in
   your Keychain and only ever sent to `api.steampowered.com`.

Right-click any game in the dropdown to set a target price. Click a game to open its store page.

## How the numbers work

- **On sale** means the store reports a discount on the app's best purchase option in your
  country (Settings → Store → Country code).
- **Low seen / new low** compare against what Steamwatch itself has observed. Steam has no price
  history API, so the record starts the first time the app looks at a game.
- **First sale ever** means every earlier reading of that game was at full price.
- **Played this week** samples Steam's "last two weeks" counter on every refresh and attributes
  each increase to the day it was noticed, so the daily bars fill in while the app is running.
  Until there is a week of samples it also shows the raw two-week total.

## Building

Requires Xcode 15 or newer (macOS 14+ to run).

```bash
swift test                                   # core library tests
./scripts/build-app.sh --install             # universal Steamwatch.app → ~/Applications
```

Useful flags on the built binary:

```bash
build/Steamwatch.app/Contents/MacOS/Steamwatch --once          # fetch once and print a summary
build/Steamwatch.app/Contents/MacOS/Steamwatch --once --demo   # same with sample data
build/Steamwatch.app/Contents/MacOS/Steamwatch --snapshot docs --demo   # README screenshots
```

Launch with `--demo` to see the UI with sample data and no network access.

## Project layout

```
Sources/SteamwatchCore   Foundation-only library: Steam client, deal engine, price history,
                         playtime log, formatting, JSON file formats. Builds on Linux/Windows.
Sources/Steamwatch       macOS app: NSStatusItem + NSPopover, SwiftUI views, Keychain,
                         UserNotifications, Settings window.
Tests/SteamwatchCoreTests
scripts/build-app.sh     universal build, signing, notarization, zip
docs/windows.md          what a Windows port needs
```

Data lives in `~/Library/Application Support/Steamwatch/` (`price-history.json`,
`playtime.json`, `targets.json`, `cache.json`). Preferences are in
`io.github.mrte1122.Steamwatch`.

## Steam API usage

| Call | Key | Used for |
| --- | --- | --- |
| `IWishlistService/GetWishlist` | no | wishlist app IDs |
| `IStoreBrowseService/GetItems` | no | names, capsule art, prices, sale end dates (50 apps per request) |
| `IPlayerService/GetRecentlyPlayedGames` | yes | playtime |
| `ISteamUser/GetPlayerSummaries` | yes | your status, friends' status and current game |
| `ISteamUser/GetFriendList` | yes | friend IDs (public friends lists only) |
| `ISteamUser/ResolveVanityURL` | yes | custom profile URLs → SteamID64 |

Default refresh is every 30 minutes: 1 wishlist call plus one store call per 50 wishlisted games,
and 3 keyed calls when a key is set. Steam is not affiliated with this project.

## License

MIT.
