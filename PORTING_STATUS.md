# Historical porting assessment

This document records the earlier Myko-branded Android port assessment. The current product is Velagram 1.0.0; names and build paths below are historical. See README.md and CHANGELOG.md for current build instructions and features.

# Android → iOS feature parity

Source inspected: `Myko.apk`, package `com.myko.tv`, version `0.1.1627`. The source hash and native-library inventory are in `audit/apk-summary.json`. DEX class names and decoded resources establish feature presence; they do not prove runtime behavior. JADX recovered Kotlin/Java code with 138 decompilation errors. The original JNI/native implementation is not recovered from its Android `.so` files.

This is a **partial native port**, not a complete reproduction of every Android capability. Telegram is now backed by native TDLib and VideoLAN. Torrent/AI features remain unimplemented; account-dependent Telegram validation is distinguished from deterministic tests.

| Android capability | iOS implementation / remaining work |
|---|---|
| Phone/tablet interface | SwiftUI, Vela themes, graphite surfaces, artwork layouts, native tabs, touch navigation |
| TMDB movies/series, search, details, seasons, episodes | Vela native implementation reused |
| Watchlist, watched history, Continue Watching | Vela persistence reused, per-episode progress retained |
| Per-title speed, subtitles and zoom preferences | Vela title player reused |
| Source selection, auto-next, preloading | Vela native implementation reused; provider roster differs from Myko Android |
| Original Myko network/wasm source providers | **Not ported**; Vela's providers and configured HTTP add-on are the current source layer |
| Stremio-compatible add-on streams/subtitles | One configurable manifest, HTTP native-player formats; torrent sources excluded |
| Multiple add-ons and catalog extensions | **Not ported** |
| Israeli live TV/radio | All 84 bundled entries loaded, including alternate sources; direct links, Mako entitlements, Kan HLS conversion and regex/page resolution implemented. Each station remains subject to current access and format support |
| Android live source grouping/failover | Alternates selectable individually; automatic failover/source reordering **not ported** |
| IPTV M3U files/URLs | Native import, merge/deduplication, group metadata, logos, request headers, search, deletion |
| Xtream Codes | M3U live playlist and XMLTV URL construction. Dedicated Xtream VOD/series/catch-up APIs **not ported** |
| Stalker/MAC portals, AceStream | **Not ported** |
| XMLTV program guide | Uncompressed XMLTV, local-time schedules, current/upcoming programs. Android ZIP/JSON guide, reminders, recording/catch-up and date-grid browsing **not ported** |
| Israeli broadcaster VOD | **Not ported**: Kan, Keshet/Mako/24, Reshet, Channel14, i24, Channel9, Sport5/Sport1, Hidabroot catalog clients |
| Jellyfin/Emby | Native sign-in, folder/series/season browsing, search and HLS/audio playback; needs real-server validation. Server progress sync, native library integration and advanced transcoding controls **not ported** |
| Radio/music | Live stations and radio-tagged M3U; Android music catalogs, playlists, queues, YouTube clips and visualizer **not ported** |
| Local video/audio | Files import, direct HTTP URLs, native controls, on-demand resume; formats limited to AVPlayer |
| Telegram/Telemedia | Native iOS TDLib: phone/code/2FA/email and QR login; main chat list and Telegram folders; chat/public-username/invitation access; paginated video/document/audio/direct-link search; forum topics; All/Movies/Series classification and overrides; grouped seasons and episodes; sorting; pins; saved downloads; local byte-range streaming; native VideoLAN playback, seeking, audio/subtitle selection, local subtitle import, resume, title speed memory and auto-next. Catalog-first Sources combines automatic title/year/episode Telegram matching with built-in web-provider choices. Real-account catalog rediscovery passed; the user confirmed real iPhone playback. Myko 1.3 adds native AVKit where compatible, a redesigned VLC player, subtitle import/online search, system caption styling, gestures, AirPlay/Cast integration, chat/date metadata, sorting/filtering and deduplicated multilingual scans. Receiver tests remain device-dependent. Android household/cloud profile synchronization, automatic group joining, and Telegram-delivered APK updates are not ported. |
| Torrent/debrid engines | **Not ported**: local magnet/torrent sessions, selection, seeking/cache, Real-Debrid/TorBox and other service account flows. Needs iOS-native libtorrent or a remote resolver plus service integration |
| VLC / FFmpeg advanced codecs | VideoLAN VLCKit is integrated for Telegram media, including MKV, audio/subtitle tracks, local subtitles and seeking. The existing catalog/live player remains AVPlayer. Android HDMI/refresh/decode controls and its custom FFmpeg/audio pipeline are not ported. |
| AI subtitle/speech pipeline | **Not ported**: Whisper/sherpa/ONNX/VAD models and JNI bridge need an iOS build and an audio extraction pipeline |
| Third-party subtitles and Subtitle Studio | Vela's SubDL/Wizdom/Ktuvit/add-on/native subtitle pipeline and timing versions reused; availability depends on provider/API access |
| Trakt/Simkl/watch-account services | **Not ported**: login/device code, lists, scrobbling and account sync |
| Profiles | Separate live/IPTV/server/direct-playback data; shared movie library. Android household/cloud backup, PINs and full profile isolation **not ported** |
| Backup/restore | Native versioned JSON for local user state and imported files; Android encrypted backup compatibility and cloud sync **not ported** |
| Kids/fights/custom home-row hubs | **Not ported** as dedicated hubs; normal catalog genres remain available |
| Android TV remote, HDMI refresh, screensaver | TV-specific behavior needs mobile product equivalents; no fake iOS switches added |
| Xcode device build / IPA export | Automatic signing with Refael Bar team `A97K2SS8D9`; development archive/export verified |

## How the remaining native integrations can be completed from the APK

1. TDLib and VLCKit now have iOS implementations. Replace the remaining JNI dependencies with iOS frameworks for libtorrent, custom FFmpeg processing, and Whisper/sherpa/ONNX. Inspect their exact behavior against the decoded Java/Kotlin call sites; there are no reusable iOS binaries in the APK.
2. Reimplement each Android provider/account protocol in native Swift and supply its account/client configuration. Validate against actual configured services rather than adding settings-only placeholders.
3. Expand the data model to full per-profile movie libraries and account state; keep its state within the existing backup boundary and add migration/round-trip tests.
4. Add provider contract fixtures, account integration tests, native-codec playback tests, and device tests for PiP/background playback/rotation before claiming parity.

The APK-only constraint is respected: no original Android repository is assumed, and no Android binary is presented as an iOS-compatible implementation.

## 1.4 IPTV/player update

HTTP playlist/API loading and IPTV on-demand catalogs are integrated. Sources merges imported M3U movies/episodes and Xtream VOD with Telegram and web candidates; on-demand browsing is under More. Current guide entries can identify matching live broadcasts. Custom VLC playback uses iOS 26 Liquid Glass and system-style parsed text captions; device-only checks and renderer limits are documented in `build/1.4-VALIDATION.md`.
