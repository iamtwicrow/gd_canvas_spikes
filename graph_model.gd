@tool
extends RefCounted
## Node-graph model for the Visual Script workspace.
##
## The graph is derived from real GDScript through the existing structural
## parser (structure_parser.gd): execution connections represent the actual
## statement flow of the script (sequential chains, if/elif/else branches,
## loop bodies and completions, match branches, returns), and data
## connections represent real value dependencies (variables, parameters,
## literals, operators).
##
## The model never stores coordinates: positions are session-only view state.
## `generate()` converts the graph back into valid native GDScript.
var script_path: String = ""   # the file this graph represents (for call resolution)

## Problems discovered while emitting (call-target missing, unresolved
## functions). Cleared at every generate() and merged into its result.
var _emit_problems: PackedStringArray = PackedStringArray()

## ---- Diagnostics side-channel (passive) ------------------------------------
## Filled while generate() runs; it never influences the generated text.
## `_diag_items`: problems bound to a node, {node, severity, message, line}.
## `_line_marks`: which node emitted which element range of the output
## buffers ([segment, first, end(exclusive), node]); generate() turns them into
## a generated-line -> node table so compiler errors can be shown on the node
## that produced the offending line.
var _diag_items: Array[Dictionary] = []
var _line_marks: Array = []
var _seg_base: Dictionary = {}
var _cur_seg: int = 0
## Why the last can_connect_data() call failed ("" when it succeeded) — the
## canvas surfaces this as feedback instead of silently dropping the wire.
var last_reject_reason: String = ""

const Types = preload("graph_types.gd")
const Parser = preload("structure_parser.gd")
const FuncReg = preload("func_registry.gd")
const TypeReg = preload("type_registry.gd")
const AnnReg = preload("annotation_registry.gd")
const AccText = preload("accessor_text.gd")
const ClassReg = preload("class_registry.gd")

enum Kind {
	ENTRY, STATEMENT, IF, ELIF, WHILE, FOR, MATCH, RETURN, BREAK, CONTINUE,
	PASS, COMMENT, PREAMBLE, LITERAL, VARIABLE_GET, VARIABLE_SET, OPERATOR, PRINT,
	CALL, VAR_DECL, CONST_DECL, SIGNAL_DECL, DECLARATION, ARGUMENT, ANNOTATION,
	CLASS_NAME, EXTENDS_DECL, CLASS_REF, LAMBDA,
}

# Header color per kind (Unreal-Blueprint-like categorisation).
const KIND_COLORS: Dictionary[int, String] = {
	Kind.ENTRY: "#732828",
	Kind.STATEMENT: "#35393f",
	Kind.IF: "#75424e",
	Kind.ELIF: "#75424e",
	Kind.WHILE: "#75424e",
	Kind.FOR: "#75424e",
	Kind.MATCH: "#75424e",
	Kind.RETURN: "#75424e",
	Kind.BREAK: "#75424e",
	Kind.CONTINUE: "#75424e",
	Kind.PASS: "#75424e",
	Kind.COMMENT: "#3a3d44",
	Kind.PREAMBLE: "#3a3d44",
	Kind.CLASS_NAME: "#4a4a55",
	Kind.EXTENDS_DECL: "#4a4a55",
	Kind.LITERAL: "#2e5d46",
	Kind.VARIABLE_GET: "#2e5d46",
	Kind.VARIABLE_SET: "#2e5d46",
	Kind.OPERATOR: "#2e5d46",
	Kind.PRINT: "#284e73",
	Kind.CALL: "#284e73",
	Kind.VAR_DECL: "#2e5d46",
	Kind.CONST_DECL: "#2e5d46",
	Kind.SIGNAL_DECL: "#2e5d46",
	Kind.DECLARATION: "#3a3d44",
	Kind.ARGUMENT: "#3d6b5e",
	Kind.ANNOTATION: "#6d4fa1",
	Kind.CLASS_REF: "#4d5590",
	Kind.LAMBDA: "#2e5d5d",
}

const KIND_TITLES: Dictionary[int, String] = {
	Kind.ENTRY: "Event",
	Kind.STATEMENT: "Statement",
	Kind.IF: "If",
	Kind.ELIF: "Else If",
	Kind.WHILE: "While",
	Kind.FOR: "For",
	Kind.MATCH: "Match",
	Kind.RETURN: "Return",
	Kind.BREAK: "Break",
	Kind.CONTINUE: "Continue",
	Kind.PASS: "Pass",
	Kind.COMMENT: "Comment",
	Kind.PREAMBLE: "Script Header",
	Kind.CLASS_NAME: "Script Class Name",
	Kind.EXTENDS_DECL: "Script Extension",
	Kind.LITERAL: "Literal",
	Kind.VARIABLE_GET: "Get",
	Kind.VARIABLE_SET: "Set",
	Kind.OPERATOR: "Operator",
	Kind.PRINT: "Print",
	Kind.CALL: "Call",
	Kind.VAR_DECL: "Variable",
	Kind.CONST_DECL: "Constant",
	Kind.SIGNAL_DECL: "Signal",
	Kind.DECLARATION: "Declaration",
	Kind.ARGUMENT: "Argument",
	Kind.ANNOTATION: "Annotation",
	Kind.CLASS_REF: "Class Reference",
	Kind.LAMBDA: "Lambda",
}

# ---- Graph state -----------------------------------------------------------
## id -> node Dictionary (see _make_node for fields). No coordinates here.
var nodes: Dictionary = {}
## id -> {port:int -> to_id}. An exec output may feed several inputs.
var exec_out: Dictionary = {}
## id -> Array[{from_id:int, from_port:int}] (joins allowed, like Blueprint).
var exec_in: Dictionary = {}
## Array[{from_id, from_out, to_id, to_in}]. Data inputs hold one link.
var data_links: Array = []
## Annotation->Declaration registrations made through a declaration's
## "add annotation" input slot: {"tid": declaration id, "aid": annotation
## node id}. Like arg_links this is ownership, not value flow: the wire only
## visualises the association, the annotation text itself lives in the
## target's "annotations" field (or the header body for class targets).
var ann_links: Array = []
## Private-variable scope registrations made through a Variable's "scope"
## output pin into a scope-owning node's "add scope" input: {"vid": variable
## id, "tid": scope-owning node id}. Like arg_links/ann_links this is
## ownership, not value flow: the wire assigns the private variable to the
## scope it belongs to (function bodies and nested if/while/for blocks). The
## variable's normal value output keeps working independently.
var scope_links: Array = []
## Export-group associations made through an @export-family Annotation
## node's "add group" input into an @export_group node's "group" output:
## {"gid": group node id, "xid": export annotation node id}. Ownership, not
## value flow: the visible wire assigns the export to that Inspector group;
## generation emits the group's line before the first grouped variable.
var group_links: Array = []
## Script Header metadata registrations: a Script Class Name node and a
## Script Extension node connect to the header's dedicated "class name" and
## "extends" inputs: {"hid": header id, "nid": node id, "kind":
## "class_name" | "extends"}. Ownership, not value flow: the visible wire
## assigns the declaration to the header; the header body stores the line.
var header_links: Array = []
## Function->Argument registrations made through the Function's left-side
## argument pins: {"eid": entry id, "aid": argument id}. Kept separately from
## data_links: these are ownership links (no value flow, no pin indices), so
## reordering arguments never invalidates them.
var arg_links: Array = []
## Class Reference -> Member registrations made through a Class Reference
## node's "add member" input slot: {"rid": class ref id, "cid": member
## (Function Call) node id}. Like arg_links / ann_links this is ownership,
## not value flow: the wire links a member node to the class it belongs to.
## Generation uses the registered reference as the member's target when its
## own target pin is empty (instance members), so `Test_class.get_health()`
## materializes without an explicit wire. Every member node ALSO exposes a
## typed data output that wires into other nodes like any value.
var member_links: Array = []

## Ordered script roots: {text:String} for verbatim chunks, {entry:int} for funcs.
var roots: Array = []
var parse_diagnostics: PackedStringArray = PackedStringArray()

var _next_id: int = 1
var _pending_join: int = -1   # join node found by the current _emit_flow walk
var _chain_tail: int = -1     # continuation a chained Else If hands back to its If


func clear() -> void:
	nodes.clear()
	exec_out.clear()
	exec_in.clear()
	data_links.clear()
	arg_links.clear()
	ann_links.clear()
	scope_links.clear()
	group_links.clear()
	header_links.clear()
	roots.clear()
	parse_diagnostics = PackedStringArray()
	_next_id = 1
	_header_id = -1
	_current_entry = -1
	func_privates.clear()
	_block_stack.clear()
	_entry_iter_names.clear()
	_entry_iter_types.clear()
	_block_unsafe.clear()
	_entry_flow_locals.clear()


func node_count() -> int:
	return nodes.size()


func link_count() -> int:
	var n: int = data_links.size()
	for id: int in exec_out:
		n += exec_out[id].size()
	return n


# ---- Building from GDScript --------------------------------------------------
## Builds the graph from a GDScript source string. Returns parser diagnostics.
## Test hook: disables the parse-time annotation-node conversion.
static var _skip_ann_convert: bool = false
## Test hook: keeps parsed `set(v):` / `get:` blocks as verbatim text (the old
## behaviour) instead of turning them into Setter / Getter nodes.
static var _skip_accessor_nodes: bool = false

func build(text: String) -> PackedStringArray:
	clear()
	var p: Parser = Parser.new()
	p.parse(text)
	parse_diagnostics = p.diagnostics
	# Top-level code is classified by its GDScript syntax (see the structural
	# parser), never merely by position or indentation:
	#   extends / class_name / file-level annotations -> ONE Script Header node
	#   var -> Variable node, const -> Constant node, signal -> Signal node
	#   enum / inner class / unrecognized statements -> Declaration node (verbatim)
	#   a comment run right before a func/decl stays with that construct
	# Every node keeps its own source text and the original order of roots, so
	# generation preserves the script's meaning. Roots also record whether the
	# source had no blank line before the next block (`tight`), so generate()
	# can reproduce the original layout instead of inserting separators.
	var blocks: Array = p.top_level_blocks()
	for j: int in blocks.size():
		var b: Dictionary = blocks[j]
		var tight: bool = j + 1 < blocks.size() \
			and int(blocks[j + 1]["first"]) == int(b["last"]) + 1
		var k: int = int(b["kind"])
		if k == Parser.Kind.FUNC:
			var s: int = _segment_of_kind_in(p, int(b["first"]), int(b["last"]), Parser.Kind.FUNC)
			if s >= 0:
				# Lines carried in front of the function: the trailing run of
				# annotations attaches to the Function node (they belong to the
				# declaration); anything before that (comments, doc comments,
				# earlier annotation runs) stays in a verbatim node, keeping the
				# original order untouched.
				var carry: String = p.text_of(int(b["first"]), p.first_line[s] - 1)
				var csplit: Dictionary = _split_func_carry(carry)
				if str(csplit["rest"]).strip_edges() != "":
					_add_verbatim_node(str(csplit["rest"]), "Comment", true)
				_build_func(p, s, tight)
				nodes[_last_entry_id()]["fields"]["annotations"] = \
					"\n".join(csplit["anns"])
			continue
		var full: String = p.text_of(int(b["first"]), int(b["last"]))
		if full.strip_edges() == "":
			continue
		match k:
			Parser.Kind.EXTENDS, Parser.Kind.CLASS_NAME, Parser.Kind.ANNOTATION:
				_add_header_directive(full, tight)
			Parser.Kind.VAR:
				_add_var_decl(p, int(b["first"]), int(b["last"]), tight)
			Parser.Kind.CONST:
				_add_const_decl(p, int(b["first"]), int(b["last"]), tight)
			Parser.Kind.SIGNAL:
				_add_signal_decl(p, int(b["first"]), int(b["last"]), tight)
			Parser.Kind.COMMENT:
				_add_verbatim_node(full, "Comment", tight)
			_:
				_add_declaration(full, tight)
	# Deferred reconstruction: same-script function calls whose ENTRY node is
	# declared later in the file convert now that every function is known.
	for id: int in nodes:
		if int(nodes[id]["kind"]) == Kind.STATEMENT \
				and str(nodes[id]["body"]).strip_edges() != "":
			_try_call_statement(id, str(nodes[id]["body"]))
	_wire_variable_reads()
	if not _skip_ann_convert:
		_convert_parsed_annotations()
	return parse_diagnostics


## Segment index whose first line is `line` (-1 if none).
func _segment_starting_at(p: Parser, line: int) -> int:
	for s: int in p.segment_count():
		if p.first_line[s] == line:
			return s
	return -1


## Strips leading annotations ("@export", "@onready ...", "@tool") and an
## optional "static" keyword from a declaration line, returning the text that
## starts at "var" ("" when the line is not a var declaration).
func _strip_var_prefix(text: String) -> String:
	var s: String = text.strip_edges()
	var i: int = 0
	var n: int = s.length()
	while i < n:
		var lead: int = _skip_ws(s, i)
		i = lead
		if i < n and s[i] == "@":
			var e: int = _ident_end_like(s, i + 1)
			i = e
			if i < n and s[i] == "(":
				var d: int = 0
				while i < n:
					if s[i] == "(":
						d += 1
					elif s[i] == ")":
						d -= 1
						if d == 0:
							i += 1
							break
					i += 1
			continue
		if s.substr(_skip_ws(s, i)).begins_with("static "):
			i = _skip_ws(s, i) + 7
			continue
		break
	var rest: String = s.substr(_skip_ws(s, i))
	return rest if rest.begins_with("var ") or rest.begins_with("var\t") else ""


## The single Script Header node: file-level directives (extends, class_name,
## annotations) in source order. Never duplicated, never empty.
var _header_id: int = -1
var _current_entry: int = -1   # entry being parsed (for local-decl hoisting)
var _block_stack: Array[int] = []   # enclosing block-owning nodes during parse
var _entry_iter_names: Dictionary = {}   # FOR iterator names of the current entry
var _entry_iter_types: Dictionary = {}   # typed FOR iterators of the current entry: name -> type
var _block_unsafe: Dictionary = {}   # names that exist only inside flow blocks
var _entry_flow_locals: Dictionary = {}   # top-level locals (emit in flow, not at the top)
var _entry_scoped_names: Dictionary = {}   # names already hoisted for this entry
var func_privates: Dictionary[int, Array] = {}   # entry id -> private var node ids (declaration order)


func _add_header_directive(text: String, tight: bool = false) -> void:
	if _header_id < 0 or not nodes.has(_header_id):
		_header_id = _make_node(Kind.PREAMBLE)
		nodes[_header_id].title = "Script Header"
		# The header's "add annotation" input slot accepts class-level
		# annotation nodes (@tool, @icon, @abstract ...).
		# The dedicated "class name" / "extends" inputs match the
		# authorable header (add_node) so the metadata wires always have
		# a pin to land on, however the header was created.
		nodes[_header_id]["data_ins"] = [
			{"name": "class name", "type": Types.PinType.ANNOTATION, "value": ""},
			{"name": "extends", "type": Types.PinType.ANNOTATION, "value": ""},
			{"name": "add annotation", "type": Types.PinType.ANNOTATION, "value": ""},
		]
		roots.insert(0, {"node": _header_id})
	var body: String = String(nodes[_header_id]["body"])
	nodes[_header_id]["body"] = text.strip_edges() if body == "" else body + "\n" + text.strip_edges()
	for r: Dictionary in roots:
		if r.has("node") and int(r["node"]) == _header_id:
			r["tight"] = tight


func _add_var_decl(p: Parser, from_line: int, to_line: int, tight: bool = false) -> void:
	var vs: int = _segment_of_kind_in(p, from_line, to_line, Parser.Kind.VAR)
	if vs < 0:
		_add_verbatim_node(p.text_of(from_line, to_line), "Variable", tight)
		return
	var carry: String = "" if p.first_line[vs] <= from_line else p.text_of(from_line, p.first_line[vs] - 1)
	var decl: String = p.text_of(p.first_line[vs], p.last_line[vs]).strip_edges()
	# Inline placement (`@export var x = 1`) vs own lines above the
	# declaration is preserved so an untouched round trip keeps the style.
	var inline_anns: bool = decl.begins_with("@")
	var var_text: String = _strip_var_prefix(decl)
	var stmt: Dictionary = _parse_stmt(var_text) if var_text != "" else {}
	if stmt.is_empty():
		# Not a recognisable var declaration (e.g. accessor syntax): keep the
		# original source in a verbatim Declaration node.
		_add_verbatim_node(p.text_of(from_line, to_line), "Variable", tight)
		return
	var nid: int = _make_node(Kind.VAR_DECL)
	var decl_prefix: String = decl.substr(0, decl.length() - var_text.length()).strip_edges()
	var carry_spfx: Dictionary = _split_prefix(carry)
	var decl_spfx: Dictionary = _split_prefix(decl_prefix)
	var inline_ann_text: String = ""
	var all_anns: PackedStringArray = PackedStringArray()
	for a: String in carry_spfx["anns"]:
		all_anns.append(a)
	for a: String in decl_spfx["anns"]:
		all_anns.append(a)
	var is_static: bool = bool(carry_spfx["static"]) or bool(decl_spfx["static"])
	# Class-only annotations (e.g. @tool) must not attach to a variable even
	# if the parser grouped them into the same block; move them to the header.
	var class_only: PackedStringArray = PackedStringArray()
	var var_anns: PackedStringArray = PackedStringArray()
	for a: String in all_anns:
		var an: String = a.strip_edges().trim_prefix("@").split("(")[0].strip_edges()
		var ae: Dictionary = AnnReg.get_registry().find(an)
		if not ae.is_empty() and (ae["targets"] as Array).has("class") and not (ae["targets"] as Array).has("var"):
			class_only.append(a)
		else:
			var_anns.append(a)
	if not class_only.is_empty():
		for ca: String in class_only:
			_add_header_directive(ca, false)
		# Remove peeled class-only annotation lines from carry/decl_prefix,
		# preserving any other comments or formatting.
		var peeled: Dictionary = {}
		for ca2: String in class_only:
			peeled[ca2.strip_edges()] = true
		var new_carry: PackedStringArray = PackedStringArray()
		for ln: String in carry.split("\n"):
			if not peeled.has(ln.strip_edges()):
				new_carry.append(ln)
		carry = "\n".join(new_carry).trim_prefix("\n").trim_suffix("\n")
		var new_dp: PackedStringArray = PackedStringArray()
		for ln2: String in decl_prefix.split("\n"):
			if not peeled.has(ln2.strip_edges()):
				new_dp.append(ln2)
		decl_prefix = "\n".join(new_dp).strip_edges()
	var prefix: String = ""
	if carry.strip_edges() != "":
		prefix = carry.strip_edges()
	if decl_prefix.strip_edges() != "":
		prefix = (prefix + "\n" if prefix != "" else "") + decl_prefix.strip_edges()
	decl = (prefix + "\n" if prefix != "" else "") + var_text
	nodes[nid].body = decl
	var spfx: Dictionary = {"anns": var_anns, "static": is_static}
	# Structured fields for the property editor: name, raw type annotation
	# ("" = untyped, preserved as-is) and default value text.
	var var_body: String = var_text.trim_prefix("var").strip_edges()
	var vsp: Dictionary = _split_assign(var_body)
	var vname: String = ""
	var vraw: String = ""
	var vdefault: String = ""
	if not vsp.is_empty():
		vname = String(vsp["lhs"])
		vdefault = String(vsp["rhs"])
	else:
		# A declaration that opens an accessor block ends with a lone ":"
		# (`var p: int :`); that opener is not part of the name/type.
		vname = var_body.trim_suffix(":").strip_edges()
	var vcolon: int = _find_typed_colon(vname)
	if vcolon >= 0:
		vraw = vname.substr(vcolon + 1).strip_edges()
		vname = vname.substr(0, vcolon).strip_edges()
	if inline_anns:
		inline_ann_text = "\n".join(_split_prefix(decl_prefix)["anns"] as PackedStringArray)
	nodes[nid].fields = {"name": vname, "raw_type": vraw, "default": vdefault,
		"prefix": prefix, "annotations": "\n".join(var_anns),
		"is_static": is_static, "scope": "public", "owner": -1,
		"ann_inline": inline_anns, "inline_ann_text": inline_ann_text}
	nodes[nid].stmt = stmt
	nodes[nid].title = "var %s" % vname
	var vt: int = int(stmt.get("type", Types.VARIANT))
	# The Default Value pin row always exists (empty when the variable has no
	# default); a connected wire overrides the stored default at generation.
	nodes[nid].data_ins = [{"name": "value", "type": vt, "value": stmt.get("rhs", "")},
		{"name": "add annotation", "type": Types.PinType.ANNOTATION, "value": ""}]
	nodes[nid].data_outs = [{"name": stmt["name"], "type": vt}]
	# A declaration that opened an indented block in the source (lambda body,
	# property accessors) keeps that block verbatim; the trailing ":" that
	# opened it must not leak into the default value.
	var tail: String = _collect_tail(p, vs)
	if tail != "":
		nodes[nid].fields["tail"] = tail
		if String(stmt.get("rhs", "")).ends_with(":"):
			stmt["rhs"] = String(stmt["rhs"]).trim_suffix(":")
			stmt["has_value"] = true
		if String(nodes[nid].fields["default"]).ends_with(":"):
			nodes[nid].fields["default"] = String(nodes[nid].fields["default"]).trim_suffix(":")
			nodes[nid].data_ins[0]["value"] = stmt["rhs"]
	_var_sync_accessors(nid)
	_convert_var_lambda(nid)
	roots.append({"node": nid, "tight": tight})
	if not _skip_accessor_nodes:
		_convert_accessors_to_nodes(p, vs, nid)


## Top-level `const` block: verbatim body, data output pin for the name.
func _add_const_decl(p: Parser, from_line: int, to_line: int, tight: bool = false) -> void:
	var cs: int = _segment_of_kind_in(p, from_line, to_line, Parser.Kind.CONST)
	var body: String = p.text_of(from_line, to_line).strip_edges()
	var decl: String = p.text_of(p.first_line[cs], p.last_line[cs]).strip_edges() if cs >= 0 else ""
	var sp: Dictionary = _split_assign(decl.trim_prefix("const").strip_edges()) if decl != "" else {}
	var title: String = "Constant"
	var cname: String = ""
	if not sp.is_empty():
		cname = String(sp["lhs"]).strip_edges().split(":")[0].strip_edges()
		title = "const %s" % cname
	var nid: int = _make_node(Kind.CONST_DECL)
	nodes[nid].body = body
	nodes[nid].title = title
	if cname != "":
		nodes[nid].data_outs = [{"name": cname, "type": _annotation_type(String(sp["lhs"]))}]
	roots.append({"node": nid, "tight": tight})


## Signal block: verbatim body.
func _add_signal_decl(p: Parser, from_line: int, to_line: int, tight: bool = false) -> void:
	# Structured Signal node: name + argument list editable on the node;
	# generation rebuilds `signal name(args)` from the fields.
	var full: String = p.text_of(from_line, to_line).strip_edges()
	var rest: String = full.trim_prefix("signal").strip_edges()
	var open: int = rest.find("(")
	var sname: String = rest.substr(0, open).strip_edges() if open >= 0 else rest.strip_edges()
	var sargs: String = ""
	if open >= 0:
		var close: int = rest.rfind(")")
		if close > open:
			sargs = rest.substr(open + 1, close - open - 1).strip_edges()
	var nid: int = _make_node(Kind.SIGNAL_DECL)
	nodes[nid].fields = {"name": sname, "args": sargs}
	nodes[nid].body = full
	nodes[nid].title = "Signal"
	roots.append({"node": nid, "tight": tight})


## Unrecognized / unsupported top-level code (enum, inner class, stray
## statement...): its own Declaration node, source preserved verbatim.
func _add_declaration(text: String, tight: bool = false, _p: Parser = null) -> void:
	var first: String = text.strip_edges().split("\n")[0].strip_edges()
	var title: String = "Declaration"
	for kw: String in ["enum", "class"]:
		if first.begins_with(kw + " "):
			title = "%s %s" % [kw, _ident_after(first, kw)]
			break
	_add_verbatim_node(text, title)


## Creates a verbatim (read-only body) node of kind DECLARATION and registers
## it as a root so its source is regenerated in place.
func _add_verbatim_node(text: String, title: String, tight: bool = false) -> int:
	var nid: int = _make_node(Kind.DECLARATION)
	nodes[nid].body = text.strip_edges()
	nodes[nid].title = title
	roots.append({"node": nid, "tight": tight})
	return nid


## First segment of `kind` whose lines lie within [from_line, to_line].
func _segment_of_kind_in(p: Parser, from_line: int, to_line: int, kind: int) -> int:
	for s: int in p.segment_count():
		if p.first_line[s] >= from_line and p.last_line[s] <= to_line and int(p.kind[s]) == kind:
			return s
	return -1


## Identifier following keyword `kw` in `text` ("" if none).
func _ident_after(text: String, kw: String) -> String:
	var idx: int = text.find(kw)
	if idx < 0:
		return ""
	var rest: String = text.substr(idx + kw.length()).strip_edges()
	var e: int = _ident_end_like(rest, 0)
	return rest.substr(0, e)


func _ident_end_like(s: String, from: int) -> int:
	var i: int = from
	while i < s.length():
		var c: String = s[i]
		if (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c == "_":
			i += 1
		else:
			break
	return i


func _skip_ws(s: String, from: int) -> int:
	var i: int = from
	while i < s.length() and (s[i] == " " or s[i] == "\t"):
		i += 1
	return i


func _build_func(p: Parser, s: int, tight: bool = false) -> void:
	var eid: int = _make_node(Kind.ENTRY)
	var full: String = p.text_of(p.first_line[s], p.last_line[s])
	var sig: String = full.split("\n")[0].strip_edges().trim_suffix(":")
	var parsed: Dictionary = _parse_sig(sig)
	# One separate ARGUMENT node per function parameter (declaration order).
	var args: Array[int] = []
	for prm: Dictionary in parsed["params"]:
		var aid: int = _make_node(Kind.ARGUMENT)
		nodes[aid].fields = {
			"name": prm["name"], "type": prm["type"],
			"default": prm["default"], "parent": eid,
		}
		var at: int = Types.type_from_name(String(prm["type"])) if String(prm["type"]) != "" else Types.VARIANT
		# One data input (the value pin) and TWO outputs: the variable value
		# pin and the Function connection pin (the visible ownership wire to
		# the parent Function's registration slot).
		nodes[aid].data_ins = [
			{"name": prm["name"], "type": at, "value": ""},
		]
		nodes[aid].data_outs = [
			{"name": prm["name"], "type": at},
			{"name": "Function", "type": Types.VARIANT},
		]
		nodes[aid].title = "arg: %s" % prm["name"]
		args.append(aid)
	nodes[eid].fields = {
		"name": parsed["name"], "ret_type": parsed["ret"],
		"static": parsed["static"], "args": args,
	}
	# Parsed arguments own their Function connection link too, so the visible
	# ownership wire exists from the moment the script is opened.
	for aid2: int in args:
		arg_links.append({"eid": eid, "aid": aid2})
	nodes[eid].sig = sig
	nodes[eid].body = sig
	nodes[eid].title = _entry_title(bool(parsed["static"]), String(parsed["name"]))
	nodes[eid].exec_outs = ["\u25b6"]
	_entry_sync_pins(eid)
	roots.append({"entry": eid, "tight": tight})
	var kids: Array = _child_segs(p, s)
	_current_entry = eid
	func_privates[eid] = []
	_entry_iter_names.clear()
	_entry_iter_types.clear()
	_block_unsafe.clear()
	_entry_flow_locals.clear()
	_entry_scoped_names.clear()
	_block_stack.clear()
	_build_list(p, kids, {}, {"id": eid, "port": 0})
	_block_stack.clear()
	_entry_iter_names.clear()
	_entry_iter_types.clear()
	_block_unsafe.clear()
	_entry_flow_locals.clear()
	_entry_scoped_names.clear()
	_current_entry = -1


## Parses a function signature line (no trailing ":") into its structured
## parts: [static] func name(params) -> ret.
func _parse_sig(sig_line: String) -> Dictionary:
	var s: String = sig_line.strip_edges()
	var is_static: bool = s.begins_with("static ")
	if is_static:
		s = s.trim_prefix("static ").strip_edges()
	s = s.trim_prefix("func ").strip_edges()
	var lp: int = s.find("(")
	var fname: String = s.substr(0, lp).strip_edges() if lp > 0 else "my_func"
	var rp: int = s.rfind(")")
	var params_text: String = s.substr(lp + 1, rp - lp - 1) if rp > lp else ""
	var ret: String = ""
	if rp >= 0 and rp + 1 < s.length():
		var tail: String = s.substr(rp + 1).strip_edges()
		if tail.begins_with("->"):
			ret = tail.substr(2).strip_edges()
	var params: Array[Dictionary] = []
	for pt: String in _split_top_commas(params_text):
		var prm: Dictionary = _parse_param(pt)
		if not prm.is_empty():
			params.append(prm)
	return {"name": fname, "static": is_static, "ret": ret, "params": params}


## Splits a parameter list on commas that are outside brackets and strings.
func _split_top_commas(text: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var depth: int = 0
	var q: String = ""
	var cur: String = ""
	var i: int = 0
	while i < text.length():
		var c: String = text[i]
		if q != "":
			if c == "\\" and i + 1 < text.length():
				cur += text.substr(i, 2)
				i += 2
				continue
			if c == q:
				q = ""
			cur += c
		elif c == "\"" or c == "'":
			q = c
			cur += c
		elif c == "(" or c == "[" or c == "{":
			depth += 1
			cur += c
		elif c == ")" or c == "]" or c == "}":
			depth = maxi(depth - 1, 0)
			cur += c
		elif c == "," and depth == 0:
			if cur.strip_edges() != "":
				out.append(cur.strip_edges())
			cur = ""
		else:
			cur += c
		i += 1
	if cur.strip_edges() != "":
		out.append(cur.strip_edges())
	return out


## Parses one parameter: "name: T [= default]", "name [= default]",
## "name := default" (inferred). Returns {} for empty fragments.
func _parse_param(text: String) -> Dictionary:
	var s: String = text.strip_edges()
	if s == "":
		return {}
	var default: String = ""
	var eq: int = _find_assign_eq(s)
	if eq >= 0:
		default = s.substr(eq + 1).strip_edges()
		s = s.substr(0, eq).strip_edges()
	var colon: int = -1
	var depth: int = 0
	var q: String = ""
	var i: int = 0
	while i < s.length():
		var c: String = s[i]
		if q != "":
			if c == "\\":
				i += 2
				continue
			if c == q:
				q = ""
		elif c == "\"" or c == "'":
			q = c
		elif c == "(" or c == "[" or c == "{":
			depth += 1
		elif c == ")" or c == "]" or c == "}":
			depth = maxi(depth - 1, 0)
		elif c == ":" and depth == 0:
			if i + 1 >= s.length() or s[i + 1] != "=":
				colon = i
				break
		i += 1
	var pname: String = ""
	var ptype: String = ""
	if colon >= 0:
		pname = s.substr(0, colon).strip_edges()
		ptype = s.substr(colon + 1).strip_edges()
	else:
		pname = s.strip_edges()
	if pname == "":
		return {}
	return {"name": pname, "type": ptype, "default": default}


## Finds the default-value assignment '=' in a parameter fragment (depth 0,
## outside strings, not ==/!=/<=/>=).
func _find_assign_eq(s: String) -> int:
	var depth: int = 0
	var q: String = ""
	var i: int = 0
	while i < s.length():
		var c: String = s[i]
		if q != "":
			if c == "\\":
				i += 2
				continue
			if c == q:
				q = ""
		elif c == "\"" or c == "'":
			q = c
		elif c == "(" or c == "[" or c == "{":
			depth += 1
		elif c == ")" or c == "]" or c == "}":
			depth = maxi(depth - 1, 0)
		elif c == "=" and depth == 0:
			var prev: String = s[i - 1] if i > 0 else " "
			var nxt: String = s[i + 1] if i + 1 < s.length() else " "
			if prev != "=" and prev != "!" and prev != "<" and prev != ">" and nxt != "=":
				return i
		i += 1
	return -1


# ---- Lambda (Callable literal) support -------------------------------------

## True when a text begins like a lambda expression: `func` (or `func (...)`)
## immediately followed by a parameter list. Detection only — `func_name`
## identifiers do not match because no `(` follows the keyword.
func _looks_like_lambda_start(s: String) -> bool:
	var t: String = s.strip_edges()
	if not t.begins_with("func"):
		return false
	return t.substr(4).strip_edges().begins_with("(")


## Parses a lambda expression head — the first physical line of `func(...) -> T:
## body` — into {params, ret, inline}. `params` is the regular parameter
## record list ({name, type, default}); `ret` is the declared return type
## text ("" when the head has no `-> T`); `inline` is the single-line body
## after the colon ("" when the body continues on the following lines).
## Returns {} when the line is not a complete lambda head (a colon must close
## the head; a missing body is fine here — the caller decides).
func _split_lambda_head(line: String) -> Dictionary:
	var s: String = line.strip_edges()
	if not _looks_like_lambda_start(s):
		return {}
	var rest: String = s.substr(4).strip_edges()
	var close: int = _lambda_match_paren(rest, 0)
	if close < 0:
		return {}
	var params_text: String = rest.substr(1, close - 1)
	var after: String = rest.substr(close + 1).strip_edges()
	var ret: String = ""
	if after.begins_with("->"):
		var tail: String = after.substr(2).strip_edges()
		var colon: int = _find_typed_colon(tail)
		if colon >= 0:
			ret = tail.substr(0, colon).strip_edges()
			after = tail.substr(colon + 1)
		else:
			# Colon-less heads end right after the return type — the caller
			# supplies the body from an already-collected tail block.
			ret = tail
			after = ""
	elif after.begins_with(":"):
		after = after.substr(1)
	elif after != "":
		return {}   # junk after the parameter list: not a lambda head
	var params: Array[Dictionary] = []
	for pt: String in _split_top_commas(params_text):
		var prm: Dictionary = _parse_param(pt)
		if prm.is_empty() or not _valid_ident(str(prm["name"])):
			return {}
		params.append(prm)
	if ret.contains(" ") or ret.contains("\n"):
		return {}   # a garbage return annotation stays verbatim
	return {"params": params, "ret": ret, "inline": after.strip_edges()}


## Finds the `)` that closes the `(` at `open` in a lambda head (depth- and
## string-aware). Returns -1 when the head is broken.
func _lambda_match_paren(s: String, open: int) -> int:
	var depth: int = 0
	var q: String = ""
	var i: int = open
	while i < s.length():
		var c: String = s[i]
		if q != "":
			if c == "\\":
				i += 2
				continue
			if c == q:
				q = ""
		elif c == "\"" or c == "'":
			q = c
		elif c == "(" or c == "[" or c == "{":
			depth += 1
		elif c == ")" or c == "]" or c == "}":
			depth -= 1
			if depth == 0:
				return i
		i += 1
	return -1


## Parses a complete lambda expression (head + optional body lines on the
## following lines) into the Lambda node's fields: {params, ret, body} with
## the body dedented to its own base level (the relative-tab convention the
## emitters use). Returns {} when the text is not a reconstructible lambda
## (not a lambda, broken head, or no body at all).
func _parse_lambda_value(rhs: String) -> Dictionary:
	var s: String = rhs.strip_edges()
	if not _looks_like_lambda_start(s):
		return {}
	var lines: PackedStringArray = s.split("\n")
	var head: Dictionary = _split_lambda_head(lines[0])
	if head.is_empty():
		return {}
	var body_lines: PackedStringArray = PackedStringArray()
	var inline: String = str(head["inline"])
	if inline != "":
		body_lines.append(inline)
	for i: int in range(1, lines.size()):
		body_lines.append(lines[i])
	var body: String = _normalize_lambda_body("\n".join(body_lines))
	if body == "":
		return {}
	# Preserve the source's layout: a body that continued on following lines
	# regenerates as a block (the head colon reopens), an inline body stays
	# inline even when it is a single statement.
	return {"params": head["params"], "ret": head["ret"], "body": body,
		"block": lines.size() > 1}


## Dedents a lambda body's continuation lines to the body's base level:
## the shallowest non-empty line defines the base, inner extra tabs survive.
## Outer blank lines are dropped (they never survive emit anyway).
func _normalize_lambda_body(body: String) -> String:
	var lines: PackedStringArray = body.split("\n")
	while lines.size() > 0 and String(lines[0]).strip_edges() == "":
		lines.remove_at(0)
	while lines.size() > 0 and String(lines[lines.size() - 1]).strip_edges() == "":
		lines.remove_at(lines.size() - 1)
	if lines.is_empty():
		return ""
	var min_lead: int = -1
	for i: int in lines.size():
		var ln: String = String(lines[i])
		if ln.strip_edges() == "":
			continue
		var lead: int = ln.length() - ln.lstrip(" \t").length()
		if min_lead < 0 or lead < min_lead:
			min_lead = lead
	if min_lead > 0:
		for i: int in lines.size():
			lines[i] = _dedent_by_base(String(lines[i]), min_lead)
	return "\n".join(lines)


## The GDScript expression text of a Lambda node: single-line bodies inline
## after the head (`func(x: float) -> float: return x * 1.15`), multi-line
## bodies reopen the block and re-indent one level under the caller.
func _lambda_expr(lid: int) -> String:
	var f: Dictionary = nodes[lid]["fields"]
	var parts: PackedStringArray = PackedStringArray()
	for p: Dictionary in f.get("params", []):
		parts.append(str(p["name"]) + (": " + str(p["type"]) if str(p["type"]) != "" else "")
			+ (" = " + str(p["default"]) if str(p["default"]) != "" else ""))
	var head: String = "func(" + ", ".join(parts) + ")"
	if str(f.get("ret", "")) != "":
		head += " -> " + str(f["ret"])
	var body: String = str(f.get("body", "pass")).strip_edges()
	if body == "":
		body = "pass"
	if not body.contains("\n") and not bool(f.get("block", false)):
		return head + ": " + body
	return head + ":\n" + _reindent_tail(body, "")


## Spawns a Lambda node from parsed source text (a complete lambda value);
## returns the new node id, or -1 when the text is not a lambda.
func _spawn_lambda_from_text(text: String, depth: int) -> int:
	var lam: Dictionary = _parse_lambda_value(text)
	if lam.is_empty():
		return -1
	var lid: int = _make_node(Kind.LAMBDA, depth)
	nodes[lid]["fields"] = {"params": lam["params"], "ret": lam["ret"], "body": lam["body"],
		"block": bool(lam.get("block", false))}
	nodes[lid]["data_outs"] = [{"name": "Callable", "type": Types.PinType.CALLABLE}]
	_lambda_sync_title(lid)
	return lid


## Converts a structured statement's or declaration's value pin into a wired
## Lambda node when the stored text is a complete lambda expression. The
## pin's type already carries the callable class when parsed from source.
func _maybe_wire_lambda(id: int, rhs: String) -> int:
	var lid: int = _spawn_lambda_from_text(rhs, int(nodes[id].get("depth", 0)))
	if lid < 0:
		return -1
	data_links.append({"from_id": lid, "from_out": 0, "to_id": id, "to_in": 0})
	# the node's value pin is now fed by the Lambda node
	var pin: Dictionary = nodes[id]["data_ins"][0]
	pin["value"] = ""
	pin["type"] = Types.PinType.CALLABLE
	return lid


## Rebuilds a Lambda node's title from its signature so the node reads like
## the code it produces (`func(x: float) -> float`).
func _lambda_sync_title(lid: int) -> void:
	var f: Dictionary = nodes[lid]["fields"]
	var parts: PackedStringArray = PackedStringArray()
	for p: Dictionary in f.get("params", []):
		var pp: String = str(p["name"])
		if str(p.get("type", "")) != "":
			pp += ": " + str(p["type"])
		parts.append(pp)
	var head: String = "func(" + ", ".join(parts) + ")"
	if str(f.get("ret", "")) != "":
		head += " -> " + str(f["ret"])
	nodes[lid]["title"] = head


## Property edits for Lambda nodes: "ret", "body" and the composite
## "param:<i>:<name|type|default>" keys. Returns false when the edit is
## invalid (kept verbatim on the node instead of applied).
func set_lambda_prop(id: int, key: String, value: String) -> bool:
	if not nodes.has(id) or int(nodes[id]["kind"]) != Kind.LAMBDA:
		return false
	last_reject_reason = ""
	var f: Dictionary = nodes[id]["fields"]
	if key == "ret":
		var t: String = value.strip_edges()
		if t != "" and not _check_type_text(t):
			return false
		f["ret"] = t
	elif key == "body":
		f["body"] = _normalize_lambda_indent(value.strip_edges())
	elif key.begins_with("param:"):
		var parts: PackedStringArray = key.split(":")
		if parts.size() != 3:
			return false
		var idx: int = int(parts[1])
		var prms: Array = f.get("params", [])
		if idx < 0 or idx >= prms.size():
			return false
		match str(parts[2]):
			"name":
				var n: String = value.strip_edges()
				if not _check_param_name(n):
					return false
				for other: Dictionary in prms:
					if other != prms[idx] and str(other["name"]) == n:
						last_reject_reason = "Another parameter is already called '%s'." % n
						return false   # duplicate parameter name
				# renaming follows into the body and into later parameter defaults
				# (a person should not have to fix the code by hand)
				var old_name: String = str(prms[idx]["name"])
				prms[idx]["name"] = n
				if old_name != n:
					f["body"] = _replace_ident(old_name, n, str(f.get("body", "")))
					for pi: int in range(idx + 1, prms.size()):
						prms[pi]["default"] = _replace_ident(old_name, n, str(prms[pi].get("default", "")))
			"type":
				var tt: String = value.strip_edges()
				if tt != "" and not _check_type_text(tt):
					return false
				prms[idx]["type"] = tt
			"default":
				var dv: String = value.strip_edges()
				if dv != "" and not _check_single_expr(dv, false):
					return false
				prms[idx]["default"] = dv
			_:
				return false
	else:
		return false
	_lambda_sync_title(id)
	return true


## Adds a parameter row to a Lambda node (uniquely named `x`, `x2`, ...).
func add_lambda_param(id: int, base_name: String = "x") -> bool:
	if not nodes.has(id) or int(nodes[id]["kind"]) != Kind.LAMBDA:
		return false
	var prms: Array = nodes[id]["fields"].get("params", [])
	var name: String = base_name.strip_edges()
	if not _valid_ident(name):
		name = "x"
	var used: Dictionary = {}
	for p: Dictionary in prms:
		used[str(p["name"])] = true
	var nm: String = name
	var k: int = 2
	while used.has(nm):
		nm = name + str(k)
		k += 1
	prms.append({"name": nm, "type": "", "default": ""})
	nodes[id]["fields"]["params"] = prms
	_lambda_sync_title(id)
	return true


## Removes a parameter row from a Lambda node.
func remove_lambda_param(id: int, index: int) -> bool:
	if not nodes.has(id) or int(nodes[id]["kind"]) != Kind.LAMBDA:
		return false
	var prms: Array = nodes[id]["fields"].get("params", [])
	if index < 0 or index >= prms.size():
		return false
	prms.remove_at(index)
	_lambda_sync_title(id)
	return true


## The GDScript signature for an Event, built from its structured fields and
## its (ordered) Argument nodes.
## Node title for a Function (Event) node: parsed, spawned and renamed
## entries all share it so static functions stay recognisable on the graph.
func _entry_title(is_static: bool, fname: String) -> String:
	return ("Static Func: " if is_static else "Event: ") + fname


func _sig_text(eid: int) -> String:
	var n: Dictionary = nodes[eid]
	var fname: String = String(n["fields"].get("name", "my_func"))
	var params: PackedStringArray = PackedStringArray()
	for aid: int in n["fields"].get("args", []):
		if not nodes.has(aid):
			continue
		var a: Dictionary = nodes[aid]
		var aname: String = String(a["fields"].get("name", "arg"))
		var atype: String = String(a["fields"].get("type", "")).strip_edges()
		# The default value is the Argument's own text field; there is no
		# separate Default input pin it could be wired through.
		var adef: String = String(a["fields"].get("default", ""))
		var pstr: String = aname
		if atype != "":
			pstr += ": " + atype
		if adef != "":
			pstr += " = " + adef
		params.append(pstr)
	var sig: String = "func " + fname + "(" + ", ".join(params) + ")"
	if bool(n["fields"].get("static", false)):
		sig = "static " + sig
	var ret: String = String(n["fields"].get("ret_type", "")).strip_edges()
	if ret != "":
		sig += " -> " + ret
	return sig


## Direct child segments of segment `s`, in order, blanks removed.
func _child_segs(p: Parser, s: int) -> Array:
	var out: Array = []
	var n: int = p.segment_count()
	for j: int in range(s + 1, n):
		if p.parent[j] == s:
			if int(p.kind[j]) != Parser.Kind.BLANK:
				out.append(j)
	return out


func _subtree_end(p: Parser, s: int) -> int:
	var e: int = s
	var n: int = p.segment_count()
	while e + 1 < n and p.parent[e + 1] >= s:
		e += 1
	return e


## Builds one sibling list (a statement chain) as real exec connections.
## `cont`     : {"id", "port"} where the chain's branch ends flow into (join).
## `entry_in` : {"id", "port"} feeding the FIRST node of the chain.
## `depth` is the control-flow nesting depth of this sibling list
## (0 = function body top level); it drives codegen indentation.
func _build_list(p: Parser, segs: Array, cont: Dictionary, entry_in: Dictionary, depth: int = 0) -> void:
	if segs.is_empty():
		return
	# Phase 1: create a node per sibling (markers for absorbed segments).
	var ids: Array = []
	for s: int in segs:
		var k: int = int(p.kind[s])
		if k == Parser.Kind.ELSE:
			ids.append(-2)     # absorbed into the preceding if/elif group
		elif k == Parser.Kind.MATCH_BRANCH:
			ids.append(-3)     # absorbed into the match node
		else:
			ids.append(_make_node_for_seg(p, s, depth))
	# Phase 2: wire sequentially with real execution semantics.
	var absorbed: Dictionary = {}
	var prev_out: Dictionary = {}
	var cont_skip: int = -1   # sibling already fed by a control group's continuation
	for i: int in segs.size():
		var s: int = segs[i]
		var nid: int = ids[i]
		if nid < 0 or absorbed.has(i):
			continue
		# A block-scoped declaration is data-only: it connects to its owning
		# block through the scope wire and must never be exec-wired.
		if int(nodes[nid]["kind"]) == Kind.VAR_DECL \
				and bool(nodes[nid]["fields"].get("scoped", false)):
			continue
		var k: int = int(p.kind[s])
		var in_target: Dictionary
		# A control group wires its continuation (the next real sibling) itself.
		if nid == cont_skip:
			cont_skip = -1
			in_target = {}   # already fed by the group's continuation links
		else:
			in_target = prev_out if not prev_out.is_empty() else entry_in
		match k:
			Parser.Kind.IF, Parser.Kind.ELIF:
				if not in_target.is_empty():
					_link_exec(in_target, nid, 0)
				var group_cont: Dictionary = _group_cont(segs, ids, i, cont)
				if group_cont.has("id"):
					cont_skip = int(group_cont["id"])
				# Blueprint / VisualScript style: True and False are separate
				# branches whose chains simply end (nothing joins them back);
				# the "done" pin carries whatever runs after the whole
				# if / elif / else chain.
				_build_children(p, nid, _child_segs(p, s), {}, {"id": nid, "port": 0}, depth + 1)
				# Scan forward for elif / else belonging to this if.
				var false_owner: int = nid
				var j: int = i + 1
				while j < segs.size():
					var kj: int = int(p.kind[segs[j]])
					if kj == Parser.Kind.ELIF and ids[j] >= 0:
						absorbed[j] = true
						_link_exec({"id": false_owner, "port": 1}, ids[j], 0)
						_build_children(p, ids[j], _child_segs(p, segs[j]), {}, {"id": ids[j], "port": 0}, depth + 1)
						false_owner = ids[j]
						j += 1
					elif kj == Parser.Kind.ELSE:
						absorbed[j] = true
						nodes[false_owner]["has_else"] = true
						_build_children(p, false_owner, _child_segs(p, segs[j]), {}, {"id": false_owner, "port": 1}, depth + 1)
						j += 1
						break
					else:
						break
				# The chain head's "done" pin continues after the group.
				_link_exec({"id": nid, "port": 2}, group_cont)
				prev_out = {}
			Parser.Kind.WHILE, Parser.Kind.FOR:
				if not in_target.is_empty():
					_link_exec(in_target, nid, 0)
				var loop_cont: Dictionary = _group_cont(segs, ids, i, cont)
				if loop_cont.has("id"):
					cont_skip = int(loop_cont["id"])
				# Body chain ends dangle (the loop repeats); "done" flows on.
				_build_children(p, nid, _child_segs(p, s), {}, {"id": nid, "port": 0}, depth + 1)
				_link_exec({"id": nid, "port": 1}, loop_cont)
				prev_out = {}
			Parser.Kind.MATCH:
				if not in_target.is_empty():
					_link_exec(in_target, nid, 0)
				var mcont: Dictionary = _group_cont(segs, ids, i, cont)
				if mcont.has("id"):
					cont_skip = int(mcont["id"])
				var b: int = 0
				for bs: int in _child_segs(p, s):
					if int(p.kind[bs]) != Parser.Kind.MATCH_BRANCH:
						continue
					# Branch content lives one block deeper than the labels.
					_build_children(p, nid, _child_segs(p, bs), mcont, {"id": nid, "port": b}, depth + 2)
					b += 1
				# Fall-through: when no branch matched, the next sibling runs.
				_link_exec({"id": nid, "port": b}, mcont)
				prev_out = {}
			Parser.Kind.RETURN, Parser.Kind.BREAK, Parser.Kind.CONTINUE:
				if not in_target.is_empty():
					_link_exec(in_target, nid, 0)
				prev_out = {}   # path ends here
			_:
				if not in_target.is_empty():
					_link_exec(in_target, nid, 0)
				prev_out = {"id": nid, "port": 0}
	# A plain statement chain flows into the continuation of this list
	# (e.g. an if-branch's last statement joins the code after the if).
	if not prev_out.is_empty() and not cont.is_empty():
		_link_exec(prev_out, cont)


## Builds a block-owning node's children with the owner pushed on the block
## stack, so branch-level declarations can find the block they are scoped to.
func _build_children(p: Parser, owner: int, segs: Array, cont: Dictionary,
		entry_in: Dictionary, depth: int) -> void:
	_block_stack.append(owner)
	_build_list(p, segs, cont, entry_in, depth)
	_block_stack.pop_back()


## Continuation handle for a control group: the first following sibling that is
## a real node (skipping blanks, elif/else/match-branch markers), else outer cont.
func _group_cont(segs: Array, ids: Array, i: int, cont: Dictionary) -> Dictionary:
	for j: int in range(i + 1, segs.size()):
		if ids[j] >= 0:
			var k: int = int(nodes[ids[j]]["kind"])
			if k == Kind.ELIF:
				continue   # belongs to this if-group
			if k == Kind.VAR_DECL and bool(nodes[ids[j]]["fields"].get("scoped", false)):
				continue   # scoped declaration: data-only, transparent in the chain
			return {"id": ids[j], "port": 0}
	return cont


# ---- Node creation ----------------------------------------------------------
func _make_node(kind: int, depth: int = 0) -> int:
	var id: int = _next_id
	_next_id += 1
	nodes[id] = {
		"id": id,
		"kind": kind,
		"title": KIND_TITLES.get(kind, "Node"),
		"color": KIND_COLORS.get(kind, "#35393f"),
		"body": "",
		"exec_in": kind != Kind.PREAMBLE and kind != Kind.LITERAL \
			and kind != Kind.VARIABLE_GET and kind != Kind.OPERATOR and kind != Kind.CALL \
			and kind != Kind.VAR_DECL and kind != Kind.CONST_DECL \
			and kind != Kind.SIGNAL_DECL and kind != Kind.DECLARATION \
			and kind != Kind.ARGUMENT and kind != Kind.CLASS_NAME \
			and kind != Kind.EXTENDS_DECL and kind != Kind.CLASS_REF \
			and kind != Kind.LAMBDA and kind != Kind.COMMENT,
		"exec_outs": [],
		"data_ins": [],   # {name, type, value}
		"data_outs": [],  # {name, type}
		"sig": "",
		"depth": depth,
		"has_else": false,
		"is_elif": kind == Kind.ELIF,
		"stmt": {},       # {decl, lhs, name, type, op, has_value}
		"fields": {},     # editable texts for data-only nodes
	}
	exec_out[id] = {}
	exec_in[id] = []
	return id


func _make_node_for_seg(p: Parser, s: int, depth: int = 0) -> int:
	var k: int = int(p.kind[s])
	var full: String = p.text_of(p.first_line[s], p.last_line[s])
	match k:
		Parser.Kind.COMMENT, Parser.Kind.DOC_COMMENT:
			var nid: int = _make_node(Kind.COMMENT, depth)
			var cln: PackedStringArray = PackedStringArray()
			for ln: String in full.split("\n"):
				cln.append(ln.strip_edges())
			nodes[nid].body = "\n".join(cln)
			return nid
		Parser.Kind.PASS:
			var nid: int = _make_node(Kind.PASS, depth)
			nodes[nid].body = full.strip_edges()
			nodes[nid].exec_outs = ["\u25b6"]
			return nid
		Parser.Kind.RETURN:
			var nid: int = _make_node(Kind.RETURN, depth)
			var rest: String = full.strip_edges().trim_prefix("return").strip_edges()
			nodes[nid].body = full.strip_edges()
			nodes[nid].exec_outs = []
			if rest != "":
				nodes[nid].data_ins = [{"name": "value", "type": Types.VARIANT, "value": rest}]
			return nid
		Parser.Kind.BREAK:
			var nid: int = _make_node(Kind.BREAK, depth)
			nodes[nid].body = "break"
			return nid
		Parser.Kind.CONTINUE:
			var nid: int = _make_node(Kind.CONTINUE, depth)
			nodes[nid].body = "continue"
			return nid
		Parser.Kind.IF, Parser.Kind.ELIF:
			var nid: int = _make_node(Kind.IF if k == Parser.Kind.IF else Kind.ELIF, depth)
			var one: String = full.strip_edges().trim_suffix(":")
			var cond: String = ""
			if one.begins_with("if "):
				cond = one.substr(3).strip_edges()
			elif one.begins_with("elif "):
				cond = one.substr(5).strip_edges()
			nodes[nid].body = one
			nodes[nid].data_ins = [{"name": "condition", "type": Types.BOOL, "value": cond}]
			nodes[nid].exec_outs = ["True", "False", "done"]
			_add_scope_slot(nid)
			# A supported comparison condition (`health > 0`) reconstructs as
			# its own comparison Operator node wired into the If's condition
			# input, so the expression is not duplicated inside the If node.
			# Anything else (boolean combinations, `not ...`, calls, chained
			# comparisons) stays verbatim on the condition pin.
			var cmp: Dictionary = _split_comparison(cond)
			if not cmp.is_empty():
				var cid: int = _make_node(Kind.OPERATOR, depth)
				nodes[cid]["fields"] = {"op": String(cmp["op"])}
				nodes[cid]["title"] = "Operator %s" % String(cmp["op"])
				nodes[cid]["data_ins"] = [
					{"name": "a", "type": Types.VARIANT, "value": String(cmp["lhs"])},
					{"name": "b", "type": Types.VARIANT, "value": String(cmp["rhs"])},
				]
				nodes[cid]["data_outs"] = [{"name": "result", "type": Types.BOOL}]
				# The comparison lives on the Operator node only: the If keeps
				# no duplicated condition text.
				nodes[nid].data_ins[0]["value"] = ""
				nodes[nid]["body"] = ""
				data_links.append({
					"from_id": cid, "from_out": 0,
					"to_id": nid, "to_in": 0,
				})
			else:
				# `if mod.is_valid():` - a value-returning method call on a
				# variable of a known type becomes its own call node wired
				# into the condition pin.
				_try_condition_call(nid, cond, depth)
			return nid
		Parser.Kind.WHILE:
			var nid: int = _make_node(Kind.WHILE, depth)
			var one: String = full.strip_edges().trim_suffix(":").trim_prefix("while ").strip_edges()
			nodes[nid].body = one
			nodes[nid].data_ins = [{"name": "condition", "type": Types.BOOL, "value": one}]
			nodes[nid].exec_outs = ["loop body", "done"]
			_add_scope_slot(nid)
			_try_condition_call(nid, one, depth)
			return nid
		Parser.Kind.FOR:
			var nid: int = _make_node(Kind.FOR, depth)
			var one: String = full.strip_edges().trim_suffix(":").trim_prefix("for ").strip_edges()
			var vname: String = "i"
			var iter: String = one
			var vtype: String = ""
			var idx: int = one.find(" in ")
			if idx > 0:
				vname = one.substr(0, idx).strip_edges()
				iter = one.substr(idx + 4).strip_edges()
				# A typed iterator (`for k: String in ...`) keeps its annotation:
				# the pin carries the real type and generation restores `: T`.
				var vcolon: int = vname.find(":")
				if vcolon >= 0:
					vtype = vname.substr(vcolon + 1).strip_edges()
					vname = vname.substr(0, vcolon).strip_edges()
				nodes[nid].body = one
				nodes[nid].fields = {"iter_type": vtype}
				var vpt: int = Types.type_from_name(vtype) if vtype != "" else Types.VARIANT
				nodes[nid].data_ins = [{"name": "sequence", "type": Types.VARIANT, "value": iter}]
				nodes[nid].data_outs = [{"name": vname, "type": vpt, "type_text": vtype}]
				nodes[nid].exec_outs = ["loop body", "done"]
				_add_scope_slot(nid)
				_entry_iter_names[vname] = true
				if vtype != "":
					_entry_iter_types[vname] = vtype
				else:
					_entry_iter_types.erase(vname)
				return nid
			nodes[nid].body = one
			nodes[nid].data_ins = [{"name": "sequence", "type": Types.VARIANT, "value": iter}]
			nodes[nid].data_outs = [{"name": vname, "type": Types.VARIANT}]
			nodes[nid].exec_outs = ["loop body", "done"]
			_add_scope_slot(nid)
			_entry_iter_names[vname] = true
			_entry_iter_types.erase(vname)
			return nid
		Parser.Kind.MATCH:
			var nid: int = _make_node(Kind.MATCH, depth)
			var one: String = full.strip_edges().trim_suffix(":").trim_prefix("match ").strip_edges()
			nodes[nid].body = one
			nodes[nid].data_ins = [{"name": "value", "type": Types.VARIANT, "value": one}]
			# One exec output per branch, labelled with the branch pattern,
			# plus a fall-through "after" pin (no branch matched).
			var outs: Array = []
			for bs: int in _child_segs(p, s):
				if int(p.kind[bs]) == Parser.Kind.MATCH_BRANCH:
					outs.append(p.text_of(p.first_line[bs], p.first_line[bs]).strip_edges())
			outs.append("after")
			nodes[nid].exec_outs = outs
			_add_scope_slot(nid)
			return nid
		Parser.Kind.ANNOTATION:
			var nid: int = _make_node(Kind.STATEMENT, depth)
			var alns: PackedStringArray = PackedStringArray()
			for aln: String in full.split("\n"):
				alns.append(aln.strip_edges())
			nodes[nid].body = "\n".join(alns)
			nodes[nid].title = "Annotation"
			nodes[nid].exec_outs = ["\u25b6"]
			return nid
		_:
			var hid: int = _maybe_hoist_local(p, s, depth)
			if hid >= 0:
				return hid
			var nid: int = _make_statement_node(full, depth)
			# A statement whose source opened an indented block (e.g. a
			# branch-level `var x := func():` with a body) keeps its block:
			# emit it verbatim so nothing is dropped.
			if int(nodes[nid]["kind"]) == Kind.STATEMENT and bool(p.is_header[s]) \
					and not _child_segs(p, s).is_empty():
				var kidsl: Array = _child_segs(p, s)
				var block: String = p.text_of(p.first_line[s],
					p.last_line[int(kidsl[kidsl.size() - 1])])
				var fl: String = p.lines[p.first_line[s]]
				var lead0: int = fl.length() - fl.lstrip(" \t").length()
				nodes[nid]["body"] = _dedent_by_base(block, lead0)
				# A statement that opens a block with a lambda (e.g.
				# `f = func():\n\treturn 1`) rebuilds structured with a wired
				# Lambda node instead of staying opaque text. Non-lambda
				# blocks (object literals, multiline strings) stay verbatim.
				var st2: Dictionary = _parse_stmt(String(nodes[nid]["body"]))
				if not st2.is_empty() and bool(st2["has_value"]) \
						and not _parse_lambda_value(String(st2["rhs"])).is_empty():
					nodes[nid]["stmt"] = st2
					nodes[nid]["title"] = ("var %s" % st2["name"]) if bool(st2["decl"]) else ("set %s" % st2["name"])
					var vt2: int = int(st2.get("type", Types.VARIANT))
					nodes[nid]["data_ins"] = [{"name": "value", "type": vt2, "value": String(st2["rhs"])}]
					if not bool(st2["decl"]):
						nodes[nid]["data_outs"] = [{"name": st2["name"], "type": vt2}]
						if nodes[nid]["exec_outs"].is_empty():
							nodes[nid]["exec_outs"] = ["\u25b6"]
					_maybe_wire_lambda(nid, String(st2["rhs"]))
				else:
					nodes[nid]["stmt"] = {}
			return nid


## A `var` declaration at the top level of a function body becomes a PRIVATE
## Variable node owned by that function (GDScript locals are not accessible
## outside their function, and hoisting preserves order/semantics for valid
## scripts). Returns -1 when the statement must stay a regular flow node
## (branch-level declarations, prefixed/static declarations, non-decls).
func _maybe_hoist_local(p: Parser, s: int, depth: int) -> int:
	if _current_entry < 0:
		return -1
	var full: String = p.text_of(p.first_line[s], p.last_line[s])
	var inline_anns: bool = full.strip_edges().begins_with("@")
	var decl: String = _strip_var_prefix(full.strip_edges())
	if decl == "" or not decl.begins_with("var"):
		return -1
	var stmt: Dictionary = _parse_stmt(decl)
	if stmt.is_empty() or not bool(stmt["decl"]):
		return -1
	var var_body: String = decl.strip_edges().trim_prefix("var").strip_edges()
	var vsp: Dictionary = _split_assign(var_body)
	var vname: String = var_body.trim_suffix(":").strip_edges() if vsp.is_empty() else String(vsp["lhs"])
	var vdefault: String = "" if vsp.is_empty() else String(vsp["rhs"])
	var vraw: String = ""
	var vcolon: int = _find_typed_colon(vname)
	if vcolon >= 0:
		vraw = vname.substr(vcolon + 1).strip_edges()
		vname = vname.substr(0, vcolon).strip_edges()
	if not _valid_ident(vname):
		return -1
	# A declaration inside a flow block (an If body, a loop body, …) becomes a
	# full private Variable node scoped to its owning block through the visible
	# scope wire — the same node a user would build by hand. Its default must
	# be evaluable at the function top (where scoped declarations generate):
	# defaults reading loop iterators or branch-only names keep their
	# statement position instead (preserved, not silently rewritten).
	var scoped: bool = depth != 0 and not _block_stack.is_empty() \
			and int(nodes[_block_stack[_block_stack.size() - 1]]["kind"]) \
				in [Kind.IF, Kind.ELIF, Kind.WHILE, Kind.FOR]
	if depth != 0 and not scoped:
		return -1
	if scoped and (not _rhs_safe_for_top(String(stmt.get("rhs", "")))
			or not _rhs_safe_for_top(vraw)
			or _collect_tail(p, s) != ""
			or _entry_scoped_names.has(vname) or _entry_flow_locals.has(vname)):
		# Lambda / block-literal bodies and defaults that read values which
		# only exist inside the block (loop iterators, branch-only names)
		# must keep the declaration at its flow position.
		_block_unsafe[vname] = true
		return -1
	var nid: int = _make_node(Kind.VAR_DECL, depth)
	var vt: int = int(stmt.get("type", Types.VARIANT))
	var local_prefix: String = full.strip_edges()
	if decl != "":
		local_prefix = local_prefix.substr(0,
			local_prefix.length() - decl.length()).strip_edges()
	var lspfx: Dictionary = _split_prefix(local_prefix)
	var local_inline_text: String = ""
	if inline_anns:
		local_inline_text = "\n".join(_split_prefix(local_prefix)["anns"] as PackedStringArray)
	nodes[nid].stmt = stmt
	nodes[nid].body = full.strip_edges()
	nodes[nid].fields = {"name": vname, "raw_type": vraw, "default": vdefault,
		"prefix": local_prefix, "annotations": "\n".join(lspfx["anns"]),
		"is_static": lspfx["static"], "scope": "private", "owner": _current_entry,
		"ann_inline": inline_anns, "inline_ann_text": local_inline_text}
	nodes[nid].data_ins = [{"name": "value", "type": vt, "value": stmt.get("rhs", "")},
		{"name": "add annotation", "type": Types.PinType.ANNOTATION, "value": ""}]
	nodes[nid].data_outs = [{"name": vname, "type": vt, "type_text": vraw}]
	nodes[nid].title = "var %s" % vname
	# A local declaration that opened an indented block in the source (a
	# lambda body) keeps that block verbatim; the trailing ":" that opened it
	# must not leak into the default value.
	var tail: String = _collect_tail(p, s)
	if tail != "":
		nodes[nid].fields["tail"] = tail
		if String(stmt.get("rhs", "")).ends_with(":"):
			stmt["rhs"] = String(stmt["rhs"]).trim_suffix(":")
			stmt["has_value"] = true
		if String(nodes[nid].fields["default"]).ends_with(":"):
			nodes[nid].fields["default"] = String(nodes[nid].fields["default"]).trim_suffix(":")
		nodes[nid].data_ins[0]["value"] = stmt["rhs"]
	if not func_privates.has(_current_entry):
		func_privates[_current_entry] = []
	func_privates[_current_entry].append(nid)
	# A parsed private variable shows its dedicated scope output pin right
	# away (same state as toggling Private in the editor; idempotent, so
	# repeated loads never duplicate the pin).
	_var_sync_scope_pin(nid)
	if scoped:
		# Associate the block-scoped declaration with its owning block through
		# the proper visible scope wire (never an execution wire).
		register_scope(_block_stack[_block_stack.size() - 1], nid)
		nodes[nid]["fields"]["scoped"] = true
		_entry_scoped_names[vname] = true
	else:
		_entry_flow_locals[vname] = true
		# Function-level locals are owned by the function's own scope slot:
		# the visible scope wire exists straight after loading.
		register_scope(_current_entry, nid)
	_convert_var_lambda(nid)
	return nid


## Replaces a variable declaration's inline lambda default with a wired
## Lambda node: the head line becomes the node's signature, the collected
## tail becomes its body, and the value pin is fed by a Callable output.
## Skipped when the tail is a real accessor block (not a lambda body).
func _convert_var_lambda(nid: int) -> void:
	var pin: Dictionary = nodes[nid]["data_ins"][0]
	if not _looks_like_lambda_start(str(pin["value"])):
		return
	var tail: String = str(nodes[nid]["fields"].get("tail", ""))
	if tail != "" and String(nodes[nid]["fields"].get("acc_mode", "other")) != "other":
		return   # accessor block tail: leave the declaration verbatim
	var head: Dictionary = _split_lambda_head(str(pin["value"]))
	if head.is_empty():
		return
	var body: String = str(head["inline"])
	var from_block: bool = tail != ""
	if tail != "":
		body = (body + "\n" if body != "" else "") + tail
	if body.strip_edges() == "":
		return
	var lid: int = _make_node(Kind.LAMBDA, int(nodes[nid].get("depth", 0)))
	nodes[lid]["fields"] = {"params": head["params"], "ret": head["ret"],
		"body": _normalize_lambda_body(body), "block": from_block}
	nodes[lid]["data_outs"] = [{"name": "Callable", "type": Types.PinType.CALLABLE}]
	_lambda_sync_title(lid)
	data_links.append({"from_id": lid, "from_out": 0, "to_id": nid, "to_in": 0})
	pin["value"] = ""
	pin["type"] = Types.PinType.CALLABLE
	nodes[nid]["fields"].erase("tail")
	nodes[nid]["fields"]["acc_mode"] = "other"


## True when an expression is safe to evaluate at the top of the function
## (where block-scoped declarations generate): it must not read loop
## iterators or names that only exist inside flow blocks.
func _rhs_safe_for_top(rhs: String) -> bool:
	var t: String = rhs.strip_edges()
	if t == "":
		return true
	# A lambda/block literal value belongs to its flow position.
	if t.begins_with("func") or t.contains("\n"):
		return false
	var in_str: bool = false
	var quote: String = ""
	var ident: String = ""
	var i: int = 0
	while i < t.length():
		var ch: String = t[i]
		if in_str:
			if ch == "\\":
				i += 2
				continue
			if ch == quote:
				in_str = false
			i += 1
			continue
		if ch == "\"" or ch == "'":
			in_str = true
			quote = ch
			i += 1
			continue
		if (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") or ch == "_":
			ident += ch
			i += 1
			continue
		if (ch >= "0" and ch <= "9") and ident != "":
			ident += ch
			i += 1
			continue
		if ident != "":
			if _unsafe_name(ident):
				return false
			ident = ""
		i += 1
	if ident != "" and _unsafe_name(ident):
		return false
	return true


## Names a top-hoisted block declaration may not read: loop iterators,
## branch-only statements and top-level locals (which emit in flow, after
## the function-top block where scoped declarations generate).
func _unsafe_name(ident: String) -> bool:
	return _block_unsafe.has(ident) or _entry_iter_names.has(ident) \
		or _entry_flow_locals.has(ident)


## Resolves the exec-flow position of a node: {entry, node} where entry is the
## owning function (EVENT node) and node is the flow node the reference is
## anchored to. Data-only nodes (Get Variable, literals, operators...) are
## anchored through their data consumers; nodes with no flow anchor return
## {entry: -1, node: -1}.
func _ref_position(id: int) -> Dictionary:
	if not nodes.has(id):
		return {"entry": -1, "node": -1}
	if int(nodes[id]["kind"]) == Kind.ENTRY:
		return {"entry": id, "node": id}
	var anchor: int = _entry_of_flow_node(id)
	if anchor >= 0:
		return {"entry": anchor, "node": id}
	# data-only: walk consumers until one sits in a flow
	var seen: Dictionary = {id: true}
	var queue: Array[int] = [id]
	while not queue.is_empty():
		var cur: int = queue.pop_back()
		for l: Dictionary in data_links:
			if int(l["from_id"]) != cur:
				continue
			var to_id: int = int(l["to_id"])
			if seen.has(to_id):
				continue
			seen[to_id] = true
			var e2: int = _entry_of_flow_node(to_id)
			if e2 >= 0:
				return {"entry": e2, "node": to_id}
			queue.append(to_id)
	return {"entry": -1, "node": -1}


## Walks the exec-in chain upwards to the owning EVENT node (-1 if unattached).
func _entry_of_flow_node(id: int) -> int:
	var seen: Dictionary = {}
	var queue: Array[int] = [id]
	while not queue.is_empty():
		var cur: int = queue.pop_front()
		if seen.has(cur):
			continue
		seen[cur] = true
		if not nodes.has(cur):
			continue
		if int(nodes[cur]["kind"]) == Kind.ENTRY:
			return cur
		for e: Dictionary in exec_in.get(cur, []):
			var up: int = int(e["from_id"])
			if not seen.has(up):
				queue.append(up)
	return -1


## Scope information for a variable name: {kind: "none"/"public"/"private"/
## "local", owner: entry id, decl: node id, block: bool}. Locals (statement
## declarations, arguments) take precedence over member variables (shadowing).
func _scope_of_name(name: String) -> Dictionary:
	for id: int in nodes:
		var n: Dictionary = nodes[id]
		var st: Dictionary = n.get("stmt", {})
		if int(n["kind"]) == Kind.STATEMENT and not st.is_empty() and bool(st.get("decl", false)) \
				and str(st.get("name", "")) == name:
			return {"kind": "local", "owner": _entry_of_flow_node(id),
				"decl": id, "block": int(n.get("depth", 0)) >= 1}
		if int(n["kind"]) == Kind.ARGUMENT and str(n["fields"].get("name", "")) == name:
			return {"kind": "local", "owner": int(n["fields"].get("parent", -1)),
				"decl": id, "block": false}
	for id2: int in nodes:
		if int(nodes[id2]["kind"]) == Kind.VAR_DECL \
				and str(nodes[id2]["fields"].get("name", "")) == name:
			var scope: String = str(nodes[id2]["fields"].get("scope", "public"))
			return {"kind": scope, "owner": int(nodes[id2]["fields"].get("owner", -1)),
				"decl": id2, "block": false}
	return {"kind": "none", "owner": -1, "decl": -1, "block": false}


## True when `ref_id` (a Get/Set Variable node) may reference `name` in its
## resolved flow position.
func _is_ref_allowed(ref_id: int, name: String) -> bool:
	var info: Dictionary = _scope_of_name(name)
	if str(info["kind"]) in ["none", "public"]:
		return true
	var pos: Dictionary = _ref_position(ref_id)
	if int(pos["entry"]) < 0:
		return false   # no verifiable flow position: treat as out of scope
	if not _private_pos_allowed(int(info["decl"]), pos):
		return false
	if not scope_links_of(int(info["decl"])).is_empty() \
			and bool(info.get("block", false)) and int(pos["node"]) != int(info["decl"]):
		# Block-scoped local (declared inside an if/loop branch) whose
		# variable also carries explicit scope registrations: the anchor must
		# still sit inside the same branch, after the declaration.
		return _flow_reaches(int(info["decl"]), int(pos["node"]))
	return true


## True when walking the exec-in chain from `anchor` passes through `decl`
## (i.e. the declaration executes before / around the anchor in the flow).
func _flow_reaches(decl: int, anchor: int) -> bool:
	var seen: Dictionary = {}
	var queue: Array[int] = [anchor]
	while not queue.is_empty():
		var cur: int = queue.pop_front()
		if seen.has(cur):
			continue
		seen[cur] = true
		if cur == decl:
			return true
		for e: Dictionary in exec_in.get(cur, []):
			var up: int = int(e["from_id"])
			if not seen.has(up):
				queue.append(up)
	return false


## Splits a var declaration's prefix into annotation lines to emit above the
## declaration and the `static` keyword that must stay on the declaration
## line itself (a bare `static` line is a parse error: "Expected "func" or
## "var" after "static""). Unknown prefix content is kept verbatim.
func _static_prefix_lines(prefix: String) -> Dictionary:
	var kept: PackedStringArray = PackedStringArray()
	var is_static: bool = false
	for ln: String in prefix.split("\n"):
		var t: String = ln.strip_edges()
		if t == "static":
			is_static = true
			continue
		if t.ends_with(" static") and t.begins_with("@"):
			kept.append(t.trim_suffix(" static"))
			is_static = true
			continue
		if t != "":
			kept.append(t)
	return {"lines": kept, "static": is_static}


## The verbatim block that followed a var declaration in the source (a lambda
## body or property accessors), dedented by the block's own base indentation
## so it can be re-indented at emit time. "" when there is no block.
func _collect_tail(p: Parser, s: int) -> String:
	var kids: Array = _child_segs(p, s)
	if kids.is_empty():
		return ""
	var first: int = int(p.first_line[int(kids[0])])
	# span to the end of the var segment's whole subtree: accessor/lambda
	# bodies are grandchildren of the var segment (children of the
	# get:/set:/func: lines), and later accessor blocks are siblings of the
	# first child within the var's subtree
	var last: int = int(p.last_line[_subtree_end(p, s)])
	var base: String = p.lines[first]
	var lead: int = base.length() - base.lstrip(" \t").length()
	return _dedent_by_base(p.text_of(first, last), lead)


## Removes up to `base_lead` leading whitespace characters from every line.
func _dedent_by_base(text: String, base_lead: int) -> String:
	var outl: PackedStringArray = PackedStringArray()
	for ln: String in text.split("\n"):
		var cut: int = 0
		while cut < ln.length() and cut < base_lead and (ln[cut] == " " or ln[cut] == "\t"):
			cut += 1
		outl.append(ln.substr(cut))
	return "\n".join(outl)


## Normalises a multi-line value expression (an array/dictionary/call literal
## that spans lines): continuation lines are dedented by their own common
## leading whitespace so the emitter's per-line indent re-creates clean,
## stable indentation without churn between saves.
func _dedent_block_value(text: String) -> String:
	if not text.contains("\n"):
		return text
	var lines: PackedStringArray = text.split("\n")
	var min_lead: int = -1
	for i: int in range(1, lines.size()):
		var ln: String = lines[i]
		if ln.strip_edges() == "":
			continue
		var lead: int = ln.length() - ln.lstrip(" \t").length()
		if min_lead < 0 or lead < min_lead:
			min_lead = lead
	if min_lead <= 0:
		return text
	return _dedent_by_base(text, min_lead)


## The dedented tail block stored on a structured var node ("" = none).
func _var_decl_tail(id: int) -> String:
	return String(nodes[id]["fields"].get("tail", ""))


# ---- Setter / Getter nodes ----------------------------------------------------
## A property accessor is a function-like node: a Setter (`set(value):`) or a
## Getter (`get:`) is an ENTRY node flagged with `fields.accessor` ("set" /
## "get") and `fields.owner_var` (the Variable node it belongs to). Its body
## is an ordinary exec chain (If, Set, Print, Return, calls ...), so nobody has
## to type GDScript. The node is never written as a `func`: generate() writes
## its body inside the variable's declaration, one level deeper.

## "Setter: health" / "Getter: health".
func accessor_title(which: String, var_name: String) -> String:
	if var_name.strip_edges() == "":
		return "Setter" if which == "set" else "Getter"
	return ("Setter: " if which == "set" else "Getter: ") + var_name


## True for a Setter / Getter node.
func is_accessor_entry(id: int) -> bool:
	return nodes.has(id) and int(nodes[id]["kind"]) == Kind.ENTRY \
		and nodes[id]["fields"].has("accessor")


## {"set": entry id, "get": entry id} for the accessors of a variable (only
## the ones that exist).
func accessor_entries_of(vid: int) -> Dictionary:
	var out: Dictionary = {}
	for id: int in nodes:
		var n: Dictionary = nodes[id]
		if int(n["kind"]) == Kind.ENTRY and n["fields"].has("accessor") \
				and int(n["fields"].get("owner_var", -1)) == vid:
			out[String(n["fields"]["accessor"])] = id
	return out


## Entry ids in the order they are written (the source order is kept when a
## script had its getter first).
func _accessor_emit_order(vid: int) -> Array[int]:
	var acc: Dictionary = accessor_entries_of(vid)
	var order: Array[int] = []
	var keys: Array = ["get", "set"] if bool(nodes[vid]["fields"].get("get_first", false)) \
		else ["set", "get"]
	for k: String in keys:
		if acc.has(k):
			order.append(int(acc[k]))
	return order


## Keeps the Setter / Getter titles in step with the variable's name.
func _accessor_refresh_titles(vid: int) -> void:
	var vname: String = String(nodes[vid]["fields"].get("name", ""))
	var acc: Dictionary = accessor_entries_of(vid)
	for which: String in acc:
		nodes[int(acc[which])]["title"] = accessor_title(which, vname)


## The name of a Setter's value argument ("value" unless the script used
## another name).
func _accessor_arg_name(eid: int) -> String:
	for aid: int in nodes[eid]["fields"].get("args", []):
		if nodes.has(aid):
			return String(nodes[aid]["fields"].get("name", AccText.DEFAULT_ARG))
	return AccText.DEFAULT_ARG


## Creates the (empty) Setter / Getter node of a variable, with the Setter's
## value argument. Returns the entry id.
func _new_accessor_entry(vid: int, which: String, arg_name: String = "value") -> int:
	# vid < 0: a Setter / Getter spawned from the node menu before a variable
	# has been picked for it
	var vf: Dictionary = nodes[vid]["fields"] if nodes.has(vid) else {}
	var vname: String = String(vf.get("name", ""))
	var raw: String = String(vf.get("raw_type", "")).strip_edges()
	var vt: int = Types.type_from_name(raw) if raw != "" else Types.VARIANT
	var eid: int = _make_node(Kind.ENTRY)
	var args: Array[int] = []
	if which == "set":
		var aname: String = arg_name if arg_name.strip_edges() != "" else AccText.DEFAULT_ARG
		var aid: int = _make_node(Kind.ARGUMENT)
		nodes[aid]["fields"] = {"name": aname, "type": "", "default": "", "parent": eid}
		nodes[aid]["data_ins"] = [{"name": aname, "type": vt, "value": ""}]
		nodes[aid]["data_outs"] = [
			{"name": aname, "type": vt},
			{"name": "Function", "type": Types.VARIANT},
		]
		nodes[aid]["title"] = "arg: %s" % aname
		args.append(aid)
		arg_links.append({"eid": eid, "aid": aid})
	nodes[eid]["fields"] = {"name": "@" + which, "ret_type": "", "static": false,
		"args": args, "annotations": "", "accessor": which, "owner_var": vid}
	nodes[eid]["sig"] = ""
	nodes[eid]["body"] = ""
	nodes[eid]["title"] = accessor_title(which, vname)
	nodes[eid]["exec_outs"] = ["\u25b6"]
	_entry_sync_pins(eid)
	roots.append({"entry": eid, "tight": true, "accessor": true})
	return eid


## Loading: turns the `set(v):` / `get:` blocks of a parsed variable into
## Setter / Getter nodes whose bodies are real node chains. A block the node
## form cannot represent exactly (comments between the accessors, one-line
## bodies, duplicates) keeps the verbatim `tail` instead, as before.
func _convert_accessors_to_nodes(p: Parser, vs: int, vid: int) -> void:
	var f: Dictionary = nodes[vid]["fields"]
	if String(f.get("acc_mode", "")) != "struct":
		return
	if not (bool(f.get("has_setter", false)) or bool(f.get("has_getter", false))):
		return
	if not var_supports_accessors(vid):
		return
	var segs: Dictionary = {}
	for k: int in _child_segs(p, vs):
		if int(p.kind[k]) != Parser.Kind.ACCESSOR or not bool(p.is_header[k]):
			return
		var head: String = String(p.lines[p.first_line[k]]).strip_edges()
		var which: String = "set" if head.begins_with("set") else "get"
		if segs.has(which):
			return
		segs[which] = k
	if segs.has("set") != bool(f.get("has_setter", false)) \
			or segs.has("get") != bool(f.get("has_getter", false)):
		return
	var arg_name: String = String(f.get("setter_arg", AccText.DEFAULT_ARG))
	for which2: String in ["set", "get"]:
		if not segs.has(which2):
			continue
		var eid: int = _new_accessor_entry(vid, which2, arg_name)
		_current_entry = eid
		func_privates[eid] = []
		_entry_iter_names.clear()
		_entry_iter_types.clear()
		_block_unsafe.clear()
		_entry_flow_locals.clear()
		_entry_scoped_names.clear()
		_block_stack.clear()
		_build_list(p, _child_segs(p, int(segs[which2])), {}, {"id": eid, "port": 0})
		_block_stack.clear()
		_entry_iter_names.clear()
		_entry_iter_types.clear()
		_block_unsafe.clear()
		_entry_flow_locals.clear()
		_entry_scoped_names.clear()
		_current_entry = -1
	f.erase("tail")
	f["acc_mode"] = "nodes"
	f["has_setter"] = false
	f["has_getter"] = false


## True when a Setter / Getter can be added to this variable: a public member
## variable whose accessors are either absent or already Setter / Getter nodes
## (a verbatim accessor block must be cleared first).
func accessor_nodes_allowed(vid: int) -> bool:
	if not nodes.has(vid) or int(nodes[vid]["kind"]) != Kind.VAR_DECL:
		return false
	var f: Dictionary = nodes[vid]["fields"]
	if String(f.get("scope", "public")) == "private":
		return false
	if String(f.get("tail", "")).strip_edges() != "":
		return false
	return true


## Builds the ready-made body of a Setter / Getter that behaves exactly like a
## plain variable (Setter: `name = value`; Getter: `return name`) from nodes,
## so the person only has to add / change nodes. Does nothing when the node
## already has a body.
func _accessor_fill_starter(eid: int, vid: int) -> void:
	if not is_accessor_entry(eid) or not nodes.has(vid) or _exec_target(eid, 0) >= 0:
		return
	var vf: Dictionary = nodes[vid]["fields"]
	var vname: String = String(vf.get("name", "my_var"))
	var raw: String = String(vf.get("raw_type", "")).strip_edges()
	var vt: int = Types.type_from_name(raw) if raw != "" else Types.VARIANT
	var which: String = String(nodes[eid]["fields"]["accessor"])
	if which == "set":
		var args: Array = nodes[eid]["fields"].get("args", [])
		# a variable that is itself called `value` needs another argument
		# name, or the default body would read `value = value`
		if not args.is_empty() and String(nodes[int(args[0])]["fields"].get("name", "")) == vname:
			set_arg_prop(int(args[0]), "name", "new_value" if vname != "new_value" else "new_val")
		var sid: int = add_node(Kind.VARIABLE_SET, {"name": vname, "type": vt})
		connect_exec(eid, 0, sid)
		if not args.is_empty():
			connect_data(int(args[0]), 0, sid, 0)
	else:
		var gid: int = add_node(Kind.VARIABLE_GET, {"name": vname, "type": vt})
		var rid: int = add_node(Kind.RETURN)
		connect_exec(eid, 0, rid)
		connect_data(gid, 0, rid, 0)


## Writes the owner-side flags of a variable that just got (or lost) a node
## accessor.
func _accessor_sync_owner_flags(vid: int, which: String) -> void:
	if not nodes.has(vid):
		return
	var vf: Dictionary = nodes[vid]["fields"]
	if which == "get" and not accessor_entries_of(vid).has("set"):
		vf["get_first"] = true
	elif which == "set":
		vf["get_first"] = false
	vf["acc_mode"] = "nodes"


## Adds a Setter ("set") or Getter ("get") to a variable. The new node starts
## with a ready-made body that behaves exactly like a plain variable
## (Setter: `name = value`; Getter: `return name`), built from nodes, so the
## person only has to add / change nodes. Returns the entry id, -1 when
## rejected (already present, private variable, verbatim accessor block).
func add_accessor(vid: int, which: String) -> int:
	if which != "set" and which != "get":
		return -1
	if not accessor_nodes_allowed(vid):
		return -1
	if accessor_entries_of(vid).has(which):
		return -1
	var vname: String = String(nodes[vid]["fields"].get("name", "my_var"))
	var arg_name: String = "new_value" if vname == AccText.DEFAULT_ARG else AccText.DEFAULT_ARG
	var eid: int = _new_accessor_entry(vid, which, arg_name)
	_accessor_fill_starter(eid, vid)
	_accessor_sync_owner_flags(vid, which)
	return eid


## Node-menu route (the same way a Function is created): spawns a Setter /
## Getter node. It attaches itself to the first member variable that does not
## have that accessor yet; when there is none it starts unattached and the
## person picks the variable on the node (see set_accessor_owner). An
## unattached Setter / Getter is never written to the script.
func add_accessor_free(which: String) -> int:
	if which != "set" and which != "get":
		return -1
	for id: int in nodes:
		if accessor_nodes_allowed(id) and not accessor_entries_of(id).has(which):
			return add_accessor(id, which)
	var eid: int = _new_accessor_entry(-1, which)
	nodes[eid]["fields"]["owner_var"] = -1
	return eid


## The member variables a Setter / Getter node can be attached to: public,
## no verbatim accessor block, and not already carrying that accessor (the
## node's own variable stays in the list). [{id, name}] in declaration order.
func accessor_owner_candidates(eid: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not is_accessor_entry(eid):
		return out
	var which: String = String(nodes[eid]["fields"]["accessor"])
	var cur: int = int(nodes[eid]["fields"].get("owner_var", -1))
	for id: int in nodes:
		if int(nodes[id]["kind"]) != Kind.VAR_DECL:
			continue
		if id != cur and (not accessor_nodes_allowed(id) or accessor_entries_of(id).has(which)):
			continue
		out.append({"id": id, "name": String(nodes[id]["fields"].get("name", ""))})
	return out


## Attaches a Setter / Getter node to a variable (vid = -1 detaches it). A node
## without a body gets the ready-made one. Returns false (and sets
## last_reject_reason) when the variable cannot take it.
func set_accessor_owner(eid: int, vid: int) -> bool:
	last_reject_reason = ""
	if not is_accessor_entry(eid):
		return false
	var f: Dictionary = nodes[eid]["fields"]
	var which: String = String(f["accessor"])
	var old: int = int(f.get("owner_var", -1))
	if vid == old:
		return true
	if vid >= 0:
		if not nodes.has(vid) or int(nodes[vid]["kind"]) != Kind.VAR_DECL \
				or not accessor_nodes_allowed(vid):
			last_reject_reason = "A Setter / Getter belongs to a public member variable"
			return false
		if accessor_entries_of(vid).has(which):
			last_reject_reason = "That variable already has a %s" % ("Setter" if which == "set" else "Getter")
			return false
	f["owner_var"] = vid
	nodes[eid]["title"] = accessor_title(which, String(nodes[vid]["fields"].get("name", "")) if vid >= 0 else "")
	if vid >= 0:
		_accessor_fill_starter(eid, vid)
		_accessor_sync_owner_flags(vid, which)
	return true


## Removes a variable's Setter / Getter together with its whole body.
func remove_accessor(vid: int, which: String) -> bool:
	var acc: Dictionary = accessor_entries_of(vid)
	if not acc.has(which):
		return false
	remove_node(int(acc[which]))
	return true


## The generated lines of one Setter / Getter block, written one level inside
## the variable declaration.
func _emit_accessor_block(eid: int, out: PackedStringArray, emitted: Dictionary, seg_id: int) -> void:
	var vid: int = int(nodes[eid]["fields"].get("owner_var", -1))
	var which: String = String(nodes[eid]["fields"].get("accessor", "set"))
	var first: int = out.size()
	if which == "set":
		out.append("\tset(%s):" % _accessor_arg_name(eid))
	else:
		var paren: bool = bool(nodes.get(vid, {}).get("fields", {}).get("getter_paren", false))
		out.append("\tget():" if paren else "\tget:")
	var flowbuf: PackedStringArray = PackedStringArray()
	_cur_seg = seg_id
	var t: int = _exec_target(eid, 0)
	if t >= 0:
		_emit_flow(t, 1, flowbuf, emitted)
	else:
		flowbuf.append("\tpass")
	_cur_seg = 0
	for pvid: int in func_privates.get(eid, []):
		if emitted.has(pvid):
			continue
		var pfirst: int = out.size()
		for ln: String in _var_decl_text(pvid).split("\n"):
			out.append("\t\t" + ln)
		_line_marks.append([0, pfirst, out.size(), pvid])
	_seg_base[seg_id] = out.size()
	for el: String in flowbuf:
		var lines: PackedStringArray = el.split("\n")
		var shifted: PackedStringArray = PackedStringArray()
		for ln2: String in lines:
			shifted.append("\t" + ln2 if ln2 != "" else ln2)
		out.append("\n".join(shifted))
	_line_marks.append([0, first, out.size(), eid])


# ---- Property accessors (set / get) on member variables -----------------------
## The stored `tail` stays the single source of truth for generation. These
## helpers mirror it into structured fields so the Variable node can edit the
## setter and getter without any syntax:
##   fields.acc_mode   "struct"  the tail is exactly a setter and / or getter
##                               (or empty): edited through the form fields
##                     "raw"     an accessor block the form cannot show
##                               exactly (comments, one-line bodies): edited
##                               as one code box, kept verbatim
##                     "other"   not an accessor block (a lambda body): left
##                               alone, no accessor editing is offered
##   fields.has_setter / setter_arg / setter_body
##   fields.has_getter / getter_paren / getter_body / get_first / acc_unit
## Parsing never rewrites `tail`; it is only rebuilt when the user edits.
func _var_sync_accessors(id: int) -> void:
	if not nodes.has(id):
		return
	var f: Dictionary = nodes[id]["fields"]
	var tail: String = String(f.get("tail", ""))
	if tail == "" and _var_value_is_lambda(id):
		# A lambda default is not an accessor block: keep accessor editing
		# off for the node (stable across later re-syncs).
		f["acc_mode"] = "other"
		f["has_setter"] = false
		f["has_getter"] = false
		return
	var d: Dictionary = AccText.parse(tail)
	if bool(d["ok"]):
		f["acc_mode"] = "struct"
		f["has_setter"] = d["has_setter"]
		f["setter_arg"] = d["setter_arg"] if String(d["setter_arg"]) != "" else AccText.DEFAULT_ARG
		f["setter_body"] = d["setter_body"]
		f["has_getter"] = d["has_getter"]
		f["getter_paren"] = d["getter_paren"]
		f["getter_body"] = d["getter_body"]
		f["get_first"] = d["get_first"]
		f["acc_unit"] = d["unit"]
		return
	# An accessor block that cannot be shown exactly still has an accessor
	# header (`set(v):` / `get:`) at its top level; a lambda body never does.
	var re: RegEx = RegEx.new()
	re.compile("(?m)^(set|get)[ \\t]*(\\([^)]*\\))?[ \\t]*:")
	f["acc_mode"] = "raw" if re.search(tail) != null else "other"
	f["has_setter"] = false
	f["has_getter"] = false


## Makes sure the structured accessor fields exist (variables created in the
## editor never went through the parser).
func _var_ensure_accessors(id: int) -> void:
	if not nodes[id]["fields"].has("acc_mode"):
		_var_sync_accessors(id)


## Rebuilds `tail` from the structured accessor fields.
func _var_recompose_accessors(id: int) -> void:
	var f: Dictionary = nodes[id]["fields"]
	var d: Dictionary = {"has_setter": f.get("has_setter", false),
		"setter_arg": f.get("setter_arg", AccText.DEFAULT_ARG),
		"setter_body": f.get("setter_body", ""),
		"has_getter": f.get("has_getter", false),
		"getter_paren": f.get("getter_paren", false),
		"getter_body": f.get("getter_body", ""),
		"get_first": f.get("get_first", false),
		"unit": f.get("acc_unit", "\t")}
	var tail: String = AccText.compose(d)
	if tail == "":
		f.erase("tail")
	else:
		f["tail"] = tail


## True when a variable node can carry accessors at all (a top-level member
## variable that is not a function-local one).
func var_supports_accessors(id: int) -> bool:
	if not nodes.has(id) or int(nodes[id]["kind"]) != Kind.VAR_DECL:
		return false
	if String(nodes[id]["fields"].get("scope", "public")) == "private":
		return false
	# A lambda default is a Callable expression: accessor blocks would make
	# the declaration invalid GDScript (`var f := func(): ... : set ...`).
	if _var_value_is_lambda(id):
		return false
	_var_ensure_accessors(id)
	var amode: String = String(nodes[id]["fields"].get("acc_mode", "struct"))
	return amode != "other" and amode != "nodes"


## True when a variable's value pin is fed by a Lambda node (or its stored
## default text is a complete lambda that could not be reconstructed).
func _var_value_is_lambda(id: int) -> bool:
	if not nodes.has(id):
		return false
	var pin: Dictionary = nodes[id]["data_ins"][0]
	var l: Dictionary = connected_data_input(id, 0)
	if not l.is_empty():
		var src: int = int(l["from_id"])
		if nodes.has(src) and int(nodes[src]["kind"]) == Kind.LAMBDA:
			return true
	return _looks_like_lambda_start(str(pin["value"]))


## Applies one accessor edit coming from the node form. Returns false when the
## edit is not valid for the node's current state.
func _set_var_accessor_prop(id: int, key: String, value: String) -> bool:
	if not var_supports_accessors(id):
		return false
	var f: Dictionary = nodes[id]["fields"]
	var vname: String = String(f.get("name", ""))
	var mode: String = String(f.get("acc_mode", "struct"))
	if key == "tail":
		# raw accessor block (only reachable in "raw" mode, or to hand-write
		# one): kept as typed, then re-analysed
		var raw: String = value.strip_edges(false, true)
		if raw.strip_edges() == "":
			f.erase("tail")
		else:
			f["tail"] = raw
		# While a raw block is being typed it stays raw (re-analysing would
		# swap the editor under the caret); it is re-analysed on reload.
		if mode != "raw" or raw.strip_edges() == "":
			_var_sync_accessors(id)
		return true
	if mode != "struct":
		return false   # raw blocks are edited through "tail" only
	match key:
		"has_setter":
			var want: bool = value.strip_edges() == "true"
			if want == bool(f.get("has_setter", false)):
				return true
			f["has_setter"] = want
			if want and String(f.get("setter_body", "")).strip_edges() == "":
				f["setter_body"] = AccText.default_setter_body(vname, String(f.get("setter_arg", "")))
		"has_getter":
			var wantg: bool = value.strip_edges() == "true"
			if wantg == bool(f.get("has_getter", false)):
				return true
			f["has_getter"] = wantg
			if wantg and String(f.get("getter_body", "")).strip_edges() == "":
				f["getter_body"] = AccText.default_getter_body(vname)
		"setter_arg":
			var a: String = value.strip_edges()
			if a != "" and not _valid_ident(a):
				return false
			var old_arg: String = String(f.get("setter_arg", AccText.DEFAULT_ARG))
			var new_arg: String = a if a != "" else AccText.DEFAULT_ARG
			f["setter_arg"] = new_arg
			# the body follows the rename of its own parameter
			f["setter_body"] = _replace_ident(old_arg, new_arg, String(f.get("setter_body", "")))
		"setter":
			f["setter_body"] = value.strip_edges(false, true)
		"getter":
			f["getter_body"] = value.strip_edges(false, true)
		_:
			return false
	_var_recompose_accessors(id)
	return true


## A renamed variable (or function argument) is renamed in accessor blocks too.
func _var_rename_in_accessors(id: int, old: String, new: String) -> void:
	if not nodes.has(id) or old == "" or old == new:
		return
	var f: Dictionary = nodes[id]["fields"]
	var tail: String = String(f.get("tail", ""))
	if tail == "":
		return
	f["tail"] = _replace_ident(old, new, tail)
	_var_sync_accessors(id)


## Renders a Variable node's annotations: separate lines (canonical) or, when
## the source placed them inline on the declaration line, joined with spaces
## so the original style survives the round trip byte for byte.
func _var_ann_prefix(id: int, spfx: Dictionary) -> String:
	var n: Dictionary = nodes[id]
	var lines: PackedStringArray = spfx["lines"]
	if (lines as PackedStringArray).is_empty():
		return ""
	var inline_flag: bool = bool(n["fields"].get("ann_inline", false))
	var inline_text: String = str(n["fields"].get("inline_ann_text", "")).strip_edges()
	if inline_flag and inline_text != "":
		# Only the annotations that shared the declaration line join it; any
		# carried (own-line) annotations stay on their own lines above. The
		# inline chain is matched against the TRAILING prefix lines by normalised
		# text (annotation arguments may contain spaces, so token splitting is
		# not reliable).
		var chain_arr: PackedStringArray = _split_prefix(inline_text)["anns"] as PackedStringArray
		var chain: String = " ".join(chain_arr).strip_edges()
		if chain != "":
			var drop_from: int = -1
			var acc: PackedStringArray = PackedStringArray()
			for li: int in range(lines.size() - 1, -1, -1):
				acc.insert(0, String(lines[li]).strip_edges())
				var joined: String = " ".join(acc).strip_edges()
				if joined == chain:
					drop_from = li
					break
				if joined.length() > chain.length() + 2:
					break
			if drop_from >= 0:
				var rest: PackedStringArray = (lines as PackedStringArray).slice(0, drop_from)
				var outp: String = ""
				for a: String in rest:
					outp += a + "\n"
				return outp + chain + " "
		return " ".join(lines) + " "
	var outp2: String = ""
	for a: String in lines:
		outp2 += a + "\n"
	return outp2


## The generated text of a Variable node's declaration line (no indent).
## Annotations sit on their own lines (or inline when the source had them
## inline) and `static` stays on the declaration line itself.
func _var_decl_text(id: int) -> String:
	var n: Dictionary = nodes[id]
	var st: Dictionary = n["stmt"]
	var vname: String = String(n["fields"].get("name", st["name"]))
	var raw: String = String(n["fields"].get("raw_type", "")).strip_edges()
	var spfx: Dictionary = _static_prefix_lines(String(n["fields"].get("prefix", "")))
	var is_static: bool = bool(spfx["static"]) or bool(n["fields"].get("is_static", false))
	var head: String = _var_ann_prefix(id, spfx)
	var line: String = ("static " if is_static else "") + "var " + vname
	if raw != "":
		line += ": " + raw
	if bool(st["has_value"]) or not connected_data_input(id, 0).is_empty():
		var op: String = str(st.get("op", "="))
		var val: String = _resolve_pin(id, 0, 0)
		# A wired Lambda node already emits its body lines relative to the
		# declaration: do not dedent it like an ordinary block value.
		var lsrc: Dictionary = connected_data_input(id, 0)
		var is_lam: bool = not lsrc.is_empty() and int(nodes.get(int(lsrc["from_id"]), {}).get("kind", -1)) == Kind.LAMBDA
		if not is_lam:
			val = _dedent_block_value(val)
		line += " " + (op if op != "" else "=") + " " + val
	var tail: String = _var_decl_tail(id)
	if tail != "":
		line += ":"
	return head + line


## The generated text of a Variable node's declaration line (no indent).


## Rebuilds a Print node from parsed source: one occupied pin per printed
## value plus the trailing grow slot, so reopening a script restores the
## exact dynamic input structure. Returns -1 when the text is not a plain
## single-line print(...) call.
func _make_print_node(full: String, depth: int = 0) -> int:
	var text: String = full.strip_edges()
	if not text.begins_with("print(") or not text.ends_with(")") \
			or text.contains("\n"):
		return -1
	var inner: String = text.substr(6, text.length() - 7)
	var depth_check: int = 0
	for i: int in inner.length():
		var c: String = inner[i]
		if c == "(" or c == "[" or c == "{":
			depth_check += 1
		elif c == ")" or c == "]" or c == "}":
			depth_check -= 1
	if depth_check != 0:
		return -1
	var nid: int = _make_node(Kind.PRINT, depth)
	nodes[nid].body = text
	nodes[nid].exec_outs = ["\u25b6"]
	var parts: PackedStringArray = _split_top_commas(inner)
	var pins: Array = []
	for pr: String in parts:
		if pr.strip_edges() == "":
			continue
		pins.append({"name": "value" if pins.is_empty() else "value%d" % (pins.size() + 1),
			"type": Types.VARIANT, "value": pr.strip_edges()})
	nodes[nid].data_ins = pins
	_ensure_one_empty(nid)
	return nid


func _make_statement_node(full: String, depth: int = 0) -> int:
	# A plain single-line print(...) statement rebuilds as a Print node with
	# one occupied pin per printed value (dynamic inputs reconstructed).
	var pn: int = _make_print_node(full, depth)
	if pn >= 0:
		return pn
	var nid: int = _make_node(Kind.STATEMENT, depth)
	# A whole-statement call with a resolvable signature becomes a real
	# Function Call node (reconstruction on reopen; see _try_call_statement).
	if _try_call_statement(nid, full, depth):
		return nid
	var text: String = full.strip_edges()
	nodes[nid].body = text
	var stmt: Dictionary = _parse_stmt(text)
	if not stmt.is_empty():
		nodes[nid].stmt = stmt
		var vt: int = stmt.get("type", Types.VARIANT)
		nodes[nid].title = ("var %s" % stmt["name"]) if stmt["decl"] else ("set %s" % stmt["name"])
		if stmt["has_value"]:
			nodes[nid].data_ins = [{"name": "value", "type": vt, "value": stmt.get("rhs", "")}]
			_maybe_wire_lambda(nid, str(stmt.get("rhs", "")))
		nodes[nid].data_outs = [{"name": stmt["name"], "type": vt}]
		nodes[nid].exec_outs = ["\u25b6"]
	else:
		nodes[nid].title = "Statement"
		nodes[nid].exec_outs = ["\u25b6"]
	return nid


# ---- Statement parsing (assignment / declaration recognition) ----------------
## Recognises `var x[: T] [= expr]` and `lhs op expr` (op in = := += -= *= /= %=).
## Returns {} when the statement is opaque (kept verbatim).
## Recognizes a statement whose whole body is a single function call
## (`name(args...)` or `Owner.name(args...)`) and converts the node in place
## into a registry-backed Function Call node — this is how call references
## are reconstructed when a graph is rebuilt from a saved script. Calls whose
## signature cannot be resolved from real metadata stay opaque statements:
## nothing is invented.
func _try_call_statement(id: int, body: String, depth: int = 0) -> bool:
	var s: String = body.strip_edges()
	if s == "" or s.ends_with(":"):
		return false
	var open: int = s.find("(")
	if open <= 0 or not s.ends_with(")"):
		return false
	var name_part: String = s.substr(0, open)
	if name_part.contains(" ") or name_part.contains("=") \
			or name_part.contains(":") or name_part.contains("["):
		return false
	# the call must span the whole body: matching paren at the very end
	var pdepth: int = 0
	var in_str: bool = false
	var quote: String = ""
	for i: int in range(open, s.length()):
		var ch: String = s[i]
		if in_str:
			if ch == quote:
				in_str = false
			continue
		if ch == "\\" or ch == "'":
			in_str = true
			quote = ch
		elif ch == "(":
			pdepth += 1
		elif ch == ")":
			pdepth -= 1
			if pdepth == 0 and i != s.length() - 1:
				return false   # trailing junk after the call — keep opaque
	var e: Dictionary
	var fname: String = ""
	var dotted_owner: String = ""
	if name_part.contains("."):
		var dot: int = name_part.rfind(".")
		var fowner: String = name_part.substr(0, dot)
		fname = name_part.substr(dot + 1)
		if not _valid_ident(fname) or not _valid_ident(fowner):
			return false
		e = _resolve_dotted_call(fowner, fname)
		dotted_owner = fowner
	else:
		fname = name_part
		if not _valid_ident(fname):
			return false
		e = _resolve_plain_call(fname)
	if e.is_empty():
		# An unresolved call is only a Lambda node's home when a lambda
		# argument actually appears in the call text (e.g.
		# `modifiers.append(func(x: float) -> float: ...)`): rebuild the node
		# as a free-form Function Call so the lambda becomes a wired node
		# instead of opaque text. Calls without a lambda stay opaque.
		return _convert_lambda_call(id, body, depth)
	# parse the provided arguments positionally (top-level commas only)
	var provided: PackedStringArray = FuncReg._split_top_commas(
		s.substr(open + 1, s.length() - open - 2))
	var args: Array = (e["args"] as Array).duplicate(true)
	if provided.size() > args.size() and not bool(e.get("vararg", false)):
		return false
	var min_args: int = 0
	for a: Dictionary in args:
		if bool(a.get("required", true)):
			min_args += 1
	if provided.size() < min_args:
		return false
	# The call text's arguments are OVERRIDES of the declared defaults, not
	# new defaults: the declared default text stays on the argument (so an
	# untouched argument can be told apart from an overridden one) and the
	# provided text rides in `value` ("the call text wins: it is the call").
	var provided_values: Dictionary = {}
	for i: int in provided.size():
		if i < args.size():
			provided_values[str(args[i]["name"])] = provided[i]
	# rebuild this node as a registry-backed Function Call (same node id, so
	# every exec link the parser already created keeps pointing here)
	var is_entry_sig: bool = str(e["cat"]) == "entry"
	nodes[id]["kind"] = Kind.CALL
	nodes[id]["fields"] = {
		"call": fname, "cat": "" if is_entry_sig else str(e["cat"]),
		"owner": "" if is_entry_sig else str(e["owner"]),
		"ret": str(e.get("ret", "void")), "mode": "exec",
		"static": bool(e.get("static", false)),
		"needs_target": bool(e.get("needs_target", false)),
		"target_type": str(e.get("target_type", "")),
		"vararg": bool(e.get("vararg", false)),
		"args": args, "declared": true, "stale": false, "sig_changed": false,
		# a dotted call resolved against a class owner is a member call: it
		# gets the "Class" ownership output and links to a Class Reference
		"member": "method" if dotted_owner != "" else "",
	}
	nodes[id]["body"] = ""
	nodes[id]["stmt"] = {}
	nodes[id]["color"] = KIND_COLORS[Kind.CALL]
	_apply_call_meta(id, provided_values)
	if dotted_owner != "":
		_link_parsed_class_member(id, dotted_owner, e)
	# A call argument written as a lambda literal becomes a wired Lambda node
	# (e.g. `use(func(): pass)` on a known Callable parameter).
	_convert_lambda_pin_values(id, depth)
	# Variadic call text may provide more arguments than the declaration
	# names: the extra texts ride on the trailing grow slot(s).
	if bool(e.get("vararg", false)) and provided.size() > args.size():
		var vps: Array = nodes[id]["data_ins"]
		var extras: int = provided.size() - args.size()
		if vps.size() > 0:
			vps[vps.size() - 1]["value"] = str(provided[args.size()])
		for x: int in range(1, extras):
			vps.append({"name": _dyn_pin_name(id), "type": Types.VARIANT,
				"value": str(provided[args.size() + x])})
	return true


## Rebuilds a whole-statement call as a free-form Function Call node when at
## least one argument is a lambda literal (e.g.
## `modifiers.append(func(x: float) -> float: return x * 1.15)`). The lambda
## becomes its own wired Lambda node; other arguments keep their text.
## Returns false when the statement is not such a call (stays opaque).
func _convert_lambda_call(nid: int, body: String, depth: int) -> bool:
	var s: String = body.strip_edges()
	var open: int = s.find("(")
	if open <= 0 or not s.ends_with(")"):
		return false
	var name_part: String = s.substr(0, open)
	if name_part.contains(" ") or name_part.contains("\n") or name_part.contains("=") \
			or name_part.contains(":") or name_part.contains("["):
		return false
	for ch: String in name_part:
		if not (ch == "." or (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z")
				or (ch >= "0" and ch <= "9") or ch == "_"):
			return false
	if name_part.begins_with(".") or name_part.ends_with(".") or name_part.contains(".."):
		return false
	var argtext: String = s.substr(open + 1, s.length() - open - 2)
	var provided: PackedStringArray = _split_top_commas(argtext)
	if provided.is_empty():
		return false
	var lambda_at: Dictionary = {}
	for i: int in provided.size():
		if not _parse_lambda_value(provided[i]).is_empty():
			lambda_at[i] = true
	if lambda_at.is_empty():
		return false   # no lambda inside: leave the statement opaque
	# rebuild this node as a free-form (undeclared) Function Call
	nodes[nid]["kind"] = Kind.CALL
	nodes[nid]["fields"] = {"call": name_part, "mode": "exec", "declared": false,
		"member": "", "cat": "", "owner": "", "stale": false, "sig_changed": false}
	nodes[nid]["body"] = ""
	nodes[nid]["stmt"] = {}
	nodes[nid]["color"] = KIND_COLORS[Kind.CALL]
	nodes[nid]["title"] = name_part
	nodes[nid]["exec_in"] = true
	nodes[nid]["exec_outs"] = ["\u25b6"]
	var pins: Array = []
	for i: int in provided.size():
		var lid: int = -1
		if lambda_at.has(i):
			lid = _spawn_lambda_from_text(provided[i], depth)
			pins.append({"name": "arg%d" % (i + 1), "type": Types.PinType.CALLABLE,
				"value": "", "lam_id": lid})
		else:
			pins.append({"name": "arg%d" % (i + 1), "type": Types.VARIANT, "value": str(provided[i])})
	nodes[nid]["data_ins"] = pins
	nodes[nid]["data_outs"] = []
	for i: int in pins.size():
		var lsrc: int = int(pins[i].get("lam_id", -1))
		if lsrc >= 0:
			data_links.append({"from_id": lsrc, "from_out": 0, "to_id": nid, "to_in": i})
		pins[i].erase("lam_id")
	_ensure_one_empty(nid)
	return true


## Scans a registry-backed call's argument pins for complete lambda literals
## and converts each into a wired Lambda node (skipping the target pin).
func _convert_lambda_pin_values(cid: int, depth: int) -> void:
	var needs_target: bool = bool(nodes[cid]["fields"].get("needs_target", false))
	var pins: Array = nodes[cid]["data_ins"]
	for i: int in pins.size():
		if needs_target and i == 0:
			continue   # the target pin cannot take a Callable
		var pin: Dictionary = pins[i]
		if _looks_like_lambda_start(str(pin["value"])):
			var lid: int = _spawn_lambda_from_text(str(pin["value"]), depth)
			if lid >= 0:
				data_links.append({"from_id": lid, "from_out": 0, "to_id": cid, "to_in": i})
			pin["value"] = ""
			pin["type"] = Types.PinType.CALLABLE


## Resolves `Owner.name(...)` against the sources whose dotted form is
## directly callable in GDScript: static methods of engine/extension classes
## and custom classes, and every Autoload singleton method. Instance methods
## cannot be invoked on a bare class/type name, so those stay opaque. Ambiguous or unknown owners return {} (the statement is not guessed).
func _resolve_dotted_call(owner: String, fname: String) -> Dictionary:
	var cats: PackedStringArray = [FuncReg.CAT_GODOT_CLASS, FuncReg.CAT_CUSTOM,
		FuncReg.CAT_AUTOLOAD, FuncReg.CAT_EXTENSION]
	var found: Dictionary = {}
	for cat: String in cats:
		var e: Dictionary = FuncReg.get_registry().find_entry(cat, owner, fname)
		if not e.is_empty():
			if cat != FuncReg.CAT_AUTOLOAD and not bool(e["static"]):
				continue   # instance method: cannot be called on a bare name
			if not found.is_empty() and str(found["args"]) != str(e["args"]):
				return {}   # ambiguous: same call, different signatures
			found = e
	return found


## Resolves a plain `name(...)` call. Priority: same-script declarations
## (ENTRY nodes carry the live signature), the script's own base class
## (inherited methods are real self-calls), a uniquely named Autoload
## function, then unique global functions. Names that exist under several
## owners stay opaque statements rather than guessing.
func _resolve_plain_call(fname: String) -> Dictionary:
	for id: int in nodes:
		if int(nodes[id]["kind"]) == Kind.ENTRY \
				and String(nodes[id]["fields"].get("name", "")) == fname:
			return {"cat": "entry", "name": fname, "args": _entry_args(id),
				"owner": "", "ret": "", "static": false, "needs_target": false,
				"target_type": "", "vararg": false}
	var base: String = _extends_base()
	if base != "":
		var bm: Dictionary = _classdb_method_entry(base, fname)
		if not bm.is_empty():
			return bm
	var autos: Array[Dictionary] = FuncReg.get_registry().entries_for(
		FuncReg.CAT_AUTOLOAD)
	var auto_hit: Dictionary = {}
	var auto_count: int = 0
	for a: Dictionary in autos:
		if str(a["name"]) == fname:
			auto_count += 1
			auto_hit = a
	if auto_count == 1:
		return auto_hit
	return FuncReg.get_registry().find_entry(FuncReg.CAT_LANGUAGE, "", fname)


## The base class of the script this graph represents (from the extends
## header), "" when unknown or extends points at a non-ClassDB script.
func _extends_base() -> String:
	if _header_id < 0 or not nodes.has(_header_id):
		return ""
	var hdr: String = String(nodes[_header_id]["body"]).strip_edges()
	if not hdr.begins_with("extends "):
		return ""
	var base: String = hdr.substr(8).strip_edges().split("\n")[0].strip_edges()
	if base == "" or base == "self":
		return ""
	return base


## A ClassDB method of `base` (or its inheritance chain) as a signature
## record, {} when the method does not exist there.
func _classdb_method_entry(base: String, fname: String) -> Dictionary:
	if not ClassDB.class_exists(base):
		return {}
	for m: Dictionary in ClassDB.class_get_method_list(base, true):
		if str(m["name"]) != fname:
			continue
		var flags: int = int(m.get("flags", 0))
		if flags & METHOD_FLAG_STATIC != 0:
			return {}   # static self-calls use the class name, not the object
		var reg: RefCounted = FuncReg.get_registry()
		var args: Array[Dictionary] = []
		var adef: Array = m.get("args", [])
		var defaults: Array = m.get("default_args", [])
		for i: int in adef.size():
			var a: Dictionary = adef[i]
			# default_args lists the trailing optional arguments; every argument
			# BEFORE them is required (matches func_registry.gd's fixed logic).
			var req: bool = i < adef.size() - defaults.size()
			args.append({
				"name": str(a.get("name", "arg%d" % i)),
				"type": reg._variant_type_name(int(a.get("type", 0)), str(a.get("class_name", ""))),
				"default": "" if req else str(defaults[i - (adef.size() - defaults.size())]),
				"required": req,
			})
		return {"name": fname, "cat": FuncReg.CAT_GODOT_CLASS, "owner": base,
			"args": args,
			"ret": reg._variant_type_name(int(m["return"].get("type", 0)), str(m["return"].get("class_name", ""))),
			"static": false, "needs_target": false, "target_type": "",
			"vararg": flags & METHOD_FLAG_VARARG != 0}
	return {}


func _entry_args(eid: int) -> Array:
	var out: Array = []
	for aid: int in nodes[eid]["fields"].get("args", []):
		if not nodes.has(aid):
			continue
		out.append({
			"name": String(nodes[aid]["fields"].get("name", "arg")),
			"type": String(nodes[aid]["fields"].get("type", "")),
			"default": String(nodes[aid]["fields"].get("default", "")),
			"required": str(nodes[aid]["fields"].get("default", "")) == "",
		})
	return out


func _parse_stmt(text: String) -> Dictionary:
	var s: String = text.strip_edges()
	if s == "" or s.begins_with("#"):
		return {}
	if s.begins_with("var ") or s.begins_with("var\t"):
		var rest: String = s.substr(4).strip_edges()
		var sp: Dictionary = _split_assign(rest)
		var decl: Dictionary = {"decl": true, "has_value": false, "op": ""}
		if not sp.is_empty():
			decl["lhs"] = sp["lhs"]
			decl["rhs"] = sp["rhs"]
			decl["op"] = sp["op"]
			decl["has_value"] = true
		else:
			var colon: int = _find_typed_colon(rest)
			decl["lhs"] = rest if colon < 0 else rest.substr(0, colon).strip_edges()
			# Full declaration text (keeps type annotations like `var speed: float`).
			decl["lhs_full"] = rest
		decl["name"] = String(decl["lhs"]).strip_edges().split(":")[0].strip_edges()
		decl["type"] = _annotation_type(String(decl["lhs"]))
		if int(decl["type"]) == Types.VARIANT and bool(decl["has_value"]):
			# no explicit annotation: infer the pin type from the default value
			# (an explicit type annotation is never replaced)
			decl["type"] = _infer_literal_type(String(decl["rhs"]))
		return decl
	var sp2: Dictionary = _split_assign(s)
	if sp2.is_empty():
		return {}
	var lhs: String = sp2["lhs"]
	if lhs == "" or lhs.contains(" ") or lhs.begins_with("if ") or lhs.begins_with("while ") \
			or lhs.begins_with("for ") or lhs.begins_with("return") or lhs.begins_with("match "):
		return {}
	return {
		"decl": false, "lhs": lhs, "name": lhs, "type": Types.VARIANT,
		"op": sp2["op"], "has_value": true, "rhs": sp2["rhs"],
	}


## Infers a pin type from a default-value expression. Only safe literal forms
## are recognised; anything else stays Variant (never guessed).
func _infer_literal_type(rhs: String) -> int:
	var v: String = rhs.strip_edges()
	if v == "":
		return Types.VARIANT
	# A lambda literal is a Callable value (its body may hold anything, so
	# only the head text decides).
	if _looks_like_lambda_start(v) and not _split_lambda_head(v).is_empty():
		return Types.PinType.CALLABLE
	if v == "true" or v == "false":
		return Types.PinType.BOOL
	if v.is_valid_int() and not v.begins_with("\""):
		return Types.PinType.INT
	if v.is_valid_float():
		return Types.PinType.FLOAT
	if v.begins_with("\"") and v.ends_with("\"") and v.length() >= 2:
		return Types.PinType.STRING
	if v.begins_with("Vector2(") or v.begins_with("Vector2.ZERO") or v.begins_with("Vector2.ONE") \
			or v.begins_with("Vector2.INF") or v.begins_with("Vector2.LEFT") \
			or v.begins_with("Vector2.RIGHT") or v.begins_with("Vector2.UP") \
			or v.begins_with("Vector2.DOWN"):
		return Types.PinType.VECTOR2
	if v.begins_with("Vector3(") or v.begins_with("Vector3.ZERO") or v.begins_with("Vector3.ONE") \
			or v.begins_with("Vector3.FORWARD") or v.begins_with("Vector3.UP") \
			or v.begins_with("Vector3.DOWN") or v.begins_with("Vector3.LEFT") \
			or v.begins_with("Vector3.RIGHT") or v.begins_with("Vector3.BACK"):
		return Types.PinType.VECTOR3
	if v.begins_with("Color(") or v.begins_with("Color."):
		return Types.PinType.COLOR
	if v.begins_with("["):
		return Types.PinType.ARRAY
	if v.begins_with("{"):
		return Types.PinType.DICTIONARY
	return Types.VARIANT


func _annotation_type(lhs: String) -> int:
	var parts: PackedStringArray = lhs.split(":")
	if parts.size() >= 2:
		return Types.type_from_name(parts[1])
	return Types.VARIANT


func _find_typed_colon(s: String) -> int:
	# The annotation colon of `x: int` (first colon at depth 0 outside strings).
	var depth: int = 0
	var q: String = ""
	for i: int in s.length():
		var c: String = s[i]
		if q != "":
			if c == "\\":
				i += 1
				continue
			if c == q:
				q = ""
		elif c == "\"" or c == "'":
			q = c
		elif c in ["(", "[", "{"]:
			depth += 1
		elif c in [")", "]", "}"]:
			depth -= 1
		elif c == ":" and depth == 0:
			return i
	return -1


## Finds the first real assignment operator outside strings/brackets.
func _split_assign(s: String) -> Dictionary:
	var depth: int = 0
	var q: String = ""
	var i: int = 0
	while i < s.length():
		var c: String = s[i]
		if q != "":
			if c == "\\":
				i += 2
				continue
			if c == q:
				q = ""
			i += 1
			continue
		if c == "\"" or c == "'":
			q = c
			i += 1
			continue
		if c in ["(", "[", "{"]:
			depth += 1
			i += 1
			continue
		if c in [")", "]", "}"]:
			depth -= 1
			i += 1
			continue
		if c == "#" and depth == 0:
			break   # rest is a comment
		if c == "=" and depth == 0:
			if i + 1 < s.length() and s[i + 1] == "=":
				i += 2
				continue
			var prev: String = s[i - 1] if i > 0 else " "
			var op: String = ""
			if prev in ["+", "-", "*", "/", "%"]:
				op = prev + "="
				return {"lhs": s.substr(0, i - 1).strip_edges(), "op": op, "rhs": s.substr(i + 1).strip_edges()}
			elif prev == ":":
				return {"lhs": s.substr(0, i - 1).strip_edges(), "op": ":=", "rhs": s.substr(i + 1).strip_edges()}
			elif prev in ["!", "<", ">", "="]:
				i += 1
				continue
			else:
				return {"lhs": s.substr(0, i).strip_edges(), "op": "=", "rhs": s.substr(i + 1).strip_edges()}
		i += 1
	return {}


# ---- Links -------------------------------------------------------------------
## `from` is {"id", "port"} (an exec output pin). `to` is a node id or a
## handle {"id"} pointing at that node's (single) exec input.
func _link_exec(from: Dictionary, to: Variant, _to_port: int = 0) -> void:
	if to is Dictionary:
		if to.is_empty():
			return   # no continuation
		to = int(to["id"])
	var to_id: int = int(to)
	if from.is_empty() or to_id < 0:
		return
	var fid: int = int(from["id"])
	var fport: int = int(from["port"])
	if not nodes.has(fid) or not nodes.has(to_id):
		return
	if not exec_out[fid].has(fport):
		exec_out[fid][fport] = to_id
		exec_in[to_id].append({"from_id": fid, "from_port": fport})


func _exec_target(id: int, port: int) -> int:
	var m: Dictionary = exec_out.get(id, {})
	if m.has(port):
		return int(m[port])
	return -1


func incoming_exec(id: int) -> int:
	return exec_in.get(id, []).size()


# ---- Match branch management -------------------------------------------------
## Renames a match branch label. The last exec_out port is the fixed
## "after" fall-through and cannot be renamed; labels must be single-line
## pattern text ("_", literals, bindings) and never "after".
func set_match_branch(id: int, port: int, label: String) -> bool:
	if not nodes.has(id) or int(nodes[id]["kind"]) != Kind.MATCH:
		return false
	var outs: Array = nodes[id]["exec_outs"]
	if port < 0 or port >= outs.size() - 1:
		return false
	var t: String = label.strip_edges()
	if t.ends_with(":"):
		t = t.trim_suffix(":")
	if t == "" or t.contains("\n") or t == "after":
		return false
	outs[port] = t
	return true


## Adds a match branch before the "after" fall-through pin (its existing
## wire moves with the pin). Default label: the first unused integer pattern
## (`0`, `1`, ...) - a valid GDScript pattern, so adding a branch never makes
## the generated script stop compiling.
func add_match_branch(id: int, label: String = "") -> bool:
	if not nodes.has(id) or int(nodes[id]["kind"]) != Kind.MATCH:
		return false
	var outs: Array = nodes[id]["exec_outs"]
	var t: String = label.strip_edges()
	if t == "" or t.contains("\n") or t == "after":
		var n: int = 0
		while outs.has(str(n)) or outs.has("%d:" % n):
			n += 1
		t = str(n)
	var old_after: int = outs.size() - 1
	outs.insert(old_after, t)
	_move_exec_out_port(id, old_after, outs.size() - 1)
	return true


## Removes a match branch (its wire is dropped; later branch ports shift
## down so remaining wires stay on their patterns). At least one branch
## plus the "after" pin always remain.
func remove_match_branch(id: int, port: int) -> bool:
	if not nodes.has(id) or int(nodes[id]["kind"]) != Kind.MATCH:
		return false
	var outs: Array = nodes[id]["exec_outs"]
	if outs.size() <= 2 or port < 0 or port >= outs.size() - 1:
		return false
	outs.remove_at(port)
	_drop_exec_out_port(id, port)
	return true


## Moves one exec-output port's wire from `from_port` to `to_port`
## (including back-references in the targets' exec_in lists).
func _move_exec_out_port(id: int, from_port: int, to_port: int) -> void:
	if from_port == to_port or not exec_out.has(id):
		return
	var m: Dictionary = exec_out[id]
	if not m.has(from_port):
		return
	m[to_port] = m[from_port]
	m.erase(from_port)
	for tgt: int in exec_in:
		for l: Dictionary in exec_in[tgt]:
			if int(l["from_id"]) == id and int(l["from_port"]) == from_port:
				l["from_port"] = to_port


## Drops the wire at exec-output port `port` and shifts later ports down so
## the remaining wires stay on their (now shifted) branch patterns.
func _drop_exec_out_port(id: int, port: int) -> void:
	if not exec_out.has(id):
		return
	var m: Dictionary = exec_out[id]
	var remap: Dictionary = {}
	for p: int in m:
		if int(p) < port:
			remap[int(p)] = m[p]
		elif int(p) > port:
			remap[int(p) - 1] = m[p]
	if remap.is_empty():
		exec_out.erase(id)
	else:
		exec_out[id] = remap
	for tgt: int in exec_in:
		var arr: Array = exec_in[tgt]
		var i: int = 0
		while i < arr.size():
			var l: Dictionary = arr[i]
			if int(l["from_id"]) == id:
				var fp: int = int(l["from_port"])
				if fp == port:
					arr.remove_at(i)
					continue
				elif fp > port:
					l["from_port"] = fp - 1
			i += 1


# ---- Connection validation ----------------------------------------------------
## May `from_id/from_port` (exec out) connect to `to_id` (exec in)?
func can_connect_exec(from_id: int, from_port: int, to_id: int) -> bool:
	if not nodes.has(from_id) or not nodes.has(to_id):
		return false
	if from_id == to_id:
		return false
	if not nodes[to_id]["exec_in"]:
		return false
	if not exec_out[from_id].is_empty() and int(from_port) >= _out_pin_count(from_id, true):
		return false
	# Reject cycles: `from_id` must not be reachable downstream of `to_id`.
	if _exec_reaches(to_id, from_id):
		return false
	return true


func _exec_reaches(start: int, target: int) -> bool:
	var seen: Dictionary = {}
	var stack: Array = [start]
	while not stack.is_empty():
		var cur: int = stack.pop_back()
		if cur == target:
			return true
		if seen.has(cur):
			continue
		seen[cur] = true
		for port: int in exec_out.get(cur, {}):
			stack.append(int(exec_out[cur][port]))
	return false


func _out_pin_count(id: int, exec_only: bool) -> int:
	var n: Dictionary = nodes[id]
	if exec_only:
		return n["exec_outs"].size()
	return n["data_outs"].size()


## May `from_id/from_out` (data out) connect to `to_id/to_in` (data in)?
## Type compatibility, no cycles, data inputs hold a single link.
func can_connect_data(from_id: int, from_out: int, to_id: int, to_in: int) -> bool:
	if not nodes.has(from_id) or not nodes.has(to_id):
		return false
	if from_id == to_id:
		return false
	var tn: Dictionary = nodes[to_id]
	var fn: Dictionary = nodes[from_id]
	if int(tn["kind"]) == Kind.ENTRY:
		return false   # a Function's left pins register Argument nodes (see register_argument)
	if int(to_in) >= tn["data_ins"].size() or int(from_out) >= fn["data_outs"].size():
		return false
	var fk: int = int(fn["kind"])
	if fk == Kind.ARGUMENT and int(from_out) >= 1:
		# The Argument's second output is the Function connection pin: it only
		# ever wires into the parent Function's registration slot.
		_set_reject("The Function connection pin only wires into a Function's argument slot")
		return false
	if fk == Kind.VAR_DECL and str(fn["fields"].get("scope", "public")) == "private" \
			and int(from_out) == 0:
		# A private variable's value pin only feeds its assigned scope (the
		# scope registrations from its scope pin decide, else the owner).
		var posv: Dictionary = _ref_position(to_id)
		if not _private_pos_allowed(from_id, posv):
			_set_reject("Private variable is scoped elsewhere (use its scope pin)")
			return false
	if fk == Kind.VARIABLE_GET and str(fn["fields"].get("name", "")) != "":
		# The Get reference must be in scope where its consumer sits.
		var info: Dictionary = _scope_of_name(str(fn["fields"].get("name", "")))
		if str(info["kind"]) in ["private", "local"]:
			var pos2: Dictionary = _ref_position(to_id)
			if not _private_pos_allowed(int(info["decl"]), pos2):
				return false
			if not scope_links_of(int(info["decl"])).is_empty() \
					and bool(info.get("block", false)) \
					and int(pos2["node"]) != int(info["decl"]) \
					and not _flow_reaches(int(info["decl"]), int(pos2["node"])):
				return false
	var ft: int = int(fn["data_outs"][from_out]["type"])
	var tt: int = int(tn["data_ins"][to_in]["type"])
	# full type identity: object classes, enums and typed containers are
	# validated against real Godot rules (inheritance, element types)
	var ftext: String = _pin_type_text(fn, true, from_out)
	var ttext: String = _pin_type_text(tn, false, to_in)
	# a pin's full type text refines its pin class (a statement writing to an
	# int variable is an int pin even though its slot stays Variant)
	if ftext != "":
		ft = FuncReg.pin_type_of(ftext)
	if ttext != "":
		tt = FuncReg.pin_type_of(ttext)
	if not Types.compatible(ft, tt):
		_set_reject("Cannot connect %s to %s (pin type mismatch)" % [Types.type_name(ft), Types.type_name(tt)])
		return false
	if ftext != "" and ttext != "" \
			and not TypeReg.get_registry().is_compatible(ftext, ttext):
		_set_reject("Cannot connect %s to %s (incompatible types)" % [ftext, ttext])
		return false
	if _data_reaches(to_id, from_id) or _depends_on(from_id, to_id):
		_set_reject("That connection would make the node depend on itself (a loop).")
		return false
	last_reject_reason = ""
	return true


func _set_reject(reason: String) -> void:
	last_reject_reason = reason


## The full type text of one data pin ("" when the pin is untyped/Variant).
## Object classes, enums and typed containers carry their real identity here
## so connections and autocomplete work on Godot-accurate types.
func _pin_type_text(n: Dictionary, is_out: bool, idx: int) -> String:
	var pins: Array = n["data_outs"] if is_out else n["data_ins"]
	if idx >= pins.size():
		return ""
	var pin: Dictionary = pins[idx]
	if pin.has("type_text"):
		return str(pin["type_text"])
	var k: int = int(n["kind"])
	if not is_out and k == Kind.CALL and bool(n["fields"].get("needs_target", false)) and idx == 0:
		var tt: String = str(n["fields"].get("target_type", ""))
		return "" if tt == "" else tt
	if k == Kind.CALL:
		var pins0: Array = pins
		if idx < pins0.size() and bool(pins0[idx].get("member", false)):
			return ""   # the "Class" ownership pin: type MEMBER, no class identity
		var args: Array = n["fields"].get("args", [])
		var ai: int = idx - (1 if (bool(n["fields"].get("needs_target", false)) and not is_out) else 0)
		if ai >= 0 and ai < args.size():
			return str(args[ai].get("type", ""))
		return ""
	if k == Kind.VAR_DECL:
		return str(n["fields"].get("raw_type", "")).strip_edges()
	if k == Kind.STATEMENT and not n["stmt"].is_empty() \
			and bool(n["stmt"].get("has_value", false)) and not bool(n["stmt"].get("decl", false)):
		# an assignment to a variable takes that variable's annotation
		return _var_decl_raw_type(str(n["stmt"].get("lhs", "")))
	if k == Kind.ARGUMENT and is_out:
		return str(n["fields"].get("type", "")).strip_edges()
	if k == Kind.VARIABLE_GET and is_out or k == Kind.VARIABLE_SET and not is_out:
		return _var_decl_raw_type(str(n["fields"].get("name", "")))
	if k == Kind.ENTRY and is_out:
		return str(n["fields"].get("ret_type", "")).strip_edges()
	return ""


## The raw type annotation of a declared variable ("" when untyped).
## Retypes every Get/Set reference of a variable after its annotation changed:
## the reference pins follow the declaration's type (this is how a type change
## propagates downstream without touching connected wires).
func _retype_var_refs(vname: String, t: int, text: String) -> void:
	if vname == "":
		return
	for id: int in nodes:
		var k: int = int(nodes[id]["kind"])
		if k != Kind.VARIABLE_GET and k != Kind.VARIABLE_SET:
			continue
		if str(nodes[id]["fields"].get("name", "")) != vname:
			continue
		if k == Kind.VARIABLE_GET and nodes[id]["data_outs"].size() > 0:
			nodes[id]["data_outs"][0]["type"] = t
		if k == Kind.VARIABLE_SET and nodes[id]["data_ins"].size() > 0:
			nodes[id]["data_ins"][0]["type"] = t
		_validate_out_links(id, 0)
		_validate_in_links(id, 0)


func _var_decl_raw_type(vname: String) -> String:
	if vname == "":
		return ""
	for id: int in nodes:
		if int(nodes[id]["kind"]) != Kind.VAR_DECL:
			continue
		if str(nodes[id]["fields"].get("name", "")) != vname:
			continue
		return str(nodes[id]["fields"].get("raw_type", "")).strip_edges()
	return ""


func _data_reaches(start: int, target: int) -> bool:
	var seen: Dictionary = {}
	var stack: Array = [start]
	while not stack.is_empty():
		var cur: int = stack.pop_back()
		if cur == target:
			return true
		if seen.has(cur):
			continue
		seen[cur] = true
		for l: Dictionary in data_links:
			if int(l["from_id"]) == cur:
				stack.append(int(l["to_id"]))
	return false


func connected_data_input(to_id: int, to_in: int) -> Dictionary:
	for l: Dictionary in data_links:
		if int(l["to_id"]) == to_id and int(l["to_in"]) == to_in:
			return l
	return {}


## The link feeding data input `to_in` of node `to_id`, {} when unwired.
func _connected_data_source(to_id: int, to_in: int) -> Dictionary:
	return connected_data_input(to_id, to_in)


func connect_exec(from_id: int, from_port: int, to_id: int) -> bool:
	if not can_connect_exec(from_id, from_port, to_id):
		return false
	if _exec_target(from_id, int(from_port)) == to_id:
		return true   # already connected, nothing to do
	exec_out[from_id][int(from_port)] = to_id
	exec_in[to_id].append({"from_id": from_id, "from_port": int(from_port)})
	return true


func disconnect_exec(from_id: int, from_port: int, to_id: int) -> void:
	if not exec_out.has(from_id):
		return
	var port: int = int(from_port)
	if exec_out[from_id].get(port, -1) == to_id:
		exec_out[from_id].erase(port)
	var arr: Array = exec_in.get(to_id, [])
	for i: int in arr.size():
		if int(arr[i]["from_id"]) == from_id and int(arr[i]["from_port"]) == port:
			arr.remove_at(i)
			break


func connect_data(from_id: int, from_out: int, to_id: int, to_in: int) -> Dictionary:
	## Returns the replaced link ({} when none) or null when rejected.
	if not nodes.has(to_id) or not nodes.has(from_id):
		return {"_rejected": true}
	# A declaration's "add annotation" slot never carries value flow: wiring
	# an Annotation node into it registers the annotation instead (like
	# argument registration on Function nodes, no data_links are involved).
	var tn0: Dictionary = nodes[to_id]
	if int(to_in) < tn0["data_ins"].size() \
			and String(tn0["data_ins"][int(to_in)]["name"]) == "add annotation" \
			and int(tn0["data_ins"][int(to_in)]["type"]) == Types.PinType.ANNOTATION:
		if int(nodes[from_id]["kind"]) == Kind.ANNOTATION \
				and int(from_out) < nodes[from_id]["data_outs"].size() \
				and int(nodes[from_id]["data_outs"][int(from_out)]["type"]) == Types.PinType.ANNOTATION:
			if String(nodes[from_id]["data_outs"][int(from_out)]["name"]) == "group":
				last_reject_reason = "@export_group connects through its group pin (an @export node's add group input)"
				return {"_rejected": true}
			return {} if register_annotation(to_id, from_id) >= 0 else {"_rejected": true}
		return {"_rejected": true}
	# A per-annotation input pin registers the Annotation node AT that
	# annotation: the pin keeps its position, the annotation's text is
	# replaced by the node's text (replace semantics, visible wire).
	if int(to_in) < tn0["data_ins"].size() \
			and bool(tn0["data_ins"][int(to_in)].get("ann", false)) \
			and int(tn0["data_ins"][int(to_in)]["type"]) == Types.PinType.ANNOTATION:
		var aslot: int = _annotation_pin_slot(to_id, int(to_in))
		if int(nodes[from_id]["kind"]) == Kind.ANNOTATION \
				and int(from_out) < nodes[from_id]["data_outs"].size() \
				and int(nodes[from_id]["data_outs"][int(from_out)]["type"]) == Types.PinType.ANNOTATION \
				and String(nodes[from_id]["data_outs"][int(from_out)]["name"]).begins_with("@"):
			return {} if register_annotation(to_id, from_id, 2, aslot) >= 0 else {"_rejected": true}
		return {"_rejected": true}
	# The Script Header's dedicated metadata slots register the Script Class
	# Name / Script Extension nodes (one of each per header, visible wires).
	var meta_kind: String = String(tn0["data_ins"][int(to_in)]["name"]) \
			if int(to_in) < tn0["data_ins"].size() else ""
	if meta_kind == "class name" or meta_kind == "extends":
		var want: int = Kind.CLASS_NAME if meta_kind == "class name" else Kind.EXTENDS_DECL
		if int(nodes[from_id]["kind"]) == want \
				and int(from_out) < nodes[from_id]["data_outs"].size() \
				and int(nodes[from_id]["data_outs"][int(from_out)]["type"]) == Types.PinType.ANNOTATION:
			return {} if register_header_link(to_id, from_id) >= 0 else {"_rejected": true}
		last_reject_reason = ("Only a Script Class Name node connects to the class name pin"
			if meta_kind == "class name"
			else "Only a Script Extension node connects to the extends pin")
		return {"_rejected": true}
	# A scope-owning node's "add scope" slot never carries value flow: wiring
	# a private variable's scope output into it registers the scope (visible
	# wire, no data_links involved).
	if int(to_in) < tn0["data_ins"].size() \
			and int(tn0["data_ins"][int(to_in)]["type"]) == Types.PinType.SCOPE:
		if int(nodes[from_id]["kind"]) == Kind.VAR_DECL \
				and int(from_out) < nodes[from_id]["data_outs"].size() \
				and int(nodes[from_id]["data_outs"][int(from_out)]["type"]) == Types.PinType.SCOPE:
			return {} if register_scope(to_id, from_id) else {"_rejected": true}
		return {"_rejected": true}
	# An export annotation's "add group" slot never carries value flow:
	# wiring an @export_group node's "group" output here registers the group
	# association (visible wire, no data_links involved).
	if int(to_in) < tn0["data_ins"].size() \
			and String(tn0["data_ins"][int(to_in)]["name"]) == "add group" \
			and int(tn0["data_ins"][int(to_in)]["type"]) == Types.PinType.ANNOTATION:
		if int(nodes[from_id]["kind"]) == Kind.ANNOTATION \
				and int(from_out) < nodes[from_id]["data_outs"].size() \
				and String(nodes[from_id]["data_outs"][int(from_out)]["name"]) == "group":
			return {} if register_group(to_id, from_id) >= 0 else {"_rejected": true}
		return {"_rejected": true}
	# A Class Reference's "add member" slot (and its per-member slot rows)
	# never carry value flow: wiring a member node's "Class" output into one
	# registers the member with that reference (visible wire, like argument /
	# annotation registration — no data_links are involved).
	if int(tn0["kind"]) == Kind.CLASS_REF and int(to_in) < tn0["data_ins"].size() \
			and int(tn0["data_ins"][int(to_in)]["type"]) == Types.PinType.MEMBER:
		if int(nodes[from_id]["kind"]) == Kind.CALL \
				and int(from_out) < nodes[from_id]["data_outs"].size() \
				and int(nodes[from_id]["data_outs"][int(from_out)]["type"]) == Types.PinType.MEMBER:
			var pre: String = _member_fit_problem(to_id, from_id)
			if pre != "":
				last_reject_reason = pre
				return {"_rejected": true}
			if String(tn0["data_ins"][int(to_in)]["name"]) == "add member":
				return {} if register_member(to_id, from_id) >= 0 else {"_rejected": true}
			# wiring into an occupied member slot moves that member's slot here
			var has_inst0: bool = tn0["data_ins"].size() > 0 \
				and String(tn0["data_ins"][0].get("name", "")) == "instance"
			var midx0: int = int(to_in) - (1 if has_inst0 else 0)
			var occupants: Array[int] = []
			for ml: Dictionary in member_links:
				if int(ml["rid"]) == to_id:
					occupants.append(int(ml["cid"]))
			if midx0 >= 0 and midx0 < occupants.size():
				var victim: int = int(occupants[midx0])
				if victim != from_id:
					unregister_member(to_id, victim)
					return {} if register_member(to_id, from_id, midx0) >= 0 else {"_rejected": true}
			return {}   # the same member: nothing changes
		last_reject_reason = "Only member nodes connect to a Class Reference's member slots"
		return {"_rejected": true}
	if not can_connect_data(from_id, from_out, to_id, to_in):
		return {"_rejected": true}
	var replaced: Dictionary = connected_data_input(to_id, to_in)
	if not replaced.is_empty():
		disconnect_data(int(replaced["from_id"]), int(replaced["from_out"]), to_id, to_in)
	data_links.append({
		"from_id": from_id, "from_out": int(from_out),
		"to_id": to_id, "to_in": int(to_in),
	})
	# Dynamic-input invariant: connecting the grow slot immediately opens a
	# fresh empty slot, so there is always exactly one free input available.
	if is_dynamic_input_node(to_id):
		var pol: Dictionary = _dyn_policy(int(nodes[to_id]["kind"]))
		var maxp: int = int(pol.get("max", -1))
		var pins: Array = nodes[to_id]["data_ins"]
		if maxp < 0 or pins.size() < maxp:
			_ensure_one_empty(to_id)
	# A comparison wired into an If / Else If condition input becomes the If's
	# only condition: any stored (now conflicting) expression is dropped.
	if int(nodes[to_id]["kind"]) in [Kind.IF, Kind.ELIF] and int(to_in) == 0 \
			and int(nodes[from_id]["kind"]) == Kind.OPERATOR \
			and _op_is_comparison(str(nodes[from_id]["fields"].get("op", "+"))):
		nodes[to_id]["data_ins"][0]["value"] = ""
		nodes[to_id]["body"] = ""
	return replaced


func disconnect_data(from_id: int, from_out: int, to_id: int, to_in: int) -> void:
	for i: int in data_links.size():
		var l: Dictionary = data_links[i]
		if int(l["from_id"]) == from_id and int(l["from_out"]) == from_out \
				and int(l["to_id"]) == to_id and int(l["to_in"]) == to_in:
			data_links.remove_at(i)
			if nodes.has(to_id) and is_dynamic_input_node(to_id):
				_trim_trailing_empties(to_id)
			return


func remove_node(id: int) -> void:
	if not nodes.has(id):
		return
	var kind: int = int(nodes[id]["kind"])
	if kind == Kind.ARGUMENT:
		for i: int in range(arg_links.size() - 1, -1, -1):
			if int(arg_links[i]["aid"]) == id:
				arg_links.remove_at(i)
		var pid: int = int(nodes[id]["fields"].get("parent", -1))
		if pid >= 0 and nodes.has(pid):
			var lst: Array = nodes[pid]["fields"].get("args", [])
			lst.erase(id)
			nodes[pid]["fields"]["args"] = lst
			nodes[pid]["sig"] = _sig_text(pid)
			nodes[pid]["body"] = nodes[pid]["sig"]
			_entry_sync_pins(pid)
			_resync_calls_for(String(nodes[pid]["fields"].get("name", "")))
	if kind == Kind.ANNOTATION:
		# Deleting an Annotation node drops its registrations but keeps the
		# annotation lines it wrote (annotations must never be lost silently).
		for i: int in range(ann_links.size() - 1, -1, -1):
			if int(ann_links[i]["aid"]) == id:
				ann_links.remove_at(i)
	if kind == Kind.VAR_DECL:
		for eid3: int in func_privates:
			func_privates[eid3].erase(id)
		for acc_eid: Variant in accessor_entries_of(id).values():
			remove_node(int(acc_eid))
	if kind == Kind.ENTRY:
		for i: int in range(arg_links.size() - 1, -1, -1):
			if int(arg_links[i]["eid"]) == id:
				arg_links.remove_at(i)
		for i: int in range(ann_links.size() - 1, -1, -1):
			if int(ann_links[i]["tid"]) == id:
				ann_links.remove_at(i)
		for vid: int in func_privates.get(id, []):
			if nodes.has(vid):
				nodes[vid]["fields"]["scope"] = "public"
				nodes[vid]["fields"]["owner"] = -1
				_var_sync_scope_pin(vid)
		func_privates.erase(id)
		# Deleting an event deletes its whole flow.
		var reach: Dictionary = {}
		var stack: Array = [id]
		while not stack.is_empty():
			var cur: int = stack.pop_back()
			if reach.has(cur):
				continue
			reach[cur] = true
			for port: int in exec_out.get(cur, {}):
				stack.append(int(exec_out[cur][port]))
		for aid: int in nodes[id]["fields"].get("args", []):
			for i: int in range(arg_links.size() - 1, -1, -1):
				if int(arg_links[i]["aid"]) == aid:
					arg_links.remove_at(i)
			if nodes.has(aid):
				_remove_node_links(aid)
				nodes.erase(aid)
		for rid: int in reach:
			_remove_node_links(rid)
			if nodes.has(rid) and int(nodes[rid]["kind"]) == Kind.PREAMBLE:
				pass
			nodes.erase(rid)
		roots = roots.filter(func(r: Dictionary) -> bool: return not (r.has("entry") and not nodes.has(int(r["entry"]))))
		return
	_remove_node_links(id)
	match kind:
		Kind.PREAMBLE, Kind.VAR_DECL, Kind.CONST_DECL, Kind.SIGNAL_DECL, Kind.DECLARATION:
			roots = roots.filter(func(r: Dictionary) -> bool: return not (r.has("node") and int(r["node"]) == id))
	nodes.erase(id)


func _remove_node_links(id: int) -> void:
	var resync_refs: Array[int] = []
	for i: int in range(member_links.size() - 1, -1, -1):
		var ml: Dictionary = member_links[i]
		if int(ml["rid"]) == id or int(ml["cid"]) == id:
			if int(ml["cid"]) == id and int(ml["rid"]) != id and not resync_refs.has(int(ml["rid"])):
				resync_refs.append(int(ml["rid"]))
			member_links.remove_at(i)
	var scope_resync: Array[int] = []
	for i: int in range(scope_links.size() - 1, -1, -1):
		var sl: Dictionary = scope_links[i]
		if int(sl["tid"]) == id or int(sl["vid"]) == id:
			if int(sl["vid"]) == id and int(sl["tid"]) != id and not scope_resync.has(int(sl["tid"])):
				scope_resync.append(int(sl["tid"]))
			scope_links.remove_at(i)
	for sh: int in scope_resync:
		if nodes.has(sh):
			_add_scope_slot(sh)
	for i2: int in range(group_links.size() - 1, -1, -1):
		var gl: Dictionary = group_links[i2]
		if int(gl["gid"]) == id or int(gl["xid"]) == id:
			group_links.remove_at(i2)
	for i3: int in range(header_links.size() - 1, -1, -1):
		var hl: Dictionary = header_links[i3]
		if int(hl["hid"]) == id or int(hl["nid"]) == id:
			header_links.remove_at(i3)
	if exec_out.has(id):
		for port: int in exec_out[id]:
			var t: int = int(exec_out[id][port])
			var arr: Array = exec_in.get(t, [])
			for i: int in arr.size():
				if int(arr[i]["from_id"]) == id:
					arr.remove_at(i)
					break
		exec_out.erase(id)
	if exec_in.has(id):
		for l: Dictionary in exec_in[id]:
			var m: Dictionary = exec_out.get(int(l["from_id"]), {})
			for port: int in m:
				if int(m[port]) == id:
					m.erase(port)
					break
		exec_in.erase(id)
	data_links = data_links.filter(func(l: Dictionary) -> bool:
		return int(l["from_id"]) != id and int(l["to_id"]) != id)
	# a Class Reference that lost a member drops that member's slot row
	for rr: int in resync_refs:
		if nodes.has(rr) and int(nodes[rr]["kind"]) == Kind.CLASS_REF:
			_apply_class_ref_meta(rr)


# ---- Node editing -------------------------------------------------------------
## Aligns a Function Call node's argument pins with its target function.
## Resolution order:
##   1. A function declared in THIS script (ENTRY node) — the live signature.
##   2. The function registry (Language / Godot Type / Godot Class / Project
##      Script / Custom Class / Autoload / Addon / Extension metadata).
##   3. Free-form: no metadata is invented — the user's pins are kept and one
##      trailing grow slot is maintained.
## Existing connections whose pin survives keep their values; links into pins
## that no longer exist are dropped.
func sync_call_signature(cid: int) -> void:
	if not nodes.has(cid) or int(nodes[cid]["kind"]) != Kind.CALL:
		return
	var n: Dictionary = nodes[cid]
	var fname: String = String(n["fields"].get("call", "")).strip_edges()
	var fcat: String = str(n["fields"].get("cat", ""))
	var fowner: String = str(n["fields"].get("owner", ""))
	var old_pins: Array = n["data_ins"]
	# 1) same-script declaration wins: its ENTRY node is the live signature
	var eid: int = -1
	if fname != "" and (fcat == "" or fowner == script_path):
		for id: int in nodes:
			if int(nodes[id]["kind"]) == Kind.ENTRY \
					and String(nodes[id]["fields"].get("name", "")) == fname:
				eid = id
				break
	if eid >= 0:
		n["fields"]["declared"] = true
		n["fields"]["stale"] = false
		var pins: Array = []
		for aid: int in nodes[eid]["fields"].get("args", []):
			if not nodes.has(aid):
				continue
			var a: Dictionary = nodes[aid]
			var aname: String = String(a["fields"].get("name", "arg"))
			var adef2: String = String(a["fields"].get("default", ""))
			pins.append({
				"name": aname,
				"type": Types.type_from_name(String(a["fields"].get("type", ""))),
				"value": adef2,
				"optional": adef2 != "",
				"default_text": adef2,
			})
		n["data_ins"] = pins
		_remap_call_links(cid, old_pins)
		return
	# 2a) member nodes resolve through the class registry first (methods,
	# properties, signals, constants — one source of truth per class)
	if str(n["fields"].get("member", "")) != "":
		var mrec: Dictionary = ClassReg.get_registry().find_member(fowner, fname)
		if not mrec.is_empty():
			n["fields"]["stale"] = false
			n["fields"]["static"] = bool(mrec["static"])
			n["fields"]["needs_target"] = bool(mrec["needs_target"])
			n["fields"]["target_type"] = str(mrec["target_type"])
			# signals expose the Signal object reference as their value type
			n["fields"]["ret"] = "Signal" if str(mrec["mtype"]) == ClassReg.MT_SIGNAL \
				else str(mrec["ret"])
			n["fields"]["vararg"] = bool(mrec.get("vararg", false))
			n["fields"]["args"] = (mrec["args"] as Array).duplicate(true)
			n["fields"]["sig_changed"] = _call_signature_differs(old_pins, n["fields"]["args"])
			var keepm: Dictionary = {}
			for pm: Dictionary in old_pins:
				keepm[String(pm["name"])] = String(pm["value"])
			_apply_call_meta(cid, keepm)
			_remap_call_links(cid, old_pins)
			return
		# fall through: the function registry / stale flagging takes over
	# 2) registry-backed function sources (real metadata, never invented)
	if fcat != "":
		var e: Dictionary = FuncReg.get_registry().find_entry(fcat, fowner, fname)
		if e.is_empty():
			# The source function is gone (script deleted, class removed...):
			# keep the user's pins and flag the node instead of guessing.
			n["fields"]["stale"] = true
			return
		n["fields"]["stale"] = false
		n["fields"]["ret"] = str(e["ret"])
		n["fields"]["static"] = bool(e["static"])
		n["fields"]["needs_target"] = bool(e["needs_target"])
		n["fields"]["target_type"] = str(e["target_type"])
		n["fields"]["vararg"] = bool(e.get("vararg", false))
		n["fields"]["args"] = (e["args"] as Array).duplicate(true)
		n["fields"]["sig_changed"] = _call_signature_differs(old_pins, n["fields"]["args"])
		var keep_values: Dictionary = {}
		for p2: Dictionary in old_pins:
			keep_values[String(p2["name"])] = String(p2["value"])
		_apply_call_meta(cid, keep_values)
		_remap_call_links(cid, old_pins)
		return
	# 3) free-form: keep the pins the user had (values preserved), then make
	# sure exactly one trailing grow slot exists.
	n["fields"]["declared"] = false
	var keep: Array = []
	for pin: Dictionary in old_pins:
		keep.append({"name": String(pin["name"]), "type": int(pin["type"]),
			"value": String(pin["value"])})
	n["data_ins"] = keep
	_ensure_one_empty(cid)
	_trim_trailing_empties(cid)
	_remap_call_links(cid, old_pins)


## Builds the pins/exec layout of a registry-backed call node from its stored
## metadata (fields). `keep_values` maps pin names to values that survive a
## resync (typed expressions or reconstruction values).
## Member nodes (fields.member set) add the "Class" ownership output first
## (registration wire into a Class Reference's "add member" slot) and shape
## their pins per member kind: properties read/write one value, signals list
## their declared arguments.
func _apply_call_meta(cid: int, keep_values: Dictionary = {}) -> void:
	var n: Dictionary = nodes[cid]
	var f: Dictionary = n["fields"]
	var mkind: String = str(f.get("member", ""))
	var is_member: bool = mkind != ""
	var pins: Array = []
	if bool(f.get("needs_target", false)):
		pins.append({
			"name": "target",
			"type": FuncReg.pin_type_of(str(f.get("target_type", ""))
				if str(f.get("target_type", "")) != "" else str(f.get("owner", ""))),
			"type_text": str(f.get("target_type", "")),
			"value": str(keep_values.get("target", "")),
		})
	if mkind == "property" and str(f.get("mode", "pure")) == "exec":
		# a property write (statement use) carries its typed value input
		var ptext: String = str(f.get("ret", "Variant"))
		pins.append({
			"name": "value",
			"type": FuncReg.pin_type_of(ptext),
			"type_text": "" if ptext == "Variant" else ptext,
			"value": str(keep_values.get("value", "")),
		})
	for a: Dictionary in f.get("args", []):
		pins.append({
			"name": str(a["name"]),
			"type": FuncReg.pin_type_of(str(a["type"])),
			"type_text": str(a.get("type", "")),
			"value": str(keep_values.get(str(a["name"]), str(a.get("default", "")))),
			# Optional/default metadata drives the pin's tooltip, its styling
			# and (in generation) whether the argument must be emitted.
			"optional": not bool(a.get("required", true)),
			"default_text": str(a.get("default", "")),
		})
	n["data_ins"] = pins
	# Variadic calls (print, Callable.call, ...) always keep exactly one
	# trailing grow slot so additional arguments can be added in the UI.
	if bool(f.get("vararg", false)):
		n["data_ins"].append({"name": _dyn_pin_name(cid), "type": Types.VARIANT, "value": ""})
	var ret: String = str(f.get("ret", "void"))
	var is_exec: bool = str(f.get("mode", "pure")) == "exec"
	var outs: Array = []
	if is_member:
		# the "Class" ownership output always comes first (Function-pin-first,
		# like Argument nodes)
		outs.append({"name": "Class", "type": Types.PinType.MEMBER, "member": true})
	if not is_exec and ret != "void" and ret != "":
		if is_member and mkind != "method":
			# properties and signals carry the member name on the value pin
			outs.append({"name": fname_pin_label(f), "type": FuncReg.pin_type_of(ret),
				"type_text": "" if ret == "Variant" else ret})
		else:
			outs.append({"name": "return", "type": FuncReg.pin_type_of(ret),
				"type_text": "" if ret == "Variant" else ret})
	n["data_outs"] = outs
	n["exec_in"] = is_exec
	n["exec_outs"] = ["\u25b6"] if is_exec else []
	n["title"] = _call_title(cid)


## Output pin label of a member value (the member's own name; plain calls
## keep the generic "return" label).
func fname_pin_label(f: Dictionary) -> String:
	var label: String = str(f.get("call", "return")).strip_edges()
	return label if label != "" else "return"


## True when the stored pins no longer match the function's real signature.
func _call_signature_differs(old_pins: Array, args: Array) -> bool:
	var names: Dictionary = {}
	for a: Dictionary in args:
		names[str(a["name"])] = str(a["type"])
	var old_names: Dictionary = {}
	for p: Dictionary in old_pins:
		if String(p["name"]) == "target":
			continue
		old_names[String(p["name"])] = true
	if names.size() != old_names.size():
		return true
	for k: String in names:
		if not old_names.has(k):
			return true
	return false


## Rebinds a call node's data links after its pins changed: links into pins
## that no longer exist are dropped, survivors keep their pin by name.
func _remap_call_links(cid: int, old_pins: Array) -> void:
	var name_to_idx: Dictionary = {}
	for i: int in nodes[cid]["data_ins"].size():
		name_to_idx[String(nodes[cid]["data_ins"][i]["name"])] = i
	for i: int in range(data_links.size() - 1, -1, -1):
		var l: Dictionary = data_links[i]
		if int(l["to_id"]) != cid:
			continue
		if int(l["to_in"]) < old_pins.size() \
				and name_to_idx.has(String(old_pins[int(l["to_in"])]["name"])):
			l["to_in"] = int(name_to_idx[String(old_pins[int(l["to_in"])]["name"])])
		else:
			data_links.remove_at(i)


## Human-readable node title: the bare function name (owner-qualified so
## same-named functions stay apart). The call node type is identified by its
## styling and fields, never by a "Call" prefix in the name.
## A short human-readable title for generation problems (unreachable nodes).
func _node_display_title(id: int) -> String:
	var n: Dictionary = nodes[id]
	var t: String = String(n["title"])
	var body: String = String(n["body"]).strip_edges().split("\n")[0]
	if (t == "Statement" or t == "Annotation") and body != "":
		return body.left(40)
	if t == "":
		t = Kind.keys()[int(n["kind"])]
	return t


func _call_title(cid: int) -> String:
	var f: Dictionary = nodes[cid]["fields"]
	var fname: String = str(f.get("call", ""))
	var owner: String = str(f.get("owner", ""))
	if owner == "":
		return fname
	var short: String = owner.get_file() if owner.contains("/") else owner
	return "%s.%s" % [short, fname]


## Switches a call between Expression (pure) and Statement (exec) use.
## Functions returning void are statement-only: their result cannot be used
## as a value and GDScript would reject the expression.
func set_call_mode(cid: int, mode: String) -> bool:
	if not nodes.has(cid) or int(nodes[cid]["kind"]) != Kind.CALL:
		return false
	var n: Dictionary = nodes[cid]
	var ret: String = str(n["fields"].get("ret", "void"))
	if mode == "pure" and (ret == "void" or ret == ""):
		return false
	if mode != "exec" and mode != "pure":
		return false
	n["fields"]["mode"] = mode
	if mode == "exec":
		n["exec_in"] = true
		n["exec_outs"] = ["\u25b6"]
		n["data_outs"] = []   # the return value is discarded in statement use
	else:
		n["exec_in"] = false
		n["exec_outs"] = []
		exec_out[cid] = {}
		exec_in[cid] = []
		n["data_outs"] = [{"name": "return", "type": FuncReg.pin_type_of(ret)}]
	return true


## Resyncs every declared call that targets `fname` (used after the function
## or its arguments change).
func _resync_calls_for(fname: String) -> void:
	for id: int in nodes:
		if int(nodes[id]["kind"]) == Kind.CALL \
				and String(nodes[id]["fields"].get("call", "")) == fname:
			sync_call_signature(id)


func call_pin_remove(cid: int, index: int) -> bool:
	if not nodes.has(cid) or not is_dynamic_input_node(cid) \
			or int(nodes[cid]["kind"]) != Kind.CALL:
		return false
	var pins: Array = nodes[cid]["data_ins"]
	var pol: Dictionary = _dyn_policy(int(nodes[cid]["kind"]))
	if index < 0 or index >= pins.size() - 1:   # the trailing grow slot is kept
		return false
	if bool(nodes[cid]["fields"].get("declared", false)):
		# Declared (vararg) calls: only the added grow arguments may be
		# removed; the declaration's own pins stay.
		if index < _call_declared_pin_count(cid):
			return false
	if pins.size() - 1 <= int(pol.get("min", 0)):
		return false
	pins.remove_at(index)
	_remap_in_links(cid, index, -1)
	_trim_trailing_empties(cid)
	return true


## Number of declaration-derived pins of a call node (target + named args).
## Extra vararg grow pins carry no "optional" metadata.
func _call_declared_pin_count(cid: int) -> int:
	var cnt: int = 0
	for pin: Dictionary in nodes[cid]["data_ins"]:
		if pin.has("optional") or String(pin["name"]) == "target":
			cnt += 1
	return cnt


## Moves one argument pin one slot left/right, together with its wire.
func call_pin_move(cid: int, index: int, dir: int) -> bool:
	if not nodes.has(cid) or not is_dynamic_input_node(cid) \
			or int(nodes[cid]["kind"]) != Kind.CALL:
		return false
	var pins: Array = nodes[cid]["data_ins"]
	var target: int = index + dir
	if index < 0 or target < 0 or target >= pins.size() - 1 or index >= pins.size() - 1:
		return false   # the trailing grow slot always stays last
	var tmp: Dictionary = pins[index]
	pins[index] = pins[target]
	pins[target] = tmp
	_remap_in_links(cid, index, target)
	return true


## Remaps the data links of one node's input pins after pins[old] moved to
## `new` (or was removed when new == -1).
func _remap_in_links(id: int, old_index: int, new_index: int) -> void:
	for l: Dictionary in data_links:
		if int(l["to_id"]) != id:
			continue
		var i: int = int(l["to_in"])
		if i == old_index:
			l["to_in"] = new_index
		elif new_index == -1 and i > old_index:
			l["to_in"] = i - 1
		elif new_index >= 0 and i == new_index:
			l["to_in"] = old_index


func set_pin_value(id: int, pin_index: int, value: String) -> void:
	if nodes.has(id) and int(pin_index) < nodes[id]["data_ins"].size():
		nodes[id]["data_ins"][pin_index]["value"] = value


func set_body(id: int, text: String) -> void:
	if nodes.has(id):
		nodes[id]["body"] = text
		# an enum Declaration's title follows the name written in its source
		if int(nodes[id]["kind"]) == Kind.DECLARATION \
				and String(nodes[id]["title"]).begins_with("enum"):
			var first: String = text.strip_edges().split("\n")[0].strip_edges()
			if first.begins_with("enum"):
				nodes[id]["title"] = "enum %s" % _ident_after(first, "enum")


func set_field(id: int, key: String, value: String) -> void:
	if not nodes.has(id):
		return
	var k: int = int(nodes[id]["kind"])
	if k == Kind.CLASS_REF:
		set_class_ref_prop(id, key, value)
		return
	if key == "name" and (k == Kind.VARIABLE_GET or k == Kind.VARIABLE_SET) \
			and value.strip_edges() != "" \
			and not _is_ref_allowed(id, value.strip_edges()):
		return   # reference outside the variable's scope: keep the old name
	if k == Kind.SIGNAL_DECL and (key == "name" or key == "args"):
		# Signal declarations regenerate from their structured fields.
		var sname: String = str(nodes[id]["fields"].get("name", "my_sig"))
		var sargs: String = str(nodes[id]["fields"].get("args", ""))
		if key == "name":
			sname = value.strip_edges()
		else:
			sargs = value.strip_edges()
		nodes[id]["fields"][key] = value.strip_edges()
		nodes[id]["body"] = "signal " + sname + "(" + sargs + ")"
		nodes[id]["title"] = "Signal"
		return
	if k == Kind.OPERATOR and key == "op":
		var new_op: String = value.strip_edges()
		nodes[id]["fields"]["op"] = new_op
		nodes[id]["title"] = "Operator %s" % new_op
		# the result pin follows the operator: bool for a comparison
		if nodes[id]["data_outs"].size() > 0:
			nodes[id]["data_outs"][0]["type"] = Types.BOOL if _op_is_comparison(new_op) \
				else Types.VARIANT
			_validate_out_links(id, 0)
		if _op_is_comparison(new_op):
			# a comparison takes exactly two operands: drop the grow pins the
			# chainable operator had (wires into them are disconnected)
			_collapse_operator_operands(id)
		else:
			# back to a chainable operator: the trailing grow slot returns
			_ensure_one_empty(id)
			_trim_trailing_empties(id)
		return
	nodes[id]["fields"][key] = value


# ---- Structured property editing (Function / Argument / Variable) ------------
## A plain GDScript identifier (no keywords checked here; the compiler will).
func _valid_ident(s: String) -> bool:
	if s == "":
		return false
	for i: int in s.length():
		var c: String = s[i]
		if not ((c >= "a" and c <= "z") or (c >= "A" and c <= "Z") \
				or (c >= "0" and c <= "9") or c == "_"):
			return false
	return not s[0].is_valid_int()


## GDScript reserved words: never valid as a parameter / variable name.
const _GD_KEYWORDS: PackedStringArray = [
	"if", "elif", "else", "for", "while", "match", "break", "continue", "pass",
	"return", "class", "class_name", "extends", "is", "in", "as", "self", "signal",
	"func", "static", "const", "enum", "var", "breakpoint", "preload", "await",
	"yield", "assert", "void", "and", "or", "not", "true", "false", "null",
	"super", "when", "PI", "TAU", "INF", "NAN"]


## Name check for a lambda parameter: a plain identifier that is not a
## GDScript keyword. Sets last_reject_reason (plain language) when invalid.
func _check_param_name(n: String) -> bool:
	if n == "":
		last_reject_reason = "A parameter needs a name."
		return false
	if not _valid_ident(n):
		last_reject_reason = "'%s' is not a valid name. Use letters, numbers and _ only, and do not start with a number." % n
		return false
	if _GD_KEYWORDS.has(n):
		last_reject_reason = "'%s' is a reserved word in GDScript. Pick another name." % n
		return false
	return true


## Type text check: no line breaks, no `;`, spaces only inside [...] so typed
## containers such as `Dictionary[String, int]` stay possible.
func _check_type_text(t: String) -> bool:
	if t.contains("\n") or t.contains(";") or t.contains("="):
		last_reject_reason = "'%s' is not a valid type." % t.replace("\n", " ")
		return false
	var depth: int = 0
	for i: int in t.length():
		var c: String = t[i]
		if c == "[":
			depth += 1
		elif c == "]":
			depth -= 1
			if depth < 0:
				break
		elif (c == " " or c == "\t") and depth == 0:
			last_reject_reason = "'%s' is not a valid type (no spaces outside [ ])." % t
			return false
	if depth != 0:
		last_reject_reason = "'%s' has unbalanced brackets." % t
		return false
	return true


## A single expression (default value / source): one line, balanced brackets
## and quotes, no `;`, and - when `allow_comma` is false - no top-level comma
## (it would split one parameter into two).
func _check_single_expr(e: String, allow_comma: bool) -> bool:
	if e.contains("\n") or e.contains("\r"):
		last_reject_reason = "This value must be a single line."
		return false
	var depth: int = 0
	var q: String = ""
	var i: int = 0
	while i < e.length():
		var c: String = e[i]
		if q != "":
			if c == "\\":
				i += 2
				continue
			if c == q:
				q = ""
		elif c == "\"" or c == "'":
			q = c
		elif c == "(" or c == "[" or c == "{":
			depth += 1
		elif c == ")" or c == "]" or c == "}":
			depth -= 1
			if depth < 0:
				last_reject_reason = "'%s' has a closing bracket without an opening one." % e
				return false
		elif c == ";":
			last_reject_reason = "'%s' contains ';' - enter one value only." % e
			return false
		elif c == "," and depth == 0 and not allow_comma:
			last_reject_reason = "'%s' looks like two values. Enter one value (use [ ] for a list)." % e
			return false
		i += 1
	if q != "" or depth != 0:
		last_reject_reason = "'%s' is incomplete (check quotes and brackets)." % e
		return false
	return true


## Re-indents a lambda body to consistent TAB levels: tab = one level, a run
## of spaces counts as levels of the smallest space indent used. Mixed
## tab/space bodies are a GDScript error, so this makes them valid.
func _normalize_lambda_indent(body: String) -> String:
	var lines: PackedStringArray = body.split("\n")
	var unit: int = 0
	for ln: String in lines:
		if ln.strip_edges() == "":
			continue
		var lead: String = ln.substr(0, ln.length() - ln.lstrip(" \t").length())
		var sp: int = lead.replace("\t", "").length()
		if sp > 0 and (unit == 0 or sp < unit):
			unit = sp
	if unit == 0:
		unit = 4
	var out: PackedStringArray = PackedStringArray()
	for ln2: String in lines:
		var rest: String = ln2.lstrip(" \t")
		if rest == "":
			out.append("")
			continue
		var lead2: String = ln2.substr(0, ln2.length() - rest.length())
		var tabs: int = lead2.count("\t")
		var spaces: int = lead2.length() - tabs
		out.append("\t".repeat(tabs + spaces / unit) + rest)
	return "\n".join(out)


## Word-boundary-safe identifier replacement (escaped regex).
func _replace_ident(old: String, new: String, text: String) -> String:
	if old == "" or old == new:
		return text
	var re: RegEx = RegEx.new()
	if re.compile("\\b%s\\b" % old) != OK:
		return text
	return re.sub(text, new, true)


## Replaces identifier references inside the code of one function's flow
## (statement bodies, pin values and structured variable names). Comments and
## verbatim declaration text are left untouched.
func _replace_ident_in_flow(entry_id: int, old: String, new: String) -> void:
	var seen: Dictionary = {}
	var stack: Array[int] = [entry_id]
	while not stack.is_empty():
		var cur: int = stack.pop_back()
		if seen.has(cur) or not nodes.has(cur):
			continue
		seen[cur] = true
		var n: Dictionary = nodes[cur]
		var k: int = int(n["kind"])
		match k:
			Kind.STATEMENT:
				n["body"] = _replace_ident(old, new, String(n["body"]))
				if not n["stmt"].is_empty():
					var st: Dictionary = n["stmt"]
					if not bool(st["decl"]) and String(st["lhs"]) == old:
						st["lhs"] = new
						if n["data_outs"].size() > 0:
							n["data_outs"][0]["name"] = new
				for pin: Dictionary in n["data_ins"]:
					pin["value"] = _replace_ident(old, new, String(pin["value"]))
			Kind.IF, Kind.ELIF, Kind.WHILE, Kind.FOR, Kind.MATCH, Kind.RETURN, \
			Kind.PRINT, Kind.OPERATOR, Kind.CALL:
				for pin: Dictionary in n["data_ins"]:
					pin["value"] = _replace_ident(old, new, String(pin["value"]))
			Kind.VAR_DECL:
				for pin: Dictionary in n["data_ins"]:
					pin["value"] = _replace_ident(old, new, String(pin["value"]))
				if String(n["fields"].get("scope", "public")) != "private":
					_var_rename_in_accessors(cur, old, new)
			Kind.VARIABLE_GET, Kind.VARIABLE_SET:
				if String(n["fields"].get("name", "")) == old:
					n["fields"]["name"] = new
					if n["data_outs"].size() > 0:
						n["data_outs"][0]["name"] = new
			_:
				pass
		# Lambda nodes are data-only (never in the exec chain): a rename on
		# the statement or declaration they feed still reaches their body.
		for l: Dictionary in data_links:
			if int(l["to_id"]) != cur:
				continue
			var lid: int = int(l["from_id"])
			if nodes.has(lid) and int(nodes[lid]["kind"]) == Kind.LAMBDA and not seen.has(lid):
				nodes[lid]["fields"]["body"] = _replace_ident(old, new,
					String(nodes[lid]["fields"].get("body", "")))
				seen[lid] = true
		for port: int in exec_out.get(cur, {}):
			stack.append(int(exec_out[cur][port]))


## Replaces identifier references in all code-bearing nodes (used for
## top-level variable renames; comment/verbatim nodes are untouched).
func _replace_ident_everywhere(old: String, new: String, skip_id: int) -> void:
	for id: int in nodes:
		if id == skip_id:
			continue
		var n: Dictionary = nodes[id]
		match int(n["kind"]):
			Kind.STATEMENT:
				n["body"] = _replace_ident(old, new, String(n["body"]))
			Kind.IF, Kind.ELIF, Kind.WHILE, Kind.FOR, Kind.MATCH, Kind.RETURN, \
			Kind.PRINT, Kind.OPERATOR, Kind.CALL, Kind.VAR_DECL, Kind.CONST_DECL:
				for pin: Dictionary in n["data_ins"]:
					pin["value"] = _replace_ident(old, new, String(pin["value"]))
				if int(n["kind"]) == Kind.VAR_DECL \
						and String(n["fields"].get("scope", "public")) != "private":
					_var_rename_in_accessors(id, old, new)
			Kind.LAMBDA:
				# A captured variable rename reaches inside lambda bodies and
				# parameter default texts.
				n["fields"]["body"] = _replace_ident(old, new, String(n["fields"].get("body", "")))
				for p2: Dictionary in n["fields"].get("params", []):
					p2["default"] = _replace_ident(old, new, str(p2.get("default", "")))
			Kind.VARIABLE_GET, Kind.VARIABLE_SET:
				if String(n["fields"].get("name", "")) == old:
					n["fields"]["name"] = new
					if n["data_outs"].size() > 0:
						n["data_outs"][0]["name"] = new
			_:
				pass


## Drops data links that became incompatible after a type change on an output
## pin. Returns how many links were dropped.
func _validate_out_links(id: int, out_index: int) -> int:
	if out_index >= nodes[id]["data_outs"].size():
		return 0
	var t: int = int(nodes[id]["data_outs"][out_index]["type"])
	var ftext: String = _pin_type_text(nodes[id], true, out_index)
	var dropped: int = 0
	for i: int in range(data_links.size() - 1, -1, -1):
		var l: Dictionary = data_links[i]
		if int(l["from_id"]) == id and int(l["from_out"]) == out_index:
			var tn: Dictionary = nodes[int(l["to_id"])]
			if int(l["to_in"]) < tn["data_ins"].size():
				var it: int = int(tn["data_ins"][int(l["to_in"])]["type"])
				var ttext: String = _pin_type_text(tn, false, int(l["to_in"]))
				var ok: bool = Types.compatible(t, it)
				if ok and ftext != "" and ttext != "":
					ok = TypeReg.get_registry().is_compatible(ftext, ttext)
				if not ok:
					disconnect_data(id, out_index, int(l["to_id"]), int(l["to_in"]))
					dropped += 1
	return dropped


## Drops data links that became incompatible after a type change on an input
## pin. Returns how many links were dropped.
func _validate_in_links(id: int, in_index: int) -> int:
	if in_index >= nodes[id]["data_ins"].size():
		return 0
	var t: int = int(nodes[id]["data_ins"][in_index]["type"])
	var ttext: String = _pin_type_text(nodes[id], false, in_index)
	var dropped: int = 0
	for i: int in range(data_links.size() - 1, -1, -1):
		var l: Dictionary = data_links[i]
		if int(l["to_id"]) == id and int(l["to_in"]) == in_index:
			var fn: Dictionary = nodes[int(l["from_id"])]
			if int(l["from_out"]) < fn["data_outs"].size():
				var st: int = int(fn["data_outs"][int(l["from_out"])]["type"])
				var ftext: String = _pin_type_text(fn, true, int(l["from_out"]))
				var ok: bool = Types.compatible(st, t)
				if ok and ftext != "" and ttext != "":
					ok = TypeReg.get_registry().is_compatible(ftext, ttext)
				if not ok:
					disconnect_data(int(l["from_id"]), int(l["from_out"]), id, in_index)
					dropped += 1
	return dropped


## Structured Function property edit: "name" or "ret_type". Returns false for
## invalid identifiers/types; never touches the function body or connections.
func set_entry_prop(eid: int, key: String, value: String) -> bool:
	if not nodes.has(eid) or int(nodes[eid]["kind"]) != Kind.ENTRY:
		return false
	var n: Dictionary = nodes[eid]
	var v: String = value.strip_edges()
	if key == "name":
		if not _valid_ident(v):
			return false
		var old_name: String = String(n["fields"].get("name", ""))
		n["fields"]["name"] = v
		n["title"] = _entry_title(bool(n["fields"].get("static", false)), v)
		if old_name != v:
			# call sites follow the rename so generated code stays valid
			for cid: int in nodes:
				if int(nodes[cid]["kind"]) == Kind.CALL \
						and String(nodes[cid]["fields"].get("call", "")) == old_name:
					nodes[cid]["fields"]["call"] = v
			_resync_calls_for(old_name)
			_resync_calls_for(v)
	elif key == "ret_type":
		if v != "" and not _valid_type_name(v):
			return false
		n["fields"]["ret_type"] = v
	elif key == "static":
		# UI authoring route: toggle the `static` keyword on a function.
		var want: bool = v == "true" or v == "static"
		if v != "true" and v != "static" and v != "false" and v != "":
			return false
		n["fields"]["static"] = want
	elif key == "annotations":
		var anns2: PackedStringArray = PackedStringArray()
		if v != "":
			anns2 = AnnReg.get_registry().split_annotations(v)
		n["fields"]["annotations"] = "\n".join(anns2)
		_validate_annotation_list(eid, anns2, "func")
		return true
	else:
		return false
	n["sig"] = _sig_text(eid)
	n["body"] = n["sig"]
	return true


## Loosely valid type annotation: identifiers, dotted names, built-in
## generics like Array[int] / Dictionary[String, int]. Empty is allowed
## (untyped / no explicit return type).
func _valid_type_name(s: String) -> bool:
	if s == "":
		return true
	var re: RegEx = RegEx.new()
	if re.compile("^[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)*"
			+ "(\\[[A-Za-z0-9_\\., \\[\\]]*\\])?$") != OK:
		return false
	return re.search(s) != null


## Adds a new Argument node to a Function and returns its id (-1 on failure).
## Rebuilds a Function node's left-side argument pins from its registered
## Argument nodes: one pin per argument (named/typed after it), then exactly
## one trailing "add argument" slot. Registration is ownership, not value
## flow, so no data_links are involved.
func _entry_sync_pins(eid: int) -> void:
	if not nodes.has(eid) or int(nodes[eid]["kind"]) != Kind.ENTRY:
		return
	var pins: Array = []
	for aid: int in nodes[eid]["fields"].get("args", []):
		if not nodes.has(aid):
			continue
		pins.append({
			"name": String(nodes[aid]["fields"].get("name", "arg")),
			"type": int(nodes[aid]["data_outs"][0]["type"]) if nodes[aid]["data_outs"].size() > 0 else Types.VARIANT,
			"value": "",
		})
	if not nodes[eid]["fields"].has("accessor"):
		# a Setter / Getter has exactly its own value argument: no extra
		# argument slot and no annotation slot
		pins.append({"name": "add argument", "type": Types.VARIANT, "value": ""})
		pins.append({"name": "add annotation", "type": Types.PinType.ANNOTATION, "value": ""})
	_add_scope_slot(eid, pins)
	nodes[eid]["data_ins"] = pins


## Registers an existing Argument node with a Function via its left-side
## "add argument" pin. Returns the pin index the argument is bound to
## (its position in the declaration order), or -1 on rejection.
func register_argument(eid: int, aid: int) -> int:
	if not nodes.has(eid) or int(nodes[eid]["kind"]) != Kind.ENTRY:
		return -1
	if not nodes.has(aid) or int(nodes[aid]["kind"]) != Kind.ARGUMENT:
		return -1
	var args: Array = nodes[eid]["fields"].get("args", [])
	if args.has(aid):
		# Already declared (e.g. created through add_argument): only make sure
		# the ownership link for wire drawing exists, then keep existing order.
		var idx0: int = int(args.find(aid))
		nodes[aid]["fields"]["parent"] = eid
		for l: Dictionary in arg_links:
			if int(l["aid"]) == aid and int(l["eid"]) == eid:
				return idx0
		arg_links.append({"eid": eid, "aid": aid})
		return idx0
	# Adopt the argument: claim ownership and keep the parameter name unique
	# inside this function (menu-spawned arguments default to "arg1").
	nodes[aid]["fields"]["parent"] = eid
	var an: String = String(nodes[aid]["fields"].get("name", ""))
	if an == "" or not _arg_name_free(eid, an):
		var bi: int = 1
		var bn: String = an if an != "" else "arg"
		while not _arg_name_free(eid, bn):
			bi += 1
			bn = "arg%d" % bi
		nodes[aid]["fields"]["name"] = bn
		nodes[aid]["data_outs"][0]["name"] = bn
		nodes[aid]["title"] = "arg: %s" % bn
	args.append(aid)
	nodes[eid]["fields"]["args"] = args
	nodes[eid]["sig"] = _sig_text(eid)
	nodes[eid]["body"] = nodes[eid]["sig"]
	for l: Dictionary in arg_links:
		if int(l["aid"]) == aid:
			l["eid"] = eid
	arg_links.append({"eid": eid, "aid": aid})
	_entry_sync_pins(eid)
	_resync_calls_for(String(nodes[eid]["fields"].get("name", "")))
	return args.size() - 1


## Unregisters an Argument from a Function (its pin is disconnected). The
## Argument node itself stays in the graph and can be deleted with Del or
## re-registered on another Function.
func unregister_argument(eid: int, aid: int) -> bool:
	if not nodes.has(eid) or int(nodes[eid]["kind"]) != Kind.ENTRY:
		return false
	var args: Array = nodes[eid]["fields"].get("args", [])
	if not args.has(aid):
		return false
	args.erase(aid)
	nodes[eid]["fields"]["args"] = args
	nodes[eid]["sig"] = _sig_text(eid)
	nodes[eid]["body"] = nodes[eid]["sig"]
	for i: int in range(arg_links.size() - 1, -1, -1):
		var l: Dictionary = arg_links[i]
		if int(l["eid"]) == eid and int(l["aid"]) == aid:
			arg_links.remove_at(i)
	_entry_sync_pins(eid)
	_resync_calls_for(String(nodes[eid]["fields"].get("name", "")))
	return true


# ---- Annotation nodes -> declarations ------------------------------------------


## Placement target kind for a declaration node: "var", "func" or "class"
## (the annotation registry's own vocabulary), or "" when the node kind
## cannot carry annotations.
func _annotation_target_of(tid: int) -> String:
	if not nodes.has(tid):
		return ""
	var k: int = int(nodes[tid]["kind"])
	if k == Kind.VAR_DECL:
		# Local (function-private) variables cannot carry annotations.
		if str(nodes[tid]["fields"].get("scope", "public")) == "private":
			return ""
		return "var"
	if k == Kind.ENTRY:
		return "func"
	if k == Kind.PREAMBLE:
		return "class"
	return ""


## Number of header metadata links of `kind` registered on `hid`.
func _header_meta_count(hid: int, kind: String) -> int:
	var n: int = 0
	for l: Dictionary in header_links:
		if int(l["hid"]) == hid and str(l["kind"]) == kind:
			n += 1
	return n


## The annotation-entry slot an ann-marked input pin represents.
func _annotation_pin_slot(tid: int, pin: int) -> int:
	var pins: Array[int] = _annotation_pin_indices(tid)
	for j: int in pins.size():
		if int(pins[j]) == pin:
			return j
	return -1


## Registers a Script Class Name / Script Extension node with a Script
## Header. One node of each kind per header: a second registration of the
## same kind is rejected (duplicate declarations are invalid GDScript).
## Returns the link index, -1 when rejected.
func register_header_link(hid: int, nid: int) -> int:
	if not nodes.has(hid) or not nodes.has(nid):
		return -1
	if int(nodes[hid]["kind"]) != Kind.PREAMBLE:
		last_reject_reason = "Header nodes connect to the Script Header"
		return -1
	var k: int = int(nodes[nid]["kind"])
	if k != Kind.CLASS_NAME and k != Kind.EXTENDS_DECL:
		last_reject_reason = "Only Script Class Name and Script Extension nodes connect here"
		return -1
	var want: String = "class_name" if k == Kind.CLASS_NAME else "extends"
	# move semantics: wiring the node to another header moves it
	for i: int in range(header_links.size() - 1, -1, -1):
		var l: Dictionary = header_links[i]
		if int(l["nid"]) == nid and int(l["hid"]) == hid \
				and str(l["kind"]) == want:
			return i
		if int(l["nid"]) == nid:
			header_links.remove_at(i)
	# duplicate class_name / extends on one header is invalid
	for l2: Dictionary in header_links:
		if int(l2["hid"]) == hid and str(l2["kind"]) == want:
			last_reject_reason = ("The script already declares a class name"
				if want == "class_name" else "The script already declares extends")
			return -1
	header_links.append({"hid": hid, "nid": nid, "kind": want})
	# a node configured before wiring writes its line now
	if k == Kind.CLASS_NAME and str(nodes[nid]["fields"].get("name", "")) != "":
		_upsert_class_name_line(hid, str(nodes[nid]["fields"]["name"]))
	elif k == Kind.EXTENDS_DECL and str(nodes[nid]["fields"].get("base", "")) != "":
		_upsert_extends_line(hid, str(nodes[nid]["fields"]["base"]))
	return header_links.size() - 1


## Unregisters a header metadata node (its wire was disconnected). The
## header body keeps the declaration line (the script keeps its class name).
func unregister_header_link(hid: int, nid: int) -> bool:
	var removed: bool = false
	for i: int in range(header_links.size() - 1, -1, -1):
		var l: Dictionary = header_links[i]
		if int(l["hid"]) == hid and int(l["nid"]) == nid:
			header_links.remove_at(i)
			removed = true
	return removed


## True when this header metadata node is registered with this header.
func is_header_registered(hid: int, nid: int) -> bool:
	for l: Dictionary in header_links:
		if int(l["hid"]) == hid and int(l["nid"]) == nid:
			return true
	return false


## Writes/updates the header's `class_name X` line (preserving a combined
## `class_name X extends Y` tail when one exists).
func _upsert_class_name_line(hid: int, cname: String) -> bool:
	if not nodes.has(hid) or int(nodes[hid]["kind"]) != Kind.PREAMBLE:
		return false
	var lines: PackedStringArray = String(nodes[hid]["body"]).split("\n")
	if String(nodes[hid]["body"]).strip_edges() == "":
		lines = PackedStringArray()
	for li: int in lines.size():
		var ln: String = String(lines[li]).strip_edges()
		if ln.begins_with("class_name "):
			var tail: String = ""
			var sp: int = ln.find(" extends")
			if sp >= 0:
				tail = " " + ln.substr(sp + 1)
			lines[li] = "class_name " + cname + tail
			nodes[hid]["body"] = "\n".join(lines)
			return true
	# new line: after the last extends/class_name line (style-guide order)
	var pos: int = lines.size()
	for li2: int in lines.size():
		var ln2: String = String(lines[li2]).strip_edges()
		if ln2.begins_with("extends") or ln2.begins_with("class_name"):
			pos = li2 + 1
	lines.insert(mini(pos, lines.size()), "class_name " + cname)
	nodes[hid]["body"] = "\n".join(lines)
	return true


## Writes/updates the header's `extends X` line (preserving a combined
## `class_name X extends Y` head when one exists).
func _upsert_extends_line(hid: int, base: String) -> bool:
	if not nodes.has(hid) or int(nodes[hid]["kind"]) != Kind.PREAMBLE:
		return false
	var lines: PackedStringArray = String(nodes[hid]["body"]).split("\n")
	if String(nodes[hid]["body"]).strip_edges() == "":
		lines = PackedStringArray()
	for li: int in lines.size():
		var ln: String = String(lines[li]).strip_edges()
		if ln.begins_with("extends "):
			var head: String = ""
			var sp: int = ln.find(" class_name")
			if sp >= 0:
				head = ln.substr(0, sp) + " "
			lines[li] = head + "extends " + base
			nodes[hid]["body"] = "\n".join(lines)
			return true
	# new line: before the first class_name line (extends comes first)
	var pos: int = lines.size()
	for li2: int in lines.size():
		if String(lines[li2]).strip_edges().begins_with("class_name "):
			pos = li2
			break
	lines.insert(mini(pos, lines.size()), "extends " + base)
	nodes[hid]["body"] = "\n".join(lines)
	return true


## Structured setter for a Script Class Name node. An empty or invalid
## identifier is rejected; a linked node rewrites the header's line.
func set_class_name(nid: int, text: String) -> bool:
	if not nodes.has(nid) or int(nodes[nid]["kind"]) != Kind.CLASS_NAME:
		return false
	var cname: String = text.strip_edges()
	if cname == "":
		nodes[nid]["fields"]["name"] = ""
		nodes[nid]["title"] = "Script Class Name"
		return true
	if not _is_valid_class_name(cname):
		last_reject_reason = "'%s' is not a valid class name (use A-Z, a-z, 0-9 and _; cannot start with a digit)" % cname
		return false
	nodes[nid]["fields"]["name"] = cname
	nodes[nid]["title"] = "Script Class Name"
	for l: Dictionary in header_links:
		if int(l["nid"]) == nid:
			_upsert_class_name_line(int(l["hid"]), cname)
	return true


## Structured setter for a Script Extension node. Accepts a base class
## identifier (optionally dotted) or a quoted script path; unknown class
## identifiers are allowed through but reported as a generation problem.
func set_extends_base(nid: int, text: String) -> bool:
	if not nodes.has(nid) or int(nodes[nid]["kind"]) != Kind.EXTENDS_DECL:
		return false
	var base: String = text.strip_edges()
	if base == "":
		nodes[nid]["fields"]["base"] = ""
		nodes[nid]["title"] = "Script Extension"
		return true
	var quoted: bool = base.begins_with("\"") or base.begins_with("'")
	if not quoted and (base.contains(" ") or base.contains("\"") or base.contains("'")):
		last_reject_reason = "'%s' is not a valid extends target (base class or quoted script path)" % base
		return false
	last_reject_reason = ""
	if not quoted and not base.contains("/") and not ClassDB.class_exists(base) \
			and not _looks_like_dotted_type(base):
		# still generated (it may be a project class); flagged as a warning
		last_reject_reason = "Unknown base class '%s' — generated anyway, check the spelling" % base
	nodes[nid]["fields"]["base"] = base
	nodes[nid]["title"] = "Script Extension"
	for l: Dictionary in header_links:
		if int(l["nid"]) == nid:
			_upsert_extends_line(int(l["hid"]), base)
	return true


## True for identifier chains like "Godot.Node" (validated loosely).
func _looks_like_dotted_type(base: String) -> bool:
	for part: String in base.split("."):
		if part.strip_edges() == "" or not _is_ident_char(part.strip_edges()[0]):
			return false
	return true


## A valid GDScript class name (global class): identifier, not reserved.
func _is_valid_class_name(cname: String) -> bool:
	if cname == "" or not _is_ident_char(cname[0]):
		return false
	for i: int in cname.length():
		if not _is_ident_char(cname[i]):
			return false
	return true


## The GDScript annotation text an Annotation node currently represents,
## e.g. "@export_range(0, 100)". Trailing empty params are dropped; a String
## param whose value is a bare word is quoted so the text always compiles.
func annotation_node_text(aid: int) -> String:
	if not nodes.has(aid) or int(nodes[aid]["kind"]) != Kind.ANNOTATION:
		return ""
	var an: Dictionary = nodes[aid]
	var name: String = str(an["fields"].get("name", ""))
	var parts: PackedStringArray = PackedStringArray()
	for i: int in an["data_ins"].size():
		var pin: Dictionary = an["data_ins"][i]
		var v: String = str(pin["value"]).strip_edges()
		# an untouched String pin holding the empty literal "" contributes
		# nothing (Godot rejects empty trailing annotation arguments)
		if v == "" or v == "\"\"" or v == "''":
			continue
		if not v.begins_with("\"") and not v.begins_with("'") and not v.begins_with("(") \
				and not v.contains("\"") and not v.contains("(") \
				and str(pin["ptype"]).to_lower() == "string":
			v = "\"" + v + "\""
		parts.append(v)
	while parts.size() > 0 and String(parts[parts.size() - 1]).strip_edges() == "":
		parts.remove_at(parts.size() - 1)
	if parts.is_empty():
		return "@" + name
	return "@" + name + "(" + ", ".join(parts) + ")"


## The annotation name (without @ and args) a node's text line carries.
func _annotation_name_of_line(line: String) -> String:
	var s: String = line.strip_edges()
	if not s.begins_with("@"):
		return ""
	return s.trim_prefix("@").split("(")[0].strip_edges()


## Adds or replaces the line carrying `name` in the declaration's annotation
## list (or the header body for class targets). Returns the line index.
func _upsert_annotation_line(tid: int, name: String, text: String,
		inline: int = 0) -> int:
	var n: Dictionary = nodes[tid]
	# Variables keep their annotation lines in the source prefix (see
	# annotations_of/_store_annotations); functions in fields.annotations;
	# the header in its body lines.
	if int(n["kind"]) == Kind.VAR_DECL:
		var anns: PackedStringArray = annotations_of(tid)
		var idx0: int = -1
		for i: int in anns.size():
			if _annotation_name_of_line(String(anns[i])) == name:
				idx0 = i
				break
		if idx0 >= 0:
			anns[idx0] = text
		else:
			idx0 = anns.size()
			anns.append(text)
		# A declaration's FIRST annotation joins the declaration line
		# (`@export var health: int = 100`); more annotations switch to the
		# canonical own-line form. inline == 2 preserves the current style.
		var mode: int = inline
		if mode == 0 and idx0 == 0 and anns.size() == 1:
			mode = 1
		_store_annotations(tid, anns, "var", mode)
		return idx0
	var lines: PackedStringArray
	if int(n["kind"]) == Kind.PREAMBLE:
		lines = String(n["body"]).split("\n")
		if String(n["body"]).strip_edges() == "":
			lines = PackedStringArray()
		# Updating an existing line keeps its position; a new class-level
		# annotation must come BEFORE extends/class_name in GDScript, so it is
		# inserted above those directives (appending would generate
		# `extends Node\n@tool`, which the parser rejects). The order of
		# annotations already present is preserved.
		var existing: int = -1
		for pi: int in lines.size():
			if _annotation_name_of_line(String(lines[pi])) == name:
				existing = pi
				break
		var written: int = existing
		if existing >= 0:
			lines[existing] = text
		else:
			var ins: int = lines.size()
			for li: int in lines.size():
				var ln: String = String(lines[li]).strip_edges()
				if ln.begins_with("extends ") or ln.begins_with("class_name ") \
						or ln == "extends" or ln == "class_name":
					ins = li
					break
			lines.insert(ins, text)
			written = ins
		n["body"] = "\n".join(lines)
		return written
	lines = String(n["fields"].get("annotations", "")).split("\n")
	if String(n["fields"].get("annotations", "")).strip_edges() == "":
		lines = PackedStringArray()
	var idx: int = -1
	for i: int in lines.size():
		if _annotation_name_of_line(String(lines[i])) == name:
			idx = i
			break
	if idx >= 0:
		lines[idx] = text
	else:
		idx = lines.size()
		lines.append(text)
	n["fields"]["annotations"] = "\n".join(lines)
	return idx


## Removes the line carrying `name` from the declaration's annotation list
## (or header body). Returns true when a line was removed.
func _drop_annotation_line(tid: int, name: String) -> bool:
	var n: Dictionary = nodes[tid]
	if int(n["kind"]) == Kind.VAR_DECL:
		var anns: PackedStringArray = annotations_of(tid)
		var found0: bool = false
		for i: int in range(anns.size() - 1, -1, -1):
			if _annotation_name_of_line(String(anns[i])) == name:
				anns.remove_at(i)
				found0 = true
		if found0:
			_store_annotations(tid, anns, "var")
		return found0
	var lines: PackedStringArray
	if int(n["kind"]) == Kind.PREAMBLE:
		lines = String(n["body"]).split("\n")
	else:
		lines = String(n["fields"].get("annotations", "")).split("\n")
	var found: bool = false
	for i: int in range(lines.size() - 1, -1, -1):
		if _annotation_name_of_line(String(lines[i])) == name:
			lines.remove_at(i)
			found = true
	if not found:
		return false
	if int(n["kind"]) == Kind.PREAMBLE:
		n["body"] = "\n".join(lines)
	else:
		n["fields"]["annotations"] = "\n".join(lines)
	return true


## Registers an Annotation node with a declaration via the declaration's
## "add annotation" input slot. The annotation text generated from the
## node's current pin values is written into the declaration's annotation
## list (deduplicated by annotation name — connecting a second annotation
## node with the same name updates the existing line instead of duplicating
## it). Returns the line index, or -1 on rejection (reason in
## last_reject_reason).
## The declaration's ordered annotation entries (one per annotation pin).
## Variables keep them in the source prefix, functions in fields.annotations,
## the header in its body lines.
func _annotation_lines_of(tid: int) -> PackedStringArray:
	if not nodes.has(tid):
		return PackedStringArray()
	var k: int = int(nodes[tid]["kind"])
	if k == Kind.VAR_DECL:
		return annotations_of(tid)
	if k == Kind.ENTRY:
		var joined: String = String(nodes[tid]["fields"].get("annotations", ""))
		return joined.split("\n") if joined.strip_edges() != "" else PackedStringArray()
	if k == Kind.PREAMBLE:
		var out: PackedStringArray = PackedStringArray()
		for ln: String in String(nodes[tid]["body"]).split("\n"):
			if ln.strip_edges().begins_with("@"):
				out.append(ln.strip_edges())
		return out
	return PackedStringArray()


## Indices of the per-annotation input pins (marked "ann") in data_ins.
func _annotation_pin_indices(tid: int) -> Array[int]:
	var out: Array[int] = []
	if not nodes.has(tid):
		return out
	var ins: Array = nodes[tid]["data_ins"]
	for i: int in ins.size():
		if bool(ins[i].get("ann", false)) \
				and int(ins[i]["type"]) == Types.PinType.ANNOTATION:
			out.append(i)
	return out


## Rebuilds the per-annotation input pins: one pin per annotation entry,
## each labelled "@name" (which annotation it belongs to), followed by the
## free "add annotation" slot. All other pins (and their data-link indices)
## keep their relative order: the annotation block always sits after the
## declaration's own pins and before the trailing registration slots.
func _sync_annotation_pins(tid: int) -> void:
	if not nodes.has(tid):
		return
	var k: int = int(nodes[tid]["kind"])
	if k != Kind.VAR_DECL and k != Kind.ENTRY and k != Kind.PREAMBLE:
		return
	var ins: Array = nodes[tid]["data_ins"]
	var kept: Array = []
	for pin: Dictionary in ins:
		if not bool(pin.get("ann", false)):
			kept.append(pin)
	var at: int = kept.size()
	for i: int in kept.size():
		if String(kept[i]["name"]) == "add annotation" \
				and int(kept[i]["type"]) == Types.PinType.ANNOTATION:
			at = i
			break
	var block: Array = []
	for a: String in _annotation_lines_of(tid):
		block.append({"name": "@" + _annotation_name_of_line(a),
			"type": Types.PinType.ANNOTATION, "value": "", "ann": true})
	var rebuilt: Array = []
	for i: int in kept.size():
		if i == at:
			rebuilt.append_array(block)
		rebuilt.append(kept[i])
	if at >= kept.size():
		rebuilt.append_array(block)
	nodes[tid]["data_ins"] = rebuilt


## The pin index of annotation entry `slot`, -1 when out of range.
func _annotation_pin_of_slot(tid: int, slot: int) -> int:
	var pins: Array[int] = _annotation_pin_indices(tid)
	return int(pins[slot]) if slot >= 0 and slot < pins.size() else -1


## Replaces the text of the annotation entry at position `slot` in place
## (per kind) without changing the entry count.
func _set_annotation_entry_text(tid: int, slot: int, text: String) -> void:
	var k: int = int(nodes[tid]["kind"])
	if k == Kind.VAR_DECL:
		var anns: PackedStringArray = annotations_of(tid)
		if slot >= 0 and slot < anns.size():
			anns[slot] = text
			_store_annotations(tid, anns, "var", 2)
	elif k == Kind.ENTRY:
		var joined: String = String(nodes[tid]["fields"].get("annotations", ""))
		var lines: PackedStringArray = joined.split("\n") if joined.strip_edges() != "" else PackedStringArray()
		if slot >= 0 and slot < lines.size():
			lines[slot] = text
			nodes[tid]["fields"]["annotations"] = "\n".join(lines)
	else:
		var lines2: PackedStringArray = String(nodes[tid]["body"]).split("\n")
		var ann_idx: Array[int] = []
		for li: int in lines2.size():
			if String(lines2[li]).strip_edges().begins_with("@"):
				ann_idx.append(li)
		if slot >= 0 and slot < ann_idx.size():
			lines2[int(ann_idx[slot])] = text
			nodes[tid]["body"] = "\n".join(lines2)


## Inserts an annotation entry at position `slot` (per kind).
func _insert_annotation_line(tid: int, slot: int, text: String) -> void:
	var k: int = int(nodes[tid]["kind"])
	if k == Kind.VAR_DECL:
		var anns: PackedStringArray = annotations_of(tid)
		var at: int = mini(slot, anns.size())
		anns.insert(at, text)
		_store_annotations(tid, anns, "var", 2)
	elif k == Kind.ENTRY:
		var joined: String = String(nodes[tid]["fields"].get("annotations", ""))
		var lines: PackedStringArray = joined.split("\n") if joined.strip_edges() != "" else PackedStringArray()
		var at2: int = mini(slot, lines.size())
		lines.insert(at2, text)
		nodes[tid]["fields"]["annotations"] = "\n".join(lines)
	else:
		# header: insert at the body position of the slot-th annotation line
		var lines2: PackedStringArray = String(nodes[tid]["body"]).split("\n")
		if String(nodes[tid]["body"]).strip_edges() == "":
			lines2 = PackedStringArray()
		var ann_idx: Array[int] = []
		for li: int in lines2.size():
			if String(lines2[li]).strip_edges().begins_with("@"):
				ann_idx.append(li)
		var pos: int = lines2.size()
		if slot < ann_idx.size():
			pos = int(ann_idx[slot])
		elif not ann_idx.is_empty():
			pos = int(ann_idx[ann_idx.size() - 1]) + 1
		else:
			# no annotation lines yet: before extends/class_name
			for li2: int in lines2.size():
				var ln: String = String(lines2[li2]).strip_edges()
				if ln.begins_with("extends ") or ln.begins_with("class_name ") \
						or ln == "extends" or ln == "class_name":
					pos = li2
					break
		lines2.insert(mini(pos, lines2.size()), text)
		nodes[tid]["body"] = "\n".join(lines2)


## Removes the annotation entry at position `slot` (per kind).
func _drop_annotation_at(tid: int, slot: int) -> void:
	var k: int = int(nodes[tid]["kind"])
	if k == Kind.VAR_DECL:
		var anns: PackedStringArray = annotations_of(tid)
		if slot >= 0 and slot < anns.size():
			anns.remove_at(slot)
			_store_annotations(tid, anns, "var", 2)
	elif k == Kind.ENTRY:
		var joined: String = String(nodes[tid]["fields"].get("annotations", ""))
		var lines: PackedStringArray = joined.split("\n") if joined.strip_edges() != "" else PackedStringArray()
		if slot >= 0 and slot < lines.size():
			lines.remove_at(slot)
			nodes[tid]["fields"]["annotations"] = "\n".join(lines)
	else:
		var lines2: PackedStringArray = String(nodes[tid]["body"]).split("\n")
		var ann_idx: Array[int] = []
		for li: int in lines2.size():
			if String(lines2[li]).strip_edges().begins_with("@"):
				ann_idx.append(li)
		if slot >= 0 and slot < ann_idx.size():
			lines2.remove_at(int(ann_idx[slot]))
			nodes[tid]["body"] = "\n".join(lines2)


func register_annotation(tid: int, aid: int, inline: int = 0, slot: int = -1) -> int:
	if not nodes.has(tid) or not nodes.has(aid):
		return -1
	if int(nodes[aid]["kind"]) != Kind.ANNOTATION:
		return -1
	var target: String = _annotation_target_of(tid)
	if target == "":
		last_reject_reason = "Annotations can only be registered on member variables, functions or the script header"
		return -1
	var name: String = str(nodes[aid]["fields"].get("name", "")).strip_edges()
	if name == "export_group":
		# @export_group never attaches to a declaration: it connects to the
		# Export Group pin of each @export-family Annotation node instead.
		last_reject_reason = "@export_group connects to an @export annotation's Export Group pin, not to a Variable"
		return -1
	var ae: Dictionary = AnnReg.get_registry().find(name)
	if ae.is_empty():
		last_reject_reason = "Unrecognized annotation @%s" % name
		return -1
	if not (ae["targets"] as Array).has(target):
		last_reject_reason = "Annotation @%s cannot be applied to a %s" % [name, target]
		return -1
	var text: String = annotation_node_text(aid)
	# One annotation node represents one annotation: wiring it to a different
	# declaration (or slot) MOVES it (the previous registration and its line
	# are dropped); a second annotation of the same name on one declaration
	# is invalid GDScript and is rejected instead of overwriting silently.
	for i: int in range(ann_links.size() - 1, -1, -1):
		var l0: Dictionary = ann_links[i]
		if int(l0["aid"]) != aid:
			continue
		if int(l0["tid"]) == tid and int(l0["slot"]) == slot:
			break   # re-registering in the same place: just update the line
		var other: int = int(l0["tid"])
		ann_links.remove_at(i)
		_drop_annotation_line(other, name)
	for l1: Dictionary in ann_links:
		if int(l1["tid"]) == tid and int(l1["aid"]) != aid \
				and nodes.has(int(l1["aid"])) \
				and str(nodes[int(l1["aid"])]["fields"].get("name", "")) == name:
			last_reject_reason = "Declaration already carries @%s (from another annotation node)" % name
			return -1
	var used: int = -1
	if slot >= 0:
		var already: bool = false
		for l3: Dictionary in ann_links:
			if int(l3["tid"]) == tid and int(l3["aid"]) == aid \
					and int(l3["slot"]) == slot:
				already = true
		if already:
			# the node already holds this pin: update its text in place
			_set_annotation_entry_text(tid, slot, text)
		else:
			# Wiring into an existing annotation pin REPLACES that annotation
			# (the pin keeps its position; whatever node held it is
			# unregistered first and its line dropped).
			for i2: int in range(ann_links.size() - 1, -1, -1):
				var l2: Dictionary = ann_links[i2]
				if int(l2["tid"]) == tid and int(l2["slot"]) == slot \
						and int(l2["aid"]) != aid:
					var oldaid: int = int(l2["aid"])
					var oldname: String = str(nodes[oldaid]["fields"].get("name", "")) \
							if nodes.has(oldaid) else ""
					ann_links.remove_at(i2)
					if oldname != "":
						_drop_annotation_at(tid, slot)
			if slot < _annotation_lines_of(tid).size():
				_set_annotation_entry_text(tid, slot, text)
			else:
				_insert_annotation_line(tid, slot, text)
		used = slot
	else:
		var idx: int = _upsert_annotation_line(tid, name, text, inline)
		used = _entry_index_of_line(tid, idx)
	for l: Dictionary in ann_links:
		if int(l["tid"]) == tid and int(l["aid"]) == aid:
			l["slot"] = used
			_sync_annotation_pins(tid)
			return used
	ann_links.append({"tid": tid, "aid": aid, "slot": used})
	_sync_annotation_pins(tid)
	return used


## The annotation-entry index for a line index as returned by
## _upsert_annotation_line (identity for var/func; the header maps body
## line indices to the annotation-line order).
func _entry_index_of_line(tid: int, line_idx: int) -> int:
	var k: int = int(nodes[tid]["kind"])
	if k != Kind.PREAMBLE:
		return line_idx
	var ann_idx: Array[int] = []
	var lines: PackedStringArray = String(nodes[tid]["body"]).split("\n")
	for li: int in lines.size():
		if String(lines[li]).strip_edges().begins_with("@"):
			ann_idx.append(li)
	var out: int = 0
	for ai: int in ann_idx:
		if int(ai) == line_idx:
			return out
		if int(ai) < line_idx:
			out += 1
	return out


## Unregisters an Annotation node from a declaration (its wire was
## disconnected). The annotation line is removed from the declaration; the
## Annotation node itself stays in the graph and can be re-registered.
func unregister_annotation(tid: int, aid: int, keep_text: bool = true) -> bool:
	if not nodes.has(tid) or not nodes.has(aid):
		return false
	var removed: bool = false
	for i: int in range(ann_links.size() - 1, -1, -1):
		var l: Dictionary = ann_links[i]
		if int(l["tid"]) == tid and int(l["aid"]) == aid:
			ann_links.remove_at(i)
			removed = true
	if not removed:
		return false
	var name: String = str(nodes[aid]["fields"].get("name", "")).strip_edges()
	if name != "" and not keep_text:
		# move semantics: the annotation travels with its node
		_drop_annotation_line(tid, name)
	_sync_annotation_pins(tid)
	return true


## True when this exact annotation node is registered with this declaration.
func is_annotation_registered(tid: int, aid: int) -> bool:
	for l: Dictionary in ann_links:
		if int(l["tid"]) == tid and int(l["aid"]) == aid:
			return true
	return false


## True when the node id has at least one annotation registration
## (declaration side; used for view rebuilds after link changes).
func has_annotation_links(tid: int) -> bool:
	for l: Dictionary in ann_links:
		if int(l["tid"]) == tid:
			return true
	return false


# ---- Private-variable scope registrations ----------------------------------
## True for annotations that participate in Inspector export groups: bare
## @export and every @export_* variant except the group markers themselves
## (@export_group defines a group; @export_subgroup/@export_category nest
## above groups and carry their own name fields).
func _is_export_family(name: String) -> bool:
	if name == "export":
		return true
	if not name.begins_with("export_"):
		return false
	return name != "export_group" and name != "export_subgroup" \
		and name != "export_category"


## Index of an Annotation node's "add group" input slot, or -1.
func group_slot_of(xid: int) -> int:
	if not nodes.has(xid) or int(nodes[xid]["kind"]) != Kind.ANNOTATION:
		return -1
	var tins: Array = nodes[xid]["data_ins"]
	for i: int in tins.size():
		if String(tins[i]["name"]) == "add group" \
				and int(tins[i]["type"]) == Types.PinType.ANNOTATION:
			return i
	return -1


## Registers an export annotation with an @export_group node through the
## "add group" input. One group per export annotation: re-wiring moves it.
## Returns the link index, -1 when rejected.
func register_group(xid: int, gid: int) -> int:
	if not nodes.has(xid) or not nodes.has(gid):
		return -1
	if int(nodes[xid]["kind"]) != Kind.ANNOTATION \
			or int(nodes[gid]["kind"]) != Kind.ANNOTATION:
		return -1
	var xname: String = str(nodes[xid]["fields"].get("name", "")).strip_edges()
	var gname: String = str(nodes[gid]["fields"].get("name", "")).strip_edges()
	if not _is_export_family(xname):
		last_reject_reason = "@%s does not take an export group" % xname
		return -1
	if gname != "export_group":
		last_reject_reason = "Only @export_group nodes can be connected to an Export Group pin"
		return -1
	# move semantics: one group per export annotation
	for i: int in range(group_links.size() - 1, -1, -1):
		if int(group_links[i]["xid"]) == xid:
			group_links.remove_at(i)
	group_links.append({"gid": gid, "xid": xid})
	return group_links.size() - 1


## Removes the export annotation's group association (its wire was
## disconnected). The annotation itself keeps its configuration.
func unregister_group(xid: int) -> bool:
	var removed: bool = false
	for i: int in range(group_links.size() - 1, -1, -1):
		if int(group_links[i]["xid"]) == xid:
			group_links.remove_at(i)
			removed = true
	return removed


## The @export_group node an export annotation belongs to, -1 when none.
func group_of(xid: int) -> int:
	for l: Dictionary in group_links:
		if int(l["xid"]) == xid:
			return int(l["gid"])
	return -1


## The @export_group node a variable's export annotations belong to (the
## first grouped export wins), -1 when the variable carries no grouped
## export annotation.
func _export_group_of(vid: int) -> int:
	for l: Dictionary in ann_links:
		if int(l["tid"]) != vid:
			continue
		var aid: int = int(l["aid"])
		if not nodes.has(aid) or int(nodes[aid]["kind"]) != Kind.ANNOTATION:
			continue
		if not _is_export_family(str(nodes[aid]["fields"].get("name", ""))):
			continue
		var gid: int = group_of(aid)
		if gid >= 0:
			return gid
	return -1


## True when an Annotation node is manually registered on any declaration
## (its line is emitted there; automatic group-header emission steps aside).
func _annotation_registered_anywhere(aid: int) -> bool:
	for l: Dictionary in ann_links:
		if int(l["aid"]) == aid:
			return true
	return false


## Appends the "add scope" registration slot to a scope-owning node's data
## inputs (unless present). Scope owners: Function, If, Else If, While, For
## and Match — the nodes that genuinely own or contain a GDScript scope.
func _add_scope_slot(tid: int, pins: Array = []) -> void:
	var target: Array = pins
	if target.is_empty() and nodes.has(tid):
		target = nodes[tid]["data_ins"]
	# Rebuild the scope pins: one named row per variable registered with this
	# scope (the variable's name shows beside its pin), then exactly one
	# trailing empty "add scope" slot for the next variable. Scope pins are
	# always last, so no other input index ever shifts.
	for i: int in range(target.size() - 1, -1, -1):
		if int(target[i]["type"]) == Types.PinType.SCOPE:
			target.remove_at(i)
	for l: Dictionary in scope_links:
		if int(l["tid"]) == tid and nodes.has(int(l["vid"])):
			target.append({"name": String(nodes[int(l["vid"])]["fields"].get("name", "var")),
				"type": Types.PinType.SCOPE, "value": "", "scope_vid": int(l["vid"])})
	target.append({"name": "add scope", "type": Types.PinType.SCOPE, "value": ""})
	if pins.is_empty() and nodes.has(tid):
		nodes[tid]["data_ins"] = target


## Input index of the scope pin a variable is registered on (-1 when it is not
## registered with `tid`); falls back to nothing, never to the empty slot.
func scope_pin_of(tid: int, vid: int) -> int:
	if not nodes.has(tid):
		return -1
	for i: int in nodes[tid]["data_ins"].size():
		var pin: Dictionary = nodes[tid]["data_ins"][i]
		if int(pin["type"]) == Types.PinType.SCOPE and int(pin.get("scope_vid", -1)) == vid:
			return i
	return -1


## Scope owners a variable is registered with.
func scope_hosts_of(vid: int) -> Array[int]:
	var out: Array[int] = []
	for l: Dictionary in scope_links:
		if int(l["vid"]) == vid and not out.has(int(l["tid"])):
			out.append(int(l["tid"]))
	return out


## Index of a scope-owning node's "add scope" registration slot (-1 when none).
func scope_slot_of(tid: int) -> int:
	if not nodes.has(tid):
		return -1
	for i: int in nodes[tid]["data_ins"].size():
		var pin: Dictionary = nodes[tid]["data_ins"][i]
		if String(pin["name"]) == "add scope" and int(pin["type"]) == Types.PinType.SCOPE:
			return i
	return -1


## True when the node kind can own or contain a private-variable scope.
func is_scope_owner(id: int) -> bool:
	if not nodes.has(id):
		return false
	match int(nodes[id]["kind"]):
		Kind.ENTRY, Kind.IF, Kind.ELIF, Kind.WHILE, Kind.FOR, Kind.MATCH:
			return true
		_:
			return false


## Registers a private variable with a scope-owning node through the
## variable's "scope" output pin and the owner's "add scope" input. The
## variable's owning function follows the scope node's function so the
## declaration still generates inside it.
func register_scope(tid: int, vid: int) -> bool:
	if not nodes.has(tid) or not nodes.has(vid):
		return false
	if int(nodes[vid]["kind"]) != Kind.VAR_DECL or not is_scope_owner(tid):
		last_reject_reason = "Scope pins only connect variables to scope-owning nodes"
		return false
	if str(nodes[vid]["fields"].get("scope", "public")) != "private":
		last_reject_reason = "Only private variables carry a scope output pin"
		return false
	for l: Dictionary in scope_links:
		if int(l["tid"]) == tid and int(l["vid"]) == vid:
			return true
	# A private variable belongs to exactly ONE scope: wiring it into a new
	# scope moves it (the previous registration is dropped, so it can never
	# stay attached to an unrelated scope as well).
	var old_hosts: Array[int] = scope_hosts_of(vid)
	for i: int in range(scope_links.size() - 1, -1, -1):
		if int(scope_links[i]["vid"]) == vid:
			scope_links.remove_at(i)
	scope_links.append({"tid": tid, "vid": vid})
	_scope_owner_sync(vid, tid)
	# the host grows a named pin for this variable plus a fresh empty slot
	for h: int in old_hosts:
		if nodes.has(h):
			_add_scope_slot(h)
	_add_scope_slot(tid)
	return true


## Removes the scope registration (its wire was disconnected). The variable
## stays private at its last owning function.
func unregister_scope(tid: int, vid: int) -> bool:
	var removed: bool = false
	for i: int in range(scope_links.size() - 1, -1, -1):
		var l: Dictionary = scope_links[i]
		if int(l["tid"]) == tid and int(l["vid"]) == vid:
			scope_links.remove_at(i)
			removed = true
	if removed and nodes.has(tid):
		_add_scope_slot(tid)
	return removed


## Scope registrations of one variable.
func scope_links_of(vid: int) -> Array:
	var out: Array = []
	for l: Dictionary in scope_links:
		if int(l["vid"]) == vid:
			out.append(l)
	return out


## Keeps a private variable's ownership metadata in step with its scope
## registration: the owning function becomes the scope node's function, so
## generation still emits the declaration inside it.
func _scope_owner_sync(vid: int, tid: int) -> void:
	if not nodes.has(vid):
		return
	var entry: int = tid if int(nodes[tid]["kind"]) == Kind.ENTRY else _entry_of_flow_node(tid)
	if entry < 0:
		return
	nodes[vid]["fields"]["owner"] = entry
	if not func_privates.has(entry):
		func_privates[entry] = []
	if not (func_privates[entry] as Array).has(vid):
		func_privates[entry].append(vid)
	_sanitize_refs_for_scope(vid)


## Adds/removes the private variable's dedicated scope output pin (index 1,
## right after the value pin) whenever its scope changes. Turning the
## variable public again drops the pin and its scope registrations.
func _var_sync_scope_pin(vid: int) -> void:
	if not nodes.has(vid) or int(nodes[vid]["kind"]) != Kind.VAR_DECL:
		return
	var outs: Array = nodes[vid]["data_outs"]
	var is_priv: bool = str(nodes[vid]["fields"].get("scope", "public")) == "private"
	var has_pin: bool = outs.size() > 1 and int(outs[1]["type"]) == Types.PinType.SCOPE
	if is_priv and not has_pin:
		outs.insert(1, {"name": "scope", "type": Types.PinType.SCOPE})
		nodes[vid]["data_outs"] = outs
	elif not is_priv and has_pin:
		outs.remove_at(1)
		nodes[vid]["data_outs"] = outs
		var hosts: Array[int] = scope_hosts_of(vid)
		for i: int in range(scope_links.size() - 1, -1, -1):
			if int(scope_links[i]["vid"]) == vid:
				scope_links.remove_at(i)
		for h: int in hosts:
			if nodes.has(h):
				_add_scope_slot(h)


## May a reference at flow position `pos` use the private variable `decl`?
## With scope registrations: allowed inside any linked scope (function bodies
## cover the whole body; block scopes cover only the flow inside their
## branches). Without registrations: the legacy owning-function rule.
func _private_pos_allowed(decl: int, pos: Dictionary) -> bool:
	var links: Array = scope_links_of(decl)
	if not links.is_empty():
		for l: Dictionary in links:
			if _scope_link_allows(int(l["tid"]), pos):
				return true
		return false
	return int(pos["entry"]) == int(nodes[decl]["fields"].get("owner", -1))


## Does one scope registration cover a reference position? Function scopes
## cover their whole body; block scopes (If / Else If / While / For / Match)
## cover only the flow inside their branches — everything from the block's
## merge point onward is outside the block's scope.
func _scope_link_allows(tid: int, pos: Dictionary) -> bool:
	if not nodes.has(tid):
		return false
	var t_entry: int = tid if int(nodes[tid]["kind"]) == Kind.ENTRY else _entry_of_flow_node(tid)
	if t_entry < 0 or int(pos["entry"]) != t_entry:
		return false
	if int(nodes[tid]["kind"]) == Kind.ENTRY:
		return true
	var inside: Dictionary = _block_inside_set(tid)
	return inside.has(int(pos["node"]))


## Nodes whose flow sits strictly inside a block scope: forward reach from
## the block's exec outputs (loop blocks start from their body pin only),
## minus the block's merge node and everything after it.
func _block_inside_set(tid: int) -> Dictionary:
	var inside: Dictionary = {}
	var merge: int = -1
	var port_sets: Array = []
	for port: int in exec_out.get(tid, {}):
		var reach: Dictionary = _fwd_reach(int(exec_out[tid][port]), tid)
		port_sets.append(reach)
		for n: int in reach:
			inside[n] = true
	if port_sets.size() > 1:
		var inter: Dictionary = port_sets[0]
		for i: int in range(1, port_sets.size()):
			var keep: Dictionary = {}
			for n: int in port_sets[i]:
				if inter.has(n):
					keep[n] = true
			inter = keep
		var dist: Dictionary = _fwd_dist(tid)
		var best: int = 1 << 30
		for n: int in inter:
			var d: int = int(dist.get(n, 1 << 30))
			if d < best:
				best = d
				merge = n
	if merge >= 0:
		var beyond: Dictionary = _fwd_reach(merge, tid)
		beyond[merge] = true
		for n: int in beyond:
			inside.erase(n)
	return inside


## Forward exec-reachable set from `start` (never stepping through `stop`).
func _fwd_reach(start: int, stop: int) -> Dictionary:
	var seen: Dictionary = {}
	var queue: Array = [start]
	while not queue.is_empty():
		var cur: int = queue.pop_front()
		if seen.has(cur) or cur == stop:
			continue
		seen[cur] = true
		for port: int in exec_out.get(cur, {}):
			queue.append(int(exec_out[cur][port]))
	return seen


## BFS distance from a node through the exec chain.
func _fwd_dist(tid: int) -> Dictionary:
	var dist: Dictionary = {tid: 0}
	var queue: Array = [tid]
	while not queue.is_empty():
		var cur: int = queue.pop_front()
		for port: int in exec_out.get(cur, {}):
			var nxt: int = int(exec_out[cur][port])
			if not dist.has(nxt):
				dist[nxt] = int(dist[cur]) + 1
				queue.append(nxt)
	return dist


# ---- Variable reads as Get Variable nodes ------------------------------------
## After a script is loaded, a value pin that is just the name of a variable
## is fed by a node instead of the name sitting on the pin as text: a declared
## variable or argument gets a Get Variable node, a loop variable is wired
## from its For node's output pin. Covers Operator operands, If / Else If /
## While conditions, Return, Print, assignment values (`x = y`) and
## function-call arguments. The generated source is unchanged. Names that are
## not variables (enum members like `Phase.COOLDOWN`, literals), a pin still
## showing its declared default, and a source that would be out of scope or
## the wrong type at that spot stay as text.
func _wire_variable_reads() -> void:
	var ids: Array = nodes.keys()
	for id: int in ids:
		if not nodes.has(id):
			continue
		var k: int = int(nodes[id]["kind"])
		var last_pin: int = -1
		if k == Kind.OPERATOR or k == Kind.PRINT or k == Kind.CALL:
			last_pin = nodes[id]["data_ins"].size() - 1
		elif k == Kind.IF or k == Kind.ELIF or k == Kind.WHILE or k == Kind.RETURN:
			last_pin = mini(0, nodes[id]["data_ins"].size() - 1)
		elif k == Kind.STATEMENT and not nodes[id]["stmt"].is_empty() \
				and bool(nodes[id]["stmt"].get("has_value", false)):
			last_pin = mini(0, nodes[id]["data_ins"].size() - 1)
		for pin: int in range(0, last_pin + 1):
			if pin >= nodes[id]["data_ins"].size():
				break
			var pd: Dictionary = nodes[id]["data_ins"][pin]
			if not _connected_data_source(id, pin).is_empty():
				continue
			if int(pd["type"]) == Types.PinType.CALLABLE:
				continue
			var vname: String = String(pd["value"]).strip_edges()
			if not _valid_ident(vname) or _GD_KEYWORDS.has(vname):
				continue
			if vname == String(pd.get("default_text", "")).strip_edges():
				continue   # untouched default: wiring it would count as an override
			if _wire_loop_variable(id, pin, vname):
				nodes[id]["data_ins"][pin]["value"] = ""
				continue
			if String(_scope_of_name(vname)["kind"]) == "none":
				continue
			var raw: String = _var_decl_raw_type(vname)
			var vt: int = Types.type_from_name(raw) if raw != "" else Types.VARIANT
			var gid: int = add_node(Kind.VARIABLE_GET, {"name": vname, "type": vt})
			var res: Dictionary = connect_data(gid, 0, id, pin)
			if res.has("_rejected"):
				remove_node(gid)
				continue
			nodes[id]["data_ins"][pin]["value"] = ""


## Wires the For node that owns loop variable `vname` into a consumer pin when
## the consumer sits inside that loop's body (nearest loop wins). False when
## no such loop exists or the connection is refused.
func _wire_loop_variable(id: int, pin: int, vname: String) -> bool:
	var pos: Dictionary = _ref_position(id)
	if int(pos["entry"]) < 0:
		return false
	var best: int = -1
	for fid: int in nodes:
		if int(nodes[fid]["kind"]) != Kind.FOR or nodes[fid]["data_outs"].is_empty():
			continue
		if String(nodes[fid]["data_outs"][0]["name"]) != vname:
			continue
		if not _in_loop_body(fid, int(pos["node"])):
			continue
		if best < 0 or int(nodes[fid]["depth"]) > int(nodes[best]["depth"]):
			best = fid
	if best < 0:
		return false
	return not connect_data(best, 0, id, pin).has("_rejected")


## True when `anchor` runs inside the loop body of For node `for_id`: walking
## back along the execution chain reaches the For through its loop-body pin.
func _in_loop_body(for_id: int, anchor: int) -> bool:
	var seen: Dictionary = {}
	var queue: Array[int] = [anchor]
	while not queue.is_empty():
		var cur: int = queue.pop_front()
		if seen.has(cur):
			continue
		seen[cur] = true
		for e: Dictionary in exec_in.get(cur, []):
			var up: int = int(e["from_id"])
			if up == for_id:
				if int(e.get("from_port", 0)) == 0:
					return true
				continue   # reached through "done": after the loop
			if not seen.has(up):
				queue.append(up)
	return false


# ---- Method-call conditions --------------------------------------------------
## Declared type of the variable a condition calls a method on: a typed loop
## variable of the function being parsed, then one of its typed arguments,
## then a typed member variable. Empty when the name is unknown or untyped.
func _condition_owner_type(owner: String) -> String:
	if _entry_iter_types.has(owner):
		return str(_entry_iter_types[owner]).strip_edges()
	if _entry_iter_names.has(owner):
		return ""   # an untyped loop variable shadows everything else
	if _current_entry >= 0 and nodes.has(_current_entry):
		for aid: int in nodes[_current_entry]["fields"].get("args", []):
			if nodes.has(aid) and str(nodes[aid]["fields"].get("name", "")) == owner:
				return str(nodes[aid]["fields"].get("type", "")).strip_edges()
	return _var_decl_raw_type(owner)


## Rebuilds an If / Else If condition that is exactly one method call on a
## variable of a known built-in type (`mod.is_valid()` where `mod: Callable`)
## as a pure Function Call node wired into the condition pin, so the If is
## connected to its call node like a comparison is to its Operator node.
## The variable stays typed text on the call's Target pin, which generates
## the same source back (`if mod.is_valid():`). Returns false - and leaves
## the condition verbatim on the pin - when the owner's type is unknown, the
## method does not exist, returns nothing, or the arguments do not fit.
func _try_condition_call(if_id: int, cond: String, depth: int) -> bool:
	var s: String = cond.strip_edges()
	var open: int = s.find("(")
	if open <= 0 or not s.ends_with(")"):
		return false
	var name_part: String = s.substr(0, open)
	var dot: int = name_part.find(".")
	if dot <= 0 or dot != name_part.rfind("."):
		return false
	var owner: String = name_part.substr(0, dot)
	var fname: String = name_part.substr(dot + 1)
	if not _valid_ident(owner) or not _valid_ident(fname):
		return false
	var otype: String = _condition_owner_type(owner)
	if otype == "":
		return false
	# the call must span the whole condition (no `a.b() and c.d()`)
	var pdepth: int = 0
	var in_str: bool = false
	var quote: String = ""
	for i: int in range(open, s.length()):
		var ch: String = s[i]
		if in_str:
			if ch == quote:
				in_str = false
			continue
		if ch == "\"" or ch == "'":
			in_str = true
			quote = ch
		elif ch == "(":
			pdepth += 1
		elif ch == ")":
			pdepth -= 1
			if pdepth == 0 and i != s.length() - 1:
				return false
	var e: Dictionary = FuncReg.get_registry().find_entry(FuncReg.CAT_GODOT_TYPE, otype, fname)
	if e.is_empty() or bool(e.get("static", false)):
		return false
	var ret: String = str(e.get("ret", "void"))
	if ret == "void" or ret == "":
		return false
	var provided: PackedStringArray = FuncReg._split_top_commas(
		s.substr(open + 1, s.length() - open - 2))
	var args: Array = (e["args"] as Array).duplicate(true)
	if provided.size() > args.size() and not bool(e.get("vararg", false)):
		return false
	var min_args: int = 0
	for a: Dictionary in args:
		if bool(a.get("required", true)):
			min_args += 1
	if provided.size() < min_args:
		return false
	var keep: Dictionary = {"target": owner}
	for i: int in provided.size():
		if i < args.size():
			keep[str(args[i]["name"])] = provided[i]
	var cid: int = _make_node(Kind.CALL, depth)
	nodes[cid]["fields"] = {
		"call": fname, "cat": FuncReg.CAT_GODOT_TYPE, "owner": otype,
		"ret": ret, "mode": "pure", "static": false,
		"needs_target": true, "target_type": otype,
		"vararg": bool(e.get("vararg", false)),
		"args": args, "declared": true, "stale": false, "sig_changed": false,
		"member": "",
	}
	nodes[cid]["color"] = KIND_COLORS[Kind.CALL]
	_apply_call_meta(cid, keep)
	_convert_lambda_pin_values(cid, depth)
	if bool(e.get("vararg", false)) and provided.size() > args.size():
		var vps: Array = nodes[cid]["data_ins"]
		var extras: int = provided.size() - args.size()
		if vps.size() > 0:
			vps[vps.size() - 1]["value"] = str(provided[args.size()])
		for x: int in range(1, extras):
			vps.append({"name": _dyn_pin_name(cid), "type": Types.VARIANT,
				"value": str(provided[args.size() + x])})
	# The call lives on its own node only: the If keeps no duplicated text.
	nodes[if_id].data_ins[0]["value"] = ""
	nodes[if_id]["body"] = ""
	data_links.append({
		"from_id": cid, "from_out": 0,
		"to_id": if_id, "to_in": 0,
	})
	return true


# ---- Comparison parsing -----------------------------------------------------
## Splits a simple comparison condition (`lhs op rhs`) into its parts so an
## If/Else If parsed from a script reconstructs a comparison Operator node. Returns {}
## when the expression is anything else (boolean combinations, `not ...`,
## function calls, chained comparisons): those stay verbatim on the If's
## condition pin instead of being reconstructed wrongly. One level of
## wrapping parentheses is unwrapped first — exactly what a generated
## Operator node emits — so reloading a generated script round-trips.
func _split_comparison(cond: String) -> Dictionary:
	var c: String = cond.strip_edges()
	while c.begins_with("(") and c.ends_with(")") and _balanced_wrap(c):
		c = c.substr(1, c.length() - 2).strip_edges()
	if c == "" or c.begins_with("not ") or c.begins_with("!"):
		return {}
	var op: String = ""
	var cut: int = -1
	var depth: int = 0
	var in_str: bool = false
	var quote: String = ""
	var i: int = 0
	while i < c.length():
		var ch: String = c[i]
		if in_str:
			if ch == "\\":
				i += 2
				continue
			if ch == quote:
				in_str = false
		elif ch == "\"" or ch == "'":
			in_str = true
			quote = ch
		elif ch == "(" or ch == "[" or ch == "{":
			depth += 1
		elif ch == ")" or ch == "]" or ch == "}":
			depth -= 1
		elif depth == 0:
			var two: String = c.substr(i, 2)
			if two == "==" or two == "!=" or two == ">=" or two == "<=":
				op = two
				cut = i
				break
			if ch == "<" or ch == ">":
				op = ch
				cut = i
				break
		i += 1
	if cut <= 0:
		return {}
	var lhs: String = c.substr(0, cut).strip_edges()
	var rhs: String = c.substr(cut + op.length()).strip_edges()
	if not _is_simple_operand(lhs) or not _is_simple_operand(rhs):
		return {}
	return {"lhs": lhs, "op": op, "rhs": rhs}


## True when the first top-level "(" closes at the final character, so the
## whole expression is one parenthesized group that may be unwrapped.
func _balanced_wrap(c: String) -> bool:
	var depth: int = 0
	var in_str: bool = false
	var quote: String = ""
	for i: int in c.length():
		var ch: String = c[i]
		if in_str:
			if ch == quote:
				in_str = false
			continue
		if ch == "\"" or ch == "'":
			in_str = true
			quote = ch
		elif ch == "(":
			depth += 1
		elif ch == ")":
			depth -= 1
			if depth == 0:
				return i == c.length() - 1
	return false


## Operands a comparison Operator node can reconstruct verbatim: identifiers (with
## dots for members), numeric literals, string literals and true/false.
## Anything else keeps the whole condition on the If node.
func _is_simple_operand(t: String) -> bool:
	if t.is_empty():
		return false
	var q: String = t[0]
	if q == "\"" or q == "'":
		return t.length() >= 2 and t[t.length() - 1] == q \
			and t.substr(1, t.length() - 2).find(q) < 0
	if t == "true" or t == "false":
		return true
	if t.begins_with("-") and _is_number(t.substr(1)):
		return true
	if _is_number(t):
		return true
	return _is_ident_chain(t)


## Digits with at most one decimal point (`0`, `12`, `3.5`).
func _is_number(s: String) -> bool:
	if s.is_empty():
		return false
	var digits: int = 0
	var dot: bool = false
	for ch: String in s:
		if ch >= "0" and ch <= "9":
			digits += 1
		elif ch == "." and not dot:
			dot = true
		else:
			return false
	return digits > 0


## Dotted identifier chain (`health`, `max_speed`, `Player.hp`).
func _is_ident_chain(t: String) -> bool:
	for p: String in t.split("."):
		if p.is_empty() or not _is_ident(p):
			return false
	return true


func _is_ident(p: String) -> bool:
	var c0: String = p[0]
	if not ((c0 >= "a" and c0 <= "z") or (c0 >= "A" and c0 <= "Z") or c0 == "_"):
		return false
	for ch: String in p:
		if not ((ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z")
				or (ch >= "0" and ch <= "9") or ch == "_"):
			return false
	return true


## Regenerates the annotation text of an Annotation node and updates every
## declaration it is registered with. Returns the affected target ids.
func sync_annotation_targets(aid: int) -> Array[int]:
	var touched: Array[int] = []
	if not nodes.has(aid) or int(nodes[aid]["kind"]) != Kind.ANNOTATION:
		return touched
	var name: String = str(nodes[aid]["fields"].get("name", "")).strip_edges()
	if name == "":
		return touched
	var text: String = annotation_node_text(aid)
	for l: Dictionary in ann_links:
		if int(l["aid"]) != aid or not nodes.has(int(l["tid"])):
			continue
		_upsert_annotation_line(int(l["tid"]), name, text, 2)
		touched.append(int(l["tid"]))
	return touched


func add_argument(eid: int, base_name: String = "arg") -> int:
	if not nodes.has(eid) or int(nodes[eid]["kind"]) != Kind.ENTRY:
		return -1
	var args: Array = nodes[eid]["fields"].get("args", [])
	var name: String = base_name if base_name != "arg" else "%s1" % base_name
	var i: int = 1
	while not _arg_name_free(eid, name):
		i += 1
		name = "%s%d" % [base_name, i]
	var aid: int = _make_node(Kind.ARGUMENT)
	nodes[aid].fields = {"name": name, "type": "", "default": "", "parent": eid}
	# One data input (the value pin) and TWO outputs: the variable value pin
	# and the Function connection pin (visible ownership wire).
	nodes[aid].data_ins = [
		{"name": name, "type": Types.VARIANT, "value": ""},
	]
	nodes[aid].data_outs = [
		{"name": name, "type": Types.VARIANT},
		{"name": "Function", "type": Types.VARIANT},
	]
	nodes[aid].title = "arg: %s" % name
	args.append(aid)
	nodes[eid]["fields"]["args"] = args
	arg_links.append({"eid": eid, "aid": aid})
	nodes[eid]["sig"] = _sig_text(eid)
	nodes[eid]["body"] = nodes[eid]["sig"]
	_entry_sync_pins(eid)
	_resync_calls_for(String(nodes[eid]["fields"].get("name", "")))
	return aid


func _arg_name_free(eid: int, name: String) -> bool:
	for aid: int in nodes[eid]["fields"].get("args", []):
		if nodes.has(aid) and String(nodes[aid]["fields"].get("name", "")) == name:
			return false
	return true


## Moves an Argument one slot left (-1) or right (+1) in its Function's
## parameter list (reordering updates the generated declaration).
func move_argument(aid: int, dir: int) -> bool:
	if not nodes.has(aid) or int(nodes[aid]["kind"]) != Kind.ARGUMENT:
		return false
	var pid: int = int(nodes[aid]["fields"].get("parent", -1))
	if pid < 0 or not nodes.has(pid):
		return false
	var args: Array = nodes[pid]["fields"].get("args", [])
	var idx: int = args.find(aid)
	if idx < 0:
		return false
	var j: int = idx + dir
	if j < 0 or j >= args.size():
		return false
	var tmp: int = int(args[j])
	args[j] = aid
	args[idx] = tmp
	nodes[pid]["fields"]["args"] = args
	nodes[pid]["sig"] = _sig_text(pid)
	nodes[pid]["body"] = nodes[pid]["sig"]
	_entry_sync_pins(pid)
	_resync_calls_for(String(nodes[pid]["fields"].get("name", "")))
	return true


## Structured Argument property edit: "name" / "type" / "default".
## Renames update the node, its output pin and textual references in the
## parent function's flow; type changes revalidate existing connections.
func set_arg_prop(aid: int, key: String, value: String) -> bool:
	if not nodes.has(aid) or int(nodes[aid]["kind"]) != Kind.ARGUMENT:
		return false
	var a: Dictionary = nodes[aid]
	var v: String = value.strip_edges()
	var pid: int = int(a["fields"].get("parent", -1))
	if key == "name":
		if not _valid_ident(v):
			return false
		var old: String = String(a["fields"].get("name", ""))
		a["fields"]["name"] = v
		a["title"] = "arg: %s" % v
		if a["data_outs"].size() > 0:
			a["data_outs"][0]["name"] = v
		if a["data_ins"].size() > 0:
			a["data_ins"][0]["name"] = v
		if pid >= 0 and nodes.has(pid):
			_entry_sync_pins(pid)
		if old != v and pid >= 0 and nodes.has(pid):
			_replace_ident_in_flow(pid, old, v)
			_resync_calls_for(String(nodes[pid]["fields"].get("name", "")))
	elif key == "type":
		if v != "" and not _valid_type_name(v):
			return false
		a["fields"]["type"] = v
		var t: int = Types.type_from_name(v) if v != "" else Types.VARIANT
		if a["data_outs"].size() > 0:
			a["data_outs"][0]["type"] = t
		if a["data_ins"].size() > 0:
			a["data_ins"][0]["type"] = t
		_validate_out_links(aid, 0)
		_validate_in_links(aid, 0)
		_validate_in_links(aid, 1)
		if pid >= 0 and nodes.has(pid):
			_entry_sync_pins(pid)
			_resync_calls_for(String(nodes[pid]["fields"].get("name", "")))
	elif key == "default":
		if not _valid_exprish(v):
			return false
		a["fields"]["default"] = v
		if pid >= 0 and nodes.has(pid):
			_resync_calls_for(String(nodes[pid]["fields"].get("name", "")))
	else:
		return false
	if pid >= 0 and nodes.has(pid):
		nodes[pid]["sig"] = _sig_text(pid)
		nodes[pid]["body"] = nodes[pid]["sig"]
	return true


## A default value / expression fragment: non-empty, no newline.
func _valid_exprish(s: String) -> bool:
	return not s.contains("\n")


## The id of the most recently built Function node (roots keep entry ids).
func _last_entry_id() -> int:
	for i: int in range(roots.size() - 1, -1, -1):
		if roots[i].has("entry"):
			return int(roots[i]["entry"])
	return -1


# ---- Annotation subsystem ---------------------------------------------------
# Annotations are preserved verbatim per declaration and exposed structurally:
# variables keep their original prefix text ("@export static" etc.), functions
# carry their trailing annotation run, and the Script Header keeps its
# directive lines. The registry validates names, placement and arguments
# against the real Godot 4.7.x rules; unknown annotations are kept and
# reported, never silently dropped.


## Splits a declaration prefix into its annotations (source order) and a
## "static" flag. Unknown tokens end the prefix (they stay in the verbatim
## prefix text, so nothing is lost).
func _split_prefix(text: String) -> Dictionary:
	var anns: PackedStringArray = PackedStringArray()
	var is_static: bool = false
	var s: String = text.strip_edges()
	var i: int = 0
	while i < s.length():
		while i < s.length() and (s[i] == " " or s[i] == "\t" or s[i] == "\n"):
			i += 1
		if i >= s.length():
			break
		if s[i] == "@":
			var end: int = _annotation_end(s, i)
			if end < 0:
				break
			anns.append(s.substr(i, end - i).strip_edges())
			i = end
		elif s.substr(i).begins_with("static"):
			var e: int = i + 6
			if e >= s.length() or not _is_ident_char(s[e]):
				is_static = true
				i = e
			else:
				break
		else:
			break
	return {"anns": anns, "static": is_static}


## Index just past the annotation starting at `i` (-1 when unbalanced).
func _is_ident_char(c: String) -> bool:
	return "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789".contains(c)


func _annotation_end(s: String, i: int) -> int:
	var n: int = s.length()
	i += 1
	while i < n and _is_ident_char(s[i]):
		i += 1
	if i < n and s[i] == "(":
		var depth: int = 0
		var in_str: String = ""
		while i < n:
			var c: String = s[i]
			if in_str != "":
				if c == "\\":
					i += 2
					continue
				if c == in_str:
					in_str = ""
				i += 1
				continue
			if c == "\"" or c == "'":
				in_str = c
				i += 1
				continue
			if c == "(":
				depth += 1
			elif c == ")":
				depth -= 1
				if depth == 0:
					return i + 1
			i += 1
		return -1
	# a bare directive (class_name Foo) takes its identifier too
	var dirname: String = s.substr(1, i - 1)
	if dirname == "class_name":
		while i < n and (s[i] == " " or s[i] == "\t"):
			i += 1
		while i < n and s[i] != "\n" and s[i] != "#":
			i += 1
	return i


## The trailing annotation run of a text block (used for lines carried in
## front of a function): annotations are taken from the end so any comments
## interleaved earlier keep their verbatim position.
func _split_func_carry(text: String) -> Dictionary:
	var anns: PackedStringArray = PackedStringArray()
	var lines: PackedStringArray = PackedStringArray(text.split("\n"))
	var i: int = lines.size()
	while i > 0:
		var ln: String = lines[i - 1].strip_edges()
		if ln == "" or not ln.begins_with("@"):
			break
		var acc: String = ln
		var depth: int = _paren_depth(acc)
		while depth > 0 and i - 2 >= 0:
			i -= 1
			acc = lines[i - 1].strip_edges() + " " + acc
			depth = _paren_depth(acc)
		anns.insert(0, acc)
		i -= 1
	return {"anns": anns, "rest": "\n".join(lines.slice(0, i))}


func _paren_depth(s: String) -> int:
	var depth: int = 0
	var in_str: String = ""
	var i: int = 0
	while i < s.length():
		var c: String = s[i]
		if in_str != "":
			if c == "\\":
				i += 2
				continue
			if c == in_str:
				in_str = ""
			i += 1
			continue
		if c == "\"" or c == "'":
			in_str = c
		elif c == "(":
			depth += 1
		elif c == ")":
			depth -= 1
		i += 1
	return depth


## The annotations attached to a Variable or Function node (source order).
func annotations_of(id: int) -> PackedStringArray:
	if not nodes.has(id):
		return PackedStringArray()
	var n: Dictionary = nodes[id]
	var k: int = int(n["kind"])
	if k == Kind.ENTRY:
		var joined: String = String(n["fields"].get("annotations", ""))
		return joined.split("\n") if joined != "" else PackedStringArray()
	if k == Kind.VAR_DECL:
		return _split_prefix(String(n["fields"].get("prefix", "")))["anns"]
	return PackedStringArray()


## The rebuilt prefix text for a Variable node: verbatim while untouched;
## after an annotation edit the canonical form (annotations one per line,
## "static" trailing the last annotation) is generated.
## Validates an annotation list against the registry and stores the problems
## on the node; the annotation text itself is always kept.
func _validate_annotation_list(id: int, texts: PackedStringArray, target: String) -> void:
	var n: Dictionary = nodes[id]
	var problems: PackedStringArray = PackedStringArray()
	var reg: RefCounted = AnnReg.get_registry()
	for t: String in texts:
		var msg: String = reg.validate(t, target)
		if msg != "":
			problems.append(msg)
	if n["fields"].has("ann_problems") or not problems.is_empty():
		n["fields"]["ann_problems"] = problems


## Structured annotation edit on a Variable or Function node: replaces the
## annotation at `index` (-1 appends). Returns false when out of range or
## the node kind does not carry annotations.
func set_annotation(id: int, index: int, text: String) -> bool:
	if not nodes.has(id):
		return false
	var k: int = int(nodes[id]["kind"])
	var target: String = ""
	if k == Kind.ENTRY:
		target = "func"
	elif k == Kind.VAR_DECL:
		target = "var"
	else:
		return false
	var anns: PackedStringArray = annotations_of(id)
	if index < 0 or index >= anns.size():
		return false
	anns[index] = text.strip_edges()
	# The row editor may show a separate "@" prefix; whatever the user types,
	# the stored annotation always carries its "@" so generation stays valid.
	if anns[index] != "" and not anns[index].begins_with("@"):
		anns[index] = "@" + anns[index]
	_store_annotations(id, anns, target)
	_sync_annotation_pins(id)
	return true


## Appends an annotation template to a Variable or Function node.
func add_annotation(id: int, template: String = "") -> bool:
	if not nodes.has(id):
		return false
	var k: int = int(nodes[id]["kind"])
	var target: String = ""
	if k == Kind.ENTRY:
		target = "func"
		template = "@rpc(\"authority\", \"call_remote\", \"reliable\", 0)" if template == "" else template
	elif k == Kind.VAR_DECL:
		target = "var"
		template = "@export" if template == "" else template
	else:
		return false
	var anns: PackedStringArray = annotations_of(id)
	anns.append(template)
	_store_annotations(id, anns, target)
	_sync_annotation_pins(id)
	return true


## Splits an annotation argument list into its top-level arguments (commas
## outside quotes and parentheses). "" yields no arguments.
func _annotation_split_args(argtext: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var cur: String = ""
	var depth: int = 0
	var in_str: String = ""
	for i: int in argtext.length():
		var c: String = argtext[i]
		if in_str != "":
			cur += c
			if c == "\\" and i + 1 < argtext.length():
				cur += argtext[i + 1]
				continue
			if c == in_str:
				in_str = ""
			continue
		if c == "\"" or c == "'":
			in_str = c
			cur += c
			continue
		if c == "(" or c == "[":
			depth += 1
			cur += c
			continue
		if c == ")" or c == "]":
			depth -= 1
			cur += c
			continue
		if c == "," and depth == 0:
			out.append(cur.strip_edges())
			cur = ""
			continue
		cur += c
	if cur.strip_edges() != "":
		out.append(cur.strip_edges())
	return out


## Converts one stored annotation of a declaration (Variable row, Function
## row or Script Header line) into a real Annotation node: the node is
## created from the registry entry, its argument pins carry the source
## arguments verbatim, and it is registered on the declaration (the source
## line is replaced in place by the node's text). Returns the node id, -1
## when the annotation cannot be represented byte-identically as a node
## (unknown annotation, too many arguments, non-round-tripping text) — the
## stored row then stays exactly as it was.
func convert_annotation_line(tid: int, index: int) -> int:
	if not nodes.has(tid):
		return -1
	var k: int = int(nodes[tid]["kind"])
	var text: String = ""
	if k == Kind.VAR_DECL:
		var anns0: PackedStringArray = annotations_of(tid)
		if index < 0 or index >= anns0.size():
			return -1
		text = String(anns0[index]).strip_edges()
	elif k == Kind.ENTRY:
		var joined: String = String(nodes[tid]["fields"].get("annotations", ""))
		var arr0: PackedStringArray = joined.split("\n") if joined.strip_edges() != "" else PackedStringArray()
		if index < 0 or index >= arr0.size():
			return -1
		text = String(arr0[index]).strip_edges()
	elif k == Kind.PREAMBLE:
		var lines0: PackedStringArray = header_lines(tid)
		if index < 0 or index >= lines0.size():
			return -1
		text = String(lines0[index]).strip_edges()
	else:
		return -1
	if text == "" or not text.begins_with("@"):
		return -1
	var name: String = _annotation_name_of_line(text)
	if name == "":
		return -1
	var ae: Dictionary = AnnReg.get_registry().find(name)
	if ae.is_empty():
		return -1
	var target: String = _annotation_target_of(tid)
	if target == "" or not (ae["targets"] as Array).has(target):
		return -1
	var argtext: String = ""
	var open: int = text.find("(")
	if open >= 0:
		var close: int = text.rfind(")")
		if close < open:
			return -1
		argtext = text.substr(open + 1, close - open - 1).strip_edges()
	elif text != "@" + name:
		return -1   # trailing garbage after a bare annotation name
	var prms: Array = (ae["params"] as Array).duplicate(true)
	var vals: PackedStringArray = PackedStringArray()
	if argtext != "":
		if prms.size() == 1 and bool(prms[0].get("variadic", false)):
			vals.append(argtext)
		else:
			vals = _annotation_split_args(argtext)
			if vals.size() > prms.size():
				return -1
	# snapshot for the failure path (the row must survive unchanged)
	var orig_var: PackedStringArray = annotations_of(tid) if k == Kind.VAR_DECL else PackedStringArray()
	var orig_entry: String = String(nodes[tid]["fields"].get("annotations", "")) if k == Kind.ENTRY else ""
	var orig_body: String = String(nodes[tid]["body"]) if k == Kind.PREAMBLE else ""
	var aid: int = add_node(Kind.ANNOTATION, {"name": name, "args": prms})
	if aid < 0:
		return -1
	for i: int in (nodes[aid]["data_ins"] as Array).size():
		set_pin_value(aid, i, String(vals[i]) if i < vals.size() else "")
	if register_annotation(tid, aid, 2, index) < 0:
		remove_node(aid)
		return -1
	if annotation_node_text(aid) != text:
		# the node's canonical text differs from the source: restore the
		# original row and drop the node again
		unregister_annotation(tid, aid)
		if k == Kind.VAR_DECL:
			_store_annotations(tid, orig_var, "var", 2)
		elif k == Kind.ENTRY:
			nodes[tid]["fields"]["annotations"] = orig_entry
		else:
			nodes[tid]["body"] = orig_body
		remove_node(aid)
		return -1
	return aid


## Loader step 1 for export groups. Godot's @export_group applies to every
## export that follows it until the next group marker, so a parsed
## `@export_group("X")` line is NOT kept as an annotation of the Variable
## below it: it becomes a standalone @export_group node (wired later to the
## Export Group pin of every export annotation it governs). An empty group
## (`@export_group("")`) only resets the active group and needs no node.
## Returns {variable id: group node id, or -1 for a reset} for each variable
## whose own annotation list carried a group line.
func _extract_export_groups() -> Dictionary:
	var starts: Dictionary = {}
	for r: Dictionary in roots:
		if not r.has("node"):
			continue
		var tid: int = int(r["node"])
		if not nodes.has(tid) or int(nodes[tid]["kind"]) != Kind.VAR_DECL \
				or str(nodes[tid]["fields"].get("scope", "public")) != "public":
			continue
		var anns: PackedStringArray = annotations_of(tid)
		var keep: PackedStringArray = PackedStringArray()
		var found: bool = false
		var gid_here: int = -1
		for a: String in anns:
			var t: String = String(a).strip_edges()
			if not t.begins_with("@") or _annotation_name_of_line(t) != "export_group":
				keep.append(a)
				continue
			var gid: int = _group_node_from_line(t)
			if gid == -2:
				keep.append(a)   # not representable: stays verbatim
				continue
			found = true
			gid_here = gid
		if found:
			_store_annotations(tid, keep, "var", 2)
			starts[tid] = gid_here
	return starts


## Creates the @export_group node for a parsed group line. Returns its id,
## -1 for the empty (reset) group, -2 when the line cannot be represented
## byte-identically (the caller keeps it verbatim).
func _group_node_from_line(text: String) -> int:
	var open: int = text.find("(")
	var close: int = text.rfind(")")
	if open < 0 or close < open:
		return -2
	var argtext: String = text.substr(open + 1, close - open - 1).strip_edges()
	var vals: PackedStringArray = _annotation_split_args(argtext) if argtext != "" else PackedStringArray()
	if vals.size() == 0 or vals.size() > 2:
		return -2
	if (vals.size() == 1 and (String(vals[0]).strip_edges() == "\"\"" or String(vals[0]).strip_edges() == "''")):
		return -1
	var ae: Dictionary = AnnReg.get_registry().find("export_group")
	if ae.is_empty():
		return -2
	var gid: int = add_node(Kind.ANNOTATION, {"name": "export_group",
		"args": (ae["params"] as Array).duplicate(true)})
	if gid < 0:
		return -2
	for i: int in (nodes[gid]["data_ins"] as Array).size():
		set_pin_value(gid, i, String(vals[i]) if i < vals.size() else "")
	if annotation_node_text(gid) != text:
		remove_node(gid)
		return -2
	return gid


## Loader step 2: wires every export-family annotation node to the group in
## force at its variable (source order), one visible Export Group wire each.
func _link_export_groups(group_start: Dictionary) -> void:
	var active: int = -1
	for r: Dictionary in roots:
		if not r.has("node"):
			continue
		var tid: int = int(r["node"])
		if not nodes.has(tid) or int(nodes[tid]["kind"]) != Kind.VAR_DECL:
			continue
		if group_start.has(tid):
			active = int(group_start[tid])
		elif _var_has_group_line(tid):
			active = -1   # a verbatim group line governs from here on
		if active < 0:
			continue
		for l: Dictionary in ann_links:
			if int(l["tid"]) != tid or not nodes.has(int(l["aid"])):
				continue
			var xid: int = int(l["aid"])
			if _is_export_family(str(nodes[xid]["fields"].get("name", ""))) \
					and group_of(xid) < 0:
				register_group(xid, active)


## True when a Variable still carries a verbatim @export_group line.
func _var_has_group_line(vid: int) -> bool:
	for a: String in annotations_of(vid):
		if _annotation_name_of_line(String(a).strip_edges()) == "export_group":
			return true
	return false


## True when a Variable carries any export-family annotation (node or text).
func _var_has_export(vid: int) -> bool:
	for a: String in annotations_of(vid):
		var t: String = String(a).strip_edges()
		if t.begins_with("@") and _is_export_family(_annotation_name_of_line(t)):
			return true
	return false


## Parse pass: every annotation parsed from the source becomes a real
## Annotation node wired to its declaration (the user requirement: no plain
## text fields — annotations are nodes with their own argument pins).
## Annotations that cannot be represented byte-identically (unknown name,
## argument overflow, exotic spacing) stay as their original rows.
func _convert_parsed_annotations() -> void:
	var group_start: Dictionary = _extract_export_groups()
	for tid: int in nodes.keys():
		var k: int = int(nodes[tid]["kind"])
		if k == Kind.VAR_DECL:
			if str(nodes[tid]["fields"].get("scope", "public")) != "public":
				continue
			var anns: PackedStringArray = annotations_of(tid)
			for i: int in anns.size():
				convert_annotation_line(tid, i)
		elif k == Kind.ENTRY:
			var joined: String = String(nodes[tid]["fields"].get("annotations", ""))
			if joined.strip_edges() == "":
				continue
			var cnt: int = joined.split("\n").size()
			for i2: int in cnt:
				convert_annotation_line(tid, i2)
		elif k == Kind.PREAMBLE:
			# only the canonical class-level placement (before
			# extends/class_name) is converted; anything else stays verbatim
			var lines: PackedStringArray = header_lines(tid)
			var limit: int = lines.size()
			for li: int in lines.size():
				var ln: String = String(lines[li]).strip_edges()
				if ln.begins_with("extends ") or ln.begins_with("class_name ") \
						or ln == "extends" or ln == "class_name":
					limit = li
					break
			for i3: int in limit:
				if String(lines[i3]).strip_edges().begins_with("@"):
					convert_annotation_line(tid, i3)
	# Annotation pins for every declaration (one per annotation entry).
	for tid2: int in nodes.keys():
		_sync_annotation_pins(tid2)
	_link_export_groups(group_start)
	# Script Header metadata nodes: class_name / extends lines get their own
	# dedicated nodes wired to the header (the body stores the line).
	for tid3: int in nodes.keys():
		if int(nodes[tid3]["kind"]) != Kind.PREAMBLE:
			continue
		var hlines: PackedStringArray = String(nodes[tid3]["body"]).split("\n")
		for li: int in hlines.size():
			var ln: String = String(hlines[li]).strip_edges()
			if ln.begins_with("class_name ") and int(_header_meta_count(tid3, "class_name")) == 0:
				var cn: String = ln.substr("class_name ".length()).strip_edges()
				var tail_base: String = ""
				var sp: int = cn.find(" extends ")
				if sp >= 0:
					tail_base = cn.substr(sp + 9).strip_edges()
					cn = cn.substr(0, sp).strip_edges()
				var cnid: int = add_node(Kind.CLASS_NAME, {"name": cn})
				header_links.append({"hid": tid3, "nid": cnid, "kind": "class_name"})
				if tail_base != "" and int(_header_meta_count(tid3, "extends")) == 0:
					var enid2: int = add_node(Kind.EXTENDS_DECL, {"base": tail_base})
					header_links.append({"hid": tid3, "nid": enid2, "kind": "extends"})
			elif ln.begins_with("extends ") and int(_header_meta_count(tid3, "extends")) == 0:
				var base: String = ln.substr("extends ".length()).strip_edges()
				var enid: int = add_node(Kind.EXTENDS_DECL, {"base": base})
				header_links.append({"hid": tid3, "nid": enid, "kind": "extends"})


func remove_annotation(id: int, index: int) -> bool:
	if not nodes.has(id):
		return false
	var k: int = int(nodes[id]["kind"])
	if k != Kind.ENTRY and k != Kind.VAR_DECL and k != Kind.PREAMBLE:
		return false
	var gone_name: String = ""
	if k == Kind.PREAMBLE:
		var lines: PackedStringArray = _annotation_lines_of(id)
		if index < 0 or index >= lines.size():
			return false
		gone_name = _annotation_name_of_line(String(lines[index]))
		_drop_annotation_at(id, index)
	else:
		var target: String = "func" if k == Kind.ENTRY else "var"
		var anns: PackedStringArray = annotations_of(id)
		if index < 0 or index >= anns.size():
			return false
		gone_name = _annotation_name_of_line(String(anns[index]))
		anns.remove_at(index)
		_store_annotations(id, anns, target)
	# A line removed by hand also drops the registration of the Annotation
	# node that owned it (the wire no longer reflects the declaration).
	if gone_name != "":
		for i: int in range(ann_links.size() - 1, -1, -1):
			var l: Dictionary = ann_links[i]
			if int(l["tid"]) == id and nodes.has(int(l["aid"])) \
					and str(nodes[int(l["aid"])]["fields"].get("name", "")) == gone_name:
				ann_links.remove_at(i)
	# Removing an annotation removes ONLY its own pin and connection; the
	# slots of the other annotations shift accordingly.
	for i2: int in range(ann_links.size() - 1, -1, -1):
		var l2: Dictionary = ann_links[i2]
		if int(l2["tid"]) == id and int(l2["slot"]) > index:
			l2["slot"] = int(l2["slot"]) - 1
	_sync_annotation_pins(id)
	return true


func _store_annotations(id: int, anns: PackedStringArray, target: String,
		inline: int = 0) -> void:
	var n: Dictionary = nodes[id]
	if int(n["kind"]) == Kind.ENTRY:
		n["fields"]["annotations"] = "\n".join(anns)
		_validate_annotation_list(id, anns, target)
		return
	# Variable: rebuild the prefix text ("static" rides the last line)
	var spfx: Dictionary = _split_prefix(String(n["fields"].get("prefix", "")))
	var rebuilt: String = ""
	if anns.is_empty():
		rebuilt = "static" if bool(spfx["static"]) else ""
	else:
		rebuilt = "\n".join(anns)
		if bool(spfx["static"]):
			rebuilt += " static"
	n["fields"]["prefix"] = rebuilt
	n["fields"]["annotations"] = "\n".join(anns)
	n["fields"]["is_static"] = bool(spfx["static"])
	# Placement style: 0 = canonical (annotations on their own lines),
	# 1 = inline (the annotation chain joins the declaration line, matching
	# `@export var health: int = 100`), 2 = keep the current style.
	if inline == 1:
		n["fields"]["ann_inline"] = true
		n["fields"]["inline_ann_text"] = "\n".join(anns)
	elif inline == 0:
		n["fields"]["ann_inline"] = false
		n["fields"]["inline_ann_text"] = ""
	elif bool(n["fields"].get("ann_inline", false)):
		# Keep the current style: only the annotations that were on the
		# declaration line before (matched by name) stay inline; own-line
		# annotations (e.g. @export_group above `@export var x`) keep their
		# own lines instead of being pulled onto the declaration.
		var inline_names: Dictionary = {}
		for ol: String in _split_prefix(str(n["fields"].get("inline_ann_text", "")))["anns"]:
			inline_names[_annotation_name_of_line(ol)] = true
		var chain2: PackedStringArray = PackedStringArray()
		for a2: String in anns:
			if inline_names.has(_annotation_name_of_line(a2)):
				chain2.append(a2)
		n["fields"]["inline_ann_text"] = "\n".join(chain2)
	_validate_annotation_list(id, anns, target)
	n["body"] = _emit_root_text(id)


## The Script Header's directive lines (extends, class_name, annotations).
func header_lines(id: int) -> PackedStringArray:
	if not nodes.has(id) or int(nodes[id]["kind"]) != Kind.PREAMBLE:
		return PackedStringArray()
	return PackedStringArray(String(nodes[id]["body"]).split("\n"))


## Replaces header directive line `index` (-1 appends an empty line).
## class_name/extends lines are validated loosely (identifier / type name);
## annotation lines are validated against the registry's class target.
func set_header_line(id: int, index: int, text: String) -> bool:
	if not nodes.has(id) or int(nodes[id]["kind"]) != Kind.PREAMBLE:
		return false
	var lines: PackedStringArray = header_lines(id)
	if index < 0:
		lines.append("")
	elif index >= lines.size():
		return false
	else:
		lines[index] = text
	nodes[id]["body"] = "\n".join(lines)
	var problems: PackedStringArray = PackedStringArray()
	var reg: RefCounted = AnnReg.get_registry()
	for ln: String in lines:
		var t: String = ln.strip_edges()
		if not t.begins_with("@"):
			continue
		var msg: String = reg.validate(t, "class")
		if msg != "":
			problems.append(msg)
	if nodes[id]["fields"].has("ann_problems") or not problems.is_empty():
		nodes[id]["fields"]["ann_problems"] = problems
	return true


## Registry target for the annotations carried by a node kind ("" = none).
func _annotation_target(kind: int) -> String:
	if kind == Kind.ENTRY:
		return "func"
	if kind == Kind.VAR_DECL:
		return "var"
	if kind == Kind.PREAMBLE:
		return "class"
	return "statement"


## Structured Variable (top-level var) property edit: "name" / "type" /
## "default". Untyped variables stay untyped unless the user sets a type.
func set_var_prop(id: int, key: String, value: String) -> bool:
	if not nodes.has(id) or int(nodes[id]["kind"]) != Kind.VAR_DECL:
		return false
	var n: Dictionary = nodes[id]
	var v: String = value.strip_edges()
	var st: Dictionary = n["stmt"]
	if key == "name":
		if not _valid_ident(v):
			return false
		var old: String = String(n["fields"].get("name", ""))
		n["fields"]["name"] = v
		n["title"] = "var %s" % v
		st["name"] = v
		if n["data_outs"].size() > 0:
			n["data_outs"][0]["name"] = v
		if old != v:
			_replace_ident_everywhere(old, v, id)
			if int(n["kind"]) == Kind.VAR_DECL:
				_var_rename_in_accessors(id, old, v)
				_accessor_refresh_titles(id)
				# the name shown beside the variable's scope pin follows
				for sh: int in scope_hosts_of(id):
					_add_scope_slot(sh)
	elif key == "has_setter" or key == "has_getter" or key == "setter" \
			or key == "getter" or key == "setter_arg" or key == "tail":
		if not _set_var_accessor_prop(id, key, value):
			return false
	elif key == "type":
		if not _valid_type_name(v):
			return false
		n["fields"]["raw_type"] = v
		var t: int = Types.type_from_name(v) if v != "" else Types.VARIANT
		st["type"] = t
		if n["data_outs"].size() > 0:
			n["data_outs"][0]["type"] = t
			n["data_outs"][0]["type_text"] = v
		if n["data_ins"].size() > 0:
			n["data_ins"][0]["type"] = t
		_validate_out_links(id, 0)
		if n["data_ins"].size() > 0:
			_validate_in_links(id, 0)
		_retype_var_refs(String(n["fields"].get("name", "")), t, v)
	elif key == "scope":
		if v != "public" and v != "private":
			return false
		if String(n["fields"].get("scope", "public")) == v:
			return true
		if v == "private":
			# A private variable needs a designated owning function.
			var owner: int = -1
			for id2: int in nodes:
				var nk: int = int(nodes[id2]["kind"])
				if nk != Kind.VARIABLE_GET and nk != Kind.VARIABLE_SET:
					continue
				if str(nodes[id2]["fields"].get("name", "")) != String(n["fields"].get("name", "")):
					continue
				var pos: Dictionary = _ref_position(id2)
				if int(pos["entry"]) >= 0:
					owner = int(pos["entry"])
					break
			if owner < 0:
				for id3: int in nodes:
					if int(nodes[id3]["kind"]) == Kind.ENTRY:
						owner = id3
						break
			if owner < 0:
				return false   # no function to own the local declaration
			n["fields"]["scope"] = "private"
			n["fields"]["owner"] = owner
			if not func_privates.has(owner):
				func_privates[owner] = []
			func_privates[owner].append(id)
			_sanitize_refs_for_scope(id)
		else:
			n["fields"]["scope"] = "public"
			n["fields"]["owner"] = -1
			for eid2: int in func_privates:
				func_privates[eid2].erase(id)
		_var_sync_scope_pin(id)
	elif key == "static":
		# UI authoring route: toggle the `static` keyword on a top-level var.
		var want: bool = v == "true" or v == "static"
		if v != "true" and v != "static" and v != "false" and v != "":
			return false
		var spfx3: Dictionary = _split_prefix(String(n["fields"].get("prefix", "")))
		var ann_text: String = "\n".join(spfx3["anns"] as PackedStringArray)
		var rebuilt3: String = ""
		if ann_text.strip_edges() != "":
			rebuilt3 = ann_text.strip_edges()
			if want:
				rebuilt3 += " static"
		elif want:
			rebuilt3 = "static"
		n["fields"]["prefix"] = rebuilt3
		n["fields"]["is_static"] = want
	elif key == "annotations":
		# value: full annotation list joined with newlines; the "static"
		# keyword and the rest of the prefix stay untouched
		var anns: PackedStringArray = PackedStringArray()
		if v != "":
			anns = AnnReg.get_registry().split_annotations(v)
		var spfx2: Dictionary = _split_prefix(String(n["fields"].get("prefix", "")))
		var rebuilt: String = ""
		if not anns.is_empty():
			rebuilt = "\n".join(anns)
			if bool(spfx2["static"]):
				rebuilt += " static"
		elif bool(spfx2["static"]):
			rebuilt = "static"
		n["fields"]["prefix"] = rebuilt
		n["fields"]["annotations"] = "\n".join(anns)
		n["fields"]["ann_inline"] = false
		n["fields"]["inline_ann_text"] = ""
		_validate_annotation_list(id, anns, "var")
	elif key == "default":
		if not _valid_exprish(v):
			return false
		n["fields"]["default"] = v
		if v != "":
			st["has_value"] = true
			if String(st.get("op", "")) == "":
				st["op"] = "="
			st["rhs"] = v
			if n["data_ins"].is_empty():
				n["data_ins"] = [{"name": "value", "type": int(st.get("type", Types.VARIANT)), "value": v}]
			else:
				n["data_ins"][0]["value"] = v
		else:
			# Empty default: the Default Value row stays visible and editable;
			# only the stored value is cleared (an existing wire still wins
			# at generation time, so it is left alone).
			st["has_value"] = false
			st["rhs"] = ""
			if n["data_ins"].is_empty():
				n["data_ins"] = [{"name": "value", "type": int(st.get("type", Types.VARIANT)), "value": ""}]
			else:
				n["data_ins"][0]["value"] = ""
	else:
		return false
	n["body"] = _emit_root_text(id)
	return true


## Drops references that became invalid after a variable turned private:
## Get/Set nodes outside the owner function lose their reference (name reset,
## types reset, wires removed) and the variable's own output links to
## consumers outside the owner are removed.
func _sanitize_refs_for_scope(vid: int) -> void:
	var vname: String = String(nodes[vid]["fields"].get("name", ""))
	for id: int in nodes:
		var k: int = int(nodes[id]["kind"])
		if k != Kind.VARIABLE_GET and k != Kind.VARIABLE_SET:
			continue
		if str(nodes[id]["fields"].get("name", "")) != vname:
			continue
		var pos: Dictionary = _ref_position(id)
		if _private_pos_allowed(vid, pos):
			continue
		_clear_var_reference(id)
	# the variable's own value output only feeds its assigned scope
	for i: int in range(data_links.size() - 1, -1, -1):
		var l: Dictionary = data_links[i]
		if int(l["from_id"]) != vid or int(l["from_out"]) != 0:
			continue
		var pos2: Dictionary = _ref_position(int(l["to_id"]))
		if not _private_pos_allowed(vid, pos2):
			data_links.remove_at(i)


## Resets a Get/Set Variable node to an empty reference (no variable name).
func _clear_var_reference(id: int) -> void:
	var k: int = int(nodes[id]["kind"])
	nodes[id]["fields"]["name"] = ""
	if k == Kind.VARIABLE_GET:
		nodes[id]["data_outs"] = [{"name": "", "type": Types.VARIANT}]
		nodes[id]["title"] = "Get"
	else:
		nodes[id]["data_ins"] = [{"name": "value", "type": Types.VARIANT, "value": ""}]
		nodes[id]["data_outs"] = [{"name": "", "type": Types.VARIANT}]
		nodes[id]["title"] = "Set"
		# Bypass the sanitized Set node in the exec chain so the flow stays
		# connected and generates valid GDScript without the dead node.
		var nxt: int = _exec_target(id, 0)
		var incoming: Array = exec_in.get(id, [])
		for src: Dictionary in incoming:
			var sid: int = int(src["from_id"])
			for port: int in exec_out.get(sid, {}).keys():
				if int(exec_out[sid][port]) == id:
					if nxt >= 0:
						exec_out[sid][port] = nxt
						if not exec_in.has(nxt):
							exec_in[nxt] = []
						exec_in[nxt].append({"from_id": sid, "from_port": port})
					else:
						exec_out[sid].erase(port)
		exec_out[id] = {}
		exec_in[id] = []
	for i: int in range(data_links.size() - 1, -1, -1):
		var l: Dictionary = data_links[i]
		if int(l["from_id"]) == id or int(l["to_id"]) == id:
			data_links.remove_at(i)


func add_node(kind: int, fields: Dictionary = {}) -> int:
	var id: int = _make_node(kind)
	var n: Dictionary = nodes[id]
	match kind:
		Kind.PREAMBLE:
			# Authorable "Script Header": gives header-less scripts a place
			# to add extends / class_name / class-level annotations.
			var lines: String = str(fields.get("lines", "")).strip_edges()
			n["body"] = lines
			n["title"] = "Script Header"
			n["data_ins"] = [
				{"name": "class name", "type": Types.PinType.ANNOTATION, "value": ""},
				{"name": "extends", "type": Types.PinType.ANNOTATION, "value": ""},
				{"name": "add annotation", "type": Types.PinType.ANNOTATION, "value": ""},
			]
			_header_id = id
			roots.insert(0, {"node": id})
		Kind.STATEMENT:
			n["exec_outs"] = ["\u25b6"]
			# A spawned statement with an initial body becomes structured
			# (assignment/declaration pins), exactly like parsed statements.
			var body: String = str(fields.get("body", "")).strip_edges()
			if body != "" and _try_call_statement(id, body):
				return id   # converted in place into a registry-backed call
			if body != "":
				n["body"] = body
				var stmt: Dictionary = _parse_stmt(body)
				if not stmt.is_empty():
					n["stmt"] = stmt
					var vt: int = stmt.get("type", Types.VARIANT)
					n["title"] = ("var %s" % stmt["name"]) if bool(stmt["decl"]) else ("set %s" % stmt["name"])
					if bool(stmt["has_value"]):
						n["data_ins"] = [{"name": "value", "type": vt, "value": stmt.get("rhs", "")}]
						_maybe_wire_lambda(id, str(stmt.get("rhs", "")))
					n["data_outs"] = [{"name": stmt["name"], "type": vt}]
		Kind.IF:
			n["exec_outs"] = ["True", "False", "done"]
			n["data_ins"] = [{"name": "condition", "type": Types.BOOL, "value": "true"}]
			_add_scope_slot(id)
		Kind.ELIF:
			# Spawnable from the menu: an Else If starts as a standalone
			# if-chain head (emitted as `if`); wiring it into an If/Else If
			# False pin makes it emit as a real `elif` branch.
			n["exec_outs"] = ["True", "False", "done"]
			n["data_ins"] = [{"name": "condition", "type": Types.BOOL, "value": "true"}]
			_add_scope_slot(id)
		Kind.MATCH:
			# Two default branches + the "after" fall-through pin, mirroring
			# the structure parsed from source (labels + after). The value
			# placeholder compiles so a freshly spawned node never blocks
			# saving; wiring a real value replaces it.
			n["exec_outs"] = ["0", "_", "after"]
			n["data_ins"] = [{"name": "value", "type": Types.VARIANT, "value": "0"}]
			n["title"] = "Match"
			_add_scope_slot(id)
		Kind.WHILE:
			n["exec_outs"] = ["loop body", "done"]
			n["data_ins"] = [{"name": "condition", "type": Types.BOOL, "value": "true"}]
			_add_scope_slot(id)
		Kind.FOR:
			n["exec_outs"] = ["loop body", "done"]
			n["data_ins"] = [{"name": "sequence", "type": Types.VARIANT, "value": "range(3)"}]
			n["data_outs"] = [{"name": "i", "type": Types.VARIANT}]
			_add_scope_slot(id)
		Kind.RETURN:
			n["data_ins"] = [{"name": "value", "type": Types.VARIANT, "value": ""}]
		Kind.BREAK, Kind.CONTINUE, Kind.PASS:
			if kind == Kind.PASS:
				n["exec_outs"] = ["\u25b6"]
		Kind.COMMENT:
			n["fields"]["text"] = str(fields.get("text", "# comment"))
		Kind.LITERAL:
			var t: int = int(fields.get("type", Types.VARIANT))
			n["fields"]["value"] = str(fields.get("value", Types.default_value(t)))
			n["data_outs"] = [{"name": "value", "type": t}]
			n["title"] = "Literal %s" % Types.type_name(t)
		Kind.VARIABLE_GET:
			n["fields"]["name"] = str(fields.get("name", "my_var"))
			n["data_outs"] = [{"name": str(fields.get("name", "my_var")), "type": int(fields.get("type", Types.VARIANT))}]
		Kind.VARIABLE_SET:
			n["exec_outs"] = ["\u25b6"]
			n["fields"]["name"] = str(fields.get("name", "my_var"))
			n["data_ins"] = [{"name": "value", "type": int(fields.get("type", Types.VARIANT)), "value": Types.default_value(int(fields.get("type", Types.VARIANT)))}]
			n["data_outs"] = [{"name": str(fields.get("name", "my_var")), "type": int(fields.get("type", Types.VARIANT))}]
		Kind.OPERATOR:
			n["fields"]["op"] = str(fields.get("op", "+"))
			n["title"] = "Operator %s" % str(fields.get("op", "+"))
			n["data_ins"] = [
				{"name": "a", "type": Types.VARIANT, "value": "0"},
				{"name": "b", "type": Types.VARIANT, "value": "0"},
			]
			# a comparison (==, !=, <, >, <=, >=) always yields a bool
			n["data_outs"] = [{"name": "result",
				"type": Types.BOOL if _op_is_comparison(str(n["fields"]["op"])) else Types.VARIANT}]
			# only chainable operators get a trailing grow slot; comparisons
			# stay at exactly two operands
			if not _op_is_comparison(str(n["fields"].get("op", "+"))):
				_ensure_one_empty(id)
		Kind.CALL:
			# Two shapes:
			#  - registry-backed (fields carry cat/owner/args/ret): pins mirror
			#    the real function signature (target, typed args, defaults,
			#    return) and generation emits the correct call syntax.
			#  - free-form (legacy "call" name only): grow-slot argument pins,
			#    no invented metadata (see sync_call_signature).
			n["fields"]["call"] = str(fields.get("call", "my_func"))
			n["fields"]["mode"] = str(fields.get("mode", "pure"))
			var fcat: String = str(fields.get("cat", ""))
			if fcat != "":
				n["fields"]["cat"] = fcat
				n["fields"]["owner"] = str(fields.get("owner", ""))
				n["fields"]["ret"] = str(fields.get("ret", "void"))
				n["fields"]["static"] = bool(fields.get("static", false))
				n["fields"]["needs_target"] = bool(fields.get("needs_target", false))
				n["fields"]["target_type"] = str(fields.get("target_type", ""))
				n["fields"]["vararg"] = bool(fields.get("vararg", false))
				n["fields"]["args"] = (fields.get("args", []) as Array).duplicate(true)
				n["fields"]["member"] = str(fields.get("member", ""))
				n["fields"]["declared"] = true
				n["fields"]["stale"] = false
				n["fields"]["sig_changed"] = false
				_apply_call_meta(id)
			else:
				n["fields"]["declared"] = false
				n["data_outs"] = [{"name": "return", "type": int(fields.get("type", Types.VARIANT))}]
				# Free-form call starts with a single argument grow slot; when the
				# call target matches a declared function the signature is synced
				# (see sync_call_signature).
				n["data_ins"] = [{"name": "arg1", "type": Types.VARIANT, "value": ""}]
				sync_call_signature(id)
		Kind.PRINT:
			n["exec_outs"] = ["\u25b6"]
			n["data_ins"] = [{"name": "value", "type": Types.VARIANT, "value": ""}]
		Kind.ENTRY:
			# A brand-new function: structured fields, no arguments yet. The
			# name/return type may be supplied by the caller (dock panel, tests).
			var no_args: Array[int] = []
			var fname: String = str(fields.get("name", "new_function"))
			var is_static: bool = bool(fields.get("static", false))
			n["fields"] = {"name": fname, "ret_type": str(fields.get("ret_type", "")),
				"static": is_static, "args": no_args}
			n["exec_outs"] = ["\u25b6"]
			n["sig"] = _sig_text(id)
			n["body"] = n["sig"]
			n["title"] = _entry_title(is_static, fname)
			_entry_sync_pins(id)
			roots.append({"entry": id, "tight": false})
		Kind.VAR_DECL:
			# A fresh top-level variable (dock panel / tests): structured fields
			# plus the statement form so generation and pin rows work like
			# parsed variables.
			var vname: String = str(fields.get("name", "my_var")).strip_edges()
			if vname == "":
				vname = "my_var"
			var raw: String = str(fields.get("raw_type", "")).strip_edges()
			var vdef: String = str(fields.get("default", "")).strip_edges()
			var vt: int = Types.type_from_name(raw) if raw != "" else Types.VARIANT
			nodes[id].fields = {"name": vname, "raw_type": raw, "default": vdef,
				"prefix": "", "annotations": "", "is_static": false,
				"scope": "public", "owner": -1}
			nodes[id].stmt = {"name": vname, "type": vt, "has_value": vdef != "",
				"rhs": vdef, "op": "=", "decl": true}
			var vline: String = "var " + vname
			if raw != "":
				vline += ": " + raw
			if vdef != "":
				vline += " = " + vdef
			nodes[id].body = vline
			nodes[id].title = "var " + vname
			nodes[id].data_ins = [{"name": "value", "type": vt, "value": vdef},
				{"name": "add annotation", "type": Types.PinType.ANNOTATION, "value": ""}]
			nodes[id].data_outs = [{"name": vname, "type": vt}]
			roots.append({"node": id, "tight": false})
		Kind.CONST_DECL:
			# A fresh top-level constant (e.g. a FileSystem file dropped on
			# the canvas): `const NAME = value`, regenerated verbatim in place
			# like a parsed constant, with its name on the data output pin.
			var cname: String = str(fields.get("name", "MY_CONST")).strip_edges()
			if cname == "":
				cname = "MY_CONST"
			var cval: String = str(fields.get("value", "")).strip_edges()
			nodes[id].body = "const %s = %s" % [cname, cval] if cval != "" else "const %s = 0" % cname
			nodes[id].title = "const " + cname
			nodes[id].data_outs = [{"name": cname, "type": Types.VARIANT}]
			roots.append({"node": id, "tight": false})
		Kind.SIGNAL_DECL:
			# Authorable from the menu ("Signal"): name + argument list fields;
			# generation rebuilds the `signal` line from the fields.
			var signame: String = str(fields.get("name", "my_sig")).strip_edges()
			var sigargs: String = str(fields.get("args", "")).strip_edges()
			nodes[id].fields = {"name": signame, "args": sigargs}
			nodes[id].body = "signal " + signame + "(" + sigargs + ")"
			nodes[id].title = "Signal"
			roots.append({"node": id, "tight": false})
		Kind.DECLARATION:
			# Verbatim top-level declaration (e.g. a signal added from the dock
			# panel): body text is regenerated in place.
			nodes[id].body = str(fields.get("body", "# ...")).strip_edges()
			nodes[id].title = str(fields.get("title", "Declaration"))
			roots.append({"node": id, "tight": false})
		Kind.ARGUMENT:
			# Standalone Argument node (spawned from the node menu): unowned
			# until its output is wired into a Function's "add argument"
			# slot, which registers it (see register_argument).
			var aname: String = str(fields.get("name", "arg1"))
			var atype: String = str(fields.get("type", ""))
			var at: int = Types.type_from_name(atype) if atype != "" else Types.VARIANT
			var adef: String = str(fields.get("default", ""))
			nodes[id].fields = {
				"name": aname, "type": atype,
				"parent": int(fields.get("parent", -1)), "default": adef,
			}
			nodes[id].data_ins = [
				{"name": aname, "type": at, "value": ""},
			]
			# Value output + Function connection output (no Default input
			# pin: the default lives in fields["default"]).
			nodes[id].data_outs = [
				{"name": aname, "type": at},
				{"name": "Function", "type": Types.VARIANT},
			]
			nodes[id].title = "arg: %s" % aname
		Kind.CLASS_NAME:
			# Script Class Name node: configures the script's global class
			# name; wired into the Script Header's "class name" input. The
			# header body stores the generated `class_name X` line.
			nodes[id].fields = {"name": str(fields.get("name", ""))}
			nodes[id].data_outs = [{"name": "class name",
				"type": Types.PinType.ANNOTATION}]
		Kind.EXTENDS_DECL:
			# Script Extension node: configures the script's inheritance
			# (base class identifier or quoted script path); wired into the
			# Script Header's "extends" input.
			nodes[id].fields = {"base": str(fields.get("base", ""))}
			nodes[id].data_outs = [{"name": "extends",
				"type": Types.PinType.ANNOTATION}]
		Kind.CLASS_REF:
			# A Class Reference node: one class/type/instance reference with a
			# typed output pin (an Object pin carrying the class identity) and
			# an "add member" slot Member nodes register through. `ref` selects
			# what the output names: "class" (the type itself: statics,
			# constants, constructors), "instance" (a concrete instance source,
			# default `self`, with an optional wired instance input) or
			# "singleton" (an Autoload singleton, callable both ways).
			n["fields"] = {
				"target": str(fields.get("target", "Node")).strip_edges(),
				"ref": str(fields.get("ref", "class")),
				"source": str(fields.get("source", "")),
			}
			_apply_class_ref_meta(id)
		Kind.LAMBDA:
			# A Lambda node: an inline `func(...) -> T:` Callable literal with
			# typed parameter rows and an editable body. Its single output pin
			# is the Callable value itself, so it wires wherever a Callable
			# argument is taken (Array.append, callback parameters...).
			var prms: Array = (fields.get("params", []) as Array).duplicate(true)
			if prms.is_empty():
				prms = [{"name": "x", "type": "float", "default": ""}]
			nodes[id].fields = {
				"params": prms,
				"ret": str(fields.get("ret", "")),
				"body": str(fields.get("body", "pass")),
			}
			nodes[id].data_outs = [{"name": "Callable", "type": Types.PinType.CALLABLE}]
			_lambda_sync_title(id)
		Kind.ANNOTATION:
			# Standalone Annotation node (spawned from the node menu): unowned
			# until its output is wired into a declaration's
			# "add annotation" slot registers the annotation
			# (see register_annotation). fields come from the node menu and
			# mirror the annotation registry entry.
			var ann_name: String = str(fields.get("name", "export")).strip_edges()
			var prms: Array = (fields.get("args", []) as Array).duplicate(true)
			nodes[id].fields = {"name": ann_name, "args": prms}
			var pins: Array = []
			for prm: Dictionary in prms:
				var ptype: int = Types.type_from_name(str(prm["type"]))
				var pval: String = str(prm["default"]) if str(prm["default"]) != "" else str(prm["sample"])
				pins.append({"name": str(prm["name"]), "type": ptype, "value": pval,
					"ptype": str(prm["type"]), "variadic": bool(prm.get("variadic", false))})
			nodes[id].data_ins = pins
			nodes[id].data_outs = [{"name": "@" + ann_name, "type": Types.PinType.ANNOTATION}]
			nodes[id].title = "@" + ann_name
			var ae: Dictionary = AnnReg.get_registry().find(ann_name)
			if not ae.is_empty():
				nodes[id].fields["targets"] = (ae["targets"] as Array).duplicate()
				nodes[id].fields["brief"] = str(ae["brief"])
			# Export-family annotations take an Export Group input: wiring an
			# @export_group node's "group" output here assigns the export to
			# that Inspector group (visible wire, registration not data flow).
			if _is_export_family(ann_name):
				nodes[id].data_ins.append({"name": "add group",
					"type": Types.PinType.ANNOTATION, "value": ""})
			elif ann_name == "export_group":
				# The group marker has exactly ONE output: "group". It is a
				# wiring marker, not a declarable annotation, so it carries no
				# "@" annotation output.
				nodes[id].data_outs = [{"name": "group",
					"type": Types.PinType.ANNOTATION}]
	return id


# ---- Class Reference & Member nodes --------------------------------------------
## A Class Reference node names one class (engine class, `class_name` script,
## Autoload singleton or res:// script path). Member nodes are Function Call
## nodes bound to one member of that class through the "add member"
## registration slot (member_links); generation resolves their target from
## the registered reference when the target pin itself is left empty.

## The resolved class record behind a Class Reference node ({} when the
## target text is not a known class — the node still works, and the
## generated script's compile check reports unknown classes; nothing is
## invented).
func _class_ref_record(rid: int) -> Dictionary:
	if not nodes.has(rid) or int(nodes[rid]["kind"]) != Kind.CLASS_REF:
		return {}
	return ClassReg.get_registry().find_class(String(nodes[rid]["fields"].get("target", "")))


## The class identity a Class Reference's pins carry (the target text when
## the class is unknown — pins still type against it verbatim).
func _class_ref_identity(rid: int) -> String:
	var rec: Dictionary = _class_ref_record(rid)
	if not rec.is_empty():
		return ClassReg.get_registry().class_identity(rec)
	return String(nodes[rid]["fields"].get("target", "")).strip_edges()


## Rebuilds a Class Reference node's pins from its fields (target, reference
## mode, registered members). Surviving links keep their meaning: the
## instance input keeps its wired source while the mode keeps it, member
## registration wires re-map onto their member's slot row.
func _apply_class_ref_meta(rid: int) -> void:
	var n: Dictionary = nodes[rid]
	var f: Dictionary = n["fields"]
	var target: String = String(f.get("target", "")).strip_edges()
	var mode: String = String(f.get("ref", "class"))
	if mode != "class" and mode != "instance" and mode != "singleton":
		mode = "class"
		f["ref"] = mode
	var identity: String = _class_ref_identity(rid)
	var rec: Dictionary = _class_ref_record(rid)
	var display: String = target
	if not rec.is_empty() and str(rec["kind"]) == ClassReg.KIND_AUTOLOAD:
		display = String(rec["name"])
	# remember what was wired before the rebuild
	var old_ins: Array = n["data_ins"]
	var old_has_instance: bool = old_ins.size() > 0 \
		and String(old_ins[0].get("name", "")) == "instance"
	var old_instance_value: String = String(old_ins[0].get("value", "")) if old_has_instance else ""
	var member_ids: Array[int] = []
	for l: Dictionary in member_links:
		if int(l["rid"]) == rid and nodes.has(int(l["cid"])):
			member_ids.append(int(l["cid"]))
	# rebuild the pins: instance input, one row per registered member,
	# always exactly one trailing "add member" slot
	var pins: Array = []
	var has_instance: bool = mode == "instance"
	if has_instance:
		var src: String = String(f.get("source", "")).strip_edges()
		if src == "" and old_has_instance and old_instance_value.strip_edges() != "":
			src = old_instance_value
		if src == "":
			src = "self"
		f["source"] = src
		pins.append({"name": "instance", "type": Types.PinType.OBJECT,
			"type_text": identity, "value": src})
	for cid: int in member_ids:
		pins.append({"name": String(nodes[cid]["fields"].get("call", "member")),
			"type": Types.PinType.MEMBER, "value": ""})
	pins.append({"name": "add member", "type": Types.PinType.MEMBER, "value": ""})
	n["data_ins"] = pins
	n["data_outs"] = [{"name": display, "type": Types.PinType.OBJECT,
		"type_text": identity}]
	n["title"] = ("Instance %s" if mode == "instance"
		else ("Singleton %s" if mode == "singleton" else "Class %s")) % display
	# remap surviving data wires: an instance-value wire keeps the instance
	# input while the mode keeps it; everything else into this node is
	# dropped (member registration wires are not data_links — they live in
	# member_links, like annotations in ann_links)
	for i: int in range(data_links.size() - 1, -1, -1):
		var l: Dictionary = data_links[i]
		if int(l["to_id"]) != rid:
			continue
		if has_instance and not _out_pin_is_member(int(l["from_id"]), int(l["from_out"])):
			l["to_in"] = 0
		else:
			data_links.remove_at(i)


func _out_pin_is_member(fid: int, out_index: int) -> bool:
	if not nodes.has(fid):
		return false
	var outs: Array = nodes[fid]["data_outs"]
	return out_index < outs.size() and int(outs[out_index]["type"]) == Types.PinType.MEMBER


## A class reference target is a class name (optionally dotted for inner
## classes) or a res:// script path. Anything else (spaces, line breaks, `;`,
## calls) would corrupt the generated script, so it is refused.
func _check_class_target(t: String) -> bool:
	var raw: String = t
	if raw.begins_with("\"") and raw.ends_with("\"") and raw.length() >= 2:
		raw = raw.substr(1, raw.length() - 2)
	if raw.begins_with("res://"):
		if raw.ends_with(".gd") and not raw.contains("\n") and not raw.contains("\"") and not raw.contains("'"):
			return true
		last_reject_reason = "A script path must end with .gd (for example res://player.gd)."
		return false
	for seg: String in raw.split("."):
		if not _valid_ident(seg):
			last_reject_reason = "'%s' is not a valid class name. Use letters, numbers and _ only (no spaces)." % t.replace("\n", " ")
			return false
	return true


## Structured Class Reference property edit ("target" / "ref" / "source").
## Rebuilds the pins and revalidates the outgoing reference wire.
func set_class_ref_prop(rid: int, key: String, value: String) -> bool:
	if not nodes.has(rid) or int(nodes[rid]["kind"]) != Kind.CLASS_REF:
		return false
	last_reject_reason = ""
	var f: Dictionary = nodes[rid]["fields"]
	match key:
		"target":
			var t: String = value.strip_edges()
			if t == "":
				last_reject_reason = "Choose a class name (for example Node2D or Player)."
				return false
			if not _check_class_target(t):
				return false
			f["target"] = t
			if not ClassReg.get_registry().is_known_class(t):
				# still applied (it may be a class the scan has not seen yet),
				# but the person is told in plain words
				last_reject_reason = "'%s' is not a class this project knows - check the spelling." % t
		"ref":
			var m: String = value.strip_edges()
			if not m in ["class", "instance", "singleton"]:
				last_reject_reason = "Reference must be Class, Instance or Singleton."
				return false
			f["ref"] = m
		"source":
			var src0: String = value.strip_edges()
			if src0 != "" and not _check_single_expr(src0, false):
				return false
			f["source"] = src0
		_:
			return false
	_apply_class_ref_meta(rid)
	_validate_out_links(rid, 0)
	return true


## Empty when `cid` (a member node) can be attached to Class Reference `rid`;
## otherwise a plain-language reason. A member needs an object of the class it
## belongs to (or a subclass); an unknown reference class is never blocked.
func _member_fit_problem(rid: int, cid: int) -> String:
	var f: Dictionary = nodes[cid]["fields"]
	var expected: String = str(f.get("target_type", "")).strip_edges()
	if expected == "":
		expected = str(f.get("owner", "")).strip_edges()
	if expected == "" or str(f.get("member", "")) == "":
		return ""
	var reg: RefCounted = ClassReg.get_registry()
	var rec: Dictionary = _class_ref_record(rid)
	if rec.is_empty():
		return ""
	var ident: String = _class_ref_identity(rid)
	var tname: String = String(nodes[rid]["fields"].get("target", "")).strip_edges()
	if expected == tname or expected == ident or reg.reference_fits(ident, expected) \
			or reg.reference_fits(tname, expected):
		return ""
	var erec: Dictionary = reg.find_class(expected)
	if not erec.is_empty() and str(erec.get("name", "")) == str(rec.get("name", "")):
		return ""
	return "'%s' belongs to %s, so it does not fit a %s reference. Use a Class Reference for %s (or a class that extends it)." \
		% [str(f.get("call", "member")), expected, ident, expected]


## True when node `start` needs the value of node `target` (through data
## wires, or - for a member - through the Class Reference it is registered on).
## Used to refuse wires and registrations that would loop.
func _depends_on(start: int, target: int) -> bool:
	var seen: Dictionary = {}
	var stack: Array = [start]
	while not stack.is_empty():
		var cur: int = stack.pop_back()
		if cur == target:
			return true
		if seen.has(cur) or not nodes.has(cur):
			continue
		seen[cur] = true
		for l: Dictionary in data_links:
			if int(l["to_id"]) == cur:
				stack.append(int(l["from_id"]))
		var owner: int = member_owner(cur)
		if owner >= 0:
			stack.append(owner)
	return false


## Registers a member node on a Class Reference (returns the pin slot index
## the registration wire connects to, -1 when rejected). A member already
## registered on another reference moves instead of duplicating. `slot`
## targets one of the reference's member slot rows (replace semantics, like
## per-annotation pins); -1 appends at the end.
func register_member(rid: int, cid: int, slot: int = -1) -> int:
	if not nodes.has(rid) or not nodes.has(cid):
		return -1
	if int(nodes[rid]["kind"]) != Kind.CLASS_REF or int(nodes[cid]["kind"]) != Kind.CALL:
		return -1
	if str(nodes[cid]["fields"].get("member", "")) == "":
		last_reject_reason = "Only class members (methods, properties, signals, constants) attach to a Class Reference."
		return -1
	var fit: String = _member_fit_problem(rid, cid)
	if fit != "":
		last_reject_reason = fit
		return -1
	if _depends_on(rid, cid):
		last_reject_reason = "That would make the Class Reference depend on its own member (a loop)."
		return -1
	last_reject_reason = ""
	var old_rid: int = member_owner(cid)
	for i: int in range(member_links.size() - 1, -1, -1):
		if int(member_links[i]["cid"]) == cid:
			member_links.remove_at(i)
	if slot >= 0:
		var at: int = member_links.size()
		var seen: int = 0
		for j: int in member_links.size():
			if int(member_links[j]["rid"]) == rid:
				if seen == slot:
					at = j
					break
				seen += 1
		member_links.insert(at, {"rid": rid, "cid": cid})
	else:
		member_links.append({"rid": rid, "cid": cid})
	_apply_class_ref_meta(rid)
	# the reference that lost the member re-syncs its slot rows too
	if old_rid >= 0 and old_rid != rid and nodes.has(old_rid):
		_apply_class_ref_meta(old_rid)
	return _member_pin_slot(rid, cid)


## Drops one registration. The member node itself stays in the graph (its
## target pin keeps whatever it held — like annotations, only the
## association is removed, never the configuration).
func unregister_member(rid: int, cid: int) -> bool:
	var found: bool = false
	for i: int in range(member_links.size() - 1, -1, -1):
		if int(member_links[i]["rid"]) == rid and int(member_links[i]["cid"]) == cid:
			member_links.remove_at(i)
			found = true
	if found and nodes.has(rid):
		_apply_class_ref_meta(rid)
	return found


## The Class Reference a member node is registered on, -1 when unregistered.
func member_owner(cid: int) -> int:
	for l: Dictionary in member_links:
		if int(l["cid"]) == cid and nodes.has(int(l["rid"])):
			return int(l["rid"])
	return -1


func is_member_registered(cid: int, rid: int) -> bool:
	for l: Dictionary in member_links:
		if int(l["cid"]) == cid and int(l["rid"]) == rid:
			return true
	return false


## The pin slot index of one member's registration wire on its reference.
func _member_pin_slot(rid: int, cid: int) -> int:
	if not nodes.has(rid):
		return -1
	var has_instance: bool = int(nodes[rid]["kind"]) == Kind.CLASS_REF \
		and nodes[rid]["data_ins"].size() > 0 \
		and String(nodes[rid]["data_ins"][0].get("name", "")) == "instance"
	var base: int = 1 if has_instance else 0
	var idx: int = 0
	for l: Dictionary in member_links:
		if int(l["rid"]) != rid:
			continue
		if int(l["cid"]) == cid:
			return base + idx
		idx += 1
	return -1


## The GDScript expression a Class Reference's output resolves to: the class
## or singleton name (class / singleton mode), the wired instance input or
## the typed source expression (instance mode), or preload("path") for
## script-path references.
func _class_ref_expr(rid: int, depth: int) -> String:
	if depth > 32 or not nodes.has(rid):
		return "null"
	var f: Dictionary = nodes[rid]["fields"]
	if String(f.get("ref", "class")) == "instance":
		if nodes[rid]["data_ins"].size() > 0 \
				and String(nodes[rid]["data_ins"][0].get("name", "")) == "instance":
			if not _connected_data_source(rid, 0).is_empty():
				return _resolve_pin(rid, 0, depth + 1)
			var s: String = String(nodes[rid]["data_ins"][0].get("value", "")).strip_edges()
			if s != "":
				return s
		return String(f.get("source", "self")).strip_edges()
	var rec: Dictionary = _class_ref_record(rid)
	if not rec.is_empty():
		return ClassReg.get_registry().class_expr(rec)
	var target: String = String(f.get("target", "")).strip_edges()
	if target.begins_with("res://") and target.ends_with(".gd"):
		return "preload(\"%s\")" % target
	return target


## The class owner expression of a class-level member (no target pin):
## the singleton name, the class name, or preload("path") for script paths.
func _call_owner_expr(cid: int) -> String:
	var f: Dictionary = nodes[cid]["fields"]
	var owner: String = str(f.get("owner", ""))
	match str(f.get("cat", "")):
		FuncReg.CAT_PROJECT, FuncReg.CAT_ADDON:
			return "preload(\"%s\")" % owner
		_:
			return owner


## True when a member node is callable through the class name itself
## (static method, class constant, static var). Signals and instance
## members always need an instance target.
func _member_class_level(cid: int) -> bool:
	var f: Dictionary = nodes[cid]["fields"]
	var mkind: String = str(f.get("member", ""))
	if mkind == "":
		return true   # plain function calls have no class target
	if mkind == "signal":
		return false
	return bool(f.get("static", false))


## Resolves a call's target expression: the wired target pin wins, then the
## typed text, then the target of the registered Class Reference (member
## nodes only). Returns {expr, rid} — rid >= 0 when the target came from a
## registered Class Reference, so generation can tell a bare class name
## from a real instance.
func _call_target_source(cid: int, depth: int) -> Dictionary:
	var n: Dictionary = nodes[cid]
	var f: Dictionary = n["fields"]
	if bool(f.get("needs_target", false)) and n["data_ins"].size() > 0:
		if not _connected_data_source(cid, 0).is_empty():
			return {"expr": _resolve_pin(cid, 0, depth), "rid": -1}
		var typed: String = String(n["data_ins"][0]["value"]).strip_edges()
		if typed != "":
			return {"expr": typed, "rid": -1}
	if str(f.get("member", "")) != "":
		var rid: int = member_owner(cid)
		if rid >= 0:
			return {"expr": _class_ref_expr(rid, depth + 1), "rid": rid}
	return {"expr": "", "rid": -1}


## Ensures the Class Reference + member grouping behind a parsed dotted call
## (`Test_class.get_health()`): when the owner resolves to exactly one known
## class, a Class Reference node is created (or reused for the same target
## and mode) and the call registers as its member. The generated text is
## unchanged — the registration only affects the target fallback and the
## visual grouping.
func _link_parsed_class_member(cid: int, owner_text: String, e: Dictionary) -> void:
	var rec: Dictionary = ClassReg.get_registry().find_class(owner_text)
	if rec.is_empty():
		return
	# Autoloads are instances: their members generate against the singleton.
	var mode: String = "singleton" if str(rec["kind"]) == ClassReg.KIND_AUTOLOAD \
		else "class"
	var target: String = String(rec["name"])
	var rid: int = -1
	for id0: int in nodes:
		if int(nodes[id0]["kind"]) == Kind.CLASS_REF \
				and String(nodes[id0]["fields"].get("target", "")) == target \
				and String(nodes[id0]["fields"].get("ref", "")) == mode:
			rid = id0
			break
	if rid < 0:
		rid = _make_node(Kind.CLASS_REF)
		nodes[rid]["fields"] = {"target": target, "ref": mode, "source": ""}
		_apply_class_ref_meta(rid)
	if member_owner(cid) < 0:
		register_member(rid, cid)


# ---- Code generation -----------------------------------------------------------
## Text generated for a verbatim/declaration root node. Structured var
## declarations regenerate from their pins (wired values win), everything else
## emits the node body verbatim.
func _emit_root_text(nid: int) -> String:
	var n: Dictionary = nodes[nid]
	if int(n["kind"]) == Kind.SIGNAL_DECL and n["fields"].has("name"):
		# Structured signal: regenerated from the (editable) fields.
		var sargs: String = str(n["fields"].get("args", "")).strip_edges()
		return "signal " + str(n["fields"].get("name", "my_sig")) + "(" + sargs + ")"
	if int(n["kind"]) == Kind.VAR_DECL and not n["stmt"].is_empty():
		if str(n["fields"].get("scope", "public")) == "private":
			return ""   # private variables are emitted inside their owner function
		var st: Dictionary = n["stmt"]
		var vname: String = String(n["fields"].get("name", st["name"]))
		var raw: String = String(n["fields"].get("raw_type", "")).strip_edges()
		# `static` must stay on the declaration line; a bare `static` line is a
		# parse error. Annotations keep their own lines above it.
		var spfx: Dictionary = _static_prefix_lines(String(n["fields"].get("prefix", "")))
		var is_static: bool = bool(spfx["static"]) or bool(n["fields"].get("is_static", false))
		var text: String = _var_ann_prefix(nid, spfx)
		var line: String = ("static " if is_static else "") + "var " + vname
		if raw != "":
			line += ": " + raw
		if bool(st["has_value"]) or not connected_data_input(nid, 0).is_empty():
			var op: String = str(st.get("op", "="))
			var val: String = _resolve_pin(nid, 0, 0)
			var lsrc: Dictionary = connected_data_input(nid, 0)
			var is_lam: bool = not lsrc.is_empty() and int(nodes.get(int(lsrc["from_id"]), {}).get("kind", -1)) == Kind.LAMBDA
			if not is_lam:
				val = _dedent_block_value(val)
			line += " " + (op if op != "" else "=") + " " + val
		# A declaration that opened a block in the source (lambda body,
		# property accessors) keeps that block verbatim below the line.
		var tail: String = _var_decl_tail(nid)
		if tail != "":
			text += line + ":\n" + _reindent_tail(tail, "")
		elif not accessor_entries_of(nid).is_empty():
			# Setter / Getter nodes: generate() writes their blocks below
			text += line + ":"
		else:
			text += line
		return text
	return String(n["body"])


## Re-indents a dedented tail block at `base_ind` (a tab prefix) plus one
## level: the tail block sat one level below its declaration line in the
## source, and the dedent removed that level.
func _reindent_tail(tail: String, base_ind: String) -> String:
	var outl: PackedStringArray = PackedStringArray()
	for ln: String in tail.split("\n"):
		outl.append(base_ind + "\t" + ln if ln != "" else "")
	return "\n".join(outl)


## The Annotation node (wired into declaration `tid`) whose generated text is
## `text`; -1 when the annotation is not backed by a node (inline text).
func _annotation_node_for_text(tid: int, text: String) -> int:
	var want: String = text.strip_edges()
	if want == "":
		return -1
	for l: Dictionary in ann_links:
		if int(l["tid"]) != tid:
			continue
		var aid: int = int(l["aid"])
		if nodes.has(aid) and int(nodes[aid]["kind"]) == Kind.ANNOTATION \
				and annotation_node_text(aid).strip_edges() == want:
			return aid
	return -1


## Records a node-bound problem for the visual error display (deduplicated).
## severity is "error" or "warning"; `line` is a generated line number or -1.
func _diag_add(node_id: int, severity: String, message: String, line: int = -1) -> void:
	for d: Dictionary in _diag_items:
		if int(d["node"]) == node_id and str(d["message"]) == message and int(d["line"]) == line:
			return
	_diag_items.append({"node": node_id, "severity": severity, "message": message, "line": line})


## A problem found while emitting: reported in the problem list exactly as
## before and additionally bound to the node that caused it.
func _note_problem(node_id: int, message: String) -> void:
	_emit_problems.append(message)
	_diag_add(node_id, "error", message)


## Maps every line of the generated `text` to the node that emitted it
## (index 0 = line 1, -1 = unknown). Returns an empty array when the mapping
## cannot be proven to line up with the text, so a wrong attribution is never
## reported.
func _compute_line_nodes(out: PackedStringArray, text: String) -> PackedInt32Array:
	var none: PackedInt32Array = PackedInt32Array()
	var tags: PackedInt32Array = PackedInt32Array()
	tags.resize(out.size())
	tags.fill(-1)
	var spans: Array = []
	for m: Array in _line_marks:
		var seg: int = int(m[0])
		var base: int = 0
		if seg != 0:
			if not _seg_base.has(seg):
				continue
			base = int(_seg_base[seg])
		spans.append([base + int(m[1]), base + int(m[2]), int(m[3])])
	# outer ranges first, so inner (more specific) nodes overwrite them
	spans.sort_custom(func(a: Array, b: Array) -> bool:
		return (int(a[1]) - int(a[0])) > (int(b[1]) - int(b[0])))
	for sp: Array in spans:
		for i: int in range(maxi(0, int(sp[0])), mini(int(sp[1]), tags.size())):
			tags[i] = int(sp[2])
	# expand buffer elements to physical lines
	var raw: PackedStringArray = PackedStringArray()
	var raw_tags: PackedInt32Array = PackedInt32Array()
	for i: int in out.size():
		for ln: String in out[i].split("\n"):
			raw.append(ln)
			raw_tags.append(tags[i])
	# replay generate()'s final clean-up: strip_edges() and blank-run collapse
	var lo: int = 0
	var hi: int = raw.size()
	while lo < hi and raw[lo].strip_edges() == "":
		lo += 1
	while hi > lo and raw[hi - 1].strip_edges() == "":
		hi -= 1
	var kept: PackedInt32Array = PackedInt32Array()
	var kept_lines: PackedStringArray = PackedStringArray()
	var prev_blank: bool = false
	for i: int in range(lo, hi):
		var is_blank: bool = raw[i] == ""
		if is_blank and prev_blank:
			continue
		prev_blank = is_blank
		kept.append(raw_tags[i])
		kept_lines.append(raw[i])
	var tl: PackedStringArray = text.split("\n")
	if tl.size() != kept_lines.size() + 1:
		return none
	for i: int in kept_lines.size():
		if kept_lines[i].strip_edges() != tl[i].strip_edges():
			return none
	# an annotation line emitted by a declaration belongs to the Annotation
	# node that carries it (so compiler errors land on that node)
	for i: int in kept.size():
		var owner: int = kept[i]
		if owner < 0 or not nodes.has(owner):
			continue
		var ok: int = int(nodes[owner]["kind"])
		if ok != Kind.VAR_DECL and ok != Kind.ENTRY:
			continue
		var line_text: String = kept_lines[i].strip_edges()
		if line_text.begins_with("@"):
			var an: int = _annotation_node_for_text(owner, line_text)
			if an >= 0:
				kept[i] = an
	return kept


## Converts the graph back into valid native GDScript.
## Returns {text:String, problems:PackedStringArray, unreachable:int,
## diagnostics:Array[Dictionary], line_nodes:PackedInt32Array}.
func generate() -> Dictionary:
	_emit_problems = PackedStringArray()
	_diag_items.clear()
	_line_marks.clear()
	_seg_base.clear()
	_cur_seg = 0
	var seg_count: int = 0
	var out: PackedStringArray = PackedStringArray()
	var problems: PackedStringArray = PackedStringArray()
	var emitted: Dictionary = {}
	var last_gid: int = -1   # export group currently active in the output
	for r: Dictionary in roots:
		if r.has("node") and nodes.has(int(r["node"])):
			var rn: Dictionary = nodes[int(r["node"])]
			var rtext: String = _emit_root_text(int(r["node"]))
			# Export groups: when a public variable's export annotation is
			# wired to an @export_group node, that group's line is emitted
			# before the first variable of the group (Godot applies
			# @export_group to every subsequent export until the next
			# marker). A group node manually registered on a declaration
			# already emits there; automatic emission steps aside for it.
			if int(rn["kind"]) == Kind.VAR_DECL \
					and str(rn["fields"].get("scope", "public")) == "public":
				var gid: int = _export_group_of(int(r["node"]))
				var vid0: int = int(r["node"])
				if gid < 0 and _var_has_group_line(vid0):
					last_gid = -1   # a verbatim group line governs here
				elif gid < 0 and last_gid >= 0 and _var_has_export(vid0):
					# Godot keeps the active group for every later export,
					# so an ungrouped export closes it explicitly.
					out.append("@export_group(\"\")")
					last_gid = -1
				if gid >= 0:
					if gid != last_gid and not _annotation_registered_anywhere(gid):
						var gtext: String = annotation_node_text(gid)
						if gtext != "":
							out.append(gtext)
							_line_marks.append([0, out.size() - 1, out.size(), gid])
						last_gid = gid
					elif gid != last_gid:
						last_gid = gid
			if rtext != "":
				out.append(rtext)
				_line_marks.append([0, out.size() - 1, out.size(), int(r["node"])])
			if rtext != "" and int(rn["kind"]) == Kind.VAR_DECL:
				# Setter / Getter nodes: their blocks follow the declaration
				for acc_eid: int in _accessor_emit_order(int(r["node"])):
					seg_count += 1
					_emit_accessor_block(acc_eid, out, emitted, seg_count)
			if rtext != "" and not bool(r.get("tight", false)):
				out.append("")
		elif r.has("entry") and bool(r.get("accessor", false)):
			continue   # written inside its variable's declaration (see above)
		elif r.has("text") and nodes.has(int(r.get("node", -1))):
			out.append(_emit_root_text(int(r["node"])))
			_line_marks.append([0, out.size() - 1, out.size(), int(r["node"])])
			if not bool(r.get("tight", false)):
				out.append("")
		elif r.has("entry") and nodes.has(int(r["entry"])):
			var eid: int = int(r["entry"])
			var entry_first: int = out.size()
			var eanns: String = String(nodes[eid]["fields"].get("annotations", ""))
			if eanns.strip_edges() != "":
				for aln: String in eanns.split("\n"):
					if aln.strip_edges() != "":
						out.append(aln.strip_edges())
			out.append(nodes[eid]["sig"] + ":")
			# The flow walk emits private/local declarations that sit in the exec
			# chain at their source position; anything disconnected (references
			# sanitized away) is emitted at the function top first.
			var flowbuf: PackedStringArray = PackedStringArray()
			seg_count += 1
			_cur_seg = seg_count
			var t: int = _exec_target(eid, 0)
			if t >= 0:
				_emit_flow(t, 1, flowbuf, emitted)
			else:
				# The event's flow is disconnected (or its statements are
				# unreachable): an empty body would be invalid GDScript.
				flowbuf.append("\tpass")
			_cur_seg = 0
			for vid: int in func_privates.get(eid, []):
				if emitted.has(vid):
					continue
				var vfirst: int = out.size()
				# multi-line for annotations and a kept lambda body block
				for ln: String in _var_decl_text(vid).split("\n"):
					out.append("\t" + ln)
				var vtail: String = _var_decl_tail(vid)
				if vtail != "":
					for tln: String in _reindent_tail(vtail, "\t").split("\n"):
						out.append(tln)
				_line_marks.append([0, vfirst, out.size(), vid])
			_seg_base[seg_count] = out.size()
			out.append_array(flowbuf)
			_line_marks.append([0, entry_first, out.size(), eid])
			out.append("")
	# Unreachable flow nodes (not wired to any event). They are skipped by
	# generation; the titles are reported so the drop is never silent.
	var unreachable: int = 0
	var unreachable_titles: PackedStringArray = PackedStringArray()
	for id: int in nodes:
		var n: Dictionary = nodes[id]
		if emitted.has(id):
			continue
		match int(n["kind"]):
			Kind.ENTRY, Kind.PREAMBLE, Kind.LITERAL, Kind.VARIABLE_GET, Kind.OPERATOR, \
			Kind.VAR_DECL, Kind.CONST_DECL, Kind.SIGNAL_DECL, Kind.DECLARATION, \
			Kind.ARGUMENT, Kind.ANNOTATION, Kind.CLASS_NAME, \
			Kind.EXTENDS_DECL, Kind.CLASS_REF, Kind.LAMBDA:
				pass   # data sources / roots need no exec reachability
			Kind.CALL:
				# expression calls are data sources; statement calls are flow
				if str(n["fields"].get("mode", "pure")) != "exec":
					pass
				else:
					unreachable += 1
					unreachable_titles.append(_node_display_title(id))
					_diag_add(id, "warning", UNREACHABLE_MESSAGE)
			_:
				unreachable += 1
				unreachable_titles.append(_node_display_title(id))
				_diag_add(id, "warning", UNREACHABLE_MESSAGE)
	# Scope validation: every Get/Set reference must sit inside the scope of
	# the variable it names; a private variable's output pin may only feed
	# its owner function.
	for id: int in nodes:
		var nk: int = int(nodes[id]["kind"])
		if nk == Kind.VARIABLE_GET or nk == Kind.VARIABLE_SET:
			var rname: String = str(nodes[id]["fields"].get("name", "")).strip_edges()
			if rname == "":
				continue
			var info: Dictionary = _scope_of_name(rname)
			if str(info["kind"]) in ["private", "local"]:
				var pos: Dictionary = _ref_position(id)
				if int(pos["entry"]) != int(info["owner"]) \
						or (bool(info["block"]) and int(pos["node"]) != int(info["decl"]) \
							and not _flow_reaches(int(info["decl"]), int(pos["node"]))):
					problems.append("Variable '%s' is not accessible from this scope" % rname)
					_diag_add(id, "error", "Variable '%s' is not accessible from this scope" % rname)
		if nk == Kind.VAR_DECL and str(nodes[id]["fields"].get("scope", "public")) == "private":
			var owner: int = int(nodes[id]["fields"].get("owner", -1))
			for l: Dictionary in data_links:
				if int(l["from_id"]) != id:
					continue
				var pos2: Dictionary = _ref_position(int(l["to_id"]))
				if int(pos2["entry"]) != owner:
					problems.append("Variable '%s' is private to another function"
						% str(nodes[id]["fields"].get("name", "")))
					_diag_add(int(l["to_id"]), "error", "Variable '%s' is private to another function"
						% str(nodes[id]["fields"].get("name", "")))
	# Annotation validation: every annotation must be a real Godot 4.7.x
	# annotation in a valid placement with a plausible argument list.
	# Problems are reported; the annotation text itself is kept verbatim.
	var areg: RefCounted = AnnReg.get_registry()
	for id: int in nodes:
		var nk: int = int(nodes[id]["kind"])
		if nk == Kind.VAR_DECL or nk == Kind.ENTRY:
			for at: String in annotations_of(id):
				var msg: String = areg.validate(at, _annotation_target(nk))
				if msg != "":
					problems.append(msg)
					# show it on the Annotation node that carries the text
					var ann_owner: int = _annotation_node_for_text(id, at)
					_diag_add(ann_owner if ann_owner >= 0 else id, "error", msg)
		elif nk == Kind.PREAMBLE:
			for ln: String in String(nodes[id]["body"]).split("\n"):
				var t: String = ln.strip_edges()
				if t.begins_with("@"):
					var msg2: String = areg.validate(t, "class")
					if msg2 != "":
						problems.append(msg2)
						_diag_add(id, "error", msg2)
		elif nk == Kind.STATEMENT:
			var sb: String = str(nodes[id]["body"]).strip_edges()
			if sb.begins_with("@"):
				var msg3: String = areg.validate(sb.split("\n")[0], "statement")
				if msg3 != "":
					problems.append(msg3)
					_diag_add(id, "error", msg3)
	# Function Call integrity: stale/unresolved sources, signature drift and
	# missing targets are reported — never silently generated as broken code.
	for id: int in nodes:
		if int(nodes[id]["kind"]) != Kind.CALL:
			continue
		var cf: Dictionary = nodes[id]["fields"]
		var cname: String = str(cf.get("call", ""))
		if bool(cf.get("stale", false)):
			problems.append("Function '%s' could not be resolved; the call was kept as free-form" % cname)
			_diag_add(id, "warning", "Function '%s' could not be resolved; the call was kept as free-form" % cname)
		elif bool(cf.get("sig_changed", false)):
			problems.append("Function '%s' signature changed; the node's pins were updated" % cname)
			_diag_add(id, "warning", "Function '%s' signature changed; the node's pins were updated" % cname)
	var text: String = "\n".join(out).strip_edges() + "\n"
	while text.contains("\n\n\n"):
		text = text.replace("\n\n\n", "\n\n")
	# Structural sanity on the generated text itself: the generator must
	# detect its own invalid output instead of reporting "problems: []" for
	# code that cannot compile (bare `static` lines, block openers without
	# an indented block).
	var line_nodes: PackedInt32Array = _compute_line_nodes(out, text)
	for sp: String in _structural_problems(text):
		problems.append(sp)
		# "line N: message" -> bind to the node that emitted line N
		var sp_line: int = -1
		var sp_msg: String = sp
		if sp.begins_with("line "):
			var colon: int = sp.find(":")
			if colon > 5:
				sp_line = int(sp.substr(5, colon - 5))
				sp_msg = sp.substr(colon + 1).strip_edges()
		var sp_node: int = -1
		if sp_line > 0 and sp_line <= line_nodes.size():
			sp_node = line_nodes[sp_line - 1]
		_diag_add(sp_node, "error", sp_msg, sp_line)
	for p: String in _emit_problems:
		if not problems.has(p):
			problems.append(p)
	return {"text": text, "problems": problems, "unreachable": unreachable,
		"unreachable_titles": unreachable_titles,
		"diagnostics": _diag_items.duplicate(true), "line_nodes": line_nodes}


const UNREACHABLE_MESSAGE: String = "Not connected to any Event flow \u2013 skipped when generating GDScript"

## Detects obviously invalid GDScript in generated output:
##  * a line that is exactly `static` (nothing may follow it but `var`/`func`
##    on the same line)
##  * a line that opens an indented block (ends with ":") but is followed
##    only by lines at the same or shallower indentation (or EOF)
func _structural_problems(text: String) -> PackedStringArray:
	var problems: PackedStringArray = PackedStringArray()
	var lines: PackedStringArray = text.split("\n")
	for i: int in lines.size():
		var ln: String = lines[i]
		var lead: int = ln.length() - ln.lstrip(" \t").length()
		var body: String = ln.substr(lead).strip_edges()
		if body == "" or body.begins_with("#"):
			continue
		if body == "static":
			problems.append("line %d: bare `static` line (expected `static var`/`static func` on one line)" % [i + 1])
		if body.ends_with(":") and not body.begins_with("#"):
			# find the next non-blank, non-comment line
			var j: int = i + 1
			var next_lead: int = -1
			while j < lines.size():
				var nl: String = lines[j]
				var nl_lead: int = nl.length() - nl.lstrip(" \t").length()
				var nl_body: String = nl.substr(nl_lead).strip_edges()
				if nl_body == "" or nl_body.begins_with("#"):
					j += 1
					continue
				next_lead = nl_lead
				break
			if next_lead < 0 or next_lead <= lead:
				problems.append("line %d: block opener '%s' has no indented block" % [i + 1, body])
	return problems


const CONTROL_KINDS: Array[int] = [Kind.IF, Kind.ELIF, Kind.WHILE, Kind.FOR, Kind.MATCH]

## Dynamic-input policy (reusable system, not per-node hacks): which node kinds
## accept a variable number of data inputs, their required minimum pin count,
## and their maximum (-1 = unbounded). Kinds NOT listed here have a fixed input
## count and never grow. Only kinds whose GDScript semantics truly support
## multiple operands/arguments are listed:
##   - operators chain left-associatively (a + b + c, a and b and c, ...)
##   - calls take an argument list
##   - print takes a value list (print(a, b, c))
const DYNAMIC_INPUTS: Dictionary[int, Dictionary] = {
	Kind.OPERATOR: {"min": 2, "max": -1},
	Kind.CALL: {"min": 0, "max": -1},
	Kind.PRINT: {"min": 1, "max": -1},
}

## Operators whose result is a Boolean comparison: they take exactly two
## operands and cannot chain the way `a + b + c` can, so their operand pins
## must never grow.
const COMPARISON_OPS: PackedStringArray = ["==", "!=", "<", ">", "<=", ">="]


static func _op_is_comparison(op: String) -> bool:
	return COMPARISON_OPS.has(op)


## Drops every operand pin beyond the first two (and any wire feeding them)
## so a comparison operator node stays logically valid. Values on the two
## kept pins are preserved.
func _collapse_operator_operands(id: int) -> void:
	var n: Dictionary = nodes[id]
	var pins: Array = n["data_ins"]
	if pins.size() <= 2:
		return
	for i: int in range(data_links.size() - 1, -1, -1):
		var l: Dictionary = data_links[i]
		if int(l["to_id"]) == id and int(l["to_in"]) >= 2:
			data_links.remove_at(i)
	n["data_ins"] = [pins[0], pins[1]]


## The dynamic-input policy for a kind ({} when the kind is fixed-size).
func _dyn_policy(kind: int) -> Dictionary:
	return DYNAMIC_INPUTS.get(kind, {})


## True when the node's inputs may grow/shrink. Calls whose target is a
## function declared in this script are exempt: their pins mirror the real
## declaration exactly (names, types, order, count).
func is_dynamic_input_node(id: int) -> bool:
	if not nodes.has(id):
		return false
	var n: Dictionary = nodes[id]
	if _dyn_policy(int(n["kind"])).is_empty():
		return false
	if int(n["kind"]) == Kind.CALL and bool(n["fields"].get("declared", false)):
		# Calls pinned to a real signature mirror the declaration exactly...
		# except variadic calls, whose argument list may grow.
		if not bool(n["fields"].get("vararg", false)):
			return false
	if int(n["kind"]) == Kind.OPERATOR and _op_is_comparison(str(n["fields"].get("op", "+"))):
		return false   # a comparison has exactly two operands, no grow slot
	return true


## A pin is "occupied" when a wire feeds it or the user typed a value.
## An unoccupied pin is an empty grow slot.
func _pin_occupied(id: int, i: int) -> bool:
	if not _connected_data_source(id, i).is_empty():
		return true
	return String(nodes[id]["data_ins"][i]["value"]).strip_edges() != ""


## Guarantees exactly one trailing empty pin (the grow slot).
func _ensure_one_empty(id: int) -> void:
	var n: Dictionary = nodes[id]
	var pins: Array = n["data_ins"]
	if pins.size() > 0 and not _pin_occupied(id, pins.size() - 1):
		return
	pins.append({"name": _dyn_pin_name(id), "type": Types.VARIANT, "value": ""})


## Trims trailing empty pins so at most one remains. Trailing empties never
## carry links, so removal cannot disturb link indices.
func _trim_trailing_empties(id: int) -> void:
	var n: Dictionary = nodes[id]
	var pol: Dictionary = _dyn_policy(int(n["kind"]))
	var minp: int = int(pol.get("min", 0))
	var pins: Array = n["data_ins"]
	while pins.size() > maxi(minp, 1) \
			and pins.size() > 1 and not _pin_occupied(id, pins.size() - 1) \
			and not _pin_occupied(id, pins.size() - 2):
		pins.remove_at(pins.size() - 1)


## Next free name for a grow-slot pin ("c"/"d"/... for operators,
## "arg4"/"arg5"/... for calls, "value2"/... for print).
func _dyn_pin_name(id: int) -> String:
	var n: Dictionary = nodes[id]
	var pins: Array = n["data_ins"]
	var taken: Dictionary = {}
	for pin: Dictionary in pins:
		taken[String(pin["name"])] = true
	var prefix: String = "arg"
	if int(n["kind"]) == Kind.OPERATOR:
		prefix = ""
	elif int(n["kind"]) == Kind.PRINT:
		prefix = "value"
	var i: int = pins.size() + 1
	while i < pins.size() + 1000:
		var name: String = prefix + (char(96 + i) if prefix == "" else str(i))
		if not taken.has(name):
			return name
		i += 1
	return prefix + "x"


## Emits the chain starting at `cur`. `walk` is the tab depth at which plain
## chain statements of this walk are emitted; nodes that are joins or that
## belong to a shallower scope are emitted at their own stored depth instead.
func _emit_flow(cur: int, walk: int, out: PackedStringArray, emitted: Dictionary) -> void:
	var first: bool = true
	while cur >= 0:
		if emitted.has(cur):
			return   # join already emitted by another path
		var n: Dictionary = nodes[cur]
		var k: int = int(n["kind"])
		var is_ctrl: bool = k in CONTROL_KINDS
		if not first and (incoming_exec(cur) >= 2 or int(n["depth"]) + 1 < walk):
			_pending_join = cur   # shared / outer continuation: caller emits it
			return
		var d: int = (int(n["depth"]) + 1) if is_ctrl else walk
		_emit_one(cur, d, out, emitted)
		first = false
		if is_ctrl or k in [Kind.RETURN, Kind.BREAK, Kind.CONTINUE, Kind.ENTRY]:
			return   # control nodes emit their own continuation
		cur = _exec_target(cur, 0)


func _emit_one(id: int, emit_d: int, out: PackedStringArray, emitted: Dictionary) -> void:
	# passive bookkeeping: remember which buffer elements this node produced
	var first_elem: int = out.size()
	_emit_one_impl(id, emit_d, out, emitted)
	if out.size() > first_elem:
		_line_marks.append([_cur_seg, first_elem, out.size(), id])


## Appends `text` as one or more output lines: continuation lines (from a
## multi-line expression such as a Lambda node) re-indent at the statement's
## own indentation, preserving the expression's relative tabs.
func _emit_indented(ind: String, text: String, out: PackedStringArray) -> void:
	for ln: String in text.split("\n"):
		out.append(ind + ln if ln != "" else "")


func _emit_one_impl(id: int, emit_d: int, out: PackedStringArray, emitted: Dictionary) -> void:
	emitted[id] = true
	var n: Dictionary = nodes[id]
	var ind: String = "\t".repeat(emit_d)
	match int(n["kind"]):
		Kind.STATEMENT:
			if not n["stmt"].is_empty():
				var st: Dictionary = n["stmt"]
				if bool(st["has_value"]):
					# Multi-line values (a typed lambda body, a block literal) are
					# typed relative to the statement: every continuation line is
					# emitted at the statement's depth plus its own indentation.
					var val: String = _resolve_pin(id, 0, 0)
					var vlines: PackedStringArray = val.split("\n")
					var dop2: String = str(st.get("op", "="))
					if bool(st["decl"]):
						out.append(ind + "var " + String(st.get("lhs_full", st["lhs"])) + " " + (dop2 if dop2 != "" else "=") + " " + vlines[0])
					else:
						out.append(ind + st["lhs"] + " " + st["op"] + " " + vlines[0])
					for vi: int in range(1, vlines.size()):
						if String(vlines[vi]).strip_edges() != "":
							out.append(ind + String(vlines[vi]))
				else:
					out.append(ind + "var " + String(st.get("lhs_full", st["lhs"])))
			else:
				if String(n["body"]).strip_edges() == "":
					# A freshly spawned statement wired into a block but not yet
					# filled in: emit a pass so the block stays valid GDScript.
					out.append(ind + "pass")
				else:
					for ln: String in String(n["body"]).split("\n"):
						out.append(ind + ln)
		Kind.COMMENT:
			for ln: String in String(n["body"]).split("\n"):
				out.append(ind + ln)
		Kind.PASS:
			out.append(ind + "pass")
		Kind.PRINT:
			var vals: PackedStringArray = PackedStringArray()
			for ai: int in n["data_ins"].size():
				if not _pin_occupied(id, ai):
					break   # stop at the first empty grow slot
				vals.append(_resolve_pin(id, ai, 0))
			_emit_indented(ind, "print(" + ", ".join(vals) + ")", out)
		Kind.CALL:
			# Statement (exec) calls emit their call line; expression (pure)
			# calls resolve as values through _resolve_pin instead.
			if str(n["fields"].get("mode", "pure")) == "exec":
				_emit_indented(ind, _call_expr(id, 0), out)
		Kind.VAR_DECL:
			# Local (private) declarations emit at their flow position so the
			# generated statements keep the source's execution order.
			for ln: String in _var_decl_text(id).split("\n"):
				out.append(ind + ln if ln != "" else "")
			var vdtail: String = _var_decl_tail(id)
			if vdtail != "":
				for tln: String in _reindent_tail(vdtail, ind).split("\n"):
					out.append(tln)
		Kind.VARIABLE_SET:
			# A sanitized-away reference keeps its node in the flow as a
			# pass-through placeholder: it emits nothing and stays valid GDScript.
			if str(n["fields"].get("name", "")).strip_edges() != "":
				_emit_indented(ind, str(n["fields"].get("name", "my_var")) + " = " + _resolve_pin(id, 0, 0), out)
		Kind.RETURN:
			var has_val: bool = n["data_ins"].size() > 0
			var val: String = _resolve_pin(id, 0, 0) if has_val else ""
			if not has_val or (String(n["data_ins"][0]["value"]).strip_edges() == "" and val == "null"):
				out.append(ind + "return")
			else:
				_emit_indented(ind, "return " + val, out)
		Kind.BREAK:
			out.append(ind + "break")
		Kind.CONTINUE:
			out.append(ind + "continue")
		Kind.IF, Kind.ELIF:
			_pending_join = -1
			var d: int = int(n["depth"]) + 1
			var ind2: String = "\t".repeat(d)
			# An Else If only emits `elif` when it is really chained from an
			# If/Else If False pin; a standalone (or plainly wired) Else If
			# starts its own if-chain, so spawned ones always compile.
			var chained: bool = false
			if bool(n["is_elif"]):
				for il: Dictionary in exec_in.get(id, []):
					if not nodes.has(int(il["from_id"])):
						continue
					var fk: int = int(nodes[int(il["from_id"])]["kind"])
					if fk in [Kind.IF, Kind.ELIF] and int(il["from_port"]) == 1:
						chained = true
						break
			var kw: String = "elif" if (bool(n["is_elif"]) and chained) else "if"
			_emit_indented(ind2, kw + " " + _resolve_pin(id, 0, 0) + ":", out)
			# True branch.
			var t: int = _exec_target(id, 0)
			if t >= 0:
				_emit_flow(t, d + 1, out, emitted)
			else:
				out.append("\t".repeat(d + 1) + "pass")   # keep the block valid
			# Where the code continues afterwards: a join reached by the True
			# branch, else this node's "done" pin.
			var cont: int = _pending_join
			_pending_join = -1
			if cont < 0:
				cont = _exec_target(id, 2)
			# False branch: a chained Else If, or an `else:` block. A False
			# wire to the same node the True branch joins on is just the
			# continuation (both paths meet there), not an else body.
			var ft: int = _exec_target(id, 1)
			if ft >= 0 and ft != cont:
				if int(nodes[ft]["kind"]) == Kind.ELIF:
					_chain_tail = -1
					_emit_one(ft, int(nodes[ft]["depth"]) + 1, out, emitted)
					if cont < 0:
						cont = _chain_tail
					_chain_tail = -1
				else:
					out.append(ind2 + "else:")
					_emit_flow(ft, d + 1, out, emitted)
					if cont < 0 and _pending_join >= 0:
						cont = _pending_join
					_pending_join = -1
			if kw == "elif":
				# A chained Else If hands the continuation to the chain head.
				_chain_tail = cont
				return
			if cont >= 0 and not emitted.has(cont):
				if int(nodes[cont]["depth"]) >= int(n["depth"]):
					_emit_flow(cont, int(nodes[cont]["depth"]) + 1, out, emitted)
				else:
					_pending_join = cont   # belongs to an outer scope: defer
		Kind.WHILE, Kind.FOR:
			_pending_join = -1
			var d: int = int(n["depth"]) + 1
			var ind2: String = "\t".repeat(d)
			if int(n["kind"]) == Kind.WHILE:
				_emit_indented(ind2, "while " + _resolve_pin(id, 0, 0) + ":", out)
			else:
				var vname: String = n["data_outs"][0]["name"] if n["data_outs"].size() > 0 else "i"
				var vtypef: String = str(n["fields"].get("iter_type", "")).strip_edges()
				var viter: String = "for " + (vname + ": " + vtypef if vtypef != "" else vname) + " in " + _resolve_pin(id, 0, 0) + ":"
				_emit_indented(ind2, viter, out)
			var bt: int = _exec_target(id, 0)
			if bt >= 0:
				_emit_flow(bt, d + 1, out, emitted)
			else:
				out.append("\t".repeat(d + 1) + "pass")   # keep the block valid
			var cont: int = _pending_join
			_pending_join = -1
			if cont < 0:
				cont = _exec_target(id, 1)   # "done" pin
			if cont >= 0 and not emitted.has(cont):
				if int(nodes[cont]["depth"]) >= int(n["depth"]):
					_emit_flow(cont, int(nodes[cont]["depth"]) + 1, out, emitted)
				else:
					_pending_join = cont   # belongs to an outer scope: defer
		Kind.MATCH:
			var d: int = int(n["depth"]) + 1
			var ind2: String = "\t".repeat(d)
			var nb: int = n["exec_outs"].size() - 1   # last port is the "after" pin
			if nb <= 0:
				out.append(ind2 + "pass")   # degenerate match: keep the code valid
				return
			_emit_indented(ind2, "match " + _resolve_pin(id, 0, 0) + ":", out)
			var cont: int = -1
			for port: int in nb:
				_pending_join = -1
				var bt: int = _exec_target(id, port)
				var lab: String = String(n["exec_outs"][port])
				# parsed branch labels keep their trailing colon; spawned/edited
				# ones are bare — always emit exactly one
				if not lab.ends_with(":"):
					lab += ":"
				out.append(ind2 + "\t" + lab)
				if bt >= 0:
					_emit_flow(bt, d + 2, out, emitted)
				else:
					out.append("\t".repeat(d + 2) + "pass")   # keep the branch valid
				if _pending_join >= 0 and cont < 0:
					cont = _pending_join
			_pending_join = -1
			if cont < 0:
				cont = _exec_target(id, nb)   # "after" pin
			if cont >= 0 and not emitted.has(cont):
				if int(nodes[cont]["depth"]) >= int(n["depth"]):
					_emit_flow(cont, int(nodes[cont]["depth"]) + 1, out, emitted)
				else:
					_pending_join = cont   # belongs to an outer scope: defer
		_:
			# Data-only node reached by flow: skip silently.
			pass


## Expression for a data input: the connected source's expression, else the
## node's inline text, else a type-aware default.
## Generates the GDScript expression for a Function Call node, using the
## invocation syntax of its source category. Target/argument expressions come
## from wired pins or typed text; a required target that is missing produces a
## generation problem instead of invalid code.
func _call_expr(cid: int, depth: int) -> String:
	var n: Dictionary = nodes[cid]
	var f: Dictionary = n["fields"]
	var fname: String = str(f.get("call", "")).strip_edges()
	var fcat: String = str(f.get("cat", ""))
	var fowner: String = str(f.get("owner", ""))
	var needs_target: bool = bool(f.get("needs_target", false))
	var mkind: String = str(f.get("member", ""))
	var arg_start: int = 1 if (needs_target and n["data_ins"].size() > 0) else 0
	# Target resolution: wired pin > typed text > registered Class Reference.
	var ti: Dictionary = _call_target_source(cid, depth)
	var target_expr: String = String(ti["expr"])
	if int(ti["rid"]) >= 0:
		# a reference retargeted after registration may no longer fit its members
		var fitp: String = _member_fit_problem(int(ti["rid"]), cid)
		if fitp != "":
			_note_problem(cid, fitp)
	# An instance-level member driven only by a class-mode Class Reference
	# cannot run: the reference names a type, not an instance.
	if int(ti["rid"]) >= 0 and not _member_class_level(cid) \
			and String(nodes[int(ti["rid"])]["fields"].get("ref", "class")) == "class":
		_note_problem(cid, "'%s' needs a real object, but its Class Reference '%s' is set to Class. Switch the reference to Instance (or connect an object to the Target pin)."
			% [fname, String(nodes[int(ti["rid"])]["fields"].get("target", ""))])
		return "null"
	if needs_target and target_expr == "":
		_note_problem(cid, "'%s' does not know which object to act on. Connect a %s to its Target pin, or attach it to a Class Reference set to Instance."
			% [fname, str(f.get("target_type", ""))
				if str(f.get("target_type", "")) != "" else fowner])
		return "null"
	if mkind == "property":
		# value read (expression use) or value write (statement use); a
		# class-level property (const / static var) reads through the class
		# owner when no target is wired
		var pbase: String = target_expr if target_expr != "" else _call_owner_expr(cid)
		if str(f.get("mode", "pure")) == "exec":
			var vi: int = 1 if arg_start == 1 else 0
			return "%s.%s = %s" % [pbase, fname, _resolve_pin(cid, vi, depth)]
		return "%s.%s" % [pbase, fname]
	if mkind == "signal" and str(f.get("mode", "exec")) == "pure":
		# the Signal object reference (for .connect(...) and friends)
		return "%s.%s" % [target_expr if target_expr != "" else _call_owner_expr(cid), fname]
	if mkind == "signal":
		var sargs: PackedStringArray = PackedStringArray()
		for ai0: int in range(arg_start, n["data_ins"].size()):
			if not _pin_occupied(cid, ai0):
				break   # stop at the first empty grow slot
			sargs.append(_resolve_pin(cid, ai0, depth))
		var stail: String = ""
		if not sargs.is_empty():
			stail = ", " + ", ".join(sargs)
		return "%s.emit_signal(\"%s\"%s)" % [target_expr, fname, stail]
	var args: PackedStringArray = PackedStringArray()
	# Only overridden arguments (wired or explicitly typed) are emitted.
	# Trailing untouched optional arguments keep the function's declared
	# default — GDScript has no named call arguments, so an untouched
	# optional argument BEFORE the last override is emitted with its real
	# default text to preserve argument order and behavior.
	var last: int = -1
	for ai: int in range(arg_start, n["data_ins"].size()):
		if _pin_overridden(cid, ai):
			last = ai
	if last < 0:
		# Nothing overridden: still report a missing required argument.
		for ai: int in range(arg_start, n["data_ins"].size()):
			var rp: Dictionary = n["data_ins"][ai]
			if rp.has("optional") and not bool(rp["optional"]):
				_note_problem(cid, "Call '%s' is missing required argument '%s'"
					% [fname, String(rp["name"])])
				break
		return _call_syntax(cid, fname, fcat, fowner, target_expr, "")
	var gap: bool = false
	for ai: int in range(arg_start, last + 1):
		var pin: Dictionary = n["data_ins"][ai]
		var aname: String = String(pin["name"])
		if _pin_overridden(cid, ai):
			args.append(_resolve_pin(cid, ai, depth))
			continue
		var dtxt: String = str(pin.get("default_text", "")).strip_edges()
		if pin.has("optional") and bool(pin["optional"]) and dtxt != "":
			# untouched optional argument before an override: pass the declared
			# default explicitly so the order (and behavior) is preserved
			gap = true
			args.append(dtxt)
			continue
		if pin.has("optional") and not bool(pin["optional"]):
			# a required argument was left empty
			_note_problem(cid, "Call '%s' is missing required argument '%s'"
				% [fname, aname])
			gap = true
			args.append("null")
			continue
		# free-form grow slot left empty: emit nothing past it
		break
	var arglist: String = ", ".join(args)
	return _call_syntax(cid, fname, fcat, fowner, target_expr, arglist)


## True when a call argument is explicitly provided: wired, or typed with a
## text other than the declaration's default. Untouched optional arguments
## (still showing their declared default) are NOT overridden.
func _pin_overridden(cid: int, ai: int) -> bool:
	if not _connected_data_source(cid, ai).is_empty():
		return true
	var pin: Dictionary = nodes[cid]["data_ins"][ai]
	var raw: String = String(pin["value"]).strip_edges()
	if raw == "":
		return false
	var dtxt: String = str(pin.get("default_text", "")).strip_edges()
	if bool(pin.get("optional", false)) and dtxt != "" and raw == dtxt:
		return false
	return true


## The GDScript invocation syntax for a call node's source category.
func _call_syntax(cid: int, fname: String, fcat: String, fowner: String,
		target_expr: String, arglist: String) -> String:
	match fcat:
		FuncReg.CAT_LANGUAGE:
			return "%s(%s)" % [fname, arglist]
		FuncReg.CAT_AUTOLOAD:
			return "%s.%s(%s)" % [fowner, fname, arglist]
		FuncReg.CAT_CUSTOM:
			if bool(nodes[cid]["fields"].get("static", false)):
				return "%s.%s(%s)" % [fowner, fname, arglist]
			return "%s.%s(%s)" % [target_expr, fname, arglist]
		FuncReg.CAT_GODOT_CLASS, FuncReg.CAT_EXTENSION:
			if bool(nodes[cid]["fields"].get("static", false)):
				return "%s.%s(%s)" % [fowner, fname, arglist]
			if not bool(nodes[cid]["fields"].get("needs_target", false)):
				# Plain self-call resolved from the script's own base class:
				# emit as an ordinary unqualified call, like the source did.
				return "%s(%s)" % [fname, arglist]
			return "%s.%s(%s)" % [target_expr, fname, arglist]
		FuncReg.CAT_PROJECT, FuncReg.CAT_ADDON:
			if fowner == script_path or fowner == "":
				return "%s(%s)" % [fname, arglist]
			if bool(nodes[cid]["fields"].get("static", false)):
				return "preload(\"%s\").%s(%s)" % [fowner, fname, arglist]
			return "%s.%s(%s)" % [target_expr, fname, arglist]
		FuncReg.CAT_GODOT_TYPE:
			return "%s.%s(%s)" % [target_expr, fname, arglist]
		_:
			# Free-form / unresolved: emit the typed call as-is (the original
			# meaning is preserved verbatim; no metadata was invented).
			return "%s(%s)" % [fname, arglist]


func _resolve_pin(id: int, pin_index: int, depth: int) -> String:
	if depth > 32:
		return "null"
	for l: Dictionary in data_links:
		if int(l["to_id"]) == id and int(l["to_in"]) == pin_index:
			return _source_expr(int(l["from_id"]), int(l["from_out"]), depth + 1)
	var n: Dictionary = nodes[id]
	if int(pin_index) >= n["data_ins"].size():
		return "null"
	var text: String = String(n["data_ins"][pin_index]["value"]).strip_edges()
	if text == "":
		return Types.default_value(int(n["data_ins"][pin_index]["type"]))
	return text


## Expression produced by a data output pin.
func _source_expr(src_id: int, out_index: int, depth: int) -> String:
	if depth > 32:
		return "null"
	var n: Dictionary = nodes[src_id]
	match int(n["kind"]):
		Kind.LITERAL:
			return String(n["fields"].get("value", "null"))
		Kind.VARIABLE_GET:
			return String(n["fields"].get("name", "null"))
		Kind.OPERATOR:
			# Left-associative fold over the occupied pins, so any number of
			# dynamic operands generates valid GDScript: ((a op b) op c).
			var parts: PackedStringArray = PackedStringArray()
			for ai: int in n["data_ins"].size():
				if not _pin_occupied(src_id, ai):
					break   # stop at the first empty grow slot
				parts.append(_resolve_pin(src_id, ai, depth))
			if parts.is_empty():
				return "null"
			var acc: String = parts[0]
			for pi: int in range(1, parts.size()):
				acc = "(%s %s %s)" % [acc, n["fields"].get("op", "+"), parts[pi]]
			return acc
		Kind.CALL:
			return _call_expr(src_id, depth)
		Kind.LAMBDA:
			return _lambda_expr(src_id)
		Kind.CLASS_REF:
			return _class_ref_expr(src_id, depth)
		Kind.ENTRY:
			if int(out_index) < n["data_outs"].size():
				return String(n["data_outs"][out_index]["name"])
			return "null"
		Kind.FOR:
			if n["data_outs"].size() > 0:
				return String(n["data_outs"][0]["name"])
			return "null"
		Kind.ARGUMENT:
			return String(n["fields"].get("name", "null"))
		Kind.STATEMENT, Kind.VARIABLE_SET, Kind.VAR_DECL, Kind.CONST_DECL:
			if n["data_outs"].size() > 0:
				return String(n["data_outs"][out_index]["name"])
			return "null"
		_:
			return "null"
