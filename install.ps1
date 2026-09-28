# bithuman CLI installer for Windows: downloads the newest CLI release that carries a Windows build,
# checks its sha256 against the published .sha256 file, and installs bithuman.exe into
# %LOCALAPPDATA%\bithuman\bin (or $env:BITHUMAN_INSTALL_DIR), then puts that folder on your PATH.
#   irm https://install.bithuman.ai/windows | iex
# Environment: BITHUMAN_VERSION=cli-vX.Y.Z pins a release; BITHUMAN_INSTALL_DIR picks the directory.
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
  # A tag that is not plain semver (a pre-release) sorts last instead of throwing.
  function TagVersion([string]$tag) {
    try { [version]($tag -replace '^cli-v', '') } catch { [version]'0.0' }
  }

  if (-not [Environment]::Is64BitOperatingSystem) { Fail 'bithuman needs 64-bit Windows (x86_64).' }
  $arch = $env:PROCESSOR_ARCHITECTURE
  if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
  if ($arch -ne 'AMD64') { Fail "this PC is $arch; the Windows build is x86_64 (AMD64)." }

  # The release: a pinned tag, or the newest published cli-v* release that CARRIES the Windows asset.
  $tag = $env:BITHUMAN_VERSION
  if (-not $tag) {
    $headers = @{ 'User-Agent' = 'bithuman-install-ps1'; 'Accept' = 'application/vnd.github+json' }
    try {
      $rels = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$Repo/releases?per_page=100"
    } catch {
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
  Info "installing bithuman $tag for Windows x86_64"

  $work = Join-Path ([IO.Path]::GetTempPath()) ('bithuman-install-' + [guid]::NewGuid())
  New-Item -ItemType Directory -Path $work | Out-Null
  try {
    $zip = Join-Path $work $Asset
    try {
      Invoke-WebRequest -UseBasicParsing -Uri "$base/$Asset" -OutFile $zip
      $sidecar = Invoke-WebRequest -UseBasicParsing -Uri "$base/$Asset.sha256"
    } catch {
      Fail "the release $tag has no $Asset (or its .sha256): $($_.Exception.Message)"
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
