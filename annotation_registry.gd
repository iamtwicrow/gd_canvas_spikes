@tool
extends RefCounted
## Registry of every GDScript annotation Godot 4.7.x defines, discovered from
## the engine's own documentation dump and verified against the actual
## GDScript parser (invalid annotations and placements were compiled and
## rejected before this list was written — nothing here is invented).
##
## The parser is the ground truth for annotations: it rejects unknown ones
## ("Unrecognized annotation") and misplaced ones ("Annotation X cannot be
## applied to a function"). This registry therefore contains exactly the
## annotations the 4.7.2 parser accepts, with their placement targets and
## argument signatures, and is used for autocomplete, structured editing and
## validation in the visual script workspace.

const FILE: String = "res://addons/gd_canvas_spikes/annotation_registry.gd"

## Targets: "class" = before class_name/extends (file level), "var" =
## variable declarations, "func" = function declarations, "statement" =
## statements/other declarations. One annotation may list several.
## Params: {name, type, default ("" = required), sample} — `sample` is the
## example value the autocomplete inserts for required arguments.
const ANNOTATIONS: Array[Dictionary] = [
	{"name": "abstract", "targets": ["class", "func"], "brief":
		"Marks the class as abstract, or a function as abstract (no body; subclasses must override).",
		"params": []},
	{"name": "class_name", "targets": ["class"], "brief":
		"Registers the script as a global named class.",
		"params": [{"name": "name", "type": "identifier", "default": "", "sample": "MyClass"}]},
	{"name": "export", "targets": ["var"], "brief":
		"Exports the variable to the Inspector.",
		"params": []},
	{"name": "export_category", "targets": ["var"], "brief":
		"Starts a new Inspector category for the following exports.",
		"params": [{"name": "name", "type": "String", "default": "", "sample": "Category"}]},
	{"name": "export_color_no_alpha", "targets": ["var"], "brief":
		"Exports a Color (or Color container) without the alpha channel.",
		"params": []},
	{"name": "export_custom", "targets": ["var"], "brief":
		"Exports with a fully custom PropertyHint and property usage flags.",
		"params": [{"name": "hint", "type": "int", "default": "", "sample": "0"},
			{"name": "hint_string", "type": "String", "default": "", "sample": "\"\""},
			{"name": "usage", "type": "int", "default": "6", "sample": "6"}]},
	{"name": "export_dir", "targets": ["var"], "brief":
		"Exports a String as a project-relative directory path.",
		"params": []},
	{"name": "export_enum", "targets": ["var"], "brief":
		"Exports an int (or String) with named enum values, e.g. @export_enum(\"A\", \"B\").",
		"params": [{"name": "names", "type": "String", "default": "", "sample": "\"A\", \"B\"", "variadic": true}]},
	{"name": "export_exp_easing", "targets": ["var"], "brief":
		"Exports a float as an exponential easing slider.",
		"params": [{"name": "hints", "type": "String", "default": "\"\"", "sample": "\"attenuation\""}]},
	{"name": "export_file", "targets": ["var"], "brief":
		"Exports a String (or String container) as a project-relative file path with an optional filter.",
		"params": [{"name": "filter", "type": "String", "default": "\"\"", "sample": "\"*.txt\""}]},
	{"name": "export_file_path", "targets": ["var"], "brief":
		"Exports a String as a file path (alias of @export_file in 4.7).",
		"params": [{"name": "filter", "type": "String", "default": "\"\"", "sample": "\"*.txt\""}]},
	{"name": "export_flags", "targets": ["var"], "brief":
		"Exports an int as named bit flags, e.g. @export_flags(\"A\", \"B\").",
		"params": [{"name": "names", "type": "String", "default": "", "sample": "\"A\", \"B\"", "variadic": true}]},
	{"name": "export_flags_2d_navigation", "targets": ["var"], "brief":
		"Exports an int as a 2D navigation layers bitmask.", "params": []},
	{"name": "export_flags_2d_physics", "targets": ["var"], "brief":
		"Exports an int as a 2D physics layers bitmask.", "params": []},
	{"name": "export_flags_2d_render", "targets": ["var"], "brief":
		"Exports an int as a 2D render layers bitmask.", "params": []},
	{"name": "export_flags_3d_navigation", "targets": ["var"], "brief":
		"Exports an int as a 3D navigation layers bitmask.", "params": []},
	{"name": "export_flags_3d_physics", "targets": ["var"], "brief":
		"Exports an int as a 3D physics layers bitmask.", "params": []},
	{"name": "export_flags_3d_render", "targets": ["var"], "brief":
		"Exports an int as a 3D render layers bitmask.", "params": []},
	{"name": "export_flags_avoidance", "targets": ["var"], "brief":
		"Exports an int as an avoidance layers bitmask.", "params": []},
	{"name": "export_global_dir", "targets": ["var"], "brief":
		"Exports a String as an absolute directory path.", "params": []},
	{"name": "export_global_file", "targets": ["var"], "brief":
		"Exports a String (or String container) as an absolute file path with an optional filter.",
		"params": [{"name": "filter", "type": "String", "default": "\"\"", "sample": "\"*.txt\""}]},
	{"name": "export_group", "targets": ["var"], "brief":
		"Starts a named Inspector group for the following exports.",
		"params": [{"name": "name", "type": "String", "default": "", "sample": "Group"},
			{"name": "prefix", "type": "String", "default": "\"\"", "sample": "\"\""}]},
	{"name": "export_multiline", "targets": ["var"], "brief":
		"Exports a String (or String container) as a multi-line editor.",
		"params": [{"name": "hint", "type": "String", "default": "\"\"", "sample": "\"\""}]},
	{"name": "export_node_path", "targets": ["var"], "brief":
		"Exports a NodePath (or NodePath container), optionally restricted to base types.",
		"params": [{"name": "type", "type": "String", "default": "\"\"", "sample": "\"Node\""}]},
	{"name": "export_placeholder", "targets": ["var"], "brief":
		"Exports a String with placeholder text shown while empty.",
		"params": [{"name": "placeholder", "type": "String", "default": "", "sample": "\"Placeholder\""}]},
	{"name": "export_range", "targets": ["var"], "brief":
		"Exports an int/float with a range slider; optional step and extra hints.",
		"params": [{"name": "min", "type": "float", "default": "", "sample": "0.0"},
			{"name": "max", "type": "float", "default": "", "sample": "100.0"},
			{"name": "step", "type": "float", "default": "1.0", "sample": "1.0"},
			{"name": "extra_hints", "type": "String", "default": "\"\"", "sample": "\"or_greater\""}]},
	{"name": "export_storage", "targets": ["var"], "brief":
		"Exports the variable in .tscn/.tres files but hides it from the Inspector.",
		"params": []},
	{"name": "export_subgroup", "targets": ["var"], "brief":
		"Starts a named Inspector subgroup inside the current group.",
		"params": [{"name": "name", "type": "String", "default": "", "sample": "Subgroup"},
			{"name": "prefix", "type": "String", "default": "\"\"", "sample": "\"\""}]},
	{"name": "export_tool_button", "targets": ["var"], "brief":
		"Shows an editor tool button (tool scripts only) that calls the variable's Callable.",
		"params": [{"name": "text", "type": "String", "default": "", "sample": "\"Run\""},
			{"name": "icon", "type": "String", "default": "\"\"", "sample": "\"\""}]},
	{"name": "icon", "targets": ["class"], "brief":
		"Sets the class icon shown in the editor.",
		"params": [{"name": "icon_path", "type": "String", "default": "", "sample": "\"res://icon.svg\""}]},
	{"name": "onready", "targets": ["var"], "brief":
		"Initializes the variable's value when the node enters the ready state.",
		"params": []},
	{"name": "rpc", "targets": ["func"], "brief":
		"Configures the function for remote procedure calls (mode, sync, transfer mode, channel).",
		"params": [{"name": "mode", "type": "String", "default": "\"authority\"", "sample": "\"authority\""},
			{"name": "sync", "type": "String", "default": "\"call_remote\"", "sample": "\"call_remote\""},
			{"name": "transfer_mode", "type": "String", "default": "\"reliable\"", "sample": "\"reliable\""},
			{"name": "transfer_channel", "type": "int", "default": "0", "sample": "0"}]},
	{"name": "static_unload", "targets": ["class"], "brief":
		"Makes static variables unload when the script is no longer in use.",
		"params": []},
	{"name": "tool", "targets": ["class"], "brief":
		"Runs the script inside the editor.",
		"params": []},
	{"name": "warning_ignore", "targets": ["class", "var", "func", "statement"], "brief":
		"Suppresses the named GDScript warning for the following declaration.",
		"params": [{"name": "warning", "type": "warning-name", "default": "", "sample": "\"unused_variable\"", "variadic": true}]},
	{"name": "warning_ignore_restore", "targets": ["class", "statement"], "brief":
		"Ends a @warning_ignore_start section, restoring the named warning.",
		"params": [{"name": "warning", "type": "warning-name", "default": "", "sample": "\"unused_variable\"", "variadic": true}]},
	{"name": "warning_ignore_start", "targets": ["class", "statement"], "brief":
		"Suppresses the named GDScript warning until the matching @warning_ignore_restore.",
		"params": [{"name": "warning", "type": "warning-name", "default": "", "sample": "\"unused_variable\"", "variadic": true}]},
]

## Not annotations in Godot 4.7: the parser rejects them and points to the
## documentation-tag equivalents. Recognized only so the workspace can give
## a precise message instead of "unknown"; never suggested by autocomplete.
const DOC_TAGS: Dictionary = {
	"deprecated": "Use a documentation tag instead: ## @deprecated: Reason here.",
	"experimental": "Use a documentation tag instead: ## @experimental: Reason here.",
}

var _by_name: Dictionary = {}
var _records: Dictionary = {}


static var _singleton: RefCounted = null


static func get_registry() -> RefCounted:
	if _singleton == null or not is_instance_valid(_singleton):
		_singleton = load(FILE).new()
	return _singleton


func _init() -> void:
	for a: Dictionary in ANNOTATIONS:
		_by_name[str(a["name"])] = a
		_records[str(a["name"])] = a


## Registered annotation entry ({} when the name is unknown).
func find(name: String) -> Dictionary:
	var n: String = name.strip_edges().trim_prefix("@")
	return _records.get(n, {})


func type_exists(name: String) -> bool:
	return _records.has(name.strip_edges().trim_prefix("@"))


## Case-insensitive exact/prefix/partial search over annotation names,
## restricted to entries usable on at least one of `targets`
## (empty targets = no restriction). Unknown doc tags are never suggested.
func search(query: String, cap: int, targets: Array[String] = []) -> Array[Dictionary]:
	var q: String = query.strip_edges().trim_prefix("@").to_lower()
	var out: Array[Dictionary] = []
	var exact: Array[String] = []
	var prefix: Array[String] = []
	var partial: Array[String] = []
	for a: Dictionary in ANNOTATIONS:
		if not targets.is_empty():
			var ok: bool = false
			for t: String in targets:
				if (a["targets"] as Array).has(t):
					ok = true
					break
			if not ok:
				continue
		var n: String = str(a["name"])
		var ln: String = n.to_lower()
		if q == "" or ln == q:
			exact.append(n)
		elif ln.begins_with(q):
			prefix.append(n)
		elif ln.contains(q):
			partial.append(n)
	for group: Array[String] in [exact, prefix, partial]:
		for n: String in group:
			if out.size() >= cap:
				return out
			out.append(_records[n])
	return out


## The annotation text autocomplete inserts: full template with default
## arguments filled in (required arguments use their sample values).
func template(name: String) -> String:
	var e: Dictionary = find(name)
	if e.is_empty():
		return ""
	var parts: PackedStringArray = PackedStringArray()
	for prm: Dictionary in e["params"]:
		var d: String = str(prm["default"])
		parts.append(d if d != "" else str(prm["sample"]))
	var n: String = str(e["name"])
	if parts.is_empty():
		return "@" + n
	return "@" + n + "(" + ", ".join(parts) + ")"


## Human-readable argument signature, e.g. "(min: float, max: float, ...)".
func signature(name: String) -> String:
	var e: Dictionary = find(name)
	if e.is_empty():
		return ""
	if (e["params"] as Array).is_empty():
		return ""
	var parts: PackedStringArray = PackedStringArray()
	for prm: Dictionary in e["params"]:
		var p: String = str(prm["name"]) + ": " + str(prm["type"])
		var d: String = str(prm["default"])
		if d != "":
			p += " = " + d
		parts.append(p)
	return "(" + ", ".join(parts) + ")"


func brief(name: String) -> String:
	var e: Dictionary = find(name)
	return "" if e.is_empty() else str(e["brief"])


## Splits an annotation prefix (one or more annotations, possibly on several
## lines) into individual annotation texts in source order. Handles nested
## parentheses, strings and a trailing inline comment; a class_name-style
## directive keeps its identifier ("@class_name Foo").
func split_annotations(text: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var s: String = text.strip_edges()
	var i: int = 0
	var n: int = s.length()
	while i < n:
		while i < n and (s[i] == " " or s[i] == "\t" or s[i] == "\n"):
			i += 1
		if i >= n or s[i] != "@":
			break
		var start: int = i
		i += 1
		while i < n and _is_ident_char(s[i]):
			i += 1
		# optional (...) argument list, honouring strings
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
					i += 1
					break
			elif depth == 0 and (c == "\n" or c == "#"):
				break
			i += 1
		# a bare identifier (class_name Foo) belongs to the directive
		if s.substr(start, i - start).trim_prefix("@") == "class_name":
			while i < n and (s[i] == " " or s[i] == "\t"):
				i += 1
			while i < n and s[i] != "\n" and s[i] != "#":
				i += 1
		var item: String = s.substr(start, i - start).strip_edges()
		if item != "":
			out.append(item)
	return out


## Validates one annotation text against the registry. Returns "" when the
## annotation is a known Godot 4.7.x annotation applicable to `target` with
## a plausible argument list; otherwise the problem message.
func validate(text: String, target: String) -> String:
	var t: String = text.strip_edges()
	if t == "" or not t.begins_with("@"):
		return "Not an annotation: '%s'" % t
	var parsed: PackedStringArray = split_annotations(t)
	if parsed.size() != 1:
		return "Malformed annotation: '%s'" % t
	var name: String = ""
	var argtext: String = ""
	var body: String = parsed[0].substr(1)
	var open: int = body.find("(")
	if open >= 0:
		name = body.substr(0, open)
		argtext = body.substr(open + 1, body.rfind(")") - open - 1)
	else:
		name = body.split(" ")[0]
		argtext = body.substr(name.length()).strip_edges()
	var e: Dictionary = find(name)
	if e.is_empty():
		if DOC_TAGS.has(name):
			return "Doc tag, not an annotation: %s" % DOC_TAGS[name]
		return "'@%s' is not a Godot 4.7 annotation; kept verbatim" % name
	if not (e["targets"] as Array).has(target):
		return "'@%s' cannot be applied to %s declarations" % [name, _target_label(target)]
	var args: PackedStringArray = PackedStringArray()
	if argtext.strip_edges() != "":
		args = _split_args(argtext)
	var req: int = 0
	var total: int = (e["params"] as Array).size()
	var variadic: bool = total > 0 and bool((e["params"][total - 1] as Dictionary).get("variadic", false))
	for prm: Dictionary in e["params"]:
		if str(prm["default"]) == "":
			req += 1
	if args.size() < req:
		return "'@%s' needs at least %d argument(s), got %d" % [name, req, args.size()]
	if args.size() > total and not variadic:
		return "'@%s' takes at most %d argument(s), got %d" % [name, total, args.size()]
	for k: int in args.size():
		var pi: int = k if k < total else (total - 1)
		var prm: Dictionary = e["params"][pi]
		var msg: String = _arg_type_problem(args[k].strip_edges(), str(prm["type"]))
		if msg != "":
			return "'@%s' argument %d (%s): %s" % [name, k + 1, str(prm["name"]), msg]
	return ""


## Splits an argument list on top-level commas, honouring strings.
func _split_args(argtext: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var depth: int = 0
	var in_str: String = ""
	var start: int = 0
	var i: int = 0
	while i < argtext.length():
		var c: String = argtext[i]
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
		elif c == "(" or c == "[":
			depth += 1
		elif c == ")" or c == "]":
			depth -= 1
		elif c == "," and depth == 0:
			out.append(argtext.substr(start, i - start).strip_edges())
			start = i + 1
		i += 1
	var last: String = argtext.substr(start).strip_edges()
	if last != "":
		out.append(last)
	return out


func _arg_type_problem(arg: String, ptype: String) -> String:
	match ptype:
		"int":
			if not arg.is_valid_int() and not _is_int_expr(arg):
				return "expected an integer, got '%s'" % arg
		"float":
			if not arg.is_valid_float() and not _is_int_expr(arg):
				return "expected a number, got '%s'" % arg
		"String":
			if not arg.begins_with("\"") and not arg.begins_with("'"):
				return "expected a string literal, got '%s'" % arg
		"identifier":
			if not _is_ident(arg):
				return "expected an identifier, got '%s'" % arg
		"warning-name":
			if not arg.begins_with("\""):
				return "expected a quoted warning name, got '%s'" % arg
	return ""


func _is_int_expr(arg: String) -> bool:
	# constants and simple negatives (PI, Int flags) are accepted; deep
	# validation stays with the GDScript parser
	var s: String = arg.strip_edges().trim_prefix("-")
	return s.is_valid_int() or s.is_valid_float() or _is_ident(s)


func _is_ident_char(c: String) -> bool:
	return c.is_valid_identifier() or c == "_" or "0123456789".contains(c)


func _is_ident(s: String) -> bool:
	if s == "":
		return false
	
	for c: String in s:
		if not _is_ident_char(c):
			return false
	return true


func _target_label(target: String) -> String:
	match target:
		"class":
			return "class-level (before class_name/extends)"
		"var":
			return "variable"
		"func":
			return "function"
		_:
			return "statement"
