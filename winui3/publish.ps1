param(
    [switch]$SelfContained,
    [ValidateSet('ARM64', 'x64')][string]$Platform = 'ARM64'
)
$ErrorActionPreference = 'Stop'
$env:DOTNET_CLI_UI_LANGUAGE = 'en'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root
$project = Join-Path $root 'src\BasaltLauncher3\BasaltLauncher3.csproj'
$rid = if ($Platform -eq 'ARM64') { 'win-arm64' } else { 'win-x64' }
$flavor = if ($SelfContained) { 'self-contained' } else { 'framework-dependent' }
$out = Join-Path $root "artifacts\publish\$rid-$flavor"
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
$args = @('publish', $project, '-c', 'Release', "-p:Platform=$Platform", '-r', $rid, '-o', $out, '-v', 'minimal')
if ($SelfContained) {
    $args += @('--self-contained', 'true', '-p:WindowsAppSDKSelfContained=true')
} else {
    $args += @('--self-contained', 'false', '-p:WindowsAppSDKSelfContained=false')
}
& dotnet @args
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# Observed with this unpackaged WinUI project: dotnet publish omits the compiled XAML
# and PRI files even though they are present in the build output. Carry them into the
# publish directory; without them the published exe exits with stowed exception 0xC000027B.
$buildOut = Join-Path $root "src\BasaltLauncher3\bin\$Platform\Release\net8.0-windows10.0.19041.0\$rid"
$resources = @(Get-ChildItem $buildOut -File | Where-Object { $_.Extension -in '.xbf', '.pri' })
if ($resources.Count -eq 0) { throw "No XBF/PRI files found under $buildOut" }
foreach ($file in $resources) { Copy-Item $file.FullName $out -Force }
exit 0