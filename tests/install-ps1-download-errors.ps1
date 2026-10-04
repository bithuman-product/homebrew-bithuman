# Offline test for install.ps1's download retry helper (Invoke-Download). Runs on any pwsh 7
# (Linux/macOS/Windows): pulls the helper out of install.ps1 through the AST and points it at a
# local HTTP server that plays the release origin. Needs python3 for the server.
#   pwsh -NoProfile -File tests/install-ps1-download-errors.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tokens = $null; $errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'install.ps1'), [ref]$tokens, [ref]$errs)
if ($errs.Count) { $errs | ForEach-Object { Write-Host "PARSE ERROR: $_" }; exit 1 }
$fns = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in 'Fail','Info','Invoke-Download' }, $true)
if ($fns.Count -ne 3) { Write-Host "FAIL: expected Fail, Info, Invoke-Download in install.ps1"; exit 1 }
foreach ($f in $fns) { . ([scriptblock]::Create($f.Extent.Text)) }
$script:dlWaited = 0

$port = Get-Random -Minimum 20000 -Maximum 40000
$server = @"
import http.server, sys
seq = {'/flaky': [429, 200], '/long': [429], '/missing': [404]}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        codes = seq.get(self.path, [200])
        code = codes.pop(0) if len(codes) > 1 else codes[0]
        self.send_response(code)
        if code == 429:
            self.send_header('Retry-After', '1' if self.path == '/flaky' else '300')
        self.end_headers()
        self.wfile.write(b'ok' if code == 200 else b'err')
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', $port), H).serve_forever()
"@
$srvFile = Join-Path ([IO.Path]::GetTempPath()) "dl-fake-$port.py"
Set-Content -Path $srvFile -Value $server
$py = Start-Process -PassThru -NoNewWindow python3 -ArgumentList $srvFile
Start-Sleep -Milliseconds 700
$fail = 0
function Check($label, $ok) { if ($ok) { Write-Host "  PASS  $label" } else { Write-Host "  FAIL  $label"; $script:fail = 1 } }
try {
  $r = Invoke-Download -Uri "http://127.0.0.1:$port/flaky" 6>&1 | Out-String
  Check '429 (Retry-After 1) then 200: retried and returned' ($r -match 'retrying in 1s' -and $r -match 'ok')

  $t0 = Get-Date; $msg = ''
  try { Invoke-Download -Uri "http://127.0.0.1:$port/long" 6>&1 | Out-Null } catch { $msg = "$_" }
  $out = (Invoke-Command { try { Invoke-Download -Uri "http://127.0.0.1:$port/long" } catch { } } 6>&1 | Out-String)
  Check '429 (Retry-After 300): stops at once' (((Get-Date) - $t0).TotalSeconds -lt 10)
  Check '429 (Retry-After 300): fails as install failed' ($msg -eq 'install failed')
  Check '429 (Retry-After 300): says rate-limiting, retry in about 300s' ($out -match 'rate-limiting downloads from this network \(HTTP 429\); retry in about 300s')

  $code = 0
  try { Invoke-Download -Uri "http://127.0.0.1:$port/missing" | Out-Null } catch { try { $code = [int]$_.Exception.Response.StatusCode } catch { } }
  Check '404: surfaces as 404 to the caller (not a rate limit)' ($code -eq 404)
} finally { Stop-Process -Id $py.Id -ErrorAction SilentlyContinue; Remove-Item $srvFile -ErrorAction SilentlyContinue }
if ($fail) { Write-Host 'install-ps1-download-errors: FAILED'; exit 1 }
Write-Host 'install-ps1-download-errors: ALL PASS'
