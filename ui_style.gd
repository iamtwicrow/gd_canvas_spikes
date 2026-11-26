@tool
extends RefCounted
## Shared visual language for the whole addon: one palette, one set of style
## factories. Nodes, the dock, the node-creation dialog, the type picker, the
## autocomplete popup and dialogs all build their StyleBoxes from here so
## they read as one tool. Palette values are sampled from the reference
## screenshots (Godot 4.7 dark editor theme + Orchestrator-style graph).

# ---- Palette -------------------------------------------------------------
const CANVAS_BG: Color = Color("#101113")      # graph background
const GRID_DOT: Color = Color("#212224")       # graph dots
const NODE_BODY: Color = Color("#1b1e20")      # node body
const NODE_EDGE: Color = Color("#101113")      # node hairline border
const PANEL_BG: Color = Color("#181b1d")       # dialogs, docks, lists
const PANEL_DEEP: Color = Color("#101113")     # recessed areas (rails, trees)
const BAR_BG: Color = Color("#202326")         # section header bars
const FIELD_BG: Color = Color("#161819")       # inputs
const BUTTON_BG: Color = Color("#35393d")      # buttons
const BUTTON_HOVER: Color = Color("#3e4348")
const BUTTON_DISABLED: Color = Color("#303336")
const ROW_SELECTED: Color = Color("#2e3134")   # selected / hovered list row
const BORDER: Color = Color("#35393d")
const ACCENT: Color = Color("#e18c00")         # selection, checkbox, toggles
const ACCENT_DIM: Color = Color("#b87505")     # focus ring on inputs
const TEXT: Color = Color("#e0e0e0")
const TEXT_BRIGHT: Color = Color("#ffffff")
const TEXT_DIM: Color = Color("#c7c8c9")
const TEXT_MUTED: Color = Color("#898b8c")
const TEXT_DISABLED: Color = Color("#6b6e70")
const LINK: Color = Color("#7fb2e0")

# ---- Metrics (one scale for every control) ------------------------------------
const RADIUS: int = 3
const NODE_RADIUS: int = 6
const FONT_SIZE: int = 13
const FONT_SIZE_SMALL: int = 11
const FONT_SIZE_TITLE: int = 14
const ROW_HEIGHT: float = 22.0

static var _check_on: ImageTexture = null
static var _check_off: ImageTexture = null


# ---- StyleBox factories ----------------------------------------------------
static func flat(bg: Color, border: Color = Color(0, 0, 0, 0), border_w: int = 0,
		radius: int = RADIUS, margin_h: float = 6.0, margin_v: float = 2.0) -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(border_w)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = margin_h
	sb.content_margin_right = margin_h
	sb.content_margin_top = margin_v
	sb.content_margin_bottom = margin_v
	return sb


## Popup / dialog surface: dark panel, hairline border, soft shadow.
static func popup_box(margin: float = 8.0) -> StyleBoxFlat:
	var sb: StyleBoxFlat = flat(PANEL_BG, BORDER, 1, RADIUS, margin, margin)
	sb.shadow_color = Color(0, 0, 0, 0.5)
	sb.shadow_size = 12
	return sb


## Text input: recessed dark field, accent ring when focused.
static func field_box(focused: bool) -> StyleBoxFlat:
	if focused:
		return flat(FIELD_BG, ACCENT_DIM, 1, 0, 6.0, 2.0)
	return flat(FIELD_BG, Color(0, 0, 0, 0), 0, 0, 6.0, 2.0)


static func button_box(state: String = "normal") -> StyleBoxFlat:
	match state:
		"hover":
			return flat(BUTTON_HOVER, Color(0, 0, 0, 0), 0, RADIUS, 8.0, 4.0)
		"pressed":
			return flat(ROW_SELECTED, ACCENT_DIM, 1, RADIUS, 8.0, 4.0)
		"disabled":
			return flat(BUTTON_DISABLED, Color(0, 0, 0, 0), 0, RADIUS, 8.0, 4.0)
		_:
			return flat(BUTTON_BG, Color(0, 0, 0, 0), 0, RADIUS, 8.0, 4.0)


## List row look. `selected` rows use the editor's tree-selection tone.
static func row_box(selected: bool = false, hover: bool = false) -> StyleBoxFlat:
	var bg: Color = Color(0, 0, 0, 0)
	if selected:
		bg = ROW_SELECTED
	elif hover:
		bg = Color(1, 1, 1, 0.05)
	return flat(bg, Color(0, 0, 0, 0), 0, 0, 4.0, 1.0)


# ---- Control stylers -----------------------------------------------------------
## Standard push button (Cancel / OK / form buttons).
static func style_button(b: Button, accent_text: bool = false) -> void:
	b.add_theme_stylebox_override("normal", button_box("normal"))
	b.add_theme_stylebox_override("hover", button_box("hover"))
	b.add_theme_stylebox_override("pressed", button_box("pressed"))
	b.add_theme_stylebox_override("disabled", button_box("disabled"))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_color_override("font_color", LINK if accent_text else TEXT_DIM)
	b.add_theme_color_override("font_hover_color", TEXT_BRIGHT)
	b.add_theme_color_override("font_pressed_color", TEXT_BRIGHT)
	b.add_theme_color_override("font_disabled_color", TEXT_DISABLED)
	b.add_theme_font_size_override("font_size", FONT_SIZE)


## Small square icon-style button (star, expand/collapse, "+").
static func style_icon_button(b: Button, active: bool = false) -> void:
	style_button(b)
	b.focus_mode = Control.FOCUS_NONE
	if active:
		b.add_theme_color_override("font_color", ACCENT)
		b.add_theme_color_override("font_hover_color", ACCENT)


## Borderless list-row button (menu items, dock rows).
static func style_row_button(b: Button, selected: bool = false) -> void:
	b.flat = false
	b.add_theme_stylebox_override("normal", row_box(selected))
	b.add_theme_stylebox_override("hover", row_box(selected, true) if not selected else row_box(true))
	b.add_theme_stylebox_override("pressed", row_box(true))
	b.add_theme_stylebox_override("focus", row_box(selected))
	b.add_theme_color_override("font_color", TEXT)
	b.add_theme_color_override("font_hover_color", TEXT_BRIGHT)
	b.add_theme_color_override("font_pressed_color", TEXT_BRIGHT)
	b.add_theme_font_size_override("font_size", FONT_SIZE)


## Input styling for LineEdit (focus ring in the accent tone).
static func style_line_edit(e: LineEdit) -> void:
	e.add_theme_stylebox_override("normal", field_box(false))
	e.add_theme_stylebox_override("focus", field_box(true))
	e.add_theme_stylebox_override("read_only", field_box(false))
	e.add_theme_color_override("font_color", TEXT)
	e.add_theme_color_override("font_placeholder_color", TEXT_DISABLED)
	e.add_theme_color_override("caret_color", TEXT_BRIGHT)


## Section header bar ("Search:", "Matches:", "Description:" ...).
static func section_label(text: String) -> Label:
	var l: Label = Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", FONT_SIZE)
	l.add_theme_color_override("font_color", TEXT_DIM)
	l.add_theme_stylebox_override("normal", flat(BAR_BG, Color(0, 0, 0, 0), 0, 0, 6.0, 3.0))
	return l


## Plain heading (no bar), used on the left rail like the reference.
static func rail_label(text: String) -> Label:
	var l: Label = Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", FONT_SIZE)
	l.add_theme_color_override("font_color", TEXT_DIM)
	l.add_theme_stylebox_override("normal", flat(BAR_BG, Color(0, 0, 0, 0), 0, 0, 6.0, 3.0))
	return l


## Recessed list area behind trees / rails.
static func list_panel(deep: bool = false) -> PanelContainer:
	var p: PanelContainer = PanelContainer.new()
	p.add_theme_stylebox_override("panel",
		flat(PANEL_DEEP if deep else PANEL_BG, Color(0, 0, 0, 0), 0, 0, 0.0, 0.0))
	return p


## Checkbox icons: orange filled box with a check vs dark empty box, as in
## the reference nodes. Generated once and cached.
static func style_check_box(cb: CheckBox) -> void:
	if _check_on == null:
		_check_on = _make_check(true)
		_check_off = _make_check(false)
	cb.add_theme_icon_override("checked", _check_on)
	cb.add_theme_icon_override("unchecked", _check_off)
	cb.add_theme_icon_override("checked_disabled", _check_on)
	cb.add_theme_icon_override("unchecked_disabled", _check_off)
	cb.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	cb.add_theme_stylebox_override("hover", StyleBoxEmpty.new())
	cb.add_theme_stylebox_override("pressed", StyleBoxEmpty.new())
	cb.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


static func _make_check(on: bool) -> ImageTexture:
	var sz: int = 20
	var img: Image = Image.create(sz, sz, false, Image.FORMAT_RGBA8)
	var fill: Color = ACCENT if on else FIELD_BG
	var edge: Color = ACCENT if on else BORDER
	for y: int in sz:
		for x: int in sz:
			var inside: bool = x >= 2 and x < sz - 2 and y >= 2 and y < sz - 2
			if not inside:
				continue
			var corner: bool = (x < 4 or x >= sz - 4) and (y < 4 or y >= sz - 4)
			if corner and not ((x == 3 or x == sz - 4) and (y == 3 or y == sz - 4)):
				continue
			var rim: bool = x == 2 or x == sz - 3 or y == 2 or y == sz - 3
			img.set_pixel(x, y, edge if rim else fill)
	if on:
		# check mark: two short strokes
		var white: Color = Color("#fff4dc")
		var pts: Array[Vector2i] = [
			Vector2i(5, 10), Vector2i(6, 11), Vector2i(7, 12), Vector2i(8, 13),
			Vector2i(9, 12), Vector2i(10, 11), Vector2i(11, 10), Vector2i(12, 9),
			Vector2i(13, 8), Vector2i(14, 7)]
		for p: Vector2i in pts:
			img.set_pixel(p.x, p.y, white)
			img.set_pixel(p.x, p.y + 1, white)
	return ImageTexture.create_from_image(img)
