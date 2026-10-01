# bithuman CLI installer for Windows: downloads the newest CLI release that carries a Windows build,
# checks its sha256 against the published .sha256 file, and installs bithuman.exe into
# %LOCALAPPDATA%\bithuman\bin (or $env:BITHUMAN_INSTALL_DIR), then puts that folder on your PATH.
#   irm https://install.bithuman.ai/windows | iex
# Environment: BITHUMAN_VERSION=cli-vX.Y.Z pins a release; BITHUMAN_INSTALL_DIR picks the directory;
# BITHUMAN_MIRROR overrides the download mirror ('off' = GitHub only);
# GITHUB_TOKEN (optional) uses your own GitHub API quota instead of this network's shared one.
# Downloads come from bitHuman's mirror (maven.bithuman.ai, a byte-for-byte copy of each GitHub
# release) first, so a normal install makes no GitHub request; GitHub is the fallback.
# The Windows build is not code-signed. Files this script downloads carry no Mark-of-the-Web, so
# Windows does not show a SmartScreen prompt for them; the sha256 check is what vouches for the bytes.
# Docs: https://docs.bithuman.ai/platforms/cli
# Everything runs inside one script block, so `irm | iex` leaves nothing behind in the
# caller's session (no preference changes, no helper functions).
& {
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue'
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $Repo = 'bithuman-product/homebrew-bithuman'
  $Asset = 'bithuman-x86_64-pc-windows-msvc.zip'
  function Fail([string]$msg) { Write-Host "install: error: $msg" -ForegroundColor Red; throw "install failed" }
  function Info([string]$msg) { Write-Host "install: $msg" }
  # GitHub answers a busy network with 429 (or 403 once the anonymous API quota of 60/hour per
  # address is spent). That means "wait", not "missing": retry up to 3 times within 120 s, honouring
  # Retry-After, then say plainly that GitHub is rate-limiting (DX audit 2026-09-30).
  $script:ghWaited = 0
  function Invoke-GitHub([string]$Uri, [string]$OutFile, [switch]$Rest) {
    $h = @{ 'User-Agent' = 'bithuman-install-ps1' }
    if ($Rest) { $h['Accept'] = 'application/vnd.github+json' }
    if ($env:GITHUB_TOKEN -and $Uri -like 'https://api.github.com/*') { $h['Authorization'] = "Bearer $($env:GITHUB_TOKEN)" }
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
        $limited = ($code -eq 429) -or ($code -eq 403 -and $wait -gt 0) -or ($code -eq 403 -and $Uri -like 'https://api.github.com/*')
        if (-not $limited) { throw }
        if (-not $wait) { $wait = 10 * $try }
        if ($try -ge 3 -or ($script:ghWaited + $wait) -gt 120) {
          Fail ("GitHub is rate-limiting downloads from this network (HTTP $code); retry in about ${wait}s. " +
                "Nothing is wrong with the release. To use your own GitHub quota, set `$env:GITHUB_TOKEN first; " +
                "pinning a release with `$env:BITHUMAN_VERSION = 'cli-vX.Y.Z' also skips the release lookup.")
        }
        Info "GitHub is rate-limiting this network (HTTP $code); retrying in ${wait}s (attempt $($try + 1) of 3)"
        Start-Sleep -Seconds $wait
        $script:ghWaited += $wait
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

  # The bitHuman mirror first (scripts/mirror-cli-release.sh): maven-metadata.xml names the newest
  # mirrored version, and <version>/<asset> + .sha256 are the GitHub release's own bytes. Anything it
  # cannot serve (down, version or asset not mirrored) falls back to GitHub below.
  $Mirror = 'https://maven.bithuman.ai/ai/bithuman/bithuman-cli'
  if ($null -ne $env:BITHUMAN_MIRROR) { $Mirror = $env:BITHUMAN_MIRROR }
  if ($Mirror -in @('off', 'none', '0')) { $Mirror = '' }
  $Mirror = "$Mirror".TrimEnd('/')
  $mh = @{ 'User-Agent' = 'bithuman-install-ps1' }

  $work = Join-Path ([IO.Path]::GetTempPath()) ('bithuman-install-' + [guid]::NewGuid())
  New-Item -ItemType Directory -Path $work | Out-Null
  try {
  $zip = Join-Path $work $Asset
  $tag = $env:BITHUMAN_VERSION
  $sidecar = $null
  $fromMirror = $false
  if ($Mirror) {
    try {
      $mtag = $tag
      if (-not $mtag) {
        $mc = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 -Headers $mh -Uri "$Mirror/maven-metadata.xml").Content
        if ($mc -is [byte[]]) { $mc = [Text.Encoding]::UTF8.GetString($mc) }
        $meta = [xml]"$mc".Trim([char]0xFEFF)
        $rel = "$($meta.metadata.versioning.release)".Trim()
        if ($rel -match '^\d+\.\d+\.\d+$') { $mtag = "cli-v$rel" }
      }
      if ($mtag -like 'cli-v*') {
        $murl = "$Mirror/$($mtag -replace '^cli-v', '')/$Asset"
        $sidecar = Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 -Headers $mh -Uri "$murl.sha256"
        Info "downloading $murl"
        Invoke-WebRequest -UseBasicParsing -Headers $mh -Uri $murl -OutFile $zip | Out-Null
        $tag = $mtag
        $fromMirror = $true
      }
    } catch {
      $sidecar = $null
      Remove-Item -Force -Path $zip -ErrorAction SilentlyContinue
      Info "the bitHuman mirror could not serve this install ($($_.Exception.Message)); using GitHub"
    }
  }

  if (-not $fromMirror) {
  # The release: a pinned tag, or the newest published cli-v* release that CARRIES the Windows asset.
  if (-not $tag) {
    try {
      $rels = Invoke-GitHub -Rest -Uri "https://api.github.com/repos/$Repo/releases?per_page=100"
    } catch {
      if ("$_" -eq 'install failed') { throw }
      Fail "could not list releases on GitHub ($($_.Exception.Message)). Pin one with `$env:BITHUMAN_VERSION = 'cli-vX.Y.Z'."
    }
    $pick = $rels | Where-Object {
      -not $_.draft -and -not $_.prerelease -and $_.tag_name -like 'cli-v*' -and
      ($_.assets | Where-Object { $_.name -eq $Asset })
    } | Sort-Object { TagVersion $_.tag_name } -Descending | Select-Object -First 1
    if (-not $pick) { Fail 'no published bithuman release carries a Windows build yet.' }
    $tag = $pick.tag_name
  }
  $base = "https://github.com/$Repo/releases/download/$tag"
  Info "installing bithuman $tag for Windows x86_64 (from GitHub)"
    try {
      Invoke-GitHub -Uri "$base/$Asset" -OutFile $zip | Out-Null
      $sidecar = Invoke-GitHub -Uri "$base/$Asset.sha256"
    } catch {
      if ("$_" -eq 'install failed') { throw }
      $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch { }
      if ($code -eq 404) { Fail "the release $tag has no $Asset (or its .sha256) (HTTP 404)." }
      Fail "could not download $Asset from GitHub ($($_.Exception.Message)); run the installer again in a minute."
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
