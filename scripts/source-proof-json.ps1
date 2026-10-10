# Stateless JSON transport for hashed source-delivery evidence. Date strings
# are payload data; readers must not reinterpret them as local DateTime values.
$script:DeliveryProofJsonHasDateKind = (Get-Command Microsoft.PowerShell.Utility\ConvertFrom-Json).Parameters.ContainsKey('DateKind')

function ConvertFrom-DeliveryProofJsonToken {
    param([Parameter(Mandatory = $true)]$Token)
    # JObject's dynamic member adapter treats .Type as a JSON property lookup.
    switch ([string]$Token.get_Type()) {
        'Object' {
            $result = [ordered]@{}
            foreach ($property in $Token.Properties()) { $result[$property.Name] = ConvertFrom-DeliveryProofJsonToken -Token $property.Value }
            return [pscustomobject]$result
        }
        'Array' {
            $items = [Collections.Generic.List[object]]::new()
            foreach ($item in $Token.Children()) { $items.Add((ConvertFrom-DeliveryProofJsonToken -Token $item)) }
            return ,$items.ToArray()
        }
        'Null' { return $null }
        default { return $Token.Value }
    }
}

function ConvertFrom-DeliveryProofJsonLegacyCore {
    param([Parameter(Mandatory = $true)][string]$Json)
    # Core versions before DateKind still expose their already-loaded Json.NET
    # reader. Explicitly disabling date parsing preserves precision and offsets.
    $textReader = [IO.StringReader]::new($Json)
    $reader = [Newtonsoft.Json.JsonTextReader]::new($textReader)
    $reader.DateParseHandling = [Newtonsoft.Json.DateParseHandling]::None
    try {
        $token = [Newtonsoft.Json.Linq.JToken]::ReadFrom($reader)
        if ($reader.Read()) { throw 'Delivery proof JSON contains trailing content.' }
        return ConvertFrom-DeliveryProofJsonToken -Token $token
    } finally { $reader.Dispose(); $textReader.Dispose() }
}

function ConvertFrom-DeliveryProofJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, ValueFromPipeline = $true)][string]$Json)
    process {
        if ($script:DeliveryProofJsonHasDateKind) {
            return Microsoft.PowerShell.Utility\ConvertFrom-Json -InputObject $Json -DateKind String
        }
        if ($PSVersionTable.PSEdition -eq 'Core') { return ConvertFrom-DeliveryProofJsonLegacyCore -Json $Json }
        # Windows PowerShell 5.1 already retains JSON dates as strings.
        return Microsoft.PowerShell.Utility\ConvertFrom-Json -InputObject $Json
    }
}

function ConvertTo-DeliveryProofJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)][AllowNull()]$InputObject,
        [ValidateRange(1, 100)][int]$Depth = 16,
        [switch]$Compress,
        [switch]$LegacyCore
    )
    process {
        $json = Microsoft.PowerShell.Utility\ConvertTo-Json -InputObject $InputObject -Depth $Depth -Compress:$Compress
        # Match Windows PowerShell's established format, including its normal
        # quote escaping. Core EscapeHtml additionally changes quotes to u0022,
        # so that option is not byte-compatible with the existing writer.
        $json = $json.Replace("'", '\u0027').Replace('<', '\u003c').Replace('>', '\u003e').Replace('&', '\u0026')
        if ($LegacyCore) {
            # Validate known historical Core hashes without modifying payload.
            # An even backslash prefix distinguishes escapes from literal text
            # such as "\\u0027", which must remain unchanged.
            $json = [regex]::Replace($json, '(?<!\\)((?:\\\\)*)\\u(0027|003c|003e|0026)', {
                param($match)
                return $match.Groups[1].Value + [char][Convert]::ToInt32($match.Groups[2].Value, 16)
            })
        }
        return $json
    }
}
