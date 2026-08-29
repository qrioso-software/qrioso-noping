Set-StrictMode -Version Latest

function Test-QriosoCodeSigningCertificate {
    param(
        [Parameter(Mandatory = $true)]
        $Certificate
    )

    foreach ($extension in @($Certificate.Extensions)) {
        if ($null -eq $extension.Oid -or $extension.Oid.Value -ne "2.5.29.37") {
            continue
        }

        $enhancedKeyUsageExtension = if ($extension -is [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]) {
            $extension
        }
        else {
            [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new(
                $extension,
                $extension.Critical
            )
        }

        foreach ($usage in @($enhancedKeyUsageExtension.EnhancedKeyUsages)) {
            if ($usage.Value -eq "1.3.6.1.5.5.7.3.3") {
                return $true
            }
        }
    }

    return $false
}
