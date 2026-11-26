# Runs headless: godot --headless --path <project> -s res://addons/gd_canvas_spikes/comparison_pin_tests_cli.gd
extends SceneTree
## Headless test of the comparison-pin invariant: Equal / Not Equal / Less /
## Greater / Less or Equal / Greater or Equal spawn Operator nodes with
## EXACTLY two operand pins (they can never grow a third input), chainable
## operators keep their grow slot, and switching an Operator's operator to a
## comparison collapses it to two operands.

const Canvas = preload("res://addons/gd_canvas_spikes/graph_canvas.gd")
const Model = preload("res://addons/gd_canvas_spikes/graph_model.gd")

var fails: int = 0
func _check(label: String, ok: bool, detail: String = "") -> void:
	if ok: print("  ok   ", label)
	else:
		fails += 1
		print("  FAIL ", label, "  ", detail)

func _init() -> void:
	var c: Canvas = Canvas.new()
	root.add_child(c)
	await process_frame
	await process_frame
	# --- menu: the six comparisons spawn fixed-2-input Operator nodes --------
	for item: Dictionary in c.menu_items():
		var nm: String = str(item["name"])
		if not ["Equal (==)", "Not Equal (!=)", "Less (<)", "Greater (>)",
				"Less or Equal (<=)", "Greater or Equal (>=)"].has(nm):
			continue
		var id: int = c.spawn_node(int(item["kind"]), item["fields"], Vector2(300, 300))
		await process_frame
		var n: Dictionary = c.model.nodes[id]
		_check("%s spawns with exactly 2 inputs" % nm,
			int(n["kind"]) == Model.Kind.OPERATOR and (n["data_ins"] as Array).size() == 2
			and not c.model.is_dynamic_input_node(id),
			"kind=%d pins=%d" % [int(n["kind"]), (n["data_ins"] as Array).size()])
		var expected_op: String = nm.substr(nm.find("(") + 1, nm.length() - nm.find("(") - 2)
		_check("%s keeps its operator" % nm, str(n["fields"]["op"]) == expected_op, str(n["fields"]))
		c.model.remove_node(id)
		await process_frame
	# --- arithmetic operators still grow (unchanged) -------------------------
	var add_id: int = c.spawn_node(Model.Kind.OPERATOR, {"op": "+"}, Vector2(300, 300))
	await process_frame
	_check("Add operator keeps its grow slot",
		(c.model.nodes[add_id]["data_ins"] as Array).size() == 3
		and c.model.is_dynamic_input_node(add_id), "")
	# wiring the grow slot opens a fresh one (chainable math stays chainable)
	var lit: int = c.spawn_node(Model.Kind.LITERAL, {"type": c.Types.PinType.INT, "value": "1"}, Vector2(80, 300))
	await process_frame
	c.model.connect_data(lit, 0, add_id, 2)
	_check("chained Add grows a further slot",
		(c.model.nodes[add_id]["data_ins"] as Array).size() == 4, "")
	# --- switching an Operator's op to a comparison collapses it to 2 --------
	var before_ins: Array = (c.model.nodes[add_id]["data_ins"] as Array).duplicate(true)
	c.model.set_field(add_id, "op", "==")
	_check("op change to == collapses to 2 pins",
		(c.model.nodes[add_id]["data_ins"] as Array).size() == 2
		and not c.model.is_dynamic_input_node(add_id), "")
	var dropped := true
	for l: Variant in c.model.data_links:
		if int(l["to_id"]) == add_id and int(l["to_in"]) >= 2:
			dropped = false
	_check("extra operand wire dropped by the collapse", dropped, "")
	_check("collapse kept the two operand pins",
		str(c.model.nodes[add_id]["data_ins"][0]["value"]) == "0" and (c.model.nodes[add_id]["data_ins"] as Array).size() == 2, str(c.model.nodes[add_id]["data_ins"]))
	_check("title shows the comparison", str(c.model.nodes[add_id]["title"]) == "Operator ==", "")
	# generated code is a single comparison, not a chain
	# switching back to "+" works and regains the grow slot
	c.model.set_field(add_id, "op", "+")
	_check("back to + regrows the slot",
		(c.model.nodes[add_id]["data_ins"] as Array).size() == 3
		and c.model.is_dynamic_input_node(add_id), "")
	# wire the comparison into a real flow and generate: one "==", never chained
	c.build_from_text("extends Node\n\nfunc f() -> void:\n\tprint(1)\n")
	await process_frame
	var eid2: int = -1
	var prid: int = -1
	for nid: int in c.model.nodes:
		if int(c.model.nodes[nid]["kind"]) == Model.Kind.ENTRY:
			eid2 = nid
		if int(c.model.nodes[nid]["kind"]) == Model.Kind.PRINT:
			prid = nid
	var op2: int = c.spawn_node(Model.Kind.OPERATOR, {"op": "+"}, Vector2(300, 400))
	var lit3: int = c.spawn_node(Model.Kind.LITERAL, {"type": c.Types.PinType.INT, "value": "5"}, Vector2(80, 400))
	await process_frame
	c.model.connect_exec(eid2, 0, prid)
	c.model.connect_data(op2, 0, prid, 0)
	c.model.connect_data(lit3, 0, op2, 0)
	c.model.set_field(op2, "op", ">=")
	await process_frame
	var gen: String = str(c.model.generate()["text"])
	_check("generated code has one comparison", gen.count(">=") == 1 and not gen.contains(">= >="), gen)
	# --- a comparison Operator stays 2-input under wiring --------------------
	var cid: int = c.spawn_node(Model.Kind.OPERATOR, {"op": ">="}, Vector2(300, 500))
	await process_frame
	var lit2: int = c.spawn_node(Model.Kind.LITERAL, {"type": c.Types.PinType.INT, "value": "2"}, Vector2(80, 500))
	await process_frame
	c.model.connect_data(lit2, 0, cid, 0)
	c.model.connect_data(lit2, 0, cid, 1)
	_check("wiring never adds pins to a comparison Operator",
		(c.model.nodes[cid]["data_ins"] as Array).size() == 2, "")
	_check("comparison title shows its operator", str(c.model.nodes[cid]["title"]) == "Operator >=", "")
	c.queue_free()
	await process_frame
	print("comparison pin tests: %s" % ("PASS" if fails == 0 else "FAIL (%d)" % fails))
	quit(0 if fails == 0 else 1)
