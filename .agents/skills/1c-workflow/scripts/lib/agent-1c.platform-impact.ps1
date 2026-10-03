# Stateless source-impact proof for operation-local legacy diagnostics. Native
# checks remain authoritative; an unknown surface selects their strict fallback.
function Get-ItlPlatformImpactBslSurface {
    param([string]$Text)
    $tokens = [Collections.Generic.List[object]]::new()
    $line = 1
    for ($i=0; $i -lt $Text.Length;) {
        $c = $Text[$i]
        if ($c -eq [char]0) { throw 'BSL_NUL_UNRESOLVED' }
        if ($c -eq "`n") { $line++; $i++; continue }
        if ([char]::IsWhiteSpace($c) -or $c -eq [char]0xFEFF) { $i++; continue }
        if ($c -eq '/' -and $i+1 -lt $Text.Length -and $Text[$i+1] -eq '/') {
            while ($i -lt $Text.Length -and $Text[$i] -ne "`n") { $i++ }
            continue
        }
        $start = $i; $tokenLine = $line; $kind = 'symbol'
        if ($c -eq '"') {
            $kind = 'string'; $i++; $closed = $false
            while ($i -lt $Text.Length) {
                if ($Text[$i] -eq '"') {
                    if ($i+1 -lt $Text.Length -and $Text[$i+1] -eq '"') { $i+=2; continue }
                    $i++; $closed=$true; break
                }
                if ($Text[$i] -eq "`n") { $line++ }
                $i++
            }
            if (-not $closed) { throw 'BSL_STRING_UNRESOLVED' }
        } elseif ([char]::IsLetter($c) -or $c -eq '_') {
            $kind = 'identifier'; $i++
            while ($i -lt $Text.Length -and ([char]::IsLetterOrDigit($Text[$i]) -or $Text[$i] -eq '_')) { $i++ }
        } else { $i++ }
        $tokens.Add([pscustomobject]@{text=$Text.Substring($start,$i-$start);kind=$kind;line=$tokenLine})
    }
    $surface = [Collections.Generic.List[string]]::new()
    $exports = [Collections.Generic.List[string]]::new()
    for ($i=0; $i -lt $tokens.Count;) {
        $token=$tokens[$i]
        if ($token.kind -eq 'identifier' -and $token.text -match '^(?i:Процедура|Функция|Procedure|Function)$') {
            $routineKind=$token.text; $headerStart=$i
            if ($i+2 -ge $tokens.Count -or $tokens[$i+1].kind -ne 'identifier' -or $tokens[$i+2].text -cne '(') { throw 'BSL_DECLARATION_UNRESOLVED' }
            $name=$tokens[$i+1].text; $i+=2; $depth=0
            do {
                if ($tokens[$i].kind -eq 'symbol' -and $tokens[$i].text -ceq '(') { $depth++ }
                if ($tokens[$i].kind -eq 'symbol' -and $tokens[$i].text -ceq ')') { $depth-- }
                $i++
                if ($i -ge $tokens.Count -and $depth -gt 0) { throw 'BSL_HEADER_UNRESOLVED' }
            } while ($depth -gt 0)
            if ($i -lt $tokens.Count -and $tokens[$i].kind -eq 'identifier' -and $tokens[$i].text -match '^(?i:Экспорт|Export)$') { $exports.Add($name); $i++ }
            for ($h=$headerStart; $h -lt $i; $h++) { $surface.Add($tokens[$h].text) }
            $endPattern = if ($routineKind -match '^(?i:Процедура|Procedure)$') { '^(?i:КонецПроцедуры|EndProcedure)$' } else { '^(?i:КонецФункции|EndFunction)$' }
            $ended=$false
            while ($i -lt $tokens.Count) {
                $bodyToken=$tokens[$i]
                if ($bodyToken.kind -eq 'identifier' -and $bodyToken.text -match $endPattern) { $surface.Add($bodyToken.text); $i++; $ended=$true; break }
                if ($bodyToken.kind -eq 'identifier' -and $bodyToken.text -match '^(?i:Процедура|Функция|Procedure|Function|КонецПроцедуры|КонецФункции|EndProcedure|EndFunction)$') { throw 'BSL_ROUTINE_BOUNDARY_UNRESOLVED' }
                # Conditional compilation can change availability. It is not a
                # body-only proof when any directive differs, even inside a body.
                if ($bodyToken.kind -eq 'symbol' -and $bodyToken.text -ceq '#') {
                    $directiveLine=$bodyToken.line
                    while ($i -lt $tokens.Count -and $tokens[$i].line -eq $directiveLine) { $surface.Add($tokens[$i].text); $i++ }
                } else { $i++ }
            }
            if (-not $ended) { throw 'BSL_ROUTINE_END_UNRESOLVED' }
        } else { $surface.Add($token.text); $i++ }
    }
    return [pscustomobject]@{surface=[string]::Join([string][char]0,$surface.ToArray());exportedNames=@($exports.ToArray())}
}

function Read-ItlPlatformImpactXml {
    param([string]$Text)
    $xml=[Xml.XmlDocument]::new(); $xml.XmlResolver=$null
    $settings=[Xml.XmlReaderSettings]::new(); $settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit; $settings.XmlResolver=$null
    $reader=[Xml.XmlReader]::Create([IO.StringReader]::new($Text.TrimStart([char]0xFEFF)),$settings)
    try { $xml.Load($reader) } finally { $reader.Dispose() }
    return ,$xml
}

function Get-ItlPlatformImpactInventory {
    param([string]$ProjectRoot,[string]$TreeObjectId)
    $files=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($record in @(Get-GitPathListAt -Root $ProjectRoot -Arguments @('ls-tree','-r','-z',$TreeObjectId))) {
        $entry=[regex]::Match($record,'^(?<mode>100644|100755) blob (?<blob>[a-f0-9]{40,64})\t(?<path>.+)$')
        if (-not $entry.Success) { throw 'SOURCE_TREE_ENTRY_UNRESOLVED' }
        $path=$entry.Groups['path'].Value
        $files.Add($path,[pscustomobject]@{path=$path;blob=$entry.Groups['blob'].Value;mode=$entry.Groups['mode'].Value;owner=(Get-PlatformGate6MetadataOwner -RelativePath $path)})
    }
    return ,$files
}

function Test-ItlPlatformLegacySourceImpact {
    param(
        [Parameter(Mandatory=$true)][string]$ProjectRoot,
        [Parameter(Mandatory=$true)][string]$PreviousTreeObjectId,
        [Parameter(Mandatory=$true)][string]$CurrentTreeObjectId
    )
    $changed=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $allOwners=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $reason=''
    try {
        if ($PreviousTreeObjectId -cnotmatch '^[a-f0-9]{40,64}$' -or $CurrentTreeObjectId -cnotmatch '^[a-f0-9]{40,64}$') { throw 'TREE_ID_UNRESOLVED' }
        $before=Get-ItlPlatformImpactInventory -ProjectRoot $ProjectRoot -TreeObjectId $PreviousTreeObjectId
        $after=Get-ItlPlatformImpactInventory -ProjectRoot $ProjectRoot -TreeObjectId $CurrentTreeObjectId
        foreach ($file in @($before.Values)+@($after.Values)) { if ($file.owner) { [void]$allOwners.Add($file.owner) } }
        $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($path in @($before.Keys)+@($after.Keys)) { [void]$paths.Add($path) }
        $changedPaths=[Collections.Generic.List[string]]::new()
        foreach ($path in $paths) {
            if (-not $before.ContainsKey($path) -or -not $after.ContainsKey($path) -or $before[$path].blob -cne $after[$path].blob -or $before[$path].mode -cne $after[$path].mode) {
                $changedPaths.Add($path)
                $owner=if ($after.ContainsKey($path)) {$after[$path].owner} else {$before[$path].owner}
                if ($owner) { [void]$changed.Add($owner) }
            }
        }
        $oldOwners=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($file in $before.Values) { if ($file.owner) { [void]$oldOwners.Add($file.owner) } }
        $hasNewObject=$false
        foreach ($path in $changedPaths) {
            if (-not $before.ContainsKey($path) -and $after.ContainsKey($path) -and $after[$path].owner -and -not $oldOwners.Contains($after[$path].owner)) { $hasNewObject=$true; break }
        }
        $needed=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        [void]$needed.Add('Configuration.xml')
        foreach ($path in $changedPaths) { [void]$needed.Add($path) }
        $utf8=[Text.UTF8Encoding]::new($false,$true)
        $beforeText=@{}; $afterText=@{}
        foreach ($pair in @(@{files=$before;text=$beforeText;scanAll=$hasNewObject},@{files=$after;text=$afterText;scanAll=$false})) {
            $readFiles=@($pair.files.Values | Where-Object { $pair.scanAll -or $needed.Contains($_.path) })
            # Normal body-only loads inspect just their changed text/root. Only
            # additive admission needs a prior-reference scan. Bound the binary
            # blob buffer instead of retaining every prior resource in memory.
            for ($offset=0; $offset -lt $readFiles.Count; $offset+=128) {
                $last=[Math]::Min($offset+127,$readFiles.Count-1)
                $batch=@($readFiles[$offset..$last])
                $blobs=Get-GitBlobBytesBatch -Root $ProjectRoot -ObjectIds @($batch | ForEach-Object blob)
                foreach ($file in $batch) {
                    if (-not $blobs.ContainsKey($file.blob)) { throw 'SOURCE_BLOB_MISSING' }
                    try { $pair.text[$file.path]=$utf8.GetString([byte[]]$blobs[$file.blob]) }
                    catch { if ([IO.Path]::GetExtension($file.path) -in @('.bsl','.xml')) { throw 'SOURCE_TEXT_UTF8_UNRESOLVED' } }
                }
            }
        }
        $newOwners=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($path in $changedPaths) {
            if ($path -ceq 'ConfigDumpInfo.xml') { continue }
            if (-not $after.ContainsKey($path)) { throw ('SOURCE_DELETION_UNRESOLVED:'+ $path) }
            if ($path -ceq 'Configuration.xml') { continue }
            $owner=$after[$path].owner
            if (-not $owner) { throw ('SOURCE_OWNER_UNRESOLVED:'+ $path) }
            if (-not $before.ContainsKey($path)) {
                if ($oldOwners.Contains($owner)) { throw ('EXISTING_OBJECT_ADDITION_UNRESOLVED:'+ $path) }
                [void]$newOwners.Add($owner); continue
            }
            if ([IO.Path]::GetExtension($path) -ine '.bsl') { throw ('EXISTING_DESCRIPTOR_OR_PAYLOAD_CHANGED:'+ $path) }
            $oldSurface=Get-ItlPlatformImpactBslSurface -Text $beforeText[$path]
            $newSurface=Get-ItlPlatformImpactBslSurface -Text $afterText[$path]
            if ($oldSurface.surface -cne $newSurface.surface) { throw ('BSL_SURFACE_CHANGED:'+ $path) }
        }
        if (-not $beforeText.ContainsKey('Configuration.xml') -or -not $afterText.ContainsKey('Configuration.xml')) { throw 'ROOT_DESCRIPTOR_MISSING' }
        $oldXml=Read-ItlPlatformImpactXml $beforeText['Configuration.xml']; $newXml=Read-ItlPlatformImpactXml $afterText['Configuration.xml']
        foreach ($xml in @($oldXml,$newXml)) {
            $root=$xml.SelectSingleNode("/*[local-name()='MetaDataObject']/*[local-name()='Configuration']")
            if ($null -eq $root) { throw 'ROOT_DESCRIPTOR_UNRESOLVED' }
            foreach ($comment in @($root.SelectNodes("./*[local-name()='Properties']/*[local-name()='Comment']"))) { [void]$comment.ParentNode.RemoveChild($comment) }
        }
        $oldRootEntries=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
        $newRootEntries=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($pair in @(@{xml=$oldXml;entries=$oldRootEntries},@{xml=$newXml;entries=$newRootEntries})) {
            foreach ($node in @($pair.xml.SelectNodes("/*[local-name()='MetaDataObject']/*[local-name()='Configuration']/*[local-name()='ChildObjects']/*"))) {
                if ($node.ChildNodes.Count -ne 1 -or $node.FirstChild.NodeType -ne [Xml.XmlNodeType]::Text -or -not $node.InnerText.Trim()) { throw 'ROOT_CHILD_ENTRY_UNRESOLVED' }
                $pair.entries.Add($node.LocalName+'|'+$node.InnerText,$node)
            }
        }
        foreach ($key in $oldRootEntries.Keys) { if (-not $newRootEntries.ContainsKey($key)) { throw 'ROOT_CHILD_REMOVED_OR_RENAMED' } }
        $addedRootEntries=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($key in $newRootEntries.Keys) { if (-not $oldRootEntries.ContainsKey($key)) { $addedRootEntries.Add($key,$newRootEntries[$key]) } }
        $definitionIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($path in $beforeText.Keys) {
            if ([IO.Path]::GetExtension($path) -ine '.xml') { continue }
            $xml=Read-ItlPlatformImpactXml $beforeText[$path]
            foreach ($id in @($xml.SelectNodes('//@uuid'))) {
                $oldId=[guid]::Empty
                if (-not [guid]::TryParse($id.Value,[ref]$oldId)) { throw 'OLD_OBJECT_UUID_UNRESOLVED' }
                [void]$definitionIds.Add($oldId.ToString('D'))
            }
        }
        $newNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($owner in $newOwners) {
            $descriptors=@($after.Values | Where-Object { $_.owner -ceq $owner -and $_.path.Split('/').Count -eq 2 -and $_.path.EndsWith('.xml',[StringComparison]::OrdinalIgnoreCase) })
            if ($descriptors.Count -ne 1) { throw ('NEW_OBJECT_DESCRIPTOR_UNRESOLVED:'+ $owner) }
            $descriptor=$descriptors[0]
            $xml=Read-ItlPlatformImpactXml $afterText[$descriptor.path]
            $object=$xml.SelectSingleNode("/*[local-name()='MetaDataObject']/*")
            if ($null -eq $object -or $xml.DocumentElement.ChildNodes.Count -ne 1) { throw 'NEW_OBJECT_KIND_UNRESOLVED' }
            $nameNode=$object.SelectSingleNode("./*[local-name()='Properties']/*[local-name()='Name']")
            if ($null -eq $nameNode -or $nameNode.InnerText -cne [IO.Path]::GetFileNameWithoutExtension($descriptor.path)) { throw 'NEW_OBJECT_NAME_UNRESOLVED' }
            $name=$nameNode.InnerText; $key=$object.LocalName+'|'+$name
            if (-not $addedRootEntries.ContainsKey($key)) { throw ('NEW_OBJECT_ROOT_ENTRY_MISSING:'+ $owner) }
            $addedNode=$addedRootEntries[$key]; [void]$addedNode.ParentNode.RemoveChild($addedNode); [void]$addedRootEntries.Remove($key)
            [void]$newNames.Add($name)
            $id=[guid]::Empty
            if (-not [guid]::TryParse($object.GetAttribute('uuid'),[ref]$id) -or $id -eq [guid]::Empty) { throw 'NEW_OBJECT_UUID_UNRESOLVED' }
            foreach ($newFile in @($after.Values | Where-Object owner -ceq $owner)) {
                if ($afterText.ContainsKey($newFile.path)) {
                    foreach ($oldEntry in $oldRootEntries.Values) {
                        $oldName=[regex]::Escape($oldEntry.InnerText)
                        $reference='(?<![\p{L}\p{N}_])'+$oldName+'\s*\.|\.\s*'+$oldName+'(?![\p{L}\p{N}_])'
                        if ([regex]::IsMatch($afterText[$newFile.path],$reference,[Text.RegularExpressions.RegexOptions]::IgnoreCase)) { throw 'NEW_SHARED_DEPENDENCY_UNRESOLVED' }
                    }
                }
                if ([IO.Path]::GetExtension($newFile.path) -ieq '.xml') {
                    $part=Read-ItlPlatformImpactXml $afterText[$newFile.path]
                    foreach ($uuid in @($part.SelectNodes('//@uuid'))) {
                        $parsedId=[guid]::Empty
                        if (-not [guid]::TryParse($uuid.Value,[ref]$parsedId) -or $parsedId -eq [guid]::Empty -or -not $definitionIds.Add($parsedId.ToString('D'))) { throw 'NEW_OBJECT_UUID_COLLISION' }
                        [void]$newNames.Add($parsedId.ToString('D'))
                    }
                    # These descriptor properties introduce ambient/shared
                    # behavior; object-name isolation does not prove its impact.
                    $ambient=@($part.SelectNodes("/*[local-name()='MetaDataObject']/*/*[local-name()='Properties']/*[local-name()='Global' or local-name()='AutoUse' or local-name()='Source' or local-name()='Event' or local-name()='Handler']"))
                    foreach ($node in $ambient) { if ($node.InnerText.Trim() -notin @('','false','False','DontUse')) { throw 'NEW_SHARED_DEPENDENCY_UNRESOLVED' } }
                } elseif ([IO.Path]::GetExtension($newFile.path) -ieq '.bsl') {
                    $surface=Get-ItlPlatformImpactBslSurface -Text $afterText[$newFile.path]
                    foreach ($export in $surface.exportedNames) { [void]$newNames.Add($export) }
                }
            }
        }
        if ($addedRootEntries.Count -ne 0) { throw 'ROOT_ADDITION_NOT_NEW_OBJECT' }
        if ($oldXml.OuterXml -cne $newXml.OuterXml) { throw 'ROOT_PROPERTIES_OR_EXISTING_CHILDREN_CHANGED' }
        # A new name must not resolve a prior reference, including one in a
        # string/comment. This deliberately declines ambiguous dependency cases.
        foreach ($name in $newNames) {
            $pattern='(?<![\p{L}\p{N}_])'+[regex]::Escape($name)+'(?![\p{L}\p{N}_])'
            foreach ($text in $beforeText.Values) { if ([regex]::IsMatch($text,$pattern,[Text.RegularExpressions.RegexOptions]::IgnoreCase)) { throw ('PREEXISTING_REFERENCE_TO_ADDED_NAME:'+ $name) } }
        }
    } catch { $reason=$_.Exception.Message }
    $proven=-not $reason
    return [pscustomobject][ordered]@{schemaVersion=1;proven=[bool]$proven;
        changedOwners=@($changed | Sort-Object -CaseSensitive);
        impactOwners=$(if ($proven) { @($changed | Sort-Object -CaseSensitive) } else { @($allOwners | Sort-Object -CaseSensitive) });
        reason=$(if ($proven) {'SOURCE_IMPACT_PROVEN'} else {$reason})}
}
