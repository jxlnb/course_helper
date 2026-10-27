# iOS build and installation

This document covers the iOS fork maintained in `jxlnb/course_helper`, which tracks
upstream `AneryCoft/course_helper` with a small set of iOS-specific patches applied.

## Compatibility scope

The Podfile declares `platform :ios, '15.0'` (upstream raised it from 13.0 in v1.2.2),
so iOS 15 or later is required. Camera, image picker, photo library, Baidu
map/location, local notifications, and Easemob IM all have iOS plugin support in the
project's current dependency set. The app requests location only while in use.

`flutter_foreground_task` is intentionally used only on Android. iOS does not permit a
general Android-style foreground service or unrestricted WebSocket keep-alive. The
Rain Classroom WebSocket remains active while its page is foregrounded; when iOS
suspends the app, the operating system controls background behavior.

## Fork-specific patches

These are the deltas this fork keeps on top of upstream. Do not drop them when
re-syncing upstream code:

| File | Patch | Why |
| --- | --- | --- |
| `lib/main.dart` | own Baidu AK constant | upstream ships its own AK bound to `com.anerycoft.coursehelper` |
| `ios/Runner.xcodeproj/project.pbxproj` | `PRODUCT_BUNDLE_IDENTIFIER = com.jxlnb.coursehelper` | must match the Baidu security code |
| `ios/Runner/Info.plist` | `NSMicrophoneUsageDescription` | defensive; upstream dropped it |
| `lib/pages/widget/baidu_map.dart` | SDK-address fallback, `isNeedNewVersionRgc` for iOS, 6s reverse-geocode timeout | avoids showing "未知位置" when reverse geocoding fails |
| `.github/workflows/ios.yml` | unsigned IPA build with retries + CocoaPods cache | upstream has no iOS workflow |

## Baidu AK and the security code

The AK is set at runtime in `lib/main.dart`; neither Baidu plugin reads `Info.plist`.

An iOS Baidu AK is validated against the **security code (安全码)** registered in the
Baidu console, which must equal the bundle identifier the app actually runs under.
Self-signing tools may append the Apple Team ID, for example:

```
compiled bundle id : com.jxlnb.coursehelper
signed bundle id   : com.jxlnb.coursehelper.FX444HYBRA   <- what Baidu must be told
```

If the two differ, map tiles still render but location authorization is rejected by
the server, producing `BMKLocationAuthErrorNetworkFailed` and an empty address.
Register the signed bundle identifier, not the compiled one.

## CI artifact and signing

The workflow produces an **unsigned** IPA and requires no Apple signing secrets. It is
a build artifact for later signing, validation, or distribution through the account
owner's chosen Apple-supported process. An unsigned IPA cannot be installed directly
on an iPhone.

Run **Build unsigned iOS IPA** from the Actions tab, then download
`course_helper-ios-unsigned-ipa`. Artifacts expire after 14 days; re-run the workflow
to rebuild. Optionally pass the `release_tag` input to also attach the IPA to a GitHub
Release for longer retention.

Before device installation, sign the IPA with your own certificate and provisioning
profile; keep those materials outside the repository.

## Validation order

1. Run `flutter pub get` and `flutter build ios --release --no-codesign` on macOS to check compilation.
2. Run the workflow and download the unsigned artifact.
3. Sign the artifact using your own Apple signing process.
4. On the device check, in order: login, multi-account switching, course list, course
   detail, local database persistence (kill and relaunch), normal and location
   sign-in, camera/QR scan, image upload, local notifications, and IM.
