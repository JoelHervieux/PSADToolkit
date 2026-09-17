<#
.SYNOPSIS
    Installe le serveur GliderUI depuis un paquet .nupkg local, sans acces Internet.
.DESCRIPTION
    L interface de PSADToolkit a besoin de deux paquets : le module GliderUI et le
    module serveur propre a la plateforme, par exemple GliderUI.Server.win-x64.
    Le second porte les classes Avalonia et ne s obtient normalement que depuis
    PowerShell Gallery. Un controleur de domaine ou un serveur d administration
    isole ne l atteint pas : Install-GLIServer echoue alors sur "Hote inconnu".

    Ce script installe ce paquet a partir d un fichier deja transfere sur la
    machine. Un .nupkg est une archive ZIP : il suffit de l extraire au bon endroit.
    Le script trouve le fichier lui-meme, quel que soit le nom que le navigateur
    lui a donne, verifie qu il correspond bien a la version de GliderUI installee,
    puis controle le resultat au lieu d echouer en silence.

    Pour obtenir le fichier, ouvrir cette adresse depuis n importe quel appareil
    connecte, en remplacant la version par celle de GliderUI installee ici, et
    win-x64 par la plateforme voulue :

        https://www.powershellgallery.com/api/v2/package/GliderUI.Server.win-x64/0.4.1

.PARAMETER Path
    Dossier contenant le fichier transfere, ou chemin direct du fichier.
.PARAMETER Scope
    CurrentUser (defaut) installe dans le profil ; AllUsers pour toute la machine
    et exige une session elevee.
.PARAMETER Force
    Remplace une installation existante de la meme version.
.EXAMPLE
    pwsh -NoProfile -File .\Tests\Install-GliderUIOffline.ps1 -Path C:\Transfert
.EXAMPLE
    .\Tests\Install-GliderUIOffline.ps1 -Path C:\Transfert\GliderUI.Server.win-x64.0.4.1.nupkg -Force
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [ValidateSet('CurrentUser', 'AllUsers')][string]$Scope = 'CurrentUser',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

function Write-ADTStep { param([string]$Text) Write-Output ('  ' + $Text) }
function Stop-ADTWithAdvice { param([string]$Text) Write-Output ''; Write-Output ('ECHEC : ' + $Text); exit 1 }

Write-Output '=== Installation hors ligne du serveur GliderUI ==='
Write-Output ''

# --- 1. Version attendue ------------------------------------------------------
$gliderModules = @(Get-Module -ListAvailable -Name GliderUI | Sort-Object Version -Descending)
if (-not $gliderModules.Count) {
    Stop-ADTWithAdvice 'Le module GliderUI n est pas installe. Installer d abord GliderUI lui-meme, par la meme methode : https://www.powershellgallery.com/api/v2/package/GliderUI/<version>'
}
$expectedVersion = [string]$gliderModules[0].Version
Write-ADTStep ('Module GliderUI installe    : ' + $expectedVersion)

$architecture = 'x64'
if ([string][System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -eq 'Arm64') { $architecture = 'arm64' }
$platform = 'win'
if ($IsLinux) { $platform = 'linux' }
if ($IsMacOS) { $platform = 'osx' }
$expectedName = 'GliderUI.Server.{0}-{1}' -f $platform, $architecture
Write-ADTStep ('Serveur attendu             : ' + $expectedName + ' ' + $expectedVersion)

# --- 2. Localisation du paquet ------------------------------------------------
if (-not (Test-Path -LiteralPath $Path)) { Stop-ADTWithAdvice ('Chemin introuvable : ' + $Path) }

$candidates = @()
if (Test-Path -LiteralPath $Path -PathType Leaf) { $candidates = @(Get-Item -LiteralPath $Path) }
else { $candidates = @(Get-ChildItem -LiteralPath $Path -File -Recurse) }
if (-not $candidates.Count) { Stop-ADTWithAdvice ('Aucun fichier dans ' + $Path) }

# Le nom du fichier telecharge varie selon le navigateur : plutot que de s y fier,
# on ouvre chaque candidat comme une archive et on cherche le manifeste du module.
$package = $null
$manifestEntry = ''
foreach ($candidate in $candidates) {
    $archive = $null
    try { $archive = [System.IO.Compression.ZipFile]::OpenRead($candidate.FullName) }
    catch { continue }
    try {
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName -eq ($expectedName + '.psd1')) {
                $package = $candidate
                $manifestEntry = $entry.FullName
                break
            }
        }
    } finally { $archive.Dispose() }
    if ($package) { break }
}

if (-not $package) {
    Write-Output ''
    Write-Output ('Aucun des {0} fichier(s) examines ne contient {1}.psd1 :' -f $candidates.Count, $expectedName)
    foreach ($candidate in ($candidates | Select-Object -First 15)) {
        Write-Output ('    {0}  ({1:N0} octets)' -f $candidate.Name, $candidate.Length)
    }
    Stop-ADTWithAdvice ('Paquet {0} introuvable. Verifier le telechargement : un fichier HTML d erreur peut avoir ete enregistre a la place de l archive.' -f $expectedName)
}
Write-ADTStep ('Paquet trouve               : ' + $package.Name)

# --- 3. Controle de version ---------------------------------------------------
# Le nuspec porte la version reelle : le nom du fichier peut mentir.
$packageVersion = ''
$archive = [System.IO.Compression.ZipFile]::OpenRead($package.FullName)
try {
    foreach ($entry in $archive.Entries) {
        if ($entry.FullName -notlike '*.nuspec') { continue }
        $reader = New-Object System.IO.StreamReader($entry.Open())
        try { $content = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $match = [regex]::Match($content, '<version>\s*([^<]+?)\s*</version>')
        if ($match.Success) { $packageVersion = $match.Groups[1].Value }
        break
    }
} finally { $archive.Dispose() }

if ($packageVersion) {
    Write-ADTStep ('Version du paquet           : ' + $packageVersion)
    if ($packageVersion -ne $expectedVersion) {
        Stop-ADTWithAdvice ('Le paquet est en {0} mais GliderUI est en {1}. Install-GLIServer exige la version EXACTE du module. Telecharger .../GliderUI.Server.{2}-{3}/{1}' -f $packageVersion, $expectedVersion, $platform, $architecture)
    }
}

# --- 4. Extraction ------------------------------------------------------------
# La plateforme se decide en premier : GetFolderPath('MyDocuments') rend une chaine
# vide hors Windows, et Join-Path refuse alors de construire le chemin.
if ($IsLinux -or $IsMacOS) {
    if ($Scope -eq 'AllUsers') { $root = '/usr/local/share/powershell/Modules' }
    else { $root = Join-Path $HOME '.local/share/powershell/Modules' }
} elseif ($Scope -eq 'AllUsers') {
    $root = Join-Path $env:ProgramFiles 'PowerShell\Modules'
} else {
    # Un profil redirige ou absent peut rendre MyDocuments vide : replier sur $HOME.
    $documents = [string][Environment]::GetFolderPath('MyDocuments')
    if (-not $documents) { $documents = Join-Path $HOME 'Documents' }
    $root = Join-Path $documents 'PowerShell\Modules'
}
$target = Join-Path $root (Join-Path $expectedName $expectedVersion)
Write-ADTStep ('Destination                 : ' + $target)

if (Test-Path -LiteralPath $target) {
    $existing = @(Get-ChildItem -LiteralPath $target -File -ErrorAction SilentlyContinue)
    if ($existing.Count -and -not $Force) {
        Stop-ADTWithAdvice ('La destination contient deja {0} fichier(s). Relancer avec -Force pour remplacer.' -f $existing.Count)
    }
}
$null = New-Item -Path $target -ItemType Directory -Force

$extracted = $false
try {
    # La surcharge a trois arguments, qui autorise l ecrasement, n existe que sur
    # .NET Core et suffisamment recent.
    [System.IO.Compression.ZipFile]::ExtractToDirectory($package.FullName, $target, $true)
    $extracted = $true
} catch {
    Write-Verbose ('Extraction directe indisponible : {0}' -f $_.Exception.Message)
}
if (-not $extracted) {
    # Expand-Archive n accepte que l extension .zip : un .nupkg, ou un fichier
    # renomme par le navigateur, doit d abord etre copie sous ce nom.
    $temporary = Join-Path ([System.IO.Path]::GetTempPath()) ('adt-gli-' + [Guid]::NewGuid().ToString('N') + '.zip')
    try {
        Copy-Item -LiteralPath $package.FullName -Destination $temporary -Force
        Expand-Archive -LiteralPath $temporary -DestinationPath $target -Force
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

$manifestPath = Join-Path $target ($expectedName + '.psd1')
if (-not (Test-Path -LiteralPath $manifestPath)) {
    Stop-ADTWithAdvice ('Extraction incomplete : {0} est absent de {1}.' -f ($expectedName + '.psd1'), $target)
}
Write-ADTStep ('Fichiers extraits           : ' + @(Get-ChildItem -LiteralPath $target -Recurse -File).Count)

# --- 5. Verification ----------------------------------------------------------
Write-Output ''
Write-Output '=== Verification ==='
$serverModule = @(Get-Module -ListAvailable -Name $expectedName |
    Where-Object { [string]$_.Version -eq $expectedVersion })
if (-not $serverModule.Count) {
    Stop-ADTWithAdvice ('PowerShell ne voit pas {0} {1}. Verifier que {2} figure bien dans $env:PSModulePath.' -f $expectedName, $expectedVersion, $root)
}
Write-ADTStep ('Module visible par PowerShell : OUI')

if (Get-Module -Name GliderUI) {
    Write-Output ''
    Write-Output 'GliderUI est deja charge dans CETTE session : les classes ne peuvent pas y etre'
    Write-Output 'ajoutees a chaud. Fermer toutes les fenetres PowerShell, en ouvrir une neuve, puis :'
    Write-Output ''
    Write-Output '    Import-Module GliderUI'
    Write-Output "    'GliderUI.Avalonia.Markup.Xaml.AvaloniaRuntimeXamlLoader' -as [type]"
    Write-Output ''
    Write-Output 'Si la seconde ligne affiche le nom du type, lancer Lancer.cmd.'
    exit 0
}

Import-Module GliderUI -ErrorAction Stop
$loader = 'GliderUI.Avalonia.Markup.Xaml.AvaloniaRuntimeXamlLoader' -as [type]
if ($loader) {
    Write-ADTStep 'Type AvaloniaRuntimeXamlLoader : RESOLU'
    Write-Output ''
    Write-Output 'SUCCES. Fermer cette fenetre et lancer Lancer.cmd.'
    exit 0
}

Write-ADTStep 'Type AvaloniaRuntimeXamlLoader : TOUJOURS INTROUVABLE'
Write-Output ''
Write-Output 'Le serveur est installe et visible, mais les classes ne se chargent pas. La cause'
Write-Output 'n est donc plus le reseau. Lancer le diagnostic complet et transmettre sa sortie :'
Write-Output ''
Write-Output '    pwsh -NoProfile -File .\Tests\Test-GliderUI.ps1'
exit 1
