@tool
extends RefCounted
## Reusable, focus-preserving autocomplete popup for any LineEdit in the
## addon (type selectors, pin value fields, enum-typed inputs...).
##
## One shared component everywhere — there are no separate per-node menus.
## Its behaviour and look deliberately mirror the canvas context menu
## (graph_canvas.gd `_build_menu` / `_on_menu_search_input` /
## `_menu_move_selection` / `_menu_wheel_guard`):
##   - suggestions appear while typing (case-insensitive partial matching),
##   - Up/Down navigate with wrapping and honor key repeats (hold to move),
##     Enter picks the highlighted row, Escape closes,
##   - mouse hover selects a row, click picks it, and the list scrolls with
##     the wheel normally — the wheel is only swallowed at the scroll limits
##     so it can never zoom or pan the graph underneath,
##   - the input control is never recreated; only suggestion rows rebuild,
##   - the popup lives on a CanvasLayer so it always renders above graph
##     nodes, wires and highlights, and is clamped to the visible window
##     (it flips above the input when there is no room below).
##   - the scroll list has a fixed minimum size (like the context menu), so
##     popup geometry never goes stale between a row rebuild and the next
##     layout pass — the scrollbar always stays inside the panel border.

signal picked(text: String)

const UiStyle = preload("ui_style.gd")
const TypeIcons = preload("type_icons.gd")

var edit: Control = null                  # LineEdit or CodeEdit/TextEdit
var source: Callable = Callable()        # query -> Array[String]
var max_rows: int = 200
## True for type pickers: each row shows Godot's native icon for its type
## (rows that are not a known type simply show no icon).
var type_icons: bool = false
var _is_text_edit: bool = false           # CodeEdit / TextEdit (no-arg text_changed)

var panel: PanelContainer = null
var list: VBoxContainer = null
var scroll: ScrollContainer = null
var rows: Array[Button] = []
var sel: int = -1
var _visible_now: bool = false
var _suppress_hide: int = 0
var _plain_style: StyleBoxFlat = null
var _hov_style: StyleBoxFlat = null
var _sel_style: StyleBoxFlat = null
var _own_layer: CanvasLayer = null


func attach(target: LineEdit, suggestion_source: Callable) -> void:
	_unwatch_current()
	detach()
	edit = target
	_is_text_edit = false
	source = suggestion_source
	_build_popup()

	edit.text_changed.connect(_on_text_changed)
	edit.gui_input.connect(_on_edit_input)
	edit.focus_exited.connect(_on_focus_exited)


## Attaches to a CodeEdit/TextEdit (e.g. the workspace script editor) so
## `@` annotation autocomplete works wherever declarations are edited.
func attach_code_edit(target: TextEdit, suggestion_source: Callable) -> void:
	_unwatch_current()
	detach()
	edit = target
	_is_text_edit = true
	source = suggestion_source
	_build_popup()
	target.text_changed.connect(_on_text_changed_te)
	target.gui_input.connect(_on_edit_input)
	target.focus_exited.connect(_on_focus_exited)


## Drops the previous edit's tree_exited watch (attach-time housekeeping;
## the watch itself belongs to that edit and dies with it).
func _unwatch_current() -> void:
	if edit != null and is_instance_valid(edit) and edit.tree_exiting.is_connected(detach):
		edit.tree_exiting.disconnect(detach)


func detach() -> void:
	if edit != null and is_instance_valid(edit):
		if not _is_text_edit and edit.text_changed.is_connected(_on_text_changed):
			edit.text_changed.disconnect(_on_text_changed)
		if _is_text_edit and (edit as TextEdit).text_changed.is_connected(_on_text_changed_te):
			(edit as TextEdit).text_changed.disconnect(_on_text_changed_te)
		if edit.gui_input.is_connected(_on_edit_input):
			edit.gui_input.disconnect(_on_edit_input)
		if edit.focus_exited.is_connected(_on_focus_exited):
			edit.focus_exited.disconnect(_on_focus_exited)
		var vp: Viewport = edit.get_viewport()
		if vp != null and vp.size_changed.is_connected(_on_viewport_resized):
			vp.size_changed.disconnect(_on_viewport_resized)
	if panel != null and is_instance_valid(panel):
		panel.get_parent().remove_child(panel)
		panel.queue_free()
	if _own_layer != null and is_instance_valid(_own_layer):
		_own_layer.queue_free()
	panel = null
	scroll = null
	list = null
	rows = []
	edit = null
	_own_layer = null
	_visible_now = false


## Builds the popup once, with the context menu's structure and styling:
## a CanvasLayer host, a bordered shadowed panel, and a fixed-size scroll
## list of flat rows. Fixed geometry keeps the scrollbar inside the panel
## no matter how often rows are rebuilt.
func _build_popup() -> void:
	panel = PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.gui_input.connect(_wheel_guard)          # wheel over borders/search
	var sb: StyleBoxFlat = UiStyle.popup_box(4.0)
	panel.add_theme_stylebox_override("panel", sb)
	scroll = ScrollContainer.new()
	# Fixed minimum like the context menu's list: never resized per query,
	# so the panel, list and scrollbar geometry are always in sync.
	scroll.custom_minimum_size = Vector2(248, 200)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.gui_input.connect(_wheel_guard)
	panel.add_child(scroll)
	list = VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 0)
	scroll.add_child(list)
	_plain_style = UiStyle.row_box(false)
	_plain_style.content_margin_left = 6.0
	_plain_style.content_margin_right = 6.0
	_hov_style = UiStyle.row_box(false, true)
	_hov_style.content_margin_left = 6.0
	_hov_style.content_margin_right = 6.0
	_sel_style = UiStyle.row_box(true)
	_sel_style.content_margin_left = 6.0
	_sel_style.content_margin_right = 6.0
	panel.visible = false
	# Render above graph nodes and wires: reuse the canvas context menu's
	# CanvasLayer when this LineEdit belongs to the canvas, otherwise host
	# the popup on a dedicated layer of the LineEdit's own window. The LineEdit
	# may still be under construction (outside the tree): defer hosting until
	# it enters the tree so the viewport is resolvable.
	if edit.is_inside_tree():
		_host_popup()
	else:
		edit.tree_entered.connect(_host_popup, CONNECT_ONE_SHOT)


## Places the popup panel on the canvas menu layer (or a dedicated layer) and
## keeps an open popup inside the window when the window is resized.
func _host_popup() -> void:
	if not is_instance_valid(edit) or panel == null:
		return
	var host: Node = _find_menu_layer()
	if host == null:
		if _own_layer == null:
			_own_layer = CanvasLayer.new()
			_own_layer.layer = 10
			edit.get_viewport().add_child.call_deferred(_own_layer)
		host = _own_layer
	host.add_child.call_deferred(panel)
	# keep an open popup inside the window when the window is resized
	if not edit.get_viewport().size_changed.is_connected(_on_viewport_resized):
		edit.get_viewport().size_changed.connect(_on_viewport_resized)


## Walks up to the canvas that owns the shared menu CanvasLayer (if any).
func _find_menu_layer() -> CanvasLayer:
	var n: Node = edit
	while n != null:
		if "_menu_layer" in n and n._menu_layer != null:
			return n._menu_layer
		n = n.get_parent()
	return null


func hide_suggestions() -> void:
	_visible_now = false
	if panel != null and is_instance_valid(panel):
		panel.visible = false
	sel = -1


## Window resized while the list is open: re-clamp/flip the popup (no-op
## when it is closed).
func _on_viewport_resized() -> void:
	if _visible_now and panel != null and is_instance_valid(panel):
		_show_at_edit()


## Rebuilds the rows for the current query. Only suggestion rows are
## recreated — the LineEdit and its focus/caret are never touched.
func _on_text_changed_te() -> void:
	var te: TextEdit = edit as TextEdit
	_on_text_changed(te.get_line(te.get_caret_line()) if te != null else "")


func _on_text_changed(text: String) -> void:
	var matches: Array = []
	if source.is_valid():
		matches = source.call(text)
	if matches.is_empty():
		hide_suggestions()
		return
	rows = []
	for child: Node in list.get_children():
		list.remove_child(child)
		child.queue_free()
	for i: int in mini(matches.size(), max_rows):
		var b: Button = Button.new()
		b.text = str(matches[i])
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		if type_icons:
			b.icon = TypeIcons.icon_for_type(str(matches[i]))
			b.add_theme_constant_override("h_separation", 6)
		b.add_theme_font_size_override("font_size", UiStyle.FONT_SIZE)
		b.add_theme_color_override("font_color", UiStyle.TEXT)
		b.add_theme_color_override("font_hover_color", UiStyle.TEXT_BRIGHT)
		b.add_theme_color_override("font_pressed_color", UiStyle.TEXT_BRIGHT)
		b.focus_mode = Control.FOCUS_NONE   # clicks must not steal input focus
		b.add_theme_stylebox_override("normal", _plain_style)
		b.add_theme_stylebox_override("hover", _hov_style)
		b.add_theme_stylebox_override("pressed", _sel_style)
		b.add_theme_stylebox_override("focus", _plain_style)
		var idx: int = i
		b.pressed.connect(func() -> void: _pick(idx))
		b.mouse_entered.connect(_select.bind(idx))
		list.add_child(b)
		rows.append(b)
	_show_at_edit()


func _show_at_edit() -> void:
	if panel == null or not is_instance_valid(panel) or edit == null \
			or not is_instance_valid(edit):
		return
	var vp: Viewport = edit.get_viewport()
	if vp == null:   # edit already left the tree (form rebuilt)
		return
	var r: Rect2 = _anchor_rect()
	var vs: Vector2 = vp.get_visible_rect().size
	var ms: Vector2 = panel.get_combined_minimum_size()
	# flip above the input when there is not enough room below, then clamp
	# the popup fully inside the visible window (all four edges)
	var below: bool = r.position.y + r.size.y + 8.0 + ms.y < vs.y
	panel.size = ms
	panel.position = Vector2(
		clampf(r.position.x, 0.0, maxf(0.0, vs.x - ms.x)),
		clampf((r.position.y + r.size.y + 2.0) if below else (r.position.y - ms.y - 2.0),
			0.0, maxf(0.0, vs.y - ms.y)))
	panel.visible = true
	_visible_now = true
	_select(0)


## Highlights the selected row without stealing focus from the input and
## keeps it visible while navigating long lists (as the context menu does).
func _select(i: int) -> void:
	sel = i
	for j: int in rows.size():
		rows[j].add_theme_stylebox_override("normal",
			_sel_style if j == i else _plain_style)
	if i >= 0 and i < rows.size():
		scroll.ensure_control_visible(rows[i])


func _pick(i: int) -> void:
	if i < 0 or i >= rows.size():
		return
	_suppress_hide = 1
	var text: String = rows[i].text
	if is_instance_valid(edit):
		if _is_text_edit:
			_apply_to_text_edit(text)
		else:
			var le: LineEdit = edit as LineEdit
			le.text = text
			le.caret_column = text.length()
	hide_suggestions()
	picked.emit(text)


## Moves the keyboard selection, wrapping at both ends of the list (like
## the context menu). Echo events are what makes holding an arrow key
## navigate continuously; other keys ignore repeats.
func _move(step: int) -> void:
	if rows.is_empty():
		return
	_select((sel + step + rows.size()) % rows.size())


## Keyboard navigation directly on the LineEdit: the popup is only open over
## typed text, so arrow keys still reach the caret normally otherwise.
func _on_edit_input(event: InputEvent) -> void:
	if not _visible_now or not (event is InputEventKey) or not event.pressed:
		return
	match int(event.keycode):
		KEY_DOWN:
			_move(1)
			edit.accept_event()
		KEY_UP:
			_move(-1)
			edit.accept_event()
		KEY_ENTER, KEY_KP_ENTER:
			_pick(sel if sel >= 0 else 0)
			edit.accept_event()
		KEY_ESCAPE:
			hide_suggestions()
			edit.accept_event()
		_:
			pass


## Any wheel event that the scroll list cannot use belongs to the popup, not
## to the graph: at the top or bottom scroll limit an unconsumed wheel event
## would fall through to the canvas and zoom it mid-scroll. While the list
## can still scroll, the event must NOT be consumed here — the
## ScrollContainer handles it (and consumes it) itself.
func _wheel_guard(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		var bar: VScrollBar = scroll.get_v_scroll_bar()
		var lo: float = 0.0
		var hi: float = bar.max_value - bar.page
		if hi <= lo:
			panel.accept_event()           # nothing to scroll: keep the wheel
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and scroll.scroll_vertical >= hi - 0.5:
			panel.accept_event()
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and scroll.scroll_vertical <= lo + 0.5:
			panel.accept_event()
		elif not scroll.is_visible_in_tree():
			panel.accept_event()


func _on_focus_exited() -> void:
	# A click on a row steals focus first; its pressed signal still fires.
	# Hide shortly afterwards unless a pick just happened.
	if edit == null or not is_instance_valid(edit):
		return
	var tree: SceneTree = edit.get_tree()
	if tree == null:
		return
	tree.create_timer(0.08).timeout.connect(_maybe_hide)


func _maybe_hide() -> void:
	if _suppress_hide > 0:
		_suppress_hide -= 1
		return
	hide_suggestions()


func _anchor_rect() -> Rect2:
	if _is_text_edit and edit is TextEdit:
		var te: TextEdit = edit as TextEdit
		var cpos: Vector2 = te.get_caret_draw_pos()
		var g: Vector2 = te.global_position + cpos
		var lh: float = te.get_line_height() + 2.0
		return Rect2(g.x, g.y, 1.0, lh)
	return edit.get_global_rect()


## Replaces the @token the caret is inside on the current line (CodeEdit).
func _apply_to_text_edit(text: String) -> void:
	var te: TextEdit = edit as TextEdit
	if te == null:
		return
	var line: int = te.get_caret_line()
	var col: int = te.get_caret_column()
	var ln: String = te.get_line(line)
	# find the @-token around the caret
	var start: int = col
	while start > 0 and ln[start - 1] != " " and ln[start - 1] != "\t":
		start -= 1
	if start < ln.length() and ln[start] != "@":
		# fall back: insert at caret
		te.insert_text_at_caret(text)
		return
	var end: int = col
	while end < ln.length() and ln[end] != " " and ln[end] != "\t":
		end += 1
	var new_ln: String = ln.substr(0, start) + text + ln.substr(end)
	te.set_line(line, new_ln)
	te.set_caret_line(line)
	te.set_caret_column(start + text.length())
