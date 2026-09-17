function New-ADTGroup {
<#
.SYNOPSIS
    Cree un groupe de securite ou de distribution dans une unite d organisation.
.DESCRIPTION
    Reprend les choix de la boite "Nouvel objet - Groupe" de la console Microsoft :
    nom, nom anterieur a Windows 2000 (sAMAccountName), etendue et type de groupe.

    Le sAMAccountName est derive du nom lorsqu il n est pas impose : accents
    retires, caracteres non valides supprimes, longueur ramenee a 64 caracteres.
    Son unicite est verifiee avant la creation, ce qui evite un echec brut du
    controleur de domaine.

    Les membres initiaux peuvent etre fournis : chacun est ajoute apres la
    creation, et un ajout refuse n annule pas le groupe deja cree. Le statut
    Partiel signale ce cas.
.PARAMETER Path
    DN de l unite d organisation qui recevra le groupe.
.PARAMETER Name
    Nom du groupe.
.PARAMETER SamAccountName
    Nom anterieur a Windows 2000. Calcule a partir du nom si omis.
.PARAMETER Scope
    Global, DomainLocal ou Universal.
.PARAMETER Category
    Security ou Distribution.
.PARAMETER Member
    Membres a ajouter juste apres la creation.
.EXAMPLE
    New-ADTGroup -Path 'OU=Groupes,DC=contoso,DC=local' -Name 'GS-VPN' -WhatIf
.EXAMPLE
    New-ADTGroup -Path 'OU=Groupes,DC=contoso,DC=local' -Name 'GS-Ventes' -Scope Universal -Member 'jcote','mtremblay'
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()][string]$Path,

        [Parameter(Mandatory = $true, Position = 1, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()][string]$Name,

        [Parameter(ValueFromPipelineByPropertyName = $true)][string]$SamAccountName,
        [ValidateSet('Global', 'DomainLocal', 'Universal')][string]$Scope = 'Global',
        [ValidateSet('Security', 'Distribution')][string]$Category = 'Security',
        [string]$Description,
        [string[]]$Member,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    begin { $common = Initialize-ADTConnection -Server $Server -Credential $Credential -LogPath $LogPath }

    process {
        $status = 'Echec'
        $errorText = ''
        $dn = ''
        $added = New-Object System.Collections.ArrayList
        $issues = New-Object System.Collections.ArrayList
        $sam = $SamAccountName

        try {
            if (-not $sam) {
                $sam = ConvertTo-ADTAsciiString -Text $Name
                if (-not $sam) { throw ('Impossible de deriver un identifiant de groupe a partir de "{0}". Preciser -SamAccountName.' -f $Name) }
            }
            if ($sam.Length -gt 64) { $sam = $sam.Substring(0, 64) }

            $container = Resolve-ADTConsoleObject -Identity $Path @common
            if (-not (Test-ADTObjectIsContainer -ObjectClass ([string]$container.ObjectClass))) {
                throw ('La destination n est pas un conteneur : {0}' -f $Path)
            }
            $containerDN = [string]$container.DistinguishedName

            $existing = @(Search-ADTDirectoryEntry -LDAPFilter ('(&(objectClass=group)(sAMAccountName=' + (ConvertTo-ADTLdapValue $sam) + '))') -SizeLimit 1 @common)
            if ($existing.Count) { throw ('Un groupe porte deja l identifiant {0} : {1}' -f $sam, [string]$existing[0].DistinguishedName) }

            if ($PSCmdlet.ShouldProcess($Name, ('Creer le groupe {0} {1} dans {2}' -f $Scope, $Category, $containerDN))) {
                $dn = New-ADTNativeGroup -Path $containerDN -Name $Name -SamAccountName $sam -Scope $Scope `
                    -Category $Category -Description $Description -ErrorAction Stop @common
                Write-ADTLog -Level 'SUCCESS' -Message ('Groupe cree : {0} ({1} {2}) dans {3}' -f $sam, $Scope, $Category, $containerDN)
                $status = 'Cree'

                foreach ($candidate in @($Member)) {
                    if (-not $candidate) { continue }
                    try {
                        $target = Resolve-ADTConsoleObject -Identity $candidate @common
                        Add-ADTNativeGroupMember -Identity $dn -Members ([string]$target.DistinguishedName) -ErrorAction Stop @common
                        [void]$added.Add([string]$target.SamAccountName)
                        Write-ADTLog -Level 'INFO' -Message ('{0} ajoute au groupe {1}' -f $candidate, $sam)
                    } catch {
                        [void]$issues.Add(('Membre {0} : {1}' -f $candidate, $_.Exception.Message))
                        Write-ADTLog -Level 'WARN' -Message ('Ajout de {0} au groupe {1} echoue : {2}' -f $candidate, $sam, $_.Exception.Message)
                    }
                }
                if ($issues.Count) { $status = 'Partiel'; $errorText = ($issues -join ' | ') }
            } else {
                $status = 'Simulation'
            }
        } catch {
            $errorText = $_.Exception.Message
            Write-ADTLog -Level 'ERROR' -Message ('Creation du groupe {0} echouee : {1}' -f $Name, $errorText)
        }

        $row = New-Object PSObject -Property @{
            Name = $Name; SamAccountName = $sam; GroupScope = $Scope; GroupCategory = $Category
            Status = $status; Members = ($added -join ';'); DistinguishedName = $dn; Error = $errorText
        }
        $row | Select-Object Name, SamAccountName, GroupScope, GroupCategory, Status, Members, DistinguishedName, Error
    }
}
