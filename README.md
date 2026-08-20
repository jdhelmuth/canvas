# Canvas

Canvas Slideshow is a native iPadOS photo frame. It reads the Apple Photos albums you authorize, includes a public-domain Landscapes album, keeps settings on device, and includes no analytics, ads, or tracking.

## Build

1. Install XcodeGen (`brew install xcodegen`) if needed.
2. Run `xcodegen generate`.
3. Open `Canvas.xcodeproj` in Xcode 26.6 and run on an iPad or iPad simulator.

Bundle ID: `com.johnhelmuth.canvas`. Google Photos Picker is optional; set `GOOGLE_PHOTOS_CLIENT_ID` and `GOOGLE_PHOTOS_CALLBACK_SCHEME` in `project.yml`.

```text
xcodebuild -project Canvas.xcodeproj -scheme Canvas \
  -destination 'generic/platform=iOS Simulator' test \
  CODE_SIGNING_ALLOWED=NO
```

Store distribution is in [RELEASE.md](RELEASE.md).

## Policies

- [Privacy](https://jdhelmuth.github.io/canvas/privacy.html)
- [Support](https://jdhelmuth.github.io/canvas/support.html)
- [Issues](https://github.com/jdhelmuth/canvas/issues)

MIT License.
