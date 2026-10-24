# EasyPrivacy Files

An independently installable Android/Windows/Linux application with Send, Sync,
and Drive surfaces. It uses the Core SDK for authorized connection status and
will use Core's private stream broker for service data.

The current development build provides the app structure and mode navigation.
The SDK stream bridge is implemented and tested against the native runtime.
Send, Sync, and Drive remain unavailable until their engine adapters and device
integration have passed their implementation gates. No file server is
installed or represented as healthy by this shell.

From the repository root:
    flutter pub get
    ./tool/build-android.ps1 -App files -Debug
    ./tool/build-windows.ps1 -App files
    bash tool/build-linux.sh files
