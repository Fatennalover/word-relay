<p align="center">
  <img src="assets/word-relay-banner.svg" alt="Word Relay. Live letter scanning and fast, offline suggestions." width="960">
</p>

<p align="center">
  <a href="#downloads"><strong>Download Word Relay</strong></a>
  · <a href="#start-a-match">Quick start</a>
  · <a href="#build-from-source">Build from source</a>
  · <a href="assets/word-relay-mark.svg">Logo</a>
</p>

# Word Relay

Word Relay reads letter tiles and finds English words that start with the full prefix. The bundled dictionary has **106,179 words** and works offline. Choose **1–100 suggestions per batch** and save **up to 100 custom words**.

## Downloads

| Platform | Download | How it works |
| --- | --- | --- |
| **macOS** | [Universal ZIP for macOS 14+](https://github.com/Fatennalover/word-relay/releases/download/v1.4.0/Word-Relay-for-macOS-1.4.0.zip) | Live Roblox scanning, submission tracking, and a shortcut to type an answer |
| **Windows** | [x64 ZIP](https://github.com/Fatennalover/word-relay/releases/download/v1.4.0/Word-Relay-for-Windows-x64-1.4.0.zip) · [ARM64 ZIP](https://github.com/Fatennalover/word-relay/releases/download/v1.4.0/Word-Relay-for-Windows-arm64-1.4.0.zip) | Live Roblox scanning, submission tracking, and a shortcut to type an answer |
| **Android** | [APK for Android 9+](https://github.com/Fatennalover/word-relay/releases/download/v1.4.0/Word-Relay-for-Android-1.4.0.apk) (ARM64 and x64) | Screen sharing, floating suggestions, board tracking, and one-tap marking |
| **iPad** | [Simulator ZIP](https://github.com/Fatennalover/word-relay/releases/download/v1.4.0/Word-Relay-iPad-Simulator-1.4.0.zip) · [Xcode project](ipad/WordRelayPad.xcodeproj) | Screenshot import, typed prefixes, and one-tap marking |

## Start a match

**macOS.** Extract the ZIP, move Word Relay to Applications, and open it alongside Roblox. On macOS 15.2 or later, click **Start** and choose the Roblox window in Apple's window picker. On macOS 14 through 15.1, enable Word Relay under **Privacy & Security → Screen & System Audio Recording**, then quit and reopen it. Enable **Input Monitoring** to track words you submit in Roblox. If an older permission entry still appears on after updating, remove Word Relay from **Input Monitoring**, add the current copy from Applications, and reopen it.

**Windows.** Extract the ZIP for your PC and run `WordRelay.exe`. Keep Roblox visible in the foreground while scanning. The ZIP includes the .NET runtime.

On both desktop apps, use **Control–Shift–S** to start scanning, **Control–Shift–D** to stop, and **Control–Shift–N** for a new match.

On your turn, press **Control–Shift–W** with Roblox in the foreground to type and submit a suggestion. macOS asks for **Accessibility** permission the first time. By default, Word Relay types the letters after the starting tiles. Uncheck **Type only the letters after the prompt** if your game expects the whole word. When the scanner sees an additional red X and the same prompt is still active, it can try another suggestion, up to three attempts per turn.

**Android.** Install the APK and open Word Relay. Tap **Start scan**. Enable **Display over other apps** for floating suggestions, then select Roblox in Android’s sharing dialog. On versions that offer sharing one app, select Roblox to limit the capture to its window. Tap the overlay’s close button, the in-app **Stop scan** button, or the Android sharing notification to stop. Tap a checkmark to mark a suggestion played.

**iPad.** Open the Xcode project and run it on an iPad simulator. Choose **Photos** or **Files** to read the letter tiles from an image, or type the prefix. Tap a checkmark to mark a suggestion played.

<details>
<summary>iPad simulator preview</summary>

<img src="assets/ipad-preview.png" alt="Word Relay on an iPad with five BOX suggestions" width="390">

</details>

## Suggestions and match history

Tap a word to copy it. **Next** cycles through batches of available suggestions. The **Played** counter counts unique words recorded in the current match. Open match history to see which suggestions were shown.

Live scans can count a complete answer from either player when the board shows the word and a matching turn handoff. Desktop apps also track pressing Enter in Roblox when submission tracking is enabled. A detected red X rolls back the rejected submission and skips that answer for the rest of the turn. Use **Undo** in match history to correct a missed rejection. Android and iPad support manual marking from the checkmark or match history.

Live scans keep suggestions visible through brief tile dropouts while the game clock is visible. Live match detection clears history when the game ends, and **New match** resets it manually.

## Build from source

| Platform | Build |
| --- | --- |
| **macOS** | Run `bash build.sh` with Xcode command-line tools. |
| **Windows** | Run `dotnet publish windows/WordRelay.Windows.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true` with .NET 10. Use `win-arm64` for ARM64. |
| **Android** | Install the .NET 10 Android workload, Android SDK 36, and JDK 17 or later. Run `dotnet build android/WordRelay.Android.csproj -c Release`. |
| **iPad** | Open `ipad/WordRelayPad.xcodeproj` in Xcode, select an iPad simulator, and run the **WordRelayPad** scheme. For a physical iPad build, select your development team in **Signing & Capabilities**. |

The dictionary is based on the [English Speller Database](https://github.com/en-wl/wordlist), release 2026.02.25. The license notices for the [dictionary](Resources/ESDB-Copyright.txt) and [Fredoka](Resources/Fredoka-OFL.txt) are included in the source.

Word Relay is an independent companion app. Screen and image recognition run on the device.
