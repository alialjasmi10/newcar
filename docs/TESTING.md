# Validation and device test record

## Actually performed in delivery environment

- Parsed the OpenStep project; checked all eight native targets and seven embedded extensions.
- Checked referenced entitlements, Info.plists, bridging header, shared-scheme identifiers and XML resources.
- Parsed plist/entitlements/resource JSON files and checked shell syntax for both scripts.
- Reviewed new data flow: secrets in Keychain; parameterized SQLite; actor-owned database; bounded feeds; transactional replacement; no provider URL diagnostics.
- Static inspection of supplied IPA metadata/entitlements/Mach-O structure. No IPA code executed or decrypted.

**Not performed:** Swift compilation, Xcode build, parser binary execution, simulator UI, real provider login, hardware playback, installation/signing, car connection, audio synchronization. No successful build is claimed.

## Automated checks on the included workflow

1. Swift parser fixtures run on the Mac runner: invalid feed, UTF-8 BOM, quoted commas, relative links, deduplication, 20,000 entries, M3U series hierarchy, HLS manifest detection, XMLTV timestamps/title entities.
2. Resolve pinned package versions, build the original shared scheme for a physical iOS device, including its target dependencies.
3. Check device platform, arm64, app identifier and presence of all seven `.appex` products before creating IPA.
4. Save logs even when a step fails. The workflow has no Apple-account credentials and does not sign or publish anything.

## First hardware pass — mark results, don't assume success

| Test | Expected / what to record | Status |
|---|---|---|
| Install and launch | Correct signing route; all required app groups/entitlements | Pending |
| Xtream valid / invalid / expired | Clear error, no partial replacement of existing catalogue | Pending |
| Slow server / no internet / cancel | Responsive UI, old catalogue intact | Pending |
| 20k real M3U | Import time, peak memory, responsive scrolling | Pending |
| Movie resume | Stop at 42 min, reopen after force close, seek near 42 min | Pending |
| Series | Correct season and episode order; progress/checkmark | Pending |
| EPG | Provider's tvg-id match, current/upcoming time in local zone | Pending |
| Live / previous / next | Change among loaded channels, note any buffer stall | Pending |
| Track / subtitles / quality | Only provider-supplied tracks; HLS automatic adaptation | Pending |
| Files / Photos / Share | Local video accessible, extension launch and handoff | Pending |
| Browser | Navigate, back/forward, save/reopen bookmark, provider errors | Pending |
| Background / PiP / interruption | Phone call, headphones removed, app return, audio session | Pending |
| Rotation / memory pressure | Landscape, dismissal, repeated channel switching | Pending |
| AirPlay | Receiver discovery, codec support, video/audio timing | Pending |
| CarPlay | Original session attach and send-to-car callback on each OS | Pending |
| USB-C mirroring | V27 parked, identify mirroring vs ReplayKit vs AirPlay path | Pending |

Audio investigation: first play the same unprotected local MP4 for five minutes on phone, then the existing USB-C output route. Record route, frame rate, connection, output audio device, drops and drift. Compare with original TDS on the same route. Do not alter video encoder timing or inject guessed audio buffering until we can reproduce the defect. The original ReplayKit extension has no audio encoder at all; adding synchronized audio is a separate implementation task.
