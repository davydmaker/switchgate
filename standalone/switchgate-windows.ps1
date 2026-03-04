#Requires -Version 5.1

$ErrorActionPreference = "Stop"

$ProxyPort = 8888
$BufferSize = 65536
$LogFile = Join-Path $PWD "proxy.log"

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] $Message"
    Write-Host $logEntry -ForegroundColor $Color
    Add-Content -Path $LogFile -Value $logEntry
}

function Get-LocalIP {
    try {
        $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
               Where-Object { $_.IPAddress -ne "127.0.0.1" -and $_.PrefixOrigin -ne "WellKnown" } |
               Select-Object -First 1).IPAddress
        return $ip
    } catch {
        return $null
    }
}

function Show-SwitchConfig {
    $ip = Get-LocalIP
    Write-Host ""
    if (-not $ip) {
        Write-Host "WARNING: Could not detect local IP address." -ForegroundColor Red
        Write-Host "Make sure you are connected to a network." -ForegroundColor Yellow
        Write-Host ""
        $ip = "<not detected>"
    }
    Write-Host "NINTENDO SWITCH CONFIGURATION:" -ForegroundColor Green
    Write-Host "=========================================="
    Write-Host "Proxy IP: " -ForegroundColor Cyan -NoNewline; Write-Host $ip
    Write-Host "Port: " -ForegroundColor Cyan -NoNewline; Write-Host $ProxyPort
    Write-Host ""
    Write-Host "HOW TO CONFIGURE ON SWITCH:" -ForegroundColor Yellow
    Write-Host "1. Go to Settings > Internet"
    Write-Host "2. Select your Wi-Fi network"
    Write-Host "3. Choose 'Change settings'"
    Write-Host "4. In 'Proxy server' choose 'Yes'"
    Write-Host "5. Enter IP: $ip"
    Write-Host "6. Enter Port: $ProxyPort"
    Write-Host "7. Save and test connection"
    Write-Host ""
    Write-Host "Log file: $LogFile" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Press Ctrl+C to stop the proxy" -ForegroundColor Yellow
    Write-Host ""
}

function Add-FirewallRule {
    $ruleName = "SwitchGate (port $ProxyPort)"
    $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if ($existing) { return }

    try {
        New-NetFirewallRule -DisplayName $ruleName `
            -Direction Inbound -Protocol TCP -LocalPort $ProxyPort `
            -Action Allow -Profile Private | Out-Null
        Write-Log "Firewall rule created for port $ProxyPort" "Green"
    } catch {
        Write-Host "WARNING: Could not create firewall rule. Run as Administrator or add it manually." -ForegroundColor Yellow
        Write-Host "  netsh advfirewall firewall add rule name=`"$ruleName`" dir=in action=allow protocol=TCP localport=$ProxyPort" -ForegroundColor Gray
        Write-Host ""
    }
}

$proxyHandler = {
    param($client, $logFile, $bufferSize)

    try {
        $clientStream = $client.GetStream()
        $clientStream.ReadTimeout = 30000
        $clientStream.WriteTimeout = 30000

        $reader = [System.IO.StreamReader]::new(
            $clientStream, [System.Text.Encoding]::ASCII, $false, $bufferSize, $true
        )

        $requestLine = $reader.ReadLine()
        if (-not $requestLine) { $client.Close(); return }

        $parts = $requestLine -split " ", 3
        if ($parts.Count -lt 3) { $client.Close(); return }

        $method = $parts[0]
        $url = $parts[1]
        $version = $parts[2]

        $headers = [ordered]@{}
        while ($true) {
            $line = $reader.ReadLine()
            if ([string]::IsNullOrEmpty($line)) { break }
            $colonIdx = $line.IndexOf(":")
            if ($colonIdx -gt 0) {
                $key = $line.Substring(0, $colonIdx).Trim()
                $value = $line.Substring($colonIdx + 1).Trim()
                $headers[$key] = $value
            }
        }

        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content -Path $logFile -Value "[$timestamp] $method $url"

        if ($method -eq "CONNECT") {
            $hostParts = $url -split ":"
            $remoteHost = $hostParts[0]
            $remotePort = if ($hostParts.Count -gt 1) { [int]$hostParts[1] } else { 443 }

            $remoteClient = [System.Net.Sockets.TcpClient]::new()
            $remoteClient.Connect($remoteHost, $remotePort)
            $remoteStream = $remoteClient.GetStream()

            $response = [System.Text.Encoding]::ASCII.GetBytes(
                "HTTP/1.1 200 Connection Established`r`n`r`n"
            )
            $clientStream.Write($response, 0, $response.Length)
            $clientStream.Flush()

            $buf1 = [byte[]]::new($bufferSize)
            $buf2 = [byte[]]::new($bufferSize)
            $clientStream.ReadTimeout = 1000
            $remoteStream.ReadTimeout = 1000

            $running = $true
            while ($running -and $client.Connected -and $remoteClient.Connected) {
                try {
                    if ($clientStream.DataAvailable) {
                        $read = $clientStream.Read($buf1, 0, $bufferSize)
                        if ($read -le 0) { break }
                        $remoteStream.Write($buf1, 0, $read)
                        $remoteStream.Flush()
                    }
                } catch [System.IO.IOException] { $running = $false }

                try {
                    if ($remoteStream.DataAvailable) {
                        $read = $remoteStream.Read($buf2, 0, $bufferSize)
                        if ($read -le 0) { break }
                        $clientStream.Write($buf2, 0, $read)
                        $clientStream.Flush()
                    }
                } catch [System.IO.IOException] { $running = $false }

                Start-Sleep -Milliseconds 10
            }

            $remoteStream.Close()
            $remoteClient.Close()
        } else {
            $uri = [System.Uri]::new($url)
            $remoteHost = $uri.Host
            $remotePort = if ($uri.Port -gt 0) { $uri.Port } else { 80 }

            $remoteClient = [System.Net.Sockets.TcpClient]::new()
            $remoteClient.Connect($remoteHost, $remotePort)
            $remoteStream = $remoteClient.GetStream()

            $path = $uri.PathAndQuery
            $requestBuilder = "$method $path $version`r`n"
            foreach ($key in $headers.Keys) {
                if ($key -ne "Proxy-Connection") {
                    $requestBuilder += "${key}: $($headers[$key])`r`n"
                }
            }
            $requestBuilder += "`r`n"

            $requestBytes = [System.Text.Encoding]::ASCII.GetBytes($requestBuilder)
            $remoteStream.Write($requestBytes, 0, $requestBytes.Length)

            if ($headers.Contains("Content-Length")) {
                $contentLength = [int]$headers["Content-Length"]
                $bodyBuffer = [byte[]]::new($bufferSize)
                $remaining = $contentLength
                while ($remaining -gt 0) {
                    $toRead = [Math]::Min($remaining, $bufferSize)
                    $read = $clientStream.Read($bodyBuffer, 0, $toRead)
                    if ($read -le 0) { break }
                    $remoteStream.Write($bodyBuffer, 0, $read)
                    $remaining -= $read
                }
            }
            $remoteStream.Flush()

            $buffer = [byte[]]::new($bufferSize)
            $remoteStream.ReadTimeout = 30000
            try {
                while ($true) {
                    $read = $remoteStream.Read($buffer, 0, $bufferSize)
                    if ($read -le 0) { break }
                    $clientStream.Write($buffer, 0, $read)
                    $clientStream.Flush()
                }
            } catch [System.IO.IOException] { }

            $remoteStream.Close()
            $remoteClient.Close()
        }
    } catch {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content -Path $logFile -Value "[$timestamp] ERROR: $_"
    } finally {
        $client.Close()
    }
}

# === Main ===

Write-Host "SwitchGate - Network Gateway for Nintendo Switch" -ForegroundColor Cyan
Write-Host "=============================================="

Add-FirewallRule

if (Test-Path $LogFile) { Remove-Item $LogFile }
New-Item -Path $LogFile -ItemType File -Force | Out-Null

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $ProxyPort)

try {
    $listener.Start()
} catch {
    Write-Host "ERROR: Could not start listener on port $ProxyPort." -ForegroundColor Red
    Write-Host "The port may be in use or you may need to run as Administrator." -ForegroundColor Yellow
    exit 1
}

Write-Log "Proxy started on port $ProxyPort" "Green"
Show-SwitchConfig

$runspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, 50)
$runspacePool.Open()
$runspaces = [System.Collections.ArrayList]::new()

Write-Host "Monitoring connections (Ctrl+C to exit):" -ForegroundColor Cyan
Write-Host "=================================================="

try {
    while ($true) {
        if ($listener.Pending()) {
            $client = $listener.AcceptTcpClient()

            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $runspacePool
            $ps.AddScript($proxyHandler).
                AddArgument($client).
                AddArgument($LogFile).
                AddArgument($BufferSize) | Out-Null
            $handle = $ps.BeginInvoke()
            $runspaces.Add(@{ PowerShell = $ps; Handle = $handle }) | Out-Null

            $completed = @($runspaces | Where-Object { $_.Handle.IsCompleted })
            foreach ($r in $completed) {
                $r.PowerShell.EndInvoke($r.Handle)
                $r.PowerShell.Dispose()
                $runspaces.Remove($r)
            }
        }
        Start-Sleep -Milliseconds 50
    }
} finally {
    Write-Host ""
    Write-Host "Stopping proxy..." -ForegroundColor Yellow
    $listener.Stop()
    foreach ($r in $runspaces) {
        $r.PowerShell.Stop()
        $r.PowerShell.Dispose()
    }
    $runspacePool.Close()
    $runspacePool.Dispose()
    Write-Host "Proxy stopped." -ForegroundColor Green
}
