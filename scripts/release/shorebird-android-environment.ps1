# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
# Dot-sourcing is inert. Call only for hosted Windows Android release/patch.
# On success APPDATA remains private until the caller's environment finally.
Set-StrictMode -Version Latest

function Assert-ShorebirdAndroidToolPath([string]$Path) {
    if (!$Path -or ![IO.Path]::IsPathFullyQualified($Path) -or
        $Path -notmatch '^[A-Za-z]:[\\/]' -or $Path -match '[\x00-\x1f]' -or
        $Path.Substring(2).Contains(':')) { throw 'shorebird_android_tool_path_invalid' }
    foreach ($part in ($Path.Substring(3) -split '[\\/]')) {
        if ($part -in @('.','..') -or $part -match '[. ]$') { throw 'shorebird_android_tool_path_invalid' }
    }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    $ancestor = $full
    while ($ancestor) {
        if ((Test-Path -LiteralPath $ancestor) -and
            ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'shorebird_android_tool_path_alias'
        }
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }
    $full
}

function Assert-ShorebirdAndroidLiteralToolPath([string]$Literal) {
    # GetFullPath can expand an existing 8.3 name on Windows. Validate the
    # physical path separately; return the exact Win32 spelling for the tools.
    if (!$Literal -or $Literal.Length -gt 2048 -or
        $Literal -cnotmatch '^[A-Za-z]:\\[A-Za-z0-9_.~\\-]+$') {
        throw 'shorebird_android_tool_literal_invalid'
    }
    foreach ($part in ($Literal.Substring(3) -split '\\')) {
        if (!$part -or $part -in @('.','..') -or $part.EndsWith('.')) {
            throw 'shorebird_android_tool_literal_invalid'
        }
    }
    $null=Assert-ShorebirdAndroidToolPath $Literal
    $Literal
}

function Initialize-ShorebirdAndroidPathInterop {
    if ('ExVpnShorebirdAndroidPath' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
public static class ExVpnShorebirdAndroidPath {
  [StructLayout(LayoutKind.Sequential)] public struct FileInfo {
    public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Created;
    public System.Runtime.InteropServices.ComTypes.FILETIME Accessed;
    public System.Runtime.InteropServices.ComTypes.FILETIME Written;
    public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
  }
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern uint GetShortPathNameW(string value, StringBuilder output, uint capacity);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security,
    uint creation, uint flags, IntPtr template);
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern bool GetFileInformationByHandle(SafeFileHandle file, out FileInfo information);
  public static string ShortPath(string path) {
    var output = new StringBuilder(32768);
    uint count = GetShortPathNameW(path, output, (uint)output.Capacity);
    if (count == 0 || count >= output.Capacity) throw new Win32Exception(Marshal.GetLastWin32Error());
    return output.ToString();
  }
  public sealed class Lease : IDisposable {
    public SafeFileHandle Handle { get; private set; }
    public string Identity { get; private set; }
    public bool Directory { get; private set; }
    public bool Reparse { get; private set; }
    public uint Links { get; private set; }
    internal Lease(string path, bool directory) {
      // Deny rename/delete while held. File leases also deny concurrent writes.
      Handle = CreateFileW(path, 0x80, directory ? 3u : 1u, IntPtr.Zero, 3,
        0x02000000u | 0x00200000u, IntPtr.Zero);
      if (Handle.IsInvalid) { Handle.Dispose(); throw new Win32Exception(Marshal.GetLastWin32Error()); }
      FileInfo info;
      if (!GetFileInformationByHandle(Handle, out info)) {
        int code=Marshal.GetLastWin32Error(); Handle.Dispose(); throw new Win32Exception(code);
      }
      Directory=(info.Attributes & 0x10)!=0; Reparse=(info.Attributes & 0x400)!=0; Links=info.Links;
      Identity=info.Volume.ToString("x8")+":"+info.IndexHigh.ToString("x8")+info.IndexLow.ToString("x8");
      if (Reparse || Directory!=directory || (!directory && Links!=1)) {
        Handle.Dispose(); throw new InvalidOperationException("invalid_file_identity");
      }
    }
    public void Dispose() { if (Handle != null) Handle.Dispose(); }
  }
  public static Lease Hold(string path, bool directory) { return new Lease(path, directory); }
}
'@ | Out-Null
}

function Assert-ShorebirdAndroidToolPair($Canonical, $Short, [bool]$Directory) {
    if (!$Canonical -or !$Short -or !$Canonical.Identity -or
        $Canonical.Identity -cne $Short.Identity -or $Canonical.Reparse -or $Short.Reparse -or
        $Canonical.Directory -ne $Directory -or $Short.Directory -ne $Directory -or
        (!$Directory -and ($Canonical.Links -ne 1 -or $Short.Links -ne 1))) {
        throw 'shorebird_android_tool_identity_mismatch'
    }
}

function Assert-ShorebirdAndroidToolSettings([string]$Raw, [string]$Sdk, [string]$Jdk) {
    if (!$Raw -or [Text.Encoding]::UTF8.GetByteCount($Raw) -gt 4096) { throw 'shorebird_android_tool_config_invalid' }
    try {
        $document = [Text.Json.JsonDocument]::Parse($Raw)
        try {
            if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'invalid' }
            $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            $values = @{}
            foreach ($property in $document.RootElement.EnumerateObject()) {
                if (!$names.Add($property.Name) -or $property.Value.ValueKind -ne [Text.Json.JsonValueKind]::String) { throw 'invalid' }
                $values[$property.Name] = $property.Value.GetString()
            }
            if ($names.Count -ne 2 -or !$names.Contains('android-sdk') -or !$names.Contains('jdk-dir') -or
                $values['android-sdk'] -cne $Sdk -or $values['jdk-dir'] -cne $Jdk) { throw 'invalid' }
        } finally { $document.Dispose() }
    } catch { throw 'shorebird_android_tool_config_invalid' }
}

function Assert-ShorebirdAndroidToolProbe($Probe) {
    if ($Probe -isnot [Collections.IDictionary] -or $Probe.Count -ne 4 -or
        @('schema','exitCode','expectedMetadataListed','classFilesFailure').Where({!$Probe.Contains($_)}).Count) {
        throw 'shorebird_android_tool_probe_failed'
    }
    if (($Probe.schema -isnot [int] -and $Probe.schema -isnot [long]) -or $Probe.schema -ne 1 -or
        ($Probe.exitCode -isnot [int] -and $Probe.exitCode -isnot [long]) -or
        $Probe.exitCode -ne 0 -or $Probe.expectedMetadataListed -isnot [bool] -or
        !$Probe.expectedMetadataListed -or $Probe.classFilesFailure -isnot [bool] -or $Probe.classFilesFailure) {
        throw 'shorebird_android_tool_probe_failed'
    }
}

function Get-ShorebirdAndroidToolFailureReason([string]$Message) {
    # Never publish an arbitrary exception, path, argument or tool output.
    $known=@('unsupported','repository','private','private_acl','private_not_fresh','java',
        'pin','revision','dart_version','flutter_config','dart_process','changed',
        'shorebird_android_tool_path_invalid','shorebird_android_tool_path_alias',
        'shorebird_android_tool_literal_invalid','shorebird_android_tool_identity_mismatch',
        'shorebird_android_tool_config_invalid','shorebird_android_tool_probe_failed',
        'shorebird_android_tool_deadline')
    if ($Message -cin $known) { return $Message }
    'unclassified'
}

function Assert-ShorebirdAndroidPrivateDirectory([string]$Directory,[string]$Repository) {
    $private=Assert-ShorebirdAndroidToolPath $Directory
    $parent=Join-Path $Repository '.private/shorebird-builds'
    if (!$private.StartsWith($parent+'\',[StringComparison]::OrdinalIgnoreCase) -or
        !(Test-Path -LiteralPath $private -PathType Container)) { throw 'private' }
    $acl=Get-Acl -LiteralPath $private
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if (!$acl.AreAccessRulesProtected -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $sid -or
        @($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]) | Where-Object {
            $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            $_.IdentityReference.Value -cnotin @($sid,'S-1-5-18')
        }).Count) { throw 'private_acl' }
    $private
}

function Write-ShorebirdAndroidToolFailureDiagnostic([string]$Repository,
    [string]$PrivateDirectory,[bool]$PrivateValid,$Failure,[string]$Phase,
    [string]$PathCheck,[Collections.IDictionary]$Inputs) {
    try {
        # Never write into a rejected caller directory. This independently
        # owned spool also captures errors before the caller's ACL is verified.
        $spool=New-ShorebirdPrivateDirectory $Repository 'android-tool-failure'
        $spool=Assert-ShorebirdAndroidPrivateDirectory $spool $Repository
        $stdout=[byte[]]::new(0);$stderr=[byte[]]::new(0)
        if ($PrivateValid) {
            foreach ($stream in @('stdout','stderr')) {
                $path=Join-Path $PrivateDirectory "analyzer.$stream.private.log"
                if (Test-Path -LiteralPath $path -PathType Leaf) {
                    $null=Assert-ShorebirdAndroidToolPath $path
                    $bytes=Read-ShorebirdPrivateTail $path $(if($stream -ceq 'stdout'){64KB}else{240KB})
                    if($stream -ceq 'stdout'){$stdout=$bytes}else{$stderr=$bytes}
                }
            }
        }
        $bounded=@{}
        foreach($name in $Inputs.Keys){$value=[string]$Inputs[$name];$bounded[$name]=$value.Substring(0,[Math]::Min(2048,$value.Length))}
        $detail=($Failure | Out-String);$detail=$detail.Substring(0,[Math]::Min(8192,$detail.Length))
        $context=[ordered]@{schemaVersion=1;phase=$Phase;pathCheck=$PathCheck;inputs=$bounded
            exceptionType=$Failure.Exception.GetType().FullName;exception=$detail}
        $tail=[Text.Encoding]::UTF8.GetBytes(("`nExVPN/android-tool-context/v1`n"+($context|ConvertTo-Json -Depth 5 -Compress)))
        $pair=Join-Path $spool 'analyzer-export.json'
        [IO.File]::WriteAllBytes($pair,$stdout)
        $combined=[byte[]]::new($stderr.Length+$tail.Length)
        [Array]::Copy($stderr,0,$combined,0,$stderr.Length);[Array]::Copy($tail,0,$combined,$stderr.Length,$tail.Length)
        [IO.File]::WriteAllBytes([IO.Path]::ChangeExtension($pair,'.log'),$combined)
        return [bool](Write-ShorebirdEncryptedDiagnostic $Repository $pair)
    } catch {
        # Never replace the real failure or fall back to plaintext artifacts.
        return $false
    }
}

function Invoke-ShorebirdAndroidPrivateProcess([string]$Executable, [string[]]$Arguments,
    [string]$Directory, [string]$Label) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$Executable; $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.WorkingDirectory=$Directory; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process=[Diagnostics.Process]::Start($start)
    try {
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(60000)) { throw 'shorebird_android_tool_deadline' }
        [IO.File]::WriteAllText((Join-Path $Directory "$Label.stdout.private.log"),$stdout.GetAwaiter().GetResult())
        [IO.File]::WriteAllText((Join-Path $Directory "$Label.stderr.private.log"),$stderr.GetAwaiter().GetResult())
        $process.ExitCode
    } finally {
        if (!$process.HasExited) { $process.Kill($true); $null=$process.WaitForExit(1000) }
        $process.Dispose()
    }
}

function Write-ShorebirdAndroidToolReceipt([string]$Repository, $Proof) {
    $directory=Assert-ShorebirdAndroidToolPath (Join-Path $Repository 'artifacts/shorebird-recovery')
    [void][IO.Directory]::CreateDirectory($directory)
    $null=Assert-ShorebirdAndroidToolPath $directory
    $path=Join-Path $directory ('android-tools-'+[guid]::NewGuid().ToString('N')+'.json')
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Proof | ConvertTo-Json -Depth 6)+"`n")
    $file=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $file.Write($bytes); $file.Flush($true) } finally { $file.Dispose() }
}

function Initialize-ShorebirdAndroidToolEnvironment {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][string]$FlutterSdkRoot,
        [Parameter(Mandatory)][string]$AndroidSdkPath, [Parameter(Mandatory)][string]$PrivateDirectory)
    $phase='paths'; $pathCheck='repository'; $privateValid=$false; $success=$false; $savedAppData=$env:APPDATA
    $moduleRepository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $repositoryRoot=$null;$private=$null
    $leases=[Collections.Generic.List[IDisposable]]::new()
    $proof=[ordered]@{schemaVersion=1;status='failed';phase=$phase;errorCode=$null
        pathCheck=$pathCheck;failureReason=$null;diagnosticEncrypted=$false
        shortPathAvailable=$false;shortPathContainsSpace=$null;sdkDirectoryIdentityMatched=$false
        literalSdkAliasPreserved=$false;literalAnalyzerAliasPreserved=$false
        analyzerFileIdentityMatched=$false;heldIdentitiesRechecked=$false;sourcePinsMatched=$false
        privateSettingsExact=$false;processAppDataOnlyChanged=$false;dartVersionMatched=$false
        dartSha256=$null;analyzerSha256=$null;settingsSha256=$null;syntheticExitCode=$null
        expectedMetadataListed=$false;analyzerStdoutBytes=$null;analyzerStderrBytes=$null
        analyzerStdoutSha256=$null;analyzerStderrSha256=$null
        applicationBuilds=0;nativeBuilds=0;rawLogsExported=$false}
    try {
        if (![OperatingSystem]::IsWindows()) { throw 'unsupported' }
        $repositoryRoot=Assert-ShorebirdAndroidToolPath $Repository
        if ($repositoryRoot -ine $moduleRepository) { throw 'repository' }
        $pathCheck='android_sdk_physical'
        $sdk=Assert-ShorebirdAndroidToolPath $AndroidSdkPath
        $pathCheck='flutter_sdk'
        $flutter=Assert-ShorebirdAndroidToolPath $FlutterSdkRoot
        $pathCheck='private_acl'
        $private=Assert-ShorebirdAndroidPrivateDirectory $PrivateDirectory $repositoryRoot
        $privateValid=$true
        $pathCheck='private_fresh'
        $toolHome=Join-Path $private 'tool-home'
        if (Test-Path -LiteralPath $toolHome) { throw 'private_not_fresh' }
        [void][IO.Directory]::CreateDirectory($toolHome)
        $jdkSetting=$env:JAVA_HOME
        $pathCheck='jdk'
        $jdk=Assert-ShorebirdAndroidToolPath $jdkSetting
        if (!(Test-Path -LiteralPath (Join-Path $jdk 'bin/java.exe') -PathType Leaf)) { throw 'java' }
        $phase='source_pins'
        $pin=Get-Content -LiteralPath (Join-Path $repositoryRoot 'scripts/bootstrap/shorebird.lock.json') -Raw | ConvertFrom-Json -AsHashtable
        $expectedFlutter=Join-Path $repositoryRoot '.tools/shorebird-1.6.129/bin/cache/flutter/5bef02a16146a0effc07da4acccaafe90a2739ce'
        if ($flutter -ine [IO.Path]::GetFullPath($expectedFlutter) -or $pin.cli.version -cne '1.6.129' -or
            $pin.flutter.revision -cne '5bef02a16146a0effc07da4acccaafe90a2739ce' -or
            $pin.flutter.engineRevision -cne '4b936a0c03e13389ddfb1ac48823f187964975c2' -or $pin.flutter.dartVersion -cne '3.13.5' -or
            [IO.File]::ReadAllText((Join-Path $flutter 'bin/internal/engine.version')).Trim() -cne $pin.flutter.engineRevision) { throw 'pin' }
        $dart=Assert-ShorebirdAndroidToolPath (Join-Path $flutter 'bin/cache/dart-sdk/bin/dart.exe')
        $proof.dartSha256=(Get-FileHash -LiteralPath $dart -Algorithm SHA256).Hash.ToLowerInvariant()
        $git=(Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        if ((Invoke-ShorebirdAndroidPrivateProcess $git @('-C',$flutter,'rev-parse','HEAD') $private 'flutter-revision') -ne 0 -or
            [IO.File]::ReadAllText((Join-Path $private 'flutter-revision.stdout.private.log')).Trim() -cne $pin.flutter.revision) { throw 'revision' }
        $proof.sourcePinsMatched=$true
        if ((Invoke-ShorebirdAndroidPrivateProcess $dart @('--version') $private 'dart-version') -ne 0 -or
            (([IO.File]::ReadAllText((Join-Path $private 'dart-version.stdout.private.log'))+
                [IO.File]::ReadAllText((Join-Path $private 'dart-version.stderr.private.log'))) -cnotmatch '^Dart SDK version: 3\.13\.5\s')) { throw 'dart_version' }
        $proof.dartVersionMatched=$true
        $phase='sdk_short_identity'
        Initialize-ShorebirdAndroidPathInterop
        $literalShort=[ExVpnShorebirdAndroidPath]::ShortPath($sdk)
        $proof.shortPathAvailable=$true; $proof.shortPathContainsSpace=$literalShort.Contains(' ')
        $short=Assert-ShorebirdAndroidLiteralToolPath $literalShort
        $proof.literalSdkAliasPreserved=$short -ceq $literalShort
        $analyzer=Assert-ShorebirdAndroidToolPath (Join-Path $sdk 'cmdline-tools/latest/bin/apkanalyzer.bat')
        # Avoid provider/path normalization here as well as for the SDK root.
        $literalAnalyzer=$short+'\cmdline-tools\latest\bin\apkanalyzer.bat'
        $shortAnalyzer=Assert-ShorebirdAndroidLiteralToolPath $literalAnalyzer
        $proof.literalAnalyzerAliasPreserved=$shortAnalyzer -ceq $literalAnalyzer
        foreach ($record in @(@($sdk,$true),@($short,$true),@($analyzer,$false),@($shortAnalyzer,$false))) {
            $leases.Add([ExVpnShorebirdAndroidPath]::Hold($record[0],$record[1]))
        }
        Assert-ShorebirdAndroidToolPair $leases[0] $leases[1] $true
        Assert-ShorebirdAndroidToolPair $leases[2] $leases[3] $false
        $proof.sdkDirectoryIdentityMatched=$true; $proof.analyzerFileIdentityMatched=$true
        $proof.analyzerSha256=(Get-FileHash -LiteralPath $analyzer -Algorithm SHA256).Hash.ToLowerInvariant()
        $phase='private_flutter_config'
        $env:APPDATA=$toolHome; $proof.processAppDataOnlyChanged=$true
        # Pass a serialized argument array to a child PowerShell. No path is
        # composed into cmd.exe syntax; only the pinned Flutter batch is called.
        $request=@{executable=(Join-Path $flutter 'bin/flutter.bat');arguments=@('--suppress-analytics','config',"--android-sdk=$short","--jdk-dir=$jdkSetting")}
        $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($request | ConvertTo-Json -Compress)))
        $command='$ErrorActionPreference="Stop";$PSNativeCommandUseErrorActionPreference=$false;$r=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("'+$encoded+'"))|ConvertFrom-Json;& $r.executable @($r.arguments);exit $LASTEXITCODE'
        $command64=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        if ((Invoke-ShorebirdAndroidPrivateProcess (Join-Path $PSHOME 'pwsh.exe') @('-NoProfile','-NonInteractive','-EncodedCommand',$command64) $private 'flutter-config') -ne 0) { throw 'flutter_config' }
        $settingsPath=Assert-ShorebirdAndroidToolPath (Join-Path $toolHome '.flutter_settings')
        Assert-ShorebirdAndroidToolSettings ([IO.File]::ReadAllText($settingsPath)) $short $jdkSetting
        $proof.privateSettingsExact=$true; $proof.settingsSha256=(Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $phase='dart_process_analyzer'
        $zipPath=Join-Path $private 'analyzer-probe.zip'
        $archive=[IO.Compression.ZipFile]::Open($zipPath,[IO.Compression.ZipArchiveMode]::Create)
        try {
            $entry=$archive.CreateEntry('BUNDLE-METADATA/com.android.tools.build.debugsymbols/arm64-v8a/libflutter.so.sym')
            $stream=$entry.Open(); try { $stream.WriteByte(1) } finally { $stream.Dispose() }
        } finally { $archive.Dispose() }
        $probePath=Join-Path $private 'analyzer-probe.dart'
        [IO.File]::WriteAllText($probePath, @'
import 'dart:convert';
import 'dart:io';
Future<void> main(List<String> args) async {
  final result = await Process.run(args[0], ['files', 'list', args[1]], runInShell: false);
  await File('${args[2]}/analyzer.stdout.private.log').writeAsString('${result.stdout}');
  await File('${args[2]}/analyzer.stderr.private.log').writeAsString('${result.stderr}');
  final text = '${result.stdout}\n${result.stderr}';
  final proof = {'schema': 1, 'exitCode': result.exitCode,
    'expectedMetadataListed': '${result.stdout}'.contains('/BUNDLE-METADATA/com.android.tools.build.debugsymbols/arm64-v8a/libflutter.so.sym'),
    'classFilesFailure': text.contains('Could not find or load main class Files') || text.contains('ClassNotFoundException: Files')};
  await File('${args[2]}/analyzer-probe.json').writeAsString(jsonEncode(proof));
}
'@)
        if ((Invoke-ShorebirdAndroidPrivateProcess $dart @($probePath,$shortAnalyzer,$zipPath,$private) $private 'dart-analyzer') -ne 0) { throw 'dart_process' }
        $probe=Get-Content -LiteralPath (Join-Path $private 'analyzer-probe.json') -Raw | ConvertFrom-Json -AsHashtable
        $proof.syntheticExitCode=$probe.exitCode; $proof.expectedMetadataListed=$probe.expectedMetadataListed
        foreach($stream in @('stdout','stderr')){
            $log=Join-Path $private "analyzer.$stream.private.log"
            $proof['analyzer'+$stream.Substring(0,1).ToUpperInvariant()+$stream.Substring(1)+'Bytes']=(Get-Item -LiteralPath $log).Length
            $proof['analyzer'+$stream.Substring(0,1).ToUpperInvariant()+$stream.Substring(1)+'Sha256']=(Get-FileHash -LiteralPath $log -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        Assert-ShorebirdAndroidToolProbe $probe
        $phase='identity_recheck'
        foreach ($record in @(@($sdk,$true,0),@($short,$true,1),@($analyzer,$false,2),@($shortAnalyzer,$false,3))) {
            $null=Assert-ShorebirdAndroidToolPath $record[0]
            $reopened=[ExVpnShorebirdAndroidPath]::Hold($record[0],$record[1])
            try { Assert-ShorebirdAndroidToolPair $leases[$record[2]] $reopened $record[1] } finally { $reopened.Dispose() }
        }
        Assert-ShorebirdAndroidToolSettings ([IO.File]::ReadAllText($settingsPath)) $short $jdkSetting
        if ((Get-FileHash -LiteralPath $analyzer -Algorithm SHA256).Hash.ToLowerInvariant() -cne $proof.analyzerSha256 -or
            (Get-FileHash -LiteralPath $dart -Algorithm SHA256).Hash.ToLowerInvariant() -cne $proof.dartSha256 -or
            (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $proof.settingsSha256 -or
            $env:APPDATA -cne $toolHome -or $env:JAVA_HOME -cne $jdkSetting) { throw 'changed' }
        $proof.heldIdentitiesRechecked=$true; $proof.status='completed'; $proof.phase='complete';$proof.pathCheck='complete'
        Write-ShorebirdAndroidToolReceipt $repositoryRoot $proof
        $success=$true
        $proof
    } catch {
        $proof.phase=$phase;$proof.pathCheck=$pathCheck;$proof.errorCode='shorebird_android_'+$phase+'_failed'
        $proof.failureReason=Get-ShorebirdAndroidToolFailureReason $_.Exception.Message
        $proof.diagnosticEncrypted=Write-ShorebirdAndroidToolFailureDiagnostic $moduleRepository $private $privateValid $_ $phase $pathCheck @{
            repository=$Repository;flutterSdkRoot=$FlutterSdkRoot;androidSdkPath=$AndroidSdkPath
            privateDirectory=$PrivateDirectory;jdk=$env:JAVA_HOME}
        if ($privateValid) { ($_ | Out-String) | Set-Content -LiteralPath (Join-Path $private 'android-tools-failure.private.log') -Encoding utf8NoBOM }
        try { Write-ShorebirdAndroidToolReceipt $moduleRepository $proof } catch { }
        throw 'shorebird_android_environment_preflight_failed'
    } finally {
        foreach ($lease in $leases) { $lease.Dispose() }
        if (!$success) { $env:APPDATA=$savedAppData }
    }
}
