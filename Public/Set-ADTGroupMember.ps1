function Set-ADTGroupMember {
<#
.SYNOPSIS
    Ajoute ou retire des membres sur un groupe donne.
.DESCRIPTION
    Vue "par groupe" de la gestion des appartenances, complementaire de
    Set-ADTUserGroupMembership, qui raisonne "par utilisateur". C est la forme
    attendue quand on ouvre un groupe et qu on gere sa liste de membres.

    Accepte plusieurs groupes et plusieurs membres, rend une ligne de resultat par
    couple groupe/membre, et prend en charge -WhatIf.

    Le retrait du groupe principal d un compte est refuse : Active Directory
    l interdit, et l echec brut du controleur n est pas explicite.
.PARAMETER Identity
    Groupes a modifier : nom, sAMAccountName, DN ou SID.
.PARAMETER Member
    Comptes ou groupes a ajouter.
.PARAMETER RemoveMember
    Comptes ou groupes a retirer.
.EXAMPLE
    Set-ADTGroupMember -Identity 'GS-VPN' -Member 'jcote','mtremblay' -WhatIf
.EXAMPLE
    $sortants = @(Get-ADTGroupMember -Identity 'GS-Stagiaires' | Select-Object -ExpandProperty SamAccountName)
    Set-ADTGroupMember -Identity 'GS-Stagiaires' -RemoveMember $sortants
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [Alias('Group', 'GroupName')]
        [string[]]$Identity,

        [Parameter(ValueFromPipelineByPropertyName = $true)]
        [Alias('Add', 'AddMember')]
        [string[]]$Member,

        [Alias('Remove')]
        [string[]]$RemoveMember,

        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    begin {
        if (-not $Member -and -not $RemoveMember) { throw 'Preciser au moins -Member ou -RemoveMember.' }
        $common = Initialize-ADTConnection -Server $Server -Credential $Credential -LogPath $LogPath
        foreach ($candidate in @($Member)) {
            if ($candidate -and (@($RemoveMember) -contains $candidate)) {
                throw ('Membre present dans l ajout ET le retrait : ' + $candidate)
            }
        }
    }

    process {
        foreach ($groupId in $Identity) {
            if (-not $groupId) { continue }

            $group = $null
            try {
                $group = Resolve-ADTConsoleObject -Identity $groupId -ObjectFilter (Get-ADTConsoleClassFilter -Type Group) @common
            } catch {
                Write-ADTLog -Level 'ERROR' -Message ('Groupe introuvable : {0}' -f $groupId)
                $failure = New-Object PSObject -Property @{
                    GroupName = $groupId; Member = ''; Action = 'Recherche'; Status = 'Echec'; Error = $_.Exception.Message
                }
                $failure | Select-Object GroupName, Member, Action, Status, Error
                continue
            }
            $groupDN = [string]$group.DistinguishedName
            $groupName = [string]$group.Name

            $operations = @()
            foreach ($item in @($Member)) { if ($item) { $operations += (New-Object PSObject -Property @{ Identity = $item; Action = 'Ajout' }) } }
            foreach ($item in @($RemoveMember)) { if ($item) { $operations += (New-Object PSObject -Property @{ Identity = $item; Action = 'Retrait' }) } }

            foreach ($operation in $operations) {
                $memberId = [string]$operation.Identity
                $action = [string]$operation.Action
                $status = 'Echec'
                $errorText = ''
                $memberName = $memberId
                try {
                    $target = Resolve-ADTConsoleObject -Identity $memberId @common
                    $memberName = [string]$target.SamAccountName
                    if (-not $memberName) { $memberName = [string]$target.Name }

                    if ($action -eq 'Retrait' -and [string]$target.PrimaryGroupID -and $group.SID) {
                        $primaryRid = ($group.SID.Value -split '-')[-1]
                        if ([string]$target.PrimaryGroupID -eq $primaryRid) {
                            throw 'Ce groupe est le groupe principal du compte. Changer le groupe principal avant de retirer le membre.'
                        }
                    }

                    if ($PSCmdlet.ShouldProcess($groupName, ('{0} de {1}' -f $action, $memberName))) {
                        if ($action -eq 'Ajout') {
                            Add-ADTNativeGroupMember -Identity $groupDN -Members ([string]$target.DistinguishedName) -ErrorAction Stop @common
                            $status = 'Ajoute'
                        } else {
                            Remove-ADTNativeGroupMember -Identity $groupDN -Members ([string]$target.DistinguishedName) -Confirm:$false -ErrorAction Stop @common
                            $status = 'Retire'
                        }
                        Write-ADTLog -Level 'SUCCESS' -Message ('{0} : {1} de {2}' -f $groupName, $status, $memberName)
                    } else {
                        $status = 'Simulation'
                    }
                } catch {
                    $errorText = $_.Exception.Message
                    Write-ADTLog -Level 'ERROR' -Message ('{0} : {1} de {2} echoue : {3}' -f $groupName, $action, $memberName, $errorText)
                }
                $row = New-Object PSObject -Property @{
                    GroupName = $groupName; Member = $memberName; Action = $action; Status = $status; Error = $errorText
                }
                $row | Select-Object GroupName, Member, Action, Status, Error
            }
        }
    }
}
