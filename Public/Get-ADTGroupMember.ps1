function Get-ADTGroupMember {
<#
.SYNOPSIS
    Liste les membres d un groupe de securite ou de distribution.
.DESCRIPTION
    La lecture part de memberOf plutot que de l attribut member du groupe :
    au-dela d environ 1500 entrees, member est renvoye par tranches par le
    controleur et une lecture naive perdrait des membres sans le signaler.
    Le groupe principal (Utilisateurs du domaine par defaut) n apparait dans
    aucun des deux attributs : il est ajoute a partir de primaryGroupID.

    Avec -Recursive, les membres des groupes imbriques sont inclus.
.PARAMETER Identity
    Groupe : nom affiche, sAMAccountName, DN ou SID.
.PARAMETER Recursive
    Inclut les membres des groupes imbriques.
.PARAMETER IncludeGroup
    Conserve les groupes membres dans le resultat. Par defaut, seuls les comptes
    sont rendus, ce qui correspond a ce que l on veut appliquer en lot.
.EXAMPLE
    Get-ADTGroupMember -Identity 'GS-VPN'
.EXAMPLE
    Get-ADTGroupMember -Identity 'GS-Comptabilite' -Recursive | Select-Object SamAccountName, Status
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('Group', 'GroupName')]
        [string[]]$Identity,

        [switch]$Recursive,
        [switch]$IncludeGroup,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    begin {
        $common = Initialize-ADTConnection -Server $Server -Credential $Credential -LogPath $LogPath
        $lockoutTicks = [long]0
        try { $lockoutTicks = [long](Get-ADTNativePasswordPolicy @common).LockoutDurationTicks } catch { $lockoutTicks = [long]0 }
    }

    process {
        foreach ($id in $Identity) {
            if (-not $id) { continue }
            $group = Resolve-ADTConsoleObject -Identity $id -ObjectFilter (Get-ADTConsoleClassFilter -Type Group) @common
            $groupDN = [string]$group.DistinguishedName
            $groupName = [string]$group.Name

            $members = @(Get-ADTNativeDirectMember -GroupDN $groupDN -Recursive:$Recursive -LockoutDurationTicks $lockoutTicks @common)
            foreach ($member in ($members | Sort-Object -Property @{ Expression = { [string]$_.Name } })) {
                if (-not $IncludeGroup -and [string]$member.ObjectClass -eq 'group') { continue }
                $row = New-Object PSObject -Property @{
                    GroupName         = $groupName
                    GroupDN           = $groupDN
                    Name              = [string]$member.Name
                    SamAccountName    = [string]$member.SamAccountName
                    UserPrincipalName = [string]$member.UserPrincipalName
                    ObjectType        = [string]$member.ObjectType
                    ObjectClass       = [string]$member.ObjectClass
                    Department        = [string]$member.Department
                    Title             = [string]$member.Title
                    Status            = (Get-ADTObjectStatusText -Object $member)
                    Enabled           = $member.Enabled
                    LockedOut         = $member.LockedOut
                    LastLogonDate     = $member.LastLogonDate
                    DistinguishedName = [string]$member.DistinguishedName
                }
                $row | Select-Object GroupName, Name, SamAccountName, UserPrincipalName, ObjectType, Department,
                Title, Status, Enabled, LockedOut, LastLogonDate, ObjectClass, DistinguishedName, GroupDN
            }
        }
    }
}
