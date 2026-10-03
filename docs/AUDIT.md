# CarCast Hub source and IPA audit

Audit date: 2026-10-03. Inputs: `TDS-Carplay-main(2).zip` and `TDS.Video1.5.ipa.zip` supplied in this workspace. The source, not a decompiled IPA, is the implementation base.

## Source structure

Existing project preserved: `TDS Video.xcodeproj`, shared scheme `TDS Video`, application product `TDS Video.app`. File-system-synchronized groups automatically include new Swift files below `TDS Video/Hub/`. No XcodeGen and no replacement project.

| Target | Original deployment minimum | Treatment |
|---|---|---|
| TDS Video | iOS 17 | New Hub root; original screens retained |
| UploadVideo | iOS 16.5 | Share extension retained |
| ScreenRec | iOS 16.5 | Broadcast upload extension retained |
| ScreenRecSetupUI | iOS 16.5 | Broadcast setup retained |
| Carplayintent | iOS 16.5 | Intent extension retained |
| CarplayintentUI | iOS 16.5 | Intent UI retained |
| SelfAirPlayTunnel | iOS 16.5 | Packet tunnel retained |
| TDSCarPlayControlsWidget | iOS 17 | Activity/widget controls retained |

The project-level deployment setting is 18; the main target overrides it to 17. Lower extension minima do not make the application installable on iOS 15. Build-tool requirements are independent of deployment target. Catalina/Xcode 12 cannot consume this modern project format and APIs.

Stale test-target references were removed from the shared scheme: their IDs had no corresponding native targets. Real parser tests are run explicitly before the CI app build.

## Reusable code kept

| Source area | Function / integration |
|---|---|
| CarPlaySceneDelegate, CarPlayMapView, custom CarPlay controllers | Original private/unsupported CarPlay scene handling |
| CarplayWKWebView, CarPlaySafari, WebBrowser | Original browser and car controls; accessible from original workspace |
| ScreenCaptureManager, ScreenRec, ScreenRecSetupUI | Original capture and broadcast transport |
| Transcoding, VideoToolbox adapters | Existing H.264 / HEVC encoders and decoders |
| TDSSelfAirPlayManager, SelfAirPlayTunnel | Existing self-AirPlay transport |
| TDSAirPlayReceiverManager + AirPlayReceiver dependency | Existing receiver behavior |
| HTTPServer + Swifter | Existing HTTP image stream |
| UploadVideo, SceneDelegate, AppDelegate | Original local/share/deep-link handlers |
| CustomVideoPlayerViewController, TDSVideoShared | Original car player; new IPTV details can send a stream through its callback |

Preserved does **not** mean tested on each OS. The source's iOS-26 warning and private interfaces remain. No claim is made that these interfaces can be signed with a normal free developer account or will work on a stock iPhone.

## New modules

- `HubModels`: common models, M3U/HLS detection, explicit SxxExx grouping, XMLTV parser.
- `HubNetworking`: 64 MB bounded remote reads, Xtream auth/categories/catalogue/details/episodes, stream address generation only at playback, XMLTV.
- `HubStorage`: actor-owned SQLite, indexed paging, parameterized SQL, transactional refresh, Keychain secrets. Xtream credentials are not embedded in catalogue stream URLs.
- `HubStore`: user-visible import lifecycle, cancellation and sanitized errors.
- `HubViews`: home, providers, library, details, seasons, local picker, car links, settings.
- `HubPlayer`: AVPlayerViewController, ready-state resume, progress persistence, previous/next within loaded queue, ten-second skips, aspect fit/fill.
- `HubBrowser`: independent WKWebView, bounded 500-entry bookmarks/history files, native User-Agent. No false DRM switch.

Photos videos are copied to a temporary file for playback and removed on dismissal. Files picker retains security-scoped access during playback. Browser data and media metadata stay local; artwork and provider requests necessarily contact their respective hosts. M3U links can contain tokens and are stored inside the protected application container. Database is excluded from backups; provider credentials use ThisDeviceOnly Keychain storage. Removing a provider deletes its credentials.

## Deliberate integration changes

- Main display name `CarCast Hub`, version 0.1/build 6; target/scheme/product names unchanged for stable build wiring.
- Bundle base `com.ali.carcasthub`; groups changed consistently to `group.com.ali.carcasthub.shared` and `.auth` across all references. This is a separate app identity, not a migration of installed TDS data. Original URL schemes remain to preserve Share behavior; avoid installing two apps competing for the same legacy scheme when testing Share.
- Removed original developer team from build settings. Retained entitlement capabilities for review at signing time; the CI build grants none of them.
- Original device/location telemetry method made a no-op. The supplied source already had its payment gate disabled; no new purchase bypass was implemented.
- URL-bearing one-line diagnostic messages were redacted to avoid leaking provider links.
- Added background audio and HTTP transport compatibility for user-entered legacy IPTV servers. HTTP credentials are unencrypted in transit; prefer HTTPS.
- Retained the original app artwork and original source attribution. UI layout is new, not a copy of APTV/Tubo.
- AirPlay package pinned to the revision in the supplied lockfile; Swifter remains 1.5.0. Availability of the AirPlay package was not established in this environment; resolve-package logs are retained if it is unavailable.

## IPA comparison

Despite its filename, the supplied app reports **version 1.2**, not 1.5; bundle ID `net.thomasdye.TDS-Video4`, minimum OS 17. It contains only five extensions: UploadVideo, ScreenRec, ScreenRecSetupUI, Carplayintent, CarplayintentUI. The source additionally contains SelfAirPlayTunnel and TDSCarPlayControlsWidget, so the IPA cannot prove those newer parts work.

The supplied executable's Mach-O encryption flag is zero. No decryption or binary modification was performed. Signed entitlements in that IPA differ from the broader source entitlements. Its signature/permissions cannot be transferred to the new app by renaming or repackaging it. See `IPA-METADATA.json` for the static inventory.

## Scope still requiring work

The added implementation is ready for its first compiler/device validation pass, not a verified finished player. Pending: actual Xcode build, endpoint fixture tests for Xtream, SQLite integration tests on iOS, signed installation, real provider test matrix, memory profiling, car hardware tests, audio capture/muxing and synchronization, iOS-15 backport, libVLC evaluation for unsupported formats, compressed XMLTV, complete manual quality selection, migration/import-export, and automatic continuation to the next episode. No Emby integration is included.

Netflix/TOD/STARZPLAY are quick links only, not declared integrations. A WebView, UA string, successful login, or FairPlay capability probe does not prove the provider issues playback licenses to that environment. No DRM bypass or proprietary-source copying is involved.

## Build environment references (checked 2026-10-03)

- GitHub runner inventory lists Xcode 26.3 at `/Applications/Xcode_26.3.app` on `macos-15`: https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md
- Apple Xcode requirements: https://developer.apple.com/xcode/system-requirements
- Original code usage notice: `TDS-ORIGINAL-README.md`.

Workflow builds only on explicit dispatch, uses read-only repository permission, saves failure logs, and packages only a physical-device app after verifying all seven extensions. There are no signing certificates, Apple IDs, provider accounts, repository secrets or binaries from the reference IPA in this delivery.
