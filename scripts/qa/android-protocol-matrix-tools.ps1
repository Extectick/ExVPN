# SPDX-License-Identifier: Apache-2.0
# Inert API36-only observer. Never starts or controls a VPN.
Set-StrictMode -Version Latest

function ConvertFrom-AndroidProtocolMatrixNetworks {
    param([Parameter(Mandatory)][string]$Output,
          [Parameter(Mandatory)][ValidateRange(10000,1999999999)][int]$ExpectedOwnerUid)
    if ($Output.Length -lt 128 -or $Output.Length -gt 2MB) { throw 'protocol_connectivity_size_invalid' }
    $text=$Output.Replace("`r`r`n","`n").Replace("`r`n","`n")
    if ($text.Contains("`r")) { throw 'protocol_connectivity_line_endings_invalid' }
    $sections=[regex]::Matches($text,'(?ms)^Current Networks:\n(.*?)^Status for known UIDs:\n')
    if ($sections.Count -ne 1 -or [regex]::Matches($text,'(?m)^Current Networks:$').Count -ne 1 -or
        [regex]::Matches($text,'(?m)^Status for known UIDs:$').Count -ne 1) { throw 'protocol_connectivity_section_invalid' }
    $rows=@($sections[0].Groups[1].Value -split "`n" | Where-Object { $_ -cmatch '^  NetworkAgentInfo\{' })
    if ($rows.Count -lt 1 -or $rows.Count -gt 16 -or
        [regex]::Matches($sections[0].Groups[1].Value,'NetworkAgentInfo\{').Count -ne $rows.Count) { throw 'protocol_connectivity_rows_invalid' }
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $interfaces=[Collections.Generic.List[string]]::new()
    foreach ($row in $rows) {
        $identity=[regex]::Match($row,'^  NetworkAgentInfo\{network\{(\d{1,10})\}  handle\{\d{1,20}\}  ni\{(WIFI|MOBILE|ETHERNET|VPN)(?:\[[A-Za-z0-9_]+\])? (CONNECTED|CONNECTING|DISCONNECTED) extra: [^}\r\n]*\}')
        $network=[regex]::Matches($row,'network\{\d+\}')
        $links=[regex]::Matches($row,' lp\{\{InterfaceName: ([A-Za-z0-9_.:-]+) ')
        $transports=[regex]::Matches($row,' nc\{\[ Transports: ([A-Z_|]+) Capabilities: ')
        if (!$identity.Success -or $network.Count -ne 1 -or $links.Count -ne 1 -or $transports.Count -ne 1 -or
            !$seen.Add($identity.Groups[1].Value) -or !$row.EndsWith('}')) { throw 'protocol_connectivity_row_unrecognized' }
        $typeVpn=$identity.Groups[2].Value -ceq 'VPN'
        $transportVpn=@($transports[0].Groups[1].Value.Split('|')) -ccontains 'VPN'
        if ($typeVpn -ne $transportVpn) { throw 'protocol_connectivity_vpn_conflict' }
        $interface=$links[0].Groups[1].Value
        if (!$typeVpn) {
            if ($interface -cmatch '^tun[0-9]+$') { throw 'protocol_connectivity_unclassified_tun' }
            continue
        }
        $owners=[regex]::Matches($row,' OwnerUid: (\d+)(?= |\])')
        $owner=0
        if ($identity.Groups[3].Value -cne 'CONNECTED' -or $interface -cnotmatch '^tun[0-9]+$' -or
            $owners.Count -ne 1 -or ![int]::TryParse($owners[0].Groups[1].Value,[ref]$owner) -or $owner -ne $ExpectedOwnerUid) { throw 'protocol_connectivity_vpn_owner_unconfirmed' }
        $interfaces.Add($interface)
    }
    if ($interfaces.Count -gt 1) { throw 'protocol_connectivity_vpn_not_unique' }
    [ordered]@{mechanism='connectivity_api36_v2';networkCount=$rows.Count;vpnCount=$interfaces.Count;
        vpnInterfaces=@($interfaces.ToArray());ownerUidMatched=($interfaces.Count -eq 1);activeVpnNetworkAbsent=($interfaces.Count -eq 0)}
}

function Read-AndroidProtocolMatrixNetworks {
    param([Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9_-]{1,60}$')][string]$Step,
          [Parameter(Mandatory)][ValidateRange(10000,1999999999)][int]$ExpectedOwnerUid)
    $output=Invoke-AndroidLifecycleAdb -Step $Step -TimeoutSeconds 10 -AdbArguments @('shell','dumpsys','connectivity')
    ConvertFrom-AndroidProtocolMatrixNetworks -Output $output -ExpectedOwnerUid $ExpectedOwnerUid
}
