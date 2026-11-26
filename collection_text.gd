@tool
extends RefCounted
## Pure text logic for the enum and dictionary form editors (no UI, no engine
## state). Turns GDScript source into editable rows and rows back into valid
## GDScript, so people never have to type braces, commas, quotes or colons.
##
## Enum rows:   {"name": String, "value": String}          value "" = automatic
## Dict rows:   {"kt": int, "k": String, "vt": int, "v": String}
## Dict value kinds: T_TEXT (plain words, quotes added for you), T_NUM,
## T_BOOL (true / false) and T_CODE (any GDScript expression, kept as typed).

const T_TEXT: int = 0
const T_NUM: int = 1
const T_BOOL: int = 2
const T_CODE: int = 3

const TYPE_NAMES: Array[String] = ["Text", "Num", "Bool", "Code"]


# ---- Shared scanning helpers ---------------------------------------------------
## Splits `text` on `sep` (one character) at nesting depth 0, outside quotes.
static func split_top(text: String, sep: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var depth: int = 0
	var quote: String = ""
	var cur: String = ""
	var i: int = 0
	while i < text.length():
		var ch: String = text[i]
		if quote != "":
			if ch == "\\" and i + 1 < text.length():
				cur += ch + text[i + 1]
				i += 2
				continue
			if ch == quote:
				quote = ""
		elif ch == "\"" or ch == "'":
			quote = ch
		elif ch == "(" or ch == "[" or ch == "{":
			depth += 1
		elif ch == ")" or ch == "]" or ch == "}":
			depth -= 1
		elif ch == sep and depth == 0:
			out.append(cur)
			cur = ""
			i += 1
			continue
		cur += ch
		i += 1
	out.append(cur)
	return out


## Index of the first `ch` at depth 0 outside quotes, -1 if there is none.
static func find_top(text: String, ch: String) -> int:
	var depth: int = 0
	var quote: String = ""
	var i: int = 0
	while i < text.length():
		var c: String = text[i]
		if quote != "":
			if c == "\\":
				i += 2
				continue
			if c == quote:
				quote = ""
		elif c == "\"" or c == "'":
			quote = c
		elif c == "(" or c == "[" or c == "{":
			depth += 1
		elif c == ")" or c == "]" or c == "}":
			depth -= 1
		elif c == ch and depth == 0:
			return i
		i += 1
	return -1


## True when `ch` appears outside any quoted string.
static func has_outside_quotes(text: String, ch: String) -> bool:
	var quote: String = ""
	var i: int = 0
	while i < text.length():
		var c: String = text[i]
		if quote != "":
			if c == "\\":
				i += 2
				continue
			if c == quote:
				quote = ""
		elif c == "\"" or c == "'":
			quote = c
		elif c == ch:
			return true
		i += 1
	return false


## Letters, digits and underscores only; spaces and dashes become underscores;
## a leading digit gets an underscore in front. Never returns invalid GDScript.
static func sanitize_ident(s: String) -> String:
	var out: String = ""
	var t: String = s.strip_edges()
	for i: int in t.length():
		var ch: String = t[i]
		var c: int = ch.unicode_at(0)
		var ok: bool = (c >= 48 and c <= 57) or (c >= 65 and c <= 90) \
			or (c >= 97 and c <= 122) or c == 95
		if ok:
			out += ch
		elif ch == " " or ch == "-":
			out += "_"
	if out != "":
		var f: int = out.unicode_at(0)
		if f >= 48 and f <= 57:
			out = "_" + out
	return out


## Enum member style: MY_VALUE. Mixed-case input ("myValue", "My Value") is
## converted; names that are already upper case are left alone.
static func member_name(s: String) -> String:
	var t: String = sanitize_ident(s)
	if t == "":
		return ""
	if t != t.to_upper():
		t = t.to_snake_case().to_upper()
	return t


## Enum / class style name: letters, digits, underscores, no spaces.
static func enum_name(s: String) -> String:
	var parts: PackedStringArray = s.strip_edges().split(" ", false)
	if parts.size() > 1:
		var joined: String = ""
		for p: String in parts:
			joined += p.substr(0, 1).to_upper() + p.substr(1)
		return sanitize_ident(joined)
	return sanitize_ident(s)


# ---- Enums -------------------------------------------------------------------
## Parses `enum Name { A, B = 2 }` (one line or many). Result:
## {"ok": bool, "name": String, "members": Array[Dictionary]}. Enums that carry
## comments or unusual member shapes are reported as not ok so the caller can
## fall back to the plain code view instead of losing anything.
static func parse_enum(body: String) -> Dictionary:
	var bad: Dictionary = {"ok": false, "name": "", "members": []}
	var t: String = body.strip_edges()
	if not t.begins_with("enum") or t.contains("#"):
		return bad
	var o: int = t.find("{")
	var c: int = t.rfind("}")
	if o < 0 or c < o or t.substr(c + 1).strip_edges() != "":
		return bad
	var head: String = t.substr(4, o - 4).strip_edges()
	if head != "" and sanitize_ident(head) != head:
		return bad
	var members: Array = []
	for item: String in split_top(t.substr(o + 1, c - o - 1), ","):
		var s: String = item.strip_edges()
		if s == "":
			continue
		var eq: int = s.find("=")
		var mname: String = s if eq < 0 else s.substr(0, eq).strip_edges()
		var mval: String = "" if eq < 0 else s.substr(eq + 1).strip_edges()
		if mname == "" or sanitize_ident(mname) != mname:
			return bad
		if eq >= 0 and mval == "":
			return bad
		members.append({"name": mname, "value": mval})
	return {"ok": true, "name": head, "members": members}


## Multi-line enum source (the style the node already displays).
static func build_enum(ename: String, members: Array) -> String:
	var lines: PackedStringArray = PackedStringArray()
	lines.append(("enum %s {" % ename) if ename != "" else "enum {")
	for m: Dictionary in members:
		var mv: String = clean_enum_value(String(m.get("value", "")))
		lines.append("\t%s%s," % [String(m["name"]), (" = " + mv) if mv != "" else ""])
	lines.append("}")
	return "\n".join(lines)


## Member value text without characters that would break the enum syntax.
static func clean_enum_value(v: String) -> String:
	var out: String = v
	for bad: String in [",", "{", "}", "#", "=", "\n", "\t", "\"", "'", ";"]:
		out = out.replace(bad, "")
	return out.strip_edges()


## The number each member will actually get ("" when it cannot be known, i.e.
## the value is an expression such as `1 << 2`). Mirrors GDScript: automatic
## members count up from the previous one, starting at 0.
static func enum_numbers(members: Array) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var next: int = 0
	var known: bool = true
	for m: Dictionary in members:
		var v: String = clean_enum_value(String(m.get("value", "")))
		if v == "":
			out.append(str(next) if known else "")
			next += 1
		elif v.is_valid_int():
			next = v.to_int()
			known = true
			out.append(str(next))
			next += 1
		else:
			known = false
			out.append("")
	return out


## Names used more than once (exact match), for the duplicate warning.
static func duplicate_names(names: Array) -> Dictionary:
	var seen: Dictionary = {}
	var dup: Dictionary = {}
	for n: Variant in names:
		var s: String = str(n)
		if s == "":
			continue
		if seen.has(s):
			dup[s] = true
		seen[s] = true
	return dup


## A free enum name (NewEnum, NewEnum2, ...) given the names already in use.
static func unique_name(base: String, taken: Array) -> String:
	if not taken.has(base):
		return base
	var i: int = 2
	while taken.has("%s%d" % [base, i]):
		i += 1
	return "%s%d" % [base, i]


# ---- Dictionaries --------------------------------------------------------------
## Classifies a source fragment: {"t": kind, "text": what the form shows}.
## Text becomes plain words (quotes removed), anything that cannot be shown
## faithfully as Text / Num / Bool stays Code and is kept exactly as typed.
static func classify(src: String) -> Dictionary:
	var s: String = src.strip_edges()
	if s == "true" or s == "false":
		return {"t": T_BOOL, "text": s}
	if s != "" and not s.contains(" ") and (s.is_valid_int() or s.is_valid_float()):
		return {"t": T_NUM, "text": s}
	if s.length() >= 2 and s.begins_with("\"") and s.ends_with("\""):
		var plain: Dictionary = _unquote(s)
		if bool(plain["ok"]):
			return {"t": T_TEXT, "text": String(plain["text"])}
	return {"t": T_CODE, "text": s}


## Reads one double-quoted literal. Only the escapes the form itself writes
## (\" and \\) are understood; anything else (\n, \t, \u...) is not ok, so
## the piece stays as raw code and survives untouched.
static func _unquote(s: String) -> Dictionary:
	var inner: String = s.substr(1, s.length() - 2)
	var out: String = ""
	var i: int = 0
	while i < inner.length():
		var ch: String = inner[i]
		if ch == "\\":
			if i + 1 >= inner.length():
				return {"ok": false, "text": ""}
			var nx: String = inner[i + 1]
			if nx == "\"" or nx == "\\":
				out += nx
				i += 2
				continue
			return {"ok": false, "text": ""}
		if ch == "\"":
			return {"ok": false, "text": ""}   # an unescaped quote: not one literal
		out += ch
		i += 1
	return {"ok": true, "text": out}


## The GDScript for one form value.
static func value_source(kind: int, text: String) -> String:
	match kind:
		T_TEXT:
			return "\"" + text.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
		T_NUM:
			var n: String = text.strip_edges()
			return n if (n.is_valid_int() or n.is_valid_float()) else "0"
		T_BOOL:
			return "true" if text.strip_edges().to_lower() == "true" else "false"
		_:
			var c: String = text.strip_edges()
			return c if c != "" else "null"


## Whether the form text is a valid value of its kind (drives the red hint).
static func value_ok(kind: int, text: String) -> bool:
	match kind:
		T_NUM:
			var n: String = text.strip_edges()
			return n.is_valid_int() or n.is_valid_float()
		T_CODE:
			return text.strip_edges() != ""
		_:
			return true


## Parses a dictionary literal. {"ok": bool, "entries": Array[Dictionary]}.
## "" and "{}" are an empty dictionary. Anything that is not a plain literal
## (a variable name, a function call, text with comments) is not ok.
static func parse_dict(text: String) -> Dictionary:
	var bad: Dictionary = {"ok": false, "entries": []}
	var t: String = text.strip_edges()
	if t == "" or t == "{}":
		return {"ok": true, "entries": []}
	if not (t.begins_with("{") and t.ends_with("}")):
		return bad
	if has_outside_quotes(t, "#"):
		return bad
	var inner: String = t.substr(1, t.length() - 2)
	var entries: Array = []
	for item: String in split_top(inner, ","):
		var s: String = item.strip_edges()
		if s == "":
			continue
		var colon: int = find_top(s, ":")
		var ktext: String = ""
		var vtext: String = ""
		var lua: bool = false
		if colon >= 0:
			ktext = s.substr(0, colon).strip_edges()
			vtext = s.substr(colon + 1).strip_edges()
		else:
			# Lua-style `key = value`: the key is a plain name that means text
			var eq: int = find_top(s, "=")
			if eq < 0:
				return bad
			ktext = s.substr(0, eq).strip_edges()
			vtext = s.substr(eq + 1).strip_edges()
			if ktext == "" or sanitize_ident(ktext) != ktext:
				return bad
			lua = true
		if ktext == "" or vtext == "":
			return bad
		var k: Dictionary = {"t": T_TEXT, "text": ktext} if lua else classify(ktext)
		var v: Dictionary = classify(vtext)
		entries.append({"kt": int(k["t"]), "k": String(k["text"]),
			"vt": int(v["t"]), "v": String(v["text"])})
	return {"ok": true, "entries": entries}


## `{"a": 1, "b": true}` ("{}" when there are no entries).
static func build_dict(entries: Array) -> String:
	if entries.is_empty():
		return "{}"
	var parts: PackedStringArray = PackedStringArray()
	for e: Dictionary in entries:
		parts.append("%s: %s" % [
			value_source(int(e["kt"]), String(e["k"])),
			value_source(int(e["vt"]), String(e["v"]))])
	return "{" + ", ".join(parts) + "}"


## Keys used more than once, as their generated source text.
static func duplicate_keys(entries: Array) -> Dictionary:
	var srcs: Array = []
	for e: Dictionary in entries:
		srcs.append(value_source(int(e["kt"]), String(e["k"])))
	return duplicate_names(srcs)


# ---- Arrays ----------------------------------------------------------------------
## True when the `[` that starts `t` is closed by the very last character, so
## `[1, 2][0]` or `[1] + [2]` are not treated as one plain list.
static func _one_bracket_group(t: String) -> bool:
	if not (t.begins_with("[") and t.ends_with("]")):
		return false
	var depth: int = 0
	var quote: String = ""
	var i: int = 0
	while i < t.length():
		var ch: String = t[i]
		if quote != "":
			if ch == "\\":
				i += 2
				continue
			if ch == quote:
				quote = ""
		elif ch == "\"" or ch == "'":
			quote = ch
		elif ch == "(" or ch == "[" or ch == "{":
			depth += 1
		elif ch == ")" or ch == "]" or ch == "}":
			depth -= 1
			if depth == 0:
				return i == t.length() - 1
		i += 1
	return false


## Parses an array literal. {"ok": bool, "items": Array[Dictionary]} with
## items {"t": kind, "text": String} (same kinds as dictionary values).
## "" and "[]" are an empty array. Anything that is not a plain literal (a
## variable name, a function call, `PackedStringArray([...])`, text with
## comments) is not ok, so the caller keeps it as code.
static func parse_array(text: String) -> Dictionary:
	var bad: Dictionary = {"ok": false, "items": []}
	var t: String = text.strip_edges()
	if t == "" or t == "[]":
		return {"ok": true, "items": []}
	if not _one_bracket_group(t):
		return bad
	if has_outside_quotes(t, "#"):
		return bad
	var items: Array = []
	for piece: String in split_top(t.substr(1, t.length() - 2), ","):
		var s: String = piece.strip_edges()
		if s == "":
			continue
		var c: Dictionary = classify(s)
		items.append({"t": int(c["t"]), "text": String(c["text"])})
	return {"ok": true, "items": items}


## `[1, "two", true]` ("[]" when there are no items).
static func build_array(items: Array) -> String:
	if items.is_empty():
		return "[]"
	var parts: PackedStringArray = PackedStringArray()
	for it: Dictionary in items:
		parts.append(value_source(int(it["t"]), String(it["text"])))
	return "[" + ", ".join(parts) + "]"
