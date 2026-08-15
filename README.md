# Canvas

Canvas Slideshow is a native iPadOS photo-frame app built with SwiftUI, PhotoKit, AVKit, and PhotosUI. No login is required for the Apple Photos workflow. It keeps selections and preferences local, reads only the Photos albums the user authorizes, and includes no analytics, advertising, or tracking.

## Build

1. Install XcodeGen (`brew install xcodegen`) if it is not already available.
2. From this folder run `xcodegen generate`.
3. Open `Canvas.xcodeproj` in Xcode 26.6, choose an iPad simulator or a connected iPad, set a development team for a physical device, then Build and Run.

The project targets iPadOS 18.0 and uses the iPad device family. The product bundle identifier is `com.johnhelmuth.canvas`. The App Store product name is Canvas Slideshow.

Build output is intentionally excluded from the repository. Physical installation requires signing with the developer account that owns this bundle identifier.

## First run

Canvas explains Photos access during onboarding, supports Full and Limited Photos authorization for browsing, then lets the user combine regular, smart, and shared albums. Full Photos access is required to safely create and reuse the named Apple Photos album used for explicit Google imports. The default frame is shuffled, repeating, ten seconds per photo, with a one-second crossfade and the screen kept awake during active playback.

All adjustable values are stored as one versioned Codable settings document in UserDefaults. Imported local audio is copied into Application Support/Canvas Audio. Explicit Google imports are stored locally and copied non-destructively into one named Apple Photos album; Apple Photos also shows those assets in All Photos. Canvas never deletes or replaces Apple Photos assets.

## Architecture

- `PhotoLibraryService`: authorization, album discovery, change observation, lazy PhotoKit fetches, iCloud-aware image requests, favorites, cache, and prefetch.
- `QueueService` / `QueueAlgorithm`: shuffle, linear, date, filename, favorites-first ordering, repeat, recent-item avoidance, and safe asset disappearance.
- `PlaybackViewModel`: cancellation-safe current-item loading, duration timers, resume navigation, loop reshuffle, and layout companion prefetch.
- `LayoutCanvas`, `MediaRenderer`, and `TransitionEngine`: single/pair/collage/grid layouts, Live Photos, video playback, Reduce Motion behavior, and transition selection.
- `SettingsStore`, presets, `ScheduleEngine`, `ScheduleMonitor`, `AudioService`, and `PowerService`: local persistence and runtime behavior.
- SwiftUI views are split between onboarding, album selection, library home, player, settings, schedules, overlays, and details.

## Verification

```text
xcodebuild -project Canvas.xcodeproj -scheme Canvas \
  -destination 'platform=iOS Simulator,name=GardenIQ iPad Pro 13' test \
  CODE_SIGNING_ALLOWED=NO
```

The unit suite covers deterministic shuffle and linear queues, favorites/date ordering, recent-item avoidance, media filters, preset round-trips, schedule windows crossing midnight, and Reduce Motion transition selection. UI tests cover onboarding and the home/settings surface with isolated launch arguments.

## Apple-platform limitations

- Limited Photos access is honored for browsing, but it cannot safely create, find, and verify a reusable Canvas-owned named album. Google imports remain intact locally and Apple Photos mirroring stays pending until the user chooses Full Access in Settings. Canvas never adopts an existing user album solely by title.
- PhotoKit may return an iCloud loading error or an asset that was deleted while queued. Canvas reports the item and continues rather than crashing.
- A physical-device build requires the user's Apple Developer signing team and a trusted, connected iPad. The simulator cannot reproduce the user's real Photos library, Live Photos, or iCloud media.
- iPadOS may suspend a foregrounded/backgrounded process and does not guarantee wake, unlock, or schedule execution while the app is not running. Schedules therefore evaluate while Canvas is active and explicitly explain this limitation. Canvas's separate automatic night mode applies an in-app low-light treatment to an open frame from 10 PM to 7 AM by default, returns to normal automatically, and never changes system brightness.
- Weather overlays use WeatherKit with a one-time When In Use location permission for current conditions, feels-like temperature, humidity, wind, UV, precipitation chance, today's high/low, sunrise/sunset, and a next-hour outlook. When an Ambient station is selected, Canvas keeps the station measurements and enriches its sky condition from Open-Meteo's current weather code; if that lookup is unavailable, it shows an honest unavailable condition instead of inferring clear skies. Optional AQI uses Open-Meteo/CAMS with coordinates rounded to approximately one-kilometer precision because WeatherKit does not expose AQI. Canvas refreshes foreground weather on a short cadence, labels cached values as last known, and reports clear states for denied location, offline access, missing WeatherKit entitlement, and service failures. The `com.johnhelmuth.canvas` App ID must have WeatherKit enabled in both its **App Capabilities** and **App Services** tabs before a signed device build can return live conditions. After changing either setting, refresh signing/provisioning and install a newly signed build.
- Apple Music playback is not enabled. Local imported audio works without a subscription; MusicKit requires a separate entitlement, user authorization, and policy review.
- PhotoKit does not provide a universal cross-library identity. For Google items Canvas explicitly mirrors, it persists Google-ID and SHA-256 mappings, verifies PhotoKit local identifiers, reuses the same PHAsset across Canvas albums when a stable ID or verified hash matches, and uses deterministic resource markers to make retry and crash recovery idempotent.
- Opening Photos is best-effort via the Photos URL scheme; the exact asset handoff is controlled by iPadOS.

## Privacy strings

The generated Info.plist includes Photos read/add and When In Use location descriptions. Location is used only when the user opts into weather and AQI; there are no analytics, advertisements, uploads, or tracking SDKs.

## Completion checklist

| Area | State |
| --- | --- |
| Photos full/limited permission and album selection | Complete |
| Combined albums, library changes, empty/deleted assets | Complete |
| Lazy sized image loading, cache, cancellation and prefetch | Complete |
| Queue modes, repeat, shuffle loops, recent avoidance, navigation | Complete |
| Media filters and local exclusions | Complete; content-level duplicate matching is unavailable from PhotoKit |
| 1 second–60 minute timing presets and video maximum | Complete |
| Cut/crossfade/slide/push/zoom/Ken Burns/blur/scale/page-style selection | Complete; blur and page-style use native SwiftUI fallbacks |
| Single/pair/collage/grid/automatic layouts | Complete |
| Live Photos and muted video playback | Complete |
| Time/date/capture/weekday/album/location/count/battery/weather overlays | Complete; weather requires the WeatherKit capability, WeatherKit App Service, and user location permission |
| Named weekday schedules and foreground enforcement | Complete; iPadOS background wake limits apply |
| Keep-awake, charging, battery, and automatic night dimming | Complete; night dimming is an in-app treatment and does not alter system brightness |
| Favorite, exclude, details, swipe, zoom, lock, keyboard/pointer-ready controls | Complete; Photos handoff is best-effort |
| Local audio, interruption recovery, independent controls | Complete; Apple Music unavailable without policy/entitlement work |
| Onboarding, settings, presets, privacy surface, accessibility hooks | Complete |
| Unit/UI tests and docs | Complete |

## Public policies and support

- [Privacy policy](https://jdhelmuth.github.io/canvas/privacy.html)
- [Support](https://jdhelmuth.github.io/canvas/support.html)
- [Issue tracker](https://github.com/jdhelmuth/canvas/issues)

Canvas is released under the [MIT License](LICENSE).
