function Move-ADTObject {
<#
.SYNOPSIS
    Deplace des objets Active Directory vers une autre unite d organisation.
.DESCRIPTION
    Deplace utilisateurs, groupes, ordinateurs et unites d organisation, un par un
    ou en lot. Le conteneur de destination est verifie avant toute ecriture.

    Deplacer une unite d organisation dans elle-meme ou dans l une de ses propres
    sous-unites est refuse : Active Directory rejetterait l operation avec un
    message peu parlant, et le controle est immediat.

    Un objet protege contre la suppression accidentelle se deplace normalement :
    la protection porte sur la suppression, pas sur le deplacement. En revanche,
    la console Microsoft protege aussi le conteneur parent ; un refus d acces sur
    le deplacement vient generalement de la delegation, pas de cette protection.
.PARAMETER Identity
    Objets a deplacer : DN, sAMAccountName, nom ou SID.
.PARAMETER TargetPath
    DN de l unite d organisation ou du conteneur de destination.
.EXAMPLE
    Move-ADTObject -Identity 'jcote' -TargetPath 'OU=Desactives,DC=contoso,DC=local' -WhatIf
.EXAMPLE
    Get-ADTGroupMember -Identity 'GS-Stagiaires' | Move-ADTObject -TargetPath 'OU=Stagiaires,DC=contoso,DC=local'
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('SamAccountName', 'DistinguishedName')]
        [string[]]$Identity,

        [Parameter(Mandatory = $true, Position = 1)]
        [Alias('Destination', 'Path')]
        [string]$TargetPath,

        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    begin {
        $common = Initialize-ADTConnection -Server $Server -Credential $Credential -LogPath $LogPath
        $destination = Resolve-ADTConsoleObject -Identity $TargetPath @common
        if (-not (Test-ADTObjectIsContainer -ObjectClass ([string]$destination.ObjectClass))) {
            throw ('La destination n est pas un conteneur : {0} ({1}).' -f $TargetPath, $destination.ObjectType)
        }
        $destinationDN = [string]$destination.DistinguishedName
    }

    process {
        foreach ($id in $Identity) {
            if (-not $id) { continue }
            $label = $id
            $status = 'Echec'
            $errorText = ''
            $sourceDN = ''
            try {
                $item = Resolve-ADTConsoleObject -Identity $id @common
                $sourceDN = [string]$item.DistinguishedName
                $label = [string]$item.SamAccountName
                if (-not $label) { $label = [string]$item.Name }

                $currentParent = Get-ADTParentDistinguishedName -DistinguishedName $sourceDN
                if ($currentParent -eq $destinationDN) { throw 'L objet est deja dans ce conteneur.' }
                if ($destinationDN -eq $sourceDN -or $destinationDN.EndsWith(',' + $sourceDN)) {
                    throw 'Impossible de deplacer un conteneur dans lui-meme ou dans l une de ses sous-unites.'
                }

                if ($PSCmdlet.ShouldProcess($label, ('Deplacer vers {0}' -f $destinationDN))) {
                    Move-ADTNativeObject -Identity $sourceDN -TargetPath $destinationDN -ErrorAction Stop @common
                    $status = 'Deplace'
                    Write-ADTLog -Level 'SUCCESS' -Message ('{0} deplace de {1} vers {2}' -f $label, $currentParent, $destinationDN)
                } else {
                    $status = 'Simulation'
                }
            } catch {
                $errorText = $_.Exception.Message
                Write-ADTLog -Level 'ERROR' -Message ('Deplacement de {0} echoue : {1}' -f $label, $errorText)
            }
            $row = New-Object PSObject -Property @{
                Name = $label; Status = $status; Source = $sourceDN; Destination = $destinationDN; Error = $errorText
            }
            $row | Select-Object Name, Status, Source, Destination, Error
        }
    }
}
