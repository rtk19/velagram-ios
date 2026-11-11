# Telegram MKV playback investigation — 2026-11-11

## Comparison with open source players

- [VLC for iOS](https://github.com/videolan/vlc-ios/blob/master/Sources/Playback/Control/VLCPlaybackService.m) uses VLCKit, which Myko already uses for MKV. Its player owns decoding, rendering, audio and the playback clock. Replacing Myko's UI with VLC's UI would leave Myko's Telegram byte source unchanged.
- [KSPlayer](https://github.com/kingslay/KSPlayer) uses FFmpeg and hardware decoding. The bundled source has a three-second preferred forward buffer, a thirty-second maximum buffer, and resumes packet reads before the buffer empties (`KSOptions.swift`, `MEPlayerItem.codecDidChangeCapacity`). It is not linked into the app's current playback target.
- [Swiftfin's player documentation](https://github.com/jellyfin/Swiftfin/blob/main/Documentation/players.md) describes MPV and AVPlayer, with MKV supported by MPV and unsupported by AVPlayer. Its server can also remux or transcode unsupported sources. Myko's Telegram bridge serves original bytes and has no equivalent server conversion.
- [VLC's core defaults](https://github.com/videolan/vlc/blob/master/src/libvlc-module.c) enable hardware decoding and set network caching to 1,000 milliseconds. Changing the engine does not eliminate network starvation or guarantee hardware decoding for every codec inside MKV.

No upstream implementation was copied into this change.

## Confirmed implementation problems

The loopback HTTP server writes up to 256 KB at a time. Previously **every** chunk awaited `getFile` and `getFileDownloadedPrefixSize`, opened the local file and read it. Even a completely downloaded 8 MB file required 64 TDLib calls for 32 chunks. These control-plane waits sit directly in the media delivery path.

The reader requested another 16 MB download only when fewer than 4 MB were available **and** TDLib reported downloading had stopped. This prevented extending an active window before it ran out. MKV index probes and seeks add nonsequential requests to the same source.

The VLC path used the generic one-second network cache. This leaves little headroom for bursty Telegram delivery. MP4 uses a separate AVPlayer buffering pipeline, so smooth MP4 does not demonstrate smooth MKV with the original configuration.

## Changes

1. Remember up to eight ranges that TDLib actually confirmed downloaded. Serve those ranges from disk without repeating control calls. Completed files require no prefix query. The server already holds a cache lease that excludes app cache eviction.
2. Refresh availability near the end of a partial range. Extend the requested download window with overlap before the current request stops. Keep confirming newly downloaded bytes; issuing a download request does not authorize reading sparse file holes.
3. Give network MKV a 3,000 ms VLC cache. This can increase startup/seek buffering in exchange for more tolerance of delivery jitter. Local files use the engine default.

VLC continues selecting its decoder, video output and audio clock. The change does not force software decoding, change clock master, or add a second audio/video decoder.

## Evidence and verification

Existing numeric playback diagnostics were read from the connected iPhone. Historical MKV sessions contain repeated missing-byte waits, and one session reached 657 lost video frames. These logs span older builds, so they support the reported symptoms but cannot establish that the latest code has resolved them. No Telegram database, credentials, or media content was copied for this investigation.

Simulator validation: **10 tests in 6 suites passed**, including parameterized cases:

- Production MKV session: seek, paused seek, resume, temporary speed, track exposure, subtitle/audio delays and PiP clock bridge.
- 1080p H.264 + AC-3 MKV: local file and HTTP byte-range bridge; continued playback after startup, no failure/buffering at the final check, and zero lost audio buffers. The HTTP fixture's sampled diagnostics also showed zero lost video frames. Logs confirm VideoToolbox decoding.
- MP4 production session: native playback, tracks and speed restoration.
- Real VLC playback and seeking over the Telegram HTTP endpoint.
- Cached sequential read: all 8 MB verified; **one** TDLib call for 32 chunks, zero prefix queries; test completed in approximately 15 ms in this run.
- Partial-cache window refill while TDLib remains active; unconfirmed seek bytes must trigger download requests.
- Missing-file recovery, relocated cache paths, HTTP half-close support, embedded plain/ASS subtitle extraction.

Test result: `/Users/refaelavramashvili/Library/Developer/XcodeBuildMCP/workspaces/myko-ios-f78864a70b95/result-bundles/test_sim_2026-11-11T08-24-34-327Z_pid95155_8fc5f6d8.xcresult`.

The optimized Release build for physical iPhone (`generic/platform=iOS`, signing disabled) also succeeded. Build log: `/tmp/myko-mkv-release-build.log`. This build has not been installed on the phone.

## Remaining release verification

The failing Telegram title/message has not yet been identified. Retest the updated app on the physical iPhone with that exact source, especially uncached startup, forward/backward seeks, extended playback, temporary speed, Bluetooth and interruptions. The short fixtures do not certify arbitrary HEVC/10-bit/4K content, long-term A/V drift, weak networks, or every MKV codec. The old phone logs are not post-fix measurements.
