$ErrorActionPreference = 'Stop'

# === Force platform-tools adb to win over QtScrcpy's old adb ===
$platformTools = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Google.PlatformTools_Microsoft.Winget.Source_8wekyb3d8bbwe\platform-tools"
if (Test-Path $platformTools) {
    $env:PATH = "$platformTools;$env:PATH"
}

$DEVICE_IP = '192.168.1.100'
$cacheFile = Join-Path $PSScriptRoot 'scrcpy_port.cache'
$logFile = Join-Path $PSScriptRoot 'scrcpy_connect.log'
$portStart = 35000
$portEnd = 45000
$scanConcurrency = 300
$connectTimeoutMs = 300
# NOTE: port-discovery background job lifetime is now managed inside Resolve-DevicePort.

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][$Level] $Message"
    $color = switch ($Level) { 'ERROR' { 'Red' } 'WARN' { 'DarkYellow' } default { 'Gray' } }
    try {
        $oldColor = [Console]::ForegroundColor
        [Console]::ForegroundColor = $color
        [Console]::WriteLine($line)
        [Console]::ForegroundColor = $oldColor
    } catch { Write-Output $line }
    try { Add-Content -Path $logFile -Value $line -Encoding UTF8 } catch {}
}

# Rotate log (keep last 200 lines, only if > 100 KB)
try {
    if ((Get-Item $logFile -ErrorAction SilentlyContinue).Length -gt 100KB) {
        $old = Get-Content $logFile | Select-Object -Last 200
        Set-Content -Path $logFile -Value $old -Encoding UTF8
    }
} catch {}
Write-Log '=== scrcpy_connect started ==='

Add-Type -AssemblyName System.Windows.Forms

function Invoke-AdbSafe {
    param([string[]]$Arguments)
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & adb @Arguments 2>&1
    } finally {
        $ErrorActionPreference = $saved
    }
    return $output
}

# --- Startup checks ---

$adbCmd = Get-Command adb -ErrorAction SilentlyContinue
if ($adbCmd) {
    Write-Log "ADB: $($adbCmd.Source)"
    $adbVer = Invoke-AdbSafe -Arguments @('version') | Select-Object -First 1
    Write-Log "ADB version: $adbVer"
} else {
    $msg = 'adb not found in PATH.'
    Write-Log $msg 'ERROR'
    [System.Windows.Forms.MessageBox]::Show($msg, 'scrcpy - adb missing', 'OK', 'Error')
    exit 1
}

$scrcpyCmd = Get-Command scrcpy -ErrorAction SilentlyContinue
if (-not $scrcpyCmd) {
    $msg = 'scrcpy not found in PATH.'
    Write-Log $msg 'ERROR'
    [System.Windows.Forms.MessageBox]::Show($msg, 'scrcpy - missing', 'OK', 'Error')
    exit 1
}
Write-Log "scrcpy: $($scrcpyCmd.Source)"

# Check WSL scrcpy availability (save/restore PATH to avoid WSL translate warnings)
$script:wslScrcpy = $null
$savedPath = $env:PATH
try {
    $env:PATH = $savedPath -replace [regex]::Escape($platformTools + ';'), ''
    $wslOut = & wsl -- which scrcpy 2>$null
    if ($LASTEXITCODE -eq 0 -and $wslOut) {
        $script:wslScrcpy = $wslOut.Trim()
        Write-Log "WSL scrcpy: $($script:wslScrcpy)"
    } else {
        Write-Log 'WSL scrcpy not found. WSL mode disabled.' 'WARN'
    }
} catch {
    # WSL check skipped (hardcoded)
} finally {
    $env:PATH = $savedPath
}

# --- Cleanup on Ctrl+C ---

trap {
    if ($_.ToString() -match 'daemon not running') { continue }
    Write-Log "TRAP: $_" 'ERROR'
    if ($script:connectedSerial) {
        try { Invoke-AdbSafe -Arguments @('disconnect', $script:connectedSerial) | Out-Null } catch {}
        $script:connectedSerial = $null
    }
    continue
}

# --- ADB helpers ---

function Test-AdbDevice {
    param([Parameter(Mandatory)][string]$Ip, [Parameter(Mandatory)][int]$Port)
    $serial = "${Ip}:${Port}"
    $devices = Invoke-AdbSafe -Arguments @('devices')
    return ($devices -match "^\s*$([regex]::Escape($serial))\s+device\s*$")
}

function Connect-AdbDevice {
    param([Parameter(Mandatory)][string]$Ip, [Parameter(Mandatory)][int]$Port)
    $serial = "${Ip}:${Port}"
    Write-Log "adb connect $serial"
    $adbResult = Invoke-AdbSafe -Arguments @('connect', $serial)
    $adbResult = $adbResult | Where-Object { $_ -notmatch 'daemon' -and $_ -notmatch '^\*' }
    Write-Log "adb result: $adbResult"
    if ($adbResult -notmatch 'connected|already connected') { return $false }
    $delay = 200
    for ($i = 0; $i -lt 5; $i++) {
        Start-Sleep -Milliseconds $delay
        if (Test-AdbDevice -Ip $Ip -Port $Port) { return $true }
        $delay = [Math]::Min($delay * 1.5, 1000)
    }
    return $false
}

# --- IP reachability ---

function Test-IPReachable {
    param([Parameter(Mandatory)][string]$Ip, [int]$TimeoutMs = 2000)
    try {
        $ping = New-Object System.Net.NetworkInformation.Ping
        $reply = $ping.Send($Ip, $TimeoutMs)
        return ($reply.Status -eq 'Success')
    } catch { return $false }
}

# --- Cache (date+port, two lines) ---
# Line 1 = yyyy-MM-dd of last successful connect, line 2 = port.
# A same-day cache means the port is probably still alive and worth trying first.
# An overnight (or old single-line) cache is treated as "first use today" and skipped,
# because the wireless-debug port changes on every reboot and waiting on the stale
# cached port wastes ~2s for nothing.

function Read-Cache {
    if (-not (Test-Path $cacheFile)) { return $null }
    $lines = Get-Content $cacheFile -ErrorAction SilentlyContinue
    if (-not $lines -or $lines.Count -lt 2) { return $null }
    if ($lines[0] -match '^\d{4}-\d{2}-\d{2}$' -and $lines[1] -match '^\d+$') {
        return @{ Date = $lines[0]; Port = [int]$lines[1] }
    }
    return $null
}

function Write-Cache {
    param([Parameter(Mandatory)][string]$Date, [Parameter(Mandatory)][int]$Port)
    Set-Content -Path $cacheFile -Value "$Date`n$Port" -Encoding UTF8
}

# --- Background cache verifier ---
# Same-day cache is treated as just another race participant: if there's a
# valid same-day cached port, this job asynchronously tries to connect to it
# in parallel with mDNS and the TCP scan. Cache-hit, cache-miss, and abort
# paths all become structurally identical — fully parallel, no special
# synchronous pre-step. Whichever participant connects first wins.

function Start-CacheVerifyBackground {
    param([Parameter(Mandatory)][string]$Ip, [Parameter(Mandatory)][string]$Today)
    $cacheBody = @"
        param(`$Ip, `$Today, `$CacheFile)
        `$cache = `$null
        if (Test-Path `$CacheFile) {
            `$lines = Get-Content `$CacheFile -ErrorAction SilentlyContinue
            if (`$lines -and `$lines.Count -ge 2 -and `$lines[0] -match '^\d{4}-\d{2}-\d{2}$' -and `$lines[1] -match '^\d+$') {
                `$cache = @{ Date = `$lines[0]; Port = [int]`$lines[1] }
            }
        }
        if (-not `$cache -or `$cache.Date -ne `$Today) { return `$null }

        # Same-day cache: try to connect asynchronously. Mirrors Connect-AdbDevice
        # but runs in the background so the dialog and the other jobs keep going.
        `$serial = "`${Ip}:`$(`$cache.Port)"
        `$saved = `$ErrorActionPreference
        `$ErrorActionPreference = 'Continue'
        try {
            `$adbResult = & adb connect `$serial 2>&1
        } finally { `$ErrorActionPreference = `$saved }
        `$adbResult = @(`$adbResult | Where-Object { `$_ -isnot [System.Management.Automation.ErrorRecord] -and `$_ -notmatch 'daemon' -and `$_ -notmatch '^\*' })
        if (-not ("`$adbResult" -match 'connected|already connected')) { return `$null }

        `$delay = 200
        for (`$i = 0; `$i -lt 5; `$i++) {
            Start-Sleep -Milliseconds `$delay
            `$devs = & adb devices 2>&1
            if ("`$devs" -match ('^\s*' + [regex]::Escape(`$serial) + '\s+device\s*$')) {
                return [int]`$cache.Port
            }
            `$delay = [Math]::Min(`$delay * 1.5, 1000)
        }
        return `$null
"@
    $bgPS = [powershell]::Create()
    [void]$bgPS.AddScript($cacheBody).AddArgument($Ip).AddArgument($Today).AddArgument($cacheFile)
    $bgHandle = $bgPS.BeginInvoke()
    $job = @{ PS = $bgPS; Handle = $bgHandle; Name = 'cache' }
    return $job
}

# --- Background mDNS resolver ---
# adb mdns services prints lines like:
#   adb-<serial>-<token>._adb-tls-connect._tcp     192.168.1.100:38815
# We pick the first service whose host IP matches DEVICE_IP.
# mDNS discovery is asynchronous: after a fresh `adb start-server` the service list
# is empty for a few seconds before populating, so retry up to 6 times.

function Start-MdnsBackground {
    param([Parameter(Mandatory)][string]$Ip, [string]$AdbPath = $adbCmd.Source)
    if (-not $AdbPath) { throw 'adb path is missing.' }
    $mdnsBody = @"
        param(`$AdbPath, `$Ip)
        for (`$attempt = 0; `$attempt -lt 6; `$attempt++) {
            try {
                `$output = & `$AdbPath mdns services 2>&1
            } catch { `$output = @() }
            foreach (`$line in `$output) {
                if (`$line -is [System.Management.Automation.ErrorRecord]) { continue }
                if (`$line -match ([regex]::Escape(`$Ip)) + ':(\d+)\s*$') {
                    return [int]`$Matches[1]
                }
            }
            Start-Sleep -Milliseconds 800
        }
        return `$null
"@
    $bgPS = [powershell]::Create()
    [void]$bgPS.AddScript($mdnsBody).AddArgument($AdbPath).AddArgument($Ip)
    $bgHandle = $bgPS.BeginInvoke()
    $job = @{ PS = $bgPS; Handle = $bgHandle; Name = 'mDNS' }
    return $job
}

# --- Background TCP port scanner ---

function Start-BackgroundScan {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [int]$StartPort = $portStart,
        [int]$EndPort = $portEnd,
        [int]$Concurrency = $scanConcurrency,
        [int]$TimeoutMs = $connectTimeoutMs
    )
    $scanBody = @"
        param(`$Ip, `$StartPort, `$EndPort, `$Concurrency, `$TimeoutMs)
        `$scanScript = {
            param(`$h, `$p, `$timeout)
            `$tcp = New-Object Net.Sockets.TcpClient
            try {
                if (`$tcp.ConnectAsync(`$h, `$p).Wait(`$timeout)) { return `$p }
            } catch {} finally { `$tcp.Dispose() }
            return `$null
        }
        `$pool = [runspacefactory]::CreateRunspacePool(1, `$Concurrency)
        `$pool.Open()
        try {
            `$pending = New-Object System.Collections.ArrayList
            `$nextPort = `$StartPort
            while (`$nextPort -le `$EndPort -or `$pending.Count -gt 0) {
                while (`$nextPort -le `$EndPort -and `$pending.Count -lt `$Concurrency) {
                    `$ps = [powershell]::Create()
                    `$ps.RunspacePool = `$pool
                    [void]`$ps.AddScript(`$scanScript).AddArgument(`$Ip).AddArgument(`$nextPort).AddArgument(`$TimeoutMs)
                    [void]`$pending.Add([pscustomobject]@{ PowerShell = `$ps; Handle = `$ps.BeginInvoke(); Port = `$nextPort })
                    `$nextPort++
                }
                `$handles = @(`$pending | ForEach-Object { `$_.Handle.AsyncWaitHandle })
                if (`$handles.Count -gt 0) {
                    `$end = [Math]::Min(63, `$handles.Count - 1)
                    [System.Threading.WaitHandle]::WaitAny(`$handles[0..`$end], 100) | Out-Null
                }
                for (`$i = `$pending.Count - 1; `$i -ge 0; `$i--) {
                    `$job = `$pending[`$i]
                    if (-not `$job.Handle.IsCompleted) { continue }
                    `$result = `$job.PowerShell.EndInvoke(`$job.Handle)
                    `$job.PowerShell.Dispose()
                    `$pending.RemoveAt(`$i)
                    if (`$result -and `$result[0]) {
                        foreach (`$r in `$pending) { try { `$r.PowerShell.Stop() } catch {} }
                        return [int]`$result[0]
                    }
                }
            }
            return `$null
        } finally {
            foreach (`$j in `$pending) { try { `$j.PowerShell.Stop() } catch {}; try { `$j.PowerShell.Dispose() } catch {} }
            `$pool.Close(); `$pool.Dispose()
        }
"@
    $bgPS = [powershell]::Create()
    [void]$bgPS.AddScript($scanBody).AddArgument($Ip).AddArgument($StartPort).AddArgument($EndPort).AddArgument($Concurrency).AddArgument($TimeoutMs)
    $bgHandle = $bgPS.BeginInvoke()
    $job = @{ PS = $bgPS; Handle = $bgHandle; Name = 'scan' }
    return $job
}

function Stop-Job {
    param($Job)
    if ($Job) {
        try { $Job.PS.Stop() } catch {}
        try { $Job.PS.Dispose() } catch {}
    }
}

function Stop-PortDiscoveryJobs {
    param([array]$Jobs)
    foreach ($j in @($Jobs)) {
        if ($null -eq $j) { continue }
        try { $j.PS.Stop() } catch {}
        try { $j.PS.Dispose() } catch {}
    }
}

# --- Port race ---
# Waits for one or more background port jobs and returns the first port that
# successfully connects via adb. Whichever source resolves first is tried first;
# if that port won't connect, we keep waiting for the other source(s) and try
# them too. Only when every source has resolved (and none connected) do we give up.

function Wait-PortRace {
    param([Parameter(Mandatory)][string]$Ip, [Parameter(Mandatory)][array]$Jobs)
    $pending = New-Object System.Collections.ArrayList
    foreach ($job in $Jobs) { [void]$pending.Add($job) }
    while ($pending.Count -gt 0) {
        $completed = @()
        for ($i = 0; $i -lt $pending.Count; $i++) {
            if ($pending[$i].Handle.IsCompleted) { $completed += $pending[$i] }
        }
        if ($completed.Count -eq 0) {
            $handles = @($pending | ForEach-Object { $_.Handle.AsyncWaitHandle })
            $end = [Math]::Min(63, $handles.Count - 1)
            [System.Threading.WaitHandle]::WaitAny($handles[0..$end], 200) | Out-Null
            continue
        }
        foreach ($job in $completed) {
            try {
                $result = $job.PS.EndInvoke($job.Handle)
            } catch {
                Write-Log "Error reading result for $($job.Name): $_" 'WARN'
                $result = $null
            }
            Stop-Job -Job $job
            $pending.Remove($job) | Out-Null
            $port = $null
            if ($result -and $result[0]) { $port = [int]$result[0] }
            if (-not $port) {
                Write-Log "$($job.Name) found no port."
                continue
            }
            Write-Log "$($job.Name) resolved port $port, verifying..."
            if (Connect-AdbDevice -Ip $Ip -Port $port) {
                Write-Log "$($job.Name) port $port OK."
                foreach ($r in @($pending)) { Stop-Job -Job $r }
                $pending.Clear()
                return $port
            }
            Write-Log "$($job.Name) port $port not usable via adb." 'WARN'
        }
    }
    return $null
}

function Resolve-DevicePort {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$Today,
        [scriptblock]$WhileWaiting
    )

    # All three participants (cache verify, mDNS, TCP scan) start together and
    # race in the background. The mode dialog runs concurrently via -WhileWaiting.
    # Cache is no longer a special synchronous pre-step: it's just another job.
    $cacheJob = Start-CacheVerifyBackground -Ip $Ip -Today $Today
    $mdnsJob = Start-MdnsBackground -Ip $Ip
    $scanJob = Start-BackgroundScan -Ip $Ip
    $jobs = @($cacheJob, $mdnsJob, $scanJob)
    try {
        Write-Log 'cache + mDNS + port scan racing in background.'
        $whileMode = $null
        if ($WhileWaiting) {
            try {
                $whileMode = & $WhileWaiting
                if ($whileMode -eq 'abort') {
                    Write-Log 'User aborted while waiting for port resolution.'
                    return [pscustomobject]@{
                        Port   = $null
                        Serial = $null
                        Mode   = $whileMode
                    }
                }
            } catch {
                Write-Log "WhileWaiting callback failed: $_" 'WARN'
            }
        }
        $port = Wait-PortRace -Ip $Ip -Jobs $jobs
        if (-not $port) {
            return [pscustomobject]@{
                Port   = $null
                Serial = $null
                Mode   = $whileMode
            }
        }
        $serial = "${Ip}:$port"
        Write-Cache -Date $Today -Port $port
        return [pscustomobject]@{
            Port   = [int]$port
            Serial = $serial
            Mode   = $whileMode
        }
    } finally {
        Stop-PortDiscoveryJobs -Jobs $jobs
    }
}

# --- Mode selection dialog ---

function Show-ModeDialog {
    param([int]$TimeoutSeconds = 3)
    $script:chosenMode = 'wsl'
    $script:intentionalClose = $false
    $wslOk = ($null -ne $script:wslScrcpy)
    $h = if ($wslOk) { 230 } else { 140 }

    $form = New-Object System.Windows.Forms.Form -Property @{
        Text = 'scrcpy Connect'; Size = New-Object System.Drawing.Size(420, $h)
        StartPosition = 'CenterScreen'; FormBorderStyle = 'FixedDialog'
        MaximizeBox = $false; MinimizeBox = $false; TopMost = $true; KeyPreview = $true
    }

    $y = 15
    $btnW = New-Object System.Windows.Forms.Button -Property @{
        Text = '  Windows  (scrcpy)'; Size = New-Object System.Drawing.Size(370, 70)
        Location = New-Object System.Drawing.Point(15, $y)
        Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
        BackColor = [System.Drawing.Color]::FromArgb(60, 60, 40); ForeColor = [System.Drawing.Color]::Yellow
        FlatStyle = 'Flat'
    }
    $btnW.FlatAppearance.BorderSize = 2
    $btnW.FlatAppearance.BorderColor = [System.Drawing.Color]::Yellow
    $btnW.Add_Click({ $script:chosenMode = 'windows'; $script:intentionalClose = $true; $form.Close() })
    $form.Controls.Add($btnW)

    $btnL = $null
    if ($wslOk) {
        $y += 80
        $btnL = New-Object System.Windows.Forms.Button -Property @{
            Text = "  WSL      (wsl scrcpy)  -- ${TimeoutSeconds}s"
            Size = New-Object System.Drawing.Size(370, 70)
            Location = New-Object System.Drawing.Point(15, $y)
            Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
            BackColor = [System.Drawing.Color]::FromArgb(20, 60, 20); ForeColor = [System.Drawing.Color]::LightGreen
            FlatStyle = 'Flat'
        }
        $btnL.FlatAppearance.BorderSize = 2
        $btnL.FlatAppearance.BorderColor = [System.Drawing.Color]::LightGreen
        $btnL.Add_Click({ $script:chosenMode = 'wsl'; $script:intentionalClose = $true; $form.Close() })
        $form.Controls.Add($btnL)
    }

    $form.Add_FormClosing({ param($s, $e) if (-not $script:intentionalClose) { $script:chosenMode = 'abort' } })

    $script:countdown = $TimeoutSeconds
    $timer = New-Object System.Windows.Forms.Timer -Property @{ Interval = 1000 }
    $timer.Add_Tick({
        $script:countdown--
        if ($script:countdown -gt 0 -and $btnL) {
            $btnL.Text = "  WSL      (wsl scrcpy)  -- $($script:countdown)s"
        } else {
            $timer.Stop(); $script:intentionalClose = $true; $form.Close()
        }
    })
    $form.Add_Shown({ $timer.Start() })
    $form.Add_FormClosed({ $timer.Stop(); $timer.Dispose() })
    $form.Add_KeyDown({
        switch ($_.KeyCode) {
            'D1'      { $script:chosenMode = 'windows'; $script:intentionalClose = $true; $form.Close() }
            'NumPad1' { $script:chosenMode = 'windows'; $script:intentionalClose = $true; $form.Close() }
            'D2'      { $script:chosenMode = 'wsl'; $script:intentionalClose = $true; $form.Close() }
            'NumPad2' { $script:chosenMode = 'wsl'; $script:intentionalClose = $true; $form.Close() }
            'Enter'   { $script:intentionalClose = $true; $form.Close() }
            'Escape'  { $script:chosenMode = 'abort'; $script:intentionalClose = $true; $form.Close() }
        }
    })
    [void]$form.ShowDialog()
    $form.Dispose()
    return $script:chosenMode
}

# --- Reconnect dialog ---

function Show-ReconnectDialog {
    $script:reconnectChoice = 'reconnect'
    $script:intentionalClose = $false
    $form = New-Object System.Windows.Forms.Form -Property @{
        Text = 'scrcpy - Disconnected'; Size = New-Object System.Drawing.Size(420, 220)
        StartPosition = 'CenterScreen'; FormBorderStyle = 'FixedDialog'
        MaximizeBox = $false; MinimizeBox = $false; TopMost = $true; KeyPreview = $true
    }
    $btnR = New-Object System.Windows.Forms.Button -Property @{
        Text = '  Reconnect'; Size = New-Object System.Drawing.Size(370, 70)
        Location = New-Object System.Drawing.Point(15, 25)
        Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
        BackColor = [System.Drawing.Color]::DarkSlateGray; ForeColor = [System.Drawing.Color]::White
        FlatStyle = 'Flat'
    }
    $btnR.FlatAppearance.BorderSize = 2
    $btnR.FlatAppearance.BorderColor = [System.Drawing.Color]::White
    $btnR.Add_Click({ $script:reconnectChoice = 'reconnect'; $script:intentionalClose = $true; $form.Close() })

    $btnX = New-Object System.Windows.Forms.Button -Property @{
        Text = '  Exit'; Size = New-Object System.Drawing.Size(370, 50)
        Location = New-Object System.Drawing.Point(15, 110)
        Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
        BackColor = [System.Drawing.Color]::FromArgb(70, 40, 40); ForeColor = [System.Drawing.Color]::White
        FlatStyle = 'Flat'
    }
    $btnX.FlatAppearance.BorderSize = 1
    $btnX.FlatAppearance.BorderColor = [System.Drawing.Color]::White
    $btnX.Add_Click({ $script:reconnectChoice = 'abort'; $script:intentionalClose = $true; $form.Close() })

    $form.Add_FormClosing({ param($s, $e) if (-not $script:intentionalClose) { $script:reconnectChoice = 'abort' } })
    $form.Controls.AddRange(@($btnR, $btnX))
    $form.Add_KeyDown({
        switch ($_.KeyCode) {
            'Enter'  { $script:reconnectChoice = 'reconnect'; $script:intentionalClose = $true; $form.Close() }
            'Escape' { $script:reconnectChoice = 'abort'; $script:intentionalClose = $true; $form.Close() }
        }
    })
    [void]$form.ShowDialog()
    $form.Dispose()
    return $script:reconnectChoice
}

function Disconnect-Device {
    if ($script:connectedSerial) {
        Write-Log "Disconnecting $($script:connectedSerial)"
        Invoke-AdbSafe -Arguments @('disconnect', $script:connectedSerial) | Out-Null
        $script:connectedSerial = $null
    }
}

function Apply-DeviceSettings {
    Write-Log 'Applying device settings...'
    foreach ($s in @(
        @{ cmd = 'settings put global charge_separation_switch 1';   label = 'charge_separation_switch' },
        @{ cmd = 'settings put global charge_separation_function 0'; label = 'charge_separation_function' },
        @{ cmd = 'settings put system fan_state_of_manual -2';       label = 'fan_state' }
    )) {
        try {
            $r = Invoke-AdbSafe -Arguments @('-s', $script:connectedSerial, 'shell', $s.cmd)
            if ($r -match 'error|fail|exception') { Write-Log "WARN: $($s.label): $r" 'WARN' }
        } catch { Write-Log "WARN: $($s.label): $_" 'WARN' }
    }
    Write-Log 'Settings applied.'
}

function Start-ScrcpySession {
    param([Parameter(Mandatory)][string]$Mode, [Parameter(Mandatory)][int]$Port)
    $args = @('--video-codec=h265', '--max-size=1080', '--max-fps=100', '--no-audio', '--turn-screen-off', '--stay-awake', '-K', "--tcpip=${DEVICE_IP}:${Port}")
    Write-Log "Starting scrcpy ($Mode)..."
    try {
        if ($Mode -eq 'windows') {
            & scrcpy @args
        } else {
            & wsl scrcpy @args
        }
    } catch {
        Write-Log "scrcpy error: $_" 'ERROR'
        [System.Windows.Forms.MessageBox]::Show(
            "scrcpy crashed:`n`n$($_.Exception.Message)",
            'scrcpy - Error', 'OK', 'Error'
        )
    }
}

# === Main loop ===

while ($true) {
    Write-Log '--- Connect attempt ---'

    # 1. Check IP reachability
    if (-not (Test-IPReachable -Ip $DEVICE_IP)) {
        Write-Log "IP $DEVICE_IP unreachable" 'ERROR'
        [System.Windows.Forms.MessageBox]::Show(
            "IP $DEVICE_IP unreachable.`n`nCheck:`n1. Device WiFi is on`n2. Same network`n3. IP is correct",
            'scrcpy - IP Unreachable', 'OK', 'Warning'
        )
        if ((Show-ReconnectDialog) -eq 'abort') { Write-Log 'User exit (IP unreachable).'; break }
        continue
    }
    Write-Log "IP $DEVICE_IP reachable."

    # 2. Resolve port (cache + mDNS + scan + verify) through one seam.
    #    This returns @{ Port; Serial; Mode } where Port is $null when unresolved.
    $today = Get-Date -Format 'yyyy-MM-dd'
    $resolved = Resolve-DevicePort -Ip $DEVICE_IP -Today $today -WhileWaiting { Show-ModeDialog }
    if ($resolved.Mode -eq 'abort') {
        Write-Log 'User aborted.'
        Disconnect-Device
        break
    }
    if (-not $resolved.Port) {
        Write-Log 'Device not found.' 'ERROR'
        [System.Windows.Forms.MessageBox]::Show(
            "Cannot connect to $DEVICE_IP.`n`nCheck:`n1. Wireless Debugging enabled`n2. Same Wi-Fi`n3. adb authorized`n4. IP may have changed",
            'scrcpy - Device Not Found', 'OK', 'Warning'
        )
        if ((Show-ReconnectDialog) -eq 'abort') { Disconnect-Device; Write-Log 'User exit (no device).'; break }
        continue
    }

    $mode = $resolved.Mode
    if (-not $mode) { $mode = Show-ModeDialog }
    if ($mode -eq 'abort') {
        Write-Log 'User aborted.'
        Disconnect-Device
        break
    }

    $port = $resolved.Port
    $serial = $resolved.Serial
    $script:connectedSerial = $serial
    Write-Log "Mode: $mode, Port: $port, Serial: $serial"
    Apply-DeviceSettings
    Start-ScrcpySession -Mode $mode -Port $port

    if ((Show-ReconnectDialog) -eq 'abort') { Disconnect-Device; Write-Log 'User exit.'; break }
}

Write-Log '=== scrcpy_connect ended ==='
