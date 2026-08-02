# Google Photos setup

Canvas uses the Google Photos Picker API, the only supported Google API for reading user-selected photos and videos. Since March 31, 2025, Google does not allow third-party apps to enumerate a user's library or shared albums. A person opens an album in Google's picker and selects its items; Canvas downloads an offline copy and merges a later selection made with the same Canvas album name.

## Configure the build

1. In Google Cloud Console, enable **Google Photos Picker API**.
2. Configure the OAuth consent screen and create an **iOS OAuth client** for Canvas's bundle identifier.
3. Set these user-defined build settings on the Canvas target (prefer an uncommitted `.xcconfig` for real credentials):
   - `GOOGLE_PHOTOS_CLIENT_ID`: the iOS OAuth client ID.
   - `GOOGLE_PHOTOS_CALLBACK_SCHEME`: the reversed client ID registered by Google (for example, `com.googleusercontent.apps.123456`).
4. Add your test Google account to the OAuth consent screen while the app is in testing status.

Canvas uses OAuth authorization code flow with PKCE. Access and refresh tokens are stored in the iOS Keychain. Imported media and album metadata stay in the app's Application Support directory. A build without the two settings remains fully functional for Apple Photos and shows an actionable missing-configuration message instead of starting a broken sign-in.

## Sync behavior and limitations

- Name the album in Canvas, then open the desired album in the Google picker and select its items.
- Repeating the flow with the same name refreshes the existing Canvas album. Strong Google item overlap also matches a renamed album.
- Exact Google items, identical downloaded bytes, and conservative cross-source metadata matches are deduplicated in playback.
- A Google selection that exactly matches an Apple album is not shown as a second album. Partial overlaps remain separately selectable so Google-only items are not lost; duplicated media is still removed from the queue.
- Google does not expose ongoing shared-album change notifications. Refreshing requires another explicit picker selection.
