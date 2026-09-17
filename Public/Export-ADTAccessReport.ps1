function Export-ADTAccessReport {
<#
.SYNOPSIS
    Genere un rapport HTML complet sur l etat des identites et des acces du domaine.
.DESCRIPTION
    Rassemble en un seul document les elements qu un gestionnaire TI ou un auditeur
    demande chaque trimestre :
      - resume du domaine (niveau fonctionnel, nombre de comptes)
      - membres des groupes a privileges
      - comptes inactifs et jamais utilises
      - mots de passe qui n expirent jamais
      - comptes desactives toujours presents dans l annuaire

    Le HTML est genere sans dependance externe (ConvertTo-Html natif), donc le rapport
    s ouvre sur n importe quel poste, sans Excel ni navigateur particulier.
    Concu pour etre planifie dans le Planificateur de taches Windows.
.PARAMETER Path
    Chemin du fichier HTML a produire.
.PARAMETER CsvFolder
    Si fourni, exporte aussi chaque section en CSV dans ce dossier.
.EXAMPLE
    Export-ADTAccessReport -Path C:\Rapports\AD-2026-09.html
.EXAMPLE
    Export-ADTAccessReport -Path C:\Rapports\AD.html -DaysInactive 120 -CsvFolder C:\Rapports\CSV
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [ValidateRange(1, 3650)]
        [int]$DaysInactive = 90,

        [string]$SearchBase,
        [string]$CsvFolder,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    if ($LogPath) { $script:ADTLogPath = $LogPath }

    $prereq = Test-ADTPrerequisite -Server $Server -Credential $Credential
    if (-not $prereq.Ready) { throw ("Prerequis non satisfaits : {0}" -f $prereq.Messages) }

    $common = @{}
    if ($Server)     { $common['Server'] = $Server }
    if ($Credential) { $common['Credential'] = $Credential }

    Write-ADTLog -Level 'INFO' -Message "=== Debut de la generation du rapport d acces ==="

    $domain = Get-ADTNativeDomain -ErrorAction Stop @common
    $Server=$domain.Server; $common['Server']=$Server

    $scope = @{}
    foreach ($key in $common.Keys) { $scope[$key] = $common[$key] }
    if ($SearchBase) { $scope['SearchBase'] = $SearchBase }

    $allUsers = @(Get-ADTNativeUser -Filter * -Properties Enabled, PasswordNeverExpires, LastLogonDate -ErrorAction Stop @scope)
    $enabledCount  = @($allUsers | Where-Object { $_.Enabled }).Count
    $disabledCount = @($allUsers | Where-Object { -not $_.Enabled }).Count

    # --- Sections ---------------------------------------------------------
    $privileged = @(Get-ADTPrivilegedGroupMember -IncludeBuiltin -Server $Server -Credential $Credential |
                    Select-Object GroupName, MemberName, SamAccountName, ObjectClass, Enabled, LastLogonDate)

    $inactive = @(Get-ADTInactiveAccount -DaysInactive $DaysInactive -SearchBase $SearchBase -Server $Server -Credential $Credential |
                  Sort-Object DaysSinceLastLogon -Descending |
                  Select-Object SamAccountName, Name, Enabled, Department, LastLogonDate, DaysSinceLastLogon, Risks)

    $neverExpires = @($allUsers | Where-Object { $_.PasswordNeverExpires -and $_.Enabled } |
                      Select-Object SamAccountName, Name, Enabled, LastLogonDate)

    $disabled = @($allUsers | Where-Object { -not $_.Enabled } |
                  Select-Object SamAccountName, Name, LastLogonDate)

    # --- Resume -----------------------------------------------------------
    $privilegedUsers=@($privileged | Where-Object { $_.ObjectClass -eq 'user' } | Select-Object -ExpandProperty SamAccountName -Unique).Count
    $auditIssues=@($privileged | Where-Object { $_.ObjectClass -eq 'Erreur' -or $_.ObjectClass -eq 'foreignSecurityPrincipal' }).Count
    $summary = @()
    $summary += New-Object PSObject -Property @{ Indicateur = 'Limite des comptes (DN)'; Valeur = $SearchBase }
    $summary += New-Object PSObject -Property @{ Indicateur = 'Entrees non resolues / non auditees'; Valeur = $auditIssues }
    $summary += New-Object PSObject -Property @{ Indicateur = 'Domaine';                        Valeur = $domain.DNSRoot }
    $summary += New-Object PSObject -Property @{ Indicateur = 'Niveau fonctionnel';             Valeur = [string]$domain.DomainMode }
    $summary += New-Object PSObject -Property @{ Indicateur = 'Comptes utilisateurs (total)';   Valeur = $allUsers.Count }
    $summary += New-Object PSObject -Property @{ Indicateur = 'Comptes actifs';                 Valeur = $enabledCount }
    $summary += New-Object PSObject -Property @{ Indicateur = 'Comptes desactives';             Valeur = $disabledCount }
    $summary += New-Object PSObject -Property @{ Indicateur = ('Comptes inactifs (> {0} j)' -f $DaysInactive); Valeur = $inactive.Count }
    $summary += New-Object PSObject -Property @{ Indicateur = 'Comptes a privileges';           Valeur = $privilegedUsers }
    $summary += New-Object PSObject -Property @{ Indicateur = 'Mots de passe sans expiration';  Valeur = $neverExpires.Count }
    # Date de generation au format regional du poste, comme tout ce que PSADToolkit affiche.
    $summary += New-Object PSObject -Property @{ Indicateur = 'Genere le';                      Valeur = (Format-ADTDateTime -Value (Get-Date)) }
    $summary += New-Object PSObject -Property @{ Indicateur = 'Genere par';                     Valeur = (Get-ADTOperatorName) }

    $summary = $summary | Select-Object Indicateur, Valeur

    # --- Assemblage HTML ---------------------------------------------------
    $css = @"
<style>
body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #1c1c1c; background: #fafafa; }
h1 { font-size: 22px; border-bottom: 3px solid #2f5d8f; padding-bottom: 8px; }
h2 { font-size: 16px; margin-top: 32px; color: #2f5d8f; }
table { border-collapse: collapse; width: 100%; background: #fff; font-size: 12px; margin-top: 8px; }
th { background: #2f5d8f; color: #fff; text-align: left; padding: 7px 9px; }
td { border-bottom: 1px solid #e3e3e3; padding: 6px 9px; }
tr:nth-child(even) td { background: #f5f7fa; }
.note { color: #666; font-size: 11px; margin-top: 4px; }
.empty { color: #666; font-style: italic; padding: 8px 0; }
</style>
"@

    $toFragment = {
        param($data, $title, $note)
        $html = "<h2>$title</h2>"
        if ($note) { $html += "<div class='note'>$note</div>" }
        if ($data -and @($data).Count -gt 0) {
            $html += ($data | ConvertTo-Html -Fragment) -join "`n"
        } else {
            $html += "<div class='empty'>Aucun element.</div>"
        }
        return $html
    }

    $body  = "<h1>Rapport d acces Active Directory - $($domain.DNSRoot)</h1>"
    $body += & $toFragment $summary     'Resume' ''
    $body += & $toFragment $privileged  'Comptes a privileges' 'Domaine selectionne uniquement (pas toute la foret). Groupes resolus par SID, membres imbriques et groupes principaux. NON AUDITE / foreignSecurityPrincipal indiquent une couverture incomplete.'
    $body += & $toFragment $inactive    ("Comptes inactifs (plus de $DaysInactive jours)") 'Base sur lastLogonTimestamp : precision de 9 a 14 jours.'
    $body += & $toFragment $neverExpires 'Comptes actifs dont le mot de passe n expire jamais' ''
    $body += & $toFragment $disabled    'Comptes desactives encore presents dans l annuaire' ''

    $html = ConvertTo-Html -Head $css -Body $body -Title 'Rapport d acces Active Directory'

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -Path $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    $html | Out-File -FilePath $Path -Encoding UTF8 -Force -ErrorAction Stop

    # --- Exports CSV optionnels --------------------------------------------
    if ($CsvFolder) {
        if (-not (Test-Path -Path $CsvFolder)) { New-Item -Path $CsvFolder -ItemType Directory -Force | Out-Null }
        $privileged   | Export-Csv -Path (Join-Path $CsvFolder 'comptes-privileges.csv')   -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        $inactive     | Export-Csv -Path (Join-Path $CsvFolder 'comptes-inactifs.csv')     -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        $neverExpires | Export-Csv -Path (Join-Path $CsvFolder 'mdp-sans-expiration.csv')  -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        $disabled     | Export-Csv -Path (Join-Path $CsvFolder 'comptes-desactives.csv')   -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
    }

    Write-ADTLog -Level 'SUCCESS' -Message ("Rapport genere : {0}" -f $Path)

    $result = New-Object PSObject -Property @{
        ReportPath        = $Path
        Domain            = $domain.DNSRoot
        TotalUsers        = $allUsers.Count
        EnabledUsers      = $enabledCount
        DisabledUsers     = $disabledCount
        InactiveUsers     = $inactive.Count
        PrivilegedEntries = $privileged.Count
        NeverExpires      = $neverExpires.Count
    }

    return ($result | Select-Object ReportPath, Domain, TotalUsers, EnabledUsers, DisabledUsers, InactiveUsers, PrivilegedEntries, NeverExpires)
}
