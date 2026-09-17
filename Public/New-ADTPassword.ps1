function New-ADTPassword {
<#
.SYNOPSIS
    Genere un mot de passe aleatoire configurable, conforme a la strategie du domaine.
.DESCRIPTION
    Generateur cryptographique du module, expose avec ses reglages : longueur,
    classes de caracteres, caracteres ambigus, jeu de symboles.

    Par defaut, la strategie du domaine est lue et la longueur demandee est
    relevee si elle est inferieure au minimum exige. PSADToolkit ne descend jamais
    sous 12 caracteres, meme lorsque le domaine autorise plus court : un mot de
    passe temporaire circule par courriel ou sur papier, il merite cette marge.
    -NoPolicyCheck evite l aller-retour vers l annuaire lorsqu il n est pas joignable.

    Le mot de passe genere n est jamais journalise. Seul l appelant en dispose.
.PARAMETER Length
    Longueur demandee. Minimum 12, defaut 16.
.PARAMETER Count
    Nombre de mots de passe a generer.
.PARAMETER NoUppercase
    Exclut les majuscules.
.PARAMETER NoLowercase
    Exclut les minuscules.
.PARAMETER NoDigit
    Exclut les chiffres.
.PARAMETER NoSpecial
    Exclut les caracteres speciaux.
.PARAMETER IncludeAmbiguous
    Reintegre O, 0, l, 1 et I, exclus par defaut pour eviter les erreurs de saisie.
.PARAMETER SpecialCharacter
    Jeu de symboles autorises.
.PARAMETER NoPolicyCheck
    N interroge pas l annuaire et n ajuste pas la longueur.
.EXAMPLE
    New-ADTPassword
.EXAMPLE
    New-ADTPassword -Length 24 -NoSpecial -Count 5
#>
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Cette fonction produit un mot de passe temporaire a remettre a l employe; il doit etre lisible par l appelant.')]
    [CmdletBinding()]
    param(
        [ValidateRange(12, 128)][int]$Length = 16,
        [ValidateRange(1, 500)][int]$Count = 1,
        [switch]$NoUppercase,
        [switch]$NoLowercase,
        [switch]$NoDigit,
        [switch]$NoSpecial,
        [switch]$IncludeAmbiguous,
        [string]$SpecialCharacter = '!#$%&*+-=?@',
        [switch]$NoPolicyCheck,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    $effectiveLength = $Length
    $policySource = 'Non consultee'
    $minimum = 0
    $complexity = $true

    if (-not $NoPolicyCheck) {
        try {
            $common = Initialize-ADTConnection -Server $Server -Credential $Credential -LogPath $LogPath
            $policy = Get-ADTNativePasswordPolicy @common
            $minimum = [int]$policy.MinimumPasswordLength
            $complexity = [bool]$policy.ComplexityEnabled
            $policySource = [string]$policy.Source
            if ($effectiveLength -lt $minimum) {
                Write-Warning ('Longueur portee de {0} a {1} pour respecter la strategie du domaine.' -f $Length, $minimum)
                $effectiveLength = $minimum
            }
        } catch {
            $policySource = 'Strategie illisible : ' + $_.Exception.Message
            Write-Warning ('Strategie du domaine non lue, longueur demandee conservee. {0}' -f $_.Exception.Message)
        }
    }
    if ($effectiveLength -gt 128) { $effectiveLength = 128 }

    $generator = @{
        Length           = $effectiveLength
        UseUppercase     = (-not $NoUppercase)
        UseLowercase     = (-not $NoLowercase)
        UseDigit         = (-not $NoDigit)
        UseSpecial       = (-not $NoSpecial)
        SpecialCharacter = $SpecialCharacter
    }
    if ($IncludeAmbiguous) { $generator['IncludeAmbiguous'] = $true }

    for ($index = 0; $index -lt $Count; $index++) {
        $clear = New-ADTRandomPassword @generator
        $check = Test-ADTPasswordComplexity -Password $clear -MinimumLength $minimum -ComplexityEnabled $complexity
        $result = New-Object PSObject -Property @{
            Password         = $clear
            Length           = $clear.Length
            MeetsPolicy      = $check.Valid
            PolicyIssues     = [string]$check.Issues
            PolicySource     = $policySource
            CharacterClasses = [int]$check.Categories
        }
        $result | Select-Object Password, Length, MeetsPolicy, PolicyIssues, CharacterClasses, PolicySource
    }
}
