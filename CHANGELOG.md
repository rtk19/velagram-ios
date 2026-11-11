# Release notes

## 1.0.0 — 2026-11-11

First Velagram release, bringing the complete currently implemented iOS feature set into the new repository.

- Rebrand the application, Xcode targets, Swift modules, assets, themes, storage identifiers, test fixtures and scripts to Velagram.
- Use the original Vela app icon, logo and accent asset; retain Vela’s native interface and player foundation.
- Include movie/series discovery, watchlist, Continue Watching, per-title playback state, source selection and auto-next.
- Include Telegram authentication, chats/folders/topics, multilingual catalog matching, grouped and deduplicated releases, downloads and streaming.
- Include native AVPlayer and VideoLAN playback, MKV support, captions, subtitle search/import/timing, PiP, AirPlay, Cast and adaptive playback controls.
- Include live television/radio, M3U and Xtream imports, VOD, XMLTV guides, favorites and live profiles.
- Include Jellyfin/Emby, direct streams, local files and configurable HTTP stream/subtitle add-ons.
- Include themes, settings, backup/restore, offline-download management, selective cache cleanup, retention and storage limits.
- Point app update checks to `rtk19/velagram-ios`.
- Add private service configuration, reproducible build instructions, simulator CI and unsigned release artifacts with checksums.

### Distribution and verification limits

Unsigned IPAs require signing. Development IPAs require registered devices. A GitHub release is not an App Store submission. External providers, paid accounts, real Telegram accounts, and physical AirPlay/Cast receivers require their own validation. Historical Android parity gaps remain documented in PORTING_STATUS.md. Earlier development-branded backup formats are not guaranteed compatible with the new application identity.
