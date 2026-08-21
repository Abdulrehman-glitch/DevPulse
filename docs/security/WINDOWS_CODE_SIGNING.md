# Windows code-signing strategy

## v0.3.0 decision

DevPulse `v0.3.0` remains transparently unsigned because no maintainer-approved production certificate, managed signing account, budget, or publisher identity has been activated. No private signing key, certificate archive, signing password, or production signing secret is stored in the repository or GitHub Actions. An unsigned artifact can still run on Windows, but it provides no Authenticode publisher identity and may trigger Microsoft Defender SmartScreen warnings.

This is a deliberate pre-1.0 limitation, not simulated production assurance. Tauri's current [Windows code-signing guide](https://v2.tauri.app/distribute/sign/windows/) supports certificate-store signing, custom signing commands, key-vault-backed keys, and Azure Artifact Signing. Microsoft documents SignTool verification, trust, revocation, and timestamp checks in the [SignTool reference](https://learn.microsoft.com/en-us/windows/win32/seccrypto/signtool).

## Sustainable activation options

1. **Preferred if a budget and verified identity are approved: Azure Artifact Signing public trust.** The signing key remains in Microsoft's managed service rather than being exported to a runner. The maintainer must complete supported-country identity validation, create the account/profile, and grant a dedicated release identity only the signing role. GitHub federation/OIDC is preferred over a long-lived client secret. Microsoft's current [Artifact Signing quickstart](https://learn.microsoft.com/en-us/azure/artifact-signing/quickstart) documents identity validation and service setup.
2. **CA-issued OV/EV certificate held in an approved hardware token or HSM.** This can support a manual signing boundary or a vendor-supported remote interface. Post-June-2023 CA key-storage requirements rule out treating a repository PFX secret as the default design. Vendor identity, renewal, token/HSM, and timestamp-service terms must be reviewed before selection.
3. **Azure Key Vault/custom Tauri signing command.** This is viable only when the certificate issuer and key design provide appropriate public-trust code-signing assurance. It adds cloud IAM and tool-maintenance responsibility and is not automatically equivalent to a public-trust managed signing service.

Current Microsoft pricing lists Artifact Signing Basic at USD 9.99 per account/month for 5,000 signatures and Premium at USD 99.99 for 100,000, with USD 0.005 per signature beyond quota; see [the Microsoft SKU table](https://learn.microsoft.com/en-us/azure/artifact-signing/how-to-change-sku). CA, token, HSM, tax, currency, and renewal pricing are vendor-specific. Pricing and eligibility must be rechecked at activation. This sprint authorises none of these costs.

## Approved future signing boundary

- The release source is an exact reviewed commit with locked inputs and green ordinary CI.
- A protected release environment receives only the least privilege needed to request signatures. A managed service should use short-lived federated identity; a hardware-token flow remains manual and attended.
- The private key is non-exportable and never enters source, a workflow artifact, an environment dump, argv, logs, reports, or a general repository secret.
- Sign the application executable, sidecar where the selected policy requires it, uninstaller/installer payloads as supported by Tauri/NSIS, and final installer. Use SHA-256.
- Always request an RFC 3161 SHA-256 timestamp from the certificate provider's approved service. Microsoft explains that timestamps preserve verifiability after certificate expiry in [Time Stamping Authenticode Signatures](https://learn.microsoft.com/en-us/windows/win32/seccrypto/time-stamping-authenticode-signatures).
- Verification, installed lifecycle QA, hashes, SBOM, manifest, and provenance attestations must refer to the exact final signed bytes. A post-QA signing mutation invalidates the candidate and requires requalification.
- Production signing failure, an unexpected publisher, missing timestamp, invalid chain, revocation failure, or hash mismatch is a no-publish result. Never fall back silently to unsigned once a release is declared signed.

## Verification machinery

`scripts/verify-authenticode.ps1` uses Windows `Get-AuthenticodeSignature` and emits a bounded JSON result. It distinguishes unsigned, valid, hash-mismatched/tampered, untrusted, expired-without-a-valid-timestamp where Windows exposes that state, unsupported, and unknown-error outcomes. It reports certificate and timestamp time state without printing a certificate thumbprint, subject, full local path, or signing material.

```powershell
.\scripts\verify-authenticode.ps1 -Path .\DevPulse_0.3.0_x64-setup.exe -ExpectedState unsigned
signtool verify /pa /all /tw .\DevPulse_0.3.0_x64-setup.exe
```

`scripts/test-authenticode-verification.ps1` runs only inside a disposable GitHub-hosted Windows runner. It creates a one-day, self-signed, non-exportable **TEST** key in the runner's current-user certificate store, temporarily adds only its public certificate to the scoped CurrentUser `TrustedPeople` and `TrustedPublisher` stores (never the protected Root store), verifies positive/unsigned/tampered/untrusted cases, removes the certificate entries, and discards its temporary directory. No certificate or key is uploaded. The result validates machinery only and is never production code-signing assurance.

## Rotation, revocation, and incident response

- Inventory certificate/profile identifier, publisher identity, expiry, access assignments, timestamp endpoint, and responsible maintainer in private operational records; do not record secrets.
- Begin renewal and verification rehearsal before expiry. Overlap old/new verification only long enough to validate the new identity, then remove old signing permission.
- Rotate federated credentials and release-role assignments on maintainer or CI-boundary changes. Review managed-service audit logs for every release signature.
- If compromise or unauthorised signing is suspected, stop publication, disable the signing identity/profile, revoke the certificate through the provider, preserve provider and GitHub audit evidence, remove compromised access, notify users with affected hashes/versions, and issue a newly identified release only after root-cause review.
- Never delete or replace already-published assets to conceal an incident. Record revocation and superseding-release guidance in the security advisory/release notes.
