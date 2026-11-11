# Vela → Myko feature audit

Compared the Swift sources in `BetterStreamflix-iOS-port/ios/Vela` with Myko on November 11, 2026. This is a source and regression-test audit; it does not assert every remote provider or receiver was exercised on a device.

## Findings and changes

The Vela catalog, library, subtitle services, skip databases and native web player were already copied into Myko. The important omissions were at the boundary between that catalog and Myko's newer Telegram/IPTV player.

| Feature | Myko behavior after this change |
| --- | --- |
| Skip intro, recap, credits and preview | Catalog-linked Telegram/IPTV playback now queries the same duration-aware SkipDB/IntroDB resolver as web playback. Buttons appear only for returned segments. Credits offer Next Episode when a next catalog episode is available. |
| Next episode | Web, catalog-linked Telegram and catalog-linked IPTV open the next episode's Sources chooser. The chooser allows switching provider or release for each episode. Standalone Telegram keeps its existing file queue and now also has a manual Next Episode button. |
| Automatic next | The existing setting controls opening the next catalog episode's chooser at playback end. It does not pick a release on the user's behalf. Standalone Telegram retains queue auto-play. |
| Watched completion | Episodes finish automatically when known credits begin, or in the last 60 seconds when credits are unknown. Completion does not interrupt playback. Subsequent local/Cast progress callbacks do not restore the completed episode's progress. |
| Continue Watching | Completion promotes the next episode. Each other episode retains its own position; the existing most-recently-played series behavior remains. |
| Playback speed | Catalog Telegram/IPTV now use the global default and the same per-title saved speed as web playback. Temporary 2× gestures remain temporary. Standalone Telegram retains its own speed history. |
| Audio and orientation | Catalog playback applies the configured audio language and player orientation; existing manual audio selection remains available. |
| Fit/fill | Catalog Telegram/IPTV now share per-title fit/fill memory with the web player. |
| Subtitle defaults | Catalog Telegram/IPTV respect the default subtitle switch, saved title visibility and primary language for embedded subtitles. Automatic online discovery honors enabled providers, saved release identity, primary/secondary language and fast versus complete-before-playback loading. Existing manual online search and file import remain available. |
| Subtitle Studio | Parsed Telegram/IPTV captions gain cue preview, seek-to-cue, play/pause, fine offset adjustment and saved timing versions for online subtitle releases. Versions use Vela's existing per-episode library storage and restore when the matching release is loaded again. The web player's full Studio remains intact. |
| Cast progress | Catalog completion uses remote progress and guards against later callbacks recreating completed progress. |
| Build integration | Regenerated the Xcode project from `project.yml` to include the existing `CacheManagement.swift`, which was absent from the checked-in project sources. |

## Existing Vela features retained

Source comparison, allowing for branding, showed that these implementations already exist in Myko:

- Home collections, artwork, title details, catalog filtering, search, seasons, episodes and progress posters. Series browsing remains under More; Myko's Live tab remains available.
- Watchlist, watched episodes, Continue Watching, per-episode resume and per-title playback preferences.
- TMDB metadata enrichment and Vela's web/anime playback providers, audio/quality policies and stream refresh/recovery.
- SkipDB/IntroDB validation, duration matching and provider fallback.
- SubDL, Wizdom, Ktuvit, add-on and built-in subtitles; parsing, direction formatting, retry/cache infrastructure and the existing web Subtitle Studio.
- Appearance themes, artwork sizing, orientation preferences, language settings, backup/export/import, cache management and open-source notices.

Myko's additional live TV, radio, IPTV/Xtream, Telegram scanning/grouping/downloads, media-server browsing, local/direct playback, Cast/AirPlay, sleep timer, control lock and gestures remain in place.

## Intentional adaptations and boundaries

- Vela's automatic release selection/preload cannot replace Myko's explicit Sources choice. Catalog navigation continues to open Sources. Existing provider preparation and the web playback infrastructure remain available.
- Vela's update checker targets the Vela product. It was not enabled for Myko.
- Files played outside the catalog may have no reliable TMDB/IMDb episode identity. They keep file resume/queue behavior; skip database queries and catalog watched status are not guessed from a filename.
- Skip buttons require database coverage for the title, episode and cut. Missing data does not block playback.
- Native image subtitles cannot provide editable text cues. The added Studio works with parsed captions; native AVPlayer built-in caption timing still has its existing platform limitation. Imported subtitle files keep their existing release-specific timing control; named saved versions require online subtitle identity.
- Real Telegram account, provider availability, physical-device AirPlay/PiP and Cast receiver validation require device/service testing beyond the deterministic simulator suite.

## Verification

The final iOS device build passed (`build/vela-parity-build.log`). The signed simulator run passed all 245 unit/integration tests across 29 suites, plus both UI smoke tests: catalog → combined Sources and modern Telegram player controls/gestures (`build/vela-parity-final-tests.log`). An earlier unsigned simulator UI attempt could not reach the catalog because Keychain returned -34018; rerunning with simulator signing resolved it. Added regression coverage for final-minute completion, next episode promotion, preserving another episode's saved position, shared speed/zoom/subtitle visibility, and restoring a saved subtitle timing version.
