function New-ADTRandomPassword {
<#
.SYNOPSIS
    Genere un mot de passe aleatoire conforme aux exigences de complexite d Active Directory.
.DESCRIPTION
    Utilise RNGCryptoServiceProvider (aleatoire cryptographique) plutot que Get-Random,
    qui n est pas sur pour du materiel de securite.
    Garantit au moins une majuscule, une minuscule, un chiffre et un caractere special.
    Les caracteres ambigus (O, 0, l, 1, I) sont exclus pour limiter les erreurs de saisie
    lors de la remise du mot de passe a l employe.
.PARAMETER Length
    Longueur du mot de passe. Minimum 12, defaut 16.
.EXAMPLE
    New-ADTRandomPassword -Length 20
#>
    [CmdletBinding()]
    param(
        [ValidateRange(12, 128)]
        [int]$Length = 16
    )

    $upper   = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower   = 'abcdefghijkmnopqrstuvwxyz'
    $digit   = '23456789'
    $special = '!#$%&*+-=?@'
    $all     = $upper + $lower + $digit + $special

    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    try {
        $bytes = New-Object 'System.Byte[]' 4

        $pickChar = {
            param($set)
            $rng.GetBytes($bytes)
            $value = [System.BitConverter]::ToUInt32($bytes, 0)
            $set[[int]($value % $set.Length)]
        }

        $chars = New-Object System.Collections.ArrayList
        [void]$chars.Add((& $pickChar $upper))
        [void]$chars.Add((& $pickChar $lower))
        [void]$chars.Add((& $pickChar $digit))
        [void]$chars.Add((& $pickChar $special))

        while ($chars.Count -lt $Length) {
            [void]$chars.Add((& $pickChar $all))
        }

        # Melange Fisher-Yates pour que les 4 premiers caracteres ne soient pas previsibles
        for ($i = $chars.Count - 1; $i -gt 0; $i--) {
            $rng.GetBytes($bytes)
            $j = [int]([System.BitConverter]::ToUInt32($bytes, 0) % ($i + 1))
            $tmp = $chars[$i]
            $chars[$i] = $chars[$j]
            $chars[$j] = $tmp
        }

        return (-join $chars)
    } finally {
        if ($rng -and $rng.PSObject.Methods['Dispose']) { $rng.Dispose() }
    }
}
