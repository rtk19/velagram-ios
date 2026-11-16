# Offline library

Home’s arrow-down button, the source scanner, Telegram, and Cache & Storage all open `DownloadsView`. The former Telegram-only downloads screen has been replaced.

## Behavior

- The scanner lists matching local releases before streaming results. Saved releases take priority over cached releases.
- An unavailable network path opens Downloads. Local playback bypasses source resolution and online subtitle discovery.
- Downloads is a title navigator. A series opens its seasons and episodes; a movie opens its source list. Episodes open a source list with every distinct saved, cached, or active release. Each title and episode appears once. The root uses title artwork and offline availability counts, with separately labeled activity for each downloading episode. It never combines a watched episode’s resume position with a different episode’s transfer. Inner episode rows share Home’s Continue Watching presentation, including artwork, playback progress, and resume time. Search and All / Downloaded / Cached filters apply to titles.
- Title and episode metadata is serialized with each entry. Poster artwork is copied into offline storage so clearing the normal artwork cache does not remove saved download posters.
- Offline playback uses `LibraryStore` for resume position, watched state, playback preferences, and Continue Watching. Auto-next selects the next locally available, unwatched episode.
- Telegram’s fully completed cache files are indexed without copying or relabeling them as saved downloads. Keep download copies a cached file into protected storage and works without a network request.
- Clear cache delegates Telegram eviction to TDLib and reconciles local entries afterward. It preserves saved downloads. Delete downloads preserves cached videos and watch history. Both operations respect active playback and transfer leases.
- Legacy Telegram download manifests remain readable. Downloaded media is excluded from automatic OS backups.

## Transfer support

Telegram files and direct HTTP video files are supported. Authenticated HTTP requests preserve source headers. Transfers expose percentage, transferred/total size, smoothed bytes per second, cancellation, errors, and retry from the scanner. The same measurements appear in the navigator, source list, and scanner. Stalled transfers show zero speed rather than retaining an old measurement. File transfers are validated before publication; incomplete files are never added to the library.

On-demand HLS streams are downloaded with AVFoundation into native offline packages, including the selected audio. HLS is detected by URL extension or response MIME type. These transfers report media-time percentage rather than invented byte counts, preserve source headers, support cancellation, and publish only packages verified playable offline. Saved packages open with the native player, contribute to saved-download storage totals, and are deleted with other saved downloads. Live, protected, and DASH sources return a specific explanation when offline saving is unsupported. Transfers currently require the app to remain open; there is no background transfer or restart-resume queue. Embedded subtitles remain part of the downloaded video; downloading external subtitles is outside this implementation.

## Validation

Targeted simulator coverage includes metadata round trips, legacy manifests, episode identity across providers, evicted files, offline next-episode selection, separate storage accounting, cache preservation, and playback progress persistence. UI coverage checks Home navigation and the title → episode → sources hierarchy, with equivalent Telegram copies collapsing to one release while distinct releases remain accessible. Unit tests cover duplicate preference, cross-episode isolation, transfer delta sampling, unknown lengths, and stalled speed. Test screenshots are attached to the Xcode test result.

The simulator run also exposed an existing TDLib process-exit race. The receiver now stops before native C++ teardown; the repeated run produced no crash attachment.

Real-device airplane-mode playback, long transfers, low storage, and suspension/relaunch behavior still need a physical-device smoke test before shipping.

## Scanner playback and cache status

Actual playback records a source history per movie or exact season/episode using the catalog identity. The last played source is shown once in a pinned section above other local and network sources; earlier played releases carry a Recently played badge. A failed source opening does not create history. Telegram copies share their release identity. Fully cached videos remain in On this device; partially cached sources show cached bytes and a percentage when the total size is known. An active transfer uses its existing transfer bar instead of duplicating it with a cache bar.
