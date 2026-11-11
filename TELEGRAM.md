# Telegram in Velagram 1.3

Choose a title or episode in Home, Movies, Series, or Search, then tap Play to open **Sources**. Velagram scans the built-in web providers and Telegram in parallel; choose a release from All, Telegram, or Web. Each release shows the available quality, container, size, and release metadata. Selecting a web source opens Vela’s player with that exact source; selecting Telegram opens the native Telegram/VLC player. Closing either player returns to the source choices. Telegram playback saves progress against the catalog title/episode for Continue Watching.

Telegram search uses the selected title, original title, prioritized Hebrew aliases, release year, and season/episode markers, searches videos/documents/links across accessible main and archived chats, deduplicates messages, and paginates remote results. It rejects explicit year and episode mismatches. Search deeper increases the pagination depth; it does not imply a complete account-wide index. Provider errors do not hide matches from other sources. Availability is checked when selected; inferred release metadata is not a codec probe.

The Telegram account and optional chat/file browser are under **More → Telegram account & files**. The implementation uses the real iOS TDLib JSON client and VideoLAN player, not Telegram Bot API, an Android bridge, or a remote media proxy.

## Sign in

Open **More → Telegram account & files** (or **Connect Telegram** in Sources) and enter your phone number with country code. Enter the code delivered by Telegram, then your two-step verification password if requested. Telegram may require an email address/email code. You can alternatively scan a login QR from another signed-in Telegram device or approve its link in the Telegram app. Codes and passwords are entered directly in Velagram, not in this chat.

New account registration and Telegram-required verification purchases are handed to the official Telegram app. An existing account is needed for Velagram media browsing. Signing out closes the Telegram session and initializes a new native client for another login.

## Browse and organize

- **Chats:** your main list, Telegram folders, local pins, chat-title search, and paginated loading.
- **All:** paginated media across accessible chats, including videos, documents, audio, and directly playable links.
- **Movies / Series:** classify videos from filename/caption episode markers and chat hints. Recognized markers include `S01E02`, `1x02`, `season 1 episode 2`, and Hebrew forms such as `עונה 1 פרק 2` and `ע1פ2`.
- **Series:** groups releases under a cleaned show title, then displays seasons and numerically ordered episodes. Duplicate releases remain separate choices.
- **Sort:** newest, oldest, title, episode order, or size. Classification is heuristic; use a file/chat menu to select Movies or Series manually, or Automatic to remove the override.
- Within a chat, use its topic picker to browse forum topics. Topics and media use Telegram pagination rather than a fixed first-page catalog.
- Search filenames and captions within the current chat/topic or across accessible chats. **Load older media** fetches further pages; the visible counts describe loaded results, not every remote file.
- Use **+** to open a public username or invitation link. Joining via an invitation requires an explicit action in the app; Velagram does not join channels automatically.

## Playback and downloads

Play opens a loopback-only byte-range stream that downloads the requested portions through TDLib. The local URL has a random token and is not exposed on Wi-Fi. No Telegram media is routed through an external proxy.

Apple-compatible formats use AVPlayerViewController. MKV and other unsupported native formats use a redesigned VideoLAN player with auto-hiding controls, temporary 2× hold, center/side double-taps, pinch fit/fill, track selection, subtitle import/online search, caption styling, timing offsets, sleep timer, and control lock. Google Cast uses the official SDK; AirPlay video requires an Apple-compatible release. Keep Velagram open while serving Telegram or relayed media to a TV. See `build/PLAYER_SCANNER_VALIDATION.md` for physical receiver limitations. Each Telegram message has independent saved progress; series share their chosen playback speed. Continue Watching shows the most recently played unfinished episode per series while preserving other episodes' positions. Auto-next follows the loaded series episode order.

**Download for offline use** copies a completed download into Velagram's persistent saved-downloads directory. The download screen supports cancellation, opening saved files, sharing, and removal. Imported playlist attachments can be added to Live TV. If iOS suspends the app, a foreground TDLib download may pause; reopen Velagram and retry if needed. This does not use a privileged background Telegram download service.

## Privacy, backup, and dependencies

TDLib's session database is at `Application Support/VelagramTelegramSession`, outside the exported user-data directory, protected with a randomly generated Keychain encryption key. Session files are excluded from OS backups. Temporary Telegram downloads/thumbnails are in Caches. Saved offline files are in `Application Support/Velagram/TelegramDownloads` and are backed up, along with pins, category overrides, recent media, playback speeds, and progress. Reconnect Telegram after restoring to another device; credentials are not exported.

The application ID/hash are taken from the supplied APK, preserving its Telegram application configuration. Requests and response bodies are not logged by Velagram; TDLib logging is minimized. Sign-in still needs Telegram's actual account verification.

The Swift package is in `Packages/MediaRuntime`. It pins:

- [Swiftgram TDLibFramework](https://github.com/Swiftgram/TDLibFramework), binary `1.8.69-6126ecae`, manifest revision `0ff4690cb5da5081e45ae2c4918b82a4435e9347`.
- [VideoLAN VLCKit](https://github.com/videolan/vlckit), binary `4.0-20260929-1631`, manifest revision `6629ecb91e7e05e6b3fcbf77b17d0421cff37923`.

The downloaded archives were checked against their published SHA-256 values. This workspace has local iOS slices to avoid repeating the large download; the package falls back to the pinned remote archives in a fresh checkout. Frameworks are ignored by Git. License texts are included in Settings → Open-source licenses.

## Validation boundaries

Automated tests exercise multilingual classification, numerical episode order, document/link parsing, folders, pagination, stable message identity, overrides/pins, backup exclusion of login sessions, exact HTTP byte ranges, native TDLib requests, MKV/audio/subtitle streaming through the real local bridge, and the native login UI. Real phone-code/2FA verification and private-channel playback require a signed-in user account; deterministic tests do not substitute for that check.

The signed-in account loads real chats and supports the catalog scanner. The user confirmed real playback on iPhone. Native AVKit and VLC decoder tests, generated-media interaction tests and real-account HIMYM source discovery are recorded in `build/PLAYER_SCANNER_VALIDATION.md`; TV receiver checks remain physical-device work.

Android household/cloud profile sync, automatic group joining, Telegram APK delivery, and Android-specific UI actions are not part of this implementation.

Velagram 1.3 verification supersedes the historical simulator transfer issue: the user confirmed playback on iPhone. The requested HIMYM S06E14 live scan found 84 matching message locations grouped into 9 unique releases, using TMDB Hebrew translations and acronym/episode variants. Sources now show chat names and message dates and support text filtering and ascending/descending sorting.
