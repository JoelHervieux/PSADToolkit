<#
.SYNOPSIS
    Fusionne le module PSADToolkit en un seul fichier .ps1 autonome.
.DESCRIPTION
    On developpe en fichiers separes (un fichier = une fonction) pour la lisibilite,
    l historique Git et les tests unitaires. On distribue un seul fichier pour pouvoir
    le deposer sur n importe quel serveur sans installation.

    Le fichier produit est autonome : aucun Import-Module, aucun chemin a configurer.
    Il suffit de le sourcer ou de l executer.

    Ce fichier de build tourne sur le poste de l administrateur (PowerShell 5.1+),
    pas sur les vieux serveurs cibles. Le fichier PRODUIT, lui, reste compatible
    PowerShell 2.0.
.PARAMETER OutputPath
    Chemin du fichier autonome a produire. Defaut : .\dist\PSADToolkit-Standalone.ps1
.EXAMPLE
    .\Build.ps1
.EXAMPLE
    .\Build.ps1 -OutputPath C:\Temp\PSADToolkit-Standalone.ps1
#>
[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'dist\PSADToolkit-Standalone.ps1')
)

$ErrorActionPreference = 'Stop'

$moduleRoot = $PSScriptRoot
$manifest   = Import-PowerShellDataFile -Path (Join-Path $moduleRoot 'PSADToolkit.psd1')
$version    = $manifest.ModuleVersion

$outputDir = Split-Path -Parent $OutputPath
if ($outputDir -and -not (Test-Path $outputDir)) {
    New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
}

$builder = New-Object System.Text.StringBuilder

[void]$builder.AppendLine(@"
<#
    PSADToolkit $version - version autonome
    Generee le $(Get-Date -Format 'yyyy-MM-dd HH:mm') par Build.ps1 - NE PAS MODIFIER A LA MAIN.

    Utilisation :
        . .\PSADToolkit-Standalone.ps1     # sourcer le fichier
        Test-ADTPrerequisite               # les fonctions sont alors disponibles

    Compatible PowerShell 2.0 et superieur (Windows Server 2008 SP2 -> 2025).
    Backend LDAP / ADSI sans RSAT. Windows PowerShell 2.0 a 5.1.
#>

# Journal par defaut (equivalent de ce que fait le .psm1)
if (`$env:LOCALAPPDATA) {
    `$script:ADTLogPath = Join-Path -Path `$env:LOCALAPPDATA -ChildPath 'PSADToolkit\PSADToolkit.log'
} else {
    `$script:ADTLogPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'PSADToolkit.log'
}
"@)

$sections = @(
    @{ Folder = 'Private'; Title = 'FONCTIONS INTERNES' },
    @{ Folder = 'Public';  Title = 'FONCTIONS PUBLIQUES' }
)

$functionCount = 0

foreach ($section in $sections) {

    $folderPath = Join-Path $moduleRoot $section.Folder
    if (-not (Test-Path $folderPath)) { continue }

    [void]$builder.AppendLine('')
    [void]$builder.AppendLine('#' + ('=' * 78))
    [void]$builder.AppendLine('#  ' + $section.Title)
    [void]$builder.AppendLine('#' + ('=' * 78))

    foreach ($file in (Get-ChildItem -Path $folderPath -Filter '*.ps1' | Sort-Object Name)) {
        [void]$builder.AppendLine('')
        [void]$builder.AppendLine('#--- ' + $file.Name + ' ' + ('-' * [Math]::Max(0, 70 - $file.Name.Length)))
        [void]$builder.AppendLine('')
        [void]$builder.AppendLine((Get-Content -Path $file.FullName -Raw))
        $functionCount++
        Write-Verbose ("Fusionne : {0}" -f $file.Name)
    }
}

# Pas d Export-ModuleMember : ce fichier n est pas un module, il est source.

$content = $builder.ToString()

# Encodage UTF-8 avec BOM : indispensable pour que PowerShell 2.0 et 5.1 lisent
# correctement les accents dans les messages et l aide integree.
$encoding = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($OutputPath, $content, $encoding)

$sizeKb = [Math]::Round((Get-Item $OutputPath).Length / 1KB, 1)
$lines  = ($content -split "`n").Count

Write-Host ""
Write-Host ("Fichier autonome genere : {0}" -f $OutputPath) -ForegroundColor Green
Write-Host ("  Version    : {0}" -f $version)
Write-Host ("  Fonctions  : {0}" -f $functionCount)
Write-Host ("  Lignes     : {0}" -f $lines)
Write-Host ("  Taille     : {0} Ko" -f $sizeKb)
Write-Host ""
Write-Host "Verification rapide de la syntaxe..." -ForegroundColor Cyan

$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($OutputPath, [ref]$null, [ref]$errors) | Out-Null

if ($errors -and $errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Warning ("Ligne {0} : {1}" -f $_.Extent.StartLineNumber, $_.Message) }
    throw ("{0} erreur(s) de syntaxe dans le fichier genere." -f $errors.Count)
}

Write-Host "Syntaxe valide." -ForegroundColor Green
