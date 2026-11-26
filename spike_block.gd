@tool
extends Panel
## One code block for the zoom spike. The CodeEdit is created lazily so the
## canvas can virtualise (only visible, sufficiently zoomed blocks pay for it).

const PAD: float = 8.0
const HEADER_H: float = 26.0
const KEYWORDS: Array[String] = [
	"if", "elif", "else", "for", "while", "match", "break", "continue", "pass", "return",
	"class", "class_name", "extends", "is", "in", "as", "self", "signal", "func", "static",
	"const", "enum", "var", "await", "assert", "true", "false", "null", "not", "and", "or",
	"void", "super",
]

var code_text: String = ""
var content_size: Vector2 = Vector2.ZERO   # code area size at zoom 1
var font: Font
var font_size: int = 14
var code: CodeEdit = null
var line_bars: PackedFloat32Array = PackedFloat32Array()  # 0..1 widths for the LOD placeholder

var _header: Label
var _dragging: bool = false
var _drag_offset: Vector2 = Vector2.ZERO


static func make_highlighter() -> CodeHighlighter:
	var hl: CodeHighlighter = CodeHighlighter.new()
	hl.number_color = Color("#d19a66")
	hl.symbol_color = Color("#abb2bf")
	hl.function_color = Color("#61afef")
	hl.member_variable_color = Color("#e5c07b")
	for kw: String in KEYWORDS:
		hl.add_keyword_color(kw, Color("#c678dd"))
	hl.add_color_region("#", "", Color("#5c6370"), true)
	hl.add_color_region("\"", "\"", Color("#98c379"))
	hl.add_color_region("'", "'", Color("#98c379"))
	return hl


func setup(title_text: String, text: String, content: Vector2, p_font: Font, p_font_size: int, bars: PackedFloat32Array) -> void:
	code_text = text
	content_size = content
	font = p_font
	font_size = p_font_size
	line_bars = bars
	size = Vector2(content.x + PAD * 2.0, content.y + HEADER_H + PAD)

	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = Color("#1e1f24")
	sb.border_color = Color("#3a3d47")
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	add_theme_stylebox_override("panel", sb)

	_header = Label.new()
	_header.text = title_text
	_header.position = Vector2(PAD, 4.0)
	_header.size = Vector2(size.x - PAD * 2.0, HEADER_H - 6.0)
	_header.clip_text = true
	_header.mouse_filter = Control.MOUSE_FILTER_STOP
	_header.mouse_default_cursor_shape = Control.CURSOR_MOVE
	_header.add_theme_font_size_override("font_size", 12)
	_header.add_theme_color_override("font_color", Color("#9aa0ad"))
	_header.gui_input.connect(_on_header_input)
	add_child(_header)


func set_detail(on: bool) -> void:
	if on == (code != null):
		return
	if on:
		code = CodeEdit.new()
		code.position = Vector2(PAD, HEADER_H)
		code.size = content_size
		code.add_theme_font_override("font", font)
		code.add_theme_font_size_override("font_size", font_size)
		code.text = code_text
		code.syntax_highlighter = make_highlighter()
		code.gutters_draw_line_numbers = true
		add_child(code)
	else:
		code.queue_free()
		code = null
	queue_redraw()


## "Crisp" mode: render the text at its real on-screen pixel size.
## The CodeEdit gets a font size of base*zoom and a counter-scale of 1/zoom,
## so after the canvas applies `zoom` the glyphs are drawn 1:1 (no bitmap stretch).
func apply_crisp(zoom: float, on: bool) -> void:
	if code == null:
		return
	if on and absf(zoom - 1.0) > 0.01:
		code.add_theme_font_size_override("font_size", maxi(6, roundi(font_size * zoom)))
		code.size = content_size * zoom
		code.scale = Vector2.ONE / zoom
	else:
		code.add_theme_font_size_override("font_size", font_size)
		code.size = content_size
		code.scale = Vector2.ONE


func _draw() -> void:
	if code != null:
		return
	# Cheap placeholder used when zoomed out or not yet realised.
	var y: float = HEADER_H + 4.0
	var max_bars: int = mini(line_bars.size(), 16)
	for i: int in max_bars:
		var bw: float = line_bars[i] * content_size.x
		if bw > 0.0:
			draw_rect(Rect2(PAD + 4.0, y, bw, 5.0), Color(1, 1, 1, 0.10))
		y += 9.0


func _on_header_input(event: InputEvent) -> void:
	var host: CanvasItem = get_parent() as CanvasItem
	if host == null:
		return
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
			if _dragging:
				# Measure in the parent's (scaled) space so the block stays under the cursor at any zoom.
				_drag_offset = host.get_local_mouse_position() - position
				move_to_front()
			_header.accept_event()
	elif event is InputEventMouseMotion and _dragging:
		position = host.get_local_mouse_position() - _drag_offset
		_header.accept_event()
