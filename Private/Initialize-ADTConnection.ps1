function Initialize-ADTConnection {
<#
.SYNOPSIS
    Verifie les prerequis puis rend les parametres de connexion communs.
.DESCRIPTION
    Toutes les fonctions publiques commencent par la meme sequence : fixer le
    journal, verifier LDAP et le domaine, puis constituer le splat Server /
    Credential passe au backend. Ce helper evite d en recopier une variante par
    fonction, et garantit que le controleur retenu par Test-ADTPrerequisite est
    bien celui utilise ensuite : sans cela, deux requetes successives pourraient
    tomber sur deux controleurs differents et lire un annuaire non replique.
.EXAMPLE
    $common = Initialize-ADTConnection -Server $Server -Credential $Credential
#>
    [CmdletBinding()]
    param(
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )
    if ($LogPath) { $script:ADTLogPath = $LogPath }
    $prerequisite = Test-ADTPrerequisite -Server $Server -Credential $Credential
    if (-not $prerequisite.Ready) { throw ('Prerequis non satisfaits : {0}' -f $prerequisite.Messages) }
    $common = @{}
    if ($prerequisite.Server) { $common['Server'] = [string]$prerequisite.Server }
    if ($Credential) { $common['Credential'] = $Credential }
    return $common
}
