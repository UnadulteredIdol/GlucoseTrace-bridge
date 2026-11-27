# Changelog

iPhone bridge for [Glucose Trace](https://github.com/UnadulteredIdol/GlucoseTrace). Version numbers match the watch app they go with.

## 2.0 (2026-11-27)

- **Protocol v6: packets are sealed with AES-CCM instead of XTEA** (AES-128 from Apple's CommonCrypto, CCM as in RFC 3610, 4-byte tag). Same packet size, messages and key. Needs Glucose Trace 2.0 on the watch; a 2.0 bridge and a 1.0 watch app do not connect (new characteristic UUID). Your key stays the same.
- Loop age: when the pump refused the last three loop changes (out of reach for about 15 minutes), the loop age now keeps growing to red instead of disappearing.
- A failed Nightscout status request no longer blanks IOB, COB and the loop age: IOB and COB stay for up to 30 minutes, the loop age keeps ageing.
- A rejected Nightscout token now gets its own notification instead of "Can't reach Nightscout". The bridge keeps asking, so fixing the token's role on the site is enough.
- Nonces stay unique after the phone's clock is set back by up to 8 minutes (PROTOCOL.md 4.5).
- The app target now really requires iOS 17 or later, as the README says.

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
