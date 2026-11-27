# Glucose Trace Bridge (iOS)

An iPhone app that sends your CGM glucose to the **[Glucose Trace](https://github.com/UnadulteredIdol/GlucoseTrace)** SuuntoPlus app on your Suunto watch. It fetches each new reading from your data source and passes it to the watch over Bluetooth, encrypted with a key only your watch has.

> [!IMPORTANT]
> **Not a medical device.** Experimental software, not approved for treatment decisions. Never rely on it as your only source of glucose information: confirm with your CGM app or a meter. Readings can be delayed or missing. Use it at your own risk.

## Data sources

| Source | What you enter | What the watch gets |
|---|---|---|
| **Nightscout** | site URL and an access token with only the *readable* role (Admin Tools → Subjects), never your API_SECRET | glucose, trend, rate; IOB and COB from an AID app (Trio, Loop, AAPS); loop age from Trio and AAPS |
| **LibreLinkUp** (FreeStyle Libre 2 and 3) | the email and password of a LibreLinkUp follower account that your Libre app shares with (your own works). Accept its terms once in the LibreLinkUp app | glucose and trend |
| **Dexcom Share** (G6, G7, ONE+), *not offered yet* | your own Dexcom login and region. If your email is refused, use your phone number with + and country code. In the Dexcom app, switch Share on and invite at least one follower | glucose and trend |

- **Dexcom Share is parked:** the code is still there, but the app doesn't offer it until a tester can actually test it. To switch it on in your own build, add `.dexcomShare` to `DataSource.offered` in `Manager/GlucoseBridgeManager.swift`.
- **LibreLinkUp and Dexcom Share** are unofficial connections that Abbott and Dexcom can change or block without notice.
  - LibreLinkUp is asked at most once a minute, also when the watch reconnects or you tap Refresh. Dexcom Share is asked only for what's new since the last reading.
  - A refused login stops all retries until you press Stop and Start again. The watch shows *Login failed* at once.
- **CGM only logging** (Nightscout, on by default): ignores insulin and carbs logged by hand in Nightscout, so people who log nothing don't see "IOB 0.0U" on the watch. Turn it off if you log your injections in Nightscout. An AID app's IOB and COB, and the loop age from Trio or AAPS, are always shown.

Passwords and the Nightscout token are stored in the iOS Keychain, on device only.

## Install

Invited testers get the bridge through TestFlight. Everyone else builds it with Xcode (the [install guide](https://github.com/UnadulteredIdol/GlucoseTrace/blob/main/INSTALL.md) covers the bridge and the watch app together):

1. You need a Mac with Xcode 26.4 or later and an iPhone with **iOS 17** or later (tested on iOS 26). The app is iPhone only.
2. Clone this repo and open `Glucose Trace.xcodeproj`.
3. Select the **Glucose Trace** target, open **Signing & Capabilities**:
   - choose your **Team** (your Apple ID, added under Xcode → Settings → Accounts);
   - change the **Bundle Identifier** to something of your own, for example `com.yourname.glucosetrace`.

   The project ships with no Team set, so both are needed.
4. Connect your iPhone, select it as the run destination and press **Run**. The first time, turn on Developer Mode on the iPhone (Settings → Privacy & Security) and trust your developer certificate (Settings → General → VPN & Device Management).

With a free Apple account the app stops opening after 7 days; build it again then. A paid developer account makes it last a year.

## Use

1. Choose your data source and enter its login.
2. Copy the **watch key** (Copy keeps it on this phone and clears it after 2 minutes), put it in `settings.bridgeKey` in `watch/data.json`, and deploy the watch app again. A sideloaded app gets its settings only from `data.json`, and a full sync from the Suunto app removes it.
   - Once Glucose Trace is in the SuuntoPlus store: paste the key into its **Bridge key** setting in the Suunto app instead, then sync the watch.
3. Tap **Start bridge**. It fetches your latest reading and starts advertising.
4. Start the workout with Glucose Trace on the watch. **Keep this app on screen until the watch shows a reading**; the screen stays on until then. After that the phone can lock.

**Why the app must be open to connect:** a backgrounded iOS app's Bluetooth advertisement is hidden from non-Apple devices, so the watch can't find the phone then. An existing connection keeps working in the background: the watch's regular reads wake the app. If the watch drops out (out of range, for example), you get a notification to open the app again.

**When data stops:** after 10 minutes without a new reading you get one notification saying whether the source can't be reached or has nothing new. The watch shows the reason on its IOB/COB line: *No internet*, *Source down*, *Login failed*, *No new data*, *No sensor* or *Bridge off*.

Only one bridge can run at a time (they share the Bluetooth service): don't run this app together with another Glucose Trace bridge.

## For developers

- [`Glucose Trace/BridgeSecurity.swift`](Glucose%20Trace/BridgeSecurity.swift): packet sealing (AES-128-CCM, using Apple's AES from CommonCrypto) and the protocol messages (`BridgeMessage`). The reference implementation of [PROTOCOL.md](https://github.com/UnadulteredIdol/GlucoseTrace/blob/main/PROTOCOL.md); the watch repo's test harness compiles against this file.
- [`Glucose Trace/CloudSources.swift`](Glucose%20Trace/CloudSources.swift): the LibreLinkUp and Dexcom Share clients (`DataSource.offered` decides which sources the app shows).
- [`Manager/GlucoseBridgeManager.swift`](Manager/GlucoseBridgeManager.swift): polling, Nightscout, the BLE peripheral, state restoration and the watch status.
- Debug builds have a **Fault tests** section that makes the bridge misbehave on purpose for a set time (hang while connected, lose its Bluetooth service, hide from the watch, answer slowly) to check how the watch reacts. Release builds leave it out.

Writing a bridge for another platform: follow PROTOCOL.md and check your packets against its test vectors.

## Privacy

See [PRIVACY.md](PRIVACY.md).

## Support

Questions, bugs or ideas: open an issue, or mail glucosetrace@pm.me.

## Licence

MIT, see [LICENSE](LICENSE). An independent project, not affiliated with Suunto, Abbott, Dexcom or the Nightscout project.
