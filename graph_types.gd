@tool
extends RefCounted
## Pin types, colors, icons and compatibility rules for the node graph.
##
## Single source of truth for the type -> color mapping: input pins, output
## pins and wires all read their color from here, so every connection is
## readable end to end (Blueprint-style). Also hosts the chamfered node
## stylebox used by all node views.

## One source line to prepend to a throw-away compile so GDScript warnings the
## user's project promotes to errors (strict typing, ...) cannot turn valid
## generated code into a failed compile. Returns "" when the project has no such
## settings (then the source is compiled untouched). Never touches settings.
static func relax_prefix() -> String:
	var names: PackedStringArray = PackedStringArray()
	for prop: Dictionary in ProjectSettings.get_property_list():
		var pname: String = str(prop.get("name", ""))
		if not pname.begins_with("debug/gdscript/warnings/"):
			continue
		var v: Variant = ProjectSettings.get_setting(pname)
		if typeof(v) == TYPE_INT and int(v) == 2 and _is_warning_name(pname.get_file()):
			names.append('"%s"' % pname.get_file())
	if names.is_empty():
		return ""
	return "@warning_ignore_start(%s)\n" % ", ".join(names)


## Warning names accepted by @warning_ignore (Godot 4.7). Unknown names, such
## as a misspelled project setting, are skipped instead of breaking the check.
const WARNING_NAMES: PackedStringArray = [
	"unassigned_variable",
	"unassigned_variable_op_assign",
	"unused_variable",
	"unused_local_constant",
	"unused_private_class_variable",
	"unused_parameter",
	"unused_signal",
	"shadowed_variable",
	"shadowed_variable_base_class",
	"shadowed_global_identifier",
	"unreachable_code",
	"unreachable_pattern",
	"standalone_expression",
	"standalone_ternary",
	"incompatible_ternary",
	"untyped_declaration",
	"inferred_declaration",
	"unsafe_property_access",
	"unsafe_method_access",
	"unsafe_cast",
	"unsafe_call_argument",
	"unsafe_void_return",
	"return_value_discarded",
	"static_called_on_instance",
	"missing_tool",
	"redundant_static_unload",
	"redundant_await",
	"missing_await",
	"assert_always_true",
	"assert_always_false",
	"integer_division",
	"narrowing_conversion",
	"int_as_enum_without_cast",
	"int_as_enum_without_match",
	"enum_variable_without_default",
	"empty_file",
	"deprecated_keyword",
	"confusable_identifier",
	"confusable_local_declaration",
	"confusable_local_usage",
	"inference_on_variant",
	"native_method_override",
	"onready_with_export",
	"property_used_as_function",
	"constant_used_as_function",
	"function_used_as_property",
]


static func _is_warning_name(wname: String) -> bool:
	return WARNING_NAMES.has(wname)


## Compiles `code` in a throw-away GDScript and returns the engine's Error.
## (When relax_prefix() adds a line, reported line numbers shift by one.)
static func compile_source(code: String) -> Error:
	var g: GDScript = GDScript.new()
	g.source_code = relax_prefix() + code
	return g.reload()


enum PinType {
	EXEC,      # execution flow (white triangles)
	BOOL,      # red
	INT,       # green
	FLOAT,     # light green
	STRING,    # pink
	VECTOR2,   # cyan
	VECTOR3,   # blue
	COLOR,     # multicolored (rainbow icon)
	OBJECT,    # purple (objects / node references)
	ARRAY,     # orange
	DICTIONARY,  # gold
	VARIANT,   # neutral fallback
	CALLABLE,  # soft orange (Callable / lambda values)
	ANNOTATION,  # purple-lilac (annotation registration wires)
	SCOPE,     # amber (private-variable scope registration wires)
	MEMBER,    # steel blue (Class Reference -> member registration wires)
}

const EXEC: int = PinType.EXEC
const BOOL: int = PinType.BOOL
const INT: int = PinType.INT
const FLOAT: int = PinType.FLOAT
const STRING: int = PinType.STRING
const VECTOR2: int = PinType.VECTOR2
const VECTOR3: int = PinType.VECTOR3
const COLOR: int = PinType.COLOR
const OBJECT: int = PinType.OBJECT
const ARRAY: int = PinType.ARRAY
const DICTIONARY: int = PinType.DICTIONARY
const VARIANT: int = PinType.VARIANT
const CALLABLE: int = PinType.CALLABLE
const ANNOTATION: int = PinType.ANNOTATION
const SCOPE: int = PinType.SCOPE
const MEMBER: int = PinType.MEMBER

## Execution style: white-ish, clearly distinct from every data color.
const EXEC_COLOR: Color = Color("#ffffff")
const EXEC_WIRE_COLOR: Color = Color("#ffffff")
## Wire thickness in screen px, measured from the reference screenshots (the
## solid core of both data and exec wires is ~3.2-3.4 px at 189-207 % zoom: it
## does not scale with zoom). GraphEdit draws every connection with one
## thickness (floor of this value), so data and exec wires share it.
const DATA_WIRE_THICKNESS: float = 3.0
const EXEC_WIRE_THICKNESS: float = 3.0

## Selection accent (the reference UI outlines selected nodes in orange) and
## the shared node chrome colors used by panels, menus and headers.
const SELECTED_COLOR: Color = Color("#e18c00")
const NODE_BG: Color = Color("#1b1e20")
const NODE_BG_SELECTED: Color = Color("#1b1e20")
const NODE_BORDER: Color = Color("#101113")
const HEADER_FG: Color = Color("#ffffff")
const CHIP_FONT_SIZE: int = 11

## Blueprint-style diagnostics: errors are red (filled circle badge, thick
## outline), warnings amber (triangle badge, thinner outline).
const ERROR_COLOR: Color = Color("#e5484d")
const WARNING_COLOR: Color = Color("#f0a020")

# ---- Centralized type -> color mapping -------------------------------------
## Every pin (input + output) and every wire of a type uses this exact color.
const TYPE_COLORS: Dictionary[int, Color] = {
	PinType.EXEC: EXEC_COLOR,
	PinType.BOOL: Color("#8ca6f0"),        # periwinkle (reference)
	PinType.INT: Color("#5ab0ff"),         # azure
	PinType.FLOAT: Color("#61d9f5"),       # cyan (reference)
	PinType.STRING: Color("#6ba6ed"),      # blue (reference)
	PinType.VECTOR2: Color("#c98cf5"),     # violet
	PinType.VECTOR3: Color("#f08cf0"),     # magenta
	PinType.COLOR: Color("#9eff70"),       # lime (reference)
	PinType.OBJECT: Color("#e0e0e0"),      # white-ish (object cube)
	PinType.ARRAY: Color("#7ee08a"),       # green
	PinType.DICTIONARY: Color("#78edb0"),  # mint (reference: Make Dictionary pin)
	PinType.VARIANT: Color("#2fe0b8"),     # teal ("Any")
	PinType.ANNOTATION: Color("#c79bf0"),  # lilac (annotation registration)
	PinType.SCOPE: Color("#e6c35c"),       # amber (private-variable scope)
	PinType.MEMBER: Color("#9fb0e8"),      # steel blue (class member registration)
}


static func type_name(t: int) -> String:
	match t:
		PinType.EXEC: return "Execution"
		PinType.BOOL: return "Boolean"
		PinType.INT: return "Integer"
		PinType.FLOAT: return "Float"
		PinType.STRING: return "String"
		PinType.VECTOR2: return "Vector2"
		PinType.VECTOR3: return "Vector3"
		PinType.COLOR: return "Color"
		PinType.OBJECT: return "Object"
		PinType.ARRAY: return "Array"
		PinType.DICTIONARY: return "Dictionary"
		PinType.ANNOTATION: return "Annotation"
		PinType.SCOPE: return "Scope"
		PinType.MEMBER: return "Member"
		PinType.CALLABLE: return "Callable"
		_: return "Variant"


## The one color lookup for pins and wires alike.
static func color_of(t: int) -> Color:
	return TYPE_COLORS.get(t, Color("#9aa0ad"))


## Short type tags shown next to pin names (Blueprint-style). Coloured with
## the pin's type colour so the tag is readable at a glance.
const TYPE_TAGS: Dictionary[int, String] = {
	PinType.BOOL: "bool",
	PinType.INT: "int",
	PinType.FLOAT: "flt",
	PinType.STRING: "Str",
	PinType.VECTOR2: "v2",
	PinType.VECTOR3: "v3",
	PinType.COLOR: "clr",
	PinType.OBJECT: "obj",
	PinType.ARRAY: "arr",
	PinType.DICTIONARY: "dict",
	PinType.VARIANT: "var",
	PinType.ANNOTATION: "ann",
	PinType.SCOPE: "scope",
	PinType.MEMBER: "member",
	PinType.CALLABLE: "fn",
}


static func type_tag(t: int) -> String:
	return TYPE_TAGS.get(t, "")


## Saturated colors for the short type tags (bool / flt / Str ...), sampled
## from the reference nodes; brighter than the pin disc colors.
const TAG_COLORS: Dictionary[int, Color] = {
	PinType.BOOL: Color("#387cff"),
	PinType.INT: Color("#00aaff"),
	PinType.FLOAT: Color("#00feff"),
	PinType.STRING: Color("#008fff"),
	PinType.VECTOR2: Color("#c070ff"),
	PinType.VECTOR3: Color("#f040f0"),
	PinType.COLOR: Color("#44ff5e"),
	PinType.OBJECT: Color("#ffffff"),
	PinType.ARRAY: Color("#44ff5e"),
	PinType.DICTIONARY: Color("#ffc030"),
	PinType.VARIANT: Color("#1fe0b0"),
	PinType.ANNOTATION: Color("#c79bf0"),
	PinType.SCOPE: Color("#e6c35c"),
	PinType.MEMBER: Color("#9fb0e8"),
	PinType.CALLABLE: Color("#f28c5c"),
}


static func tag_color_of(t: int) -> Color:
	return TAG_COLORS.get(t, color_of(t))


## May a pin of type `from_t` (output) feed a pin of type `to_t` (input)?
static func compatible(from_t: int, to_t: int) -> bool:
	if from_t == to_t:
		return true
	# Annotation wires only ever run between annotation pins: no Variant
	# fallback, so arbitrary values can never be wired into a declaration's
	# "add annotation" slot (and annotations cannot leak into value pins).
	if from_t == PinType.ANNOTATION or to_t == PinType.ANNOTATION:
		return false
	# Scope wires only ever run between scope pins: a private variable's scope
	# output registers with a scope-owning node's "add scope" input — no
	# Variant fallback, so scope wires can never leak into value pins.
	if from_t == PinType.SCOPE or to_t == PinType.SCOPE:
		return from_t == PinType.SCOPE and to_t == PinType.SCOPE
	# Member wires only ever run between member pins: a member node's "Class"
	# output registers with a Class Reference's "add member" input — no
	# Variant fallback, so member wires can never leak into value pins.
	if from_t == PinType.MEMBER or to_t == PinType.MEMBER:
		return from_t == PinType.MEMBER and to_t == PinType.MEMBER
	# Callable pins take only Callables (and Variant, checked below): a lambda
	# expression must not silently wire into an untyped int slot and the other
	# way around a typed number must not stand in for a callback.
	if from_t == PinType.CALLABLE or to_t == PinType.CALLABLE:
		if from_t == to_t:
			return true
		if from_t == PinType.VARIANT or to_t == PinType.VARIANT:
			return true   # Variant stays the universal fallback
		return false
	if from_t == PinType.VARIANT or to_t == PinType.VARIANT:
		return true
	if from_t == PinType.INT and to_t == PinType.FLOAT:
		return true  # GDScript allows implicit int -> float
	if (from_t == PinType.INT or from_t == PinType.FLOAT) and to_t == PinType.BOOL:
		return true  # GDScript truthiness: numeric values convert to bool
	return false


## GDScript type-name -> pin type (for `var x: int` annotations, param sigs,
## and the node-creation menu).
static func type_from_name(n: String) -> int:
	var s: String = n.strip_edges()
	# typed containers keep their container pin class
	if s.begins_with("Array["):
		return PinType.ARRAY
	if s.begins_with("Dictionary["):
		return PinType.DICTIONARY
	# dotted names are engine/custom enum types (ints at the language level)
	if s.contains(".") and not s.contains("("):
		return PinType.INT
	match s:
		"int": return PinType.INT
		"float": return PinType.FLOAT
		"bool": return PinType.BOOL
		"String", "string": return PinType.STRING
		"Vector2", "Vector2i": return PinType.VECTOR2
		"Vector3", "Vector3i": return PinType.VECTOR3
		"Color": return PinType.COLOR
		"Array", "PackedByteArray", "PackedInt32Array", "PackedInt64Array", \
		"PackedFloat32Array", "PackedFloat64Array", "PackedStringArray", \
		"PackedVector2Array", "PackedVector3Array": return PinType.ARRAY
		"Dictionary": return PinType.DICTIONARY
		"StringName": return PinType.STRING
		"NodePath": return PinType.STRING
		"Callable": return PinType.CALLABLE
		"void", "Signal", "RID": return PinType.VARIANT
		_:
			# Any other capitalized identifier is an object type (Node, Sprite2D,
			# custom classes...). Lowercase unknowns stay Variant.
			if s.length() > 0 and s[0] == s[0].to_upper() and s[0] != s[0].to_lower():
				return PinType.OBJECT
			return PinType.VARIANT


## All (from_type, to_type) pairs GraphEdit should accept. Registering these
## makes the editor itself reject incompatible drags before we validate.
static func valid_pairs() -> Array:
	var pairs: Array = []
	pairs.append([PinType.EXEC, PinType.EXEC])
	for t: int in [PinType.BOOL, PinType.INT, PinType.FLOAT, PinType.STRING,
			PinType.VECTOR2, PinType.VECTOR3, PinType.COLOR, PinType.OBJECT,
			PinType.ARRAY, PinType.DICTIONARY, PinType.VARIANT]:
		pairs.append([t, t])
		pairs.append([PinType.VARIANT, t])
		pairs.append([t, PinType.VARIANT])
	pairs.append([PinType.ANNOTATION, PinType.ANNOTATION])
	pairs.append([PinType.SCOPE, PinType.SCOPE])
	pairs.append([PinType.MEMBER, PinType.MEMBER])
	pairs.append([PinType.CALLABLE, PinType.CALLABLE])
	pairs.append([PinType.INT, PinType.FLOAT])
	pairs.append([PinType.INT, PinType.BOOL])
	pairs.append([PinType.FLOAT, PinType.BOOL])
	return pairs


static func default_value(t: int) -> String:
	match t:
		PinType.BOOL: return "false"
		PinType.INT: return "0"
		PinType.FLOAT: return "0.0"
		PinType.STRING: return "\"\""
		PinType.VECTOR2: return "Vector2.ZERO"
		PinType.VECTOR3: return "Vector3.ZERO"
		PinType.COLOR: return "Color.WHITE"
		PinType.ARRAY: return "[]"
		PinType.DICTIONARY: return "{}"
		_: return "null"


# ---- Port icons -------------------------------------------------------------
## Small white triangle (points right, into the node) for execution ports.
static func exec_icon() -> Texture2D:
	if _exec_icon != null:
		return _exec_icon
	_exec_icon = _make_exec_icon(Color.WHITE)
	return _exec_icon

static var _exec_icon: ImageTexture = null


## Slot icon for a data pin of type `t`: always null, so the engine draws its
## default circle tinted with color_of(t) (exactly the reference pins). The
## data-type glyph itself (Str / bool / flt / clr / dict ...) is Godot's own
## editor icon, shown next to the pin label - see type_icons.gd.
static func data_icon_for(_t: int) -> Texture2D:
	return null


static func _make_exec_icon(col: Color) -> ImageTexture:
	var img: Image = Image.create(16, 16, false, Image.FORMAT_RGBA8)
	for y: int in 16:
		for x: int in 16:
			var fx: float = float(x) + 0.5
			var fy: float = float(y) + 0.5
			if fx >= 2.0 and fx <= 13.0:
				var half: float = (fx - 2.0) * (5.5 / 11.0)
				if absf(fy - 7.5) <= half + 0.6:
					img.set_pixel(x, y, col)
	return ImageTexture.create_from_image(img)


# ---- Chamfered node shape ----------------------------------------------------
## Rectangular node with small 45-degree cut ("diamond-cut") corners, as in the
## reference nodes: every corner is a straight diagonal bevel, never an arc.
## Applied to every node's panel and titlebar. A corner whose cut_* flag is
## false stays square (titlebar bottom corners / body top corners, so the
## header and body join into one clean silhouette).
class ChamferStyle extends StyleBox:
	var bg_color: Color = Color("#1e1f24")
	var border_color: Color = Color(0, 0, 0, 0)
	var border_width: float = 1.0
	var chamfer: float = 4.0   # length of the diagonal cut along each edge, px
	var cut_top_left: bool = true
	var cut_top_right: bool = true
	var cut_bottom_left: bool = true
	var cut_bottom_right: bool = true
	var border_top: bool = true      # draw the top edge of the border
	var border_bottom: bool = true   # draw the bottom edge of the border

	func _init(bg: Color = Color("#1e1f24"), border: Color = Color(0, 0, 0, 0)) -> void:
		bg_color = bg
		border_color = border

	## Outline polygon (clockwise from the top edge). Each cut corner becomes
	## one diagonal segment; the cut is clamped so tiny rects stay valid.
	func _points(rect: Rect2) -> PackedVector2Array:
		var cut: float = clampf(chamfer, 0.0, minf(rect.size.x, rect.size.y) * 0.5)
		var b: float = border_width * 0.5
		var r: Rect2 = rect.grow(-b)
		var x0: float = r.position.x
		var y0: float = r.position.y
		var x1: float = r.end.x
		var y1: float = r.end.y
		var tl: float = cut if cut_top_left else 0.0
		var tr: float = cut if cut_top_right else 0.0
		var br: float = cut if cut_bottom_right else 0.0
		var bl: float = cut if cut_bottom_left else 0.0
		var pts: PackedVector2Array = PackedVector2Array()
		pts.append(Vector2(x0 + tl, y0))
		pts.append(Vector2(x1 - tr, y0))
		if tr > 0.0:
			pts.append(Vector2(x1, y0 + tr))
		pts.append(Vector2(x1, y1 - br))
		if br > 0.0:
			pts.append(Vector2(x1 - br, y1))
		pts.append(Vector2(x0 + bl, y1))
		if bl > 0.0:
			pts.append(Vector2(x0, y1 - bl))
		if tl > 0.0:
			pts.append(Vector2(x0, y0 + tl))
		pts.append(pts[0])   # close the outline
		return pts

	func _draw(to_canvas_item: RID, rect: Rect2) -> void:
		if rect.size.x < 2.0 or rect.size.y < 2.0:
			return   # degenerate rect: nothing drawable (avoids triangulation errors)
		var pts: PackedVector2Array = _points(rect)
		# last point repeats the first (closed outline); the fill needs it once
		var fill: PackedVector2Array = pts.duplicate()
		fill.remove_at(fill.size() - 1)
		RenderingServer.canvas_item_add_polygon(to_canvas_item, fill, PackedColorArray([bg_color]))
		if border_width > 0.0 and border_color.a > 0.0:
			RenderingServer.canvas_item_add_polyline(to_canvas_item, _outline(pts, rect),
				PackedColorArray([border_color]), border_width, true)

	## The border path: the full closed outline, or an open path without the
	## top / bottom edge, so a header + body pair share ONE selection outline
	## (the titlebar skips its bottom edge, the body skips its top edge).
	func _outline(pts: PackedVector2Array, rect: Rect2) -> PackedVector2Array:
		if border_top and border_bottom:
			return pts
		if not border_top:
			return pts.slice(1)   # drop the first segment (the top edge)
		# no bottom edge: rotate the closed path so it starts right after the
		# horizontal segment lying on the bottom line and ends before it
		var y1: float = rect.end.y - border_width * 0.5
		for i: int in range(pts.size() - 1):
			if is_equal_approx(pts[i].y, y1) and is_equal_approx(pts[i + 1].y, y1):
				var path: PackedVector2Array = pts.slice(i + 1)
				path.append_array(pts.slice(1, i + 1))
				return path
		return pts
