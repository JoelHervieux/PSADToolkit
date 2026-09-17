@{
    # ModuleToProcess (et non RootModule) pour rester lisible par PowerShell 2.0
    ModuleToProcess   = 'PSADToolkit.psm1'
    ModuleVersion     = '3.0.0'
    GUID              = 'd7c1e8a4-4b92-4f3e-9c21-5a8e6f0b3d11'
    Author            = 'Joel'
    CompanyName       = ''
    Copyright         = '(c) 2026. Licence MIT.'
    Description       = 'Boite a outils PowerShell pour automatiser la gestion des identites Active Directory : provisionnement, depart d employe, audit des acces et rapports. Controleurs de domaine Windows Server 2008 SP2 a 2025 via LDAP. Fonctions utilisables depuis Windows PowerShell 2.0 ; l interface graphique exige PowerShell 7.4 et le module GliderUI.'

    # Seuil volontairement bas : le module doit tourner sur d anciens serveurs
    PowerShellVersion = '2.0'

    # Le backend utilise System.DirectoryServices (ADSI / LDAP), sans RSAT ni ADWS.
    # Windows PowerShell 2.0 a 5.1; verification via Test-ADTPrerequisite.
    RequiredModules   = @()

    FunctionsToExport = @(
        'Test-ADTPrerequisite',
        'New-ADTUser',
        'Import-ADTUserFromCsv',
        'Set-ADTUserGroupMembership',
        'Start-ADTUserOffboarding',
        'Get-ADTInactiveAccount',
        'Get-ADTPrivilegedGroupMember',
        'Export-ADTAccessReport'
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
            Prerelease = 'test3'
            ProjectUri = 'https://github.com/JoelHervieux/PSADToolkit'
            LicenseUri = 'https://github.com/JoelHervieux/PSADToolkit/blob/main/LICENSE'
        }
    }
}
