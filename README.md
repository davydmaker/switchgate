# SwitchGate

Network gateway proxy that routes your Nintendo Switch traffic through your PC's network connection. This enables the Switch to access VPNs, virtual LANs, and other networks it can't reach on its own.

## Use Cases

### Nintendo Cloud Games via VPN
Some Nintendo Switch games are available as [Cloud Versions](https://pt-americas-support.nintendo.com/app/answers/detail/a_id/53750) — they run on Nintendo's servers and are streamed to your Switch (e.g. Control, Hitman 3, A Plague Tale). However, these titles are **region-locked** and only available in select regions. Even if you change your account region, the latency to a distant server makes them unplayable.

With SwitchGate, you connect your PC to a VPN server in the supported region and route the Switch traffic through it. This way the Switch gets both **access** to the cloud game and a **low-latency route** to the streaming server.

### Virtual LAN with Friends (Hamachi, Radmin VPN, ZeroTier, etc.)
Connect your PC to a virtual LAN tool and use SwitchGate to bridge your Switch into that network. This unlocks **local connection features** over the internet:

- **Local wireless play** - Play games that support local multiplayer as if your friends were in the same room
- **Game sharing** - Use the Switch's game share feature with friends on the virtual LAN
- **Game lending** - Lend digital games to friends through local connection
- **Local network features in games** - For example, use the Union Room in **Pokemon FireRed/LeafGreen** (via NSO) for battles and trades over the internet, or local co-op in **Monster Hunter Rise**, **Mario Kart 8**, and many others

### Access Home Network Services
Route your Switch through a PC that's connected to your home VPN (WireGuard, OpenVPN) while you're away, giving the Switch access to local network game servers or NAS media.

### Network Debugging
Monitor and log all HTTP/HTTPS traffic from your Switch for troubleshooting connectivity issues. All connections are logged to `proxy.log`.

## Quick Start

Requires **Python 3.6+** (no external dependencies).

```bash
python3 switchgate.py
```

The script will display your local IP and port. Configure your Switch:

1. Go to **Settings > Internet**
2. Select your Wi-Fi network
3. Choose **Change Settings**
4. Set **Proxy Server** to **On**
5. Enter the **IP** and **Port** shown by SwitchGate
6. Save and test connection

### Options

```bash
python3 switchgate.py --port 3128    # custom port (default: 8888)
```

### Stop

Press `Ctrl+C` to gracefully shut down the proxy.

## Standalone Scripts

If you prefer not to use Python, platform-specific standalone scripts are available in the `standalone/` directory. These are single-file scripts that run natively on each OS:

| Script | Platform | Dependency |
|---|---|---|
| `standalone/switchgate-macos.sh` | macOS | [tinyproxy](https://formulae.brew.sh/formula/tinyproxy) (`brew install tinyproxy`) |
| `standalone/switchgate-linux.sh` | Linux | tinyproxy (`apt install tinyproxy` / `dnf install tinyproxy` / `pacman -S tinyproxy`) |
| `standalone/switchgate-windows.ps1` | Windows | None (pure PowerShell) |

```bash
# macOS
./standalone/switchgate-macos.sh

# Linux
./standalone/switchgate-linux.sh

# Windows (PowerShell)
powershell -ExecutionPolicy Bypass -File standalone\switchgate-windows.ps1
```

## How It Works

SwitchGate runs an HTTP proxy server on your PC. The Switch is configured to send all its network traffic through this proxy. Since the proxy runs on your PC, the Switch's traffic inherits whatever network access your PC has — VPNs, virtual LANs, or any other connection.

- **HTTP requests** are forwarded via `http.client`
- **HTTPS connections** are tunneled via the `CONNECT` method (no traffic inspection)
- Only private network IPs are allowed to connect (192.168.x.x, 10.x.x.x, 172.16.x.x)
- All connections are logged to `proxy.log`

## Project Structure

```
switchgate.py                        # Cross-platform proxy (Python 3.6+)
standalone/
  switchgate-macos.sh                # macOS standalone (requires tinyproxy)
  switchgate-linux.sh                # Linux standalone (requires tinyproxy)
  switchgate-windows.ps1             # Windows standalone (pure PowerShell)
```

## History

This project evolved from a simple macOS shell script. The original v1 is still available as a [GitHub Gist](https://gist.github.com/davydmaker/601b3f11cc1c28bf75253038278cc582), but this repository is the actively maintained version with cross-platform support and additional features.

## License

MIT
