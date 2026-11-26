# Privacy policy: Glucose Trace bridge

Date: 24 November 2026

This policy covers the Glucose Trace bridge app for iPhone. It is based on what the app's code does.

## Summary

- The app has no servers of its own, no analytics, no advertising and no tracking.
- It talks only to the data source you choose, and to your watch over Bluetooth.
- The developer receives no data from the app.

## Network connections

The app contacts only the source you select, and only to fetch your glucose data and, for LibreLinkUp and Dexcom Share, to log in.

- **Nightscout:** the web address you type in. The app requests glucose entries, status and device status (IOB, COB, loop) from it, and sends your token, if you set one, as part of the request. Only https addresses are accepted. The token travels in the web address of each request (`?token=`), as Nightscout expects. The connection is encrypted, but your Nightscout server, or the service hosting it, may record that address in its own logs. Use a token with only the readable role, never your API_SECRET.
- **LibreLinkUp:** `api.libreview.io`, and the regional server it redirects to, `api-<region>.libreview.io`. Your email and password are sent to log in.
- **Dexcom Share** (not offered in the current version; this applies if it is offered again): one of `share2.dexcom.com` (US), `shareous1.dexcom.com` (outside the US) or `share.dexcom.jp` (Japan), depending on the region you choose. Your username and password are sent to log in.

Those services have their own privacy policies. The app contacts no other host.

## Bluetooth

The app sends glucose readings to your watch over Bluetooth. Each packet is encrypted and authenticated with your own 128-bit key. Someone nearby can see that a Bluetooth device is present, but cannot read the readings.

## What is stored on your iPhone

In the iOS Keychain (this device only, not synced to iCloud):
- The bridge key.
- Your LibreLinkUp password.
- Your Dexcom password (only if Dexcom Share is offered and used).
- Your Nightscout token.

In the app's ordinary settings storage (not the Keychain):
- The selected source and units.
- Your Nightscout URL.
- Your LibreLinkUp email and Dexcom username.
- Your Dexcom region (only if Dexcom Share is offered and used).
- A few internal values, such as the last packet counter.

The app does not store a glucose history on the phone. Uninstalling the app removes its ordinary settings. iOS may keep Keychain items (key, passwords, token) after an app is deleted; to remove your passwords and token, empty those fields in the app before deleting it.

The app may show local notifications, for example when the watch disconnects or no new readings arrive. These are created on the phone and are not sent anywhere.

## Workout saving

Saving glucose to a workout is a setting of the watch app, not this app. It is off by default. When on, the watch records glucose into the workout file, which then goes wherever your workouts go (the Suunto app and services you sync to). This app does not do that.

## Your key

The bridge key lives in the Keychain and on your watch app's settings. You can replace it any time with **New key**.

## Medical notice

This app is not a medical device. Do not use it for treatment decisions.

## Contact

glucosetrace@pm.me
