# Google Photos setup

Canvas uses the Google Photos Picker API, the generally available Google API for reading user-selected photos and videos. Since March 31, 2025, Google does not allow third-party apps to enumerate a user's library or shared albums through the Library API. The Picker returns only the media explicitly selected in one session, not source-album identity, membership, ownership, contributor identity, or a subscription to later changes. Canvas downloads an offline copy and additively merges later selections made with the same Canvas album name.

## Configure the build

1. In Google Cloud Console, enable **Google Photos Picker API**.
2. Configure the OAuth consent screen and create an **iOS OAuth client** for Canvas's bundle identifier.
3. Set these user-defined build settings on the Canvas target (prefer an uncommitted `.xcconfig` for real credentials):
   - `GOOGLE_PHOTOS_CLIENT_ID`: the iOS OAuth client ID.
   - `GOOGLE_PHOTOS_CALLBACK_SCHEME`: the reversed client ID registered by Google (for example, `com.googleusercontent.apps.123456`).
4. Add your test Google account to the OAuth consent screen while the app is in testing status.

Canvas uses OAuth authorization code flow with PKCE. Access and refresh tokens are stored in the iOS Keychain. Imported media and album metadata stay in the app's Application Support directory. A build without the two settings remains fully functional for Apple Photos and shows an actionable missing-configuration message instead of starting a broken sign-in.

## Saved-selection behavior and limitations

- Name the album in Canvas, open Google's Picker, search for the desired album title, select its items, and tap Done. Google limits each Picker session to 2,000 items.
- Google may not return media added by another contributor until it is saved to the signed-in account's library. Canvas cannot enumerate hidden contributor items or prove which source album a Picker item came from. In Google Photos, open the shared album and choose **Save all to library**; saving only the album to the Albums tab does not save its contents. Then start a new Picker session in Canvas.
- Repeating the flow with the same Canvas name adds another batch and refreshes matching persistent Google item IDs. Items saved by earlier sessions remain in the Canvas album because absence from a new Picker selection does not prove that an item left the Google album.
- After the local Canvas album commits, Full Apple Photos access lets Canvas create or reuse one verified Canvas-owned album and add non-duplicate copies there. Canvas never adopts an existing user album solely because its title matches. These assets necessarily also appear in **All Photos**. Limited or denied access is not enough to safely create or verify the dedicated album; the local Google import remains available and the Apple copy can be retried after enabling Full Access.
- To rebuild a saved Canvas album from scratch, delete its saved Canvas copy and import again. This never deletes anything from Google Photos or Apple Photos; an Apple album and assets previously created by Canvas remain under the user's control.
- Exact Google items, identical downloaded bytes, and conservative cross-source metadata matches are deduplicated in playback.
- Google does not expose ongoing shared-album change notifications through Picker. Canvas cannot automatically follow changes; every addition or refresh requires a new explicit Picker session.

Official references: [Picker experience](https://developers.google.com/photos/picker/guides/picking-experience), [Picker session limit](https://developers.google.com/photos/picker/reference/rest/v1/sessions), [Photos API changes](https://developers.google.com/photos/support/updates), and [saving shared photos](https://support.google.com/photos/answer/6131416).
