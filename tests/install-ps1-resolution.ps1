# Offline end-to-end test for install.ps1's release resolution: which tag it installs, and from
# where, when latest.json / releases.json / the mirror answer or fail. Runs the WHOLE installer
# (pwsh 7 on Linux, macOS or Windows) against a local HTTP server that plays the release origin
# and the mirror. Needs python3 for the server. Nothing leaves 127.0.0.1.
#   pwsh -NoProfile -File tests/install-ps1-resolution.ps1
#
# The case that motivated it (2026-10, the move to downloads.bithuman.ai): a latest.json that
# cannot be read (404 while the origin names no latest yet) must still let releases.json decide,
# exactly as install.sh does, instead of dropping straight to the mirror's metadata.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $root 'install.ps1'
$asset = 'bithuman-x86_64-pc-windows-msvc.zip'

$work = Join-Path ([IO.Path]::GetTempPath()) ('ps1-resolution-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $work | Out-Null
$stage = Join-Path $work 'stage'; New-Item -ItemType Directory -Path $stage | Out-Null
Set-Content -Path (Join-Path $stage 'bithuman.exe') -Value 'not a real binary'
$zip = Join-Path $work $asset
Compress-Archive -Path (Join-Path $stage 'bithuman.exe') -DestinationPath $zip
$sha = (Get-FileHash -Algorithm SHA256 -Path $zip).Hash.ToLower()

# The server reads its routes from routes.json on every request, so each case only rewrites it.
$routes = Join-Path $work 'routes.json'
$hits = Join-Path $work 'hits.log'
$port = Get-Random -Minimum 20000 -Maximum 40000
$server = @"
import http.server, json, sys
ROUTES, HITS, ZIP = sys.argv[1], sys.argv[2], sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(HITS, 'a') as f: f.write(self.path + '\n')
        r = json.load(open(ROUTES)).get(self.path)
        if r is None:
            self.send_response(404); self.end_headers(); self.wfile.write(b'not found'); return
        if r == '@429':
            self.send_response(429); self.send_header('Retry-After', '300'); self.end_headers(); return
        body = open(ZIP, 'rb').read() if r == '@zip' else r.encode()
        self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', int(sys.argv[4])), H).serve_forever()
"@
$srvFile = Join-Path $work 'fake.py'
Set-Content -Path $srvFile -Value $server
$py = Start-Process -PassThru -NoNewWindow python3 -ArgumentList @($srvFile, $routes, $hits, $zip, $port)
Start-Sleep -Milliseconds 800

$O = "http://127.0.0.1:$port/origin"
$M = "http://127.0.0.1:$port/mirror"
function Rel([string]$tag, [bool]$pre = $false, [bool]$windows = $true) {
  $assets = @(@{ name = 'bithuman-x86_64-unknown-linux-gnu.tar.gz'; size = 1; browser_download_url = "$O/$tag/x" })
  if ($windows) { $assets += @{ name = $asset; size = 1; browser_download_url = "$O/$tag/$asset" } }
  @{ tag_name = $tag; name = $tag; draft = $false; prerelease = $pre; published_at = '2026-10-01T00:00:00Z'; body = ''; assets = $assets }
}
function OriginBytes([string]$tag) { @{ "/origin/$tag/$asset" = '@zip'; "/origin/$tag/$asset.sha256" = "$sha  $asset" } }
function MirrorMeta([string]$ver) {
  @{ '/mirror/maven-metadata.xml' = "<metadata><versioning><release>$ver</release></versioning></metadata>"
     "/mirror/$ver/$asset" = '@zip'; "/mirror/$ver/$asset.sha256" = "$sha  $asset" }
}

$fail = 0
$script:allHits = @()
function Check($label, $ok) { if ($ok) { Write-Host "  PASS  $label" } else { Write-Host "  FAIL  $label"; $script:fail = 1 } }

# Runs install.ps1 in a child pwsh with the given routes and environment; returns its output.
function RunCase([hashtable]$map, [string]$mirror) {
  ($map | ConvertTo-Json -Depth 8 -Compress) | Set-Content -Path $routes
  if (Test-Path $hits) { Remove-Item $hits }
  $dir = Join-Path $work ('bin-' + [guid]::NewGuid())
  $env:PROCESSOR_ARCHITECTURE = 'AMD64'
  $env:BITHUMAN_DOWNLOADS = $O
  $env:BITHUMAN_MIRROR = $mirror
  $env:BITHUMAN_INSTALL_DIR = $dir
  Remove-Item Env:BITHUMAN_VERSION -ErrorAction SilentlyContinue
  # `& bithuman.exe --version` at the very end cannot run a placeholder off Windows; everything the
  # cases grade (which tag, from where, sha256, the install) is printed before it.
  $out = & (Get-Process -Id $PID).Path -NoProfile -File $installer *>&1 | Out-String
  $script:lastHits = if (Test-Path $hits) { @(Get-Content $hits) } else { @() }
  $script:allHits += $script:lastHits
  $out
}

try {
  # 1. latest.json 404 (origin seeded, no latest named yet): releases.json decides, not the mirror.
  $map = @{ '/origin/releases.json' = (ConvertTo-Json -Depth 8 @((Rel 'cli-v2.8.8'), (Rel 'cli-v2.8.7'))) } + (OriginBytes 'cli-v2.8.8') + (MirrorMeta '2.8.6')
  $out = RunCase $map 'off'
  Check 'latest.json 404: installs the releases.json pick (cli-v2.8.8)' ($out -match 'installing bithuman cli-v2\.8\.8 for Windows x86_64 \(from ')
  Check 'latest.json 404: sha256 checked and installed' ($out -match 'sha256 ok' -and $out -match 'install: installed ')
  Check 'latest.json 404: the mirror metadata is never asked' (-not ($lastHits -contains '/mirror/maven-metadata.xml'))

  # 1b. the same with the mirror ON: still releases.json's pick (cli-v2.8.8), not the mirror's 2.8.6.
  $out = RunCase $map $M
  Check 'latest.json 404, mirror on: tag from releases.json, not maven-metadata (2.8.6)' ($out -match 'installing bithuman cli-v2\.8\.8' -and $out -notmatch 'cli-v2\.8\.6')

  # 2. latest.json names a usable release: it wins, releases.json is not needed.
  $map = @{ '/origin/latest.json' = (ConvertTo-Json -Depth 8 (Rel 'cli-v2.8.8')) } + (OriginBytes 'cli-v2.8.8')
  $out = RunCase $map 'off'
  Check 'latest.json usable: installs it' ($out -match 'installing bithuman cli-v2\.8\.8')
  Check 'latest.json usable: releases.json not fetched' (-not ($lastHits -contains '/origin/releases.json'))

  # 3. latest.json names a pre-release: not trusted; releases.json's newest real release wins.
  $map = @{ '/origin/latest.json' = (ConvertTo-Json -Depth 8 (Rel 'cli-v2.9.0-rc1' $true))
            '/origin/releases.json' = (ConvertTo-Json -Depth 8 @((Rel 'cli-v2.9.0-rc1' $true), (Rel 'cli-v2.8.8'))) } + (OriginBytes 'cli-v2.8.8')
  $out = RunCase $map 'off'
  Check 'latest.json pre-release: falls through to the picker (cli-v2.8.8)' ($out -match 'installing bithuman cli-v2\.8\.8')

  # 4. origin unreadable (both indexes 404): the mirror's newest version, from the mirror.
  $map = (MirrorMeta '2.8.7')
  $out = RunCase $map $M
  Check 'origin down: mirror metadata names cli-v2.8.7' ($out -match 'latest release \(bitHuman mirror')
  Check 'origin down: installs cli-v2.8.7 from the mirror' ($out -match 'installing bithuman cli-v2\.8\.7 for Windows x86_64 \(from the bitHuman mirror\)')

  # 4b. the origin rate-limits the lookup (429, Retry-After beyond the cap): the mirror still decides.
  $map = @{ '/origin/latest.json' = '@429'; '/origin/releases.json' = '@429' } + (MirrorMeta '2.8.7')
  $out = RunCase $map $M
  Check 'origin rate-limited: the mirror is still asked and names cli-v2.8.7' ($out -match 'latest release \(bitHuman mirror')
  Check 'origin rate-limited: installs cli-v2.8.7 from the mirror' ($out -match 'installing bithuman cli-v2\.8\.7 for Windows x86_64 \(from the bitHuman mirror\)')
  Check 'origin rate-limited, mirror answers: no rate-limit error printed' ($out -notmatch 'rate-limiting downloads')

  # 4c. the origin rate-limits and there is no mirror: fails with the rate-limit message, not "could not read".
  $map = @{ '/origin/latest.json' = '@429'; '/origin/releases.json' = '@429' }
  $out = RunCase $map 'off'
  Check 'origin rate-limited, no mirror: names the rate limit and BITHUMAN_VERSION' ($out -match 'rate-limiting downloads from this network \(HTTP 429; retry in about 300s\)' -and $out -match 'BITHUMAN_VERSION')

  # 5. releases.json readable but no release carries the Windows zip, mirror off: says so by name.
  $map = @{ '/origin/releases.json' = (ConvertTo-Json -Depth 8 @((Rel 'cli-v2.8.8' $false $false))) }
  $out = RunCase $map 'off'
  Check 'no Windows build anywhere: fails with the by-name message' ($out -match 'no published bithuman release carries a Windows build yet')

  # 6. nothing readable anywhere: fails and suggests pinning.
  $out = RunCase @{} 'off'
  Check 'nothing readable: fails and suggests BITHUMAN_VERSION' ($out -match 'could not read the release list from' -and $out -match 'BITHUMAN_VERSION')

  # 7. across every case, each request the installer made was to the fake origin or mirror paths.
  Check "every request ($($allHits.Count)) went to the fake origin or mirror" ($allHits.Count -gt 0 -and @($allHits | Where-Object { $_ -notmatch '^/(origin|mirror)/' }).Count -eq 0)
} finally {
  Stop-Process -Id $py.Id -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force -Path $work -ErrorAction SilentlyContinue
}
if ($fail) { Write-Host 'install-ps1-resolution: FAILED'; exit 1 }
Write-Host 'install-ps1-resolution: ALL PASS'
