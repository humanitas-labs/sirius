import AppKit

// The few pieces of Markdown a toast renders, used sparingly: a line
// starting "- " (or "* ", "• ") is a bullet, **bold** is semibold, `code` is
// monospaced. Anything else, headings and links included, stays as typed.
// Agents are told to use a short list rarely (packaging/agent/instructions.md).
//
// A bullet hangs: its wrapped lines start under the text, not the dot, which
// is dimmer than the text. Items sit a little apart from each other and from
// the line above them.
// TODO(copy): the indent, dot colour and spacing are a first pass.
enum ToastText {
    static let bulletIndent: CGFloat = 15
    static let itemSpacing: CGFloat = 3
    static let dot = NSColor(white: 1, alpha: 0.45)

    // `lineHeight`, when given, sets every line to it, the text centred in
    // the line as CSS line-height does.
    static func attributed(_ text: String, font: NSFont, color: NSColor, lineHeight: CGFloat? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")
        var previousWasBullet = false
        for (index, line) in lines.enumerated() {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            var body = line
            let bullet = bulletBody(line)
            if let bullet {
                body = bullet
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: bulletIndent)]
                paragraph.headIndent = bulletIndent
                paragraph.paragraphSpacingBefore = index == 0 ? 0 : itemSpacing
            } else if previousWasBullet {
                paragraph.paragraphSpacingBefore = itemSpacing
            }
            previousWasBullet = bullet != nil
            let start = result.length
            if bullet != nil {
                result.append(NSAttributedString(string: "•\t", attributes: [.font: font, .foregroundColor: dot]))
            }
            result.append(inline(body, font: font, color: color))
            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: font, .foregroundColor: color]))
            }
            if let lineHeight {
                paragraph.minimumLineHeight = lineHeight
                paragraph.maximumLineHeight = lineHeight
            }
            result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: start, length: result.length - start))
        }
        // TextKit sets a taller line's baseline at its bottom less the
        // descent rounded up, all the extra height above the text; CSS puts
        // half above the ascent and half below the descent. The lift is the
        // difference, to the half point (one pixel at 2x): 1 at 14.6 on 21.
        if let lineHeight {
            let lift = (lineHeight - font.ascender - font.descender) / 2 - ceil(-font.descender)
            result.addAttribute(.baselineOffset, value: max(0, (lift * 2).rounded() / 2),
                                range: NSRange(location: 0, length: result.length))
        }
        return result
    }

    // A list that runs past `maxLines` at `width` keeps the lines that fit
    // whole, the last ending in an ellipsis; the label's own truncation drew
    // the last item without its indent (an agent sent eight bullets). Not a
    // "+N more", which says nothing useful; agents are
    // told never to send more than fits. Text without bullets, or a list
    // that fits, is returned as attributed() gives it.
    static func fitted(_ text: String, font: NSFont, color: NSColor, width: CGFloat, maxLines: Int,
                       lineHeight: CGFloat? = nil) -> NSAttributedString {
        let full = attributed(text, font: font, color: color, lineHeight: lineHeight)
        var lines = text.components(separatedBy: "\n")
        guard lines.contains(where: { bulletBody($0) != nil }) else { return full }
        let limit = height(attributed(Array(repeating: "x", count: maxLines).joined(separator: "\n"), font: font, color: color,
                                      lineHeight: lineHeight),
                           width: width) + CGFloat(maxLines - 1) * itemSpacing + 1
        guard height(full, width: width) > limit else { return full }
        while lines.count > 1 {
            lines.removeLast()
            var shown = lines
            shown[shown.count - 1] += "…"
            let kept = attributed(shown.joined(separator: "\n"), font: font, color: color, lineHeight: lineHeight)
            if height(kept, width: width) <= limit { return kept }
        }
        return full
    }

    static func height(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                               options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }

    // The line's text after its bullet marker, or nil when it is not a bullet.
    static func bulletBody(_ line: String) -> String? {
        let trimmed = line.drop { $0 == " " }
        for marker in ["- ", "* ", "• "] where trimmed.hasPrefix(marker) {
            return String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // **bold** and `code`; an unclosed marker stays as typed.
    static func inline(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let bold = NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)
        let code = NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.93, weight: .regular)
        let result = NSMutableAttributedString()
        var rest = Substring(text)
        func plain(_ s: Substring) {
            result.append(NSAttributedString(string: String(s), attributes: [.font: font, .foregroundColor: color]))
        }
        while !rest.isEmpty {
            let boldStart = rest.range(of: "**")
            let codeStart = rest.range(of: "`")
            let next = [boldStart, codeStart].compactMap { $0 }.min { $0.lowerBound < $1.lowerBound }
            guard let next else { plain(rest); break }
            let isBold = next == boldStart
            let marker = isBold ? "**" : "`"
            let after = rest[next.upperBound...]
            guard let close = after.range(of: marker), close.lowerBound > after.startIndex else {
                plain(rest[..<next.upperBound])
                rest = after
                continue
            }
            plain(rest[..<next.lowerBound])
            result.append(NSAttributedString(string: String(after[..<close.lowerBound]),
                                             attributes: [.font: isBold ? bold : code, .foregroundColor: color]))
            rest = after[close.upperBound...]
        }
        return result
    }
}
