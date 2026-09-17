# Developer validation: Windows PowerShell 5.1 or PowerShell 7 + PSScriptAnalyzer.
# This does not substitute for execution on Server 2008 / PS 2.0.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$all=@(Get-ChildItem $root -Recurse -Include *.ps1,*.psm1,*.psd1)
foreach ($file in $all) {
    $tokens=$null; $parseErrors=$null
    $null=[System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$parseErrors)
    if ($parseErrors) { throw ($file.Name+': '+($parseErrors.Message -join '; ')) }
}
$targets=@(Get-ChildItem (Join-Path $root 'Private') -Filter *.ps1)+@(Get-ChildItem (Join-Path $root 'Public') -Filter *.ps1)
# Start-PSADToolkit.ps1 n est plus une cible : l interface GliderUI exige PowerShell 7.4.
# Le module, lui, reste utilisable en ligne de commande sur Windows PowerShell 2.0 a 5.1.
$targets += Get-Item (Join-Path $root 'PSADToolkit.psm1'),(Join-Path $root 'PSADToolkit.psd1'),(Join-Path $root 'dist/PSADToolkit-Standalone.ps1')
$settings=@{IncludeRules=@('PSUseCompatibleSyntax');Rules=@{PSUseCompatibleSyntax=@{Enable=$true;TargetVersions=@('2.0','5.1')}}}
foreach ($file in $targets) {
    $issues=@(Invoke-ScriptAnalyzer -Path $file.FullName -Settings $settings)
    $issues+=@(Invoke-ScriptAnalyzer -Path $file.FullName -Severity Error)
    if ($issues) { $issues | Format-List; throw ('Analyse echouee : '+$file.Name) }
    $text=[IO.File]::ReadAllText($file.FullName)
    $sourceTokens=$null; $sourceErrors=$null
    $null=[System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$sourceTokens,[ref]$sourceErrors)
    foreach ($comment in ($sourceTokens | Where-Object { $_.Kind -eq 'Comment' } | Sort-Object { $_.Extent.StartOffset } -Descending)) {
        $text=$text.Remove($comment.Extent.StartOffset,$comment.Extent.EndOffset-$comment.Extent.StartOffset)
    }
    # These APIs/syntax often pass a modern parser but are unavailable on PS 2.0.
    if ($text -match '(?im)^\s*[^#\r\n].*(\[pscustomobject\]|\[ordered\]|\$PSScriptRoot|\bConvertTo-Json\b|\bGet-CimInstance\b|\bImport-PowerShellDataFile\b|\bGet-Content\b[^\r\n]*-Raw\b)') {
        throw ('API moderne dans un fichier cible PS 2.0 : '+$file.Name)
    }
}
'PASS: syntaxe native, regles PS 2.0 / 5.1, aucune erreur PSScriptAnalyzer sur les fichiers cibles.'
