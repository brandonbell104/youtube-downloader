import Foundation

/// Pulls individual functions out of YouTube's `base.js`.
///
/// The file is a couple of megabytes of minified, regularly-reshuffled code,
/// so nothing here assumes a fixed shape beyond a few anchors. Functions are
/// located by a distinctive anchor and then delimited by brace matching, which
/// survives the internals being rewritten. Everything returns `nil` rather
/// than throwing: an extraction miss degrades the download, it doesn't break
/// the app.
enum PlayerScriptParser {
    struct Snippet {
        /// Self-contained JavaScript, ready to evaluate.
        var source: String
        /// Name of the function to call inside that source.
        var entryPoint: String
    }

    // MARK: - Small values

    /// e.g. `/s/player/8e7a3f21/player_ias.vflset/en_US/base.js` -> `8e7a3f21`
    static func playerID(in source: String) -> String? {
        firstMatch(#"player\\?/([a-zA-Z0-9_-]{6,})\\?/"#, in: source, group: 1)
    }

    static func signatureTimestamp(in source: String) -> Int? {
        firstMatch(#"(?:signatureTimestamp|sts)\s*[:=]\s*(\d{5,})"#, in: source, group: 1).flatMap { Int($0) }
    }

    // MARK: - Signature shuffle

    /// Finds `xy=function(a){a=a.split("");Zq.Ab(a,3);…;return a.join("")}`
    /// plus the helper object (`Zq`) whose methods it calls.
    static func signatureFunction(in source: String) -> Snippet? {
        let patterns = [
            #"([a-zA-Z0-9_$]+)\s*=\s*function\(\s*([a-zA-Z0-9_$]+)\s*\)\s*\{\s*\2\s*=\s*\2\.split\(\s*(?:""|'')\s*\)\s*;"#,
            #"([a-zA-Z0-9_$]+)\s*=\s*function\(\s*([a-zA-Z0-9_$]+)\s*\)\s*\{\s*\2\s*=\s*\2\.split\(\s*\2\.slice\(0\s*,\s*0\)\s*\)\s*;"#,
        ]

        for pattern in patterns {
            guard let match = firstMatchRanges(pattern, in: source), match.count > 1,
                  let nameRange = match[1] else { continue }
            let name = String(source[nameRange])

            guard let braceIndex = source[match[0]!.lowerBound...].firstIndex(of: "{"),
                  let body = balancedBraces(in: source, openingAt: braceIndex) else { continue }

            guard let keyword = source.range(
                of: "function",
                range: match[0]!.lowerBound..<braceIndex
            ) else { continue }

            let functionText = String(source[keyword.lowerBound..<body.upperBound])
            let bodyText = String(source[body])

            var pieces: [String] = []
            if let helper = helperObject(usedIn: bodyText, source: source) {
                pieces.append(helper)
            }
            pieces.append("var \(name)=\(functionText);")

            return Snippet(source: pieces.joined(separator: "\n"), entryPoint: name)
        }
        return nil
    }

    /// The shuffle helpers live in an object literal like
    /// `var Zq={Ab:function(a,b){…},reverse:function(a){…}};`
    private static func helperObject(usedIn body: String, source: String) -> String? {
        guard let name = firstMatch(#"[;\s{(]([a-zA-Z0-9_$]{1,4})\.[a-zA-Z0-9_$]{1,4}\("#, in: body, group: 1) else {
            return nil
        }
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard let declaration = firstMatchRanges(#"var\s+\#(escaped)\s*=\s*\{"#, in: source),
              let range = declaration[0],
              let braceIndex = source[range].firstIndex(of: "{"),
              let literal = balancedBraces(in: source, openingAt: braceIndex) else {
            return nil
        }
        return "var \(name)=\(source[literal]);"
    }

    // MARK: - n parameter transform

    /// The throttling transform is the only function in the file that mentions
    /// `enhanced_except` (its own bail-out marker), which makes it easy to find
    /// even as the surrounding code churns.
    static func nTransformFunction(in source: String) -> Snippet? {
        let anchors = ["enhanced_except", "String.prototype.split.call", "-_w8_"]

        for anchor in anchors {
            guard let anchorRange = source.range(of: anchor) else { continue }
            guard let keyword = source.range(
                of: "function",
                options: .backwards,
                range: source.startIndex..<anchorRange.lowerBound
            ) else { continue }

            guard let braceIndex = source[keyword.upperBound...].firstIndex(of: "{"),
                  let body = balancedBraces(in: source, openingAt: braceIndex),
                  body.upperBound > anchorRange.upperBound else { continue }

            let functionText = String(source[keyword.lowerBound..<body.upperBound])
            let bodyText = String(source[body])
            let name = declaredName(before: keyword.lowerBound, in: source) ?? "ytdlpHubNTransform"
            let globals = globalDeclarations(referencedIn: bodyText, source: source, excluding: keyword.lowerBound)

            var pieces = globals
            pieces.append("var \(name)=\(functionText);")
            return Snippet(source: pieces.joined(separator: "\n"), entryPoint: name)
        }
        return nil
    }

    /// Reads the identifier in `foo=function(…)` or `var foo=function(…)`,
    /// scanning left from the `function` keyword.
    private static func declaredName(before index: String.Index, in source: String) -> String? {
        var cursor = index
        // Skip whitespace back to the assignment operator.
        while cursor > source.startIndex {
            let previous = source.index(before: cursor)
            if source[previous].isWhitespace { cursor = previous } else { break }
        }
        guard cursor > source.startIndex else { return nil }
        let equals = source.index(before: cursor)
        guard source[equals] == "=" else { return nil }

        var end = equals
        while end > source.startIndex {
            let previous = source.index(before: end)
            if source[previous].isWhitespace { end = previous } else { break }
        }
        var start = end
        while start > source.startIndex {
            let previous = source.index(before: start)
            guard isIdentifierCharacter(source[previous]) else { break }
            start = previous
        }
        guard start < end else { return nil }
        let name = String(source[start..<end])
        return name.first.map { $0.isNumber } == true ? nil : name
    }

    /// Recent players hoist lookup tables the transform depends on into
    /// file-level `var`s. Pull in any that the body actually references.
    private static func globalDeclarations(
        referencedIn body: String,
        source: String,
        excluding functionStart: String.Index
    ) -> [String] {
        let pattern = #"(?:^|[;\n])\s*var\s+([a-zA-Z0-9_$]{1,4})\s*=\s*("(?:[^"\\]|\\.){0,200}"\s*\.\s*split\(\s*"[^"]{0,20}"\s*\)|\[[^\[\]]{0,40000}\])\s*;"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }

        let nsSource = source as NSString
        let searchLimit = min(nsSource.length, source.distanceInUTF16(to: functionStart))
        var declarations: [String] = []
        var seen = Set<String>()

        regex.enumerateMatches(
            in: source,
            options: [],
            range: NSRange(location: 0, length: searchLimit)
        ) { match, _, _ in
            guard let match, match.numberOfRanges > 2 else { return }
            let name = nsSource.substring(with: match.range(at: 1))
            guard !seen.contains(name), references(body, identifier: name) else { return }
            seen.insert(name)
            declarations.append("var \(name)=\(nsSource.substring(with: match.range(at: 2)));")
        }
        return declarations
    }

    private static func references(_ body: String, identifier: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: identifier)
        return firstMatchRanges(#"[^a-zA-Z0-9_$]\#(escaped)[^a-zA-Z0-9_$]"#, in: body) != nil
    }

    // MARK: - Utilities

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "$"
    }

    /// Returns the range *inside* a `{ … }` pair, honouring nesting, strings
    /// and escapes. Minified JavaScript puts braces inside string literals, so
    /// a naive counter would run off the end.
    static func balancedBraces(in source: String, openingAt index: String.Index) -> Range<String.Index>? {
        guard source[index] == "{" else { return nil }

        var depth = 0
        var cursor = index
        var quote: Character?
        var escaped = false

        while cursor < source.endIndex {
            let character = source[cursor]

            if escaped {
                escaped = false
            } else if let active = quote {
                if character == "\\" {
                    escaped = true
                } else if character == active {
                    quote = nil
                }
            } else if character == "\"" || character == "'" || character == "`" {
                quote = character
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return source.index(after: index)..<cursor
                }
            }

            cursor = source.index(after: cursor)
        }
        return nil
    }

    static func firstMatch(_ pattern: String, in source: String, group: Int) -> String? {
        guard let ranges = firstMatchRanges(pattern, in: source),
              group < ranges.count,
              let range = ranges[group] else { return nil }
        return String(source[range])
    }

    /// Runs `pattern` and returns the matched ranges, index 0 being the whole
    /// match. Elements are `nil` for groups that did not participate.
    static func firstMatchRanges(_ pattern: String, in source: String) -> [Range<String.Index>?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, options: [], range: range) else { return nil }
        return (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: source) }
    }
}

private extension String {
    /// UTF-16 offset of `index`, which is what `NSRange` counts in.
    func distanceInUTF16(to index: String.Index) -> Int {
        utf16.distance(from: utf16.startIndex, to: index)
    }
}
