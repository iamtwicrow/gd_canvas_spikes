@tool
extends RefCounted
## Form editors for enums, dictionaries and arrays: add, rename, reorder and remove
## rows with buttons instead of typing GDScript. Both forms keep their own
## row state and report every change as finished source text through
## `on_change`, so the host node only has to store that text.

const UiStyle = preload("ui_style.gd")

class Base extends VBoxContainer:
	const ERR_COLOR: Color = Color("#ff6b6b")
	const WARN_COLOR: Color = Color("#e6b84d")


	static func _small_button(label: String, tip: String) -> Button:
		var b: Button = Button.new()
		b.text = label
		b.tooltip_text = tip
		b.flat = true
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 11)
		b.custom_minimum_size = Vector2(22, 22)
		return b


	static func _style_field(le: LineEdit, font: Font, font_size: int) -> void:
		le.add_theme_font_override("font", font)
		le.add_theme_font_size_override("font_size", font_size)
		UiStyle.style_line_edit(le)


	static func _mark(le: Control, ok: bool) -> void:
		if le is LineEdit:
			(le as LineEdit).add_theme_color_override("font_color", UiStyle.TEXT if ok else ERR_COLOR)

	## Set while rows are being rebuilt: stale focus_exited commits are ignored.
	var _rebuilding: bool = false

	func _end_rebuild() -> void:
		_rebuilding = false


	## True while the user is typing in one of this form's fields: outside
	## text is never pushed over a field that has the caret.
	func _has_focus_inside() -> bool:
		if not is_inside_tree():
			return false
		var vp: Viewport = get_viewport()
		if vp == null:
			return false
		var fo: Control = vp.gui_get_focus_owner()
		return fo != null and is_ancestor_of(fo)


# =============================================================================
# Enum form
# =============================================================================
class EnumForm extends Base:
	const T = preload("collection_text.gd")
	const Ui = preload("ui_style.gd")

	var enum_name: String = ""
	var members: Array = []
	var on_change: Callable = Callable()
	var _font: Font
	var _fs: int = 13
	var _last_body: String = ""
	var _rows: VBoxContainer
	var _name_edit: LineEdit
	var _warn: Label
	var _index_labels: Array[Label] = []
	var _name_edits: Array[LineEdit] = []
	var _value_edits: Array[LineEdit] = []


	## `body` must already parse (T.parse_enum(body).ok).
	func setup(body: String, font: Font, font_size: int, change_cb: Callable) -> void:
		_font = font
		_fs = font_size
		on_change = change_cb
		_load(body)
		_build()


	func _load(body: String) -> void:
		var info: Dictionary = T.parse_enum(body)
		enum_name = String(info["name"])
		members = (info["members"] as Array).duplicate(true)
		_last_body = T.build_enum(enum_name, members)


	## Called when the model's text changed from outside (undo, reload).
	func sync_external(body: String) -> void:
		if body.strip_edges() == _last_body.strip_edges() or _has_focus_inside():
			return
		var info: Dictionary = T.parse_enum(body)
		if not bool(info["ok"]):
			return
		_load(body)
		_build()


	func _build() -> void:
		_rebuilding = true
		for c: Node in get_children():
			remove_child(c)
			c.queue_free()
		_index_labels.clear()
		_name_edits.clear()
		_value_edits.clear()
		add_theme_constant_override("separation", 4)

		var head: HBoxContainer = HBoxContainer.new()
		head.add_theme_constant_override("separation", 6)
		var hl: Label = Label.new()
		hl.text = "Enum name"
		hl.add_theme_font_size_override("font_size", 12)
		hl.add_theme_color_override("font_color", Ui.TEXT_DIM)
		head.add_child(hl)
		_name_edit = LineEdit.new()
		_name_edit.text = enum_name
		_name_edit.placeholder_text = "Phase"
		_name_edit.tooltip_text = "The name of this list of choices. Spaces are removed for you."
		_name_edit.custom_minimum_size = Vector2(120, 24)
		_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_style_field(_name_edit, _font, _fs)
		_name_edit.text_changed.connect(_on_name_typed)
		_name_edit.text_submitted.connect(func(_t: String) -> void: _commit_name())
		_name_edit.focus_exited.connect(_commit_name)
		head.add_child(_name_edit)
		add_child(head)

		_rows = VBoxContainer.new()
		_rows.add_theme_constant_override("separation", 2)
		add_child(_rows)
		for i: int in members.size():
			_rows.add_child(_make_row(i))

		var foot: HBoxContainer = HBoxContainer.new()
		foot.add_theme_constant_override("separation", 6)
		var add: Button = Button.new()
		add.text = "+ Add member"
		add.tooltip_text = "Add a new choice to the end of the list"
		add.focus_mode = Control.FOCUS_NONE
		Ui.style_button(add)
		add.pressed.connect(_add_member)
		foot.add_child(add)
		_warn = Label.new()
		_warn.add_theme_font_size_override("font_size", 11)
		_warn.add_theme_color_override("font_color", WARN_COLOR)
		foot.add_child(_warn)
		add_child(foot)
		call_deferred("_end_rebuild")
		_refresh_numbers()


	func _make_row(i: int) -> Control:
		var row: HBoxContainer = HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		var idx: Label = Label.new()
		idx.custom_minimum_size = Vector2(26, 0)
		idx.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		idx.add_theme_font_size_override("font_size", 11)
		idx.add_theme_color_override("font_color", Ui.TEXT_MUTED)
		idx.tooltip_text = "The number this choice has in your game"
		row.add_child(idx)
		_index_labels.append(idx)

		var ne: LineEdit = LineEdit.new()
		ne.text = String(members[i]["name"])
		ne.placeholder_text = "MEMBER_NAME"
		ne.tooltip_text = "Name of this choice, e.g. IDLE. Written as UPPER_CASE_WITH_UNDERSCORES."
		ne.custom_minimum_size = Vector2(130, 24)
		ne.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_style_field(ne, _font, _fs)
		ne.text_changed.connect(func(t: String) -> void: _on_member_typed(i, t))
		ne.text_submitted.connect(func(_t: String) -> void: _commit_member(i))
		ne.focus_exited.connect(func() -> void: _commit_member(i))
		row.add_child(ne)
		_name_edits.append(ne)

		var ve: LineEdit = LineEdit.new()
		ve.text = String(members[i]["value"])
		ve.placeholder_text = "auto"
		ve.tooltip_text = "Optional number for this choice. Leave empty to count up automatically (0, 1, 2 ...)."
		ve.custom_minimum_size = Vector2(52, 24)
		_style_field(ve, _font, _fs)
		ve.text_changed.connect(func(t: String) -> void: _on_value_typed(i, t))
		ve.text_submitted.connect(func(_t: String) -> void: _commit_value(i))
		ve.focus_exited.connect(func() -> void: _commit_value(i))
		row.add_child(ve)
		_value_edits.append(ve)

		var up: Button = _small_button("\u25b2", "Move up")
		up.disabled = i == 0
		up.pressed.connect(func() -> void: _move(i, -1))
		row.add_child(up)
		var dn: Button = _small_button("\u25bc", "Move down")
		dn.disabled = i >= members.size() - 1
		dn.pressed.connect(func() -> void: _move(i, 1))
		row.add_child(dn)
		var rm: Button = _small_button("\u2715", "Remove this choice")
		rm.disabled = members.size() <= 1
		if rm.disabled:
			rm.tooltip_text = "An enum needs at least one choice"
		rm.pressed.connect(func() -> void: _remove(i))
		row.add_child(rm)
		return row


	# ---- editing ---------------------------------------------------------------
	func _emit() -> void:
		var body: String = T.build_enum(enum_name, members)
		_last_body = body
		_refresh_numbers()
		if on_change.is_valid():
			on_change.call(body)


	func _on_name_typed(t: String) -> void:
		var clean: String = T.enum_name(t)
		if clean == "":
			return   # keep the last valid name until something usable is typed
		enum_name = clean
		_emit()


	func _commit_name() -> void:
		if _rebuilding or not is_instance_valid(_name_edit):
			return
		var clean: String = T.enum_name(_name_edit.text)
		if clean == "":
			clean = enum_name
		if _name_edit.text != clean:
			_name_edit.text = clean
		if enum_name != clean:
			enum_name = clean
			_emit()


	func _on_member_typed(i: int, t: String) -> void:
		if i >= members.size():
			return
		var clean: String = T.member_name(t)
		if clean == "":
			return
		members[i]["name"] = clean
		_emit()


	func _commit_member(i: int) -> void:
		if _rebuilding or i >= members.size() or i >= _name_edits.size() or not is_instance_valid(_name_edits[i]):
			return
		var clean: String = T.member_name(_name_edits[i].text)
		if clean == "":
			clean = String(members[i]["name"])
		# a name that is already taken by another member gets a number
		var taken: Array = []
		for j: int in members.size():
			if j != i:
				taken.append(String(members[j]["name"]))
		var unique: String = clean
		var n: int = 2
		while taken.has(unique):
			unique = "%s_%d" % [clean, n]
			n += 1
		if _name_edits[i].text != unique:
			_name_edits[i].text = unique
		if String(members[i]["name"]) != unique:
			members[i]["name"] = unique
			_emit()


	func _on_value_typed(i: int, t: String) -> void:
		if i >= members.size():
			return
		members[i]["value"] = T.clean_enum_value(t)
		_emit()


	func _commit_value(i: int) -> void:
		if _rebuilding or i >= members.size() or i >= _value_edits.size() or not is_instance_valid(_value_edits[i]):
			return
		var clean: String = T.clean_enum_value(_value_edits[i].text)
		if _value_edits[i].text != clean:
			_value_edits[i].text = clean
		if String(members[i]["value"]) != clean:
			members[i]["value"] = clean
			_emit()


	func _add_member() -> void:
		var names: Array = []
		for m: Dictionary in members:
			names.append(String(m["name"]))
		var n: int = members.size() + 1
		var nm: String = "VALUE_%d" % n
		while names.has(nm):
			n += 1
			nm = "VALUE_%d" % n
		members.append({"name": nm, "value": ""})
		_build()
		_emit()
		var last: int = _name_edits.size() - 1
		if last >= 0:
			_name_edits[last].call_deferred("grab_focus")
			_name_edits[last].call_deferred("select_all")


	func _remove(i: int) -> void:
		if members.size() <= 1 or i >= members.size():
			return
		members.remove_at(i)
		_build()
		_emit()


	func _move(i: int, delta: int) -> void:
		var j: int = i + delta
		if i < 0 or j < 0 or i >= members.size() or j >= members.size():
			return
		var tmp: Dictionary = members[i]
		members[i] = members[j]
		members[j] = tmp
		_build()
		_emit()


	## Updates the number chips and the duplicate warning in place.
	func _refresh_numbers() -> void:
		var nums: PackedStringArray = T.enum_numbers(members)
		var names: Array = []
		for m: Dictionary in members:
			names.append(String(m["name"]))
		var dup: Dictionary = T.duplicate_names(names)
		for i: int in _index_labels.size():
			if i < nums.size() and is_instance_valid(_index_labels[i]):
				_index_labels[i].text = nums[i] if nums[i] != "" else "?"
		for i2: int in _name_edits.size():
			if i2 < members.size() and is_instance_valid(_name_edits[i2]):
				_mark(_name_edits[i2], not dup.has(String(members[i2]["name"])))
		if is_instance_valid(_warn):
			_warn.text = "\u26a0 two choices share a name" if not dup.is_empty() else ""


# =============================================================================
# Dictionary form
# =============================================================================
class DictForm extends Base:
	const T = preload("collection_text.gd")
	const Ui = preload("ui_style.gd")

	var entries: Array = []
	var on_change: Callable = Callable()
	var _font: Font
	var _fs: int = 13
	var _last_text: String = ""
	var _raw_mode: bool = false
	var _rows: VBoxContainer
	var _count: Label
	var _warn: Label
	var _key_edits: Array[Control] = []
	var _val_edits: Array[Control] = []


	func setup(text: String, font: Font, font_size: int, change_cb: Callable) -> void:
		_font = font
		_fs = font_size
		on_change = change_cb
		_last_text = text
		_load(text)
		_build()


	func _load(text: String) -> void:
		var info: Dictionary = T.parse_dict(text)
		_raw_mode = not bool(info["ok"])
		entries = (info["entries"] as Array).duplicate(true) if not _raw_mode else []


	## Called when the model's text changed from outside (undo, reload).
	func sync_external(text: String) -> void:
		if text == _last_text or _has_focus_inside():
			return
		_last_text = text
		_load(text)
		_build()


	func _build() -> void:
		_rebuilding = true
		for c: Node in get_children():
			remove_child(c)
			c.queue_free()
		_key_edits.clear()
		_val_edits.clear()
		add_theme_constant_override("separation", 3)
		if _raw_mode:
			_build_raw()
			call_deferred("_end_rebuild")
			return

		var head: HBoxContainer = HBoxContainer.new()
		head.add_theme_constant_override("separation", 6)
		var add: Button = Button.new()
		add.text = "+ Add entry"
		add.tooltip_text = "Add a new key and value"
		add.focus_mode = Control.FOCUS_NONE
		Ui.style_button(add)
		add.pressed.connect(_add_entry)
		head.add_child(add)
		var sort: Button = _small_button("A\u2192Z", "Sort entries by key")
		sort.disabled = entries.size() < 2
		sort.pressed.connect(_sort)
		head.add_child(sort)
		var clear: Button = _small_button("Clear", "Remove every entry")
		clear.disabled = entries.is_empty()
		clear.pressed.connect(_clear)
		head.add_child(clear)
		_count = Label.new()
		_count.add_theme_font_size_override("font_size", 11)
		_count.add_theme_color_override("font_color", Ui.TEXT_MUTED)
		head.add_child(_count)
		add_child(head)

		_rows = VBoxContainer.new()
		_rows.add_theme_constant_override("separation", 2)
		add_child(_rows)
		for i: int in entries.size():
			_rows.add_child(_make_row(i))

		_warn = Label.new()
		_warn.add_theme_font_size_override("font_size", 11)
		_warn.add_theme_color_override("font_color", WARN_COLOR)
		add_child(_warn)
		call_deferred("_end_rebuild")
		_refresh_status()


	func _build_raw() -> void:
		var hint: Label = Label.new()
		hint.text = "Custom code. Clear the box to use the list editor."
		hint.add_theme_font_size_override("font_size", 11)
		hint.add_theme_color_override("font_color", Ui.TEXT_MUTED)
		add_child(hint)
		var raw: LineEdit = LineEdit.new()
		raw.text = _last_text
		raw.custom_minimum_size = Vector2(ROW_MIN_W, 24)
		raw.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_style_field(raw, _font, _fs)
		raw.text_changed.connect(func(t: String) -> void:
			_last_text = t
			if on_change.is_valid():
				on_change.call(t))
		var back: Callable = func() -> void:
			if _rebuilding or not is_instance_valid(raw):
				return
			var info: Dictionary = T.parse_dict(raw.text)
			if bool(info["ok"]):
				call_deferred("_leave_raw", raw.text)
		raw.text_submitted.connect(func(_t: String) -> void: back.call())
		raw.focus_exited.connect(back)
		add_child(raw)


	const ROW_MIN_W: float = 260.0


	func _leave_raw(text: String) -> void:
		_load(text)
		_build()


	func _type_button(kind: int, tip: String) -> OptionButton:
		var ob: OptionButton = OptionButton.new()
		for i: int in T.TYPE_NAMES.size():
			ob.add_item(T.TYPE_NAMES[i], i)
		ob.select(kind)
		ob.tooltip_text = tip
		ob.focus_mode = Control.FOCUS_NONE
		ob.add_theme_font_size_override("font_size", 11)
		ob.custom_minimum_size = Vector2(58, 24)
		return ob


	## The value control for one side (key or value) of an entry.
	func _make_input(i: int, is_key: bool) -> Control:
		var kind: int = int(entries[i]["kt" if is_key else "vt"])
		var text: String = String(entries[i]["k" if is_key else "v"])
		if kind == T.T_BOOL:
			var cb: CheckBox = CheckBox.new()
			cb.button_pressed = text.strip_edges().to_lower() == "true"
			cb.text = "true" if cb.button_pressed else "false"
			cb.tooltip_text = "Checked = true, unchecked = false"
			cb.custom_minimum_size = Vector2(70, 24)
			cb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			Ui.style_check_box(cb)
			cb.toggled.connect(func(on: bool) -> void:
				cb.text = "true" if on else "false"
				_set_text(i, is_key, "true" if on else "false"))
			return cb
		var le: LineEdit = LineEdit.new()
		le.text = text
		le.custom_minimum_size = Vector2(70, 24)
		le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		match kind:
			T.T_TEXT:
				le.placeholder_text = "key" if is_key else "words"
				le.tooltip_text = "Plain text. Quotes are added for you."
			T.T_NUM:
				le.placeholder_text = "0"
				le.tooltip_text = "A number such as 5 or 2.5"
			_:
				le.placeholder_text = "expression"
				le.tooltip_text = "Any GDScript, e.g. Phase.IDLE or Vector2(1, 2). Kept exactly as typed."
		_style_field(le, _font, _fs)
		le.text_changed.connect(func(t: String) -> void: _set_text(i, is_key, t))
		return le


	func _make_row(i: int) -> Control:
		var row: HBoxContainer = HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)

		var kb: OptionButton = _type_button(int(entries[i]["kt"]), "What kind of key this is")
		kb.item_selected.connect(func(idx: int) -> void: _set_kind(i, true, idx))
		row.add_child(kb)
		var ki: Control = _make_input(i, true)
		row.add_child(ki)
		_key_edits.append(ki)

		var colon: Label = Label.new()
		colon.text = "\u2192"
		colon.add_theme_color_override("font_color", Ui.TEXT_MUTED)
		row.add_child(colon)

		var vb: OptionButton = _type_button(int(entries[i]["vt"]), "What kind of value this is")
		vb.item_selected.connect(func(idx: int) -> void: _set_kind(i, false, idx))
		row.add_child(vb)
		var vi: Control = _make_input(i, false)
		row.add_child(vi)
		_val_edits.append(vi)

		var up: Button = _small_button("\u25b2", "Move up")
		up.disabled = i == 0
		up.pressed.connect(func() -> void: _move(i, -1))
		row.add_child(up)
		var dn: Button = _small_button("\u25bc", "Move down")
		dn.disabled = i >= entries.size() - 1
		dn.pressed.connect(func() -> void: _move(i, 1))
		row.add_child(dn)
		var rm: Button = _small_button("\u2715", "Remove this entry")
		rm.pressed.connect(func() -> void: _remove(i))
		row.add_child(rm)
		return row


	# ---- editing ---------------------------------------------------------------
	func _emit() -> void:
		var text: String = T.build_dict(entries)
		_last_text = text
		_refresh_status()
		if on_change.is_valid():
			on_change.call(text)


	func _set_text(i: int, is_key: bool, t: String) -> void:
		if i >= entries.size():
			return
		entries[i]["k" if is_key else "v"] = t
		_emit()


	func _set_kind(i: int, is_key: bool, kind: int) -> void:
		if i >= entries.size():
			return
		var kk: String = "kt" if is_key else "vt"
		var tk: String = "k" if is_key else "v"
		var old: int = int(entries[i][kk])
		if old == kind:
			return
		var text: String = String(entries[i][tk])
		# keep what was typed when it still makes sense for the new kind
		if kind == T.T_BOOL:
			text = "true" if text.strip_edges().to_lower() == "true" else "false"
		elif kind == T.T_NUM and not (text.is_valid_int() or text.is_valid_float()):
			text = "0"
		elif old == T.T_BOOL and kind != T.T_BOOL:
			pass   # "true" / "false" is a fine starting text for Text and Code
		entries[i][kk] = kind
		entries[i][tk] = text
		_build()
		_emit()


	func _add_entry() -> void:
		var n: int = entries.size() + 1
		var existing: Array = []
		for e: Dictionary in entries:
			existing.append(String(e["k"]))
		var key: String = "key%d" % n
		while existing.has(key):
			n += 1
			key = "key%d" % n
		entries.append({"kt": T.T_TEXT, "k": key, "vt": T.T_TEXT, "v": ""})
		_build()
		_emit()
		var last: int = _key_edits.size() - 1
		if last >= 0:
			_key_edits[last].call_deferred("grab_focus")
			if _key_edits[last] is LineEdit:
				(_key_edits[last] as LineEdit).call_deferred("select_all")


	func _remove(i: int) -> void:
		if i >= entries.size():
			return
		entries.remove_at(i)
		_build()
		_emit()


	func _move(i: int, delta: int) -> void:
		var j: int = i + delta
		if i < 0 or j < 0 or i >= entries.size() or j >= entries.size():
			return
		var tmp: Dictionary = entries[i]
		entries[i] = entries[j]
		entries[j] = tmp
		_build()
		_emit()


	func _sort() -> void:
		entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return String(a["k"]).naturalnocasecmp_to(String(b["k"])) < 0)
		_build()
		_emit()


	func _clear() -> void:
		entries.clear()
		_build()
		_emit()


	## Entry count, duplicate-key warning and red marks for unusable numbers.
	func _refresh_status() -> void:
		if is_instance_valid(_count):
			_count.text = "%d %s" % [entries.size(), "entry" if entries.size() == 1 else "entries"]
		var dup: Dictionary = T.duplicate_keys(entries)
		for i: int in entries.size():
			var e: Dictionary = entries[i]
			var key_dup: bool = dup.has(T.value_source(int(e["kt"]), String(e["k"])))
			if i < _key_edits.size() and is_instance_valid(_key_edits[i]):
				_mark(_key_edits[i], T.value_ok(int(e["kt"]), String(e["k"])) and not key_dup)
			if i < _val_edits.size() and is_instance_valid(_val_edits[i]):
				_mark(_val_edits[i], T.value_ok(int(e["vt"]), String(e["v"])))
		if is_instance_valid(_warn):
			_warn.text = "\u26a0 two entries use the same key" if not dup.is_empty() else ""


# =============================================================================
# Array form
# =============================================================================
class ArrayForm extends Base:
	const T = preload("collection_text.gd")
	const Ui = preload("ui_style.gd")
	const ROW_MIN_W: float = 220.0

	var items: Array = []
	var on_change: Callable = Callable()
	var _font: Font
	var _fs: int = 13
	var _last_text: String = ""
	var _raw_mode: bool = false
	var _rows: VBoxContainer
	var _count: Label
	var _edits: Array[Control] = []


	func setup(text: String, font: Font, font_size: int, change_cb: Callable) -> void:
		_font = font
		_fs = font_size
		on_change = change_cb
		_last_text = text
		_load(text)
		_build()


	func _load(text: String) -> void:
		var info: Dictionary = T.parse_array(text)
		_raw_mode = not bool(info["ok"])
		items = (info["items"] as Array).duplicate(true) if not _raw_mode else []


	## Called when the model's text changed from outside (undo, reload).
	func sync_external(text: String) -> void:
		if text == _last_text or _has_focus_inside():
			return
		_last_text = text
		_load(text)
		_build()


	func _build() -> void:
		_rebuilding = true
		for c: Node in get_children():
			remove_child(c)
			c.queue_free()
		_edits.clear()
		add_theme_constant_override("separation", 3)
		if _raw_mode:
			_build_raw()
			call_deferred("_end_rebuild")
			return

		var head: HBoxContainer = HBoxContainer.new()
		head.add_theme_constant_override("separation", 6)
		var add: Button = Button.new()
		add.text = "+ Add item"
		add.tooltip_text = "Add a new item to the end of the list"
		add.focus_mode = Control.FOCUS_NONE
		Ui.style_button(add)
		add.pressed.connect(_add_item)
		head.add_child(add)
		var sort: Button = _small_button("A\u2192Z", "Sort the items")
		sort.disabled = items.size() < 2
		sort.pressed.connect(_sort)
		head.add_child(sort)
		var clear: Button = _small_button("Clear", "Remove every item")
		clear.disabled = items.is_empty()
		clear.pressed.connect(_clear)
		head.add_child(clear)
		_count = Label.new()
		_count.add_theme_font_size_override("font_size", 11)
		_count.add_theme_color_override("font_color", Ui.TEXT_MUTED)
		head.add_child(_count)
		add_child(head)

		_rows = VBoxContainer.new()
		_rows.add_theme_constant_override("separation", 2)
		add_child(_rows)
		for i: int in items.size():
			_rows.add_child(_make_row(i))
		call_deferred("_end_rebuild")
		_refresh_status()


	func _build_raw() -> void:
		var hint: Label = Label.new()
		hint.text = "Custom code. Clear the box to use the list editor."
		hint.add_theme_font_size_override("font_size", 11)
		hint.add_theme_color_override("font_color", Ui.TEXT_MUTED)
		add_child(hint)
		var raw: LineEdit = LineEdit.new()
		raw.text = _last_text
		raw.custom_minimum_size = Vector2(ROW_MIN_W, 24)
		raw.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_style_field(raw, _font, _fs)
		raw.text_changed.connect(func(t: String) -> void:
			_last_text = t
			if on_change.is_valid():
				on_change.call(t))
		var back: Callable = func() -> void:
			if _rebuilding or not is_instance_valid(raw):
				return
			var info: Dictionary = T.parse_array(raw.text)
			if bool(info["ok"]):
				call_deferred("_leave_raw", raw.text)
		raw.text_submitted.connect(func(_t: String) -> void: back.call())
		raw.focus_exited.connect(back)
		add_child(raw)


	func _leave_raw(text: String) -> void:
		_load(text)
		_build()


	func _type_button(kind: int) -> OptionButton:
		var ob: OptionButton = OptionButton.new()
		for i: int in T.TYPE_NAMES.size():
			ob.add_item(T.TYPE_NAMES[i], i)
		ob.select(kind)
		ob.tooltip_text = "What kind of item this is: Text, Num (number), Bool (true / false) or Code (any GDScript)"
		ob.focus_mode = Control.FOCUS_NONE
		ob.add_theme_font_size_override("font_size", 11)
		ob.custom_minimum_size = Vector2(58, 24)
		return ob


	func _make_input(i: int) -> Control:
		var kind: int = int(items[i]["t"])
		var text: String = String(items[i]["text"])
		if kind == T.T_BOOL:
			var cb: CheckBox = CheckBox.new()
			cb.button_pressed = text.strip_edges().to_lower() == "true"
			cb.text = "true" if cb.button_pressed else "false"
			cb.tooltip_text = "Checked = true, unchecked = false"
			cb.custom_minimum_size = Vector2(70, 24)
			cb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			Ui.style_check_box(cb)
			cb.toggled.connect(func(on: bool) -> void:
				cb.text = "true" if on else "false"
				_set_text(i, "true" if on else "false"))
			return cb
		var le: LineEdit = LineEdit.new()
		le.text = text
		le.custom_minimum_size = Vector2(90, 24)
		le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		match kind:
			T.T_TEXT:
				le.placeholder_text = "words"
				le.tooltip_text = "Plain text. Quotes are added for you."
			T.T_NUM:
				le.placeholder_text = "0"
				le.tooltip_text = "A number such as 5 or 2.5"
			_:
				le.placeholder_text = "expression"
				le.tooltip_text = "Any GDScript, e.g. Phase.IDLE or Vector2(1, 2). Kept exactly as typed."
		_style_field(le, _font, _fs)
		le.text_changed.connect(func(t: String) -> void: _set_text(i, t))
		return le


	func _make_row(i: int) -> Control:
		var row: HBoxContainer = HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		var idx: Label = Label.new()
		idx.text = str(i)
		idx.custom_minimum_size = Vector2(22, 0)
		idx.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		idx.add_theme_font_size_override("font_size", 11)
		idx.add_theme_color_override("font_color", Ui.TEXT_MUTED)
		idx.tooltip_text = "Position in the list (the first item is 0)"
		row.add_child(idx)
		var tb: OptionButton = _type_button(int(items[i]["t"]))
		tb.item_selected.connect(func(k: int) -> void: _set_kind(i, k))
		row.add_child(tb)
		var inp: Control = _make_input(i)
		row.add_child(inp)
		_edits.append(inp)
		var up: Button = _small_button("\u25b2", "Move up")
		up.disabled = i == 0
		up.pressed.connect(func() -> void: _move(i, -1))
		row.add_child(up)
		var dn: Button = _small_button("\u25bc", "Move down")
		dn.disabled = i >= items.size() - 1
		dn.pressed.connect(func() -> void: _move(i, 1))
		row.add_child(dn)
		var rm: Button = _small_button("\u2715", "Remove this item")
		rm.pressed.connect(func() -> void: _remove(i))
		row.add_child(rm)
		return row


	# ---- editing ---------------------------------------------------------------
	func _emit() -> void:
		var text: String = T.build_array(items)
		_last_text = text
		_refresh_status()
		if on_change.is_valid():
			on_change.call(text)


	func _set_text(i: int, t: String) -> void:
		if i >= items.size():
			return
		items[i]["text"] = t
		_emit()


	func _set_kind(i: int, kind: int) -> void:
		if i >= items.size():
			return
		var old: int = int(items[i]["t"])
		if old == kind:
			return
		var text: String = String(items[i]["text"])
		if kind == T.T_BOOL:
			text = "true" if text.strip_edges().to_lower() == "true" else "false"
		elif kind == T.T_NUM and not (text.is_valid_int() or text.is_valid_float()):
			text = "0"
		items[i]["t"] = kind
		items[i]["text"] = text
		_build()
		_emit()


	## A new item has the same kind as the last one, so a list of numbers keeps
	## getting numbers.
	func _add_item() -> void:
		var kind: int = int(items[items.size() - 1]["t"]) if not items.is_empty() else T.T_TEXT
		var text: String = ""
		match kind:
			T.T_NUM:
				text = "0"
			T.T_BOOL:
				text = "false"
			T.T_CODE:
				text = "null"
		items.append({"t": kind, "text": text})
		_build()
		_emit()
		var last: int = _edits.size() - 1
		if last >= 0:
			_edits[last].call_deferred("grab_focus")
			if _edits[last] is LineEdit:
				(_edits[last] as LineEdit).call_deferred("select_all")


	func _remove(i: int) -> void:
		if i >= items.size():
			return
		items.remove_at(i)
		_build()
		_emit()


	func _move(i: int, delta: int) -> void:
		var j: int = i + delta
		if i < 0 or j < 0 or i >= items.size() or j >= items.size():
			return
		var tmp: Dictionary = items[i]
		items[i] = items[j]
		items[j] = tmp
		_build()
		_emit()


	func _sort() -> void:
		items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return String(a["text"]).naturalnocasecmp_to(String(b["text"])) < 0)
		_build()
		_emit()


	func _clear() -> void:
		items.clear()
		_build()
		_emit()


	## Item count and red marks for unusable numbers.
	func _refresh_status() -> void:
		if is_instance_valid(_count):
			_count.text = "%d %s" % [items.size(), "item" if items.size() == 1 else "items"]
		for i: int in items.size():
			if i < _edits.size() and is_instance_valid(_edits[i]):
				_mark(_edits[i], T.value_ok(int(items[i]["t"]), String(items[i]["text"])))
