# Run a project bash script with Git Bash from PowerShell.
# (Plain `bash` in PowerShell starts WSL, which has no Docker/kubectl here.)
#
# Usage (from project root):
#   .\src\scripts\run.ps1 preflight
#   .\src\scripts\run.ps1 init-env --force
#   .\src\scripts\run.ps1 build-images
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Script,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$ScriptArgs
)

$gitBash = @(
    "$env:ProgramFiles\Git\bin\bash.exe",
    "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
    "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

if (-not $gitBash) {
    $git = (Get-Command git -ErrorAction SilentlyContinue).Source
    if ($git) { $gitBash = Join-Path (Split-Path (Split-Path $git)) "bin\bash.exe" }
}
if (-not $gitBash -or -not (Test-Path $gitBash)) {
    Write-Error "Git Bash not found. Install Git for Windows or run the script from Git Bash."
    exit 1
}

$root = Split-Path (Split-Path $PSScriptRoot)
$name = if ($Script.EndsWith(".sh")) { $Script } else { "$Script.sh" }
$path = Join-Path $PSScriptRoot $name
if (-not (Test-Path $path)) { Write-Error "No such script: src\scripts\$name"; exit 1 }

Push-Location $root
try {
    & $gitBash "src/scripts/$name" @ScriptArgs
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
