function Get-ADTDirectoryChild {
<#
.SYNOPSIS
    Liste le contenu direct d une unite d organisation ou d un conteneur.
.DESCRIPTION
    Equivalent du volet droit de la console Utilisateurs et ordinateurs Active
    Directory : les objets immediatement contenus dans le conteneur designe, sans
    descendre dans les sous-unites. La lecture passe par LDAP, sans RSAT.

    Les conteneurs sont rendus en premier, puis les autres objets par nom, dans
    l ordre de tri de la culture de la machine.
.PARAMETER Path
    DN du conteneur a lire. Ex : 'OU=Employes,DC=contoso,DC=local'
.PARAMETER Type
    Classes a retenir : All, Container, User, Group, Computer. Cumulables.
.PARAMETER SizeLimit
    Plafond de resultats. 0 = sans limite. Protege l interface d une OU contenant
    des dizaines de milliers d objets.
.PARAMETER Server
    Controleur de domaine. Vide = detection automatique.
.PARAMETER Credential
    Compte autre que celui de la session Windows.
.EXAMPLE
    Get-ADTDirectoryChild -Path 'OU=Employes,DC=contoso,DC=local'
.EXAMPLE
    Get-ADTDirectoryChild -Path 'OU=Employes,DC=contoso,DC=local' -Type User,Group | Format-Table Name, ObjectType, Status
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipelineByPropertyName = $true)]
        [Alias('DistinguishedName', 'SearchBase')]
        [string]$Path,

        [ValidateSet('All', 'Container', 'User', 'Group', 'Computer')]
        [string[]]$Type = @('All'),

        [int]$SizeLimit = 0,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    begin {
        $common = Initialize-ADTConnection -Server $Server -Credential $Credential -LogPath $LogPath
        $policy = $null
        try { $policy = Get-ADTNativePasswordPolicy @common } catch { $policy = $null }
        $lockoutTicks = [long]0
        if ($policy) { $lockoutTicks = [long]$policy.LockoutDurationTicks }
    }

    process {
        $include = New-Object System.Collections.ArrayList
        foreach ($item in $Type) {
            switch ($item) {
                'All' {
                    foreach ($class in @('organizationalUnit', 'container', 'user', 'group', 'computer')) {
                        if (-not $include.Contains($class)) { [void]$include.Add($class) }
                    }
                }
                'Container' {
                    foreach ($class in @('organizationalUnit', 'container')) {
                        if (-not $include.Contains($class)) { [void]$include.Add($class) }
                    }
                }
                'User' { if (-not $include.Contains('user')) { [void]$include.Add('user') } }
                'Group' { if (-not $include.Contains('group')) { [void]$include.Add('group') } }
                'Computer' { if (-not $include.Contains('computer')) { [void]$include.Add('computer') } }
            }
        }

        $children = @(Get-ADTNativeContainerChild -DistinguishedName $Path -Include ([string[]]@($include)) `
                -SizeLimit $SizeLimit -LockoutDurationTicks $lockoutTicks @common)

        $rows = @()
        foreach ($child in $children) {
            $rows += New-Object PSObject -Property @{
                Name              = [string]$child.Name
                ObjectType        = [string]$child.ObjectType
                SamAccountName    = [string]$child.SamAccountName
                UserPrincipalName = [string]$child.UserPrincipalName
                Description       = [string]$child.Description
                Status            = (Get-ADTObjectStatusText -Object $child)
                Enabled           = $child.Enabled
                LockedOut         = $child.LockedOut
                LastLogonDate     = $child.LastLogonDate
                whenCreated       = $child.whenCreated
                ObjectClass       = [string]$child.ObjectClass
                DistinguishedName = [string]$child.DistinguishedName
                IsContainer       = (Test-ADTObjectIsContainer -ObjectClass ([string]$child.ObjectClass))
            }
        }

        $sorted = @($rows | Sort-Object -Property @{ Expression = { if ($_.IsContainer) { 0 } else { 1 } } }, @{ Expression = { [string]$_.Name } })
        foreach ($row in $sorted) {
            $row | Select-Object Name, ObjectType, SamAccountName, UserPrincipalName, Description, Status,
            Enabled, LockedOut, LastLogonDate, whenCreated, ObjectClass, DistinguishedName, IsContainer
        }
    }
}
