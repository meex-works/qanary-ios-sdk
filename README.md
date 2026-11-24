# Qanary SDK for iOS

The SDK that goes inside an app being tested on [Qanary](https://qanaries.com), the marketplace for paid app testing.
It measures how testers use your app during a Qanary test, which is what they're paid for and what your struggle
ranking is built from. For everyone else it does nothing: it records only after your app was opened from the Qanary
app for a test.

Swift, iOS 13 and later, no dependencies. The Android SDK is at [qanaries.com/developers/sdk](https://qanaries.com/developers/sdk).

## 1. Install

In Xcode: **File → Add Package Dependencies…**, enter `https://github.com/meex-works/qanary-ios-sdk`, choose
**Up to Next Major Version** from `0.1.0`, and add the **Qanary** library to your app target.

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/meex-works/qanary-ios-sdk", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "Qanary", package: "qanary-ios-sdk")]),
]
```

## 2. Give your app a URL scheme

Qanary opens your app with `<your scheme>://qanary?session=…`. If your app doesn't have a URL scheme yet, add one:
select your target → **Info** → **URL Types** → **+**, and set **URL Schemes** to a name of your own, e.g. `myapp`.
In `Info.plist` that is:

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLSchemes</key>
        <array><string>myapp</string></array>
    </dict>
</array>
```

Then enter the same scheme in the [Qanary console](https://qanaries.com/console): **Your apps** → **Edit** →
**iPhone URL scheme**, next to your App Store link.

## 3. Start it, and give it the links your app opens

SwiftUI:

```swift
import Qanary

@main
struct MyApp: App {
    init() { Qanary.start() }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    if Qanary.handle(url) { return }   // a Qanary link: nothing else to do with it
                    // your own deep links here
                }
        }
    }
}
```

UIKit with scenes:

```swift
// AppDelegate
func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    Qanary.start()
    return true
}

// SceneDelegate: a cold launch from a link arrives in connectionOptions, a warm one in openURLContexts.
func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    Qanary.handle(connectionOptions.urlContexts)
}

func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    Qanary.handle(URLContexts)
}
```

UIKit without scenes: call `Qanary.handle(url)` in `application(_:open:options:)`.

`handle` returns `true` for a Qanary link and `false` for any other URL, so it sits in front of your own link handling.

## 4. Screens, fields and errors

- **Screens.** UIKit view controllers are named automatically by their class. SwiftUI has no view controllers of
  yours to watch, so name the screens that matter:

  ```swift
  CheckoutView().qanaryScreen("Checkout")
  ```

  Or call `Qanary.screen("Checkout")` yourself.
- **Text fields.** `UITextField` and `UITextView`, and SwiftUI's `TextField`, are counted automatically: how many times
  each was edited, cleared or abandoned. Never the text. A field is named by its `accessibilityIdentifier`, else its
  placeholder. For a field the SDK can't see, report it when it loses focus:

  ```swift
  Qanary.field("promo-code", edits: edits, clears: clears)
  Qanary.fieldAbandoned("promo-code")   // typed in, then left empty
  ```

- **Crashes and freezes** (the main thread blocked for 5 seconds) are recorded automatically.
- **Failed requests.** Report the status only, never the URL or the body:

  ```swift
  do {
      let (data, response) = try await URLSession.shared.data(for: request)
      if let http = response as? HTTPURLResponse, http.statusCode >= 500 { Qanary.requestFailed(http.statusCode) }
      // …
  } catch let error as URLError {
      Qanary.requestFailed(0)   // no response at all
      throw error
  }
  ```

- **Tasks (optional).** Mark a test task done from inside your app with `Qanary.task("task_1", "done")`. Task ids are
  `task_1`, `task_2`, … in the order you list your tasks in the console.

## 5. Verify your build

A test opens only once the SDK has reported from your build, because testers are paid for the use it measures. In
the [console](https://qanaries.com/console), go to **Your apps** and choose **Verify the SDK on iPhone**. Install
your build on an iPhone or the Simulator, open the link the console shows (on a phone, send it to yourself and tap
it; on the Simulator, `xcrun simctl openurl booted '<link>'`), and use the app for a few seconds. The check turns ✓
and lists the screens it saw. It uses no paid slot and expires after a day.

Testers install your **App Store** version: Apple doesn't allow paid testers on TestFlight builds. So the SDK has to
ship in the build that's live on the App Store.

To watch it work, set `Qanary.debug = true` before `start()` and filter Console (or Xcode's console) by the subsystem
`com.qanaries.sdk`. Session tokens are never logged.

## What it records

- **When:** only after your app was opened from the Qanary app for a test (or by your own verify link). It stops when
  that tester's work is done: their report is in, the test closes, or their claim expires; after 15 days at most; or
  when you call `Qanary.stop()`. Your other users are never recorded.
- **What:** screens viewed and time on each, rage taps (fast repeated taps in one spot), how many times each field was
  edited, cleared or abandoned (counts only), failed request status codes you report, crashes (the exception name or
  signal and your app's top frame) and freezes, app in front or behind, the device model, iOS version and your app's
  version.
- **Never:** text typed into fields, screenshots, contacts, location, the advertising identifier or any other
  identifier, or anything outside your app. Qanary's server refuses event data that tries to carry field contents.

It sends to `https://api.qanaries.com` only, keeps a small queue in your app's Application Support folder (excluded
from backups), and uses no `UserDefaults`.

## App Store privacy

The package includes a privacy manifest (`PrivacyInfo.xcprivacy`), which Xcode merges into your app's privacy report.
It declares **Product Interaction**, **Crash Data**, **Performance Data** and **Other Diagnostic Data**: collected, not
linked to the person, not used for tracking, used for analytics and app functionality. It also declares one
required-reason API, system boot time (reason `35F9.1`), used to time events within a launch.

In App Store Connect → **App Privacy**, declare the same data types the same way. A sentence you can adapt for your
privacy policy:

> When you join a paid test through Qanary (qanaries.com), the Qanary SDK in this app records how you use it during
> that test: screens viewed, taps, how many times fields were edited (never what you typed), crashes and freezes. It
> sends this to Qanary so we can see where the app is hard to use. It records nothing unless you opened the app from
> the Qanary app for a test.

This is guidance, not legal advice; your own counsel decides what your disclosures say.

## Requirements

- iOS 13 or later; Swift 5.9 (Xcode 15) or later.
- No dependencies beyond the system frameworks. No permissions to ask for.

Questions: [hello@qanaries.com](mailto:hello@qanaries.com). License: free to use in apps tested with Qanary; see
[LICENSE](LICENSE).
