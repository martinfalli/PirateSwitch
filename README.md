# Download Switch

A small macOS menu bar app that cuts [Transmission](https://transmissionbt.com) off the internet whenever your VPN is down. Only Transmission is affected, and it isn't quit: it just can't send or receive a single packet outside the VPN.

## How it works

**1. Kernel binding (the actual kill switch).** The app sets Transmission's hidden `BindAddressIPv4` / `BindAddressIPv6` preferences so every Transmission socket (peers, trackers, DHT, uTP, web seeds) is bound to the VPN's address. The macOS kernel enforces that binding:

- While the VPN is up, packets from that address are only routed through the VPN interface.
- The moment the VPN drops, its address disappears. TCP connections stop sending, UDP sends fail, new connections can't be made, and the IP layer drops anything with that source address (`EADDRNOTAVAIL`). There is no gap to wait out, because none of this depends on the app noticing the VPN drop.

IPv6 is bound to an address that never exists, so Transmission can't use IPv6 at all and nothing can bypass the VPN that way.

**2. Freeze.** Name lookups go through the system resolver, not Transmission's own sockets, so the binding can't stop them. When the VPN drops, the app freezes Transmission (`SIGSTOP`) within milliseconds, so it doesn't even look up a tracker name. Transmission keeps all its state. Its window just stops responding until the VPN is back, and then it's resumed where it was. You can turn this off under **Freeze Transmission While VPN Is Down** if you'd rather keep its window usable. Peers and trackers stay cut off by the binding either way.

**Restarts.** Transmission reads its binding only at launch, so it's restarted in two cases:

- The VPN comes back with a different address. Many WireGuard-based VPNs keep the same one.
- Transmission was started without the binding: before Download Switch was installed, or while the VPN was down.

The restart only happens with the VPN up, and the old Transmission can't reach anything in the meantime.

The VPN is detected automatically as the tunnel interface (`utun`, `ipsec`, `ppp`, `tun`, `wg`…) that currently carries your internet traffic. If that guesses wrong, pick the interface under **VPN Interface** in the menu.

| Icon | Meaning |
| --- | --- |
| Shield with lock | VPN connected, Transmission bound to it |
| Shield with ✕ | VPN down, Transmission cut off |
| Shield with slash | Kill switch turned off |

Notes:
- Quitting Download Switch unfreezes Transmission, but the binding stays: it still only works over the same VPN address. Turn **Kill Switch** off to give Transmission normal internet again.
- On logout/shutdown a frozen Transmission is killed rather than resumed, so it can't contact anything outside the VPN on its way out.

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
