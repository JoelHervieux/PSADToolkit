function ConvertTo-ADTAsciiString {
<#
.SYNOPSIS
    Retire les accents et les caracteres non ASCII d une chaine.
.DESCRIPTION
    Indispensable en environnement francophone : "Joel Cote-Tremblay" doit devenir
    un SamAccountName valide sans accent ni caractere special.
    Utilise la normalisation Unicode FormD, disponible depuis .NET 2.0.
.EXAMPLE
    ConvertTo-ADTAsciiString -Text 'Jose Andre Gagne'
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) { return '' }

    $normalized = $Text.Normalize([System.Text.NormalizationForm]::FormD)
    $builder = New-Object System.Text.StringBuilder

    foreach ($char in $normalized.ToCharArray()) {
        $category = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($char)
        if ($category -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$builder.Append($char)
        }
    }

    $clean = $builder.ToString()
    # On ne garde que lettres, chiffres, point, tiret et souligne
    $clean = [System.Text.RegularExpressions.Regex]::Replace($clean, '[^A-Za-z0-9\.\-_]', '')
    return $clean
}
