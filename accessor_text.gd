@tool
extends RefCounted
## Text logic for property accessors (`set(value):` / `get:`) on a member
## variable. Pure functions, no engine state, so they are unit-testable.
##
## The accessor block of a variable is stored dedented by one level (headers
## at column 0, bodies one level deeper):
##
##     set(val):
##     \tvar prev := charge
##     \tcharge = clampf(val, 0.0, MAX_CHARGE)
##     get:
##     \treturn charge
##
## parse() splits that text into a structured setter and getter; compose()
## rebuilds it. A block that cannot be represented exactly (comments between
## the accessors, a body on the header line, duplicate accessors, anything
## that is not set / get) is reported as not ok, and the caller keeps it
## verbatim, so nothing is ever lost or rewritten behind the user's back.

const DEFAULT_ARG: String = "value"


## Splits a dedented accessor block.
## Returns {ok, has_setter, setter_arg, setter_body, has_getter, getter_paren,
## getter_body, get_first, unit}. Bodies are dedented by their own first
## level (relative indentation inside is preserved); `unit` is that level's
## whitespace so compose() can re-create the original indentation.
static func parse(tail: String) -> Dictionary:
	var res: Dictionary = empty()
	if tail.strip_edges() == "":
		res["ok"] = true
		return res
	var lines: PackedStringArray = tail.split("\n")
	var re: RegEx = RegEx.new()
	re.compile("^(set|get)[ \\t]*(?:\\(([^)]*)\\))?[ \\t]*:[ \\t]*\\r?$")
	var cur: String = ""
	var cur_arg: String = ""
	var cur_paren: bool = false
	var cur_body: PackedStringArray = PackedStringArray()
	var order: PackedStringArray = PackedStringArray()
	var unit: String = ""
	var done: Array[Dictionary] = []
	for ln: String in lines:
		var lead: int = ln.length() - ln.lstrip(" \t").length()
		var blank: bool = ln.strip_edges() == ""
		if not blank and lead == 0:
			# a new accessor header
			if cur != "":
				done.append({"name": cur, "arg": cur_arg, "paren": cur_paren, "body": cur_body})
			var m: RegExMatch = re.search(ln)
			if m == null:
				return _bad()   # comment / inline body / not an accessor
			cur = m.get_string(1)
			cur_paren = m.get_string(0).contains("(")
			cur_arg = m.get_string(2).strip_edges()
			cur_body = PackedStringArray()
			continue
		if cur == "":
			return _bad()   # indented or blank text before the first header
		cur_body.append(ln)
		if unit == "" and not blank:
			unit = ln.substr(0, lead)
	if cur != "":
		done.append({"name": cur, "arg": cur_arg, "paren": cur_paren, "body": cur_body})
	var seen: Dictionary = {}
	for d: Dictionary in done:
		var nm: String = String(d["name"])
		if seen.has(nm):
			return _bad()   # duplicate accessor
		seen[nm] = true
		var body_lines: PackedStringArray = d["body"]
		# drop blank lines that trail the body (they belong to the gap after)
		var end: int = body_lines.size()
		while end > 0 and body_lines[end - 1].strip_edges() == "":
			end -= 1
		if end != body_lines.size():
			return _bad()   # trailing blanks would not round-trip exactly
		if end == 0:
			return _bad()   # empty accessor body
		var dedented: Dictionary = _dedent(body_lines, unit)
		if not bool(dedented["ok"]):
			return _bad()   # inconsistent indentation
		var text: String = String(dedented["text"])
		if nm == "set":
			res["has_setter"] = true
			res["setter_arg"] = String(d["arg"])
			res["setter_body"] = text
		else:
			res["has_getter"] = true
			res["getter_paren"] = bool(d["paren"])
			res["getter_body"] = text
	res["get_first"] = String(done[0]["name"]) == "get" and done.size() > 1
	res["unit"] = unit if unit != "" else "\t"
	res["ok"] = true
	return res


## Rebuilds the dedented accessor block from the structured parts. "" when
## neither accessor is enabled.
static func compose(d: Dictionary) -> String:
	var blocks: Array[String] = []
	var unit: String = String(d.get("unit", "\t"))
	if unit == "":
		unit = "\t"
	if bool(d.get("has_setter", false)):
		var arg: String = String(d.get("setter_arg", DEFAULT_ARG)).strip_edges()
		if arg == "":
			arg = DEFAULT_ARG
		blocks.append(_block("set(%s):" % arg, String(d.get("setter_body", "pass")), unit))
	if bool(d.get("has_getter", false)):
		var head: String = "get():" if bool(d.get("getter_paren", false)) else "get:"
		blocks.append(_block(head, String(d.get("getter_body", "pass")), unit))
	if blocks.size() == 2 and bool(d.get("get_first", false)):
		blocks.reverse()
	return "\n".join(blocks)


## The state of a variable that has no accessors.
static func empty() -> Dictionary:
	return {"ok": false, "has_setter": false, "setter_arg": DEFAULT_ARG,
		"setter_body": "", "has_getter": false, "getter_paren": false,
		"getter_body": "", "get_first": false, "unit": "\t"}


## A starter body for a freshly enabled accessor.
static func default_setter_body(var_name: String, arg: String) -> String:
	var a: String = arg if arg.strip_edges() != "" else DEFAULT_ARG
	return "%s = %s" % [var_name, a] if var_name != "" else "pass"


static func default_getter_body(var_name: String) -> String:
	return "return %s" % var_name if var_name != "" else "pass"


static func _block(head: String, body: String, unit: String) -> String:
	var outl: PackedStringArray = PackedStringArray([head])
	var text: String = body.strip_edges(false, true)
	if text.strip_edges() == "":
		text = "pass"
	for ln: String in text.split("\n"):
		outl.append(unit + _retab(ln, unit) if ln.strip_edges() != "" else "")
	return "\n".join(outl)


## The editor indents with tabs; a script indented with spaces gets the
## leading tabs of a body line converted, so the block never mixes the two.
static func _retab(ln: String, unit: String) -> String:
	if unit.begins_with("\t") or not ln.begins_with("\t"):
		return ln
	var n: int = ln.length() - ln.lstrip("\t").length()
	return unit.repeat(n) + ln.substr(n)


static func _dedent(body_lines: PackedStringArray, unit: String) -> Dictionary:
	var outl: PackedStringArray = PackedStringArray()
	for ln: String in body_lines:
		if ln.strip_edges() == "":
			outl.append("")
		elif ln.begins_with(unit):
			outl.append(ln.substr(unit.length()))
		else:
			return {"ok": false, "text": ""}
	return {"ok": true, "text": "\n".join(outl)}


static func _bad() -> Dictionary:
	var bad: Dictionary = empty()
	bad["ok"] = false
	return bad
