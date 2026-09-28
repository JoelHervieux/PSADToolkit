<#
.SYNOPSIS
    Construit PSADToolkit.exe et le programme d installation PSADToolkit-Setup-<version>.exe.
.DESCRIPTION
    A executer sur Windows, avec Windows PowerShell 5.1 ou PowerShell 7 :

      1. prepare build\stage : les fichiers de l application, sans les tests ;
      2. compile PSADToolkit.exe avec le compilateur C# du .NET Framework 4 ;
      3. telecharge les prerequis livres dans prereq : PowerShell 7 (MSI) et les
         paquets GliderUI et GliderUI.Server de la version de reference ;
      4. appelle Inno Setup 6 (ISCC.exe) sur installer\PSADToolkit.iss.

    Le programme d installation obtenu fonctionne hors ligne. Il n est pas signe :
    SmartScreen peut demander une confirmation au premier lancement.
.PARAMETER PowerShellVersion
    Version de PowerShell 7 a livrer. Par defaut, la derniere du canal fixe dans
    Launcher.settings.psd1.
.PARAMETER NoPrerequisites
    Ne livre aucun prerequis : l installation les telechargera alors.
.PARAMETER Iscc
    Chemin de ISCC.exe, s il n est pas a l emplacement habituel.
.EXAMPLE
    .\installer\Build-Installer.ps1
#>
[CmdletBinding()]
param(
    [string]$PowerShellVersion,
    [switch]$NoPrerequisites,
    [string]$Iscc,
    [string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$installer = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $installer
. (Join-Path $root 'Tools\ADTDependency.ps1')
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Write-Host et non Write-Output : appele depuis des fonctions qui rendent un
# chemin, Write-Output ajouterait le message a leur resultat.
function Write-Step { param([string]$Text) Write-Host ('==> ' + $Text) }

# --- Version ------------------------------------------------------------------
$manifest = Import-PowerShellDataFile -Path (Join-Path $root 'PSADToolkit.psd1')
$number = [string]$manifest.ModuleVersion
$channel = [string]$manifest.PrivateData.PSData.Prerelease
$version = $number
if ($channel) { $version = $number + '-' + $channel }
$fileVersion = $number + '.0'
Write-Step ('PSADToolkit ' + $version)

$build = Join-Path $root 'build'
$stage = Join-Path $build 'stage'
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $build 'installer' }
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
$null = New-Item -ItemType Directory -Force -Path $stage, $OutputDirectory

# --- 1. Fichiers de l application ---------------------------------------------
Write-Step 'Preparation des fichiers'
foreach ($folder in @('Private', 'Public', 'UI', 'Tools', 'Examples')) {
    Copy-Item -LiteralPath (Join-Path $root $folder) -Destination (Join-Path $stage $folder) -Recurse
}
foreach ($file in @('PSADToolkit.psd1', 'PSADToolkit.psm1', 'Start-PSADToolkit.ps1', 'Launcher.ps1',
        'Launcher.settings.psd1', 'Lancer.cmd', 'LICENSE', 'README.md', 'CHANGELOG.md')) {
    Copy-Item -LiteralPath (Join-Path $root $file) -Destination $stage
}
$null = New-Item -ItemType Directory -Force -Path (Join-Path $stage 'installer')
Copy-Item -LiteralPath (Join-Path $installer 'PSADToolkit.ico') -Destination (Join-Path $stage 'installer')

# --- 2. PSADToolkit.exe -----------------------------------------------------------
Write-Step 'Compilation de PSADToolkit.exe'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path -LiteralPath $csc)) { throw 'Compilateur C# du .NET Framework 4 introuvable.' }
$source = [System.IO.File]::ReadAllText((Join-Path $installer 'PSADToolkit.Launcher.cs'))
$source = $source.Replace('AssemblyVersion("0.0.0.0")', ('AssemblyVersion("{0}")' -f $fileVersion))
$source = $source.Replace('AssemblyFileVersion("0.0.0.0")', ('AssemblyFileVersion("{0}")' -f $fileVersion))
$source = $source.Replace('AssemblyInformationalVersion("0.0.0")', ('AssemblyInformationalVersion("{0}")' -f $version))
$generated = Join-Path $build 'PSADToolkit.Launcher.cs'
[System.IO.File]::WriteAllText($generated, $source, (New-Object System.Text.UTF8Encoding($true)))
$exe = Join-Path $stage 'PSADToolkit.exe'
& $csc /nologo /target:winexe /platform:anycpu /optimize+ ('/win32icon:' + (Join-Path $installer 'PSADToolkit.ico')) `
    /reference:System.Windows.Forms.dll ('/out:' + $exe) $generated
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $exe)) { throw 'Compilation de PSADToolkit.exe en echec.' }

# --- 3. Prerequis livres ----------------------------------------------------------
if (-not $NoPrerequisites) {
    $settings = Import-PowerShellDataFile -Path (Join-Path $root 'Launcher.settings.psd1')
    $prereq = Join-Path $stage 'prereq'
    $cache = Join-Path $build 'cache'
    $null = New-Item -ItemType Directory -Force -Path $prereq, $cache

    function Get-CachedFile {
        # Les prerequis sont gardes dans build\cache : reconstruire ne retelecharge pas.
        param([string]$Url, [string]$Name)
        $path = Join-Path $cache $Name
        if (-not (Test-Path -LiteralPath $path)) {
            Write-Step ('Telechargement de ' + $Name)
            $partial = $path + '.partial'
            $client = New-Object System.Net.WebClient
            try { $client.DownloadFile($Url, $partial) } finally { $client.Dispose() }
            Move-Item -LiteralPath $partial -Destination $path -Force
        }
        return $path
    }

    if (-not $PowerShellVersion) {
        $client = New-Object System.Net.WebClient
        try { $info = ConvertFrom-Json ($client.DownloadString('https://aka.ms/pwsh-buildinfo-' + $settings.PowerShell.Channel)) }
        finally { $client.Dispose() }
        $PowerShellVersion = [string](ConvertTo-ADTVersion ([string]$info.ReleaseTag))
    }
    if ((ConvertTo-ADTVersion $PowerShellVersion) -lt (ConvertTo-ADTVersion $settings.PowerShell.MinimumVersion)) {
        throw ('PowerShell {0} est plus ancien que la version minimale {1}.' -f $PowerShellVersion, $settings.PowerShell.MinimumVersion)
    }
    $msiName = 'PowerShell-{0}-win-x64.msi' -f $PowerShellVersion
    $msi = Get-CachedFile -Url (Get-ADTPowerShellMsiUrl -Version $PowerShellVersion -Architecture x64) -Name $msiName
    Copy-Item -LiteralPath $msi -Destination $prereq

    $glider = [string]$settings.GliderUI.BaselineVersion
    foreach ($name in @('GliderUI', 'GliderUI.Server.win-x64')) {
        $fileName = '{0}.{1}.nupkg' -f $name, $glider
        $package = Get-CachedFile -Url ('https://www.powershellgallery.com/api/v2/package/{0}/{1}' -f $name, $glider) -Name $fileName
        $info = Get-ADTNupkgInfo -Path $package
        if ($info.Id -ne $name -or $info.Version -ne $glider) {
            throw ('Paquet inattendu : {0} contient {1} {2}.' -f $fileName, $info.Id, $info.Version)
        }
        Copy-Item -LiteralPath $package -Destination $prereq
    }
    Write-Step ('Prerequis livres : PowerShell {0}, GliderUI {1}' -f $PowerShellVersion, $glider)
}

# --- 4. Inno Setup ------------------------------------------------------------------
if (-not $Iscc) {
    foreach ($candidate in @((Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'), (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'))) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { $Iscc = $candidate; break }
    }
}
if (-not $Iscc) { $Iscc = [string](Get-Command -Name iscc.exe -ErrorAction SilentlyContinue).Source }
if (-not $Iscc) { throw 'Inno Setup 6 (ISCC.exe) introuvable : https://jrsoftware.org/isdl.php' }

Write-Step 'Creation du programme d installation'
& $Iscc /Q ('/DAppVersion=' + $version) ('/DFileVersion=' + $fileVersion) ('/DSourceDir=' + $stage) `
    ('/DOutputDir=' + $OutputDirectory) (Join-Path $installer 'PSADToolkit.iss')
if ($LASTEXITCODE -ne 0) { throw ('Inno Setup en echec (code {0}).' -f $LASTEXITCODE) }

$setup = Join-Path $OutputDirectory ('PSADToolkit-Setup-{0}.exe' -f $version)
if (-not (Test-Path -LiteralPath $setup)) { throw ('Programme d installation absent : ' + $setup) }
$hash = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash
Write-Step ('{0}  ({1:N1} Mo)' -f $setup, ((Get-Item -LiteralPath $setup).Length / 1MB))
Write-Output ('SHA256 : ' + $hash)
