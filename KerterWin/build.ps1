# Compila KerterWin en tu PC con Windows y deja el .exe en .\publish\KerterWin.exe
# Requisito: .NET 8 SDK (https://dotnet.microsoft.com/download/dotnet/8.0)
$ErrorActionPreference = "Stop"
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
dotnet publish "$PSScriptRoot\src\KerterWin\KerterWin.csproj" -c Release -r "win-$arch" -p:Platform=$arch `
    --self-contained true -o "$PSScriptRoot\publish"
Write-Host "Listo: $PSScriptRoot\publish\KerterWin.exe"
