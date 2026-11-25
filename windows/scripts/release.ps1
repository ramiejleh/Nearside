<#
Builds Nearside's Windows release: an installer for each architecture, its entry in the update
feed and the winget manifests. Runs on Windows 11 (x64 or ARM64: both are built either way).

  windows\scripts\release.ps1 -Version 0.2.0 -Apk <app-release.apk> [-Arch x64,arm64] [-NoSign] [-NoFeed]
    -> windows\build\release\Nearside-<version>-<arch>.exe (+ .sha256), a new entry at the top of
       site\appcast-windows.xml and winget\ manifests (for microsoft/winget-pkgs)

Nothing personal lives in the repo; everything comes from your environment:
  NEARSIDE_SIGN_CERT      SHA-1 thumbprint of the code-signing certificate in your certificate
                          store (a USB token's or a cloud signing service's driver puts it there)
  NEARSIDE_TIMESTAMP_URL  the timestamp server (default: http://time.certum.pl)
  NEARSIDE_UPDATE_KEY     winsparkle-tool's private key file (default: %USERPROFILE%\nearside-winsparkle.key)
  NEARSIDE_FFMPEG_X64 / NEARSIDE_FFMPEG_ARM64   FFmpeg's shared LGPL builds (BtbN's
                          ffmpeg-n8.1-latest-win64/winarm64-lgpl-shared-8.1; default: in %USERPROFILE%\deps)

One-time setup:
  Inno Setup 7, the Swift toolchain, the Visual Studio Build Tools (C++ for x64 and ARM64) and the .NET 10 SDK.
  The update-signing key: run winsparkle-tool (in %USERPROFILE%\.nuget\packages\winsparkle\0.9.4\tools,
    after one build of the app) with  generate-key --file %USERPROFILE%\nearside-winsparkle.key
    Keep the file safe (no key, no updates); put the public key it prints in windows\App\Updates.cs.
  The phone app: the release APK from the Mac (mac/scripts/release.sh builds it, signed with the
    release key), with Gradle's output-metadata.json beside it (it has the versionCode).

-NoSign builds unsigned (SmartScreen warns about such an installer); -NoFeed leaves the update feed
and the git checks alone (for trying the script; pass -Build then if this isn't a git checkout).
#>
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$Apk,
    [string[]]$Arch = @('x64', 'arm64'),
    [int]$Build = 0,
    [switch]$NoSign,
    [switch]$NoFeed
)
$ErrorActionPreference = 'Stop'
function Fail([string]$message) { [Console]::Error.WriteLine("error: $message"); exit 1 }
function Step([string]$message) { Write-Host "==> $message" }
# Tools report failure by exit code; what they print on stderr (warnings) isn't an error here
# (Windows PowerShell 5 would stop on it otherwise).
function Native([string]$exe, [string[]]$arguments) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $exe @arguments 2>&1 | ForEach-Object { "$_" } } finally { $ErrorActionPreference = $saved }
}
function Run([string]$exe, [string[]]$arguments) {
    Native $exe $arguments | Write-Host
    if ($LASTEXITCODE -ne 0) { Fail "$([IO.Path]::GetFileName($exe)) failed ($LASTEXITCODE)" }
}
function GitOut([string[]]$arguments) { Native 'git.exe' (@('-C', $Repo) + $arguments) | Where-Object { $_ -notmatch '^fatal:' } }

$Windows = Split-Path -Parent $PSScriptRoot
$Repo = Split-Path -Parent $Windows
$Out = Join-Path $Windows 'build\release'

# --- Checks first, so a release never half-builds. ---------------------------------------
if ($Version -notmatch '^\d+\.\d+\.\d+$') { Fail "the version is three numbers, e.g. 0.2.0" }
foreach ($a in $Arch) { if ($a -notin @('x64', 'arm64')) { Fail "unknown architecture $a (x64 or arm64)" } }
if (-not (Test-Path $Apk)) { Fail "no APK at $Apk" }
$Apk = (Resolve-Path $Apk).Path
$metadata = Join-Path (Split-Path -Parent $Apk) 'output-metadata.json'
if (-not (Test-Path $metadata)) { Fail "no output-metadata.json next to the APK (Gradle writes it; it has the versionCode)" }
$ApkVersion = [int](Get-Content $metadata -Raw | ConvertFrom-Json).elements[0].versionCode
if ($ApkVersion -le 0) { Fail "no versionCode in $metadata" }

$git = Get-Command git -ErrorAction SilentlyContinue
$isCheckout = $git -and (GitOut @('rev-parse', '--is-inside-work-tree')) -eq 'true'
if ($Build -le 0) {
    if (-not $isCheckout) { Fail "not a git checkout: pass -Build <number>" }
    $Build = [int](GitOut @('rev-list', '--count', 'HEAD')) # the commit count, as on the Mac
}
if (-not $NoFeed) {
    if (-not $isCheckout) { Fail "the update feed needs a git checkout (or use -NoFeed)" }
    if (GitOut @('status', '--porcelain')) { Fail "commit everything first: the build number is the commit count" }
    $UpdateKey = if ($env:NEARSIDE_UPDATE_KEY) { $env:NEARSIDE_UPDATE_KEY } else { Join-Path $env:USERPROFILE 'nearside-winsparkle.key' }
    if (-not (Test-Path $UpdateKey)) { Fail "no update-signing key at $UpdateKey (see the top of this script)" }
    if ((Get-Content (Join-Path $Windows 'App\Updates.cs') -Raw) -match 'PublicKey = "";') {
        Fail "no public key in windows\App\Updates.cs (see the top of this script)"
    }
}

$kits = "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
$hostKits = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
$SignTool = Get-ChildItem $kits -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
    Where-Object { $_.Directory.Name -eq $hostKits } | Sort-Object FullName | Select-Object -Last 1
$MsiDb = Get-ChildItem $kits -Recurse -Filter msidb.exe -ErrorAction SilentlyContinue | Sort-Object FullName | Select-Object -Last 1
if (-not $MsiDb) { Fail "msidb.exe not found (it comes with the Windows SDK)" }
if (-not $NoSign) {
    if (-not $env:NEARSIDE_SIGN_CERT) { Fail "set NEARSIDE_SIGN_CERT to your code-signing certificate's thumbprint (or use -NoSign)" }
    if (-not $SignTool) { Fail "signtool.exe not found (it comes with the Windows SDK)" }
    $cert = Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My | Where-Object { $_.Thumbprint -eq $env:NEARSIDE_SIGN_CERT }
    if (-not $cert) { Fail "no certificate with thumbprint $env:NEARSIDE_SIGN_CERT in your certificate store" }
    $Timestamp = if ($env:NEARSIDE_TIMESTAMP_URL) { $env:NEARSIDE_TIMESTAMP_URL } else { 'http://time.certum.pl' }
    $SignArgs = @('sign', '/sha1', $env:NEARSIDE_SIGN_CERT, '/fd', 'sha256', '/tr', $Timestamp, '/td', 'sha256')
}
$Iscc = @("$env:LOCALAPPDATA\Programs\Inno Setup 7\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup 7\ISCC.exe", "$env:ProgramFiles\Inno Setup 7\ISCC.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $Iscc) { Fail "Inno Setup 7 not found" }
$SwiftRoot = "$env:LOCALAPPDATA\Programs\Swift"
$SwiftVersion = (Get-ChildItem "$SwiftRoot\Redistributables" -Directory | Sort-Object Name | Select-Object -Last 1).Name
if (-not $SwiftVersion) { Fail "the Swift toolchain's redistributables weren't found in $SwiftRoot" }
$VS = Native "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" @('-latest', '-products', '*', '-property', 'installationPath') | Select-Object -First 1
$Crt = Get-ChildItem "$VS\VC\Redist\MSVC" -Directory | Where-Object { $_.Name -match '^\d' } | Sort-Object Name | Select-Object -Last 1
if (-not $Crt) { Fail "the Visual C++ redistributable files weren't found in $VS" }
foreach ($a in $Arch) {
    $ff = if ($a -eq 'x64') { $env:NEARSIDE_FFMPEG_X64 } else { $env:NEARSIDE_FFMPEG_ARM64 }
    if (-not $ff) { $ff = Join-Path $env:USERPROFILE "deps\ffmpeg-n8.1-latest-$(if ($a -eq 'x64') { 'win64' } else { 'winarm64' })-lgpl-shared-8.1" }
    if (-not (Test-Path "$ff\bin\avcodec-*.dll")) { Fail "FFmpeg for $a not found in $ff" }
}

# UTF-8 without a byte-order mark (Windows PowerShell 5's Set-Content would add one).
function Write-Text([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text.Replace("`r`n", "`n")) }

function Sign([string[]]$files) {
    if ($NoSign) { return }
    Run $SignTool.FullName ($SignArgs + $files)
}

# The Swift runtime for one architecture, from the toolchain's redistributable merge module.
function Copy-SwiftRuntime([string]$a, [string]$to) {
    $msm = "$SwiftRoot\Redistributables\$SwiftVersion\rtl.shared.$(if ($a -eq 'x64') { 'amd64' } else { 'arm64' }).msm"
    $work = Join-Path ([IO.Path]::GetTempPath()) "nearside-swift-$a"
    if (Test-Path $work) { Remove-Item $work -Recurse -Force }
    New-Item -ItemType Directory "$work\files" | Out-Null
    Copy-Item $msm "$work\rtl.msm"
    Run $MsiDb.FullName @('-d', "$work\rtl.msm", '-f', $work, '-e', 'File')
    Run $MsiDb.FullName @('-d', "$work\rtl.msm", '-f', $work, '-x', 'MergeModule.CABinet')
    Run "$env:SystemRoot\System32\expand.exe" @("$work\MergeModule.CABinet", '-F:*', "$work\files")
    foreach ($row in (Get-Content "$work\File.idt" | Select-Object -Skip 3)) {
        $columns = $row -split "`t"
        $name = ($columns[2] -split '\|')[-1] # "short|long"
        if ($name -like '*.dll') { Copy-Item "$work\files\$($columns[0])" (Join-Path $to $name) -Force }
    }
    Remove-Item $work -Recurse -Force
}

New-Item -ItemType Directory $Out -Force | Out-Null
$Installers = @{}
foreach ($a in $Arch) {
    $triple = if ($a -eq 'x64') { 'x86_64' } else { 'aarch64' }
    $platform = if ($a -eq 'x64') { 'x64' } else { 'ARM64' }
    $ff = if ($a -eq 'x64') { $env:NEARSIDE_FFMPEG_X64 } else { $env:NEARSIDE_FFMPEG_ARM64 }
    if (-not $ff) { $ff = Join-Path $env:USERPROFILE "deps\ffmpeg-n8.1-latest-$(if ($a -eq 'x64') { 'win64' } else { 'winarm64' })-lgpl-shared-8.1" }
    $stage = Join-Path $Windows "build\stage\$a"
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }

    Step "Building the engine for $a"
    Push-Location $Windows
    try {
        Run swift @('build', '-c', 'release', '--arch', $triple, '--product', 'NearsideBridge')
        $bin = (Native 'swift' @('build', '-c', 'release', '--arch', $triple, '--show-bin-path') | Select-Object -Last 1).Trim()
    } finally { Pop-Location }
    if (-not (Test-Path "$bin\NearsideBridge.dll")) { Fail "NearsideBridge.dll isn't in $bin" }

    Step "Building the camera for $a"
    Run "$env:ComSpec" @('/c', (Join-Path $Windows 'Camera\build.cmd'), $a)

    Step "Building the app for $a"
    Run dotnet @('publish', (Join-Path $Windows 'App\Nearside.csproj'), '-c', 'Release', '-r', "win-$a", "-p:Platform=$platform",
        '--self-contained', 'true', "-p:Version=$Version", "-p:NearsideBuild=$Build", "-p:SwiftBuildDir=$bin",
        "-p:FFmpegDir=$ff", '-o', $stage, '-v', 'quiet', '-nologo')
    foreach ($needed in @('Nearside.exe', 'NearsideBridge.dll', 'NearsideCamera.dll', 'WinSparkle.dll', 'avcodec-62.dll')) {
        if (-not (Test-Path "$stage\$needed")) { Fail "$needed is missing from the $a build" }
    }

    Step "Adding the runtimes, the phone app and the licences"
    Copy-SwiftRuntime $a $stage
    Copy-Item "$($Crt.FullName)\$a\Microsoft.VC143.CRT\*.dll" $stage -Force
    Copy-Item $Apk "$stage\phone-app.apk"
    Set-Content "$stage\phone-app.version" $ApkVersion -NoNewline -Encoding ascii
    Copy-Item (Join-Path $Repo 'LICENSE') "$stage\LICENSE.txt"
    Copy-Item (Join-Path $Repo 'NOTICE') "$stage\NOTICE.txt"
    Copy-Item "$ff\LICENSE.txt" "$stage\FFmpeg-LICENSE.txt"
    Copy-Item "$env:USERPROFILE\.nuget\packages\winsparkle\0.9.4\COPYING" "$stage\WinSparkle-COPYING.txt"
    Get-ChildItem $stage -Recurse -Include *.pdb | Remove-Item

    Sign @("$stage\Nearside.exe", "$stage\Nearside.dll", "$stage\NearsideBridge.dll", "$stage\NearsideCamera.dll")

    Step "Making the $a installer"
    $isccArgs = @("/DVersion=$Version", "/DArch=$a", "/DSource=$stage", "/DOutput=$Out", '/Q')
    if (-not $NoSign) { $isccArgs += @('/DSign', "/Snearside=`"$($SignTool.FullName)`" $($SignArgs -join ' ') `$f") }
    Run $Iscc ($isccArgs + (Join-Path $Windows 'installer\Nearside.iss'))
    $installer = Join-Path $Out "Nearside-$Version-$a.exe"
    $sha = (Get-FileHash $installer -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content "$installer.sha256" "$sha  $(Split-Path -Leaf $installer)" -Encoding ascii
    $Installers[$a] = @{ Path = $installer; Sha = $sha }
}

$Release = "https://github.com/ramiejleh/Nearside/releases/download/v$Version"

# --- The update feed: a signed entry for this release at the top of site\appcast-windows.xml. --
if (-not $NoFeed) {
    Step "Adding $Version to the update feed"
    $tool = "$env:USERPROFILE\.nuget\packages\winsparkle\0.9.4\tools\winsparkle-tool.exe"
    $enclosures = foreach ($a in $Installers.Keys | Sort-Object) {
        $signature = (Native $tool @('sign', '--private-key-file', $UpdateKey, $Installers[$a].Path) | Select-Object -Last 1).Trim() # sparkle:edSignature="…" length="…"
        if ($LASTEXITCODE -ne 0 -or $signature -notmatch 'edSignature') { Fail "signing the $a installer for the feed failed" }
        "      <enclosure url=`"$Release/$(Split-Path -Leaf $Installers[$a].Path)`" sparkle:os=`"windows-$a`" sparkle:installerArguments=`"/SILENT /SP- /NOCANCEL /RELAUNCH`" type=`"application/octet-stream`" $signature/>"
    }
    $previous = GitOut @('describe', '--tags', '--abbrev=0')
    $notes = if ($previous) {
        (GitOut @('log', '-n', '40', '--format=%s', "$previous..HEAD", '--no-merges')) | ForEach-Object { "<li>$([Security.SecurityElement]::Escape($_))</li>" }
    } else { '<li>The first release.</li>' }
    $item = @"
    <item>
      <title>Nearside $Version</title>
      <pubDate>$([DateTime]::UtcNow.ToString('ddd, dd MMM yyyy HH:mm:ss +0000', [Globalization.CultureInfo]::InvariantCulture))</pubDate>
      <sparkle:version>$Build</sparkle:version>
      <sparkle:shortVersionString>$Version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>10.0.22000</sparkle:minimumSystemVersion>
      <description><![CDATA[<ul>
$($notes -join "`n")
</ul>]]></description>
$($enclosures -join "`n")
    </item>
"@
    $feed = Join-Path $Repo 'site\appcast-windows.xml'
    $marker = '<!-- releases: newest first -->'
    $text = [IO.File]::ReadAllText($feed)
    if (-not $text.Contains($marker)) { Fail "the update feed's marker is missing" }
    [IO.File]::WriteAllText($feed, $text.Replace($marker, "$marker`n$($item.TrimEnd())"))
}

# --- winget: manifests for a pull request to microsoft/winget-pkgs. -----------------------
$wingetDir = Join-Path $Out "winget\manifests\n\Nearside\Nearside\$Version"
New-Item -ItemType Directory $wingetDir -Force | Out-Null
$schema = '1.10.0'
$common = "PackageIdentifier: Nearside.Nearside`nPackageVersion: $Version"
Write-Text "$wingetDir\Nearside.Nearside.yaml" @"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.version.$schema.schema.json
$common
DefaultLocale: en-US
ManifestType: version
ManifestVersion: $schema
"@
$wingetInstallers = foreach ($a in $Installers.Keys | Sort-Object) {
    "- Architecture: $a`n  InstallerUrl: $Release/$(Split-Path -Leaf $Installers[$a].Path)`n  InstallerSha256: $($Installers[$a].Sha.ToUpperInvariant())"
}
Write-Text "$wingetDir\Nearside.Nearside.installer.yaml" @"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.installer.$schema.schema.json
$common
InstallerType: inno
Scope: machine
ElevationRequirement: elevatesSelf
MinimumOSVersion: 10.0.22000.0
UpgradeBehavior: install
ProductCode: '{799C5799-6D48-4290-8D27-D73DEC50C003}_is1'
Installers:
$($wingetInstallers -join "`n")
ManifestType: installer
ManifestVersion: $schema
"@
Write-Text "$wingetDir\Nearside.Nearside.locale.en-US.yaml" @"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.defaultLocale.$schema.schema.json
$common
PackageLocale: en-US
Publisher: Nearside
PublisherUrl: https://ramiejleh.github.io/Nearside/
PublisherSupportUrl: https://github.com/ramiejleh/Nearside/issues
PackageName: Nearside
PackageUrl: https://ramiejleh.github.io/Nearside/
License: AGPL-3.0
LicenseUrl: https://github.com/ramiejleh/Nearside/blob/main/LICENSE
ShortDescription: Your Android phone on your PC - clipboard, notifications, messages, files, calls and apps
Tags:
- android
- clipboard
- notifications
- phone
- continuity
ReleaseNotesUrl: https://github.com/ramiejleh/Nearside/releases/tag/v$Version
ManifestType: defaultLocale
ManifestVersion: $schema
"@

Step "Done (build $Build)"
foreach ($a in $Installers.Keys | Sort-Object) { Write-Host "  $($Installers[$a].Path)  $($Installers[$a].Sha)" }
if ($NoSign) { Write-Host "  (unsigned: SmartScreen will warn)" }
@"

Next:
  1. Try an installer on a clean PC: install, check it connects, check the camera shows up.
  2. git tag v$Version; git push --tags (the Mac release uses the same tag).
  3. Add the installers and their .sha256 files to the GitHub release for v$Version.
  4. Commit and push site\appcast-windows.xml (PCs then see the update).
  5. Copy $Out\winget\manifests into a fork of microsoft/winget-pkgs and open a pull request.
"@ | Write-Host
