@tool
extends RefCounted
## Native Godot data-type icons for the whole addon.
##
## Every type glyph shown by the addon (pin type indicators on nodes, the type
## picker chips, the type autocomplete rows, the type input fields) comes from
## here, and every icon returned is one of the editor's OWN theme icons
## ("EditorIcons" type: bool, int, float, String ("Str"), Color ("clr"),
## Dictionary ("dict"), Vector2, Object, Variant, Node, Sprite2D ...) - or, for
## a custom class, the icon its `class_name` script declares (@icon) - or the
## icon of the nearest ancestor class. Nothing is drawn or invented here.
##
## Resolution order for a type name:
##   1. the editor theme icon with exactly that name (all builtin Variant
##      types and every native/extension class)
##   2. custom `class_name` classes: their own @icon, else the icon of their
##      base class (walking the script inheritance chain)
##   3. native classes without a dedicated icon: the nearest ancestor's icon
##   4. enum types (dotted names): the "Enum" icon, else "int"
##   5. null - the caller shows no icon rather than a wrong one
##
## Outside the editor (headless tests, exported tool runs) there is no editor
## theme: every lookup returns null and the icon slots simply stay empty.

const Types = preload("graph_types.gd")
const TypeReg = preload("type_registry.gd")

const ICON_TYPE: String = "EditorIcons"
const MAX_HOPS: int = 16

## Canonical native type name for each pin class; used when a pin carries no
## more specific type text (a plain "Vector2" pin may really be Vector2i: the
## precise text, when the model has it, always wins).
const PIN_TYPE_NAMES: Dictionary[int, String] = {
	Types.PinType.BOOL: "bool",
	Types.PinType.INT: "int",
	Types.PinType.FLOAT: "float",
	Types.PinType.STRING: "String",
	Types.PinType.VECTOR2: "Vector2",
	Types.PinType.VECTOR3: "Vector3",
	Types.PinType.COLOR: "Color",
	Types.PinType.OBJECT: "Object",
	Types.PinType.ARRAY: "Array",
	Types.PinType.DICTIONARY: "Dictionary",
	Types.PinType.CALLABLE: "Callable",
	Types.PinType.VARIANT: "Variant",
}

static var _cache: Dictionary[String, Texture2D] = {}


## The editor theme, or null when not running inside the editor.
static func editor_theme() -> Theme:
	if not Engine.is_editor_hint():
		return null
	return EditorInterface.get_editor_theme()


## Drops cached lookups (call after an editor theme / scale change or when
## the project's class list changed).
static func clear_cache() -> void:
	_cache.clear()


## Type text -> the name an icon is looked up under: typed containers use
## their container's icon (Array[int] -> Array, Dictionary[String, int] ->
## Dictionary), like the editor itself.
static func icon_key(type_text: String) -> String:
	var s: String = type_text.strip_edges()
	if s.begins_with("Array["):
		return "Array"
	if s.begins_with("Dictionary["):
		return "Dictionary"
	return s


## Godot has no dedicated `void` glyph: the neutral Variant icon is the
## honest stand-in so the Return Type field looks consistent with other
## types instead of showing nothing.
static func _icon_key_or_void(key: String) -> String:
	if key == "":
		return ""
	if key == "void":
		return "Variant"
	return key


## The editor icon name that `type_text` resolves to ("" when none). Cheap
## enough to call per pin; also used as the stable id tests compare.
static func icon_name_for(type_text: String) -> String:
	var t: Theme = editor_theme()
	var key: String = _icon_key_or_void(icon_key(type_text))
	if key == "":
		return ""
	if t == null:
		# No theme: still report the canonical built-in name so callers (and
		# tests) can tell which glyph WOULD be shown.
		return key if _is_builtin_name(key) else ""
	return _resolve_name(t, key, 0)


## Native icon for a GDScript type text such as "int", "Vector2i", "Node2D",
## "Array[int]" or a custom class name. Null when there is no honest match.
static func icon_for_type(type_text: String) -> Texture2D:
	var t: Theme = editor_theme()
	if t == null:
		return null
	var key: String = _icon_key_or_void(icon_key(type_text))
	if key == "":
		return null
	if _cache.has(key):
		return _cache[key]
	var tex: Texture2D = _resolve_texture(t, key, 0)
	_cache[key] = tex
	return tex


## Icon for a pin. The precise type text wins; otherwise the pin class's
## canonical type. Execution and annotation pins have no data-type icon.
static func icon_for_pin(pin_type: int, type_text: String = "") -> Texture2D:
	var tex: Texture2D = null
	if type_text.strip_edges() != "":
		tex = icon_for_type(type_text)
		if tex != null:
			return tex
	var canonical: String = pin_type_name(pin_type)
	if canonical == "":
		return null
	return icon_for_type(canonical)


## Icon name for a pin (same rules as icon_for_pin).
static func icon_name_for_pin(pin_type: int, type_text: String = "") -> String:
	if type_text.strip_edges() != "":
		var n: String = icon_name_for(type_text)
		if n != "":
			return n
	var canonical: String = pin_type_name(pin_type)
	return icon_name_for(canonical) if canonical != "" else ""


## Canonical native type name of a pin class ("" for exec / annotation pins).
static func pin_type_name(pin_type: int) -> String:
	return PIN_TYPE_NAMES.get(pin_type, "")


# ---- Resolution ---------------------------------------------------------------
static func _is_builtin_name(key: String) -> bool:
	return key in PIN_TYPE_NAMES.values() or ClassDB.class_exists(key) \
		or _builtin_variant_names().has(key)


static func _builtin_variant_names() -> PackedStringArray:
	return PackedStringArray(["Vector2i", "Vector3i", "Vector4", "Vector4i", "Rect2",
		"Rect2i", "Transform2D", "Transform3D", "Basis", "Quaternion", "AABB", "Plane",
		"Projection", "StringName", "NodePath", "RID", "Callable", "Signal",
		"PackedByteArray", "PackedInt32Array", "PackedInt64Array", "PackedFloat32Array",
		"PackedFloat64Array", "PackedStringArray", "PackedVector2Array",
		"PackedVector3Array", "PackedVector4Array", "PackedColorArray"])


static func _is_enum_name(key: String) -> bool:
	return key.contains(".") and not key.contains("(")


## Name of the first existing editor icon among `names`, else "".
static func _first_existing(t: Theme, names: Array[String]) -> String:
	for n: String in names:
		if t.has_icon(n, ICON_TYPE):
			return n
	return ""


## Resolves the editor-icon NAME for a key (custom class @icon files have no
## theme name: they resolve to their own class name).
static func _resolve_name(t: Theme, key: String, hops: int) -> String:
	if hops > MAX_HOPS:
		return ""
	if _is_enum_name(key):
		return _first_existing(t, ["Enum", "int"])
	if t.has_icon(key, ICON_TYPE):
		return key
	var gc: Dictionary = global_class(key)
	if not gc.is_empty():
		if str(gc.get("icon", "")) != "":
			return key
		return _resolve_name(t, str(gc.get("base", "")), hops + 1)
	if ClassDB.class_exists(key):
		var p: String = ClassDB.get_parent_class(key)
		while p != "":
			if t.has_icon(p, ICON_TYPE):
				return p
			p = ClassDB.get_parent_class(p)
	return ""


static func _resolve_texture(t: Theme, key: String, hops: int) -> Texture2D:
	if hops > MAX_HOPS:
		return null
	if _is_enum_name(key):
		var en: String = _first_existing(t, ["Enum", "int"])
		return t.get_icon(en, ICON_TYPE) if en != "" else null
	if t.has_icon(key, ICON_TYPE):
		return t.get_icon(key, ICON_TYPE)
	var gc: Dictionary = global_class(key)
	if not gc.is_empty():
		var icon_path: String = str(gc.get("icon", ""))
		if icon_path != "" and ResourceLoader.exists(icon_path):
			var res: Resource = load(icon_path)
			if res is Texture2D:
				return res as Texture2D
		return _resolve_texture(t, str(gc.get("base", "")), hops + 1)
	if ClassDB.class_exists(key):
		var p: String = ClassDB.get_parent_class(key)
		while p != "":
			if t.has_icon(p, ICON_TYPE):
				return t.get_icon(p, ICON_TYPE)
			p = ClassDB.get_parent_class(p)
	return null


## The project's `class_name` entry for `class_key` ({class, base, icon,
## path, language}) or {}. Falls back to the addon's own type registry for
## scripts the editor has not registered yet.
static func global_class(class_key: String) -> Dictionary:
	for entry: Dictionary in ProjectSettings.get_global_class_list():
		if str(entry.get("class", "")) == class_key:
			return entry
	var reg: RefCounted = TypeReg.get_registry()
	for rec: Dictionary in reg.all_types():
		if str(rec["name"]) == class_key and str(rec["kind"]) == "class" \
				and str(rec["cat"]) == "Custom Class":
			return {"class": class_key, "base": str(rec["base"]), "icon": ""}
	return {}


## A ready-to-add 16x16 icon control for `type_text` / pin type (null icon =
## empty control, so rows keep their geometry and can be updated in place).
static func make_icon_rect(icon: Texture2D, size_px: float = 16.0) -> TextureRect:
	var tr: TextureRect = TextureRect.new()
	apply_icon(tr, icon, size_px)
	return tr


static func apply_icon(tr: TextureRect, icon: Texture2D, size_px: float = 16.0) -> void:
	tr.texture = icon
	tr.custom_minimum_size = Vector2(size_px, size_px)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tr.mouse_filter = Control.MOUSE_FILTER_PASS
