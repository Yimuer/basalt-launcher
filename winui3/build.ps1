$env:DOTNET_CLI_UI_LANGUAGE = 'en'
$proj = "$env:USERPROFILE\dev\basalt-launcher3\src\BasaltLauncher3\BasaltLauncher3.csproj"
& dotnet build $proj -c Release -p:Platform=ARM64 -v minimal *> "$env:USERPROFILE\dev\basalt-launcher3\build1.log"
"exitcode=$LASTEXITCODE" | Add-Content "$env:USERPROFILE\dev\basalt-launcher3\build1.log"