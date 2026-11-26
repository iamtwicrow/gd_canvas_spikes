@tool
extends GraphNode
## Read-only "Error" / "Warning" node (display only).
##
## When a node of the graph has errors or warnings, that node grows an "error"
## and / or "warning" output pin (see graph_node.gd, set_diagnostics) and the
## canvas spawns one of these nodes per severity, wired to that pin. The node
## lists every message of that severity, with the generated line number.
##
## These nodes are NOT part of the graph model: they are never saved, never
## generated, never counted as graph nodes and never persisted. They appear and
## disappear with the problems themselves. graph_canvas.gd loads this file
## lazily, so a failure here can never break the workspace.

const Types = preload("graph_types.gd")
const UiStyle = preload("ui_style.gd")

const SEV_ERROR: String = "error"
const SEV_WARNING: String = "warning"
const BODY_W: float = 260.0
## More messages than this are summarised as "... and N more" (the tooltip
## always holds the complete list).
const MAX_SHOWN: int = 12

## "error" or "warning".
var severity: String = SEV_ERROR
## Model id of the node this one reports on.
var source_id: int = -1
## True once the canvas has positioned it (a later layout pass re-places it).
var placed: bool = false

var _sig: String = ""
var _body: Label = null
var _copy_btn: Button = null
var _glyph: Control = null
var _copied_lbl: Label = null
var _copy_gen: int = 0
var _full_text: String = ""
var _font: Font = null
var _font_size: int = 13


## Builds the node on first use and refreshes its text on every later call, so
## an existing node (and a position the person dragged it to) survives edits.
func setup(sev: String, src_id: int, src_title: String, items: Array, font: Font,
		font_size: int) -> void:
	severity = sev
	source_id = src_id
	_font = font
	_font_size = font_size
	var is_error: bool = sev == SEV_ERROR
	name = "dg_%s%d" % ["e" if is_error else "w", src_id]
	var sig: String = "%s|%s|%s" % [sev, src_title, JSON.stringify(items)]
	if _body == null:
		_build(is_error)
	if sig == _sig:
		return
	_sig = sig
	var noun: String = "Error" if is_error else "Warning"
	title = noun if items.size() <= 1 else "%d %ss" % [items.size(), noun]
	var full: String = _text_for(items, items.size())
	_full_text = full
	_body.text = _text_for(items, MAX_SHOWN)
	var tip: String = full
	if src_title != "":
		tip = "%s on '%s'\n%s" % [noun, src_title, full]
	_body.tooltip_text = tip
	tooltip_text = tip
	# the node's height follows its text
	size = Vector2(size.x, 0.0)


func _build(is_error: bool) -> void:
	var color: Color = Types.ERROR_COLOR if is_error else Types.WARNING_COLOR
	resizable = false
	selectable = true
	draggable = true
	add_theme_constant_override("separation", 6)
	add_theme_color_override("title_color", Types.HEADER_FG)
	add_theme_font_size_override("title_font_size", UiStyle.FONT_SIZE_TITLE)
	add_theme_constant_override("title_h_offset", 0)

	var tsb: Types.ChamferStyle = _titlebar_style(color.darkened(0.45), Color(0, 0, 0, 0), 0.0)
	add_theme_stylebox_override("titlebar", tsb)
	var tsel: Types.ChamferStyle = _titlebar_style(color.darkened(0.45), Types.SELECTED_COLOR, 2.0)
	tsel.border_bottom = false
	add_theme_stylebox_override("titlebar_selected", tsel)

	var bsb: Types.ChamferStyle = Types.ChamferStyle.new(Types.NODE_BG.lerp(color, 0.10), color)
	bsb.border_width = 1.5
	_body_margins(bsb)
	add_theme_stylebox_override("panel", bsb)
	var bsel: Types.ChamferStyle = Types.ChamferStyle.new(Types.NODE_BG_SELECTED, Types.SELECTED_COLOR)
	bsel.border_width = 2.0
	bsel.border_top = false
	_body_margins(bsel)
	add_theme_stylebox_override("panel_selected", bsel)

	_body = Label.new()
	_body.name = "Message"
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.custom_minimum_size = Vector2(BODY_W, 0.0)
	_body.mouse_filter = Control.MOUSE_FILTER_PASS
	if _font != null:
		_body.add_theme_font_override("font", _font)
	_body.add_theme_font_size_override("font_size", maxi(_font_size - 1, UiStyle.FONT_SIZE_SMALL))
	_body.add_theme_color_override("font_color", color.lightened(0.55))
	add_child(_body)
	# one input pin on the left; the wire comes from the reporting node's
	# "error" / "warning" output pin
	set_slot(0, true, Types.VARIANT, color, false, Types.VARIANT, Color.WHITE, null, null)

	# bottom-right copy button: puts the message text on the clipboard
	var bar: HBoxContainer = HBoxContainer.new()
	bar.name = "CopyBar"
	var fill: Control = Control.new()
	fill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(fill)
	_copied_lbl = Label.new()
	_copied_lbl.name = "CopiedLabel"
	_copied_lbl.text = "Copied!"
	_copied_lbl.visible = false
	_copied_lbl.add_theme_font_size_override("font_size", UiStyle.FONT_SIZE_SMALL + 1)
	_copied_lbl.add_theme_color_override("font_color", Color(0.45, 0.9, 0.55))
	bar.add_child(_copied_lbl)
	_copy_btn = Button.new()
	_copy_btn.name = "CopyButton"
	_copy_btn.flat = true
	_copy_btn.focus_mode = Control.FOCUS_NONE
	_copy_btn.tooltip_text = "Copy the message"
	_copy_btn.custom_minimum_size = Vector2(26.0, 22.0)
	var glyph: CopyGlyph = CopyGlyph.new()
	glyph.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_copy_btn.add_child(glyph)
	_glyph = glyph
	_copy_btn.pressed.connect(_on_copy_pressed)
	bar.add_child(_copy_btn)
	add_child(bar)


func _titlebar_style(bg: Color, border: Color, width: float) -> Types.ChamferStyle:
	var sb: Types.ChamferStyle = Types.ChamferStyle.new(bg, border)
	sb.border_width = width
	sb.cut_bottom_left = false
	sb.cut_bottom_right = false
	sb.content_margin_left = 8.0
	sb.content_margin_right = 8.0
	sb.content_margin_top = 4.0
	sb.content_margin_bottom = 4.0
	return sb


func _body_margins(sb: Types.ChamferStyle) -> void:
	sb.content_margin_left = 8.0
	sb.content_margin_right = 8.0
	sb.content_margin_bottom = 6.0
	sb.cut_top_left = false
	sb.cut_top_right = false


## "L12: message" per problem (no line prefix when the line is unknown).
func _text_for(items: Array, limit: int) -> String:
	var lines: PackedStringArray = PackedStringArray()
	for i: int in mini(items.size(), limit):
		var d: Dictionary = items[i] as Dictionary
		var ln: int = int(d.get("line", -1))
		var prefix: String = "L%d: " % ln if ln > 0 else ""
		lines.append(prefix + str(d.get("message", "")))
	if items.size() > limit:
		lines.append("... and %d more" % (items.size() - limit))
	return "\n".join(lines)


func _on_copy_pressed() -> void:
	DisplayServer.clipboard_set(_full_text)
	# visible confirmation: green check + "Copied!" for a moment
	_copy_gen += 1
	var gen: int = _copy_gen
	_set_copied(true)
	if is_inside_tree():
		get_tree().create_timer(1.5).timeout.connect(func() -> void:
			if gen == _copy_gen:
				_set_copied(false))


func _set_copied(on: bool) -> void:
	if _copied_lbl != null and is_instance_valid(_copied_lbl):
		_copied_lbl.visible = on
	if _glyph != null and is_instance_valid(_glyph):
		_glyph.set("copied", on)
		_glyph.queue_redraw()
	if _copy_btn != null and is_instance_valid(_copy_btn):
		_copy_btn.tooltip_text = "Copied to clipboard" if on else "Copy the message"
	size = Vector2(size.x, 0.0)


## Text the copy button puts on the clipboard.
func copy_text() -> String:
	return _full_text


## Small "copy" glyph (two overlapping sheets) drawn in code, so it looks the
## same everywhere and does not depend on the editor theme.
class CopyGlyph extends Control:
	var copied: bool = false

	func _draw() -> void:
		if copied:
			var g: Color = Color(0.45, 0.9, 0.55)
			var m: Vector2 = size * 0.5
			draw_polyline(PackedVector2Array([m + Vector2(-5.0, 0.0), m + Vector2(-1.5, 4.0),
				m + Vector2(5.5, -4.5)]), g, 2.2, true)
			return
		var c: Color = Color(0.86, 0.88, 0.92)
		var o: Vector2 = (size - Vector2(12.0, 14.0)) * 0.5
		var back: Rect2 = Rect2(o + Vector2(3.0, 0.0), Vector2(9.0, 10.0))
		var front: Rect2 = Rect2(o + Vector2(0.0, 4.0), Vector2(9.0, 10.0))
		draw_rect(back, c.darkened(0.25), false, 1.5)
		draw_rect(front, Color(0.11, 0.12, 0.13), true)
		draw_rect(front, c, false, 1.5)
		draw_line(front.position + Vector2(2.5, 4.0), front.position + Vector2(6.5, 4.0), c, 1.0)
		draw_line(front.position + Vector2(2.5, 7.0), front.position + Vector2(6.5, 7.0), c, 1.0)
