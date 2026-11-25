# Optional, on-recall source tokenizer. No model call, Python or service.
function Measure-ItlMemoryTokens {
    param([string]$Text)
    # .NET Framework regex works on UTF-16 categories. Do not present a non-BMP
    # approximation as the Unicode-scalar tokenizer's exact result.
    if($Text -match '[\uD800-\uDFFF]'){return @{measurement='unknown-non-BMP';utf8UpperBound=[Text.Encoding]::UTF8.GetByteCount($Text)}}
    $assetRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../assets/memory-tokenizer'))
    if(-not ('ItlMemoryBpe' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;
using System.Collections.Generic;
public sealed class ItlMemoryBpe {
    readonly Dictionary<string,int> ranks = new Dictionary<string,int>(StringComparer.Ordinal);
    readonly Regex pieces;
    public ItlMemoryBpe(string path, string pattern, string expected) {
        using(var file=File.OpenRead(path))
        using(var zip=new GZipStream(file,CompressionMode.Decompress))
        using(var raw=new MemoryStream()) {
            zip.CopyTo(raw);
            using(var sha=System.Security.Cryptography.SHA256.Create()) {
                string actual=BitConverter.ToString(sha.ComputeHash(raw.ToArray())).Replace("-","").ToLowerInvariant();
                if(actual!=expected) throw new InvalidDataException("MEMORY_TOKENIZER_HASH");
            }
            raw.Position=0;
            using(var reader=new StreamReader(raw,Encoding.UTF8)) {
                string line; while((line=reader.ReadLine())!=null) {
                    int split=line.IndexOf(' ');
                    ranks.Add(line.Substring(0,split),int.Parse(line.Substring(split+1),System.Globalization.CultureInfo.InvariantCulture));
                }
            }
        }
        pieces=new Regex(pattern,RegexOptions.CultureInvariant,TimeSpan.FromSeconds(1));
    }
    public int Count(string text) {
        int total=0, covered=0;
        foreach(Match match in pieces.Matches(text)) {
            if(match.Index!=covered) throw new InvalidDataException("MEMORY_TOKENIZER_GAP");
            covered+=match.Length;
            byte[] bytes=Encoding.UTF8.GetBytes(match.Value);
            if(ranks.ContainsKey(Convert.ToBase64String(bytes))) {total++;continue;}
            var starts=new List<int>(); for(int i=0;i<=bytes.Length;i++) starts.Add(i);
            while(starts.Count>2) {
                int best=int.MaxValue, at=-1;
                for(int i=0;i<starts.Count-2;i++) {
                    int rank; string key=Convert.ToBase64String(bytes,starts[i],starts[i+2]-starts[i]);
                    if(ranks.TryGetValue(key,out rank) && rank<best) {best=rank;at=i;}
                }
                if(at<0) break;
                starts.RemoveAt(at+1);
            }
            total+=starts.Count-1;
        }
        if(covered!=text.Length) throw new InvalidDataException("MEMORY_TOKENIZER_GAP");
        return total;
    }
}
'@
    }
    if(-not (Get-Variable ItlMemoryTokenizers -Scope Script -ErrorAction SilentlyContinue)){
        $manifest=Read-ItlMemoryJson (Join-Path $assetRoot 'manifest.json')
        # Atomic groups preserve upstream possessive quantifiers on .NET regex.
        $patterns=@{
            cl100k_base="'(?i:[sdmt]|ll|ve|re)|(?>[^\r\n\p{L}\p{N}]?)(?>\p{L}+)|(?>\p{N}{1,3})| ?(?>[^\s\p{L}\p{N}]+)(?>[\r\n]*)|(?>\s+)$|\s*[\r\n]|\s+(?!\S)|\s"
            o200k_base="[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]*[\p{Ll}\p{Lm}\p{Lo}\p{M}]+(?i:'s|'t|'re|'ve|'m|'ll|'d)?|[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]+[\p{Ll}\p{Lm}\p{Lo}\p{M}]*(?i:'s|'t|'re|'ve|'m|'ll|'d)?|\p{N}{1,3}| ?[^\s\p{L}\p{N}]+[\r\n/]*|\s*[\r\n]+|\s+(?!\S)|\s+"
        }
        $script:ItlMemoryTokenizers=@{}
        foreach($asset in $manifest.assets){
            $path=Join-Path $assetRoot ($asset.encoding+'.gz')
            if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $asset.packedSha256){throw 'MEMORY_TOKENIZER_HASH'}
            $script:ItlMemoryTokenizers[$asset.encoding]=[ItlMemoryBpe]::new($path,$patterns[$asset.encoding],$asset.sourceSha256)
        }
    }
    return @{measurement='measured-encode-ordinary';cl100k_base=$script:ItlMemoryTokenizers.cl100k_base.Count($Text);o200k_base=$script:ItlMemoryTokenizers.o200k_base.Count($Text);modelMapping='unverified until actual client/model G5'}
}
