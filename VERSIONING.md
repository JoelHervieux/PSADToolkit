# Nomenclature de version

Ce document définit la numérotation de PSADToolkit, l'endroit où chaque version est inscrite et la procédure à suivre pour publier. Il fait autorité : en cas de divergence entre deux fichiers, c'est le manifeste `PSADToolkit.psd1` qui a raison, et `Tests\Test-VersionConsistency.ps1` le vérifie.

## Format

```
MAJEUR.MINEUR.CORRECTIF[-CANAL]
```

Exemples : `3.0.0-test2`, `3.1.0-rc1`, `3.1.0`.

| Élément | Quand il change |
|---|---|
| MAJEUR | Rupture de compatibilité : paramètre public retiré ou renommé, comportement d'écriture AD modifié, abandon d'un système ou d'une version de PowerShell ciblés. |
| MINEUR | Nouvelle fonction publique, nouvel onglet, nouvelle colonne CSV, nouveau paramètre facultatif. Les appels existants continuent de fonctionner. |
| CORRECTIF | Correction de bogue, documentation, tests, message d'erreur. Aucune nouvelle capacité. |
| CANAL | État de validation de la version. Voir ci-dessous. |

## Canaux

| Canal | Signification | Utilisation |
|---|---|---|
| `-testN` | La version n'a pas passé la recette Windows de `VALIDATION.md`. Syntaxe, tests Pester et annuaire simulé peuvent être verts ; l'exécution sur un domaine réel n'est pas prouvée. | Laboratoire uniquement. Simulation cochée. Aucune écriture en production. |
| `-rcN` | La recette Windows est commencée et concluante jusqu'ici, sur une partie seulement des systèmes cibles. | Pilote encadré, sur une OU de test. |
| *(aucun suffixe)* | Recette Windows de `VALIDATION.md` effectuée sur au moins Server 2008 SP2 / PowerShell 2.0 et un serveur récent / PowerShell 5.1. | Production. |

`N` est un entier qui repart à `1` à chaque nouveau numéro de version : `3.0.0-test1`, `3.0.0-test2`, puis `3.0.1-test1`.

Le suffixe ne contient **ni point ni espace** : `test1`, pas `test.1`. PowerShellGet n'accepte dans un suffixe de préversion que des caractères alphanumériques et le trait d'union.

**État actuel : `3.0.0-test2`.** Le passage à 3.0.0 applique la règle MAJEUR ci-dessus : l'interface abandonne Windows Forms pour GliderUI et exige PowerShell 7.4, alors que les versions 2.x s'exécutaient sous Windows PowerShell 2.0 à 5.1. Aucune version de ce dépôt n'a encore passé la recette Windows. Tant que le canal reste `test`, la compatibilité annoncée dans `README.md` est une cible technique, pas un résultat mesuré.

## Où la version est inscrite

| Emplacement | Contenu | Qui l'écrit |
|---|---|---|
| `PSADToolkit.psd1` → `ModuleVersion` | Numéro seul : `3.0.0`. **Source de vérité.** | À la main. |
| `PSADToolkit.psd1` → `PrivateData.PSData.Prerelease` | Canal seul : `test1`. Chaîne vide pour une version stable. | À la main. |
| `dist\PSADToolkit-Standalone.ps1` (en-tête) | Version complète : `3.0.0-test2`. | `Build.ps1`, jamais à la main. |
| `Start-PSADToolkit.ps1` (attribut `Title` du XAML) | Version complète. L'opérateur doit voir à l'écran qu'il utilise une version de test. | À la main. |
| `README.md` (titre de niveau 1 et encadré d'état) | Version complète. | À la main. |
| `CHANGELOG.md` | Une section `## <version complète> - AAAA-MM-JJ` par version, ordre décroissant. | À la main. |
| Étiquette git | `v<version complète>`, par exemple `v3.0.0-test2`. | `git tag`. |

`ModuleVersion` reste purement numérique parce que Windows PowerShell 2.0 refuse tout suffixe dans un manifeste. La version complète est reconstituée par concaténation, comme le fait `Build.ps1`.

`VALIDATION.md` n'est pas dans cette liste : il décrit une campagne de validation datée et garde le numéro qu'il a réellement validé.

## Procédure de publication

1. Mettre à jour `ModuleVersion` et `Prerelease` dans `PSADToolkit.psd1`.
2. Ajouter la section correspondante en tête de `CHANGELOG.md`, avec la date du jour.
3. Reporter la version complète dans `README.md` et dans le titre de `Start-PSADToolkit.ps1`.
4. Régénérer le standalone : `.\Build.ps1` sur un poste PowerShell 5.1 ou 7.
5. Vérifier :

   ```powershell
   .\Tests\Test-VersionConsistency.ps1
   Invoke-Pester -Path .\Tests -Output Detailed
   .\Tests\Test-Compatibility.ps1
   ```

6. Commiter, puis étiqueter : `git tag -a v3.0.0-test2 -m "PSADToolkit 3.0.0-test2"`.
7. Pousser la branche et l'étiquette : `git push -u origin <branche> --follow-tags`.

## Passage en version stable

Retirer le suffixe seulement après avoir exécuté la recette Windows de `VALIDATION.md` sur les deux extrémités de la cible : Server 2008 SP2 / PowerShell 2.0 et un serveur récent / PowerShell 5.1. La campagne est consignée dans `VALIDATION.md` avec sa date et son périmètre, puis la version passe de `X.Y.Z-rcN` à `X.Y.Z` sans autre changement de code. Une correction faite pendant la recette relance un canal : `X.Y.Z+1-test1`.
