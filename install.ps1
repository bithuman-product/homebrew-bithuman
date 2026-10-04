# bithuman CLI installer for Windows: downloads the newest CLI release that carries a Windows build,
# checks its sha256 against the published .sha256 file, and installs bithuman.exe into
# %LOCALAPPDATA%\bithuman\bin (or $env:BITHUMAN_INSTALL_DIR), then puts that folder on your PATH.
#   irm https://install.bithuman.ai/windows | iex
# Environment: BITHUMAN_VERSION=cli-vX.Y.Z pins a release; BITHUMAN_INSTALL_DIR picks the directory;
# BITHUMAN_DOWNLOADS overrides the release origin (default https://downloads.bithuman.ai/homebrew-bithuman);
# BITHUMAN_MIRROR overrides the download mirror ('off' = the release origin only).
# The release origin publishes latest.json, releases.json and <tag>/<asset> (scripts/downloads-publish.py);
# bitHuman's mirror (maven.bithuman.ai, a byte-for-byte copy of each CLI release) serves the bytes first
# when it holds the version. GitHub is not used.
# The Windows build is not code-signed. Files this script downloads carry no Mark-of-the-Web, so
# Windows does not show a SmartScreen prompt for them; the sha256 check is what vouches for the bytes.
# Docs: https://docs.bithuman.ai/platforms/cli
# Everything runs inside one script block, so `irm | iex` leaves nothing behind in the
# caller's session (no preference changes, no helper functions).
& {
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue'
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $Downloads = 'https://downloads.bithuman.ai/homebrew-bithuman'
  if ($env:BITHUMAN_DOWNLOADS) { $Downloads = $env:BITHUMAN_DOWNLOADS }
  $Downloads = "$Downloads".TrimEnd('/')
  $Asset = 'bithuman-x86_64-pc-windows-msvc.zip'
  function Fail([string]$msg) { Write-Host "install: error: $msg" -ForegroundColor Red; throw "install failed" }
  function Info([string]$msg) { Write-Host "install: $msg" }
  # A busy network can be answered with 429 (or 403 with Retry-After). That means "wait", not
  # "missing": retry up to 3 times within 120 s, honouring Retry-After, then say plainly that the
  # download server is rate-limiting (DX audit 2026-09-30). No credential is ever sent.
  # -Soft (the release lookup only): an exhausted rate limit records its message in
  # $script:rateLimited and throws 'rate limited' instead of failing, so the lookup can still ask
  # the mirror, which exists for exactly this kind of origin trouble.
  $script:dlWaited = 0
  $script:rateLimited = $null
  function Invoke-Download([string]$Uri, [string]$OutFile, [switch]$Rest, [switch]$Soft) {
    $h = @{ 'User-Agent' = 'bithuman-install-ps1' }
    for ($try = 1; ; $try++) {
      try {
        if ($Rest) { return Invoke-RestMethod -Headers $h -Uri $Uri }
        if ($OutFile) { return Invoke-WebRequest -UseBasicParsing -Headers $h -Uri $Uri -OutFile $OutFile }
        return Invoke-WebRequest -UseBasicParsing -Headers $h -Uri $Uri
      } catch {
        $resp = $_.Exception.Response
        $code = 0; if ($resp) { try { $code = [int]$resp.StatusCode } catch { } }
        $wait = 0
        if ($resp) {
          try { $ra = $resp.Headers['Retry-After']; if ($ra) { $wait = [int]"$ra" } } catch { }
          if (-not $wait) { try { $wait = [int]$resp.Headers.RetryAfter.Delta.TotalSeconds } catch { } }
        }
        $limited = ($code -eq 429) -or ($code -eq 403 -and $wait -gt 0)
        if (-not $limited) { throw }
        if (-not $wait) { $wait = 10 * $try }
        if ($try -ge 3 -or ($script:dlWaited + $wait) -gt 120) {
          if ($Soft) { $script:rateLimited = "HTTP $code; retry in about ${wait}s"; throw 'rate limited' }
          Fail ("the download server is rate-limiting downloads from this network (HTTP $code); retry in about ${wait}s. " +
                "Nothing is wrong with the release. Pinning a release with `$env:BITHUMAN_VERSION = 'cli-vX.Y.Z' " +
                "skips the release lookup.")
        }
        Info "the download server is rate-limiting this network (HTTP $code); retrying in ${wait}s (attempt $($try + 1) of 3)"
        Start-Sleep -Seconds $wait
        $script:dlWaited += $wait
      }
    }
  }
  # A tag that is not plain semver (a pre-release) sorts last instead of throwing.
  function TagVersion([string]$tag) {
    try { [version]($tag -replace '^cli-v', '') } catch { [version]'0.0' }
  }

  if (-not [Environment]::Is64BitOperatingSystem) { Fail 'bithuman needs 64-bit Windows (x86_64).' }
  $arch = $env:PROCESSOR_ARCHITECTURE
  if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
  if ($arch -ne 'AMD64') { Fail "this PC is $arch; the Windows build is x86_64 (AMD64)." }

  # The mirror (scripts/mirror-cli-release.sh): maven-metadata.xml names the newest mirrored version,
  # and <version>/<asset> + .sha256 are the release's own bytes.
  $Mirror = 'https://maven.bithuman.ai/ai/bithuman/bithuman-cli'
  if ($null -ne $env:BITHUMAN_MIRROR) { $Mirror = $env:BITHUMAN_MIRROR }
  if ($Mirror -in @('off', 'none', '0')) { $Mirror = '' }
  $Mirror = "$Mirror".TrimEnd('/')
  $mh = @{ 'User-Agent' = 'bithuman-install-ps1' }
  # A release that may be installed: published, not a pre-release, a cli-v* tag, carrying the Windows asset.
  function Usable($r) {
    $r -and -not $r.draft -and -not $r.prerelease -and "$($r.tag_name)" -like 'cli-v*' -and
      ($r.assets | Where-Object { $_.name -eq $Asset })
  }

  $work = Join-Path ([IO.Path]::GetTempPath()) ('bithuman-install-' + [guid]::NewGuid())
  New-Item -ItemType Directory -Path $work | Out-Null
  try {
  $zip = Join-Path $work $Asset
  $tag = $env:BITHUMAN_VERSION
  $sidecar = $null
  $fromMirror = $false

  # The release: a pinned tag; else latest.json from the release origin (when it carries the Windows
  # asset); else the newest usable release in releases.json; else the mirror's newest version. Each
  # step stands alone, as in install.sh: a latest.json that cannot be read (a 404 while the origin
  # names no latest yet, a malformed body) still lets releases.json decide before the mirror does.
  # A rate limit on the origin is remembered and the mirror is still asked; only when the mirror
  # cannot name a release either does the run end, with the rate-limit message.
  if (-not $tag) {
    $originErr = $null
    $noWindows = $false
    try {
      $latest = Invoke-Download -Rest -Soft -Uri "$Downloads/latest.json"
      if (Usable $latest) { $tag = $latest.tag_name }
    } catch {
      if ("$_" -eq 'install failed') { throw }
      $originErr = $_.Exception.Message
    }
    if (-not $tag -and -not $script:rateLimited) {
      try {
        $rels = Invoke-Download -Rest -Soft -Uri "$Downloads/releases.json"
        $pick = @($rels) | Where-Object { Usable $_ } |
          Sort-Object { TagVersion $_.tag_name } -Descending | Select-Object -First 1
        if ($pick) { $tag = $pick.tag_name } else { $noWindows = $true }
      } catch {
        if ("$_" -eq 'install failed') { throw }
        $originErr = $_.Exception.Message
      }
    }
    if (-not $tag -and $Mirror) {
      try {
        $mc = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 -Headers $mh -Uri "$Mirror/maven-metadata.xml").Content
        if ($mc -is [byte[]]) { $mc = [Text.Encoding]::UTF8.GetString($mc) }
        $meta = [xml]"$mc".Trim([char]0xFEFF)
        $rel = "$($meta.metadata.versioning.release)".Trim()
        if ($rel -match '^\d+\.\d+\.\d+$') { $tag = "cli-v$rel"; Info "latest release (bitHuman mirror; $Downloads could not name one): $tag" }
      } catch { }
    }
    if (-not $tag) {
      if ($script:rateLimited) {
        Fail ("the download server is rate-limiting downloads from this network ($script:rateLimited), and the " +
              "bitHuman mirror could not name a release either. Nothing is wrong with the release. Pinning a " +
              "release with `$env:BITHUMAN_VERSION = 'cli-vX.Y.Z' skips the release lookup.")
      }
      if ($noWindows) { Fail 'no published bithuman release carries a Windows build yet.' }
      Fail "could not read the release list from $Downloads ($originErr). Pin one with `$env:BITHUMAN_VERSION = 'cli-vX.Y.Z'."
    }
  }

  # The bytes: the mirror first when it holds this version, else the release origin.
  if ($Mirror -and $tag -like 'cli-v*') {
    try {
      $murl = "$Mirror/$($tag -replace '^cli-v', '')/$Asset"
      $sidecar = Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 -Headers $mh -Uri "$murl.sha256"
      Info "downloading $murl"
      Invoke-WebRequest -UseBasicParsing -Headers $mh -Uri $murl -OutFile $zip | Out-Null
      $fromMirror = $true
    } catch {
      $sidecar = $null
      Remove-Item -Force -Path $zip -ErrorAction SilentlyContinue
      Info "the bitHuman mirror could not serve $tag ($($_.Exception.Message)); using the release origin"
    }
  }

  if (-not $fromMirror) {
    $base = "$Downloads/$tag"
    Info "installing bithuman $tag for Windows x86_64 (from $Downloads)"
    try {
      Invoke-Download -Uri "$base/$Asset" -OutFile $zip | Out-Null
      $sidecar = Invoke-Download -Uri "$base/$Asset.sha256"
    } catch {
      if ("$_" -eq 'install failed') { throw }
      $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch { }
      if ($code -eq 404) { Fail "the release $tag has no $Asset (or its .sha256) (HTTP 404)." }
      Fail "could not download $Asset from $Downloads ($($_.Exception.Message)); run the installer again in a minute."
    }
  } else {
    Info "installing bithuman $tag for Windows x86_64 (from the bitHuman mirror)"
  }
    $text = $sidecar.Content
    if ($text -is [byte[]]) { $text = [Text.Encoding]::ASCII.GetString($text) }
    $want = (($text.Trim()) -split '\s+')[0].ToLower()
    if ($want -notmatch '^[0-9a-f]{64}$') { Fail "the .sha256 file is malformed: '$text'" }
    $got = (Get-FileHash -Algorithm SHA256 -Path $zip).Hash.ToLower()
    if ($got -ne $want) { Fail "sha256 mismatch: downloaded $got, the release says $want. Nothing was installed." }
    Info "sha256 ok ($got)"

    $x = Join-Path $work 'x'
    Expand-Archive -Path $zip -DestinationPath $x
    if (-not (Test-Path (Join-Path $x 'bithuman.exe'))) { Fail "$Asset carries no bithuman.exe" }

    $dir = $env:BITHUMAN_INSTALL_DIR
    if (-not $dir) { $dir = Join-Path $env:LOCALAPPDATA 'bithuman\bin' }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Get-ChildItem -Path $x | Copy-Item -Destination $dir -Recurse -Force
    $installed = Join-Path $dir 'bithuman.exe'
    Info "installed $installed"

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @(($userPath -split ';') | Where-Object { $_ })
    if ($parts -notcontains $dir) {
      [Environment]::SetEnvironmentVariable('Path', (($parts + $dir) -join ';'), 'User')
      Info "added $dir to your PATH (open a new terminal to pick it up)"
    }
    if (($env:Path -split ';') -notcontains $dir) { $env:Path = "$dir;$env:Path" }
    & $installed --version
    Write-Host ''
    Write-Host 'Next:'
    Write-Host '  bithuman login            # or set BITHUMAN_API_SECRET'
    Write-Host '  bithuman run <CODE>       # one of your agents, live on bitHuman cloud'
    Write-Host '  bithuman mcp              # the MCP server for your AI tools'
  } finally {
    Remove-Item -Recurse -Force -Path $work -ErrorAction SilentlyContinue
  }
}
