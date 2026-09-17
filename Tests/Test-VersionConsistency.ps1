# Developer validation: Windows PowerShell 5.1 or PowerShell 7.
# Verifie que tous les fichiers annoncent la version du manifeste. Voir VERSIONING.md.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$manifest=Import-PowerShellDataFile -Path (Join-Path $root 'PSADToolkit.psd1')

$numero=[string]$manifest.ModuleVersion
if ($numero -notmatch '^\d+\.\d+\.\d+$') { throw ("ModuleVersion doit etre MAJEUR.MINEUR.CORRECTIF sans suffixe : '"+$numero+"'.") }

$canal=''
if ($manifest.ContainsKey('PrivateData') -and $manifest.PrivateData -is [hashtable] -and
    $manifest.PrivateData.ContainsKey('PSData') -and $manifest.PrivateData.PSData -is [hashtable]) {
    $canal=[string]$manifest.PrivateData.PSData['Prerelease']
}
# Ni point ni espace : PowerShellGet n accepte que des alphanumeriques et le trait d union.
if ($canal -and $canal -notmatch '^[A-Za-z0-9-]+$') { throw ("Prerelease invalide : '"+$canal+"'. Attendu par exemple 'test1' ou 'rc1'.") }

$version=$numero
if ($canal) { $version=$numero+'-'+$canal }

function Read-ADTFileText { param([string]$RelativePath)
    $full=Join-Path $root $RelativePath
    if (-not (Test-Path $full)) { throw ('Fichier absent : '+$RelativePath) }
    return ([IO.File]::ReadAllText($full) -replace "^﻿",'')
}
$echecs=@()
function Test-ADTVersionIn { param([string]$RelativePath,[string]$Attendu,[string]$Description)
    $texte=Read-ADTFileText $RelativePath
    if ($texte.IndexOf($Attendu) -lt 0) {
        $script:echecs+=("{0} : {1} n annonce pas la version du manifeste. Attendu '{2}'." -f $RelativePath,$Description,$Attendu)
    }
}

Test-ADTVersionIn 'dist/PSADToolkit-Standalone.ps1' ('PSADToolkit '+$version+' - version autonome') 'en-tete du standalone'
Test-ADTVersionIn 'Start-PSADToolkit.ps1' ('PSADToolkit '+$version+' | Administration Active Directory') 'titre de la fenetre'

$readme=Read-ADTFileText 'README.md'
$titre=($readme -split "`r?`n")[0]
if ($titre -ne ('# PSADToolkit '+$version)) { $echecs+=("README.md : titre de niveau 1 '"+$titre+"'. Attendu '# PSADToolkit "+$version+"'.") }
if ($readme.IndexOf('**Version `'+$version+'`') -lt 0) { $echecs+=('README.md : encadre d etat sans la version '+$version+'.') }

$changelog=Read-ADTFileText 'CHANGELOG.md'
$sections=@([regex]::Matches($changelog,'(?m)^##\s+(\S+)(?:\s+-\s+(\d{4}-\d{2}-\d{2}))?\s*$'))
if ($sections.Count -eq 0) { $echecs+='CHANGELOG.md : aucune section de version.' }
elseif ($sections[0].Groups[1].Value -ne $version) {
    $echecs+=("CHANGELOG.md : la premiere section est '"+$sections[0].Groups[1].Value+"'. Attendu '"+$version+"' en tete, ordre decroissant.")
} elseif (-not $sections[0].Groups[2].Success) {
    $echecs+=('CHANGELOG.md : la section '+$version+' doit porter une date AAAA-MM-JJ.')
}

if ($echecs) { $echecs | ForEach-Object { Write-Warning $_ }; throw ('Versions incoherentes : '+$echecs.Count+' ecart(s). Voir VERSIONING.md.') }

'PASS: version {0} coherente dans le manifeste, le standalone, l interface, le README et le CHANGELOG.' -f $version
