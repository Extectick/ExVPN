# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
Set-StrictMode -Version Latest

# Only bounded Ethernet EPBs are inspected; payload/query names are never emitted.
function Get-PhysicalDnsPacketCounts([string]$Path) {
    $file=Get-Item -LiteralPath $Path
    if($file.Length -gt 32MB -or $file.Length -lt 28){throw 'bounded_pcapng_required'}
    $bytes=[IO.File]::ReadAllBytes($file.FullName)
    $offset=0; $packets=0; $dns=0; $ipv6=0
    while($offset -lt $bytes.Length){
        if($offset+12 -gt $bytes.Length){throw 'pcapng_block_truncated'}
        $kind=[BitConverter]::ToUInt32($bytes,$offset)
        $length=[BitConverter]::ToUInt32($bytes,$offset+4)
        if($length -lt 12 -or $length%4 -or $offset+$length -gt $bytes.Length -or [BitConverter]::ToUInt32($bytes,$offset+$length-4) -ne $length){throw 'pcapng_block_invalid'}
        if($kind -eq 0x0A0D0D0A -and [BitConverter]::ToUInt32($bytes,$offset+8) -ne 0x1A2B3C4D){throw 'little_endian_pcapng_required'}
        if($kind -eq 1 -and [BitConverter]::ToUInt16($bytes,$offset+8) -ne 1){throw 'ethernet_linktype_required'}
        if($kind -eq 6){
            if($length -lt 32){throw 'pcapng_packet_invalid'}
            $captured=[BitConverter]::ToUInt32($bytes,$offset+20)
            if($captured -lt 14 -or 28+$captured -gt $length-4){throw 'pcapng_packet_truncated'}
            $packets++;$start=$offset+28;$end=$start+$captured
            $ethernetType=([int]$bytes[$start+12] -shl 8) -bor $bytes[$start+13]
            $ip=$start+14;$transport=0;$protocol=0
            if($ethernetType -eq 0x0800 -and $ip+20 -le $end){
                $protocol=$bytes[$ip+9];$transport=$ip+(($bytes[$ip] -band 15)*4)
                if($transport -lt $ip+20){throw 'ipv4_header_invalid'}
            }elseif($ethernetType -eq 0x86DD -and $ip+40 -le $end){
                $ipv6++;$protocol=$bytes[$ip+6];$transport=$ip+40
                for($extension=0;$extension -lt 8 -and $protocol -in @(0,43,60,44,51);$extension++){
                    if($transport+8 -gt $end){throw 'ipv6_extension_truncated'}
                    $next=$bytes[$transport]
                    $size=if($protocol -eq 44){8}elseif($protocol -eq 51){($bytes[$transport+1]+2)*4}else{($bytes[$transport+1]+1)*8}
                    $transport+=$size;$protocol=$next
                }
            }
            if($protocol -in @(6,17) -and $transport+4 -le $end){
                $sourcePort=([int]$bytes[$transport] -shl 8) -bor $bytes[$transport+1]
                $destinationPort=([int]$bytes[$transport+2] -shl 8) -bor $bytes[$transport+3]
                if($sourcePort -eq 53 -or $destinationPort -eq 53){$dns++}
            }
        }
        $offset+=$length
    }
    [ordered]@{format=1;capturedPackets=$packets;dnsPackets=$dns;ipv6Packets=$ipv6;bytes=$bytes.Length;sha256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
}
