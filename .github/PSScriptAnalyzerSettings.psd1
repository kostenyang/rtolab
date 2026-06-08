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
        # PSUseCompatibleSyntax excluded: repo targets pwsh 7 only (CLAUDE.md).
        # No need to check PS 3/4/5/6 compatibility.
        'PSUseDeclaredVarsMoreThanAssignments',
        'PSUseSingularNouns'
    )
}
