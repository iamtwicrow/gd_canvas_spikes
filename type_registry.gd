@tool
extends RefCounted
## Dynamic data-type registry for the Visual Script addon.
##
## Discovers every data type available to the running Godot project from real
## metadata (never a hardcoded list) and provides:
##   - searchable type suggestions (autocomplete across all sources),
##   - Godot-accurate pin compatibility (inheritance, containers, enums),
##   - enum value lookup for contextual value autocompletion,
##   - re-scans on demand so new scripts/addons/registrations appear.
##
## Sources:
##   Builtin      built-in Variant types from the engine's API dump
##   Engine       ClassDB classes (all of them, base class recorded)
##   Extension    GDExtension / C# classes (ClassDB API_EXTENSION)
##   Custom       `class_name` scripts of the project (incl. resources)
##   Script Enum  `enum` declarations found in project scripts (with values)
##   Engine Enum  per-class engine enums from ClassDB (with values)
##   Typed        Array[T] / Dictionary[K,V] forms built from discovered types
##
## Types that cannot be verified (unknown identifiers) are never invented:
## they stay Variant and the generated script's compile check reports them.

const FuncReg = preload("func_registry.gd")
const API_JSON: String = "res://addons/gd_canvas_spikes/builtin_api.json"

# ---- Type categories -----------------------------------------------------------
const CAT_BUILTIN: String = "Builtin"
const CAT_ENGINE: String = "Engine"
const CAT_EXTENSION: String = "Extension"
const CAT_CUSTOM: String = "Custom Class"
const CAT_ENUM: String = "Enum"

static var _instance: RefCounted = null


static func get_registry() -> RefCounted:
	if _instance == null:
		_instance = load("res://addons/gd_canvas_spikes/type_registry.gd").new()
	return _instance


var types: Array[Dictionary] = []
var _by_name: Dictionary = {}
var _records: Dictionary = {}   # name -> full record (enums carry their values)
var _class_scan: Dictionary = {}   # path -> {class_name, extends, enums:{Name:[values]}}
var _providers: Array[Callable] = []

## Session caches (see func_registry.gd): the engine-side records (API dump,
## ClassDB classes and enums) are collected once and replayed; project scripts
## are re-parsed only when their modified time changes.
static var _static_records: Array = []        # API-dump types + ClassDB classes
static var _static_enum_records: Array = []   # per-class engine enums
static var _static_ready: bool = false
static var _static_enums_ready: bool = false
static var _parse_cache: Dictionary = {}   # path -> {"mt": int, "info": Dictionary}
var _recorded: Array = []
var _recording: bool = false


# ---- Public API ----------------------------------------------------------------
## Full re-scan (builtins, ClassDB, project scripts, addons, extensions).
func refresh() -> void:
	types = []
	_by_name = {}
	_records = {}
	_class_scan = {}
	_load_static_records()
	_scan_project_scripts()
	_load_static_enum_records()
	for cb: Callable in _providers:
		for e: Dictionary in cb.call():
			_add(e)


## Engine-side records: collected once per editor session, replayed afterwards.
## The original scan order is kept (builtins, ClassDB classes, project scripts,
## engine enums) because a duplicate name keeps its first record.
func _load_static_records() -> void:
	if _static_ready:
		for e: Dictionary in _static_records:
			_add(e)
		return
	_recorded = []
	_recording = true
	_load_builtins()
	_load_classdb()
	_recording = false
	_static_records = _recorded
	_recorded = []
	_static_ready = true


func _load_static_enum_records() -> void:
	if _static_enums_ready:
		for e: Dictionary in _static_enum_records:
			_add(e)
		return
	_recorded = []
	_recording = true
	_load_engine_enums()
	_recording = false
	_static_enum_records = _recorded
	_recorded = []
	_static_enums_ready = true


## External contributors (addons/tests) can register types directly.
func register_type(e: Dictionary) -> void:
	_add(e)


func register_provider(cb: Callable) -> void:
	_providers.append(cb)


func all_types() -> Array[Dictionary]:
	return types


## Case-insensitive partial-name search, best matches first.
## Returns up to `cap` records {name, cat, owner, base, kind}.
func search(query: String, cap: int = 40) -> Array[Dictionary]:
	ensure()
	var q: String = query.strip_edges().to_lower()
	var out: Array[Dictionary] = []
	if q == "":
		return out
	# typed containers: typing "Array[" suggests Array[<every known type>]
	if q.begins_with("array["):
		var elem: String = q.trim_prefix("array[").strip_edges()
		for e: Dictionary in types:
			if str(e["kind"]) != "enum":
				out.append({
					"name": "Array[%s]" % str(e["name"]), "cat": CAT_BUILTIN,
					"owner": "Array", "base": "", "kind": "typed",
				})
				if out.size() >= cap:
					return out
		return out
	if q.begins_with("dictionary["):
		var el: String = q.trim_prefix("dictionary[").strip_edges()
		for e2: Dictionary in types:
			out.append({
				"name": "Dictionary[%s, Variant]" % str(e2["name"]),
				"cat": CAT_BUILTIN, "owner": "Dictionary", "base": "", "kind": "typed",
			})
			if out.size() >= cap:
				return out
		return out
	var exact: Array[Dictionary] = []
	var prefix: Array[Dictionary] = []
	var partial: Array[Dictionary] = []
	for e3: Dictionary in types:
		var n: String = str(e3["name"]).to_lower()
		if n == q:
			exact.append(e3)
		elif n.begins_with(q):
			prefix.append(e3)
		elif n.contains(q):
			partial.append(e3)
	for group: Array[Dictionary] in [exact, prefix, partial]:
		for e4: Dictionary in group:
			out.append(e4)
			if out.size() >= cap:
				return out
	return out


## True when `name` resolves to a known type (engine, builtin or custom).
func type_exists(name: String) -> bool:
	ensure()
	var s: String = _base_name(name)
	if s == "" or s == "Variant" or s == "void":
		return true   # valid GDScript, treated as untyped
	if s.contains("."):
		return _by_name.has(s)   # enum type
	return _by_name.has(s)


## Godot-accurate assignment compatibility for full type texts.
## Empty texts mean "untyped/Variant" and accept everything.
func is_compatible(from_text: String, to_text: String) -> bool:
	var ft: String = from_text.strip_edges()
	var tt: String = to_text.strip_edges()
	if ft == "" or tt == "" or ft == "Variant" or tt == "Variant":
		return true
	if ft == tt:
		return true
	var f: String = _base_name(ft)
	var t: String = _base_name(tt)
	# typed containers: element types must be assignable (or the container untyped)
	if ft.begins_with("Array[") or ft.begins_with("Dictionary["):
		return _container_assignable(ft, tt)
	if tt.begins_with("Array[") or tt.begins_with("Dictionary["):
		if f == t:
			return true   # untyped Array -> Array[int] is not safe either
		return false   # untyped container cannot feed a typed one safely
	# enums are ints at the language level (and int -> enum is an explicit cast)
	if _is_enum(f):
		return t == "int" or t == "float" or _is_enum(t) and f == t
	if _is_enum(t):
		return f == "int"
	# int -> float is the only implicit scalar widening in GDScript
	if f == "int" and t == "float":
		return true
	# numeric values convert to bool through GDScript truthiness
	if (f == "int" or f == "float") and t == "bool":
		return true
	# object types: inheritance via ClassDB (covers engine + extension classes)
	if ClassDB.class_exists(f) and ClassDB.class_exists(t):
		return ClassDB.is_parent_class(f, t)
	# custom classes: script inheritance chain known from the scan
	var finfo: Dictionary = _class_info_of(f)
	var tinfo: Dictionary = _class_info_of(t)
	if not finfo.is_empty():
		return _script_isa(finfo, t)
	return false


## The values of an enum type ("Node.ProcessMode" or a script enum), for
## contextual value autocompletion. Empty for non-enum types.
func enum_values(type_text: String) -> Array[String]:
	ensure()
	var s: String = _base_name(type_text)
	if not _is_enum(s):
		return []
	var e: Dictionary = _records.get(s, {})
	var vals: Array[String] = []
	for v: String in e.get("values", []):
		vals.append(v)
	return vals


func _is_enum(s: String) -> bool:
	if not s.contains("."):
		return false
	var e: Dictionary = _records.get(s, {})
	return not e.is_empty() and str(e["kind"]) == "enum"


func ensure() -> void:
	if types.is_empty():
		refresh()


func _add(e: Dictionary) -> void:
	if _recording:
		_recorded.append(e)
	var n: String = str(e["name"]).strip_edges()
	if n == "":
		return
	if _by_name.has(n):
		return   # duplicate exposure: keep the first real record
	_by_name[n] = true
	var record: Dictionary = {
		"name": n,
		"cat": str(e.get("cat", CAT_ENGINE)),
		"owner": str(e.get("owner", "")),
		"base": str(e.get("base", "")),
		"kind": str(e.get("kind", "class")),
		"values": (e.get("values", []) as Array).duplicate(true),
		"script_path": str(e.get("script_path", "")),
	}
	_records[n] = record
	types.append(record)


# ---- Discovery: built-in Variant types (engine API dump) ------------------------
func _load_builtins() -> void:
	var f: FileAccess = FileAccess.open(API_JSON, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f = null
	if not (parsed is Dictionary):
		return
	for c: Dictionary in (parsed as Dictionary).get("builtin_classes", []):
		_add({"name": str(c["name"]), "cat": CAT_BUILTIN, "owner": "Godot",
			"kind": "builtin"})


# ---- Discovery: ClassDB (engine + extension classes) ----------------------------
func _load_classdb() -> void:
	for cn: String in ClassDB.get_class_list():
		var cat: String = CAT_ENGINE
		if ClassDB.class_get_api_type(cn) == ClassDB.API_EXTENSION:
			cat = CAT_EXTENSION
		elif ClassDB.class_get_api_type(cn) == ClassDB.API_EDITOR:
			continue   # editor-only classes have no runtime value
		_add({"name": cn, "cat": cat, "owner": "Godot",
			"base": ClassDB.get_parent_class(cn), "kind": "class"})


# ---- Discovery: engine enums (per class, with their constant values) ------------
func _load_engine_enums() -> void:
	for cn: String in ClassDB.get_class_list():
		if ClassDB.class_get_api_type(cn) == ClassDB.API_EDITOR:
			continue
		for en: String in ClassDB.class_get_enum_list(cn):
			_add({
				"name": "%s.%s" % [cn, en], "cat": CAT_ENUM, "owner": cn,
				"kind": "enum", "values": ClassDB.class_get_enum_constants(cn, en),
			})


# ---- Discovery: project scripts / custom classes / addons -----------------------
func _scan_project_scripts() -> void:
	var found: Dictionary = {}
	_collect_scripts("res://", found, 0)
	for path: String in found:
		var info: Dictionary = found[path]
		var cls: String = str(info["class_name"])
		if cls != "":
			_add({
				"name": cls, "cat": CAT_CUSTOM, "owner": path,
				"base": str(info["extends"]), "kind": "class",
				"script_path": path,
			})
		for en: String in info["enums"].keys():
			_add({
				"name": ("%s.%s" % [cls, en]) if cls != "" else ("%s.%s" % [path.get_file().get_basename(), en]),
				"cat": CAT_ENUM, "owner": cls if cls != "" else path,
				"kind": "enum", "values": info["enums"][en],
				"script_path": path,
			})


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
				_collect_scripts(dir_path.path_join(f), found, depth + 1)
		elif f.ends_with(".gd"):
			var path: String = dir_path.path_join(f)
			found[path] = _parse_script_file(path)
		f = dir.get_next()
	dir.list_dir_end()


## Side-effect-free source parse: `class_name`, `extends` and top-level `enum`
## declarations with their constant names (annotation-usable types only —
## scripts without class_name cannot be used as type annotations in GDScript).
func _parse_script_file(path: String) -> Dictionary:
	var mt: int = FileAccess.get_modified_time(path)
	var hit: Variant = _parse_cache.get(path)
	if hit is Dictionary and int((hit as Dictionary)["mt"]) == mt:
		return (hit as Dictionary)["info"] as Dictionary
	var info: Dictionary = {"class_name": "", "extends": "", "enums": {}}
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return info
	var lines: PackedStringArray = f.get_as_text().split("\n")
	f = null
	for ln: String in lines:
		var s: String = ln.strip_edges()
		if s.begins_with("class_name "):
			info["class_name"] = s.trim_prefix("class_name ").strip_edges().split(" ")[0]
		elif s.begins_with("extends "):
			if str(info["extends"]) == "":
				info["extends"] = s.substr(8).strip_edges().split(" ")[0]
		elif s.begins_with("enum "):
			var ename: String = s.trim_prefix("enum ").strip_edges()
			var brace: int = ename.find("{")
			if brace >= 0:
				ename = ename.substr(0, brace).strip_edges()
			var vals: Array[String] = []
			for part: String in s.substr(s.find("{") + 1).split(","):
				part = part.strip_edges().trim_suffix("}").strip_edges()
				if part == "" or part.contains("=") or part.contains("}"):
					part = part.split("=")[0].strip_edges()
				if part.is_valid_identifier() and not _is_keyword(part):
					vals.append(part)
				if part.contains("}"):
					break
			if ename.is_valid_identifier() and not vals.is_empty():
				info["enums"][ename] = vals
	_parse_cache[path] = {"mt": mt, "info": info}
	return info


func _is_keyword(s: String) -> bool:
	return s in ["pass", "extends", "var", "const", "func", "static"]


# ---- Helpers --------------------------------------------------------------------
## Strips generic parameters: "Array[int]" -> "Array", "Dictionary[String, int]"
## -> "Dictionary", enum texts stay whole (they contain dots, not brackets).
func _base_name(text: String) -> String:
	var s: String = text.strip_edges()
	if s.begins_with("Array[") or s.begins_with("Dictionary["):
		return s.substr(0, s.find("["))
	return s


func _container_assignable(f: String, t: String) -> bool:
	if t == _base_name(f):
		return true   # Array -> Array[int]: untyped accepts typed
	if t.begins_with("Array[") and f.begins_with("Array["):
		var fe: String = f.trim_prefix("Array[").trim_suffix("]")
		var te: String = t.trim_prefix("Array[").trim_suffix("]")
		return fe == te or fe == "Variant" or _is_enum(fe) and te == "int"
	if t.begins_with("Dictionary[") and f.begins_with("Dictionary["):
		var fp: PackedStringArray = f.trim_prefix("Dictionary[").trim_suffix("]").split(",")
		var tp: PackedStringArray = t.trim_prefix("Dictionary[").trim_suffix("]").split(",")
		if fp.size() != tp.size():
			return false
		for i: int in fp.size():
			var a: String = fp[i].strip_edges()
			var b: String = tp[i].strip_edges()
			if not (a == b or a == "Variant"):
				return false
		return true
	return false


func _class_info_of(name: String) -> Dictionary:
	ensure()
	for e: Dictionary in types:
		if str(e["name"]) == name and str(e["kind"]) == "class" \
				and str(e["cat"]) == CAT_CUSTOM:
			return e
	return {}


## Does the custom class (or its script inheritance chain) derive from `t`?
func _script_isa(info: Dictionary, target: String) -> bool:
	var cur: String = str(info["base"])
	var hops: int = 0
	while cur != "" and hops < 12:
		hops += 1
		if cur == target:
			return true
		if ClassDB.class_exists(cur) and ClassDB.is_parent_class(cur, target):
			return true
		var next: Dictionary = _class_info_of(cur)
		if next.is_empty():
			return false
		cur = str(next["base"])
	return false
