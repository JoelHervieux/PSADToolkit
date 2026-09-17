function Remove-ADTObject {
<#
.SYNOPSIS
    Supprime des objets Active Directory, avec les garde-fous de la console Microsoft.
.DESCRIPTION
    Supprime utilisateurs, groupes, ordinateurs et unites d organisation.

    Trois protections sont appliquees avant toute suppression :
      - ConfirmImpact eleve : la confirmation est demandee par defaut ;
      - un conteneur non vide n est supprime qu avec -Recursive, et le nombre
        d objets emportes est indique ;
      - la protection contre la suppression accidentelle est detectee et
        signalee ; elle n est levee qu avec -RemoveProtection.

    Une suppression est definitive du point de vue de PSADToolkit : la corbeille
    Active Directory, lorsqu elle est activee dans le domaine, reste le seul
    moyen de restaurer l objet.

    Pour un depart d employe, preferer Start-ADTUserOffboarding : il sauvegarde
    les acces et desactive le compte au lieu de le detruire.
.PARAMETER Identity
    Objets a supprimer : DN, sAMAccountName, nom ou SID.
.PARAMETER Recursive
    Autorise la suppression d un conteneur et de tout son contenu.
.PARAMETER RemoveProtection
    Leve la protection contre la suppression accidentelle avant de supprimer.
.EXAMPLE
    Remove-ADTObject -Identity 'CN=test,OU=Bac,DC=contoso,DC=local' -WhatIf
.EXAMPLE
    Remove-ADTObject -Identity 'OU=Ancien,DC=contoso,DC=local' -Recursive -RemoveProtection
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('SamAccountName', 'DistinguishedName')]
        [string[]]$Identity,

        [switch]$Recursive,
        [switch]$RemoveProtection,
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
            $objectType = ''
            $dn = ''
            try {
                $item = Resolve-ADTConsoleObject -Identity $id @common
                $dn = [string]$item.DistinguishedName
                $objectType = [string]$item.ObjectType
                $label = [string]$item.SamAccountName
                if (-not $label) { $label = [string]$item.Name }

                $childCount = 0
                if (Test-ADTObjectIsContainer -ObjectClass ([string]$item.ObjectClass)) {
                    $children = @(Get-ADTNativeContainerChild -DistinguishedName $dn @common)
                    $childCount = $children.Count
                    if ($childCount -gt 0 -and -not $Recursive) {
                        throw ('Ce conteneur contient {0} objet(s). Utiliser -Recursive pour tout supprimer.' -f $childCount)
                    }
                }

                $protected = $false
                try { $protected = Get-ADTNativeDeletionProtection -DistinguishedName $dn @common }
                catch { Write-Verbose ('Protection non lisible sur {0} : {1}' -f $dn, $_.Exception.Message) }
                if ($protected -and -not $RemoveProtection) {
                    throw 'Objet protege contre la suppression accidentelle. Utiliser -RemoveProtection pour lever la protection.'
                }

                $action = 'Supprimer'
                if ($childCount -gt 0) { $action = ('Supprimer avec {0} objet(s) contenu(s)' -f $childCount) }

                if ($PSCmdlet.ShouldProcess($dn, $action)) {
                    if ($protected) {
                        Set-ADTNativeDeletionProtection -DistinguishedName $dn -Protected $false -ErrorAction Stop @common
                        Write-ADTLog -Level 'WARN' -Message ('Protection contre la suppression levee sur {0}' -f $dn)
                    }
                    Remove-ADTNativeObject -DistinguishedName $dn -Recursive:$Recursive -ErrorAction Stop @common
                    $status = 'Supprime'
                    Write-ADTLog -Level 'SUCCESS' -Message ('{0} supprime ({1}, {2} objet(s) contenu(s))' -f $dn, $objectType, $childCount)
                } else {
                    $status = 'Simulation'
                }
            } catch {
                $errorText = $_.Exception.Message
                Write-ADTLog -Level 'ERROR' -Message ('Suppression de {0} refusee : {1}' -f $label, $errorText)
            }
            $row = New-Object PSObject -Property @{
                Name = $label; ObjectType = $objectType; Status = $status; DistinguishedName = $dn; Error = $errorText
            }
            $row | Select-Object Name, ObjectType, Status, DistinguishedName, Error
        }
    }
}
