param(
    [switch]$FakeError
)

$rootDir = Split-Path $PSScriptRoot
$listsDir = Join-Path $rootDir "lists"
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

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "       ZAPRET TEST - CURRENT SYSTEM (NO STRATEGY)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "[INFO] No winws will be started. Testing internet as-is." -ForegroundColor Yellow

# Wait for network to be ready (up to 60s)
$netWaited = 0
while ($netWaited -lt 60) {
    if (Test-Connection -ComputerName 1.1.1.1 -Count 1 -Quiet -ErrorAction SilentlyContinue) { break }
    if ($netWaited -eq 0) { Write-Host "[INFO] Waiting for network..." -ForegroundColor Yellow }
    Start-Sleep -Seconds 3
    $netWaited += 3
}

$curlTimeoutSeconds = 5
$maxParallel = 8
$runspacePool = [runspacefactory]::CreateRunspacePool(1, $maxParallel)
$runspacePool.Open()

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

$runspaces = @()
foreach ($target in $targetList) {
    $ps = [powershell]::Create().AddScript($scriptBlock)
    [void]$ps.AddArgument($target)
    [void]$ps.AddArgument($curlTimeoutSeconds)
    $ps.RunspacePool = $runspacePool

    $runspaces += [PSCustomObject]@{
        Powershell = $ps
        Handle     = $ps.BeginInvoke()
    }
}

Write-Host "  > Running tests..." -ForegroundColor DarkGray

$targetResults = @()
foreach ($rs in $runspaces) {
    try {
        $waitMs = ([int]$curlTimeoutSeconds + 5) * 1000
        $handle = $rs.Handle
        if ($handle -and $handle.AsyncWaitHandle) {
            $completed = $handle.AsyncWaitHandle.WaitOne($waitMs)
            if (-not $completed) {
                Write-Host "[WARN] Runspace for target timed out; stopping..." -ForegroundColor Yellow
                try { $rs.Powershell.Stop() } catch {}
            }
        }
    } catch {
    }
    try {
        $targetResults += $rs.Powershell.EndInvoke($rs.Handle)
    } catch {
        $targetResults += [PSCustomObject]@{ Name = 'UNKNOWN'; HttpTokens = @('HTTP:ERROR'); PingResult = 'Timeout'; IsUrl = $true }
    }
    $rs.Powershell.Dispose()
}

$runspacePool.Close()
$runspacePool.Dispose()
$targetLookup = @{}

foreach ($res in $targetResults) { $targetLookup[$res.Name] = $res }

if ($FakeError) {
    Write-Host "[INFO] FakeError mode: injecting UNSUP into HTTP/TLS1.2" -ForegroundColor Magenta
    foreach ($res in $targetResults) {
        if ($res.IsUrl -and $res.HttpTokens.Count -ge 2) {
            $toks = @($res.HttpTokens)
            $toks[0] = "HTTP:UNSUP"
            $toks[1] = "TLS1.2:UNSUP"
            $res.HttpTokens = $toks
        } elseif (-not $res.IsUrl) {
            $res.PingResult = "Timeout"
        }
    }
}

$analytics = @{ OK = 0; ERROR = 0; UNSUP = 0; PingOK = 0; PingFail = 0 }

Write-Host ""
foreach ($target in $targetList) {
    $res = $targetLookup[$target.Name]
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
            if ($tok -match "OK") { $analytics.OK++ }
            elseif ($tok -match "SSL|ERR") { $analytics.ERROR++ }
            elseif ($criticalUnsup) { $analytics.ERROR++ }
            elseif ($tok -match "UNSUP") { $analytics.UNSUP++ }
        }
        Write-Host " | Ping: " -NoNewline -ForegroundColor DarkGray
        if ($res.PingResult -eq "Timeout") {
            $pingColor = "Red"
            $analytics.PingFail++
        } else {
            $pingColor = "Cyan"
            $analytics.PingOK++
        }
        Write-Host "$($res.PingResult)" -ForegroundColor $pingColor
    } else {
        Write-Host " Ping: " -NoNewline -ForegroundColor DarkGray
        if ($res.PingResult -eq "Timeout") {
            $pingColor = "Red"
            $analytics.PingFail++
        } else {
            $pingColor = "Cyan"
            $analytics.PingOK++
        }
        Write-Host "$($res.PingResult)" -ForegroundColor $pingColor
    }
}

Write-Host ""
Write-Host "=== ANALYTICS ===" -ForegroundColor Cyan
Write-Host "HTTP OK: $($analytics.OK), ERR: $($analytics.ERROR), UNSUP: $($analytics.UNSUP), Ping OK: $($analytics.PingOK), Fail: $($analytics.PingFail)" -ForegroundColor Yellow

$dateStr = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$resultFile = Join-Path $resultsDir "test_current_$dateStr.txt"
"" | Out-File $resultFile -Encoding UTF8
foreach ($target in $targetList) {
    $res = $targetLookup[$target.Name]
    if (-not $res) { continue }
    $http = $res.HttpTokens -join ' '
    Add-Content $resultFile "  $($target.Name) : $http | Ping: $($res.PingResult)"
}
Add-Content $resultFile ""
Add-Content $resultFile "=== ANALYTICS ==="
Add-Content $resultFile "HTTP OK: $($analytics.OK), ERR: $($analytics.ERROR), UNSUP: $($analytics.UNSUP), Ping OK: $($analytics.PingOK), Fail: $($analytics.PingFail)"

Write-Host ""
Write-Host "Results saved to $resultFile" -ForegroundColor Green

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

$hasRed = ($analytics.ERROR -gt 0 -or $analytics.PingFail -gt 0)
Write-Host ""
function Set-Bg { param($c) try { $Host.UI.RawUI.BackgroundColor = $c } catch { try { [Console]::BackgroundColor = $c } catch {} } }
function Set-Fg { param($c) try { $Host.UI.RawUI.ForegroundColor = $c } catch { try { [Console]::ForegroundColor = $c } catch {} } }
function Write-Banner {
    param($art, $color)
    for ($r = 0; $r -lt 3; $r++) {
        foreach ($l in $art) { Write-Host $l -ForegroundColor $color }
        if ($r -lt 2) { Write-Host "" }
    }
}
if ($hasRed) {
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
} else {
    Write-Banner -art $okArt -color 'Green'
}
Set-Bg 'Black'
Set-Fg 'Gray'
Write-Host ""
if ($hasRed -and -not $FakeError) {
    Write-Host "[INFO] Errors detected. Searching for the best config..." -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot "test configs.ps1")
}
Write-Host ""
Write-Host "Press any key to close..." -ForegroundColor Yellow
[void][System.Console]::ReadKey($true)
exit