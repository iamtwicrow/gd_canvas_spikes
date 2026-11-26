@tool
extends GraphNode
## One graph node view: Blueprint-style header, body and connection pins.
## Rows (top to bottom): exec in, data inputs, code body, data outputs, exec outs.
## Left slots = inputs, right slots = outputs; execution ports are white
## triangles, data ports are circles tinted by type, with Godot's own
## data-type icon (type_icons.gd) beside the pin label. Nodes are rectangular
## with small 45-degree cut corners (ChamferStyle).

const Types = preload("graph_types.gd")
const Model = preload("graph_model.gd")
const TypeReg = preload("type_registry.gd")
const TypeSuggest = preload("type_suggest.gd")
const TypePicker = preload("type_picker.gd")
const AnnReg = preload("annotation_registry.gd")
const UiStyle = preload("ui_style.gd")
const TypeIcons = preload("type_icons.gd")
const CollText = preload("collection_text.gd")
const CollEd = preload("collection_editor.gd")

signal pin_value_changed(node_id: int, pin_index: int, text: String)
signal body_text_changed(node_id: int, text: String)
signal field_changed(node_id: int, key: String, text: String)
signal annotation_action(node_id: int, action: String, index: int, text: String)
## A Setter / Getter node's variable picker: the chosen Variable node's id (-1 = none).
signal accessor_owner_picked(node_id: int, var_id: int)

const ROW_W: float = 230.0
const ROW_H: float = 26.0
const CHAMFER: float = 4.0
## Outline colour of comment nodes (reference: goldenrod comment box).
const COMMENT_BORDER := Color("#9a7328")

## Kinds whose body is freely editable code (opaque statements, comments...).
const EDITABLE_BODY_KINDS: Array[int] = [Model.Kind.STATEMENT, Model.Kind.COMMENT, Model.Kind.PRINT]

## Kinds rendered from user-editable `fields` instead of a code body.
const FIELD_EDITORS: Dictionary[int, Array] = {
	Model.Kind.LITERAL: ["value"],
	Model.Kind.VARIABLE_GET: ["name"],
	Model.Kind.VARIABLE_SET: ["name"],
	Model.Kind.OPERATOR: ["op"],
	Model.Kind.CALL: ["call"],
}

## Common GDScript types offered by the type selectors. Custom types can
## always be typed directly into the editable field.
const COMMON_TYPES: Array[String] = ["int", "float", "bool", "String",
	"Vector2", "Vector2i", "Vector3", "Vector3i", "Color", "Array",
	"Dictionary", "Node", "Resource", "Object", "void"]

signal argument_action(node_id: int, action: String)
## Match branch editing on Match nodes: "set" (port = branch index, text =
## new pattern), "add" (index -1, text = optional pattern), "remove" (port).
signal match_action(node_id: int, action: String, port: int, text: String)
## Dynamic call-argument management on Function Call nodes:
## "add" (index -1), "remove"/"left"/"right" (index = pin index).
signal call_arg_action(node_id: int, action: String, index: int)
signal lambda_action(node_id: int, action: String, index: int)
## Emitted when a form field starts an editing session (focus gained) so the
## canvas can snapshot undo state BEFORE the first keystroke.
signal field_edit_started(node_id: int, key: String)
## Emitted when a form field finishes an editing session (focus lost / Enter /
## type picked); carries the text the field had when the session began.
signal field_committed(node_id: int, key: String, old_text: String)

var model_id: int = -1
## The graph model this view belongs to (set by the canvas). Used to hide
## annotation rows that a connected Annotation node already represents.
var model_ref: Model = null
var _font: Font
var _font_size: int = 13
var _in_defs: Array = []    # input port index -> {kind:"exec"/"data", index:int, row:int}
var _out_defs: Array = []   # output port index -> {kind:"exec"/"data", index:int, row:int}
var _form_fields: Dictionary = {}   # property key -> editor control (Function/Variable/Argument forms)
var _form_selectors: Dictionary = {}  # property key -> TypeSelect (for autocomplete access)
var _lambda_edits: Dictionary = {}    # Lambda property key -> editor (param rows / ret / body)
var _lambda_selects: Dictionary = {}  # Lambda property key -> TypeSelect
var _ann_edits: Array[LineEdit] = []   # one editor per annotation row
var _header_edits: Array[LineEdit] = []   # one editor per header directive line
var _out_labels: Dictionary = {}    # data-out index -> Label (updated in place)
var _in_labels: Dictionary = {}     # data-in index -> Label (updated in place)
var _pin_tags: Dictionary = {}      # data-in index -> native type icon (TextureRect)
var _out_tags: Dictionary = {}      # data-out index -> native type icon (TextureRect)
var _pin_editors: Dictionary = {}   # data-in index -> inline value editor (typed)
var _comment_body: Label = null   # comment node: plain-text body display
var _comment_edit: LineEdit = null   # comment node: active in-place editor
var _comment_raw: String = ""   # comment node: raw body behind the display
var _class_mode: OptionButton = null   # Class Reference: reference mode
var _enum_form: Control = null   # enum Declaration: the member form (null for other bodies)
var _acc_edits: Dictionary = {}   # accessor key -> editor (CheckBox / LineEdit / CodeEdit) on a Variable node
var _acc_layout: String = ""   # accessor section layout this view was built with (see accessor_layout_of)


## Contextual value suggestions for pin fields: (query, pin_index) -> Array[String].
## Set by the canvas so the model's type/variable knowledge drives completion.
var value_suggest: Callable = Callable()


func setup(n: Dictionary, font: Font, font_size: int) -> void:
	model_id = int(n["id"])
	_font = font
	_font_size = font_size
	name = "n%d" % model_id
	var kind: int = int(n["kind"])
	# Comment nodes are borderless text blocks in the reference UI: no header
	# band, no box - the light text IS the node. Verbatim declaration blocks
	# that hold only comment lines share that look.
	var is_comment: bool = _comment_look(kind, String(n["body"]))
	if is_comment:
		title = ""
	else:
		title = n["title"]
	if int(n["kind"]) == Model.Kind.ANNOTATION:
		# One node per annotation: the registry brief explains what it does
		# and where it may be applied.
		var brief: String = String(n["fields"].get("brief", ""))
		var tg: String = ", ".join((n["fields"].get("targets", []) as Array).map(
			func(t: Variant) -> String: return str(t)))
		tooltip_text = (brief + ("\nApplies to: " + tg if tg != "" else "")).strip_edges()
	var header: Color = Color(n["color"])
	var edge: Color = Types.NODE_BORDER

	if is_comment:
		# comment look: one dark box with a goldenrod outline; a selected
		# comment gets the brighter orange outline like every other node
		add_theme_stylebox_override("titlebar", StyleBoxEmpty.new())
		add_theme_stylebox_override("titlebar_selected", StyleBoxEmpty.new())
		var card: Types.ChamferStyle = Types.ChamferStyle.new(Color("#161719"), COMMENT_BORDER)
		card.border_width = 1.0
		card.content_margin_left = 10.0
		card.content_margin_right = 10.0
		card.content_margin_top = 7.0
		card.content_margin_bottom = 8.0
		add_theme_stylebox_override("panel", card)
		var csel: Types.ChamferStyle = Types.ChamferStyle.new(Color("#161719"), Types.SELECTED_COLOR)
		csel.content_margin_left = 10.0
		csel.content_margin_right = 10.0
		csel.content_margin_top = 7.0
		csel.content_margin_bottom = 8.0
		csel.border_width = 2.0
		add_theme_stylebox_override("panel_selected", csel)
	else:
		var tsb: Types.ChamferStyle = _titlebar_style(header)
		add_theme_stylebox_override("titlebar", tsb)
		# Selected: the header carries the orange outline itself (no bottom
		# edge) and the body panel continues it (no top edge), so the whole
		# node gets ONE chamfered outline like the reference.
		var tsb_sel: Types.ChamferStyle = _titlebar_style(header)
		tsb_sel.border_color = Types.SELECTED_COLOR
		tsb_sel.border_width = 2.0
		tsb_sel.border_bottom = false
		add_theme_stylebox_override("titlebar_selected", tsb_sel)
		add_theme_color_override("title_color", Types.HEADER_FG)
		add_theme_font_size_override("title_font_size", UiStyle.FONT_SIZE_TITLE)
		add_theme_constant_override("title_h_offset", 0)

		var bsb: Types.ChamferStyle = Types.ChamferStyle.new(Types.NODE_BG, edge)
		bsb.content_margin_left = 8.0
		bsb.content_margin_right = 8.0
		bsb.content_margin_bottom = 5.0
		bsb.cut_top_left = false
		bsb.cut_top_right = false
		add_theme_stylebox_override("panel", bsb)
		# selected nodes get the reference's orange outline around the whole
		# node: the panel covers the full node rect and the titlebar draws on
		# top of its upper strip
		var bsb_sel: Types.ChamferStyle = Types.ChamferStyle.new(Types.NODE_BG_SELECTED, Types.SELECTED_COLOR)
		bsb_sel.content_margin_left = 8.0
		bsb_sel.content_margin_right = 8.0
		bsb_sel.content_margin_bottom = 5.0
		bsb_sel.cut_top_left = false
		bsb_sel.cut_top_right = false
		bsb_sel.border_width = 2.0
		bsb_sel.border_top = false
		add_theme_stylebox_override("panel_selected", bsb_sel)
	_apply_header_deco(kind, is_comment)

	add_theme_constant_override("separation", 6)
	var icon: Texture2D = Types.exec_icon()
	var rows: int = 0

	# --- execution input
	if bool(n["exec_in"]):
		add_child(_spacer())
		set_slot(rows, true, Types.EXEC, Types.color_of(Types.EXEC), false, Types.EXEC, Color.WHITE, icon, null)
		_in_defs.append({"kind": "exec", "index": 0, "row": rows})
		rows += 1

	# --- Script metadata nodes: one editable field each (class name / base)
	if kind == Model.Kind.CLASS_NAME or kind == Model.Kind.EXTENDS_DECL:
		var is_cn: bool = kind == Model.Kind.CLASS_NAME
		var fkey: String = "name" if is_cn else "base"
		var flabel: String = "Class Name" if is_cn else "Base Class / Script Path"
		var fdef: String = "" if is_cn else "CharacterBody2D"
		var fe: LineEdit = _text_editor(String(n["fields"].get(fkey, "")), fkey, 150.0)
		if is_cn:
			(fe as LineEdit).placeholder_text = "PlayerController"
		else:
			(fe as LineEdit).placeholder_text = fdef
		_form_fields[fkey] = fe
		add_child(_form_row(flabel, fe))
		rows += 1

	# --- structured property form for top-level Variable nodes: Name + Type
	# (the Default Value row is the variable's data input pin row below).
	if kind == Model.Kind.VAR_DECL:
		var sc: OptionButton = OptionButton.new()
		sc.add_item("Public")
		sc.add_item("Private")
		sc.selected = 1 if str(n["fields"].get("scope", "public")) == "private" else 0
		sc.custom_minimum_size = Vector2(96, 24)
		sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sc.focus_mode = Control.FOCUS_CLICK
		UiStyle.style_button(sc)
		sc.item_selected.connect(func(i: int) -> void:
			field_edit_started.emit(model_id, "scope")
			field_changed.emit(model_id, "scope", "public" if i == 0 else "private")
			field_committed.emit(model_id, "scope",
				"private" if i == 0 else "public"))
		# NOTE: the old per-node "Static" checkbox was removed from the UI on
		# purpose - static-ness stays a model/generation concern (fields
		# is_static still round-trips and is still emitted by the generator).
		add_child(_form_row("Scope", sc))
		var vn: LineEdit = _text_editor(String(n["fields"].get("name", "")), "name", 118.0)
		_form_fields["name"] = vn
		add_child(_form_row("Variable Name", vn))
		var vt: TypeSelect = _type_selector(String(n["fields"].get("raw_type", "")), "type")
		_form_fields["type"] = vt.edit
		_form_selectors["type"] = vt
		add_child(_form_row("Data Type", vt))
		rows += 3
		rows += _annotations_rows(n, "var",
			str(n["fields"].get("scope", "public")) != "private")
		rows += _accessor_rows(n)

	# --- Class Reference: reference mode, class target, instance source
	if kind == Model.Kind.CLASS_REF:
		var cm: OptionButton = OptionButton.new()
		cm.add_item("Class")
		cm.add_item("Instance")
		cm.add_item("Singleton")
		var cref: String = String(n["fields"].get("ref", "class"))
		cm.selected = {"class": 0, "instance": 1, "singleton": 2}.get(cref, 0)
		cm.custom_minimum_size = Vector2(96, 24)
		cm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cm.focus_mode = Control.FOCUS_CLICK
		UiStyle.style_button(cm)
		_class_mode = cm
		cm.item_selected.connect(func(i: int) -> void:
			var val: String = ["class", "instance", "singleton"][i]
			field_edit_started.emit(model_id, "ref")
			field_changed.emit(model_id, "ref", val)
			field_committed.emit(model_id, cref, val))
		add_child(_form_row("Reference", cm))
		rows += 1
		var ct: TypeSelect = _type_selector(String(n["fields"].get("target", "")), "target")
		_form_fields["target"] = ct.edit
		_form_selectors["target"] = ct
		add_child(_form_row("Class", ct))
		rows += 1
		if cref == "instance":
			var se: LineEdit = _text_editor(String(n["fields"].get("source", "self")), "source", 118.0)
			se.placeholder_text = "self"
			_form_fields["source"] = se
			add_child(_form_row("Instance Source", se))
			rows += 1

	# --- Lambda: typed parameter rows, return type selector, body
	if kind == Model.Kind.LAMBDA:
		_lambda_edits = {}
		_lambda_selects = {}
		var lprms: Array = n["fields"].get("params", [])
		for li: int in lprms.size():
			var name_key: String = "param:%d:name" % li
			var type_key: String = "param:%d:type" % li
			var def_key: String = "param:%d:default" % li
			var pn: LineEdit = _text_editor(String(lprms[li].get("name", "")), name_key, 62.0)
			pn.placeholder_text = "name"
			var pt: TypeSelect = _type_selector(String(lprms[li].get("type", "")), type_key)
			var pd: LineEdit = _text_editor(String(lprms[li].get("default", "")), def_key, 62.0)
			pd.placeholder_text = "default"
			_lambda_edits[name_key] = pn
			_lambda_edits[type_key] = pt.edit
			_lambda_selects[type_key] = pt
			_lambda_edits[def_key] = pd
			var prow: HBoxContainer = HBoxContainer.new()
			prow.add_theme_constant_override("separation", 4)
			prow.add_child(pn)
			prow.add_child(pt)
			prow.add_child(pd)
			prow.add_child(_lambda_btn("\u00d7", "Remove this parameter", "remove_param", li))
			add_child(_form_row("Param", prow))
			rows += 1
		add_child(_form_row("Parameters", _lambda_btn("+ param", "Add a parameter row", "add_param", -1)))
		rows += 1
		var rt: TypeSelect = _type_selector(String(n["fields"].get("ret", "")), "ret")
		_lambda_edits["ret"] = rt.edit
		_lambda_selects["ret"] = rt
		add_child(_form_row("Return Type", rt))
		rows += 1
		var bd: CodeEdit = _lambda_code("body", String(n["fields"].get("body", "pass")))
		add_child(_form_row("Body", Control.new()))
		add_child(bd)
		rows += 2

	# --- data inputs (inline editable expression; Function nodes render their
	# left-side argument registration pins as label-only rows)
	var di: Array = n["data_ins"]
	for i: int in (0 if kind == Model.Kind.ARGUMENT else di.size()):
		var pin: Dictionary = di[i]
		var row: HBoxContainer = HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		row.custom_minimum_size = Vector2(ROW_W, 0)
		var lab: Label = Label.new()
		lab.text = pin["name"]
		lab.add_theme_font_size_override("font_size", UiStyle.FONT_SIZE)
		lab.add_theme_color_override("font_color", _pin_label_color(pin))
		lab.tooltip_text = _pin_label_tip(pin)
		# Godot's native data-type icon (bool / flt / Str / clr ...) between
		# the pin and the pin name, like the reference node UI.
		if TypeIcons.pin_type_name(int(pin["type"])) != "":
			var tag: TextureRect = _type_icon_rect(int(pin["type"]), _pin_type_text(n, pin))
			row.add_child(tag)
			_pin_tags[i] = tag
		row.add_child(lab)
		if kind == Model.Kind.ENTRY:
			# Function argument registration pin: no value editor. The "add
			# argument" and "add annotation" slots are the affordances for
			# registering Argument / Annotation nodes.
			var dim: bool = String(pin["name"]) == "add argument" \
				or String(pin["name"]) == "add annotation"
			if dim:
				lab.add_theme_color_override("font_color", UiStyle.TEXT_DISABLED)
			add_child(row)
			set_slot(rows, true, int(pin["type"]), Types.color_of(int(pin["type"])), false,
				int(pin["type"]), Color.WHITE, Types.data_icon_for(int(pin["type"])), null)
			_in_defs.append({"kind": "data", "index": i, "row": rows})
			_in_labels[i] = lab
			rows += 1
			continue
		if (String(pin["name"]) == "add annotation" \
				or bool(pin.get("ann", false))) \
				and int(pin["type"]) == Types.PinType.ANNOTATION:
			# Declaration annotation pins: one per annotation (labelled
			# @name - which annotation it belongs to) plus the free
			# "add annotation" slot. No value editor: Annotation nodes
			# register through them.
			add_child(row)
			set_slot(rows, true, int(pin["type"]), Types.color_of(int(pin["type"])), false,
				int(pin["type"]), Color.WHITE, Types.data_icon_for(int(pin["type"])), null)
			_in_defs.append({"kind": "data", "index": i, "row": rows,
				"ann": 1 if bool(pin.get("ann", false)) else 0})
			_in_labels[i] = lab
			rows += 1
			continue
		if kind == Model.Kind.PREAMBLE \
				and (String(pin["name"]) == "class name" or String(pin["name"]) == "extends") \
				and int(pin["type"]) == Types.PinType.ANNOTATION:
			# Script Header's "class name" / "extends" slots: wire-only (the
			# Script Class Name / Script Extension nodes edit the values), so
			# no text field here.
			add_child(row)
			set_slot(rows, true, int(pin["type"]), Types.color_of(int(pin["type"])), false,
				int(pin["type"]), Color.WHITE, Types.data_icon_for(int(pin["type"])), null)
			_in_defs.append({"kind": "data", "index": i, "row": rows})
			_in_labels[i] = lab
			rows += 1
			continue
		if String(pin["name"]) == "add group" \
				and int(pin["type"]) == Types.PinType.ANNOTATION:
			# Export annotations' "add group" slot: no value editor; an
			# @export_group node registers through it (visible wire).
			add_child(row)
			set_slot(rows, true, int(pin["type"]), Types.color_of(int(pin["type"])), false,
				int(pin["type"]), Color.WHITE, Types.data_icon_for(int(pin["type"])), null)
			_in_defs.append({"kind": "data", "index": i, "row": rows})
			_in_labels[i] = lab
			rows += 1
			continue
		if int(pin["type"]) == Types.PinType.SCOPE:
			# Scope-owning nodes' scope pins: one named row per registered
			# private variable (its name shows beside the pin) plus the empty
			# "add scope" slot; no value editor, the amber scope wire does it.
			if String(pin["name"]) == "add scope":
				lab.add_theme_color_override("font_color", UiStyle.TEXT_DISABLED)
			add_child(row)
			set_slot(rows, true, int(pin["type"]), Types.color_of(int(pin["type"])), false,
				int(pin["type"]), Color.WHITE, Types.data_icon_for(int(pin["type"])), null)
			_in_defs.append({"kind": "data", "index": i, "row": rows})
			_in_labels[i] = lab
			rows += 1
			continue
		if kind == Model.Kind.CLASS_REF and int(pin["type"]) == Types.PinType.MEMBER:
			# Class Reference "add member" slot and its per-member rows: no
			# value editor; member nodes register through them (visible wire).
			if String(pin["name"]) == "add member":
				lab.add_theme_color_override("font_color", UiStyle.TEXT_DISABLED)
			add_child(row)
			set_slot(rows, true, int(pin["type"]), Types.color_of(int(pin["type"])), false,
				int(pin["type"]), Color.WHITE, Types.data_icon_for(int(pin["type"])), null)
			_in_defs.append({"kind": "data", "index": i, "row": rows})
			_in_labels[i] = lab
			rows += 1
			continue
		# Typed inline value editor: bool pins get a checkbox, Color pins a
		# color picker; everything else stays a text field.
		var ed: Control = _make_pin_editor(i, pin, kind == Model.Kind.VAR_DECL)
		var idx: int = i
		if ed is LineEdit:
			if kind == Model.Kind.VAR_DECL:
				# The variable's value pin doubles as its structured value
				# field; a connected wire overrides it at generation.
				lab.text = "Value"
				(ed as LineEdit).text_changed.connect(func(t: String) -> void: field_changed.emit(model_id, "default", t))
			else:
				(ed as LineEdit).text_changed.connect(func(t: String) -> void: pin_value_changed.emit(model_id, idx, t))
		row.add_child(ed)
		if kind == Model.Kind.VAR_DECL and ed is LineEdit:
			# the variable's Default Value field participates in the form
			_form_fields["default"] = ed
			_wire_commit(ed, "default")
		if ed is LineEdit and kind != Model.Kind.ENTRY:
			# Contextual value autocompletion on every pin value field
			# (variables, enum constants... - the canvas decides what fits).
			_attach_value_suggest(ed, i)
		if kind == Model.Kind.CALL and (not bool(n["fields"].get("declared", false)) \
				or bool(n["fields"].get("vararg", false))):
			# free-form call arguments can be removed/reordered per pin
			var acts: HBoxContainer = HBoxContainer.new()
			acts.add_theme_constant_override("separation", 2)
			acts.add_child(_call_arg_button("\u25c0", "Move argument left", "left", i))
			acts.add_child(_call_arg_button("\u25b6", "Move argument right", "right", i))
			acts.add_child(_call_arg_button("\u2715", "Remove argument", "remove", i))
			row.add_child(acts)
		add_child(row)
		set_slot(rows, true, int(pin["type"]), Types.color_of(int(pin["type"])), false,
			int(pin["type"]), Color.WHITE, Types.data_icon_for(int(pin["type"])), null)
		_in_defs.append({"kind": "data", "index": i, "row": rows})
		_in_labels[i] = lab
		rows += 1
		# (call argument actions rendered above; the Add button follows the loop)

	# --- body / code content (or structured property editors)
	if kind == Model.Kind.ENTRY:
		# Function property form: Name + Return Type as labelled fields
		# (never the raw declaration line). Arguments live in their own nodes.
		# NOTE: the per-node "Static" checkbox was removed from the UI on
		# purpose - static functions are authored with the dedicated
		# "Static Func" node (fields.static still round-trips and is still
		# emitted by the generator).
		if n["fields"].has("accessor"):
			# Setter / Getter: no name, return type or annotations - it
			# belongs to one variable and runs when that variable is
			# assigned / read.
			var ovid: int = int(n["fields"].get("owner_var", -1))
			var pick: OptionButton = OptionButton.new()
			pick.add_theme_font_override("font", _font)
			pick.add_theme_font_size_override("font_size", _font_size)
			pick.focus_mode = Control.FOCUS_NONE
			pick.tooltip_text = "The variable this runs for. Pick one - a Setter / Getter without a variable is not written to the script."
			pick.add_item("(pick a variable)", 0)
			pick.set_item_metadata(0, -1)
			var sel_idx: int = 0
			if model_ref != null:
				for cand: Dictionary in model_ref.accessor_owner_candidates(model_id):
					pick.add_item(String(cand["name"]))
					pick.set_item_metadata(pick.item_count - 1, int(cand["id"]))
					if int(cand["id"]) == ovid:
						sel_idx = pick.item_count - 1
			pick.select(sel_idx)
			pick.item_selected.connect(func(i: int) -> void:
				accessor_owner_picked.emit(model_id, int(pick.get_item_metadata(i))))
			add_child(_form_row("Variable", pick))
			var rlab: Label = Label.new()
			rlab.text = "when it is assigned" if String(n["fields"]["accessor"]) == "set" \
				else "when it is read"
			rlab.add_theme_font_size_override("font_size", UiStyle.FONT_SIZE)
			rlab.add_theme_color_override("font_color", UiStyle.TEXT_DISABLED)
			add_child(_form_row("Runs", rlab))
			rows += 2
		else:
			var fn: LineEdit = _text_editor(String(n["fields"].get("name", "")), "name", 118.0)
			_form_fields["name"] = fn
			add_child(_form_row("Function Name", fn))
			var rt: TypeSelect = _type_selector(String(n["fields"].get("ret_type", "")), "ret_type")
			_form_fields["ret_type"] = rt.edit
			_form_selectors["ret_type"] = rt
			add_child(_form_row("Return Type", rt))
			rows += 2
			rows += _annotations_rows(n, "func")
	elif kind == Model.Kind.ARGUMENT:
		# Argument property panel, reference order: Function connection pin
		# first (top), then the property form, the default value editor and
		# the variable value pin last (bottom).
		# --- function connection output (TOP): the visible ownership wire
		# into the parent Function's registration slot (independent of the
		# value pin).
		var frow: HBoxContainer = HBoxContainer.new()
		frow.custom_minimum_size = Vector2(ROW_W, 0)
		var flab: Label = Label.new()
		flab.text = "Function"
		flab.add_theme_font_size_override("font_size", _font_size)
		flab.add_theme_color_override("font_color", UiStyle.TEXT_BRIGHT)
		flab.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		flab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		frow.add_child(flab)
		add_child(frow)
		# The slot type stays Variant so GraphEdit lets the drag reach our own
		# validation; the white pin colour marks the ownership wire.
		set_slot(rows, false, Types.VARIANT, Color.WHITE, true, Types.VARIANT,
			Types.color_of(Types.PinType.EXEC), null, null)
		_out_defs.append({"kind": "data", "index": 1, "row": rows})
		_out_labels[1] = flab
		rows += 1
		# --- property form
		var an: LineEdit = _text_editor(String(n["fields"].get("name", "")), "name", 118.0)
		_form_fields["name"] = an
		add_child(_form_row("Name", an))
		rows += 1
		var at_sel: TypeSelect = _type_selector(String(n["fields"].get("type", "")), "type")
		_form_fields["type"] = at_sel.edit
		_form_selectors["type"] = at_sel
		add_child(_form_row("Data Type", at_sel))
		rows += 1
		# --- default value field (no label, no pin: the default is edited
		# here, it can never be wired)
		var douts_arg: Array = n["data_outs"]
		var val_t: int = int(douts_arg[0]["type"]) if douts_arg.size() > 0 else Types.VARIANT
		var val_name: String = String(douts_arg[0]["name"]) if douts_arg.size() > 0 else String(n["fields"].get("name", "arg"))
		var def_val: String = String(n["fields"].get("default", ""))
		var drow: HBoxContainer = HBoxContainer.new()
		drow.custom_minimum_size = Vector2(ROW_W, 0)
		var dctl: Control
		if val_t == Types.BOOL:
			var dcb: CheckBox = CheckBox.new()
			dcb.button_pressed = def_val.to_lower() == "true"
			dcb.toggled.connect(func(on: bool) -> void:
				field_changed.emit(model_id, "default", "true" if on else "false")
				field_committed.emit(model_id, "default", "true" if on else "false"))
			dctl = dcb
		elif val_t == Types.COLOR:
			var dcp: ColorPickerButton = ColorPickerButton.new()
			dcp.custom_minimum_size = Vector2(40, 24)
			dcp.color = _parse_color(def_val)
			dcp.popup_closed.connect(func() -> void:
				var c: Color = dcp.color
				var s: String = "Color(%s, %s, %s, %s)" % [c.r, c.g, c.b, c.a]
				field_changed.emit(model_id, "default", s)
				field_committed.emit(model_id, "default", s))
			dctl = dcp
		else:
			var ded: LineEdit = LineEdit.new()
			ded.text = def_val
			ded.flat = true
			ded.add_theme_font_size_override("font_size", _font_size)
			ded.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			ded.text_changed.connect(func(t: String) -> void: field_changed.emit(model_id, "default", t))
			_wire_commit(ded, "default")
			dctl = ded
		# The default editor is a plain form field (never a pin), registered
		# so refresh() can keep it in sync with undo/redo and external edits.
		_form_fields["default"] = dctl
		dctl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		drow.add_child(dctl)
		add_child(drow)
		# No slot at all: the default row is a plain editor field.
		set_slot(rows, false, 0, Color.WHITE, false, 0, Color.WHITE, null, null)
		rows += 1
		# --- value pin (BOTTOM, input/output, beside the argument variable
		# value; independent of the Function connection pin above)
		var vrow: HBoxContainer = HBoxContainer.new()
		vrow.custom_minimum_size = Vector2(ROW_W, 0)
		var vlab: Label = Label.new()
		vlab.text = val_name
		vlab.add_theme_font_size_override("font_size", _font_size)
		vlab.add_theme_color_override("font_color", UiStyle.TEXT)
		vlab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vlab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		vrow.add_child(vlab)
		add_child(vrow)
		set_slot(rows, true, val_t, Types.color_of(val_t), true, val_t, Types.color_of(val_t),
			Types.data_icon_for(val_t), Types.data_icon_for(val_t))
		_in_defs.append({"kind": "data", "index": 0, "row": rows})
		_out_defs.append({"kind": "data", "index": 0, "row": rows})
		_out_labels[0] = vlab
		rows += 1
	elif FIELD_EDITORS.has(kind):
		for key: String in FIELD_EDITORS[kind]:
			var frow: HBoxContainer = HBoxContainer.new()
			frow.add_theme_constant_override("separation", 6)
			frow.custom_minimum_size = Vector2(ROW_W, 0)
			var flab: Label = Label.new()
			flab.text = "Function" if (kind == Model.Kind.CALL and key == "call") else key
			flab.add_theme_font_size_override("font_size", 12)
			flab.add_theme_color_override("font_color", UiStyle.TEXT_DIM)
			frow.add_child(flab)
			if kind == Model.Kind.LITERAL and key == "value" \
					and _coll_kind_of(int(n["fields"].get("type", Types.VARIANT))) != "":
				# Literal Dictionary / Array: entry / item form (add / remove /
				# reorder / sort) instead of typing braces, brackets, quotes.
				flab.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
				var ltype: int = int(n["fields"].get("type", Types.VARIANT))
				frow.add_child(_make_coll_form(ltype,
					String(n["fields"].get("value", "{}" if ltype == Types.PinType.DICTIONARY else "[]")),
					func(t: String) -> void: field_changed.emit(model_id, "value", t)))
				add_child(frow)
				rows += 1
				continue
			var fed: LineEdit = LineEdit.new()
			fed.text = String(n["fields"].get(key, ""))
			fed.custom_minimum_size = Vector2(110, 0)
			fed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			fed.add_theme_font_override("font", _font)
			fed.add_theme_font_size_override("font_size", _font_size)
			var fkey: String = key
			fed.text_changed.connect(func(t: String) -> void: field_changed.emit(model_id, fkey, t))
			_wire_commit(fed, fkey)
			frow.add_child(fed)
			add_child(frow)
			rows += 1
			if kind == Model.Kind.LITERAL and key == "value":
				_attach_value_suggest(fed, -1)
		if kind == Model.Kind.CALL:
			rows += _add_call_info_rows(n)
	elif kind == Model.Kind.VAR_DECL:
		# The raw "var my_var ..." declaration preview is intentionally not
		# rendered any more: Scope / Variable Name / Data Type / Value /
		# annotations already cover every editable part, and the preview only
		# duplicated text at the bottom of the node.
		pass
	elif kind == Model.Kind.IF or kind == Model.Kind.ELIF:
		# Blueprint style: the condition pin is the only place the condition
		# lives (typed value or a wired comparison node); the raw "if ..."
		# source line is never shown, so nothing is duplicated.
		pass
	else:
		var brow: Control = _body_row(n)
		add_child(brow)
		rows += 1

	# --- data outputs
	var douts: Array = n["data_outs"]
	for i: int in (0 if kind == Model.Kind.ARGUMENT else douts.size()):
		var pin2: Dictionary = douts[i]
		var row2: HBoxContainer = HBoxContainer.new()
		row2.custom_minimum_size = Vector2(ROW_W, 0)
		var lab2: Label = Label.new()
		lab2.text = pin2["name"]
		lab2.add_theme_font_size_override("font_size", UiStyle.FONT_SIZE)
		lab2.add_theme_color_override("font_color", UiStyle.TEXT_BRIGHT)
		lab2.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		lab2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row2.add_theme_constant_override("separation", 6)
		row2.add_child(lab2)
		if TypeIcons.pin_type_name(int(pin2["type"])) != "":
			var otag: TextureRect = _type_icon_rect(int(pin2["type"]), _pin_type_text(n, pin2))
			row2.add_child(otag)
			_out_tags[i] = otag
		add_child(row2)
		var dt: int = int(pin2["type"])
		set_slot(rows, false, dt, Color.WHITE, true, dt, Types.color_of(dt), null, Types.data_icon_for(dt))
		_out_defs.append({"kind": "data", "index": i, "row": rows})
		_out_labels[i] = lab2
		rows += 1

	# --- execution outputs
	var eouts: Array = n["exec_outs"]
	var is_match: bool = int(n["kind"]) == Model.Kind.MATCH
	for i: int in eouts.size():
		var r2: HBoxContainer = HBoxContainer.new()
		r2.custom_minimum_size = Vector2(ROW_W, 0)
		# A bare "▶" glyph inside the node is redundant (the GraphEdit slot
		# already draws the execution triangle at the node edge): keep the
		# label control (it sizes the row) but with empty text. Real branch
		# labels (True/False, loop body/done) stay visible.
		var elabel: String = String(eouts[i])
		if is_match and i < eouts.size() - 1:
			# Match branch patterns are editable (commit on Enter / focus
			# loss so the caret survives typing); a remove button drops the
			# branch (the last wire stays put, later branches shift).
			var bedit: LineEdit = LineEdit.new()
			bedit.text = elabel
			bedit.custom_minimum_size = Vector2(80, 22)
			bedit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			bedit.add_theme_font_size_override("font_size", 12)
			var bidx: int = i
			var bnode: int = model_id
			bedit.text_submitted.connect(func(t: String) -> void:
				match_action.emit(bnode, "set", bidx, t))
			bedit.focus_exited.connect(func() -> void:
				match_action.emit(bnode, "set", bidx, bedit.text))
			var bdel: Button = Button.new()
			bdel.text = "\u00d7"
			bdel.tooltip_text = "Remove this branch"
			bdel.flat = true
			bdel.focus_mode = Control.FOCUS_NONE
			bdel.add_theme_font_size_override("font_size", 12)
			bdel.pressed.connect(func() -> void:
				match_action.emit(bnode, "remove", bidx, ""))
			r2.add_child(bedit)
			r2.add_child(bdel)
		else:
			var lab3: Label = Label.new()
			lab3.text = "" if elabel == "\u25b6" else elabel
			lab3.add_theme_font_size_override("font_size", UiStyle.FONT_SIZE)
			lab3.add_theme_color_override("font_color", UiStyle.TEXT_BRIGHT)
			lab3.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			lab3.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			r2.add_child(lab3)
		add_child(r2)
		set_slot(rows, false, Types.EXEC, Color.WHITE, true, Types.EXEC, Types.color_of(Types.EXEC), null, icon)
		_out_defs.append({"kind": "exec", "index": i, "row": rows})
		rows += 1
	if is_match:
		# one grow slot: adds a branch before the "after" pin
		var addrow: HBoxContainer = HBoxContainer.new()
		addrow.custom_minimum_size = Vector2(ROW_W, 0)
		var addb: Button = Button.new()
		addb.text = "+ branch"
		addb.tooltip_text = "Add a match branch before the fall-through pin"
		addb.alignment = HORIZONTAL_ALIGNMENT_RIGHT
		addb.flat = true
		addb.add_theme_font_size_override("font_size", 11)
		addb.add_theme_color_override("font_color", UiStyle.LINK)
		addb.add_theme_color_override("font_hover_color", UiStyle.TEXT_BRIGHT)
		addb.focus_mode = Control.FOCUS_NONE
		var mnode: int = model_id
		addb.pressed.connect(func() -> void:
			match_action.emit(mnode, "add", -1, ""))
		addrow.add_child(addb)
		add_child(addrow)
		set_slot(rows, false, Types.EXEC, Color.WHITE, false, Types.EXEC, Color.WHITE, null, null)
		rows += 1


## Inline value editor for a data-in pin, chosen by the pin's type: bool pins
## get a checkbox, Color pins a color picker; everything else stays a text
## field (GDScript expressions, variable names, literals). Returns the control
## and records it in _pin_editors so refresh() can sync it in place.
func _make_pin_editor(pin_index: int, pin: Dictionary, is_default: bool) -> Control:
	var t: int = int(pin["type"])
	match t:
		Types.BOOL:
			var cb: CheckBox = CheckBox.new()
			cb.button_pressed = String(pin["value"]).strip_edges().to_lower() == "true"
			cb.tooltip_text = "Boolean value \u2014 checked is true, unchecked is false"
			UiStyle.style_check_box(cb)
			var mid: int = model_id
			var pi: int = pin_index
			cb.toggled.connect(func(on: bool) -> void:
				var txt: String = "true" if on else "false"
				if is_default:
					field_changed.emit(mid, "default", txt)
				else:
					pin_value_changed.emit(mid, pi, txt))
			_pin_editors[pi] = cb
			return cb
		Types.PinType.DICTIONARY, Types.PinType.ARRAY:
			# Dictionary / Array pins get the entry / item form instead of a
			# raw text box.
			var mid3: int = model_id
			var pi3: int = pin_index
			var dform: Control = _make_coll_form(t, String(pin["value"]), func(txt: String) -> void:
				if is_default:
					field_changed.emit(mid3, "default", txt)
				else:
					pin_value_changed.emit(mid3, pi3, txt))
			_pin_editors[pi3] = dform
			return dform
		Types.PinType.COLOR:
			var cp: ColorPickerButton = ColorPickerButton.new()
			cp.custom_minimum_size = Vector2(46, 26)
			cp.color = _color_from_text(String(pin["value"]))
			cp.tooltip_text = "Color value"
			cp.add_theme_stylebox_override("normal", UiStyle.flat(UiStyle.BUTTON_BG, Color(0, 0, 0, 0), 0, UiStyle.RADIUS, 4.0, 4.0))
			cp.add_theme_stylebox_override("hover", UiStyle.flat(UiStyle.BUTTON_HOVER, Color(0, 0, 0, 0), 0, UiStyle.RADIUS, 4.0, 4.0))
			cp.add_theme_stylebox_override("pressed", UiStyle.flat(UiStyle.ROW_SELECTED, UiStyle.ACCENT_DIM, 1, UiStyle.RADIUS, 4.0, 4.0))
			cp.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
			var mid2: int = model_id
			var pi2: int = pin_index
			cp.color_changed.connect(func(c: Color) -> void:
				var txt: String = var_to_str(c)
				if is_default:
					field_changed.emit(mid2, "default", txt)
				else:
					pin_value_changed.emit(mid2, pi2, txt))
			_pin_editors[pi2] = cp
			return cp
		_:
			var ed: LineEdit = LineEdit.new()
			ed.text = String(pin["value"])
			# same fixed field height as the structured property editors
			# (_text_editor), so the value box flows with the other boxes
			ed.custom_minimum_size = Vector2(110, 24)
			ed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			ed.add_theme_font_override("font", _font)
			ed.add_theme_font_size_override("font_size", _font_size)
			UiStyle.style_line_edit(ed)
			_pin_editors[pin_index] = ed
			return ed


## Pin-name label color: required pins use the full type color, optional
## (default-valued) pins are dimmed so the distinction is visible at a glance.
func _pin_label_color(pin: Dictionary) -> Color:
	var c: Color = UiStyle.TEXT_BRIGHT
	if pin.has("optional") and bool(pin["optional"]):
		c = Color(c.r, c.g, c.b, 0.72)
	if String(pin["name"]) == "add annotation" or String(pin["name"]) == "add group":
		c = Color(UiStyle.TEXT_DIM.r, UiStyle.TEXT_DIM.g, UiStyle.TEXT_DIM.b, 0.85)
	return c


## Pin-name tooltip: required vs optional (with the actual declared default).
func _pin_label_tip(pin: Dictionary) -> String:
	if String(pin["name"]) == "add annotation" \
			and int(pin["type"]) == Types.PinType.ANNOTATION:
		return "Connect an Annotation node here to add a new annotation"
	if bool(pin.get("ann", false)):
		return "This annotation's own pin: connect an Annotation node to replace it; disconnecting keeps the text unconnected"
	if int(pin["type"]) == Types.PinType.SCOPE:
		if String(pin["name"]) == "add scope":
			return "Connect a private variable's scope pin here to assign it to this scope"
		return "Private variable \"%s\" belongs to this scope" % String(pin["name"])
	if String(pin["name"]) == "add group" \
			and int(pin["type"]) == Types.PinType.ANNOTATION:
		return "Connect an @export_group node here to assign this export to that group"
	if not pin.has("optional"):
		return "Argument (vararg / grow slot)"
	if bool(pin["optional"]):
		var d: String = str(pin.get("default_text", ""))
		return "Optional argument - default: %s (leave untouched to use it)" % (d if d != "" else "none")
	return "Required argument"


## Parses a Color from a pin value string: "Color(1, 0, 0, 1)" (var_to_str
## form), named forms like "Color.WHITE", HTML "#ff8800". Falls back to white.
func _color_from_text(text: String) -> Color:
	var s: String = text.strip_edges()
	if s == "":
		return Color.WHITE
	var v: Variant = str_to_var(s)
	if v is Color:
		return v
	# Named constant form: "Color.RED" / "Color.WHITE" (constructor accepts
	# lowercase colour names).
	var named: String = s.trim_prefix("Color.").strip_edges().to_lower()
	if named != "" and named != s.to_lower():
		return Color(named)
	var e: Expression = Expression.new()
	if e.parse(s) == OK:
		var r: Variant = e.execute([], self, false)
		if not e.has_execute_error() and r is Color:
			return r
	return Color.WHITE


## Syncs an inline pin editor (CheckBox / ColorPickerButton / LineEdit) with
## a model value without emitting signals back into the model.
func _sync_pin_editor(ctrl: Control, pval: String) -> void:
	if not is_instance_valid(ctrl):
		return
	if ctrl.has_meta("coll_sync"):
		(ctrl.get_meta("coll_sync") as Callable).call(pval)
	elif ctrl is CheckBox:
		var cb: CheckBox = ctrl
		var on: bool = pval.strip_edges().to_lower() == "true"
		if cb.button_pressed != on:
			cb.set_pressed_no_signal(on)
	elif ctrl is ColorPickerButton:
		var cp: ColorPickerButton = ctrl
		var c: Color = _color_from_text(pval)
		if cp.color != c:
			cp.color = c
	elif ctrl is LineEdit:
		var le: LineEdit = ctrl
		if not le.has_focus() and le.text != pval:
			le.text = pval


## Updates the view IN PLACE from the current model node: title, slot
## colours/icons, pin labels and (unfocused) form field texts. No control is
## recreated, so keyboard focus, cursor position and selection survive.
func refresh(n: Dictionary) -> void:
	var k: int = int(n["kind"])
	title = "" if _comment_look(k, String(n["body"])) else String(n["title"])
	if _enum_form != null and is_instance_valid(_enum_form):
		(_enum_form as CollEd.EnumForm).sync_external(String(n["body"]))
	for d: Dictionary in _in_defs:
		var row: int = int(d["row"])
		if d["kind"] == "exec":
			set_slot(row, true, Types.EXEC, Types.color_of(Types.EXEC), false,
				Types.EXEC, Color.WHITE, Types.exec_icon(), null)
		else:
			var di: int = int(d["index"])
			if di >= n["data_ins"].size():
				continue
			var pin: Dictionary = n["data_ins"][di]
			var t: int = int(pin["type"])
			set_slot(row, true, t, Types.color_of(t), false, t, Color.WHITE,
				Types.data_icon_for(t), null)
			if _in_labels.has(di):
				var il: Label = _in_labels[di]
				il.add_theme_color_override("font_color", _pin_label_color(pin))
				il.tooltip_text = _pin_label_tip(pin)
			# sync the short type tag and the inline value editor in place
			if _pin_tags.has(di):
				var tg: TextureRect = _pin_tags[di]
				if is_instance_valid(tg):
					_set_type_icon(tg, t, _pin_type_text(n, pin))
			if _pin_editors.has(di):
				_sync_pin_editor(_pin_editors[di], String(pin["value"]))
	for d2: Dictionary in _out_defs:
		if d2["kind"] == "diag":
			continue   # auto-created error / warning pin: owned by set_diagnostics
		var row2: int = int(d2["row"])
		if d2["kind"] == "exec":
			set_slot(row2, false, Types.EXEC, Color.WHITE, true, Types.EXEC,
				Types.color_of(Types.EXEC), null, Types.exec_icon())
		else:
			var oi: int = int(d2["index"])
			if oi >= n["data_outs"].size():
				continue
			var pin2: Dictionary = n["data_outs"][oi]
			var t2: int = int(pin2["type"])
			set_slot(row2, false, t2, Color.WHITE, true, t2, Types.color_of(t2),
				null, Types.data_icon_for(t2))
			if _out_tags.has(oi):
				var otg: TextureRect = _out_tags[oi]
				if is_instance_valid(otg):
					_set_type_icon(otg, t2, _pin_type_text(n, pin2))
			if _out_labels.has(oi):
				var ol: Label = _out_labels[oi]
				ol.text = String(pin2["name"])
				ol.add_theme_color_override("font_color", UiStyle.TEXT_BRIGHT)
	# sync annotation rows (not currently being edited) with the model
	var anns_now: PackedStringArray = PackedStringArray()
	var joined_anns: String = String(n["fields"].get("annotations", ""))
	if joined_anns != "":
		anns_now = joined_anns.split("\n")
	for ai: int in _ann_edits.size():
		if ai >= anns_now.size():
			continue
		var ae: LineEdit = _ann_edits[ai]
		if is_instance_valid(ae) and not ae.has_focus() and ae.text != anns_now[ai]:
			ae.text = anns_now[ai]
	# sync header directive rows the same way
	if int(n["kind"]) == Model.Kind.PREAMBLE and _header_edits.size() > 0:
		var hlines: PackedStringArray = String(n["body"]).split("\n")
		for hi: int in mini(_header_edits.size(), hlines.size()):
			var he: LineEdit = _header_edits[hi]
			if is_instance_valid(he) and not he.has_focus() and he.text != hlines[hi]:
				he.text = hlines[hi]
	# Class Reference: the mode selector follows the model (external edits,
	# undo/redo); the target/source editors sync through _form_fields.
	if k == Model.Kind.CLASS_REF and _class_mode != null and is_instance_valid(_class_mode):
		var want_ref: int = {"class": 0, "instance": 1, "singleton": 2} \
			.get(String(n["fields"].get("ref", "class")), 0)
		if _class_mode.selected != want_ref:
			_class_mode.selected = want_ref
	# sync the comment node's plain-text display (hidden while being edited)
	if _comment_body != null and is_instance_valid(_comment_body):
		_comment_raw = String(n["body"])
		_comment_body.text = _comment_display_text(_comment_raw)
		_fit_comment_size()

	_sync_accessor_editors(n)
	_sync_lambda_editors(n)

	# sync form fields that are not currently being edited
	var kd: int = int(n["kind"])
	for key: String in _form_fields:
		var fraw: Variant = _form_fields.get(key)
		if kd == Model.Kind.ARGUMENT and key == "default":
			# The Argument's default editor may be a CheckBox / ColorPicker
			# (typed defaults): sync it in place like any pin editor.
			if fraw is Control and is_instance_valid(fraw):
				_sync_pin_editor(fraw, String(n["fields"].get("default", "")))
			continue
		var f: LineEdit = fraw as LineEdit
		if f == null or not is_instance_valid(f) or f.has_focus():
			continue
		var val: String = ""
		if kd == Model.Kind.VAR_DECL and key == "default":
			if n["data_ins"].size() > 0:
				val = String(n["data_ins"][0]["value"])
		elif kd == Model.Kind.VAR_DECL and key == "type":
			# the variable model stores the raw type text under "raw_type"
			# (there is no fields["type"]); reading the wrong key used to
			# blank the field ("untyped") on every unfocused refresh even
			# though the model kept the committed type
			val = String(n["fields"].get("raw_type", ""))
		else:
			val = String(n["fields"].get(key, ""))
		if f.text != val:
			f.text = val


## Number of data-in slots this view currently renders (structure check).
func data_in_count() -> int:
	var cnt: int = 0
	for d: Dictionary in _in_defs:
		if d["kind"] == "data":
			cnt += 1
	return cnt


## One labelled form row (login/register style): fixed-width caption on the
## left, vertically centred, with roomy spacing and an expanding field.
func _form_row(label_text: String, ctl: Control) -> HBoxContainer:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.custom_minimum_size = Vector2(ROW_W, 0)
	var lab: Label = Label.new()
	lab.text = label_text
	lab.add_theme_font_size_override("font_size", UiStyle.FONT_SIZE)
	lab.add_theme_color_override("font_color", UiStyle.TEXT_BRIGHT)
	lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lab.custom_minimum_size = Vector2(100, 0)
	row.add_child(lab)
	ctl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(ctl)
	return row


func _parse_color(s: String) -> Color:
	var t: String = s.strip_edges()
	if t.is_empty():
		return Color.WHITE
	var v: Variant = str_to_var(t)
	if v is Color:
		return v
	if t.begins_with("#") or Color.html_is_valid(t):
		return Color.from_string(t, Color.WHITE)
	# Last resort: try GDScript Color(...) literal with named args/variants.
	if t.begins_with("Color("):
		var inner: String = t.substr(6, t.length() - 7)
		var parts: PackedStringArray = inner.split(",", false)
		if parts.size() >= 3:
			var r: float = parts[0].strip_edges().to_float()
			var g: float = parts[1].strip_edges().to_float()
			var b: float = parts[2].strip_edges().to_float()
			var a: float = parts[3].strip_edges().to_float() if parts.size() >= 4 else 1.0
			return Color(r, g, b, a)
	return Color.WHITE


## Full-width flat form button with a hairline border.
func _form_button(label_text: String, on_pressed: Callable) -> Button:
	var b: Button = Button.new()
	b.text = label_text
	b.alignment = HORIZONTAL_ALIGNMENT_CENTER
	UiStyle.style_button(b, true)
	b.pressed.connect(on_pressed)
	return b


## Input-field look for form LineEdits: padded, slightly lighter panel,
## small radius, subtle border.
static func _field_box(focused: bool) -> StyleBoxFlat:
	return UiStyle.field_box(focused)


## One labelled form row for the structured property editors. Identical
## metrics to _form_row, so labels and value boxes align across every node
## type (Function, Variable, Argument, Call).
## Registry-backed Function Call nodes show their resolved source, the real
## signature and (for value-returning functions) a Statement/Expression mode
## selector. Returns the number of rows added.
func _add_call_info_rows(n: Dictionary) -> int:
	var f: Dictionary = n["fields"]
	var cat: String = str(f.get("cat", ""))
	var rows: int = 0
	if str(f.get("member", "")) != "":
		# member nodes: one row naming the member kind and owning class
		var mk: Label = Label.new()
		var kind_text: String = {"method": "Method", "property": "Property",
			"signal": "Signal"}.get(str(f.get("member", "")), "Member")
		mk.text = "Member: %s of %s" % [kind_text, str(f.get("owner", ""))]
		mk.add_theme_font_size_override("font_size", 11)
		mk.add_theme_color_override("font_color", UiStyle.LINK)
		mk.custom_minimum_size = Vector2(ROW_W, 0)
		mk.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		add_child(mk)
		rows += 1
	if bool(f.get("declared", false)):
		var src: Label = Label.new()
		src.text = "Source: " + ((cat + " - " + str(f.get("owner", ""))
			.get_file() if str(f.get("owner", "")).contains("/")
			else cat + " - " + str(f.get("owner", ""))) if cat != "" else "This script")
		src.add_theme_font_size_override("font_size", 11)
		src.add_theme_color_override("font_color", UiStyle.LINK)
		src.custom_minimum_size = Vector2(ROW_W, 0)
		src.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		add_child(src)
		rows += 1
		var sig: Label = Label.new()
		var parts: PackedStringArray = PackedStringArray()
		for a: Dictionary in f.get("args", []):
			parts.append("%s: %s" % [str(a["name"]), str(a["type"])])
		var ret: String = str(f.get("ret", "void"))
		sig.text = "Signature: %s(%s) -> %s" % [str(f.get("call", "")), ", ".join(parts),
			ret if ret != "" else "void"]
		sig.add_theme_font_size_override("font_size", 11)
		sig.add_theme_color_override("font_color", UiStyle.TEXT_MUTED)
		sig.custom_minimum_size = Vector2(ROW_W, 0)
		sig.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		add_child(sig)
		rows += 1
		var mode: String = str(f.get("mode", "exec"))
		var can_be_pure: bool = ret != "" and ret != "void"
		var mb: OptionButton = OptionButton.new()
		mb.add_item("Statement (exec)")
		if can_be_pure:
			mb.add_item("Expression (value)")
		mb.selected = 1 if (mode == "pure" and can_be_pure) else 0
		mb.disabled = not can_be_pure
		mb.custom_minimum_size = Vector2(ROW_W, 24)
		mb.focus_mode = Control.FOCUS_CLICK
		mb.item_selected.connect(func(i: int) -> void:
			var val: String = "pure" if (i == 1 and can_be_pure) else "exec"
			field_edit_started.emit(model_id, "mode")
			field_changed.emit(model_id, "mode", val)
			field_committed.emit(model_id, mode, val))
		add_child(_form_row("Call Mode", mb))
		rows += 1
	return rows


func _prop_row(label_text: String, ctl: Control) -> HBoxContainer:
	return _form_row(label_text, ctl)


## Plain editable text field bound to a structured field key.
func _text_editor(initial: String, key: String, min_width: float) -> LineEdit:
	var ed: LineEdit = LineEdit.new()
	ed.text = initial
	ed.custom_minimum_size = Vector2(min_width, 24)
	ed.add_theme_font_override("font", _font)
	ed.add_theme_font_size_override("font_size", _font_size)
	ed.add_theme_stylebox_override("normal", _field_box(false))
	ed.add_theme_stylebox_override("focus", _field_box(true))
	ed.text_changed.connect(func(t: String) -> void: field_changed.emit(model_id, key, t))
	_wire_commit(ed, key)
	return ed


## Undo session wiring for a form field: snapshot on focus, commit on
## focus lost / Enter. The control itself is never replaced while typing.
func _wire_commit(ed: LineEdit, key: String) -> void:
	var old: String = ed.text
	ed.focus_entered.connect(func() -> void:
		old = ed.text
		field_edit_started.emit(model_id, key))
	ed.text_submitted.connect(func(_t: String) -> void:
		field_committed.emit(model_id, key, old))
	ed.focus_exited.connect(func() -> void:
		field_committed.emit(model_id, key, old))


## Editable type field with a dropdown of common GDScript types; custom types
## are typed directly into the field. An empty text means "untyped" /
## "no explicit return type".
## Attaches the shared autocomplete to a pin value field; suggestions come
## from the canvas hook (context: node, pin, its type - enums offer their
## real constant values, other pins offer fitting variable names).
func _attach_value_suggest(ed: LineEdit, pin_index: int) -> void:
	if not value_suggest.is_valid():
		return
	var sg: TypeSuggest = TypeSuggest.new()
	var vid: int = model_id
	var pi: int = pin_index
	sg.attach(ed, func(q: String) -> Array:
		if not value_suggest.is_valid():
			return []
		return value_suggest.call(q, vid, pi))


func _type_selector(initial: String, key: String) -> TypeSelect:
	var sel: TypeSelect = TypeSelect.new(initial)
	sel.edit.add_theme_stylebox_override("normal", _field_box(false))
	sel.edit.add_theme_stylebox_override("focus", _field_box(true))
	sel.add_theme_font_override("font", _font)
	sel.add_theme_font_size_override("font_size", _font_size)
	sel.type_changed.connect(func(t: String) -> void: field_changed.emit(model_id, key, t))
	sel.type_edit_started.connect(func() -> void: field_edit_started.emit(model_id, key))
	sel.type_committed.connect(func(old: String) -> void: field_committed.emit(model_id, key, old))
	return sel


## Small action button for per-pin call-argument management.
func _call_arg_button(text: String, tip: String, action: String, index: int) -> Button:
	var b: Button = Button.new()
	b.text = text
	b.tooltip_text = tip
	b.flat = true
	b.add_theme_font_size_override("font_size", 10)
	b.add_theme_color_override("font_color", UiStyle.TEXT_MUTED)
	b.add_theme_color_override("font_hover_color", UiStyle.ACCENT)
	b.pressed.connect(func() -> void: call_arg_action.emit(model_id, action, index))
	return b


## Small action button used for argument reorder/remove.
func _action_button(text: String, tip: String, action: String) -> Button:
	var b: Button = Button.new()
	b.text = text
	b.tooltip_text = tip
	b.flat = true
	b.add_theme_font_size_override("font_size", 11)
	b.add_theme_color_override("font_color", UiStyle.TEXT_DIM)
	b.add_theme_color_override("font_hover_color", UiStyle.ACCENT)
	b.pressed.connect(func() -> void: argument_action.emit(model_id, action))
	return b


## Small action button used on Lambda nodes (parameter add / remove).
func _lambda_btn(text: String, tip: String, action: String, index: int) -> Button:
	var b: Button = Button.new()
	b.text = text
	b.tooltip_text = tip
	b.flat = true
	b.add_theme_font_size_override("font_size", 10)
	b.add_theme_color_override("font_color", UiStyle.TEXT_MUTED)
	b.add_theme_color_override("font_hover_color", UiStyle.ACCENT)
	b.pressed.connect(func() -> void: lambda_action.emit(model_id, action, index))
	return b


## A small multi-line GDScript editor bound to one Lambda field (the body).
func _lambda_code(key: String, initial: String) -> CodeEdit:
	var cd: CodeEdit = CodeEdit.new()
	cd.text = initial
	cd.tooltip_text = "Lambda body. One statement per line; `return` produces the Callable's value."
	cd.add_theme_font_override("font", _font)
	cd.add_theme_font_size_override("font_size", _font_size)
	cd.add_theme_stylebox_override("normal", _field_box(false))
	cd.add_theme_stylebox_override("focus", _field_box(true))
	cd.custom_minimum_size = Vector2(ROW_W + 40.0, 24.0 * (initial.split("\n").size() + 1))
	cd.gutters_draw_line_numbers = false
	cd.highlight_current_line = true
	cd.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	cd.scroll_fit_content_height = true
	cd.scroll_fit_content_width = false
	cd.indent_use_spaces = false
	cd.indent_automatic = true
	var old: Array[String] = [initial]
	cd.focus_entered.connect(func() -> void:
		old[0] = cd.text
		field_edit_started.emit(model_id, key))
	cd.text_changed.connect(func() -> void: field_changed.emit(model_id, key, cd.text))
	cd.focus_exited.connect(func() -> void: field_committed.emit(model_id, key, old[0]))
	_lambda_edits[key] = cd
	return cd


## Keeps the Lambda editors in step with the model (undo / redo, external
## changes) without touching one that is being typed in.
func _sync_lambda_editors(n: Dictionary) -> void:
	if _lambda_edits.is_empty():
		return
	var prms: Array = n["fields"].get("params", [])
	for key: String in _lambda_edits:
		var ctl: Variant = _lambda_edits[key]
		if not (ctl is Control) or not is_instance_valid(ctl):
			continue
		var val: String = ""
		var parts: PackedStringArray = key.split(":")
		if parts[0] == "param":
			var idx: int = int(parts[1])
			if idx >= prms.size():
				continue
			val = String(prms[idx].get(parts[2], ""))
		else:
			val = String(n["fields"].get(key, ""))
		if ctl is TextEdit:
			var te: TextEdit = ctl as TextEdit
			if not te.has_focus() and te.text != val:
				te.text = val
		elif ctl is LineEdit:
			var le: LineEdit = ctl as LineEdit
			if not le.has_focus() and le.text != val:
				le.text = val


## Borderless comment look: real comments and verbatim declaration blocks
## made only of comment lines.
func _comment_look(kind: int, body: String) -> bool:
	return kind == Model.Kind.COMMENT \
		or (kind == Model.Kind.DECLARATION and body.strip_edges().begins_with("#"))


## Reference comment look: a "# Title" header row and the comment text below
## as plain large text - no embedded editor box, no scrollbar. Double-click
## the text to edit it in place (single-line comments get a LineEdit,
## multi-line ones a small code editor); the display comes back when the
## editor loses focus.
func _comment_display(n: Dictionary) -> Control:
	_comment_raw = String(n["body"])
	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	var head: HBoxContainer = HBoxContainer.new()
	head.add_theme_constant_override("separation", 5)
	var hash_lab: Label = Label.new()
	hash_lab.text = "#"
	hash_lab.add_theme_font_override("font", _font)
	hash_lab.add_theme_font_size_override("font_size", _font_size + 5)
	hash_lab.add_theme_color_override("font_color", COMMENT_BORDER.lightened(0.45))
	head.add_child(hash_lab)
	var tl: Label = Label.new()
	tl.text = String(n["title"])
	tl.add_theme_font_override("font", _font)
	tl.add_theme_font_size_override("font_size", _font_size + 5)
	tl.add_theme_color_override("font_color", UiStyle.TEXT_BRIGHT)
	head.add_child(tl)
	vbox.add_child(head)
	_comment_body = Label.new()
	_comment_body.text = _comment_display_text(_comment_raw)
	_comment_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_comment_body.add_theme_font_override("font", _font)
	_comment_body.add_theme_font_size_override("font_size", _font_size + 5)
	_comment_body.add_theme_color_override("font_color", UiStyle.TEXT_BRIGHT)
	_comment_body.mouse_filter = Control.MOUSE_FILTER_STOP
	_comment_body.tooltip_text = "Double-click to edit this comment"
	_comment_body.gui_input.connect(_on_comment_gui_input)
	vbox.add_child(_comment_body)
	_fit_comment_size()
	return vbox


## Display text for a comment: the raw body with each line's leading "#"
## marker (and indentation) stripped - the "#" badge in the header already
## says this is a comment.
func _comment_display_text(body: String) -> String:
	var out: PackedStringArray = []
	for line: String in body.split("\n"):
		var s: String = line.strip_edges(true, true)
		if s.begins_with("#"):
			s = s.substr(1).strip_edges(true, false)
		out.append(s)
	return "\n".join(out)


func _on_comment_gui_input(event: InputEvent) -> void:
	var mb: InputEventMouseButton = event as InputEventMouseButton
	if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT \
			or not mb.double_click:
		return
	_begin_comment_edit()


func _begin_comment_edit() -> void:
	if _comment_edit != null or _comment_body == null or not is_instance_valid(_comment_body):
		return
	var body: String = _comment_raw
	var parent: Container = _comment_body.get_parent()
	var ed: Control
	if body.contains("\n"):
		var cd: CodeEdit = CodeEdit.new()
		cd.text = body
		cd.add_theme_font_override("font", _font)
		cd.add_theme_font_size_override("font_size", _font_size + 5)
		cd.custom_minimum_size = Vector2(ROW_W + 40.0, ROW_H * 1.6 * float(body.split("\n").size() + 1))
		cd.gutters_draw_line_numbers = false
		cd.highlight_current_line = true
		cd.text_changed.connect(func() -> void: body_text_changed.emit(model_id, cd.text))
		ed = cd
	else:
		var le: LineEdit = LineEdit.new()
		le.text = body
		le.flat = true
		le.add_theme_font_override("font", _font)
		le.add_theme_font_size_override("font_size", _font_size + 5)
		le.add_theme_color_override("font_color", UiStyle.TEXT_BRIGHT)
		le.custom_minimum_size = Vector2(ROW_W + 40.0, 0)
		le.text_changed.connect(func(t: String) -> void: body_text_changed.emit(model_id, t))
		le.text_submitted.connect(func(_t: String) -> void: _end_comment_edit())
		ed = le
	ed.focus_exited.connect(_end_comment_edit)
	_comment_edit = ed
	parent.add_child(ed)
	parent.move_child(ed, _comment_body.get_index())
	_comment_body.visible = false
	ed.grab_focus()
	if ed is LineEdit:
		(ed as LineEdit).caret_column = (ed as LineEdit).text.length()


## Widest a comment grows before its text wraps.
const COMMENT_MAX_W: float = 360.0
const COMMENT_MIN_W: float = 90.0


## Sizes the comment to its text: as wide as the longest line (up to
## COMMENT_MAX_W, then it wraps) and exactly as tall as the wrapped text
## needs, so the node never stays a tall, mostly empty column.
func _fit_comment_size() -> void:
	if _comment_body == null or not is_instance_valid(_comment_body):
		return
	var fs: int = _font_size + 5
	var widest: float = 0.0
	for ln: String in _comment_body.text.split("\n"):
		widest = maxf(widest, _font.get_string_size(ln, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
	var w: float = clampf(ceilf(widest) + 4.0, COMMENT_MIN_W, COMMENT_MAX_W)
	_comment_body.custom_minimum_size = Vector2(w, 0)
	var box: Control = _comment_body.get_parent() as Control
	if box != null:
		box.custom_minimum_size = Vector2(w, 0)
	# a GraphNode only grows on its own: drop the old size so it shrinks to fit
	if is_inside_tree():
		set_deferred("size", Vector2.ZERO)
	else:
		size = Vector2.ZERO


func _end_comment_edit() -> void:
	if _comment_edit == null:
		return
	var ed: Control = _comment_edit
	_comment_edit = null
	if _comment_body != null and is_instance_valid(_comment_body):
		_comment_body.visible = true
		_fit_comment_size()
	ed.queue_free()


## The most precise type text the model has for a pin (so Vector2i shows the
## Vector2i icon, a custom class its own icon): the pin's own `type_text`,
## else the declared type of the Argument / Variable node that owns the pin.
func _pin_type_text(n: Dictionary, pin: Dictionary) -> String:
	var own: String = String(pin.get("type_text", "")).strip_edges()
	if own != "":
		return own
	match int(n["kind"]):
		Model.Kind.ARGUMENT:
			return String(n["fields"].get("type", "")).strip_edges()
		Model.Kind.VAR_DECL:
			return String(n["fields"].get("raw_type", "")).strip_edges()
	return ""


## A native data-type icon control for a pin (tooltip names the type).
func _type_icon_rect(pin_type: int, type_text: String) -> TextureRect:
	var tr: TextureRect = TypeIcons.make_icon_rect(null)
	_set_type_icon(tr, pin_type, type_text)
	return tr


## Points an existing pin icon at the right native icon for the pin's type.
## No honest icon (outside the editor, unknown type): the slot stays empty.
func _set_type_icon(tr: TextureRect, pin_type: int, type_text: String) -> void:
	tr.texture = TypeIcons.icon_for_pin(pin_type, type_text)
	tr.set_meta("type_icon", TypeIcons.icon_name_for_pin(pin_type, type_text))
	var shown: String = type_text if type_text != "" else Types.type_name(pin_type)
	tr.tooltip_text = shown


func _titlebar_style(bg: Color) -> Types.ChamferStyle:
	var sb: Types.ChamferStyle = Types.ChamferStyle.new(bg, Color(0, 0, 0, 0))
	sb.border_width = 0.0
	sb.cut_bottom_left = false
	sb.cut_bottom_right = false
	sb.content_margin_left = 8.0
	sb.content_margin_right = 8.0
	sb.content_margin_top = 4.0
	sb.content_margin_bottom = 4.0
	return sb


# ---- Reference header decorations ---------------------------------------------
## Injects the reference header content into the node's built-in title bar:
## a kind icon at the left, and for Function Call nodes a notification bell
## at the right. The title bar is the GraphNode-internal HBox at child
## index 0 (title Label first) - decorations are appended around it.
func _apply_header_deco(kind: int, is_comment: bool) -> void:
	if is_comment:
		return
	var kids: Array = get_children(true)
	if kids.is_empty():
		return
	var thb: HBoxContainer = kids[0] as HBoxContainer
	if thb == null or thb.get_child_count() == 0 or not (thb.get_child(0) is Label):
		return
	var tlabel: Label = thb.get_child(0) as Label
	# the title text must reach the bell on the far right
	tlabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var icon: Texture2D = _kind_icon(kind)
	if icon != null:
		var tr: TextureRect = TextureRect.new()
		tr.texture = icon
		tr.custom_minimum_size = Vector2(16, 16)
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		tr.mouse_filter = Control.MOUSE_FILTER_PASS
		thb.add_child(tr)
		thb.move_child(tr, 0)
	if kind == Model.Kind.CALL or kind == Model.Kind.PRINT:
		var bell: Texture2D = _editor_icon("Notification")
		if bell != null:
			var tr2: TextureRect = TextureRect.new()
			tr2.texture = bell
			tr2.custom_minimum_size = Vector2(14, 14)
			tr2.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			tr2.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			tr2.mouse_filter = Control.MOUSE_FILTER_PASS
			thb.add_child(tr2)


## Kind icon for the header. Editor-provided icons are used when available;
## the drawn exec triangle covers event nodes (reference: white play arrow
## on the red header). Returns null when nothing is safe to show.
func _kind_icon(kind: int) -> Texture2D:
	match kind:
		Model.Kind.ENTRY:
			return Types.exec_icon()
		Model.Kind.CALL:
			return _editor_icon("MemberMethod")
		Model.Kind.PRINT:
			return _editor_icon("MemberMethod")
		Model.Kind.VAR_DECL, Model.Kind.VARIABLE_GET, Model.Kind.VARIABLE_SET:
			return _editor_icon("MemberProperty")
		Model.Kind.SIGNAL_DECL:
			return _editor_icon("MemberSignal")
		Model.Kind.PREAMBLE:
			return _editor_icon("Script")
		Model.Kind.CONST_DECL:
			return _editor_icon("Constant")
		_:
			return null


## An editor theme icon by name (null outside the editor or when missing).
func _editor_icon(icon_name: String) -> Texture2D:
	if not Engine.is_editor_hint():
		return null
	var t: Theme = EditorInterface.get_editor_theme()
	if t == null or not t.has_icon(icon_name, "EditorIcons"):
		return null
	return t.get_icon(icon_name, "EditorIcons")


## Annotation rows for a Variable or Function node: one editor per
## annotation (source order), each with annotation autocomplete and a remove
## action. New annotations are added by wiring an Annotation node into the
## declaration's "add annotation" input slot (no Add button anymore).
## Returns the number of rows added.
## Layout signature of a Variable node's accessor section: "" (nothing shown:
## Setter / Getter are their own nodes, created from the node menu like a
## function) or "raw" (one code box for a verbatim accessor block the node
## form cannot show exactly). The canvas rebuilds a view when this changes.
static func accessor_layout_of(n: Dictionary) -> String:
	if int(n["kind"]) != Model.Kind.VAR_DECL:
		return ""
	var f: Dictionary = n["fields"]
	if String(f.get("scope", "public")) == "private":
		return ""
	if String(f.get("acc_mode", "struct")) == "raw":
		return "raw"
	return ""


func accessor_layout_matches(n: Dictionary) -> bool:
	return _acc_layout_now(n) == _acc_layout


## Layout signature of this view's accessor section: "" (nothing) or "raw"
## (a verbatim accessor block shown as code).
func _acc_layout_now(n: Dictionary) -> String:
	if int(n["kind"]) != Model.Kind.VAR_DECL:
		return ""
	var f: Dictionary = n["fields"]
	if String(f.get("scope", "public")) == "private":
		return ""
	var mode: String = String(f.get("acc_mode", "struct"))
	if mode == "other" or mode == "nodes":
		return ""
	if String(f.get("tail", "")).strip_edges() != "":
		return "raw"
	return ""


## Property accessors on a member Variable node. A Setter and a Getter are
## their own function-like nodes (created from the node menu like a Function,
## bodies built from nodes, no code typing), so the Variable node shows no
## accessor controls at all. Only a verbatim accessor block the node form
## cannot represent (comments, one-line bodies) is shown as one code box and
## kept exactly as written.
func _accessor_rows(n: Dictionary) -> int:
	_acc_edits = {}
	_acc_layout = _acc_layout_now(n)
	if _acc_layout != "raw":
		return 0
	var f: Dictionary = n["fields"]
	var rcd: CodeEdit = _accessor_code("tail", String(f.get("tail", "")),
		"Property accessors (set / get). Shown as code because the block has comments or one-line bodies; it is kept exactly as written.")
	add_child(_form_row("Accessors", Control.new()))
	add_child(rcd)
	return 2


## A small multi-line GDScript editor bound to one accessor field.
func _accessor_code(key: String, initial: String, tip: String) -> CodeEdit:
	var cd: CodeEdit = CodeEdit.new()
	cd.text = initial
	cd.tooltip_text = tip
	cd.add_theme_font_override("font", _font)
	cd.add_theme_font_size_override("font_size", _font_size)
	cd.add_theme_stylebox_override("normal", _field_box(false))
	cd.add_theme_stylebox_override("focus", _field_box(true))
	cd.custom_minimum_size = Vector2(ROW_W + 40.0, 24.0 * (initial.split("\n").size() + 1))
	cd.gutters_draw_line_numbers = false
	cd.highlight_current_line = true
	cd.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	cd.scroll_fit_content_height = true
	cd.scroll_fit_content_width = false
	cd.indent_use_spaces = false
	cd.indent_automatic = true
	var old: Array[String] = [initial]
	cd.focus_entered.connect(func() -> void:
		old[0] = cd.text
		field_edit_started.emit(model_id, key))
	cd.text_changed.connect(func() -> void: field_changed.emit(model_id, key, cd.text))
	cd.focus_exited.connect(func() -> void: field_committed.emit(model_id, key, old[0]))
	_acc_edits[key] = cd
	return cd


## Keeps the accessor editors in step with the model (undo / redo, renames)
## without touching one that is being typed in.
func _sync_accessor_editors(n: Dictionary) -> void:
	if _acc_edits.is_empty():
		return
	var f: Dictionary = n["fields"]
	for key: String in _acc_edits:
		var ctl: Variant = _acc_edits[key]
		if not (ctl is Control) or not is_instance_valid(ctl):
			continue
		if ctl is CheckBox:
			(ctl as CheckBox).set_pressed_no_signal(bool(f.get(key, false)))
			continue
		var field_key: String = key
		if key == "setter" or key == "getter":
			field_key = key + "_body"
		var want: String = String(f.get(field_key, ""))
		if ctl is TextEdit:
			var te: TextEdit = ctl as TextEdit
			if not te.has_focus() and te.text != want:
				te.text = want
		elif ctl is LineEdit:
			var le: LineEdit = ctl as LineEdit
			if not le.has_focus() and le.text != want:
				le.text = want


func _annotations_rows(n: Dictionary, target: String, allow_add: bool = true) -> int:
	var rows: int = 0
	var joined: String = String(n["fields"].get("annotations", ""))
	var anns: PackedStringArray = joined.split("\n") if joined != "" else PackedStringArray()
	_ann_edits = []
	# Annotations already represented by a connected Annotation node do not
	# get a second (plain-text) row: the node itself shows the name, argument
	# pins and the visible wire.
	var registered: Dictionary = {}
	if model_ref != null:
		for l: Dictionary in model_ref.ann_links:
			if int(l["tid"]) == model_id and model_ref.nodes.has(int(l["aid"])):
				registered[str(model_ref.nodes[int(l["aid"])]["fields"].get("name", ""))] = true
	for i: int in anns.size():
		var aname: String = _annotation_name_of_line(String(anns[i]))
		if registered.has(aname):
			continue
		var row: HBoxContainer = HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		row.custom_minimum_size = Vector2(ROW_W, 0)
		var ed: LineEdit = LineEdit.new()
		ed.text = anns[i]
		ed.custom_minimum_size = Vector2(110, 0)
		ed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ed.add_theme_font_override("font", _font)
		ed.add_theme_font_size_override("font_size", _font_size)
		var idx: int = i
		ed.text_changed.connect(func(t: String) -> void:
			annotation_action.emit(model_id, "set", idx, t))
		_wire_commit(ed, "annotations")
		# Committing a row converts it into a real Annotation node (with its
		# own argument pins and wire); unrepresentable text keeps the row.
		var commit_row: Callable = func() -> void:
			annotation_action.emit(model_id, "commit", idx, "")
		ed.text_submitted.connect(commit_row)
		ed.focus_exited.connect(commit_row)
		_attach_annotation_suggest(ed, [target])
		row.add_child(ed)
		var rm: Button = Button.new()
		rm.text = "\u2715"
		rm.tooltip_text = "Remove annotation"
		rm.flat = true
		rm.add_theme_font_size_override("font_size", 10)
		rm.focus_mode = Control.FOCUS_NONE
		rm.pressed.connect(func() -> void:
			annotation_action.emit(model_id, "remove", idx, ""))
		row.add_child(rm)
		ed.tooltip_text = _annotation_hint(anns[i], target)
		add_child(row)
		_ann_edits.append(ed)
		rows += 1
	# The "+ Annotation" control opens the node menu pre-filtered to
	# annotations valid for this declaration's target; spawning one wires
	# it into the "add annotation" slot and registers it automatically.
	# Private (function-local) variables cannot carry annotations: no control.
	# (The visible "+ Annotation" button was removed on request: annotations
	# are added from the node menu or by dragging from the "add annotation"
	# pin, which opens the same pre-filtered list.)
	return rows


## The header body's annotation lines (ordered), for the read-only rows.
func _annotation_lines_of_preamble(n: Dictionary) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for ln: String in String(n["body"]).split("\n"):
		if ln.strip_edges().begins_with("@"):
			out.append(ln.strip_edges())
	return out


## Readable enum text: `enum Name { A, B = 2 }` on one line becomes a header
## line plus one member per line. Anything else (already multi-line, comments,
## unusual shapes) is returned unchanged.
func _pretty_enum(body: String) -> String:
	var t: String = body.strip_edges()
	if not t.begins_with("enum") or t.contains("\n") or t.contains("#"):
		return body
	var o: int = t.find("{")
	var c: int = t.rfind("}")
	if o < 0 or c < o or t.substr(c + 1).strip_edges() != "":
		return body
	var head: String = t.substr(0, o).strip_edges()
	var inner: String = t.substr(o + 1, c - o - 1)
	var items: PackedStringArray = PackedStringArray()
	var depth: int = 0
	var quote: String = ""
	var cur: String = ""
	for i: int in inner.length():
		var ch: String = inner[i]
		if quote != "":
			if ch == quote:
				quote = ""
		elif ch == "\"" or ch == "'":
			quote = ch
		elif ch == "(" or ch == "[" or ch == "{":
			depth += 1
		elif ch == ")" or ch == "]" or ch == "}":
			depth -= 1
		elif ch == "," and depth == 0:
			items.append(cur.strip_edges())
			cur = ""
			continue
		cur += ch
	items.append(cur.strip_edges())
	var lines: PackedStringArray = PackedStringArray([head + " {"])
	for it: String in items:
		if it != "":
			lines.append("\t" + it + ",")
	lines.append("}")
	return "\n".join(lines)


## The shared "+ Annotation" affordance (Variables, Functions, Script Header).
func _annotation_add_button() -> Button:
	var b: Button = Button.new()
	b.text = "+ Annotation"
	b.tooltip_text = "Add an annotation node and connect it here"
	b.flat = true
	b.add_theme_font_size_override("font_size", 11)
	b.add_theme_color_override("font_color", UiStyle.TEXT_DIM)
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(func() -> void:
		annotation_action.emit(model_id, "menu", -1, ""))
	return b


## The annotation name (without @ and arguments) a stored line carries.
func _annotation_name_of_line(line: String) -> String:
	var st: String = line.strip_edges()
	if not st.begins_with("@"):
		return ""
	return st.trim_prefix("@").split("(")[0].strip_edges()


## Validation/hint text for an annotation row (registry message or the
## expected argument signature).
func _annotation_hint(text: String, target: String) -> String:
	var reg: RefCounted = AnnReg.get_registry()
	var msg: String = reg.validate(text, target)
	if msg != "":
		return msg
	var name: String = text.strip_edges().trim_prefix("@").split("(")[0].strip_edges()
	var sig: String = reg.signature(name)
	var brief: String = reg.brief(name)
	return brief + ("" if sig == "" else "\n" + name + sig)


## Shared annotation autocomplete: suggestions come from the annotation
## registry, filtered by the placement targets of the field; picking inserts
## a full template with default arguments.
func _attach_annotation_suggest(ed: LineEdit, targets: Array[String]) -> void:
	var reg: RefCounted = AnnReg.get_registry()
	var sg: TypeSuggest = TypeSuggest.new()
	sg.attach(ed, func(q: String) -> Array:
		var out: Array = []
		for e: Dictionary in reg.search(q, 40, targets):
			var tpl: String = reg.template(str(e["name"]))
			if tpl != "":
				out.append(tpl)
		return out)


func _body_row(n: Dictionary) -> Control:
	var kind: int = int(n["kind"])
	var body: String = String(n["body"])
	var stmt: Dictionary = n["stmt"]
	if kind == Model.Kind.PREAMBLE:
		# The script header is metadata-only: `class_name` / `extends` are
		# configured through their dedicated Script Class Name / Script
		# Extension nodes, annotations through Annotation nodes wired to the
		# header's per-annotation pins. No generic text fields here - only
		# annotations that cannot be represented as nodes stay as read-only
		# rows (with a remove action) so nothing in the script is invisible.
		var vbox: VBoxContainer = VBoxContainer.new()
		vbox.add_theme_constant_override("separation", 4)
		vbox.custom_minimum_size = Vector2(ROW_W - 12.0, 0)
		_header_edits = []
		var registered: Dictionary = {}
		if model_ref != null:
			for l: Dictionary in model_ref.ann_links:
				if int(l["tid"]) == model_id and model_ref.nodes.has(int(l["aid"])):
					registered[str(model_ref.nodes[int(l["aid"])]["fields"].get("name", ""))] = true
		for ai: int in _annotation_lines_of_preamble(n).size():
			var atext: String = _annotation_lines_of_preamble(n)[ai]
			var aname: String = _annotation_name_of_line(atext)
			if registered.has(aname):
				continue   # represented by its connected Annotation node
			var rrow: HBoxContainer = HBoxContainer.new()
			rrow.add_theme_constant_override("separation", 6)
			var rlab: Label = Label.new()
			rlab.text = atext
			rlab.add_theme_font_override("font", _font)
			rlab.add_theme_font_size_override("font_size", _font_size)
			rlab.add_theme_color_override("font_color", UiStyle.TEXT_DIM)
			rlab.tooltip_text = "Not representable as an Annotation node; shown verbatim. Spawning a matching Annotation node replaces this row."
			rlab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			rrow.add_child(rlab)
			var rm2: Button = Button.new()
			rm2.text = "\u2715"
			rm2.tooltip_text = "Remove annotation"
			rm2.flat = true
			rm2.add_theme_font_size_override("font_size", 10)
			rm2.focus_mode = Control.FOCUS_NONE
			var ridx: int = ai
			rm2.pressed.connect(func() -> void:
				annotation_action.emit(model_id, "remove", ridx, ""))
			rrow.add_child(rm2)
			vbox.add_child(rrow)
		# NOTE: the old "+ Add Directive" button stays removed (it was a
		# useless affordance). Script-level annotations are added through the
		# dedicated "+ Annotation" control below: it opens the node menu
		# pre-filtered to class-level annotations and the spawned Annotation
		# node wires into the header's "add annotation" slot automatically.
		return vbox
	if _comment_look(kind, body):
		# Comment look (real comments and verbatim declaration blocks made
		# only of comment lines): a "# Title" header row and the comment
		# text below as plain large text - no embedded editor box, no
		# scrollbar. Double-click the text to edit it in place.
		return _comment_display(n)
	if stmt.is_empty() and (EDITABLE_BODY_KINDS.has(kind) and kind != Model.Kind.PRINT \
			or kind == Model.Kind.DECLARATION):
		if kind == Model.Kind.DECLARATION:
			# Enums that parse cleanly get a member form (add / rename /
			# reorder / remove rows, no syntax to type); anything the form
			# cannot show faithfully (comments, odd shapes) keeps the code view.
			if bool(CollText.parse_enum(body)["ok"]):
				return _make_enum_form(body)
			# Verbatim declarations (enum, inner class, custom block) are
			# multi-line: edit them in a small code editor on the node.
			var cd: CodeEdit = CodeEdit.new()
			# Enums are shown one member per line (display only: the stored
			# body stays as parsed until the user edits it, and a multi-line
			# enum is equally valid GDScript).
			var shown: String = _pretty_enum(body)
			cd.text = shown
			cd.add_theme_font_override("font", _font)
			cd.add_theme_font_size_override("font_size", _font_size)
			cd.custom_minimum_size = Vector2(ROW_W + 40.0, 24.0 * (shown.split("\n").size() + 1))
			cd.gutters_draw_line_numbers = false
			cd.highlight_current_line = true
			cd.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
			cd.scroll_fit_content_height = true
			cd.scroll_fit_content_width = false
			cd.text_changed.connect(func() -> void: body_text_changed.emit(model_id, cd.text))
			return cd
		var ed: LineEdit = LineEdit.new()
		ed.text = body
		ed.add_theme_font_override("font", _font)
		ed.add_theme_font_size_override("font_size", _font_size)
		ed.custom_minimum_size = Vector2(ROW_W - 12.0, 0)
		ed.text_changed.connect(func(t: String) -> void: body_text_changed.emit(model_id, t))
		if body.strip_edges().begins_with("@"):
			_attach_annotation_suggest(ed, ["statement"])
		return ed
	return _body_label(body, kind)


## "dict" / "array" for the pin types that get a form editor, "" otherwise.
static func _coll_kind_of(pin_type: int) -> String:
	if pin_type == Types.PinType.DICTIONARY:
		return "dict"
	if pin_type == Types.PinType.ARRAY:
		return "array"
	return ""


## True when the Value editor of a variable node already fits its data type
## (the entry form for Dictionary, the item form for Array, the plain / typed
## box otherwise).
func dict_editor_matches(n: Dictionary) -> bool:
	if (n["data_ins"] as Array).is_empty():
		return true
	var want: String = _coll_kind_of(int(n["data_ins"][0]["type"]))
	var have: String = ""
	if _pin_editors.has(0) and is_instance_valid(_pin_editors[0]) \
			and (_pin_editors[0] as Control).has_meta("coll_sync"):
		have = String((_pin_editors[0] as Control).get_meta("coll_kind", "dict"))
	return want == have


func _make_enum_form(body: String) -> Control:
	var f: CollEd.EnumForm = CollEd.EnumForm.new()
	f.setup(body, _font, _font_size,
		func(b: String) -> void: body_text_changed.emit(model_id, b))
	f.custom_minimum_size = Vector2(ROW_W + 40.0, 0)
	_enum_form = f
	return f


## The Dictionary entry form or the Array item form for a pin of `pin_type`.
func _make_coll_form(pin_type: int, text: String, change_cb: Callable) -> Control:
	if pin_type == Types.PinType.ARRAY:
		var af: CollEd.ArrayForm = CollEd.ArrayForm.new()
		af.setup(text, _font, _font_size, change_cb)
		af.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		af.set_meta("coll_sync", Callable(af, "sync_external"))
		af.set_meta("coll_kind", "array")
		return af
	return _make_dict_form(text, change_cb)


## The dictionary entry form: every edit reports the regenerated literal.
func _make_dict_form(text: String, change_cb: Callable) -> Control:
	var f: CollEd.DictForm = CollEd.DictForm.new()
	f.setup(text, _font, _font_size, change_cb)
	f.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	f.set_meta("coll_sync", Callable(f, "sync_external"))
	f.set_meta("coll_kind", "dict")
	return f


func _body_label(body: String, kind: int = -1) -> Label:
	var lab: Label = Label.new()
	lab.text = body if body != "" else " "
	lab.add_theme_font_override("font", _font)
	if _comment_look(kind, body):
		# reference comment look: larger light text, no box
		lab.add_theme_font_size_override("font_size", _font_size + 5)
		lab.add_theme_color_override("font_color", UiStyle.TEXT_BRIGHT)
		lab.custom_minimum_size = Vector2(ROW_W + 40.0, 0)
	else:
		lab.add_theme_font_size_override("font_size", _font_size)
		lab.add_theme_color_override("font_color", UiStyle.TEXT_DIM)
		lab.clip_text = true
		lab.custom_minimum_size = Vector2(ROW_W - 12.0, 0)
	return lab


func _spacer() -> Control:
	var c: Control = Control.new()
	c.custom_minimum_size = Vector2(ROW_W, ROW_H - 12.0)
	return c


# ---- Port <-> pin mapping ------------------------------------------------------
## Definition of input port `port` (GraphEdit reports ports, not child slots).
func in_def(port: int) -> Dictionary:
	return _in_defs[port] if port >= 0 and port < _in_defs.size() else {}


func out_def(port: int) -> Dictionary:
	return _out_defs[port] if port >= 0 and port < _out_defs.size() else {}


## GraphEdit output port that carries model exec output pin `model_index`.
func exec_out_port(model_index: int) -> int:
	for p: int in _out_defs.size():
		if _out_defs[p]["kind"] == "exec" and int(_out_defs[p]["index"]) == model_index:
			return p
	return -1


## GraphEdit output port that carries model data output pin `model_index`.
func data_out_port(model_index: int) -> int:
	for p: int in _out_defs.size():
		if _out_defs[p]["kind"] == "data" and int(_out_defs[p]["index"]) == model_index:
			return p
	return -1


## GraphEdit input port that carries model exec input pin `model_index`.
func exec_in_port(model_index: int = 0) -> int:
	for p: int in _in_defs.size():
		if _in_defs[p]["kind"] == "exec" and int(_in_defs[p]["index"]) == model_index:
			return p
	return -1


## GraphEdit input port that carries model data input pin `model_index`.
func data_in_port(model_index: int) -> int:
	for p: int in _in_defs.size():
		if _in_defs[p]["kind"] == "data" and int(_in_defs[p]["index"]) == model_index:
			return p
	return -1


# ---- Blueprint-style diagnostics (errors / warnings) ---------------------------
## Pure display layer: marks this node with a header badge, a coloured outline
## and a one-line message row. The model, the generated code and the node's own
## fields are never touched. Errors: red circle badge + thick red outline;
## warnings: amber triangle badge + thinner amber outline. Hovering the badge or
## the message row shows the full text of every problem on this node.
var _diag_sig: String = ""
## out_def "index" of a diagnostic pin: far outside any model pin index, so the
## model-pin loops (refresh, port lookups) can never mistake it for a data pin.
const DIAG_PIN_INDEX: int = 100000
var _diag_badge: Control = null
var _diag_row: Control = null
var _diag_row2: Control = null   # second message row, only when a node has errors AND warnings
var _diag_pin_rows: Array[int] = []   # slot (child) index of each auto-created diagnostic pin
var _diag_panel: StyleBox = null
var _diag_panel_sel: StyleBox = null


## items: [{severity: "error"|"warning", message: String, line: int}] - an empty
## array clears every indicator.
func set_diagnostics(items: Array) -> void:
	var sig: String = JSON.stringify(items)
	if sig == _diag_sig:
		return
	_diag_sig = sig
	_remove_diag_widgets()
	if items.is_empty():
		return
	var errors: Array = []
	var warnings: Array = []
	for v: Variant in items:
		if str((v as Dictionary).get("severity", "error")) == "error":
			errors.append(v)
		else:
			warnings.append(v)
	var has_error: bool = not errors.is_empty()
	var color: Color = Types.ERROR_COLOR if has_error else Types.WARNING_COLOR
	var full: String = diagnostics_text(items)
	_apply_diag_styles(color, has_error)
	var thb: HBoxContainer = get_titlebar_hbox()
	if thb != null:
		var badge: DiagBadge = DiagBadge.new()
		badge.setup(has_error, color, full)
		thb.add_child(badge)
		_diag_badge = badge
	# One message row per severity present, each with its own output pin
	# ("error" first, then "warning"): the pin is what the canvas wires to the
	# Error / Warning node. A node with only warnings gets only the warning pin.
	var groups: Array[Dictionary] = []
	if has_error:
		groups.append({"sev": "error", "items": errors})
	if not warnings.is_empty():
		groups.append({"sev": "warning", "items": warnings})
	for gi: int in groups.size():
		var g: Dictionary = groups[gi]
		var is_err: bool = str(g["sev"]) == "error"
		var gcolor: Color = Types.ERROR_COLOR if is_err else Types.WARNING_COLOR
		var gitems: Array = g["items"] as Array
		var row: Control = _make_diag_row(gitems, gcolor, is_err, diagnostics_text(gitems))
		if gi > 0:
			row.name = "DiagRowWarn"
		add_child(row)
		if gi == 0:
			_diag_row = row
		else:
			_diag_row2 = row
		var slot: int = _control_child_count() - 1
		set_slot(slot, false, Types.VARIANT, Color.WHITE, true, Types.VARIANT, gcolor, null, null)
		_diag_pin_rows.append(slot)
		_out_defs.append({"kind": "diag", "index": DIAG_PIN_INDEX, "row": slot,
			"severity": str(g["sev"])})
	call_deferred("_fit_height")


## GraphEdit output port of this node's "error" / "warning" pin, -1 when the
## node currently has no problem of that severity.
func diag_out_port(severity: String) -> int:
	for p: int in _out_defs.size():
		if _out_defs[p]["kind"] == "diag" and str(_out_defs[p].get("severity", "")) == severity:
			return p
	return -1


## Number of child controls that take part in GraphNode's slot numbering.
func _control_child_count() -> int:
	var cnt: int = 0
	for c: Node in get_children():
		if c is Control and not (c as Control).top_level:
			cnt += 1
	return cnt


## True while any error / warning indicator is shown on this node.
func has_diagnostics() -> bool:
	return _diag_row != null and is_instance_valid(_diag_row)


## The full multi-line message shown in the hover tooltips.
func diagnostics_text(items: Array) -> String:
	var lines: PackedStringArray = PackedStringArray()
	for v: Variant in items:
		var d: Dictionary = v as Dictionary
		var tag: String = "Error" if str(d.get("severity", "error")) == "error" else "Warning"
		var ln: int = int(d.get("line", -1))
		var where: String = " (generated line %d)" % ln if ln > 0 else ""
		lines.append("%s%s: %s" % [tag, where, str(d.get("message", ""))])
	return "\n".join(lines)


func _make_diag_row(items: Array, color: Color, is_error: bool, full: String) -> Control:
	# Just the word "Error" / "Warning" (with a count when there are several),
	# right-aligned next to the node's error / warning pin. The messages
	# themselves live on the Error / Warning node and in this row's tooltip.
	var row: HBoxContainer = HBoxContainer.new()
	row.name = "DiagRow"
	row.custom_minimum_size = Vector2(ROW_W, 0)
	row.tooltip_text = full
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	var text: String = "Error" if is_error else "Warning"
	if items.size() > 1:
		text += " (%d)" % items.size()
	var lbl: Label = Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", _font_size)
	lbl.add_theme_color_override("font_color", color.lightened(0.35))
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	lbl.tooltip_text = full
	row.add_child(lbl)
	return row


## Outline + slight tint on the node body. The selected look keeps its orange
## selection outline (so selection stays visible) but gets the same tint.
func _apply_diag_styles(color: Color, is_error: bool) -> void:
	var cur: Types.ChamferStyle = get_theme_stylebox("panel") as Types.ChamferStyle
	if cur != null:
		_diag_panel = cur
		add_theme_stylebox_override("panel",
			_diag_style(cur, color, 3.0 if is_error else 2.0, color))
	var cur_sel: Types.ChamferStyle = get_theme_stylebox("panel_selected") as Types.ChamferStyle
	if cur_sel != null:
		_diag_panel_sel = cur_sel
		add_theme_stylebox_override("panel_selected",
			_diag_style(cur_sel, cur_sel.border_color, cur_sel.border_width, color))


func _diag_style(src: Types.ChamferStyle, border: Color, width: float, tint: Color) -> Types.ChamferStyle:
	var st: Types.ChamferStyle = Types.ChamferStyle.new(src.bg_color.lerp(tint, 0.14), border)
	st.border_width = width
	st.chamfer = src.chamfer
	st.cut_top_left = src.cut_top_left
	st.cut_top_right = src.cut_top_right
	st.cut_bottom_left = src.cut_bottom_left
	st.cut_bottom_right = src.cut_bottom_right
	st.border_top = src.border_top
	st.border_bottom = src.border_bottom
	st.content_margin_left = src.content_margin_left
	st.content_margin_right = src.content_margin_right
	st.content_margin_top = src.content_margin_top
	st.content_margin_bottom = src.content_margin_bottom
	return st


func _remove_diag_widgets() -> void:
	var had_row: bool = false
	# drop the auto-created error / warning pins together with their rows
	for slot: int in _diag_pin_rows:
		clear_slot(slot)
	_diag_pin_rows.clear()
	var kept_outs: Array = []
	for od: Variant in _out_defs:
		if (od as Dictionary)["kind"] != "diag":
			kept_outs.append(od)
	_out_defs = kept_outs
	if _diag_row2 != null and is_instance_valid(_diag_row2):
		had_row = true
		if _diag_row2.get_parent() != null:
			_diag_row2.get_parent().remove_child(_diag_row2)
		_diag_row2.queue_free()
	_diag_row2 = null
	if _diag_badge != null and is_instance_valid(_diag_badge):
		if _diag_badge.get_parent() != null:
			_diag_badge.get_parent().remove_child(_diag_badge)
		_diag_badge.queue_free()
	_diag_badge = null
	if _diag_row != null and is_instance_valid(_diag_row):
		had_row = true
		if _diag_row.get_parent() != null:
			_diag_row.get_parent().remove_child(_diag_row)
		_diag_row.queue_free()
	_diag_row = null
	if _diag_panel != null:
		add_theme_stylebox_override("panel", _diag_panel)
		_diag_panel = null
	if _diag_panel_sel != null:
		add_theme_stylebox_override("panel_selected", _diag_panel_sel)
		_diag_panel_sel = null
	if had_row:
		call_deferred("_shrink_after_diag")


func _fit_height() -> void:
	if is_inside_tree():
		size = Vector2(size.x, 0.0)


## The message row made the node taller; let it fall back to its natural height.
func _shrink_after_diag() -> void:
	if is_inside_tree() and not has_diagnostics():
		size = Vector2(size.x, 0.0)


## Small status badge drawn in the node header: red circle with a cross for
## errors, amber triangle with an exclamation mark for warnings.
class DiagBadge extends Control:
	var is_error: bool = true
	var color: Color = Color.RED

	func setup(error: bool, badge_color: Color, tip: String) -> void:
		name = "DiagBadge"
		is_error = error
		color = badge_color
		tooltip_text = tip
		custom_minimum_size = Vector2(20.0, 20.0)
		size_flags_vertical = Control.SIZE_SHRINK_CENTER
		mouse_filter = Control.MOUSE_FILTER_PASS

	func _draw() -> void:
		var c: Vector2 = size * 0.5
		if is_error:
			draw_circle(c, 8.0, color)
			draw_line(c + Vector2(-3.0, -3.0), c + Vector2(3.0, 3.0), Color.WHITE, 2.0, true)
			draw_line(c + Vector2(-3.0, 3.0), c + Vector2(3.0, -3.0), Color.WHITE, 2.0, true)
		else:
			var tri: PackedVector2Array = PackedVector2Array([
				c + Vector2(0.0, -8.0), c + Vector2(8.5, 7.0), c + Vector2(-8.5, 7.0)])
			draw_colored_polygon(tri, color)
			var ink: Color = Color(0.1, 0.07, 0.0)
			draw_line(c + Vector2(0.0, -3.0), c + Vector2(0.0, 2.0), ink, 2.0, true)
			draw_circle(c + Vector2(0.0, 5.0), 1.2, ink)


## Editable type input with a dropdown of common GDScript types.
class TypeSelect extends HBoxContainer:
	signal type_changed(text: String)
	signal type_edit_started()
	signal type_committed(old_text: String)

	var edit: LineEdit
	var suggest: TypeSuggest = null
	# Last committed value: updated on focus entry and after a pick; the
	# model only ever follows text that differs from this baseline.
	var committed_text: String = ""

	func _init(initial: String = "") -> void:
		edit = LineEdit.new()
		edit.text = initial
		edit.custom_minimum_size = Vector2(96, 24)
		edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		edit.placeholder_text = "untyped"
		add_child(edit)
		# Native icon of the typed text at the field's right edge. Purely
		# visual: only a text that names a known type shows an icon.
		_refresh_icon()
		# (re-checked on every redraw too, so programmatic text updates from
		# model refreshes keep the icon in sync; it only reassigns on change)
		edit.text_changed.connect(func(_t: String) -> void: _refresh_icon())
		edit.draw.connect(_refresh_icon)
		var menu_btn: Button = Button.new()
		menu_btn.text = "\u25be"
		menu_btn.tooltip_text = "Suggest types"
		menu_btn.focus_mode = Control.FOCUS_NONE
		UiStyle.style_icon_button(menu_btn)
		menu_btn.add_theme_font_size_override("font_size", 11)
		add_child(menu_btn)
		# The ▾ button opens the reference's categorized type picker panel.
		# (A MenuButton would ALSO pop its own (empty) PopupMenu next to the
		# list - two overlapping dropdowns from one click - so the plain
		# button is the correct control here; typed queries still use the
		# inline suggestion popup via the LineEdit.)
		menu_btn.pressed.connect(func() -> void:
			if picker == null:
				picker = TypePicker.new()
				_picker_host(picker)
				picker.type_picked.connect(_on_suggest_picked)
			if picker.visible:
				picker.hide()
				return
			_picker_anchor(menu_btn)
			picker.show())
	var picker: Control = null

	## Hosts the picker panel on the canvas menu layer (or a dedicated
	## layer of this node's window) - same mechanism as the type-suggest
	## popup, so it always renders above the graph.
	func _picker_host(p: Control) -> void:
		var host: CanvasLayer = null
		var n: Node = self
		while n != null:
			if "_menu_layer" in n and n._menu_layer != null:
				host = n._menu_layer
				break
			n = n.get_parent()
		if host == null:
			host = CanvasLayer.new()
			host.layer = 10
			get_viewport().add_child.call_deferred(host)
			# The dedicated host must not outlive the picker it was made for:
			# when the picker leaves the tree its layer goes with it.
			p.tree_exited.connect(host.queue_free)
		host.add_child.call_deferred(p)

	## Positions the panel under the ▾ button, clamped into the viewport
	## (the minimum size is used - the panel may not be laid out yet).
	func _picker_anchor(btn: Control) -> void:
		var vp: Viewport = get_viewport()
		var sz: Vector2 = picker.get_combined_minimum_size()
		var p: Vector2 = btn.get_global_position() + Vector2(-4.0, btn.size.y + 2.0)
		var vp_sz: Vector2 = vp.get_visible_rect().size
		p.x = clampf(p.x, 0.0, maxf(0.0, vp_sz.x - sz.x - 8.0))
		p.y = clampf(p.y, 0.0, maxf(0.0, vp_sz.y - sz.y - 8.0))
		picker.position = p
		# Deliberately NOT connected to edit.text_changed: the model (and the
		# pin type tag) must only follow COMMITTED text. Updating on every
		# keystroke restyled the pin with the intermediate text ("St" ->
		# unknown name -> obj tag) and let partial names leak into the model.
		# The commit points are wired in _ready().

	func _ready() -> void:
		# The shared autocomplete (search across every discovered type source)
		# is attached once; the LineEdit keeps focus and its caret while the
		# suggestion popup updates.
		suggest = TypeSuggest.new()
		suggest.type_icons = true
		suggest.attach(edit, _suggest_types)
		suggest.picked.connect(_on_suggest_picked)
		committed_text = edit.text
		edit.focus_entered.connect(func() -> void:
			committed_text = edit.text
			type_edit_started.emit())
		edit.text_submitted.connect(func(_t: String) -> void:
			_commit_from_field())
		edit.focus_exited.connect(_commit_from_field)

	func _refresh_icon() -> void:
		var ic: Texture2D = TypeIcons.icon_for_type(edit.text)
		if edit.right_icon != ic:
			edit.right_icon = ic

	## Emits the commit pair for the field's current text. Only a real change
	## against the committed baseline reaches the model.
	func _commit_from_field() -> void:
		if edit.text != committed_text:
			type_changed.emit(edit.text)
		type_committed.emit(committed_text)

	func _suggest_types(query: String) -> Array:
		var reg: RefCounted = TypeReg.get_registry()
		var names: Array = []
		if query.strip_edges() == "":
			for t: String in COMMON_TYPES:
				names.append(t)
			return names
		for e: Dictionary in reg.search(query, 40):
			names.append(str(e["name"]))
		return names

	func _on_suggest_picked(t: String) -> void:
		type_edit_started.emit()
		var pre: String = edit.text
		# the suggest already placed the text and moved the caret to its end;
		# re-assigning the same text would reset the caret to 0 (set_text),
		# so only assign when it actually differs
		if pre != t:
			edit.text = t
		if t != committed_text:
			type_changed.emit(t)
			committed_text = t
		type_committed.emit(committed_text)
