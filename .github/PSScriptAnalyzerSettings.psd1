@{
    # Only error on real bugs; skip style rules that would spam lab scripts
    IncludeRules = @(
        # PSAvoidUsingPlainTextForPassword excluded: lab scripts legitimately accept
        # plain-text passwords from sops-decrypted secrets and pass them to PowerCLI APIs.
        # PSAvoidUsingConvertToSecureStringWithPlainText excluded: same reason —
        # ConvertTo-SecureString -AsPlainText -Force is the standard PowerCLI pattern.
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
