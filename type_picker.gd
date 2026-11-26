extends PanelContainer
## Categorized type picker (reference: data_type_slection_manu.png): a dark
## panel listing the graph's supported pin types grouped into categories;
## picking a chip applies it to the opening field. Hosted on a CanvasLayer
## (like the type-suggest popup) so it always renders above the graph and
## is not clipped by the node it belongs to.

signal type_picked(tname: String)

const Types = preload("res://addons/gd_canvas_spikes/graph_types.gd")
const UiStyle = preload("res://addons/gd_canvas_spikes/ui_style.gd")
const TypeIcons = preload("res://addons/gd_canvas_spikes/type_icons.gd")

## Chip groups in reference order. Values are GDScript type names as they
## appear in generated code; every entry maps to a supported model pin type.
const GROUPS: Array = [
	["Basic", ["bool", "int", "float", "String"]],
	["Structured", ["Vector2", "Vector3", "Color"]],
	["Collections", ["Array", "Dictionary"]],
	["Engine", ["Object"]],
	["Any", ["Variant"]],
]

const NAME_TO_PIN: Dictionary[String, int] = {
	"bool": Types.PinType.BOOL,
	"int": Types.PinType.INT,
	"float": Types.PinType.FLOAT,
	"String": Types.PinType.STRING,
	"Vector2": Types.PinType.VECTOR2,
	"Vector3": Types.PinType.VECTOR3,
	"Color": Types.PinType.COLOR,
	"Object": Types.PinType.OBJECT,
	"Array": Types.PinType.ARRAY,
	"Dictionary": Types.PinType.DICTIONARY,
	"Variant": Types.PinType.VARIANT,
}


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	add_theme_stylebox_override("panel", UiStyle.popup_box(8.0))
	custom_minimum_size = Vector2(232, 0)
	var v: VBoxContainer = VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	add_child(v)
	var head: Label = Label.new()
	head.text = "Data Type"
	head.add_theme_font_size_override("font_size", UiStyle.FONT_SIZE)
	head.add_theme_color_override("font_color", UiStyle.TEXT_DIM)
	head.add_theme_stylebox_override("normal", UiStyle.flat(UiStyle.BAR_BG, Color(0, 0, 0, 0), 0, 0, 6.0, 3.0))
	v.add_child(head)
	for g: Array in GROUPS:
		var h: Label = Label.new()
		h.text = str(g[0])
		h.add_theme_font_size_override("font_size", UiStyle.FONT_SIZE_SMALL)
		h.add_theme_color_override("font_color", UiStyle.TEXT_MUTED)
		v.add_child(h)
		var flow: HFlowContainer = HFlowContainer.new()
		flow.add_theme_constant_override("h_separation", 4)
		flow.add_theme_constant_override("v_separation", 4)
		v.add_child(flow)
		for tname: String in g[1]:
			flow.add_child(_chip(tname))


## One type chip, tinted with its pin type color (label text color, dark
## chip body — readable on the dark popup like the reference picker).
func _chip(tname: String) -> Button:
	var b: Button = Button.new()
	b.text = tname
	# Godot's own icon for this type (bool / int / float / Str / Vector2 ...)
	b.icon = TypeIcons.icon_for_type(tname)
	b.add_theme_constant_override("h_separation", 6)
	b.tooltip_text = _desc_for(tname)
	b.focus_mode = Control.FOCUS_NONE
	var pin: int = int(NAME_TO_PIN.get(tname, Types.PinType.VARIANT))
	var c: Color = Types.color_of(pin)
	var plain: StyleBoxFlat = UiStyle.flat(UiStyle.BUTTON_BG, Color(0, 0, 0, 0), 0, UiStyle.RADIUS, 8.0, 2.0)
	plain.border_color = c
	plain.border_width_left = 3
	var hov: StyleBoxFlat = UiStyle.flat(UiStyle.BUTTON_HOVER, Color(0, 0, 0, 0), 0, UiStyle.RADIUS, 8.0, 2.0)
	hov.border_color = c
	hov.border_width_left = 3
	b.add_theme_stylebox_override("normal", plain)
	b.add_theme_stylebox_override("hover", hov)
	b.add_theme_stylebox_override("pressed", hov)
	b.add_theme_stylebox_override("focus", plain)
	b.add_theme_color_override("font_color", UiStyle.TEXT)
	b.add_theme_color_override("font_hover_color", UiStyle.TEXT_BRIGHT)
	b.add_theme_font_size_override("font_size", UiStyle.FONT_SIZE)
	b.pressed.connect(func() -> void:
		hide()
		type_picked.emit(tname))
	return b


## One factual line per type (what the pin accepts / emits).
func _desc_for(tname: String) -> String:
	match tname:
		"bool": return "true / false"
		"int": return "Whole number"
		"float": return "Decimal number"
		"String": return "Text"
		"Vector2": return "2D point / direction (x, y)"
		"Vector3": return "3D point / direction (x, y, z)"
		"Color": return "RGBA color value"
		"Object": return "Node / resource reference"
		"Array": return "Ordered list of values"
		"Dictionary": return "Key / value map"
		"Variant": return "Any type (no restriction)"
		_: return ""
