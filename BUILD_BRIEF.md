# Canvas — Product Build Brief

Build a production-quality native iPad digital photo-frame app named **Canvas**. Use Swift, SwiftUI, and the latest stable Apple frameworks supported by the installed Xcode. Target iPad first, structure for a later iPhone target, prefer native APIs, and avoid third-party dependencies unless they offer a major benefit.

The current public release is named **Canvas Slideshow**. It intentionally excludes the WeatherKit capability and does not request device location; the weather requirement below is a future-provider option, not a current release claim.

The source project uses the product name Canvas Slideshow and bundle identifier `com.johnhelmuth.canvas`.

## Product goal and defaults

Users select one or more albums from Apple Photos, start an edge-to-edge slideshow, place the iPad on a stand, and precisely control playback, layout, transitions, media, overlays, schedules, audio, power behavior, and accessibility.

Defaults: Recents; shuffle; repeat enabled; 10-second photos; crossfade; 1-second transition; automatic layout; portrait pairing enabled; Live Photos play once; videos enabled and muted; overlays hidden; keep awake while playing; charging-only disabled; night schedule disabled; blurred-photo background; controls hide after four seconds.

## Required functional scope

- Complete PhotoKit authorization for full and limited access. Explain limitations in-app. Show accessible folders, regular and smart albums, Recents, Favorites, and shared albums where supported. Combine multiple albums, persist selections, observe live library changes, tolerate deleted/empty albums, and never duplicate full-resolution libraries.
- Efficient lazy/paged fetching, appropriately sized thumbnail/image caching, request cancellation, upcoming-item prefetch, memory-pressure handling, iCloud download/loading states, graceful failure/skip behavior, and responsiveness with tens of thousands of assets.
- Queue modes: shuffle, album order, oldest/newest, newest/oldest, filename where available, favorites first, repeat or play once, resume position, recent-item avoidance, reshuffle each loop or stable session shuffle, manual next/previous, pause/resume, and jump to an item.
- Filters for hidden items, screenshots, duplicates where reliably detectable, bursts, date range, favorites, people/location where PhotoKit exposes usable data, and photo/Live Photo/video media types. Clearly label unsupported or limited PhotoKit capabilities.
- Separate configurable durations for photos, Live Photos, and video, including all requested presets from 1 second through 60 minutes, custom values, full video playback or a maximum duration.
- Working calm transitions: cut, crossfade/dissolve, four slide directions, push, zoom in/out, Ken Burns, blur dissolve, scale/fade, and page-style swipe where appropriate. Include adjustable duration, random mode, exclusions, smooth rendering, and Reduce Motion fallbacks.
- Layouts: one photo, fit with blurred fill, intelligent fill/crop, solid background, horizontal/vertical pair, smart portrait/landscape pairing, three-photo collage, four-photo grid, and automatic layout. Support fit/fill, background, blur, crop position, spacing, border, corners, shadow, automatic portrait pairing, and paired advancement policy. Use face metadata for safer balanced crops when available.
- Working animated Live Photos and video with autoplay/still, once/loop, mute, volume, replay, skip, and clean slideshow-state continuity.
- Optional configurable overlays for time, date, weekday, capture date, album, location, caption/title, item count, battery/charging, and opt-in weather. Each needs position, typography, opacity, material/shadow, timed hiding, and always-visible mode. Weather must use an appropriate Apple-supported source if entitlement/API access is available and degrade cleanly without it.
- Named schedules by weekday with start/stop, nighttime dimming/brightness, black sleep screen, morning resume, multiple schedules, and manual override until the next event. Respect iPadOS limits on background execution, wake, and unlock, and explain them in-app.
- Frame behavior: keep awake only during active playback, restore prior brightness, charging detection, optional power-only operation, configurable low-battery stop, subtle burn-in protection, and control auto-hide.
- Playback interaction: tap controls, swipes for navigation/exit, pinch/drag zoom, configurable double-tap favorite, long-press details, keyboard, pointer/trackpad, sensible Pencil support, optional on-screen remote controls, and a child/accidental-touch control lock with configurable gesture or local passcode.
- Optional background audio: none, permitted local audio, clean Apple Music integration only if policies/APIs allow, shuffle/repeat, independent controls, fade around audible video, interruption recovery, and full usability without a subscription.
- Favorite/unfavorite where authorized, app-local exclusions without deleting Photos assets, open in Photos where supported, share, metadata, temporary album skip, and multiple complete presets covering albums, filters, transitions, timing, layouts, overlays, sound, schedules, and power settings.
- Polished onboarding: explanation, Photos permission, album choice, duration/transition defaults, schedule/charging choices, then first slideshow. Settings sections: Albums & Filters, Playback, Timing, Transitions, Layout, Live Photos & Video, Overlays, Schedule, Audio, Power & Display, Accessibility, Storage & Privacy. Provide useful live previews.
- Premium iPad design for portrait/landscape, Stage Manager/multitasking, dark setup surfaces, large targets, native materials, light/dark mode, Dynamic Type, VoiceOver, Reduce Motion, shallow navigation, and distraction-free edge-to-edge playback.
- Private by default: no uploads, analytics, ads, or tracking. Keep settings/exclusions local unless future opt-in iCloud sync is added. Include correct Photos, location, and media usage descriptions and an in-app privacy section.
- Robust handling of denied/limited/changed permissions, deleted/empty albums, missing iCloud assets, corrupt media, memory warnings, offline/weather failures, audio interruptions, backgrounding, and rotation during transitions. Asset disappearance must never crash playback.

## Architecture and persistence

Use maintainable separation and dependency injection where useful. Define testable protocols/services for Photo Library access, album selection, queue generation, asset loading/caching, playback, transitions, layouts, video/Live Photos, presets, schedules, persistence, permissions, weather, and optional audio services. Avoid a monolithic view model. Use SwiftData when appropriate for the chosen installed deployment target; otherwise use a clean Apple-native alternative.

## Tests and documentation

Add unit tests for shuffle and linear queues, looping, recent-item avoidance, media filters, preset persistence, schedule calculations, durations, random/excluded transition selection, smart portrait pairing, and album deletion. Add practical UI tests for onboarding and primary slideshow flows.

Deliver a complete building Xcode project, source and assets, README, setup/permissions instructions, architecture documentation, test instructions, known iPadOS/PhotoKit limitations, and a checklist marking every requested feature complete, partial, or unavailable due to platform rules.

## Execution requirements

1. Inspect the workspace and installed Xcode/toolchain first; determine whether the folder is new.
2. Write a concise implementation plan, then create the project structure.
3. Build the first functional vertical slice: Photos permission, album selection, full-screen slideshow, shuffle/linear ordering, adjustable duration, looping, and several transitions.
4. Continue through presets/settings, advanced transitions, layouts, Live Photos/video, overlays/scheduling/audio/power, tests, accessibility, documentation, and polish.
5. After every major stage, build, fix compiler errors, and run relevant tests. Report completed work and current limitations, then continue without waiting unless a decision cannot safely be made.
6. Do not leave core features as mock buttons or placeholder screens. Implement working vertical slices. Use sensible defaults and clearly expose genuine Apple API limitations.
7. Inspect and follow any repository instructions. Preserve unrelated user work. Keep implementation in this dedicated Canvas task and provide evidence-backed completion states.
