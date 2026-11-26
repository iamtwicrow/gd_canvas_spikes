@tool
extends VBoxContainer
## Editor main-screen workspace ("Visual Script" tab): a Blueprint-style node
## graph derived from a GDScript file through the structural parser.
## plugin.gd adds this to the editor's main screen and shows/hides it via
## EditorPlugin._make_visible(). Built lazily on first show; nothing persisted.

const CanvasView = preload("graph_canvas.gd")
const Model = preload("graph_model.gd")
const Types = preload("graph_types.gd")
const UiStyle = preload("ui_style.gd")
const ScriptIO = preload("script_io.gd")

const DEMO_SCRIPT: String = """extends Node

var health: int = 100
var speed: float = 4.5
var alive := true

func take_hit(amount: int) -> void:
	health -= amount
	if health > 0:
		print("still alive")
	else:
		alive = false
		print("game over")
		return
	speed = speed * 0.5
	print("speed now ", speed)

func tick(delta: float) -> void:
	for i in range(3):
		print(i)
	var n := 0
	while n < 3:
		n += 1
	match health:
		0:
			print("dead")
		_:
			pass
	if speed > 2.0:
		speed = 2.0
"""

## The editor's undo history, injected by the plugin (EditorPlugin
## .get_undo_redo()) so structured property edits join the editor's undo
## system. Standalone/test usage leaves it null (canvas uses a local history).
var undo_redo: UndoRedo = null
var _canvas: CanvasView
var _path_edit: LineEdit
var _stats: Label
var _dirty_label: Label
var _diag_label: Label
# Function editor: banner shown while one function is isolated on the canvas.
var _focus_bar: HBoxContainer = null
var _focus_label: Label = null
var _loaded: bool = false
var _fit_pending: bool = false
var _fit_countdown: int = 0
# Currently loaded script and its disk snapshot (for save + change detection).
var _loaded_path: String = ""
var _loaded_text: String = ""
var _dirty: bool = false
# Title screen: shown instead of an auto-loaded script whenever nothing is
# loaded yet. Offers Create New Script / Load Script / Load Demo.
var _title_screen: PanelContainer = null
# Right-side dock panel (Graphs / Functions / Macros / Variables / Signals).
var _dock_content: Dictionary = {}   # section -> VBoxContainer with the rows
var _dock_root: VBoxContainer = null


func _init() -> void:
	name = "VisualScriptWorkspace"
	# The editor main screen is a VBoxContainer: children must opt in to fill it.
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL


## Flattened catalog used by the "Add Node" button and by tests/add-all loops.
var NODE_MENU: Array[Dictionary] = []


func _ready() -> void:
	var row1: HFlowContainer = HFlowContainer.new()
	add_child(row1)
	_path_edit = LineEdit.new()
	_path_edit.custom_minimum_size = Vector2(420, 0)
	_path_edit.text = _default_script_path()
	UiStyle.style_line_edit(_path_edit)
	row1.add_child(_path_edit)
	row1.add_child(_button("Load", _load))
	row1.add_child(_button("Demo", _load_demo))
	row1.add_child(_button("Save", _save))
	var add_btn: MenuButton = MenuButton.new()
	add_btn.text = "Add Node"
	UiStyle.style_button(add_btn)
	row1.add_child(add_btn)
	_stats = _label("")
	row1.add_child(_stats)
	_dirty_label = _label("")
	_dirty_label.add_theme_color_override("font_color", UiStyle.ACCENT)
	row1.add_child(_dirty_label)
	# Function-editor banner: shown while one function is isolated on the
	# canvas (double-click a function in the dock); the button (or Esc) goes
	# back to the full picture.
	_focus_bar = HBoxContainer.new()
	_focus_bar.add_theme_constant_override("separation", 10)
	var back_btn: Button = _button("◀ Full picture", _exit_function_focus)
	back_btn.tooltip_text = "Back to the whole graph (also Esc)"
	back_btn.custom_minimum_size = Vector2(140, 0)
	_focus_bar.add_child(back_btn)
	_focus_label = _label("")
	_focus_label.add_theme_color_override("font_color", UiStyle.ACCENT)
	_focus_bar.add_child(_focus_label)
	_focus_bar.visible = false
	add_child(_focus_bar)
	move_child(_focus_bar, 1)
	# error / warning counters (hover for the full list)
	_diag_label = _label("")
	_diag_label.mouse_filter = Control.MOUSE_FILTER_STOP
	row1.add_child(_diag_label)

	_canvas = CanvasView.new()
	_canvas.undo_redo = undo_redo
	_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_canvas.custom_minimum_size = Vector2(400, 300)
	# Canvas + right-side dock (Graphs / Functions / Macros / Variables /
	# Signals) side by side, matching the reference editor's layout. Both live
	# in a wrapper Control so the title screen can overlay them.
	var middle: HBoxContainer = HBoxContainer.new()
	middle.size_flags_vertical = Control.SIZE_EXPAND_FILL
	middle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	middle.add_theme_constant_override("separation", 0)
	middle.add_child(_canvas)
	_build_dock_panel(middle)
	var middle_wrap: Control = Control.new()
	middle_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	middle_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	middle_wrap.custom_minimum_size = Vector2(400, 300)
	middle_wrap.add_child(middle)
	middle.set_anchors_preset(Control.PRESET_FULL_RECT)
	_title_screen = _build_title_screen()
	middle_wrap.add_child(_title_screen)
	_title_screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	_title_screen.visible = false
	add_child(middle_wrap)
	_canvas.status_changed.connect(_on_status)
	_canvas.diagnostics_changed.connect(_on_diagnostics)
	_canvas.function_focus_changed.connect(_on_function_focus_changed)
	_canvas.diagnostics_enabled = true
	_canvas.modified.connect(_on_modified)
	_canvas.save_requested.connect(_save)
	_canvas.show_menu = true
	for entry: Dictionary in _canvas.menu_items():
		NODE_MENU.append({"name": str(entry["name"]), "kind": int(entry["kind"]), "fields": entry.get("fields", {}) as Dictionary})
	# Fill the Add Node menu from the same catalog as the canvas context menu.
	var popup: PopupMenu = add_btn.get_popup()
	var last_cat: String = ""
	for i: int in _canvas.menu_items().size():
		var entry: Dictionary = _canvas.menu_items()[i]
		if str(entry["cat"]) != last_cat:
			last_cat = str(entry["cat"])
			popup.add_separator(last_cat)
		popup.add_item(str(entry["name"]), i)
	popup.index_pressed.connect(_on_add_node)

	var help: Label = Label.new()
	help.text = "Right-click empty canvas to create nodes (searchable, categorized). Drag from a pin to a compatible pin to connect (white triangle = execution, colored circle = data); drag a wire off a pin to disconnect. Click a wire to select it, then press Del/Backspace to remove. Deleting a node (Del on selection) removes its wires; deleting an Event removes its whole flow. Positions are session-only; the graph logic is regenerated from the script."
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.add_theme_font_size_override("font_size", UiStyle.FONT_SIZE_SMALL)
	help.add_theme_color_override("font_color", UiStyle.TEXT_MUTED)
	add_child(help)

	visibility_changed.connect(_on_visibility_changed)
	_on_visibility_changed()


## Called by the editor (via plugin.gd) whenever this workspace is shown/hidden.
## First show builds the graph (so enabling the plugin costs nothing at start-up);
## hidden, the workspace stops processing but keeps all state.
func _on_visibility_changed() -> void:
	var shown: bool = is_visible_in_tree()
	set_process(shown)
	if not shown:
		if _dirty:
			# Closing the workspace with unsaved changes: offer Save / Discard /
			# Cancel (Cancel keeps the changes in memory; nothing is lost).
			_prompt_unsaved(func(choice: String) -> void:
				if choice == "save":
					_do_save(func(_ok: bool) -> void: pass)
				elif choice == "discard":
					_do_open(_loaded_path))
			return
	if not _loaded:
		_loaded = true
		# First show: offer the title screen instead of silently opening the
		# last plugin-internal script path (the canvas stays empty until the
		# user creates, loads or opens a script from the editor).
		_show_title_screen(true)
		_fit_pending = true
	if _fit_pending:
		_fit_countdown = 2  # frames to let the containers lay out


func _process(_delta: float) -> void:
	if _fit_countdown > 0:
		_fit_countdown -= 1
		if _fit_countdown == 0:
			_fit_pending = false


# ---- Script loading / switching (used by plugin.gd double-click handling) ---
## Can this workspace take over editing `object`? Called by plugin.gd from
## _handles(): true only for real .gd files while the workspace is open.
func can_open_script(object: Object) -> bool:
	if not (object is GDScript):
		return false
	var path: String = (object as GDScript).resource_path
	return path != "" and not path.begins_with("res://.godot/")


## Opens `path` in this workspace. With unsaved changes the user is asked to
## Save / Discard / Cancel first; Cancel keeps the current script untouched.
## The same path never opens twice at once (the editor can announce the same
## script through both the _edit handover and the follow signal).
func open_script(path: String) -> void:
	if _dirty and path != _loaded_path:
		if path == _pending_open:
			return   # the Save/Discard/Cancel prompt for this path is already up
		_pending_open = path
		_prompt_unsaved(func(choice: String) -> void:
			_pending_open = ""
			if choice == "save":
				_do_save(func(ok: bool) -> void:
					if ok:
						_do_open(path))
			elif choice == "discard":
				_do_open(path)
			else:
				# Cancel: keep the current script; do not auto-follow this
				# switch again until a different script is opened.
				_follow_declined = path)
		return
	_pending_open = ""
	_do_open(path)

## Script currently waiting on its unsaved-changes prompt (deduplication).
var _pending_open: String = ""


## Called by plugin.gd so the workspace follows the script currently open in
## the editor (its active Script editor script). Loads `path` unless it is
## already on screen; with unsaved changes open_script() asks first, and a
## cancelled follow is not re-prompted until the target script changes.
func follow_script(path: String) -> void:
	if path == "" or not is_visible_in_tree():
		return
	if path != _follow_declined:
		_follow_declined = ""
	if path == _loaded_path:
		# Already on screen: pick up edits made to the file meanwhile (typed
		# in the Script editor, changed externally).
		sync_with_disk()
		return
	if path == _follow_declined:
		return
	open_script(path)

## Script the user declined to follow (Cancel on the unsaved-changes prompt);
## prevents the same prompt from re-appearing on every tab switch.
var _follow_declined: String = ""


func _do_open(path: String) -> void:
	var text: String = FileAccess.get_file_as_string(path)
	if text.is_empty() and FileAccess.get_open_error() != OK:
		_stats.text = "Could not read '%s' (error %d)" % [path, FileAccess.get_open_error()]
		return
	_follow_declined = ""
	_pending_open = ""
	_loaded_path = path
	_loaded_text = text
	_dirty = false
	_path_edit.text = path
	# The registry re-scans the project on every open so newly added scripts,
	# custom classes, autoloads, addons and extensions are discovered; the
	# model learns its own path so same-script calls generate as plain calls.
	var t0: int = Time.get_ticks_usec()
	var reg: RefCounted = preload("func_registry.gd").get_registry()
	reg.refresh()
	reg.current_script = path
	# the type database re-scans too: new classes/addons/extensions appear
	preload("type_registry.gd").get_registry().refresh()
	var t1: int = Time.get_ticks_usec()
	_canvas.model.script_path = path
	_canvas.build_from_text(text)
	var t2: int = Time.get_ticks_usec()
	_show_title_screen(false)
	_update_dirty_label()
	_refresh_dock()
	var t3: int = Time.get_ticks_usec()
	_stats.text = "Loaded %s in %d ms (registries %d, graph %d, dock %d)" % [path.get_file(),
		float(t3 - t0) / 1000.0, float(t1 - t0) / 1000.0, float(t2 - t1) / 1000.0,
		float(t3 - t2) / 1000.0]


func _default_script_path() -> String:
	var here: Script = get_script() as Script
	return here.resource_path.get_base_dir().path_join("structure_parser.gd")


func _load() -> void:
	_do_open(_path_edit.text.strip_edges())


func _load_demo() -> void:
	# The demo is an unsaved scratch graph (no file behind it).
	_follow_declined = ""
	_loaded_path = ""
	_loaded_text = ""
	_dirty = false
	_path_edit.text = ""
	_canvas.build_from_text(DEMO_SCRIPT)
	_show_title_screen(false)
	_update_dirty_label()
	_refresh_dock()


# ---- Title screen ------------------------------------------------------------
## Shown whenever the workspace has nothing open: a friendly entry point
## with Create New Script / Load Script / Load Demo instead of an
## auto-loaded plugin-internal script.
func title_screen_visible() -> bool:
	return _title_screen != null and _title_screen.visible


func _show_title_screen(on: bool) -> void:
	if _title_screen != null:
		_title_screen.visible = on


func _build_title_screen() -> PanelContainer:
	var panel: PanelContainer = PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiStyle.flat(UiStyle.CANVAS_BG, Color(0, 0, 0, 0), 0, 0, 0.0, 0.0))
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var center: VBoxContainer = VBoxContainer.new()
	center.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_theme_constant_override("separation", 14)
	panel.add_child(center)
	var title: Label = Label.new()
	title.text = "Visual Script"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 38)
	title.add_theme_color_override("font_color", UiStyle.TEXT_BRIGHT)
	center.add_child(title)
	var subtitle: Label = Label.new()
	subtitle.text = "Blueprint-style visual scripting for your GDScript files"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 14)
	subtitle.add_theme_color_override("font_color", UiStyle.TEXT_DIM)
	center.add_child(subtitle)
	center.add_child(Control.new())   # spacer
	# Flow container: the three buttons wrap into rows when the dock is
	# narrow (responsive layout) instead of being clipped at the dock edge.
	var row: HFlowContainer = HFlowContainer.new()
	row.alignment = FlowContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("h_separation", 14)
	row.add_theme_constant_override("v_separation", 10)
	center.add_child(row)
	row.add_child(_title_button("Create New Script", "Start a new .gd file and open it here", _prompt_new_script))
	row.add_child(_title_button("Load Script", "Open an existing .gd file", _file_dialog))
	row.add_child(_title_button("Load Demo", "Explore a sample graph", _load_demo))
	var hint: Label = Label.new()
	hint.text = "Tip: this workspace follows the script you open in the editor; double-click any .gd file in the FileSystem dock to edit it as a graph. Ctrl+S (or Save) generates the GDScript and updates the file."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", UiStyle.TEXT_MUTED)
	center.add_child(hint)
	return panel


func _title_button(text: String, tip: String, cb: Callable) -> Button:
	var b: Button = Button.new()
	b.text = text
	b.tooltip_text = tip
	b.custom_minimum_size = Vector2(170, 46)
	UiStyle.style_button(b)
	b.add_theme_font_size_override("font_size", 15)
	b.pressed.connect(cb)
	return b


## Create New Script: asks for a file name and base class, writes a small
## starter template to res://<name>.gd and opens it in the graph.
func _prompt_new_script() -> void:
	_dock_prompt("Create New Script", ["File name (becomes res://<name>.gd)",
		"Extends base (default Node)"],
		func(vals: PackedStringArray) -> void:
			_create_new_script(vals[0].strip_edges(), vals[1].strip_edges()))


## Creates res://<fname>.gd with a starter template and opens it. Reports
## problems on the status bar; returns true when the file was created.
func _create_new_script(fname: String, base: String) -> bool:
	if fname == "":
		_stats.text = "File name is empty — nothing created."
		return false
	if not fname.is_valid_identifier():
		_stats.text = "'%s' is not a valid script name." % fname
		return false
	var path: String = "res://%s.gd" % fname
	if FileAccess.file_exists(path):
		_stats.text = "'%s' already exists — nothing created." % path
		return false
	if base == "":
		base = "Node"
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_stats.text = "Could not create '%s' (error %d)." % [path, FileAccess.get_open_error()]
		return false
	f.store_string("extends %s\n\nvar score: int = 0\n\n\nfunc _ready() -> void:\n\tprint(\"Hello from %s\")\n\tscore = score + 1\n" % [base, fname])
	f = null
	_do_open(path)
	return true


## Load Script: a file dialog rooted at res:// filtered to .gd files.
func _file_dialog() -> void:
	var dlg: EditorFileDialog = EditorFileDialog.new()
	dlg.access = EditorFileDialog.ACCESS_RESOURCES
	dlg.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	dlg.add_filter("*.gd", "GDScript files")
	dlg.title = "Load Script"
	dlg.file_selected.connect(func(p: String) -> void:
		dlg.queue_free()
		open_script(p))
	add_child(dlg)
	dlg.popup_centered(Vector2i(720, 480))


func _on_add_node(idx: int) -> void:
	if idx < 0 or idx >= NODE_MENU.size():
		return
	var item: Dictionary = NODE_MENU[idx]
	_canvas.add_user_node(int(item["kind"]), item["fields"])


# ---- Modification state and saving --------------------------------------------
## Ctrl+S while the Visual Script tab is open (the canvas handles it when it
## has focus; this catches focus sitting in a dock field, toolbar edit or
## elsewhere): generate the GDScript and write it to the loaded file. With
## nothing loaded the shortcut falls through to the editor's own save.
func _shortcut_input(event: InputEvent) -> void:
	if not is_visible_in_tree() or _loaded_path == "":
		return
	var key: InputEventKey = event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if not (key.is_command_or_control_pressed()
			and (key.keycode == KEY_S or key.physical_keycode == KEY_S)):
		return
	get_viewport().set_input_as_handled()
	_save()


## Called by plugin.gd on every editor save (Ctrl+S / Save All, scene or
## project save) and before the game runs: writes the generated GDScript into
## the .gd file automatically when the graph has unsaved edits. Works whether
## or not the Visual Script tab is the visible one. Never opens a dialog: if
## the file changed on disk meanwhile, or the graph does not compile, the save
## is skipped and the status line says why (nothing is overwritten).
func save_if_dirty() -> void:
	if _dirty and _loaded_path != "":
		_do_save(func(_ok: bool) -> void: pass, false)


## Re-reads the loaded script from disk when it changed behind the graph's back
## (typed in the Script editor, edited externally, version-control checkout).
## A clean graph reloads silently so the tab always shows the file as it is; a
## graph with unsaved edits keeps them and the next save asks before
## overwriting the external change.
func sync_with_disk() -> void:
	if _loaded_path == "" or not FileAccess.file_exists(_loaded_path):
		return
	var disk: String = ScriptIO.read_text(_loaded_path)
	if disk == _loaded_text:
		return
	if _dirty:
		_stats.text = "'%s' changed on disk while the graph has unsaved edits \u2014 saving will ask before overwriting it." % _loaded_path.get_file()
		return
	_do_open(_loaded_path)
	_stats.text = "Reloaded '%s' (it changed on disk)." % _loaded_path.get_file()


func _notification(what: int) -> void:
	# Coming back to the editor window (e.g. after editing the file elsewhere).
	if what == NOTIFICATION_APPLICATION_FOCUS_IN and is_visible_in_tree() \
			and not _save_busy:
		sync_with_disk()


func _on_modified() -> void:
	if not _dirty:
		_dirty = true
		_update_dirty_label()
	_refresh_dock()


func _update_dirty_label() -> void:
	var sname: String = _loaded_path.get_file() if _loaded_path != "" else "(unsaved)"
	_dirty_label.text = "%s %s" % [sname, "\u25cf unsaved changes" if _dirty else ""]


## Save entry point (Save button / Ctrl+S).
func _save() -> void:
	_do_save(func(_ok: bool) -> void: pass)


## True while a save is waiting on its "File changed on disk" dialog, so a
## second Ctrl+S (or an editor save hook) cannot stack another dialog or write
## underneath it.
var _save_busy: bool = false


## Generates the graph back to GDScript and writes it to the loaded file.
## Steps: compile-check the generated code, make sure the file was not changed
## on disk since it was loaded, write it atomically, verify, then sync the
## editor. Refuses to write code that does not compile (the file keeps its
## working content). `interactive` false (editor save hooks) never opens a
## dialog and skips instead of overwriting an external change. Calls
## `then(ok)`; every outcome leaves a message on the status line.
func _do_save(then: Callable, interactive: bool = true) -> void:
	if _loaded_path == "":
		_stats.text = "No script file is loaded (use Load or double-click a .gd file)."
		then.call(false)
		return
	if _save_busy:
		then.call(false)
		return
	var res: Dictionary = _canvas.generate_code()
	var code: String = res["code"]
	if not bool(res["ok"]):
		# Never overwrite a working file with output that cannot compile.
		# The graph state is untouched and the file keeps its working content;
		# the generated code stays unapplied until the graph compiles again.
		_stats.text = "Save cancelled: generated code does not compile (%s). Check the graph and try again." % res["err_text"]
		push_warning("GD Canvas: '%s' was not saved \u2014 the generated code does not compile." % _loaded_path.get_file())
		then.call(false)
		return
	var note: String = _unreachable_note(res)
	var disk: String = ScriptIO.read_text(_loaded_path)
	if disk != _loaded_text and not disk.is_empty() and disk != code:
		if not interactive:
			_stats.text = "Auto-save skipped: '%s' changed on disk after it was opened. Press Save to choose whether to overwrite it." % _loaded_path.get_file()
			push_warning("GD Canvas: auto-save of '%s' skipped \u2014 the file changed on disk." % _loaded_path.get_file())
			then.call(false)
			return
		_confirm_overwrite_external(code, then, note)
		return
	_write_script(code, then, note)


## Lists graph nodes that cannot be part of the file (not reachable from any
## function) so the status line can say what a save left out.
func _unreachable_note(res: Dictionary) -> String:
	var unt: PackedStringArray = res.get("unreachable_titles", PackedStringArray()) as PackedStringArray
	if unt.size() == 0:
		return ""
	return " \u2014 note: %d node(s) not reachable from any function were skipped: %s" \
		% [unt.size(), ", ".join(unt.slice(0, 8))]


## The file changed on disk after it was loaded: ask before overwriting.
func _confirm_overwrite_external(code: String, then: Callable, note: String = "") -> void:
	_save_busy = true
	var dlg: ConfirmationDialog = ConfirmationDialog.new()
	dlg.title = "File changed on disk"
	dlg.dialog_text = "'%s' was modified outside the Visual Script editor.\nOverwrite it with the generated script?" % _loaded_path.get_file()
	dlg.get_ok_button().text = "Overwrite"
	dlg.confirmed.connect(func() -> void:
		dlg.queue_free()
		_save_busy = false
		_write_script(code, then, note))
	dlg.canceled.connect(func() -> void:
		dlg.queue_free()
		_save_busy = false
		_stats.text = "Save cancelled: '%s' was left as it is on disk." % _loaded_path.get_file()
		then.call(false))
	add_child(dlg)
	dlg.popup_centered()


## Writes `code` to the loaded file (atomically, verified) and brings the
## editor in line with it. Never reports success for a write that did not
## reach the .gd file.
func _write_script(code: String, then: Callable, note: String = "") -> void:
	var err: Error = ScriptIO.write_text(_loaded_path, code)
	if err != OK:
		_stats.text = "Save failed: could not write '%s' (error %d: %s)." % [_loaded_path, err, error_string(err)]
		push_warning("GD Canvas: could not write '%s' (error %d)." % [_loaded_path, err])
		then.call(false)
		return
	_loaded_text = code
	_dirty = false
	_update_dirty_label()
	var t: Dictionary = Time.get_time_dict_from_system()
	_stats.text = "Saved '%s' at %02d:%02d:%02d%s" % [_loaded_path.get_file(),
		int(t["hour"]), int(t["minute"]), int(t["second"]), note]
	_sync_editor_after_write(code)
	then.call(true)


## Keeps the editor in sync so the standard Script editor shows the saved
## code instead of its stale buffer: update the in-memory GDScript resource,
## reload the open script editors from disk and refresh the file cache.
func _sync_editor_after_write(code: String) -> void:
	if not Engine.is_editor_hint():
		return
	if ResourceLoader.exists(_loaded_path):
		var res: Resource = load(_loaded_path)
		if res is GDScript:
			(res as GDScript).source_code = code
			(res as GDScript).reload()
	var se: ScriptEditor = EditorInterface.get_script_editor()
	if se != null:
		se.reload_open_files()
	var efs: EditorFileSystem = EditorInterface.get_resource_filesystem()
	if efs != null:
		efs.update_file(_loaded_path)


## Asks the user what to do with unsaved changes. `then` receives
## "save" / "discard" / "cancel".
func _prompt_unsaved(then: Callable) -> void:
	var dlg: ConfirmationDialog = ConfirmationDialog.new()
	dlg.title = "Unsaved changes"
	dlg.dialog_text = "The script has unsaved changes in the Visual Script editor.\nSave them before continuing?"
	dlg.get_ok_button().text = "Save"
	var discard: Button = dlg.add_button("Discard", true)
	discard.pressed.connect(func() -> void:
		dlg.queue_free()
		then.call("discard"))
	dlg.confirmed.connect(func() -> void:
		dlg.queue_free()
		then.call("save"))
	dlg.canceled.connect(func() -> void:
		dlg.queue_free()
		then.call("cancel"))
	add_child(dlg)
	dlg.popup_centered()


func _on_status(text: String) -> void:
	_stats.text = text


## Error / warning counters next to the toolbar; the tooltip lists every
## problem (also those that could not be tied to a single node).
func _on_diagnostics(errors: int, warnings: int, details: String) -> void:
	if _diag_label == null:
		return
	var parts: PackedStringArray = PackedStringArray()
	if errors > 0:
		parts.append("%d error%s" % [errors, "" if errors == 1 else "s"])
	if warnings > 0:
		parts.append("%d warning%s" % [warnings, "" if warnings == 1 else "s"])
	_diag_label.text = "  |  ".join(parts)
	_diag_label.tooltip_text = details
	_diag_label.add_theme_color_override("font_color",
		Types.ERROR_COLOR if errors > 0 else Types.WARNING_COLOR)


# ---- Right-side dock panel ------------------------------------------------------
## The reference editor's dock: Graphs (events), Functions, Macros, Variables
## and Signals. Every functional "+" creates a real node, every row focuses
## its node, and the variable "eye" toggles the variable's @export annotation.

var _dock_adds: Dictionary = {}   # section -> "+" Button


func _build_dock_panel(parent: Control) -> void:
	var panel: PanelContainer = PanelContainer.new()
	panel.custom_minimum_size = Vector2(234, 0)
	panel.add_theme_stylebox_override("panel", UiStyle.flat(UiStyle.PANEL_DEEP, Color(0, 0, 0, 0), 0, 0, 0.0, 0.0))
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var box: VBoxContainer = VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 0)
	scroll.add_child(box)
	panel.add_child(scroll)
	parent.add_child(panel)
	_dock_root = box
	# Section "+" buttons. Graphs/Macros stay visible for parity but disabled:
	# a script has exactly one graph, and macros have no GDScript codegen.
	var graphs_add: Button = _dock_add_button()
	graphs_add.disabled = true
	graphs_add.tooltip_text = "A script has one graph; new entry points are functions"
	_dock_adds["Graphs"] = graphs_add
	var fn_add: Button = _dock_add_button()
	fn_add.pressed.connect(_dock_add_function)
	_dock_adds["Functions"] = fn_add
	var mac_add: Button = _dock_add_button()
	mac_add.disabled = true
	mac_add.tooltip_text = "Macros are not supported by GDScript code generation"
	_dock_adds["Macros"] = mac_add
	var var_add: Button = _dock_add_button()
	var_add.pressed.connect(_dock_add_variable)
	_dock_adds["Variables"] = var_add
	var enum_add: Button = _dock_add_button()
	enum_add.tooltip_text = "Add an enum (a named list of choices)"
	enum_add.pressed.connect(_dock_add_enum)
	_dock_adds["Enums"] = enum_add
	var dict_add: Button = _dock_add_button()
	dict_add.tooltip_text = "Add a Dictionary variable (a list of keys and values)"
	dict_add.pressed.connect(_dock_add_dictionary)
	_dock_adds["Dictionaries"] = dict_add
	var arr_add: Button = _dock_add_button()
	arr_add.tooltip_text = "Add an Array variable (a list of items)"
	arr_add.pressed.connect(_dock_add_array)
	_dock_adds["Arrays"] = arr_add
	var sig_add: Button = _dock_add_button()
	sig_add.pressed.connect(_dock_add_signal)
	_dock_adds["Signals"] = sig_add
	for section: String in ["Graphs", "Functions", "Macros", "Variables", "Enums", "Dictionaries", "Arrays", "Signals"]:
		var header: HBoxContainer = HBoxContainer.new()
		header.add_theme_constant_override("separation", 4)
		var hl: Label = Label.new()
		hl.text = "\u25be  " + section
		hl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hl.add_theme_font_size_override("font_size", UiStyle.FONT_SIZE)
		hl.add_theme_color_override("font_color", UiStyle.TEXT_DIM)
		hl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		header.add_child(hl)
		header.add_child(_dock_adds[section])
		var header_panel: PanelContainer = PanelContainer.new()
		header_panel.add_theme_stylebox_override("panel", UiStyle.flat(UiStyle.BAR_BG, Color(0, 0, 0, 0), 0, 0, 6.0, 2.0))
		header_panel.add_child(header)
		box.add_child(header_panel)
		var content: VBoxContainer = VBoxContainer.new()
		content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		box.add_child(content)
		_dock_content[section] = content
	_refresh_dock()


func _dock_add_button() -> Button:
	var b: Button = Button.new()
	b.text = "+"
	b.tooltip_text = "Add"
	b.custom_minimum_size = Vector2(28, 0)
	UiStyle.style_icon_button(b)
	b.add_theme_font_size_override("font_size", 14)
	return b


## Rebuilds the dock rows from the model. Called on every graph modification
## and after loading a script.
func _refresh_dock() -> void:
	if _dock_root == null or _canvas == null:
		return
	var m: Model = _canvas.model
	var events: Array[int] = []
	var accessors: Array[int] = []
	for id: int in m.nodes:
		if int(m.nodes[id]["kind"]) == Model.Kind.ENTRY:
			# Setter / Getter nodes are not functions: they are listed under
			# Graphs only (by their title), never under Functions
			if m.is_accessor_entry(id):
				accessors.append(id)
			else:
				events.append(id)
	_fill_dock_section("Graphs", func() -> void:
		if events.is_empty() and accessors.is_empty():
			_dock_label("Event Graph")
		for eid: int in events:
			_dock_func_row("\u25b6 " + str(m.nodes[eid]["fields"].get("name", "?")), eid,
				"Click: go to this event / function graph. Double-click: edit only this function.")
		for aid: int in accessors:
			_dock_func_row("\u25b6 " + str(m.nodes[aid].get("title", "?")), aid,
				"Click: go to this Setter / Getter. Double-click: edit only this one."))
	_fill_dock_section("Functions", func() -> void:
		if events.is_empty():
			_dock_label("No functions defined")
		for eid: int in events:
			_dock_func_row(str(m.nodes[eid]["fields"].get("name", "?")), eid,
				"Click: go to this function. Double-click: edit only this function (Esc / the banner button goes back)."))
	_fill_dock_section("Macros", func() -> void:
		_dock_label("No macros defined"))
	_fill_dock_section("Variables", func() -> void:
		var vars: Array[int] = []
		for id2: int in m.nodes:
			if int(m.nodes[id2]["kind"]) == Model.Kind.VAR_DECL:
				vars.append(id2)
		if vars.is_empty():
			_dock_label("No variables defined")
		for vid: int in vars:
			_dock_variable_row(m, vid))
	_fill_dock_section("Enums", func() -> void:
		var enums: Array[int] = []
		for ide: int in m.nodes:
			if int(m.nodes[ide]["kind"]) == Model.Kind.DECLARATION \
					and str(m.nodes[ide]["title"]).begins_with("enum "):
				enums.append(ide)
		if enums.is_empty():
			_dock_label("No enums defined")
		for eid2: int in enums:
			_dock_row(str(m.nodes[eid2]["title"]), eid2, "Go to this enum"))
	_fill_dock_section("Dictionaries", func() -> void:
		var dicts: Array[int] = []
		for idd: int in m.nodes:
			if int(m.nodes[idd]["kind"]) == Model.Kind.VAR_DECL \
					and str(m.nodes[idd]["fields"].get("raw_type", "")).begins_with("Dictionary"):
				dicts.append(idd)
		if dicts.is_empty():
			_dock_label("No dictionaries defined")
		for did: int in dicts:
			_dock_row(str(m.nodes[did]["fields"].get("name", "?")), did, "Go to this dictionary"))
	_fill_dock_section("Arrays", func() -> void:
		var arrs: Array[int] = []
		for ida: int in m.nodes:
			if int(m.nodes[ida]["kind"]) == Model.Kind.VAR_DECL \
					and str(m.nodes[ida]["fields"].get("raw_type", "")).begins_with("Array"):
				arrs.append(ida)
		if arrs.is_empty():
			_dock_label("No arrays defined")
		for aid2: int in arrs:
			_dock_row(str(m.nodes[aid2]["fields"].get("name", "?")), aid2, "Go to this array"))
	_fill_dock_section("Signals", func() -> void:
		var sigs: Array[int] = []
		for id3: int in m.nodes:
			if int(m.nodes[id3]["kind"]) == Model.Kind.DECLARATION \
					and str(m.nodes[id3]["body"]).strip_edges().begins_with("signal "):
				sigs.append(id3)
		if sigs.is_empty():
			_dock_label("No signals defined")
		for sid: int in sigs:
			_dock_row(str(m.nodes[sid]["body"]).strip_edges(), sid, "Go to this signal"))


func _fill_dock_section(section: String, fill: Callable) -> void:
	var content: VBoxContainer = _dock_content.get(section)
	if content == null:
		return
	for c: Node in content.get_children():
		content.remove_child(c)
		c.queue_free()
	_dock_current = content
	fill.call()
	_dock_current = null


func _dock_label(text: String) -> void:
	var l: Label = Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", UiStyle.FONT_SIZE)
	l.add_theme_color_override("font_color", UiStyle.TEXT_DIM)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.custom_minimum_size = Vector2(0, 26)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if _dock_current != null:
		_dock_current.add_child(l)


## Adds one clickable row to the section currently being filled.
var _dock_current: VBoxContainer = null


func _dock_row(text: String, id: int, tip: String) -> void:
	var b: Button = Button.new()
	b.text = text
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.tooltip_text = tip
	UiStyle.style_row_button(b)
	b.pressed.connect(func() -> void:
		if not _canvas.focus_contains(id):
			_canvas.exit_function_focus()   # the target is hidden by the focus
		_canvas.focus_node(id))
	if _dock_current != null:
		_dock_current.add_child(b)


## Dock row for a function / event graph. Single click goes to it (and, while
## a function is isolated, another function's row switches the isolation
## directly). Double-click opens the function editor: only that function on
## the canvas, everything else hidden, banner + Esc to go back.
func _dock_func_row(text: String, id: int, tip: String) -> void:
	var b: Button = Button.new()
	b.text = text
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.tooltip_text = tip
	UiStyle.style_row_button(b)
	b.pressed.connect(func() -> void:
		if _canvas.is_function_focused():
			if _canvas.focused_function() != id:
				_canvas.enter_function_focus(id)   # switch directly
			# already editing this function: the second press of a double-click
			# lands here too — it must not scroll away from the isolated view
		else:
			_canvas.focus_node(id))
	b.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT \
				and ev.double_click:
			_canvas.enter_function_focus(id))
	if _dock_current != null:
		_dock_current.add_child(b)


## Variable row: type-coloured dot, name (focuses the node) and an "eye"
## toggle for the @export annotation.
func _dock_variable_row(m: Model, vid: int) -> void:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var vt: int = Types.VARIANT
	if (m.nodes[vid]["data_outs"] as Array).size() > 0:
		vt = int(m.nodes[vid]["data_outs"][0]["type"])
	var dot: ColorRect = ColorRect.new()
	dot.custom_minimum_size = Vector2(10, 10)
	dot.color = Types.color_of(vt)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(dot)
	var name: String = str(m.nodes[vid]["fields"].get("name", "?"))
	var b: Button = Button.new()
	b.text = name
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.tooltip_text = "Go to this variable"
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UiStyle.style_row_button(b)
	b.pressed.connect(func() -> void:
		if not _canvas.focus_contains(vid):
			_canvas.exit_function_focus()   # the variable is hidden by the focus
		_canvas.focus_node(vid))
	row.add_child(b)
	var eye: Button = Button.new()
	eye.toggle_mode = true
	var exported: bool = str(m.nodes[vid]["fields"].get("annotations", "")).contains("@export")
	eye.button_pressed = exported
	eye.text = "\u25c9" if exported else "\u25cb"
	eye.tooltip_text = "Toggle @export on this variable"
	eye.custom_minimum_size = Vector2(28, 0)
	UiStyle.style_icon_button(eye, exported)
	eye.toggled.connect(func(on: bool) -> void: _toggle_var_export(vid, on))
	row.add_child(eye)
	if _dock_current != null:
		_dock_current.add_child(row)


## Turns the variable's @export annotation on/off through the model's
## annotation API (the same path the node's annotation rows use).
func _toggle_var_export(id: int, on: bool) -> void:
	var m: Model = _canvas.model
	if not m.nodes.has(id):
		return
	var joined: String = str(m.nodes[id]["fields"].get("annotations", ""))
	var anns: PackedStringArray = joined.split("\n") if joined != "" else PackedStringArray()
	var idx: int = -1
	for i: int in anns.size():
		if anns[i].strip_edges().begins_with("@export"):
			idx = i
			break
	var ok: bool = false
	if on and idx < 0:
		ok = m.add_annotation(id, "@export")
	elif not on and idx >= 0:
		ok = m.remove_annotation(id, idx)
	if not ok:
		return
	if _canvas.views.has(id):
		_canvas._rebuild_annotation_view(id)
	_canvas.modified.emit()
	_refresh_dock()


## Small modal form (one LineEdit per label); `then` receives the texts.
func _dock_prompt(title: String, labels: Array[String], then: Callable) -> void:
	var dlg: AcceptDialog = AcceptDialog.new()
	dlg.title = title
	var box: VBoxContainer = VBoxContainer.new()
	box.custom_minimum_size = Vector2(280, 0)
	box.add_theme_constant_override("separation", 6)
	var edits: Array[LineEdit] = []
	for lab: String in labels:
		var l: Label = Label.new()
		l.text = lab
		box.add_child(l)
		var le: LineEdit = LineEdit.new()
		le.custom_minimum_size = Vector2(240, 0)
		box.add_child(le)
		edits.append(le)
	dlg.add_child(box)
	dlg.confirmed.connect(func() -> void:
		var vals: PackedStringArray = PackedStringArray()
		for le: LineEdit in edits:
			vals.append(le.text)
		dlg.queue_free()
		then.call(vals))
	add_child(dlg)
	dlg.popup_centered()


func _dock_add_function() -> void:
	_dock_prompt("Add Function", ["Function name", "Return type (empty = void)"],
		func(vals: PackedStringArray) -> void:
			var fname: String = vals[0].strip_edges()
			if fname == "":
				fname = "new_function"
			_canvas.spawn_node(Model.Kind.ENTRY, {"name": fname, "ret_type": vals[1].strip_edges()})
			_refresh_dock())


func _dock_add_variable() -> void:
	_dock_prompt("Add Variable", ["Variable name", "Type (e.g. int, empty = Variant)",
		"Default value (empty = none)"],
		func(vals: PackedStringArray) -> void:
			_canvas.spawn_node(Model.Kind.VAR_DECL, {"name": vals[0].strip_edges(),
				"raw_type": vals[1].strip_edges(), "default": vals[2].strip_edges()})
			_refresh_dock())


func _dock_add_enum() -> void:
	_canvas.spawn_node(Model.Kind.DECLARATION, {"new_enum": true})
	_refresh_dock()


func _dock_add_array() -> void:
	_canvas.spawn_node(Model.Kind.VAR_DECL, {"new_array": true})
	_refresh_dock()


func _dock_add_dictionary() -> void:
	_canvas.spawn_node(Model.Kind.VAR_DECL, {"new_dict": true})
	_refresh_dock()


func _dock_add_signal() -> void:
	_dock_prompt("Add Signal", ["Signal name"],
		func(vals: PackedStringArray) -> void:
			var sname: String = vals[0].strip_edges()
			if sname == "":
				sname = "my_signal"
			_canvas.spawn_node(Model.Kind.DECLARATION,
				{"body": "signal " + sname, "title": "Signal"})
			_refresh_dock())


func _label(t: String) -> Label:
	var l: Label = Label.new()
	l.text = t
	return l


## Leaves the function editor (banner button; Esc works on the canvas too).
func _exit_function_focus() -> void:
	if _canvas != null:
		_canvas.exit_function_focus()


## Shows / hides the function-editor banner. The model is untouched while one
## function is isolated: exit restores the full picture exactly as it was.
func _on_function_focus_changed(entry_id: int) -> void:
	if _focus_bar == null:
		return
	if entry_id < 0 or not _canvas.model.nodes.has(entry_id):
		_focus_bar.visible = false
		return
	var fname: String = str(_canvas.model.nodes[entry_id]["fields"].get("name", "?"))
	_focus_label.text = "Editing function '%s' — only this function is on the canvas; Esc or the button shows the full picture again." % fname
	_focus_bar.visible = true


func _button(t: String, cb: Callable) -> Button:
	var b: Button = Button.new()
	b.text = t
	UiStyle.style_button(b)
	b.pressed.connect(cb)
	return b
