# iOS build and installation

## Scope and compatibility audit

The iOS target is configured for iOS 13.0 or later. Camera, image picker, photo library, Baidu map/location, local notifications, and Easemob IM have iOS plugin support in the project's current dependency set. The iOS app requests location only while in use.

`flutter_foreground_task` is intentionally used only on Android. iOS does not permit a general Android-style foreground service or unrestricted WebSocket keep-alive. The Rain Classroom WebSocket remains active while its page is foregrounded; when iOS suspends the app, the operating system controls background behavior.

## GitHub Actions secrets

Create these repository secrets; never commit the original files:

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_BASE64` | Base64 of a development `.p12` certificate |
| `APPLE_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` |
| `PROVISIONING_PROFILE_BASE64` | Base64 of the matching development `.mobileprovision` |
| `KEYCHAIN_PASSWORD` | A random, CI-only keychain password |
| `APPLE_TEAM_ID` | Apple Developer Team ID |

The provisioning profile's App ID must match the bundle identifier in `ios/Runner.xcodeproj/project.pbxproj` (`com.example.chaoxingSignin`) until the project owner changes it to their own unique identifier. Update the identifier in all Runner build configurations before creating the App ID and profile.

## Signing and installation

The workflow creates a **development-signed** IPA. It may be installed only on devices registered in the development provisioning profile. Development certificates and profiles normally expire after one year; rebuild with renewed signing material before expiry. The Apple Developer account holder needs permission to create certificates, registered devices, App IDs, and provisioning profiles.

Run **Build signed iOS IPA** from the Actions tab, then download `course_helper-ios-ipa`. On Windows, install the IPA only through an Apple-supported development-device workflow that accepts the signed IPA and the registered device (for example, Apple Configurator on a Mac is the usual path). TestFlight is not required by this workflow and it does not bypass Apple signing or device-registration rules.

## Validation order

1. Run `flutter pub get` and `flutter build ios --release --no-codesign` on macOS to check compilation.
2. Add the secrets above and run the workflow.
3. Download the artifact and install it on a registered device.
4. Check login, course list, normal and location sign-in, camera/QR scan, image upload, local notifications, and IM.
