# SPDX-License-Identifier: Apache-2.0
# Synthetic read-only fixtures; no ADB, keys, builds or network mutations.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'android-protocol-matrix-tools.ps1')
$script:checks=0
function Check([bool]$Value){if(!$Value){throw 'protocol_matrix_fixture_failed'};$script:checks++}
function Reject([string]$Text){try{ConvertFrom-AndroidProtocolMatrixNetworks $Text 10214|Out-Null}catch{$script:checks++;return};throw 'protocol_matrix_fixture_not_rejected'}
$wifi='  NetworkAgentInfo{network{101}  handle{437197393933}  ni{WIFI CONNECTED extra: } created=2026-10-21T00:00:00 lp{{InterfaceName: wlan0 LinkAddresses: []}} nc{[ Transports: WIFI Capabilities: INTERNET]}}'
$vpn='  NetworkAgentInfo{network{102}  handle{441492361229}  ni{VPN CONNECTED extra: } created=2026-10-21T00:00:00 lp{{InterfaceName: tun0 LinkAddresses: []}} nc{[ Transports: WIFI|VPN Capabilities: INTERNET OwnerUid: 10214]}}'
$baseline="Current Networks:`n$wifi`nStatus for known UIDs:`n"; $connected="Current Networks:`n$wifi`n$vpn`nStatus for known UIDs:`n"
Check ((ConvertFrom-AndroidProtocolMatrixNetworks $baseline 10214).activeVpnNetworkAbsent)
$observed=ConvertFrom-AndroidProtocolMatrixNetworks $connected 10214
Check ($observed.vpnCount -eq 1 -and $observed.ownerUidMatched)
Reject $connected.Replace('OwnerUid: 10214','OwnerUid: 10215')
Reject $connected.Replace('OwnerUid: 10214','OwnerUid: 10214 OwnerUid: 10214')
Reject $connected.Replace('Transports: WIFI|VPN','Transports: WIFI')
Reject $connected.Replace('ni{VPN CONNECTED','ni{WIFI CONNECTED')
Reject $connected.Replace('ni{VPN CONNECTED','ni{VPN DISCONNECTED')
Reject $baseline.Replace('InterfaceName: wlan0','InterfaceName: tun0')
Reject $connected.Replace('network{102}','network{101}')
Reject $connected.Replace('Status for known UIDs:','Status for unknown UIDs:')
Reject ($connected+"Current Networks:`n$wifi`nStatus for known UIDs:`n")
Reject $connected.Replace('InterfaceName: tun0','InterfaceName: unknown0')
[ordered]@{status='PASS';checks=$script:checks;scope='strict API36 network observer'}|ConvertTo-Json -Compress
