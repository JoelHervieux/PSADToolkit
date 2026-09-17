# Developer validation: Windows PowerShell 5.1 or PowerShell 7.
# Detecte les variables de boucle foreach qui reutilisent le nom d un parametre type.
# Les noms de variables PowerShell sont insensibles a la casse et la contrainte de type
# du parametre vaut pour toute la fonction : la boucle echoue alors sur une conversion
# impossible. Voir CHANGELOG 3.0.0-test3.
[CmdletBinding()]
param([string]$Path)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
if ($Path) { $files=@(Get-Item -Path $Path) }
else { $files=@(Get-ChildItem $root -Recurse -Include *.ps1,*.psm1 | Where-Object { $_.FullName -notmatch '[\\/]dist[\\/]' }) }

$findings=@()
foreach ($file in $files) {
    $parseErrors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$null,[ref]$parseErrors)
    if ($parseErrors) { throw ($file.Name+' : '+($parseErrors.Message -join '; ')) }

    foreach ($function in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },$true)) {
        $parameters=@()
        if ($function.Parameters) { $parameters+=$function.Parameters }
        elseif ($function.Body -and $function.Body.ParamBlock) { $parameters+=$function.Body.ParamBlock.Parameters }

        $typed=@{}
        foreach ($parameter in $parameters) {
            $constraint=@($parameter.Attributes | Where-Object { $_ -is [System.Management.Automation.Language.TypeConstraintAst] })
            if ($constraint.Count) { $typed[$parameter.Name.VariablePath.UserPath]=[string]$constraint[0].TypeName }
        }
        if (-not $typed.Count) { continue }

        foreach ($loop in $function.Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.ForEachStatementAst] },$true)) {
            $name=$loop.Variable.VariablePath.UserPath
            if ($typed.ContainsKey($name)) {
                $findings+=('{0} ligne {1} : dans {2}, la boucle foreach utilise ${3}, qui est aussi le parametre [{4}]${3}.' -f `
                    $file.Name,$loop.Extent.StartLineNumber,$function.Name,$name,$typed[$name])
            }
        }
    }
}

if ($findings) { $findings | ForEach-Object { Write-Warning $_ }; throw ('Parametres types masques par une boucle : '+$findings.Count+' cas.') }
('PASS: {0} fichiers analyses, aucune boucle foreach ne masque un parametre type.' -f $files.Count)
