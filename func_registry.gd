@tool
extends RefCounted
## Universal function-discovery registry for the Function Call node.
##
## Discovers callable functions from every source available to the running
## Godot project and exposes them as uniform signature records:
##
##  - Language        global GDScript/Godot utility functions (print, lerp...)
##  - Godot Type      methods of built-in Variant types (String, Array, ...)
##  - Godot Class     engine class methods, incl. inherited ones (ClassDB)
##  - Project Script  funcs declared in .gd scripts of the current project
##  - Custom Class    funcs of scripts registered through `class_name`
##  - Autoload        funcs exposed through Autoload singletons
##  - Addon           funcs declared in scripts under res://addons/
##  - Extension       methods of classes registered by GDExtensions / C#
##
## Metadata comes from real APIs (the engine's extension-api dump shipped as
## builtin_api.json, ClassDB, script metadata / lightweight source parsing and
## ProjectSettings) — nothing is invented. Entries with incomplete metadata are
## still usable (free-form call) but carry "partial": true so callers can
## explain what could not be resolved.
##
## Extensibility: addons/tests can contribute entries through register_entry()
## or whole sources through register_provider() without touching this file.
## refresh() re-scans the project so newly added scripts/addons/registrations
## appear without a restart.

const Types = preload("graph_types.gd")

# ---- Source categories -------------------------------------------------------
const CAT_LANGUAGE: String = "Language"
const CAT_GODOT_TYPE: String = "Godot Type"
const CAT_GODOT_CLASS: String = "Godot Class"
const CAT_PROJECT: String = "Project Script"
const CAT_CUSTOM: String = "Custom Class"
const CAT_AUTOLOAD: String = "Autoload"
const CAT_ADDON: String = "Addon"
const CAT_EXTENSION: String = "Extension"
const CAT_UNKNOWN: String = "Unknown"

## The Godot API JSON asset shipped with the addon (reduced dump of the
## engine's extension API: utility functions + built-in Variant type methods).
const API_JSON: String = "res://addons/gd_canvas_spikes/builtin_api.json"

## Engine classes offered in the function menu. This is menu curation, NOT a
## support limit: discover_class() can add any ClassDB class at runtime, and
## every project/custom/autoload/addon script function is discovered fully.
const MENU_CLASSES: Array[String] = [
	"Object", "Node", "Node2D", "Node3D", "Control", "CanvasItem",
	"Sprite2D", "Timer", "AnimationPlayer", "Resource", "RefCounted",
	"PackedScene", "SceneTree", "JSON", "FileAccess", "DirAccess",
	"RandomNumberGenerator", "HttpClient", "EditorInterface",
]

## Builtin Variant types whose methods are listed in the menu (the rest are
## still fully supported through the registry/free-form calls).
const MENU_BUILTIN_TYPES: Array[String] = [
	"String", "Array", "Dictionary", "Vector2", "Vector3", "Callable",
]

static var _instance: RefCounted = null

## The script currently being edited (its functions generate as plain calls).
var current_script: String = ""

var entries: Array[Dictionary] = []
var _by_key: Dictionary = {}          # dedup key -> entry
var _providers: Array[Callable] = []  # external contributors
var _builtin_loaded: bool = false

## Session caches. The engine-side half of discovery (API dump JSON, ClassDB
## method lists) cannot change while the editor runs, and a project script's
## signatures only change when the file does, so a re-scan on every script
## open replays the first scan's records and re-parses only files whose
## modified time changed. Same entries as a cold scan; just not recomputed.
static var _static_entries: Array = []
static var _static_ready: bool = false
static var _static_builtin_loaded: bool = false
static var _parse_cache: Dictionary = {}   # path -> {"mt": int, "info": Dictionary}
var _recorded: Array = []
var _recording: bool = false


# ---- Singleton access ----------------------------------------------------------
static func get_registry() -> RefCounted:
	if _instance == null:
		_instance = load("res://addons/gd_canvas_spikes/func_registry.gd").new()
	return _instance


# ---- Public API ----------------------------------------------------------------
## Full re-scan (project scripts, addons, autoloads, extensions, ClassDB).
func refresh() -> void:
	entries = []
	_by_key = {}
	_load_static_entries()
	_scan_project_scripts()
	_scan_autoloads()
	for cb: Callable in _providers:
		for e: Dictionary in cb.call():
			_add_entry(e)


## Engine-side entries: scanned once per editor session, replayed afterwards.
func _load_static_entries() -> void:
	if _static_ready:
		for e: Dictionary in _static_entries:
			_add_entry(e)
		_builtin_loaded = _static_builtin_loaded
		return
	_recorded = []
	_recording = true
	_load_builtin_api()
	_discover_classdb()
	_recording = false
	_static_entries = _recorded
	_recorded = []
	_static_builtin_loaded = _builtin_loaded
	_static_ready = true


## Lazy discovery (first menu open). A full refresh() re-scans later.
func ensure() -> void:
	if entries.is_empty():
		refresh()


## Contribute one signature record (extension point for addons/tests).
func register_entry(e: Dictionary) -> void:
	_add_entry(e)


## Contribute a whole source: the Callable must return an Array[Dictionary].
func register_provider(cb: Callable) -> void:
	_providers.append(cb)


## All entries of one category.
func entries_for(cat: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e: Dictionary in entries:
		if str(e["cat"]) == cat:
			out.append(e)
	return out


## Signature lookup for pin building / change detection.
## `owner` semantics per category:
##   Language        "" (ignored)
##   Godot Type      the type name ("String", "Array", ...)
##   Godot Class     the class name ("Node", "Resource", ...)
##   Project Script  the script path (res://...)
##   Addon           the script path (res://addons/...)
##   Custom Class    the registered class name
##   Autoload        the singleton name
##   Extension       the class name
func find_entry(cat: String, owner: String, fname: String) -> Dictionary:
	ensure()
	# Pass 1: exact identity (category + owner + name).
	for e: Dictionary in entries:
		if str(e["cat"]) != cat:
			continue
		if str(e["name"]) != fname:
			continue
		if str(e["owner"]) == owner \
				or (owner == "" and (cat == CAT_LANGUAGE or str(e["owner"]) == current_script)):
			return e
	# Pass 2: basename fallback (call sites may store a shortened owner).
	# Same-basename scripts in different folders are genuinely different
	# classes: only fall back when the basename is unambiguous inside the
	# category, otherwise "a/foo.gd" must never silently resolve to "b/foo.gd".
	if owner != "" and owner.contains("/"):
		var base: String = owner.get_file()
		var hits: Array[Dictionary] = []
		for e2: Dictionary in entries:
			if str(e2["cat"]) == cat and str(e2["name"]) == fname \
					and str(e2["owner"]).get_file() == base:
				hits.append(e2)
		if hits.size() == 1:
			return hits[0]
	# Engine class fallback: the exact class may not expose the method itself
	# (inherited methods are only listed under their declaring class). Walk up
	# the ClassDB chain so `node.get_instance_id()` still resolves — the
	# returned entry keeps its "inherited" flag.
	if cat == CAT_GODOT_CLASS and owner != "" and ClassDB.class_exists(owner):
		var cls: String = owner
		while true:
			cls = ClassDB.get_parent_class(cls)
			if cls == "" or not ClassDB.class_exists(cls):
				break
			for e2: Dictionary in entries:
				if str(e2["cat"]) != cat or str(e2["name"]) != fname:
					continue
				if str(e2["owner"]) == cls:
					return e2
	return {}


## A human-readable menu name for an entry: owner prefix keeps same-named
## functions from different classes/objects distinguishable in search results.
func display_name(e: Dictionary) -> String:
	# The bare function name exactly as its source exposes it; for methods the
	# owning class/type/singleton is kept as a qualifier so same-named
	# functions from different owners stay distinguishable (no "Call" prefix —
	# the node type is identified by its styling/metadata, not the name).
	var cat: String = str(e["cat"])
	var n: String = str(e["name"])
	match cat:
		CAT_LANGUAGE:
			return n
		CAT_AUTOLOAD:
			return "%s.%s" % [str(e["owner"]), n]
		CAT_CUSTOM:
			return "%s.%s" % [str(e["owner"]), n]
		CAT_GODOT_TYPE, CAT_GODOT_CLASS, CAT_EXTENSION:
			return "%s.%s" % [str(e["owner"]), n]
		_:
			# script-backed sources: qualify with the file name, keep the full
			# owner in the node's source info instead (paths are too long)
			var base: String = str(e["owner"]).get_file().get_basename()
			return "%s.%s" % [base, n]


# ---- Discovery: engine API dump --------------------------------------------------
func _load_builtin_api() -> void:
	_builtin_loaded = false
	if not FileAccess.file_exists(API_JSON):
		return
	var f: FileAccess = FileAccess.open(API_JSON, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f = null
	if not (parsed is Dictionary):
		return
	var api: Dictionary = parsed as Dictionary
	for u: Dictionary in api.get("utility_functions", []):
		_add_entry({
			"name": str(u["name"]),
			"cat": CAT_LANGUAGE,
			"owner": "",
			"args": _args_from_json(u.get("args", [])),
			"ret": str(u.get("ret", "void")),
			"static": true,
			"needs_target": false,
			"vararg": bool(u.get("vararg", false)),
			"target_type": "",
		})
	var menu_types: Dictionary = {}
	for t: String in MENU_BUILTIN_TYPES:
		menu_types[t] = true
	# GDScript-compiler builtins are not engine utility functions, so the API
	# dump does not list them (e.g. print_debug, assert, preload). They are
	# real, documented language functions: add the ones with call-signatures
	# here so they are discoverable like every other language function.
	# (assert/preload are keywords/expressions, not normal calls.)
	var dumped: Dictionary = {}
	for u2: Dictionary in api.get("utility_functions", []):
		dumped[str(u2["name"])] = true
	if not dumped.has("print_debug"):
		_add_entry({
			"name": "print_debug", "cat": CAT_LANGUAGE, "owner": "",
			"args": [{"name": "value", "type": "Variant", "default": "", "required": true}],
			"ret": "void", "static": true, "needs_target": false,
			"vararg": true, "target_type": "",
		})
	for c: Dictionary in api.get("builtin_classes", []):
		var tn: String = str(c["name"])
		for m: Dictionary in c.get("methods", []):
			var is_static: bool = bool(m.get("static", false))
			if not menu_types.has(tn):
				continue   # supported through the registry, curated out of the menu
			_add_entry({
				"name": str(m["name"]),
				"cat": CAT_GODOT_TYPE,
				"owner": tn,
				"args": _args_from_json(m.get("args", [])),
				"ret": str(m.get("ret", "void")),
				"static": is_static,
				"needs_target": not is_static,
				"vararg": bool(m.get("vararg", false)),
				"target_type": tn,
			})
	_builtin_loaded = true


# ---- Discovery: ClassDB (engine classes + extensions) ----------------------------
func _discover_classdb() -> void:
	for cn: String in ClassDB.get_class_list():
		var api_type: int = ClassDB.class_get_api_type(cn)
		var cat: String = CAT_GODOT_CLASS
		if api_type == ClassDB.API_EXTENSION:
			cat = CAT_EXTENSION
		elif api_type == ClassDB.API_EDITOR:
			continue   # editor-only plumbing has no runtime call target
		if cat == CAT_GODOT_CLASS and not MENU_CLASSES.has(cn):
			continue   # menu curation; discover_class() can opt in any class
		_discover_class(cn, cat)


## Adds every method of one ClassDB class (also the extension point for
## supporting additional engine classes discovered at runtime).
func discover_class(cls: String, cat: String = CAT_GODOT_CLASS) -> void:
	_discover_class(cls, cat)


func _discover_class(cn: String, cat: String) -> void:
	if not ClassDB.class_exists(cn):
		return
	var methods: Array = ClassDB.class_get_method_list(cn, true)
	for m: Dictionary in methods:
		var flags: int = int(m.get("flags", 0))
		if flags & METHOD_FLAG_STATIC != 0:
			continue   # static engine methods are rare; ClassDB marks them
		var args: Array[Dictionary] = []
		var adef: Array = m.get("args", [])
		var min_args: int = 0
		var defaults: Array = m.get("default_args", [])
		# default_args lists the trailing optional arguments; every argument
		# BEFORE them is required. (The old inverted check marked optional
		# arguments as required and hid real defaults.)
		var opt_start: int = adef.size() - defaults.size()
		for i: int in adef.size():
			var a: Dictionary = adef[i]
			var req: bool = i < opt_start
			if req:
				min_args += 1
			args.append({
				"name": str(a.get("name", "arg%d" % i)),
				"type": _variant_type_name(int(a.get("type", 0)), String(a.get("class_name", ""))),
				# var_to_str yields a valid GDScript literal for every default
				# (Vector2(1, 2), true, "\"\"", null, ...) — str() would emit
				# invalid text like "(1, 2)" for math types.
				"default": "" if req else var_to_str(defaults[i - opt_start]),
				"required": req,
			})
		_add_entry({
			"name": str(m["name"]),
			"cat": cat,
			"owner": cn,
			"args": args,
			"min_args": min_args,
			"ret": _variant_type_name(int(m["return"].get("type", 0)), str(m["return"].get("class_name", ""))),
			"static": false,
			"needs_target": true,
			"vararg": flags & METHOD_FLAG_VARARG != 0,
			"target_type": cn,
			"inherited": not _own_method(cn, String(m["name"])),
			"virtual": flags & METHOD_FLAG_VIRTUAL != 0,
		})


func _own_method(cn: String, fname: String) -> bool:
	var parent: String = ClassDB.get_parent_class(cn)
	if parent == "" or not ClassDB.class_exists(parent):
		return true
	for m: Dictionary in ClassDB.class_get_method_list(parent, true):
		if str(m["name"]) == fname:
			return false
	return true


func _variant_type_name(vt: int, cls: String) -> String:
	if cls != "" and vt == Variant.Type.TYPE_OBJECT:
		return cls
	match vt:
		Variant.Type.TYPE_NIL: return "void"
		Variant.Type.TYPE_BOOL: return "bool"
		Variant.Type.TYPE_INT: return "int"
		Variant.Type.TYPE_FLOAT: return "float"
		Variant.Type.TYPE_STRING: return "String"
		Variant.Type.TYPE_STRING_NAME: return "StringName"
		Variant.Type.TYPE_NODE_PATH: return "NodePath"
		Variant.Type.TYPE_VECTOR2: return "Vector2"
		Variant.Type.TYPE_VECTOR2I: return "Vector2i"
		Variant.Type.TYPE_VECTOR3: return "Vector3"
		Variant.Type.TYPE_VECTOR3I: return "Vector3i"
		Variant.Type.TYPE_VECTOR4: return "Vector4"
		Variant.Type.TYPE_COLOR: return "Color"
		Variant.Type.TYPE_RECT2: return "Rect2"
		Variant.Type.TYPE_TRANSFORM2D: return "Transform2D"
		Variant.Type.TYPE_TRANSFORM3D: return "Transform3D"
		Variant.Type.TYPE_QUATERNION: return "Quaternion"
		Variant.Type.TYPE_BASIS: return "Basis"
		Variant.Type.TYPE_CALLABLE: return "Callable"
		Variant.Type.TYPE_SIGNAL: return "Signal"
		Variant.Type.TYPE_DICTIONARY: return "Dictionary"
		Variant.Type.TYPE_ARRAY: return "Array"
		Variant.Type.TYPE_RID: return "RID"
		Variant.Type.TYPE_OBJECT: return "Object"
		_:
			if vt >= Variant.Type.TYPE_PACKED_BYTE_ARRAY and vt <= Variant.Type.TYPE_PACKED_VECTOR4_ARRAY:
				return "PackedArray"
			return "Variant"


# ---- Discovery: project scripts / custom classes / addons ------------------------
func _scan_project_scripts() -> void:
	var found: Dictionary = {}   # path -> {class_name, extends, funcs: Array[Dictionary]}
	_collect_scripts("res://", found, 0)
	# extends map for the virtual-chain resolver: by path and by global class
	# name, so `extends SomeGlobalClass` / `extends "res://base.gd"` resolve.
	_script_extends = {}
	for path: String in found:
		var info0: Dictionary = found[path]
		_script_extends[path] = str(info0.get("extends", ""))
		var cn0: String = str(info0.get("class_name", ""))
		if cn0 != "":
			_script_extends[cn0] = str(info0.get("extends", ""))
	for path: String in found:
		var info: Dictionary = found[path]
		var in_addon: bool = path.begins_with("res://addons/")
		var has_cls: bool = str(info["class_name"]) != ""
		var cat: String = CAT_PROJECT
		if in_addon:
			cat = CAT_ADDON
		elif has_cls:
			cat = CAT_CUSTOM
		var virts: Dictionary = _script_virtuals(str(info.get("extends", "")))
		for fn: Dictionary in info["funcs"]:
			var e: Dictionary = fn.duplicate(true)
			e["cat"] = cat
			e["owner"] = str(info["class_name"]) if (cat == CAT_CUSTOM) else path
			e["script_path"] = path
			e["static"] = bool(fn.get("static", false))
			e["needs_target"] = not bool(fn.get("static", false)) \
				and (cat != CAT_PROJECT or path != current_script)
			# An engine-invoked callback: a non-static function whose name is a
			# virtual method somewhere in this script's inheritance chain. A
			# static function can never be engine-invoked (Godot calls instance
			# methods only), so it stays an ordinary callable.
			e["virtual"] = not bool(fn.get("static", false)) \
				and bool(virts.get(str(fn["name"]), false))
			_add_entry(e)


func _collect_scripts(dir_path: String, found: Dictionary, depth: int) -> void:
	if depth > 4 or found.size() > 600:
		return
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var f: String = dir.get_next()
	while f != "":
		if dir.current_is_dir():
			if not f.begins_with("."):
				var sub: String = dir_path.path_join(f)
				# A directory holding its own project.godot is a nested,
				# separate Godot project: its scripts are not part of this
				# project's callable space. Scanning it used to duplicate every
				# function of vendored addon copies (same file, second identity).
				if not FileAccess.file_exists(sub.path_join("project.godot")):
					_collect_scripts(sub, found, depth + 1)
		elif f.ends_with(".gd"):
			var path: String = dir_path.path_join(f)
			found[path] = _parse_script_file(path)
		f = dir.get_next()
	dir.list_dir_end()


## Lightweight source parse of one script: `class_name` plus every `func`
## declaration with its argument names, types, defaults and return type.
## Pure text parsing keeps discovery side-effect free — loading arbitrary
## project scripts would execute their static state and cannot reload while
## instances of them are running (the addon scans its own scripts too).
func _parse_script_file(path: String) -> Dictionary:
	var mt: int = FileAccess.get_modified_time(path)
	var hit: Variant = _parse_cache.get(path)
	if hit is Dictionary and int((hit as Dictionary)["mt"]) == mt:
		return (hit as Dictionary)["info"] as Dictionary
	var info: Dictionary = {"class_name": "", "extends": "", "funcs": []}
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return info
	var text: String = f.get_as_text()
	f = null
	info["class_name"] = _class_name_of(text)
	info["extends"] = _extends_of(text)
	var lines: PackedStringArray = text.split("\n")
	# Only column-0 `func` lines are script-level functions. Indented `func`
	# declarations belong to inner classes (e.g. a helper class nested in the
	# script) and are NOT callable on the script itself — attributing them to
	# the outer script used to create phantom globally-callable entries.
	for ln: String in lines:
		if ln.begins_with("\t") or ln.begins_with(" "):
			continue
		var s: String = ln.strip_edges()
		if not s.begins_with("func ") and not s.begins_with("static func "):
			continue
		var entry: Dictionary = _parse_func_line(s)
		if not entry.is_empty():
			info["funcs"].append(entry)
	_parse_cache[path] = {"mt": mt, "info": info}
	return info


func _class_name_of(text: String) -> String:
	for ln: String in text.split("\n"):
		var s: String = ln.strip_edges()
		if s.begins_with("class_name "):
			return s.trim_prefix("class_name ").strip_edges().split(" ")[0]
	return ""


## The raw `extends X` clause of a script source ("" when implicit).
func _extends_of(text: String) -> String:
	for ln: String in text.split("\n"):
		var s: String = ln.strip_edges()
		if s.begins_with("extends "):
			return s.trim_prefix("extends ").strip_edges()
	return ""


# ---- Engine-invoked virtual callbacks -------------------------------------------
## Functions Godot invokes automatically (lifecycle callbacks, notifications,
## property hooks...). Ground truth is real engine metadata, never name
## patterns:
##   * built-in classes: ClassDB lists them with METHOD_FLAG_VIRTUAL
##     (verified on 4.7.2: Node._process/_ready/_input all carry the flag),
##   * GDScript scripts: the name matches a virtual method in the script's
##     own inheritance chain (its `extends` clause resolved through project
##     scripts and/or the ClassDB ancestor chain).
## They stay valid declarations (parsing keeps representing them as Event
## nodes) but are excluded from the Function Call creation menu: calling them
## manually is never what a script needs.
static var _virtual_cache: Dictionary = {}   # ClassDB class -> {name: true}


## Own (non-inherited) virtual method names of one ClassDB class.
func _classdb_virtuals(cls: String) -> Dictionary:
	if _virtual_cache.has(cls):
		return _virtual_cache[cls]
	var out: Dictionary = {}
	if ClassDB.class_exists(cls):
		for m: Dictionary in ClassDB.class_get_method_list(cls, true):
			if int(m.get("flags", 0)) & METHOD_FLAG_VIRTUAL != 0:
				out[str(m["name"])] = true
	_virtual_cache[cls] = out
	return out


## Every virtual method name reachable through a ClassDB ancestor chain
## (each list is own-methods-only, so the chain must be walked).
func _classdb_chain_virtuals(cls: String) -> Dictionary:
	var out: Dictionary = {}
	var c: String = cls
	var guard: int = 0
	while c != "" and ClassDB.class_exists(c) and guard < 24:
		out.merge(_classdb_virtuals(c), true)
		c = ClassDB.get_parent_class(c)
		guard += 1
	return out

## path/global-class-name -> raw extends clause of every scanned project
## script (rebuilt by _scan_project_scripts, used to resolve script parent
## chains and by the autoload scan).
var _script_extends: Dictionary = {}


## Virtual-method names a script inherits, given its raw `extends` clause.
## The chain may pass through other project scripts (by res:// path or global
## class name); it bottoms out at a ClassDB class ("RefCounted" when a script
## declares no extends).
func _script_virtuals(base: String, depth: int = 0) -> Dictionary:
	if depth > 8:
		return {}
	var b: String = base.strip_edges()
	if b.begins_with("\""):
		b = b.trim_prefix("\"").trim_suffix("\"").strip_edges()
	if b == "":
		b = "RefCounted"   # implicit base class of every GDScript
	if b.ends_with(".gd"):
		# parent identified by script path (relative paths resolve against
		# the script's own directory at generation time; discovery only
		# trusts absolute res:// paths it actually scanned)
		var p: String = b
		if not p.begins_with("res://"):
			return {}
		if _script_extends.has(p):
			return _script_virtuals(str(_script_extends[p]), depth + 1)
		return {}
	if _script_extends.has(b):
		# parent identified by a global class name declared in the project
		return _script_virtuals(str(_script_extends[b]), depth + 1)
	if ClassDB.class_exists(b):
		return _classdb_chain_virtuals(b)
	return {}   # unknown base (e.g. not yet scanned): nothing is excluded


func _parse_func_line(s: String) -> Dictionary:
	var is_static: bool = false
	var body: String = s
	if body.begins_with("static "):
		is_static = true
		body = body.trim_prefix("static ").strip_edges()
	body = body.trim_prefix("func ").strip_edges()
	var popen: int = body.find("(")
	if popen < 0:
		return {}
	var fname: String = body.substr(0, popen).strip_edges()
	if not _valid_ident(fname):
		return {}
	var close: int = _matching_paren(body, popen)
	if close < 0:
		return {}
	var argtext: String = body.substr(popen + 1, close - popen - 1)
	var ret: String = "void"
	var after: String = body.substr(close + 1)
	var arrow: int = after.find("->")
	if arrow >= 0:
		var tail: String = after.substr(arrow + 2)
		ret = tail.substr(0, tail.find(":")).strip_edges()
	var args: Array[Dictionary] = []
	var min_args: int = 0
	for part: String in _split_top_commas(argtext):
		part = part.strip_edges()
		if part == "":
			continue
		var def: String = ""
		var eq: int = part.find("=")
		if eq >= 0:
			def = part.substr(eq + 1).strip_edges()
			part = part.substr(0, eq).strip_edges()
		var colon: int = part.find(":")
		var aname: String = part
		var atype: String = "Variant"
		if colon >= 0:
			aname = part.substr(0, colon).strip_edges()
			atype = part.substr(colon + 1).strip_edges()
		if not _valid_ident(aname):
			return {}   # unparseable signature: refuse rather than invent pins
		args.append({"name": aname, "type": atype, "default": def, "required": def == ""})
		if def == "":
			min_args += 1
	return {
		"name": fname,
		"args": args,
		"min_args": min_args,
		"ret": ret if ret != "" else "void",
		"static": is_static,
		"vararg": argtext.contains("**"),
	}


func _matching_paren(s: String, open_at: int) -> int:
	var depth: int = 0
	for i: int in range(open_at, s.length()):
		var ch: String = s[i]
		if ch == "(":
			depth += 1
		elif ch == ")":
			depth -= 1
			if depth == 0:
				return i
	return -1


static func _split_top_commas(s: String) -> PackedStringArray:
	var parts: PackedStringArray = []
	var depth: int = 0
	var cur: String = ""
	for ch: String in s:
		if ch == "(" or ch == "[":
			depth += 1
		elif ch == ")" or ch == "]":
			depth -= 1
		if ch == "," and depth == 0:
			parts.append(cur)
			cur = ""
		else:
			cur += ch
	if cur.strip_edges() != "":
		parts.append(cur)
	return parts


func _valid_ident(s: String) -> bool:
	if s == "":
		return false
	for i: int in s.length():
		var c: String = s[i]
		if not ((c >= "a" and c <= "z") or (c >= "A" and c <= "Z") \
				or (c >= "0" and c <= "9") or c == "_"):
			return false
	return not s[0].is_valid_int()


# ---- Discovery: autoloads --------------------------------------------------------
func _scan_autoloads() -> void:
	for p: Dictionary in ProjectSettings.get_property_list():
		var pname: String = str(p["name"])
		if not pname.begins_with("autoload/"):
			continue
		var sname: String = pname.trim_prefix("autoload/")
		var val: String = str(ProjectSettings.get_setting(pname, ""))
		var path: String = val.trim_prefix("*").strip_edges()
		var info: Dictionary = _parse_script_file(path) if path.ends_with(".gd") \
			else {"class_name": "", "extends": "", "funcs": []}
		var virts: Dictionary = _script_virtuals(str(info.get("extends", "")))
		for fn: Dictionary in info["funcs"]:
			var e: Dictionary = fn.duplicate(true)
			e["cat"] = CAT_AUTOLOAD
			e["owner"] = sname
			e["script_path"] = path
			e["needs_target"] = false
			e["virtual"] = not bool(fn.get("static", false)) \
				and bool(virts.get(str(fn["name"]), false))
			_add_entry(e)


# ---- Discovery: GDExtensions -----------------------------------------------------
## Registered extension classes come from ClassDB (api_type == API_EXTENSION)
## via _discover_classdb(). This adds an injection point for extension APIs
## that expose no ClassDB metadata (partially discoverable): entries can be
## registered externally through register_entry()/register_provider().


# ---- Entry bookkeeping -----------------------------------------------------------
func _add_entry(e: Dictionary) -> void:
	if _recording:
		_recorded.append(e)
	var args: Array[Dictionary] = []
	var min_args: int = int(e.get("min_args", -1))
	for a: Dictionary in e.get("args", []):
		args.append({
			"name": str(a.get("name", "arg")),
			"type": str(a.get("type", "Variant")),
			"default": str(a.get("default", "")),
			"required": bool(a.get("required", true)),
		})
		if bool(a.get("required", true)):
			min_args += 1 if min_args < 0 else 0
	if min_args < 0:
		min_args = 0
	var entry: Dictionary = {
		"name": str(e["name"]),
		"cat": str(e.get("cat", CAT_UNKNOWN)),
		"owner": str(e.get("owner", "")),
		"args": args,
		"min_args": min_args,
		"ret": str(e.get("ret", "void")),
		"static": bool(e.get("static", false)),
		"needs_target": bool(e.get("needs_target", false)),
		"vararg": bool(e.get("vararg", false)),
		"target_type": str(e.get("target_type", "")),
		"partial": bool(e.get("partial", false)),
		"inherited": bool(e.get("inherited", false)),
		"virtual": bool(e.get("virtual", false)),
		"script_path": str(e.get("script_path", "")),
	}
	# Identity of one callable: category + owner + name. GDScript has no
	# overloads, so a second exposure with a different parsed arg count is the
	# same function seen again (stale cache, drift) — keep the first, real
	# scan always wins because it runs first.
	var key: String = "%s|%s|%s" % [entry["cat"], entry["owner"], entry["name"]]
	if _by_key.has(key):
		return   # duplicate exposure of the same function: keep the first
	_by_key[key] = true
	entries.append(entry)


func _args_from_json(jargs: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for a: Dictionary in jargs:
		var d: String = str(a.get("default", ""))
		out.append({
			"name": str(a.get("name", "arg")),
			"type": str(a.get("type", "Variant")),
			"default": d,
			"required": d == "",
		})
	return out


func _args_from_metadata(mi: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var adef: Array = mi.get("args", [])
	var defaults: Array = mi.get("default_args", [])
	var opt_start: int = adef.size() - defaults.size()
	for i: int in adef.size():
		var a: Dictionary = adef[i]
		var req: bool = i < opt_start
		out.append({
			"name": str(a.get("name", "arg%d" % i)),
			"type": _variant_type_name(int(a.get("type", 0)), String(a.get("class_name", ""))),
			"default": "" if req else var_to_str(defaults[i - opt_start]),
			"required": req,
		})
	return out


func _ret_from_metadata(mi: Dictionary) -> String:
	var r: Dictionary = mi.get("return", {})
	return _variant_type_name(int(r.get("type", 0)), String(r.get("class_name", "")))


# ---- API type text -> pin type ---------------------------------------------------
## Maps a function signature's type text (from the API dump, ClassDB metadata
## or script source) onto the graph's pin types. Unknown texts fall back to
## Variant — types are never invented.
static func pin_type_of(api_type: String) -> int:
	var s: String = api_type.strip_edges()
	if s.begins_with("enum.") or s.begins_with("bitfield."):
		return Types.PinType.INT
	if s.begins_with("Array["):
		return Types.PinType.ARRAY
	match s:
		"void", "Nil", "null": return Types.PinType.VARIANT
		"bool": return Types.PinType.BOOL
		"int": return Types.PinType.INT
		"float": return Types.PinType.FLOAT
		"String", "StringName": return Types.PinType.STRING
		"NodePath": return Types.PinType.STRING
		"Vector2", "Vector2i": return Types.PinType.VECTOR2
		"Vector3", "Vector3i": return Types.PinType.VECTOR3
		"Color": return Types.PinType.COLOR
		"Array", "PackedArray", "PackedByteArray", "PackedInt32Array", \
		"PackedInt64Array", "PackedFloat32Array", "PackedFloat64Array", \
		"PackedStringArray", "PackedVector2Array", "PackedVector3Array", \
		"PackedColorArray", "PackedVector4Array": return Types.PinType.ARRAY
		"Dictionary": return Types.PinType.DICTIONARY
		_:
			if s.length() > 0 and s[0] == s[0].to_upper() and s[0] != s[0].to_lower():
				return Types.PinType.OBJECT
			return Types.PinType.VARIANT


# ---- Shared menu search ranking ------------------------------------------------
## Ranks `name` (a bare function/annotation name) against a search query.
## Case-insensitive; the owning class/type/singleton is matched as secondary
## metadata so `ball` finds `football`, `_ready` finds itself without the
## `Node.` prefix, and minor typos still hit via subsequence matching.
## Returns 0 (exact name) .. 6 (weak fuzzy), or -1 when there is no match.
static func rank_match(query: String, name: String, owner: String = "") -> int:
	var q: String = query.strip_edges().trim_prefix("@").to_lower()
	if q == "":
		return 0
	var ln: String = name.strip_edges().to_lower()
	var lo: String = owner.strip_edges().to_lower()
	var qualified: String = (lo + "." + ln) if lo != "" else ln
	if ln == q:
		return 0
	if qualified == q:
		return 1
	if ln.begins_with(q):
		return 2
	if ln.contains(q):
		return 3
	if lo != "" and (lo.begins_with(q) or lo.contains(q)):
		return 4
	# fuzzy: every query character appears in order in the name (e.g. "hlp"
	# -> "help", "proces" -> "process"). Weak on purpose: ranked last so
	# exact/prefix/substring results always win.
	if _is_subsequence(q, ln):
		return 5
	if lo != "" and _is_subsequence(q, lo):
		return 6
	return -1


## True when every character of `q` appears in `s` in order (not necessarily
## adjacent).
static func _is_subsequence(q: String, s: String) -> bool:
	if q.is_empty():
		return true
	var at: int = 0
	for ch: String in q:
		at = s.find(ch, at)
		if at < 0:
			return false
		at += 1
	return true
