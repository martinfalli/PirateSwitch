# Download Switch

A small macOS menu bar app that acts as a VPN kill switch for [Transmission](https://transmissionbt.com).
Transmission can only use the VPN. If the VPN drops, Transmission is stopped and can't be reopened until the VPN is back.

## How it works

Two layers:

1. **Binding.** The app writes Transmission's hidden `BindAddressIPv4` / `BindAddressIPv6` preferences, so every Transmission socket (peers, trackers, DHT) is bound to the VPN's address. When the VPN goes away that address no longer exists, so nothing can connect. IPv6 is blocked unless the VPN has its own IPv6 address.
2. **Watchdog.** Every second (and immediately on network changes or when Transmission launches) it checks the VPN:
   - VPN down: Transmission is force-quit and blocked from starting.
   - VPN back: Transmission is reopened (optional) with the new address.
   - VPN address changed: Transmission is restarted so it binds to the new one.

The VPN is detected automatically as the tunnel interface (`utun`, `ipsec`, `ppp`, `tun`, `wg`…) that currently carries your internet traffic. If that guesses wrong (e.g. you run several tunnels), pick the interface under **VPN Interface** in the menu.

| Icon | Meaning |
| --- | --- |
| Shield with lock | VPN connected, Transmission allowed |
| Shield with ✕ | VPN down, Transmission blocked |
| Shield with slash | Kill switch turned off |

Notes:
- Only Transmission is affected. The rest of your Mac keeps its normal internet.
- Transmission is force-quit (a normal quit can hang on its "active transfers" dialog). It saves progress periodically, so at worst a few minutes of download is re-fetched.
- Quitting Download Switch leaves the binding in place, so Transmission still only works with the same VPN address. Turn **Kill Switch** off first to give Transmission normal internet again.

## Install

Requires macOS 13+ and Xcode (or the Xcode command line tools).

```sh
scripts/build-app.sh --install
```

This builds `build/Download Switch.app`, copies it to `/Applications` and opens it. It turns on **Launch at Login** on first run (toggle it in the menu).

A prebuilt zip is also attached to each [GitHub Actions run](../../actions). It's ad-hoc signed, so macOS will block it the first time: open it, then allow it in **System Settings → Privacy & Security → Open Anyway**.

## Uninstall

Turn **Kill Switch** off (this removes the binding from Transmission), quit the app and delete it. If you deleted it first, run:

```sh
defaults delete org.m0k.transmission BindAddressIPv4
defaults delete org.m0k.transmission BindAddressIPv6
```

## Development

```sh
swift test                 # decision logic tests
swift run DownloadSwitch   # run without bundling (no notifications)
```

`Sources/DownloadSwitchCore` holds the pure logic (VPN detection, kill switch state machine); `Sources/DownloadSwitch` is the AppKit menu bar app.
