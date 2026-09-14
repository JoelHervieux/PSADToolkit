function Get-ADTInactiveAccount {
<#
.SYNOPSIS
    Recherche les comptes inactifs, jamais utilises ou a risque.
.DESCRIPTION
    Les comptes dormants sont l un des vecteurs d attaque les plus exploites :
    personne ne surveille un compte que personne n utilise.

    Signale egalement, car c est ce qu un auditeur regarde en premier :
      - les comptes n ayant jamais ouvert de session
      - les mots de passe qui n expirent jamais (PasswordNeverExpires)
      - les comptes dont le mot de passe n est pas requis (PasswordNotRequired)

    Note sur LastLogonDate : il s agit de l attribut repliqu2 lastLogonTimestamp,
    dont la precision est de 9 a 14 jours par defaut. C est suffisant pour un seuil
    de 90 jours, pas pour du temps reel.
.PARAMETER DaysInactive
    Seuil d inactivite en jours. Defaut 90.
.PARAMETER SearchBase
    Limiter la recherche a une OU. Fortement recommande sur un gros domaine.
.PARAMETER IncludeDisabled
    Inclure les comptes deja desactives.
.EXAMPLE
    Get-ADTInactiveAccount -DaysInactive 90 | Format-Table -AutoSize
.EXAMPLE
    Get-ADTInactiveAccount -DaysInactive 180 -SearchBase 'OU=Employes,DC=contoso,DC=local' |
        Export-Csv .\comptes-inactifs.csv -NoTypeInformation -Encoding UTF8
#>
    [CmdletBinding()]
    param(
        [ValidateRange(1, 3650)]
        [int]$DaysInactive = 90,

        [string]$SearchBase,
        [switch]$IncludeDisabled,
        [switch]$ExcludeNeverLoggedOn,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential
    )

    $prereq = Test-ADTPrerequisite -Server $Server -Credential $Credential
    if (-not $prereq.Ready) { throw ("Prerequis non satisfaits : {0}" -f $prereq.Messages) }

    $common = @{}
    if ($Server)     { $common['Server'] = $Server }
    if ($Credential) { $common['Credential'] = $Credential }
    if ($SearchBase) { $common['SearchBase'] = $SearchBase }

    $threshold = (Get-Date).AddDays(-1 * $DaysInactive)
    $properties = @('LastLogonDate', 'PasswordLastSet', 'PasswordNeverExpires', 'PasswordNotRequired',
                    'whenCreated', 'Enabled', 'Description', 'Department', 'Title', 'DistinguishedName')

    $users = Get-ADTNativeUser -Filter * -Properties $properties -ErrorAction Stop @common

    foreach ($user in $users) {

        if (-not $IncludeDisabled -and -not $user.Enabled) { continue }

        $lastLogon    = $user.LastLogonDate
        $neverLoggedOn = $false
        $daysSince    = $null

        if ($lastLogon) {
            $daysSince = [int]((Get-Date) - $lastLogon).TotalDays
        } else {
            $neverLoggedOn = $true
            if ($user.whenCreated) { $daysSince = [int]((Get-Date) - $user.whenCreated).TotalDays }
        }

        if ($neverLoggedOn -and $ExcludeNeverLoggedOn) { continue }

        $isInactive = $false
        if ($neverLoggedOn) { $isInactive = ($user.whenCreated -and $user.whenCreated -lt $threshold) }
        elseif ($lastLogon -lt $threshold) { $isInactive = $true }

        if (-not $isInactive) { continue }

        $risks = New-Object System.Collections.ArrayList
        if ($neverLoggedOn)             { [void]$risks.Add('Jamais connecte') }
        if ($user.PasswordNeverExpires) { [void]$risks.Add('Mot de passe sans expiration') }
        if ($user.PasswordNotRequired)  { [void]$risks.Add('Mot de passe non requis') }
        if ($user.Enabled)              { [void]$risks.Add('Encore actif') }

        $out = New-Object PSObject -Property @{
            SamAccountName       = $user.SamAccountName
            Name                 = $user.Name
            Enabled              = $user.Enabled
            Department           = $user.Department
            Title                = $user.Title
            LastLogonDate        = $lastLogon
            DaysSinceLastLogon   = $daysSince
            PasswordLastSet      = $user.PasswordLastSet
            PasswordNeverExpires = $user.PasswordNeverExpires
            Created              = $user.whenCreated
            Risks                = ($risks -join ', ')
            DistinguishedName    = $user.DistinguishedName
        }

        $out | Select-Object SamAccountName, Name, Enabled, Department, Title, LastLogonDate,
                             DaysSinceLastLogon, PasswordLastSet, PasswordNeverExpires, Created,
                             Risks, DistinguishedName
    }
}
