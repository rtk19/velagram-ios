# Velagram for iPhone & iPad

<img src="Velagram/Resources/Assets.xcassets/VelagramLogo.imageset/VelaLogo.png" width="160" alt="Vela logo">

Velagram **1.0.0** brings Vela’s native SwiftUI interface, original logo, movie and series library, and playback experience together with Telegram media discovery, live TV, IPTV, and personal media servers. Requires **iOS 17 or later** on iPhone or iPad.

## Features

- **Movies and series:** TMDB discovery and search, title details, seasons and episodes, watchlist, Continue Watching, resume positions, title-specific playback speed, next episodes, and source selection.
- **Telegram:** TDLib login with phone/code/2FA or QR, chats and folders, forum topics, multilingual title/year/episode matching, deduplicated releases, sorting and filters, thumbnails, saved downloads, and byte-range streaming.
- **Playback:** AVPlayer for compatible streams and VideoLAN for MKV and other formats; seeking, audio/subtitle selection, gestures, background audio, picture in picture, AirPlay, Google Cast, and iOS 26 Liquid Glass controls where supported.
- **Subtitles:** embedded tracks, local imports, online providers, device caption styling, timing adjustments, and saved Subtitle Studio versions.
- **Live TV and radio:** bundled channel directory, search, groups, favorites, recent channels, and XMLTV program guides.
- **IPTV:** HTTP/local M3U imports, Xtream accounts, and movie/series VOD discovery. Reimport merges matching streams.
- **Personal libraries:** Jellyfin and Emby browsing and playback; direct HTTP streams and imported local video/audio files; configurable Stremio-compatible HTTP stream/subtitle add-ons.
- **Profiles and customization:** separate live-TV profiles, themes, playback defaults, languages, and settings.
- **Backup and storage:** validated versioned JSON export/import, imported-file restore, cache usage and cleanup, retention periods, optional storage caps, and offline download management.
- **Updates:** checks [this repository’s releases](https://github.com/rtk19/velagram-ios/releases).

Provider accounts, network availability, stream codecs, and receiver support affect playback. This release includes the implemented iOS features; it does not claim complete parity with the Android app that informed earlier development. Torrent and speech engines, Android cloud/household synchronization, and automatic Telegram group joining are not included. See [porting history](PORTING_STATUS.md), [Telegram details](TELEGRAM.md), and [release notes](CHANGELOG.md).

## Build from a fresh checkout

Use Xcode with the iOS 26 SDK or newer, Swift 5.10 language mode, and XcodeGen (`brew install xcodegen`). The app’s minimum deployment target remains iOS 17.

```sh
git clone https://github.com/rtk19/velagram-ios.git
cd velagram-ios
./scripts/configure.sh
# Fill in Config/Local.xcconfig and your Telegram configuration as described below.
xcodegen generate
open Velagram.xcodeproj
```

Select the **Velagram** scheme and a simulator or device. For a physical device, select your Apple development team and a bundle identifier available to your account. The checked-in project uses `com.refael.Velagram` and the original development team. Project structure and version settings are defined in `project.yml`; regenerate after changing that file.

SwiftPM fetches the exact Google Cast version and checksum-pinned TDLib/VideoLAN binary archives. The optional local `Packages/MediaRuntime/Artifacts/` directory is ignored. A fresh checkout uses the upstream URLs automatically; no Android binaries or retired player dependencies are required.

### Service configuration

Credentials are excluded from Git. `./scripts/configure.sh` creates safe empty defaults, so an unconfigured checkout builds but account-dependent services need configuration:

| Service | Configuration |
| --- | --- |
| TMDB catalog | Set `TMDB_READ_ACCESS_TOKEN` in `Config/Local.xcconfig`, or enter a token in app settings |
| SubDL | Set `SUBDL_API_KEY` in `Config/Local.xcconfig` |
| Telegram | Copy `Config/TelegramConfiguration.example.plist` to `Config/TelegramConfiguration.local.plist`, set your `api_id` and `api_hash`, then rerun `./scripts/configure.sh` |
| IPTV / Jellyfin / Emby / stream add-on | Configure your own services in the app |

Obtain your own API credentials from the respective services. Configuration compiled into an app can be extracted from the app bundle. Do not distribute builds containing credentials you cannot share.

### Tests

```sh
xcodebuild -project Velagram.xcodeproj -scheme Velagram \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

Unit tests cover catalogs, playback, subtitles, backup/restore, Telegram, cache policy, M3U/XMLTV/Xtream parsing, profiles, and server integration logic. UI tests cover navigation and fixture playback. Live provider checks are opt-in with `VELAGRAM_LIVE_STREAMS=1`; real accounts, physical receivers, and paid services require separate checks.

### IPA and GitHub builds

```sh
./scripts/configure.sh
./scripts/build-ipa.sh development
./scripts/build-ipa.sh ad-hoc
./scripts/build-ipa.sh app-store-connect
./build-unsigned-ipa.sh
```

Outputs are under `build/<mode>/`. Signed exports require the appropriate Apple certificates and provisioning profiles. Development builds install only on provisioned devices. An **unsigned IPA must be signed before installation**. App Store export does not upload to App Store Connect.

GitHub Actions runs simulator unit tests on pushes and pull requests. A version tag (`v1.0.0`) or manual release-build dispatch builds an unsigned Release IPA and retains it as an Actions artifact; tag runs attach it and its SHA-256 checksum to the GitHub release. For service-enabled CI builds, set repository secrets `TMDB_READ_ACCESS_TOKEN`, `SUBDL_API_KEY`, `TELEGRAM_API_ID`, and `TELEGRAM_API_HASH`. Without secrets, builds use empty configuration. Apple signing and App Store upload are intentionally local configuration steps.

## Data and privacy

App preferences and `Application Support/Velagram` hold user state. JSON backups include preferences, profiles, library/history, subtitle versions, saved-download metadata and imported local files. Imports validate and replace backed-up state. The Velagram bundle identifier creates a separate app installation from earlier development builds; export before switching apps. Earlier branded backups are not guaranteed compatible.

Telegram databases use a Keychain encryption key and are excluded from JSON/device backups. Server tokens are stored in Keychain and excluded from JSON exports; reconnect accounts after restoring on another device. Exported playlist URLs may contain provider credentials. Regenerable caches are excluded from backups.

## Attribution

Velagram uses the original Vela logo and interface at the project owner’s request. The Vela foundation retains its Apache 2.0 license and notices: see [LICENSE](LICENSE), [NOTICE](NOTICE), and bundled third-party notices. TDLib, VideoLAN and Google Cast retain their respective licenses. Channel metadata/artwork inherited from the supplied Android material does not confer redistribution rights to broadcaster content. Velagram is an independent client and is not affiliated with Telegram, TMDB, VideoLAN, Google, or the listed providers.
