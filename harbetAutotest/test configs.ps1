param()

# Self-elevate (winws requires admin)
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[INFO] Requesting administrator rights..." -ForegroundColor Yellow
    Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"") -Verb RunAs
    exit
}

$rootDir = Split-Path $PSScriptRoot
$utilsDir = Join-Path $rootDir "utils"
$resultsDir = Join-Path $PSScriptRoot "test results"
if (-not (Test-Path $resultsDir)) { New-Item -ItemType Directory -Path $resultsDir | Out-Null }

# Check curl
if (-not (Get-Command "curl.exe" -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] curl.exe not found. Install curl or add it to PATH." -ForegroundColor Red
    Write-Host "Press any key to close..." -ForegroundColor Yellow
    [void][System.Console]::ReadKey($true)
    exit 1
}

function Convert-Target {
    param([string]$Name, [string]$Value)
    if ($Value -like "PING:*") {
        $ping = $Value -replace '^PING:\s*', ''
        return (New-Object PSObject -Property @{ Name = $Name; Url = $null; PingTarget = $ping })
    } else {
        $url = $Value
        $pingTarget = $url -replace "^https?://", "" -replace "/.*$", ""
        return (New-Object PSObject -Property @{ Name = $Name; Url = $url; PingTarget = $pingTarget })
    }
}

# Load targets
$targetList = @()
$targetsFile = Join-Path $utilsDir "targets.txt"
$rawTargets = New-Object System.Collections.Specialized.OrderedDictionary
if (Test-Path $targetsFile) {
    Get-Content $targetsFile | ForEach-Object {
        if ($_ -match '^\s*(\w+)\s*=\s*"(.+)"\s*$') {
            $rawTargets[$matches[1]] = $matches[2]
        }
    }
}
if ($rawTargets.Count -eq 0) {
    $rawTargets["Discord Main"]           = "https://discord.com"
    $rawTargets["Discord Gateway"]        = "https://gateway.discord.gg"
    $rawTargets["Discord CDN"]            = "https://cdn.discordapp.com"
    $rawTargets["Discord Updates"]        = "https://updates.discord.com"
    $rawTargets["YouTube Web"]            = "https://www.youtube.com"
    $rawTargets["YouTube Short"]          = "https://youtu.be"
    $rawTargets["YouTube Image"]          = "https://i.ytimg.com"
    $rawTargets["YouTube Video Redirect"] = "https://redirector.googlevideo.com"
    $rawTargets["Google Main"]            = "https://www.google.com"
    $rawTargets["Google Gstatic"]         = "https://www.gstatic.com"
    $rawTargets["Cloudflare Web"]         = "https://www.cloudflare.com"
    $rawTargets["Cloudflare CDN"]         = "https://cdnjs.cloudflare.com"
    $rawTargets["Cloudflare DNS 1.1.1.1"] = "PING:1.1.1.1"
    $rawTargets["Cloudflare DNS 1.0.0.1"] = "PING:1.0.0.1"
    $rawTargets["Google DNS 8.8.8.8"]     = "PING:8.8.8.8"
    $rawTargets["Google DNS 8.8.4.4"]     = "PING:8.8.4.4"
    $rawTargets["Quad9 DNS 9.9.9.9"]      = "PING:9.9.9.9"
} else {
    Write-Host "[INFO] Loaded targets from targets.txt" -ForegroundColor Gray
}

foreach ($key in $rawTargets.Keys) {
    $targetList += Convert-Target -Name $key -Value $rawTargets[$key]
}

$maxNameLen = ($targetList | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
if (-not $maxNameLen -or $maxNameLen -lt 10) { $maxNameLen = 10 }

# Config list (all strategy bats)
$batFiles = Get-ChildItem -Path $rootDir -Filter "*.bat" |
    Where-Object { $_.Name -notlike "service*" -and $_.Name -notlike "test*" -and $_.Name -notlike "setup*" } |
    Sort-Object { [Regex]::Replace($_.Name, "(\d+)", { $args[0].Value.PadLeft(8, "0") }) }

if (-not $batFiles -or $batFiles.Count -eq 0) {
    Write-Host "[ERROR] No strategy .bat files found" -ForegroundColor Red
    Write-Host "Press any key to close..." -ForegroundColor Yellow
    [void][System.Console]::ReadKey($true)
    exit 1
}

function Stop-Zapret {
    Get-Process -Name "winws" -ErrorAction SilentlyContinue | Stop-Process -Force
}

function Get-GameFilterValues {
    $gameFilter = "12"; $gameFilterTcp = "12"; $gameFilterUdp = "12"
    $gameFlagFile = Join-Path $utilsDir "game_filter.enabled"
    if (Test-Path $gameFlagFile) {
        $mode = (Get-Content $gameFlagFile -TotalCount 1).Trim()
        if ($mode -eq "all") { $gameFilter = "1024-65535"; $gameFilterTcp = "1024-65535"; $gameFilterUdp = "1024-65535" }
        elseif ($mode -eq "tcp") { $gameFilter = "1024-65535"; $gameFilterTcp = "1024-65535" }
        elseif ($mode -eq "udp") { $gameFilter = "1024-65535"; $gameFilterUdp = "1024-65535" }
    }
    return [PSCustomObject]@{ All = $gameFilter; Tcp = $gameFilterTcp; Udp = $gameFilterUdp }
}

# Port of service.bat :service_install arg parsing (token split on space/tab/,/;/=, merge back, path resolution)
function Get-BatServiceArgs {
    param([string]$path)

    $binDir = Join-Path $rootDir "bin\"
    $listsDir = Join-Path $rootDir "lists\"
    $gf = Get-GameFilterValues

    $lines = Get-Content -Path $path -Encoding UTF8
    $argsStr = ""
    $capture = $false
    $state = 0
    foreach ($line in $lines) {
        $t = $line.TrimEnd()
        if (-not $capture) {
            $idx = $t.IndexOf("%BIN%winws.exe")
            if ($idx -lt 0) { continue }
            $capture = $true
            $endQ = $t.IndexOf('"', $idx + 14)
            if ($endQ -ge 0) { $t = $t.Substring($endQ + 1) } else { $t = $t.Substring($idx + 14) }
        }
        $tokens = @($t -split '[ \t,;=]+' | Where-Object { $_ -ne "" -and $_ -ne "^" })
        foreach ($arg in $tokens) {
            if ($arg.StartsWith("--") -and $state -ne 0) { $state = 0 }

            if ($arg.StartsWith('"')) {
                $inner = $arg.Trim('"')
                if ($inner.Contains(":")) { $arg = '\"' + $inner + '\"' }
                elseif ($inner.StartsWith("@")) { $arg = '\"@' + $rootDir + '\' + $inner.Substring(1) + '\"' }
                elseif ($inner.StartsWith("%BIN%")) { $arg = '\"' + $binDir + $inner.Substring(5) + '\"' }
                elseif ($inner.StartsWith("%LISTS%")) { $arg = '\"' + $listsDir + $inner.Substring(7) + '\"' }
                else { $arg = '\"' + $rootDir + '\' + $inner + '\"' }
            } elseif ($arg.StartsWith("%GameFilterTCP%")) { $arg = $gf.Tcp }
            elseif ($arg.StartsWith("%GameFilterUDP%")) { $arg = $gf.Udp }
            elseif ($arg.StartsWith("%GameFilter%")) { $arg = $gf.All }

            if ($state -eq 1) { $argsStr += ",$arg" }
            elseif ($state -eq 3) { $argsStr += "=$arg"; $state = 1 }
            else { $argsStr += " $arg" }

            if ($arg.StartsWith("--")) { $state = 2 }
            elseif ($state -ge 1) {
                if ($state -eq 2) { $state = 1 }
                foreach ($x in @("sni", "host", "altorder")) {
                    if ($arg -ieq $x) { $state = 3 }
                }
            }
        }
    }
    return $argsStr.Trim()
}

# Port of service.bat :service_remove
function Remove-ZapretServices {
    Write-Host "[INFO] Removing existing services..." -ForegroundColor Cyan

    if (Get-Service -Name "zapret" -ErrorAction SilentlyContinue) {
        net stop zapret 2>&1 | Out-Null
        sc.exe delete zapret 2>&1 | Out-Null
    } else {
        Write-Host "  Service `"zapret`" is not installed." -ForegroundColor DarkGray
    }

    Stop-Zapret

    if (Get-Service -Name "WinDivert" -ErrorAction SilentlyContinue) {
        net stop WinDivert 2>&1 | Out-Null
        if (Get-Service -Name "WinDivert" -ErrorAction SilentlyContinue) {
            sc.exe delete WinDivert 2>&1 | Out-Null
        }
    }
    net stop WinDivert14 2>&1 | Out-Null
    sc.exe delete WinDivert14 2>&1 | Out-Null
}

function Install-ZapretService {
    param([System.IO.FileInfo]$configFile)

    Remove-ZapretServices

    $binDir = Join-Path $rootDir "bin\"
    $finalArgs = Get-BatServiceArgs -path $configFile.FullName
    if (-not $finalArgs) {
        Write-Host "[ERROR] Failed to parse winws args from $($configFile.Name)" -ForegroundColor Red
        return $false
    }

    Write-Host "[INFO] Enabling TCP timestamps..." -ForegroundColor DarkGray
    try { netsh interface tcp set global timestamps=enabled | Out-Null } catch {}

    $strategyName = [System.IO.Path]::GetFileNameWithoutExtension($configFile.Name)
    $escapedArgs = $finalArgs.Replace("^", "^^")

    $tmpBat = Join-Path $env:TEMP "zapret_install_service.tmp.bat"
    $lines = @(
        '@echo off',
        ('sc create zapret binPath= "\"' + $binDir + 'winws.exe\" ' + $escapedArgs + '" DisplayName= "zapret" start= auto'),
        'sc description zapret "Zapret DPI bypass software"',
        'sc start zapret',
        ('reg add "HKLM\System\CurrentControlSet\Services\zapret" /v zapret-discord-youtube /t REG_SZ /d "' + $strategyName + '" /f')
    )
    [System.IO.File]::WriteAllText($tmpBat, ($lines -join "`r`n") + "`r`n")

    Write-Host "[INFO] Installing service 'zapret' from `"$strategyName`"..." -ForegroundColor Cyan
    $out = & $tmpBat 2>&1
    $out | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    Remove-Item -LiteralPath $tmpBat -Force -ErrorAction SilentlyContinue

    $svc = Get-Service -Name "zapret" -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        Write-Host "[OK] Service 'zapret' installed from `"$strategyName`" and started" -ForegroundColor Green
        return $true
    }
    Write-Host "[ERROR] Service installation failed or service is not running" -ForegroundColor Red
    return $false
}

function Get-WinwsSnapshot {
    try {
        return Get-CimInstance Win32_Process -Filter "Name='winws.exe'" |
            Select-Object ProcessId, CommandLine, ExecutablePath
    } catch {
        return @()
    }
}

function Restore-WinwsSnapshot {
    param($snapshot)

    if (-not $snapshot -or $snapshot.Count -eq 0) { return }

    $current = @()
    try { $current = (Get-WinwsSnapshot).CommandLine } catch { $current = @() }

    Write-Host "[INFO] Restoring previously running winws instances..." -ForegroundColor DarkGray
    foreach ($p in $snapshot) {
        if (-not $p.ExecutablePath) { continue }
        if ($current -and $current -contains $p.CommandLine) { continue }

        $exe = $p.ExecutablePath
        $processArgs = ""
        if ($p.CommandLine) {
            $quotedExe = '"' + $exe + '"'
            if ($p.CommandLine.StartsWith($quotedExe)) {
                $processArgs = $p.CommandLine.Substring($quotedExe.Length).Trim()
            } elseif ($p.CommandLine.StartsWith($exe)) {
                $processArgs = $p.CommandLine.Substring($exe.Length).Trim()
            }
        }

        Start-Process -FilePath $exe -ArgumentList $processArgs -WorkingDirectory (Split-Path $exe -Parent) -WindowStyle Minimized | Out-Null
    }
}

$scriptBlock = {
    param($t, $curlTimeoutSeconds)

    $httpPieces = @()

    if ($t.Url) {
        $tests = @(
            @{ Label = "HTTP";   Args = @("--http1.1") },
            @{ Label = "TLS1.2"; Args = @("--tlsv1.2", "--tls-max", "1.2") },
            @{ Label = "TLS1.3"; Args = @("--tlsv1.3", "--tls-max", "1.3") }
        )

        $baseArgs = @("-I", "-s", "-m", $curlTimeoutSeconds, "-o", "NUL", "-w", "%{http_code}", "--show-error")
        foreach ($test in $tests) {
            try {
                $curlArgs = $baseArgs + $test.Args
                $stderr = $null
                $output = & curl.exe @curlArgs $t.Url 2>&1 | ForEach-Object {
                    if ($_ -is [System.Management.Automation.ErrorRecord]) {
                        $stderr += $_.Exception.Message + " "
                    } else {
                        $_
                    }
                }
                $httpCode = ($output | Out-String).Trim()

                $dnsHijack = ($stderr -match "Could not resolve host|certificate|SSL certificate problem|self[- ]?signed|certificate verify failed|unable to get local issuer certificate")
                if ($dnsHijack) {
                    $httpPieces += "$($test.Label):SSL  "
                    continue
                }

                $unsupported = (($LASTEXITCODE -eq 35) -or ($stderr -match "does not support|not supported|protocol\s+'?.+'?\s+not\s+supported|unsupported protocol|TLS.*not supported|Unrecognized option|Unknown option|unsupported option|unsupported feature|schannel"))
                if ($unsupported) {
                    $httpPieces += "$($test.Label):UNSUP"
                    continue
                }

                if ($LASTEXITCODE -eq 0) {
                    $httpPieces += "$($test.Label):OK   "
                } else {
                    $httpPieces += "$($test.Label):ERROR"
                }
            } catch {
                $httpPieces += "$($test.Label):ERROR"
            }
        }
    }

    $pingResult = "n/a"
    if ($t.PingTarget) {
        try {
            $pings = Test-Connection -ComputerName $t.PingTarget -Count 3 -ErrorAction Stop
            $avg = ($pings | Measure-Object -Property ResponseTime -Average).Average
            $pingResult = "{0:N0} ms" -f $avg
        } catch {
            $pingResult = "Timeout"
        }
    }

    return (New-Object PSObject -Property @{
        Name       = $t.Name
        HttpTokens = $httpPieces
        PingResult = $pingResult
        IsUrl      = [bool]$t.Url
    })
}

function Invoke-TargetTests {
    param([array]$targets, [int]$timeoutSeconds)

    $maxParallel = 8
    $runspacePool = [runspacefactory]::CreateRunspacePool(1, $maxParallel)
    $runspacePool.Open()

    $runspaces = @()
    foreach ($target in $targets) {
        $ps = [powershell]::Create().AddScript($scriptBlock)
        [void]$ps.AddArgument($target)
        [void]$ps.AddArgument($timeoutSeconds)
        $ps.RunspacePool = $runspacePool

        $runspaces += [PSCustomObject]@{
            Powershell = $ps
            Handle     = $ps.BeginInvoke()
        }
    }

    $results = @()
    foreach ($rs in $runspaces) {
        try {
            $waitMs = ([int]$timeoutSeconds + 5) * 1000
            $handle = $rs.Handle
            if ($handle -and $handle.AsyncWaitHandle) {
                $completed = $handle.AsyncWaitHandle.WaitOne($waitMs)
                if (-not $completed) {
                    try { $rs.Powershell.Stop() } catch {}
                }
            }
        } catch {
        }
        try {
            $results += $rs.Powershell.EndInvoke($rs.Handle)
        } catch {
            $results += [PSCustomObject]@{ Name = 'UNKNOWN'; HttpTokens = @('HTTP:ERROR'); PingResult = 'Timeout'; IsUrl = $true }
        }
        $rs.Powershell.Dispose()
    }

    $runspacePool.Close()
    $runspacePool.Dispose()
    return $results
}

function Show-Results {
    param([array]$targets, [array]$results, [hashtable]$counters)

    $lookup = @{}
    foreach ($res in $results) { $lookup[$res.Name] = $res }

    foreach ($target in $targets) {
        $res = $lookup[$target.Name]
        if (-not $res) { continue }

        Write-Host "  $($target.Name.PadRight($maxNameLen))    " -NoNewline

        if ($res.IsUrl -and $res.HttpTokens) {
            foreach ($tok in $res.HttpTokens) {
                $tokColor = "Green"
                $criticalUnsup = (($tok -match "UNSUP") -and ($tok -match "HTTP|TLS1\.2"))
                if ($criticalUnsup) { $tokColor = "Red" }
                elseif ($tok -match "UNSUP") { $tokColor = "Yellow" }
                elseif ($tok -match "SSL") { $tokColor = "Red" }
                elseif ($tok -match "ERR") { $tokColor = "Red" }
                Write-Host " $tok" -NoNewline -ForegroundColor $tokColor
                if ($tok -match "OK") { $counters.OK++ }
                elseif ($tok -match "SSL|ERR") { $counters.ERROR++ }
                elseif ($criticalUnsup) { $counters.ERROR++ }
                elseif ($tok -match "UNSUP") { $counters.UNSUP++ }
            }
            Write-Host " | Ping: " -NoNewline -ForegroundColor DarkGray
            if ($res.PingResult -eq "Timeout") {
                Write-Host "$($res.PingResult)" -ForegroundColor Red
                $counters.PingFail++
            } else {
                Write-Host "$($res.PingResult)" -ForegroundColor Cyan
                $counters.PingOK++
            }
        } else {
            Write-Host " Ping: " -NoNewline -ForegroundColor DarkGray
            if ($res.PingResult -eq "Timeout") {
                Write-Host "$($res.PingResult)" -ForegroundColor Red
                $counters.PingFail++
            } else {
                Write-Host "$($res.PingResult)" -ForegroundColor Cyan
                $counters.PingOK++
            }
        }
    }
}

$env:NO_UPDATE_CHECK = "1"
$originalWinws = Get-WinwsSnapshot
$globalResults = @()
$curlTimeoutSeconds = 5

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "           ZAPRET BEST CONFIG SEARCH" -ForegroundColor Cyan
Write-Host "           Standard tests (HTTP/ping) - All configs" -ForegroundColor Cyan
Write-Host "           Total configs: $($batFiles.Count.ToString().PadLeft(2))" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "[WARNING] Tests may take several minutes. Please wait..." -ForegroundColor Yellow

try {
    $configNum = 0
    foreach ($file in $batFiles) {
        $configNum++
        Write-Host ""
        Write-Host "------------------------------------------------------------" -ForegroundColor DarkCyan
        Write-Host "  [$configNum/$($batFiles.Count)] $($file.Name)" -ForegroundColor Yellow
        Write-Host "------------------------------------------------------------" -ForegroundColor DarkCyan

        Stop-Zapret

        Write-Host "  > Starting config..." -ForegroundColor Cyan
        $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$($file.FullName)`"" -WorkingDirectory $rootDir -PassThru -WindowStyle Minimized
        Start-Sleep -Seconds 5

        Write-Host "  > Running tests..." -ForegroundColor DarkGray
        $targetResults = Invoke-TargetTests -targets $targetList -timeoutSeconds $curlTimeoutSeconds

        $counters = @{ OK = 0; ERROR = 0; UNSUP = 0; PingOK = 0; PingFail = 0 }
        Show-Results -targets $targetList -results $targetResults -counters $counters

        Write-Host "  SUMMARY: HTTP OK: $($counters.OK), ERR: $($counters.ERROR), UNSUP: $($counters.UNSUP), Ping OK: $($counters.PingOK), Fail: $($counters.PingFail)" -ForegroundColor Yellow

        $globalResults += @{ Config = $file.Name; File = $file; Results = $targetResults; Analytics = $counters }

        Stop-Zapret
        if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    }
} finally {
    Stop-Zapret
}

# Find best config
$best = $null
foreach ($r in $globalResults) {
    if (-not $best) { $best = $r; continue }
    $a = $r.Analytics
    $b = $best.Analytics
    if ($a.OK -gt $b.OK) { $best = $r }
    elseif ($a.OK -eq $b.OK) {
        if ($a.PingOK -gt $b.PingOK) { $best = $r }
        elseif ($a.PingOK -eq $b.PingOK -and $a.ERROR -lt $b.ERROR) { $best = $r }
    }
}

Write-Host ""
Write-Host "=== ANALYTICS (ALL CONFIGS) ===" -ForegroundColor Cyan
foreach ($r in $globalResults) {
    $a = $r.Analytics
    $mark = ""
    if ($best -and $r.Config -eq $best.Config) { $mark = "  <== BEST" }
    Write-Host "$($r.Config) : HTTP OK: $($a.OK), ERR: $($a.ERROR), UNSUP: $($a.UNSUP), Ping OK: $($a.PingOK), Fail: $($a.PingFail)$mark" -ForegroundColor Yellow
}

if ($best) {
    Write-Host ""
    Write-Host "Best config: $($best.Config)" -ForegroundColor Green
}

# Install best config as service (same way as service.bat install service)
$installed = $false
if ($best) {
    $installed = Install-ZapretService -configFile $best.File
}
if (-not $installed) {
    Restore-WinwsSnapshot -snapshot $originalWinws
}

# Save to file
$dateStr = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$resultFile = Join-Path $resultsDir "test_configs_$dateStr.txt"
"" | Out-File $resultFile -Encoding UTF8
foreach ($r in $globalResults) {
    Add-Content $resultFile "Config: $($r.Config)"
    $lookup = @{}
    foreach ($res in $r.Results) { $lookup[$res.Name] = $res }
    foreach ($target in $targetList) {
        $res = $lookup[$target.Name]
        if (-not $res) { continue }
        $http = $res.HttpTokens -join ' '
        Add-Content $resultFile "  $($target.Name) : $http | Ping: $($res.PingResult)"
    }
    $a = $r.Analytics
    Add-Content $resultFile "  SUMMARY: HTTP OK: $($a.OK), ERR: $($a.ERROR), UNSUP: $($a.UNSUP), Ping OK: $($a.PingOK), Fail: $($a.PingFail)"
    Add-Content $resultFile ""
}
if ($best) { Add-Content $resultFile "Best config: $($best.Config)" }
Write-Host "Results saved to $resultFile" -ForegroundColor Green

# Banner
$okArt = @(
    '  ######      ##    ##    ',
    ' ##    ##     ##   ##     ',
    '##      ##    ##  ##      ',
    '##      ##    ####        ',
    '##      ##    ##  ##      ',
    ' ##    ##     ##   ##     ',
    '  ######      ##    ##    '
)

$errArt = @(
    '############  ##########    ##########      ######      ##########  ',
    '##            ##      ##    ##      ##     ##    ##     ##      ##  ',
    '##            ##      ##    ##      ##    ##      ##    ##      ##  ',
    '#######       ##########    ##########    ##      ##    ##########  ',
    '##            ##  ##        ##  ##        ##      ##    ##  ##      ',
    '##            ##    ##      ##    ##       ##    ##     ##    ##    ',
    '############   ##      ##   ##      ##      ######      ##      ##  '
)

function Set-Bg { param($c) try { $Host.UI.RawUI.BackgroundColor = $c } catch { try { [Console]::BackgroundColor = $c } catch {} } }
function Set-Fg { param($c) try { $Host.UI.RawUI.ForegroundColor = $c } catch { try { [Console]::ForegroundColor = $c } catch {} } }
function Write-Banner {
    param($art, $color)
    for ($r = 0; $r -lt 3; $r++) {
        foreach ($l in $art) { Write-Host $l -ForegroundColor $color }
        if ($r -lt 2) { Write-Host "" }
    }
}

$allGreen = ($best -and $best.Analytics.ERROR -eq 0 -and $best.Analytics.PingFail -eq 0)
Write-Host ""
if ($allGreen) {
    Write-Banner -art $okArt -color 'Green'
} else {
    $pos = $Host.UI.RawUI.CursorPosition
    for ($i = 0; $i -lt 6; $i++) {
        $Host.UI.RawUI.CursorPosition = $pos
        if ($i % 2 -eq 0) {
            Set-Bg 'Red'
            Set-Fg 'White'
        } else {
            Set-Bg 'Black'
            Set-Fg 'White'
        }
        Write-Banner -art $errArt -color 'White'
        Start-Sleep -Milliseconds 400
    }
    Set-Bg 'Black'
    Set-Fg 'Red'
    $Host.UI.RawUI.CursorPosition = $pos
    Write-Banner -art $errArt -color 'White'
}
Set-Bg 'Black'
Set-Fg 'Gray'
Write-Host ""
Write-Host "Press any key to close..." -ForegroundColor Yellow
[void][System.Console]::ReadKey($true)
exit