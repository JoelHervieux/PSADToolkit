function Set-ADTUserGroupMembership {
<#
.SYNOPSIS
    Ajoute ou retire un ou plusieurs utilisateurs de groupes de securite, en masse.
.DESCRIPTION
    Gestion des acces par lot, avec journalisation et prise en charge de -WhatIf.
    Accepte les identites par le pipeline, ce qui permet de chainer avec Get-ADTNativeUser :

        Get-ADTNativeUser -Filter "Department -eq 'TI'" | Set-ADTUserGroupMembership -AddGroup 'GS-VPN'
.PARAMETER Identity
    Un ou plusieurs utilisateurs (SamAccountName, DN ou objet AD).
.PARAMETER AddGroup
    Groupes auxquels ajouter les utilisateurs.
.PARAMETER RemoveGroup
    Groupes desquels retirer les utilisateurs.
.EXAMPLE
    Set-ADTUserGroupMembership -Identity 'jcote','mtremblay' -AddGroup 'GS-VPN' -RemoveGroup 'GS-Stagiaires'
.EXAMPLE
    Get-Content .\liste.txt | Set-ADTUserGroupMembership -AddGroup 'GS-Comptabilite' -WhatIf
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('SamAccountName', 'User')]
        [string[]]$Identity,

        [string[]]$AddGroup,
        [string[]]$RemoveGroup,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    begin {
        if ($LogPath) { $script:ADTLogPath = $LogPath }
        if (-not $AddGroup -and -not $RemoveGroup) {
            throw "Preciser au moins -AddGroup ou -RemoveGroup."
        }
        $pre = Test-ADTPrerequisite -Server $Server -Credential $Credential
        if (-not $pre.Ready) { throw $pre.Messages }
        $Server = $pre.Server
        foreach ($g in $AddGroup) { if ($RemoveGroup -contains $g) { throw ('Groupe present dans ajout ET retrait : ' + $g) } }
        $common = @{}
        if ($Server)     { $common['Server'] = $Server }
        if ($Credential) { $common['Credential'] = $Credential }
    }

    process {
        foreach ($user in $Identity) {
            if (-not $user) { continue }

            $adUser = $null
            try {
                $adUser = Get-ADTNativeUser -Identity $user -ErrorAction Stop @common
            } catch {
                Write-ADTLog -Level 'ERROR' -Message ("Utilisateur introuvable : {0}" -f $user)
                $failed = New-Object PSObject -Property @{
                    SamAccountName = $user; Action = 'Recherche'; Group = ''
                    Status = 'Echec'; Error = 'Utilisateur introuvable'
                }
                $failed | Select-Object SamAccountName, Action, Group, Status, Error
                continue
            }

            foreach ($group in $AddGroup) {
                if (-not $group) { continue }
                $status = 'Echec'; $errorText = ''
                try {
                    if ($PSCmdlet.ShouldProcess($adUser.SamAccountName, ("Ajouter au groupe {0}" -f $group))) {
                        Add-ADTNativeGroupMember -Identity $group -Members $adUser.DistinguishedName -ErrorAction Stop @common
                        $status = 'Ajoute'
                        Write-ADTLog -Level 'SUCCESS' -Message ("{0} ajoute a {1}" -f $adUser.SamAccountName, $group)
                    } else { $status = 'Simulation' }
                } catch {
                    $errorText = $_.Exception.Message
                    Write-ADTLog -Level 'ERROR' -Message ("Ajout de {0} a {1} echoue : {2}" -f $adUser.SamAccountName, $group, $errorText)
                }
                $out = New-Object PSObject -Property @{
                    SamAccountName = $adUser.SamAccountName; Action = 'Ajout'; Group = $group
                    Status = $status; Error = $errorText
                }
                $out | Select-Object SamAccountName, Action, Group, Status, Error
            }

            foreach ($group in $RemoveGroup) {
                if (-not $group) { continue }
                $status = 'Echec'; $errorText = ''
                try {
                    if ($PSCmdlet.ShouldProcess($adUser.SamAccountName, ("Retirer du groupe {0}" -f $group))) {
                        Remove-ADTNativeGroupMember -Identity $group -Members $adUser.DistinguishedName -Confirm:$false -ErrorAction Stop @common
                        $status = 'Retire'
                        Write-ADTLog -Level 'SUCCESS' -Message ("{0} retire de {1}" -f $adUser.SamAccountName, $group)
                    } else { $status = 'Simulation' }
                } catch {
                    $errorText = $_.Exception.Message
                    Write-ADTLog -Level 'ERROR' -Message ("Retrait de {0} de {1} echoue : {2}" -f $adUser.SamAccountName, $group, $errorText)
                }
                $out = New-Object PSObject -Property @{
                    SamAccountName = $adUser.SamAccountName; Action = 'Retrait'; Group = $group
                    Status = $status; Error = $errorText
                }
                $out | Select-Object SamAccountName, Action, Group, Status, Error
            }
        }
    }
}
