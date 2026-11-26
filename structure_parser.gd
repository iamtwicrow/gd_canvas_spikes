@tool
extends RefCounted
## Tier-1 structural parser for GDScript (spike).
##
## Guarantees:
##  * Lossless: every physical line belongs to exactly one segment, in order,
##    so concatenating the segments reproduces the file byte for byte.
##  * Never fails: unknown constructs become STATEMENT / OPAQUE segments that
##    keep their exact text. Problems are reported in `diagnostics`.
##
## It does NOT parse expressions (that is the Tier-2 job).
## Results are stored as parallel packed arrays, one entry per segment.

enum Kind {
	BLANK, COMMENT, DOC_COMMENT, ANNOTATION, CLASS_NAME, EXTENDS, INNER_CLASS,
	SIGNAL, ENUM, CONST, VAR, FUNC, IF, ELIF, ELSE, FOR, WHILE, MATCH,
	MATCH_BRANCH, ACCESSOR, RETURN, BREAK, CONTINUE, PASS, STATEMENT, OPAQUE,
}

# ---- Result -------------------------------------------------------------
var lines: PackedStringArray = PackedStringArray()
var first_line: PackedInt32Array = PackedInt32Array()
var last_line: PackedInt32Array = PackedInt32Array()
var kind: PackedInt32Array = PackedInt32Array()
var indent: PackedInt32Array = PackedInt32Array()   # visual width, tab = 4
var parent: PackedInt32Array = PackedInt32Array()   # segment index, -1 = root
var depth: PackedInt32Array = PackedInt32Array()
var is_header: PackedByteArray = PackedByteArray()  # opens an indented block
var has_annotation: PackedByteArray = PackedByteArray()
var names: PackedStringArray = PackedStringArray()
var diagnostics: PackedStringArray = PackedStringArray()

# ---- Scanner state (carried across physical lines of one logical line) ---
var _special: RegEx = RegEx.new()
var _depth: int = 0
var _str: String = ""      # active string delimiter ("", ", ', """, ''')
var _cont: bool = false    # trailing backslash continuation

# ---- Classifier scratch ---------------------------------------------------
var _c_name: String = ""
var _c_word: String = ""
var _c_ann: bool = false


func _init() -> void:
	# Characters the scanner must look at: quotes, '#', brackets, backslash.
	var err: Error = _special.compile("[\"'#()\\[\\]{}\\\\]")
	assert(err == OK)


func segment_count() -> int:
	return first_line.size()


func kind_name(k: int) -> String:
	return Kind.keys()[k]


func text_of(from_line: int, to_line: int) -> String:
	return "\n".join(lines.slice(from_line, to_line + 1))


func reassemble() -> String:
	var parts: PackedStringArray = PackedStringArray()
	for s: int in first_line.size():
		parts.append(text_of(first_line[s], last_line[s]))
	return "\n".join(parts)


func _reset() -> void:
	lines = PackedStringArray()
	first_line.clear()
	last_line.clear()
	kind.clear()
	indent.clear()
	parent.clear()
	depth.clear()
	is_header.clear()
	has_annotation.clear()
	names.clear()
	diagnostics.clear()


func parse(text: String) -> void:
	_reset()
	lines = text.split("\n", true)
	var n: int = lines.size()
	var stack_seg: Array[int] = []
	var stack_ind: Array[int] = []
	var pending: Array[int] = []   # trivia segments waiting for a parent
	var i: int = 0
	while i < n:
		var line: String = lines[i]
		var lead: int = line.length() - line.lstrip(" \t").length()
		var body: String = line.substr(lead)

		# ---- run of blank lines
		if body.is_empty() or body == "\r":
			var jb: int = i
			while jb + 1 < n and _is_blank(lines[jb + 1]):
				jb += 1
			pending.append(_add(Kind.BLANK, i, jb, 0, false, false, ""))
			i = jb + 1
			continue

		# ---- run of comment lines with the same indentation
		if body.begins_with("#"):
			var jc: int = i
			while jc + 1 < n:
				var nl: String = lines[jc + 1]
				var nlead: int = nl.length() - nl.lstrip(" \t").length()
				if nlead == lead and nl.substr(nlead).begins_with("#"):
					jc += 1
				else:
					break
			var ck: int = Kind.DOC_COMMENT if body.begins_with("##") else Kind.COMMENT
			pending.append(_add(ck, i, jc, _width(line, lead), false, false, ""))
			i = jc + 1
			continue

		# ---- code: one logical line (may span several physical lines)
		var w: int = _width(line, lead)
		_depth = 0
		_str = ""
		_cont = false
		var cpos: int = _scan(line, lead)
		var last: int = i
		while (_depth > 0 or _str != "" or _cont) and last + 1 < n:
			if _depth > 0 and _str == "" and _looks_toplevel(lines[last + 1]):
				diagnostics.append("line %d: unbalanced bracket, resynchronised at line %d" % [i + 1, last + 2])
				break
			last += 1
			cpos = _scan(lines[last], 0)
		if last + 1 >= n and (_depth > 0 or _str != ""):
			diagnostics.append("line %d: unterminated bracket or string at end of file" % (i + 1))

		var tail: String = lines[last]
		if cpos >= 0:
			tail = tail.substr(0, cpos)
		var header: bool = tail.strip_edges(false, true).ends_with(":")

		var k: int = _classify(body)

		# Attach trivia (blank/comment lines) that precede this statement.
		for p: int in pending:
			var eff: int = w
			if kind[p] != Kind.BLANK:
				eff = maxi(indent[p], w)
			parent[p] = _find_parent(stack_ind, stack_seg, eff)
			depth[p] = 0 if parent[p] < 0 else depth[parent[p]] + 1
		pending.clear()

		while not stack_ind.is_empty() and stack_ind.back() >= w:
			stack_ind.pop_back()
			stack_seg.pop_back()
		var par: int = -1
		if not stack_seg.is_empty():
			par = stack_seg.back()

		if par >= 0 and header and kind[par] == Kind.MATCH:
			k = Kind.MATCH_BRANCH
		elif par >= 0 and kind[par] == Kind.VAR and k == Kind.STATEMENT and (_c_word == "get" or _c_word == "set"):
			k = Kind.ACCESSOR

		var idx: int = _add(k, i, last, w, header, _c_ann, _c_name)
		parent[idx] = par
		depth[idx] = 0 if par < 0 else depth[par] + 1
		if header:
			stack_seg.append(idx)
			stack_ind.append(w)
		i = last + 1

	# Trivia at end of file.
	for p: int in pending:
		var eff_eof: int = 0
		if kind[p] != Kind.BLANK:
			eff_eof = indent[p]
		parent[p] = _find_parent(stack_ind, stack_seg, eff_eof)
		depth[p] = 0 if parent[p] < 0 else depth[parent[p]] + 1


# ---- Scanner --------------------------------------------------------------
## Scans one physical line starting at `from`, updating scanner state.
## Returns the index of a '#' that starts a comment, or -1.
func _scan(line: String, from: int) -> int:
	var pos: int = from
	var n: int = line.length()
	_cont = false
	while pos < n:
		var m: RegExMatch = _special.search(line, pos)
		if m == null:
			break
		var i: int = m.get_start()
		var c: String = line[i]
		if _str != "":
			if c == "\\":
				pos = i + 2
			elif c == _str[0]:
				if _str.length() == 3:
					if line.substr(i, 3) == _str:
						_str = ""
						pos = i + 3
					else:
						pos = i + 1
				else:
					_str = ""
					pos = i + 1
			else:
				pos = i + 1
			continue
		if c == "#":
			return i
		elif c == "\"" or c == "'":
			var triple: String = c + c + c
			if line.substr(i, 3) == triple:
				_str = triple
				pos = i + 3
			else:
				_str = c
				pos = i + 1
		elif c == "(" or c == "[" or c == "{":
			_depth += 1
			pos = i + 1
		elif c == ")" or c == "]" or c == "}":
			_depth = maxi(_depth - 1, 0)
			pos = i + 1
		else:  # backslash outside a string
			if i + 1 >= n or (i + 2 == n and line[i + 1] == "\r"):
				_cont = true
			pos = i + 1
	if _str.length() == 1:
		_str = ""  # unterminated single-line string: recover at end of line
	return -1


func _looks_toplevel(line: String) -> bool:
	return line.begins_with("func ") or line.begins_with("static func ") \
		or line.begins_with("class ") or line.begins_with("signal ") \
		or line.begins_with("const ") or line.begins_with("enum ") \
		or line.begins_with("var ")


# ---- Classifier -------------------------------------------------------------
func _classify(body: String) -> int:
	_c_name = ""
	_c_word = ""
	_c_ann = false
	var n: int = body.length()
	var p: int = 0
	while p < n and body[p] == "@":
		var e: int = _ident_end(body, p + 1)
		if e == p + 1:
			return Kind.OPAQUE
		_c_ann = true
		p = _skip_ws(body, e)
		if p < n and body[p] == "(":
			p = _skip_parens(body, p)
			if p < 0:
				return Kind.ANNOTATION  # arguments continue on later lines
			p = _skip_ws(body, p)
	if p >= n or body[p] == "#":
		return Kind.ANNOTATION if _c_ann else Kind.STATEMENT
	return _keyword_kind(body.substr(p) if p > 0 else body)


func _keyword_kind(s: String) -> int:
	var e: int = _ident_end(s, 0)
	if e == 0:
		if "$%([{\"'&^-+~!.".contains(s[0]):
			return Kind.STATEMENT
		return Kind.OPAQUE
	var w: String = s.substr(0, e)
	_c_word = w
	match w:
		"class_name":
			_c_name = _name_after(s, e)
			return Kind.CLASS_NAME
		"extends":
			return Kind.EXTENDS
		"class":
			_c_name = _name_after(s, e)
			return Kind.INNER_CLASS
		"signal":
			_c_name = _name_after(s, e)
			return Kind.SIGNAL
		"enum":
			_c_name = _name_after(s, e)
			return Kind.ENUM
		"const":
			_c_name = _name_after(s, e)
			return Kind.CONST
		"var":
			_c_name = _name_after(s, e)
			return Kind.VAR
		"func":
			_c_name = _name_after(s, e)
			return Kind.FUNC
		"static":
			var rest: String = s.substr(_skip_ws(s, e))
			if rest.is_empty():
				return Kind.OPAQUE
			return _keyword_kind(rest)
		"if":
			return Kind.IF
		"elif":
			return Kind.ELIF
		"else":
			return Kind.ELSE
		"for":
			return Kind.FOR
		"while":
			return Kind.WHILE
		"match":
			return Kind.MATCH
		"return":
			return Kind.RETURN
		"break":
			return Kind.BREAK
		"continue":
			return Kind.CONTINUE
		"pass":
			return Kind.PASS
	return Kind.STATEMENT


func _name_after(s: String, from: int) -> String:
	var st: int = _skip_ws(s, from)
	var en: int = _ident_end(s, st)
	return s.substr(st, en - st)


func _ident_end(s: String, from: int) -> int:
	var i: int = from
	var n: int = s.length()
	while i < n:
		var c: int = s.unicode_at(i)
		if (c >= 97 and c <= 122) or (c >= 65 and c <= 90) or (c >= 48 and c <= 57) or c == 95 or c > 127:
			i += 1
		else:
			break
	return i


func _skip_ws(s: String, from: int) -> int:
	var i: int = from
	var n: int = s.length()
	while i < n and (s[i] == " " or s[i] == "\t"):
		i += 1
	return i


## `s[p]` must be "(". Returns the index after the matching ")", or -1.
func _skip_parens(s: String, p: int) -> int:
	var d: int = 0
	var i: int = p
	var n: int = s.length()
	var q: String = ""
	while i < n:
		var c: String = s[i]
		if q != "":
			if c == "\\":
				i += 2
				continue
			if c == q:
				q = ""
		elif c == "\"" or c == "'":
			q = c
		elif c == "(":
			d += 1
		elif c == ")":
			d -= 1
			if d == 0:
				return i + 1
		elif c == "#":
			break
		i += 1
	return -1


# ---- Helpers ----------------------------------------------------------------
func _add(k: int, first: int, last: int, ind: int, header: bool, ann: bool, nm: String) -> int:
	first_line.append(first)
	last_line.append(last)
	kind.append(k)
	indent.append(ind)
	parent.append(-1)
	depth.append(0)
	is_header.append(1 if header else 0)
	has_annotation.append(1 if ann else 0)
	names.append(nm)
	return first_line.size() - 1


func _width(line: String, lead: int) -> int:
	if lead == 0:
		return 0
	return lead + 3 * line.substr(0, lead).count("\t")


func _is_blank(line: String) -> bool:
	var s: String = line.lstrip(" \t")
	return s.is_empty() or s == "\r"


func _find_parent(stack_ind: Array[int], stack_seg: Array[int], eff: int) -> int:
	var k: int = stack_ind.size() - 1
	while k >= 0:
		if stack_ind[k] < eff:
			return stack_seg[k]
		k -= 1
	return -1


# ---- Queries ------------------------------------------------------------------
## Index of the last segment in the subtree rooted at segment `s`.
func subtree_end(s: int) -> int:
	var e: int = s
	var n: int = first_line.size()
	while e + 1 < n and parent[e + 1] >= s:
		e += 1
	return e


## Root-level declarations, each with its subtree and any directly preceding
## comment/annotation lines. Returns [{first, last, kind, name}, ...] (line indices).
func top_level_blocks() -> Array:
	var out: Array = []
	var carry: int = -1
	var carry_last: int = -1
	var n: int = first_line.size()
	var s: int = 0
	while s < n:
		if parent[s] != -1:
			s += 1
			continue
		var k: int = kind[s]
		if k == Kind.BLANK:
			if carry >= 0:
				out.append({"first": carry, "last": carry_last, "kind": Kind.COMMENT, "name": ""})
				carry = -1
			s += 1
			continue
		if k == Kind.COMMENT or k == Kind.DOC_COMMENT or k == Kind.ANNOTATION:
			if carry < 0:
				carry = first_line[s]
			carry_last = last_line[s]
			s += 1
			continue
		var e: int = subtree_end(s)
		var start: int = carry if carry >= 0 else first_line[s]
		out.append({"first": start, "last": last_line[e], "kind": k, "name": names[s]})
		carry = -1
		s = e + 1
	if carry >= 0:
		out.append({"first": carry, "last": carry_last, "kind": Kind.COMMENT, "name": ""})
	return out


## Checks the structural invariants. Empty result = healthy.
func validate() -> PackedStringArray:
	var errs: PackedStringArray = PackedStringArray()
	var n: int = first_line.size()
	var expect: int = 0
	for s: int in n:
		if first_line[s] != expect:
			errs.append("segment %d starts at line %d, expected %d" % [s, first_line[s], expect])
		if last_line[s] < first_line[s]:
			errs.append("segment %d has an inverted line range" % s)
		expect = last_line[s] + 1
		var p: int = parent[s]
		if p >= s:
			errs.append("segment %d has parent %d that does not precede it" % [s, p])
		elif p >= 0:
			if is_header[p] == 0:
				errs.append("segment %d has non-header parent %d" % [s, p])
			var k: int = kind[s]
			var trivia: bool = k == Kind.BLANK or k == Kind.COMMENT or k == Kind.DOC_COMMENT
			if not trivia and indent[s] <= indent[p]:
				errs.append("segment %d is not indented deeper than parent %d" % [s, p])
	if expect != lines.size():
		errs.append("segments cover %d of %d lines" % [expect, lines.size()])
	return errs
