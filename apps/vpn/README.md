# EasyPrivacy VPN

The optional Android/Windows Internet VPN application. Core manages enrollment;
VPN generates and stores its own traffic keys and requests authorized profiles
through the shared Core SDK. Enable VPN access under Connected applications in
Core. A local Disconnect remains available during Core outages.

The inherited system tunnel, Android notifications, and Windows tray are in
packages/easyprivacy_vpn_feature/ and this app's native runners.

From the repository root:
    flutter pub get
    ./tool/build-android.ps1 -App vpn -Debug
    ./tool/build-windows.ps1 -App vpn

Build the Windows helper first with tool/build-vpn-windows.sh in WSL.
This is a development split. Core temporarily retains Previous VPN connection
controls for migration. Do not connect both legacy and new clients concurrently.
Core now hosts the private service data plane; Files engines remain future work.
On Android this VPN excludes Core so its encrypted service connection remains
independent. A physical smoke test passed with both private and Internet
connections active.
Core also passed Wi-Fi/mobile handovers with Proton VPN active. Extended
recovery and further provider/settings combinations remain to be tested.
