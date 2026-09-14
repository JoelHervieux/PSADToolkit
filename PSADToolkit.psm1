<#
    PSADToolkit
    Module d automatisation Active Directory.

    Compatibilite : PowerShell 2.0 et superieur (Windows Server 2008 SP2 -> 2025).
    Contraintes respectees pour les anciens serveurs :
      - pas de [pscustomobject]  -> New-Object PSObject + Select-Object
      - pas de $PSScriptRoot     -> $MyInvocation.MyCommand.Path
      - pas de ConvertTo-Json    -> exports CSV
      - pas d operateurs -in / -notin, pas de syntaxe simplifiee Where-Object
      - pas de classes PowerShell ni d operateur ternaire
#>

$script:ADTModuleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# Journal par defaut. Surchargeable via le parametre -LogPath de chaque fonction.
if ($env:LOCALAPPDATA) {
    $script:ADTLogPath = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'PSADToolkit\PSADToolkit.log'
} else {
    $script:ADTLogPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'PSADToolkit.log'
}

$exported = @()

foreach ($folder in @('Private', 'Public')) {
    $folderPath = Join-Path -Path $script:ADTModuleRoot -ChildPath $folder
    if (Test-Path -Path $folderPath) {
        $files = Get-ChildItem -Path $folderPath -Filter '*.ps1' | Sort-Object Name
        foreach ($file in $files) {
            try {
                . $file.FullName
                if ($folder -eq 'Public') { $exported += $file.BaseName }
            } catch {
                throw ("Chargement impossible de {0} : {1}" -f $file.FullName, $_.Exception.Message)
            }
        }
    }
}

Export-ModuleMember -Function $exported
