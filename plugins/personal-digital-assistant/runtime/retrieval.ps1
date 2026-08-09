Set-StrictMode -Version Latest

function Select-PdaKnowledgeEvidence {
    <#
    Rerank already-authorized evidence chunks. This is relevance ranking only;
    adapters must apply tenant, identity and knowledge permissions first.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)][object[]]$Candidates,
        [ValidateRange(1, 20)][int]$Limit = 5
    )

    $lowerQuery = $Query.ToLowerInvariant()
    $scheduleIntent = [regex]::IsMatch($lowerQuery, '\u6392\u671f|\u65f6\u95f4\u8ba1\u5212|\u91cc\u7a0b\u7891|\u7518\u7279')
    $projectCodes = @([regex]::Matches($Query, '(?i)\bQ\d{2}[A-Z]*\b') | ForEach-Object { $_.Value.ToUpperInvariant() } | Select-Object -Unique)
    $scheduleTerms = @('\u9636\u6bb5','\u65f6\u95f4\u8303\u56f4','\u91cc\u7a0b\u7891','evt','dvt','pvt','\u7b2c\s*\d+(?:\.\d+)?-')

    $ranked = foreach ($candidate in $Candidates) {
        $source = [string]$candidate.source
        $title = [string]$candidate.title
        $heading = [string]$candidate.heading
        $content = [string]$candidate.content
        $body = "$heading`n$content".ToLowerInvariant()
        $score = if ($null -ne $candidate.PSObject.Properties['score']) { [double]$candidate.score } else { 0.0 }

        foreach ($code in $projectCodes) {
            if (("$source`n$title`n$body").ToUpperInvariant().Contains($code)) { $score += 30 }
        }
        if ($scheduleIntent) {
            if ([regex]::IsMatch(("$source`n$title").ToLowerInvariant(), '\u6392\u671f|\u65f6\u95f4计划|\u7518\u7279')) { $score += 35 }
            foreach ($term in $scheduleTerms) { if ([regex]::IsMatch($body, $term)) { $score += 18 } }
        }
        [pscustomobject]@{ candidate=$candidate; effectiveScore=$score; source=$source }
    }

    $selected = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($ranked | Sort-Object effectiveScore -Descending)) {
        $key = if ($entry.source) { $entry.source } else { [guid]::NewGuid().ToString() }
        if ($seen.Add($key)) { $selected.Add($entry.candidate) }
        if ($selected.Count -ge $Limit) { break }
    }
    return @($selected)
}
