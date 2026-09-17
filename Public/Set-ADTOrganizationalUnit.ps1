function Set-ADTOrganizationalUnit {
<#
.SYNOPSIS
    Modifie une unite d organisation : nom, description, protection, gestionnaire.
.DESCRIPTION
    Seuls les parametres fournis sont ecrits. Renommer une unite change le DN de
    tous les objets qu elle contient : les scripts, les strategies de groupe liees
    par DN et les raccourcis qui referencent l ancien DN doivent etre revus.
    Le nouveau DN est rendu dans le resultat.
.PARAMETER Identity
    Unite d organisation visee : DN ou nom.
.PARAMETER NewName
    Nouveau nom de l unite.
.PARAMETER Description
    Nouvelle description. Chaine vide pour l effacer.
.PARAMETER ManagedBy
    Compte ou groupe responsable de l unite. Chaine vide pour l effacer.
.PARAMETER ProtectFromAccidentalDeletion
    Active ou retire la protection contre la suppression accidentelle.
.EXAMPLE
    Set-ADTOrganizationalUnit -Identity 'OU=Ventes,DC=contoso,DC=local' -Description 'Service des ventes' -WhatIf
.EXAMPLE
    Set-ADTOrganizationalUnit -Identity 'OU=Ventes,DC=contoso,DC=local' -ProtectFromAccidentalDeletion $false
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('DistinguishedName')]
        [string[]]$Identity,

        [string]$NewName,
        [string]$Description,
        [string]$ManagedBy,
        [bool]$ProtectFromAccidentalDeletion,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    begin { $common = Initialize-ADTConnection -Server $Server -Credential $Credential -LogPath $LogPath }

    process {
        foreach ($id in $Identity) {
            if (-not $id) { continue }
            $label = $id
            $status = 'Echec'
            $errorText = ''
            $dn = ''
            $changes = New-Object System.Collections.ArrayList
            try {
                $unit = Resolve-ADTConsoleObject -Identity $id -ObjectFilter (Get-ADTConsoleClassFilter -Type OrganizationalUnit) @common
                $dn = [string]$unit.DistinguishedName
                $label = [string]$unit.Name

                $attributes = @{}
                if ($PSBoundParameters.ContainsKey('Description')) { $attributes['description'] = $Description; [void]$changes.Add('Description') }
                if ($PSBoundParameters.ContainsKey('ManagedBy')) {
                    if ($ManagedBy) {
                        $owner = Resolve-ADTConsoleObject -Identity $ManagedBy @common
                        $attributes['managedBy'] = [string]$owner.DistinguishedName
                    } else { $attributes['managedBy'] = '' }
                    [void]$changes.Add('ManagedBy')
                }
                if ($PSBoundParameters.ContainsKey('ProtectFromAccidentalDeletion')) { [void]$changes.Add('Protection') }
                if ($NewName) { [void]$changes.Add('NewName') }
                if (-not $changes.Count) { throw 'Aucune propriete a modifier : preciser au moins un parametre.' }

                if ($PSCmdlet.ShouldProcess($label, ('Modifier : {0}' -f ($changes -join ', ')))) {
                    if ($attributes.Count) {
                        Set-ADTNativeObjectAttribute -DistinguishedName $dn -Attribute $attributes -ErrorAction Stop @common
                    }
                    if ($PSBoundParameters.ContainsKey('ProtectFromAccidentalDeletion')) {
                        Set-ADTNativeDeletionProtection -DistinguishedName $dn -Protected $ProtectFromAccidentalDeletion -ErrorAction Stop @common
                    }
                    if ($NewName) {
                        $dn = Rename-ADTNativeObject -DistinguishedName $dn -NewName $NewName -ObjectClass 'organizationalUnit' -ErrorAction Stop @common
                        $label = $NewName
                    }
                    $status = 'Modifiee'
                    Write-ADTLog -Level 'SUCCESS' -Message ('Unite d organisation {0} modifiee : {1}' -f $dn, ($changes -join ', '))
                } else {
                    $status = 'Simulation'
                }
            } catch {
                $errorText = $_.Exception.Message
                Write-ADTLog -Level 'ERROR' -Message ('Modification de l unite {0} echouee : {1}' -f $label, $errorText)
            }
            $row = New-Object PSObject -Property @{
                Name = $label; Status = $status; Changed = ($changes -join ', '); DistinguishedName = $dn; Error = $errorText
            }
            $row | Select-Object Name, Status, Changed, DistinguishedName, Error
        }
    }
}
