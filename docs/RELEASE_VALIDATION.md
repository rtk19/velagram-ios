# Velagram 1.0.0 validation

Validated on 2026-11-11 using the committed Velagram project and local service configuration.

- Xcode simulator build and test: **passed** on iPhone 17 Pro, iOS 26.5.
- Swift Testing: **250 tests in 30 suites passed**. Opt-in live/account tests remain skipped unless configured.
- XCUITest: **7 tests passed**, covering cache overview/cleanup confirmation, combined catalog source selection, Live/More/Files navigation, native player dismissal, Telegram player controls/gestures, native player settings, and Telegram account navigation.
- Device Release archive: **ARCHIVE SUCCEEDED**.
- Development-signed IPA export: **EXPORT SUCCEEDED** (`build/development/Velagram.ipa`, local and ignored).
- Shell syntax, resource plists and asset catalog JSON: passed validation.
- App icon and in-app logo: copied unchanged from the original local Vela project.
- Git staging scan: no local TMDB, SubDL or Telegram credentials in committed files.

The development IPA contains the local service configuration and remains local. GitHub builds use empty service configuration unless repository secrets are supplied. The publicly built unsigned IPA needs signing and service configuration for account-dependent functionality. Actual provider accounts, long playback sessions, and physical Cast/AirPlay receivers were not revalidated for this branding release. Historical test reports under ignored `build/` are not shipped as release evidence for untested features.
