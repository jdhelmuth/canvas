# Canvas privacy policy

Last updated: August 11, 2026

Canvas is a private iPad photo frame. No account or login is required to use
the Apple Photos features.

## Information Canvas accesses

- Canvas reads only the Apple Photos albums and media that you authorize. For
  an explicit Google Photos import, Full Photos access also permits Canvas to
  add a non-destructive copy to a verified Canvas-owned Apple Photos album.
  Canvas never deletes or replaces Apple Photos assets or albums and never
  adopts an existing album solely because its title matches.
- Canvas stores settings, exclusions, imported local audio, and selected
  Google Photos media on the iPad in its app container.
- If you explicitly use Google Photos, Canvas opens Google’s supported Picker
  flow. Google handles that authorization and selection. Canvas stores OAuth
  tokens in the iPad Keychain and downloads only the media you select for local
  playback. Limited or denied Photos access does not discard a local Google
  import; it leaves the optional Apple Photos copy pending until Full Access
  is granted. Google Photos is optional; Apple Photos remains usable without it.
- Canvas may display location metadata already present in an authorized photo.
  When you opt into current weather, Canvas requests When In Use location
  permission and sends the current coordinates to Apple's WeatherKit to obtain
  local conditions. For AQI, Canvas rounds the coordinates to two decimal
  places (approximately one-kilometer precision) and sends that approximate
  location to Open-Meteo, whose air-quality forecast is based on Copernicus
  Atmosphere Monitoring Service (CAMS) data. Canvas stores only the last
  combined weather snapshot locally so it can label it as last known when the
  network or service is unavailable.

Canvas does not operate a server for your media, and does not include
analytics, advertising, tracking, or data brokerage.

## Storage and deletion

Canvas data stays in the app’s local container. Disconnect Google Photos from
Canvas to remove its saved authorization. Deleting Canvas removes its local
settings, exclusions, imported audio, downloaded Google Photos media, and
stored tokens; it does not remove anything from Apple Photos or Google Photos.
Deleting a saved Canvas Google copy also does not remove its Apple Photos
album or assets.

## Third parties

Apple system frameworks provide Photos, media playback, Keychain, local
storage, and WeatherKit. Google receives information necessary for the
optional Google Photos Picker and OAuth flow when you choose that feature.
Open-Meteo receives the approximate coordinates needed for optional AQI data;
its free API may retain technical logs, including those coordinates, for up to
90 days. Canvas does not send your media to any Canvas-operated service.

## Contact

For privacy questions or deletion requests, use the support page:

<https://jdhelmuth.github.io/canvas/support.html>
