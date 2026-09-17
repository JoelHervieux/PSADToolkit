function New-ADTCredentialDocument {
<#
.SYNOPSIS
    Produit un document HTML de remise des identifiants a un employe.
.DESCRIPTION
    Genere une fiche imprimable contenant le nom de l employe, son identifiant,
    son UPN, son domaine et son mot de passe temporaire, avec les consignes de
    premiere connexion.

    Cette generation est une action volontaire : elle ne se declenche jamais
    automatiquement a la creation d un compte ou a la reinitialisation d un mot
    de passe. C est l administrateur qui la demande, et qui choisit ou le fichier
    est ecrit.

    Le fichier contient un mot de passe en clair. Il est cree avec les seules
    autorisations heritees du dossier choisi : deposer ce dossier sur un partage
    largement accessible reviendrait a publier les mots de passe. Le journal du
    module ne consigne que le compte concerne et le chemin du document, jamais le
    mot de passe lui-meme.

    Accepte la sortie de New-ADTUser et de Set-ADTUserPassword par le pipeline.
.PARAMETER SamAccountName
    Identifiant de connexion.
.PARAMETER Password
    Mot de passe temporaire a imprimer.
.PARAMETER DisplayName
    Nom complet de l employe.
.PARAMETER UserPrincipalName
    UPN du compte.
.PARAMETER Domain
    Nom du domaine. Lu dans l annuaire si absent et si -NoDirectoryLookup n est pas utilise.
.PARAMETER Path
    Fichier HTML a ecrire. Un dossier DEJA EXISTANT, ou un chemin se terminant par
    un separateur, est traite comme un dossier : le nom du fichier est alors
    derive de l identifiant et de l horodatage. Tout autre chemin designe le
    fichier lui-meme, dont les dossiers manquants sont crees.
.PARAMETER Force
    Ecrase un fichier existant.
.PARAMETER NoDirectoryLookup
    N interroge pas l annuaire pour completer les champs manquants.
.EXAMPLE
    Set-ADTUserPassword -Identity 'jcote' | New-ADTCredentialDocument -Path 'C:\Remises'
.EXAMPLE
    New-ADTCredentialDocument -SamAccountName 'jcote' -Password 'Exemple123!' -DisplayName 'Joel Cote' -Path 'C:\Remises\jcote.html' -NoDirectoryLookup
#>
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Le document remis a l employe doit contenir le mot de passe temporaire en clair; sa protection releve du choix du dossier de destination.')]
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('Identity', 'User')]
        [string]$SamAccountName,

        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [string]$Password,

        [Parameter(ValueFromPipelineByPropertyName = $true)][string]$DisplayName,
        [Parameter(ValueFromPipelineByPropertyName = $true)][string]$UserPrincipalName,
        [Parameter(ValueFromPipelineByPropertyName = $true)][string]$Domain,
        [Parameter(ValueFromPipelineByPropertyName = $true)][string]$DistinguishedName,
        [Parameter(ValueFromPipelineByPropertyName = $true)][string]$EmailAddress,

        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Title = 'Vos identifiants de connexion',
        [string]$Note,
        [switch]$Force,
        [switch]$NoDirectoryLookup,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    begin {
        $common = @{}
        if (-not $NoDirectoryLookup) {
            try { $common = Initialize-ADTConnection -Server $Server -Credential $Credential -LogPath $LogPath }
            catch {
                Write-Warning ('Annuaire non joignable, document produit avec les seules valeurs fournies. {0}' -f $_.Exception.Message)
                $NoDirectoryLookup = $true
            }
        } elseif ($LogPath) {
            $script:ADTLogPath = $LogPath
        }
    }

    process {
        if (-not $Password) { throw 'Aucun mot de passe a inscrire dans le document.' }

        $account = $null
        if (-not $NoDirectoryLookup -and (-not $DisplayName -or -not $UserPrincipalName -or -not $Domain)) {
            try { $account = Resolve-ADTConsoleObject -Identity $SamAccountName -ObjectFilter (Get-ADTConsoleClassFilter -Type User) @common }
            catch { Write-Warning ('Compte {0} non relu dans l annuaire : {1}' -f $SamAccountName, $_.Exception.Message) }
        }
        if ($account) {
            if (-not $DisplayName) { $DisplayName = [string]$account.DisplayName }
            if (-not $UserPrincipalName) { $UserPrincipalName = [string]$account.UserPrincipalName }
            if (-not $DistinguishedName) { $DistinguishedName = [string]$account.DistinguishedName }
            if (-not $EmailAddress) { $EmailAddress = [string]$account.EmailAddress }
        }
        if (-not $Domain -and $UserPrincipalName -and $UserPrincipalName.Contains('@')) {
            $Domain = $UserPrincipalName.Substring($UserPrincipalName.IndexOf('@') + 1)
        }
        if (-not $DisplayName) { $DisplayName = $SamAccountName }

        $target = $Path
        $isDirectory = (Test-Path -LiteralPath $Path -PathType Container)
        if ($isDirectory -or $Path.EndsWith('\') -or $Path.EndsWith('/')) {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $target = Join-Path -Path $Path -ChildPath ('identifiants-' + (ConvertTo-ADTAsciiString -Text $SamAccountName) + '-' + $stamp + '.html')
        }
        $folder = Split-Path -Parent $target
        if ($folder -and -not (Test-Path -LiteralPath $folder)) {
            New-Item -Path $folder -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        if ((Test-Path -LiteralPath $target) -and -not $Force) {
            throw ('Le fichier existe deja : {0}. Utiliser -Force pour l ecraser.' -f $target)
        }

        $status = 'Echec'
        $errorText = ''
        if ($PSCmdlet.ShouldProcess($target, ('Ecrire le document de remise des identifiants de {0}' -f $SamAccountName))) {
            try {
                $rows = @()
                $rows += New-Object PSObject -Property @{ Label = 'Nom'; Value = $DisplayName }
                $rows += New-Object PSObject -Property @{ Label = 'Identifiant de connexion'; Value = $SamAccountName }
                if ($UserPrincipalName) { $rows += New-Object PSObject -Property @{ Label = 'Nom d utilisateur principal (UPN)'; Value = $UserPrincipalName } }
                if ($Domain) { $rows += New-Object PSObject -Property @{ Label = 'Domaine'; Value = $Domain } }
                if ($EmailAddress) { $rows += New-Object PSObject -Property @{ Label = 'Courriel'; Value = $EmailAddress } }
                $rows += New-Object PSObject -Property @{ Label = 'Mot de passe temporaire'; Value = $Password }

                $html = New-Object System.Text.StringBuilder
                [void]$html.AppendLine('<!DOCTYPE html><html lang="fr"><head><meta charset="utf-8" />')
                [void]$html.AppendLine('<title>' + [System.Security.SecurityElement]::Escape($Title) + '</title>')
                [void]$html.AppendLine('<style>')
                [void]$html.AppendLine('body { font-family: Segoe UI, Arial, sans-serif; margin: 32px; color: #1c1c1c; }')
                [void]$html.AppendLine('h1 { font-size: 20px; border-bottom: 3px solid #2f5d8f; padding-bottom: 8px; }')
                [void]$html.AppendLine('table { border-collapse: collapse; margin-top: 18px; font-size: 14px; }')
                [void]$html.AppendLine('th { background: #2f5d8f; color: #fff; text-align: left; padding: 8px 14px; width: 260px; }')
                [void]$html.AppendLine('td { border: 1px solid #c9d4e2; padding: 8px 14px; font-family: Consolas, monospace; }')
                [void]$html.AppendLine('.avis { margin-top: 22px; padding: 12px 14px; border-left: 4px solid #b3541e; background: #fdf3ec; font-size: 13px; }')
                [void]$html.AppendLine('.pied { margin-top: 26px; color: #666; font-size: 11px; }')
                [void]$html.AppendLine('</style></head><body>')
                [void]$html.AppendLine('<h1>' + [System.Security.SecurityElement]::Escape($Title) + '</h1>')
                [void]$html.AppendLine('<table>')
                foreach ($row in $rows) {
                    [void]$html.AppendLine('<tr><th>' + [System.Security.SecurityElement]::Escape([string]$row.Label) + '</th><td>' +
                        [System.Security.SecurityElement]::Escape([string]$row.Value) + '</td></tr>')
                }
                [void]$html.AppendLine('</table>')
                [void]$html.AppendLine('<div class="avis">Ce mot de passe est temporaire. Il doit etre change a la premiere ouverture de session et ne doit etre communique a personne. Detruire ce document une fois le mot de passe change.</div>')
                if ($Note) { [void]$html.AppendLine('<div class="avis">' + [System.Security.SecurityElement]::Escape($Note) + '</div>') }
                [void]$html.AppendLine('<div class="pied">Document genere le ' + [System.Security.SecurityElement]::Escape((Format-ADTDateTime -Value (Get-Date))) +
                    ' par ' + [System.Security.SecurityElement]::Escape((Get-ADTOperatorName)) + '.</div>')
                [void]$html.AppendLine('</body></html>')

                Set-Content -Path $target -Value $html.ToString() -Encoding UTF8 -ErrorAction Stop
                $status = 'Genere'
                # Le mot de passe ne figure jamais dans le journal, seulement le
                # fait qu un document a ete produit et ou.
                Write-ADTLog -Level 'INFO' -Message ('Document de remise genere pour {0} : {1}' -f $SamAccountName, $target)
            } catch {
                $errorText = $_.Exception.Message
                Write-ADTLog -Level 'ERROR' -Message ('Document de remise non genere pour {0} : {1}' -f $SamAccountName, $errorText)
            }
        } else {
            $status = 'Simulation'
        }

        $output = New-Object PSObject -Property @{
            SamAccountName = $SamAccountName; DisplayName = $DisplayName; Path = $target; Status = $status; Error = $errorText
        }
        $output | Select-Object SamAccountName, DisplayName, Path, Status, Error
    }
}
