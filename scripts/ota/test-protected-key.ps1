# SPDX-License-Identifier: Apache-2.0
#Requires -Version 7.2
# Synthetic RSA/DPAPI only: no real signing material and no plaintext key files.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'aot-inputs.ps1')
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'build-ui-patch.ps1'),[ref]$tokens,[ref]$errors)
if($errors){throw 'protected_key_builder_parse_failed'}
foreach($name in @('Import-OtaProtectedKeyBytes','Import-OtaSigningKey')){
    $function=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
    if($function.Count -ne 1){throw 'protected_key_importer_missing'}
    . ([scriptblock]::Create($function[0].Extent.Text))
}
$script:checks=0
function Check([bool]$Value,[string]$Name){if(!$Value){throw ('protected_key_fixture_failed_'+$Name)};$script:checks++}
function Reject([scriptblock]$Action,[string]$Code){try{& $Action|Out-Null}catch{Check ($_.Exception.Message -ceq $Code) $Code;return};throw ('protected_key_fixture_did_not_reject_'+$Code)}
$fixture=Join-Path $root ('artifacts/qa/ota-protected-key-'+[guid]::NewGuid().ToString('N'))
$private=Join-Path $fixture '.private';New-Item -ItemType Directory -Path $private -Force|Out-Null
$key=[Security.Cryptography.RSA]::Create(4096);$other=[Security.Cryptography.RSA]::Create(2048);$imported=$null
$raw=$null;$buffer=$null
try {
    $raw=$key.ExportPkcs8PrivateKey()
    $buffer=[byte[]]$raw.Clone()
    $imported=Import-OtaProtectedKeyBytes $buffer $key
    Check (@($buffer|Where-Object {$_ -ne 0}).Count -eq 0) 'decrypted_buffer_cleared_after_success'
    $hash=Get-ExvpnOtaTextSha256 'synthetic patch'
    $signature=New-ExvpnOtaHashSignature $hash $imported
    Check ($key.VerifyData([Text.Encoding]::UTF8.GetBytes($hash),[Convert]::FromBase64String($signature),[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)) 'memory_import_can_sign_expected_public_key'
    $imported.Dispose();$imported=$null
    $buffer=[byte[]](@($raw)+@(0))
    Reject {Import-OtaProtectedKeyBytes $buffer $key} 'ota_private_key_trailing_data'
    Check (@($buffer|Where-Object {$_ -ne 0}).Count -eq 0) 'decrypted_buffer_cleared_after_trailing_data'
    $buffer=[byte[]]$raw.Clone()
    Reject {Import-OtaProtectedKeyBytes $buffer $other} 'ota_signing_key_mismatch'
    Check (@($buffer|Where-Object {$_ -ne 0}).Count -eq 0) 'decrypted_buffer_cleared_after_wrong_public_key'
    $buffer=[byte[]](1,2,3)
    Reject {Import-OtaProtectedKeyBytes $buffer $key} 'ota_private_key_format_invalid'
    Check (@($buffer|Where-Object {$_ -ne 0}).Count -eq 0) 'decrypted_buffer_cleared_after_parse_failure'
    $path=Join-Path $private 'synthetic.dpapi'
    [IO.File]::WriteAllBytes($path,[Security.Cryptography.ProtectedData]::Protect($raw,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser))
    $imported=Import-OtaSigningKey $fixture '' $path $key
    Check ($imported.KeySize -eq 4096) 'local_dpapi_import_without_plaintext_file'
    $imported.Dispose();$imported=$null
    Check (@(Get-ChildItem -LiteralPath $private -File).Count -eq 1 -and !(Test-Path -LiteralPath (Join-Path $private 'synthetic.pem'))) 'no_plaintext_key_created'
    Reject {Import-OtaSigningKey $fixture 'a.pem' $path $key} 'ota_private_key_input_ambiguous'
    Reject {Import-OtaSigningKey $fixture '' '' $key} 'ota_private_key_input_ambiguous'
    Reject {Import-OtaSigningKey $fixture '' (Join-Path $fixture 'outside.dpapi') $key} 'ota_private_key_location_invalid'
    $oversized=Join-Path $private 'oversized.dpapi';[IO.File]::WriteAllBytes($oversized,[byte[]]::new(65537))
    Reject {Import-OtaSigningKey $fixture '' $oversized $key} 'ota_private_key_file_invalid'
    $empty=Join-Path $private 'empty.dpapi';[IO.File]::WriteAllBytes($empty,[byte[]]::new(0))
    Reject {Import-OtaSigningKey $fixture '' $empty $key} 'ota_private_key_file_invalid'
    $bad=Join-Path $private 'bad.dpapi';[IO.File]::WriteAllBytes($bad,[byte[]](1,2,3))
    Reject {Import-OtaSigningKey $fixture '' $bad $key} 'ota_protected_key_decrypt_failed'
    $linkTarget=Join-Path $private 'link-target';New-Item -ItemType Directory -Path $linkTarget|Out-Null
    Copy-Item -LiteralPath $path -Destination (Join-Path $linkTarget 'synthetic.dpapi')
    $junction=Join-Path $private 'linked-parent'
    $null=New-Item -ItemType Junction -Path $junction -Target $linkTarget
    Reject {Import-OtaSigningKey $fixture '' (Join-Path $junction 'synthetic.dpapi') $key} 'ota_path_link_rejected'
    $parameters=@($ast.ParamBlock.Parameters|ForEach-Object {$_.Extent.Text})
    Check (@($parameters|Where-Object {$_ -match "ParameterSetName='Protected'" -and $_ -match '\$ProtectedPrivateKeyPath'}).Count -eq 1 -and @($parameters|Where-Object {$_ -match "ParameterSetName='Pem'" -and $_ -match '\$PrivateKeyPath'}).Count -eq 1) 'cli_key_inputs_are_mutually_exclusive'
    $keyFunctions=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -cin @('Import-OtaProtectedKeyBytes','Import-OtaSigningKey')},$true)|ForEach-Object {$_.Extent.Text})-join "`n"
    Check ($keyFunctions -notmatch 'ExportPkcs|Export.*Private|WriteAll|Set-Content|Write-Output|Write-Host') 'signing_import_never_exports_writes_or_logs_private_key'
} finally {
    if($imported){$imported.Dispose()};$key.Dispose();$other.Dispose()
    if($raw){[Security.Cryptography.CryptographicOperations]::ZeroMemory($raw)}
    if($buffer){[Security.Cryptography.CryptographicOperations]::ZeroMemory($buffer)}
}
[ordered]@{checks=$script:checks;passed=$true;scope='synthetic in-memory PKCS8/DPAPI import and zeroization; no real signing keys, AOT build or plaintext key files'}|ConvertTo-Json -Compress
