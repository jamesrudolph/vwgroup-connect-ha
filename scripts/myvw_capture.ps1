<#
.SYNOPSIS
  Capture read-only uiautomator dumps of the myVW app (one per screen) and
  write a redacted copy that is safe to review and share.

.DESCRIPTION
  Run it from a PowerShell prompt with the phone plugged in over USB and USB
  debugging allowed. For each screen you open on the phone, type a short name;
  the script dumps the screen, validates it and saves it. It only ever runs
  `uiautomator dump` and `adb pull`: it never taps or types on the phone.

  Raw dumps go to <OutDir>\raw (KEEP PRIVATE, never commit).
  Redacted dumps go to <OutDir>\sanitized, with a sources.json.
  The redaction is a first pass. Read the report and review the files yourself.

.EXAMPLE
  pwsh .\scripts\myvw_capture.ps1
  pwsh .\scripts\myvw_capture.ps1 -SanitizeOnly      # redo the redaction only
#>
[CmdletBinding()]
param(
    # _private/ is gitignored, so raw dumps cannot be committed by accident.
    [string]$OutDir = (Join-Path (Get-Location) '_private\myvw_capture'),
    # Canada is com.vw.carnet.releaseca; the US app is com.vw.carnet.release.
    [string]$Package = 'com.vw.carnet.releaseca',
    [string]$Contributor = '',
    [string]$Vehicle = '',
    [switch]$SanitizeOnly
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Raw = Join-Path $OutDir 'raw'
$Clean = Join-Path $OutDir 'sanitized'
$MetaFile = Join-Path $Raw 'meta.json'

function Invoke-Adb {
    param([Parameter(ValueFromRemainingArguments)][string[]]$AdbArgs)
    $ErrorActionPreference = 'Continue'
    $out = & adb @AdbArgs 2>&1
    [pscustomobject]@{ Code = $LASTEXITCODE; Text = (($out | Out-String).Trim()) }
}

function Get-Meta {
    if (Test-Path $MetaFile) { return Get-Content $MetaFile -Raw | ConvertFrom-Json }
    return $null
}

# ---------------------------------------------------------------- redaction --

function Protect-Dump {
    param([string]$Text, [hashtable]$Counts)

    # VIN: keep the 11-character prefix, zero the 6-digit serial.
    $Text = [regex]::Replace($Text, '\b([A-HJ-NPR-Z0-9]{11})([A-HJ-NPR-Z0-9]{6})\b', {
            param($m)
            # a real VIN always mixes letters and digits; skip all-letter words
            if ($m.Value -cmatch '^[A-Z]+$' -or $m.Value -cmatch '^[0-9]+$') { return $m.Value }
            $Counts.vin++
            return $m.Groups[1].Value + '000000'
        })

    $Text = [regex]::Replace($Text, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', {
            param($m) $Counts.email++; 'redacted@example.com' })

    # coordinates and other long decimals: round to one decimal (~11 km)
    $Text = [regex]::Replace($Text, '(?<![\w.])-?\d{1,3}\.\d{4,}(?![\w.])', {
            param($m)
            $Counts.decimal++
            ([math]::Round([double]::Parse($m.Value, [Globalization.CultureInfo]::InvariantCulture), 1)).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)
        })

    # North American phone numbers
    $Text = [regex]::Replace($Text, '\(?\b\d{3}\)?[ .-]\d{3}[ .-]\d{4}\b', {
            param($m) $Counts.phone++; '000-000-0000' })

    # Canadian postal codes
    $Text = [regex]::Replace($Text, '\b[A-CEGHJ-NPRSTVXY]\d[A-CEGHJ-NPRSTV-Z][ -]?\d[A-CEGHJ-NPRSTV-Z]\d\b', {
            param($m) $Counts.postal++; 'A0A 0A0' })

    return $Text
}

function Invoke-Sanitize {
    if (-not (Test-Path $Raw)) { throw "No raw folder at $Raw. Capture first." }
    New-Item -ItemType Directory -Force $Clean | Out-Null
    Get-ChildItem $Clean -Filter *.xml | Remove-Item -Force
    $files = Get-ChildItem $Raw -Filter *.xml | Sort-Object Name
    if (-not $files) { throw "No .xml dumps in $Raw." }

    $report = @()
    foreach ($f in $files) {
        $counts = @{ vin = 0; email = 0; decimal = 0; phone = 0; postal = 0 }
        $text = [IO.File]::ReadAllText($f.FullName, $Utf8NoBom)
        $redacted = Protect-Dump -Text $text -Counts $counts
        [IO.File]::WriteAllText((Join-Path $Clean $f.Name), $redacted, $Utf8NoBom)
        $report += "{0,-34} vin={1} email={2} decimals={3} phone={4} postal={5}" -f `
            $f.Name, $counts.vin, $counts.email, $counts.decimal, $counts.phone, $counts.postal
    }

    $meta = Get-Meta
    # Same shape as tests/fixtures/companion_*/sources.json: a list of per-file entries.
    $appVer = if ($meta) { $meta.app_version } else { 'UNKNOWN' }
    $pkg = if ($meta) { $meta.package } else { $Package }
    $dev = if ($meta) { "$($meta.device_model), Android $($meta.android)" } else { 'unknown device' }
    $sources = @($files | ForEach-Object {
            [ordered]@{
                fixture     = $_.Name
                contributor = $Contributor
                source      = "Local ADB capture, $(Get-Date -Format 'yyyy-MM-dd'), $Vehicle, myVW $pkg $appVer (English), $dev"
                note        = 'Read-only uiautomator dump, no taps made. Redacted: VIN serial zeroed; e-mail, phone, postal code and long decimals masked.'
            }
        })
    [IO.File]::WriteAllText((Join-Path $Clean 'sources.json'), (ConvertTo-Json -InputObject $sources -Depth 4), $Utf8NoBom)

    Write-Host "`nAutomatic redaction report (counts replaced per file):" -ForegroundColor Cyan
    $report | ForEach-Object { Write-Host "  $_" }
    Write-Host @"

The script cannot find everything. Open each file in $Clean and search for:
  your name, vehicle nickname, street address, licence plate, dealer name or
  address, place names on the map/location screen, and anything personal.
Edit those out by hand. Nothing in '$Raw' may be shared or committed.
"@ -ForegroundColor Yellow
}

if ($SanitizeOnly) { Invoke-Sanitize; return }

# ------------------------------------------------------------------ capture --

if (-not (Get-Command adb -ErrorAction SilentlyContinue)) {
    throw 'adb not found on PATH. Install Android platform-tools and reopen PowerShell.'
}

$devs = @((Invoke-Adb devices).Text -split "`r?`n" | Where-Object { $_ -match '^\S+\s+(device|unauthorized|offline)$' })
$ready = @($devs | Where-Object { $_ -match '\sdevice$' })
if ($devs -match '\sunauthorized$') { throw 'Phone says unauthorized: unlock it and tap Allow on the USB-debugging prompt.' }
if ($ready.Count -ne 1) { throw "Expected exactly one connected device in 'device' state, found $($ready.Count). Output:`n$($devs -join "`n")" }

$pk = Invoke-Adb shell pm list packages $Package
if ($pk.Text -notmatch [regex]::Escape($Package)) {
    $guess = (Invoke-Adb shell 'pm list packages | grep -i -E "vw|volkswagen|carnet"').Text
    throw "Package ${Package} is not installed. Candidates on the phone:`n$guess`nRe-run with -Package <name>."
}

$ver = ((Invoke-Adb shell "dumpsys package $Package | grep versionName").Text -split "`r?`n" | Select-Object -First 1).Trim() -replace '^versionName=', ''
$model = (Invoke-Adb shell getprop ro.product.model).Text
$android = (Invoke-Adb shell getprop ro.build.version.release).Text
Write-Host "Device: $model (Android $android)   App: ${Package} $ver" -ForegroundColor Green

New-Item -ItemType Directory -Force $Raw | Out-Null
[IO.File]::WriteAllText($MetaFile, ([ordered]@{
            package = $Package; app_version = $ver; device_model = $model; android = $android
        } | ConvertTo-Json), $Utf8NoBom)

Write-Host @"

Open a screen in the myVW app, let it stop moving, then type a short name for
it (letters, digits, dashes) and press Enter. Press Enter on an empty name to
finish. Navigate only. Do NOT tap lock/unlock, start, climate or honk buttons,
and do not pull-to-refresh.
"@

$n = (Get-ChildItem $Raw -Filter *.xml -ErrorAction SilentlyContinue | Measure-Object).Count
while ($true) {
    $name = (Read-Host "`nScreen name (empty = finish)").Trim()
    if (-not $name) { break }
    $name = ($name -replace '[^A-Za-z0-9_-]', '-')
    $n++
    $file = '{0:D2}_{1}.xml' -f $n, $name
    $dest = Join-Path $Raw $file

    $focus = (Invoke-Adb shell "dumpsys window | grep -E 'mCurrentFocus'").Text
    if ($focus -and $focus -notmatch [regex]::Escape($Package)) {
        Write-Warning "Foreground does not look like myVW: $focus"
    }

    $ok = $false
    foreach ($try in 1..4) {
        $r = Invoke-Adb shell uiautomator dump /sdcard/myvw_dump.xml
        if ($r.Code -eq 0 -and $r.Text -match 'dumped to') {
            $p = Invoke-Adb pull /sdcard/myvw_dump.xml $dest
            if ($p.Code -eq 0) {
                $xml = [IO.File]::ReadAllText($dest, $Utf8NoBom)
                $nodes = ([regex]::Matches($xml, '<node ')).Count
                if ($xml -match '<hierarchy' -and $nodes -gt 3) { $ok = $true; break }
            }
        }
        Write-Host "  dump attempt $try failed ($($r.Text)); waiting 3 s..." -ForegroundColor DarkYellow
        Start-Sleep -Seconds 3
    }
    if ($ok) {
        Write-Host "  saved $file ($nodes nodes)" -ForegroundColor Green
        if ($xml -notmatch [regex]::Escape($Package)) {
            Write-Warning "No node mentions ${Package}: this may be another app or a secured screen."
        }
    }
    else {
        Remove-Item $dest -ErrorAction SilentlyContinue
        $n--
        Write-Warning 'Could not capture this screen (busy, animating or secured). Wait for it to settle and retry.'
    }
}

Invoke-Adb shell rm -f /sdcard/myvw_dump.xml | Out-Null

if (-not $Contributor) { $Contributor = (Read-Host 'GitHub handle for sources.json').Trim() }
if (-not $Vehicle) { $Vehicle = (Read-Host 'Vehicle for sources.json (for example: Atlas 2024)').Trim() }
Invoke-Sanitize
