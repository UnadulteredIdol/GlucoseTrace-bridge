# Changelog

iPhone bridge for [Glucose Trace](https://github.com/UnadulteredIdol/GlucoseTrace). Version numbers match the watch app they go with.

## 1.0 (2026-11-26)

First public release, and the first build for TestFlight testers. Developed privately since October 2026.

- Sources: **Nightscout** (glucose, trend, IOB and COB from Trio, Loop or AAPS, loop age from Trio or AAPS) and **LibreLinkUp** (FreeStyle Libre 2 and 3). Dexcom Share is in the code but parked; see the README to switch it on in your own build.
- Sends each reading to the watch over Bluetooth, encrypted and authenticated with your own key (protocol v5).
- Tells the watch why there is no data: no internet, source down, login failed, no new data, no sensor.
- Keeps working in the background once the watch has connected; Bluetooth state restoration lets iOS bring it back. A notification asks you to reopen the app if the watch drops out.
- A refused LibreLinkUp or Dexcom login stops all retries until you start again, so an account is not locked by repeated attempts.
- Passwords, the Nightscout token and the key stay in the iOS Keychain, on this device only.
- iPhone only.
- Debug builds have a *Fault tests* section to check how the watch reacts when the bridge misbehaves.
