@tool
extends EditorPlugin
## Adds a "Visual Script" workspace tab to the editor's main screen (next to 2D, 3D,
## Script, Game), hosting the zoom / canvas spike. This plugin adds nothing to the
## Project > Tools menu.
## The workspace script is loaded lazily (never preloaded here), so a compile error in
## it cannot stop this plugin from enabling: the tab then shows an explanation, and
## Godot prints the actual 'Parse Error' line in the Output panel.

const DIR: String = "res://addons/gd_canvas_spikes/"
const WORKSPACE_NAME: String = "Visual Script"
const WORKSPACE_SCRIPT: String = "graph_workspace.gd"
## Built-in editor icons to try, in order, for the tab button.
const WORKSPACE_ICONS: Array[String] = ["GraphEdit", "VisualShader", "Script", "Node"]

var _workspace: Control
# Path of the script the editor currently has open (the Script editor's active
# script). The workspace follows it: opening the Visual Script tab (or changing
# the active script while the tab is open) loads that script into the graph.
var _current_script_path: String = ""


func _enter_tree() -> void:
	_workspace = _build_workspace()
	if _workspace != null:
		# structured property edits join the editor's unified undo history
		_workspace.set("undo_redo", get_undo_redo())
	_make_visible(false)  # must be hidden before it joins the main screen
	EditorInterface.get_editor_main_screen().add_child(_workspace)
	var se: ScriptEditor = EditorInterface.get_script_editor()
	if se != null:
		if not se.editor_script_changed.is_connected(_on_editor_script_changed):
			se.editor_script_changed.connect(_on_editor_script_changed)
		var cur: Script = se.get_current_script()
		if cur != null:
			_current_script_path = cur.resource_path


func _exit_tree() -> void:
	var se: ScriptEditor = EditorInterface.get_script_editor()
	if se != null and se.editor_script_changed.is_connected(_on_editor_script_changed):
		se.editor_script_changed.disconnect(_on_editor_script_changed)
	if is_instance_valid(_workspace):
		_workspace.queue_free()
	_workspace = null


## The Script editor's active script changed (a script was opened, selected or
## switched to). Remember it and, while the Visual Script tab is open, load it
## into the graph right away so the workspace always shows the opened script.
func _on_editor_script_changed(script: Script) -> void:
	if script == null:
		return
	var path: String = script.resource_path
	if path == "" or path.begins_with("res://.godot/"):
		return
	_current_script_path = path
	if _workspace_active() and _workspace.has_method("follow_script"):
		_workspace.follow_script(path)


## Every editor save goes through here (Ctrl+S / Save All / scene or project
## save, and running the game): graph edits are generated and written into the
## .gd file automatically, so the file on disk is always the saved graph. This
## runs whichever main-screen tab is showing, as long as a script is loaded and
## has unsaved graph edits.
func _apply_changes() -> void:
	_save_generated_if_dirty()


func _save_external_data() -> void:
	_save_generated_if_dirty()


func _save_generated_if_dirty() -> void:
	if is_instance_valid(_workspace) and _workspace.has_method("save_if_dirty"):
		_workspace.save_if_dirty()


# ---- Main screen ("Visual Script" workspace tab) ---------------------------------
# The editor calls these to build the tab button and to switch workspaces.
# While the Visual Script tab is open, double-clicking (or selecting) a .gd
# script in the FileSystem dock routes the script into this workspace instead
# of the Script editor. When another workspace is active we claim nothing, so
# scripts keep opening in the Script editor as usual.


func _handles(object: Object) -> bool:
	if not _workspace_active():
		return false
	return _workspace != null and _workspace.has_method("can_open_script") \
		and _workspace.can_open_script(object)


func _edit(object: Object) -> void:
	if _workspace_active() and object is GDScript:
		var path: String = (object as GDScript).resource_path
		if path != "" and _workspace.has_method("open_script"):
			_workspace.open_script(path)


func _workspace_active() -> bool:
	return Engine.is_editor_hint() and is_instance_valid(_workspace) and _workspace.visible


func _has_main_screen() -> bool:
	return true


func _get_plugin_name() -> String:
	return WORKSPACE_NAME


func _get_plugin_icon() -> Texture2D:
	var th: Theme = EditorInterface.get_editor_theme()
	for icon_name: String in WORKSPACE_ICONS:
		if th.has_icon(icon_name, "EditorIcons"):
			return th.get_icon(icon_name, "EditorIcons")
	return null


## Called by the editor whenever the active workspace changes. Hiding (not freeing)
## keeps zoom, pan and block positions across switches. Showing the Visual Script
## tab loads the script the editor currently has open (if any), so the workspace
## always follows the opened script instead of requiring a manual Load.
func _make_visible(visible: bool) -> void:
	if is_instance_valid(_workspace):
		_workspace.visible = visible
	if visible and _workspace_active() and _current_script_path != "" \
			and _workspace.has_method("follow_script"):
		_workspace.follow_script(_current_script_path)


## Instantiates the demo workspace; if its scripts do not compile, returns a short
## explanation panel instead so the tab (and the editor) still works.
func _build_workspace() -> Control:
	var res: Resource = ResourceLoader.load(DIR + WORKSPACE_SCRIPT)
	if res is GDScript and (res as GDScript).can_instantiate():
		var ws: Control = (res as GDScript).new() as Control
		if ws != null:
			return ws
	var box: CenterContainer = CenterContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var msg: Label = Label.new()
	msg.text = "The Visual Script workspace did not compile.\nSee the Output panel (or Debugger > Errors) for the 'Parse Error' line."
	msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(msg)
	return box
