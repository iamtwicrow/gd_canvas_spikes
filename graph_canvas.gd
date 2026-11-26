@tool
extends GraphEdit
## Interactive node canvas (Blueprint-style) wired to the graph model.
## Handles: drag-connect between pins (with validation + visual feedback via
## GraphEdit's valid connection types), disconnecting wires by dragging either
## end, selecting a wire and deleting it with Del/Backspace, right-click node
## creation menu (searchable, categorized, Blueprint-like), node deletion,
## node moving (session-only positions; the model never stores coordinates)
## and code generation.
##
## Engine notes (verified against Godot 4.7):
## - GraphNode positions are stored in graph coordinates on `position_offset`
##   (`position` is the derived, zoomed/panned screen position).
## - GraphEdit colors wires as a gradient between the two port colors, so the
##   centralized type colors flow through to the wires automatically.
## - `popup_request` fires on right-click over the canvas (also over nodes, so
##   we re-check node rectangles before opening the menu).

const Types = preload("graph_types.gd")
const FuncReg = preload("func_registry.gd")
const TypeReg = preload("type_registry.gd")
const AnnReg = preload("annotation_registry.gd")
const ClassReg = preload("class_registry.gd")
const Model = preload("graph_model.gd")
const NodeView = preload("graph_node.gd")
const UiStyle = preload("ui_style.gd")
const TypeIcons = preload("type_icons.gd")
const CollText = preload("collection_text.gd")
const DropDecls = preload("drop_decls.gd")

signal status_changed(text: String)
signal modified()
signal save_requested()
## Fired whenever the error/warning picture of the graph was (re)computed.
## `details` is the full multi-line list (used as a tooltip by the workspace).
signal diagnostics_changed(errors: int, warnings: int, details: String)

var model: Model = Model.new()
var views: Dictionary[int, NodeView] = {}   # model id -> NodeView

# Blueprint-style error / warning display (see graph_diagnostics.gd). Live
# re-checking after edits is opt-in: the workspace switches it on.
const DIAG_DELAY: float = 0.45
var diagnostics_enabled: bool = false
var diag_errors: int = 0
var diag_warnings: int = 0
var diag_details: String = ""
var _diag_module: RefCounted = null
var _diag_module_tried: bool = false
var _diag_by_node: Dictionary = {}   # model id -> Array of {severity, message, line, source}
var _diag_gen: int = 0
## analyze() is a coroutine (the analyzer-warning pass awaits), so a refresh
## runs over several frames; while one is running further requests queue up
## and re-run it with the freshest graph once it finishes.
var _diag_refresh_busy: bool = false
var _diag_refresh_queued: bool = false
## Error / Warning nodes (graph_diag_node.gd): display-only nodes spawned for
## every node that has problems. NOT model nodes: never in `views`, never
## saved, never generated. Keyed by node name ("dg_e5" / "dg_w5").
const DIAG_NODE_PREFIX: String = "dg_"
var _diag_node_script: GDScript = null
var _diag_node_tried: bool = false
var _diag_nodes: Dictionary = {}
var _font: Font
var _font_size: int = 13

# Selection navigation history (toolbar back/forward arrows).
var _nav_history: Array[int] = []
var _nav_pos: int = -1
# Grid pattern selector shown in the GraphEdit toolbar (Dots / Lines).
var _grid_pattern_btn: OptionButton = null

# Wire selection state ({from_node, from_port, to_node, to_port}).
var _selected_wire: Dictionary = {}
# Spawn menu state.
var _menu_root: PanelContainer = null
var _menu_layer: CanvasLayer = null
var _menu_arg_btn: Button = null
var _menu_search: LineEdit = null
var _menu_list: VBoxContainer = null
var _menu_headers: Array[Dictionary] = []   # {label: Label, from: int, to: int} catalog range
var _menu_buttons: Array[Button] = []   # Button per catalog entry
var _menu_sel: int = -1   # keyboard-highlighted catalog entry (search results)
var _menu_open: bool = false
var _menu_at: Vector2 = Vector2.ZERO
var _pending_drag: Dictionary = {}   # {is_output: bool, node: String, port: int}
var _drag_origin: Dictionary = {}   # pin a connection drag started from
# Node creation catalog: {cat, name, kind, fields}.
var _catalog: Array[Dictionary] = []
var _menu_catalog: Array[Dictionary] = []   # _catalog + dynamic variable entries
var _menu_items: Array[Dictionary] = []   # what the open menu currently lists (incl. functions)
var _menu_fav_btn: Button = null
var _menu_ok_btn: Button = null
var _menu_collapsed: Dictionary = {}   # category -> true while folded (ignored during search)
var _menu_fav_list: VBoxContainer = null
var _menu_recent_list: VBoxContainer = null
var _menu_desc: Label = null
var _menu_favs: Array[String] = []   # favorite entry keys (cat|name|kind), session-scoped
var _menu_recents: Array[String] = []   # most-recently used entry keys
var _func_items: Array[Dictionary] = []   # registry-derived function menu entries
var _ann_items: Array[Dictionary] = []   # registry-derived annotation menu entries
var _class_items: Array[Dictionary] = []   # registry-derived class menu entries
var _member_items: Array[Dictionary] = []   # registry-derived member menu entries


func _init() -> void:
	_catalog = [
		# Flow Control
		{"cat": "Flow Control", "name": "If", "kind": Model.Kind.IF, "fields": {}},
		{"cat": "Flow Control", "name": "Else If", "kind": Model.Kind.ELIF, "fields": {}},
		{"cat": "Flow Control", "name": "Match", "kind": Model.Kind.MATCH, "fields": {}},
		{"cat": "Flow Control", "name": "While", "kind": Model.Kind.WHILE, "fields": {}},
		{"cat": "Flow Control", "name": "For", "kind": Model.Kind.FOR, "fields": {}},
		{"cat": "Flow Control", "name": "Return", "kind": Model.Kind.RETURN, "fields": {}},
		{"cat": "Flow Control", "name": "Break", "kind": Model.Kind.BREAK, "fields": {}},
		{"cat": "Flow Control", "name": "Continue", "kind": Model.Kind.CONTINUE, "fields": {}},
		{"cat": "Flow Control", "name": "Pass", "kind": Model.Kind.PASS, "fields": {}},
		# Actions
		{"cat": "Actions", "name": "Statement", "kind": Model.Kind.STATEMENT, "fields": {}},
		{"cat": "Actions", "name": "Print", "kind": Model.Kind.PRINT, "fields": {}},
		{"cat": "Actions", "name": "Comment", "kind": Model.Kind.COMMENT, "fields": {}},
		# Variables
		{"cat": "Variables", "name": "Signal", "kind": Model.Kind.SIGNAL_DECL, "fields": {}},
		# Enum / Dictionary: born with a unique name and editable through forms
		# (add / rename / reorder / remove rows), no syntax needed.
		{"cat": "Variables", "name": "Enum", "kind": Model.Kind.DECLARATION, "fields": {"new_enum": true}},
		{"cat": "Variables", "name": "Dictionary Variable", "kind": Model.Kind.VAR_DECL, "fields": {"new_dict": true}},
		{"cat": "Variables", "name": "Array Variable", "kind": Model.Kind.VAR_DECL, "fields": {"new_array": true}},
		{"cat": "Variables", "name": "Get Variable", "kind": Model.Kind.VARIABLE_GET, "fields": {}},
		{"cat": "Variables", "name": "Set Variable", "kind": Model.Kind.VARIABLE_SET, "fields": {}},
		# Constants
		{"cat": "Constants", "name": "Literal int", "kind": Model.Kind.LITERAL, "fields": {"type": Types.PinType.INT}},
		{"cat": "Constants", "name": "Literal float", "kind": Model.Kind.LITERAL, "fields": {"type": Types.PinType.FLOAT}},
		{"cat": "Constants", "name": "Literal string", "kind": Model.Kind.LITERAL, "fields": {"type": Types.PinType.STRING}},
		{"cat": "Constants", "name": "Literal bool", "kind": Model.Kind.LITERAL, "fields": {"type": Types.PinType.BOOL}},
		{"cat": "Constants", "name": "Literal Vector2", "kind": Model.Kind.LITERAL, "fields": {"type": Types.PinType.VECTOR2}},
		{"cat": "Constants", "name": "Literal Vector3", "kind": Model.Kind.LITERAL, "fields": {"type": Types.PinType.VECTOR3}},
		{"cat": "Constants", "name": "Literal Color", "kind": Model.Kind.LITERAL, "fields": {"type": Types.PinType.COLOR}},
		{"cat": "Constants", "name": "Literal Array", "kind": Model.Kind.LITERAL, "fields": {"type": Types.PinType.ARRAY}},
		{"cat": "Constants", "name": "Literal Dictionary", "kind": Model.Kind.LITERAL, "fields": {"type": Types.PinType.DICTIONARY}},
		# Operators
		{"cat": "Operators", "name": "Add (+)", "kind": Model.Kind.OPERATOR, "fields": {"op": "+"}},
		{"cat": "Operators", "name": "Subtract (-)", "kind": Model.Kind.OPERATOR, "fields": {"op": "-"}},
		{"cat": "Operators", "name": "Multiply (*)", "kind": Model.Kind.OPERATOR, "fields": {"op": "*"}},
		{"cat": "Operators", "name": "Divide (/)", "kind": Model.Kind.OPERATOR, "fields": {"op": "/"}},
		{"cat": "Operators", "name": "Modulo (%)", "kind": Model.Kind.OPERATOR, "fields": {"op": "%"}},
		# Comparisons: an Operator with a comparison op always keeps exactly two
		# operand pins; it never grows a third like chainable arithmetic does.
		{"cat": "Operators", "name": "Equal (==)", "kind": Model.Kind.OPERATOR, "fields": {"op": "=="}},
		{"cat": "Operators", "name": "Not Equal (!=)", "kind": Model.Kind.OPERATOR, "fields": {"op": "!="}},
		{"cat": "Operators", "name": "Less (<)", "kind": Model.Kind.OPERATOR, "fields": {"op": "<"}},
		{"cat": "Operators", "name": "Greater (>)", "kind": Model.Kind.OPERATOR, "fields": {"op": ">"}},
		{"cat": "Operators", "name": "Less or Equal (<=)", "kind": Model.Kind.OPERATOR, "fields": {"op": "<="}},
		{"cat": "Operators", "name": "Greater or Equal (>=)", "kind": Model.Kind.OPERATOR, "fields": {"op": ">="}},
		{"cat": "Operators", "name": "And", "kind": Model.Kind.OPERATOR, "fields": {"op": "and"}},
		{"cat": "Operators", "name": "Or", "kind": Model.Kind.OPERATOR, "fields": {"op": "or"}},
		{"cat": "Operators", "name": "Type Check (is)", "kind": Model.Kind.OPERATOR, "fields": {"op": "is"}},
		{"cat": "Operators", "name": "Cast (as)", "kind": Model.Kind.OPERATOR, "fields": {"op": "as"}},
		{"cat": "Operators", "name": "Contains (in)", "kind": Model.Kind.OPERATOR, "fields": {"op": "in"}},
		{"cat": "Operators", "name": "Bitwise XOR (^)", "kind": Model.Kind.OPERATOR, "fields": {"op": "^"}},
		{"cat": "Operators", "name": "Shift Left (<<)", "kind": Model.Kind.OPERATOR, "fields": {"op": "<<"}},
		{"cat": "Operators", "name": "Shift Right (>>)", "kind": Model.Kind.OPERATOR, "fields": {"op": ">>"}},
		# Functions category: functions first (leftmost bands after the header),
		# then the data-declaration grids.
		{"cat": "Functions", "name": "Script Header", "kind": Model.Kind.PREAMBLE, "fields": {}},
		{"cat": "Functions", "name": "Function", "kind": Model.Kind.ENTRY, "fields": {}},
		# Static Func: a Function node born with static = true (the per-node
		# Static checkbox is gone from the UI; this is the authoring path).
		{"cat": "Functions", "name": "Static Func", "kind": Model.Kind.ENTRY, "fields": {"static": true, "name": "new_static_function"}},
		# Setter / Getter: created exactly like a Function (this menu), then
		# the variable is picked on the node; the body is built from nodes.
		{"cat": "Functions", "name": "Setter", "kind": Model.Kind.ENTRY, "fields": {"accessor": "set"}},
		{"cat": "Functions", "name": "Getter", "kind": Model.Kind.ENTRY, "fields": {"accessor": "get"}},
		{"cat": "Functions", "name": "Function Argument", "kind": Model.Kind.ARGUMENT, "fields": {}},
		{"cat": "Functions", "name": "Function Call", "kind": Model.Kind.CALL, "fields": {}},
		# Lambda: an inline Callable literal with typed parameter rows and an
		# editable body; its Callable output wires wherever a callback argument
		# is taken (Array.append, function parameters, signal connects).
		{"cat": "Functions", "name": "Lambda", "kind": Model.Kind.LAMBDA, "fields": {}},
	]
	_menu_catalog = _catalog.duplicate()


func _ready() -> void:
	connection_lines_curvature = 0.45
	connection_lines_thickness = Types.DATA_WIRE_THICKNESS
	connection_lines_antialiased = true
	minimap_enabled = false
	right_disconnects = true   # dragging from an occupied output detaches the wire
	# Toolbar parity with the reference editor: numeric zoom % readout and a
	# grid-pattern picker (Dots/Lines) next to the built-in grid controls.
	show_zoom_label = true
	grid_pattern = GraphEdit.GRID_PATTERN_DOTS
	_setup_toolbar()
	add_theme_color_override("grid_major", Color("#2a2c2f"))
	add_theme_color_override("grid_minor", UiStyle.GRID_DOT)
	add_theme_color_override("connection_rim_color", Color(0.04, 0.04, 0.05, 0.6))
	add_theme_stylebox_override("panel", UiStyle.flat(UiStyle.CANVAS_BG, Color(0, 0, 0, 0), 0, 0, 0.0, 0.0))
	# The canvas takes focus for keyboard shortcuts; the default focus style
	# would paint a loud accent frame around the whole graph. Use a subtle
	# hairline instead.
	var foc: StyleBoxFlat = StyleBoxFlat.new()
	foc.draw_center = false
	foc.border_color = UiStyle.ACCENT_DIM
	foc.set_border_width_all(1)
	foc.set_corner_radius_all(0)
	add_theme_stylebox_override("focus", foc)
	for pair: Array in Types.valid_pairs():
		add_valid_connection_type(int(pair[0]), int(pair[1]))
	for t: int in Types.TYPE_COLORS.keys():
		add_valid_left_disconnect_type(int(t))
		add_valid_right_disconnect_type(int(t))
	# Pin tooltips ("Integer", "Vector2", ...) from the same type table.
	var names: Dictionary = {}
	for t: int in Types.TYPE_COLORS.keys():
		names[int(t)] = Types.type_name(int(t))
	type_names = names
	_font = _code_font()
	_font_size = _code_font_size()
	node_selected.connect(_on_nav_selected)
	popup_request.connect(_on_popup_request)
	connection_drag_started.connect(_on_connection_drag_started)
	connection_to_empty.connect(_on_connection_to_empty)
	connection_from_empty.connect(_on_connection_from_empty)
	connection_request.connect(_on_connection_request)
	disconnection_request.connect(_on_disconnection_request)
	delete_nodes_request.connect(_on_delete_nodes_request)
	modified.connect(_schedule_diagnostics)


# ---- Building ----------------------------------------------------------------
## Rebuilds the whole graph view from GDScript source. Positions are derived
## from graph structure (never persisted).
func build_from_text(text: String) -> void:
	exit_function_focus()
	clear_all()
	model.build(text)
	_sync_views()
	_schedule_diagnostics(0.1)


func clear_all() -> void:
	_reset_diagnostics()
	_selected_wire = {}
	clear_connections()
	for id: int in views:
		views[id].get_parent().remove_child(views[id])
		views[id].queue_free()
	views.clear()
	model.clear()


func _sync_views() -> void:
	# Create one view per model node, laid out by structural depth.
	for id: int in model.nodes:
		_make_view(id)
	_layout()
	_sync_connections()
	_update_status()


func _make_view(id: int) -> NodeView:
	var v: NodeView = NodeView.new()
	# add before setup: setup builds child controls whose suggest popups need
	# the view to already live in the tree (they resolve a viewport).
	add_child(v)
	v.model_ref = model
	v.setup(model.nodes[id], _font, _font_size)
	v.pin_value_changed.connect(_on_pin_value_changed)
	v.body_text_changed.connect(_on_body_text_changed)
	v.field_changed.connect(_on_field_changed)
	v.match_action.connect(_on_match_action)
	v.annotation_action.connect(_on_annotation_action)
	v.accessor_owner_picked.connect(_on_accessor_owner_picked)
	v.field_edit_started.connect(_on_field_edit_started)
	v.field_committed.connect(_on_field_committed)
	v.lambda_action.connect(_on_lambda_action)
	v.argument_action.connect(_on_argument_action)
	v.call_arg_action.connect(_on_call_arg_action)
	v.value_suggest = _value_suggestions
	views[id] = v
	v.position_offset_changed.connect(_mark_wires_dirty)
	v.resized.connect(_mark_wires_dirty)
	# while one function is isolated, a view is visible only when it belongs
	# to that function or was created after the isolation began (nodes the
	# person spawns while editing, undo-restored nodes, ...)
	v.visible = _focus_entry < 0 or _focused_set.has(id) or id >= _focus_new_from
	# a rebuilt view keeps showing the problems that belong to its node
	if _diag_by_node.has(id):
		v.set_diagnostics(_diag_by_node[id] as Array)
	return v


## True when the model node's pin structure no longer matches what the view
## was built with (e.g. the variable's Default Value pin appeared/vanished).
func _view_structure_changed(v: NodeView, n: Dictionary) -> bool:
	if v.data_in_count() != n["data_ins"].size():
		return true
	if not v.accessor_layout_matches(n):
		return true   # a verbatim accessor block appeared / went away
	var out_data: int = 0
	for d: Dictionary in v._out_defs:
		if d["kind"] == "data":
			out_data += 1
	return out_data != n["data_outs"].size()


## Rebuilds a view after an annotation row was added or removed (the row
## structure changed but the pins did not).
func _rebuild_annotation_view(id: int) -> void:
	if not model.nodes.has(id):
		return
	if views.has(id):
		_rebuild_view(id)
		_sync_connections()
		_restack_annotations(id)
	_update_status()


## Re-stacks one declaration's registered Annotation nodes directly above it:
## slot order top-to-bottom, LAYOUT_ANN_GAP between nodes, the declaration
## itself never moves. Waits one frame so the engine has measured the
## (possibly rebuilt) views. Used after every register / unregister / move of
## an annotation so live edits keep the same placement as a fresh load.
func _restack_annotations(tid: int) -> void:
	if not is_inside_tree():
		return
	await get_tree().process_frame
	if not views.has(tid) or not model.nodes.has(tid):
		return
	if int(model.nodes[tid]["kind"]) == Model.Kind.PREAMBLE:
		_restack_header_left(tid)
		return
	var links: Array = []
	for l: Dictionary in model.ann_links:
		if int(l["tid"]) == tid and views.has(int(l["aid"])):
			links.append(l)
	links.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.get("slot", 0)) < int(b.get("slot", 0)))
	var tv: NodeView = views[tid]
	var y: float = tv.position_offset.y
	for i: int in links.size():
		var av: NodeView = views[int(links[i]["aid"])]
		_place(av, Vector2(tv.position_offset.x - LAYOUT_ANN_SIDE_GAP - maxf(av.size.x, av.get_combined_minimum_size().x), y))
		y += av.size.y + LAYOUT_ANN_GAP


## Re-stacks the Script Header's dedicated LEFT area: Script Class Name, then
## Script Extension, then the script-level Annotation nodes (slot order), all
## right-aligned just left of the header, starting level with it and stacked
## top-to-bottom with LAYOUT_ANN_GAP between nodes. The header never moves.
func _restack_header_left(hid: int) -> void:
	if not views.has(hid):
		return
	var hv: NodeView = views[hid]
	var right_edge: float = hv.position_offset.x - LAYOUT_COL_GAP_LEFT
	var y: float = hv.position_offset.y
	for id: int in _header_left_ids(hid):
		var v: NodeView = views[id]
		_place(v, Vector2(right_edge - maxf(v.size.x, v.get_combined_minimum_size().x), y))
		y += v.size.y + LAYOUT_ANN_GAP


## Ids (with views) of the nodes in a header's left area, in stacking order.
func _header_left_ids(hid: int) -> Array:
	var out: Array = []
	for want: int in [Model.Kind.CLASS_NAME, Model.Kind.EXTENDS_DECL]:
		for hl: Dictionary in model.header_links:
			var nid: int = int(hl["nid"])
			if int(hl["hid"]) == hid and views.has(nid) and model.nodes.has(nid) \
					and int(model.nodes[nid]["kind"]) == want:
				out.append(nid)
	var links: Array = []
	for l: Dictionary in model.ann_links:
		if int(l["tid"]) == hid and views.has(int(l["aid"])):
			links.append(l)
	links.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.get("slot", 0)) < int(b.get("slot", 0)))
	for l2: Dictionary in links:
		if not out.has(int(l2["aid"])):
			out.append(int(l2["aid"]))
	return out


## Declaration an Annotation node is currently registered on (-1 when none).
func _annotation_owner_of(aid: int) -> int:
	for l: Dictionary in model.ann_links:
		if int(l["aid"]) == aid:
			return int(l["tid"])
	return -1


## Rebuilds a view (keeping its position) when dynamic-input growth/shrinkage
## changed the node's pin count. Returns true when it rebuilt.
## Rebuilds the views of scope-owning nodes (Function / If / loops ...) after
## their named scope pins changed: a variable registered or removed grows or
## drops its pin (with the variable's name beside it); `force` also redraws
## the views when only a variable's name changed.
func _refresh_scope_hosts(hosts: Array, force: bool = false) -> void:
	for h: Variant in hosts:
		var hid: int = int(h)
		if not views.has(hid) or not model.nodes.has(hid):
			continue
		if force:
			_rebuild_view(hid)
		else:
			_maybe_rebuild_pins(views[hid])


func _maybe_rebuild_pins(v: NodeView) -> bool:
	if v == null or not is_instance_valid(v) or not model.nodes.has(v.model_id):
		return false
	if _view_structure_changed(v, model.nodes[v.model_id]):
		_rebuild_view(v.model_id)
		return true
	return false


# ---- Undo / Redo for structured property edits ---------------------------------
## The UndoRedo to commit into. The workspace injects the editor's history
## (EditorPlugin.get_undo_redo()) so Function/Variable edits join the editor's
## unified undo system; standalone/test usage falls back to a local history.
var undo_redo: UndoRedo = null
var _local_undo: UndoRedo = UndoRedo.new()
var _pending_edit: Dictionary = {}   # {id, key, text, links} snapshot before typing
## Nodes whose last field edit was refused by the model: their text box shows
## the refused text until the edit is committed, then the view is rebuilt so it
## shows the value that is really in use.
var _rejected_edits: Dictionary = {}


func _ur() -> UndoRedo:
	return undo_redo if undo_redo != null else _local_undo


## The property value the model currently holds for (id, key).
func _prop_value(id: int, key: String) -> String:
	var n: Dictionary = model.nodes.get(id, {})
	if n.is_empty():
		return ""
	match int(n["kind"]):
		Model.Kind.ENTRY:
			return String(n["fields"].get(key, ""))
		Model.Kind.ARGUMENT:
			return String(n["fields"].get(key, ""))
		Model.Kind.CALL:
			return String(n["fields"].get(key, ""))
		Model.Kind.LAMBDA:
			# composite keys: param:<i>:<name|type|default>
			var lparts: PackedStringArray = key.split(":")
			if lparts[0] == "param":
				var li: int = int(lparts[1])
				var lprms: Array = n["fields"].get("params", [])
				if li >= 0 and li < lprms.size():
					return String(lprms[li].get(lparts[2], ""))
				return ""
			return String(n["fields"].get(key, ""))
		Model.Kind.CLASS_REF:
			return String(n["fields"].get(key, ""))
		Model.Kind.VAR_DECL:
			if key == "default":
				return String(n["data_ins"][0]["value"]) if n["data_ins"].size() > 0 else ""
			if key == "type":
				return String(n["fields"].get("raw_type", ""))
			if key == "annotations":
				return "\\n".join(model.annotations_of(id))
			# accessor flags (has_setter / has_getter) are booleans: str(), not String()
			return str(n["fields"].get(key, ""))
		Model.Kind.PREAMBLE:
			# key "header:N": the directive line currently at index N
			if key.begins_with("header:"):
				var lines: PackedStringArray = String(n["body"]).split("\\n")
				var li: int = int(key.trim_prefix("header:"))
				return lines[li] if li >= 0 and li < lines.size() else ""
	return ""


func _on_field_edit_started(id: int, key: String) -> void:
	_pending_edit = {"id": id, "key": key, "text": _prop_value(id, key),
		"links": model.data_links.duplicate(true)}


func _on_field_committed(id: int, key: String, old_text: String) -> void:
	var n: Dictionary = model.nodes.get(id, {})
	var k: int = int(n.get("kind", -1))
	if _rejected_edits.has(id):
		# a refused edit: show the value that is really in use again
		_rejected_edits.erase(id)
		if views.has(id):
			_rebuild_view.call_deferred(id)
	# A variable whose type just became (or stopped being) Dictionary or
	# Array swaps its Value editor; done on commit so typing the type never loses focus.
	if key == "type" and k == Model.Kind.VAR_DECL and views.has(id) \
			and not views[id].dict_editor_matches(n):
		_rebuild_view.call_deferred(id)
	if k != Model.Kind.ENTRY and k != Model.Kind.ARGUMENT \
			and k != Model.Kind.VAR_DECL and k != Model.Kind.CALL \
			and k != Model.Kind.PREAMBLE and k != Model.Kind.CLASS_REF \
			and k != Model.Kind.LAMBDA:
		_pending_edit = {}   # not an undo-managed property field
		return
	var new_val: String = _prop_value(id, key)
	var before_links: Array = []
	var old_for_undo: String = old_text
	if not _pending_edit.is_empty() and int(_pending_edit["id"]) == id \
			and str(_pending_edit["key"]) == key:
		before_links = _pending_edit["links"]
		# annotation/header edits snapshot the whole list/header at edit
		# start (the view only knows the single row's old text)
		old_for_undo = str(_pending_edit["text"])
		_pending_edit = {}
	if new_val == old_text:
		return   # nothing changed in this session
	if before_links.is_empty() and not model.data_links.is_empty():
		# defensive: a commit without a matching session start still gets a
		# usable snapshot (best effort) instead of wiping links on undo
		before_links = model.data_links.duplicate(true)
	var after_links: Array = model.data_links.duplicate(true)
	var ur: UndoRedo = _ur()
	ur.create_action(_action_title(id, key))
	ur.add_do_method(_apply_prop.bind(id, key, new_val, after_links))
	ur.add_undo_method(_apply_prop.bind(id, key, old_for_undo, before_links))
	ur.commit_action()


## Applies a property value and restores an exact link set — used for both the
## do and the undo side, so undoing a type change also restores the connections
## that were dropped by validation.
func _apply_prop(id: int, key: String, val: String, links: Array) -> void:
	var n: Dictionary = model.nodes.get(id, {})
	if n.is_empty():
		return
	match int(n["kind"]):
		Model.Kind.ENTRY:
			model.set_entry_prop(id, key, val)
		Model.Kind.ARGUMENT:
			model.set_arg_prop(id, key, val)
		Model.Kind.PREAMBLE:
			if key.begins_with("header:"):
				model.set_header_line(id, int(key.trim_prefix("header:")), val)
		Model.Kind.CALL:
			model.set_field(id, key, val)
			if key == "call":
				model.sync_call_signature(id)
		Model.Kind.CLASS_REF:
			model.set_field(id, key, val)
		Model.Kind.LAMBDA:
			model.set_lambda_prop(id, key, val)
		Model.Kind.VAR_DECL:
			model.set_var_prop(id, key, val)
		_:
			return
	model.data_links = (links as Array).duplicate(true)
	if views.has(id):
		var v: NodeView = views[id]
		if _view_structure_changed(v, model.nodes[id]):
			_rebuild_view(id)
		else:
			v.refresh(model.nodes[id])
	_sync_connections()
	modified.emit()
	_update_status()


func _action_title(id: int, key: String) -> String:
	var k: int = int(model.nodes[id]["kind"]) if model.nodes.has(id) else -1
	if k == Model.Kind.CALL:
		return "Set Call Target"
	if k == Model.Kind.CLASS_REF:
		match key:
			"target":
				return "Set Class Reference"
			"ref":
				return "Set Reference Mode"
			_:
				return "Set Instance Source"
	if k == Model.Kind.ENTRY:
		return "Set Function Name" if key == "name" else "Set Return Type"
	if k == Model.Kind.ARGUMENT:
		match key:
			"name":
				return "Set Argument Name"
			"type":
				return "Set Argument Data Type"
			_:
				return "Set Argument Default Value"
	if k == Model.Kind.VAR_DECL:
		match key:
			"name":
				return "Set Variable Name"
			"type":
				return "Set Variable Data Type"
			"has_setter", "setter", "setter_arg":
				return "Set Variable Setter"
			"has_getter", "getter":
				return "Set Variable Getter"
			"tail":
				return "Set Variable Accessors"
			_:
				return "Set Variable Default Value"
	if k == Model.Kind.LAMBDA:
		var lparts: PackedStringArray = key.split(":")
		if lparts[0] == "param":
			match lparts[2]:
				"name":
					return "Set Lambda Parameter"
				"type":
					return "Set Lambda Parameter Type"
				_:
					return "Set Lambda Parameter Default"
		if key == "ret":
			return "Set Lambda Return Type"
		return "Set Lambda Body"
	return "Set Property"


## Ctrl+Z / Ctrl+Shift+Z / Ctrl+Y while the graph itself is focused (no text
## field is being edited; a focused LineEdit keeps its native text undo).
func _shortcut_input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	var key: InputEventKey = event as InputEventKey
	if key == null or not key.pressed:
		return
	if not (key.is_command_or_control_pressed() and (key.keycode == KEY_Z or key.keycode == KEY_Y)):
		return
	var focus: Control = get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit or focus is CodeEdit:
		return   # native text undo owns the shortcut while editing text
	var ur: UndoRedo = _ur()
	if key.keycode == KEY_Z and not key.shift_pressed:
		if ur.has_undo():
			ur.undo()
			get_viewport().set_input_as_handled()
	elif (key.keycode == KEY_Z and key.shift_pressed) or key.keycode == KEY_Y:
		if ur.has_redo():
			ur.redo()
			get_viewport().set_input_as_handled()


## Left-to-right BFS depth layout (session-only; never persisted). Phase 1
## stacks nodes with an estimate; a deferred phase 2 restacks with the real
## measured heights so nodes in a column never overlap.
##
## Cluster banding keeps the depth-map sorting as the foundation: nodes are
## grouped into logical clusters (global variables, signals, constants, and
## one independent cluster per function with its arguments, locals and
## operations). Each cluster stacks with the same depth-column algorithm in
## its own horizontal band; bands are separated by a clear gap.
const LAYOUT_COL_PITCH := 320.0   # was 300: slightly more breathing room
const LAYOUT_ROW_GAP := 60.0      # was 46 (estimated-height pass)
const LAYOUT_ROW_GAP_REAL := 56.0 # was 42 (real-height pass)
const LAYOUT_CLUSTER_GAP := 110.0 # clear visual gap between clusters
const LAYOUT_COL_GAP_LEFT := 40.0 # gap between header metadata nodes and the header
const LAYOUT_ANN_SIDE_GAP := 24.0 # gap between a declaration and its annotations on its left
const LAYOUT_ANN_GAP := 8.0       # gap between stacked annotations and their declaration

func _layout() -> void:
	var depth: Dictionary = _depth_map()
	_layout_pass(depth, _cluster_map(), false)
	_place_diag_nodes()
	_relayout_real_deferred()


func _depth_map() -> Dictionary:
	var depth: Dictionary = {}
	var queue: Array = []
	for r: Dictionary in model.roots:
		if r.has("node") and views.has(int(r["node"])):
			depth[int(r["node"])] = 0
			queue.append(int(r["node"]))
		if r.has("entry") and views.has(int(r["entry"])):
			depth[int(r["entry"])] = 0
			queue.append(int(r["entry"]))
	var head: int = 0
	while head < queue.size():
		var cur: int = queue[head]
		head += 1
		for port: int in model.exec_out.get(cur, {}):
			var nxt: int = int(model.exec_out[cur][port])
			if not depth.has(nxt) or depth[nxt] < depth[cur] + 1:
				depth[nxt] = depth[cur] + 1
				queue.append(nxt)
	# Argument nodes and function-local declarations are data sources of
	# their function. Arguments sit one column LEFT of the function node
	# (the Function reads them from its left side, Blueprint-style); hoisted
	# locals sit one column right so the function's column holds only the
	# entry and its arguments.
	var meta_owner: Dictionary = {}
	for hl: Dictionary in model.header_links:
		meta_owner[int(hl["nid"])] = int(hl["hid"])
	for id: int in model.nodes:
		var k: int = int(model.nodes[id]["kind"])
		var pid: int = -1
		var left: bool = false
		if k == Model.Kind.ARGUMENT:
			pid = int(model.nodes[id]["fields"].get("parent", -1))
			left = true
		elif k == Model.Kind.VAR_DECL:
			# private (function-local) variables sit LEFT of their function,
			# level with its arguments
			pid = int(model.nodes[id]["fields"].get("owner", -1))
			left = true
		elif k == Model.Kind.CLASS_NAME or k == Model.Kind.EXTENDS_DECL:
			# Script header metadata nodes sit one column LEFT of the header
			# (part of the header cluster, never stacked underneath it).
			pid = int(meta_owner.get(id, -1))
			left = true
		if pid >= 0 and depth.has(pid) and k == Model.Kind.VAR_DECL:
			# a function-local (private) variable always sits one column
			# LEFT of its function, even when it is part of the exec chain
			depth[id] = int(depth[pid]) - 1
		elif pid >= 0 and depth.has(pid) and not depth.has(id):
			depth[id] = int(depth[pid]) - 1 if left else int(depth[pid]) + 1
	return depth


func _relayout_real_deferred() -> void:
	# Let the engine lay out the GraphNodes, then restack with real heights.
	await get_tree().process_frame
	await get_tree().process_frame
	if views.is_empty() or not is_inside_tree():
		return
	var depth: Dictionary = _depth_map()
	_layout_pass(depth, _cluster_map(), true)
	# Widths settle a frame or two after the first real pass (value editors,
	# rebuilt pins): re-run until no node width changed, so side-by-side
	# nodes (annotations beside declarations) never overlap.
	for _i: int in 3:
		var before: Dictionary = {}
		for wid: int in views:
			before[wid] = _node_w(wid)
		await get_tree().process_frame
		await get_tree().process_frame
		if views.is_empty() or not is_inside_tree():
			return
		var changed: bool = false
		for wid2: int in views:
			if not before.has(wid2) or absf(float(before[wid2]) - _node_w(wid2)) > 0.5:
				changed = true
		if not changed:
			break
		_layout_pass(_depth_map(), _cluster_map(), true)
	# Error / Warning nodes follow their (now final) source nodes
	_place_diag_nodes()
	# With problems on the graph, land the view on the problems (all of them
	# at once) instead of the header; without problems, the old behavior.
	if _diag_nodes.is_empty():
		# After loading a script the topmost node (usually the Script Header)
		# must be fully visible instead of cut off behind the toolbar.
		_scroll_content_to_top()
	else:
		_scroll_to_diag_nodes()


## One stacking pass over the cluster bands (relative coordinates first, so
## band offsets can be assigned top-to-bottom once every cluster height is
## known). Identical column algorithm to the previous single-stack layout —
## just applied per cluster with the slightly increased row spacing.
func _layout_pass(depth: Dictionary, cluster: Dictionary, real: bool) -> void:
	var order: Array = _cluster_order(cluster)
	var row_gap: float = LAYOUT_ROW_GAP_REAL if real else LAYOUT_ROW_GAP
	var rel_pos: Dictionary = {}  # node id -> position relative to its band
	var band_h: Dictionary = {}   # cluster -> band height
	# Annotation nodes registered on a declaration are laid out WITH that
	# declaration: stacked in the declaration's own column, in registration
	# (slot) order, directly above it. ann_of: target id -> [annotation ids];
	# ann_h: target id -> height of that stack including the trailing gap.
	var ann_of: Dictionary = {}
	var ann_member: Dictionary = {}
	var links: Array = []
	for l: Dictionary in model.ann_links:
		if views.has(int(l["aid"])) and views.has(int(l["tid"])) and not ann_member.has(int(l["aid"])):
			links.append(l)
			ann_member[int(l["aid"])] = true
	links.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.get("slot", 0)) < int(b.get("slot", 0)))
	var ann_h: Dictionary = {}
	var hdr_ann: Dictionary = {}   # header id -> [annotation ids] (left area)
	for l2: Dictionary in links:
		var tid: int = int(l2["tid"])
		if int(model.nodes.get(tid, {}).get("kind", -1)) == Model.Kind.PREAMBLE:
			# script-level annotations live in the header's left area, not
			# stacked above the header
			if not hdr_ann.has(tid):
				hdr_ann[tid] = []
			(hdr_ann[tid] as Array).append(int(l2["aid"]))
			continue
		if not ann_of.has(tid):
			ann_of[tid] = []
			ann_h[tid] = 0.0
		(ann_of[tid] as Array).append(int(l2["aid"]))
		ann_h[tid] = float(ann_h[tid]) + _node_h(int(l2["aid"]), real) + LAYOUT_ANN_GAP
	# Annotation lane: every declaration column reserves a strip on its LEFT
	# for its annotation nodes (and wired @export_group nodes), so annotations
	# sit left of what they annotate and never overlap the neighbouring column.
	var flow_order: Dictionary = _flow_order()
	for cid: String in order:
		# the left strip is reserved only in clusters that have annotations
		# (other clusters keep the compact column spacing)
		var lane: float = _annotation_lane(hdr_ann, cluster, cid)
		var ids: Array = []
		for id: int in views:
			if str(cluster.get(id, "misc")) == cid and not ann_member.has(id):
				ids.append(id)
		if cid.begins_with("func:"):
			# Flow nodes stack in execution-tree order (a node's lower exec
			# output subtree always comes after its upper output subtree),
			# so the wires of a node with two outputs (True/False, loop
			# body/done) never cross each other.
			var pos_of: Dictionary = {}
			for ii: int in ids.size():
				pos_of[ids[ii]] = ii
			ids.sort_custom(func(a: int, b: int) -> bool:
				# arguments first (they sit left of the function), then the rest
				var ka: int = -1000000 if int(model.nodes[a]["kind"]) == Model.Kind.ARGUMENT else 0
				var kb: int = -1000000 if int(model.nodes[b]["kind"]) == Model.Kind.ARGUMENT else 0
				var oa: int = ka + int(flow_order.get(a, 1000000 + int(pos_of[a])))
				var ob: int = kb + int(flow_order.get(b, 1000000 + int(pos_of[b])))
				return oa < ob)
		var bottom: float = 0.0
		if cid == "var" or cid == "enum" or cid == "const" or cid == "signal":
			# Data-declaration categories spread over a balanced grid; anything
			# else in the band (private member variables) keeps column stacking.
			bottom = _stack_decl_grid(ids, cid, rel_pos, row_gap, real, ann_h, lane)
		var cols: Dictionary = {}
		var header_id: int = -1
		for id: int in ids:
			if rel_pos.has(id):
				continue   # grid member, already positioned
			var mk: int = int(model.nodes.get(id, {}).get("kind", -1))
			if mk == Model.Kind.CLASS_NAME or mk == Model.Kind.EXTENDS_DECL:
				continue   # placed beside the header below
			if _group_anchor(id) >= 0 and str(cluster.get(_group_anchor(id), "")) == cid:
				continue   # @export_group: placed left of its members below
			if mk == Model.Kind.PREAMBLE:
				header_id = id
			var d: int = int(depth.get(id, 0))
			var y: float = float(cols.get(d, 0.0))
			# Function clusters shift one column right: their arguments occupy
			# column 0 (left of the function), so the entry never sits at the
			# band's left edge without its arguments beside it.
			var col: int = d + 1 if cid.begins_with("func:") else d
			var node_h: float = maxf(_node_h(id, real), float(ann_h.get(id, 0.0)))
			rel_pos[id] = Vector2(lane + float(col) * (LAYOUT_COL_PITCH + lane), y)
			cols[d] = y + node_h + row_gap
			bottom = maxf(bottom, cols[d])
		# Script Class Name / Extension nodes sit LEFT of the header, level
		# with it, stacked top-to-bottom (class name first) so they never
		# overlap each other.
		if header_id >= 0:
			var my: float = rel_pos[header_id].y
			for want: int in [Model.Kind.CLASS_NAME, Model.Kind.EXTENDS_DECL]:
				for id3: int in ids:
					if int(model.nodes.get(id3, {}).get("kind", -1)) != want:
						continue
					# right-aligned just left of the header whatever the node's
					# width (the Extension node is wider than a layout column)
					rel_pos[id3] = Vector2(rel_pos[header_id].x - LAYOUT_COL_GAP_LEFT - _node_w(id3), my)
					my += _node_h(id3, real) + LAYOUT_ANN_GAP
			# script-level annotations continue the same left column
			for aid2: int in hdr_ann.get(header_id, []):
				rel_pos[aid2] = Vector2(rel_pos[header_id].x - LAYOUT_COL_GAP_LEFT - _node_w(aid2), my)
				my += _node_h(aid2, real) + LAYOUT_ANN_GAP
			bottom = maxf(bottom, my - LAYOUT_ANN_GAP + row_gap)
		# Annotation stacks: directly above their declaration, in order.
		for id4: int in ids:
			if not ann_of.has(id4) or not rel_pos.has(id4):
				continue
			var ay: float = rel_pos[id4].y
			for aid: int in ann_of[id4]:
				rel_pos[aid] = Vector2(rel_pos[id4].x - LAYOUT_ANN_SIDE_GAP - _node_w(aid), ay)
				ay += _node_h(aid, real) + LAYOUT_ANN_GAP
		# @export_group nodes: a column LEFT of the band, level with their
		# first member annotation, never overlapping each other.
		var gids: Array = []
		for idg: int in ids:
			if not rel_pos.has(idg) and _group_anchor(idg) >= 0 \
					and rel_pos.has(_group_anchor(idg)):
				gids.append(idg)
		gids.sort_custom(func(a: int, b: int) -> bool:
			return rel_pos[_group_anchor(a)].y < rel_pos[_group_anchor(b)].y)
		var gy: float = -INF
		for idg2: int in gids:
			var gyy: float = maxf(rel_pos[_group_anchor(idg2)].y, gy)
			rel_pos[idg2] = Vector2(rel_pos[_group_anchor(idg2)].x - LAYOUT_ANN_SIDE_GAP - _node_w(idg2), gyy)
			gy = gyy + _node_h(idg2, real) + LAYOUT_ANN_GAP
			bottom = maxf(bottom, gy - LAYOUT_ANN_GAP + row_gap)
		band_h[cid] = maxf(bottom - row_gap, 0.0)
	var band: float = 40.0
	for cid: String in order:
		for id: int in views:
			if str(cluster.get(id, "misc")) != cid or not rel_pos.has(id):
				continue
			_place(views[id], Vector2(40.0 + rel_pos[id].x, band + rel_pos[id].y))
		band += float(band_h[cid]) + LAYOUT_CLUSTER_GAP


## Node width for layout: never narrower than the node's minimum size, so a
## node whose content widened after the last measurement cannot end up
## overlapping the declaration it sits beside.
func _node_w(id: int) -> float:
	var v: NodeView = views[id]
	return maxf(v.size.x, v.get_combined_minimum_size().x)


func _node_h(id: int, real: bool) -> float:
	return views[id].size.y if real else float(_est_height(views[id]))


## Depth-first pre-order of the exec graph, lowest output port first: node ->
## sequence number. A node's port-0 subtree gets smaller numbers than its
## port-1 subtree, which keeps sibling branches in wire order when stacked.
func _flow_order() -> Dictionary:
	var out: Dictionary = {}
	var n: int = 0
	for r: Dictionary in model.roots:
		if not r.has("entry") or not views.has(int(r["entry"])):
			continue
		var stack: Array = [int(r["entry"])]
		while not stack.is_empty():
			var cur: int = int(stack.pop_back())
			if out.has(cur):
				continue
			out[cur] = n
			n += 1
			var ports: Array = (model.exec_out.get(cur, {}) as Dictionary).keys()
			ports.sort()
			ports.reverse()
			for port: Variant in ports:
				var nxt: int = int(model.exec_out[cur][port])
				if views.has(nxt) and not out.has(nxt):
					stack.append(nxt)
	return out


## Width of the strip reserved left of each declaration column: the widest
## non-header annotation node plus, when export groups are wired, the widest
## group node, each with the standard gap. Zero when nothing needs a strip.
func _annotation_lane(hdr_ann: Dictionary, cluster: Dictionary, cid: String) -> float:
	var aw: float = 0.0
	var skip: Dictionary = {}
	for hid: int in hdr_ann:
		for a: int in hdr_ann[hid]:
			skip[a] = true
	for l: Dictionary in model.ann_links:
		var aid: int = int(l["aid"])
		if views.has(aid) and views.has(int(l["tid"])) and not skip.has(aid) \
				and str(cluster.get(int(l["tid"]), "misc")) == cid:
			aw = maxf(aw, _node_w(aid))
	var gw: float = 0.0
	for gl: Dictionary in model.group_links:
		if views.has(int(gl["gid"])) and views.has(int(gl["xid"])) \
				and str(cluster.get(int(gl["xid"]), "misc")) == cid:
			gw = maxf(gw, _node_w(int(gl["gid"])))
	var lane: float = 0.0
	if aw > 0.0:
		lane += aw + LAYOUT_ANN_SIDE_GAP
	if gw > 0.0:
		lane += gw + LAYOUT_ANN_SIDE_GAP
	return lane


## Data-declaration category grids (public Variables, Enums, Constants,
## Signals — each sized independently from its own node count):
## columns = ceil(sqrt(n)), rows fill left-to-right, top-to-bottom. Row
## heights come from the tallest node in each row, so vertical spacing stays
## consistent while uneven node heights never overlap. Non-member nodes in
## the same band (private member variables, annotations attached to these
## declarations) are not counted and keep the regular stacking. Returns the
## grid bottom (y cursor for the rest of the band).
@warning_ignore("integer_division")
func _stack_decl_grid(ids: Array, cid: String, rel_pos: Dictionary, row_gap: float, real: bool, ann_h: Dictionary = {}, lane: float = 0.0) -> float:
	var pub: Array = []
	for id: int in ids:
		if _grid_member(id, cid):
			pub.append(id)
	if pub.is_empty():
		return 0.0
	var cols_n: int = int(ceil(sqrt(float(pub.size()))))
	var rows_n: int = int(ceil(float(pub.size()) / float(cols_n)))
	var row_h: Array = []
	for r: int in rows_n:
		row_h.append(0.0)
	for i: int in pub.size():
		var h: float = maxf(_node_h(pub[i], real), float(ann_h.get(pub[i], 0.0)))
		row_h[i / cols_n] = maxf(float(row_h[i / cols_n]), h)
	var row_y: Array = []
	var y: float = 0.0
	for r: int in rows_n:
		row_y.append(y)
		y += float(row_h[r]) + row_gap
	for i: int in pub.size():
		rel_pos[pub[i]] = Vector2(lane + float(i % cols_n) * (LAYOUT_COL_PITCH + lane), float(row_y[i / cols_n]))
	# same convention as the column stacking cursor: the trailing gap is
	# included so the band-height math stays uniform
	return float(row_y[rows_n - 1]) + float(row_h[rows_n - 1]) + row_gap


## Membership of a node in its category's grid: public variables only in the
## "var" band (private members keep stacking below), the whole declaration
## kind in the enum / const / signal bands (annotation nodes attached to
## them stay out and keep stacking).
func _grid_member(id: int, cid: String) -> bool:
	var n: Dictionary = model.nodes[id]
	var k: int = int(n["kind"])
	match cid:
		"var":
			return k == Model.Kind.VAR_DECL \
				and str(n["fields"].get("scope", "public")) == "public"
		"enum":
			return k == Model.Kind.DECLARATION and String(n["title"]).begins_with("enum ")
		"const":
			return k == Model.Kind.CONST_DECL
		"signal":
			return k == Model.Kind.SIGNAL_DECL
		_:
			return false


## Cluster id per visible node: data declarations group by category, the
## script header and verbatim declarations/comments get small bands, and
## every function forms one cluster keyed by its root entry id (arguments,
## hoisted locals, exec-flow nodes and their data-only helpers all inherit
## it). Deterministic: only model structure is consulted.
func _cluster_map() -> Dictionary:
	var out: Dictionary = {}
	var data_next: Dictionary = {}   # from_id -> [to_id, ...] (data links)
	for l: Dictionary in model.data_links:
		var f: int = int(l["from_id"])
		if not data_next.has(f):
			data_next[f] = []
		data_next[f].append(int(l["to_id"]))
	var ann_owner: Dictionary = {}   # annotation id -> declared target id
	for l: Dictionary in model.ann_links:
		ann_owner[int(l["aid"])] = int(l["tid"])
	for id: int in views:
		if not model.nodes.has(id):
			out[id] = "misc"
			continue
		if int(model.nodes[id]["kind"]) == Model.Kind.ANNOTATION and ann_owner.has(id):
			continue   # resolved in a second pass, after the target's cluster
		var n: Dictionary = model.nodes[id]
		var k: int = int(n["kind"])
		match k:
			Model.Kind.VAR_DECL:
				var owner: int = int(n["fields"].get("owner", -1))
				out[id] = ("func:%d" % owner) if owner >= 0 else "var"
			Model.Kind.CONST_DECL:
				out[id] = "const"
			Model.Kind.SIGNAL_DECL:
				out[id] = "signal"
			Model.Kind.DECLARATION:
				if String(n["title"]) == "Comment":
					out[id] = "comments"
				elif String(n["title"]).begins_with("enum "):
					out[id] = "enum"
				else:
					out[id] = "decl"
			Model.Kind.COMMENT:
				out[id] = "comments"
			Model.Kind.PREAMBLE:
				out[id] = "header"
			Model.Kind.ARGUMENT:
				out[id] = "func:%d" % int(n["fields"].get("parent", -1))
			Model.Kind.ENTRY:
				out[id] = "func:%d" % id
			Model.Kind.CLASS_NAME, Model.Kind.EXTENDS_DECL:
				pass   # resolved in the second pass into the header's cluster
			_:
				var root: int = model._entry_of_flow_node(id)
				if root < 0:
					root = _data_owner_of(id, data_next)
				out[id] = ("func:%d" % root) if root >= 0 else "misc"
	# Second pass: annotations join their target declaration's cluster (the
	# target may appear later in the iteration order); Script Class Name and
	# Script Extension nodes join the Script Header's cluster; Class
	# Reference nodes join the cluster of their first registered member.
	var meta_owner: Dictionary = {}
	for hl: Dictionary in model.header_links:
		meta_owner[int(hl["nid"])] = int(hl["hid"])
	for id: int in views:
		if out.has(id):
			continue
		var target: int = int(ann_owner.get(id, -1))
		if target < 0:
			target = int(meta_owner.get(id, -1))
		var member_anchor: int = -1
		if target < 0 and int(model.nodes.get(id, {}).get("kind", -1)) == Model.Kind.CLASS_REF:
			for ml2: Dictionary in model.member_links:
				if int(ml2["rid"]) == id and out.has(int(ml2["cid"])):
					member_anchor = int(ml2["cid"])
					break
			if member_anchor >= 0:
				target = member_anchor
		out[id] = str(out.get(target, "misc")) if target >= 0 else "misc"
	# @export_group nodes join the cluster of the first export annotation
	# wired to them (so the group sits beside its members, not far away).
	for id: int in views:
		var anchor: int = _group_anchor(id)
		if anchor >= 0 and out.has(anchor):
			out[id] = out[anchor]
	return out


## First export annotation (with a view) wired to an @export_group node, -1
## when the node is not a wired group node.
func _group_anchor(gid: int) -> int:
	for gl: Dictionary in model.group_links:
		if int(gl["gid"]) == gid and views.has(int(gl["xid"])):
			return int(gl["xid"])
	return -1


## For data-only helper nodes (literals, operators, Get Variable nodes that
## never enter the exec flow): climb outgoing data links to the first node
## with a function owner and inherit its cluster.
func _data_owner_of(id: int, data_next: Dictionary) -> int:
	var seen: Dictionary = {id: true}
	var queue: Array = [id]
	var head: int = 0
	while head < queue.size():
		var cur: int = queue[head]
		head += 1
		for t: int in data_next.get(cur, []):
			if seen.has(t):
				continue
			seen[t] = true
			var root: int = model._entry_of_flow_node(t)
			if root >= 0:
				return root
			queue.append(t)
	return -1


## Stable band order: header, then the data-declaration clusters, comments,
## anything unattached, then one band per function following the script's
## root order (orphan function clusters last, ordered by entry id).
func _cluster_order(cluster: Dictionary) -> Array:
	var order: Array = []
	for prefix: String in ["header", "var", "enum", "signal", "const", "decl", "comments", "misc"]:
		for id: int in views:
			if str(cluster.get(id, "misc")) == prefix:
				order.append(prefix)
				break
	var seen: Dictionary = {}
	for r: Dictionary in model.roots:
		if r.has("entry") and views.has(int(r["entry"])):
			var cid: String = "func:%d" % int(r["entry"])
			if not seen.has(cid):
				seen[cid] = true
				order.append(cid)
	var orphans: Array = []
	for id: int in views:
		var c: String = str(cluster.get(id, "misc"))
		if c.begins_with("func:") and not seen.has(c):
			seen[c] = true
			orphans.append([int(c.substr(5)), c])
	orphans.sort()
	for o: Array in orphans:
		order.append(str(o[1]))
	return order


## Scrolls the view so the topmost/leftmost node sits fully inside the
## canvas with a small margin (used after every rebuild from source).
func _scroll_content_to_top() -> void:
	var top: float = INF
	var left: float = INF
	for id: int in views:
		var v: NodeView = views[id]
		top = minf(top, v.position_offset.y)
		left = minf(left, v.position_offset.x)
	if top == INF:
		return
	# _graph_to_local: local = graph * zoom - scroll_offset; keep the content's
	# top-left corner inside the canvas — enough vertical margin to clear the
	# GraphEdit toolbar strip that overlays the top of the canvas.
	scroll_offset = Vector2(left, top) * zoom - Vector2(16.0, 44.0)


## Places a view at graph coordinates (Godot 4.7 stores graph positions in
## `position_offset`; `position` is the derived screen position).
func _place(v: NodeView, graph_pos: Vector2) -> void:
	if "position_offset" in v:
		v.position_offset = graph_pos
	else:
		v.position = graph_pos


## Converts a position in canvas-local (screen) space to graph coordinates.
func _local_to_graph(p: Vector2) -> Vector2:
	return (p + scroll_offset) / zoom


## Converts graph coordinates to canvas-local (screen) space.
func _graph_to_local(p: Vector2) -> Vector2:
	return p * zoom - scroll_offset


func _est_height(v: NodeView) -> float:
	var n: Dictionary = model.nodes[v.model_id]
	var rows: int = 1
	if bool(n["exec_in"]):
		rows += 1
	rows += n["data_ins"].size() + n["data_outs"].size() + n["exec_outs"].size()
	var k: int = int(n["kind"])
	# Structured property rows (Function / Argument / Variable editors).
	if k == Model.Kind.ENTRY:
		rows += 3   # 2 property rows + Add Argument button
	elif k == Model.Kind.ARGUMENT:
		rows += 5
	elif k == Model.Kind.VAR_DECL:
		rows += 3   # Scope / Variable Name / Data Type (no preview row)
	if v._comment_look(k, String(n["body"])):
		rows += 2   # comment display: header row + roomier text body
	var body_lines: int = maxi(1, String(n["body"]).split("\n").size())
	return 34.0 + rows * 26.0 + body_lines * 15.0


## Recreates every GraphEdit wire from the model. Wires are stored at the view
## port indices (mapped through the node's data outputs), never at raw model
## pin indices, so dragging/hovering/removing wires always hits the right pin.
func _sync_connections() -> void:
	clear_connections()
	_deselect_wire()
	_mark_wires_dirty()
	for id: int in model.exec_out:
		var fv: NodeView = views.get(id)
		if fv == null:
			continue
		for port: int in model.exec_out[id]:
			var to_id: int = int(model.exec_out[id][port])
			var tv: NodeView = views.get(to_id)
			if tv == null:
				continue
			var vp: int = fv.exec_out_port(port)
			var ip: int = tv.exec_in_port(0)
			if vp >= 0 and ip >= 0:
				connect_node("n%d" % id, vp, "n%d" % to_id, ip)
	for al: Dictionary in model.arg_links:
		var av: NodeView = views.get(int(al["aid"]))
		var ev2: NodeView = views.get(int(al["eid"]))
		if av == null or ev2 == null or not model.nodes.has(int(al["eid"])):
			continue
		var args2: Array = model.nodes[int(al["eid"])]["fields"].get("args", [])
		var ai: int = int(args2.find(int(al["aid"])))
		if ai < 0:
			continue
		var eport: int = ev2.data_in_port(ai)
		# The ownership wire always starts at the Argument's Function
		# connection pin (output index 1), never at the value pin.
		var aport: int = av.data_out_port(1)
		if eport >= 0 and aport >= 0:
			connect_node("n%d" % int(al["aid"]), aport, "n%d" % int(al["eid"]), eport)
	for al2: Dictionary in model.ann_links:
		var av3: NodeView = views.get(int(al2["aid"]))
		var tv3: NodeView = views.get(int(al2["tid"]))
		if av3 == null or tv3 == null or not model.nodes.has(int(al2["tid"])):
			continue
		# each annotation renders through its OWN per-annotation input pin
		var tport: int = tv3.data_in_port(model._annotation_pin_of_slot(
			int(al2["tid"]), int(al2.get("slot", -1))))
		var aport3: int = av3.data_out_port(0)
		if tport >= 0 and aport3 >= 0:
			connect_node("n%d" % int(al2["aid"]), aport3, "n%d" % int(al2["tid"]), tport)
	# Script Header metadata: the Class Name / Extension node's output wires
	# into the header's dedicated slot (one visible wire each).
	for hl: Dictionary in model.header_links:
		var mv: NodeView = views.get(int(hl["nid"]))
		var hv2: NodeView = views.get(int(hl["hid"]))
		if mv == null or hv2 == null or not model.nodes.has(int(hl["hid"])):
			continue
		var mport_name: String = "class name" if str(hl["kind"]) == "class_name" else "extends"
		var mport: int = -1
		var tins2: Array = model.nodes[int(hl["hid"])]["data_ins"]
		for mi: int in tins2.size():
			if String(tins2[mi]["name"]) == mport_name:
				mport = hv2.data_in_port(mi)
				break
		if mport >= 0:
			connect_node("n%d" % int(hl["nid"]), mv.data_out_port(0), "n%d" % int(hl["hid"]), mport)
	for l: Dictionary in model.data_links:
		var fv2: NodeView = views.get(int(l["from_id"]))
		var tv2: NodeView = views.get(int(l["to_id"]))
		if fv2 == null or tv2 == null:
			continue
		var vp2: int = fv2.data_out_port(int(l["from_out"]))
		var ip2: int = tv2.data_in_port(int(l["to_in"]))
		if vp2 >= 0 and ip2 >= 0:
			connect_node("n%d" % int(l["from_id"]), vp2, "n%d" % int(l["to_id"]), ip2)
	# Private-variable scope registrations: the visible amber wire runs from
	# the variable's scope output (out index 1) into the scope-owning node's
	# "add scope" input slot.
	for sl: Dictionary in model.scope_links:
		var sv: NodeView = views.get(int(sl["vid"]))
		var st: NodeView = views.get(int(sl["tid"]))
		if sv == null or st == null:
			continue
		var slot2: int = model.scope_pin_of(int(sl["tid"]), int(sl["vid"]))
		if slot2 < 0:
			continue
		var s_out: int = sv.data_out_port(1)
		var s_in: int = st.data_in_port(slot2)
		if s_out >= 0 and s_in >= 0:
			connect_node("n%d" % int(sl["vid"]), s_out, "n%d" % int(sl["tid"]), s_in)
	# Export-group associations: the visible lilac wire runs from the
	# @export_group node's "group" output (out index 1) into the export
	# annotation's "add group" input slot.
	for gl: Dictionary in model.group_links:
		var gv: NodeView = views.get(int(gl["gid"]))
		var xv: NodeView = views.get(int(gl["xid"]))
		if gv == null or xv == null:
			continue
		var gslot: int = model.group_slot_of(int(gl["xid"]))
		if gslot < 0:
			continue
		var g_out: int = -1
		for oi: int in (model.nodes[int(gl["gid"])]["data_outs"] as Array).size():
			if String(model.nodes[int(gl["gid"])]["data_outs"][oi]["name"]) == "group":
				g_out = gv.data_out_port(oi)
				break
		var g_in: int = xv.data_in_port(gslot)
		if g_out >= 0 and g_in >= 0:
			connect_node("n%d" % int(gl["gid"]), g_out, "n%d" % int(gl["xid"]), g_in)
	# Class Reference member registrations: the visible steel-blue wire runs
	# from the member's "Class" output (first data out) into the reference's
	# member slot row for that member.
	for ml: Dictionary in model.member_links:
		var mv: NodeView = views.get(int(ml["cid"]))
		var rv2: NodeView = views.get(int(ml["rid"]))
		if mv == null or rv2 == null or not model.nodes.has(int(ml["rid"])):
			continue
		var mslot: int = model._member_pin_slot(int(ml["rid"]), int(ml["cid"]))
		if mslot < 0:
			continue
		var cport: int = mv.data_out_port(0)
		var rport: int = rv2.data_in_port(mslot)
		if cport >= 0 and rport >= 0:
			connect_node("n%d" % int(ml["cid"]), cport, "n%d" % int(ml["rid"]), rport)
	# clear_connections() above also dropped the Error / Warning wires
	_connect_diag_wires()
	# while one function is isolated, rebuilt wires of hidden nodes must not
	# float in the focused view; the model keeps them all
	if _focus_entry >= 0:
		_remove_hidden_wires()


# ---- User node additions -------------------------------------------------------
## Spawns a new node of `kind` at `local_pos` (canvas-local coordinates; the
## view centre when omitted). Returns the new model id, -1 on failure.
func spawn_node(kind: int, fields: Dictionary = {}, local_pos: Vector2 = Vector2.INF) -> int:
	if kind == Model.Kind.ENTRY and fields.has("accessor"):
		return _spawn_accessor(String(fields["accessor"]), local_pos)
	if bool(fields.get("new_enum", false)):
		fields = new_enum_fields()
	elif bool(fields.get("new_dict", false)):
		fields = new_dictionary_fields()
	elif bool(fields.get("new_array", false)):
		fields = new_array_fields()
	var id: int = model.add_node(kind, fields)
	if id < 0:
		return -1
	var v: NodeView = _make_view(id)
	var at: Vector2 = size * 0.5 if local_pos == Vector2.INF else local_pos
	_place(v, _local_to_graph(at) + Vector2(randf_range(-20, 20), randf_range(-20, 20)))
	modified.emit()
	_update_status()
	return id


# ---- Drag and drop from the editor docks -----------------------------------------
## Scene tree node  + Ctrl -> `@onready var <name>: <Type> = $Path`
## Scene tree node  + Alt  -> `@export var <name>: <Type>`
## FileSystem file  + Ctrl -> `const <Name> = preload("res://...")`
## FileSystem file  + Alt  -> `@export var <name>: <Type> = preload("res://...")`
## Several dragged items create several nodes. Without a modifier the status
## line explains the two shortcuts.
func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if not (data is Dictionary):
		return false
	var t: String = str((data as Dictionary).get("type", ""))
	return t == "nodes" or t == "files"


func _drop_data(at_position: Vector2, data: Variant) -> void:
	if not (data is Dictionary):
		return
	var d: Dictionary = data as Dictionary
	var ctrl: bool = Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_META)
	var alt: bool = Input.is_key_pressed(KEY_ALT)
	if not ctrl and not alt:
		status_changed.emit("Hold Ctrl (@onready / const) or Alt (@export) while dropping.")
		return
	var made: PackedStringArray = PackedStringArray()
	var i: int = 0
	match str(d.get("type", "")):
		"nodes":
			for np: Variant in d.get("nodes", []) as Array:
				var label: String = _drop_scene_node(NodePath(str(np)), alt and not ctrl, at_position + Vector2(0, 80.0 * i))
				if label != "":
					made.append(label)
					i += 1
		"files":
			for fp: Variant in d.get("files", []) as Array:
				var label2: String = _drop_file(str(fp), alt and not ctrl, at_position + Vector2(0, 80.0 * i))
				if label2 != "":
					made.append(label2)
					i += 1
	if made.size() > 0:
		status_changed.emit("Created %s" % ", ".join(made))
	else:
		status_changed.emit("Nothing was created from the dropped item(s).")


## Names already used by top-level variables / constants (for unique names).
func _taken_decl_names() -> Array:
	var taken: Array = []
	for nid: int in model.nodes:
		var nn: Dictionary = model.nodes[nid]
		var k: int = int(nn["kind"])
		if k == Model.Kind.VAR_DECL:
			taken.append(String(nn["fields"].get("name", "")))
		elif k == Model.Kind.CONST_DECL:
			taken.append(String(nn["title"]).trim_prefix("const ").strip_edges())
	return taken


## Creates a variable node carrying `annotation` (@onready / @export).
func _spawn_annotated_var(vname: String, raw_type: String, default_expr: String,
		annotation: String, local_pos: Vector2) -> int:
	var id: int = spawn_node(Model.Kind.VAR_DECL,
		{"name": vname, "raw_type": raw_type, "default": default_expr}, local_pos)
	if id < 0:
		return -1
	if model.add_annotation(id, annotation):
		# Turn the annotation row into a real Annotation node wired to the
		# variable's "add annotation" pin; it is laid out in the column to the
		# left of the declaration. (If it cannot be represented as a node the
		# editable row simply stays.)
		var idx: int = model.annotations_of(id).size() - 1
		var aid: int = model.convert_annotation_line(id, idx)
		if aid >= 0:
			var av: NodeView = _make_view(aid)
			var tv: NodeView = views.get(id, null)
			if av != null and tv != null:
				_place(av, tv.position + Vector2(-(av.size.x + 80.0), 0.0))
			_sync_connections()
		_rebuild_annotation_view(id)
		modified.emit()
	return id


## One dropped Scene tree node. Returns a short label, "" when nothing was made.
func _drop_scene_node(np: NodePath, as_export: bool, local_pos: Vector2) -> String:
	if not Engine.is_editor_hint():
		return ""
	var node: Node = get_node_or_null(np)
	if node == null:
		return ""
	# Paths are relative to the node that owns this script when the open scene
	# has one, otherwise to the scene root (what the Script editor does).
	var scene_root: Node = EditorInterface.get_edited_scene_root()
	var base: Node = _find_script_owner(scene_root, model.script_path)
	if base == null:
		base = scene_root
	var type_name: String = node.get_class()
	var scr: Script = node.get_script() as Script
	if scr != null and str(scr.get_global_name()) != "":
		type_name = str(scr.get_global_name())
	var vname: String = DropDecls.unique(DropDecls.var_name(str(node.name)), _taken_decl_names())
	if as_export:
		_spawn_annotated_var(vname, type_name, "", "@export", local_pos)
		return "@export var %s: %s" % [vname, type_name]
	var rel: String = str(base.get_path_to(node)) if base != null else str(node.name)
	_spawn_annotated_var(vname, type_name, DropDecls.node_path_expr(rel), "@onready", local_pos)
	return "@onready var %s: %s" % [vname, type_name]


## First node under `n` whose script is the file at `script_path`.
func _find_script_owner(n: Node, script_path: String) -> Node:
	if n == null or script_path == "":
		return null
	var s: Script = n.get_script() as Script
	if s != null and s.resource_path == script_path:
		return n
	for c: Node in n.get_children():
		var r: Node = _find_script_owner(c, script_path)
		if r != null:
			return r
	return null


## One dropped FileSystem file. Returns a short label, "" when nothing was made.
func _drop_file(path: String, as_export: bool, local_pos: Vector2) -> String:
	if path == "" or path.ends_with("/"):
		return ""
	var expr: String = DropDecls.preload_expr(path)
	if as_export:
		var ftype: String = ""
		if Engine.is_editor_hint():
			var efs: EditorFileSystem = EditorInterface.get_resource_filesystem()
			if efs != null:
				ftype = efs.get_file_type(path)
		var tname: String = DropDecls.export_type(ftype)
		var vname: String = DropDecls.unique(DropDecls.var_name(path.get_file().get_basename()), _taken_decl_names())
		_spawn_annotated_var(vname, tname, expr, "@export", local_pos)
		return "@export var %s: %s" % [vname, tname]
	var cname: String = DropDecls.unique(DropDecls.const_name(path), _taken_decl_names())
	if spawn_node(Model.Kind.CONST_DECL, {"name": cname, "value": expr}, local_pos) < 0:
		return ""
	return "const %s" % cname


## Legacy helper (Add Node menu): spawn a node near the view centre.
func add_user_node(kind: int, fields: Dictionary = {}) -> void:
	spawn_node(kind, fields)


## Fields for a brand-new enum: a free name (NewEnum, NewEnum2, ...) and two
## starter members, so the member form has something to edit right away.
func new_enum_fields() -> Dictionary:
	var taken: Array = []
	for nid: int in model.nodes:
		var nn: Dictionary = model.nodes[nid]
		if int(nn["kind"]) == Model.Kind.DECLARATION and String(nn["title"]).begins_with("enum "):
			taken.append(String(nn["title"]).trim_prefix("enum ").strip_edges())
	var ename: String = CollText.unique_name("NewEnum", taken)
	var body: String = CollText.build_enum(ename, [
		{"name": "VALUE_1", "value": ""}, {"name": "VALUE_2", "value": ""}])
	return {"body": body, "title": "enum " + ename}


## Fields for a brand-new Dictionary variable with a free name.
func new_dictionary_fields() -> Dictionary:
	var taken: Array = []
	for nid: int in model.nodes:
		var nn: Dictionary = model.nodes[nid]
		if int(nn["kind"]) == Model.Kind.VAR_DECL:
			taken.append(String(nn["fields"].get("name", "")))
	var vname: String = "my_dictionary"
	var i: int = 2
	while taken.has(vname):
		vname = "my_dictionary%d" % i
		i += 1
	return {"name": vname, "raw_type": "Dictionary", "default": "{}"}


## Fields for a brand-new Array variable with a free name.
func new_array_fields() -> Dictionary:
	var taken: Array = []
	for nid: int in model.nodes:
		var nn: Dictionary = model.nodes[nid]
		if int(nn["kind"]) == Model.Kind.VAR_DECL:
			taken.append(String(nn["fields"].get("name", "")))
	var vname: String = "my_array"
	var i: int = 2
	while taken.has(vname):
		vname = "my_array%d" % i
		i += 1
	return {"name": vname, "raw_type": "Array", "default": "[]"}


## Argument node actions from a Function or Argument node view.
func _on_argument_action(id: int, action: String) -> void:
	if not model.nodes.has(id):
		return
	match action:
		"left":
			if model.move_argument(id, -1):
				_rebuild_parent_entry(id)
				modified.emit()
		"right":
			if model.move_argument(id, 1):
				_rebuild_parent_entry(id)
				modified.emit()
		_:
			pass


## Lambda node actions: parameter rows are form structure (not pins), so an
## add / remove rebuilds the node view after the model change.
func _on_lambda_action(id: int, action: String, index: int) -> void:
	if not model.nodes.has(id):
		return
	var ok: bool = false
	match action:
		"add_param":
			ok = model.add_lambda_param(id)
		"remove_param":
			ok = model.remove_lambda_param(id, index)
	if ok:
		_rebuild_view(id)
		_sync_connections()
		modified.emit()
		_update_status()


## Spawns a Setter ("set") / Getter ("get") node from the node menu, the same
## way a Function is spawned. It attaches to the first variable that does not
## have one yet (with the ready-made body that behaves like a plain variable);
## with no variable available it starts unattached and the person picks the
## variable on the node.
func _spawn_accessor(which: String, local_pos: Vector2 = Vector2.INF) -> int:
	var eid: int = model.add_accessor_free(which)
	if eid < 0:
		return -1
	var at: Vector2 = size * 0.5 if local_pos == Vector2.INF else local_pos
	var origin: Vector2 = _local_to_graph(at) + Vector2(randf_range(-20, 20), randf_range(-20, 20))
	var created: Array[int] = []
	for nid: int in model.nodes:
		if not views.has(nid):
			_make_view(nid)
			created.append(nid)
	_place_accessor_cluster(eid, origin, created)
	_sync_connections()
	modified.emit()
	_update_status()
	if int(model.nodes[eid]["fields"].get("owner_var", -1)) < 0:
		status_changed.emit("Pick the variable this %s belongs to (the Variable row on the node)." \
			% ("Setter" if which == "set" else "Getter"))
	return eid


## Lays out a freshly created Setter / Getter: the node at `origin`, its value
## argument to the left and its ready-made body to the right. Only nodes in
## `created` are moved, so existing ones keep their place.
func _place_accessor_cluster(eid: int, origin: Vector2, created: Array[int]) -> void:
	if created.has(eid) and views.has(eid):
		_place(views[eid], origin)
	var args: Array = model.nodes[eid]["fields"].get("args", [])
	for aid: Variant in args:
		if created.has(int(aid)) and views.has(int(aid)):
			_place(views[int(aid)], origin - Vector2(280.0, 0.0))
	var cur: int = model._exec_target(eid, 0)
	var step: int = 0
	while cur >= 0 and views.has(cur) and step < 8:
		if created.has(cur):
			_place(views[cur], origin + Vector2(340.0 * float(step + 1), 0.0))
		# a value feeding this node sits just below it
		for l: Dictionary in model.data_links:
			if int(l["to_id"]) == cur and created.has(int(l["from_id"])) \
					and int(l["from_id"]) != eid and not args.has(int(l["from_id"])) \
					and views.has(int(l["from_id"])):
				_place(views[int(l["from_id"])], origin + Vector2(340.0 * float(step + 1), 150.0))
		cur = model._exec_target(cur, 0)
		step += 1


## A Setter / Getter node's Variable picker.
func _on_accessor_owner_picked(eid: int, vid: int) -> void:
	if not model.nodes.has(eid) or not model.is_accessor_entry(eid):
		return
	if not model.set_accessor_owner(eid, vid):
		status_changed.emit(model.last_reject_reason)
		_rebuild_view(eid)   # the picker goes back to what the model holds
		return
	var created: Array[int] = []
	for nid: int in model.nodes:
		if not views.has(nid):
			_make_view(nid)
			created.append(nid)
	if not created.is_empty() and views.has(eid):
		var ev: NodeView = views[eid]
		_place_accessor_cluster(eid, ev.position_offset, created)
	# every Setter / Getter picker lists the variables that are still free
	for aid: int in model.nodes:
		if model.is_accessor_entry(aid) and views.has(aid):
			_rebuild_view(aid)
	_sync_connections()
	modified.emit()
	_update_status()


## Rebuilds the Function view that owns an argument (pin order may change).
func _rebuild_parent_entry(aid: int) -> void:
	if not model.nodes.has(aid):
		return
	var pid: int = int(model.nodes[aid]["fields"].get("parent", -1))
	if pid >= 0 and views.has(pid):
		_rebuild_view(pid)


## Rebuilds one node's view in place (keeps its graph position). Used when a
## structured edit changes the node's rows or pin types.
func _rebuild_view(id: int) -> void:
	var v: NodeView = views.get(id)
	if v == null:
		return
	var pos: Vector2 = v.position_offset
	v.get_parent().remove_child(v)
	v.queue_free()
	views.erase(id)
	var nv: NodeView = _make_view(id)
	_place(nv, pos)
	_sync_connections()


## The node-creation catalog (also drives the workspace "Add Node" button).
## Annotation nodes join the catalog so every supported annotation is
## selectable there too.
func menu_items() -> Array[Dictionary]:
	var base: Array[Dictionary] = _menu_catalog if not _menu_catalog.is_empty() else _catalog
	var out: Array[Dictionary] = base.duplicate()
	out.append_array(_annotation_menu_items())
	return out


# ---- Model edits from views ----------------------------------------------------
func _on_pin_value_changed(id: int, pin_index: int, text: String) -> void:
	model.set_pin_value(id, pin_index, text)
	if model.nodes.has(id) and int(model.nodes[id]["kind"]) == Model.Kind.ANNOTATION:
		# Editing an Annotation node's argument pins updates the annotation
		# line in every declaration it is registered with.
		for tid: int in model.sync_annotation_targets(id):
			if views.has(tid):
				views[tid].refresh(model.nodes[tid])
	modified.emit()


func _on_body_text_changed(id: int, text: String) -> void:
	model.set_body(id, text)
	if views.has(id):
		# the comment display label is driven by refresh(); the editor keeps
		# its own live text so this is a no-op for LineEdit bodies
		views[id].refresh(model.nodes[id])
	modified.emit()


## Match branch editing from the node view: rename / add / remove branches.
## Structure changes rebuild the view (exec pin count changed); a rename
## refreshes the label in place so the editing field keeps focus.
func _on_match_action(id: int, action: String, port: int, text: String) -> void:
	if not model.nodes.has(id):
		return
	var ok: bool = false
	match action:
		"set":
			ok = model.set_match_branch(id, port, text)
		"add":
			ok = model.add_match_branch(id, text)
		"remove":
			ok = model.remove_match_branch(id, port)
	if not ok:
		return
	_rebuild_view(id)
	_sync_connections()
	modified.emit()
	_update_status()


## Structured annotation editing from a Variable/Function node: row adds and
## removes change the row structure -> the view is rebuilt (keeping its
## position); text edits refresh in place so focus survives every keystroke.
func _on_annotation_action(id: int, action: String, index: int, text: String) -> void:
	if not model.nodes.has(id):
		return
	if action == "menu":
		# The node's "+ Annotation" affordance: open the node menu anchored at
		# the declaration's "add annotation" slot. The menu then lists exactly
		# the annotations valid for this target, and spawning one wires and
		# registers it automatically (see _auto_connect_spawn).
		var slot2: int = _annotation_slot_of(id)
		if slot2 < 0:
			return
		var v: NodeView = views.get(id, null)
		if v == null:
			return
		_pending_drag = {"is_output": false, "node": "n%d" % id, "port": v.data_in_port(slot2)}
		_open_menu(_graph_to_local(v.position + Vector2(v.size.x + 20.0, 0.0)), _pending_drag)
		return
	var ok: bool = false
	match action:
		"commit":
			# The row editor was committed (Enter / focus left): a valid,
			# round-trippable annotation becomes a real Annotation node with
			# its own argument pins, wired to the declaration. Anything else
			# keeps its row.
			var aid2: int = model.convert_annotation_line(id, index)
			if aid2 >= 0:
				var nv: NodeView = _make_view(aid2)
				var tv2: NodeView = views.get(id, null)
				if tv2 != null:
					var offs: int = 0
					for l2: Dictionary in model.ann_links:
						if int(l2["tid"]) == id:
							offs += 1
					_place(nv, tv2.position + Vector2(tv2.size.x + 80.0, -20.0 + 90.0 * float(offs)))
				_sync_connections()
				_rebuild_annotation_view(id)
				modified.emit()
				_update_status()
			return
		"set":
			ok = model.set_annotation(id, index, text)
		"add":
			ok = model.add_annotation(id)
		"remove":
			ok = model.remove_annotation(id, index)
		_:
			return
	if not ok:
		return
	modified.emit()
	if action == "set":
		views[id].refresh(model.nodes[id])
	else:
		_rebuild_annotation_view(id)
	_update_status()


func _on_field_changed(id: int, key: String, text: String) -> void:
	var kind: int = int(model.nodes[id]["kind"]) if model.nodes.has(id) else -1
	# Structured header-directive editing (see graph_node): row adds change
	# the row structure -> rebuild; text edits refresh in place so the
	# focused editor keeps focus and caret.
	if key.begins_with("header:"):
		model.set_header_line(id, int(key.trim_prefix("header:")), text)
		modified.emit()
		if model.nodes.has(id):
			views[id].refresh(model.nodes[id])
		_update_status()
		return
	match kind:
		Model.Kind.CLASS_NAME, Model.Kind.EXTENDS_DECL:
			# Script metadata nodes: one structured field each. Invalid class
			# names are rejected with a status message; unknown base classes
			# are applied but reported (generation stays valid).
			var okc: bool = (model.set_class_name(id, text) if kind == Model.Kind.CLASS_NAME
				else model.set_extends_base(id, text))
			if model.nodes.has(id):
				views[id].refresh(model.nodes[id])
			if not okc:
				_update_status()
				return
			modified.emit()
			_update_status()
			if model.last_reject_reason != "":
				status_changed.emit(model.last_reject_reason)
			return
		Model.Kind.ENTRY:
			# Structured Function properties: name / return type. Updated in
			# place — the view is never rebuilt while the user is typing, so
			# keyboard focus and the caret survive every keystroke.
			model.set_entry_prop(id, key, text)
			if model.nodes.has(id):
				views[id].refresh(model.nodes[id])
			modified.emit()
			return
		Model.Kind.ARGUMENT:
			# Structured Argument properties, updated in place. A type change
			# may drop connections; a default change may add/remove the value
			# pin (structure change -> rebuild, keeping the position).
			model.set_arg_prop(id, key, text)
			modified.emit()
			if model.nodes.has(id):
				if _view_structure_changed(views[id], model.nodes[id]):
					_rebuild_view(id)
				else:
					views[id].refresh(model.nodes[id])
			_sync_connections()
			_update_status()
			return
		Model.Kind.VAR_DECL:
			# Structured Variable properties (name / type / default), updated
			# in place; the Default Value field may add/remove the value pin.
			model.set_var_prop(id, key, text)
			modified.emit()
			if model.nodes.has(id):
				if _view_structure_changed(views[id], model.nodes[id]):
					_rebuild_view(id)
				else:
					views[id].refresh(model.nodes[id])
			_sync_connections()
			_update_status()
			return
		Model.Kind.CALL:
			# Function Call properties: renaming resyncs the pins against the
			# new target's signature; the mode toggle rebuilds the pin layout.
			if key == "mode":
				model.set_call_mode(id, text)
				modified.emit()
				if model.nodes.has(id):
					_rebuild_view(id)
					_sync_connections()
					_update_status()
				return
			model.set_field(id, key, text)
			modified.emit()
			if key == "call" and model.nodes.has(id):
				model.sync_call_signature(id)
				if model.nodes.has(id):
					if _view_structure_changed(views[id], model.nodes[id]):
						_rebuild_view(id)
					else:
						views[id].refresh(model.nodes[id])
					_sync_connections()
					_update_status()
				return
		Model.Kind.LAMBDA:
			# Lambda properties update in place (the title follows the
			# signature while the person types); the view is never rebuilt
			# while typing so focus and the caret survive every keystroke.
			var lam_ok: bool = model.set_lambda_prop(id, key, text)
			var lam_why: String = model.last_reject_reason
			if model.nodes.has(id):
				views[id].refresh(model.nodes[id])
			modified.emit()
			_update_status()
			if lam_ok:
				_rejected_edits.erase(id)
			else:
				_rejected_edits[id] = true
				if lam_why != "":
					# tell the person why the edit was not applied (previous value kept)
					status_changed.emit(lam_why + " (previous value kept)")
			return
		Model.Kind.CLASS_REF:
			# Class Reference fields: refused input keeps the previous value and
			# says why; an unknown-but-well-formed class is applied with a hint.
			var cr_ok: bool = model.set_class_ref_prop(id, key, text)
			var cr_why: String = model.last_reject_reason
			modified.emit()
			if cr_ok:
				_rejected_edits.erase(id)
				if cr_why != "":
					status_changed.emit(cr_why)
			else:
				_rejected_edits[id] = true
				if cr_why != "":
					status_changed.emit(cr_why + " (previous value kept)")
			return
		_:
			pass
	model.set_field(id, key, text)
	modified.emit()
	if not model.nodes.has(id):
		return
	var n: Dictionary = model.nodes[id]
	# Keep dependent parts of the model consistent (views refresh on rebuild).
	if key == "name" and kind == Model.Kind.VAR_DECL:
		_refresh_scope_hosts(model.scope_hosts_of(id), true)
		_sync_connections()
	if key == "name" and kind in [Model.Kind.VARIABLE_GET, Model.Kind.VARIABLE_SET]:
		if n["data_outs"].size() > 0:
			n["data_outs"][0]["name"] = text
		views[id].title = ("Get %s" % text) if kind == Model.Kind.VARIABLE_GET else ("Set %s" % text)
	elif key == "op" and kind == Model.Kind.OPERATOR:
		# set_field updated the title and the operand pin layout (a comparison
		# has exactly two operands, a chainable operator regains its grow slot)
		views[id].title = n["title"]
		if _view_structure_changed(views[id], n):
			_rebuild_view(id)
			_sync_connections()
	elif key == "value" and kind == Model.Kind.LITERAL:
		n["title"] = "Literal %s" % Types.type_name(int(n["fields"].get("type", Types.VARIANT)))


## Dynamic call-argument management from a Function Call node's controls.
func _on_call_arg_action(id: int, action: String, index: int) -> void:
	var ok: bool = false
	match action:
		"remove":
			ok = model.call_pin_remove(id, index)
		"left":
			ok = model.call_pin_move(id, index, -1)
		"right":
			ok = model.call_pin_move(id, index, 1)
	if not ok:
		return
	_rebuild_view(id)
	_sync_connections()
	modified.emit()
	_update_status()


# ---- Connection management -----------------------------------------------------
func _id_of(node_name: String) -> int:
	return int(node_name.trim_prefix("n")) if node_name.begins_with("n") else -1


func _view_of(node_name: StringName) -> NodeView:
	var id: int = _id_of(str(node_name))
	return views.get(id, null)


## Live drag feedback: GraphEdit consults this while the wire follows the mouse.
func _is_node_hover_valid(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> bool:
	var norm: Array = _normalize_connection(String(from_node), from_port, String(to_node), to_port)
	if norm.is_empty():
		return false   # ports have no matching pin pair in either direction
	var fv: NodeView = norm[0]
	var tv: NodeView = norm[1]
	var od: Dictionary = norm[6]
	var idn: Dictionary = norm[7]
	if od["kind"] == "exec":
		return model.can_connect_exec(fv.model_id, int(od["index"]), tv.model_id)
	if tv.model_id >= 0 and int(model.nodes[tv.model_id]["kind"]) == Model.Kind.ENTRY:
		# A Function's left-side pins register Argument nodes (into the "add
		# argument" slot) or Annotation nodes (into the "add annotation" slot).
		var epins: Array = model.nodes[tv.model_id]["data_ins"]
		var fk: int = int(model.nodes[fv.model_id]["kind"])
		if fk == Model.Kind.ARGUMENT and int(od["index"]) != 1:
			return false   # only the Function connection output registers
		var want: String = "add argument" if fk == Model.Kind.ARGUMENT \
			else ("add annotation" if fk == Model.Kind.ANNOTATION else "")
		if want == "" or int(idn["index"]) >= epins.size():
			return false
		return String(epins[int(idn["index"])]["name"]) == want
	return model.can_connect_data(fv.model_id, int(od["index"]), tv.model_id, int(idn["index"]))


## Normalizes a GraphEdit connection interaction. Godot reports the
## drag-start pin as the request's "from" side, so a drag that starts on an
## INPUT pin arrives reversed (from = input row, to = output row). Port
## numbers also count every node row while out_def/in_def index only their
## own direction's rows. This helper resolves the real output/input pair in
## both cases and returns [from_view, to_view, from_node, from_port,
## to_node, to_port, out_def, in_def] oriented output -> input, or an empty
## Array when the ports cannot be resolved to a compatible pair.
func _normalize_connection(from_node: String, from_port: int, to_node: String, to_port: int) -> Array:
	var fv: NodeView = _view_of(from_node)
	var tv: NodeView = _view_of(to_node)
	if fv == null or tv == null:
		return []
	var od: Dictionary = fv.out_def(from_port)
	var idn: Dictionary = tv.in_def(to_port)
	if od.is_empty() or idn.is_empty() or od["kind"] != idn["kind"]:
		# Maybe the drag started on an input pin: mirror the direction.
		var rod: Dictionary = tv.out_def(to_port)
		var ridn: Dictionary = fv.in_def(from_port)
		if rod.is_empty() or ridn.is_empty() or rod["kind"] != ridn["kind"]:
			return []
		var tmpv: NodeView = fv
		fv = tv
		tv = tmpv
		var tmpn: String = from_node
		from_node = to_node
		to_node = tmpn
		var tmpi: int = from_port
		from_port = to_port
		to_port = tmpi
		od = rod
		idn = ridn
	return [fv, tv, from_node, from_port, to_node, to_port, od, idn]


func _on_connection_request(from_node: String, from_port: int, to_node: String, to_port: int) -> void:
	var norm: Array = _normalize_connection(from_node, from_port, to_node, to_port)
	if norm.is_empty():
		return
	var fv: NodeView = norm[0]
	var tv: NodeView = norm[1]
	from_node = norm[2]
	from_port = norm[3]
	to_node = norm[4]
	to_port = norm[5]
	var od: Dictionary = norm[6]
	var idn: Dictionary = norm[7]
	if od["kind"] == "exec":
		if model.connect_exec(fv.model_id, int(od["index"]), tv.model_id):
			connect_node(from_node, from_port, to_node, to_port)
			modified.emit()
	else:
		if tv.model_id >= 0 and int(model.nodes[tv.model_id]["kind"]) == Model.Kind.ENTRY:
			# Argument registration through the Function's left-side pin: only
			# the Function connection output (pin index 1) registers.
			if int(model.nodes[fv.model_id]["kind"]) == Model.Kind.ARGUMENT \
					and int(od["index"]) != 1:
				status_changed.emit("Use the Argument's Function connection pin to link it to a Function")
			else:
				_register_argument_wire(fv, tv, idn)
			_update_status()
			return
		var old_ann_target: int = _annotation_owner_of(fv.model_id) \
			if int(model.nodes[fv.model_id]["kind"]) == Model.Kind.ANNOTATION else -1
		var replaced: Dictionary = model.connect_data(fv.model_id, int(od["index"]), tv.model_id, int(idn["index"]))
		if replaced.has("_rejected"):
			# useful feedback instead of a silent drop
			status_changed.emit(model.last_reject_reason
				if model.last_reject_reason != "" else "Connection rejected")
		else:
			if not replaced.is_empty():
				var rv: NodeView = views.get(int(replaced["from_id"]))
				if rv != null:
					disconnect_node("n%d" % int(replaced["from_id"]),
						rv.data_out_port(int(replaced["from_out"])),
						to_node, tv.data_in_port(int(replaced["to_in"])))
			# connecting the grow slot may have opened a fresh empty pin
			_maybe_rebuild_pins(tv)
			# a comparison connect clears the If's own condition text: keep the
			# view's body label / value editor in sync with the model
			tv.refresh(model.nodes[tv.model_id])
			connect_node(from_node, from_port, to_node, to_port)
			if int(model.nodes[tv.model_id]["kind"]) == Model.Kind.CLASS_REF \
					and model.is_member_registered(fv.model_id, tv.model_id):
				# a member registered through a slot row: the reference's pins
				# changed (new member row) and its GraphEdit wires follow the
				# member_links table
				_maybe_rebuild_pins(tv)
				_sync_connections()
			if not model.scope_links_of(fv.model_id).is_empty() \
					and int(od.get("index", -1)) == 1 and model.scope_slot_of(tv.model_id) >= 0:
				# a scope wire may have MOVED the variable from another scope:
				# the hosts regrow their named scope pins, then the wires follow
				_refresh_scope_hosts(model.scope_hosts_of(fv.model_id))
				_sync_connections()
			if model.is_annotation_registered(tv.model_id, fv.model_id):
				# the declaration gained/updated an annotation row
				_rebuild_annotation_view(tv.model_id)
				if old_ann_target >= 0 and old_ann_target != tv.model_id and views.has(old_ann_target):
					# re-wired from another declaration: close the gap there
					_rebuild_annotation_view(old_ann_target)
			modified.emit()
	_update_status()


func _on_disconnection_request(from_node: String, from_port: int, to_node: String, to_port: int) -> void:
	var norm: Array = _normalize_connection(from_node, from_port, to_node, to_port)
	if norm.is_empty():
		return
	var fv: NodeView = norm[0]
	var tv: NodeView = norm[1]
	from_node = norm[2]
	from_port = norm[3]
	to_node = norm[4]
	to_port = norm[5]
	var od: Dictionary = norm[6]
	var idn: Dictionary = norm[7]
	# in_def entries carry the row index only; resolve the real pin name for
	# slot-aware disconnection semantics.
	var tpin_name: String = ""
	if int(idn.get("index", -1)) >= 0 \
			and int(idn["index"]) < model.nodes[tv.model_id]["data_ins"].size():
		tpin_name = String(model.nodes[tv.model_id]["data_ins"][int(idn["index"])]["name"])
	var links_before: int = model.link_count()
	if od["kind"] == "exec" and idn["kind"] == "exec":
		model.disconnect_exec(fv.model_id, int(od["index"]), tv.model_id)
	elif od["kind"] == "data" and idn["kind"] == "data" \
			and int(model.nodes[tv.model_id]["data_ins"][int(idn["index"])]["type"]) == Types.PinType.SCOPE \
			and not model.scope_links_of(fv.model_id).is_empty():
		# Disconnecting a private variable's scope output unregisters the
		# scope (the variable stays private at its last owning function); the
		# host drops that variable's named pin.
		model.unregister_scope(tv.model_id, fv.model_id)
		_refresh_scope_hosts([tv.model_id])
	elif od["kind"] == "data" and idn["kind"] == "data" \
			and tpin_name == "add annotation" \
			and model.is_annotation_registered(tv.model_id, fv.model_id):
		# Disconnecting a declaration's annotation slot unregisters the
		# annotation (the Annotation node itself stays in the graph).
		model.unregister_annotation(tv.model_id, fv.model_id)
		_rebuild_annotation_view(tv.model_id)
	elif od["kind"] == "data" and idn["kind"] == "data" \
			and int(idn.get("ann", 0)) == 1 \
			and model.is_annotation_registered(tv.model_id, fv.model_id):
		# Disconnecting a per-annotation pin unregisters the node; the
		# annotation's text stays on the declaration (its pin remains,
		# now empty and usable).
		model.unregister_annotation(tv.model_id, fv.model_id)
		_rebuild_annotation_view(tv.model_id)
	elif od["kind"] == "data" and idn["kind"] == "data" \
			and (tpin_name == "class name" or tpin_name == "extends") \
			and model.is_header_registered(tv.model_id, fv.model_id):
		# Disconnecting the header metadata wire unregisters the node; the
		# declaration line stays in the script.
		model.unregister_header_link(tv.model_id, fv.model_id)
	elif od["kind"] == "data" and idn["kind"] == "data" \
			and tpin_name == "add group" \
			and model.group_of(tv.model_id) == fv.model_id:
		# Disconnecting an export annotation's group slot unregisters the
		# association; the annotation keeps its own configuration.
		model.unregister_group(tv.model_id)
	elif od["kind"] == "data" and idn["kind"] == "data" \
			and int(model.nodes[tv.model_id]["kind"]) == Model.Kind.CLASS_REF \
			and int(idn["index"]) < model.nodes[tv.model_id]["data_ins"].size() \
			and int(model.nodes[tv.model_id]["data_ins"][int(idn["index"])]["type"]) == Types.PinType.MEMBER \
			and model.is_member_registered(fv.model_id, tv.model_id):
		# Disconnecting a Class Reference's member slot unregisters the member
		# (the member node itself stays in the graph; its target pin keeps
		# whatever it held).
		model.unregister_member(tv.model_id, fv.model_id)
		_maybe_rebuild_pins(tv)
	elif od["kind"] == "data" and idn["kind"] == "data" \
			and int(model.nodes[tv.model_id]["kind"]) == Model.Kind.ENTRY \
			and tpin_name != "add annotation":
		# Disconnecting a Function's argument pin unregisters the argument.
		model.unregister_argument(tv.model_id, fv.model_id)
		_maybe_rebuild_pins(tv)
	elif od["kind"] == "data" and idn["kind"] == "data":
		model.disconnect_data(fv.model_id, int(od["index"]), tv.model_id, int(idn["index"]))
	else:
		# Port definitions disagree with the wire's kinds (legacy wires built
		# before the port mapping fix). Resolve the real link from the model so
		# unrelated connections stay untouched.
		_disconnect_model_link(fv, tv, from_port, to_port)
	disconnect_node(from_node, from_port, to_node, to_port)
	_maybe_rebuild_pins(tv)
	if model.link_count() != links_before:
		modified.emit()
	if not _selected_wire.is_empty() and str(_selected_wire["from_node"]) == str(from_node) \
			and int(_selected_wire["from_port"]) == from_port \
			and str(_selected_wire["to_node"]) == str(to_node) \
			and int(_selected_wire["to_port"]) == to_port:
		# The disconnected wire was selected: drop the selection AND repaint the
		# highlight layer now, otherwise the glow line stays as a frozen ghost
		# until the next selection redraws the layer.
		_deselect_wire()
		if _wire_layer != null:
			_wire_layer.queue_redraw()
	_update_status()


## Registers the dragged Argument with the Function and draws its wire into
## the left-side slot. Only the trailing "add argument" slot accepts wires.
func _register_argument_wire(fv: NodeView, tv: NodeView, idn: Dictionary) -> void:
	if int(model.nodes[fv.model_id]["kind"]) != Model.Kind.ARGUMENT:
		# A private variable's scope wire into the Function's "add scope"
		# slot goes through the model's scope registration instead.
		var epins0: Array = model.nodes[tv.model_id]["data_ins"]
		var from_out: int = -1
		var outs: Array = model.nodes[fv.model_id]["data_outs"]
		for oi: int in outs.size():
			if int(outs[oi]["type"]) == Types.PinType.SCOPE:
				from_out = oi
		if from_out >= 0 and int(idn["index"]) < epins0.size() \
				and int(epins0[int(idn["index"])]["type"]) == Types.PinType.SCOPE:
			var res: Dictionary = model.connect_data(fv.model_id, from_out, tv.model_id, int(idn["index"]))
			if res.has("_rejected"):
				status_changed.emit(model.last_reject_reason
					if model.last_reject_reason != "" else "Connection rejected")
			else:
				# the Function grows a named pin for the variable (and a fresh
				# empty slot); moving a variable between scopes drops its old
				# wire and pin
				_refresh_scope_hosts(model.scope_hosts_of(fv.model_id))
				_sync_connections()
				modified.emit()
		return
	var epins: Array = model.nodes[tv.model_id]["data_ins"]
	if String(epins[int(idn["index"])]["name"]) != "add argument":
		return   # only the empty slot accepts new registrations
	var idx: int = model.register_argument(tv.model_id, fv.model_id)
	if idx < 0:
		return
	var av2: NodeView = views.get(fv.model_id)
	if av2 != null and av2.model_id >= 0 and model.nodes.has(fv.model_id):
		av2.refresh(model.nodes[fv.model_id])
	_maybe_rebuild_pins(tv)
	var ev: NodeView = views[tv.model_id]
	connect_node("n%d" % fv.model_id, fv.data_out_port(1), "n%d" % tv.model_id, ev.data_in_port(idx))
	modified.emit()


## Index of a declaration's "add annotation" input slot, or -1.
func _annotation_slot_of(tid: int) -> int:
	var tins: Array = model.nodes.get(tid, {}).get("data_ins", [])
	for i: int in tins.size():
		if String(tins[i]["name"]) == "add annotation" \
				and int(tins[i]["type"]) == Types.PinType.ANNOTATION:
			return i
	return -1


## Fallback: find the single model link that corresponds to this wire and
## remove exactly that one.
func _disconnect_model_link(fv: NodeView, tv: NodeView, from_port: int, to_port: int) -> void:
	var fid: int = fv.model_id
	var tid: int = tv.model_id
	if model.exec_out.has(fid):
		for port: int in model.exec_out[fid]:
			if int(model.exec_out[fid][port]) == tid and fv.exec_out_port(port) == from_port:
				model.disconnect_exec(fid, port, tid)
				return
	for i: int in range(model.data_links.size() - 1, -1, -1):
		var l: Dictionary = model.data_links[i]
		if int(l["from_id"]) == fid and int(l["to_id"]) == tid \
				and fv.data_out_port(int(l["from_out"])) == from_port \
				and tv.data_in_port(int(l["to_in"])) == to_port:
			model.disconnect_data(fid, int(l["from_out"]), tid, int(l["to_in"]))
			return
	# Function argument registrations use their own link table.
	if int(model.nodes.get(tid, {}).get("kind", -1)) == Model.Kind.ENTRY:
		var eid: int = tid
		var eargs: Array = model.nodes[eid]["fields"].get("args", [])
		for j: int in range(model.arg_links.size() - 1, -1, -1):
			var al: Dictionary = model.arg_links[j]
			if int(al["eid"]) != eid:
				continue
			var aid: int = int(al["aid"])
			if int(eargs.find(aid)) < 0:
				continue
			var av: NodeView = views.get(aid)
			if av != null and fv.data_out_port(1) == from_port \
					and tv.data_in_port(int(eargs.find(aid))) == to_port:
				model.unregister_argument(eid, aid)
				_maybe_rebuild_pins(tv)
				return
	# Annotation registrations likewise.
	for j2: int in range(model.ann_links.size() - 1, -1, -1):
		var al2: Dictionary = model.ann_links[j2]
		if int(al2["tid"]) != tid:
			continue
		var aid2: int = int(al2["aid"])
		var av2: NodeView = views.get(aid2)
		if av2 != null and fv.data_out_port(0) == from_port and tv.data_in_port(_annotation_slot_of(tid)) == to_port:
			model.unregister_annotation(tid, aid2)
			_rebuild_annotation_view(tid)
			return
	# Private-variable scope registrations likewise: disconnecting the amber
	# scope wire unregisters the scope (the variable stays private).
	for j3: int in range(model.scope_links.size() - 1, -1, -1):
		var sl: Dictionary = model.scope_links[j3]
		if int(sl["tid"]) != tid:
			continue
		var sv: NodeView = views.get(int(sl["vid"]))
		var slot3: int = model.scope_pin_of(tid, int(sl["vid"]))
		if sv != null and slot3 >= 0 and tv.data_in_port(slot3) == to_port \
				and sv.data_out_port(1) == from_port:
			model.unregister_scope(tid, int(sl["vid"]))
			_refresh_scope_hosts([tid])
			_sync_connections()
			return


func _on_delete_nodes_request(nodes: Array[StringName]) -> void:
	var before: Dictionary = model.nodes.duplicate()
	for node_name: StringName in nodes:
		var id: int = _id_of(str(node_name))
		if id >= 0 and views.has(id):
			model.remove_node(id)
	var acc_owners: Array[int] = []
	for id: int in before:
		if not model.nodes.has(id) and views.has(id):
			var gone: Dictionary = before[id]
			if int(gone["kind"]) == Model.Kind.ENTRY and gone["fields"].has("accessor"):
				acc_owners.append(int(gone["fields"].get("owner_var", -1)))
			views[id].get_parent().remove_child(views[id])
			views[id].queue_free()
			views.erase(id)
	# a deleted private variable drops its named pin from its scope owner
	for sid: int in model.nodes:
		if model.is_scope_owner(sid) and views.has(sid):
			_maybe_rebuild_pins(views[sid])
	_sync_connections()
	# a deleted Setter / Getter frees its variable in the other pickers
	if not acc_owners.is_empty():
		for aid: int in model.nodes:
			if model.is_accessor_entry(aid) and views.has(aid):
				_rebuild_view(aid)
	if _focus_entry >= 0 and not model.nodes.has(_focus_entry):
		exit_function_focus()   # the isolated function itself was deleted
	_deselect_wire()
	clear_orphan_connections()
	if model.nodes.size() != before.size():
		modified.emit()
	_update_status()


## Removes GraphEdit wires whose endpoint views were deleted.
func clear_orphan_connections() -> void:
	for c: Dictionary in get_connection_list():
		if not _wire_endpoint_alive(str(c["from_node"])) or not _wire_endpoint_alive(str(c["to_node"])):
			disconnect_node(str(c["from_node"]), int(c["from_port"]), str(c["to_node"]), int(c["to_port"]))
	_prune_diag_nodes()


# ---- Wire selection + keyboard deletion -----------------------------------------
## Finds the wire closest to `local_pos` (canvas-local coordinates), {} if none.
func wire_at(local_pos: Vector2) -> Dictionary:
	var hit: Variant = get_closest_connection_at_point(local_pos, 12.0 / clampf(zoom, 0.4, 2.0))
	if hit is Dictionary and not (hit as Dictionary).is_empty():
		return hit
	return {}


func _select_wire(hit: Dictionary) -> void:
	if hit.is_empty() or not hit.has("from_node"):
		return
	# Error / Warning wires are display only: not selectable, not deletable
	if str(hit["from_node"]).begins_with(DIAG_NODE_PREFIX) or str(hit["to_node"]).begins_with(DIAG_NODE_PREFIX):
		return
	_ensure_wire_layer()
	_deselect_wire()
	_selected_wire = hit.duplicate()
	set_connection_activity(str(hit["from_node"]), int(hit["from_port"]),
		str(hit["to_node"]), int(hit["to_port"]), 1.0)
	_wire_layer.queue_redraw()
	grab_focus()


func _deselect_wire() -> void:
	if _selected_wire.is_empty():
		return
	if views.has(_id_of(str(_selected_wire["from_node"]))) \
			and is_node_connected(str(_selected_wire["from_node"]), int(_selected_wire["from_port"]),
				str(_selected_wire["to_node"]), int(_selected_wire["to_port"])):
		set_connection_activity(str(_selected_wire["from_node"]), int(_selected_wire["from_port"]),
			str(_selected_wire["to_node"]), int(_selected_wire["to_port"]), 0.0)
	_selected_wire = {}
	if _wire_layer != null:
		_wire_layer.queue_redraw()


## Deletes the selected wire from both GraphEdit and the model.
func delete_selected_wire() -> bool:
	if _selected_wire.is_empty():
		return false
	# Route through the same handler as a drag-away disconnect so the model,
	# status label and selection state all update identically.
	_on_disconnection_request(str(_selected_wire["from_node"]), int(_selected_wire["from_port"]),
		str(_selected_wire["to_node"]), int(_selected_wire["to_port"]))
	return true


func _gui_input(event: InputEvent) -> void:
	# Menu-layer handling: the menu lives on its own CanvasLayer, so convert
	# canvas-local event positions to window space before testing the menu rect.
	var mg: Transform2D = get_global_transform()
	if _menu_open and event is InputEventMouseButton and event.pressed \
			and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN,
			MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT] \
			and _menu_root != null and _menu_root.is_visible_in_tree() \
			and Rect2(_menu_root.position, _menu_root.size).has_point(mg * event.position):
		accept_event()   # wheel over the menu belongs to the menu, never zooms
		return
	if _menu_open and event is InputEventMouseButton and event.pressed \
			and not Rect2(_menu_root.position, _menu_root.size).has_point(mg * event.position):
		_close_menu()   # click anywhere outside closes the menu; fall through
	if event is InputEventMouseButton and event.pressed:
		grab_focus()   # keep Del/Backspace working on the canvas after clicks
		if event.button_index == MOUSE_BUTTON_LEFT:
			var hit: Dictionary = wire_at(event.position)
			if not hit.is_empty():
				# Select the wire for Del/Backspace, but do NOT accept the event:
				# GraphEdit must still see the press so a drag that starts on the
				# wire (e.g. dragging it off a pin) runs its native connection
				# machinery and fires disconnection_request. Consuming the press
				# here silently blocked disconnecting a selected wire.
				_select_wire(hit)
				return
			if not _selected_wire.is_empty():
				_deselect_wire()
	elif event is InputEventKey and event.pressed and not event.echo:
		if (event.keycode == KEY_S or event.physical_keycode == KEY_S) \
				and (event.ctrl_pressed or event.meta_pressed):
			# Save the script from the Visual Script editor (Ctrl+S).
			save_requested.emit()
			accept_event()
			return
		if (event.keycode == KEY_DELETE or event.physical_keycode == KEY_DELETE \
				or event.keycode == KEY_BACKSPACE or event.physical_keycode == KEY_BACKSPACE) \
				and not _selected_wire.is_empty():
			delete_selected_wire()
			accept_event()
			return
	# Native GraphEdit input handling runs on its own; only events we
	# accept_event() above are blocked (e.g. a click that selects a wire).


## Highlight layer: draws a bright glow along the selected wire (drawn above
## the graph so the selection stays visible even where the wire passes nodes).
var _wire_layer: WireHighlight


## The wire overlay repaints only when something it draws could have moved
## (pan / zoom are watched by the overlay itself; node moves, resizes, pin
## rebuilds and Error / Warning nodes call this). Cheap no-op without a layer.
func _mark_wires_dirty() -> void:
	if _wire_layer != null:
		_wire_layer.mark_dirty()


func _ensure_wire_layer() -> void:
	if _wire_layer != null:
		return
	_wire_layer = WireHighlight.new()
	_wire_layer.canvas = self
	_wire_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wire_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_wire_layer)
	# Below the node views (wires run under nodes, over the GraphEdit's own
	# background grid and its untinted connection cores which the overlay
	# covers with the reference's type colors).
	move_child(_wire_layer, 0)


class WireHighlight extends Control:
	var canvas: Control
	var _last_from: Vector2 = Vector2.INF
	var _last_to: Vector2 = Vector2.INF
	var _dirty: bool = true
	var _last_scroll: Vector2 = Vector2.INF
	var _last_zoom: float = -1.0
	var _last_size: Vector2 = Vector2.INF

	## Current endpoint positions of the selected wire in this overlay's
	## local space (canvas space). GraphEdit applies its zoom to the node
	## views themselves, so the views' global transforms already carry the
	## current zoom; mapping through the canvas transform therefore yields
	## positions that always match the pins as they are drawn right now.
	func _endpoints() -> Array:
		var sel: Dictionary = canvas._selected_wire
		if sel.is_empty():
			return []
		var fv: NodeView = canvas.views.get(int(str(sel["from_node"]).trim_prefix("n")))
		var tv: NodeView = canvas.views.get(int(str(sel["to_node"]).trim_prefix("n")))
		if fv == null or tv == null:
			return []
		var inv: Transform2D = canvas.get_global_transform().affine_inverse()
		var fp: Vector2 = inv * (fv.get_global_transform() * fv.get_output_port_position(int(sel["from_port"])))
		var tp: Vector2 = inv * (tv.get_global_transform() * tv.get_input_port_position(int(sel["to_port"])))
		return [fp, tp]

	func _ready() -> void:
		set_process(true)

	## Something the overlay draws may have moved (node move / resize, pin
	## rebuild, new connections): repaint on the next frame.
	func mark_dirty() -> void:
		_dirty = true

	## The overlay is not a child of the zoomed nodes, so a zoom or scroll
	## change never invalidates it on its own. Pan / zoom are detected here from
	## three cheap values (scroll offset, zoom, size) - O(1) per frame - and node
	## moves / resizes arrive through mark_dirty(). (This used to walk and
	## measure EVERY connection each frame, which made panning sluggish.)
	func _process(_delta: float) -> void:
		var sc: Vector2 = canvas.scroll_offset
		var zm: float = canvas.zoom
		var sz: Vector2 = canvas.size
		if _dirty or sc != _last_scroll or zm != _last_zoom or sz != _last_size:
			_dirty = false
			_last_scroll = sc
			_last_zoom = zm
			_last_size = sz
			queue_redraw()
		if canvas._selected_wire.is_empty():
			return
		var ep2: Array = _endpoints()
		if ep2.size() < 2:
			return
		if (ep2[0] as Vector2) != _last_from or (ep2[1] as Vector2) != _last_to:
			_last_from = ep2[0]
			_last_to = ep2[1]
			queue_redraw()

	## Endpoint positions of one connection entry in overlay-local space.
	func _conn_endpoints(c: Dictionary, inv: Transform2D) -> Array:
		var fv: GraphNode = canvas.graph_node_for(str(c["from_node"]))
		var tv: GraphNode = canvas.graph_node_for(str(c["to_node"]))
		if fv == null or tv == null:
			return []
		var fp: Vector2 = inv * (fv.get_global_transform() * fv.get_output_port_position(int(c["from_port"])))
		var tp: Vector2 = inv * (tv.get_global_transform() * tv.get_input_port_position(int(c["to_port"])))
		return [fp, tp]

	## Per-connection draw spec: geometry + reference look. A wire is a
	## gradient from the OUTPUT pin's type color to the INPUT pin's type color
	## (exec wires are white end to end), exactly like the reference wires:
	## e.g. a Dictionary pin (#78edb0) feeding a String pin (#6ba6ed) fades
	## mint -> blue. GraphEdit's dark connection rim is drawn underneath.
	func _wire_specs() -> Array:
		var out: Array = []
		var inv: Transform2D = canvas.get_global_transform().affine_inverse()
		var view_rect: Rect2 = Rect2(Vector2.ZERO, size)
		for c: Dictionary in canvas.get_connection_list():
			var ep: Array = _conn_endpoints(c, inv)
			if ep.size() < 2:
				continue
			# Wires entirely outside the visible area are not built or drawn
			# (the box is padded for the curve's overshoot past its endpoints).
			var p0: Vector2 = ep[0]
			var p1: Vector2 = ep[1]
			var box: Rect2 = Rect2(p0, Vector2.ZERO).expand(p1)
			if not view_rect.intersects(box.grow(maxf(160.0, absf(p1.x - p0.x) * 0.5))):
				continue
			# Error / Warning wire: plain wire in the severity colour
			var to_name: String = str(c["to_node"])
			if to_name.begins_with("dg_") or str(c["from_node"]).begins_with("dg_"):
				var dpts: PackedVector2Array = canvas.get_connection_line(ep[0], ep[1])
				if dpts.size() >= 2:
					var dcol: Color = canvas.diag_wire_color(to_name)
					out.append({"pts": dpts, "from": dcol, "to": dcol,
						"width": Types.DATA_WIRE_THICKNESS})
				continue
			var fv: NodeView = canvas.views.get(int(str(c["from_node"]).trim_prefix("n")))
			var tv: NodeView = canvas.views.get(int(str(c["to_node"]).trim_prefix("n")))
			var od: Dictionary = fv.out_def(int(c["from_port"]))
			var idn: Dictionary = tv.in_def(int(c["to_port"]))
			var from_color: Color = Types.color_of(Types.PinType.VARIANT)
			var to_color: Color = from_color
			var width: float = Types.DATA_WIRE_THICKNESS
			if (not od.is_empty() and str(od["kind"]) == "exec") \
					or (not idn.is_empty() and str(idn["kind"]) == "exec"):
				from_color = Types.EXEC_WIRE_COLOR
				to_color = Types.EXEC_WIRE_COLOR
				width = Types.EXEC_WIRE_THICKNESS
			else:
				var ft: int = int(Types.PinType.VARIANT)
				var tt: int = int(Types.PinType.VARIANT)
				if not od.is_empty():
					var outs: Array = canvas.model.nodes[fv.model_id]["data_outs"]
					if int(od["index"]) < outs.size():
						ft = int(outs[int(od["index"])]["type"])
				if not idn.is_empty():
					var ins: Array = canvas.model.nodes[tv.model_id]["data_ins"]
					if int(idn["index"]) < ins.size():
						tt = int(ins[int(idn["index"])]["type"])
				from_color = Types.color_of(ft)
				to_color = Types.color_of(tt)
				# An Argument's Function connection wire is an ownership link:
				# render it white (exec-style), clearly apart from value flow.
				if not od.is_empty() and int(od["index"]) == 1 \
						and canvas.model.nodes.has(fv.model_id) \
						and int(canvas.model.nodes[fv.model_id]["kind"]) == Model.Kind.ARGUMENT:
					from_color = Types.EXEC_WIRE_COLOR
					to_color = Types.EXEC_WIRE_COLOR
					width = Types.EXEC_WIRE_THICKNESS
			var pts: PackedVector2Array = canvas.get_connection_line(ep[0], ep[1])
			if pts.size() < 2:
				continue
			out.append({"pts": pts, "from": from_color, "to": to_color, "width": width})
		return out

	## Per-point gradient colors along a polyline (by travelled length).
	static func gradient_colors(pts: PackedVector2Array, from_c: Color, to_c: Color) -> PackedColorArray:
		var cols: PackedColorArray = PackedColorArray()
		var total: float = 0.0
		for i: int in range(1, pts.size()):
			total += pts[i].distance_to(pts[i - 1])
		var run: float = 0.0
		for i: int in pts.size():
			if i > 0:
				run += pts[i].distance_to(pts[i - 1])
			cols.append(from_c.lerp(to_c, run / total if total > 0.0 else 0.0))
		return cols

	func _draw() -> void:
		# Same thickness as GraphEdit's own wires (it does not scale with zoom).
		for w: Dictionary in _wire_specs():
			var wpts: PackedVector2Array = w["pts"]
			draw_polyline_colors(wpts, gradient_colors(wpts, w["from"], w["to"]),
				float(w["width"]), true)
		# selected wire keeps its white highlight on top of everything
		var ep: Array = _endpoints()
		if ep.size() < 2:
			return
		var fp: Vector2 = ep[0]
		var tp: Vector2 = ep[1]
		# Use the EXACT polyline GraphEdit draws for this connection (via
		# get_connection_line) instead of an approximated bezier: Godot bends
		# connections differently when the target sits left of / above the
		# source (>= 90 degrees), and an approximation renders as a second,
		# diverging wire.
		var pts: PackedVector2Array = canvas.get_connection_line(fp, tp)
		if pts.size() < 2:
			return
		draw_polyline(pts, Color(1, 1, 1, 0.20), Types.DATA_WIRE_THICKNESS + 7.0, true)
		draw_polyline(pts, Color(1, 1, 1, 0.95), Types.DATA_WIRE_THICKNESS, true)


# ---- Node creation menu ----------------------------------------------------------
func _on_popup_request(at_position: Vector2) -> void:
	if not _over_empty_canvas(at_position):
		return
	_open_menu(at_position)


## True when `local_pos` is not covered by any node view.
func _over_empty_canvas(local_pos: Vector2) -> bool:
	for id: int in views:
		var v: NodeView = views[id]
		if Rect2(v.position, v.size).has_point(local_pos):
			return false
	return true


## Called when a wire drag is released over empty canvas (Blueprint-style:
## opens the spawn menu and connects the spawned node automatically).
func _on_connection_drag_started(node: StringName, port: int, is_output: bool) -> void:
	_drag_origin = {"node": str(node), "port": int(port), "is_output": is_output}


func _on_connection_to_empty(from_node: StringName, from_port: int, release_position: Vector2) -> void:
	# the auto-created error / warning pins only feed their Error / Warning node
	var src_view: NodeView = _view_of(from_node)
	if src_view != null and str(src_view.out_def(from_port).get("kind", "")) == "diag":
		return
	var pending: Dictionary = {"is_output": true, "node": str(from_node), "port": from_port}
	# Detaching a wire from an occupied INPUT pin flips the drag to the
	# wire's output end (Godot's detach-and-redrag). The user's intent was to
	# re-route the INPUT side, so keep the original input pin as the anchor:
	# whatever is spawned from the menu then feeds that input.
	if not _drag_origin.is_empty() and not bool(_drag_origin["is_output"]) \
			and (str(from_node) != str(_drag_origin["node"])
				or int(from_port) != int(_drag_origin["port"])):
		pending = {"is_output": false,
			"node": str(_drag_origin["node"]), "port": int(_drag_origin["port"])}
	_open_menu(_release_local(release_position), pending)


## Called when a drag from an occupied input pin is released over empty canvas.
func _on_connection_from_empty(to_node: StringName, to_port: int, release_position: Vector2) -> void:
	_open_menu(_release_local(release_position), {"is_output": false, "node": str(to_node), "port": to_port})


## release_position arrives in canvas-local coordinates when inside the canvas,
## otherwise it is already in graph coordinates.
func _release_local(p: Vector2) -> Vector2:
	if Rect2(Vector2.ZERO, size).has_point(p):
		return p
	return _graph_to_local(p)


func _open_menu(local_pos: Vector2, pending: Dictionary = {}) -> void:
	_pending_drag = pending
	_menu_at = local_pos
	_ensure_wire_layer()
	if _menu_root == null:
		_build_menu()
	_menu_search.text = ""
	_refresh_menu_items("")
	_menu_arg_btn.visible = _pending_is_argument_slot()
	# The menu layer shares the window's coordinate space, while local_pos is
	# canvas-local: offset by the canvas's own global origin.
	_menu_root.position = get_global_position() + _clamped_menu_pos(local_pos)
	_menu_root.show()
	# D1: the canvas is often partly hidden behind the editor's docks, so a
	# position valid in canvas coordinates can still land off-window. Clamp
	# the final placement to the visible viewport so the menu is always
	# entirely on-screen (the menu lives on a CanvasLayer in window space).
	var vr: Rect2 = get_viewport_rect()
	_menu_root.position = Vector2(
		clampf(_menu_root.position.x, 0.0, maxf(0.0, vr.size.x - _menu_root.size.x)),
		clampf(_menu_root.position.y, 0.0, maxf(0.0, vr.size.y - _menu_root.size.y)))
	_menu_open = true
	_menu_search.grab_focus()


## Annotation target the pending wire drag is anchored to ("" when the drag
## is not anchored at a declaration's "add annotation" slot). Used to open
## the node menu pre-filtered to annotations valid in that context.
## The special-slot kind the pending drag is anchored at: "" when the drag
## is not anchored at a declaration's registration slot, else "annotation"
## (free add-annotation slot), "group" (export annotation's add-group slot),
## "class_name" / "extends" (Script Header metadata slots).
func _pending_slot_kind() -> String:
	if _pending_drag.is_empty() or bool(_pending_drag["is_output"]):
		return ""
	var other: NodeView = _view_of(str(_pending_drag["node"]))
	if other == null or not model.nodes.has(other.model_id):
		return ""
	var tn: Dictionary = model.nodes[other.model_id]
	var idn: Dictionary = other.in_def(int(_pending_drag["port"]))
	if idn.is_empty() or idn["kind"] != "data":
		return ""
	var tins: Array = tn["data_ins"]
	if int(idn["index"]) >= tins.size():
		return ""
	var pname: String = String(tins[int(idn["index"])]["name"])
	if pname == "add annotation" or bool(tins[int(idn["index"])].get("ann", false)):
		return "annotation"
	if pname == "add group":
		return "group"
	if pname == "class name":
		return "class_name"
	if pname == "extends":
		return "extends"
	if int(tn["kind"]) == Model.Kind.CLASS_REF \
			and int(tins[int(idn["index"])]["type"]) == Types.PinType.MEMBER:
		return "member"
	return ""


func _pending_annotation_slot_target() -> String:
	if _pending_slot_kind() != "annotation":
		return ""
	var other: NodeView = _view_of(str(_pending_drag["node"]))
	return model._annotation_target_of(other.model_id)


## True when the pending wire drag is anchored at a Class Reference's
## "add member" slot or one of its member slot rows (the menu then lists
## exactly that class's members).
func _pending_is_member_slot() -> bool:
	return _pending_slot_kind() == "member"


## The class a pending member-slot drag belongs to ("" when none).
func _pending_member_target() -> String:
	if not _pending_is_member_slot():
		return ""
	var other: NodeView = _view_of(str(_pending_drag["node"]))
	if other == null or not model.nodes.has(other.model_id):
		return ""
	return String(model.nodes[other.model_id]["fields"].get("target", ""))


## True when the pending wire drag is anchored at an export annotation's
## "add group" input (the menu then offers @export_group nodes only).
func _pending_is_group_slot() -> bool:
	return _pending_slot_kind() == "group"


## True when the pending wire drag comes from a Function's "add argument" slot.
func _pending_is_argument_slot() -> bool:
	if _pending_drag.is_empty() or bool(_pending_drag["is_output"]):
		return false
	var other: NodeView = _view_of(str(_pending_drag["node"]))
	if other == null:
		return false
	var idn: Dictionary = other.in_def(int(_pending_drag["port"]))
	if idn.is_empty() or idn["kind"] != "data":
		return false
	var tins: Array = model.nodes[other.model_id]["data_ins"]
	if int(idn["index"]) >= tins.size():
		return false
	return int(model.nodes[other.model_id]["kind"]) == Model.Kind.ENTRY \
		and String(tins[int(idn["index"])]["name"]) == "add argument"


## Menu action: create one new separate Argument node and register it with the
## Function whose add-argument slot started this drag; then wire it up.
func _on_menu_spawn_argument() -> void:
	if not _pending_is_argument_slot():
		_close_menu()
		return
	var other: NodeView = _view_of(str(_pending_drag["node"]))
	var eid: int = other.model_id
	var aid: int = model.add_argument(eid)
	if aid < 0:
		_close_menu()
		return
	var idx: int = model.register_argument(eid, aid)
	var v: NodeView = _make_view(aid)
	var count: int = (model.nodes[eid]["fields"].get("args", []) as Array).size()
	var at: Vector2 = _local_to_graph(other.position + Vector2(other.size.x + 40.0, float(count) * 120.0))
	_place(v, at)
	_maybe_rebuild_pins(other)
	if idx >= 0:
		connect_node("n%d" % aid, views[aid].data_out_port(1), "n%d" % eid,
			views[eid].data_in_port(idx))
	modified.emit()
	_update_status()
	_close_menu()


func _close_menu() -> void:
	_menu_open = false
	_pending_drag = {}
	_drag_origin = {}
	_menu_set_selection(-1)
	if _menu_root != null:
		_menu_root.hide()


func _clamped_menu_pos(local_pos: Vector2) -> Vector2:
	var ms: Vector2 = Vector2(440, 520)   # fallback before first layout
	if _menu_root != null:
		var cm: Vector2 = _menu_root.get_combined_minimum_size()
		if cm.x > 0.0 and cm.y > 0.0:
			ms = cm
	# Prefer opening just right of / below the cursor; flip above when there is
	# not enough room below (Blueprint-like placement).
	var p: Vector2 = local_pos + Vector2(4, 4)
	if p.y + ms.y > size.y and local_pos.y - ms.y - 8.0 >= 0.0:
		p.y = local_pos.y - ms.y - 8.0
	p.x = clampf(p.x, 0.0, maxf(0.0, size.x - ms.x))
	p.y = clampf(p.y, 0.0, maxf(0.0, size.y - ms.y))
	return p


func _build_menu() -> void:
	# The menu lives on its own CanvasLayer: a layer above the base canvas
	# always renders above graph nodes and wires, is never clipped by node
	# containers, and its panel keeps mouse/wheel events (scrolling, search)
	# out of the graph underneath it.
	_menu_root = PanelContainer.new()
	_menu_root.mouse_filter = Control.MOUSE_FILTER_STOP
	# Consume wheel events on the panel itself (see _menu_wheel_guard below).
	_menu_root.gui_input.connect(_menu_wheel_guard)
	_menu_root.add_theme_stylebox_override("panel", UiStyle.popup_box(6.0))
	var outer: VBoxContainer = VBoxContainer.new()
	outer.add_theme_constant_override("separation", 6)
	_menu_root.add_child(outer)

	# --- body: Favorites/Recent rail + Search/Matches/Description column
	var body: HBoxContainer = HBoxContainer.new()
	body.add_theme_constant_override("separation", 6)
	outer.add_child(body)
	var rail: VBoxContainer = VBoxContainer.new()
	rail.custom_minimum_size = Vector2(120, 0)
	rail.add_theme_constant_override("separation", 0)
	body.add_child(rail)
	rail.add_child(_menu_head_label("Favorites:"))
	var fav_panel: PanelContainer = UiStyle.list_panel(true)
	fav_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_menu_fav_list = VBoxContainer.new()
	_menu_fav_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fav_panel.add_child(_menu_fav_list)
	rail.add_child(fav_panel)
	rail.add_child(_menu_head_label("Recent:"))
	var rec_panel: PanelContainer = UiStyle.list_panel(true)
	rec_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_menu_recent_list = VBoxContainer.new()
	_menu_recent_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rec_panel.add_child(_menu_recent_list)
	rail.add_child(rec_panel)

	var right: VBoxContainer = VBoxContainer.new()
	right.custom_minimum_size = Vector2(300, 0)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 3)
	body.add_child(right)

	# --- search row: field (accent ring on focus) + star + expand/collapse all
	right.add_child(_menu_head_label("Search:"))
	var search_row: HBoxContainer = HBoxContainer.new()
	search_row.add_theme_constant_override("separation", 3)
	_menu_search = LineEdit.new()
	_menu_search.placeholder_text = "Search nodes..."
	_menu_search.custom_minimum_size = Vector2(150, 26)
	_menu_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_menu_search.caret_blink = true
	_menu_search.clear_button_enabled = true
	UiStyle.style_line_edit(_menu_search)
	_menu_search.text_changed.connect(_refresh_menu_items)
	_menu_search.gui_input.connect(_on_menu_search_input)
	search_row.add_child(_menu_search)
	_menu_fav_btn = Button.new()
	_menu_fav_btn.text = "\u2606"
	_menu_fav_btn.tooltip_text = "Star the selected entry (session favorites)"
	_menu_fav_btn.custom_minimum_size = Vector2(26, 26)
	UiStyle.style_icon_button(_menu_fav_btn)
	_menu_fav_btn.pressed.connect(_on_menu_fav_toggle)
	search_row.add_child(_menu_fav_btn)
	var expand_btn: Button = Button.new()
	expand_btn.text = "\u2195"
	expand_btn.tooltip_text = "Expand all categories"
	expand_btn.custom_minimum_size = Vector2(26, 26)
	UiStyle.style_icon_button(expand_btn, true)
	expand_btn.pressed.connect(_menu_set_all_collapsed.bind(false))
	search_row.add_child(expand_btn)
	var collapse_btn: Button = Button.new()
	collapse_btn.text = "\u21c5"
	collapse_btn.tooltip_text = "Collapse all categories"
	collapse_btn.custom_minimum_size = Vector2(26, 26)
	UiStyle.style_icon_button(collapse_btn)
	collapse_btn.pressed.connect(_menu_set_all_collapsed.bind(true))
	search_row.add_child(collapse_btn)
	right.add_child(search_row)

	right.add_child(_menu_head_label("Matches:"))
	var list_panel: PanelContainer = UiStyle.list_panel(false)
	list_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(list_panel)
	var sc: ScrollContainer = ScrollContainer.new()
	sc.custom_minimum_size = Vector2(300, 300)
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# Wheel events over the list belong to the menu even at the scroll limits
	# (unconsumed wheel would otherwise fall through to the GraphEdit and zoom
	# the canvas mid-scroll).
	sc.gui_input.connect(_menu_wheel_guard_list)
	list_panel.add_child(sc)
	_menu_list = VBoxContainer.new()
	_menu_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_menu_list.add_theme_constant_override("separation", 0)
	sc.add_child(_menu_list)
	# Shown only when the menu was opened by dragging off a Function's
	# "add argument" slot: creates + registers a new separate Argument node.
	_menu_arg_btn = Button.new()
	_menu_arg_btn.text = "+  Function Argument"
	_menu_arg_btn.alignment = HORIZONTAL_ALIGNMENT_CENTER
	UiStyle.style_button(_menu_arg_btn, true)
	_menu_arg_btn.pressed.connect(_on_menu_spawn_argument)
	_menu_arg_btn.visible = false
	right.add_child(_menu_arg_btn)

	# --- description footer
	right.add_child(_menu_head_label("Description:"))
	_menu_desc = Label.new()
	_menu_desc.custom_minimum_size = Vector2(300, 44)
	_menu_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_menu_desc.add_theme_font_size_override("font_size", UiStyle.FONT_SIZE_SMALL)
	_menu_desc.add_theme_color_override("font_color", UiStyle.TEXT_MUTED)
	right.add_child(_menu_desc)

	# --- dialog buttons: Cancel closes, OK creates the selected entry
	var foot: HBoxContainer = HBoxContainer.new()
	foot.alignment = BoxContainer.ALIGNMENT_CENTER
	foot.add_theme_constant_override("separation", 40)
	var cancel_btn: Button = Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.custom_minimum_size = Vector2(100, 28)
	UiStyle.style_button(cancel_btn)
	cancel_btn.pressed.connect(_close_menu)
	foot.add_child(cancel_btn)
	_menu_ok_btn = Button.new()
	_menu_ok_btn.text = "OK"
	_menu_ok_btn.custom_minimum_size = Vector2(100, 28)
	UiStyle.style_button(_menu_ok_btn)
	_menu_ok_btn.pressed.connect(_on_menu_ok)
	foot.add_child(_menu_ok_btn)
	outer.add_child(foot)
	_build_menu_items()


## OK button: creates the highlighted entry (same path as pressing Enter).
func _on_menu_ok() -> void:
	if _menu_visible(_menu_sel):
		_on_menu_item(_menu_sel)


## Folds / unfolds every category at once (the buttons beside Search).
func _menu_set_all_collapsed(on: bool) -> void:
	for h: Dictionary in _menu_headers:
		var hl: Label = h["label"] as Label
		_menu_collapsed[str(hl.get_meta("cat", ""))] = on
	_apply_menu_collapse()


## Applies the fold state: folded categories hide their rows. While a search
## term is active every category stays open so results are never hidden.
func _apply_menu_collapse() -> void:
	var searching: bool = _menu_search != null and _menu_search.text.strip_edges() != ""
	for h: Dictionary in _menu_headers:
		var hl: Label = h["label"] as Label
		var cat: String = str(hl.get_meta("cat", ""))
		var folded: bool = bool(_menu_collapsed.get(cat, false)) and not searching
		hl.text = ("\u25b8  " if folded else "\u25be  ") + cat
		for i: int in range(int(h["from"]), int(h["to"]) + 1):
			if i < _menu_buttons.size():
				var row: Control = _menu_buttons[i].get_parent() as Control
				if row != null:
					row.visible = not folded
	if _menu_sel >= 0 and not _menu_visible(_menu_sel):
		_reset_menu_selection()


## Click on a category header toggles its fold state.
func _on_menu_header_input(event: InputEvent, cat: String) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		_menu_collapsed[cat] = not bool(_menu_collapsed.get(cat, false))
		_apply_menu_collapse()
		accept_event()


## Section label used across the menu (reference: bar with dim text).
func _menu_head_label(text: String) -> Label:
	return UiStyle.section_label(text)


## Rebuilds the menu's item list from the static catalog plus dynamic
## variable entries (Get/Set per declared variable, scope-filtered).
func _build_menu_items() -> void:
	_menu_catalog = []
	for e: Dictionary in _catalog:
		_menu_catalog.append(e)
	# Script header metadata nodes are always available in the menu.
	_menu_catalog.append({"cat": "Script header", "name": "Script Class Name",
		"kind": Model.Kind.CLASS_NAME, "fields": {}})
	_menu_catalog.append({"cat": "Script header", "name": "Script Extension",
		"kind": Model.Kind.EXTENDS_DECL, "fields": {}})
	# Class Reference nodes: every known class (engine classes curated,
	# custom classes and autoloads complete), one spawnable entry each.
	for c: Dictionary in _class_menu_items():
		_menu_catalog.append(c)
	var dyn: Array[Dictionary] = _dyn_var_entries()
	# insert after the existing "Variables" entries so they share the header
	var insert_at: int = _menu_catalog.size()
	for i: int in range(_menu_catalog.size() - 1, -1, -1):
		if str(_menu_catalog[i]["cat"]) == "Variables":
			insert_at = i + 1
		else:
			break
	for j: int in range(dyn.size()):
		_menu_catalog.insert(mini(insert_at + j, _menu_catalog.size()), dyn[j])
	_menu_items = _menu_catalog.duplicate()
	_rebuild_menu_list(_menu_items)
	_refresh_menu_rails()
	_update_menu_desc()
	_update_menu_fav_btn()


## Registry-derived function entries for the menu, grouped by source category
## ("print", "String.repeat", "helper.gd.process", ...).
## The menu lists a default selection when the search is empty and searches
## across every discovered source as soon as the user types.
func _function_menu_items() -> Array[Dictionary]:
	var reg: RefCounted = FuncReg.get_registry()
	if _func_items.is_empty():
		reg.ensure()
		for e: Dictionary in reg.entries:
			var cat: String = str(e["cat"])
			if cat == FuncReg.CAT_GODOT_TYPE \
					and not FuncReg.MENU_BUILTIN_TYPES.has(str(e["owner"])):
				continue   # fully supported via the registry; curated out of the menu
			if cat == FuncReg.CAT_GODOT_CLASS:
				if not FuncReg.MENU_CLASSES.has(str(e["owner"])):
					continue
				if bool(e.get("inherited", false)):
					continue   # own methods in the menu; inherited remain searchable
			if bool(e.get("virtual", false)):
				# Engine-invoked lifecycle/virtual callbacks (_ready, _process,
				# _input, ...): Godot calls them itself, so they are never
				# offered as manually callable Function Call nodes — for built-in
				# classes, custom scripts, addons and autoloads alike.
				continue
			if cat == FuncReg.CAT_EXTENSION and not bool(e.get("inherited", false)):
				pass
			_func_items.append(_menu_entry_for_function(e))
	return _func_items


## Converts one registry signature record into a spawnable menu entry. The
## bare function name is shown; the owning class/type/file is metadata.
func _menu_entry_for_function(e: Dictionary) -> Dictionary:
	var ret: String = str(e["ret"])
	var mode: String = "pure" if (ret != "void" and ret != "") else "exec"
	return {
		"cat": "Call: " + str(e["cat"]),
		"name": str(e["name"]),
		"meta": _menu_owner_text(e),
		"kind": Model.Kind.CALL,
		"fields": {
			"call": str(e["name"]), "cat": str(e["cat"]), "owner": str(e["owner"]),
			"ret": ret, "static": bool(e["static"]),
			"needs_target": bool(e["needs_target"]),
			"target_type": str(e["target_type"]),
			"vararg": bool(e.get("vararg", false)),
			"args": (e["args"] as Array).duplicate(true),
			"mode": mode, "declared": true,
		},
	}


## Secondary menu-row metadata: the owning class / type / singleton / file.
## Accepts both registry entries and menu entries (the latter keep cat/owner
## inside their fields).
func _menu_owner_text(e: Dictionary) -> String:
	var d: Dictionary = e["fields"] if e.has("fields") else e
	var cat: String = str(d.get("cat", ""))
	var owner_s: String = str(d.get("owner", ""))
	if cat == FuncReg.CAT_LANGUAGE:
		return "Engine"
	if owner_s.contains("/"):
		return owner_s.get_file()
	return owner_s


## Human-readable label for an annotation target context.
func _annotation_target_label(target: String) -> String:
	match target:
		"var":
			return "variables"
		"func":
			return "functions"
		"class":
			return "the script header"
		_:
			return "statements"


## One menu entry per annotation the registry knows: every supported built-in
## and custom GDScript annotation becomes its own selectable Annotation node.
func _annotation_menu_items() -> Array[Dictionary]:
	if _ann_items.is_empty():
		var reg: RefCounted = AnnReg.get_registry()
		for a: Dictionary in reg.ANNOTATIONS:
			if str(a["name"]) == "class_name":
				continue   # covered by the Script Header node's class_name field
			_ann_items.append({
				"cat": "Annotations",
				"name": "@" + str(a["name"]),
				"kind": Model.Kind.ANNOTATION,
				"fields": {"name": str(a["name"]),
					"args": (a["params"] as Array).duplicate(true)},
			})
	return _ann_items


## One menu entry per known class: spawns a Class Reference node. Autoloads
## spawn in singleton mode (the singleton IS the instance), everything else
## in class mode.
func _class_menu_items() -> Array[Dictionary]:
	if _class_items.is_empty():
		for c: Dictionary in ClassReg.get_registry().menu_classes():
			var mode: String = "singleton" if str(c["kind"]) == ClassReg.KIND_AUTOLOAD \
				else "class"
			_class_items.append({
				"cat": "Classes",
				"name": str(c["name"]),
				"meta": _class_owner_text(c),
				"kind": Model.Kind.CLASS_REF,
				"fields": {"target": str(c["name"]), "ref": mode, "source": ""},
			})
	return _class_items


## Secondary menu-row metadata for a class entry.
func _class_owner_text(c: Dictionary) -> String:
	match str(c.get("kind", "")):
		ClassReg.KIND_CUSTOM:
			return "Custom class"
		ClassReg.KIND_AUTOLOAD:
			return "Autoload singleton"
		ClassReg.KIND_EXTENSION:
			return "Extension class"
		ClassReg.KIND_SCRIPT:
			return str(c.get("path", ""))
		_:
			return "Engine class"


## The function-registry category of a class record's members (member call
## nodes reuse the call generation, which switches on this category).
func _member_cat_for(rec: Dictionary) -> String:
	match str(rec.get("kind", "")):
		ClassReg.KIND_ENGINE:
			return FuncReg.CAT_GODOT_CLASS
		ClassReg.KIND_EXTENSION:
			return FuncReg.CAT_EXTENSION
		ClassReg.KIND_CUSTOM:
			return FuncReg.CAT_CUSTOM
		ClassReg.KIND_AUTOLOAD:
			return FuncReg.CAT_AUTOLOAD
		_:
			return FuncReg.CAT_PROJECT


## Converts one class-member record into a spawnable member entry (a
## Function Call node bound to that member). Properties spawn as reads
## (the Call Mode selector switches to write), signals as emit statements.
func _member_menu_entry(rec: Dictionary, m: Dictionary) -> Dictionary:
	var target: String = str(rec["name"])
	var cat: String = _member_cat_for(rec)
	var owner_f: String = target if str(rec["kind"]) != ClassReg.KIND_SCRIPT \
		else str(rec.get("path", target))
	var mtype: String = str(m["mtype"])
	# signals emit as statements; properties and constants are reads (the
	# Call Mode selector switches a property to write)
	var mode: String = "exec" if mtype == ClassReg.MT_SIGNAL else "pure"
	var ret: String = str(m["ret"])
	if mtype == ClassReg.MT_SIGNAL:
		ret = "Signal"
	var kind_label: String = {ClassReg.MT_METHOD: "Method",
		ClassReg.MT_PROPERTY: "Property", ClassReg.MT_SIGNAL: "Signal",
		ClassReg.MT_CONSTANT: "Constant"}.get(mtype, "Member")
	return {
		"cat": "Members",
		"name": "%s.%s" % [target, str(m["name"])],
		"meta": kind_label,
		"kind": Model.Kind.CALL,
		"fields": {
			"call": str(m["name"]), "cat": cat, "owner": owner_f,
			"ret": ret, "mode": mode,
			"static": bool(m["static"]),
			"needs_target": bool(m["needs_target"]),
			"target_type": str(m["target_type"]),
			"vararg": bool(m.get("vararg", false)),
			"args": (m["args"] as Array).duplicate(true),
			"member": mtype,
			"declared": true,
		},
	}


## Member entries for the general menu search: every member of the curated
## class list (engine classes the function menu already curates, plus every
## custom class and autoload). Virtual callbacks stay excluded.
func _member_menu_items() -> Array[Dictionary]:
	if _member_items.is_empty():
		var regc: RefCounted = ClassReg.get_registry()
		for rec: Dictionary in regc.menu_classes():
			for m: Dictionary in regc.members_of(str(rec["name"])):
				if bool(m.get("virtual", false)):
					continue   # engine-invoked: never called by hand
				_member_items.append(_member_menu_entry(rec, m))
	return _member_items


## Rebuilds the visible menu list (headers + buttons) from concrete entries.
func _rebuild_menu_list(items: Array[Dictionary]) -> void:
	_menu_items = items
	for child: Control in _menu_list.get_children():
		_menu_list.remove_child(child)
		child.queue_free()
	_menu_headers = []
	_menu_buttons = []
	var last_cat: String = ""
	for i: int in items.size():
		var entry: Dictionary = items[i]
		if entry["cat"] != last_cat:
			last_cat = str(entry["cat"])
			var h: Label = Label.new()
			h.text = "\u25be  " + last_cat
			h.set_meta("cat", last_cat)
			h.add_theme_font_size_override("font_size", UiStyle.FONT_SIZE)
			h.add_theme_color_override("font_color", UiStyle.TEXT_DIM)
			h.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			h.custom_minimum_size = Vector2(0, UiStyle.ROW_HEIGHT)
			h.mouse_filter = Control.MOUSE_FILTER_STOP
			h.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			h.gui_input.connect(_on_menu_header_input.bind(last_cat))
			_menu_list.add_child(h)
			_menu_headers.append({"label": h, "from": i, "to": i})
		else:
			_menu_headers[-1]["to"] = i
		var b: Button = Button.new()
		b.text = entry["name"]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		UiStyle.style_row_button(b)
		b.add_theme_stylebox_override("normal", _menu_row_style(false))
		b.add_theme_stylebox_override("hover", _menu_row_style(true))
		b.add_theme_stylebox_override("pressed", _menu_row_style(true))
		b.add_theme_stylebox_override("focus", _menu_row_style(false))
		b.pressed.connect(_on_menu_item.bind(i))
		b.mouse_entered.connect(_menu_set_selection.bind(i))
		var row: HBoxContainer = HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_theme_constant_override("separation", 6)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(b)
		var meta_text: String = str(entry.get("meta", ""))
		if meta_text != "":
			var meta: Label = Label.new()
			meta.text = meta_text
			meta.add_theme_font_size_override("font_size", UiStyle.FONT_SIZE_SMALL)
			meta.add_theme_color_override("font_color", UiStyle.TEXT_MUTED)
			meta.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			meta.custom_minimum_size = Vector2(0, b.get_minimum_size().y)
			row.add_child(meta)
		# The data type the entry produces (a call's return type, a variable's
		# type, a literal's type, bool for comparisons) as an icon at the far
		# right of the row. The control is always added so the icons line up.
		var type_info: Dictionary = _menu_entry_type(entry)
		var type_icon: TextureRect = TypeIcons.make_icon_rect(
			TypeIcons.icon_for_type(str(type_info.get("text", ""))) \
			if str(type_info.get("text", "")) != "" else null, 16.0)
		type_icon.tooltip_text = str(type_info.get("text", ""))
		row.add_child(type_icon)
		_menu_list.add_child(row)
		_menu_buttons.append(b)
	_apply_menu_collapse()
	if _menu_layer == null:
		_menu_layer = CanvasLayer.new()
		_menu_layer.layer = 10   # above the base canvas (nodes, wires, highlights)
		add_child(_menu_layer)
	if _menu_root.get_parent() != _menu_layer:
		_menu_layer.add_child(_menu_root)
		_menu_root.hide()


## The data type a menu entry produces, as GDScript type text for its row
## icon ({} / empty text when it has none: flow nodes, statements, void calls).
func _menu_entry_type(entry: Dictionary) -> Dictionary:
	var f: Dictionary = entry.get("fields", {})
	match int(entry.get("kind", -1)):
		Model.Kind.LITERAL, Model.Kind.VARIABLE_GET, Model.Kind.VARIABLE_SET:
			return {"text": TypeIcons.pin_type_name(int(f.get("type", Types.VARIANT)))}
		Model.Kind.CALL:
			var ret: String = str(f.get("ret", "")).strip_edges()
			return {} if ret == "" or ret == "void" else {"text": ret}
		Model.Kind.OPERATOR:
			return {"text": "bool"} if Model._op_is_comparison(str(f.get("op", ""))) else {}
		Model.Kind.VAR_DECL:
			if bool(f.get("new_dict", false)):
				return {"text": "Dictionary"}
			if bool(f.get("new_array", false)):
				return {"text": "Array"}
		Model.Kind.CLASS_REF:
			return {"text": str(f.get("target", ""))}
	return {}


## Any wheel event over the menu belongs to the menu, never to the graph:
## Godot propagates unconsumed mouse-wheel events up the control tree, and the
## inner ScrollContainer only consumes them while it can actually scroll. At
## the menu's top or bottom scroll limit the wheel event would otherwise reach
## the GraphEdit and zoom the canvas mid-scroll. Consuming every wheel event
## on the menu panel itself (all four directions, at both limits) keeps menu
## scrolling and graph zooming strictly separate without touching scroll limits.
func _menu_wheel_guard(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN,
			MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT] \
			and _menu_root != null:
		accept_event()


## Wheel guard for the scroll list itself. The unconditional guard above
## must not be connected to the list: accepting a wheel event in the
## gui_input handler prevents the ScrollContainer's own wheel handling, so
## the list could never be scrolled by the wheel at all. Instead, the wheel
## is only swallowed at the scroll limits (where the unconsumed event would
## otherwise fall through to the graph and zoom it); everywhere else the
## ScrollContainer scrolls normally and consumes the event itself.
func _menu_wheel_guard_list(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and _menu_list != null and _menu_root != null:
		if event.button_index in [MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]:
			accept_event()   # horizontal wheel never scrolls the list
			return
		if event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var bar: VScrollBar = _menu_list.get_parent().get_v_scroll_bar()
			var hi: float = bar.max_value - bar.page
			var down: bool = event.button_index == MOUSE_BUTTON_WHEEL_DOWN
			if hi <= 0.0 or (down and _menu_list.get_parent().scroll_vertical >= hi - 0.5) \
					or (not down and _menu_list.get_parent().scroll_vertical <= 0.5):
				accept_event()


## Dynamic variable entries for the node menu: one Get/Set pair per declared
## variable, filtered by the menu's scope anchor. Private variables appear
## only when the menu is anchored inside their owner function (e.g. opened
## by dragging from a pin inside it).
func _dyn_var_entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var anchor: int = -1
	if not _pending_drag.is_empty():
		var pid: int = int(str(_pending_drag["node"]).trim_prefix("n"))
		if model.nodes.has(pid):
			anchor = int(model._ref_position(pid)["entry"])
	for id: int in model.nodes:
		if int(model.nodes[id]["kind"]) != Model.Kind.VAR_DECL:
			continue
		var n: Dictionary = model.nodes[id]
		var vname: String = str(n["fields"].get("name", ""))
		if vname == "":
			continue
		var is_private: bool = str(n["fields"].get("scope", "public")) == "private"
		if is_private and int(n["fields"].get("owner", -1)) != anchor:
			continue
		var t: int = int(n["stmt"].get("type", Types.VARIANT))
		out.append({"cat": "Variables", "name": "Get " + vname,
			"kind": Model.Kind.VARIABLE_GET, "fields": {"name": vname, "type": t}})
		out.append({"cat": "Variables", "name": "Set " + vname,
			"kind": Model.Kind.VARIABLE_SET, "fields": {"name": vname, "type": t}})
	return out


func _on_menu_search_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		# Up/Down honor key repeats so holding an arrow key navigates
		# continuously; other keys ignore repeats.
		if event.echo and event.keycode != KEY_UP and event.keycode != KEY_DOWN:
			return
		if event.keycode == KEY_ESCAPE:
			_close_menu()
			accept_event()
		elif event.keycode == KEY_DOWN:
			_menu_move_selection(1)
			accept_event()
		elif event.keycode == KEY_UP:
			_menu_move_selection(-1)
			accept_event()
		elif event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
			# Enter activates the keyboard-selected result; with no selection
			# (or a selection hidden by a newer search) it falls back to the
			# first visible match.
			var target: int = _menu_sel if _menu_visible(_menu_sel) else -1
			if target < 0:
				for i: int in _menu_items.size():
					if _menu_visible(i):
						target = i
						break
			if target >= 0:
				_on_menu_item(target)
			else:
				accept_event()   # no results: swallow Enter, keep menu open


func _item_matches(i: int, filter: String) -> bool:
	if i < 0 or i >= _menu_catalog.size():
		return false
	var f: String = filter.strip_edges().to_lower()
	if f == "":
		return true
	return str(_menu_catalog[i]["name"]).to_lower().contains(f)


func _menu_visible(i: int) -> bool:
	return i >= 0 and i < _menu_buttons.size() and i < _menu_items.size() \
		and _menu_buttons[i].visible and _menu_buttons[i].get_parent().visible


## Row look inside the Matches tree: indented under its category header,
## selected / hovered rows use the editor's tree-selection tone.
func _menu_row_style(hover: bool, selected: bool = false) -> StyleBoxFlat:
	var sb: StyleBoxFlat = UiStyle.row_box(selected, hover)
	sb.content_margin_left = 22.0
	sb.content_margin_right = 4.0
	return sb


## Moves the keyboard selection over the currently visible (search-filtered)
## entries. Wraps at both ends; skips hidden entries.
func _menu_move_selection(step: int) -> void:
	if _menu_buttons.is_empty():
		return
	var start: int = _menu_sel if _menu_visible(_menu_sel) else -1
	var sel: int = start
	for n: int in _menu_buttons.size():
		sel = (sel + step + _menu_buttons.size()) % _menu_buttons.size()
		if _menu_visible(sel):
			_menu_set_selection(sel)
			return
		if sel == start:
			break


## Highlights the keyboard-selected entry without stealing focus from the
## search field (arrow keys must keep typing possible).
func _menu_set_selection(i: int) -> void:
	if _menu_sel >= 0 and _menu_sel < _menu_buttons.size():
		var prev: Button = _menu_buttons[_menu_sel]
		prev.add_theme_stylebox_override("normal", _menu_row_style(false))
		prev.add_theme_stylebox_override("hover", _menu_row_style(true))
		prev.add_theme_stylebox_override("pressed", _menu_row_style(true))
	_menu_sel = i
	if i < 0:
		if _menu_ok_btn != null:
			_menu_ok_btn.disabled = true
		return
	var b: Button = _menu_buttons[i]
	var sb: StyleBoxFlat = _menu_row_style(true, true)
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("hover", sb)
	b.add_theme_stylebox_override("pressed", sb)
	if _menu_ok_btn != null:
		_menu_ok_btn.disabled = false
	# keep the selection visible while navigating the results list
	if _menu_list != null and b.is_visible_in_tree():
		var sc: ScrollContainer = _menu_list.get_parent() as ScrollContainer
		if sc != null:
			sc.ensure_control_visible(b)
	_update_menu_desc()
	_update_menu_fav_btn()


# ---- Menu rail: Favorites / Recent + description footer -----------------------
## Stable key for a menu entry (identifies it across search reordering and
## menu openings).
func _menu_entry_key(entry: Dictionary) -> String:
	return str(entry.get("cat", "")) + "|" + str(entry.get("name", "")) + "|" \
		+ str(entry.get("kind", -1))


func _on_menu_fav_toggle() -> void:
	if _menu_sel < 0 or _menu_sel >= _menu_items.size():
		return
	var key: String = _menu_entry_key(_menu_items[_menu_sel])
	if _menu_favs.has(key):
		_menu_favs.erase(key)
	else:
		if not _menu_favs.is_empty():
			_menu_favs.reverse()
			_menu_favs.append(key)
			_menu_favs.reverse()
		else:
			_menu_favs.append(key)
	_refresh_menu_rails()
	_update_menu_fav_btn()


func _menu_record_recent(entry: Dictionary) -> void:
	var key: String = _menu_entry_key(entry)
	_menu_recents.erase(key)
	_menu_recents.insert(0, key)
	while _menu_recents.size() > 6:
		_menu_recents.pop_back()


## Star reflects the selected entry's favorite state (filled vs empty).
func _update_menu_fav_btn() -> void:
	if _menu_fav_btn == null:
		return
	var faved: bool = _menu_sel >= 0 and _menu_sel < _menu_items.size() \
		and _menu_favs.has(_menu_entry_key(_menu_items[_menu_sel]))
	_menu_fav_btn.text = "\u2605" if faved else "\u2606"
	_menu_fav_btn.add_theme_color_override("font_color",
		UiStyle.ACCENT if faved else UiStyle.TEXT_DIM)


## Rebuilds the Favorites/Recent rail rows from the entry keys.
func _refresh_menu_rails() -> void:
	if _menu_fav_list == null:
		return
	for box: VBoxContainer in [_menu_fav_list, _menu_recent_list]:
		for child: Control in box.get_children():
			box.remove_child(child)
			child.queue_free()
	# Resolve keys back to catalog entries (dynamic variable entries may not
	# be present in the current catalog: skip those rows).
	var by_key: Dictionary = {}
	for e: Dictionary in _menu_catalog:
		by_key[_menu_entry_key(e)] = e
	for key: String in _menu_favs:
		if by_key.has(key):
			_menu_fav_list.add_child(_menu_rail_btn(by_key[key], "\u2605 "))
	for key: String in _menu_recents:
		if by_key.has(key):
			_menu_recent_list.add_child(_menu_rail_btn(by_key[key], ""))


## One rail row: a flat text button that spawns the entry when pressed.
func _menu_rail_btn(entry: Dictionary, prefix: String) -> Button:
	var b: Button = Button.new()
	b.text = prefix + str(entry["name"])
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.clip_text = true
	b.tooltip_text = str(entry["name"])
	b.focus_mode = Control.FOCUS_NONE
	UiStyle.style_row_button(b)
	b.pressed.connect(_spawn_menu_entry.bind(entry))
	return b


## Spawns a rail entry without going through the filtered list (rail rows are
## always visible while the menu is open).
func _spawn_menu_entry(entry: Dictionary) -> void:
	_menu_record_recent(entry)
	spawn_node(int(entry["kind"]), entry.get("fields", {}), _menu_at)
	_close_menu()


## Description footer: a factual one-liner for the keyboard/mouse-selected
## entry (updates on selection changes).
func _update_menu_desc() -> void:
	if _menu_desc == null:
		return
	if _menu_sel < 0 or _menu_sel >= _menu_items.size():
		_menu_desc.text = ""
		return
	var e: Dictionary = _menu_items[_menu_sel]
	var d: Dictionary = e["fields"] if e.has("fields") else {}
	var k: int = int(e["kind"])
	var txt: String = ""
	if k == Model.Kind.ANNOTATION:
		var reg: RefCounted = AnnReg.get_registry()
		for a: Dictionary in reg.ANNOTATIONS:
			if str(a["name"]) == str(d.get("name", "")):
				txt = str(a.get("brief", ""))
				break
		if txt == "":
			txt = "Annotation @" + str(d.get("name", ""))
	elif d.has("accessor"):
		txt = ("Setter: runs whenever its variable is assigned. Build the body from nodes, like a function."
			if str(d["accessor"]) == "set"
			else "Getter: runs whenever its variable is read. Build the body from nodes, like a function.")
	elif k == Model.Kind.CALL:
		var sig: String = str(d.get("call", ""))
		if str(d.get("owner", "")) != "" and str(d.get("owner", "")) != sig:
			sig = str(d.get("owner", "")) + "." + sig
		txt = "Function call" + (" · returns " + str(d.get("ret", "")) if str(d.get("ret", "void")) != "void" else "")
	else:
		# factual kind summary straight from the model's own title table
		if Model.KIND_TITLES.has(k):
			txt = str(Model.KIND_TITLES[k])
	_menu_desc.text = txt


## Shows/hides entries by the search filter; empty categories hide too.
func _refresh_menu_items(filter: String) -> void:
	if _menu_list == null:
		return
	var f: String = filter.strip_edges().to_lower()
	# A drag anchored at a declaration's "add annotation" slot opens the menu
	# in the annotation context: with an empty search it lists exactly the
	# annotations that are valid for that target (spawning one wires and
	# registers it automatically); a search term falls through to the general
	# ranked list so nothing becomes unreachable.
	var slot_kind: String = _pending_slot_kind()
	if slot_kind == "group" and f == "":
		# dragging from an export annotation's "add group" input: the menu
		# offers exactly @export_group (spawning one wires the association)
		_rebuild_menu_list([{"cat": "Export groups",
			"name": "@export_group", "kind": Model.Kind.ANNOTATION,
			"fields": {"name": "export_group",
				"args": [{"name": "name", "type": "String", "default": "",
					"sample": "Group"}]}}])
		_reset_menu_selection()
		return
	if slot_kind == "class_name" and f == "":
		_rebuild_menu_list([{"cat": "Script header", "name": "Script Class Name",
			"kind": Model.Kind.CLASS_NAME, "fields": {}}])
		_reset_menu_selection()
		return
	if slot_kind == "extends" and f == "":
		_rebuild_menu_list([{"cat": "Script header", "name": "Script Extension",
			"kind": Model.Kind.EXTENDS_DECL, "fields": {}}])
		_reset_menu_selection()
		return
	if slot_kind == "member" and f == "":
		# dragging from a Class Reference's member slot: the menu offers
		# exactly that class's members (spawning one wires and registers it
		# automatically, Blueprint-style)
		var ctx_cls: String = _pending_member_target()
		var rec0: Dictionary = ClassReg.get_registry().find_class(ctx_cls)
		var ctx: Array[Dictionary] = []
		if not rec0.is_empty():
			for m: Dictionary in ClassReg.get_registry().members_of(ctx_cls):
				if bool(m.get("virtual", false)):
					continue   # engine-invoked callbacks are never called by hand
				ctx.append(_member_menu_entry(rec0, m))
		if not ctx.is_empty():
			_rebuild_menu_list(ctx)
			_reset_menu_selection()
			return
	var ann_target: String = _pending_annotation_slot_target()
	if ann_target != "" and f == "":
		var ctx: Array[Dictionary] = []
		var reg0: RefCounted = AnnReg.get_registry()
		for a: Dictionary in reg0.ANNOTATIONS:
			if str(a["name"]) == "class_name":
				continue   # covered by the Script Class Name node
			if str(a["name"]) == "export_group":
				continue   # attaches through Export Group pins, not this slot
			if not (a["targets"] as Array).has(ann_target):
				continue
			ctx.append({"cat": "Annotations for %s" % _annotation_target_label(ann_target),
				"name": "@" + str(a["name"]), "kind": Model.Kind.ANNOTATION,
				"fields": {"name": str(a["name"]),
					"args": (a["params"] as Array).duplicate(true)}})
		if not ctx.is_empty():
			_rebuild_menu_list(ctx)
			_reset_menu_selection()
			return
	# Static + variable entries are always part of the list; function entries
	# come from the registry: a default selection when the search is empty,
	# a cross-source search as soon as the user types.
	var items: Array[Dictionary] = []
	for e: Dictionary in _menu_catalog:
		if f == "" or str(e["name"]).to_lower().contains(f):
			items.append(e)
	var anns: Array[Dictionary] = _annotation_menu_items()
	var funcs: Array[Dictionary] = _function_menu_items()
	var header_items: Array[Dictionary] = [
		{"cat": "Script header", "name": "Script Class Name",
			"kind": Model.Kind.CLASS_NAME, "fields": {}},
		{"cat": "Script header", "name": "Script Extension",
			"kind": Model.Kind.EXTENDS_DECL, "fields": {}}]
	if f == "":
		# The starter list leads with the script header nodes.
		for hi: Dictionary in header_items:
			items.append(hi)
		# Class Reference entries follow (a starter set of known classes).
		var class_items: Array[Dictionary] = _class_menu_items()
		for i: int in mini(class_items.size(), 40):
			items.append(class_items[i])
		# A starter set of annotation nodes is shown without a search term.
		for i: int in mini(anns.size(), 10):
			items.append(anns[i])
		var per_cat: Dictionary = {}
		for e: Dictionary in funcs:
			var c: String = str(e["cat"])
			var cap: int = 114 if c == "Call: " + FuncReg.CAT_LANGUAGE else 30
			if c in ["Call: " + FuncReg.CAT_LANGUAGE, "Call: " + FuncReg.CAT_PROJECT,
					"Call: " + FuncReg.CAT_CUSTOM, "Call: " + FuncReg.CAT_AUTOLOAD,
					"Call: " + FuncReg.CAT_ADDON]:
				per_cat[c] = int(per_cat.get(c, 0)) + 1
				if int(per_cat[c]) <= cap:
					items.append(e)
		_rebuild_menu_list(items)
		_reset_menu_selection()
		return
	# Search: ranked matches across function names, class metadata and
	# annotations. Exact name beats prefix beats substring beats owner match
	# beats fuzzy; ties resolve alphabetically. Nothing valid is excluded:
	# substring and fuzzy matches always make the list (ranked last).
	var ranked: Array[Dictionary] = []
	for e: Dictionary in funcs:
		var rank: int = FuncReg.rank_match(f, str(e["name"]), _menu_owner_text(e))
		if rank >= 0:
			ranked.append({"rank": rank, "e": e})
	for e2: Dictionary in anns:
		var rank2: int = FuncReg.rank_match(f, str(e2["name"]).trim_prefix("@"), "")
		if rank2 >= 0:
			ranked.append({"rank": rank2, "e": e2})
	for e3: Dictionary in _class_menu_items():
		var rankc: int = FuncReg.rank_match(f, str(e3["name"]), _menu_owner_text(e3))
		if rankc >= 0:
			ranked.append({"rank": rankc, "e": e3})
	for e4: Dictionary in _member_menu_items():
		var rankm: int = FuncReg.rank_match(f, str(e4["name"]), _menu_owner_text(e4))
		if rankm >= 0:
			ranked.append({"rank": rankm, "e": e4})
	for hi2: Dictionary in header_items:
		var rankh: int = FuncReg.rank_match(f, str(hi2["name"]), "")
		if rankh >= 0:
			ranked.append({"rank": rankh, "e": hi2})
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["rank"]) != int(b["rank"]):
			return int(a["rank"]) < int(b["rank"])
		var an: String = str(a["e"]["name"]).to_lower()
		var bn: String = str(b["e"]["name"]).to_lower()
		if an != bn:
			return an < bn
		# deterministic category/owner order keeps same-named functions
		# (Language.clamp vs Vector3.clamp) in their registry order
		var ac: String = str(a["e"]["cat"]) + str(a["e"].get("fields", {}).get("owner", ""))
		var bc: String = str(b["e"]["cat"]) + str(b["e"].get("fields", {}).get("owner", ""))
		return ac < bc)
	for m: Dictionary in ranked:
		if items.size() >= 200:
			break
		items.append(m["e"])
	_rebuild_menu_list(items)
	_reset_menu_selection()


## Puts the keyboard selection on the first visible entry after a rebuild.
func _reset_menu_selection() -> void:
	var first: int = -1
	for i: int in _menu_items.size():
		if _menu_visible(i):
			first = i
			break
	_menu_set_selection(first)


func _on_menu_item(idx: int) -> void:
	if idx < 0 or idx >= _menu_items.size():
		_close_menu()
		return
	var entry: Dictionary = _menu_items[idx]
	if OS.get_environment("VS_DEBUG_MENU") != "":
		print("MENUITEM idx=", idx, " name=", entry.get("name"), " kind=", entry.get("kind"))
	_menu_record_recent(entry)
	if int(entry["kind"]) == Model.Kind.ARGUMENT and _pending_is_argument_slot():
		# Dragging from a Function's "add argument" slot: spawn the argument
		# and register it with that Function immediately.
		_on_menu_spawn_argument()
		return
	if _pending_is_member_slot() and int(entry["kind"]) == Model.Kind.CALL \
			and str(entry.get("fields", {}).get("member", "")) != "":
		# Dragging from a Class Reference's member slot: spawn the member
		# and register it with that reference immediately.
		_on_menu_spawn_member(entry)
		return
	var id: int = spawn_node(int(entry["kind"]), entry.get("fields", {}), _menu_at)
	if id >= 0 and not _pending_drag.is_empty():
		_auto_connect_spawn(id, _pending_drag)
		_offset_getter_from_consumer(id, _pending_drag)
	_pending_drag = {}
	_close_menu()


## A Get Variable node spawned from a consumer's input pin sits one level
## (column) farther left of the node that uses it, instead of on top of it.
## The vertical position stays where the wire was dropped.
func _offset_getter_from_consumer(new_id: int, pending: Dictionary) -> void:
	if bool(pending.get("is_output", true)):
		return
	if int(model.nodes.get(new_id, {}).get("kind", -1)) != Model.Kind.VARIABLE_GET:
		return
	var consumer: NodeView = _view_of(pending["node"])
	var gv: NodeView = views.get(new_id, null)
	if consumer == null or gv == null:
		return
	_place(gv, Vector2(consumer.position_offset.x - LAYOUT_COL_PITCH, gv.position_offset.y))


## Menu action: create one member node for the Class Reference whose member
## slot started this drag, register it and wire it up (one step, like the
## Argument / Annotation spawn actions).
func _on_menu_spawn_member(entry: Dictionary) -> void:
	var other: NodeView = _view_of(str(_pending_drag["node"]))
	if other == null or not model.nodes.has(other.model_id):
		_close_menu()
		return
	var rid: int = other.model_id
	var id: int = spawn_node(int(entry["kind"]), entry.get("fields", {}))
	if id < 0:
		_close_menu()
		return
	# place the member right of its class reference, stacked by slot order
	if views.has(id) and views.has(rid):
		var rv: NodeView = views[rid]
		var slot: int = model.register_member(rid, id)
		var count: int = 0
		for ml: Dictionary in model.member_links:
			if int(ml["rid"]) == rid:
				count += 1
		_place(views[id], rv.position_offset
			+ Vector2(maxf(rv.size.x, rv.get_combined_minimum_size().x) + 60.0,
				float(count - 1) * 110.0))
		if slot >= 0:
			connect_node("n%d" % id, views[id].data_out_port(0), "n%d" % rid,
				views[rid].data_in_port(slot))
	_maybe_rebuild_pins(views.get(rid))
	_sync_connections()
	modified.emit()
	_update_status()
	_close_menu()


## Wires a just-spawned node to the wire drag that spawned it (Blueprint-style).
func _auto_connect_spawn(new_id: int, pending: Dictionary) -> void:
	var nn: Dictionary = model.nodes.get(new_id)
	if nn == null:
		return
	var other: NodeView = _view_of(pending["node"])
	if other == null:
		return
	var resynced: bool = false
	if bool(pending["is_output"]):
		var od: Dictionary = other.out_def(int(pending["port"]))
		if od.is_empty():
			return
		if od["kind"] == "exec" and bool(nn["exec_in"]):
			if model.connect_exec(other.model_id, int(od["index"]), new_id):
				resynced = true
		elif od["kind"] == "data":
			var t: int = int(model.nodes[other.model_id]["data_outs"][int(od["index"])]["type"])
			for i: int in nn["data_ins"].size():
				if Types.compatible(t, int(nn["data_ins"][i]["type"])):
					if not model.connect_data(other.model_id, int(od["index"]), new_id, i).has("_rejected"):
						resynced = true
					break
	else:
		var idn: Dictionary = other.in_def(int(pending["port"]))
		if idn.is_empty():
			return
		if idn["kind"] == "exec" and nn["exec_outs"].size() > 0:
			if model.connect_exec(new_id, 0, other.model_id):
				resynced = true
		elif idn["kind"] == "data":
			var tt: int = int(model.nodes[other.model_id]["data_ins"][int(idn["index"])]["type"])
			if int(tt) == Types.PinType.SCOPE and int(nn["kind"]) == Model.Kind.VAR_DECL:
				# Spawning a Variable from a scope slot: the variable becomes
				# private and joins the block through its scope wire (never an
				# execution wire), exactly like wiring an existing node by hand.
				if model.set_var_prop(new_id, "scope", "private") \
						and model.register_scope(other.model_id, new_id):
					resynced = true
					var nv: NodeView = _view_of(StringName("n%d" % new_id))
					if nv != null:
						_maybe_rebuild_pins(nv)
					# the host grows the new variable's named pin + a fresh slot
					_refresh_scope_hosts([other.model_id])
			for i: int in nn["data_outs"].size():
				if Types.compatible(int(nn["data_outs"][i]["type"]), tt):
					if not model.connect_data(new_id, i, other.model_id, int(idn["index"])).has("_rejected"):
						resynced = true
					break
	if resynced:
		_sync_connections()
		modified.emit()
		_update_status()


# ---- Diagnostics (Blueprint-style error / warning display) ---------------------
## Display only: this never edits the graph or the code.
func _get_diag_module() -> RefCounted:
	if _diag_module_tried:
		return _diag_module
	_diag_module_tried = true
	var me: Script = get_script() as Script
	if me == null or me.resource_path == "":
		return null
	var path: String = me.resource_path.get_base_dir().path_join("graph_diagnostics.gd")
	var gs: GDScript = ResourceLoader.load(path) as GDScript
	if gs != null and gs.can_instantiate():
		_diag_module = gs.new() as RefCounted
	return _diag_module


## Debounced re-check after an edit: indicators of errors that were fixed
## disappear, new ones appear, once editing pauses.
func _schedule_diagnostics(delay: float = DIAG_DELAY) -> void:
	if not diagnostics_enabled or not is_inside_tree():
		return
	_diag_gen += 1
	get_tree().create_timer(delay).timeout.connect(_on_diag_timer.bind(_diag_gen))


func _on_diag_timer(gen: int) -> void:
	if gen != _diag_gen or not is_inside_tree():
		return
	# The check compiles scratch copies of the script on the main thread: never
	# start it in the middle of a pan / drag, wait until the mouse is released.
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) \
			or Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE) \
			or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		_schedule_diagnostics(0.3)
		return
	refresh_diagnostics(false)


## Re-computes every error / warning of the current graph and updates the node
## indicators. `force_engine` also compile-checks scripts with static
## initializers (the live check skips those because the engine evaluates them).
## Coroutine (the analyzer-warning pass awaits a couple of frames); callers
## may fire-and-forget it, but a call while one is still running only queues
## another pass once the running one finishes.
func refresh_diagnostics(force_engine: bool = false) -> void:
	if _diag_refresh_busy:
		_diag_refresh_queued = true
		return
	var mod: RefCounted = _get_diag_module()
	if mod == null:
		return
	_diag_refresh_busy = true
	var ids: Dictionary = {}
	for id: int in model.nodes:
		ids[id] = true
	var gen: Dictionary = model.generate()
	var gen_at_start: int = _diag_gen   # _reset_diagnostics() cancels by bumping this
	var raw: Variant = await mod.call("analyze", gen, force_engine, ids)
	_diag_refresh_busy = false
	if gen_at_start != _diag_gen:
		return   # the graph was cleared / reloaded while the pass was awaiting
	if _diag_refresh_queued:
		_diag_refresh_queued = false
		if is_inside_tree():
			call_deferred("refresh_diagnostics", false)
	if not (raw is Dictionary) or not is_inside_tree():
		return
	_apply_diagnostics(raw as Dictionary)


func _apply_diagnostics(out: Dictionary) -> void:
	# the nodes' error / warning pins are rebuilt below: drop their wires first
	_disconnect_diag_wires()
	_diag_by_node = out.get("by_node", {}) as Dictionary
	for id: int in views:
		var v: NodeView = views[id]
		if is_instance_valid(v):
			v.set_diagnostics(_diag_by_node.get(id, []) as Array)
	_sync_diag_nodes()
	diag_errors = int(out.get("errors", 0))
	diag_warnings = int(out.get("warnings", 0))
	diag_details = _diag_details_text(out)
	diagnostics_changed.emit(diag_errors, diag_warnings, diag_details)


## Problems currently shown on one node (empty when it is clean).
func diagnostics_for(id: int) -> Array:
	return _diag_by_node.get(id, []) as Array


func _reset_diagnostics() -> void:
	_diag_gen += 1   # cancels any pending check
	_diag_by_node.clear()
	_clear_diag_nodes()
	if diag_errors != 0 or diag_warnings != 0 or diag_details != "":
		diag_errors = 0
		diag_warnings = 0
		diag_details = ""
		diagnostics_changed.emit(0, 0, "")


func _diag_details_text(out: Dictionary) -> String:
	var lines: PackedStringArray = PackedStringArray()
	var by_node: Dictionary = out.get("by_node", {}) as Dictionary
	var ids: Array = by_node.keys()
	ids.sort()
	for id: Variant in ids:
		var title: String = model._node_display_title(int(id))
		for v: Variant in (by_node[id] as Array):
			lines.append(_diag_line(title, v as Dictionary))
	for g: Variant in (out.get("global", []) as Array):
		lines.append(_diag_line("", g as Dictionary))
	if lines.size() > 25:
		var extra: int = lines.size() - 25
		lines = lines.slice(0, 25)
		lines.append("... and %d more" % extra)
	var note: String = str(out.get("note", ""))
	if note != "":
		lines.append(note)
	return "\n".join(lines)


func _diag_line(title: String, d: Dictionary) -> String:
	var tag: String = "Error" if str(d.get("severity", "error")) == "error" else "Warning"
	var ln: int = int(d.get("line", -1))
	var where: String = " (line %d)" % ln if ln > 0 else ""
	var who: String = "  [%s]" % title if title != "" else ""
	return "%s%s%s: %s" % [tag, who, where, str(d.get("message", ""))]


# ---- Error / Warning nodes ---------------------------------------------------
## A node with problems has an "error" and / or "warning" output pin (see
## graph_node.gd). For every such pin one Error / Warning node is spawned next
## to it, wired to the pin, listing the messages. Display only: nothing here
## touches the model or the generated code, and the nodes are re-derived from
## the diagnostics every time (positions included, never persisted).
func _get_diag_node_script() -> GDScript:
	if _diag_node_tried:
		return _diag_node_script
	_diag_node_tried = true
	var me: Script = get_script() as Script
	if me == null or me.resource_path == "":
		return null
	var path: String = me.resource_path.get_base_dir().path_join("graph_diag_node.gd")
	var gs: GDScript = ResourceLoader.load(path) as GDScript
	if gs != null and gs.can_instantiate():
		_diag_node_script = gs
	return _diag_node_script


## The GraphNode behind a GraphEdit node name: a model node's view or an
## Error / Warning node (null when it does not exist).
func graph_node_for(node_name: String) -> GraphNode:
	if node_name.begins_with(DIAG_NODE_PREFIX):
		return _diag_nodes.get(node_name, null) as GraphNode
	return views.get(_id_of(node_name), null) as GraphNode


## Error / Warning node of a model node ("error" or "warning"), null if none.
func diag_node_for(id: int, severity: String) -> GraphNode:
	return _diag_nodes.get("dg_%s%d" % [severity.substr(0, 1), id], null) as GraphNode


## Wire colour of an Error / Warning node's connection.
func diag_wire_color(node_name: String) -> Color:
	return Types.WARNING_COLOR if node_name.begins_with("dg_w") else Types.ERROR_COLOR


func _wire_endpoint_alive(node_name: String) -> bool:
	if node_name.begins_with(DIAG_NODE_PREFIX):
		var dn: GraphNode = _diag_nodes.get(node_name, null) as GraphNode
		return dn != null and views.has(int(dn.get("source_id")))
	return views.has(_id_of(node_name))


## Creates / updates / removes the Error and Warning nodes so they match
## `_diag_by_node`, then wires each to its source node's pin.
func _sync_diag_nodes() -> void:
	var dscript: GDScript = _get_diag_node_script()
	var wanted: Dictionary = {}   # node name -> {id, sev, items}
	if dscript != null:
		for id: Variant in _diag_by_node:
			if not views.has(int(id)):
				continue
			if _focus_entry >= 0 and not _focused_set.has(int(id)):
				continue   # focused on one function: its problems only
			for sev: String in ["error", "warning"]:
				var part: Array = []
				for it: Variant in (_diag_by_node[id] as Array):
					if str((it as Dictionary).get("severity", "error")) == sev:
						part.append(it)
				if not part.is_empty():
					wanted["dg_%s%d" % [sev.substr(0, 1), int(id)]] = {
						"id": int(id), "sev": sev, "items": part}
	for nm: String in _diag_nodes.keys():
		if not wanted.has(nm):
			_free_diag_node(nm)
	var fresh_any: bool = false
	for nm2: String in wanted:
		var w: Dictionary = wanted[nm2]
		var sid: int = int(w["id"])
		var node: GraphNode = _diag_nodes.get(nm2, null) as GraphNode
		var fresh: bool = node == null
		if fresh:
			node = dscript.new() as GraphNode
			add_child(node)
			node.position_offset_changed.connect(_mark_wires_dirty)
			node.resized.connect(_mark_wires_dirty)
		node.call("setup", str(w["sev"]), sid, model._node_display_title(sid),
			w["items"] as Array, _font, _font_size)
		if fresh:
			_diag_nodes[nm2] = node
			fresh_any = true
	if fresh_any:
		_place_diag_nodes(true)
		# new problems must be visible at once, not hunted down one by one
		_scroll_to_diag_nodes()
	_connect_diag_wires()
	_mark_wires_dirty()


## Wires every Error / Warning node to its source node's pin.
func _connect_diag_wires() -> void:
	for nm: String in _diag_nodes:
		var dn: GraphNode = _diag_nodes[nm] as GraphNode
		var sid: int = int(dn.get("source_id"))
		var sv: NodeView = views.get(sid)
		if sv == null:
			continue
		var port: int = sv.diag_out_port(str(dn.get("severity")))
		if port >= 0 and not is_node_connected("n%d" % sid, port, nm, 0):
			connect_node("n%d" % sid, port, nm, 0)


func _disconnect_diag_wires() -> void:
	for c: Dictionary in get_connection_list():
		if str(c["to_node"]).begins_with(DIAG_NODE_PREFIX):
			disconnect_node(str(c["from_node"]), int(c["from_port"]),
				str(c["to_node"]), int(c["to_port"]))


func _free_diag_node(nm: String) -> void:
	var old: GraphNode = _diag_nodes.get(nm, null) as GraphNode
	_diag_nodes.erase(nm)
	if old != null and is_instance_valid(old):
		if old.get_parent() != null:
			old.get_parent().remove_child(old)
		old.queue_free()


func _clear_diag_nodes() -> void:
	for nm: String in _diag_nodes.keys():
		_free_diag_node(nm)


## Frees Error / Warning nodes whose source node no longer exists.
func _prune_diag_nodes() -> void:
	for nm: String in _diag_nodes.keys():
		if not _wire_endpoint_alive(nm):
			_free_diag_node(nm)


func _graph_rect_of(n: GraphNode) -> Rect2:
	var ms: Vector2 = n.get_combined_minimum_size()
	return Rect2(n.position_offset, Vector2(maxf(n.size.x, ms.x), maxf(n.size.y, ms.y)))


## Puts each Error / Warning node next to its source node, on the first side
## (right, bottom-right, below, above, left) where it overlaps nothing.
## `only_fresh` leaves nodes that were already placed (and maybe dragged by the
## person) alone; a layout pass re-places all of them.
func _place_diag_nodes(only_fresh: bool = false) -> void:
	if _diag_nodes.is_empty():
		return
	var taken: Array[Rect2] = []
	for id: int in views:
		if _focus_entry >= 0 and not _focused_set.has(id):
			continue   # hidden by the function focus: it blocks no placement
		taken.append(_graph_rect_of(views[id]))
	var names: Array = _diag_nodes.keys()
	names.sort()
	for nm: String in names:
		var dn: GraphNode = _diag_nodes[nm] as GraphNode
		if only_fresh and bool(dn.get("placed")):
			taken.append(_graph_rect_of(dn))
			continue
		var sv: NodeView = views.get(int(dn.get("source_id")))
		if sv == null:
			continue
		var src: Rect2 = _graph_rect_of(sv)
		var ds: Vector2 = _graph_rect_of(dn).size
		var gap: float = 28.0
		var spots: Array[Vector2] = [
			Vector2(src.end.x + gap, src.position.y),
			Vector2(src.end.x + gap, src.end.y - ds.y),
			Vector2(src.position.x, src.end.y + gap),
			Vector2(src.position.x, src.position.y - ds.y - gap),
			Vector2(src.position.x - ds.x - gap, src.position.y)]
		var pick: Vector2 = spots[0]
		for sp: Vector2 in spots:
			var r: Rect2 = Rect2(sp, ds).grow(8.0)
			var hit: bool = false
			for t: Rect2 in taken:
				if r.intersects(t):
					hit = true
					break
			if not hit:
				pick = sp
				break
		dn.position_offset = pick
		dn.set("placed", true)
		taken.append(Rect2(pick, ds))


## Pans the canvas so every Error / Warning node — together with the source
## node it reports on — is on screen at once. Only pans when something is
## actually outside the current view, so it never fights the person's own
## scrolling. The content is centered when it fits and pinned to its top-left
## edge when it is larger than the view.
func _scroll_to_diag_nodes() -> void:
	if _diag_nodes.is_empty() or not is_inside_tree():
		return
	var content: Rect2 = Rect2()
	var first: bool = true
	for nm: String in _diag_nodes:
		var dn: GraphNode = _diag_nodes[nm] as GraphNode
		var r: Rect2 = _graph_rect_of(dn)
		content = r if first else content.merge(r)
		first = false
		var sv: NodeView = views.get(int(dn.get("source_id")))
		if sv != null:
			content = content.merge(_graph_rect_of(sv))
	if first:
		return
	_scroll_to_fit(content.grow(24.0), 260.0)


## Pans so `content` (graph coordinates) is fully on screen: centered when it
## fits, pinned to its top-left edge when it is larger than the view.
func _scroll_to_fit(content: Rect2, right_margin: float = 0.0) -> void:
	var view_w: float = maxf(size.x - right_margin, 300.0)
	var view: Rect2 = Rect2(_local_to_graph(Vector2.ZERO), Vector2(view_w, size.y) / zoom)
	if view.encloses(content):
		return
	var off: Vector2 = scroll_offset
	if content.size.x <= view.size.x:
		off.x = content.get_center().x * zoom - view_w * 0.5
	else:
		off.x = content.position.x * zoom - 16.0
	if content.size.y <= view.size.y:
		off.y = content.get_center().y * zoom - size.y * 0.5
	else:
		off.y = content.position.y * zoom - 16.0
	scroll_offset = off


# ---- Code generation -----------------------------------------------------------
## Generates GDScript from the graph and compile-checks it.
## Returns {text, problems, unreachable, ok, err_text}.
func generate_code() -> Dictionary:
	var res: Dictionary = model.generate()
	var code: String = res["text"]
	var err: Error = Types.compile_source(code)
	res["ok"] = err == OK
	res["err_text"] = "" if err == OK else "compile error %d" % err
	# The problem list must reflect invalid output: a compile failure is
	# surfaced here so callers (workspace save, dialogs, tests) never see
	# "problems: []" for code that cannot compile.
	if err != OK:
		var probs: PackedStringArray = res.get("problems", PackedStringArray()) as PackedStringArray
		var msg: String = "generated code does not compile (%s)" % res["err_text"]
		var already: bool = false
		for p: String in probs:
			if String(p).begins_with("generated code does not compile"):
				already = true
				break
		if not already:
			probs.append(msg)
		res["problems"] = probs
	res["code"] = code
	return res


## Contextual value suggestions for a pin's value field. The pin's full type
## identity decides what is relevant: enum-typed pins offer their actual
## constant values, everything else offers declared variable names whose
## text matches the typed prefix (never irrelevant suggestions).
func _value_suggestions(query: String, node_id: int, pin_index: int) -> Array:
	var n: Dictionary = model.nodes.get(node_id, {})
	if n.is_empty():
		return []
	var reg: RefCounted = TypeReg.get_registry()
	var ttext: String = model._pin_type_text(n, false, pin_index) \
		if pin_index >= 0 else str(n["fields"].get("type_text", ""))
	var q: String = query.strip_edges().to_lower()
	if ttext != "":
		var vals: Array = reg.enum_values(ttext)
		if not vals.is_empty():
			var out: Array = []
			for v: String in vals:
				if q == "" or v.to_lower().contains(q):
					out.append(v)
			return out
	var names: Array = []
	for id: int in model.nodes:
		if int(model.nodes[id]["kind"]) != Model.Kind.VAR_DECL:
			continue
		var vn: String = str(model.nodes[id]["fields"].get("name", ""))
		if vn != "" and (q == "" or vn.to_lower().contains(q)):
			names.append(vn)
	return names


func _update_status() -> void:
	status_changed.emit("%d nodes | %d connections" % [model.node_count(), model.link_count()])


# ---- Toolbar: grid pattern picker, selection navigation, header shortcut ------
## Adds the missing toolbar controls to the built-in GraphEdit menu bar:
## a Dots/Lines grid-pattern picker, back/forward selection navigation and an
## "Extends Node" shortcut to the script header node.
func _setup_toolbar() -> void:
	# toolbar strip uses the same bar tone as the editor's section headers
	add_theme_stylebox_override("menu_panel", UiStyle.flat(UiStyle.BAR_BG, Color(0, 0, 0, 0), 0, UiStyle.RADIUS, 4.0, 2.0))
	var mh: HBoxContainer = get_menu_hbox()
	var back: Button = Button.new()
	back.text = "\u25c0"
	back.tooltip_text = "Back to the previously selected node"
	UiStyle.style_icon_button(back)
	back.disabled = true
	back.pressed.connect(_nav_back)
	mh.add_child(back)
	mh.move_child(back, 0)   # navigation arrows bookend the bar
	var pat: OptionButton = OptionButton.new()
	pat.add_item("Dots")
	pat.add_item("Lines")
	pat.selected = 0
	pat.tooltip_text = "Grid pattern"
	UiStyle.style_button(pat)
	pat.item_selected.connect(func(i: int) -> void: grid_pattern = i)
	_grid_pattern_btn = pat
	mh.add_child(pat)
	mh.move_child(pat, 4)   # directly after the zoom buttons, before grid toggles
	var ext: Button = Button.new()
	ext.text = "Extends Node"
	ext.tooltip_text = "Go to the script header node (extends / class_name / class annotations)"
	UiStyle.style_button(ext)
	ext.pressed.connect(_focus_header)
	mh.add_child(ext)
	var fwd: Button = Button.new()
	fwd.text = "\u25b6"
	fwd.tooltip_text = "Forward to the next selected node"
	UiStyle.style_icon_button(fwd)
	fwd.disabled = true
	fwd.pressed.connect(_nav_forward)
	mh.add_child(fwd)
	_nav_back_btn = back
	_nav_fwd_btn = fwd


var _nav_back_btn: Button = null
var _nav_fwd_btn: Button = null
var _nav_moving: bool = false


## Tracks selection history for the back/forward toolbar arrows.
func _on_nav_selected(node: Node) -> void:
	if _nav_moving:
		return
	var id: int = _id_of(str(node.name))
	if id >= 0:
		_nav_push(id)


func _nav_push(id: int) -> void:
	if _nav_pos >= 0 and _nav_pos < _nav_history.size() and _nav_history[_nav_pos] == id:
		return
	if _nav_pos + 1 < _nav_history.size():
		_nav_history = _nav_history.slice(0, _nav_pos + 1)
	_nav_history.append(id)
	_nav_pos = _nav_history.size() - 1
	_update_nav_buttons()


func _nav_back() -> void:
	if _nav_pos <= 0:
		return
	_nav_pos -= 1
	_nav_moving = true
	focus_node(_nav_history[_nav_pos])
	_nav_moving = false
	_update_nav_buttons()


func _nav_forward() -> void:
	if _nav_pos >= _nav_history.size() - 1:
		return
	_nav_pos += 1
	_nav_moving = true
	focus_node(_nav_history[_nav_pos])
	_nav_moving = false
	_update_nav_buttons()


func _update_nav_buttons() -> void:
	if _nav_back_btn != null:
		_nav_back_btn.disabled = _nav_pos <= 0
	if _nav_fwd_btn != null:
		_nav_fwd_btn.disabled = _nav_pos >= _nav_history.size() - 1


# ---- Function focus (edit one function in isolation) ---------------------------
## Double-clicking a function in the workspace dock isolates it on the canvas:
## every other node is hidden, the function's own cluster fills the view and a
## workspace banner offers the way back (also Esc). Display only — the model,
## the generated code and the session positions of the hidden nodes are never
## touched; leaving the focus unhides everything and restores every wire.
## Emitted when the focus changes; -1 means the full graph is shown again.
signal function_focus_changed(entry_id: int)

var _focus_entry: int = -1
var _focused_set: Dictionary = {}   # node id -> true (the isolated cluster)
## Model ids created from here on belong to the editing session (spawned,
## undo-restored, resync-created): they stay visible inside the focus.
var _focus_new_from: int = 0

func is_function_focused() -> bool:
	return _focus_entry >= 0


func focused_function() -> int:
	return _focus_entry


## True when node `id` is currently visible inside the function focus.
func focus_contains(id: int) -> bool:
	return _focus_entry < 0 or _focused_set.has(id) or id >= _focus_new_from


## Isolates the function whose ENTRY node is `entry_id`. Returns true when the
## focus was entered (or already sat on that function).
func enter_function_focus(entry_id: int) -> bool:
	if not views.has(entry_id) or not model.nodes.has(entry_id):
		return false
	if int(model.nodes[entry_id]["kind"]) != Model.Kind.ENTRY:
		return false
	if _focus_entry == entry_id:
		_scroll_to_focus()
		return true
	exit_function_focus()
	_focus_entry = entry_id
	_focused_set.clear()
	var clusters: Dictionary = _cluster_map()
	var key: String = "func:%d" % entry_id
	var mx: int = entry_id
	for id: int in views:
		if str(clusters.get(id, "misc")) == key:
			_focused_set[id] = true
		mx = maxi(mx, id)
	_focused_set[entry_id] = true
	_focus_new_from = mx + 1
	# hide everything else and drop its display wires (the model is untouched)
	for id2: int in views:
		views[id2].visible = _focused_set.has(id2)
		if views[id2].is_selected():
			views[id2].selected = false
	_deselect_wire()
	_remove_hidden_wires()
	# Error / Warning nodes of hidden sources have no place in the focused view
	for nm: String in _diag_nodes.keys():
		var dn: GraphNode = _diag_nodes[nm] as GraphNode
		if dn != null and not _focused_set.has(int(dn.get("source_id"))):
			_free_diag_node(nm)
	_scroll_to_focus()
	function_focus_changed.emit(entry_id)
	return true


## Back to the full picture: unhides every node, restores every wire and
## returns the view to the graph's top-left (the same view a fresh load shows).
func exit_function_focus() -> void:
	if _focus_entry < 0:
		return
	_focus_entry = -1
	_focused_set.clear()
	_focus_new_from = 0
	for id: int in views:
		if is_instance_valid(views[id]):
			views[id].visible = true
	_sync_connections()
	_connect_diag_wires()
	_sync_diag_nodes()
	_scroll_content_to_top()
	function_focus_changed.emit(-1)


func _view_is_hidden(node_name: String) -> bool:
	var gn: GraphNode = graph_node_for(node_name)
	return gn == null or not gn.visible


## Drops the display wires of hidden nodes (function focus). Model links are
## untouched; `_sync_connections()` rebuilds them when the focus ends.
func _remove_hidden_wires() -> void:
	for c: Dictionary in get_connection_list():
		if _view_is_hidden(str(c["from_node"])) or _view_is_hidden(str(c["to_node"])):
			disconnect_node(str(c["from_node"]), int(c["from_port"]),
				str(c["to_node"]), int(c["to_port"]))


## Pans (and only pans) so the isolated function's whole cluster is on screen.
func _scroll_to_focus() -> void:
	if _focus_entry < 0 or not is_inside_tree():
		return
	var content: Rect2 = Rect2()
	var first: bool = true
	for id: int in _focused_set:
		if not views.has(id):
			continue
		var r: Rect2 = _graph_rect_of(views[id])
		content = r if first else content.merge(r)
		first = false
	# the function's own Error / Warning nodes belong to the focused view
	for nm: String in _diag_nodes:
		var dn: GraphNode = _diag_nodes[nm] as GraphNode
		if dn != null and _focused_set.has(int(dn.get("source_id"))):
			var dr: Rect2 = _graph_rect_of(dn)
			content = dr if first else content.merge(dr)
			first = false
	if first:
		return
	_scroll_to_fit(content.grow(24.0), 260.0)


## Esc leaves the function focus (the workspace banner button does the same).
func _unhandled_key_input(event: InputEvent) -> void:
	if _focus_entry >= 0 and event is InputEventKey and event.pressed \
			and not event.echo and event.keycode == KEY_ESCAPE:
		exit_function_focus()


## Centers the canvas on node `id` and selects it (also used by the toolbar
## "Extends Node" shortcut and the Graphs/Functions/Variables dock lists).
func focus_node(id: int) -> void:
	if not views.has(id):
		return
	var v: NodeView = views[id]
	var center: Vector2 = v.position_offset + v.size * 0.5
	scroll_offset = center * zoom - size * 0.5
	if not v.is_selected():
		_nav_moving = true
		set_selected(v)
		_nav_moving = false


## Toolbar "Extends Node": jumps to the Script Header node (extends,
## class_name, class-level annotations). Reports on the status bar when the
## graph has no header node.
func _focus_header() -> void:
	var hid: int = model._header_id
	if hid >= 0 and views.has(hid):
		focus_node(hid)
	else:
		status_changed.emit("This script has no header node (no extends/class_name/directives).")


# ---- Fonts -------------------------------------------------------------------
func _code_font() -> Font:
	if Engine.is_editor_hint():
		var th: Theme = EditorInterface.get_editor_theme()
		if th != null and th.has_font("source", "EditorFonts"):
			return th.get_font("source", "EditorFonts")
	return ThemeDB.fallback_font


func _code_font_size() -> int:
	if Engine.is_editor_hint():
		var th: Theme = EditorInterface.get_editor_theme()
		if th != null and th.has_font_size("source_size", "EditorFonts"):
			return th.get_font_size("source_size", "EditorFonts")
	return 13
