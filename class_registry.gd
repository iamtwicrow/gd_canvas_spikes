@tool
extends RefCounted
## Class & member discovery registry for the Class Reference / Member node
## system (graph_model.gd Kind.CLASS_REF + member Function Call nodes).
##
## Discovers every class a project script can reference and, per class, every
## member a Member node can represent - always from real metadata, never
## invented:
##
##   Engine    ClassDB classes (methods / properties / signals / constants,
##             inherited members flagged, virtuals flagged)
##   Extension GDExtension / C# classes (ClassDB API_EXTENSION)
##   Custom    `class_name` scripts of the project (methods via the function
##             registry, vars / signals / consts via side-effect-free parsing)
##   Autoload  Autoload singletons (instance-level members: the singleton IS
##             the instance)
##   Script    res:// scripts without class_name (static methods and consts
##             only - the only members callable through preload("path"))
##
## Member kinds (mtype): "method", "property", "signal", "constant". A member
## record mirrors the function registry's signature shape so Function Call
## nodes consume it directly (args / min_args / ret / static / needs_target /
## vararg / virtual), plus "mtype" and "type_text" for the pin type.
##
## Extensibility: register_class() / register_member() / register_provider()
## let addons contribute without touching the discovery code. refresh()
## re-scans so new scripts and registrations appear without a restart.

const Types = preload("graph_types.gd")
const FuncReg = preload("func_registry.gd")
const TypeReg = preload("type_registry.gd")

# ---- Class kinds ---------------------------------------------------------------
const KIND_ENGINE: String = "engine"
const KIND_EXTENSION: String = "extension"
const KIND_CUSTOM: String = "custom"
const KIND_SCRIPT: String = "script"
const KIND_AUTOLOAD: String = "autoload"

# ---- Member kinds ----------------------------------------------------------------
const MT_METHOD: String = "method"
const MT_PROPERTY: String = "property"
const MT_SIGNAL: String = "signal"
const MT_CONSTANT: String = "constant"

const REGISTRY_SCRIPT: String = "res://addons/gd_canvas_spikes/class_registry.gd"

static var _instance: RefCounted = null

static func get_registry() -> RefCounted:
	if _instance == null:
		_instance = load(REGISTRY_SCRIPT).new()
	return _instance


# key -> class record; key is the class name, the singleton name or the
# res:// script path (whatever a generated reference is written against).
var _classes: Dictionary = {}
# key -> Array[Dictionary] member records (built lazily, cached per refresh).
var _members: Dictionary = {}
var _providers: Array[Callable] = []
var _scanned: bool = false


# ---- Public API ----------------------------------------------------------------
## Full re-scan. The class table is cheap (no members are built until asked).
func refresh() -> void:
	_classes = {}
	_members = {}
	_scanned = true
	_scan_classdb()
	_scan_custom_classes()
	_scan_autoloads()
	for cb: Callable in _providers:
		for c: Dictionary in cb.call():
			register_class(c)


## Lazy discovery (first menu open / first lookup).
func ensure() -> void:
	if not _scanned:
		refresh()


## Contribute one class record (extension point for addons/tests).
func register_class(c: Dictionary) -> void:
	var rec: Dictionary = {
		"name": str(c.get("name", "")),
		"kind": str(c.get("kind", KIND_ENGINE)),
		"path": str(c.get("path", "")),
		"base": str(c.get("base", "")),
		"singleton": bool(c.get("singleton", false)),
		"cls": str(c.get("cls", "")),
		"menu": bool(c.get("menu", false)),
	}
	if rec["name"] == "":
		return
	# GDScript resolves one global name per spelling; a later registration
	# (fresh scan) replaces a stale one, a duplicate keeps the first.
	var key: String = _class_key(rec)
	if _classes.has(key) and not _scanned:
		return
	_classes[key] = rec
	_members.erase(key)


## Contribute one member record for an already-known class.
func register_member(cls: String, m: Dictionary) -> void:
	if not _classes.has(cls):
		return
	if not _members.has(cls):
		_members[cls] = []
	var rec: Dictionary = _member_record(m, str(_classes[cls]["name"]))
	for existing: Dictionary in _members[cls]:
		if str(existing["name"]) == rec["name"] and str(existing["mtype"]) == rec["mtype"]:
			return   # same member twice: keep the first
	_members[cls].append(rec)


## Contribute a whole source: the Callable must return Array[Dictionary]
## of class records.
func register_provider(cb: Callable) -> void:
	_providers.append(cb)


## All known class records (engine + extension + custom + autoload + script).
func classes() -> Array[Dictionary]:
	ensure()
	var out: Array[Dictionary] = []
	for key: String in _classes:
		out.append(_classes[key])
	return out


## Curated default menu listing: engine classes the function menu already
## curates, every custom class, every autoload. Everything else stays
## reachable through search (see search()).
func menu_classes() -> Array[Dictionary]:
	ensure()
	var out: Array[Dictionary] = []
	for e: Dictionary in classes():
		match str(e["kind"]):
			KIND_CUSTOM, KIND_AUTOLOAD:
				out.append(e)
			KIND_ENGINE, KIND_EXTENSION:
				if FuncReg.MENU_CLASSES.has(str(e["name"])):
					out.append(e)
			_:
				pass
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a["name"]).to_lower() < str(b["name"]).to_lower())
	return out


## Case-insensitive search across every discoverable class. Returns up to
## `cap` records {name, kind, path, base, singleton, cls, menu}.
func search(query: String, cap: int = 40) -> Array[Dictionary]:
	ensure()
	var q: String = query.strip_edges().to_lower()
	var out: Array[Dictionary] = []
	if q == "":
		return out
	var exact: Array[Dictionary] = []
	var prefix: Array[Dictionary] = []
	var partial: Array[Dictionary] = []
	for e: Dictionary in classes():
		var n: String = str(e["name"]).to_lower()
		if n == q:
			exact.append(e)
		elif n.begins_with(q):
			prefix.append(e)
		elif n.contains(q):
			partial.append(e)
	for group: Array[Dictionary] in [exact, prefix, partial]:
		for e2: Dictionary in group:
			out.append(e2)
			if out.size() >= cap:
				return out
	return out


## Resolves one class reference target: a class_name, an engine/extension
## class, an Autoload singleton name, or a res:// script path (a preload
## reference — static methods and consts only). {} when the text is not a
## known class.
func find_class(target: String) -> Dictionary:
	ensure()
	var t: String = target.strip_edges()
	if t == "":
		return {}
	if _classes.has(t):
		return _classes[t]
	# A quoted script path ("res://x.gd") resolves like the bare path.
	if t.begins_with("\"") and t.ends_with("\""):
		var inner: String = t.trim_prefix("\"").trim_suffix("\"").strip_edges()
		if _classes.has(inner):
			return _classes[inner]
		t = inner
	# A res:// script path is a valid reference target even when the scan has
	# not (yet) seen the file: build the record on demand, nothing invented.
	if t.begins_with("res://") and t.ends_with(".gd") and FileAccess.file_exists(t):
		return {"name": t, "kind": KIND_SCRIPT, "path": t, "base": "",
			"singleton": false, "cls": "", "menu": false}
	return {}


func is_known_class(target: String) -> bool:
	return not find_class(target).is_empty()


## The class identity used for pin typing: a custom class is its class_name,
## an autoload is its script's class_name (or the singleton name when the
## script has none), a script path stays the path.
func class_identity(rec: Dictionary) -> String:
	var cls: String = str(rec.get("cls", ""))
	if cls != "":
		return cls
	return str(rec.get("name", ""))


## The GDScript expression a class-mode Class Reference node emits.
func class_expr(rec: Dictionary) -> String:
	match str(rec.get("kind", "")):
		KIND_SCRIPT:
			return "preload(\"%s\")" % str(rec.get("path", ""))
		_:
			# class names and singleton names are written verbatim
			return str(rec.get("name", ""))


## Every member of one class (methods, properties, signals, constants),
## including inherited engine members. Cached per refresh.
func members_of(target: String) -> Array[Dictionary]:
	ensure()
	var rec: Dictionary = find_class(target)
	if rec.is_empty():
		return []
	var key: String = _class_key(rec)
	if _members.has(key):
		return _members[key]
	var out: Array[Dictionary] = []
	match str(rec["kind"]):
		KIND_ENGINE, KIND_EXTENSION:
			out = _engine_members(str(rec["name"]))
		KIND_CUSTOM, KIND_AUTOLOAD:
			out = _script_members(rec)
		KIND_SCRIPT:
			out = _path_members(rec)
		_:
			pass
	_members[key] = out
	return out


## One member record by name (first match; methods win over same-named
## members because they are the common case).
func find_member(target: String, mname: String) -> Dictionary:
	for m: Dictionary in members_of(target):
		if str(m["name"]) == mname:
			return m
	return {}


## True when `from_t` (a class reference identity) can supply the target of
## a member whose class is `to_t`: same class, or a subclass -> base class.
func reference_fits(from_text: String, to_text: String) -> bool:
	if from_text == "" or to_text == "":
		return true
	if from_text == to_text:
		return true
	if ClassDB.class_exists(from_text) and ClassDB.class_exists(to_text):
		return ClassDB.is_parent_class(from_text, to_text)
	# script chains are validated by the type registry (inheritance walk)
	return TypeReg.get_registry().is_compatible(from_text, to_text)


# ---- ClassDB scan -----------------------------------------------------------------
func _scan_classdb() -> void:
	for cn: String in ClassDB.get_class_list():
		var api: int = ClassDB.class_get_api_type(cn)
		var kind: String = KIND_ENGINE
		if api == ClassDB.API_EXTENSION:
			kind = KIND_EXTENSION
		elif api == ClassDB.API_EDITOR:
			continue   # editor-only plumbing has no runtime reference
		register_class({
			"name": cn, "kind": kind, "base": ClassDB.get_parent_class(cn),
			"menu": FuncReg.MENU_CLASSES.has(cn),
		})


# ---- Custom classes (class_name scripts) -------------------------------------------
func _scan_custom_classes() -> void:
	# The type registry already scans the project's class_name scripts
	# (side-effect-free source parse); its records carry path and base.
	TypeReg.get_registry().ensure()
	for e: Dictionary in TypeReg.get_registry().all_types():
		if str(e["kind"]) != "class" or str(e["cat"]) != TypeReg.CAT_CUSTOM:
			continue
		register_class({
			"name": str(e["name"]), "kind": KIND_CUSTOM,
			"path": str(e.get("script_path", "")),
			"base": str(e.get("base", "")), "menu": true,
		})


# ---- Autoloads ----------------------------------------------------------------------
func _scan_autoloads() -> void:
	for p: Dictionary in ProjectSettings.get_property_list():
		var pname: String = str(p["name"])
		if not pname.begins_with("autoload/"):
			continue
		var sname: String = pname.trim_prefix("autoload/")
		var val: String = str(ProjectSettings.get_setting(pname, ""))
		var path: String = val.trim_prefix("*").strip_edges()
		var cls: String = ""
		if path.ends_with(".gd") and FileAccess.file_exists(path):
			cls = _script_class_name(path)
		register_class({
			"name": sname, "kind": KIND_AUTOLOAD, "path": path,
			"singleton": true, "cls": cls, "menu": true,
		})


# ---- Member discovery: engine / extension classes -----------------------------------
func _engine_members(cls: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var parent: String = ClassDB.get_parent_class(cls)
	# Methods (own + inherited; statics included - ClassDB marks them).
	for m: Dictionary in ClassDB.class_get_method_list(cls, false):
		var flags: int = int(m.get("flags", 0))
		var is_static: bool = flags & METHOD_FLAG_STATIC != 0
		var adef: Array = m.get("args", [])
		var defaults: Array = m.get("default_args", [])
		var opt_start: int = adef.size() - defaults.size()
		var args: Array[Dictionary] = []
		var min_args: int = 0
		for i: int in adef.size():
			var a: Dictionary = adef[i]
			var req: bool = i < opt_start
			if req:
				min_args += 1
			args.append({
				"name": str(a.get("name", "arg%d" % i)),
				"type": _vtype_text(int(a.get("type", 0)), str(a.get("class_name", ""))),
				"default": "" if req else var_to_str(defaults[i - opt_start]),
				"required": req,
			})
		out.append({
			"mtype": MT_METHOD, "name": str(m["name"]),
			"static": is_static,
			"needs_target": not is_static,
			"target_type": cls,
			"args": args, "min_args": min_args,
			"ret": _vtype_text(int(m["return"].get("type", 0)), str(m["return"].get("class_name", ""))),
			"vararg": flags & METHOD_FLAG_VARARG != 0,
			"virtual": flags & METHOD_FLAG_VIRTUAL != 0,
			"inherited": not _own_method(cls, parent, str(m["name"])),
			"type_text": "",
		})
	# Properties (instance vars, exported engine properties; typed).
	for prop: Dictionary in ClassDB.class_get_property_list(cls, false):
		var pname: String = str(prop.get("name", ""))
		if pname == "" or pname.contains("/") or pname.contains(":"):
			continue
		if _member_name_taken(out, pname):
			continue   # same name already offered (rare engine overlaps)
		var ttext: String = _vtype_text(int(prop.get("type", 0)), str(prop.get("class_name", "")))
		out.append({
			"mtype": MT_PROPERTY, "name": pname,
			"static": false, "needs_target": true, "target_type": cls,
			"args": [], "min_args": 0, "ret": ttext, "vararg": false,
			"virtual": false, "inherited": not _own_property(cls, parent, pname),
			"type_text": ttext,
		})
	# Signals (declared engine signals with their argument signatures).
	for sig: Dictionary in ClassDB.class_get_signal_list(cls, false):
		var sname: String = str(sig.get("name", ""))
		if sname == "" or _member_name_taken(out, sname):
			continue
		var sargs: Array[Dictionary] = []
		for a: Dictionary in sig.get("args", []):
			sargs.append({
				"name": str(a.get("name", "arg")),
				"type": _vtype_text(int(a.get("type", 0)), str(a.get("class_name", ""))),
				"default": "", "required": true,
			})
		out.append({
			"mtype": MT_SIGNAL, "name": sname,
			"static": false, "needs_target": true, "target_type": cls,
			"args": sargs, "min_args": sargs.size(), "ret": "void",
			"vararg": false, "virtual": false,
			"inherited": not _own_signal(cls, parent, sname),
			"type_text": "Signal",
		})
	# Constants and enum constants (class-level reads).
	var enums: Dictionary = {}
	for en: String in ClassDB.class_get_enum_list(cls, true):
		for ec: String in ClassDB.class_get_enum_constants(cls, en, true):
			enums[ec] = en
	for cname: String in ClassDB.class_get_integer_constant_list(cls, true):
		if _member_name_taken(out, cname):
			continue
		var etext: String = "int"
		if enums.has(cname):
			etext = "enum.%s.%s" % [cls, str(enums[cname])]
		out.append({
			"mtype": MT_CONSTANT, "name": cname,
			"static": true, "needs_target": false, "target_type": "",
			"args": [], "min_args": 0, "ret": etext, "vararg": false,
			"virtual": false, "inherited": false, "type_text": etext,
		})
	return out


# ---- Member discovery: custom classes / autoloads (script parsing) -------------------
func _script_members(rec: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var key: String = str(rec["name"])
	var path: String = str(rec.get("path", ""))
	# Methods: the function registry already parsed every script-level `func`
	# of the project (signatures, statics, virtual detection).
	var cat: String = FuncReg.CAT_CUSTOM if str(rec["kind"]) == KIND_CUSTOM \
		else FuncReg.CAT_AUTOLOAD
	FuncReg.get_registry().ensure()
	for e: Dictionary in FuncReg.get_registry().entries:
		if str(e["cat"]) != cat or str(e["owner"]) != key:
			continue
		out.append({
			"mtype": MT_METHOD, "name": str(e["name"]),
			"static": bool(e["static"]),
			"needs_target": not bool(e["static"]),
			"target_type": class_identity(rec),
			"args": (e["args"] as Array).duplicate(true),
			"min_args": int(e.get("min_args", 0)),
			"ret": str(e["ret"]), "vararg": bool(e.get("vararg", false)),
			"virtual": bool(e.get("virtual", false)), "inherited": false,
			"type_text": "",
		})
	# Vars, signals, consts and funcs: side-effect-free column-0 parse of the
	# file (func parsing keeps the registry self-sufficient for classes the
	# function scan has not seen, e.g. test-registered singletons).
	if path.ends_with(".gd") and FileAccess.file_exists(path):
		var info: Dictionary = _parse_script_members(path)
		var seen_funcs: Dictionary = {}
		for m0: Dictionary in out:
			if str(m0["mtype"]) == MT_METHOD:
				seen_funcs[str(m0["name"])] = true
		for fn: Dictionary in info["funcs"]:
			if seen_funcs.has(str(fn["name"])):
				continue   # the function scan's entry (with virtual detection) wins
			out.append({
				"mtype": MT_METHOD, "name": str(fn["name"]),
				"static": bool(fn["static"]),
				"needs_target": not bool(fn["static"]),
				"target_type": class_identity(rec),
				"args": (fn["args"] as Array).duplicate(true),
				"min_args": int(fn.get("min_args", 0)),
				"ret": str(fn["ret"]), "vararg": bool(fn.get("vararg", false)),
				"virtual": false, "inherited": false, "type_text": "",
			})
		for v: Dictionary in info["vars"]:
			out.append({
				"mtype": MT_PROPERTY, "name": str(v["name"]),
				"static": bool(v["static"]),
				"needs_target": not bool(v["static"]),
				"target_type": class_identity(rec),
				"args": [], "min_args": 0,
				"ret": str(v["type"]), "vararg": false, "virtual": false,
				"inherited": false, "type_text": str(v["type"]),
			})
		for s: Dictionary in info["signals"]:
			var sargs: Array[Dictionary] = []
			for a: Dictionary in s["args"]:
				sargs.append({
					"name": str(a["name"]), "type": str(a["type"]),
					"default": "", "required": true,
				})
			out.append({
				"mtype": MT_SIGNAL, "name": str(s["name"]),
				"static": false, "needs_target": true,
				"target_type": class_identity(rec),
				"args": sargs, "min_args": sargs.size(), "ret": "void",
				"vararg": false, "virtual": false, "inherited": false,
				"type_text": "Signal",
			})
		for c: Dictionary in info["consts"]:
			out.append({
				"mtype": MT_CONSTANT, "name": str(c["name"]),
				"static": true, "needs_target": false, "target_type": "",
				"args": [], "min_args": 0, "ret": str(c["type"]),
				"vararg": false, "virtual": false, "inherited": false,
				"type_text": str(c["type"]),
			})
	return out


# ---- Member discovery: script paths (preload references) ------------------------------
func _path_members(rec: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var path: String = str(rec.get("path", ""))
	FuncReg.get_registry().ensure()
	for cat: String in [FuncReg.CAT_PROJECT, FuncReg.CAT_ADDON]:
		for e: Dictionary in FuncReg.get_registry().entries:
			if str(e["cat"]) != cat or str(e["owner"]) != path:
				continue
			if not bool(e["static"]):
				continue   # a preload reference has no instance: statics only
			out.append({
				"mtype": MT_METHOD, "name": str(e["name"]),
				"static": true, "needs_target": false, "target_type": "",
				"args": (e["args"] as Array).duplicate(true),
				"min_args": int(e.get("min_args", 0)),
				"ret": str(e["ret"]), "vararg": bool(e.get("vararg", false)),
				"virtual": false, "inherited": false, "type_text": "",
			})
	if path.ends_with(".gd") and FileAccess.file_exists(path):
		var info: Dictionary = _parse_script_members(path)
		for c: Dictionary in info["consts"]:
			out.append({
				"mtype": MT_CONSTANT, "name": str(c["name"]),
				"static": true, "needs_target": false, "target_type": "",
				"args": [], "min_args": 0, "ret": str(c["type"]),
				"vararg": false, "virtual": false, "inherited": false,
				"type_text": str(c["type"]),
			})
	return out


## Column-0 member declarations of one script (inner-class members are NOT
## callable on the script itself, mirroring func_registry's rule).
func _parse_script_members(path: String) -> Dictionary:
	var info: Dictionary = {"vars": [], "signals": [], "consts": [], "funcs": []}
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return info
	var lines: PackedStringArray = f.get_as_text().split("\n")
	f = null
	for ln: String in lines:
		if ln.begins_with("\t") or ln.begins_with(" "):
			continue
		var s: String = ln.strip_edges()
		if s.begins_with("#") or s == "":
			continue
		var is_static: bool = false
		if s.begins_with("static "):
			is_static = true
			s = s.trim_prefix("static ").strip_edges()
		if s.begins_with("var ") or s.begins_with("var\t"):
			info["vars"].append(_parse_var_line(s, is_static))
		elif s.begins_with("const ") and not is_static:
			info["consts"].append(_parse_const_line(s))
		elif s.begins_with("signal ") and not is_static:
			info["signals"].append(_parse_signal_line(s))
		elif s.begins_with("func "):
			var fn: Dictionary = FuncReg.get_registry()._parse_func_line("func " + s.trim_prefix("func "))
			if not fn.is_empty():
				fn["static"] = is_static
				info["funcs"].append(fn)
	return info


func _parse_var_line(s: String, is_static: bool) -> Dictionary:
	var rest: String = s.trim_prefix("var").strip_edges()
	var name_part: String = rest
	var vtype: String = ""
	var vdef: String = ""
	var infer: int = rest.find(":=")
	var eq: int = _top_level_char(rest, "=")
	if infer >= 0 and (eq < 0 or infer < eq):
		# `var x := 5`: inferred type, no explicit annotation
		name_part = rest.substr(0, infer).strip_edges()
		vdef = rest.substr(infer + 2).strip_edges()
		vtype = _infer_literal_type(vdef)
	else:
		var colon: int = _typed_colon(rest)
		if colon >= 0:
			name_part = rest.substr(0, colon).strip_edges()
			var after: String = rest.substr(colon + 1).strip_edges()
			# type text runs to the `=` of the default (or to the end)
			var eq2: int = _top_level_char(after, "=")
			vtype = after.substr(0, eq2).strip_edges() if eq2 >= 0 else after.strip_edges()
			if eq2 >= 0:
				vdef = after.substr(eq2 + 1).strip_edges()
		else:
			var eq0: int = _top_level_char(rest, "=")
			if eq0 >= 0:
				name_part = rest.substr(0, eq0).strip_edges()
				vdef = rest.substr(eq0 + 1).strip_edges()
				vtype = _infer_literal_type(vdef)
	return {"name": name_part, "type": vtype, "static": is_static}


func _parse_const_line(s: String) -> Dictionary:
	var rest: String = s.trim_prefix("const").strip_edges()
	var eq: int = _top_level_char(rest, "=")
	var name_part: String = rest.substr(0, eq).strip_edges() if eq >= 0 else rest.strip_edges()
	var vdef: String = rest.substr(eq + 1).strip_edges() if eq >= 0 else ""
	var colon: int = _typed_colon(name_part)
	var ctype: String = ""
	if colon >= 0:
		ctype = name_part.substr(colon + 1).strip_edges()
		name_part = name_part.substr(0, colon).strip_edges()
	if ctype == "" and vdef != "":
		ctype = _infer_literal_type(vdef)
	return {"name": name_part, "type": ctype}


func _parse_signal_line(s: String) -> Dictionary:
	var rest: String = s.trim_prefix("signal").strip_edges()
	var open: int = rest.find("(")
	var sname: String = rest if open < 0 else rest.substr(0, open).strip_edges()
	var argtext: String = ""
	if open >= 0:
		var close: int = rest.rfind(")")
		if close > open:
			argtext = rest.substr(open + 1, close - open - 1)
	var args: Array[Dictionary] = []
	for part: String in FuncReg._split_top_commas(argtext):
		part = part.strip_edges()
		if part == "":
			continue
		var colon: int = part.find(":")
		var aname: String = part
		var atype: String = "Variant"
		if colon >= 0:
			aname = part.substr(0, colon).strip_edges()
			atype = part.substr(colon + 1).strip_edges()
		args.append({"name": aname, "type": atype if atype != "" else "Variant"})
	return {"name": sname, "args": args}


## First top-level (bracket/paren depth 0) occurrence of `ch`, -1 when absent.
func _top_level_char(s: String, ch: String) -> int:
	var depth: int = 0
	var in_str: bool = false
	var quote: String = ""
	for i: int in s.length():
		var c: String = s[i]
		if in_str:
			if c == "\\":
				continue
			if c == quote:
				in_str = false
			continue
		if c == "\"" or c == "'":
			in_str = true
			quote = c
		elif c == "(" or c == "[":
			depth += 1
		elif c == ")" or c == "]":
			depth -= 1
		elif depth == 0 and c == ch:
			# avoid matching `==` / `<=` / `>=` operator characters
			if ch == "=" and i > 0 and (s[i - 1] in ["=", "!", "<", ">"] or (i + 1 < s.length() and s[i + 1] == "=")):
				continue
			return i
	return -1


## The colon of a `name: Type` annotation (not inside brackets, not `:=`).
func _typed_colon(s: String) -> int:
	var depth: int = 0
	var in_str: bool = false
	var quote: String = ""
	for i: int in s.length():
		var c: String = s[i]
		if in_str:
			if c == "\\":
				continue
			if c == quote:
				in_str = false
			continue
		if c == "\"" or c == "'":
			in_str = true
			quote = c
		elif c == "(" or c == "[":
			depth += 1
		elif c == ")" or c == "]":
			depth -= 1
		elif depth == 0 and c == ":":
			if i + 1 < s.length() and s[i + 1] == "=":
				continue   # `:=` inference, not a type annotation
			return i
	return -1


## Safe literal inference for parsed defaults (never invents object types).
func _infer_literal_type(v: String) -> String:
	var s: String = v.strip_edges()
	if s == "":
		return ""
	if s == "true" or s == "false":
		return "bool"
	if s.is_valid_int():
		return "int"
	if s.is_valid_float():
		return "float"
	if s.begins_with("\"") or s.begins_with("'"):
		return "String"
	if s.begins_with("Vector2(") or s == "Vector2.ZERO" or s == "Vector2.ONE":
		return "Vector2"
	if s.begins_with("Vector3(") or s == "Vector3.ZERO" or s == "Vector3.ONE":
		return "Vector3"
	if s.begins_with("Color(") or s.begins_with("Color."):
		return "Color"
	return ""   # unresolvable: stays untyped (never guessed)


func _script_class_name(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var text: String = f.get_as_text()
	f = null
	for ln: String in text.split("\n"):
		var s: String = ln.strip_edges()
		if s.begins_with("class_name "):
			return s.trim_prefix("class_name ").strip_edges().split(" ")[0]
	return ""


# ---- Record shaping ------------------------------------------------------------------
## Normalizes one member record (filling every field the graph model reads).
func _member_record(m: Dictionary, cls: String) -> Dictionary:
	var mtype: String = str(m.get("mtype", MT_METHOD))
	var is_static: bool = bool(m.get("static", false))
	var needs_target: bool = bool(m.get("needs_target", not is_static))
	var args: Array[Dictionary] = []
	for a: Dictionary in m.get("args", []):
		args.append({
			"name": str(a.get("name", "arg")),
			"type": str(a.get("type", "Variant")),
			"default": str(a.get("default", "")),
			"required": bool(a.get("required", true)),
		})
	return {
		"mtype": mtype, "name": str(m.get("name", "")),
		"static": is_static, "needs_target": needs_target,
		"target_type": str(m.get("target_type", cls)),
		"args": args, "min_args": int(m.get("min_args", 0)),
		"ret": str(m.get("ret", "void")), "vararg": bool(m.get("vararg", false)),
		"virtual": bool(m.get("virtual", false)),
		"inherited": bool(m.get("inherited", false)),
		"type_text": str(m.get("type_text", "")),
	}


func _member_name_taken(out: Array[Dictionary], mname: String) -> bool:
	for m: Dictionary in out:
		if str(m["name"]) == mname:
			return true
	return false


# ---- Inheritance helpers (own vs inherited members) -----------------------------------
func _own_method(cls: String, parent: String, mname: String) -> bool:
	if parent == "" or not ClassDB.class_exists(parent):
		return true
	for m: Dictionary in ClassDB.class_get_method_list(parent, true):
		if str(m["name"]) == mname:
			return false
	return true


func _own_property(cls: String, parent: String, pname: String) -> bool:
	if parent == "" or not ClassDB.class_exists(parent):
		return true
	for p: Dictionary in ClassDB.class_get_property_list(parent, true):
		if str(p.get("name", "")) == pname:
			return false
	return true


func _own_signal(cls: String, parent: String, sname: String) -> bool:
	if parent == "" or not ClassDB.class_exists(parent):
		return true
	for s: Dictionary in ClassDB.class_get_signal_list(parent, true):
		if str(s.get("name", "")) == sname:
			return false
	return true


## Variant type id + class name -> the GDScript type text (reuses the function
## registry's mapping so call nodes and member pins agree on every type).
func _vtype_text(vt: int, cls: String) -> String:
	return FuncReg.get_registry()._variant_type_name(vt, cls)


# ---- Bookkeeping ----------------------------------------------------------------------
func _class_key(rec: Dictionary) -> String:
	return str(rec.get("name", ""))
