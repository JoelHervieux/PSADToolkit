# Exercise the actual GUI field definitions without requiring Windows Forms.
BeforeAll {
    $root=Split-Path $PSScriptRoot -Parent
    $tokens=$null; $errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Start-PSADToolkit.ps1'),[ref]$tokens,[ref]$errors)
    $assignment=@($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$specs'
    },$true))
    if ($assignment.Count -ne 1) { throw 'Expected one GUI schema assignment.' }
    # Evaluate only the local, constant schema expression from the GUI source.
    $specs=@(& ([scriptblock]::Create($assignment[0].Right.Extent.Text)))
}
Describe 'GUI field definitions' {
    It 'Preserves every field as a three-string descriptor, including single-field tabs' {
        foreach ($spec in $specs) {
            foreach ($field in $spec.Fields) {
                ($field -is [System.Array]) | Should -BeTrue -Because $spec.Title
                $field.Count | Should -Be 3
                foreach ($value in $field) { ($value -is [string]) | Should -BeTrue }
            }
        }
    }
    It 'Constructs the required-field flags using EndsWith on all seven tabs' {
        $specs.Count | Should -Be 7
        $count=0
        foreach ($spec in $specs) {
            foreach ($field in $spec.Fields) {
                $label=$field[1]
                $required=$label.EndsWith('*')
                ($required -is [bool]) | Should -BeTrue
                $count++
            }
        }
        $count | Should -Be 35
    }
    It 'Keeps IncludeBuiltin as the sole checkbox on the privileges tab' {
        $tab=@($specs | Where-Object { $_.Command -eq 'Get-ADTPrivilegedGroupMember' })[0]
        @($tab.Fields).Count | Should -Be 1
        $tab.Fields[0][0] | Should -Be 'IncludeBuiltin'
        $tab.Fields[0][2] | Should -Be 'check'
    }
}
