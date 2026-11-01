# Canvas Slideshow 1.0.8 (74)

Canvas now supports iPhone and iPad. Compact-width Home, onboarding, slideshow controls, and overlay editing respect device safe areas. iPhone supports portrait and landscape; existing iPad orientations and features remain available.

Release validation found that the original build 73 clipped onboarding content on small iPhones in landscape. Build 74 makes both onboarding pages scroll when needed, preserving the portrait composition and keeping Continue/Back outside the scrolling content. The drag regression test now uses a viewport-sized translation so a correct phone-edge clamp is not mistaken for a drag defect. A landscape onboarding regression checks that the explanation and album picker stay reachable.

Build 73 was already processed in TestFlight. Build 74 is required for the production layout correction; use one Manual Public Release App Store-eligible build for both TestFlight and App Review. Preserve automatic release after approval and the existing iPad listing. Five iPhone screenshots cover welcome, included albums, portrait slideshow, landscape slideshow, and overlay settings using actual app UI and bundled public-domain imagery.

Required validation: complete local native suite with simulator health through teardown, phone and iPad coverage, smallest-phone landscape/portrait inspection, Release build, release requirements and live build-number preflight. Release receipts and screenshots are kept with the November 1 release task.

Limitations: simulator tests do not prove live WeatherKit service or every real PhotoKit/iCloud scenario. Existing physical-device-only diagnostics are opt-in and do not run against the user's active devices during this release.
