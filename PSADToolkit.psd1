@{
    # ModuleToProcess (et non RootModule) pour rester lisible par PowerShell 2.0
    ModuleToProcess   = 'PSADToolkit.psm1'
    ModuleVersion     = '3.1.0'
    GUID              = 'd7c1e8a4-4b92-4f3e-9c21-5a8e6f0b3d11'
    Author            = 'Joel'
    CompanyName       = ''
    Copyright         = '(c) 2026. Licence MIT.'
    Description       = 'Boite a outils PowerShell pour administrer Active Directory : console d arborescence (OU, utilisateurs, groupes, ordinateurs), provisionnement, depart d employe, horaires de connexion, mots de passe, audit des acces et rapports. Controleurs de domaine Windows Server 2008 SP2 a 2025 via LDAP, sans RSAT. Fonctions utilisables depuis Windows PowerShell 2.0 ; l interface graphique exige PowerShell 7.4 et le module GliderUI.'

    # Seuil volontairement bas : le module doit tourner sur d anciens serveurs
    PowerShellVersion = '2.0'

    # Le backend utilise System.DirectoryServices (ADSI / LDAP), sans RSAT ni ADWS.
    # Windows PowerShell 2.0 a 5.1; verification via Test-ADTPrerequisite.
    RequiredModules   = @()

    FunctionsToExport = @(
        # Socle historique : provisionnement, depart, audit.
        'Test-ADTPrerequisite',
        'New-ADTUser',
        'Import-ADTUserFromCsv',
        'Set-ADTUserGroupMembership',
        'Start-ADTUserOffboarding',
        'Get-ADTInactiveAccount',
        'Get-ADTPrivilegedGroupMember',
        'Export-ADTAccessReport',
        # Console d administration : navigation et lecture.
        'Get-ADTDirectoryChild',
        'Find-ADTDirectoryObject',
        'Get-ADTObjectProperty',
        'Get-ADTGroupMember',
        'Get-ADTPasswordPolicy',
        'Get-ADTUserLogonHours',
        # Console d administration : ecriture.
        'Set-ADTUser',
        'Set-ADTAccountState',
        'Set-ADTUserPassword',
        'Set-ADTUserLogonHours',
        'Set-ADTGroupMember',
        'New-ADTGroup',
        'New-ADTOrganizationalUnit',
        'Set-ADTOrganizationalUnit',
        'Move-ADTObject',
        'Remove-ADTObject',
        # Outils : mots de passe, horaires, document de remise.
        'New-ADTPassword',
        'New-ADTLogonHourSchedule',
        'New-ADTCredentialDocument'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    # Canal de version. Voir VERSIONING.md.
    # ModuleVersion reste purement numerique : Windows PowerShell 2.0 n accepte
    # aucun suffixe. Le canal de la version est donc porte ici.
    # Chaine vide = version stable, validee par la recette Windows de VALIDATION.md.
    PrivateData       = @{
        PSData = @{
            Prerelease = 'test1'
            ProjectUri = 'https://github.com/JoelHervieux/PSADToolkit'
            LicenseUri = 'https://github.com/JoelHervieux/PSADToolkit/blob/main/LICENSE'
        }
    }
}
