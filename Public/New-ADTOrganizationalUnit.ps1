function New-ADTOrganizationalUnit {
<#
.SYNOPSIS
    Cree une unite d organisation.
.DESCRIPTION
    Equivalent de "Nouvel objet - Unite d organisation" de la console Microsoft,
    y compris la case "Proteger le conteneur contre une suppression accidentelle",
    active par defaut comme dans la console.

    La protection est une entree de refus pour Tout le monde sur les droits de
    suppression. Si le compte utilise n a pas le droit de modifier les
    autorisations de l objet, l unite est tout de meme creee : le statut Partiel
    signale alors que la protection n a pas pu etre posee.
.PARAMETER Path
    DN du conteneur parent. Ex : 'DC=contoso,DC=local'
.PARAMETER Name
    Nom de l unite d organisation.
.PARAMETER NoProtection
    Ne pas proteger l unite contre la suppression accidentelle.
.EXAMPLE
    New-ADTOrganizationalUnit -Path 'DC=contoso,DC=local' -Name 'Employes' -WhatIf
.EXAMPLE
    New-ADTOrganizationalUnit -Path 'OU=Employes,DC=contoso,DC=local' -Name 'Comptabilite' -Description 'Service comptable'
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()][string]$Path,

        [Parameter(Mandatory = $true, Position = 1, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()][string]$Name,

        [string]$Description,
        [switch]$NoProtection,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    begin { $common = Initialize-ADTConnection -Server $Server -Credential $Credential -LogPath $LogPath }

    process {
        $status = 'Echec'
        $errorText = ''
        $dn = ''
        $protectedState = $false
        try {
            $container = Resolve-ADTConsoleObject -Identity $Path @common
            if (-not (Test-ADTObjectIsContainer -ObjectClass ([string]$container.ObjectClass))) {
                throw ('La destination n est pas un conteneur : {0}' -f $Path)
            }
            $containerDN = [string]$container.DistinguishedName

            if ($PSCmdlet.ShouldProcess($Name, ('Creer l unite d organisation dans {0}' -f $containerDN))) {
                $dn = New-ADTNativeOrganizationalUnit -Path $containerDN -Name $Name -Description $Description -ErrorAction Stop @common
                $status = 'Creee'
                Write-ADTLog -Level 'SUCCESS' -Message ('Unite d organisation creee : {0}' -f $dn)

                if (-not $NoProtection) {
                    try {
                        Set-ADTNativeDeletionProtection -DistinguishedName $dn -Protected $true -ErrorAction Stop @common
                        $protectedState = $true
                    } catch {
                        $status = 'Partiel'
                        $errorText = 'Protection contre la suppression non posee : ' + $_.Exception.Message
                        Write-ADTLog -Level 'WARN' -Message ('Protection non posee sur {0} : {1}' -f $dn, $_.Exception.Message)
                    }
                }
            } else {
                $status = 'Simulation'
            }
        } catch {
            $errorText = $_.Exception.Message
            Write-ADTLog -Level 'ERROR' -Message ('Creation de l unite d organisation {0} echouee : {1}' -f $Name, $errorText)
        }

        $row = New-Object PSObject -Property @{
            Name = $Name; Status = $status; DistinguishedName = $dn; Protected = $protectedState; Error = $errorText
        }
        $row | Select-Object Name, Status, DistinguishedName, Protected, Error
    }
}
