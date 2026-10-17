# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'android-exclusions-selectors.ps1')
$checks = 0
[xml]$before = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/android-exclusions/before-keyboard.xml') -Raw
[xml]$fitting = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/android-exclusions/filtered-keyboard.xml') -Raw
function Assert-Selector([bool]$Condition) {
    if (!$Condition) { throw 'qa_selector_positive_fixture_failed' }
    $script:checks++
}
function Assert-SelectorReject([scriptblock]$Action, [string]$Code) {
    $failure = $null
    try { $null = & $Action } catch { $failure = $_.Exception.Message }
    if (!$failure -or ($Code -and $failure -cne $Code)) { throw 'qa_selector_refusal_fixture_failed' }
    $script:checks++
}
function Test-SelectorMutation([string]$XPath, [string]$Attribute, [string]$Value, [string]$Code) {
    [xml]$copy = $fitting.OuterXml
    $copy.SelectSingleNode($XPath).SetAttribute($Attribute, $Value)
    Assert-SelectorReject { Get-AndroidExclusionsScreen $copy } $Code
}
function New-NoResultFixture {
    [xml]$copy = $fitting.OuterXml
    $screen = Get-AndroidExclusionsScreen $copy
    foreach ($row in @($screen.content.SelectNodes('.//node[@checkable="true"]'))) { $null = $row.ParentNode.RemoveChild($row) }
    $screen.search.SetAttribute('text', 'exvpn-qa-no-matches')
    $count = @(Find-AndroidExclusionExactLabel $copy 'Выбрано всего: 0')[0]
    $count.SetAttribute('content-desc', 'Выбрано всего: 1')
    $empty = $copy.CreateElement('node')
    foreach ($entry in @{package='ru.exvpn.exvpn';class='android.view.View';'content-desc'='Ничего не найдено';text='';bounds='[24,820][1056,940]';enabled='true';clickable='false';scrollable='false';checkable='false'}.GetEnumerator()) {
        $empty.SetAttribute($entry.Key, $entry.Value)
    }
    $null = $screen.content.AppendChild($empty)
    return ,$copy
}

$pre = Get-AndroidExclusionsScreen $before -ExpectedQuery ''
Assert-Selector ($pre.supportsScroll -and $pre.selectedCount -eq 0 -and !$pre.noResults)
Assert-Selector (($pre.viewport -join ',') -ceq '0,237,1080,1928')
$fit = Get-AndroidExclusionsScreen $fitting -ExpectedQuery 'ru.exvpn.netprobe'
Assert-Selector (!$fit.supportsScroll -and $fit.selectedCount -eq 0 -and !$fit.noResults)
Assert-Selector (($fit.viewport -join ',') -ceq '0,237,1080,1243')
Assert-Selector ($fit.search.GetAttribute('focused') -ceq 'true')
foreach ($package in @('ru.exvpn.netprobe', 'ru.exvpn.netprobe.excluded')) {
    $target = Find-AndroidExclusionsTarget $fitting $package $false
    Assert-Selector ($target.GetAttribute('checked') -ceq 'false')
}
$save = Find-AndroidExclusionsSave $fitting
Assert-Selector ($save.GetAttribute('bounds') -ceq '[370,1287][710,1419]')

# The global selected count includes filtered-out selections. Never derive it
# from visible rows or turn no-results into an empty persisted policy.
$noResults = New-NoResultFixture
$empty = Get-AndroidExclusionsScreen $noResults -ExpectedQuery 'exvpn-qa-no-matches'
Assert-Selector ($empty.noResults -and !$empty.supportsScroll -and $empty.selectedCount -eq 1)
Assert-Selector ((Find-AndroidExclusionsSave $noResults).GetAttribute('enabled') -ceq 'true')
Assert-SelectorReject { Find-AndroidExclusionsTarget $noResults 'ru.exvpn.netprobe' $false } 'qa_exclusion_query_unconfirmed'
[xml]$hidden = $fitting.OuterXml
@(Find-AndroidExclusionExactLabel $hidden 'Выбрано всего: 0')[0].SetAttribute('content-desc', 'Выбрано всего: 1')
Assert-Selector ((Get-AndroidExclusionsScreen $hidden).selectedCount -eq 1)

# A nested editable scroll node must not replace the content viewport or make
# a non-scrollable outer content area eligible for swiping.
[xml]$nested = $fitting.OuterXml
$nestedScreen = Get-AndroidExclusionsScreen $nested
$inner = $nested.CreateElement('node')
foreach ($entry in @{package='ru.exvpn.exvpn';class='android.widget.ScrollView';scrollable='true';bounds='[0,545][1080,721]'}.GetEnumerator()) {
    $inner.SetAttribute($entry.Key, $entry.Value)
}
$null = $nestedScreen.search.ParentNode.ReplaceChild($inner, $nestedScreen.search)
$null = $inner.AppendChild($nestedScreen.search)
$nestedResult = Get-AndroidExclusionsScreen $nested
Assert-Selector (!$nestedResult.supportsScroll -and ($nestedResult.viewport -join ',') -ceq '0,237,1080,1243')

$searchPath = '//node[@class="android.widget.EditText"]'
$savePath = '//node[@content-desc="Сохранить"]'
$countPath = '//node[@content-desc="Выбрано всего: 0"]'
foreach ($fixture in @(
    @($searchPath,'package','com.example.foreign','qa_exclusion_target_context_invalid'),
    @($searchPath,'enabled','false','qa_exclusion_target_context_invalid'),
    @($searchPath,'clickable','false','qa_exclusion_target_context_invalid'),
    @($searchPath,'focusable','false','qa_exclusion_control_invalid'),
    @($searchPath,'visible-to-user','false','qa_exclusion_target_hidden'),
    @($searchPath,'bounds','[0,545][0,721]','qa_exclusion_bounds_empty'),
    @($searchPath,'bounds','[0,1500][1080,1700]','qa_exclusion_target_clipped'),
    @($searchPath,'text','unknown','qa_exclusion_query_unconfirmed'),
    @($searchPath,'content-desc','Another field','qa_exclusion_search_label_invalid'),
    @($savePath,'enabled','false','qa_exclusion_target_context_invalid'),
    @($savePath,'clickable','false','qa_exclusion_target_context_invalid'),
    @($savePath,'class','android.view.View','qa_exclusion_control_invalid'),
    @($savePath,'package','com.example.foreign','qa_exclusion_target_context_invalid'),
    @($savePath,'visible-to-user','false','qa_exclusion_target_hidden'),
    @($savePath,'bounds','[370,2300][710,2400]','qa_exclusion_target_clipped'),
    @($savePath,'bounds','[370,1000][710,1100]','qa_exclusion_viewport_geometry_invalid'),
    @($countPath,'content-desc','Выбрано всего: 00','qa_exclusion_count_invalid'),
    @($countPath,'package','com.example.foreign','qa_exclusion_target_context_invalid'),
    @($countPath,'text','Выбрано всего: 1','qa_exclusion_count_invalid'),
    @('//node[@content-desc="Исключения приложений"]','content-desc','Another screen','qa_exclusion_screen_ambiguous_or_missing')
)) { Test-SelectorMutation @fixture }
Assert-SelectorReject { Get-AndroidExclusionsScreen $fitting -ExpectedQuery 'exvpn-qa-no-matches' } 'qa_exclusion_query_unconfirmed'

foreach ($xpath in @($searchPath, $savePath, $countPath, '//node[@content-desc="Исключения приложений"]')) {
    [xml]$copy = $fitting.OuterXml
    $node = $copy.SelectSingleNode($xpath)
    $null = $node.ParentNode.AppendChild($node.CloneNode($true))
    Assert-SelectorReject { Get-AndroidExclusionsScreen $copy }
}
foreach ($xpath in @($searchPath, $savePath, $countPath)) {
    [xml]$copy = $fitting.OuterXml
    $node = $copy.SelectSingleNode($xpath)
    $null = $node.ParentNode.RemoveChild($node)
    Assert-SelectorReject { Get-AndroidExclusionsScreen $copy }
}
foreach ($attribute in @('bounds', 'class', 'package', 'scrollable')) {
    [xml]$copy = $fitting.OuterXml
    $content = (Get-AndroidExclusionsScreen $copy).content
    $value = switch ($attribute) { bounds {'[0,237][0,1243]'} class {'android.widget.EditText'} package {'com.example.foreign'} scrollable {'unknown'} }
    $content.SetAttribute($attribute, $value)
    Assert-SelectorReject { Get-AndroidExclusionsScreen $copy }
}

foreach ($fixture in @(
    @('enabled','false'), @('clickable','false'), @('checked','unknown'),
    @('checked','true'), @('visible-to-user','false'), @('bounds','[0,1500][1080,1700]'),
    @('bounds','[0,996][0,1194]'), @('class','android.view.View'), @('package','com.example.foreign')
)) {
    [xml]$copy = $fitting.OuterXml
    $target = Find-AndroidExclusionsTarget $copy 'ru.exvpn.netprobe.excluded' $false
    $target.SetAttribute($fixture[0], $fixture[1])
    Assert-SelectorReject { Find-AndroidExclusionsTarget $copy 'ru.exvpn.netprobe.excluded' $false }
}
[xml]$duplicateTarget = $fitting.OuterXml
$target = Find-AndroidExclusionsTarget $duplicateTarget 'ru.exvpn.netprobe' $false
$null = $target.ParentNode.AppendChild($target.CloneNode($true))
Assert-SelectorReject { Find-AndroidExclusionsTarget $duplicateTarget 'ru.exvpn.netprobe' $false } 'qa_exclusion_target_ambiguous_or_missing'
[xml]$twoIdentities = $fitting.OuterXml
$target = Find-AndroidExclusionsTarget $twoIdentities 'ru.exvpn.netprobe' $false
$target.SetAttribute('text','com.example.second')
Assert-SelectorReject { Find-AndroidExclusionsTarget $twoIdentities 'ru.exvpn.netprobe' $false } 'qa_exclusion_target_state_invalid'
Assert-SelectorReject { Find-AndroidExclusionsTarget $fitting 'com.example.notAllowed' $false }
[xml]$outside = $fitting.OuterXml
$screen = Get-AndroidExclusionsScreen $outside
$target = Find-AndroidExclusionsTarget $outside 'ru.exvpn.netprobe' $false
$null = $screen.root.AppendChild($target)
Assert-SelectorReject { Get-AndroidExclusionsScreen $outside } 'qa_exclusion_row_outside_content'
[xml]$clipped = $fitting.OuterXml
$target = Find-AndroidExclusionsTarget $clipped 'ru.exvpn.netprobe' $false
$target.ParentNode.SetAttribute('bounds','[0,798][1080,820]')
Assert-SelectorReject { Find-AndroidExclusionsTarget $clipped 'ru.exvpn.netprobe' $false } 'qa_exclusion_target_clipped'
[xml]$emptyMissing = $noResults.OuterXml
$label = @(Find-AndroidExclusionExactLabel $emptyMissing 'Ничего не найдено')[0]
$null = $label.ParentNode.RemoveChild($label)
Assert-SelectorReject { Get-AndroidExclusionsScreen $emptyMissing } 'qa_exclusion_rows_missing'
[xml]$contradiction = $fitting.OuterXml
$emptyLabel = @(Find-AndroidExclusionExactLabel $noResults 'Ничего не найдено')[0]
$null = (Get-AndroidExclusionsScreen $contradiction).content.AppendChild($contradiction.ImportNode($emptyLabel, $true))
Assert-SelectorReject { Get-AndroidExclusionsScreen $contradiction } 'qa_exclusion_empty_state_inconsistent'
[pscustomobject]@{status='PASS';checks=$checks;fixtureLayouts=2;adbCalls=0;guestActions=0} | ConvertTo-Json -Compress
