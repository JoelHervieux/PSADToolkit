function Set-ADTUserLogonHours {
<#
.SYNOPSIS
    Applique un horaire de connexion a des comptes, ou aux membres d un groupe.
.DESCRIPTION
    Le masque fourni decrit 168 heures en HEURE LOCALE, du dimanche 00 h au samedi
    23 h. La conversion vers le temps universel attendu par l annuaire est faite
    ici : un horaire 08 h - 18 h saisi a Montreal s affiche bien 08 h - 18 h dans
    la console Microsoft executee sur le meme fuseau.

    Trois portees sont possibles :
      - des comptes nommes, avec -Identity ;
      - les membres d un groupe, avec -Group ;
      - les membres d un groupe sauf certains, avec -Group et -ExcludeIdentity,
        pour qu une equipe garde un horaire different du reste du groupe.

    Un masque entierement autorise efface l attribut, ce qui correspond a
    "Toutes les heures" dans la console Microsoft. Un masque entierement interdit
    empeche toute ouverture de session : il exige -AllowNoLogonWindow, pour que ce
    soit un choix et non une faute de saisie.
.PARAMETER Identity
    Comptes vises.
.PARAMETER Group
    Groupe dont les membres recoivent l horaire.
.PARAMETER ExcludeIdentity
    Membres du groupe a laisser inchanges.
.PARAMETER Recursive
    Inclut les membres des groupes imbriques lorsque -Group est utilise.
.PARAMETER Schedule
    Masque de 168 caracteres 0 ou 1, produit par New-ADTLogonHourSchedule.
.PARAMETER AllowNoLogonWindow
    Autorise un horaire ne laissant aucune heure de connexion.
.EXAMPLE
    $horaire = New-ADTLogonHourSchedule -Day Monday,Tuesday,Wednesday,Thursday,Friday -StartHour 8 -EndHour 18
    Set-ADTUserLogonHours -Identity 'jcote' -Schedule $horaire.Mask -WhatIf
.EXAMPLE
    Set-ADTUserLogonHours -Group 'GS-Ventes' -ExcludeIdentity 'dgagnon' -Schedule $horaire.Mask
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium', DefaultParameterSetName = 'Identity')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Identity', Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('SamAccountName', 'User')]
        [string[]]$Identity,

        [Parameter(Mandatory = $true, ParameterSetName = 'Group')]
        [Alias('GroupName')]
        [string]$Group,

        [Parameter(ParameterSetName = 'Group')]
        [string[]]$ExcludeIdentity,

        [Parameter(ParameterSetName = 'Group')]
        [switch]$Recursive,

        [Parameter(Mandatory = $true)]
        [Alias('Mask')]
        [string]$Schedule,

        [switch]$AllowNoLogonWindow,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    begin {
        if (-not (Test-ADTLogonHoursMask -Mask $Schedule)) {
            throw 'Horaire invalide : 168 caracteres 0 ou 1 attendus. Utiliser New-ADTLogonHourSchedule.'
        }
        if ($Schedule -eq ('0' * 168) -and -not $AllowNoLogonWindow) {
            throw 'Cet horaire n autorise aucune heure de connexion. Confirmer avec -AllowNoLogonWindow.'
        }
        $common = Initialize-ADTConnection -Server $Server -Credential $Credential -LogPath $LogPath
        $summary = ConvertTo-ADTLogonHoursText -Mask $Schedule
        $targets = New-Object System.Collections.ArrayList

        if ($PSCmdlet.ParameterSetName -eq 'Group') {
            $excluded = @{}
            foreach ($item in @($ExcludeIdentity)) {
                if ($item) { $excluded[([string]$item).ToLowerInvariant()] = $true }
            }
            foreach ($member in @(Get-ADTGroupMember -Identity $Group -Recursive:$Recursive @common)) {
                if ([string]$member.ObjectClass -ne 'user') { continue }
                $sam = ([string]$member.SamAccountName).ToLowerInvariant()
                $dn = ([string]$member.DistinguishedName).ToLowerInvariant()
                if ($excluded.ContainsKey($sam) -or $excluded.ContainsKey($dn)) { continue }
                [void]$targets.Add([string]$member.DistinguishedName)
            }
            if (-not $targets.Count) { Write-Warning ('Aucun compte a traiter dans le groupe {0}.' -f $Group) }
        }
    }

    process {
        $queue = @()
        if ($PSCmdlet.ParameterSetName -eq 'Group') { $queue = @($targets) }
        else { $queue = @($Identity) }

        foreach ($id in $queue) {
            if (-not $id) { continue }
            $sam = $id
            $status = 'Echec'
            $errorText = ''
            try {
                $user = Resolve-ADTConsoleObject -Identity $id -ObjectFilter (Get-ADTConsoleClassFilter -Type User) @common
                $sam = [string]$user.SamAccountName
                if ($PSCmdlet.ShouldProcess($sam, ('Appliquer les horaires de connexion : {0}' -f $summary))) {
                    Set-ADTNativeLogonHours -DistinguishedName ([string]$user.DistinguishedName) -Mask $Schedule -ErrorAction Stop @common
                    $status = 'Applique'
                    Write-ADTLog -Level 'SUCCESS' -Message ('Horaires de connexion appliques a {0} : {1}' -f $sam, $summary)
                } else {
                    $status = 'Simulation'
                }
            } catch {
                $errorText = $_.Exception.Message
                Write-ADTLog -Level 'ERROR' -Message ('Horaires de connexion refuses pour {0} : {1}' -f $sam, $errorText)
            }
            $row = New-Object PSObject -Property @{
                SamAccountName = $sam; Status = $status; Schedule = $summary; Error = $errorText
            }
            $row | Select-Object SamAccountName, Status, Schedule, Error
        }
    }
}
