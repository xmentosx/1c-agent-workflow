# Pure JSONC text operations. Offsets are UTF-16, Start inclusive / End exclusive.
# Read returns Text, Value (ordinal maps, arrays, scalars), Root (syntax nodes),
# Tokens (including untouched trivia) and Format. No operation reads or writes files.
function Initialize-ItlJsoncRuntime {
    if ('Itl.Jsonc.Document' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Itl.Jsonc {
    public sealed class JsoncException : FormatException {
        public string Code { get; private set; }
        public JsoncException(string code, string message) : base(code + ": " + message) { Code = code; }
    }
    public sealed class Token {
        public string Kind { get; set; }
        public int Start { get; set; }
        public int End { get; set; }
        public string Text { get; set; }
        public object Value { get; set; }
    }
    public sealed class Member {
        public string Name { get; set; }
        public int Start { get; set; }
        public int NameEnd { get; set; }
        public int ColonStart { get; set; }
        public int End { get { return Value.End; } }
        public int CommaStart { get; set; }
        public Node Value { get; set; }
    }
    public sealed class Node {
        public string Kind { get; set; }
        public int Start { get; set; }
        public int End { get; set; }
        public object Value { get; set; }
        public List<Member> Members { get; set; }
        public List<Node> Items { get; set; }
    }
    public sealed class TextFormat {
        public bool HasBom { get; set; }
        public string NewLine { get; set; }
    }
    public sealed class Document {
        public string Text { get; set; }
        public Node Root { get; set; }
        public object Value { get { return Root.Value; } }
        public List<Token> Tokens { get; set; }
        public TextFormat Format { get; set; }
    }
    public sealed class Parser {
        private readonly string text;
        private readonly List<Token> tokens = new List<Token>();
        private int cursor;
        private static readonly Regex Number = new Regex(@"\G-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?", RegexOptions.CultureInvariant);
        private Parser(string input) { text = input; }
        private void Invalid(string message, int position) {
            throw new JsoncException("CLIENT_JSONC_INVALID", message + " at offset " + position.ToString(CultureInfo.InvariantCulture));
        }
        private void Add(string kind, int start, int end, object value) {
            tokens.Add(new Token { Kind = kind, Start = start, End = end, Text = text.Substring(start, end - start), Value = value });
        }
        private void Lex() {
            int i = 0;
            if (text.Length > 0 && text[0] == '\uFEFF') { Add("bom", 0, 1, null); i++; }
            while (i < text.Length) {
                int start = i;
                char ch = text[i];
                if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') {
                    do { i++; } while (i < text.Length && (text[i] == ' ' || text[i] == '\t' || text[i] == '\r' || text[i] == '\n'));
                    Add("whitespace", start, i, null);
                } else if (ch == '/' && i + 1 < text.Length && text[i + 1] == '/') {
                    i += 2;
                    while (i < text.Length && text[i] != '\r' && text[i] != '\n') i++;
                    Add("lineComment", start, i, null);
                } else if (ch == '/' && i + 1 < text.Length && text[i + 1] == '*') {
                    i += 2;
                    while (i + 1 < text.Length && !(text[i] == '*' && text[i + 1] == '/')) i++;
                    if (i + 1 >= text.Length) Invalid("unterminated comment", start);
                    i += 2;
                    Add("blockComment", start, i, null);
                } else if (ch == '"') {
                    i++;
                    StringBuilder value = new StringBuilder();
                    bool closed = false;
                    while (i < text.Length) {
                        char c = text[i++];
                        if (c == '"') { closed = true; break; }
                        if (c < 0x20) Invalid("control character in string", i - 1);
                        if (c != '\\') { value.Append(c); continue; }
                        if (i == text.Length) Invalid("unterminated escape", i - 1);
                        char escape = text[i++];
                        switch (escape) {
                            case '"': value.Append('"'); break;
                            case '\\': value.Append('\\'); break;
                            case '/': value.Append('/'); break;
                            case 'b': value.Append('\b'); break;
                            case 'f': value.Append('\f'); break;
                            case 'n': value.Append('\n'); break;
                            case 'r': value.Append('\r'); break;
                            case 't': value.Append('\t'); break;
                            case 'u':
                                int code = 0;
                                if (i + 4 > text.Length || !Int32.TryParse(text.Substring(i, 4), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out code))
                                    Invalid("invalid unicode escape", i);
                                value.Append((char)code); i += 4; break;
                            default: Invalid("invalid string escape", i - 1); break;
                        }
                    }
                    if (!closed) Invalid("unterminated string", start);
                    Add("string", start, i, value.ToString());
                } else if ("{}[],:".IndexOf(ch) >= 0) {
                    i++; Add(ch.ToString(), start, i, null);
                } else if (ch == '-' || (ch >= '0' && ch <= '9')) {
                    Match match = Number.Match(text, i);
                    if (!match.Success) Invalid("invalid number", i);
                    i += match.Length;
                    long integer;
                    double floating;
                    object value;
                    if (Int64.TryParse(match.Value, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out integer)) value = integer;
                    else if (Double.TryParse(match.Value, NumberStyles.Float, CultureInfo.InvariantCulture, out floating)) value = floating;
                    else value = match.Value.StartsWith("-", StringComparison.Ordinal) ? Double.NegativeInfinity : Double.PositiveInfinity;
                    Add("number", start, i, value);
                } else {
                    string literal = null;
                    foreach (string candidate in new[] { "true", "false", "null" }) {
                        if (text.Length - i >= candidate.Length && String.CompareOrdinal(text, i, candidate, 0, candidate.Length) == 0) { literal = candidate; break; }
                    }
                    if (literal == null) Invalid("unexpected character", i);
                    i += literal.Length;
                    Add(literal, start, i, literal == "null" ? null : (object)(literal == "true"));
                }
            }
        }
        private Token Peek() {
            while (cursor < tokens.Count && (tokens[cursor].Kind == "bom" || tokens[cursor].Kind == "whitespace" || tokens[cursor].Kind == "lineComment" || tokens[cursor].Kind == "blockComment")) cursor++;
            return cursor < tokens.Count ? tokens[cursor] : null;
        }
        private Token Take(string kind) {
            Token token = Peek();
            if (token == null || token.Kind != kind) Invalid("expected " + kind, token == null ? text.Length : token.Start);
            cursor++; return token;
        }
        private Node ParseValue() {
            Token token = Peek();
            if (token == null) Invalid("expected value", text.Length);
            if (token.Kind == "{") {
                cursor++;
                Node node = new Node { Kind = "object", Start = token.Start, Members = new List<Member>() };
                Dictionary<string, object> map = new Dictionary<string, object>(StringComparer.Ordinal);
                if (Peek() != null && Peek().Kind != "}") {
                    while (true) {
                        Token name = Take("string");
                        Token colon = Take(":");
                        Node value = ParseValue();
                        Member member = new Member { Name = (string)name.Value, Start = name.Start, NameEnd = name.End, ColonStart = colon.Start, Value = value, CommaStart = -1 };
                        node.Members.Add(member); map[member.Name] = value.Value;
                        if (Peek() == null || Peek().Kind != ",") break;
                        member.CommaStart = Take(",").Start;
                        if (Peek() != null && Peek().Kind == "}") break;
                    }
                }
                node.End = Take("}").End; node.Value = map; return node;
            }
            if (token.Kind == "[") {
                cursor++;
                Node node = new Node { Kind = "array", Start = token.Start, Items = new List<Node>() };
                if (Peek() != null && Peek().Kind != "]") {
                    while (true) {
                        node.Items.Add(ParseValue());
                        if (Peek() == null || Peek().Kind != ",") break;
                        Take(",");
                        if (Peek() != null && Peek().Kind == "]") break;
                    }
                }
                node.End = Take("]").End;
                object[] values = new object[node.Items.Count];
                for (int i = 0; i < values.Length; i++) values[i] = node.Items[i].Value;
                node.Value = values; return node;
            }
            if (token.Kind != "string" && token.Kind != "number" && token.Kind != "true" && token.Kind != "false" && token.Kind != "null") Invalid("expected value", token.Start);
            cursor++;
            return new Node { Kind = token.Kind == "true" || token.Kind == "false" ? "boolean" : token.Kind, Start = token.Start, End = token.End, Value = token.Value };
        }
        public static Document Read(string text) {
            if (text == null) throw new JsoncException("CLIENT_JSONC_INVALID", "text is null");
            Parser parser = new Parser(text);
            parser.Lex();
            Node root = parser.ParseValue();
            if (parser.Peek() != null) parser.Invalid("unexpected token after value", parser.Peek().Start);
            int newline = text.IndexOf('\n');
            string line = newline >= 0 ? (newline > 0 && text[newline - 1] == '\r' ? "\r\n" : "\n") : (text.IndexOf('\r') >= 0 ? "\r" : "\n");
            return new Document { Text = text, Root = root, Tokens = parser.tokens, Format = new TextFormat { HasBom = text.Length > 0 && text[0] == '\uFEFF', NewLine = line } };
        }
    }
    public static class Editor {
        private sealed class Edit {
            public int Start, End;
            public string Text;
        }
        private static void CheckPath(string[] path) {
            if (path == null || path.Length == 0) throw new JsoncException("CLIENT_JSONC_PROPERTY_PATH_INVALID", "a nonempty object property path is required");
            foreach (string part in path) if (part == null) throw new JsoncException("CLIENT_JSONC_PROPERTY_PATH_INVALID", "path components cannot be null");
        }
        private static Member Find(Node node, string name) {
            Member found = null;
            foreach (Member member in node.Members) {
                if (!String.Equals(member.Name, name, StringComparison.Ordinal)) continue;
                if (found != null) throw new JsoncException("CLIENT_JSONC_AMBIGUOUS_PROPERTY", "duplicate property on the edited path: " + name);
                found = member;
            }
            return found;
        }
        private static bool Equal(object a, object b) {
            if (a == null || b == null) return a == null && b == null;
            IDictionary left = a as IDictionary, right = b as IDictionary;
            if (left != null || right != null) {
                if (left == null || right == null || left.Count != right.Count) return false;
                foreach (object key in left.Keys) if (!right.Contains(key) || !Equal(left[key], right[key])) return false;
                return true;
            }
            object[] first = a as object[], second = b as object[];
            if (first != null || second != null) {
                if (first == null || second == null || first.Length != second.Length) return false;
                for (int i = 0; i < first.Length; i++) if (!Equal(first[i], second[i])) return false;
                return true;
            }
            if ((a is long || a is double) && (b is long || b is double)) {
                if (a is long && b is long) return (long)a == (long)b;
                if (a is long) return (double)b >= Int64.MinValue && (double)b < 9223372036854775808.0 && (double)b == Math.Truncate((double)b) && (long)a == (long)(double)b;
                if (b is long) return Equal(b, a);
            }
            return a.Equals(b);
        }
        private static string Quote(string value) {
            StringBuilder result = new StringBuilder("\"");
            foreach (char c in value) {
                if (c == '"' || c == '\\') result.Append('\\').Append(c);
                else if (c < 0x20) result.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                else result.Append(c);
            }
            return result.Append('"').ToString();
        }
        private static string Apply(string text, List<Edit> edits) {
            edits.Sort(delegate(Edit a, Edit b) { return b.Start.CompareTo(a.Start); });
            foreach (Edit edit in edits) text = text.Substring(0, edit.Start) + edit.Text + text.Substring(edit.End);
            // Validate the edited document through this same parser, never a second JSONC dialect.
            Parser.Read(text); return text;
        }
        private static int LineStart(string text, int position) {
            while (position > 0 && text[position - 1] != '\n' && text[position - 1] != '\r') position--;
            return position;
        }
        private static bool Horizontal(string text) {
            foreach (char c in text) if (c != ' ' && c != '\t') return false;
            return true;
        }
        private static string Insert(Document document, Node node, string name, string value) {
            string text = document.Text;
            int close = node.End - 1, start = LineStart(text, close);
            string closingIndent = text.Substring(start, close - start);
            bool multiline = start > node.Start && Horizontal(closingIndent);
            string indent = closingIndent + "  ";
            string colonSpace = " ";
            if (node.Members.Count > 0) {
                Member first = node.Members[0];
                int firstLine = LineStart(text, first.Start);
                string candidate = text.Substring(firstLine, first.Start - firstLine);
                if (firstLine > node.Start && Horizontal(candidate)) indent = candidate;
                candidate = text.Substring(first.ColonStart + 1, first.Value.Start - first.ColonStart - 1);
                if (Horizontal(candidate)) colonSpace = candidate;
            }
            List<Edit> edits = new List<Edit>();
            Member last = node.Members.Count > 0 ? node.Members[node.Members.Count - 1] : null;
            string fragment = Quote(name) + ":" + colonSpace + value + (last != null && last.CommaStart >= 0 ? "," : "");
            if (multiline) fragment = indent + fragment + document.Format.NewLine;
            else if (last != null && close > 0 && !Char.IsWhiteSpace(text[close - 1]) && text[close - 1] != ',') fragment = " " + fragment;
            int position = multiline ? start : close;
            if (last != null && last.CommaStart < 0) {
                if (last.End == position) fragment = "," + fragment;
                else edits.Add(new Edit { Start = last.End, End = last.End, Text = "," });
            }
            edits.Add(new Edit { Start = position, End = position, Text = fragment });
            return Apply(text, edits);
        }
        public static string Set(string text, string[] path, string jsonValue) {
            CheckPath(path);
            Document document = Parser.Read(text);
            Node desired = Parser.Read(jsonValue).Root;
            Node current = document.Root;
            for (int i = 0; i < path.Length; i++) {
                if (current.Kind != "object") throw new JsoncException("CLIENT_JSONC_EXPECTED_OBJECT", "edited path traverses a non-object");
                Member member = Find(current, path[i]);
                if (member == null) {
                    for (int child = path.Length - 1; child > i; child--) jsonValue = "{" + Quote(path[child]) + ":" + jsonValue + "}";
                    return Insert(document, current, path[i], jsonValue);
                }
                if (i == path.Length - 1) {
                    if (Equal(member.Value.Value, desired.Value)) return text;
                    return Apply(text, new List<Edit> { new Edit { Start = member.Value.Start, End = member.Value.End, Text = jsonValue } });
                }
                current = member.Value;
            }
            return text;
        }
        public static string Remove(string text, string[] path) {
            CheckPath(path);
            Document document = Parser.Read(text);
            Node current = document.Root;
            for (int i = 0; i < path.Length; i++) {
                if (current.Kind != "object") return text;
                Member member = Find(current, path[i]);
                if (member == null) return text;
                if (i == path.Length - 1) {
                    List<Edit> edits = new List<Edit> { new Edit { Start = member.Start, End = member.End, Text = "" } };
                    int comma = member.CommaStart;
                    int index = current.Members.IndexOf(member);
                    if (comma < 0 && index > 0) comma = current.Members[index - 1].CommaStart;
                    if (comma >= 0) edits.Add(new Edit { Start = comma, End = comma + 1, Text = "" });
                    return Apply(text, edits);
                }
                current = member.Value;
            }
            return text;
        }
    }
}
'@
}

function Read-ItlJsoncDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    Initialize-ItlJsoncRuntime
    return [Itl.Jsonc.Parser]::Read($Text)
}

function Set-ItlJsoncObjectProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][AllowNull()][string[]]$PropertyPath,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][AllowEmptyCollection()][object]$Value
    )
    Initialize-ItlJsoncRuntime
    $json = if ($null -eq $Value) { 'null' } else { ConvertTo-Json -InputObject $Value -Depth 100 -Compress }
    return [Itl.Jsonc.Editor]::Set($Text, $PropertyPath, [string]$json)
}

function Remove-ItlJsoncObjectProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][AllowNull()][string[]]$PropertyPath
    )
    Initialize-ItlJsoncRuntime
    return [Itl.Jsonc.Editor]::Remove($Text, $PropertyPath)
}
