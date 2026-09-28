<#
    Annuaire simule pour le test de fumee de l interface.

    Charge par Start-PSADToolkit.ps1 -SmokeTest apres le module et les helpers : ces
    fonctions masquent celles qui liraient ou ecriraient dans un vrai domaine. Le test
    exerce donc toute la construction de l interface - fenetres, arborescence,
    grilles, menus - sans controleur de domaine.

    Les ecritures sont remplacees par des fonctions generees a partir des vraies :
    memes parametres, reponse "Simulation". Un parametre renomme dans le module fait
    ainsi echouer le test au lieu de passer inapercu.
#>

$script:FakeDomainDN = 'DC=lab,DC=local'
$script:FakeServer = 'dc01.lab.local'

$script:FakeContainers = @(
    @{ Name = 'Employes'; DN = 'OU=Employes,DC=lab,DC=local'; Class = 'organizationalUnit' },
    @{ Name = 'Comptabilite'; DN = 'OU=Comptabilite,OU=Employes,DC=lab,DC=local'; Class = 'organizationalUnit' },
    @{ Name = 'Groupes'; DN = 'OU=Groupes,DC=lab,DC=local'; Class = 'organizationalUnit' },
    @{ Name = 'Volume'; DN = 'OU=Volume,DC=lab,DC=local'; Class = 'organizationalUnit' },
    @{ Name = 'Users'; DN = 'CN=Users,DC=lab,DC=local'; Class = 'container' },
    @{ Name = 'Builtin'; DN = 'CN=Builtin,DC=lab,DC=local'; Class = 'builtinDomain' }
)

function New-FakeRow {
    param([string]$Name, [string]$Class, [string]$Parent, [string]$Sam = '', [bool]$Enabled = $true, [bool]$Locked = $false)
    $prefix = 'CN='
    if ($Class -eq 'organizationalUnit') { $prefix = 'OU=' }
    $types = @{ user = 'Utilisateur'; group = 'Groupe'; computer = 'Ordinateur'; organizationalUnit = 'Unite d organisation'; container = 'Conteneur' }
    $status = ''
    if ($Class -eq 'user' -or $Class -eq 'computer') {
        $parts = @()
        if ($Enabled) { $parts += 'Actif' } else { $parts += 'Desactive' }
        if ($Locked) { $parts += 'Verrouille' }
        $status = $parts -join ', '
    }
    [pscustomobject]@{
        Name              = $Name
        ObjectType        = [string]$types[$Class]
        SamAccountName    = $Sam
        UserPrincipalName = $(if ($Class -eq 'user') { $Sam + '@lab.local' } else { '' })
        Description       = ''
        Status            = $status
        Enabled           = $Enabled
        LockedOut         = $Locked
        LastLogonDate     = (Get-Date).AddDays(-3)
        whenCreated       = (Get-Date).AddYears(-1)
        ObjectClass       = $Class
        DistinguishedName = $prefix + $Name + ',' + $Parent
        IsContainer       = ($Class -eq 'organizationalUnit' -or $Class -eq 'container')
    }
}

function Get-FakeChildren {
    param([string]$Path)
    switch ($Path) {
        'OU=Employes,DC=lab,DC=local' {
            New-FakeRow -Name 'Comptabilite' -Class 'organizationalUnit' -Parent $Path
            New-FakeRow -Name 'Joel Cote' -Class 'user' -Parent $Path -Sam 'jcote'
            New-FakeRow -Name 'Marie Tremblay' -Class 'user' -Parent $Path -Sam 'mtremblay' -Enabled $false
            New-FakeRow -Name 'Denis Gagnon' -Class 'user' -Parent $Path -Sam 'dgagnon' -Locked $true
            New-FakeRow -Name 'GS-Ventes' -Class 'group' -Parent $Path -Sam 'GS-Ventes'
            New-FakeRow -Name 'GS-VPN' -Class 'group' -Parent $Path -Sam 'GS-VPN'
            New-FakeRow -Name 'PC-001' -Class 'computer' -Parent $Path -Sam 'PC-001$'
        }
        'OU=Volume,DC=lab,DC=local' {
            for ($i = 1; $i -le 150; $i++) { New-FakeRow -Name ('Compte {0:000}' -f $i) -Class 'user' -Parent $Path -Sam ('compte{0:000}' -f $i) }
        }
        default {
            New-FakeRow -Name 'Exemple' -Class 'user' -Parent $Path -Sam 'exemple'
        }
    }
}

# --- Lecture ------------------------------------------------------------------

function Test-ADTPrerequisite {
    [CmdletBinding()] param($Server, $Credential)
    [pscustomobject]@{
        Ready = $true; Server = $script:FakeServer; DomainName = 'lab.local'; DomainMode = '7'
        PowerShellVersion = [string]$PSVersionTable.PSVersion; Messages = 'Annuaire simule.'
    }
}

function Get-ADTNativeDomain {
    [CmdletBinding()] param($Server, $Credential)
    [pscustomobject]@{ DNSRoot = 'lab.local'; DistinguishedName = $script:FakeDomainDN; Server = $script:FakeServer; DomainMode = '7'; DomainSID = $null }
}

function Get-ADTNativeDomainCandidate {
    [CmdletBinding()] param()
    [pscustomobject]@{ Name = 'lab.local'; Source = 'Domaine de ce poste' }
    [pscustomobject]@{ Name = 'filiale.lab.local'; Source = 'Meme foret' }
}

function Search-ADTDirectoryEntry {
    [CmdletBinding()] param($LDAPFilter, $SearchBase, $Scope, $Property, $SizeLimit, $LockoutDurationTicks, $Server, $Credential)
    foreach ($item in $script:FakeContainers) {
        [pscustomobject]@{ Name = $item.Name; DistinguishedName = $item.DN; ObjectClass = $item.Class }
    }
}

function Get-ADTDirectoryChild {
    [CmdletBinding()] param($Path, $Type, $SizeLimit, $Server, $Credential, $LogPath)
    Get-FakeChildren -Path $Path
}

function Find-ADTDirectoryObject {
    [CmdletBinding()] param($SearchTerm, $Type, $SearchBase, $Attribute, $Exact, $SizeLimit, $Server, $Credential, $LogPath)
    foreach ($row in (Get-FakeChildren -Path 'OU=Employes,DC=lab,DC=local')) {
        if ([string]$row.Name -like ('*' + $SearchTerm + '*')) {
            $row | Add-Member -NotePropertyName Container -NotePropertyValue 'OU=Employes,DC=lab,DC=local' -Force -PassThru
        }
    }
}

function Get-ADTObjectProperty {
    [CmdletBinding()] param($Identity, $SkipDeletionProtection, $Server, $Credential, $LogPath)
    $dn = [string]@($Identity)[0]
    $class = 'user'
    if ($dn -like 'OU=*') { $class = 'organizationalUnit' }
    elseif ($dn -like 'CN=GS-*') { $class = 'group' }
    $mask = New-ADTLogonHoursMask -Day 1, 2, 3, 4, 5 -StartHour 8 -EndHour 18
    [pscustomobject]@{
        Name = (Get-ADTRdnValue -DistinguishedName $dn); DisplayName = 'Objet simule'; ObjectClass = $class
        ObjectType = 'Objet simule'; DistinguishedName = $dn; Container = (Get-ADTParentDistinguishedName -DistinguishedName $dn)
        SamAccountName = 'jcote'; UserPrincipalName = 'jcote@lab.local'; SID = 'S-1-5-21-1-2-3-1105'
        GivenName = 'Joel'; Surname = 'Cote'; Initials = ''; Description = 'Compte de demonstration'; EmailAddress = 'jcote@lab.local'
        OfficePhone = ''; MobilePhone = ''; Office = ''; Title = 'Analyste'; Department = 'TI'; Company = 'Lab'
        Manager = 'CN=Marie Tremblay,OU=Employes,DC=lab,DC=local'; ManagedBy = ''; StreetAddress = ''; City = ''; State = ''
        PostalCode = ''; Country = ''; EmployeeID = ''; Notes = ''; HomeDirectory = ''; HomeDrive = ''; ProfilePath = ''; ScriptPath = ''
        Enabled = $true; LockedOut = $false; Status = 'Actif'; MustChangePassword = $false; CannotChangePassword = $false
        PasswordNeverExpires = $false; PasswordNotRequired = $false; SmartcardLogonRequired = $false; AccountNotDelegated = $false
        DoesNotRequirePreAuth = $false; UserAccountControl = 512; PasswordLastSet = (Get-Date).AddDays(-20); LastLogonDate = (Get-Date).AddDays(-1)
        AccountExpirationDate = (Get-Date).Date.AddDays(91); AccountExpiresEndOfDay = (Get-Date).Date.AddDays(90)
        whenCreated = (Get-Date).AddYears(-1); whenChanged = (Get-Date).AddDays(-2)
        LogonHoursMask = $mask; LogonHoursText = (ConvertTo-ADTLogonHoursText -Mask $mask); LogonHoursRestricted = $true
        MemberOf = @('CN=GS-VPN,OU=Employes,DC=lab,DC=local'); MemberOfNames = @('GS-VPN', 'GS-Ventes')
        GroupScope = 'Globale'; GroupCategory = 'Securite'; OperatingSystem = ''; OperatingSystemVersion = ''; DnsHostName = ''
        ProtectedFromDeletion = $true; PasswordPolicySource = 'Simulee'; MinimumPasswordLength = 12
    }
}

function Get-ADTGroupMember {
    [CmdletBinding()] param($Identity, $Recursive, $IncludeGroup, $Server, $Credential, $LogPath)
    foreach ($row in (Get-FakeChildren -Path 'OU=Employes,DC=lab,DC=local')) {
        if ([string]$row.ObjectClass -ne 'user') { continue }
        $row | Add-Member -NotePropertyName GroupName -NotePropertyValue 'GS-Ventes' -Force
        $row | Add-Member -NotePropertyName Department -NotePropertyValue 'Ventes' -Force -PassThru
    }
}

function Get-ADTUserLogonHours {
    [CmdletBinding()] param($Identity, $Server, $Credential, $LogPath)
    $mask = New-ADTLogonHoursMask -Day 1, 2, 3, 4, 5 -StartHour 8 -EndHour 18
    [pscustomobject]@{ SamAccountName = 'jcote'; Mask = $mask; Summary = (ConvertTo-ADTLogonHoursText -Mask $mask) }
}

# --- Ecriture -----------------------------------------------------------------
# Generees a partir des vraies fonctions : un splat qui ne correspond plus a leurs
# parametres echoue ici comme il echouerait en production.

$fakeWrites = @(
    'Set-ADTAccountState', 'Set-ADTUser', 'Set-ADTUserPassword', 'Set-ADTUserLogonHours', 'Set-ADTGroupMember',
    'Set-ADTUserGroupMembership', 'New-ADTGroup', 'New-ADTOrganizationalUnit', 'Set-ADTOrganizationalUnit',
    'Move-ADTObject', 'Remove-ADTObject', 'New-ADTUser', 'Get-ADTInactiveAccount', 'New-ADTCredentialDocument'
)
$common = @([System.Management.Automation.PSCmdlet]::CommonParameters) + @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)
foreach ($commandName in $fakeWrites) {
    $real = Get-Command -Name $commandName -Module PSADToolkit -ErrorAction Stop
    $names = @($real.Parameters.Keys | Where-Object { $common -notcontains $_ })
    $declared = ($names | ForEach-Object { '$' + $_ }) -join ', '
    $body = "[CmdletBinding(SupportsShouldProcess = `$true)] param($declared) " +
    "[pscustomobject]@{ Commande = '$commandName'; Status = 'Simulation'; Error = '' }"
    Set-Item -Path ('function:script:' + $commandName) -Value ([scriptblock]::Create($body))
}
