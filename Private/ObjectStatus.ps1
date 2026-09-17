# Etat lisible d un objet de l annuaire, partage par les listes, la recherche et
# les fiches de proprietes pour qu une meme situation s affiche partout pareil.

function Test-ADTObjectIsContainer {
<#
.SYNOPSIS
    Indique si une classe d objet peut contenir d autres objets.
.EXAMPLE
    Test-ADTObjectIsContainer -ObjectClass 'organizationalUnit'
#>
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowEmptyString()][string]$ObjectClass)
    return (@('organizationalUnit', 'container', 'builtinDomain', 'domainDNS') -contains [string]$ObjectClass)
}

function Get-ADTObjectStatusText {
<#
.SYNOPSIS
    Resume l etat d un compte : actif, desactive, verrouille, expire.
.DESCRIPTION
    Les conteneurs et les groupes n ont pas d etat de compte : la fonction rend
    une chaine vide plutot qu un statut trompeur.
.EXAMPLE
    Get-ADTObjectStatusText -Object $user
#>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, Position = 0)]$Object)
    $class = [string]$Object.ObjectClass
    if (@('user', 'computer') -notcontains $class) { return '' }

    $states = New-Object System.Collections.ArrayList
    if ($Object.Enabled) { [void]$states.Add('Actif') } else { [void]$states.Add('Desactive') }
    if ($Object.LockedOut) { [void]$states.Add('Verrouille') }
    if ($Object.AccountExpirationDate -and ([datetime]$Object.AccountExpirationDate) -lt (Get-Date)) { [void]$states.Add('Expire') }
    if ($Object.MustChangePassword) { [void]$states.Add('Mot de passe a changer') }
    return ($states -join ', ')
}

function Get-ADTRdnValue {
<#
.SYNOPSIS
    Valeur lisible du premier composant d un DN, sans son prefixe ni ses echappements.
.DESCRIPTION
    'CN=Cote\, Joel,OU=Employes,DC=contoso,DC=local' rend 'Cote, Joel'.
    Sert a afficher un groupe ou un gestionnaire sans imposer son DN complet.
.EXAMPLE
    Get-ADTRdnValue -DistinguishedName 'CN=GS-VPN,OU=Groupes,DC=contoso,DC=local'
#>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][string]$DistinguishedName)
    if (-not $DistinguishedName) { return '' }
    $rdn = $DistinguishedName
    for ($index = 0; $index -lt $DistinguishedName.Length; $index++) {
        if ($DistinguishedName[$index] -eq ',' -and ($index -eq 0 -or $DistinguishedName[$index - 1] -ne '\')) {
            $rdn = $DistinguishedName.Substring(0, $index)
            break
        }
    }
    $separator = $rdn.IndexOf('=')
    if ($separator -ge 0) { $rdn = $rdn.Substring($separator + 1) }
    # Les echappements RDN doivent etre defaits dans l ordre inverse de leur pose.
    foreach ($pair in @(',', '+', '"', '<', '>', ';', '=')) { $rdn = $rdn.Replace('\' + $pair, $pair) }
    $rdn = $rdn.Replace('\2f', '/').Replace('\20', ' ')
    $rdn = $rdn.Replace('\\', '\')
    return $rdn
}

function Get-ADTOperatorName {
<#
.SYNOPSIS
    Identite de l operateur courant, pour les traces et les documents produits.
.DESCRIPTION
    USERDOMAIN n est pas renseigne partout : sur un poste hors domaine ou sous
    PowerShell 7 multiplateforme, seul USERNAME l est. La fonction rend alors le
    seul nom d utilisateur plutot qu un '\' isole.
.EXAMPLE
    Get-ADTOperatorName
#>
    [CmdletBinding()]
    param()
    $domain = [string]$env:USERDOMAIN
    $user = [string]$env:USERNAME
    if (-not $user) { $user = [string]$env:USER }
    if ($domain -and $user) { return ('{0}\{1}' -f $domain, $user) }
    if ($user) { return $user }
    return 'compte inconnu'
}
