function ConvertTo-ADTSecurePassword {
    param([Parameter(Mandatory=$true)][string]$Text)
    $secure=New-Object System.Security.SecureString
    foreach ($character in $Text.ToCharArray()) { $secure.AppendChar($character) }
    $secure.MakeReadOnly()
    return $secure
}
