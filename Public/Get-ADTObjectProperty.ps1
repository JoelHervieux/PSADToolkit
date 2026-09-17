function Get-ADTObjectProperty {
<#
.SYNOPSIS
    Fiche complete d un objet Active Directory, pour la feuille de proprietes.
.DESCRIPTION
    Lit en une fois tous les attributs presentes dans les sections General,
    Compte, Organisation, Groupes, Profil et Horaires de connexion, et y ajoute
    les valeurs calculees : etat du compte, horaires en clair, appartenances
    resolues en noms lisibles, protection contre la suppression accidentelle.

    Les horaires de connexion sont convertis en heure locale de la machine, comme
    le fait la console Microsoft : l attribut logonHours est stocke en temps
    universel dans l annuaire.
.PARAMETER Identity
    DN, sAMAccountName, UPN, SID ou nom affiche de l objet.
.PARAMETER SkipDeletionProtection
    N interroge pas le descripteur de securite. Utile lorsque le compte n a pas
    le droit de lire les autorisations, ou pour accelerer un affichage en lot.
.EXAMPLE
    Get-ADTObjectProperty -Identity 'jcote'
.EXAMPLE
    Get-ADTObjectProperty -Identity 'OU=Employes,DC=contoso,DC=local' | Format-List
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('DistinguishedName', 'SamAccountName')]
        [string[]]$Identity,

        [switch]$SkipDeletionProtection,
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
        foreach ($id in $Identity) {
            if (-not $id) { continue }
            $item = Resolve-ADTConsoleObject -Identity $id -Detail -LockoutDurationTicks $lockoutTicks @common

            $mask = ConvertFrom-ADTLogonHoursByte -Byte $item.LogonHours
            $restricted = ($mask -ne ('1' * 168))

            $groupNames = New-Object System.Collections.ArrayList
            foreach ($groupDN in @($item.MemberOf)) {
                if (-not $groupDN) { continue }
                [void]$groupNames.Add((Get-ADTRdnValue -DistinguishedName ([string]$groupDN)))
            }

            $protected = $null
            if (-not $SkipDeletionProtection) {
                try { $protected = Get-ADTNativeDeletionProtection -DistinguishedName ([string]$item.DistinguishedName) @common }
                catch { $protected = $null }
            }

            $expiresOn = $null
            if ($item.AccountExpirationDate) {
                # accountExpires designe l instant ou le compte cesse d etre
                # utilisable. La console Microsoft affiche le dernier jour ouvert.
                $expiresOn = ([datetime]$item.AccountExpirationDate).AddSeconds(-1).Date
            }

            $output = New-Object PSObject -Property @{
                Name                    = [string]$item.Name
                DisplayName             = [string]$item.DisplayName
                ObjectClass             = [string]$item.ObjectClass
                ObjectType              = [string]$item.ObjectType
                DistinguishedName       = [string]$item.DistinguishedName
                Container               = (Get-ADTParentDistinguishedName -DistinguishedName ([string]$item.DistinguishedName))
                SamAccountName          = [string]$item.SamAccountName
                UserPrincipalName       = [string]$item.UserPrincipalName
                SID                     = [string]$item.SID
                GivenName               = [string]$item.GivenName
                Surname                 = [string]$item.Surname
                Initials                = [string]$item.Initials
                Description             = [string]$item.Description
                EmailAddress            = [string]$item.EmailAddress
                OfficePhone             = [string]$item.OfficePhone
                MobilePhone             = [string]$item.MobilePhone
                Office                  = [string]$item.Office
                Title                   = [string]$item.Title
                Department              = [string]$item.Department
                Company                 = [string]$item.Company
                Manager                 = [string]$item.Manager
                ManagedBy               = [string]$item.ManagedBy
                StreetAddress           = [string]$item.StreetAddress
                City                    = [string]$item.City
                State                   = [string]$item.State
                PostalCode              = [string]$item.PostalCode
                Country                 = [string]$item.Country
                EmployeeID              = [string]$item.EmployeeID
                Notes                   = [string]$item.Notes
                HomeDirectory           = [string]$item.HomeDirectory
                HomeDrive               = [string]$item.HomeDrive
                ProfilePath             = [string]$item.ProfilePath
                ScriptPath              = [string]$item.ScriptPath
                Enabled                 = $item.Enabled
                LockedOut               = $item.LockedOut
                Status                  = (Get-ADTObjectStatusText -Object $item)
                MustChangePassword      = $item.MustChangePassword
                CannotChangePassword    = $item.CannotChangePassword
                PasswordNeverExpires    = $item.PasswordNeverExpires
                PasswordNotRequired     = $item.PasswordNotRequired
                SmartcardLogonRequired  = $item.SmartcardLogonRequired
                AccountNotDelegated     = $item.AccountNotDelegated
                DoesNotRequirePreAuth   = $item.DoesNotRequirePreAuth
                UserAccountControl      = $item.UserAccountControl
                PasswordLastSet         = $item.PasswordLastSet
                LastLogonDate           = $item.LastLogonDate
                AccountExpirationDate   = $item.AccountExpirationDate
                AccountExpiresEndOfDay  = $expiresOn
                whenCreated             = $item.whenCreated
                whenChanged             = $item.whenChanged
                LogonHoursMask          = $mask
                LogonHoursText          = (ConvertTo-ADTLogonHoursText -Mask $mask)
                LogonHoursRestricted    = $restricted
                MemberOf                = @($item.MemberOf)
                MemberOfNames           = ([string[]]@($groupNames))
                GroupScope              = [string]$item.GroupScope
                GroupCategory           = [string]$item.GroupCategory
                OperatingSystem         = [string]$item.OperatingSystem
                OperatingSystemVersion  = [string]$item.OperatingSystemVersion
                DnsHostName             = [string]$item.DnsHostName
                ProtectedFromDeletion   = $protected
                PasswordPolicySource    = ''
                MinimumPasswordLength   = 0
            }
            if ($policy) {
                $output.PasswordPolicySource = [string]$policy.Source
                $output.MinimumPasswordLength = [int]$policy.MinimumPasswordLength
            }
            $output
        }
    }
}
