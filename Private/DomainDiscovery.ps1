# Detection des domaines proposes a l ouverture de l interface. Chaque source est
# interrogee isolement : un poste hors domaine, une foret injoignable ou une
# approbation illisible ne doivent jamais empecher de saisir un domaine a la main.

function Get-ADTNativeDomainCandidate {
<#
.SYNOPSIS
    Domaines Active Directory vraisemblablement administrables depuis ce poste.
.DESCRIPTION
    Rassemble, sans doublon et sans echouer :
      - le domaine de l utilisateur (USERDNSDOMAIN) ;
      - le domaine de l ordinateur ;
      - les autres domaines de la foret ;
      - les domaines approuves par la foret.
    Chaque entree porte son origine pour que l operateur sache d ou elle vient.
.EXAMPLE
    Get-ADTNativeDomainCandidate | Format-Table Name, Source
#>
    [CmdletBinding()]
    param()
    $seen = @{}
    $result = New-Object System.Collections.ArrayList
    $add = {
        param([string]$Name, [string]$Source)
        if (-not $Name) { return }
        $clean = $Name.Trim().TrimEnd('.').ToLowerInvariant()
        if (-not $clean -or $seen.ContainsKey($clean)) { return }
        $seen[$clean] = $true
        [void]$result.Add((New-Object PSObject -Property @{ Name = $clean; Source = $Source }))
    }

    & $add ([string]$env:USERDNSDOMAIN) 'Domaine de la session'

    try {
        $computerDomain = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain()
        try { & $add ([string]$computerDomain.Name) 'Domaine de ce poste' } finally { $computerDomain.Dispose() }
    } catch { Write-Verbose ('Poste hors domaine ou domaine injoignable : {0}' -f $_.Exception.Message) }

    try {
        $forest = [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest()
        try {
            foreach ($member in $forest.Domains) { & $add ([string]$member.Name) 'Meme foret' }
            try {
                foreach ($trust in $forest.GetAllTrustRelationships()) { & $add ([string]$trust.TargetName) 'Foret approuvee' }
            } catch { Write-Verbose ('Approbations de foret illisibles : {0}' -f $_.Exception.Message) }
        } finally { $forest.Dispose() }
    } catch { Write-Verbose ('Foret courante injoignable : {0}' -f $_.Exception.Message) }

    foreach ($item in $result) { $item | Select-Object Name, Source }
}
