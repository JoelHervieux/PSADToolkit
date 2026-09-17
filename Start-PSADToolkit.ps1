#requires -version 2.0
<#
.SYNOPSIS
    Interface graphique francaise pour PSADToolkit. Lancer avec Lancer.cmd.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or $PSVersionTable.PSVersion.Major -gt 5) { throw 'Utiliser Windows PowerShell 2.0 a 5.1 (powershell.exe).' }
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Lancer via Lancer.cmd ou powershell.exe -STA -File Start-PSADToolkit.ps1.' }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Data
[Windows.Forms.Application]::EnableVisualStyles()
$script:Worker=$null; $script:Handle=$null; $script:Runspace=$null; $script:Rows=@(); $script:Operation=''

function New-UiControl {
    param([string]$Type,$Parent,[string]$Text,[int]$X,[int]$Y,[int]$Width,[int]$Height)
    $c=New-Object ('System.Windows.Forms.'+$Type)
    $c.Text=$Text; $c.Location=New-Object Drawing.Point($X,$Y); $c.Size=New-Object Drawing.Size($Width,$Height)
    $Parent.Controls.Add($c); return $c
}
function Show-UiError { param($Message) [void][Windows.Forms.MessageBox]::Show([string]$Message,'PSADToolkit',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Error) }
function Get-UiConnection {
    $p=@{}
    if ($serverBox.Text.Trim()) { $p['Server']=$serverBox.Text.Trim() }
    if ($otherAccount.Checked) {
        if (-not $userBox.Text.Trim() -or -not $passwordBox.Text) { throw 'Indiquer le compte DOMAINE\utilisateur (ou UPN) et son mot de passe.' }
        $secure=New-Object System.Security.SecureString
        foreach ($character in $passwordBox.Text.ToCharArray()) { $secure.AppendChar($character) }
        $secure.MakeReadOnly()
        $p['Credential']=New-Object System.Management.Automation.PSCredential($userBox.Text.Trim(),$secure)
    }
    return $p
}

function New-FieldSpec {
    param([string]$Key,[string]$Label,[string]$Kind)
    return (New-Object PSObject -Property @{Key=$Key;Label=$Label;Kind=$Kind;Required=([bool]$Label.EndsWith('*'))})
}
function Open-UiDirectoryEntry {
    param([string]$DN,[string]$Server,[System.Management.Automation.PSCredential]$Credential)
    $path='LDAP://'
    if ($Server) { $path += $Server + '/' }
    $path += $DN
    $entry=New-Object System.DirectoryServices.DirectoryEntry
    $entry.Path=$path
    $entry.AuthenticationType=[System.DirectoryServices.AuthenticationTypes]::Secure -bor [System.DirectoryServices.AuthenticationTypes]::Signing -bor [System.DirectoryServices.AuthenticationTypes]::Sealing
    if ($Credential) { $entry.Username=$Credential.UserName; $entry.Password=$Credential.GetNetworkCredential().Password }
    $null=$entry.NativeObject
    return ,$entry
}
function Show-OUSelectionDialog {
    param([string]$CurrentDN)
    $conn=Get-UiConnection
    $server=''; $credential=$null
    if ($conn.ContainsKey('Server')) { $server=[string]$conn['Server'] }
    if ($conn.ContainsKey('Credential')) { $credential=$conn['Credential'] }
    $root=Open-UiDirectoryEntry -DN 'RootDSE' -Server $server -Credential $credential
    try {
        $domainDN=[string]$root.Properties['defaultNamingContext'][0]
        if (-not $server) { $server=[string]$root.Properties['dnsHostName'][0] }
    } finally { $root.Dispose() }
    if (-not $domainDN) { throw 'Impossible de determiner le domaine Active Directory.' }

    $dialog=New-Object Windows.Forms.Form
    $dialog.Text='Selectionner une OU'; $dialog.Size=New-Object Drawing.Size(720,560); $dialog.StartPosition='CenterParent'
    $tree=New-UiControl 'TreeView' $dialog '' 12 12 680 435; $tree.Anchor='Top,Bottom,Left,Right'; $tree.HideSelection=$false
    $dnBox=New-UiControl 'TextBox' $dialog '' 12 455 680 23; $dnBox.Anchor='Bottom,Left,Right'; $dnBox.ReadOnly=$true
    $ok=New-UiControl 'Button' $dialog 'Selectionner' 490 488 98 30; $ok.Anchor='Bottom,Right'; $ok.DialogResult=[Windows.Forms.DialogResult]::OK
    $cancel=New-UiControl 'Button' $dialog 'Annuler' 594 488 98 30; $cancel.Anchor='Bottom,Right'; $cancel.DialogResult=[Windows.Forms.DialogResult]::Cancel
    $dialog.AcceptButton=$ok; $dialog.CancelButton=$cancel

    $domainNode=New-Object Windows.Forms.TreeNode($domainDN); $domainNode.Tag=$domainDN
    $dummy=New-Object Windows.Forms.TreeNode('Chargement...'); $dummy.Tag='__DUMMY__'; [void]$domainNode.Nodes.Add($dummy); [void]$tree.Nodes.Add($domainNode)

    $loadChildren={
        param($node)
        if ($node.Nodes.Count -eq 1 -and [string]$node.Nodes[0].Tag -eq '__DUMMY__') {
            $node.Nodes.Clear()
            $base=Open-UiDirectoryEntry -DN ([string]$node.Tag) -Server $server -Credential $credential
            $searcher=New-Object System.DirectoryServices.DirectorySearcher($base)
            try {
                $searcher.SearchScope=[System.DirectoryServices.SearchScope]::OneLevel
                $searcher.Filter='(objectClass=organizationalUnit)'; $searcher.PageSize=1000
                [void]$searcher.PropertiesToLoad.Add('distinguishedName'); [void]$searcher.PropertiesToLoad.Add('name')
                $children=@($searcher.FindAll() | ForEach-Object {
                    New-Object PSObject -Property @{Name=[string]$_.Properties['name'][0];DN=[string]$_.Properties['distinguishedname'][0]}
                } | Sort-Object Name)
                foreach ($child in $children) {
                    $n=New-Object Windows.Forms.TreeNode($child.Name); $n.Tag=$child.DN
                    $d=New-Object Windows.Forms.TreeNode('Chargement...'); $d.Tag='__DUMMY__'; [void]$n.Nodes.Add($d); [void]$node.Nodes.Add($n)
                }
            } finally { $searcher.Dispose(); $base.Dispose() }
        }
    }
    $tree.Add_BeforeExpand({ param($sender,$e) & $loadChildren $e.Node })
    $tree.Add_AfterSelect({ $dnBox.Text=[string]$tree.SelectedNode.Tag })
    & $loadChildren $domainNode; $domainNode.Expand()
    $tree.SelectedNode=$domainNode

    try {
        if ($dialog.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK -and $tree.SelectedNode) { return [string]$tree.SelectedNode.Tag }
        return $null
    } finally { $dialog.Dispose() }
}
function Read-UiFlexibleCsv {
    param([string]$Path,[char]$Delimiter)
    Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
    $parser=New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($Path,[Text.Encoding]::UTF8,$true)
    $list=New-Object System.Collections.ArrayList
    try {
        $parser.TextFieldType=[Microsoft.VisualBasic.FileIO.FieldType]::Delimited; $parser.SetDelimiters(@([string]$Delimiter)); $parser.HasFieldsEnclosedInQuotes=$true
        $header=$parser.ReadFields(); if (-not $header) { throw 'En-tete CSV invalide.' }
        $groupIndex=-1
        for ($i=0;$i -lt $header.Count;$i++) { $header[$i]=([string]$header[$i]).TrimStart([char]0xFEFF).Trim(); if ($header[$i] -eq 'Groups') { $groupIndex=$i } }
        while (-not $parser.EndOfData) {
            $cells=$parser.ReadFields(); if (-not $cells) { continue }
            if ($cells.Count -gt $header.Count -and $groupIndex -ge 0) {
                $extra=$cells.Count-$header.Count; $fixed=New-Object string[] $header.Count
                for ($j=0;$j -lt $groupIndex;$j++) { $fixed[$j]=[string]$cells[$j] }
                $parts=New-Object System.Collections.ArrayList
                for ($j=$groupIndex;$j -le ($groupIndex+$extra);$j++) { if ([string]$cells[$j]) { [void]$parts.Add(([string]$cells[$j]).Trim()) } }
                $fixed[$groupIndex]=[string]($parts -join ';')
                for ($j=$groupIndex+1;$j -lt $header.Count;$j++) { $fixed[$j]=[string]$cells[$j+$extra] }
                $cells=$fixed
            }
            $o=New-Object PSObject
            for ($j=0;$j -lt $header.Count;$j++) { $v=''; if ($j -lt $cells.Count) { $v=[string]$cells[$j] }; $o | Add-Member NoteProperty $header[$j] $v }
            [void]$list.Add($o)
        }
    } finally { $parser.Close(); $parser.Dispose() }
    # Retourner chaque ligne directement. Une virgule unaire ici creerait un
    # tableau imbrique et casserait l apercu ainsi que la detection des colonnes.
    return $list.ToArray()
}
function Show-ImportPreviewDialog {
    param([hashtable]$Parameters)
    if (-not $Parameters['Path']) { throw 'Selectionner un fichier CSV.' }
    if (-not $Parameters['DefaultOU']) { throw 'Selectionner l OU de destination avant de poursuivre l import.' }
    $delimiter=[char]';'; if ($Parameters.ContainsKey('Delimiter')) { $delimiter=[char]$Parameters['Delimiter'] }
    $rows=@(Read-UiFlexibleCsv -Path $Parameters['Path'] -Delimiter $delimiter)
    if (-not $rows.Count) { throw 'Le fichier CSV ne contient aucune ligne.' }
    $table=New-Object System.Data.DataTable
    foreach ($name in @('Prenom','Nom','Departement','OU cible','Groupes')) { [void]$table.Columns.Add($name,[string]) }
    foreach ($row in $rows) {
        $target=''
        if ($Parameters['CreateDepartmentOUs']) {
            $target=[string]$Parameters['DefaultOU']; $dept=([string]$row.Department).Trim()
            if ($dept) { $safe=$dept.Replace('\','\\').Replace(',','\\,').Replace('+','\\+').Replace('"','\\"').Replace('<','\\<').Replace('>','\\>').Replace(';','\\;').Replace('=','\\='); $target='OU='+$safe+','+$target }
        } else { $target=[string]$Parameters['DefaultOU'] }
        $groups=New-Object System.Collections.ArrayList
        if ($Parameters['DefaultGroups']) { foreach ($g in $Parameters['DefaultGroups']) { if ($g) { [void]$groups.Add($g) } } }
        if ($row.PSObject.Properties['Groups'] -and $row.Groups) { foreach ($g in (([string]$row.Groups)-split ';')) { if ($g.Trim()) { [void]$groups.Add($g.Trim()) } } }
        $r=$table.NewRow(); $r['Prenom']=[string]$row.GivenName; $r['Nom']=[string]$row.Surname; $r['Departement']=[string]$row.Department; $r['OU cible']=$target; $r['Groupes']=$groups -join '; '; $table.Rows.Add($r)
    }
    $d=New-Object Windows.Forms.Form; $d.Text='Apercu avant import'; $d.Size=New-Object Drawing.Size(1000,600); $d.StartPosition='CenterParent'
    $lab=New-UiControl 'Label' $d ('Apercu de '+$rows.Count+' utilisateur(s). Verifier les OU et les groupes avant de continuer.') 12 12 950 23
    $g=New-UiControl 'DataGridView' $d '' 12 42 960 470; $g.Anchor='Top,Bottom,Left,Right'; $g.ReadOnly=$true; $g.AllowUserToAddRows=$false; $g.RowHeadersVisible=$false; $g.AutoSizeColumnsMode='DisplayedCells'; $g.DataSource=$table
    $go=New-UiControl 'Button' $d 'Continuer' 760 525 100 30; $go.Anchor='Bottom,Right'; $go.DialogResult=[Windows.Forms.DialogResult]::OK
    $no=New-UiControl 'Button' $d 'Annuler' 872 525 100 30; $no.Anchor='Bottom,Right'; $no.DialogResult=[Windows.Forms.DialogResult]::Cancel
    $d.AcceptButton=$go; $d.CancelButton=$no
    try { return ($d.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) } finally { $d.Dispose() }
}
function Start-UiOperation {
    param([string]$Command,[hashtable]$Parameters)
    if ($script:Worker) { return }
    $script:Operation=$Command
    $script:Rows=@(); $grid.DataSource=$null; $details.Clear()
    $statusLabel.Text='Traitement en cours : '+$Command
    $connection.Enabled=$false; $tabs.Enabled=$false; $exportButton.Enabled=$false
    $progress.Style='Marquee'
    try {
        $script:Runspace=[RunspaceFactory]::CreateRunspace()
        $script:Runspace.ApartmentState='STA'; $script:Runspace.ThreadOptions='ReuseThread'; $script:Runspace.Open()
        $script:Worker=[PowerShell]::Create(); $script:Worker.Runspace=$script:Runspace
        $workerScript={
            param($ModulePath,$Command,$Parameters)
            $ErrorActionPreference='Stop'
            Import-Module $ModulePath -Force -ErrorAction Stop
            & $Command @Parameters
        }
        $null=$script:Worker.AddScript($workerScript.ToString()).AddArgument((Join-Path $script:Root 'PSADToolkit.psd1')).AddArgument($Command).AddArgument($Parameters)
        $script:Handle=$script:Worker.BeginInvoke()
        $timer.Start()
    } catch {
        if ($script:Worker) { $script:Worker.Dispose(); $script:Worker=$null }
        if ($script:Runspace) { $script:Runspace.Dispose(); $script:Runspace=$null }
        $connection.Enabled=$true; $tabs.Enabled=$true; $progress.Style='Blocks'
        $statusLabel.Text='Echec du lancement'; Show-UiError $_.Exception.Message
    }
}
function Update-UiGrid {
    $table=New-Object System.Data.DataTable
    if ($script:Rows.Count) {
        $names=@($script:Rows[0].PSObject.Properties | ForEach-Object { $_.Name })
        foreach ($name in $names) {
            if ($name -eq 'Password' -and -not $showPasswords.Checked) { continue }
            [void]$table.Columns.Add($name,[string])
        }
        foreach ($item in $script:Rows) {
            $row=$table.NewRow()
            foreach ($col in $table.Columns) { $row[$col.ColumnName]=[string]$item.($col.ColumnName) }
            $table.Rows.Add($row)
        }
    }
    $grid.DataSource=$table
    $exportButton.Enabled=($script:Rows.Count -gt 0)
}

$form=New-Object Windows.Forms.Form
$form.Text='PSADToolkit 2.1.4-test1 | Administration Active Directory'
$form.Size=New-Object Drawing.Size(1110,850); $form.MinimumSize=New-Object Drawing.Size(1020,780)
$form.StartPosition='CenterScreen'; $form.Font=New-Object Drawing.Font('Segoe UI',9)
$form.BackColor=[Drawing.Color]::FromArgb(242,245,249)
$header=New-UiControl 'Panel' $form '' 0 0 1090 65
$header.BackColor=[Drawing.Color]::FromArgb(22,40,64); $header.Anchor='Top,Left,Right'
$title=New-UiControl 'Label' $header 'PSADToolkit' 22 10 270 30
$title.ForeColor=[Drawing.Color]::White; $title.Font=New-Object Drawing.Font('Segoe UI',18,[Drawing.FontStyle]::Bold)
$subtitle=New-UiControl 'Label' $header 'Comptes, accès et audits Active Directory' 305 23 700 25
$subtitle.ForeColor=[Drawing.Color]::FromArgb(190,212,237)
$connection=New-UiControl 'GroupBox' $form 'Connexion au domaine' 15 75 1060 110
$connection.Anchor='Top,Left,Right'
$null=New-UiControl 'Label' $connection 'Contrôleur de domaine (FQDN, vide = automatique)' 15 22 340 20
$serverBox=New-UiControl 'TextBox' $connection '' 15 45 330 25
$otherAccount=New-UiControl 'CheckBox' $connection 'Autre compte' 365 21 155 22
$userBox=New-UiControl 'TextBox' $connection '' 365 46 235 25
$passwordBox=New-UiControl 'TextBox' $connection '' 615 46 220 25; $passwordBox.UseSystemPasswordChar=$true
$null=New-UiControl 'Label' $connection 'Mot de passe' 615 23 200 20
$testButton=New-UiControl 'Button' $connection 'Tester la connexion' 850 43 190 30
$userBox.Enabled=$false; $passwordBox.Enabled=$false
$otherAccount.Add_CheckedChanged({ $userBox.Enabled=$otherAccount.Checked; $passwordBox.Enabled=$otherAccount.Checked; if (-not $otherAccount.Checked) { $passwordBox.Clear() } })
$null=New-UiControl 'Label' $connection 'Compte de la session Windows utilise par defaut. Les droits AD delegues suffisent.' 15 80 1000 22
$testButton.Add_Click({ try { Start-UiOperation 'Test-ADTPrerequisite' (Get-UiConnection) } catch { Show-UiError $_.Exception.Message } })

$tabs=New-UiControl 'TabControl' $form '' 15 195 1060 320
$tabs.Anchor='Top,Left,Right'
# Each operation has a compact form. Keys map directly to existing public parameters.
$specs=@(
 (New-Object PSObject -Property @{Title='Creer un compte';Command='New-ADTUser';Write=$true;Fields=@(
    (New-FieldSpec 'GivenName' 'Prenom *' 'text'),(New-FieldSpec 'Surname' 'Nom *' 'text'),(New-FieldSpec 'Path' 'OU cible (DN) *' 'ou'),(New-FieldSpec 'SamAccountName' 'Identifiant (vide = automatique)' 'text'),(New-FieldSpec 'Department' 'Service' 'text'),(New-FieldSpec 'Title' 'Fonction' 'text'),(New-FieldSpec 'Groups' 'Groupes (separes par ;)' 'list'),(New-FieldSpec 'EmailAddress' 'Courriel' 'text'),(New-FieldSpec 'HomeDirectoryRoot' 'Racine du dossier personnel (UNC)' 'text'),(New-FieldSpec 'HomeDrive' 'Lecteur (ex. H:)' 'text'),(New-FieldSpec 'Disabled' 'Creer le compte desactive' 'check'))}),
 (New-Object PSObject -Property @{Title='Importer un CSV';Command='Import-ADTUserFromCsv';Write=$true;Fields=@(
    (New-FieldSpec 'Path' 'Fichier CSV *' 'open'),(New-FieldSpec 'DefaultOU' 'OU de destination *' 'ou'),(New-FieldSpec 'DefaultGroups' 'Groupes par defaut (;)' 'list'),(New-FieldSpec 'Delimiter' 'Separateur du CSV' 'delimiter'),(New-FieldSpec 'CreateDepartmentOUs' 'Creer automatiquement une sous-OU par departement' 'check'),(New-FieldSpec 'PasswordReportPath' 'Rapport des mots de passe (facultatif)' 'savecsv'),(New-FieldSpec 'SkipExisting' 'Ignorer les identifiants deja existants' 'check'))}),
 (New-Object PSObject -Property @{Title='Groupes';Command='Set-ADTUserGroupMembership';Write=$true;Fields=@(
    (New-FieldSpec 'Identity' 'Utilisateurs (identifiants separes par ;) *' 'list'),(New-FieldSpec 'AddGroup' 'Groupes a ajouter (;)' 'list'),(New-FieldSpec 'RemoveGroup' 'Groupes a retirer (;)' 'list'))}),
 (New-Object PSObject -Property @{Title='Depart';Command='Start-ADTUserOffboarding';Write=$true;Fields=@(
    (New-FieldSpec 'Identity' 'Utilisateurs (identifiants separes par ;) *' 'list'),(New-FieldSpec 'BackupPath' 'Dossier des sauvegardes *' 'folder'),(New-FieldSpec 'DisabledOU' 'OU de destination (DN, facultatif)' 'ou'),(New-FieldSpec 'Reason' 'Motif' 'text'),(New-FieldSpec 'KeepGroups' 'Conserver les groupes secondaires' 'check'),(New-FieldSpec 'NoPasswordReset' 'Conserver le mot de passe actuel' 'check'))}),
 (New-Object PSObject -Property @{Title='Comptes inactifs';Command='Get-ADTInactiveAccount';Write=$false;Fields=@(
    (New-FieldSpec 'DaysInactive' 'Seuil en jours' 'number'),(New-FieldSpec 'SearchBase' 'Limiter a une OU (DN)' 'ou'),(New-FieldSpec 'IncludeDisabled' 'Inclure les comptes desactives' 'check'),(New-FieldSpec 'ExcludeNeverLoggedOn' 'Exclure les comptes jamais connectes' 'check'))}),
 (New-Object PSObject -Property @{Title='Privileges';Command='Get-ADTPrivilegedGroupMember';Write=$false;Fields=@((New-FieldSpec 'IncludeBuiltin' 'Inclure les groupes integres' 'check'))}),
 (New-Object PSObject -Property @{Title='Rapport HTML';Command='Export-ADTAccessReport';Write=$false;Fields=@(
    (New-FieldSpec 'Path' 'Fichier HTML *' 'savehtml'),(New-FieldSpec 'DaysInactive' 'Seuil en jours' 'number'),(New-FieldSpec 'SearchBase' 'Limiter les comptes a une OU (DN)' 'ou'),(New-FieldSpec 'CsvFolder' 'Dossier CSV complementaire (facultatif)' 'folder'))})
)
foreach ($spec in $specs) {
    $page=New-Object Windows.Forms.TabPage; $page.Text=$spec.Title; $page.BackColor=$form.BackColor; $page.AutoScroll=$true; $tabs.TabPages.Add($page)
    $fields=@{}; $i=0
    foreach ($field in $spec.Fields) {
        $x=15+([int]($i%2)*515); $y=12+([int][Math]::Floor($i/2)*38)
        $key=[string]$field.Key; $label=[string]$field.Label; $kind=[string]$field.Kind
        if ($kind -eq 'check') { $control=New-UiControl 'CheckBox' $page $label $x ($y+13) 480 23 }
        else {
            $null=New-UiControl 'Label' $page $label $x $y 480 16
            if ($kind -eq 'number') { $control=New-UiControl 'NumericUpDown' $page '' $x ($y+16) 465 22; $control.Minimum=1; $control.Maximum=3650; $control.Value=90 }
            elseif ($kind -eq 'delimiter') { $control=New-UiControl 'ComboBox' $page '' $x ($y+16) 465 22; $control.DropDownStyle='DropDownList'; [void]$control.Items.Add(';'); [void]$control.Items.Add(','); $control.SelectedIndex=0 }
            else {
                $width=465; if (@('open','savecsv','savehtml','folder','ou') -contains $kind) { $width=425 }
                $control=New-UiControl 'TextBox' $page '' $x ($y+16) $width 22
                if ($key -eq 'Reason') { $control.Text='Depart de l employe' }
                if ($width -eq 425) {
                    $browse=New-UiControl 'Button' $page '...' ($x+430) ($y+14) 35 25
                    $browse.Tag=@{Control=$control;Kind=$kind;Command=[string]$spec.Command;Fields=$fields}
                    $browse.Add_Click({
                        $tag=$this.Tag; $dialog=$null
                        try {
                            if ($tag.Kind -eq 'ou') { $selected=Show-OUSelectionDialog -CurrentDN $tag.Control.Text; if ($selected) { $tag.Control.Text=$selected }; return }
                            if ($tag.Kind -eq 'folder') { $dialog=New-Object Windows.Forms.FolderBrowserDialog }
                            elseif ($tag.Kind -eq 'open') { $dialog=New-Object Windows.Forms.OpenFileDialog; $dialog.Filter='CSV (*.csv)|*.csv|Tous les fichiers|*.*' }
                            else { $dialog=New-Object Windows.Forms.SaveFileDialog; $dialog.Filter='CSV (*.csv)|*.csv'; if ($tag.Kind -eq 'savehtml') { $dialog.Filter='HTML (*.html)|*.html' } }
                            if ($dialog.ShowDialog() -eq 'OK') {
                                if ($tag.Kind -eq 'folder') { $tag.Control.Text=$dialog.SelectedPath }
                                else {
                                    $tag.Control.Text=$dialog.FileName
                                    if ($tag.Kind -eq 'open' -and $tag.Command -eq 'Import-ADTUserFromCsv') {
                                        $selectedOU=Show-OUSelectionDialog -CurrentDN ''
                                        if (-not $selectedOU) { $tag.Control.Clear(); return }
                                        if ($tag.Fields.ContainsKey('DefaultOU')) { $tag.Fields['DefaultOU'].Control.Text=$selectedOU }
                                    }
                                }
                            }
                        } catch { Show-UiError $_.Exception.Message } finally { if ($dialog) { $dialog.Dispose() } }
                    })
                }
            }
        }
        $fields[$key]=@{Control=$control;Kind=$kind;Required=[bool]$field.Required}; $i++
    }
    $simulate=New-UiControl 'CheckBox' $page 'Simulation : verifier sans modifier Active Directory' 15 255 600 24
    $simulate.Checked=$true; $simulate.Visible=[bool]$spec.Write
    if (-not $spec.Write) { $null=New-UiControl 'Label' $page 'Lecture du domaine. Le rapport HTML et les exports creent des fichiers locaux.' 15 258 740 23 }
    $run=New-UiControl 'Button' $page 'Executer' 850 252 170 30
    if ($spec.Command -eq 'Import-ADTUserFromCsv') { $run.Text='Apercu / Importer' }
    $run.Tag=@{Spec=$spec;Fields=$fields;Simulation=$simulate}
    $run.Add_Click({
        try {
            $tag=$this.Tag; $p=Get-UiConnection
            foreach ($key in $tag.Fields.Keys) {
                $f=$tag.Fields[$key]; $c=$f.Control
                if ($f.Kind -eq 'check') { if ($c.Checked) { $p[$key]=$true }; continue }
                $value=$c.Text.Trim()
                if ($f.Required -and -not $value) { throw ('Champ obligatoire : '+$key) }
                if (-not $value) { continue }
                if ($f.Kind -eq 'list') { $p[$key]=[string[]]@($value -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
                elseif ($f.Kind -eq 'number') { $p[$key]=[int]$c.Value }
                elseif ($f.Kind -eq 'delimiter') { $p[$key]=[char]$value }
                else { $p[$key]=$value }
            }
            if ($tag.Spec.Command -eq 'Import-ADTUserFromCsv') {
                if (-not (Show-ImportPreviewDialog -Parameters $p)) { return }
            }
            if ($tag.Spec.Write) {
                $p['WhatIf']=$tag.Simulation.Checked; $p['Confirm']=$false
                if (-not $tag.Simulation.Checked) {
                    $target='Domaine de la session'; if ($p['Server']) { $target=$p['Server'] }
                    $summary='Operation : '+$tag.Spec.Title+"`r`nServeur : "+$target+"`r`n"
                    foreach ($key in @('Identity','GivenName','Surname','Path','DefaultOU','Groups','DefaultGroups','AddGroup','RemoveGroup','DisabledOU','BackupPath')) { if ($p[$key]) { $summary += $key+' : '+($p[$key] -join '; ')+"`r`n" } }
                    if ($p['CreateDepartmentOUs']) { $summary += "Sous-OU par departement : OUI`r`n" }
                    $summary += "`r`nAppliquer ces modifications a Active Directory ?"
                    if ([Windows.Forms.MessageBox]::Show($summary,'Confirmer les modifications','YesNo','Warning','Button2') -ne 'Yes') { return }
                }
            }
            Start-UiOperation $tag.Spec.Command $p
        } catch { Show-UiError $_.Exception.Message }
    })
}
$null=New-UiControl 'Label' $form 'Résultats' 18 525 180 22
$showPasswords=New-UiControl 'CheckBox' $form 'Afficher / exporter les mots de passe générés' 205 522 510 25
$showPasswords.Add_CheckedChanged({ Update-UiGrid })
$exportButton=New-UiControl 'Button' $form 'Exporter les résultats CSV' 855 519 220 30
$exportButton.Anchor='Top,Right'; $exportButton.Enabled=$false
$grid=New-UiControl 'DataGridView' $form '' 15 555 1060 140
$grid.Anchor='Top,Bottom,Left,Right'; $grid.ReadOnly=$true; $grid.AllowUserToAddRows=$false; $grid.AllowUserToDeleteRows=$false
$grid.AutoSizeColumnsMode='DisplayedCells'; $grid.BackgroundColor=[Drawing.Color]::White; $grid.RowHeadersVisible=$false
$details=New-UiControl 'TextBox' $form '' 15 704 1060 60
$details.Anchor='Bottom,Left,Right'; $details.Multiline=$true; $details.ReadOnly=$true; $details.ScrollBars='Vertical'
$statusLabel=New-UiControl 'Label' $form 'Prêt. Commencer par tester la connexion.' 15 775 810 23
$statusLabel.Anchor='Bottom,Left,Right'
$progress=New-UiControl 'ProgressBar' $form '' 865 774 210 20
$progress.Anchor='Bottom,Right'
$timer=New-Object Windows.Forms.Timer; $timer.Interval=250
$timer.Add_Tick({
    if (-not $script:Handle -or -not $script:Handle.IsCompleted) { return }
    $timer.Stop()
    try {
        $script:Rows=@($script:Worker.EndInvoke($script:Handle))
        $messages=@()
        foreach ($w in $script:Worker.Streams.Warning) { $messages += 'AVERTISSEMENT : '+$w.Message }
        foreach ($e in $script:Worker.Streams.Error) { $messages += 'ERREUR : '+$e.ToString() }
        $details.Text=$messages -join "`r`n"
        Update-UiGrid
        $failures=@($script:Rows | Where-Object { $_.Status -eq 'Echec' -or $_.Status -eq 'Partiel' -or ($_.PSObject.Properties['Ready'] -and -not $_.Ready) }).Count
        $statusLabel.Text=('{0} resultat(s). Verifier les colonnes Status, Error et Messages.' -f $script:Rows.Count)
        if ($failures -or $script:Worker.Streams.Error.Count) { $statusLabel.Text='Termine avec erreurs : consulter les résultats et les messages.' }
        if ($script:Operation -eq 'Test-ADTPrerequisite' -and $script:Rows.Count -gt 0 -and $script:Rows[0].Ready) {
            $serverBox.Text=$script:Rows[0].Server
            $statusLabel.Text='Connecte a '+$script:Rows[0].DomainName+' via '+$script:Rows[0].Server
        }
    } catch { $details.Text=$_.Exception.Message; $statusLabel.Text='Operation interrompue : consulter le detail.' }
    finally {
        if ($script:Worker) { $script:Worker.Dispose() }; if ($script:Runspace) { $script:Runspace.Dispose() }
        $script:Worker=$null; $script:Runspace=$null; $script:Handle=$null
        $connection.Enabled=$true; $tabs.Enabled=$true; $progress.Style='Blocks'
    }
})
$exportButton.Add_Click({
    $dialog=New-Object Windows.Forms.SaveFileDialog; $dialog.Filter='CSV (*.csv)|*.csv'
    try {
        if ($dialog.ShowDialog() -eq 'OK') {
            $data=$script:Rows
            if (-not $showPasswords.Checked) { $data=@($data | Select-Object * -ExcludeProperty Password) }
            $data | Export-Csv -Path $dialog.FileName -Delimiter ';' -Encoding UTF8 -NoTypeInformation -ErrorAction Stop
            $statusLabel.Text='Export enregistre : '+$dialog.FileName
        }
    } catch { Show-UiError $_.Exception.Message } finally { $dialog.Dispose() }
})
$form.Add_FormClosing({
    param($sender,$eventArgs)
    if ($script:Worker) { $eventArgs.Cancel=$true; [void][Windows.Forms.MessageBox]::Show('Une operation est en cours. Attendre son resultat avant de fermer.','PSADToolkit') }
})
try { [void]$form.ShowDialog() }
finally { $timer.Dispose(); $passwordBox.Clear(); $script:Rows=@(); $form.Dispose() }
