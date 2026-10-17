# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0
# Pure selectors for the ExVPN exclusions sheet. No ADB, input, scrolling or I/O.
# Callers supply a fresh, bounded XML snapshot only after confirming no active VPN.
# A complete viewport can be non-scrollable when filtered content fits. Neither
# that state nor an unchanged snapshot is evidence that a list was fully scanned.
Set-StrictMode -Version Latest

function Get-AndroidExclusionBounds([Xml.XmlElement]$Node) {
    $match = [regex]::Match($Node.GetAttribute('bounds'), '\A\[([0-9]{1,5}),([0-9]{1,5})\]\[([0-9]{1,5}),([0-9]{1,5})\]\z')
    if (!$match.Success) { throw 'qa_exclusion_bounds_invalid' }
    $bounds = @($match.Groups[1..4] | ForEach-Object { [int]$_.Value })
    if ($bounds[2] -le $bounds[0] -or $bounds[3] -le $bounds[1]) { throw 'qa_exclusion_bounds_empty' }
    return $bounds
}

function Test-AndroidExclusionDescendant([Xml.XmlElement]$Node, [Xml.XmlElement]$Ancestor) {
    for ($current = $Node; $null -ne $current -and $current.Name -ceq 'node'; $current = $current.ParentNode) {
        if ([object]::ReferenceEquals($current, $Ancestor)) { return $true }
    }
    return $false
}

function Find-AndroidExclusionExactLabel([xml]$Tree, [string]$Label) {
    return @($Tree.SelectNodes('//node') | Where-Object {
        $_.GetAttribute('content-desc') -ceq $Label -or $_.GetAttribute('text') -ceq $Label
    })
}

function Assert-AndroidExclusionVisible([Xml.XmlElement]$Node, [Xml.XmlElement]$Root, [switch]$Actionable) {
    if ($Node.GetAttribute('package') -cne 'ru.exvpn.exvpn' -or
        !(Test-AndroidExclusionDescendant $Node $Root) -or
        ($Actionable -and ($Node.GetAttribute('enabled') -cne 'true' -or $Node.GetAttribute('clickable') -cne 'true'))) {
        throw 'qa_exclusion_target_context_invalid'
    }
    $bounds = Get-AndroidExclusionBounds $Node
    $x = ($bounds[0] + $bounds[2]) / 2
    $y = ($bounds[1] + $bounds[3]) / 2
    for ($current = $Node; $null -ne $current -and $current.Name -ceq 'node'; $current = $current.ParentNode) {
        if ($current.GetAttribute('visible-to-user') -ceq 'false') { throw 'qa_exclusion_target_hidden' }
        $clip = Get-AndroidExclusionBounds $current
        if ($x -le $clip[0] -or $x -ge $clip[2] -or $y -le $clip[1] -or $y -ge $clip[3]) {
            throw 'qa_exclusion_target_clipped'
        }
        if ([object]::ReferenceEquals($current, $Root)) { return }
    }
    throw 'qa_exclusion_root_not_reached'
}

function Get-AndroidExclusionsScreen {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][xml]$Tree,
        [AllowEmptyString()][ValidateSet('', 'ru.exvpn.netprobe', 'exvpn-qa-no-matches')][string]$ExpectedQuery
    )
    if ($Tree.DocumentType -or @($Tree.SelectNodes('//node')).Count -gt 8192) { throw 'qa_exclusion_tree_invalid' }
    $roots = @($Tree.SelectNodes('/hierarchy/node[@package="ru.exvpn.exvpn"]'))
    $titles = @(Find-AndroidExclusionExactLabel $Tree 'Исключения приложений')
    $searches = @($Tree.SelectNodes('//node[@class="android.widget.EditText"]'))
    $saves = @(Find-AndroidExclusionExactLabel $Tree 'Сохранить')
    if ($roots.Count -ne 1 -or $titles.Count -ne 1 -or $searches.Count -ne 1 -or $saves.Count -ne 1) {
        throw 'qa_exclusion_screen_ambiguous_or_missing'
    }
    $root = $roots[0]; $title = $titles[0]; $search = $searches[0]; $save = $saves[0]
    Assert-AndroidExclusionVisible $title $root
    Assert-AndroidExclusionVisible $search $root -Actionable
    Assert-AndroidExclusionVisible $save $root -Actionable
    if ($search.GetAttribute('focusable') -cne 'true' -or $save.GetAttribute('class') -cne 'android.widget.Button') {
        throw 'qa_exclusion_control_invalid'
    }
    $query = $search.GetAttribute('text')
    if ($query -cnotin @('', 'ru.exvpn.netprobe', 'exvpn-qa-no-matches') -or
        ($PSBoundParameters.ContainsKey('ExpectedQuery') -and $query -cne $ExpectedQuery)) {
        throw 'qa_exclusion_query_unconfirmed'
    }
    # API30 can omit the Flutter label/hint. Empty semantics are accepted only
    # with the complete sheet contract below; this is not accessibility proof.
    $searchLabel = $search.GetAttribute('content-desc')
    if ($searchLabel -and @($searchLabel -split '\r?\n') -cnotcontains 'Поиск приложений') {
        throw 'qa_exclusion_search_label_invalid'
    }
    $countNodes = @($Tree.SelectNodes('//node') | Where-Object {
        $_.GetAttribute('content-desc').StartsWith('Выбрано всего:', [StringComparison]::Ordinal) -or
        $_.GetAttribute('text').StartsWith('Выбрано всего:', [StringComparison]::Ordinal)
    })
    if ($countNodes.Count -ne 1) { throw 'qa_exclusion_count_ambiguous_or_missing' }
    $countNode = $countNodes[0]
    Assert-AndroidExclusionVisible $countNode $root
    $countLabels = @(@($countNode.GetAttribute('content-desc'), $countNode.GetAttribute('text')) |
        Where-Object { $_.StartsWith('Выбрано всего:', [StringComparison]::Ordinal) } | Select-Object -Unique)
    if ($countLabels.Count -ne 1 -or $countLabels[0] -cnotmatch '\AВыбрано всего: (0|[1-9][0-9]{0,4})\z') {
        throw 'qa_exclusion_count_invalid'
    }
    $selectedCount = [int]$Matches[1]

    # The nearest common ancestor identifies content, independently of whether
    # accessibility advertises ScrollView or a fitting, non-scrollable View.
    $content = $search.ParentNode
    while ($null -ne $content -and $content.Name -ceq 'node' -and
        !(Test-AndroidExclusionDescendant $countNode $content)) { $content = $content.ParentNode }
    if ($null -eq $content -or $content.Name -cne 'node' -or [object]::ReferenceEquals($content, $root) -or
        $content.GetAttribute('package') -cne 'ru.exvpn.exvpn' -or
        $content.GetAttribute('class') -cnotin @('android.view.View', 'android.widget.ScrollView') -or
        $content.GetAttribute('scrollable') -cnotin @('true', 'false')) { throw 'qa_exclusion_viewport_invalid' }
    $viewport = Get-AndroidExclusionBounds $content
    $window = Get-AndroidExclusionBounds $root
    $titleBounds = Get-AndroidExclusionBounds $title
    $saveBounds = Get-AndroidExclusionBounds $save
    if ($viewport[2] - $viewport[0] -lt 100 -or $viewport[3] - $viewport[1] -lt 80 -or
        $viewport[0] -lt $window[0] -or $viewport[2] -gt $window[2] -or
        $viewport[1] -lt $titleBounds[3] -or $viewport[3] -gt $saveBounds[1] -or
        (Test-AndroidExclusionDescendant $save $content)) { throw 'qa_exclusion_viewport_geometry_invalid' }
    $rows = @($Tree.SelectNodes('//node[@checkable="true"]'))
    foreach ($row in $rows) {
        if ($row.GetAttribute('package') -cne 'ru.exvpn.exvpn' -or !(Test-AndroidExclusionDescendant $row $content)) {
            throw 'qa_exclusion_row_outside_content'
        }
    }
    $noResults = @(Find-AndroidExclusionExactLabel $Tree 'Ничего не найдено')
    if ($noResults.Count -gt 1 -or ($noResults.Count -eq 1 -and ($rows.Count -ne 0 -or !$query))) {
        throw 'qa_exclusion_empty_state_inconsistent'
    }
    if ($noResults.Count -eq 1) {
        Assert-AndroidExclusionVisible $noResults[0] $root
        if (!(Test-AndroidExclusionDescendant $noResults[0] $content)) { throw 'qa_exclusion_empty_state_outside_content' }
    } elseif (!$rows.Count) { throw 'qa_exclusion_rows_missing' }
    return [pscustomobject]@{
        root = $root; search = $search; content = $content; save = $save
        viewport = $viewport; supportsScroll = $content.GetAttribute('scrollable') -ceq 'true'
        query = $query; selectedCount = $selectedCount; noResults = $noResults.Count -eq 1
    }
}

function Find-AndroidExclusionsTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][xml]$Tree,
        [Parameter(Mandatory)][ValidateSet('ru.exvpn.netprobe', 'ru.exvpn.netprobe.excluded')][string]$Package,
        [Parameter(Mandatory)][bool]$ExpectedSelected
    )
    $screen = Get-AndroidExclusionsScreen $Tree -ExpectedQuery 'ru.exvpn.netprobe'
    $targets = @($screen.content.SelectNodes('.//node[@checkable="true"]') | Where-Object {
        @((@($_.GetAttribute('content-desc'), $_.GetAttribute('text')) -join "`n") -split '\r?\n') -ccontains $Package
    })
    if ($targets.Count -ne 1) { throw 'qa_exclusion_target_ambiguous_or_missing' }
    $target = $targets[0]
    $identityLines = @((@($target.GetAttribute('content-desc'), $target.GetAttribute('text')) -join "`n") -split '\r?\n' |
        Where-Object { $_ -cmatch '^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z0-9_]+)+$' })
    if ($identityLines.Count -ne 1 -or $identityLines[0] -cne $Package -or
        $target.GetAttribute('class') -cne 'android.widget.CheckBox' -or
        $target.GetAttribute('checked') -cnotin @('true', 'false') -or
        ($target.GetAttribute('checked') -ceq 'true') -ne $ExpectedSelected) { throw 'qa_exclusion_target_state_invalid' }
    Assert-AndroidExclusionVisible $target $screen.root -Actionable
    return ,$target
}

function Find-AndroidExclusionsSave([xml]$Tree) {
    return ,(Get-AndroidExclusionsScreen $Tree).save
}
