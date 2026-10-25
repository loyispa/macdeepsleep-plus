# macdeepsleep-plus

Cut the network when the lid closes, restore it when the lid opens. Fixes the fast
battery drain MacBooks show while sleeping with the lid shut.

## Features

- **Lid closed** — powers off the Wi-Fi radio and brings down `awdl0` (the AirDrop /
  Continuity peer-to-peer interface). Bluetooth is optional.
- **Lid opened** — restores exactly what was on before.
- **Dark wakes are ignored** — the network stays off while the lid is shut, so a
  maintenance wake cannot undo the work.
- **Idle sleep with the lid open is untouched** — walking away without closing the
  lid does not cut your network.
- **Crash safe** — the cut state is persisted, so a forced reboot or a crash is
  recovered on the next start.

## Install

Requires the Command Line Tools: `xcode-select --install`

```bash
sudo bash setup.sh --install
```

What gets installed:

| Path | Purpose |
|---|---|
| `/usr/local/bin/macdeepsleep` | executable |
| `/usr/local/etc/macdeepsleep.conf` | configuration |
| `/Library/LaunchDaemons/com.local.macdeepsleep.plist` | launchd daemon |
| `/var/log/macdeepsleep.log` | log |

Configuration:

```ini
disable_bluetooth=0   # 1 = also power off Bluetooth while sleeping
disable_awdl=1        # 1 = also bring down awdl0 while sleeping
```

Apply changes by restarting the daemon:

```bash
sudo launchctl kickstart -k system/com.local.macdeepsleep
```

## Uninstall

```bash
sudo bash setup.sh --uninstall
```

Stops the daemon, removes the plist and the executable, clears the state file, and
makes sure Wi-Fi is left powered on.

## Status

```bash
/usr/local/bin/macdeepsleep --status
```

## License

MIT
