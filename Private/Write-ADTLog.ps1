function Write-ADTLog {
<#
.SYNOPSIS
    Ecrit une entree horodatee dans le journal du module.
.DESCRIPTION
    Toute action ecrivant dans Active Directory doit laisser une trace : qui, quoi, quand.
    C est une exigence de base en audit et en conformite.
    Le journal est un fichier texte simple, lisible sur n importe quel serveur.
.PARAMETER Message
    Texte a journaliser.
.PARAMETER Level
    INFO, SUCCESS, WARN ou ERROR.
.PARAMETER Path
    Chemin du journal. Par defaut %LOCALAPPDATA%\PSADToolkit\PSADToolkit.log
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Message,

        [ValidateSet('INFO', 'SUCCESS', 'WARN', 'ERROR')]
        [string]$Level = 'INFO',

        [string]$Path
    )

    if (-not $Path) {
        if ($script:ADTLogPath) { $Path = $script:ADTLogPath }
        else { $Path = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'PSADToolkit.log' }
    }

    try {
        $directory = Split-Path -Parent $Path
        if ($directory -and -not (Test-Path -Path $directory)) {
            New-Item -Path $directory -ItemType Directory -Force | Out-Null
        }

        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $line  = '{0} [{1,-7}] [{2}\{3}] {4}' -f $stamp, $Level, $env:USERDOMAIN, $env:USERNAME, $Message
        Add-Content -Path $Path -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Warning ("Ecriture du journal impossible ({0}) : {1}" -f $Path, $_.Exception.Message)
    }

    switch ($Level) {
        'ERROR'   { Write-Warning $Message }
        'WARN'    { Write-Warning $Message }
        default   { Write-Verbose $Message }
    }
}
