@{
    # Only error on real bugs; skip style rules that would spam lab scripts
    IncludeRules = @(
        'PSAvoidUsingPlainTextForPassword',
        'PSAvoidUsingConvertToSecureStringWithPlainText',
        'PSAvoidUsingInvokeExpression',
        'PSMisleadingBacktick',
        'PSMissingModuleManifestField',
        'PSPossibleIncorrectComparisonWithNull',
        'PSPossibleIncorrectUsageOfAssignmentOperator',
        'PSPossibleIncorrectUsageOfRedirectionOperator',
        'PSUseCompatibleSyntax',
        'PSUseDeclaredVarsMoreThanAssignments',
        'PSUseSingularNouns'
    )

    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable        = $true
            TargetedVersions = @('7.0', '7.2')
        }
    }
}
