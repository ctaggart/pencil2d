// Minimal XML parser for Pencil2D main.xml files.
// Supports: elements, attributes, text content, nesting.
// Does NOT support: CDATA, DTD, namespaces, entities beyond &amp; &lt; &gt; &quot; &apos;

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Attribute = struct {
    name: []const u8,
    value: []const u8,
};

pub const Element = struct {
    tag: []const u8,
    attributes: []Attribute,
    children: []Element,
    text: ?[]const u8,

    pub fn attr(self: Element, name: []const u8) ?[]const u8 {
        for (self.attributes) |a| {
            if (std.mem.eql(u8, a.name, name)) return a.value;
        }
        return null;
    }

    pub fn attrInt(self: Element, name: []const u8, default: i32) i32 {
        const val = self.attr(name) orelse return default;
        return std.fmt.parseInt(i32, val, 10) catch default;
    }

    pub fn attrFloat(self: Element, name: []const u8, default: f64) f64 {
        const val = self.attr(name) orelse return default;
        return std.fmt.parseFloat(f64, val) catch default;
    }

    /// Find first child element with given tag name.
    pub fn findChild(self: Element, tag: []const u8) ?*const Element {
        for (self.children) |*child| {
            if (std.mem.eql(u8, child.tag, tag)) return child;
        }
        return null;
    }

    /// Iterate children with a given tag name.
    pub fn childrenByTag(self: Element, tag: []const u8) ChildIterator {
        return .{ .children = self.children, .tag = tag, .index = 0 };
    }

    pub const ChildIterator = struct {
        children: []Element,
        tag: []const u8,
        index: usize,

        pub fn next(self: *ChildIterator) ?*const Element {
            while (self.index < self.children.len) {
                const i = self.index;
                self.index += 1;
                if (std.mem.eql(u8, self.children[i].tag, self.tag)) {
                    return &self.children[i];
                }
            }
            return null;
        }
    };
};

pub const Document = struct {
    root: Element,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn parse(allocator: Allocator, xml: []const u8) !Document {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var parser = Parser{ .src = xml, .pos = 0, .alloc = arena.allocator() };
    // Skip XML declaration <?xml ... ?>
    parser.skipWhitespace();
    while (parser.pos < parser.src.len and parser.peek() == '<') {
        if (parser.startsWith("<?")) {
            parser.skipPastStr("?>");
        } else if (parser.startsWith("<!")) {
            parser.skipPastStr(">");
        } else {
            break;
        }
        parser.skipWhitespace();
    }
    const root = try parser.parseElement();
    return .{ .root = root, .arena = arena };
}

const Parser = struct {
    src: []const u8,
    pos: usize,
    alloc: Allocator,

    fn peek(self: Parser) u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else 0;
    }

    fn advance(self: *Parser) u8 {
        if (self.pos < self.src.len) {
            const c = self.src[self.pos];
            self.pos += 1;
            return c;
        }
        return 0;
    }

    fn startsWith(self: Parser, prefix: []const u8) bool {
        if (self.pos + prefix.len > self.src.len) return false;
        return std.mem.eql(u8, self.src[self.pos..][0..prefix.len], prefix);
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.src.len and isSpace(self.src[self.pos])) self.pos += 1;
    }

    fn skipPastStr(self: *Parser, needle: []const u8) void {
        if (std.mem.indexOfPos(u8, self.src, self.pos, needle)) |idx| {
            self.pos = idx + needle.len;
        } else {
            self.pos = self.src.len;
        }
    }

    fn isSpace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r';
    }

    fn parseName(self: *Parser) []const u8 {
        const start = self.pos;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (isSpace(c) or c == '=' or c == '>' or c == '/' or c == '<') break;
            self.pos += 1;
        }
        return self.src[start..self.pos];
    }

    fn parseAttrValue(self: *Parser) ![]const u8 {
        const quote = self.advance(); // consume " or '
        if (quote != '"' and quote != '\'') return error.InvalidXml;
        const start = self.pos;
        while (self.pos < self.src.len and self.src[self.pos] != quote) self.pos += 1;
        const raw = self.src[start..self.pos];
        if (self.pos < self.src.len) self.pos += 1; // consume closing quote
        return self.unescapeXml(raw);
    }

    fn unescapeXml(self: *Parser, s: []const u8) ![]const u8 {
        if (std.mem.indexOf(u8, s, "&") == null) return s;
        var buf: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < s.len) {
            if (s[i] == '&') {
                if (std.mem.startsWith(u8, s[i..], "&amp;")) {
                    try buf.append(self.alloc, '&');
                    i += 5;
                } else if (std.mem.startsWith(u8, s[i..], "&lt;")) {
                    try buf.append(self.alloc, '<');
                    i += 4;
                } else if (std.mem.startsWith(u8, s[i..], "&gt;")) {
                    try buf.append(self.alloc, '>');
                    i += 4;
                } else if (std.mem.startsWith(u8, s[i..], "&quot;")) {
                    try buf.append(self.alloc, '"');
                    i += 6;
                } else if (std.mem.startsWith(u8, s[i..], "&apos;")) {
                    try buf.append(self.alloc, '\'');
                    i += 6;
                } else {
                    try buf.append(self.alloc, s[i]);
                    i += 1;
                }
            } else {
                try buf.append(self.alloc, s[i]);
                i += 1;
            }
        }
        return buf.items;
    }

    fn parseText(self: *Parser) !?[]const u8 {
        self.skipWhitespace();
        if (self.pos >= self.src.len or self.peek() == '<') return null;
        const start = self.pos;
        while (self.pos < self.src.len and self.src[self.pos] != '<') self.pos += 1;
        const raw = std.mem.trim(u8, self.src[start..self.pos], &[_]u8{ ' ', '\t', '\n', '\r' });
        if (raw.len == 0) return null;
        const unescaped = try self.unescapeXml(raw);
        return @as(?[]const u8, unescaped);
    }

    fn parseElement(self: *Parser) !Element {
        self.skipWhitespace();
        if (self.peek() != '<') return error.InvalidXml;
        self.pos += 1; // skip <
        const tag = self.parseName();

        // Parse attributes
        var attrs: std.ArrayList(Attribute) = .empty;
        while (true) {
            self.skipWhitespace();
            if (self.pos >= self.src.len) break;
            if (self.peek() == '/' or self.peek() == '>') break;
            const attr_name = self.parseName();
            if (attr_name.len == 0) break;
            self.skipWhitespace();
            if (self.peek() == '=') {
                self.pos += 1; // skip =
                self.skipWhitespace();
                const attr_val = try self.parseAttrValue();
                try attrs.append(self.alloc, .{ .name = attr_name, .value = attr_val });
            }
        }

        // Self-closing?
        if (self.peek() == '/') {
            self.pos += 1; // skip /
            if (self.peek() == '>') self.pos += 1; // skip >
            return .{
                .tag = tag,
                .attributes = attrs.items,
                .children = &.{},
                .text = null,
            };
        }

        if (self.peek() == '>') self.pos += 1; // skip >

        // Parse children and text
        var children: std.ArrayList(Element) = .empty;
        var text: ?[]const u8 = null;

        while (self.pos < self.src.len) {
            self.skipWhitespace();
            if (self.pos >= self.src.len) break;

            if (self.startsWith("</")) {
                // Closing tag
                self.pos += 2;
                self.skipPastStr(">");
                break;
            }

            if (self.peek() == '<') {
                if (self.startsWith("<!--")) {
                    self.skipPastStr("-->");
                    continue;
                }
                try children.append(self.alloc, try self.parseElement());
            } else {
                text = try self.parseText();
            }
        }

        return .{
            .tag = tag,
            .attributes = attrs.items,
            .children = children.items,
            .text = text,
        };
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "parse simple element" {
    const xml = "<root><child name=\"hello\"/></root>";
    var doc = try parse(std.testing.allocator, xml);
    defer doc.deinit();

    try std.testing.expectEqualStrings("root", doc.root.tag);
    try std.testing.expectEqual(@as(usize, 1), doc.root.children.len);
    try std.testing.expectEqualStrings("child", doc.root.children[0].tag);
    try std.testing.expectEqualStrings("hello", doc.root.children[0].attr("name").?);
}

test "parse pencil2d main.xml structure" {
    const xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<document>
        \\  <object>
        \\    <layer id="1" name="Background" visibility="1" type="1">
        \\      <image frame="1" src="001.001.png" topLeftX="-64" topLeftY="-64" opacity="1"/>
        \\      <image frame="5" src="001.005.png" topLeftX="0" topLeftY="0"/>
        \\    </layer>
        \\    <layer id="2" name="Camera" visibility="1" type="5" width="800" height="600">
        \\      <camera frame="1" r="0" s="1" dx="0" dy="0"/>
        \\      <camera frame="10" r="45" s="1.5" dx="100" dy="50" easing="1"/>
        \\    </layer>
        \\  </object>
        \\  <version>0.7.2</version>
        \\</document>
    ;

    var doc = try parse(std.testing.allocator, xml);
    defer doc.deinit();

    try std.testing.expectEqualStrings("document", doc.root.tag);

    // Object
    const obj = doc.root.findChild("object").?;
    var layer_iter = obj.childrenByTag("layer");

    // Layer 1: bitmap
    const l1 = layer_iter.next().?;
    try std.testing.expectEqual(@as(i32, 1), l1.attrInt("id", 0));
    try std.testing.expectEqualStrings("Background", l1.attr("name").?);
    try std.testing.expectEqual(@as(i32, 1), l1.attrInt("type", 0));

    var img_iter = l1.childrenByTag("image");
    const img1 = img_iter.next().?;
    try std.testing.expectEqual(@as(i32, 1), img1.attrInt("frame", 0));
    try std.testing.expectEqualStrings("001.001.png", img1.attr("src").?);
    try std.testing.expectEqual(@as(i32, -64), img1.attrInt("topLeftX", 0));
    try std.testing.expectEqual(@as(f64, 1.0), img1.attrFloat("opacity", 0));

    const img2 = img_iter.next().?;
    try std.testing.expectEqual(@as(i32, 5), img2.attrInt("frame", 0));

    // Layer 2: camera
    const l2 = layer_iter.next().?;
    try std.testing.expectEqual(@as(i32, 5), l2.attrInt("type", 0));
    try std.testing.expectEqual(@as(i32, 800), l2.attrInt("width", 0));

    var cam_iter = l2.childrenByTag("camera");
    const cam1 = cam_iter.next().?;
    try std.testing.expectEqual(@as(f64, 0), cam1.attrFloat("r", -1));
    const cam2 = cam_iter.next().?;
    try std.testing.expectEqual(@as(f64, 45), cam2.attrFloat("r", 0));
    try std.testing.expectEqual(@as(f64, 1.5), cam2.attrFloat("s", 0));
    try std.testing.expectEqual(@as(i32, 1), cam2.attrInt("easing", 0));

    // Version
    const ver = doc.root.findChild("version").?;
    try std.testing.expectEqualStrings("0.7.2", ver.text.?);
}

test "parse xml entities" {
    const xml = "<root attr=\"a&amp;b\">x &lt; y</root>";
    var doc = try parse(std.testing.allocator, xml);
    defer doc.deinit();

    try std.testing.expectEqualStrings("a&b", doc.root.attr("attr").?);
    try std.testing.expectEqualStrings("x < y", doc.root.text.?);
}

test "parse empty document" {
    const xml = "<empty/>";
    var doc = try parse(std.testing.allocator, xml);
    defer doc.deinit();

    try std.testing.expectEqualStrings("empty", doc.root.tag);
    try std.testing.expectEqual(@as(usize, 0), doc.root.children.len);
    try std.testing.expect(doc.root.text == null);
}
