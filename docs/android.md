# Kore on Android

The phone app shows the chats on your Mac and your boxes over KoreNet. It needs Android 12 or later.

## Install

Download `kore.apk` from the [latest release](https://github.com/SoumilB7/kore/releases/latest) and open it. Android asks you to allow installs from your browser once.

Every release APK is signed with one certificate. Its SHA-256 is:

```
E9:18:81:D1:CA:84:81:1C:F5:34:3A:F6:B8:FD:51:2C:ED:66:0C:C8:76:C5:15:D4:E4:F6:E0:C5:C6:F1:89:6F
```

`apksigner verify --print-certs kore.apk` prints the same value for a genuine APK.

## Updates

- The app checks the latest release when it opens, at most once a day. A newer version shows in Settings.
- Before Android's installer sees an update, the app checks three things:
  - `SHA256SUMS` is signed with Kore's release key, which is compiled into the app;
  - the downloaded `kore.apk` matches its hash in `SHA256SUMS`;
  - the APK is signed with this app's certificate and with the release certificate above.
- An older version is never offered.
- An app built and signed with a debug key doesn't update from a release. Uninstall it, then install the release APK; later updates install in place.
