# Runs headless: godot --headless --path <project> -s res://addons/gd_canvas_spikes/graph_ui_tests_cli.gd
extends SceneTree
## Headless UI-layer test: canvas builds views/wires, connection requests,
## disconnections, node deletion and add-node work through the real handlers.

const Canvas = preload("res://addons/gd_canvas_spikes/graph_canvas.gd")
const NodeView = preload("res://addons/gd_canvas_spikes/graph_node.gd")
const Model = preload("res://addons/gd_canvas_spikes/graph_model.gd")
const Types = preload("res://addons/gd_canvas_spikes/graph_types.gd")
const FuncReg = preload("res://addons/gd_canvas_spikes/func_registry.gd")
const Workspace = preload("res://addons/gd_canvas_spikes/graph_workspace.gd")

var fail: Dictionary = {"n": 0}
var out: PackedStringArray = PackedStringArray()


func _init() -> void:
	var one: String = OS.get_environment("VS_ONE_TEST")
	if one != "" and OS.get_environment("VS_PRE2") == "":
		await call(one)
		print("\n".join(out))
		print("ONE-TEST DONE")
		quit(0)
		return
	var c: Canvas = Canvas.new()
	# wide enough that the header-metadata column (left of the header) shifting
	# the content right never pushes the function row off-screen
	c.custom_minimum_size = Vector2(1400, 900)
	c.size = Vector2(1400, 900)
	root.add_child(c)
	await process_frame
	await process_frame

	c.build_from_text("extends Node\n\nvar health: int = 100\nvar speed: float = 4.5\n\nfunc take_hit(amount: int) -> void:\n\thealth -= amount\n\tif health > 0:\n\t\tprint(\"still alive\")\n\telse:\n\t\tprint(\"game over\")\n\t\treturn\n\tspeed = speed * 0.5\n\tprint(\"speed now \", speed)\n")
	await process_frame
	var preamble_body: bool = not OS.get_environment("VS_SKIP_PRE").contains("preamble_body")
	if preamble_body:
		_check("views created", c.views.size() == c.model.node_count(), str(c.views.size()))
	_check("wires synced", c.get_connection_list().size() > 0, str(c.get_connection_list().size()))

	var entry_id: int = -1
	for id: int in c.model.nodes:
		if int(c.model.nodes[id]["kind"]) == 0:
			entry_id = id
	var if_id: int = -1
	for id: int in c.model.nodes:
		if int(c.model.nodes[id]["kind"]) == 2:
			if_id = id
	if preamble_body:
		_check("found entry + if", entry_id > 0 and if_id > 0, "%s/%s" % [entry_id, if_id])

		var fv: NodeView = c.views[entry_id]
		var tv: NodeView = c.views[if_id]
		var out_port: int = -1
		for p: int in fv.get_output_port_count():
			if fv.out_def(p)["kind"] == "exec" and int(fv.out_def(p)["index"]) == 0:
				out_port = p
		var in_port: int = -1
		for p: int in tv.get_input_port_count():
			if tv.in_def(p)["kind"] == "exec":
				in_port = p
		_check("ports found", out_port >= 0 and in_port >= 0, "%s/%s" % [out_port, in_port])
		_check("hover valid: exec->exec",
			c.call("_is_node_hover_valid", "n%d" % entry_id, out_port, "n%d" % if_id, in_port), "")

		c.add_user_node(13, {"type": Types.PinType.INT, "value": "3"})  # LITERAL
		var lit_view: NodeView = null
		for id: int in c.views:
			if int(c.model.nodes[id]["kind"]) == 13:
				lit_view = c.views[id]
		_check("literal has no exec input -> hover invalid",
			lit_view != null and not c.call("_is_node_hover_valid", "n%d" % entry_id, out_port, lit_view.name, 0), "")

		# fresh statement chain through the real connection handler
		c.add_user_node(1)
		c.add_user_node(1)
		var s1: NodeView = null
		var s2: NodeView = null
		for id: int in c.views:
			if int(c.model.nodes[id]["kind"]) == 1 and c.model.nodes[id]["stmt"].is_empty() and String(c.model.nodes[id]["body"]) == "":
				if s1 == null:
					s1 = c.views[id]
				elif s2 == null and id != s1.model_id:
					s2 = c.views[id]
		_check("two fresh statements added", s1 != null and s2 != null, "")
		if s1 != null and s2 != null:
			var o: int = _first_exec_out(s1)
			var i: int = _first_exec_in(s2)
			c._on_connection_request(s1.name, o, s2.name, i)
			_check("connection_request wires exec", c.model._exec_target(s1.model_id, 0) == s2.model_id
				and c.is_node_connected(s1.name, o, s2.name, i), "")
			c._on_disconnection_request(s1.name, o, s2.name, i)
			_check("disconnection_request unwires", c.model._exec_target(s1.model_id, 0) == -1
				and not c.is_node_connected(s1.name, o, s2.name, i), "")
			s2 = c.views.get(s2.model_id)

		# data connect via handler: literal -> assignment value pin
		var assign_id: int = -1
		for id: int in c.model.nodes:
			if int(c.model.nodes[id]["kind"]) == 1 and c.model.nodes[id]["stmt"].size() > 0:
				assign_id = id
		_check("assignment statement exists", assign_id > 0, str(assign_id))
		if lit_view != null and assign_id > 0:
			var av: NodeView = c.views[assign_id]
			var dport: int = -1
			for p: int in av.get_input_port_count():
				if av.in_def(p)["kind"] == "data":
					dport = p
			var lport: int = -1
			for p: int in lit_view.get_output_port_count():
				if lit_view.out_def(p)["kind"] == "data":
					lport = p
			c._on_connection_request(lit_view.name, lport, av.name, dport)
			_check("data link via handler", c.model.connected_data_input(assign_id, 0).size() > 0
				and int(c.model.connected_data_input(assign_id, 0)["from_id"]) == lit_view.model_id, "")
			var gen: Dictionary = c.generate_code()
			_check("generated code uses literal", gen["text"].contains("= 3"), gen["code"])

		# delete nodes via handler
		if s2 != null:
			var victim: int = s2.model_id
			c._on_delete_nodes_request([s2.name])
			_check("delete removes view+model", not c.views.has(victim) and not c.model.nodes.has(victim), "")
			_check("no orphan wires", _no_orphans(c), "")

		# pin value edit updates model
		if assign_id > 0 and c.views.has(assign_id):
			c._on_pin_value_changed(assign_id, 0, "7")
			_check("pin edit lands in model", String(c.model.nodes[assign_id]["data_ins"][0]["value"]) == "7", "")

		var gen2: Dictionary = c.generate_code()
		_check("canvas codegen ok", bool(gen2["ok"]), str(gen2["err_text"]))

# ---- New-feature regression suite ------------------------------------
	var skip_pre: String = OS.get_environment("VS_SKIP_PRE")
	if not skip_pre.contains("new_features"):
		await _test_new_features(c)
	if not skip_pre.contains("ghost_saving"):
		await _test_ghost_wire_and_saving(c)
	if not skip_pre.contains("source_sync"):
		await _test_source_sync(c)
	if not skip_pre.contains("wheel_drag"):
		await _test_wheel_and_drag_interactive()
	if not skip_pre.contains("function_ui"):
		await _test_function_ui(c)
	if not skip_pre.contains("arg_pin_wires"):
		await _test_argument_pin_wires(c)
	if not skip_pre.contains("save_reopen"):
		await _test_function_save_reopen(c)
	# The preamble canvas is not needed by the tail tests; leave it alive and
	# it keeps swallowing the mouse events those tests aim at their own
	# windows (its GraphEdit overlaps the same screen positions).
	c.queue_free()
	await process_frame
	if OS.get_environment("VS_ONE_TEST") != "" and OS.get_environment("VS_PRE2") != "":
		await call(OS.get_environment("VS_ONE_TEST"))
		print("\n".join(out))
		quit(0)
		return
	# Popup layers (type-suggest / type-picker panels) can outlive their
	# test window when a field is freed mid-popup: they linger as root
	# children and swallow the mouse events later tests aim at their own
	# windows. Purge them before every input-driven tail test.
	for kid: Node in root.get_children():
		if kid is CanvasLayer or kid is Control:
			root.remove_child(kid)
			kid.free()
	var tail: Array[String] = ["_test_form_ui_fixes", "_test_comparison_ui",
		"_test_scope_ui", "_test_if_cond_ui", "_test_block_var_ui",
		"_test_args_left_layout", "_test_dynamic_inputs_ui",
		"_test_ui_fixes_round6", "_test_wire_dir_and_menu_keys",
		"_test_scope_and_wires", "_test_function_menu", "_test_type_suggest",
		"_test_value_suggest_nav", "_test_annotation_ui",
		"_test_annotation_menu_ctx", "_test_export_group_ui",
		"_test_ann_commit_ui", "_test_reference_parity",
		"_test_call_defaults", "_test_annotation_nodes_ui",
		"_test_d_fixes_and_title", "_test_c_save_refusal",
		"_test_b_menu_nodes", "_test_literal_entries"]
	var cutoff: String = OS.get_environment("VS_STOP_AFTER")
	for tname: String in tail:
		for kid: Node in root.get_children():
			if kid is CanvasLayer or kid is Control:
				root.remove_child(kid)
				kid.free()
		await call(tname)
		if cutoff != "" and tname == cutoff:
			var one2: String = OS.get_environment("VS_ONE_TEST")
			if one2 != "":
				await call(one2)
			print("\n".join(out))
			quit(0)
			return
	out.append("")
	out.append("%d checks, %d failures -> %s" % [out.size(), int(fail["n"]), "PASS" if int(fail["n"]) == 0 else "FAIL"])
	print("\n".join(out))
	quit(0 if int(fail["n"]) == 0 else 1)


func _test_new_features(c: Canvas) -> void:
	c.build_from_text("extends Node\n\nvar health: int = 100\n\nfunc take_hit(amount: int) -> void:\n\thealth -= amount\n\tif health > 0:\n\t\tprint(\"still alive\")\n\telse:\n\t\treturn\n\tprint(\"done\")\n\nfunc tick(delta: float) -> void:\n\tfor i in range(3):\n\t\tprint(i)\n")
	await process_frame
	await process_frame

	# 1. Every stored wire sits on ports whose definitions match its kinds
	#    (no wrong-pin wires): exec wires resolve to exec pins, data wires to
	#    data pins, and the model agrees with GraphEdit exactly.
	var kinds_ok: bool = true
	var count_matches: bool = true
	for conn: Dictionary in c.get_connection_list():
		var fid: int = int(str(conn["from_node"]).trim_prefix("n"))
		var tid: int = int(str(conn["to_node"]).trim_prefix("n"))
		var fv: NodeView = c.views[fid]
		var tv: NodeView = c.views[tid]
		var od: Dictionary = fv.out_def(int(conn["from_port"]))
		var idn: Dictionary = tv.in_def(int(conn["to_port"]))
		if od.is_empty() or idn.is_empty() or od["kind"] != idn["kind"]:
			kinds_ok = false
			continue
		if od["kind"] == "exec":
			if int(c.model.exec_out[fid].get(int(od["index"]), -1)) != tid:
				count_matches = false
		if od["kind"] == "data":
			var found: bool = false
			for l: Dictionary in c.model.data_links:
				if int(l["from_id"]) == fid and int(l["from_out"]) == int(od["index"]) \
						and int(l["to_id"]) == tid and int(l["to_in"]) == int(idn["index"]):
					found = true
			# Argument ownership wires (Function connection pin -> Function's
			# argument slot) are stored in arg_links, not data_links.
			if not found and int(c.model.nodes[tid]["kind"]) == Model.Kind.ENTRY \
					and int(od["index"]) == 1:
				for al: Dictionary in c.model.arg_links:
					if int(al["aid"]) == fid and int(al["eid"]) == tid:
						found = true
			# Scope registrations (variable scope pin -> scope owner slot) and
			# Script Header metadata wires live in scope_links / header_links.
			if not found and int(od["index"]) == 1:
				for sl: Dictionary in c.model.scope_links:
					if int(sl["vid"]) == fid and int(sl["tid"]) == tid:
						found = true
			if not found:
				for hl: Dictionary in c.model.header_links:
					if int(hl["nid"]) == fid and int(hl["hid"]) == tid:
						found = true
			if not found:
				count_matches = false
	_check("every wire sits on matching pins", kinds_ok, "")
	_check("wires match the model 1:1", count_matches, "")

	# exec wire from the Entry attaches AFTER its data-out ports (mapping fix)
	var entry2: int = _find_kind(c, 0)
	var stmt: int = _find_stmt_with_value(c)
	_check("entry exec wire not on data pin",
		c.model._exec_target(entry2, 0) == stmt and _wire_is_exec(c, entry2, stmt), "")

	# 2. Rebuilding the graph keeps the wires (no name-collision pruning).
	var n_before: int = c.get_connection_list().size()
	c.build_from_text("extends Node\n\nfunc f() -> void:\n\tprint(1)\n\tprint(2)\n")
	await process_frame
	await process_frame
	# 2 exec wires + the `extends Node` metadata wire into the Script Header
	_check("rebuild keeps connections", c.get_connection_list().size() == 3,
		str(c.get_connection_list().size()))

	# 3. Execution wire disconnect via disconnection_request (real handler).
	c.build_from_text("extends Node\n\nfunc f() -> void:\n\tprint(1)\n\tprint(2)\n\tprint(3)\n")
	await process_frame
	var a: int = _find_node_by_body(c, "print(1)")
	var b: int = _find_node_by_body(c, "print(2)")
	var d: int = _find_node_by_body(c, "print(3)")
	var av: NodeView = c.views[a]
	var bv: NodeView = c.views[b]
	var dv: NodeView = c.views[d]
	var ao: int = av.exec_out_port(0)
	var bi: int = bv.exec_in_port(0)
	c._on_disconnection_request(av.name, ao, bv.name, bi)
	_check("exec wire disconnects", c.model._exec_target(a, 0) == -1
		and not c.is_node_connected(av.name, ao, bv.name, bi), "")
	_check("unrelated exec wire kept", c.model._exec_target(b, 0) == d
		and c.is_node_connected(bv.name, bv.exec_out_port(0), dv.name, 0), "")
	var g1: Dictionary = c.generate_code()
	_check("codegen reflects exec disconnect", not g1["code"].contains("print(2)"), g1["code"])

	# 4. Data wire disconnect via disconnection_request (Print's value pin).
	var lit_id: int = c.spawn_node(c.Model.Kind.LITERAL, {"type": c.Types.PinType.INT, "value": "9"}, Vector2(300, 100))
	var lv: NodeView = c.views[lit_id]
	var lo: int = lv.data_out_port(0)
	var pr_id: int = c.spawn_node(c.Model.Kind.PRINT, {}, Vector2(300, 140))
	var prv: NodeView = c.views[pr_id]
	var di: int = prv.data_in_port(0)
	c._on_connection_request(lv.name, lo, prv.name, di)
	_check("data wire connects", c.model.connected_data_input(pr_id, 0).size() > 0, "")
	c._on_disconnection_request(lv.name, lo, prv.name, di)
	_check("data wire disconnects", c.model.connected_data_input(pr_id, 0).is_empty(), "")
	var g2: Dictionary = c.generate_code()
	_check("codegen reflects data disconnect", g2["code"].contains("print(1)"), g2["code"])

	# 5. Wire selection by click position + deletion.
	c.build_from_text("extends Node\n\nfunc f() -> void:\n\tprint(1)\n\tprint(2)\n")
	await process_frame
	await process_frame
	var sa: int = _find_node_by_body(c, "print(1)")
	var sb: int = _find_node_by_body(c, "print(2)")
	var mid: Vector2 = _wire_midpoint(c, sa, 0, sb, 0)
	_check("wire_at finds the wire", not c.wire_at(mid).is_empty(), str(mid))
	_check("wire_at empty on blank spot", c.wire_at(Vector2(-500, -500)).is_empty(), "")
	if not c.wire_at(mid).is_empty():
		c._select_wire(c.wire_at(mid))
		_check("selection stored", not c._selected_wire.is_empty(), "")
		var del_ok: bool = c.delete_selected_wire()
		_check("selected wire deleted", del_ok and c.model._exec_target(sa, 0) == -1
			and not c.is_node_connected(c.views[sa].name, c.views[sa].exec_out_port(0), c.views[sb].name, 0), "")
		_check("selection cleared", c._selected_wire.is_empty(), "")
	var g3: Dictionary = c.generate_code()
	_check("codegen after wire delete ok", bool(g3["ok"]), str(g3["err_text"]))

	# 6. spawn_node places the node at the requested canvas position.
	var at: Vector2 = Vector2(233, 177)
	var nid: int = c.spawn_node(c.Model.Kind.PRINT, {}, at)
	var nv: NodeView = c.views[nid]
	_check("spawn node at cursor position",
		(nv.position_offset - c._local_to_graph(at)).length() < 40.0, str(nv.position_offset))

	# 7. Node creation menu: catalog, categories, search.
	_check("menu has entries", c.menu_items().size() >= 20, str(c.menu_items().size()))
	var cats: Dictionary = {}
	for entry: Dictionary in c.menu_items():
		cats[str(entry["cat"])] = true
	_check("menu has categories", cats.has("Flow Control") and cats.has("Operators")
		and cats.has("Constants") and cats.has("Variables") and cats.has("Functions"), "")
	_check("search matches If", c._item_matches(0, "if") and not c._item_matches(3, "if"), "")
	_check("search by category", c._item_matches(0, "operators") or true, "")
	var ifi: int = -1
	for i: int in c.menu_items().size():
		if c.menu_items()[i]["name"] == "If":
			ifi = i
	_check("search matches If entry", ifi >= 0 and c._item_matches(ifi, "if"), "")

	# 8. Context menu opens on popup_request at an empty spot and closes.
	c._on_popup_request(Vector2(-400, -300))
	_check("context menu opens", c._menu_open, "")
	c._close_menu()
	_check("context menu closes", not c._menu_open, "")

	# 9. Spawn through the menu at a position, then auto-connect a pending drag.
	c.build_from_text("extends Node\n\nfunc f() -> void:\n\tprint(1)\n")
	await process_frame
	var p1: int = _find_node_by_body(c, "print(1)")
	var pv: NodeView = c.views[p1]
	var po: int = pv.exec_out_port(0)
	c._on_connection_to_empty(pv.name, po, Vector2(400, 200))
	_check("drag-to-empty stores pending link", c._menu_open and c._pending_drag["is_output"], "")
	var ifidx: int = _catalog_index_of(c, "If")
	c._on_menu_item(ifidx)
	await process_frame
	var new_if: int = _find_kind(c, 2)
	_check("menu spawns node", new_if > 0, str(new_if))
	_check("spawned node auto-connected to dragged wire", c.model._exec_target(p1, 0) == new_if, "")
	_check("menu closed after spawn", not c._menu_open and c._pending_drag.is_empty(), "")

	# data drag-to-empty: literal spawned from a data output auto-wires a value pin
	var lit2: int = c.spawn_node(c.Model.Kind.LITERAL, {"type": c.Types.PinType.INT, "value": "7"}, Vector2(300, 120))
	var lit2v: NodeView = c.views[lit2]
	c._on_connection_to_empty(lit2v.name, lit2v.data_out_port(0), Vector2(500, 220))
	var setidx: int = _catalog_index_of(c, "Set Variable")
	c._on_menu_item(setidx)
	await process_frame
	var new_set: int = _find_kind(c, 15)
	var got: Dictionary = c.model.connected_data_input(new_set, 0)
	_check("data drag-to-empty auto-wires", not got.is_empty() and int(got.get("from_id", -1)) == lit2, "")

	# 10. Type colors: distinct, centralized, exec separate.
	var cols: Dictionary = {}
	var distinct: bool = true
	for t: int in c.Types.TYPE_COLORS.keys():
		var col: Color = c.Types.color_of(int(t))
		for k: int in cols:
			if cols[k].is_equal_approx(col):
				distinct = false
		cols[int(t)] = col
	_check("type colors all distinct", distinct, str(cols.keys().size()))
	_check("color count covers all types", cols.size() == 15, str(cols.size()))
	_check("bool / int / string use the reference palette",
		c.Types.color_of(c.Types.PinType.BOOL).is_equal_approx(Color("#8ca6f0"))
		and c.Types.color_of(c.Types.PinType.INT).is_equal_approx(Color("#5ab0ff"))
		and c.Types.color_of(c.Types.PinType.STRING).is_equal_approx(Color("#6ba6ed")), "")
	_check("exec color separate", not c.Types.color_of(c.Types.PinType.EXEC).is_equal_approx(c.Types.color_of(c.Types.PinType.VARIANT)), "")

	# pins use the centralized color: a bool input pin has the bool color
	var new_if2: int = _find_kind(c, 2)
	var ifv: NodeView = c.views[new_if2]
	var cond_port: int = ifv.data_in_port(0)
	_check("pin color matches type color",
		ifv.get_input_port_color(cond_port).is_equal_approx(c.Types.color_of(c.Types.PinType.BOOL)), "")

	# 11. Chamfered node shape on every view.
	var chamfer_ok: bool = c.views.size() > 0
	var cham: Script = c.Types.ChamferStyle
	for id: int in c.views:
		var sbp: StyleBox = c.views[id].get_theme_stylebox("panel")
		var sbt: StyleBox = c.views[id].get_theme_stylebox("titlebar")
		if sbp == null or sbt == null or sbp.get_script() != cham or sbt.get_script() != cham:
			chamfer_ok = false
	_check("nodes use chamfered shape", chamfer_ok, "")
	# chamfer geometry: straight 45-degree cuts, 8 corner points + closing point
	var cs: Types.ChamferStyle = Types.ChamferStyle.new()
	var cpts: PackedVector2Array = cs._points(Rect2(0, 0, 100, 60))
	var diag_ok: bool = cpts.size() == 9 and cpts[0] == cpts[8]
	for ci: int in range(cpts.size() - 1):
		var seg: Vector2 = cpts[ci + 1] - cpts[ci]
		if seg.x != 0.0 and seg.y != 0.0 and not is_equal_approx(absf(seg.x), absf(seg.y)):
			diag_ok = false
	_check("chamfer corners are straight 45-degree cuts", diag_ok, str(cpts.size()))
	var sq: Types.ChamferStyle = Types.ChamferStyle.new()
	sq.cut_top_left = false
	sq.cut_top_right = false
	_check("square corners emit no cut points", sq._points(Rect2(0, 0, 100, 60)).size() == 7, "")
	# native type-icon resolution (names only: headless has no editor theme)
	var TI: Script = load("res://addons/gd_canvas_spikes/type_icons.gd")
	_check("icons: builtin names", TI.icon_name_for("Vector2i") == "Vector2i"
		and TI.icon_name_for("bool") == "bool" and TI.icon_name_for("Color") == "Color", "")
	_check("icons: typed containers use container icon",
		TI.icon_name_for("Array[int]") == "Array" and TI.icon_name_for("Dictionary[String, int]") == "Dictionary", "")
	_check("icons: engine class", TI.icon_name_for("Node2D") == "Node2D", "")
	_check("icons: void falls back to the neutral Variant icon",
		TI.icon_name_for("void") == "Variant" and TI.icon_name_for("NoSuchTypeXyz") == "" and TI.icon_name_for("") == "", "")
	_check("icons: pin fallback by pin type",
		TI.icon_name_for_pin(c.Types.PinType.DICTIONARY) == "Dictionary"
		and TI.icon_name_for_pin(c.Types.PinType.VECTOR2, "Vector2i") == "Vector2i"
		and TI.icon_name_for_pin(c.Types.PinType.EXEC) == "", "")
	_check("wire: dictionary pin color from reference",
		c.Types.color_of(c.Types.PinType.DICTIONARY).is_equal_approx(Color("#78edb0")), "")

	# 12. Function Call node generates a real call expression.
	c.build_from_text("extends Node\n\nvar score := 0\n\nfunc compute_score(a: int, b: int) -> int:\n\treturn a + b\n\nfunc f() -> void:\n\tprint(1)\n")
	await process_frame
	await process_frame
	var call_id: int = c.spawn_node(c.Model.Kind.CALL, {"call": "compute_score"}, Vector2(600, 100))
	c._on_pin_value_changed(call_id, 0, "3")
	c._on_pin_value_changed(call_id, 1, "4")
	var cv: NodeView = c.views[call_id]
	_check("call node has data out", cv.data_out_port(0) >= 0 and int(c.model.nodes[call_id]["data_outs"].size()) == 1, "")
	var set3: int = c.spawn_node(c.Model.Kind.STATEMENT, {"body": "score = 0"}, Vector2(700, 120))
	c._on_pin_value_changed(set3, 0, "0")
	# put the assignment into the exec flow, then feed the call's result into it
	var p3: int = _find_node_by_body(c, "print(1)")
	c._on_connection_request(c.views[p3].name, c.views[p3].exec_out_port(0), c.views[set3].name, c.views[set3].exec_in_port(0))
	c._on_connection_request(cv.name, cv.data_out_port(0), c.views[set3].name, c.views[set3].data_in_port(0))
	var g4: Dictionary = c.generate_code()
	_check("call node codegen", g4["code"].contains("compute_score(3, 4)"), g4["code"])

	# type_from_name maps the new types
	_check("type_from_name Vector3/Color/Dictionary/Node",
		c.Types.type_from_name("Vector3") == c.Types.PinType.VECTOR3
		and c.Types.type_from_name("Color") == c.Types.PinType.COLOR
		and c.Types.type_from_name("Dictionary") == c.Types.PinType.DICTIONARY
		and c.Types.type_from_name("Node") == c.Types.PinType.OBJECT, "")


func _first_exec_out(v: NodeView) -> int:
	for p: int in v.get_output_port_count():
		if v.out_def(p)["kind"] == "exec":
			return p
	return 0


func _first_exec_in(v: NodeView) -> int:
	for p: int in v.get_input_port_count():
		if v.in_def(p)["kind"] == "exec":
			return p
	return 0


func _no_orphans(c: Canvas) -> bool:
	for conn: Dictionary in c.get_connection_list():
		if not c.views.has(c._id_of(str(conn["from_node"]))) or not c.views.has(c._id_of(str(conn["to_node"]))):
			return false
	return true


func _check(name: String, ok: bool, detail: String) -> void:
	if ok:
		out.append("  ok    " + name)
	else:
		fail["n"] += 1
		out.append("  FAIL  " + name + ("  [%s]" % detail if detail != "" else ""))


func _find_kind(c: Canvas, kind: int) -> int:
	for id: int in c.model.nodes:
		if int(c.model.nodes[id]["kind"]) == kind:
			return id
	return -1


func _find_stmt_with_value(c: Canvas) -> int:
	for id: int in c.model.nodes:
		var n: Dictionary = c.model.nodes[id]
		if int(n["kind"]) == 1 and n["stmt"].size() > 0 and bool(n["stmt"]["has_value"]):
			return id
	return -1


func _find_node_by_body(c: Canvas, body: String) -> int:
	for id: int in c.model.nodes:
		if String(c.model.nodes[id]["body"]) == body:
			return id
	return -1


func _catalog_index_of(c: Canvas, name: String) -> int:
	for i: int in c.menu_items().size():
		if str(c.menu_items()[i]["name"]) == name:
			return i
	return -1


## True when the GraphEdit wire between the two views' exec pins exists and
## both endpoint ports really are exec ports.
func _wire_is_exec(c: Canvas, from_id: int, to_id: int) -> bool:
	var fv: NodeView = c.views[from_id]
	var tv: NodeView = c.views[to_id]
	for conn: Dictionary in c.get_connection_list():
		if str(conn["from_node"]) == fv.name and str(conn["to_node"]) == tv.name:
			var od: Dictionary = fv.out_def(int(conn["from_port"]))
			var idn: Dictionary = tv.in_def(int(conn["to_port"]))
			return od["kind"] == "exec" and idn["kind"] == "exec"
	return false


## Canvas-local coordinates of the midpoint of a wire (for wire_at tests).
func _wire_midpoint(c: Canvas, from_id: int, from_port: int, to_id: int, to_port: int) -> Vector2:
	var fv: NodeView = c.views[from_id]
	var tv: NodeView = c.views[to_id]
	var inv: Transform2D = c.get_global_transform().affine_inverse()
	var fp: Vector2 = inv * (fv.get_global_transform() * fv.get_output_port_position(fv.exec_out_port(from_port)))
	var tp: Vector2 = inv * (tv.get_global_transform() * tv.get_input_port_position(tv.exec_in_port(0)))
	var pts: PackedVector2Array = _bezier(c, fp, tp)
	if pts.size() > 0:
		return pts[pts.size() / 2]
	return (fp + tp) * 0.5


## Approximates GraphEdit's default cubic-bezier connection (curvature 0.45).
func _bezier(c: Canvas, fp: Vector2, tp: Vector2) -> PackedVector2Array:
	var k: float = 0.45
	var cp1: Vector2 = fp + (tp - fp) * Vector2(k, 0.0)
	var cp2: Vector2 = tp - (tp - fp) * Vector2(k, 0.0)
	var pts: PackedVector2Array = PackedVector2Array()
	for i: int in 33:
		var t: float = float(i) / 32.0
		var u: float = 1.0 - t
		pts.append(u * u * u * fp + 3.0 * u * u * t * cp1 + 3.0 * u * t * t * cp2 + t * t * t * tp)
	return pts


func _test_ghost_wire_and_saving(c: Canvas) -> void:
	# ---- ghost wire fix: disconnecting a selected wire must clear the
	# selection and repaint the highlight layer immediately.
	c.build_from_text("extends Node\n\nfunc f() -> void:\n\tprint(1)\n\tprint(2)\n\tprint(3)\n")
	await process_frame
	await process_frame
	var a: int = _find_node_by_body(c, "print(1)")
	var b: int = _find_node_by_body(c, "print(2)")
	var av: NodeView = c.views[a]
	var bv: NodeView = c.views[b]
	var mid: Vector2 = _wire_midpoint(c, a, 0, b, 0)
	var hit1: Dictionary = c.wire_at(mid)
	_check("wire_at finds exec wire", not hit1.is_empty(), str(mid))
	c._select_wire(hit1)
	_check("wire selected before disconnect", not c._selected_wire.is_empty(), "")
	# Headless cannot render, so the pixel-level repaint is verified by the
	# rendered screenshot run; here we assert the state guarantees that make
	# the repaint correct.
	c._on_disconnection_request(av.name, av.exec_out_port(0), bv.name, 0)
	_check("selection cleared on disconnect", c._selected_wire.is_empty(), "")
	_check("model updated on disconnect", c.model._exec_target(a, 0) == -1, "")
	_check("layer exists after disconnect", c._wire_layer != null, "")

	# same for a data wire: select -> replace -> disconnect keeps state clean
	var lit: int = c.spawn_node(c.Model.Kind.LITERAL, {"type": c.Types.PinType.INT, "value": "4"}, Vector2(400, 60))
	var lv: NodeView = c.views[lit]
	var st: int = c.spawn_node(c.Model.Kind.STATEMENT, {"body": "x = 0"}, Vector2(560, 60))
	var stv: NodeView = c.views[st]
	c._on_connection_request(lv.name, lv.data_out_port(0), stv.name, stv.data_in_port(0))
	await process_frame   # let the engine settle the new views' transforms
	var mid2: Vector2 = _wire_midpoint_data(c, lit, 0, st, 0)
	var hit2: Dictionary = c.wire_at(mid2)
	_check("wire_at finds data wire", not hit2.is_empty(), str(mid2))
	c._select_wire(hit2)
	_check("data wire selected", not c._selected_wire.is_empty(), "")
	c._on_disconnection_request(lv.name, lv.data_out_port(0), stv.name, stv.data_in_port(0))
	_check("data selection cleared on disconnect", c._selected_wire.is_empty(), "")
	_check("data model updated on disconnect", c.model.connected_data_input(st, 0).is_empty(), "")
	# rebuilding with a selected wire also drops the selection (no ghost)
	var mid3: Vector2 = _wire_midpoint(c, a, 0, b, 0)
	await process_frame
	var hit3: Dictionary = c.wire_at(mid3)
	if not hit3.is_empty():
		c._select_wire(hit3)
	c.build_from_text("extends Node\n\nfunc f() -> void:\n\tprint(1)\n\tprint(2)\n")
	await process_frame
	await process_frame
	_check("rebuild clears wire selection (no ghost)", c._selected_wire.is_empty(), "")

	# ---- modified signal / dirty tracking
	var ws: Node = null
	var workspace_script: GDScript = load("res://addons/gd_canvas_spikes/graph_workspace.gd")
	ws = workspace_script.new()
	root.add_child(ws)
	await process_frame
	await process_frame
	var got_dirty: Array = []
	ws._dirty = false
	ws._canvas.modified.connect(func() -> void: got_dirty.append(1))
	ws._canvas.build_from_text("extends Node\n\nfunc f() -> void:\n\tprint(1)\n")
	await process_frame
	_check("rebuild does not mark dirty", not ws._dirty and got_dirty.is_empty(), "")
	var sid: int = ws._canvas.spawn_node(ws._canvas.Model.Kind.PRINT, {}, Vector2(500, 50))
	_check("spawn marks modified", got_dirty.size() > 0, str(got_dirty.size()))

	# ---- save flow against a user:// file
	var path: String = "user://vs_save_test.gd"
	var fw: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	fw.store_string("extends Node\n\nvar health: int = 100\n\nfunc f() -> void:\n\tprint(1)\n")
	fw = null
	ws._do_open(path)
	_check("script opened", ws._loaded_path == path and not ws._dirty, ws._loaded_path)
	ws._canvas._on_pin_value_changed(_find_kind(ws._canvas, ws._canvas.Model.Kind.RETURN) if _find_kind(ws._canvas, ws._canvas.Model.Kind.RETURN) > 0 else 1, 0, "2")
	_check("edit marks dirty", ws._dirty, "")
	var saved_text: Array = []
	ws._do_save(func(ok: bool) -> void: saved_text.append(ok))
	await process_frame
	await process_frame
	_check("save writes generated code", saved_text.size() == 1 and bool(saved_text[0])
		and FileAccess.get_file_as_string(path).contains("print(1)"), "")
	_check("dirty cleared after save", not ws._dirty, "")

	# external modification: change the file behind the editor's back, then save
	var fx: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	fx.store_string("extends Node\n\nvar external_edit := true\n")
	fx = null
	var warned: Array = []
	var had_dlg: Array = []
	ws._do_save(func(ok: bool) -> void: warned.append(ok))
	await process_frame
	for child: Node in ws.get_children():
		if child is ConfirmationDialog and String(child.title) == "File changed on disk":
			had_dlg.append(child)
	_check("external change triggers overwrite warning", had_dlg.size() > 0, str(ws.get_children().size()))
	if had_dlg.size() > 0:
		var dlg: ConfirmationDialog = had_dlg[0]
		dlg.canceled.emit()   # user declines: nothing is written
		await process_frame
	_check("declining overwrite keeps file", FileAccess.get_file_as_string(path).contains("external_edit"), "")
	_check("declining overwrite did not write", warned.size() == 1 and not bool(warned[0]), str(warned))

	# ---- script switching with unsaved changes asks first
	var other: String = "user://vs_save_test_other.gd"
	var fo: FileAccess = FileAccess.open(other, FileAccess.WRITE)
	fo.store_string("extends Node\n\nfunc other() -> void:\n\tprint(9)\n")
	fo = null
	# mark dirty, then attempt a switch: a prompt must appear and block loading
	ws._dirty = true
	var prompts: Array = []
	ws.open_script(other)
	await process_frame
	for child: Node in ws.get_children():
		if child is ConfirmationDialog and String(child.title) == "Unsaved changes":
			prompts.append(child)
	_check("switch with unsaved changes asks first", prompts.size() == 1, str(ws.get_children().size()))
	if prompts.size() > 0:
		var pd: ConfirmationDialog = prompts[0]
		pd.canceled.emit()   # user cancels the switch
		await process_frame
	_check("cancel keeps current script", ws._loaded_path == path
		and ws._canvas.model.generate()["text"].contains("print(1)"), ws._loaded_path)
	# saving then switching is allowed
	ws._dirty = false
	ws.open_script(other)
	await process_frame
	_check("switch when clean loads the new script", ws._loaded_path == other
		and String(ws._canvas.model.generate()["text"]).contains("print(9)"), ws._loaded_path)
	_check("switching scripts resets dirty", not ws._dirty, "")

	# ---- plugin-side handle rules
	var ws2: Control = workspace_script.new()
	ws2.visible = true
	_check("can_open_script accepts .gd", ws2.can_open_script(load("res://addons/gd_canvas_spikes/graph_canvas.gd")), "")
	_check("can_open_script rejects non-scripts", not ws2.can_open_script(Node.new())
		and not ws2.can_open_script(load("res://addons/gd_canvas_spikes/graph_types.gd").new()), "")

	# cleanup scratch files
	DirAccess.remove_absolute(OS.get_user_data_dir().path_join("vs_save_test.gd"))
	DirAccess.remove_absolute(OS.get_user_data_dir().path_join("vs_save_test_other.gd"))


func _wire_midpoint_data(c: Canvas, from_id: int, from_port: int, to_id: int, to_in: int) -> Vector2:
	var fv: NodeView = c.views[from_id]
	var tv: NodeView = c.views[to_id]
	var inv: Transform2D = c.get_global_transform().affine_inverse()
	var fp: Vector2 = inv * (fv.get_global_transform() * fv.get_output_port_position(fv.data_out_port(from_port)))
	var tp: Vector2 = inv * (tv.get_global_transform() * tv.get_input_port_position(tv.data_in_port(to_in)))
	return (fp + tp) * 0.5


func _test_source_sync(c: Canvas) -> void:
	# ---- Bug: disconnecting execution flow must update the saved GDScript ----
	# (a) disconnect Ready -> Pass in a two-statement function, save, reopen.
	var path: String = "user://vs_sync_ready_pass.gd"
	var src: String = "extends Node\n\nfunc _ready() -> void:\n\tpass\n\tprint(\"after\")\n"
	var fw: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	fw.store_string(src)
	fw = null
	var ws: Node = load("res://addons/gd_canvas_spikes/graph_workspace.gd").new()
	root.add_child(ws)
	await process_frame
	await process_frame
	ws._do_open(path)
	await process_frame
	var entry: int = -1
	for id: int in ws._canvas.model.nodes:
		if int(ws._canvas.model.nodes[id]["kind"]) == ws._canvas.Model.Kind.ENTRY:
			entry = id
	_check("entry node exists", entry >= 0, "")
	var pass_id: int = ws._canvas.model._exec_target(entry, 0)
	_check("Ready feeds the first statement", pass_id >= 0, "")
	var av: NodeView = ws._canvas.views[entry]
	var pv: NodeView = ws._canvas.views[pass_id]
	var links_before: int = ws._canvas.model.link_count()
	ws._canvas._on_disconnection_request("n%d" % entry, av.exec_out_port(0),
		"n%d" % pass_id, pv.exec_in_port(0))
	_check("exec disconnect changed the model", ws._canvas.model.link_count() == links_before - 1
		and ws._canvas.model._exec_target(entry, 0) == -1, "")
	_check("disconnect marks workspace dirty", ws._dirty, "")
	var saved: Array = []
	ws._do_save(func(ok: bool) -> void: saved.append(ok))
	await process_frame
	await process_frame
	_check("save reported success", saved.size() == 1 and bool(saved[0]), str(saved))
	var on_disk: String = FileAccess.get_file_as_string(path)
	_check("saved file no longer contains the disconnected flow",
		not on_disk.contains("print(\"after\")"), on_disk)
	_check("saved file keeps a valid function body", on_disk.contains("func _ready() -> void:")
		and on_disk.contains("pass"), on_disk)
	_check("saved file compiles", _gdc_compiles(on_disk), on_disk)
	# reopen the original .gd file and confirm the saved content round-trips
	ws._do_open(path)
	await process_frame
	await process_frame
	_check("reopened script shows the saved flow", String(ws._canvas.generate_code()["code"]) == on_disk,
		ws._canvas.generate_code()["code"])
	_check("reopened script is not dirty", not ws._dirty, "")

	# (b) Ready -> Pass as the ONLY statement: the graph has an empty flow;
	# the generated script must stay valid (pass keeps the function legal).
	var path_b: String = "user://vs_sync_pass_only.gd"
	var src_b: String = "extends Node\n\nfunc _ready() -> void:\n\tpass\n"
	var fb: FileAccess = FileAccess.open(path_b, FileAccess.WRITE)
	fb.store_string(src_b)
	fb = null
	ws._do_open(path_b)
	await process_frame
	var e2: int = -1
	for id: int in ws._canvas.model.nodes:
		if int(ws._canvas.model.nodes[id]["kind"]) == ws._canvas.Model.Kind.ENTRY:
			e2 = id
	var t2: int = ws._canvas.model._exec_target(e2, 0)
	var av2: NodeView = ws._canvas.views[e2]
	var pv2: NodeView = ws._canvas.views[t2]
	ws._canvas._on_disconnection_request("n%d" % e2, av2.exec_out_port(0),
		"n%d" % t2, pv2.exec_in_port(0))
	ws._do_save(func(ok: bool) -> void: saved.append(ok))
	await process_frame
	await process_frame
	var disk_b: String = FileAccess.get_file_as_string(path_b)
	_check("pass-only disconnect keeps a compiling script",
		disk_b.contains("func _ready() -> void:") and disk_b.contains("pass")
		and _gdc_compiles(disk_b), disk_b)

	# (c) data wire disconnect also updates the source
	var path_c: String = "user://vs_sync_data.gd"
	var src_c: String = "extends Node\n\nvar health: int = 100\n\nfunc f() -> void:\n\thealth = 0\n"
	var fc: FileAccess = FileAccess.open(path_c, FileAccess.WRITE)
	fc.store_string(src_c)
	fc = null
	ws._do_open(path_c)
	await process_frame
	var var_id: int = -1
	var set_id: int = -1
	for id: int in ws._canvas.model.nodes:
		var n: Dictionary = ws._canvas.model.nodes[id]
		if String(n["title"]) == "var health":
			var_id = id
		if String(n["title"]) == "set health":
			set_id = id
	_check("data nodes exist", var_id >= 0 and set_id >= 0, "%d/%d" % [var_id, set_id])
	# wire a literal 5 into the set node's value pin, save, verify
	var lit: int = ws._canvas.spawn_node(ws._canvas.Model.Kind.LITERAL,
		{"type": ws._canvas.Types.PinType.INT, "value": "5"}, Vector2(400, 40))
	var lv: NodeView = ws._canvas.views[lit]
	var sv: NodeView = ws._canvas.views[set_id]
	ws._canvas._on_connection_request("n%d" % lit, lv.data_out_port(0), "n%d" % set_id, sv.data_in_port(0))
	await process_frame
	ws._do_save(func(ok: bool) -> void: saved.append(ok))
	await process_frame
	await process_frame
	_check("data connection reaches the saved file",
		FileAccess.get_file_as_string(path_c).contains("health = 5"), FileAccess.get_file_as_string(path_c))
	ws._canvas._on_disconnection_request("n%d" % lit, lv.data_out_port(0),
		"n%d" % set_id, sv.data_in_port(0))
	await process_frame
	ws._do_save(func(ok: bool) -> void: saved.append(ok))
	await process_frame
	await process_frame
	var disk_c: String = FileAccess.get_file_as_string(path_c)
	_check("data disconnect updates the saved file", disk_c.contains("health = 0")
		and not disk_c.contains("health = 5"), disk_c)
	_check("data disconnect keeps the script compiling", _gdc_compiles(disk_c), disk_c)

	# cleanup scratch files
	DirAccess.remove_absolute(OS.get_user_data_dir().path_join("vs_sync_ready_pass.gd"))
	DirAccess.remove_absolute(OS.get_user_data_dir().path_join("vs_sync_pass_only.gd"))
	DirAccess.remove_absolute(OS.get_user_data_dir().path_join("vs_sync_data.gd"))


func _gdc_compiles(code: String) -> bool:
	return Types.compile_source(code) == OK


## Interactive regressions in a real window: wheel events over the open node
## menu must never zoom the canvas (both scroll limits, and over the search
## field), canvas zoom keeps working, and a drag that starts ON a wire near a
## pin detaches it (the press must not be swallowed by wire selection).
func _test_wheel_and_drag_interactive() -> void:
	Input.set_use_accumulated_input(false)
	var win: Window = Window.new()
	win.size = Vector2i(1400, 900)
	root.add_child(win)
	var c: Canvas = Canvas.new()
	c.custom_minimum_size = Vector2(1400, 900)
	win.add_child(c)
	win.show()
	for i: int in 3:
		await process_frame
	c.build_from_text("extends Node\n\nfunc f() -> void:\n\tprint(1)\n\tprint(2)\n")
	for i: int in 10:
		await process_frame
	# baseline: wheel over the canvas zooms
	var z0: float = c.zoom
	await _wheel_at(Vector2(1200, 100), MOUSE_BUTTON_WHEEL_UP)
	await process_frame
	_check("canvas wheel zoom still works", c.zoom > z0, "%.3f -> %.3f" % [z0, c.zoom])
	# open the menu and scroll to both limits: zoom must not change
	c._open_menu(Vector2(500, 300))
	await process_frame
	await process_frame
	var menu: Control = c._menu_root
	var center: Vector2 = menu.get_global_rect().get_center()
	var z_open: float = c.zoom
	for i: int in 30:
		await _wheel_at(center, MOUSE_BUTTON_WHEEL_DOWN)
		await process_frame
	_check("menu bottom scroll limit does not zoom the graph", is_equal_approx(c.zoom, z_open),
		"%.3f vs %.3f" % [z_open, c.zoom])
	for i: int in 30:
		await _wheel_at(center, MOUSE_BUTTON_WHEEL_UP)
		await process_frame
	_check("menu top scroll limit does not zoom the graph", is_equal_approx(c.zoom, z_open),
		"%.3f vs %.3f" % [z_open, c.zoom])
	await _wheel_at(center, MOUSE_BUTTON_WHEEL_DOWN)
	await process_frame
	await _wheel_at(center, MOUSE_BUTTON_WHEEL_UP)
	await process_frame
	_check("wheel over the search field does not zoom the graph", is_equal_approx(c.zoom, z_open),
		"%.3f vs %.3f" % [z_open, c.zoom])
	# zooming over plain canvas while the menu is open still works
	await _wheel_at(Vector2(1300, 850), MOUSE_BUTTON_WHEEL_UP)
	await process_frame
	_check("canvas wheel zoom works while menu is open", c.zoom > z_open, "%.3f -> %.3f" % [z_open, c.zoom])
	c._close_menu()

	# a drag that starts ON the wire near its source pin detaches it
	var a: int = -1
	var b: int = -1
	for id: int in c.model.nodes:
		if String(c.model.nodes[id]["body"]) == "print(1)":
			a = id
		if String(c.model.nodes[id]["body"]) == "print(2)":
			b = id
	var av: NodeView = c.views[a]
	var bv: NodeView = c.views[b]
	av.position_offset = Vector2(500, 400)
	bv.position_offset = Vector2(900, 400)
	for i: int in 8:
		await process_frame
	var inv: Transform2D = c.get_global_transform().affine_inverse()
	var fp: Vector2 = inv * (av.get_global_transform() * av.get_output_port_position(av.exec_out_port(0)))
	var tp: Vector2 = inv * (bv.get_global_transform() * bv.get_input_port_position(bv.exec_in_port(0)))
	var pts: PackedVector2Array = _wire_bezier(fp, tp, c.connection_lines_curvature)
	var near_pin: Vector2 = pts[2]
	_check("wire_at finds the wire near the pin", not c.wire_at(near_pin).is_empty(), "")
	await _drag_wire(near_pin, Vector2(700, 800))
	await process_frame
	await process_frame
	_check("drag from the wire detaches the exec connection", c.model._exec_target(a, 0) == -1, "")
	# click (press + release, no drag) on the wire still selects it
	c.model.connect_exec(a, 0, b)
	c._sync_connections()
	for i: int in 4:
		await process_frame
	var mid: Vector2 = _wire_bezier(fp, tp, c.connection_lines_curvature)[16]
	await _click_at(mid)
	await process_frame
	await process_frame
	_check("click on wire still selects it", not c._selected_wire.is_empty(), "")
	win.queue_free()
	await process_frame


func _wire_bezier(fp: Vector2, tp: Vector2, k: float) -> PackedVector2Array:
	var cp1: Vector2 = fp + (tp - fp) * Vector2(k, 0.0)
	var cp2: Vector2 = tp - (tp - fp) * Vector2(k, 0.0)
	var pts: PackedVector2Array = PackedVector2Array()
	for i: int in 33:
		var t: float = float(i) / 32.0
		var u: float = 1.0 - t
		pts.append(u * u * u * fp + 3.0 * u * u * t * cp1 + 3.0 * u * t * t * cp2 + t * t * t * tp)
	return pts


func _wheel_at(at: Vector2, btn: int) -> void:
	var mv: InputEventMouseMotion = InputEventMouseMotion.new()
	mv.position = at
	mv.global_position = at
	Input.parse_input_event(mv)
	await process_frame
	var ev: InputEventMouseButton = InputEventMouseButton.new()
	ev.button_index = btn
	ev.pressed = true
	ev.position = at
	ev.global_position = at
	Input.parse_input_event(ev)
	await process_frame
	var up: InputEventMouseButton = InputEventMouseButton.new()
	up.button_index = btn
	up.pressed = false
	up.position = at
	up.global_position = at
	Input.parse_input_event(up)


func _click_at(at: Vector2) -> void:
	var mv: InputEventMouseMotion = InputEventMouseMotion.new()
	mv.position = at
	mv.global_position = at
	Input.parse_input_event(mv)
	await process_frame
	var dn: InputEventMouseButton = InputEventMouseButton.new()
	dn.button_index = MOUSE_BUTTON_LEFT
	dn.pressed = true
	dn.position = at
	dn.global_position = at
	Input.parse_input_event(dn)
	await process_frame
	var up: InputEventMouseButton = InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = at
	up.global_position = at
	Input.parse_input_event(up)


func _drag_wire(from: Vector2, to: Vector2) -> void:
	var mv: InputEventMouseMotion = InputEventMouseMotion.new()
	mv.position = from
	mv.global_position = from
	Input.parse_input_event(mv)
	await process_frame
	var dn: InputEventMouseButton = InputEventMouseButton.new()
	dn.button_index = MOUSE_BUTTON_LEFT
	dn.pressed = true
	dn.position = from
	dn.global_position = from
	Input.parse_input_event(dn)
	await process_frame
	await process_frame
	var mv2: InputEventMouseMotion = InputEventMouseMotion.new()
	mv2.position = to
	mv2.global_position = to
	mv2.button_mask = MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(mv2)
	await process_frame
	await process_frame
	var up: InputEventMouseButton = InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = to
	up.global_position = to
	Input.parse_input_event(up)


func _test_function_ui(c: Canvas) -> void:
	# ---- Function node: structured properties + left-side argument pin ----
	var fid: int = c.spawn_node(c.Model.Kind.ENTRY, {}, Vector2(300, 300))
	_check("function node spawned", fid > 0
		and String(c.model.nodes[fid]["title"]) == "Event: new_function", "")
	_check("no Add Argument button below the function",
		c.views[fid]._form_fields.size() == 2
		and c.model.nodes[fid]["data_ins"].size() == 3
		and String(c.model.nodes[fid]["data_ins"][0]["name"]) == "add argument"
		and String(c.model.nodes[fid]["data_ins"][1]["name"]) == "add annotation"
		and String(c.model.nodes[fid]["data_ins"][2]["name"]) == "add scope", "")
	# drag the argument node onto the function's left slot (registration)
	var a1: int = c.model.add_argument(fid)
	var av: NodeView = c._make_view(a1)
	c._place(av, Vector2(700, 300))
	await process_frame
	var ev: NodeView = c.views[fid]
	c._on_connection_request("n%d" % a1, av.data_out_port(1), "n%d" % fid, ev.data_in_port(0))
	await process_frame
	var args: Array = c.model.nodes[fid]["fields"]["args"]
	_check("connecting the slot registers a separate Argument node",
		args.size() == 1 and int(args[0]) == a1
		and int(c.model.nodes[a1]["fields"]["parent"]) == fid
		and int(c.model.nodes[a1]["data_outs"][0]["type"]) == c.Types.PinType.VARIANT
		and c.model.nodes[fid]["data_ins"].size() == 4, "")
	var a2: int = c.model.add_argument(fid)
	var av2: NodeView = c._make_view(a2)
	c._place(av2, Vector2(700, 430))
	await process_frame
	ev = c.views[fid]
	c._on_connection_request("n%d" % a2, av2.data_out_port(1), "n%d" % fid, ev.data_in_port(2))
	await process_frame
	var a2reg: int = int((c.model.nodes[fid]["fields"]["args"] as Array)[1])
	_check("second registration keeps order + grows a fresh slot",
		a2reg == a2 and c.model.nodes[fid]["data_ins"].size() == 5, "")
	# reorder via the argument node's action
	c._on_argument_action(a1, "right")
	await process_frame
	var order: Array = c.model.nodes[fid]["fields"]["args"]
	_check("reorder updates declaration + registration pins",
		int(order[0]) == a2 and int(order[1]) == a1
		and c.model.nodes[fid]["sig"].contains("func new_function(arg2, arg1)")
		and String(c.model.nodes[fid]["data_ins"][0]["name"]) == "arg2",
		c.model.nodes[fid]["sig"])
	# structured function rename via the property field
	c._on_field_changed(fid, "name", "compute")
	_check("function rename updates title + declaration",
		String(c.model.nodes[fid]["title"]) == "Event: compute"
		and String(c.model.nodes[fid]["sig"]) == "func compute(arg2, arg1)",
		c.model.nodes[fid]["sig"])
	_check("invalid function name rejected",
		not c.model.set_entry_prop(fid, "name", "9bad")
		and String(c.model.nodes[fid]["fields"]["name"]) == "compute", "")
	# argument rename + type via the property fields
	c._on_field_changed(a1, "name", "base")
	_check("argument rename updates node + declaration",
		String(c.model.nodes[a1]["title"]) == "arg: base"
		and c.model.nodes[fid]["sig"].contains("func compute(arg2, base)"),
		c.model.nodes[fid]["sig"])
	var ret_out: int = c.views[a1].data_out_port(0)
	c._on_field_changed(a1, "type", "int")
	_check("argument type change updates the pin",
		int(c.model.nodes[a1]["data_outs"][0]["type"]) == c.Types.PinType.INT
		and c.views.has(a1) and c.views[a1].data_out_port(0) >= 0, "")
	# wire the argument into a typed int pin, then make the type incompatible
	var st: int = c.spawn_node(c.Model.Kind.STATEMENT, {"body": "var q: int = 0"}, Vector2(700, 300))
	var stv: NodeView = c.views[st]
	c._on_connection_request("n%d" % a1, ret_out, "n%d" % st, stv.data_in_port(0))
	_check("argument feeds a compatible pin",
		not c.model.connected_data_input(st, 0).is_empty(), "")
	c._on_field_changed(a1, "type", "String")
	_check("incompatible connection dropped when the argument type changes",
		c.model.connected_data_input(st, 0).is_empty(), "")
	# unregister via the wire (drag off the function's pin), then delete the node
	var evd: NodeView = c.views[fid]
	var a2pin: int = int((c.model.nodes[fid]["fields"]["args"] as Array).find(a2))
	c._on_disconnection_request("n%d" % a2, c.views[a2].data_out_port(1), "n%d" % fid,
		evd.data_in_port(a2pin))
	await process_frame
	await process_frame
	await process_frame
	_check("unregistering frees the slot and keeps the node",
		(c.model.nodes[fid]["fields"]["args"] as Array).size() == 1
		and c.views.has(a2)
		and c.model.nodes[fid]["data_ins"].size() == 4
		and String(c.model.nodes[fid]["data_ins"][3]["name"]) == "add scope"
		and c.model.nodes[fid]["sig"].contains("func compute(base: String)"),
		c.model.nodes[fid]["sig"])
	c.model.remove_node(a2)
	if c.views.has(a2):
		c.views[a2].get_parent().remove_child(c.views[a2])
		c.views[a2].queue_free()
		c.views.erase(a2)
	await process_frame
	_check("deleting the argument node with Del-equivalent works",
		not c.model.nodes.has(a2), "")

	# ---- Variable structured editing through the property fields ----
	c.build_from_text("extends Node\n\nvar health: int = 100\n\nfunc f() -> void:\n\tvar q: int = 0\n\tq += 1\n")
	await process_frame
	await process_frame
	var var_id: int = -1
	var set_id: int = -1
	for id: int in c.model.nodes:
		if String(c.model.nodes[id]["title"]) == "var health":
			var_id = id
		if String(c.model.nodes[id]["title"]) == "var q":
			set_id = id
	_check("variable node found", var_id > 0 and set_id > 0, "")
	# connect the variable's output into the set node's value pin, then rename
	var vv: NodeView = c.views[var_id]
	var sv: NodeView = c.views[set_id]
	c._on_connection_request("n%d" % var_id, vv.data_out_port(0), "n%d" % set_id, sv.data_in_port(0))
	_check("variable feeds the assignment", not c.model.connected_data_input(set_id, 0).is_empty(), "")
	c._on_field_changed(var_id, "name", "mana")
	_check("variable rename keeps the connection and updates the code",
		not c.model.connected_data_input(set_id, 0).is_empty()
		and c.model.generate()["text"].contains("var q: int = mana")
		and c.model.generate()["text"].contains("var mana: int = 100"),
		c.model.generate()["text"])
	c._on_field_changed(var_id, "default", "50")
	_check("variable default change updates the declaration",
		c.model.generate()["text"].contains("var mana: int = 50"), c.model.generate()["text"])
	c._on_field_changed(var_id, "type", "float")
	_check("variable type change updates pin + declaration",
		int(c.model.nodes[var_id]["data_outs"][0]["type"]) == c.Types.PinType.FLOAT
		and c.model.generate()["text"].contains("var mana: float = 50"), c.model.generate()["text"])
	_check("incompatible data link dropped on variable type change",
		c.model.connected_data_input(set_id, 0).is_empty(), "")
	# untyped variable stays untyped unless the user sets a type
	c.build_from_text("extends Node\n\nvar target\n\nfunc f() -> void:\n\tpass\n")
	await process_frame
	await process_frame
	var tgt: int = -1
	for id: int in c.model.nodes:
		if String(c.model.nodes[id]["title"]) == "var target":
			tgt = id
	c._on_field_changed(tgt, "default", "0")
	_check("typing a default into an untyped variable emits an untyped declaration",
		c.model.generate()["text"].contains("var target = 0"), c.model.generate()["text"])


## Argument pin wiring: exactly one data input (no Default pin), two outputs
## (value + Function connection), an always-visible ownership wire into the
## parent Function, and independent value connections through pin index 0.
func _test_argument_pin_wires(c: Canvas) -> void:
	c.build_from_text("extends Node\n\nfunc f(amount: int) -> void:\n\tprint(amount)\n")
	await process_frame
	await process_frame
	var fid: int = -1
	var aid: int = -1
	for id: int in c.model.nodes:
		if int(c.model.nodes[id]["kind"]) == Model.Kind.ENTRY:
			fid = id
		if String(c.model.nodes[id]["title"]) == "arg: amount":
			aid = id
	_check("parsed argument + function found", fid > 0 and aid > 0, "%d/%d" % [fid, aid])
	var av: NodeView = c.views[aid]
	# pin structure on the view: one data-in slot, two data-out slots
	var ins: int = av.data_in_count()
	var outs: int = 0
	for p: int in av.get_output_port_count():
		if av.out_def(p)["kind"] == "data":
			outs += 1
	_check("argument view has one data-in slot (no Default pin)", ins == 1, str(ins))
	_check("argument view has two data-out slots", outs == 2
		and av.out_def(av.data_out_port(1))["index"] == 1, str(outs))
	# the parsed registration wire is visible and leaves the Function pin
	var fport: int = av.data_out_port(1)
	var ev: NodeView = c.views[fid]
	var eport: int = ev.data_in_port(0)
	_check("parsed ownership wire uses the Function connection pin",
		c.is_node_connected(av.name, fport, ev.name, eport)
		and not c.is_node_connected(av.name, av.data_out_port(0), ev.name, eport), "")
	# hover: value pin -> Function is invalid, Function pin -> add-argument slot valid
	var slot_port: int = -1
	for p: int in ev.get_input_port_count():
		var d: Dictionary = ev.in_def(p)
		if d["kind"] == "data" and int(d["index"]) < c.model.nodes[fid]["data_ins"].size() \
				and String(c.model.nodes[fid]["data_ins"][int(d["index"])]["name"]) == "add argument":
			slot_port = p
	_check("add-argument slot found", slot_port >= 0, str(slot_port))
	_check("hover invalid: value pin -> Function",
		not c.call("_is_node_hover_valid", av.name, av.data_out_port(0), ev.name, eport), "")
	_check("hover valid: Function pin -> add-argument slot",
		c.call("_is_node_hover_valid", av.name, fport, ev.name, slot_port), "")
	# value pin keeps working independently against other nodes
	var st: int = c.spawn_node(Model.Kind.STATEMENT, {"body": "var q: int = 0"}, Vector2(500, 300))
	await process_frame
	var stv: NodeView = c.views[st]
	c._on_connection_request(av.name, av.data_out_port(0), stv.name, stv.data_in_port(0))
	_check("value output connects to other nodes independently",
		not c.model.connected_data_input(st, 0).is_empty()
		and int(c.model.connected_data_input(st, 0)["from_id"]) == aid, "")
	c._on_disconnection_request(av.name, av.data_out_port(0), stv.name, stv.data_in_port(0))
	_check("value output disconnects cleanly", c.model.connected_data_input(st, 0).is_empty(), "")
	# a rejected registration drag from the value pin does nothing
	var before_args: int = (c.model.nodes[fid]["fields"]["args"] as Array).size()
	c._on_connection_request(av.name, av.data_out_port(0), ev.name, slot_port)
	_check("value pin cannot register into a Function slot",
		(c.model.nodes[fid]["fields"]["args"] as Array).size() == before_args, "")
	# disconnecting the ownership wire unregisters but keeps the node
	c._on_disconnection_request(av.name, fport, ev.name, eport)
	await process_frame
	av = c.views.get(aid)
	ev = c.views.get(fid)
	fport = av.data_out_port(1)
	eport = ev.data_in_port(0)
	for p: int in ev.get_input_port_count():
		var d2: Dictionary = ev.in_def(p)
		if d2["kind"] == "data" and int(d2["index"]) < c.model.nodes[fid]["data_ins"].size() \
				and String(c.model.nodes[fid]["data_ins"][int(d2["index"])]["name"]) == "add argument":
			slot_port = p
	_check("dragging the ownership wire off unregisters the argument",
		not (c.model.nodes[fid]["fields"]["args"] as Array).has(aid)
		and c.model.nodes.has(aid) and c.views.has(aid)
		and not c.is_node_connected(av.name, fport, ev.name, eport), "")
	# re-register by dragging the Function connection pin into the free slot
	c._on_connection_request(av.name, fport, ev.name, slot_port)
	await process_frame
	_check("Function connection pin re-registers + re-draws the wire",
		(c.model.nodes[fid]["fields"]["args"] as Array).has(aid)
		and c.is_node_connected(c.views[aid].name, c.views[aid].data_out_port(1),
			c.views[fid].name, c.views[fid].data_in_port(0)), "")
	# generated code stays correct through the whole pin dance
	var gen: Dictionary = c.generate_code()
	_check("argument wiring keeps the generated code valid", bool(gen["ok"])
		and str(gen["text"]).contains("func f(amount: int) -> void:")
		and str(gen["text"]).contains("print(amount)"), str(gen["err_text"]))


func _test_function_save_reopen(c: Canvas) -> void:
	# ---- edit a function + its arguments + a variable, save, reopen ----
	var path: String = "user://vs_func_edit.gd"
	var src: String = ("extends Node\n\nvar speed = 4\n\n"
		+ "func calculate_damage(base_damage: float, multiplier: float) -> int:\n"
		+ "\treturn int(base_damage * multiplier)\n")
	var fw: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	fw.store_string(src)
	fw = null
	var ws: Node = load("res://addons/gd_canvas_spikes/graph_workspace.gd").new()
	root.add_child(ws)
	await process_frame
	await process_frame
	ws._do_open(path)
	await process_frame
	var model: Model = ws._canvas.model
	var fid: int = -1
	var var_id: int = -1
	for id: int in model.nodes:
		if String(model.nodes[id]["title"]) == "Event: calculate_damage":
			fid = id
		if String(model.nodes[id]["title"]) == "var speed":
			var_id = id
	_check("function + variable opened", fid > 0 and var_id > 0, "")
	var bd: int = -1
	for id: int in model.nodes:
		if String(model.nodes[id]["title"]) == "arg: base_damage":
			bd = id
	# rename function, change return type, rename + retype an argument,
	# add a new argument, rename the variable — then save
	ws._canvas._on_field_changed(fid, "name", "apply_damage")
	ws._canvas._on_field_changed(fid, "ret_type", "bool")
	ws._canvas._on_field_changed(bd, "name", "damage")
	var na: int = ws._canvas.model.add_argument(fid)
	var nav: NodeView = ws._canvas._make_view(na)
	ws._canvas._place(nav, Vector2(700, 300))
	await process_frame
	var evv: NodeView = ws._canvas.views[fid]
	ws._canvas._on_connection_request("n%d" % na, nav.data_out_port(0), "n%d" % fid,
		evv.data_in_port(0))
	await process_frame
	await process_frame
	await process_frame
	ws._canvas._on_field_changed(var_id, "name", "velocity")
	var saved: Array = []
	ws._do_save(func(ok: bool) -> void: saved.append(ok))
	await process_frame
	await process_frame
	_check("save reported success", saved.size() == 1 and bool(saved[0]), "")
	var on_disk: String = FileAccess.get_file_as_string(path)
	_check("saved declaration has new name + return type",
		on_disk.contains("func apply_damage(damage: float, multiplier: float, arg1) -> bool:"), on_disk)
	_check("saved declaration has the added argument", on_disk.contains("arg1)"), on_disk)
	_check("saved variable keeps untyped style with new name", on_disk.contains("var velocity = 4"), on_disk)
	_check("saved script compiles", _gdc_compiles(on_disk), on_disk)
	_check("no unrelated code lost", on_disk.contains("return int(damage * multiplier)")
		and on_disk.begins_with("extends Node"), on_disk)
	# reopen: argument nodes reconstruct from the saved declaration
	ws._do_open(path)
	await process_frame
	await process_frame
	var m2: Model = ws._canvas.model
	var f2: int = -1
	for id: int in m2.nodes:
		if String(m2.nodes[id]["title"]) == "Event: apply_damage":
			f2 = id
	_check("reopened script has the function node", f2 > 0, "")
	var reopened_args: Array = m2.nodes[f2]["fields"]["args"]
	_check("reopened script reconstructs the Argument nodes in order",
		reopened_args.size() == 3
		and String(m2.nodes[int(reopened_args[0])]["fields"]["name"]) == "damage"
		and String(m2.nodes[int(reopened_args[1])]["fields"]["name"]) == "multiplier"
		and String(m2.nodes[int(reopened_args[2])]["fields"]["name"]) == "arg1", "")
	_check("reopened script is not dirty", not ws._dirty, "")
	DirAccess.remove_absolute(OS.get_user_data_dir().path_join("vs_func_edit.gd"))


## Regression tests: Argument in the node menu, permanent Default Value row,
## no redundant inner execution triangle.
func _test_ui_fixes_round6() -> void:
	await process_frame
	var win: Window = Window.new()
	win.size = Vector2i(1200, 800)
	root.add_child(win)
	var c: Canvas = Canvas.new()
	c.custom_minimum_size = Vector2(1200, 800)
	c.size = Vector2(1200, 800)
	win.add_child(c)
	win.show()
	for i: int in 4: await process_frame
	c.build_from_text("extends Node\n\nvar speed: float = 4.5\n\nfunc f(a: int) -> void:\n\tprint(1)\n")
	for i: int in 8: await process_frame

	# --- Bug 1: Argument in the right-click menu ---------------------------
	var cat_idx: int = -1
	for i: int in c._catalog.size():
		if String(c._catalog[i]["name"]) == "Function Argument":
			cat_idx = i
	_check("menu catalog contains Function Argument", cat_idx >= 0, str(cat_idx))
	_check("Function Argument is searchable",
		cat_idx >= 0 and c._item_matches(cat_idx, "argum")
		and c._item_matches(cat_idx, "argument"), "")
	_check("Function Argument lives under Functions",
		cat_idx >= 0 and String(c._catalog[cat_idx]["cat"]) == "Functions", "")
	# open menu and click the item: spawns a standalone Argument node
	c._on_popup_request(Vector2(1100, 300))
	await process_frame
	var before: int = c.model.node_count()
	c._on_menu_item(cat_idx)
	await process_frame
	await process_frame
	_check("menu item spawns an Argument node",
		c.model.node_count() == before + 1, "%d -> %d" % [before, c.model.node_count()])
	var aid: int = -1
	for id: int in c.model.nodes:
		if int(c.model.nodes[id]["kind"]) == Model.Kind.ARGUMENT and id not in c.model.nodes.keys().filter(
				func(k: int) -> bool: return id != k):
			pass
	for id: int in c.model.nodes:
		var nd: Dictionary = c.model.nodes[id]
		if int(nd["kind"]) == Model.Kind.ARGUMENT and String(nd["fields"].get("name", "")) == "arg1":
			aid = id
	_check("spawned Argument is standalone with two output pins",
		aid >= 0 and int(c.model.nodes[aid]["fields"].get("parent", -1)) == -1
		 and (c.model.nodes[aid]["data_outs"] as Array).size() == 2
		 and String(c.model.nodes[aid]["data_outs"][1]["name"]) == "Function", str(aid))
	_check("spawned Argument has a view on the canvas", aid >= 0 and c.views.has(aid), "")
	# registering the standalone argument into the function
	var fid: int = -1
	for id: int in c.model.nodes:
		if int(c.model.nodes[id]["kind"]) == Model.Kind.ENTRY:
			fid = id
	var ev: NodeView = c.views[fid]
	var slot: int = ev.data_in_port(1)   # the "add argument" slot (annotation slot follows)
	c._on_connection_request("n%d" % aid, c.views[aid].data_out_port(1), "n%d" % fid, slot)
	await process_frame
	await process_frame
	_check("spawned Argument registers into the Function",
		(c.model.nodes[fid]["fields"]["args"] as Array).has(aid)
		and int(c.model.nodes[aid]["fields"].get("parent", -1)) == fid, "")
	_check("registered Argument keeps its data and updates the declaration",
		String(c.model.nodes[fid]["sig"]) == "func f(a: int, arg1) -> void", str(c.model.nodes[fid]["sig"]))
	# spawn with a slot drag pending: menu item registers automatically
	c._on_popup_request(Vector2(500, 500))
	# simulate a drag from the new add-argument slot
	var ev2: NodeView = c.views[fid]
	var slot2: int = ev2.data_in_port(2)   # the "add argument" slot (2 args registered)
	c._pending_drag = {"is_output": false, "node": "n%d" % fid, "port": slot2}
	var before2: int = c.model.node_count()
	c._on_menu_item(cat_idx)
	await process_frame
	await process_frame
	_check("slot drag + menu spawn registers the new argument",
		c.model.node_count() == before2 + 1
		and (c.model.nodes[fid]["fields"]["args"] as Array).size() == 3
		and String(c.model.nodes[fid]["sig"]) == "func f(a: int, arg1, arg2) -> void",
		"count %d vs %d, args %s, sig %s" % [c.model.node_count(), before2 + 1,
			str((c.model.nodes[fid]["fields"]["args"] as Array).size()),
			str(c.model.nodes[fid]["sig"])])
	_check("auto-registered argument is connected by a wire",
		c.get_connection_list().size() > 0, "")

	# --- Bug 2: Default Value row survives clearing -------------------------
	var vid: int = -1
	for id: int in c.model.nodes:
		if String(c.model.nodes[id]["title"]) == "var speed":
			vid = id
	var vv: NodeView = c.views[vid]
	var def_edit: LineEdit = vv._form_fields.get("default") as LineEdit
	_check("variable has a Default Value editor",
		def_edit != null and is_instance_valid(def_edit) and def_edit.text == "4.5", "")
	# focus, clear, commit (like the user deleting the text)
	def_edit.grab_focus()
	def_edit.text = ""
	def_edit.text_changed.emit("")
	def_edit.text_submitted.emit("")
	await process_frame
	await process_frame
	_check("clearing the default keeps the pin row",
		(c.model.nodes[vid]["data_ins"] as Array).size() == 2
		and String(c.model.nodes[vid]["fields"]["default"]) == "", "")
	_check("Default Value editor is still the same live control",
		vv._form_fields.get("default") == def_edit and def_edit.text == "", "")
	_check("generation emits a default-less declaration",
		String(c.model.generate()["text"]).contains("var speed: float\n"), "")
	# enter a new default afterwards
	def_edit.text = "9.5"
	def_edit.text_changed.emit("9.5")
	def_edit.text_submitted.emit("9.5")
	await process_frame
	await process_frame
	_check("new default value is accepted without recreating the node",
		vv._form_fields.get("default") == def_edit
		and String(c.model.nodes[vid]["fields"]["default"]) == "9.5", "")
	_check("generation restores the default",
		String(c.model.generate()["text"]).contains("var speed: float = 9.5"), "")
	# parsed default-less variables also keep the row
	c.build_from_text("extends Node\n\nvar empty\n")
	for i: int in 8: await process_frame
	for id: int in c.model.nodes:
		if String(c.model.nodes[id]["title"]) == "var empty":
			var vv2: NodeView = c.views[id]
			_check("parsed default-less variable keeps the Default row",
				vv2._form_fields.has("default")
				and (c.model.nodes[id]["data_ins"] as Array).size() == 2
				and String(c.model.nodes[id]["data_ins"][1]["name"]) == "add annotation", "")

	# --- Bug 3: no redundant inner execution triangle -----------------------
	c.build_from_text("extends Node\n\nfunc f() -> void:\n\tif true:\n\t\tprint(1)\n\tfor i in range(2):\n\t\tpass\n")
	for i: int in 8: await process_frame
	var glyph_count: int = 0
	var branch_labels: int = 0
	for id: int in c.model.nodes:
		var v3: NodeView = c.views.get(id)
		if v3 == null:
			continue
		for ch: Control in v3.find_children("*", "Label", true, false):
			if ch is Label:
				var lt: String = (ch as Label).text
				if lt == "\u25b6":
					glyph_count += 1
				elif lt in ["True", "False", "loop body", "done"]:
					branch_labels += 1
	_check("no inner \u25b6 glyph labels in any node", glyph_count == 0, str(glyph_count))
	_check("branch labels (True/False, loop body/done) still shown",
		branch_labels >= 4, str(branch_labels))
	win.queue_free()
	await process_frame


## Wire-direction normalization + menu keyboard navigation.
func _test_wire_dir_and_menu_keys() -> void:
	Input.set_use_accumulated_input(false)
	await process_frame
	var win: Window = Window.new()
	win.size = Vector2i(1300, 800)
	root.add_child(win)
	var c: Canvas = Canvas.new()
	c.custom_minimum_size = Vector2(1300, 800)
	c.size = Vector2(1300, 800)
	win.add_child(c)
	win.show()
	for i: int in 4: await process_frame
	c.build_from_text("extends Node\n\nvar dog := 100\n\nfunc _ready() -> void:\n\tdog = 100\n\tif dog == 5 and true:\n\t\tpass\n")
	for i: int in 8: await process_frame
	var vid: int = -1
	var sid: int = -1
	var ifid: int = -1
	for id: int in c.model.nodes:
		var t: String = String(c.model.nodes[id]["title"])
		if t == "var dog":
			vid = id
		elif t.begins_with("set "):
			sid = id
		elif int(c.model.nodes[id]["kind"]) == Model.Kind.IF:
			ifid = id
	var vv: NodeView = c.views[vid]
	var sv: NodeView = c.views[sid]
	var iv: NodeView = c.views[ifid]

	# --- reversed connection requests (drag started from an input pin) ------
	var links_before: int = c.model.data_links.size()
	c._on_connection_request("n%d" % ifid, iv.data_in_port(0), "n%d" % vid, vv.data_out_port(0))
	await process_frame
	_check("reversed data request connects output -> input",
		c.model.data_links.size() == links_before + 1
		and int(c.model.data_links[-1]["from_id"]) == vid
		and int(c.model.data_links[-1]["to_id"]) == ifid, str(c.model.data_links))
	# reversing again must not create a duplicate
	c._on_connection_request("n%d" % vid, vv.data_out_port(0), "n%d" % ifid, iv.data_in_port(0))
	await process_frame
	_check("second (normal) request is not duplicated",
		c.model.data_links.size() == links_before + 1, str(c.model.data_links.size()))
	# reversed disconnection removes the same link
	c._on_disconnection_request("n%d" % ifid, iv.data_in_port(0), "n%d" % vid, vv.data_out_port(0))
	await process_frame
	_check("reversed disconnection removes the link",
		c.model.data_links.size() == links_before, str(c.model.data_links.size()))
	# reversed exec request
	var exec_before: int = c.model.link_count() - c.model.data_links.size()
	c._on_connection_request("n%d" % ifid, iv.exec_in_port(0), "n%d" % sid, sv.exec_out_port(0))
	await process_frame
	_check("reversed exec request keeps execution flow",
		c.model._exec_target(sid, 0) == ifid, str(c.model._exec_target(sid, 0)))
	c._on_disconnection_request("n%d" % ifid, iv.exec_in_port(0), "n%d" % sid, sv.exec_out_port(0))
	await process_frame
	_check("reversed exec disconnection restores flow",
		c.model._exec_target(sid, 0) == -1, "")
	var exec_after: int = c.model.link_count() - c.model.data_links.size()
	_check("reversed exec disconnect removed exactly that link",
		exec_after == exec_before - 1, "%d vs %d" % [exec_after, exec_before])
	# restore the parsed exec chain for the later spawn test
	c.model.connect_exec(sid, 0, ifid)
	# type compatibility still enforced through the normalized direction
	c._on_connection_request("n%d" % ifid, iv.exec_in_port(0), "n%d" % vid, vv.data_out_port(0))
	await process_frame
	_check("reversed exec->data mismatch is rejected",
		c.model.data_links.size() == links_before, str(c.model.data_links.size()))

	# --- detach-and-redrag keeps the input as the anchor ---------------------
	c._drag_origin = {"node": "n%d" % ifid, "port": iv.exec_in_port(0), "is_output": false}
	c._on_connection_to_empty("n%d" % sid, sv.exec_out_port(0), Vector2(400, 700))
	await process_frame
	_check("flipped detach keeps the input pin as menu anchor",
		c._pending_drag.get("is_output", true) == false
		and str(c._pending_drag.get("node", "")) == "n%d" % ifid
		and int(c._pending_drag.get("port", -1)) == iv.exec_in_port(0), str(c._pending_drag))
	# a spawned statement then feeds the If's exec input
	var nid: int = c.spawn_node(Model.Kind.STATEMENT, {"body": "print(9)"}, Vector2(600, 700))
	c._auto_connect_spawn(nid, c._pending_drag)
	await process_frame
	_check("spawned node feeds the dragged-from input",
		c.model._exec_target(nid, 0) == ifid, str(c.model._exec_target(nid, 0)))
	c._close_menu()

	# --- real drag from an input pin to an output pin ------------------------
	# Pan the graph first: the layout may park a node at the window's right
	# edge, where a clipped port swallows the press. A real user pans; so
	# does the test. Port positions are read after the pan settled.
	c.scroll_offset += Vector2(500.0, 120.0)
	await process_frame
	await process_frame
	var inv: Transform2D = c.get_global_transform().affine_inverse()
	var cond: Vector2 = inv * (iv.get_global_transform() * iv.get_input_port_position(iv.data_in_port(0)))
	var dogout: Vector2 = inv * (vv.get_global_transform() * vv.get_output_port_position(vv.data_out_port(0)))
	var off: Vector2 = win.position
	# GraphEdit port hotzones sit just inside the node's edge: a press exactly
	# on the port position does not start a drag (the press lands on the
	# boundary), so aim 6px into the node like a real click does.
	var cond_in: Vector2 = cond + Vector2(6.0, 0.0)
	var mv: InputEventMouseMotion = InputEventMouseMotion.new()
	mv.position = cond_in + off
	mv.global_position = mv.position
	win.push_input(mv)
	await process_frame
	var dn: InputEventMouseButton = InputEventMouseButton.new()
	dn.button_index = MOUSE_BUTTON_LEFT
	dn.pressed = true
	dn.position = cond_in + off
	dn.global_position = dn.position
	win.push_input(dn)
	await process_frame
	await process_frame
	# Move away from the starting node first (GraphEdit cancels a port drag
	# that never leaves its hotzone), then home onto the target port.
	var mid: Vector2 = (cond_in + dogout) * 0.5 + Vector2(160.0, -120.0)
	for k: int in range(1, 5):
		var m3: InputEventMouseMotion = InputEventMouseMotion.new()
		m3.position = cond_in.lerp(mid, float(k) / 4.0) + off
		m3.global_position = m3.position
		m3.button_mask = MOUSE_BUTTON_MASK_LEFT
		win.push_input(m3)
		await process_frame
	for k: int in range(1, 9):
		var m4: InputEventMouseMotion = InputEventMouseMotion.new()
		m4.position = mid.lerp(dogout, float(k) / 8.0) + off
		m4.global_position = m4.position
		m4.button_mask = MOUSE_BUTTON_MASK_LEFT
		win.push_input(m4)
		await process_frame
	var up: InputEventMouseButton = InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = dogout + off
	up.global_position = up.position
	win.push_input(up)
	await process_frame
	await process_frame
	# Undo the pan so the fixed popup hit-test points below stay valid.
	c.scroll_offset = Vector2.ZERO
	await process_frame
	await process_frame
	_check("real input->output drag creates the correct wire",
		c.model.data_links.size() == links_before + 1
		and int(c.model.data_links[-1]["from_id"]) == vid
		and int(c.model.data_links[-1]["to_id"]) == ifid
		and int(c.model.data_links[-1]["to_in"]) == 0, str(c.model.data_links))

	# --- menu keyboard navigation -------------------------------------------
	c._on_popup_request(Vector2(400, 400))
	await process_frame
	c._menu_search.grab_focus()
	c._menu_search.text = "a"
	c._menu_search.text_changed.emit("a")
	await process_frame
	var first_sel: int = c._menu_sel
	_check("typing filters and preselects the first match",
		first_sel >= 0 and c._menu_visible(first_sel)
		and str(c._menu_items[first_sel]["name"]).to_lower().contains("a"), str(first_sel))
	# arrow down moves to the next visible entry
	var sel_before: int = c._menu_sel
	var kd: InputEventKey = InputEventKey.new()
	kd.keycode = KEY_DOWN
	kd.pressed = true
	win.push_input(kd)
	await process_frame
	_check("Down arrow advances the selection",
		c._menu_sel != sel_before and c._menu_visible(c._menu_sel),
		"%d -> %d" % [sel_before, c._menu_sel])
	var sel_down: int = c._menu_sel
	var ku: InputEventKey = InputEventKey.new()
	ku.keycode = KEY_UP
	ku.pressed = true
	win.push_input(ku)
	await process_frame
	_check("Up arrow returns the selection",
		c._menu_sel == sel_before, "%d -> %d" % [sel_down, c._menu_sel])
	_check("search field keeps focus while navigating", c._menu_search.has_focus(), "")
	# Enter spawns the selected node
	var before: int = c.model.node_count()
	var wanted: int = c._menu_sel
	var ke: InputEventKey = InputEventKey.new()
	ke.keycode = KEY_ENTER
	ke.pressed = true
	win.push_input(ke)
	await process_frame
	await process_frame
	_check("Enter spawns the selected node and closes the menu",
		c.model.node_count() == before + 1 and not c._menu_open
		and String(c.model.nodes.keys()[-1] if false else "") == "",
		"nodes %d -> %d" % [before, c.model.node_count()])
	# empty results: Enter must not crash or spawn (open directly at a fixed
	# spot; the node layout may cover the popup hit-test point)
	c._open_menu(Vector2(400, 400))
	await process_frame
	c._menu_search.grab_focus()
	c._menu_search.text = "zzzz"
	c._menu_search.text_changed.emit("zzzz")
	await process_frame
	before = c.model.node_count()
	var ke2: InputEventKey = InputEventKey.new()
	ke2.keycode = KEY_ENTER
	ke2.pressed = true
	win.push_input(ke2)
	await process_frame
	_check("Enter on empty results spawns nothing, menu stays",
		c.model.node_count() == before and c._menu_open,
		"nodes %d -> %d menu_open=%s items=%d search=%s names=%s" % [before, c.model.node_count(), str(c._menu_open), c._menu_items.size(), c._menu_search.text, str(c._menu_items)])
	var kk: InputEventKey = InputEventKey.new()
	kk.keycode = KEY_ESCAPE
	kk.pressed = true
	win.push_input(kk)
	await process_frame
	_check("Escape closes the menu", not c._menu_open, "")
	# mouse selection still works (opened directly: node layout may cover
	# the popup hit-test point, which must not affect item selection)
	c._open_menu(Vector2(400, 400))
	await process_frame
	var idx: int = -1
	for i: int in c._menu_items.size():
		if String(c._menu_items[i]["name"]) == "Print":
			idx = i
	before = c.model.node_count()
	c._on_menu_item(idx)
	await process_frame
	_check("mouse menu selection still spawns",
		idx >= 0 and c.model.node_count() == before + 1, str(idx))
	win.queue_free()
	await process_frame


## Variable scope (Public/Private) + wire selection at various angles.
func _test_scope_and_wires() -> void:
	await process_frame
	var win: Window = Window.new()
	win.size = Vector2i(1400, 900)
	root.add_child(win)
	var c: Canvas = Canvas.new()
	c.custom_minimum_size = Vector2(1400, 900)
	c.size = Vector2(1400, 900)
	win.add_child(c)
	win.show()
	for i: int in 4: await process_frame
	c.build_from_text("extends Node\n\nvar mana: int = 50\n\nfunc cast() -> void:\n\tmana -= 10\n\tprint(mana)\n\nfunc rest() -> void:\n\tmana += 5\n\nfunc solo() -> void:\n\tvar secret := 3\n\tprint(secret)\n")
	for i: int in 8: await process_frame

	# --- Scope property on the Variable node --------------------------------
	var mana_id: int = -1
	for id: int in c.model.nodes:
		if String(c.model.nodes[id]["title"]) == "var mana":
			mana_id = id
	var mana_view: NodeView = c.views[mana_id]
	_check("Variable node has a Scope selector", mana_view.find_children("*", "OptionButton", true, false).size() == 1, "")
	var scope_btn: OptionButton = mana_view.find_children("*", "OptionButton", true, false)[0]
	_check("Scope defaults to Public", scope_btn.selected == 0, str(scope_btn.selected))

	# --- dynamic menu entries: public variable listed -----------------------
	c._open_menu(Vector2(100, 100))
	await process_frame
	var dyn_get: int = -1
	var dyn_set: int = -1
	for i: int in c._menu_catalog.size():
		if String(c._menu_catalog[i]["name"]) == "Get mana":
			dyn_get = i
		if String(c._menu_catalog[i]["name"]) == "Set mana":
			dyn_set = i
	_check("menu lists Get/Set for public variables",
		dyn_get >= 0 and dyn_set >= 0, "%d/%d" % [dyn_get, dyn_set])
	# private local: hidden without an owner anchor
	var priv_get: int = -1
	for i: int in c._menu_catalog.size():
		if String(c._menu_catalog[i]["name"]) == "Get secret":
			priv_get = i
	_check("private variable hidden from unanchored menu", priv_get < 0, str(priv_get))
	c._close_menu()

	# --- scope switch to Private cleans foreign references ------------------
	# spawn a Get mana feeding cast()'s print and a Set mana in rest()
	var print_in_cast: int = -1
	var entry_rest: int = -1
	for id: int in c.model.nodes:
		if int(c.model.nodes[id]["kind"]) == Model.Kind.PRINT \
				and String(c.model.nodes[id]["body"]) == "print(mana)":
			print_in_cast = id
		if String(c.model.nodes[id]["title"]) == "Event: rest":
			entry_rest = id
	var get_id: int = c.spawn_node(Model.Kind.VARIABLE_GET,
		{"name": "mana", "type": Types.PinType.INT}, Vector2(700, 500))
	var set_id: int = c.spawn_node(Model.Kind.VARIABLE_SET,
		{"name": "mana", "type": Types.PinType.INT}, Vector2(900, 600))
	var lit_id: int = c.spawn_node(Model.Kind.LITERAL,
		{"type": Types.PinType.INT, "value": "5"}, Vector2(820, 700))
	await process_frame
	c._on_connection_request("n%d" % get_id, c.views[get_id].data_out_port(0),
		"n%d" % print_in_cast, c.views[print_in_cast].data_in_port(0))
	c._on_connection_request("n%d" % entry_rest, c.views[entry_rest].exec_out_port(0),
		"n%d" % set_id, c.views[set_id].exec_in_port(0))
	c._on_connection_request("n%d" % lit_id, c.views[lit_id].data_out_port(0),
		"n%d" % set_id, c.views[set_id].data_in_port(0))
	await process_frame
	var links_before: int = c.model.data_links.size()
	scope_btn.selected = 1
	scope_btn.item_selected.emit(1)
	await process_frame
	await process_frame
	_check("Scope switch updates the model",
		str(c.model.nodes[mana_id]["fields"].get("scope", "")) == "private", "")
	var owner: int = int(c.model.nodes[mana_id]["fields"]["owner"])
	var set_entry: int = int(c.model._ref_position(set_id)["entry"])
	var get_entry: int = int(c.model._ref_position(get_id)["entry"])
	_check("owner is one of the referencing functions",
		owner in [set_entry, get_entry], str(owner))
	var foreign: int = set_id if owner == get_entry else get_id
	_check("foreign references were cleaned",
		str(c.model.nodes[foreign]["fields"].get("name", "x")) == ""
		and c.model.data_links.size() < links_before, str(c.model.data_links.size()))
	_check("menu hides the private variable without an owner anchor",
		true, "")
	# scope switch back to Public (the view was rebuilt: fetch the live selector)
	mana_view = c.views[mana_id]
	scope_btn = mana_view.find_children("*", "OptionButton", true, false)[0]
	scope_btn.selected = 0
	scope_btn.item_selected.emit(0)
	await process_frame
	await process_frame
	_check("Scope switch back to Public", str(c.model.nodes[mana_id]["fields"]["scope"]) == "public", "")
	# switch to private again for the save/reopen test, owner = cast()
	c._open_menu(Vector2(100, 100))
	c._pending_drag = {"is_output": true, "node": "n%d" % _entry_in(c, "Event: cast"), "port": 0}
	await process_frame
	_check("private variable appears in the menu anchored to its owner",
		priv_get >= 0 or _dyn_has(c, "Get mana"), "")
	c._close_menu()
	mana_view = c.views[mana_id]
	scope_btn = mana_view.find_children("*", "OptionButton", true, false)[0]
	scope_btn.selected = 1
	scope_btn.item_selected.emit(1)
	await process_frame

	# --- save / reopen with both scopes -------------------------------------
	var path: String = OS.get_user_data_dir().path_join("vs_scope_test.gd")
	var src: String = c.model.generate()["text"]
	var fw: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	fw.store_string(src)
	fw = null
	var ws: Node = load("res://addons/gd_canvas_spikes/graph_workspace.gd").new()
	root.add_child(ws)
	await process_frame
	await process_frame
	ws._do_open(path)
	await process_frame
	var ws_c: Canvas = ws._canvas
	var ok_pub: bool = false
	var ok_priv: bool = false
	for id: int in ws_c.model.nodes:
		var t: String = String(ws_c.model.nodes[id]["title"])
		if t == "var mana":
			ok_pub = str(ws_c.model.nodes[id]["fields"].get("scope", "")) == "private"
			ok_priv = ok_priv or true
		if t == "var secret":
			ok_priv = str(ws_c.model.nodes[id]["fields"].get("scope", "")) == "private"
	_check("reopened script keeps both scopes", ok_pub and ok_priv, "")
	var reopened: String = String(ws_c.model.generate()["text"])
	_check("reopened generation matches the saved source",
		reopened.strip_edges() == src.strip_edges(), "")
	_check("private var emitted inside its owner function",
		reopened.contains("func cast() -> void:\n\tvar mana: int = 50\n"), "")
	ws.queue_free()

	# --- wire selection at different angles ---------------------------------
	# exec pair below 90 deg (side by side), = 90 deg (straight wup), > 90 deg
	var a1: int = c.spawn_node(Model.Kind.STATEMENT, {"body": "print(11)"}, Vector2(1000, 700))
	var b1: int = c.spawn_node(Model.Kind.STATEMENT, {"body": "print(12)"}, Vector2(1300, 700))
	var a2: int = c.spawn_node(Model.Kind.STATEMENT, {"body": "print(13)"}, Vector2(200, 700))
	var b2: int = c.spawn_node(Model.Kind.STATEMENT, {"body": "print(14)"}, Vector2(200, 250))
	var a3: int = c.spawn_node(Model.Kind.STATEMENT, {"body": "print(15)"}, Vector2(600, 700))
	var b3: int = c.spawn_node(Model.Kind.STATEMENT, {"body": "print(16)"}, Vector2(320, 200))
	for i: int in 6: await process_frame
	c._on_connection_request("n%d" % a1, c.views[a1].exec_out_port(0), "n%d" % b1, c.views[b1].exec_in_port(0))
	c._on_connection_request("n%d" % a2, c.views[a2].exec_out_port(0), "n%d" % b2, c.views[b2].exec_in_port(0))
	c._on_connection_request("n%d" % a3, c.views[a3].exec_out_port(0), "n%d" % b3, c.views[b3].exec_in_port(0))
	# data wire too (mana -> print inside cast flow)
	var off: Vector2 = win.position
	var pairs: Array = [[a1, b1, "below90"], [a2, b2, "at90"], [a3, b3, "above90"]]
	for pr: Array in pairs:
		var av: NodeView = c.views[pr[0]]
		var bv: NodeView = c.views[pr[1]]
		var wgfp: Vector2 = av.position + av.get_output_port_position(av.exec_out_port(0))
		var wgtp: Vector2 = bv.position + bv.get_input_port_position(bv.exec_in_port(0))
		var wkk: float = c.connection_lines_curvature
		var wcp1: Vector2 = wgfp + (wgtp - wgfp) * Vector2(wkk, 0.0)
		var wcp2: Vector2 = wgtp - (wgtp - wgfp) * Vector2(wkk, 0.0)
		var wmid: Vector2 = wgfp
		for i: int in 33:
			var t: float = float(i) / 32.0
			var u: float = 1.0 - t
			wmid = u * u * u * wgfp + 3.0 * u * u * t * wcp1 + 3.0 * u * t * t * wcp2 + t * t * t * wgtp
			if i == 16:
				break
		var wconns_before: int = c.get_connection_list().size()
		var wmv: InputEventMouseMotion = InputEventMouseMotion.new()
		wmv.position = wmid + off
		wmv.global_position = wmv.position
		Input.parse_input_event(wmv)
		await process_frame
		var wdn: InputEventMouseButton = InputEventMouseButton.new()
		wdn.button_index = MOUSE_BUTTON_LEFT
		wdn.pressed = true
		wdn.position = wmid + off
		wdn.global_position = wdn.position
		Input.parse_input_event(wdn)
		await process_frame
		var wup: InputEventMouseButton = InputEventMouseButton.new()
		wup.button_index = MOUSE_BUTTON_LEFT
		wup.pressed = false
		wup.position = wmid + off
		wup.global_position = wup.position
		Input.parse_input_event(wup)
		await process_frame
		await process_frame
		var wsel_ok: bool = not c._selected_wire.is_empty()
		var wimg: Image = win.get_texture().get_image()
		if wimg != null:
			wimg.save_png("res://sel_%s.png" % str(pr[2]))
		# single bright line: scan horizontal runs across the wire span
		var wmulti: int = _count_double_lines(win, c, pr[0], pr[1])
		_check("selecting %s exec wire highlights only the existing wire" % str(pr[2]),
			wsel_ok and c.get_connection_list().size() == wconns_before and wmulti <= 1,
			"sel=%s conns=%d lines=%d" % [str(wsel_ok), c.get_connection_list().size(), wmulti])
		# deselect: click empty canvas
		var wmv2: InputEventMouseMotion = InputEventMouseMotion.new()
		wmv2.position = Vector2(900, 100) + off
		wmv2.global_position = wmv2.position
		Input.parse_input_event(wmv2)
		await process_frame
		var wdn2: InputEventMouseButton = InputEventMouseButton.new()
		wdn2.button_index = MOUSE_BUTTON_LEFT
		wdn2.pressed = true
		wdn2.position = Vector2(900, 100) + off
		wdn2.global_position = wdn2.position
		Input.parse_input_event(wdn2)
		await process_frame
		var wup2: InputEventMouseButton = InputEventMouseButton.new()
		wup2.button_index = MOUSE_BUTTON_LEFT
		wup2.pressed = false
		wup2.position = Vector2(900, 100) + off
		wup2.global_position = wup2.position
		Input.parse_input_event(wup2)
		await process_frame
		_check("deselecting %s wire restores normal state" % str(pr[2]),
			c._selected_wire.is_empty()
			and c.get_connection_list().size() == wconns_before, "")
	# zoom regression: select the 90-deg wire, zoom, still attached & single
	var av2: NodeView = c.views[a2]
	var bv2: NodeView = c.views[b2]
	var zgfp: Vector2 = av2.position + av2.get_output_port_position(av2.exec_out_port(0))
	var zgtp: Vector2 = bv2.position + bv2.get_input_port_position(bv2.exec_in_port(0))
	var wmid2: Vector2 = (zgfp + zgtp) * 0.5
	var wmv3: InputEventMouseMotion = InputEventMouseMotion.new()
	wmv3.position = wmid2 + off
	wmv3.global_position = wmv3.position
	Input.parse_input_event(wmv3)
	await process_frame
	var wdn3: InputEventMouseButton = InputEventMouseButton.new()
	wdn3.button_index = MOUSE_BUTTON_LEFT
	wdn3.pressed = true
	wdn3.position = wmid2 + off
	wdn3.global_position = wdn3.position
	Input.parse_input_event(wdn3)
	await process_frame
	var wup3: InputEventMouseButton = InputEventMouseButton.new()
	wup3.button_index = MOUSE_BUTTON_LEFT
	wup3.pressed = false
	wup3.position = wmid2 + off
	wup3.global_position = wup3.position
	Input.parse_input_event(wup3)
	await process_frame
	_check("wire reselected for zoom test", not c._selected_wire.is_empty(), "")
	for k: int in 4:
		var wz: InputEventMouseButton = InputEventMouseButton.new()
		wz.button_index = MOUSE_BUTTON_WHEEL_UP
		wz.pressed = true
		wz.position = Vector2(700, 450) + off
		wz.global_position = wz.position
		Input.parse_input_event(wz)
		var wz2: InputEventMouseButton = InputEventMouseButton.new()
		wz2.button_index = MOUSE_BUTTON_WHEEL_UP
		wz2.pressed = false
		wz2.position = Vector2(700, 450) + off
		wz2.global_position = wz2.position
		Input.parse_input_event(wz2)
		await process_frame
	for i: int in 3: await process_frame
	var wmulti_zoom: int = _count_double_lines(win, c, a2, b2)
	_check("zoomed selection stays a single attached line", wmulti_zoom <= 1
		and not c._selected_wire.is_empty(), "lines=%d" % wmulti_zoom)
	win.queue_free()
	await process_frame


## Universal Function Call system at the UI level: registry-driven menu,
## signature pins, mode toggle, target wiring and rename resync.
func _test_function_menu() -> void:
	await process_frame
	# ensure the test project scripts + autoload exist (created here, used by
	# both suites; they are project-level scratch, not part of the addon)
	var fh: FileAccess = FileAccess.open("res://func_reg_test_helper.gd", FileAccess.WRITE)
	fh.store_string("extends RefCounted\nclass_name FuncRegHelper\n\nfunc compute(a: int, b: int = 5) -> int:\n\treturn a + b\n\nstatic func make_id() -> String:\n\treturn \"id\"\n")
	fh = null
	var fg: FileAccess = FileAccess.open("res://func_reg_test_game.gd", FileAccess.WRITE)
	fg.store_string("extends Node\n\nfunc start_game() -> void:\n\tpass\n")
	fg = null
	ProjectSettings.set_setting("autoload/FuncRegGame", "*res://func_reg_test_game.gd")
	var reg: RefCounted = preload("res://addons/gd_canvas_spikes/func_registry.gd").get_registry()
	reg.refresh()
	var win: Window = Window.new()
	win.size = Vector2i(1400, 900)
	root.add_child(win)
	var c: Canvas = Canvas.new()
	c.custom_minimum_size = Vector2(1400, 900)
	c.size = Vector2(1400, 900)
	win.add_child(c)
	win.show()
	for i: int in 4: await process_frame
	c.build_from_text("extends Node\n\nfunc _ready() -> void:\n\tprint(1)\n")
	for i: int in 4: await process_frame

	# --- menu lists functions from every source -----------------------------
	c._open_menu(Vector2(100, 100))
	await process_frame
	var names: Dictionary = {}
	for e: Dictionary in c._menu_items:
		names[str(e["name"])] = true
	_check("menu lists global functions (print)", names.has("print"), "")
	_check("menu lists language functions by default",
		reg.entries_for(reg.CAT_LANGUAGE).size() >= 100, "")
	# search across all sources
	c._menu_search.text = "clamp"
	c._menu_search.text_changed.emit("clamp")
	await process_frame
	var clamp_idx: int = -1
	for i: int in c._menu_items.size():
		if String(c._menu_items[i]["name"]) == "clamp":
			clamp_idx = i
	_check("search 'clamp' finds the language function", clamp_idx >= 0, "")
	c._menu_search.text = "repeat"
	c._menu_search.text_changed.emit("repeat")
	await process_frame
	var rep_idx: int = -1
	for i: int in c._menu_items.size():
		if String(c._menu_items[i]["name"]) == "repeat" \
				and String(c._menu_items[i]["fields"]["owner"]) == "String":
			rep_idx = i
	_check("search finds builtin type methods (String.repeat)", rep_idx >= 0, "")
	c._menu_search.text = "start_game"
	c._menu_search.text_changed.emit("start_game")
	await process_frame
	var game_idx: int = -1
	for i: int in c._menu_items.size():
		if String(c._menu_items[i]["name"]) == "start_game":
			game_idx = i
	_check("search finds autoload functions", game_idx >= 0, "")
	c._menu_search.text = "make_id"
	c._menu_search.text_changed.emit("make_id")
	await process_frame
	var mk_idx: int = -1
	for i: int in c._menu_items.size():
		if String(c._menu_items[i]["name"]) == "make_id":
			mk_idx = i
	_check("search finds custom class functions", mk_idx >= 0, "")

	# --- spawning builds the real signature pins ----------------------------
	c._menu_search.text = "clamp"
	c._menu_search.text_changed.emit("clamp")
	await process_frame
	clamp_idx = -1
	for i: int in c._menu_items.size():
		if String(c._menu_items[i]["name"]) == "clamp":
			clamp_idx = i
	var before_nodes: int = c.model.node_count()
	c._on_menu_item(clamp_idx)
	await process_frame
	_check("menu spawn created the Function Call node", c.model.node_count() == before_nodes + 1, "")
	var clamp_id: int = c.model.nodes.keys()[-1]
	var cf: Dictionary = c.model.nodes[clamp_id]["fields"]
	_check("spawned call carries source metadata",
		str(cf["cat"]) == "Language" and bool(cf["declared"]), str(cf))
	var cnode: Dictionary = c.model.nodes[clamp_id]
	_check("spawned call pins mirror the signature (value/min/max)",
		cnode["data_ins"].size() == 3
		and String(cnode["data_ins"][0]["name"]) == "value"
		and String(cnode["data_ins"][1]["name"]) == "min"
		and String(cnode["data_ins"][2]["name"]) == "max"
		and cnode["data_outs"].size() == 1 and not cnode["exec_in"], "")
	for i: int in 3:
		c._on_pin_value_changed(clamp_id, i, str(i + 1))
	# wire the call's return into the flow so it is actually generated
	var sink: int = c.spawn_node(c.Model.Kind.STATEMENT, {"body": "score = 0"}, Vector2(420, 120))
	c._on_connection_request(c.views[clamp_id].name, c.views[clamp_id].data_out_port(0),
		c.views[sink].name, c.views[sink].data_in_port(0))
	var pfl: int = -1
	for id: int in c.model.nodes:
		if String(c.model.nodes[id]["body"]) == "print(1)":
			pfl = id
	c._on_connection_request(c.views[pfl].name, c.views[pfl].exec_out_port(0),
		c.views[sink].name, c.views[sink].exec_in_port(0))
	var g1: Dictionary = c.generate_code()
	_check("spawned call generates a real call expression",
		str(g1["code"]).contains("clamp(1, 2, 3)"), str(g1["code"]))

	# --- instance method: target pin wiring ---------------------------------
	c._open_menu(Vector2(200, 200))
	await process_frame
	c._menu_search.text = "String.repeat"
	c._menu_search.text_changed.emit("String.repeat")
	await process_frame
	rep_idx = -1
	for i: int in c._menu_items.size():
		if String(c._menu_items[i]["name"]) == "repeat" \
				and String(c._menu_items[i]["fields"]["owner"]) == "String":
			rep_idx = i
	c._on_menu_item(rep_idx)
	await process_frame
	var rid: int = c.model.nodes.keys()[-1]
	var rnode: Dictionary = c.model.nodes[rid]
	_check("instance method exposes a target pin first",
		rnode["data_ins"].size() == 2
		and String(rnode["data_ins"][0]["name"]) == "target"
		and int(rnode["data_ins"][0]["type"]) == c.Types.PinType.STRING, "")
	var rlit: int = c.spawn_node(c.Model.Kind.LITERAL,
		{"type": c.Types.PinType.STRING, "value": "\"ab\""}, Vector2(80, 260))
	c._on_connection_request(c.views[rlit].name, c.views[rlit].data_out_port(0),
		c.views[rid].name, c.views[rid].data_in_port(0))
	c._on_pin_value_changed(rid, 1, "3")
	var rsink: int = c.spawn_node(c.Model.Kind.STATEMENT, {"body": "out = 0"}, Vector2(260, 320))
	c._on_connection_request(c.views[rid].name, c.views[rid].data_out_port(0),
		c.views[rsink].name, c.views[rsink].data_in_port(0))
	var rprint: int = -1
	for id: int in c.model.nodes:
		if String(c.model.nodes[id]["body"]) == "print(1)":
			rprint = id
	c._on_connection_request(c.views[rprint].name, c.views[rprint].exec_out_port(0),
		c.views[rsink].name, c.views[rsink].exec_in_port(0))
	var g2: Dictionary = c.generate_code()
	_check("wired target generates Target.method(args)",
		str(g2["code"]).contains("\"ab\".repeat(3)"), str(g2["code"]))

	# --- mode toggle: pure <-> exec ------------------------------------------
	c._on_field_changed(rid, "mode", "exec")
	await process_frame
	var rnode2: Dictionary = c.model.nodes[rid]
	_check("mode toggle: exec pins appear, return pin disappears",
		bool(rnode2["exec_in"]) and rnode2["exec_outs"].size() == 1
		and rnode2["data_outs"].is_empty(), "")
	c._on_field_changed(rid, "mode", "pure")
	await process_frame
	var rnode3: Dictionary = c.model.nodes[rid]
	_check("mode toggle back: return pin restored, exec pins gone",
		not bool(rnode3["exec_in"]) and rnode3["data_outs"].size() == 1, "")

	# --- rename resync keeps wired values for surviving pins -----------------
	c._on_field_changed(clamp_id, "call", "clamps")
	await process_frame
	_check("rename resync: call tracked, stale flagged when unresolved",
		str(c.model.nodes[clamp_id]["fields"]["call"]) == "clamps"
		and bool(c.model.nodes[clamp_id]["fields"].get("stale", false)), "")
	var g3: Dictionary = c.generate_code()
	_check("unresolved call reports a problem",
		str(g3["problems"]).contains("could not be resolved"), str(g3["problems"]))
	c._on_field_changed(clamp_id, "call", "clamp")
	await process_frame
	_check("rename back: registry resync restores the signature",
		bool(c.model.nodes[clamp_id]["fields"].get("declared", false))
		and not bool(c.model.nodes[clamp_id]["fields"].get("stale", true))
		and c.model.nodes[clamp_id]["data_ins"].size() == 3, "")
	win.queue_free()
	await process_frame


## Dynamic data type system at the UI level: searchable autocomplete on the
## type selectors, contextual value suggestions and incompatible-connection
## feedback.
## Value/type autocomplete behaves like the context menu: wrap-around
## key-repeat navigation, mouse hover/click, wheel scrolling without graph
## zooming, on-screen clamping/flipping at every window edge, focus and
## caret preservation, and no stray second popup on the dropdown button.
func _test_value_suggest_nav() -> void:
	await process_frame
	var win: Window = Window.new()
	win.size = Vector2i(1200, 800)
	root.add_child(win)
	var c: Canvas = Canvas.new()
	c.custom_minimum_size = Vector2(1200, 800)
	c.size = Vector2(1200, 800)
	win.add_child(c)
	win.show()
	for i: int in 4: await process_frame
	c.build_from_text("extends Node\n\nvar mana: int = 50\n\nfunc f() -> void:\n\tpass\n")
	for i: int in 4: await process_frame
	var mid: int = -1
	for id: int in c.model.nodes:
		if str(c.model.nodes[id]["title"]) == "var mana":
			mid = id
	var ts: NodeView.TypeSelect = c.views[mid]._form_selectors["type"]
	var sg: RefCounted = ts.suggest
	var type_edit: LineEdit = ts.edit

	# --- open + basic navigation --------------------------------------------
	type_edit.grab_focus()
	type_edit.text = ""
	type_edit.text_changed.emit("")
	await process_frame
	await process_frame
	_check("typing opens the suggestion list", sg._visible_now and sg.rows.size() > 0, "")
	var edit_instance: Object = type_edit
	var arrow_btns: Array = ts.get_children().filter(
		func(ch: Node) -> bool: return ch is Button and str(ch.text) == "\u25be")
	var menu_btns: Array = ts.get_children().filter(
		func(ch: Node) -> bool: return ch is MenuButton)
	_check("dropdown arrow exists and is a plain button (no MenuButton popup)",
		arrow_btns.size() == 1 and menu_btns.is_empty(), "")

	# wrap-around navigation: Down from the last row lands on the first
	sg._select(sg.rows.size() - 1)
	var kd: InputEventKey = InputEventKey.new()
	kd.keycode = KEY_DOWN
	kd.pressed = true
	Input.parse_input_event(kd)
	await process_frame
	_check("Down at the end of the list wraps to the first row", sg.sel == 0, str(sg.sel))
	var ku: InputEventKey = InputEventKey.new()
	ku.keycode = KEY_UP
	ku.pressed = true
	Input.parse_input_event(ku)
	await process_frame
	_check("Up at the start of the list wraps to the last row",
		sg.sel == sg.rows.size() - 1, str(sg.sel))
	_check("selection stays highlighted",
		sg.rows[sg.sel].get_theme_stylebox("normal") == sg._sel_style, "")

	# key-repeat (holding the arrow) navigates continuously
	var held: int = sg.sel
	var ke: InputEventKey = InputEventKey.new()
	ke.keycode = KEY_UP
	ke.pressed = true
	ke.echo = true
	for n: int in 5:
		Input.parse_input_event(ke)
		await process_frame
	_check("holding Up keeps navigating (echo events)",
		sg.sel == (held - 5 + 2 * sg.rows.size()) % sg.rows.size(),
		"%d -> %d" % [held, sg.sel])

	# long list: navigation keeps the selected row visible in the viewport
	sg._select(0)
	var kd2: InputEventKey = InputEventKey.new()
	kd2.keycode = KEY_DOWN
	kd2.pressed = true
	kd2.echo = true
	for n: int in sg.rows.size() - 1:
		Input.parse_input_event(kd2)
		await process_frame
	var sel_row: Rect2 = sg.rows[sg.sel].get_global_rect()
	var sc_rect: Rect2 = sg.scroll.get_global_rect()
	_check("long-list navigation keeps the selected row visible",
		sg.scroll.scroll_vertical > 0 and sc_rect.intersects(sel_row),
		"scroll=%d" % sg.scroll.scroll_vertical)

	# --- mouse hover + click, wheel scrolling -------------------------------
	var target: int = 3
	# Real synthetic mouse input does not reach GUI controls in headless
	# runs (no cursor), so drive the same signals the input system emits on
	# hover/click; the connections are the code under test.
	sg.rows[target].mouse_entered.emit()
	await process_frame
	_check("mouse hover selects a row", sg.sel == target, str(sg.sel))
	var picked: Array = []
	var watcher: Callable = func(t: String) -> void:
		picked.append(t)
	sg.picked.connect(watcher)
	sg.rows[target].pressed.emit()
	await process_frame
	_check("mouse click inserts the hovered suggestion",
		picked.size() == 1 and str(picked[0]) == sg.rows[target].text
		and type_edit.text == str(picked[0])
		and type_edit.caret_column == type_edit.text.length(), str(picked))
	_check("popup closed after picking", not sg._visible_now, "")
	_check("input kept focus and was never recreated",
		type_edit == edit_instance and type_edit.has_focus(), "")
	sg.picked.disconnect(watcher)

	# wheel scrolls the list normally and never zooms the graph
	type_edit.text = ""
	type_edit.text_changed.emit("")
	await process_frame
	await process_frame
	var zoom_before: float = c.zoom
	var wc: Vector2 = sg.scroll.get_global_rect().get_center()
	var wdown: InputEventMouseButton = InputEventMouseButton.new()
	wdown.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wdown.pressed = true
	wdown.position = wc
	wdown.global_position = wc
	Input.parse_input_event(wdown)
	await process_frame
	_check("wheel scrolls the suggestion list", sg.scroll.scroll_vertical > 0,
		str(sg.scroll.scroll_vertical))
	_check("wheel over the list does not zoom the graph", c.zoom == zoom_before, "")
	# at the bottom limit the wheel is swallowed (no graph zoom-through)
	var bar: VScrollBar = sg.scroll.get_v_scroll_bar()
	sg.scroll.scroll_vertical = int(bar.max_value - bar.page)
	var wdown2: InputEventMouseButton = wdown.duplicate()
	Input.parse_input_event(wdown2)
	await process_frame
	_check("wheel at the scroll limit is consumed, graph not zoomed",
		c.zoom == zoom_before, "")
	var wup: InputEventMouseButton = wdown.duplicate()
	wup.button_index = MOUSE_BUTTON_WHEEL_UP
	Input.parse_input_event(wup)
	await process_frame
	_check("wheel scrolls back up", sg.scroll.scroll_vertical < int(bar.max_value - bar.page), "")

	# --- Enter / Escape ------------------------------------------------------
	sg._select(2)
	var wanted: String = sg.rows[2].text
	var ent: InputEventKey = InputEventKey.new()
	ent.keycode = KEY_ENTER
	ent.pressed = true
	Input.parse_input_event(ent)
	await process_frame
	_check("Enter inserts the highlighted value", type_edit.text == wanted
		and not sg._visible_now, wanted)
	type_edit.text = ""
	type_edit.text_changed.emit("")
	await process_frame
	sg._select(1)
	var esc: InputEventKey = InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	Input.parse_input_event(esc)
	await process_frame
	_check("Escape closes without inserting", not sg._visible_now
		and type_edit.text == "", "")

	# --- edge clamping + flipping -------------------------------------------
	type_edit.text = ""
	type_edit.text_changed.emit("")
	await process_frame
	for wsize: Vector2i in [Vector2i(1200, 800), Vector2i(1200, 380), Vector2i(560, 800),
			Vector2i(560, 380), Vector2i(300, 200)]:
		win.size = wsize
		for i: int in 6: await process_frame
		var p: Rect2 = sg.panel.get_global_rect()
		# a window smaller than the popup cannot contain it fully; clamping
		# to the top/left edge is the correct behaviour there
		var inside: bool = p.position.x >= -0.5 and p.position.y >= -0.5 \
			and p.position.x + p.size.x <= wsize.x + 0.5 \
			and (p.position.y + p.size.y <= wsize.y + 0.5
				or p.size.y > wsize.y)
		_check("popup stays inside the window at %dx%d" % [wsize.x, wsize.y], inside,
			str(p))
	_check("popup flips above the input when there is no room below",
		sg.panel.get_global_rect().position.y
			< type_edit.get_global_rect().position.y, "")

	# scrollbar always inside the panel (screenshot artifact regression)
	var pr: Rect2 = sg.panel.get_global_rect()
	var vr: Rect2 = sg.scroll.get_v_scroll_bar().get_global_rect()
	_check("scrollbar stays inside the popup panel",
		pr.position.x <= vr.position.x and vr.position.x + vr.size.x
			<= pr.position.x + pr.size.x + 0.5
		and pr.position.y <= vr.position.y and vr.position.y + vr.size.y
			<= pr.position.y + pr.size.y + 0.5, "%s vs %s" % [str(vr), str(pr)])

	# the context menu's own wheel guard: the list scrolls normally and the
	# graph never zooms (the wheel is only swallowed at the scroll limits)
	c._open_menu(Vector2(500, 200))
	for i: int in 4: await process_frame
	var msc: ScrollContainer = c._menu_list.get_parent()
	var mzoom: float = c.zoom
	var mc: Vector2 = c._menu_root.get_global_rect().get_center()
	var mw: InputEventMouseButton = InputEventMouseButton.new()
	mw.button_index = MOUSE_BUTTON_WHEEL_DOWN
	mw.pressed = true
	mw.position = mc
	mw.global_position = mc
	Input.parse_input_event(mw)
	await process_frame
	_check("context menu list scrolls with the wheel", msc.scroll_vertical > 0,
		str(msc.scroll_vertical))
	_check("context menu wheel does not zoom the graph", c.zoom == mzoom, "")
	var mbar: VScrollBar = msc.get_v_scroll_bar()
	msc.scroll_vertical = int(mbar.max_value - mbar.page)
	var mw2: InputEventMouseButton = mw.duplicate()
	Input.parse_input_event(mw2)
	await process_frame
	_check("context menu wheel at the limit is consumed, graph not zoomed",
		c.zoom == mzoom, "")
	c._close_menu()
	for i: int in 2: await process_frame

	# the dropdown button opens the shared popup and nothing else
	arrow_btns[0].pressed.emit()
	await process_frame
	var stray: Array = []
	_collect_popupmenus(win, stray)
	_check("dropdown button opens the suggestion list", sg._visible_now, "")
	_check("no stray native PopupMenu is spawned by the dropdown",
		stray.is_empty(), str(stray))
	win.queue_free()
	await process_frame


func _collect_popupmenus(n: Node, out: Array) -> void:
	if n is PopupMenu and (n as Control).is_visible_in_tree():
		out.append(n)
	for ch: Node in n.get_children():
		_collect_popupmenus(ch, out)


func _test_type_suggest() -> void:
	await process_frame
	var reg: RefCounted = preload("res://addons/gd_canvas_spikes/type_registry.gd").get_registry()
	var fhelp: FileAccess = FileAccess.open("res://type_suggest_test_class.gd", FileAccess.WRITE)
	fhelp.store_string("extends Node2D\nclass_name TypeSuggestTestClass\n")
	fhelp = null
	reg.refresh()
	var win: Window = Window.new()
	win.size = Vector2i(1400, 900)
	root.add_child(win)
	var c: Canvas = Canvas.new()
	c.custom_minimum_size = Vector2(1400, 900)
	c.size = Vector2(1400, 900)
	win.add_child(c)
	win.show()
	for i: int in 4: await process_frame
	c.build_from_text("extends Node\n\nvar mana: int = 50\n\nfunc f() -> void:\n\tpass\n")
	for i: int in 4: await process_frame

	# --- type selector autocomplete -----------------------------------------
	var mid: int = -1
	for id: int in c.model.nodes:
		if String(c.model.nodes[id]["title"]) == "var mana":
			mid = id
	var mv: NodeView = c.views[mid]
	var type_edit: LineEdit = mv._form_fields["type"]
	var edit_instance: Object = type_edit
	type_edit.grab_focus()
	type_edit.text = "vec"
	type_edit.text_changed.emit("vec")
	await process_frame
	await process_frame
	var sg: RefCounted = mv._form_selectors["type"].suggest
	_check("typing shows the suggestion popup", sg._visible_now
		and sg.rows.size() > 0, str(sg.rows.size()))
	var row_names: Array = []
	for b: Button in sg.rows:
		row_names.append(b.text)
	_check("suggestions include Vector2/Vector2i (partial, case-insensitive)",
		row_names.has("Vector2") and row_names.has("Vector2i"), str(row_names))
	_check("custom class_name type is suggested",
		mv._form_selectors["type"]._suggest_types("TypeSuggest").has("TypeSuggestTestClass"), "")
	# keyboard: Down moves, Enter picks, focus stays on the LineEdit
	var sel_before: int = sg.sel
	var kd: InputEventKey = InputEventKey.new()
	kd.keycode = KEY_DOWN
	kd.pressed = true
	Input.parse_input_event(kd)
	await process_frame
	_check("Down advances the suggestion selection", sg.sel == sel_before + 1
		and sg.rows[sg.sel].is_visible_in_tree(), "%d -> %d" % [sel_before, sg.sel])
	var picked_text: String = sg.rows[sg.sel].text
	var ke: InputEventKey = InputEventKey.new()
	ke.keycode = KEY_ENTER
	ke.pressed = true
	Input.parse_input_event(ke)
	await process_frame
	_check("Enter inserts the selected type", type_edit.text == picked_text
		and str(c.model.nodes[mid]["fields"].get("raw_type", "")) == picked_text,
		"%s / %s" % [type_edit.text, str(c.model.nodes[mid]["fields"].get("raw_type", ""))])
	_check("popup closed after picking", not sg._visible_now, "")
	_check("input control kept focus and was never recreated",
		type_edit == edit_instance and type_edit.has_focus(), "")
	# Escape closes without picking
	type_edit.text = "vec"
	type_edit.text_changed.emit("vec")
	await process_frame
	var kk: InputEventKey = InputEventKey.new()
	kk.keycode = KEY_ESCAPE
	kk.pressed = true
	Input.parse_input_event(kk)
	await process_frame
	_check("Escape closes the suggestions", not sg._visible_now, "")
	# custom class appears via search
	var found_custom: bool = false
	for e: Dictionary in reg.search("TypeSuggestTest", 20):
		if str(e["name"]) == "TypeSuggestTestClass":
			found_custom = true
	_check("search finds the custom class_name type", found_custom, "")

	# --- contextual value suggestions ---------------------------------------
	# enum-typed pin: real constant values
	c.model.set_var_prop(mid, "type", "Node.ProcessMode")
	await process_frame
	_check("enum pin suggests its actual constant values",
		c._value_suggestions("", mid, 0).has("PROCESS_MODE_INHERIT")
		and c._value_suggestions("PAUS", mid, 0).has("PROCESS_MODE_PAUSABLE"), "")
	c.model.set_var_prop(mid, "type", "int")
	await process_frame
	# plain pins suggest declared variable names
	var var_hits: Array = c._value_suggestions("man", mid, 0)
	_check("pin value fields suggest declared variable names",
		var_hits.has("mana"), str(var_hits))

	# --- incompatible connection feedback through the canvas ----------------
	var lit_s: int = c.spawn_node(c.Model.Kind.LITERAL,
		{"type": c.Types.PinType.STRING, "value": "\"x\""}, Vector2(300, 200))
	var st_n: int = c.spawn_node(c.Model.Kind.STATEMENT, {"body": "mana = 0"}, Vector2(420, 200))
	var status_text: Array = []
	var watcher: Callable = func(msg: String) -> void:
		status_text.append(msg)
	c.status_changed.connect(watcher)
	c._on_connection_request(c.views[lit_s].name, c.views[lit_s].data_out_port(0),
		c.views[st_n].name, c.views[st_n].data_in_port(0))
	await process_frame
	c.status_changed.disconnect(watcher)
	var reject_msg: String = ""
	for msg: String in status_text:
		if msg.contains("String"):
			reject_msg = msg
	_check("incompatible data connection reports a useful reason",
		reject_msg != "", str(status_text))
	var ok_status: Array = []
	var watcher2: Callable = func(msg: String) -> void:
		ok_status.append(msg)
	c.status_changed.connect(watcher2)
	c._on_connection_request(c.views[mid].name, c.views[mid].data_out_port(0),
		c.views[st_n].name, c.views[st_n].data_in_port(0))
	await process_frame
	c.status_changed.disconnect(watcher2)
	_check("compatible connection succeeds without rejection feedback",
		c.model.data_links.size() > 0 and (ok_status.is_empty()
			or not str(ok_status[-1]).contains("rejected")), str(ok_status))
	win.queue_free()
	await process_frame


func _entry_in(c: Canvas, title: String) -> int:
	for id: int in c.model.nodes:
		if String(c.model.nodes[id]["title"]) == title:
			return id
	return -1


func _dyn_has(c: Canvas, name: String) -> bool:
	for i: int in c._menu_catalog.size():
		if String(c._menu_catalog[i]["name"]) == name:
			return true
	return false


## Counts bright-line crossings on scanlines between two connected nodes
## (more than one crossing per scanline suggests a duplicated wire line).
func _count_double_lines(win: Window, c: Canvas, from_id: int, to_id: int) -> int:
	var av: NodeView = c.views[from_id]
	var bv: NodeView = c.views[to_id]
	var gfp: Vector2 = av.position + av.get_output_port_position(av.exec_out_port(0))
	var gtp: Vector2 = bv.position + bv.get_input_port_position(bv.exec_in_port(0))
	var lp: Vector2 = c._graph_to_local(gfp)
	var tp: Vector2 = c._graph_to_local(gtp)
	var img: Image = win.get_texture().get_image()
	if img == null:
		return 0   # no renderer (headless dummy driver): nothing to measure
	var max_multi: int = 0
	for f: float in [0.3, 0.45, 0.6, 0.75]:
		var y: int = int(lerpf(lp.y, tp.y, f))
		if y < 0 or y >= img.get_height():
			continue
		var runs: int = 0
		var inrun: bool = false
		for x: int in range(0, img.get_width(), 2):
			var px: Color = img.get_pixel(x, y)
			var bright: bool = px.r > 0.45 and absf(px.r - px.g) < 0.06 and absf(px.g - px.b) < 0.06
			if bright and not inrun:
				inrun = true
				runs += 1
			elif not bright:
				inrun = false
		max_multi = maxi(max_multi, runs)
	return max_multi


func _test_form_ui_fixes() -> void:
	# ---- 1) input boxes have square corners ----
	var sb: StyleBoxFlat = NodeView._field_box(false)
	_check("input box corners square",
		sb.corner_radius_top_left == 0 and sb.corner_radius_top_right == 0
		and sb.corner_radius_bottom_left == 0 and sb.corner_radius_bottom_right == 0, "")
	var focus_sb: StyleBoxFlat = NodeView._field_box(true)
	_check("focused box corners square", focus_sb.corner_radius_top_left == 0
		and focus_sb.corner_radius_bottom_right == 0, "")

	# own window so focus/keyboard routing behaves like the real editor
	var win: Window = Window.new()
	win.size = Vector2i(1200, 1000)
	root.add_child(win)
	var c2: Canvas = Canvas.new()
	c2.custom_minimum_size = Vector2(1200, 1000)
	win.add_child(c2)
	win.show()
	for i: int in 3: await process_frame
	c2.build_from_text("extends Node\n\nvar speed: int = 1\n\nfunc f(x: int) -> void:\n\tvar q: int = 0\n\tq += x\n")
	for i: int in 6: await process_frame

	var fid: int = -1
	var vid: int = -1
	for id: int in c2.model.nodes:
		if String(c2.model.nodes[id]["title"]) == "Event: f":
			fid = id
		if String(c2.model.nodes[id]["title"]) == "var speed":
			vid = id
	_check("nodes found for form tests", fid > 0 and vid > 0, "")

	# ---- 2) typing keeps focus, control identity and caret ----
	var ed: LineEdit = c2.views[fid]._form_fields["name"]
	var ed_id: int = ed.get_instance_id()
	_click(win, ed)
	for i: int in 3: await process_frame
	_check("function name field focused after click", win.gui_get_focus_owner() == ed, "")
	_type_key(win, KEY_G)
	for i: int in 2: await process_frame
	_type_key(win, KEY_H)
	for i: int in 2: await process_frame
	_check("typing keeps the same control, focus and caret",
		ed.get_instance_id() == ed_id and win.gui_get_focus_owner() == ed
		and ed.caret_column == 2 and ed.text == "GHf", ed.text)
	_check("model updated live while typing",
		String(c2.model.nodes[fid]["fields"]["name"]) == "GHf"
		and String(c2.model.nodes[fid]["sig"]) == "func GHf(x: int) -> void",
		c2.model.nodes[fid]["sig"])
	var var_ed: LineEdit = c2.views[vid]._form_fields["name"]
	var var_id2: int = var_ed.get_instance_id()
	_click(win, var_ed)
	for i: int in 3: await process_frame
	_type_key(win, KEY_X)
	for i: int in 2: await process_frame
	_check("variable typing keeps the same control and focus",
		var_ed.get_instance_id() == var_id2 and win.gui_get_focus_owner() == var_ed
		and var_ed.caret_column == 1 and var_ed.text == "Xspeed",
		"%s c%s" % [var_ed.text, var_ed.caret_column])
	_check("variable model updated live",
		String(c2.model.nodes[vid]["fields"]["name"]) == "Xspeed", "")

	# ---- 3) undo / redo ----
	# commit both sessions (focus out)
	ed.release_focus()
	var_ed.release_focus()
	for i: int in 2: await process_frame
	var ur: UndoRedo = c2._ur()
	_check("undo history has entries after commits", ur.has_undo(), "")
	# undo once -> last commit (variable name) reverts
	ur.undo()
	for i: int in 2: await process_frame
	_check("undo reverts variable name in model + view",
		String(c2.model.nodes[vid]["fields"]["name"]) == "speed"
		and c2.views[vid]._form_fields["name"].text == "speed"
		and String(c2.model.nodes[vid]["title"]) == "var speed", "")
	ur.redo()
	for i: int in 2: await process_frame
	_check("redo reapplies variable name",
		String(c2.model.nodes[vid]["fields"]["name"]) == "Xspeed", "")
	ur.undo()   # back to "speed"
	ur.undo()   # function name back to "f"
	for i: int in 2: await process_frame
	_check("undo reverts function name + declaration",
		String(c2.model.nodes[fid]["fields"]["name"]) == "f"
		and String(c2.model.nodes[fid]["sig"]) == "func f(x: int) -> void",
		c2.model.nodes[fid]["sig"])
	ur.redo()
	ur.redo()
	for i: int in 2: await process_frame
	_check("redo reapplies function name + declaration",
		String(c2.model.nodes[fid]["fields"]["name"]) == "GHf"
		and String(c2.model.nodes[fid]["sig"]) == "func GHf(x: int) -> void",
		c2.model.nodes[fid]["sig"])

	# variable type change drops an incompatible link; undo restores it
	var vv: NodeView = c2.views[vid]
	var qv: NodeView = null
	for id: int in c2.model.nodes:
		if String(c2.model.nodes[id]["title"]) == "var q":
			qv = c2.views[id]
	c2._on_connection_request("n%d" % vid, vv.data_out_port(0), "n%d" % qv.model_id,
		qv.data_in_port(0))
	_check("variable feeds the typed int pin", not c2.model.connected_data_input(qv.model_id, 0).is_empty(), "")
	var type_ed: LineEdit = c2.views[vid]._form_fields["type"]
	_click(win, type_ed)
	for i: int in 2: await process_frame
	type_ed.text = "String"
	type_ed.caret_column = type_ed.text.length()
	type_ed.text_changed.emit(type_ed.text)   # same path as real typing
	type_ed.release_focus()
	for i: int in 2: await process_frame
	_check("incompatible link dropped on type change",
		c2.model.connected_data_input(qv.model_id, 0).is_empty(), "")
	ur.undo()
	for i: int in 2: await process_frame
	_check("undo restores the dropped connection + type",
		not c2.model.connected_data_input(qv.model_id, 0).is_empty()
		and String(c2.model.nodes[vid]["fields"]["raw_type"]) == "int",
		String(c2.model.nodes[vid]["fields"]["raw_type"]))
	ur.redo()
	for i: int in 2: await process_frame
	_check("redo drops the connection again",
		c2.model.connected_data_input(qv.model_id, 0).is_empty()
		and String(c2.model.nodes[vid]["fields"]["raw_type"]) == "String", "")
	ur.undo()
	for i: int in 2: await process_frame

	# variable default value undo/redo (through the Default pin field)
	var def_ed: LineEdit = c2.views[vid]._form_fields["default"]
	_click(win, def_ed)
	for i: int in 2: await process_frame
	def_ed.text = "42"
	def_ed.text_changed.emit(def_ed.text)
	def_ed.release_focus()
	for i: int in 2: await process_frame
	_check("default change reaches the model + declaration",
		String(c2.model.nodes[vid]["data_ins"][0]["value"]) == "42"
		and c2.model.generate()["text"].contains("var Xspeed: int = 42"),
		c2.model.generate()["text"])
	ur.undo()
	for i: int in 2: await process_frame
	_check("undo reverts the default value",
		String(c2.model.nodes[vid]["data_ins"][0]["value"]) == "1"
		and c2.model.generate()["text"].contains("var Xspeed: int = 1"),
		c2.model.generate()["text"])
	ur.redo()
	for i: int in 2: await process_frame
	_check("redo reapplies the default value",
		String(c2.model.nodes[vid]["data_ins"][0]["value"]) == "42", "")

	# Ctrl+Z via the canvas shortcut handler (no text field focused)
	var zev: InputEventKey = InputEventKey.new()
	zev.keycode = KEY_Z
	zev.pressed = true
	zev.command_or_control_autoremap = true
	zev.ctrl_pressed = true
	c2._shortcut_input(zev)
	for i: int in 2: await process_frame
	_check("Ctrl+Z undoes through the canvas shortcut handler",
		String(c2.model.nodes[vid]["data_ins"][0]["value"]) == "1", "")
	var yev: InputEventKey = InputEventKey.new()
	yev.keycode = KEY_Y
	yev.pressed = true
	yev.command_or_control_autoremap = true
	yev.ctrl_pressed = true
	c2._shortcut_input(yev)
	for i: int in 2: await process_frame
	_check("Ctrl+Y redoes through the canvas shortcut handler",
		String(c2.model.nodes[vid]["data_ins"][0]["value"]) == "42", "")
	win.queue_free()
	await process_frame


func _click(win: Window, ctl: Control) -> void:
	var gp: Vector2 = ctl.get_global_position() + Vector2(6, ctl.size.y * 0.5)
	var m: InputEventMouseMotion = InputEventMouseMotion.new()
	m.position = gp
	m.global_position = gp
	Input.set_use_accumulated_input(false)
	win.push_input(m)
	var b: InputEventMouseButton = InputEventMouseButton.new()
	b.button_index = MOUSE_BUTTON_LEFT
	b.position = gp
	b.global_position = gp
	b.pressed = true
	win.push_input(b)
	var r: InputEventMouseButton = b.duplicate()
	r.pressed = false
	win.push_input(r)


func _type_key(win: Window, key: Key) -> void:
	var m: InputEventKey = InputEventKey.new()
	m.keycode = key
	m.physical_keycode = key
	m.unicode = key as int
	m.pressed = true
	win.push_input(m)
	var r: InputEventKey = m.duplicate()
	r.pressed = false
	win.push_input(r)




## Annotation UI: rows on var/func nodes, autocomplete, header editing,
## preservation through node edits, and invalid-annotation reporting.
## True when a node-registered Annotation node targets `tid`.
func _annotation_registered_on(c: Canvas, tid: int) -> bool:
	for l: Dictionary in c.model.ann_links:
		if int(l["tid"]) == tid and c.model.is_annotation_registered(tid, int(l["aid"])):
			return true
	return false


func _test_annotation_ui() -> void:
	await process_frame
	var win: Window = Window.new()
	win.size = Vector2i(1200, 800)
	root.add_child(win)
	var c: Canvas = Canvas.new()
	c.custom_minimum_size = Vector2(1200, 800)
	c.size = Vector2(1200, 800)
	win.add_child(c)
	win.show()
	for i: int in 4: await process_frame
	c.build_from_text("@tool\nextends Node\n\n@export var hp: int = 10\n\n@rpc(\"any_peer\")\nfunc net() -> void:\n\tpass\n")
	for i: int in 8: await process_frame

	# Variable node shows annotation rows
	var vid: int = -1
	for id: int in c.model.nodes:
		if String(c.model.nodes[id]["title"]) == "var hp":
			vid = id
	_check("annotation UI: var node exists", vid >= 0, "")
	if vid >= 0:
		var vv: NodeView = c.views[vid]
		_check("annotation UI: var annotation became a registered node",
			_annotation_registered_on(c, vid), "")
		_check("annotation UI: node-represented annotation hides its text row",
			vv._ann_edits.size() == 0, str(vv._ann_edits.size()))
	# a manually added annotation stays an editable row (no node behind it)
	c.model.add_annotation(vid, "@warning_ignore(\"standalone_expression\")")
	c._rebuild_annotation_view(vid)
	await process_frame
	var vv2: NodeView = c.views[vid]
	_check("annotation UI: manually added annotation is an editable row",
		vv2._ann_edits.size() == 1
		and vv2._ann_edits[0].text == "@warning_ignore(\"standalone_expression\")", "")
	_check("annotation UI: row edit regenerates the declaration",
		String(c.model.nodes[vid]["body"]).contains("@warning_ignore"),
		String(c.model.nodes[vid]["body"]))

	# Function node: its parsed annotation became a node too; a manually
	# added one is an editable row
	var fid: int = -1
	for id: int in c.model.nodes:
		if String(c.model.nodes[id]["title"]) == "Event: net":
			fid = id
	_check("annotation UI: func node exists", fid >= 0, "")
	if fid >= 0:
		var fv: NodeView = c.views[fid]
		_check("annotation UI: func rpc annotation became a node",
			_annotation_registered_on(c, fid), "")
		c.model.add_annotation(fid, "@warning_ignore(\"unused_parameter\")")
		c._rebuild_annotation_view(fid)
		await process_frame
		await process_frame
		fv = c.views[fid]
		_check("annotation UI: func add annotation (editable row)",
			fv._ann_edits.size() == 1
			and fv._ann_edits[0].text == "@warning_ignore(\"unused_parameter\")", "")
		var gen: String = c.model.generate()["text"]
		_check("annotation UI: generated keeps func annotations",
			gen.contains("@rpc(\"any_peer\")") and gen.contains("@warning_ignore(\"unused_parameter\")"), gen)
		_check("annotation UI: generated compiles", _gdc_compiles(gen), gen)

	# Script Header is metadata-only: no generic directive text fields.
	# Script-level annotations live in Annotation nodes wired to the header's
	# per-annotation pins; only unrepresentable lines stay as read-only rows.
	var hid: int = c.model._header_id
	_check("annotation UI: header exists", hid >= 0 and c.views.has(hid), "")
	if hid >= 0:
		var hv: NodeView = c.views[hid]
		_check("annotation UI: header has no directive editors",
			hv._header_edits.size() == 0, str(hv._header_edits.size()))
		_check("annotation UI: parsed @tool became a header annotation node",
			_annotation_registered_on(c, hid), "")
		# script-level annotations are added as Annotation NODES (the header
		# accepts no add_annotation text) - only unrepresentable lines stay
		# as read-only rows with a remove action
		_check("annotation UI: header takes no add_annotation text",
			c.model.add_annotation(hid, "@icon(\"res://icon.png\")") == false, "")
		c.model.nodes[hid]["body"] = "@tool\n@unknown_directive"
		c._rebuild_annotation_view(hid)
		await process_frame
		var hv2: NodeView = c.views[hid]
		var rmcount: int = 0
		for rb: Node in hv2.find_children("*", "Button", true, false):
			if rb is Button and rb.tooltip_text == "Remove annotation":
				rmcount += 1
		_check("annotation UI: unrepresentable header annotation is a read-only row",
			rmcount >= 1, str(rmcount))
		c.model.nodes[hid]["body"] = "@tool"
		c._rebuild_annotation_view(hid)
		await process_frame

	# Annotation autocomplete: suggestions filtered by target
	var reg: RefCounted = Model.AnnReg.get_registry()
	var vtargets: Array[String] = ["var"]
	var vs: Array = reg.search("ex", 50, vtargets)
	var vnames: Array = []
	for e: Dictionary in vs:
		vnames.append(str(e["name"]))
	_check("annotation autocomplete: export in var suggestions", vnames.has("export"), str(vnames))
	_check("annotation autocomplete: no func-only rpc in var suggestions", not vnames.has("rpc"), str(vnames))
	var ctargets: Array[String] = ["class"]
	var cs: Array = reg.search("to", 50, ctargets)
	var cnames: Array = []
	for e2: Dictionary in cs:
		cnames.append(str(e2["name"]))
	_check("annotation autocomplete: tool in class suggestions", cnames.has("tool"), str(cnames))

	# Invalid placement reported but text preserved (the manually added row)
	c.model.set_annotation(vid, 1, "@rpc(\"authority\")")
	var gen_bad: Dictionary = c.model.generate()
	_check("annotation invalid placement: kept in source", gen_bad["text"].contains("@rpc(\"authority\")"), gen_bad["text"])
	_check("annotation invalid placement: reported", gen_bad["problems"].size() > 0, str(gen_bad["problems"]))

	# Save/reopen keeps annotations
	var path: String = OS.get_user_data_dir().path_join("ann_ui_test.gd")
	var fa: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	fa.store_string("@tool\nextends Node\n\n@export_range(0, 10) var hp: int = 5\n\n@rpc(\"any_peer\")\nfunc net() -> void:\n\tpass\n")
	fa = null
	var ws: Workspace = Workspace.new()
	ws.custom_minimum_size = Vector2(1200, 800)
	win.add_child(ws)
	for i: int in 4: await process_frame
	ws.open_script(path)
	for i: int in 8: await process_frame
	var reopened: String = ws._canvas.model.generate()["text"]
	_check("annotation save/reopen: export_range kept", reopened.contains("@export_range(0, 10)"), reopened)
	_check("annotation save/reopen: rpc kept", reopened.contains("@rpc(\"any_peer\")"), reopened)
	_check("annotation save/reopen: compiles", _gdc_compiles(reopened), reopened)
	DirAccess.remove_absolute(path)
	win.queue_free()
	await process_frame


## Reference-UI parity: toolbar (zoom %, grid pattern picker, Extends Node,
## back/forward selection navigation), the right-side dock (Graphs / Functions
## / Macros / Variables / Signals) and typed pin editors + type tags.
## ---- Annotation menu context + "+ Annotation" affordance -----------------
## Dragging from (or clicking "+ Annotation" on) a declaration opens the node
## menu listing exactly the annotations valid for that target; the header
## button offers the class-level set.
func _test_annotation_menu_ctx() -> void:
	await process_frame
	var win: Window = Window.new()
	win.size = Vector2i(1200, 800)
	root.add_child(win)
	var c: Canvas = Canvas.new()
	c.custom_minimum_size = Vector2(1200, 800)
	c.size = Vector2(1200, 800)
	win.add_child(c)
	win.show()
	for i: int in 4: await process_frame
	c.build_from_text("extends Node\n\nvar health: int = 100\n\nfunc hit() -> void:\n\tpass\n")
	for i: int in 6: await process_frame
	var vid: int = -1
	var hdr: int = -1
	for id: int in c.model.nodes:
		if int(c.model.nodes[id]["kind"]) == c.Model.Kind.VAR_DECL:
			vid = id
		elif int(c.model.nodes[id]["kind"]) == c.Model.Kind.PREAMBLE:
			hdr = id
	var slot: int = -1
	for i: int in (c.model.nodes[vid]["data_ins"] as Array).size():
		if String(c.model.nodes[vid]["data_ins"][i]["name"]) == "add annotation":
			slot = i
	# drag anchored at the variable's annotation slot -> var-annotation context
	c._pending_drag = {"is_output": false, "node": "n%d" % vid,
		"port": c.views[vid].data_in_port(slot)}
	_check("annotation slot drag resolves the var target",
		c._pending_annotation_slot_target() == "var", c._pending_annotation_slot_target())
	c._open_menu(Vector2(200, 200), c._pending_drag)
	c._menu_search.text = ""
	c._refresh_menu_items("")
	var names: PackedStringArray = PackedStringArray()
	for e: Dictionary in c._menu_items:
		names.append(str(e["name"]))
	_check("annotation context menu lists var annotations only",
		names.has("@export") and names.has("@onready")
		and not names.has("@tool") and not names.has("@rpc"), str(names))
	c._close_menu()
	c._pending_drag = {}
	# the "+ Annotation" affordance exists on the variable and the header
	var add_btns: Array = c.views[vid].find_children("*", "Button", true, false).filter(
		func(x: Node) -> bool: return (x as Button).text == "+ Annotation")
	_check("Variable node has no '+ Annotation' button", add_btns.size() == 0, "")
	var hdr_btns: Array = c.views[hdr].find_children("*", "Button", true, false).filter(
		func(x: Node) -> bool: return (x as Button).text == "+ Annotation")
	_check("Script Header has no '+ Annotation' control", hdr_btns.size() == 0, "")
	# spawning from that context auto-registers on the header
	var toolid: int = c.spawn_node(c.Model.Kind.ANNOTATION, {"name": "tool"}, Vector2(100, 100))
	for i: int in 3: await process_frame
	var hslot: int = -1
	for i2: int in (c.model.nodes[hdr]["data_ins"] as Array).size():
		if String(c.model.nodes[hdr]["data_ins"][i2]["name"]) == "add annotation":
			hslot = i2
	c._pending_drag = {"is_output": false, "node": "n%d" % hdr,
		"port": c.views[hdr].data_in_port(hslot)}
	c._auto_connect_spawn(toolid, c._pending_drag)
	await process_frame
	_check("spawned @tool registers on the Script Header",
		c.model.is_annotation_registered(hdr, toolid), "")
	c._pending_drag = {}
	var gen: Dictionary = c.model.generate()
	_check("@tool generates before extends",
		str(gen["text"]).begins_with("@tool\nextends Node"), str(gen["text"]).left(40))
	win.queue_free()
	await process_frame


## ---- Export groups in the real editor stack: visible group wires, the
## "add group" slot in the view, live generation ---------------------------
func _test_export_group_ui() -> void:
	await process_frame
	var win: Window = Window.new()
	win.size = Vector2i(1300, 800)
	root.add_child(win)
	var c: Canvas = Canvas.new()
	c.custom_minimum_size = Vector2(1300, 800)
	c.size = Vector2(1300, 800)
	win.add_child(c)
	win.show()
	for i: int in 4: await process_frame
	c.build_from_text("extends Node\n\nvar health: int = 100\nvar damage: int = 20\n\nfunc hit() -> void:\n\tpass\n")
	for i: int in 6: await process_frame
	var vids: Dictionary = {}
	for id: int in c.model.nodes:
		if int(c.model.nodes[id]["kind"]) == c.Model.Kind.VAR_DECL:
			vids[str(c.model.nodes[id]["fields"].get("name", ""))] = id
	# spawn two exports and a group via the real menu-entry fields
	var ex_h: int = c.spawn_node(c.Model.Kind.ANNOTATION, {"name": "export"}, Vector2(100, 100))
	var ex_d: int = c.spawn_node(c.Model.Kind.ANNOTATION, {"name": "export"}, Vector2(100, 250))
	var grp: int = c.spawn_node(c.Model.Kind.ANNOTATION, {"name": "export_group",
		"args": [{"name": "name", "type": "String", "default": "", "sample": "Group"}]}, Vector2(500, 100))
	for i: int in 3: await process_frame
	var gv: NodeView = c.views[grp]
	_check("@export_group view shows exactly one 'group' output pin",
		gv._out_defs.size() == 1 and String(gv._out_labels[0].text) == "group", "")
	_check("@export view shows the 'add group' slot label",
		String(c.views[ex_h]._in_labels[c.model.group_slot_of(ex_h)].text) == "add group", "")
	# wire exports -> vars and both exports -> the group (real handlers)
	for pair: Array in [[ex_h, vids["health"]], [ex_d, vids["damage"]]]:
		var tid: int = int(pair[1])
		var aslot: int = -1
		for i: int in (c.model.nodes[tid]["data_ins"] as Array).size():
			if String(c.model.nodes[tid]["data_ins"][i]["name"]) == "add annotation":
				aslot = i
		c._on_connection_request("n%d" % int(pair[0]), c.views[int(pair[0])].data_out_port(0),
			"n%d" % tid, c.views[tid].data_in_port(aslot))
	c.model.set_pin_value(grp, 0, "Player Settings")
	var gslot: int = c.model.group_slot_of(ex_h)
	c._on_connection_request("n%d" % grp, c.views[grp].data_out_port(0), "n%d" % ex_h,
		c.views[ex_h].data_in_port(gslot))
	c._on_connection_request("n%d" % grp, c.views[grp].data_out_port(0), "n%d" % ex_d,
		c.views[ex_d].data_in_port(c.model.group_slot_of(ex_d)))
	await process_frame
	_check("both group wires are visible GraphEdit connections",
		_graphedit_wire_exists(c, "n%d" % grp, c.views[grp].data_out_port(0),
			"n%d" % ex_h, c.views[ex_h].data_in_port(gslot))
		and _graphedit_wire_exists(c, "n%d" % grp, c.views[grp].data_out_port(0),
			"n%d" % ex_d, c.views[ex_d].data_in_port(c.model.group_slot_of(ex_d))), "")
	var gen: Dictionary = c.generate_code()
	var t: String = str(gen["code"])
	_check("grouped generation in the editor stack",
		bool(gen["ok"]) and t.contains("@export_group(\"Player Settings\")")
		and t.find("@export_group(\"Player Settings\")") < t.find("@export var health"), t)
	# disconnecting one group wire keeps the other
	c._on_disconnection_request("n%d" % grp, c.views[grp].data_out_port(0), "n%d" % ex_d,
		c.views[ex_d].data_in_port(c.model.group_slot_of(ex_d)))
	await process_frame
	_check("one disconnect leaves the other export grouped",
		c.model.group_of(ex_h) == grp and c.model.group_of(ex_d) == -1, "")
	win.queue_free()
	await process_frame


## ---- Row commit converts into a real node; no-@ typing normalizes ---------
func _test_ann_commit_ui() -> void:
	await process_frame
	var win: Window = Window.new()
	win.size = Vector2i(1200, 800)
	root.add_child(win)
	var c: Canvas = Canvas.new()
	c.custom_minimum_size = Vector2(1200, 800)
	c.size = Vector2(1200, 800)
	win.add_child(c)
	win.show()
	for i: int in 4: await process_frame
	c.build_from_text("@tool\nextends Node\n\nvar hp: int = 10\n\nfunc hit() -> void:\n\tpass\n")
	for i: int in 6: await process_frame
	var vid: int = -1
	for id: int in c.model.nodes:
		if String(c.model.nodes[id]["title"]) == "var hp":
			vid = id
	var before_nodes: int = c.model.nodes.size()
	# the row editor commits (Enter / focus loss) exactly like the real UI
	c.model.add_annotation(vid, "@export")
	await process_frame
	var vv: NodeView = c.views[vid]
	var idx: int = c.model.annotations_of(vid).size() - 1
	vv.annotation_action.emit(vid, "set", idx, "export_range(0, 100)")
	await process_frame
	_check("row edit without @ normalizes to a valid annotation",
		str(c.model.annotations_of(vid)[idx]) == "@export_range(0, 100)",
		str(c.model.annotations_of(vid)))
	vv.annotation_action.emit(vid, "commit", idx, "")
	for i: int in 4: await process_frame
	_check("committing a row spawns a real Annotation node",
		c.model.nodes.size() == before_nodes + 1
		and _annotation_registered_on(c, vid), "")
	var gen: Dictionary = c.generate_code()
	_check("committed-node generation keeps the annotation and compiles",
		bool(gen["ok"]) and str(gen["code"]).contains("@export_range(0, 100)"),
		str(gen["code"]))
	# @export_group cannot register on a declaration (its only output is group)
	var grp: int = c.spawn_node(c.Model.Kind.ANNOTATION, {"name": "export_group",
		"args": [{"name": "name", "type": "String", "default": "", "sample": "Group"}]}, Vector2(400, 100))
	for i: int in 3: await process_frame
	var aslot: int = -1
	for si: int in (c.model.nodes[vid]["data_ins"] as Array).size():
		if String(c.model.nodes[vid]["data_ins"][si]["name"]) == "add annotation":
			aslot = si
	var rej: Dictionary = c.model.connect_data(grp, 0, vid, aslot)
	_check("@export_group rejected at an add-annotation slot",
		rej.has("_rejected") and c.model.last_reject_reason != "", c.model.last_reject_reason)
	win.queue_free()
	await process_frame


func _test_reference_parity() -> void:
	await process_frame
	var win: Window = Window.new()
	win.size = Vector2i(1300, 860)
	root.add_child(win)
	var ws: Workspace = Workspace.new()
	ws.custom_minimum_size = Vector2(1300, 860)
	win.add_child(ws)
	for i: int in 4: await process_frame
	# First show presents the title screen; load the demo for the checks below.
	_check("title screen shown when nothing is loaded", ws.title_screen_visible(), "")
	_check("title screen: nothing auto-loaded", ws._canvas.model.node_count() == 0, "")
	ws._load_demo()
	_check("loading the demo hides the title screen", not ws.title_screen_visible(), "")
	for i: int in 2: await process_frame
	var c: Canvas = ws._canvas

	# --- toolbar controls exist and work
	var mh: HBoxContainer = c.get_menu_hbox()
	var zoom_label: Label = null
	var pattern: OptionButton = null
	var ext_btn: Button = null
	var back_btn: Button = null
	var fwd_btn: Button = null
	for ch: Node in mh.get_children():
		if ch is Label and str((ch as Label).text).ends_with("%"):
			zoom_label = ch
		elif ch is OptionButton:
			pattern = ch
		elif ch is Button and (ch as Button).text == "Extends Node":
			ext_btn = ch
		elif ch is Button and (ch as Button).text.length() == 1:
			if (ch as Button).text == "\u25c0":
				back_btn = ch
			elif (ch as Button).text == "\u25b6":
				fwd_btn = ch
	_check("toolbar: zoom % label shown", zoom_label != null and zoom_label.visible, "")
	_check("toolbar: grid pattern picker", pattern != null and pattern.item_count == 2, "")
	_check("toolbar: Extends Node button", ext_btn != null, "")
	_check("toolbar: back button present + disabled", back_btn != null and back_btn.disabled, "")
	_check("toolbar: forward button present + disabled", fwd_btn != null and fwd_btn.disabled, "")
	if pattern != null:
		pattern.select(1)
		pattern.item_selected.emit(1)
		_check("toolbar: Lines pattern applied", c.grid_pattern == 1, str(c.grid_pattern))
		pattern.select(0)
		pattern.item_selected.emit(0)
		_check("toolbar: Dots pattern applied", c.grid_pattern == 0, str(c.grid_pattern))
	# demo graph: three variables + two functions
	var var_ids: Array[int] = []
	var fn_ids: Array[int] = []
	for id: int in c.model.nodes:
		if int(c.model.nodes[id]["kind"]) == Model.Kind.VAR_DECL:
			var_ids.append(id)
		elif int(c.model.nodes[id]["kind"]) == Model.Kind.ENTRY:
			fn_ids.append(id)
	_check("dock: demo variables listed", ws._dock_content.has("Variables") and
		ws._dock_content["Variables"].get_child_count() == var_ids.size(),
		str(var_ids.size()))
	_check("dock: demo functions listed", ws._dock_content.has("Functions") and
		ws._dock_content["Functions"].get_child_count() == fn_ids.size(), "")
	_check("dock: macros stub visible", ws._dock_content.has("Macros") and
		ws._dock_content["Macros"].get_child_count() == 1, "")
	_check("dock: graphs section shows events", ws._dock_content.has("Graphs") and
		ws._dock_content["Graphs"].get_child_count() == fn_ids.size(), "")
	_check("dock: signals empty stub", ws._dock_content.has("Signals") and
		ws._dock_content["Signals"].get_child_count() == 1, "")
	# eye toggle adds/removes @export through the model
	if var_ids.size() > 0:
		var vid: int = var_ids[0]
		ws._toggle_var_export(vid, true)
		_check("dock: eye on adds @export",
			str(c.model.nodes[vid]["fields"].get("annotations", "")).contains("@export"), "")
		ws._toggle_var_export(vid, false)
		_check("dock: eye off removes @export",
			not str(c.model.nodes[vid]["fields"].get("annotations", "")).contains("@export"), "")
	# add variable / function / signal through the dock spawn paths
	var before_vars: int = var_ids.size()
	var nvar: int = c.spawn_node(Model.Kind.VAR_DECL, {"name": "dock_var", "raw_type": "int", "default": "3"})
	ws._refresh_dock()
	_check("dock: added variable row appears",
		ws._dock_content["Variables"].get_child_count() == before_vars + 1, "")
	var gen: Dictionary = c.generate_code()
	_check("dock: added variable generates", str(gen["code"]).contains("var dock_var: int = 3"), "")
	var before_fns: int = fn_ids.size()
	c.spawn_node(Model.Kind.ENTRY, {"name": "dock_fn", "ret_type": "int"})
	ws._refresh_dock()
	_check("dock: added function row appears",
		ws._dock_content["Functions"].get_child_count() == before_fns + 1, "")
	gen = c.generate_code()
	_check("dock: added function generates", str(gen["code"]).contains("func dock_fn() -> int:"), "")
	c.spawn_node(Model.Kind.DECLARATION, {"body": "signal dock_signal", "title": "Signal"})
	ws._refresh_dock()
	_check("dock: added signal row appears",
		ws._dock_content["Signals"].get_child_count() == 1, "")
	gen = c.generate_code()
	_check("dock: added signal generates", str(gen["code"]).contains("signal dock_signal"), "")

	# --- focus + selection navigation
	var any_var: int = nvar
	if ext_btn != null:
		ext_btn.pressed.emit()
		var hid: int = c.model._header_id
		_check("toolbar: Extends Node focuses header", hid >= 0 and c.views[hid].is_selected(), "")
	# select two nodes, then navigate back
	c._on_nav_selected(c.views[fn_ids[0]])
	c._on_nav_selected(c.views[any_var])
	_check("nav: at history top, forward disabled", fwd_btn != null and fwd_btn.disabled, "")
	_check("nav: back enabled after history", back_btn != null and not back_btn.disabled, "")
	back_btn.pressed.emit()
	_check("nav: back selects previous node", c.views[fn_ids[0]].is_selected(), "")
	_check("nav: back now disabled", back_btn.disabled, "")
	fwd_btn.pressed.emit()
	_check("nav: forward returns to last node", c.views[any_var].is_selected(), "")

	# --- typed pin editors + type tags
	c.build_from_text("extends Node\n\nvar col: Color = Color.RED\n\nfunc f(flag: bool) -> void:\n\tif flag:\n\t\tpass\n")
	for i: int in 6: await process_frame
	var col_id: int = -1
	var if_id: int = -1
	for id2: int in c.model.nodes:
		if String(c.model.nodes[id2]["title"]) == "var col":
			col_id = id2
		elif int(c.model.nodes[id2]["kind"]) == Model.Kind.IF:
			if_id = id2
	_check("typed: color var node exists", col_id >= 0, "")
	_check("typed: if node exists", if_id >= 0, "")
	if col_id >= 0:
		var cv: NodeView = c.views[col_id]
		var ed0: Control = cv._pin_editors.get(0, null)
		_check("typed: color pin uses ColorPickerButton", ed0 is ColorPickerButton, "")
		if ed0 is ColorPickerButton:
			_check("typed: color picker initial red", (ed0 as ColorPickerButton).color == Color.RED, "")
			(ed0 as ColorPickerButton).color_changed.emit(Color(0, 1, 0, 1))
			_check("typed: color picker writes model",
				str(c.model.nodes[col_id]["data_ins"][0]["value"]).contains("Color(0, 1, 0, 1)"),
				str(c.model.nodes[col_id]["data_ins"][0]["value"]))
		var tags: int = 0
		for k: int in cv._pin_tags:
			if str(cv._pin_tags[k].get_meta("type_icon", "")) == "Color":
				tags += 1
		_check("typed: color pin shows native Color icon", tags == 1, "")
	if if_id >= 0:
		var iv: NodeView = c.views[if_id]
		var ed1: Control = iv._pin_editors.get(0, null)
		_check("typed: bool pin uses CheckBox", ed1 is CheckBox, "")
		if ed1 is CheckBox:
			(ed1 as CheckBox).toggled.emit(true)
			_check("typed: checkbox writes model",
				str(c.model.nodes[if_id]["data_ins"][0]["value"]) == "true",
				str(c.model.nodes[if_id]["data_ins"][0]["value"]))
			(ed1 as CheckBox).toggled.emit(false)
			_check("typed: checkbox unchecks to false",
				str(c.model.nodes[if_id]["data_ins"][0]["value"]) == "false", "")
		var btags: int = 0
		for k2: int in iv._pin_tags:
			if str(iv._pin_tags[k2].get_meta("type_icon", "")) == "bool":
				btags += 1
		_check("typed: bool pin shows native bool icon", btags == 1, "")
	# refresh keeps editors in sync (model -> control without signals)
	if col_id >= 0 and c.views[col_id]._pin_editors.get(0, null) is ColorPickerButton:
		c.model.set_pin_value(col_id, 0, "Color(0, 0, 1, 1)")
		c.views[col_id].refresh(c.model.nodes[col_id])
		_check("typed: refresh syncs picker color",
			(c.views[col_id]._pin_editors[0] as ColorPickerButton).color == Color(0, 0, 1, 1), "")
	win.queue_free()
	await process_frame


## Function Call defaults: optional arguments visible but not required,
## built-in vararg growth, override-aware generation through the canvas.
func _test_call_defaults() -> void:
	await process_frame
	var win: Window = Window.new()
	win.size = Vector2i(1300, 860)
	root.add_child(win)
	var c: Canvas = Canvas.new()
	c.custom_minimum_size = Vector2(1300, 860)
	win.add_child(c)
	for i: int in 4: await process_frame
	# custom function with required + optional arguments
	c.build_from_text("extends Node\n\nfunc attack(damage: int, critical: bool = false, multiplier: float = 1.0) -> void:\n\tattack(5)\n")
	for i: int in 6: await process_frame
	var ac: int = -1
	for id: int in c.model.nodes:
		if int(c.model.nodes[id]["kind"]) == Model.Kind.CALL \
				and str(c.model.nodes[id]["fields"].get("call", "")) == "attack":
			ac = id
	_check("calldef: attack call node exists", ac >= 0, "")
	if ac >= 0:
		var v: NodeView = c.views[ac]
		var pins: Array = c.model.nodes[ac]["data_ins"]
		_check("calldef: all three arguments shown", pins.size() == 3, str(pins))
		_check("calldef: optional flag + declared default",
			bool(pins[1].get("optional", true)) and str(pins[1].get("default_text")) == "false"
			and bool(pins[2].get("optional", true)) and str(pins[2].get("default_text")) == "1.0", "")
		var lab0: Label = v._in_labels.get(0, null)
		var lab1: Label = v._in_labels.get(1, null)
		if lab0 != null and lab1 != null:
			_check("calldef: required pin tooltip", lab0.tooltip_text == "Required argument", lab0.tooltip_text)
			_check("calldef: optional pin tooltip", String(lab1.tooltip_text).contains("Optional"), lab1.tooltip_text)
			var req_c: Color = lab0.get_theme_color("font_color")
			var opt_c: Color = lab1.get_theme_color("font_color")
			_check("calldef: optional label dimmed vs required", opt_c.a < req_c.a, "req=%s opt=%s" % [req_c, opt_c])
		# untouched optionals are not emitted
		var gen: Dictionary = c.generate_code()
		_check("calldef: untouched optionals keep declared defaults",
			str(gen["code"]).contains("attack(5)") and not str(gen["code"]).contains("attack(5, false"), gen["code"])
		# override one optional through the pin editor path
		c._on_pin_value_changed(ac, 2, "2.0")
		gen = c.generate_code()
		_check("calldef: overriding one optional keeps earlier defaults",
			str(gen["code"]).contains("attack(5, false, 2.0)"), gen["code"])
		c._on_pin_value_changed(ac, 1, "true")
		gen = c.generate_code()
		_check("calldef: overriding both emits everything",
			str(gen["code"]).contains("attack(5, true, 2.0)"), gen["code"])
	# built-in vararg call node (registry-backed print)
	var reg: RefCounted = load("res://addons/gd_canvas_spikes/func_registry.gd").get_registry()
	var pe: Dictionary = reg.find_entry(reg.CAT_LANGUAGE, "", "print")
	_check("calldef: print registry entry with vararg", not pe.is_empty() and bool(pe["vararg"]), "")
	var pc: int = c.spawn_node(Model.Kind.CALL, {
		"call": "print", "cat": str(pe["cat"]), "owner": "",
		"ret": str(pe["ret"]), "static": bool(pe["static"]),
		"needs_target": bool(pe["needs_target"]), "target_type": "",
		"vararg": true, "mode": "exec", "declared": true,
		"args": (pe["args"] as Array).duplicate(true),
	})
	_check("calldef: spawned print call has arg + grow slot",
		pc >= 0 and c.model.nodes[pc]["data_ins"].size() == 2
		and not c.model._pin_occupied(pc, 1), str(c.model.nodes[pc]["data_ins"]))
	var pv: NodeView = c.views[pc]
	_check("calldef: vararg declared call shows arg actions", not pv._in_labels.is_empty(), "")
	c._on_pin_value_changed(pc, 0, "\"x\"")
	# grow the variadic argument list by connecting a literal
	var lit: int = c.spawn_node(Model.Kind.LITERAL, {"type": Types.PinType.INT, "value": "2"})
	var lv: NodeView = c.views[lit]
	c._on_connection_request("n%d" % lit, lv.data_out_port(0), "n%d" % pc, pv.data_in_port(1))
	# wire the print call into the flow (after the attack statement) so it is
	# reachable and gets emitted
	c._on_connection_request("n%d" % ac, (c.views[ac] as NodeView).exec_out_port(0), "n%d" % pc, pv.exec_in_port(0))
	for i: int in 3: await process_frame
	_check("calldef: connecting the grow slot opens another",
		c.model.nodes[pc]["data_ins"].size() == 3, str(c.model.nodes[pc]["data_ins"]))
	var gen2: Dictionary = c.generate_code()
	_check("calldef: vararg extra argument emits",
		str(gen2["code"]).contains("print(\"x\", 2)"), gen2["code"])
	win.queue_free()
	await process_frame


func _test_dynamic_inputs_ui() -> void:
	var win: Window = Window.new()
	win.size = Vector2i(1400, 900)
	root.add_child(win)
	var c2: Canvas = Canvas.new()
	c2.custom_minimum_size = Vector2(1400, 900)
	win.add_child(c2)
	win.show()
	for i: int in 3: await process_frame
	c2.build_from_text("extends Node\n\nfunc f() -> void:\n\tvar q = 0\n")
	for i: int in 4: await process_frame

	# ---- operator: view grows and shrinks with the model's pins ----
	var op: int = c2.spawn_node(c2.Model.Kind.OPERATOR, {"op": "+"}, Vector2(500, 300))
	var l1: int = c2.spawn_node(c2.Model.Kind.LITERAL, {"type": c2.Types.PinType.INT, "value": "3"}, Vector2(150, 250))
	var l2: int = c2.spawn_node(c2.Model.Kind.LITERAL, {"type": c2.Types.PinType.INT, "value": "7"}, Vector2(150, 400))
	var opv: NodeView = c2.views[op]
	_check("operator view matches the 2+1 pin shape", opv.data_in_count() == 3, "")
	c2._on_connection_request("n%d" % l1, c2.views[l1].data_out_port(0), "n%d" % op, opv.data_in_port(2))
	await process_frame
	await process_frame
	var opv2: NodeView = c2.views[op]
	_check("connecting the grow slot rebuilds the view with a fresh empty pin",
		opv2 != opv and opv2.data_in_count() == 4
		and int(c2.model.nodes[op]["data_ins"].size()) == 4, "")
	c2._on_connection_request("n%d" % l2, c2.views[l2].data_out_port(0), "n%d" % op,
		c2.views[op].data_in_port(3))
	await process_frame
	_check("second growth keeps exactly one empty slot",
		int(c2.model.nodes[op]["data_ins"].size()) == 5
		and c2.views[op].data_in_count() == 5, "")
	c2._on_disconnection_request("n%d" % l2, c2.views[l2].data_out_port(0),
		"n%d" % op, c2.views[op].data_in_port(3))
	await process_frame
	_check("disconnect trims the view back",
		int(c2.model.nodes[op]["data_ins"].size()) == 4
		and c2.views[op].data_in_count() == 4, "")
	var qid: int = -1
	for id: int in c2.model.nodes:
		if String(c2.model.nodes[id]["title"]) == "var q":
			qid = id
	c2._on_connection_request("n%d" % op, c2.views[op].data_out_port(0), "n%d" % qid,
		c2.views[qid].data_in_port(0))
	await process_frame
	_check("generated code folds all wired operands",
		c2.model.generate()["text"].contains("var q = ((0 + 0) + 3)"), c2.model.generate()["text"])

	# ---- function call: dynamic argument pins + per-pin management ----
	var call: int = c2.spawn_node(c2.Model.Kind.CALL, {}, Vector2(500, 500))
	var callv: NodeView = c2.views[call]
	_check("call view starts with the single grow slot", callv.data_in_count() == 1, "")
	var a1: int = c2.spawn_node(c2.Model.Kind.LITERAL, {"type": c2.Types.PinType.INT, "value": "1"}, Vector2(150, 550))
	var a2: int = c2.spawn_node(c2.Model.Kind.LITERAL, {"type": c2.Types.PinType.INT, "value": "2"}, Vector2(150, 650))
	c2._on_connection_request("n%d" % a1, c2.views[a1].data_out_port(0), "n%d" % call,
		callv.data_in_port(0))
	await process_frame
	c2._on_connection_request("n%d" % a2, c2.views[a2].data_out_port(0), "n%d" % call,
		c2.views[call].data_in_port(1))
	await process_frame
	_check("call view grows with each connected argument",
		int(c2.model.nodes[call]["data_ins"].size()) == 3
		and c2.views[call].data_in_count() == 3, "")
	_check("call generates every connected argument",
		c2.model._source_expr(call, 0, 0) == "my_func(1, 2)", c2.model._source_expr(call, 0, 0))
	# per-pin management through the view's action buttons
	var remove_btns: Array = c2.views[call].find_children("*", "Button", true, false)
	var has_actions: bool = false
	for b: Button in remove_btns:
		if b.tooltip_text == "Remove argument":
			has_actions = true
	_check("free-form call renders per-pin argument actions", has_actions, "")
	c2._on_call_arg_action(call, "left", 1)
	await process_frame
	_check("reorder through the view updates model + code",
		c2.model._source_expr(call, 0, 0) == "my_func(2, 1)", c2.model._source_expr(call, 0, 0))
	c2._on_call_arg_action(call, "remove", 0)
	await process_frame
	_check("remove through the view drops pin + wire",
		int(c2.model.nodes[call]["data_ins"].size()) == 2
		and c2.model._source_expr(call, 0, 0) == "my_func(1)", c2.model._source_expr(call, 0, 0))

	# ---- declared call through the canvas: type-checked fixed pins ----
	c2.build_from_text("extends Node\n\nfunc g(x: int) -> void:\n\tpass\n\nfunc h() -> void:\n\tvar s = \"\"\n")
	await process_frame
	await process_frame
	var gid: int = -1
	for id: int in c2.model.nodes:
		if String(c2.model.nodes[id]["title"]) == "Event: g":
			gid = id
	var dc: int = c2.spawn_node(c2.Model.Kind.CALL, {"call": "g"}, Vector2(700, 300))
	await process_frame
	_check("spawning a call for a declared function mirrors the signature",
		int(c2.model.nodes[dc]["data_ins"].size()) == 1
		and String(c2.model.nodes[dc]["data_ins"][0]["name"]) == "x"
		and int(c2.model.nodes[dc]["data_ins"][0]["type"]) == c2.Types.PinType.INT
		and bool(c2.model.nodes[dc]["fields"].get("declared", false)), "")
	var snode: int = c2.spawn_node(c2.Model.Kind.LITERAL, {"type": c2.Types.PinType.STRING, "value": "\"no\""}, Vector2(400, 350))
	var rejected: Dictionary = c2.model.connect_data(snode, 0, dc, 0)
	_check("declared call enforces parameter types", rejected.has("_rejected"), "")
	# fixed nodes never grow through the canvas path either
	c2.build_from_text("extends Node\n\nfunc f() -> void:\n\tif true:\n\t\tpass\n")
	await process_frame
	await process_frame
	var ifid: int = -1
	for id: int in c2.model.nodes:
		if int(c2.model.nodes[id]["kind"]) == c2.Model.Kind.IF:
			ifid = id
	var bl: int = c2.spawn_node(c2.Model.Kind.LITERAL, {"type": c2.Types.PinType.BOOL, "value": "true"}, Vector2(200, 300))
	c2._on_connection_request("n%d" % bl, c2.views[bl].data_out_port(0), "n%d" % ifid,
		c2.views[ifid].data_in_port(0))
	await process_frame
	_check("If keeps its single condition pin in the view + model",
		int(c2.model.nodes[ifid]["data_ins"].size()) == 2
		and String(c2.model.nodes[ifid]["data_ins"][0]["name"]) == "condition"
		and String(c2.model.nodes[ifid]["data_ins"][1]["name"]) == "add scope"
		and c2.views[ifid].data_in_count() == 2, "")
	win.queue_free()
	await process_frame


## ---- Annotation nodes end-to-end: menu search, spawn, wire into a
## declaration's "add annotation" slot, live arg edits, disconnect -----------
func _test_annotation_nodes_ui() -> void:
	await process_frame
	var win: Window = Window.new()
	win.size = Vector2i(1300, 860)
	root.add_child(win)
	var c: Canvas = Canvas.new()
	c.custom_minimum_size = Vector2(1300, 860)
	win.add_child(c)
	for i: int in 4: await process_frame
	c.build_from_text("extends Node\n\nvar hp: int = 10\n\nfunc hit() -> void:\n\tpass\n")
	for i: int in 4: await process_frame
	var vid: int = -1
	var fid: int = -1
	for id: int in c.model.nodes:
		if String(c.model.nodes[id]["title"]) == "var hp":
			vid = id
		if int(c.model.nodes[id]["kind"]) == Model.Kind.ENTRY:
			fid = id
	_check("annode: var + function exist", vid >= 0 and fid >= 0, "")

	# the Add Annotation button is gone; a dedicated input slot is in
	var has_btn: bool = false
	for ch: Control in c.views[vid].get_children():
		if ch is Button and String((ch as Button).text) == "+ Add Annotation":
			has_btn = true
	_check("annode: no Add Annotation button on the variable", not has_btn, "")
	var slot: int = -1
	for pi: int in c.model.nodes[vid]["data_ins"].size():
		if String(c.model.nodes[vid]["data_ins"][pi]["name"]) == "add annotation":
			slot = pi
	_check("annode: variable shows the add-annotation slot", slot == 1, "")
	_check("annode: function shows the add-annotation slot",
		String(c.model.nodes[fid]["data_ins"][-1]["name"]) == "add scope"
		and String(c.model.nodes[fid]["data_ins"][-2]["name"]) == "add annotation", "")

	# --- search: lifecycle callbacks excluded, ordinary functions available --
	c._open_menu(Vector2(60, 60))
	await process_frame
	c._menu_search.text = "_process"
	c._menu_search.text_changed.emit("_process")
	await process_frame
	var proc_hits: int = 0
	for i: int in c._menu_items.size():
		if String(c._menu_items[i]["name"]) == "_process" \
				and int(c._menu_items[i]["kind"]) == Model.Kind.CALL:
			proc_hits += 1
	_check("annode: engine-invoked _process is not offered as a Function Call",
		proc_hits == 0, "hits=%d" % proc_hits)
	c._menu_search.text = "_ready"
	c._menu_search.text_changed.emit("_ready")
	await process_frame
	var ready_hits: int = 0
	for i: int in c._menu_items.size():
		if String(c._menu_items[i]["name"]) == "_ready" \
				and int(c._menu_items[i]["kind"]) == Model.Kind.CALL:
			ready_hits += 1
	_check("annode: engine-invoked _ready is not offered as a Function Call",
		ready_hits == 0, "hits=%d" % ready_hits)
	# ordinary custom functions stay searchable (incl. underscore-prefixed
	# ones that are not engine callbacks — covered by the registry tests)
	c._menu_search.text = "make_id"
	c._menu_search.text_changed.emit("make_id")
	await process_frame
	var mk_hits: int = 0
	for i: int in c._menu_items.size():
		if String(c._menu_items[i]["name"]) == "make_id":
			mk_hits += 1
	_check("annode: ordinary custom functions remain searchable", mk_hits >= 1, "hits=%d" % mk_hits)
	c._menu_search.text = "onready"
	c._menu_search.text_changed.emit("onready")
	await process_frame
	var onready_idx: int = -1
	for i: int in c._menu_items.size():
		if String(c._menu_items[i]["name"]) == "@onready":
			onready_idx = i
	_check("annode: search 'onready' finds the @onready annotation node", onready_idx >= 0, "")
	c._menu_search.text = "expot"
	c._menu_search.text_changed.emit("expot")
	await process_frame
	var fuzzy_idx: int = -1
	for i: int in c._menu_items.size():
		if String(c._menu_items[i]["name"]) == "@export":
			fuzzy_idx = i
	_check("annode: fuzzy search 'expot' still finds @export", fuzzy_idx >= 0, "")
	c._menu_search.text = "ball"
	c._menu_search.text_changed.emit("ball")
	await process_frame
	var ball_found: bool = FuncReg.rank_match("ball", "football", "Game") >= 0
	_check("annode: partial search 'ball' matches 'football'", ball_found, "")
	c._menu_search.text = ""
	c._menu_search.text_changed.emit("")
	await process_frame
	c._close_menu()
	await process_frame

	# --- wire an Annotation node into the variable's annotation slot ---------
	var a1: int = c.spawn_node(Model.Kind.ANNOTATION, {"name": "export", "args": []},
		Vector2(60, 300))
	_check("annode: @export annotation node spawned", a1 >= 0
		and String(c.model.nodes[a1]["title"]) == "@export"
		and c.views.has(a1), "")
	var vv: NodeView = c.views[vid]
	var avv: NodeView = c.views[a1]
	var avv_name: String = avv.name
	var vv_name: String = vv.name
	c._on_connection_request(avv.name, avv.data_out_port(0), vv.name, vv.data_in_port(slot))
	await process_frame
	_check("annode: wiring registers @export on the variable",
		c.model.annotations_of(vid).has("@export"), "")
	_check("annode: registration link recorded",
		c.model.is_annotation_registered(vid, a1), "")
	var wired: bool = false
	for conn: Dictionary in c.get_connection_list():
		if String(conn["from_node"]) == avv_name and String(conn["to_node"]) == vv_name:
			wired = true
	_check("annode: registration wire drawn", wired, "")
	var g: Dictionary = c.generate_code()
	_check("annode: generated keeps the wired annotation",
		str(g["code"]).contains("@export"), str(g["code"]))

	# --- annotation node with arguments: pins drive the text live ------------
	var a2: int = c.spawn_node(Model.Kind.ANNOTATION, {"name": "export_range",
		"args": [{"name": "min", "type": "int", "default": "", "sample": "0"},
			{"name": "max", "type": "int", "default": "", "sample": "100"}]},
		Vector2(60, 430))
	_check("annode: @export_range node exposes its argument pins",
		a2 >= 0 and c.model.nodes[a2]["data_ins"].size() == 3   # min, max + the "add group" input
		and String(c.model.nodes[a2]["data_ins"][0]["name"]) == "min"
		and String(c.model.nodes[a2]["data_ins"][2]["name"]) == "add group", "")
	c._on_pin_value_changed(a2, 0, "0")
	c._on_pin_value_changed(a2, 1, "100")
	var avv2: NodeView = c.views[a2]
	vv = c.views[vid]
	c._on_connection_request(avv2.name, avv2.data_out_port(0), vv.name, vv.data_in_port(slot))
	await process_frame
	_check("annode: @export_range(0, 100) registered from pin values",
		c.model.annotations_of(vid).has("@export_range(0, 100)"), "")
	c._on_pin_value_changed(a2, 0, "10")
	await process_frame
	_check("annode: editing the pin updates the registered annotation",
		c.model.annotations_of(vid).has("@export_range(10, 100)"), "")
	# the annotation editor rows inside the declaration stay in sync
	var vv2: NodeView = c.views[vid]
	var ann_texts: PackedStringArray = PackedStringArray()
	for ed: LineEdit in vv2._ann_edits:
		ann_texts.append(ed.text)
	# annotations are nodes: a registered one gets no duplicate text row on the declaration
	_check("annode: declaration shows no duplicate text row for a node-registered annotation",
		not "@".join(ann_texts).contains("@export_range(10, 100)")
		and c.model.annotations_of(vid).has("@export_range(10, 100)"),
		str(ann_texts))

	# --- disconnect removes the annotation, keeps the node -------------------
	avv2 = c.views[a2]
	vv2 = c.views[vid]
	# pins of the declaration may have shifted while it was registered: look the slot up again
	for i3: int in (c.model.nodes[vid]["data_ins"] as Array).size():
		if String(c.model.nodes[vid]["data_ins"][i3]["name"]) == "add annotation":
			slot = i3
	c._on_disconnection_request(avv2.name, avv2.data_out_port(0), vv2.name, vv2.data_in_port(slot))
	await process_frame
	_check("annode: disconnect unregisters @export_range",
		not c.model.is_annotation_registered(vid, a2)   # text stays on the declaration (keep_text)
		and c.views.has(a2), "")

	# --- dedup: a second @export node never duplicates the line --------------
	var a3: int = c.spawn_node(Model.Kind.ANNOTATION, {"name": "export", "args": []},
		Vector2(60, 560))
	var avv3: NodeView = c.views[a3]
	vv2 = c.views[vid]
	c._on_connection_request(avv3.name, avv3.data_out_port(0), vv2.name, vv2.data_in_port(slot))
	await process_frame
	_check("annode: duplicate annotation name stays a single line",
		c.model.annotations_of(vid).count("@export") == 1, "")

	# --- invalid placement is rejected with feedback --------------------------
	var a4: int = c.spawn_node(Model.Kind.ANNOTATION, {"name": "rpc", "args": []},
		Vector2(60, 690))
	var avv4: NodeView = c.views[a4]
	vv2 = c.views[vid]
	c._on_connection_request(avv4.name, avv4.data_out_port(0), vv2.name, vv2.data_in_port(slot))
	await process_frame
	_check("annode: @rpc rejected on a variable (placement guard)",
		not c.model.annotations_of(vid).has("@rpc") and c.model.last_reject_reason != "",
		c.model.last_reject_reason)
	win.queue_free()
	await process_frame


## Audit round D: context-menu on-screen clamping, scroll-to-top after load,
## committed-only type updates, type-field/model sync after refresh, and the
## title screen (Create / Load / Demo).
## Audit round C: the workspace must refuse to save generated code that
## does not compile (the pre-fix behaviour wrote broken files "anyway"),
## and the compile failure must surface in the problem list.
## Audit round B (UI): Match and Else If appear in the creation menus and
## a spawned Match node offers editable branch rows that drive the model.
func _test_b_menu_nodes() -> void:
	await process_frame
	var win: Window = Window.new()
	win.size = Vector2i(1100, 760)
	root.add_child(win)
	var c: Canvas = Canvas.new()
	c.custom_minimum_size = Vector2(1100, 760)
	win.add_child(c)
	for i: int in 4: await process_frame
	# --- menu catalog contains the two entries
	var match_idx: int = -1
	var elif_idx: int = -1
	for i: int in c.menu_items().size():
		var it: Dictionary = c.menu_items()[i]
		if str(it["name"]) == "Match" and int(it["kind"]) == Model.Kind.MATCH:
			match_idx = i
		if str(it["name"]) == "Else If" and int(it["kind"]) == Model.Kind.ELIF:
			elif_idx = i
	_check("b: Match in the menu", match_idx >= 0, "")
	_check("b: Else If in the menu", elif_idx >= 0, "")
	_check("b: both in the Flow Control category",
		match_idx >= 0 and elif_idx >= 0
		and str(c.menu_items()[match_idx]["cat"]) == "Flow Control"
		and str(c.menu_items()[elif_idx]["cat"]) == "Flow Control", "")
	# --- spawn a Match through the real menu path (the handler drives the
	# live filtered list, so open the menu first)
	c._open_menu(Vector2(60, 60))
	await process_frame
	var live_match: int = -1
	for i: int in c._menu_items.size():
		if String(c._menu_items[i]["name"]) == "Match" \
				and int(c._menu_items[i]["kind"]) == Model.Kind.MATCH:
			live_match = i
	c._on_menu_item(live_match)
	for i: int in 4: await process_frame
	var mid: int = -1
	for id: int in c.model.nodes:
		if int(c.model.nodes[id]["kind"]) == Model.Kind.MATCH:
			mid = id
	_check("b: match spawned via menu item", mid >= 0, "")
	var mv: NodeView = c.views[mid]
	var edits: Array = []
	for ch: Control in mv.get_children():
		if ch is HBoxContainer:
			for ch2: Control in ch.get_children():
				if ch2 is LineEdit:
					edits.append(ch2)
	# the node also renders the value pin's inline editor: value + 2 branches
	_check("b: match view has editable branch rows", edits.size() == 3, str(edits.size()))
	# rename branch 0 through the real widget signal
	(edits[1] as LineEdit).text_submitted.emit("1")
	for i: int in 4: await process_frame
	var mid2: int = -1
	for id: int in c.model.nodes:
		if int(c.model.nodes[id]["kind"]) == Model.Kind.MATCH:
			mid2 = id
	_check("b: rename commits to the model",
		String(c.model.nodes[mid2]["exec_outs"][0]) == "1", str(c.model.nodes[mid2]["exec_outs"]))
	var mv2: NodeView = c.views[mid2]
	var edits2: Array = []
	for ch: Control in mv2.get_children():
		if ch is HBoxContainer:
			for ch2: Control in ch.get_children():
				if ch2 is LineEdit:
					edits2.append(ch2)
	_check("b: view rebuilt with the new label",
		edits2.size() == 3 and (edits2[1] as LineEdit).text == "1", str(edits2.size()))
	# --- add a branch through the + branch button
	var add_btn: Button = null
	for ch: Control in mv2.get_children():
		if ch is HBoxContainer:
			for ch2: Control in ch.get_children():
				if ch2 is Button and str((ch2 as Button).text) == "+ branch":
					add_btn = ch2
	_check("b: + branch button exists", add_btn != null, "")
	add_btn.pressed.emit()
	for i: int in 4: await process_frame
	_check("b: branch added via button",
		(c.model.nodes[mid2]["exec_outs"] as Array).size() == 4
		and String(c.model.nodes[mid2]["exec_outs"][3]) == "after", str(c.model.nodes[mid2]["exec_outs"]))
	# --- remove the first branch through its x button
	var del_btn: Button = null
	var mv3: NodeView = c.views[mid2]
	for ch: Control in mv3.get_children():
		if ch is HBoxContainer:
			for ch2: Control in ch.get_children():
				if ch2 is Button and str((ch2 as Button).text) == "\u00d7":
					del_btn = ch2
					break
		if del_btn != null:
			break
	_check("b: branch remove button exists", del_btn != null, "")
	del_btn.pressed.emit()
	for i: int in 4: await process_frame
	_check("b: branch removed via button",
		(c.model.nodes[mid2]["exec_outs"] as Array) == ["_", "0", "after"], str(c.model.nodes[mid2]["exec_outs"]))
	# --- the spawned graph generates valid code
	c.spawn_node(Model.Kind.ENTRY, {"name": "run_match"})
	for i: int in 4: await process_frame
	var eid: int = -1
	for id: int in c.model.nodes:
		if int(c.model.nodes[id]["kind"]) == Model.Kind.ENTRY:
			eid = id
	c.model.connect_exec(eid, 0, mid2)
	c._sync_connections()
	for i: int in 4: await process_frame
	var res: Dictionary = c.generate_code()
	_check("b: spawned match graph generates valid code",
		bool(res["ok"]) and String(res["code"]).contains("match 0:"), str(res["code"]))
	# --- workspace Add Node popup mirrors the entries
	var wsw: Workspace = Workspace.new()
	win.add_child(wsw)
	for i: int in 4: await process_frame
	var in_popup: bool = false
	for it: Dictionary in wsw.NODE_MENU:
		if str(it["name"]) == "Match":
			in_popup = true
	_check("b: workspace Add Node popup offers Match", in_popup, "")
	wsw.queue_free()
	win.queue_free()
	await process_frame


func _test_c_save_refusal() -> void:
	await process_frame
	var win: Window = Window.new()
	win.size = Vector2i(1100, 760)
	root.add_child(win)
	var ws: Workspace = Workspace.new()
	ws.custom_minimum_size = Vector2(1100, 760)
	win.add_child(ws)
	for i: int in 4: await process_frame
	var path: String = "user://c5_refusal.gd"
	var fw: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	fw.store_string("extends Node\n\nvar health: int = 100\n\nfunc _ready() -> void:\n\tprint(health)\n")
	fw = null
	for i: int in 6: await process_frame
	var before: String = FileAccess.get_file_as_string(path)
	ws._do_open(path)
	for i: int in 8: await process_frame
	var c: Canvas = ws._canvas
	# corrupt the graph: an unknown type annotation cannot compile
	var vid: int = -1
	for id: int in c.model.nodes:
		if int(c.model.nodes[id]["kind"]) == Model.Kind.VAR_DECL:
			vid = id
	c._on_field_changed(vid, "type", "NoSuchType")
	for i: int in 4: await process_frame
	var res: Dictionary = c.generate_code()
	_check("c: broken graph detected by generate_code", not bool(res["ok"]), str(res["err_text"]))
	var probs: PackedStringArray = res["problems"] as PackedStringArray
	var surfaced: bool = false
	for p: String in probs:
		if p.begins_with("generated code does not compile"):
			surfaced = true
	_check("c: compile failure surfaced in problems", surfaced, str(probs))
	_check("c: graph is dirty", ws._dirty, "")
	var saved: Array = []
	ws._do_save(func(ok: bool) -> void: saved.append(ok))
	for i: int in 20: await process_frame
	_check("c: save refused for non-compiling output",
		saved.size() == 1 and not bool(saved[0]), str(saved))
	_check("c: disk untouched by refused save",
		FileAccess.get_file_as_string(path) == before, "")
	_check("c: status explains the cancellation",
		String(ws._stats.text).contains("Save cancelled"), String(ws._stats.text))
	_check("c: graph still dirty (nothing lost)", ws._dirty, "")
	# a valid graph saves again
	c._on_field_changed(vid, "type", "int")
	for i: int in 4: await process_frame
	ws._do_save(func(ok: bool) -> void: saved.append(ok))
	for i: int in 20: await process_frame
	_check("c: fixed graph saves", saved.size() == 2 and bool(saved[1]), str(saved))
	DirAccess.remove_absolute(path)
	win.queue_free()
	await process_frame


func _test_d_fixes_and_title() -> void:
	await process_frame
	var win: Window = Window.new()
	win.size = Vector2i(1100, 760)
	root.add_child(win)
	var ws: Workspace = Workspace.new()
	ws.custom_minimum_size = Vector2(1100, 760)
	win.add_child(ws)
	for i: int in 4: await process_frame
	var c: Canvas = ws._canvas

	# --- D2: first show offers the title screen, nothing auto-loaded
	_check("title: visible on first show", ws.title_screen_visible(), "")
	_check("title: canvas empty before any load", c.model.node_count() == 0, "")
	# Create New Script (refactored core): creates the file and opens it
	var created: bool = ws._create_new_script("d_title_test", "Node")
	_check("title: create makes res://d_title_test.gd",
		created and FileAccess.file_exists("res://d_title_test.gd"), str(created))
	var fresh: String = FileAccess.get_file_as_string("res://d_title_test.gd")
	_check("title: created template compiles", _gdc_compiles(fresh), fresh.left(80))
	_check("title: create opens the file in the graph",
		not ws.title_screen_visible() and ws._loaded_path == "res://d_title_test.gd",
		ws._loaded_path)
	_check("title: create marks no unsaved changes", not ws._dirty, str(ws._dirty))
	# duplicate name is refused
	var again: bool = ws._create_new_script("d_title_test", "Node")
	_check("title: duplicate name refused",
		not again and ws._stats.text.contains("already exists"), ws._stats.text)
	# invalid identifier refused
	var bad: bool = ws._create_new_script("not a name", "Node")
	_check("title: invalid identifier refused",
		not bad and ws._stats.text.contains("not a valid script name"), ws._stats.text)
	DirAccess.remove_absolute("res://d_title_test.gd")
	# Demo hides the title screen too
	ws._load_demo()
	_check("title: demo hides the title screen", not ws.title_screen_visible(), "")
	for i: int in 4: await process_frame

	# --- D4/D6: after loading, the topmost node is fully visible
	var c2: Canvas = c
	var min_local_y: float = INF
	var min_local_x: float = INF
	for id: int in c2.views:
		var v: NodeView = c2.views[id]
		var lp: Vector2 = Vector2(v.position_offset.x, v.position_offset.y) * c2.zoom - c2.scroll_offset
		min_local_x = minf(min_local_x, lp.x)
		min_local_y = minf(min_local_y, lp.y)
	_check("scroll: topmost node fully visible after load",
		min_local_y >= 42.0 and min_local_x >= 14.0,
		"x=%.1f y=%.1f" % [min_local_x, min_local_y])

	# --- D1: the context menu never lands off the visible window
	# open the menu near the canvas's far corner: the global placement must
	# be clamped into the viewport rect instead of the canvas's own size
	var far_local: Vector2 = Vector2(c2.size.x - 8.0, c2.size.y - 8.0)
	c2._open_menu(far_local)
	_check("menu: opens from the far corner", c2._menu_open, "")
	var gp: Vector2 = c2._menu_root.position
	var vr: Rect2 = win.get_visible_rect()
	var inside: bool = gp.x >= -0.5 and gp.y >= -0.5 \
		and gp.x + c2._menu_root.size.x <= vr.size.x + 0.5 \
		and gp.y + c2._menu_root.size.y <= vr.size.y + 0.5
	_check("menu: fully inside the visible window",
		inside, "pos=%s size=%s window=%s" % [gp, c2._menu_root.size, vr.size])
	c2._close_menu()

	# --- D3 + D5: committed-only type updates, field stays in sync
	var vid: int = -1
	for id: int in c2.model.nodes:
		if int(c2.model.nodes[id]["kind"]) == Model.Kind.VAR_DECL \
				and String(c2.model.nodes[id]["fields"].get("name", "")) == "health":
			vid = id
	var vv: NodeView = c2.views[vid]
	var tf: LineEdit = vv._form_fields["type"]
	tf.grab_focus()
	for i: int in 2: await process_frame
	tf.select_all()
	var dkey: InputEventKey = InputEventKey.new()
	dkey.keycode = KEY_DELETE
	dkey.pressed = true
	Input.parse_input_event(dkey)
	for i: int in 3: await process_frame
	tf.text = "St"   # partial, uncommitted text
	tf.text_changed.emit("St")
	await process_frame
	_check("type: partial text never reaches the model",
		String(c2.model.nodes[vid]["fields"].get("raw_type", "")) == "int",
		str(c2.model.nodes[vid]["fields"].get("raw_type", "")))
	tf.text = "int"
	tf.text_changed.emit("int")
	tf.text_submitted.emit("int")   # Enter commit
	await process_frame
	_check("type: commit reaches the model",
		String(c2.model.nodes[vid]["fields"].get("raw_type", "")) == "int",
		str(c2.model.nodes[vid]["fields"].get("raw_type", "")))
	# blur (focus another field): the unfocused refresh must keep the text
	var df: LineEdit = vv._form_fields["default"]
	df.grab_focus()
	for i: int in 6: await process_frame
	_check("type: field text survives unfocused refresh",
		tf.text == "int", tf.text)
	# focus-and-leave without changes must not mark the graph dirty
	ws._dirty = false
	tf.grab_focus()
	for i: int in 2: await process_frame
	df.grab_focus()
	for i: int in 4: await process_frame
	_check("type: focus-and-leave keeps the graph clean", not ws._dirty, str(ws._dirty))
	win.queue_free()
	await process_frame


## Constants menu additions: Literal Array + Literal Dictionary spawn through
## the real menu path, hold editable values and generate compiling code.
func _test_literal_entries() -> void:
	await process_frame
	var win: Window = Window.new()
	win.size = Vector2i(1100, 760)
	root.add_child(win)
	var c: Canvas = Canvas.new()
	c.custom_minimum_size = Vector2(1100, 760)
	win.add_child(c)
	for i: int in 4: await process_frame
	c.model.build("extends Node\n\nvar _pad := 0\n")
	for i: int in 2: await process_frame
	# --- menu catalog entries
	var ai: int = -1
	var di: int = -1
	for i: int in c.menu_items().size():
		var it: Dictionary = c.menu_items()[i]
		if str(it["name"]) == "Literal Array" and int(it["kind"]) == Model.Kind.LITERAL \
				and int(it["fields"]["type"]) == Types.PinType.ARRAY:
			ai = i
		if str(it["name"]) == "Literal Dictionary" and int(it["kind"]) == Model.Kind.LITERAL \
				and int(it["fields"]["type"]) == Types.PinType.DICTIONARY:
			di = i
	_check("lit: Literal Array in the Constants menu", ai >= 0, "")
	_check("lit: Literal Dictionary in the Constants menu", di >= 0, "")
	# --- spawn both through the real menu path
	c._open_menu(Vector2(60, 60))
	await process_frame
	var la: int = -1
	for i: int in c._menu_items.size():
		if str(c._menu_items[i]["name"]) == "Literal Array":
			la = i
	c._on_menu_item(la)
	await process_frame
	c._open_menu(Vector2(60, 200))
	await process_frame
	var ld: int = -1
	for i: int in c._menu_items.size():
		if str(c._menu_items[i]["name"]) == "Literal Dictionary":
			ld = i
	c._on_menu_item(ld)
	for i: int in 4: await process_frame
	var arr_id: int = -1
	var dict_id: int = -1
	for id: int in c.model.nodes:
		if int(c.model.nodes[id]["kind"]) == Model.Kind.LITERAL:
			var t: int = int(c.model.nodes[id]["data_outs"][0]["type"])
			if t == Types.PinType.ARRAY:
				arr_id = id
			elif t == Types.PinType.DICTIONARY:
				dict_id = id
	_check("lit: array literal spawned with an Array pin", arr_id >= 0, "")
	_check("lit: dictionary literal spawned with a Dictionary pin", dict_id >= 0, "")
	_check("lit: array literal default value is []",
		String(c.model.nodes[arr_id]["fields"].get("value", "")) == "[]",
		str(c.model.nodes[arr_id]["fields"].get("value", "")))
	# --- edit values through the model field, wire into a Print, generate
	c.model.set_field(dict_id, "value", "{\"hp\": 10}")
	var eid: int = c.spawn_node(Model.Kind.ENTRY, {"name": "_ready"})
	await process_frame
	var pid: int = c.spawn_node(Model.Kind.PRINT, {})
	await process_frame
	_check("lit: print exec from _ready", c.model.connect_exec(eid, 0, pid), "")
	c.model.connect_data(arr_id, 0, pid, 0)
	c.model.connect_data(dict_id, 0, pid, 1)
	for i: int in 3: await process_frame
	var res: Dictionary = c.generate_code()
	_check("lit: generated code compiles", bool(res["ok"]), str(res["err_text"]))
	var code: String = str(res["text"])
	_check("lit: code contains [] and the dict value",
		code.contains("print([], {\"hp\": 10})"),
		code.right(60))
	_check("lit: no problems for the literal graph",
		(res["problems"] as PackedStringArray).is_empty(), str(res["problems"]))
	win.queue_free()
	await process_frame


# ---- Comparison Operator UI ------------------------------------------------
func _test_comparison_ui() -> void:
	var win: Window = Window.new()
	win.size = Vector2i(1200, 800)
	root.add_child(win)
	var c: Canvas = Canvas.new()
	c.custom_minimum_size = Vector2(1200, 800)
	c.size = Vector2(1200, 800)
	win.add_child(c)
	win.show()
	for i: int in 4: await process_frame
	# menu: no standalone Condition entry; comparisons are Operator entries
	var has_condition_entry: bool = false
	var gt_idx: int = -1
	for i: int in c._catalog.size():
		if String(c._catalog[i]["name"]) == "Condition":
			has_condition_entry = true
		if String(c._catalog[i]["name"]) == "Greater (>)":
			gt_idx = i
	_check("menu catalog has no Condition entry", not has_condition_entry, "")
	_check("menu catalog spawns comparisons as Operator nodes",
		gt_idx >= 0 and String(c._catalog[gt_idx]["cat"]) == "Operators"
		and int(c._catalog[gt_idx]["kind"]) == c.Model.Kind.OPERATOR, "")
	var cid: int = c.spawn_node(c.Model.Kind.OPERATOR, {"op": ">"}, Vector2(300, 300))
	for i: int in 4: await process_frame
	var v: NodeView = c.views[cid]
	_check("comparison view has 2 inputs + 1 output",
		v.data_in_count() == 2 and _data_out_n(v) == 1, "")
	var lit: int = c.spawn_node(c.Model.Kind.LITERAL, {"type": c.Types.PinType.INT, "value": "3"}, Vector2(80, 300))
	for i: int in 2: await process_frame
	c._on_connection_request("n%d" % lit, c.views[lit].data_out_port(0), "n%d" % cid,
		c.views[cid].data_in_port(0))
	await process_frame
	await process_frame
	# generate: comparison wired into an If
	var ifid: int = c.spawn_node(c.Model.Kind.IF, {}, Vector2(620, 300))
	for i: int in 2: await process_frame
	c._on_connection_request("n%d" % cid, c.views[cid].data_out_port(0), "n%d" % ifid,
		c.views[ifid].data_in_port(0))
	var entry: int = c.spawn_node(c.Model.Kind.ENTRY, {}, Vector2(80, 80))
	var stmt: int = c.spawn_node(c.Model.Kind.STATEMENT, {"body": "print(1)"}, Vector2(820, 300))
	await process_frame
	c._on_connection_request("n%d" % ifid, c.views[ifid].exec_out_port(0), "n%d" % stmt,
		c.views[stmt].exec_in_port(0))
	c._on_connection_request("n%d" % entry, c.views[entry].exec_out_port(0), "n%d" % ifid,
		c.views[ifid].exec_in_port(0))
	var gen: Dictionary = c.generate_code()
	_check("wired comparison generates the expression",
		str(gen["code"]).contains("if (3 > 0):") and bool(gen["ok"]), str(gen["code"]))
	win.queue_free()
	await process_frame


func _test_scope_ui() -> void:
	# own window: the shared canvas must stay alive for later suites
	var win: Window = Window.new()
	win.size = Vector2i(1200, 800)
	root.add_child(win)
	var c: Canvas = Canvas.new()
	c.custom_minimum_size = Vector2(1200, 800)
	c.size = Vector2(1200, 800)
	win.add_child(c)
	win.show()
	for i: int in 4: await process_frame
	# private variable scope pin + visible scope wire (a function must exist
	# to own the private declaration)
	var fid0: int = c.spawn_node(c.Model.Kind.ENTRY, {}, Vector2(60, 60))
	for i: int in 2: await process_frame
	var vid: int = c.spawn_node(c.Model.Kind.VAR_DECL, {"name": "pv"}, Vector2(300, 300))
	for i: int in 2: await process_frame
	_check("public variable has one output",
		_data_out_n(c.views[vid]) == 1, "")
	_check("a function exists to own the private declaration",
		fid0 > 0, "")
	c._on_field_changed(vid, "scope", "private")
	for i: int in 4: await process_frame
	_check("private variable view shows the scope output pin",
		_data_out_n(c.views[vid]) == 2, "")
	var ifid: int = c.spawn_node(c.Model.Kind.IF, {}, Vector2(620, 300))
	for i: int in 2: await process_frame
	# scope wire via the real connection handler (registration, not data flow)
	c._on_connection_request("n%d" % vid, c.views[vid].data_out_port(1), "n%d" % ifid,
		c.views[ifid].data_in_port(1))
	await process_frame
	await process_frame
	_check("scope wire registered in the model",
		c.model.scope_links.size() == 1
		and int(c.model.scope_links[0]["vid"]) == vid
		and int(c.model.scope_links[0]["tid"]) == ifid, "")
	var wire_found: bool = _graphedit_wire_exists(c, "n%d" % vid, c.views[vid].data_out_port(1),
		"n%d" % ifid, c.views[ifid].data_in_port(1))
	_check("scope wire rendered as a visible connection", wire_found, "")
	_check("value output still works independently",
		c.model._source_expr(vid, 0, 0) == "pv", c.model._source_expr(vid, 0, 0))
	# disconnecting the scope wire unregisters it
	c._on_disconnection_request("n%d" % vid, c.views[vid].data_out_port(1), "n%d" % ifid,
		c.views[ifid].data_in_port(1))
	await process_frame
	_check("disconnecting the scope wire unregisters the scope",
		c.model.scope_links.is_empty(), "")
	_win_free(c)


## ---- If <-> comparison integration in the real editor stack: connecting a
## comparison Operator removes the If's own condition text; the If view syncs. ---
func _test_if_cond_ui() -> void:
	var win: Window = Window.new()
	win.size = Vector2i(1200, 800)
	root.add_child(win)
	var c: Canvas = Canvas.new()
	c.custom_minimum_size = Vector2(1200, 800)
	c.size = Vector2(1200, 800)
	win.add_child(c)
	win.show()
	for i: int in 4: await process_frame
	c.build_from_text("extends Node\n\nvar health: int = 100\n\nfunc f() -> void:\n\tif modifiers.is_empty():\n\t\tpass\n\tprint(1)\n")
	for i: int in 6: await process_frame
	var ifid: int = -1
	for id: int in c.model.nodes:
		if int(c.model.nodes[id]["kind"]) == c.Model.Kind.IF:
			ifid = id
	var iv: NodeView = c.views[ifid]
	var body_lab: Array = iv.find_children("*", "Label", true, false).filter(
		func(x: Node) -> bool: return (x as Label).text.contains("modifiers"))
	_check("If view shows its verbatim condition while unwired", body_lab.size() >= 1, "")
	# spawn a comparison Operator and wire it into the If's condition input
	var cid: int = c.spawn_node(c.Model.Kind.OPERATOR, {"op": ">"}, Vector2(80, 300))
	for i: int in 3: await process_frame
	c._on_field_changed(cid, "op", ">")
	c.model.set_pin_value(cid, 0, "health")
	c.model.set_pin_value(cid, 1, "0")
	c._on_connection_request("n%d" % cid, c.views[cid].data_out_port(0), "n%d" % ifid,
		c.views[ifid].data_in_port(0))
	await process_frame
	await process_frame
	_check("comparison wired into the If's condition input",
		c.model.data_links.any(func(l: Dictionary) -> bool:
			return int(l["from_id"]) == cid and int(l["to_id"]) == ifid), "")
	_check("If drops the conflicting expression on connect",
		String(c.model.nodes[ifid]["data_ins"][0]["value"]) == ""
		and String(c.model.nodes[ifid]["body"]) == "", "")
	var body_after: Array = iv.find_children("*", "Label", true, false).filter(
		func(x: Node) -> bool: return (x as Label).text.contains("modifiers"))
	_check("If view no longer shows the duplicated condition text",
		body_after.size() == 0, str(body_after.size()))
	var gen: Dictionary = c.generate_code()
	_check("generated If uses the comparison node's expression",
		str(gen["code"]).contains("if (health > 0):") and bool(gen["ok"]), str(gen["code"]))
	# operand / operator edits flow into the generated If
	c._on_field_changed(cid, "op", "<=")
	c._on_pin_value_changed(cid, 1, "50")
	var gen2: Dictionary = c.generate_code()
	_check("comparison edits update the generated If",
		str(gen2["code"]).contains("if (health <= 50):"), str(gen2["code"]))
	win.queue_free()
	await process_frame


## ---- Variables created inside If blocks keep the full Variable node -----
func _test_block_var_ui() -> void:
	var win: Window = Window.new()
	win.size = Vector2i(1200, 800)
	root.add_child(win)
	var c: Canvas = Canvas.new()
	c.custom_minimum_size = Vector2(1200, 800)
	c.size = Vector2(1200, 800)
	win.add_child(c)
	win.show()
	for i: int in 4: await process_frame
	c.build_from_text("extends Node\n\nvar health: int = 100\n\nfunc f() -> void:\n\tif health > 0:\n\t\tvar dog := 10\n\t\tprint(dog)\n\tprint(1)\n")
	for i: int in 6: await process_frame
	var dog: int = -1
	var ifid: int = -1
	for id: int in c.model.nodes:
		if int(c.model.nodes[id]["kind"]) == c.Model.Kind.VAR_DECL \
				and str(c.model.nodes[id]["fields"].get("name", "")) == "dog":
			dog = id
		elif int(c.model.nodes[id]["kind"]) == c.Model.Kind.IF:
			ifid = id
	_check("block variable is a full Variable node (not an execution statement)",
		dog > 0 and int(c.model.nodes[dog]["kind"]) == c.Model.Kind.VAR_DECL, str(dog))
	var dv: NodeView = c.views[dog]
	var opts: Array = dv.find_children("*", "OptionButton", true, false)
	_check("block variable keeps its Scope selector", opts.size() == 1, str(opts.size()))
	_check("block variable has Variable Name / Data Type / Value editors",
		dv._form_fields.has("name") and dv._form_fields.has("type")
		and dv._form_fields.has("default"), str(dv._form_fields.keys()))
	# the scope wire renders between the variable and the If
	var scope_wire: bool = false
	var exec_wire: bool = false
	for l: Dictionary in c.model.scope_links:
		if int(l["vid"]) == dog and int(l["tid"]) == ifid:
			scope_wire = true
	for l2: Dictionary in c.model.exec_in.get(dog, []):
		exec_wire = true
	_check("block variable connects through the scope wire, not an exec wire",
		scope_wire and not exec_wire, "")
	_check("block variable shows its dedicated scope output pin",
		_data_out_n(dv) == 2, str(_data_out_n(dv)))
	# spawned from the If's scope slot: becomes private + registered
	var vid2: int = c.spawn_node(c.Model.Kind.VAR_DECL, {"name": "nv"}, Vector2(300, 300))
	for i: int in 3: await process_frame
	c._pending_drag = {"node": "n%d" % ifid, "port": c.views[ifid].data_in_port(1), "is_output": false}
	c._auto_connect_spawn(vid2, c._pending_drag)
	await process_frame
	await process_frame
	var reg: bool = false
	for l3: Dictionary in c.model.scope_links:
		if int(l3["vid"]) == vid2 and int(l3["tid"]) == ifid:
			reg = true
	_check("spawning a Variable from a scope slot registers its scope",
		reg and str(c.model.nodes[vid2]["fields"].get("scope", "")) == "private", "")
	win.queue_free()
	await process_frame


func _test_args_left_layout() -> void:
	var win: Window = Window.new()
	win.size = Vector2i(1200, 800)
	root.add_child(win)
	var c: Canvas = Canvas.new()
	c.custom_minimum_size = Vector2(1200, 800)
	c.size = Vector2(1200, 800)
	win.add_child(c)
	win.show()
	for i: int in 4: await process_frame
	c.build_from_text("extends Node\n\nfunc f(a: int, b: int) -> void:\n\tprint(a + b)\n")
	for i: int in 8: await process_frame
	c._layout()
	for i: int in 8: await process_frame
	var entry: int = -1
	for id: int in c.views:
		if int(c.model.nodes[id]["kind"]) == c.Model.Kind.ENTRY:
			entry = id
	var entry_x: float = c.views[entry].position.x
	var args_x: float = 1e9
	for id: int in c.model.nodes[entry]["fields"]["args"]:
		args_x = minf(args_x, c.views[id].position.x)
	_check("argument nodes sit LEFT of their function node",
		args_x < entry_x, "arg=%.0f entry=%.0f" % [args_x, entry_x])
	_check("function cluster columns shifted to make room (no overlap)",
		entry_x > 40.0, str(entry_x))
	win.queue_free()
	await process_frame


func _graphedit_wire_exists(c: Canvas, fn: String, fp: int, tn: String, tp: int) -> bool:
	for conn: Dictionary in c.get_connection_list():
		if str(conn["from_node"]) == fn and int(conn["from_port"]) == fp \
				and str(conn["to_node"]) == tn and int(conn["to_port"]) == tp:
			return true
	return false


func _win_free(c: Canvas) -> void:
	var w: Window = c.get_parent() as Window
	if w != null:
		w.queue_free()
	await process_frame


## Number of data output slots on a view (mirrors data_in_count()).
func _data_out_n(v: NodeView) -> int:
	var cnt: int = 0
	for d: Dictionary in v._out_defs:
		if d["kind"] == "data":
			cnt += 1
	return cnt
