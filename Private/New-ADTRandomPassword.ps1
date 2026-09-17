function New-ADTRandomPassword {
<#
.SYNOPSIS
    Genere un mot de passe aleatoire conforme aux exigences de complexite d Active Directory.
.DESCRIPTION
    Utilise RNGCryptoServiceProvider (aleatoire cryptographique) plutot que Get-Random,
    qui n est pas sur pour du materiel de securite.
    Par defaut, garantit au moins une majuscule, une minuscule, un chiffre et un
    caractere special, et exclut les caracteres ambigus (O, 0, l, 1, I) pour limiter
    les erreurs de saisie lors de la remise du mot de passe a l employe.

    Les classes de caracteres sont selectionnables. Une classe desactivee n est ni
    imposee ni tiree. Active Directory exige, lorsque la complexite est activee,
    des caracteres d au moins trois classes sur quatre : desactiver deux classes
    produit donc un mot de passe que le domaine refusera. La fonction ne l interdit
    pas, l appelant reste maitre de sa politique, mais Test-ADTPasswordComplexity
    permet de le verifier avant d ecrire dans l annuaire.
.PARAMETER Length
    Longueur du mot de passe. Minimum 12, defaut 16. PSADToolkit ne descend jamais
    sous 12 caracteres, meme si la strategie du domaine autorise plus court.
.PARAMETER UseUppercase
    Inclure des majuscules. Actif par defaut.
.PARAMETER UseLowercase
    Inclure des minuscules. Actif par defaut.
.PARAMETER UseDigit
    Inclure des chiffres. Actif par defaut.
.PARAMETER UseSpecial
    Inclure des caracteres speciaux. Actif par defaut.
.PARAMETER IncludeAmbiguous
    Reintegrer les caracteres ambigus O, 0, l, 1 et I.
.PARAMETER SpecialCharacter
    Jeu de caracteres speciaux a utiliser. Par defaut !#$%&*+-=?@, volontairement
    limite aux symboles qui se saisissent sans difficulte sur un clavier francais
    comme sur un clavier anglais.
.EXAMPLE
    New-ADTRandomPassword -Length 20
.EXAMPLE
    New-ADTRandomPassword -Length 24 -UseSpecial $false
#>
    [CmdletBinding()]
    param(
        [ValidateRange(12, 128)]
        [int]$Length = 16,
        [bool]$UseUppercase = $true,
        [bool]$UseLowercase = $true,
        [bool]$UseDigit = $true,
        [bool]$UseSpecial = $true,
        [switch]$IncludeAmbiguous,
        [string]$SpecialCharacter = '!#$%&*+-=?@'
    )

    if ($IncludeAmbiguous) {
        $upper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
        $lower = 'abcdefghijklmnopqrstuvwxyz'
        $digit = '0123456789'
    } else {
        $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
        $lower = 'abcdefghijkmnopqrstuvwxyz'
        $digit = '23456789'
    }
    $special = $SpecialCharacter

    $sets = New-Object System.Collections.ArrayList
    if ($UseUppercase) { [void]$sets.Add($upper) }
    if ($UseLowercase) { [void]$sets.Add($lower) }
    if ($UseDigit) { [void]$sets.Add($digit) }
    if ($UseSpecial -and $special) { [void]$sets.Add($special) }
    if (-not $sets.Count) { throw 'Aucune classe de caracteres selectionnee pour le mot de passe.' }
    if ($sets.Count -gt $Length) { throw ('Longueur {0} insuffisante pour couvrir {1} classes de caracteres.' -f $Length, $sets.Count) }

    $all = ''
    foreach ($set in $sets) { $all += $set }

    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    try {
        $bytes = New-Object 'System.Byte[]' 4

        # Rejet des tirages qui tomberaient dans la tranche incomplete de l espace
        # 32 bits : un simple modulo favoriserait les premiers caracteres du jeu.
        $pickChar = {
            param($set)
            $size = [long]$set.Length
            if ($size -le 1) { return $set[0] }
            $threshold = [long]4294967296 - ([long]4294967296 % $size)
            while ($true) {
                $rng.GetBytes($bytes)
                $value = [long][System.BitConverter]::ToUInt32($bytes, 0)
                if ($value -lt $threshold) { return $set[[int]($value % $size)] }
            }
        }

        $chars = New-Object System.Collections.ArrayList
        foreach ($set in $sets) { [void]$chars.Add((& $pickChar $set)) }

        while ($chars.Count -lt $Length) {
            [void]$chars.Add((& $pickChar $all))
        }

        # Melange Fisher-Yates pour que les premiers caracteres imposes ne soient
        # pas previsibles.
        for ($i = $chars.Count - 1; $i -gt 0; $i--) {
            $rng.GetBytes($bytes)
            $j = [int]([long][System.BitConverter]::ToUInt32($bytes, 0) % [long]($i + 1))
            $tmp = $chars[$i]
            $chars[$i] = $chars[$j]
            $chars[$j] = $tmp
        }

        return (-join $chars)
    } finally {
        if ($rng -and $rng.PSObject.Methods['Dispose']) { $rng.Dispose() }
    }
}

function Test-ADTPasswordComplexity {
<#
.SYNOPSIS
    Verifie qu un mot de passe satisfait la complexite Active Directory.
.DESCRIPTION
    Regle Microsoft : au moins trois des cinq categories (majuscule, minuscule,
    chiffre, caractere non alphanumerique, caractere Unicode hors categories
    precedentes), et longueur au moins egale au minimum du domaine.
    Le controle du nom de compte et du nom complet dans le mot de passe n est pas
    reproduit ici : il depend d un decoupage que seul le controleur applique.
.PARAMETER Password
    Mot de passe a verifier, en clair. N est jamais journalise.
.PARAMETER MinimumLength
    Longueur minimale exigee par la strategie.
.PARAMETER ComplexityEnabled
    Appliquer ou non la regle des trois categories.
.EXAMPLE
    Test-ADTPasswordComplexity -Password $clear -MinimumLength 12
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Password,
        [int]$MinimumLength = 7,
        [bool]$ComplexityEnabled = $true
    )
    $issues = New-Object System.Collections.ArrayList
    if ($Password.Length -lt $MinimumLength) {
        [void]$issues.Add(('Longueur {0} inferieure au minimum du domaine ({1}).' -f $Password.Length, $MinimumLength))
    }
    $categories = 0
    if ($Password -cmatch '[A-Z]') { $categories++ }
    if ($Password -cmatch '[a-z]') { $categories++ }
    if ($Password -match '[0-9]') { $categories++ }
    if ($Password -match '[^a-zA-Z0-9]') { $categories++ }
    if ($ComplexityEnabled -and $categories -lt 3) {
        [void]$issues.Add(('Complexite insuffisante : {0} categorie(s) sur les 3 exigees.' -f $categories))
    }
    New-Object PSObject -Property @{
        Valid      = ($issues.Count -eq 0)
        Categories = $categories
        Length     = $Password.Length
        Issues     = ($issues -join ' ')
    }
}
