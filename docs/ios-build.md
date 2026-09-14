# iOS build and installation

## Scope and compatibility audit

The iOS target is configured for iOS 13.0 or later. Camera, image picker, photo library, Baidu map/location, local notifications, and Easemob IM have iOS plugin support in the project's current dependency set. The iOS app requests location only while in use.

`flutter_foreground_task` is intentionally used only on Android. iOS does not permit a general Android-style foreground service or unrestricted WebSocket keep-alive. The Rain Classroom WebSocket remains active while its page is foregrounded; when iOS suspends the app, the operating system controls background behavior.

## CI artifact and signing

The workflow produces an **unsigned** IPA and requires no Apple signing secrets. It is a build artifact for later signing, validation, or distribution through the account owner's chosen Apple-supported process. An unsigned IPA cannot be installed directly on an iPhone.

Run **Build unsigned iOS IPA** from the Actions tab, then download `course_helper-ios-unsigned-ipa`. Before device installation, sign the IPA with your own certificate and provisioning profile; keep those materials outside the repository.

## Validation order

1. Run `flutter pub get` and `flutter build ios --release --no-codesign` on macOS to check compilation.
2. Run the workflow and download the unsigned artifact.
3. Sign the artifact using your own Apple Developer process before installing it on a registered device.
4. Check login, course list, normal and location sign-in, camera/QR scan, image upload, local notifications, and IM.
