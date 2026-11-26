@tool
extends VBoxContainer
## Editor main-screen workspace ('Visual Script' tab) hosting the zoom spike:
## HUD + canvas + manual test checklist. plugin.gd adds this to the editor's main
## screen and shows/hides it via EditorPlugin._make_visible().

const CanvasView = preload("spike_canvas.gd")

const CHECKLIST: String = """MANUAL CHECKS - note the result at 50 / 100 / 200 / 300 % zoom (toggle 'Crisp text' on and off):
1. Text is sharp (not blurry or shimmering).   2. Click in code: the caret lands under the cursor.   3. Drag-select across lines; double-click a word.
4. Type, delete, Ctrl+Z, paste.   5. Wheel over code scrolls the block; Ctrl+wheel zooms at the cursor; wheel on background pans.
6. Drag a block by its title: it stays under the cursor at every zoom.   7. IME / compose input, if you use one.   8. Gutter, caret and scrollbars look right.
Pan: drag the background or hold the middle mouse button."""

var _canvas: CanvasView
var _path_edit: LineEdit
var _copies: SpinBox
var _stats: Label
var _fps: Label
var _fps_timer: float = 0.0
var _loaded: bool = false
var _fit_pending: bool = false
var _fit_countdown: int = 0


func _init() -> void:
	name = "VisualScriptWorkspace"
	# The editor main screen is a VBoxContainer: children must opt in to fill it.
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL


func _ready() -> void:
	var root: VBoxContainer = self
	root.add_theme_constant_override("separation", 4)

	var row1: HFlowContainer = HFlowContainer.new()
	root.add_child(row1)
	_path_edit = LineEdit.new()
	_path_edit.custom_minimum_size = Vector2(420, 0)
	_path_edit.text = _default_script_path()
	row1.add_child(_path_edit)
	row1.add_child(_button("Load", _load))
	row1.add_child(_label("copies:"))
	_copies = SpinBox.new()
	_copies.min_value = 1
	_copies.max_value = 300
	_copies.value = 1
	row1.add_child(_copies)
	row1.add_child(_button("Rebuild", _load))
	row1.add_child(_label("(stress test: more copies = more blocks)"))

	var row2: HFlowContainer = HFlowContainer.new()
	root.add_child(row2)
	row2.add_child(_check("Virtualize", true, _on_virtualize))
	row2.add_child(_check("LOD below 35%", true, _on_lod))
	row2.add_child(_check("Crisp text", false, _on_crisp))
	row2.add_child(_button("Fit all", func() -> void: _canvas.fit()))
	row2.add_child(_button("100%", func() -> void: _canvas.set_zoom_at(1.0, _canvas.size * 0.5)))
	row2.add_child(_button("Run sweep (~8 s)", func() -> void: _canvas.run_sweep()))
	_stats = _label("")
	row2.add_child(_stats)
	_fps = _label("")
	row2.add_child(_fps)

	_canvas = CanvasView.new()
	_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_canvas.custom_minimum_size = Vector2(400, 300)
	root.add_child(_canvas)
	_canvas.stats_changed.connect(_on_stats)
	_canvas.sweep_finished.connect(_on_sweep_finished)

	var help: Label = Label.new()
	help.text = CHECKLIST
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.add_theme_font_size_override("font_size", 11)
	help.add_theme_color_override("font_color", Color("#9aa0ad"))
	root.add_child(help)

	visibility_changed.connect(_on_visibility_changed)
	_on_visibility_changed()


## Called by the editor (via plugin.gd) whenever this workspace is shown or hidden.
## The first time it is shown the canvas is built (so enabling the plugin costs
## nothing at editor start-up); hidden, it stops processing but keeps all state.
func _on_visibility_changed() -> void:
	var shown: bool = is_visible_in_tree()
	set_process(shown)
	if not shown:
		return
	if not _loaded:
		_loaded = true
		_load()
		_fit_pending = true
	if _fit_pending:
		_fit_countdown = 2  # frames to let the containers lay out (see _process)


func _process(delta: float) -> void:
	# The first fit waits until the freshly shown workspace has its real size;
	# fitting earlier would use a stale canvas size.
	if _fit_countdown > 0:
		_fit_countdown -= 1
		if _fit_countdown == 0:
			_fit_pending = false
			_canvas.fit()
	_fps_timer += delta
	if _fps_timer >= 0.25:
		_fps_timer = 0.0
		_fps.text = "| %d fps (idle redraw is throttled by the editor; use Run sweep)" % Engine.get_frames_per_second()


## The script loaded by default: the parser, next to this file. Resolved through this
## script's own resource path (a typed Script), not through a preloaded constant.
func _default_script_path() -> String:
	var here: Script = get_script() as Script
	return here.resource_path.get_base_dir().path_join("structure_parser.gd")


func _load() -> void:
	var path: String = _path_edit.text.strip_edges()
	var text: String = FileAccess.get_file_as_string(path)
	if text.is_empty():
		_stats.text = "Could not read '%s' (error %d)" % [path, FileAccess.get_open_error()]
		return
	_canvas.build(text, int(_copies.value))


func _on_virtualize(on: bool) -> void:
	_canvas.virtualize = on
	_canvas.request_refresh()


func _on_lod(on: bool) -> void:
	_canvas.lod_enabled = on
	_canvas.request_refresh()


func _on_crisp(on: bool) -> void:
	_canvas.crisp = on
	_canvas.apply_crisp_now()


func _on_stats(total: int, live: int, in_view: int) -> void:
	_stats.text = "blocks %d | live CodeEdits %d | in view %d | zoom %d%%" % [total, live, in_view, roundi(_canvas.zoom * 100.0)]


func _on_sweep_finished(report: String) -> void:
	var dlg: AcceptDialog = AcceptDialog.new()
	dlg.title = "Sweep result (copy and send back)"
	var te: TextEdit = TextEdit.new()
	te.text = report
	te.editable = false
	te.custom_minimum_size = Vector2(760, 260)
	dlg.add_child(te)
	dlg.confirmed.connect(dlg.queue_free)
	dlg.canceled.connect(dlg.queue_free)
	add_child(dlg)
	dlg.popup_centered()


func _label(t: String) -> Label:
	var l: Label = Label.new()
	l.text = t
	return l


func _button(t: String, cb: Callable) -> Button:
	var b: Button = Button.new()
	b.text = t
	b.pressed.connect(cb)
	return b


func _check(t: String, on: bool, cb: Callable) -> CheckBox:
	var c: CheckBox = CheckBox.new()
	c.text = t
	c.button_pressed = on
	c.toggled.connect(cb)
	return c
