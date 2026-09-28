# Sonde temporaire : que permet la machine Windows de GitHub ?
$ErrorActionPreference = 'Continue'
function Check { param([string]$Name, [scriptblock]$Body)
    try { $r = & $Body; Write-Host ("[OK]   {0} : {1}" -f $Name, ($r | Out-String).Trim()) }
    catch { Write-Host ("[FAIL] {0} : {1}" -f $Name, $_.Exception.Message) }
}
Check 'PowerShell' { $PSVersionTable.PSVersion.ToString() }
Check 'OS' { [Environment]::OSVersion.VersionString }
Check 'Session interactive' { [Environment]::UserInteractive }
Check 'ISCC' { $p = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'; if (Test-Path $p) { $p } else { (Get-Command iscc -ErrorAction Stop).Source } }
Check 'csc' { $p = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'; if (Test-Path $p) { $p } else { throw 'absent' } }
Check 'Windows PowerShell 5.1' { (powershell.exe -NoProfile -Command '$PSVersionTable.PSVersion.ToString()') }
Check 'Pester sous WinPS' { (powershell.exe -NoProfile -Command '(Get-Module -ListAvailable Pester | Sort Version -Desc | Select -First 1).Version.ToString()') }
Check 'Install GliderUI 0.4.1' { Install-PSResource -Name GliderUI -Version 0.4.1 -TrustRepository -Scope CurrentUser -ErrorAction Stop; 'installe' }
Check 'Install-GLIServer' { Import-Module GliderUI -RequiredVersion 0.4.1 -ErrorAction Stop; Install-GLIServer -TrustRepository -ErrorAction Stop; 'installe' }
Check 'Modules' { Get-Module -ListAvailable GliderUI, GliderUI.Server.* | ForEach-Object { '{0} {1} {2}' -f $_.Name, $_.Version, $_.ModuleBase } }
Check 'Nom complet' { [bool]('GliderUI.Avalonia.Markup.Xaml.AvaloniaRuntimeXamlLoader' -as [type]) }
Check 'Nom court via using (bloc)' { [bool]([scriptblock]::Create("using namespace GliderUI.Avalonia.Markup.Xaml`n[AvaloniaRuntimeXamlLoader]").Invoke()) }

$win = $null
Check 'Window::new' { $script:win = [GliderUI.Avalonia.Controls.Window]::new(); $script:win.Title = 'Sonde'; $script:win.Width = 400; $script:win.Height = 300; 'cree' }
Check 'XAML DataGrid Extended' {
    $g = [GliderUI.Avalonia.Markup.Xaml.AvaloniaRuntimeXamlLoader]::Parse('<DataGrid xmlns="https://github.com/avaloniaui" SelectionMode="Extended" IsReadOnly="True"><DataGrid.Columns><DataGridTextColumn Header="A" Binding="{Binding A}"/></DataGrid.Columns></DataGrid>', $null)
    $items = [GliderUI.System.Collections.ObjectModel.ObservableCollection[GliderUI.DataSource]]::new()
    $items.Add([GliderUI.DataSource]@{ A = 'x' }); $items.Add([GliderUI.DataSource]@{ A = 'y' })
    $g.ItemsSource = $items
    $g.SelectedIndex = 1
    'SelectedIndex=' + $g.SelectedIndex + ' SelectedItems=' + ($null -ne $g.SelectedItems) + ' A=' + $g.SelectedItem.A
}
Check 'XAML Expander' { $e = [GliderUI.Avalonia.Markup.Xaml.AvaloniaRuntimeXamlLoader]::Parse('<Expander xmlns="https://github.com/avaloniaui" Header="Journal"><TextBlock Text="x"/></Expander>', $null); $e.IsExpanded = $true; 'IsExpanded=' + $e.IsExpanded }
Check 'TreeView' {
    $t = [GliderUI.Avalonia.Controls.TreeView]::new(); $n = [GliderUI.Avalonia.Controls.TreeViewItem]::new(); $n.Header = 'racine'; $n.Tag = 'DC=x'
    $c = [GliderUI.Avalonia.Controls.TreeViewItem]::new(); $c.Header = 'enfant'; $n.Items.Add($c) | Out-Null; $t.Items.Add($n) | Out-Null
    $n.IsExpanded = $true; $t.SelectedItem = $c; $n.Items.Clear(); 'SelectedItem OK, Items.Clear OK'
}
Check 'ContextMenu' { $m = [GliderUI.Avalonia.Controls.ContextMenu]::new(); $i = [GliderUI.Avalonia.Controls.MenuItem]::new(); $i.Header = 'x'; $i.AddClick({ }); $m.Items.Add($i) | Out-Null; $m.Items.Add([GliderUI.Avalonia.Controls.Separator]::new()) | Out-Null; $b = [GliderUI.Avalonia.Controls.Button]::new(); $b.ContextMenu = $m; 'attache' }
Check 'AddDoubleTapped' { $b = [GliderUI.Avalonia.Controls.Button]::new(); $b.AddDoubleTapped({ }); 'present' }
Check 'AddIsCheckedChanged' { $c = [GliderUI.Avalonia.Controls.CheckBox]::new(); $c.AddIsCheckedChanged({ }); 'present' }
Check 'ToolTip' { $c = [GliderUI.Avalonia.Controls.CheckBox]::new(); $c.ToolTip = 'x'; 'accepte' }
Check 'Watermark' { $t = [GliderUI.Avalonia.Controls.TextBox]::new(); $t.Watermark = 'x'; 'accepte' }
Check 'PasswordChar' { $t = [GliderUI.Avalonia.Controls.TextBox]::new(); $t.PasswordChar = '*'; 'accepte' }
Check 'Show + Close' {
    $script:win.Content = [GliderUI.Avalonia.Controls.TextBlock]::new()
    $script:win.Show()
    Start-Sleep -Seconds 2
    $script:win.Close()
    $script:win.WaitForClosed()
    'fenetre affichee puis fermee'
}
Check 'Show + Close + WaitForClosed (seconde fenetre)' {
    $w2 = [GliderUI.Avalonia.Controls.Window]::new(); $w2.Show(); $w2.Close(); $w2.WaitForClosed(); 'OK'
}
Write-Host 'FIN DE SONDE'
