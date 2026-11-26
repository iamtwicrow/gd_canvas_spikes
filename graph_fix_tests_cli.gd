# Runs headless: godot --headless --path <project> -s res://addons/gd_canvas_spikes/graph_fix_tests_cli.gd
extends SceneTree
## Regression tests for: annotation placement left of Variables, Script Class
## Name / Script Extension -> Script Header wires, and Private Variable scope
## wires. Everything goes through the real canvas (build_from_text, connection
## handlers) so layout, wires and generation are checked together.

const Canvas = preload("res://addons/gd_canvas_spikes/graph_canvas.gd")
const Model = preload("res://addons/gd_canvas_spikes/graph_model.gd")
const NodeView = preload("res://addons/gd_canvas_spikes/graph_node.gd")

const SRC := "@tool\n@icon(\"res://icon.svg\")\nclass_name PlayerController\nextends CharacterBody2D\n\n@export_range(0, 10)\n@export_group(\"G\")\n@export var speed: int = 5\nvar health: int = 100\n\n@onready var node_a = null\n\nfunc a() -> void:\n\tvar priv1: int = 1\n\tprint(priv1)\n\nfunc b() -> void:\n\tvar priv2: int = 2\n\tif priv2 > 0:\n\t\tvar inner: int = 3\n\t\tprint(inner)\n\nfunc c() -> void:\n\tvar priv3: int = 3\n\tprint(priv3)\n"

var fails: int = 0
var checks: int = 0


func _check(name: String, ok: bool, detail: String = "") -> void:
	checks += 1
	if not ok:
		fails += 1
		print("  FAIL  ", name, "  [", detail, "]")


func _init() -> void:
	await _run()
	print("%d checks, %d failures -> %s" % [checks, fails, "PASS" if fails == 0 else "FAIL"])
	quit(0 if fails == 0 else 1)


func _make() -> Canvas:
	var c: Canvas = Canvas.new()
	c.custom_minimum_size = Vector2(1200, 800)
	root.add_child(c)
	await process_frame
	await process_frame
	return c


func _settle(n: int = 6) -> void:
	for i: int in n:
		await process_frame


func _id_by_title(c: Canvas, title: String) -> int:
	for id: int in c.model.nodes:
		if String(c.model.nodes[id]["title"]) == title:
			return id
	return -1


func _rect(c: Canvas, id: int) -> Rect2:
	var v: NodeView = c.views[id]
	return Rect2(v.position_offset, v.size)


func _anns_of(c: Canvas, tid: int) -> Array:
	var links: Array = []
	for l: Dictionary in c.model.ann_links:
		if int(l["tid"]) == tid:
			links.append(l)
	links.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["slot"]) < int(b["slot"]))
	return links.map(func(l: Dictionary) -> int: return int(l["aid"]))


## Annotations of `tid` sit in a column LEFT of it, right-aligned, the first
## level with the declaration's top and the rest stacked downward in slot order.
func _check_stack(c: Canvas, tid: int, label: String) -> void:
	var anns: Array = _anns_of(c, tid)
	_check(label + ": has annotations", anns.size() > 0, str(anns.size()))
	var tr: Rect2 = _rect(c, tid)
	var expect_top: float = tr.position.y
	for i: int in anns.size():
		var ar: Rect2 = _rect(c, int(anns[i]))
		_check("%s: annotation %d is left of the declaration" % [label, i],
			ar.end.x <= tr.position.x + 0.6, "%s vs %s" % [ar.end.x, tr.position.x])
		_check("%s: annotation %d gap is small and exact" % [label, i],
			absf(ar.position.y - expect_top) < 0.6, "%s vs %s" % [ar.position.y, expect_top])
		expect_top = ar.end.y + Canvas.LAYOUT_ANN_GAP


func _wire_exists(c: Canvas, from_id: int, to_id: int) -> bool:
	for w: Dictionary in c.get_connection_list():
		if str(w["from_node"]) == "n%d" % from_id and str(w["to_node"]) == "n%d" % to_id:
			return true
	return false


func _wire_count(c: Canvas, from_id: int, to_id: int) -> int:
	var n: int = 0
	for w: Dictionary in c.get_connection_list():
		if str(w["from_node"]) == "n%d" % from_id and str(w["to_node"]) == "n%d" % to_id:
			n += 1
	return n


## Issues the same request the editor sends when a wire is dropped on a pin.
func _connect(c: Canvas, from_id: int, from_out_model: int, to_id: int, to_in_model: int) -> void:
	var fv: NodeView = c.views[from_id]
	var tv: NodeView = c.views[to_id]
	c._on_connection_request("n%d" % from_id, fv.data_out_port(from_out_model),
		"n%d" % to_id, tv.data_in_port(to_in_model))


func _pin_index(c: Canvas, id: int, pin_name: String, outputs: bool = false) -> int:
	var pins: Array = c.model.nodes[id]["data_outs" if outputs else "data_ins"]
	for i: int in pins.size():
		if String(pins[i]["name"]) == pin_name:
			return i
	return -1


func _no_overlap(c: Canvas, label: String) -> void:
	var ids: Array = c.views.keys()
	var bad: String = ""
	for i: int in ids.size():
		for j: int in range(i + 1, ids.size()):
			if _rect(c, int(ids[i])).intersects(_rect(c, int(ids[j]))):
				bad += "%s/%s " % [c.model.nodes[ids[i]]["title"], c.model.nodes[ids[j]]["title"]]
	_check(label + ": no overlapping nodes", bad == "", bad)


func _run() -> void:
	var c: Canvas = await _make()
	c.build_from_text(SRC)
	await _settle()
	var m: Model = c.model

	# ---------------- 1) annotation placement ----------------
	var speed: int = _id_by_title(c, "var speed")
	var health: int = _id_by_title(c, "var health")
	var node_a: int = _id_by_title(c, "var node_a")
	var header: int = _id_by_title(c, "Script Header")
	_check("found declarations", speed > 0 and health > 0 and node_a > 0 and header > 0)
	_check("speed carries its two export annotations in source order (the group is no longer one of them)",
		_anns_of(c, speed).map(func(a: int) -> String: return String(m.nodes[a]["title"]))
		== ["@export_range", "@export"], str(_anns_of(c, speed)))
	var grp: int = _id_by_title(c, "@export_group")
	_check("@export_group loads as its own node", grp > 0)
	var exp_ids: Array = _anns_of(c, speed).filter(func(a: int) -> bool: return String(m.nodes[a]["title"]) in ["@export_range", "@export"])
	_check("group node is wired to the Export Group pin of BOTH export annotations",
		exp_ids.size() == 2 and _wire_exists(c, grp, int(exp_ids[0])) and _wire_exists(c, grp, int(exp_ids[1])))
	_check("no direct @export_group -> Variable wire", not _wire_exists(c, grp, speed))
	_check_stack(c, speed, "speed")
	_check_stack(c, node_a, "node_a")
	# script-level annotations live in the header's LEFT area, not above it
	var hdr_anns: Array = _anns_of(c, header)
	_check("header has script-level annotations", hdr_anns.size() == 2, str(hdr_anns.size()))
	var hr: Rect2 = _rect(c, header)
	var hdr_left: Array = hdr_anns.duplicate()
	hdr_left.append(_id_by_title(c, "Script Class Name"))
	hdr_left.append(_id_by_title(c, "Script Extension"))
	for hid2: int in hdr_left:
		var lr: Rect2 = _rect(c, hid2)
		_check("header-left node %s is left of the header" % str(m.nodes[hid2]["title"]),
			lr.end.x <= hr.position.x, "%s vs %s" % [lr.end.x, hr.position.x])
		_check("header-left node %s is not above the header" % str(m.nodes[hid2]["title"]),
			lr.position.y >= hr.position.y - 0.6, "%s vs %s" % [lr.position.y, hr.position.y])
	# annotations of one variable never sit inside another variable's stack
	var speed_top: float = _rect(c, int(_anns_of(c, speed)[0])).position.y
	var speed_bottom: float = _rect(c, speed).end.y
	for other: int in [health, node_a]:
		var r: Rect2 = _rect(c, other)
		var same_col: bool = is_equal_approx(r.position.x, _rect(c, speed).position.x)
		_check("speed's stack does not cover another variable",
			not same_col or r.end.y <= speed_top or r.position.y >= speed_bottom, "")
	_no_overlap(c, "loaded script")

	# ---------------- 2) Script header wires ----------------
	var cn: int = _id_by_title(c, "Script Class Name")
	var ex: int = _id_by_title(c, "Script Extension")
	_check("class name / extension nodes exist", cn > 0 and ex > 0)
	_check("header exposes class name + extends input pins",
		_pin_index(c, header, "class name") >= 0 and _pin_index(c, header, "extends") >= 0)
	_check("class name node has a visible output pin", c.views[cn].get_output_port_count() == 1)
	_check("extension node has a visible output pin", c.views[ex].get_output_port_count() == 1)
	_check("class name wired to header", _wire_exists(c, cn, header))
	_check("extension wired to header", _wire_exists(c, ex, header))
	var header_ports: Array = []
	for w: Dictionary in c.get_connection_list():
		if str(w["to_node"]) == "n%d" % header and (str(w["from_node"]) == "n%d" % cn or str(w["from_node"]) == "n%d" % ex):
			header_ports.append(int(w["to_port"]))
	_check("class name and extension wire into different header pins",
		header_ports.size() == 2 and header_ports[0] != header_ports[1], str(header_ports))
	_check("class name / extension nodes do not overlap each other", not _rect(c, cn).intersects(_rect(c, ex)))
	var gen: String = String(m.generate()["text"])
	_check("generated output keeps class_name + extends in order",
		gen.contains("class_name PlayerController\nextends CharacterBody2D\n"), gen.substr(0, 120))
	# duplicate connection attempt does not add a second wire / link
	var links_before: int = m.header_links.size()
	_connect(c, cn, 0, header, _pin_index(c, header, "class name"))
	await _settle(2)
	_check("duplicate class name connection is not added",
		m.header_links.size() == links_before and _wire_count(c, cn, header) == 1)
	# invalid connection: class name node into the extends pin
	_connect(c, cn, 0, header, _pin_index(c, header, "extends"))
	await _settle(2)
	_check("class name node cannot connect to the extends pin",
		m.header_links.size() == links_before and _wire_count(c, cn, header) == 1)
	# invalid: a variable value into the class name pin
	_connect(c, speed, 0, header, _pin_index(c, header, "class name"))
	await _settle(2)
	_check("variable output cannot connect to class name pin", m.header_links.size() == links_before)
	# editing the class name / base class updates generation
	_check("class name setter accepts a valid name", m.set_class_name(cn, "Hero"))
	_check("extends setter accepts a valid base", m.set_extends_base(ex, "Node2D"))
	var gen2: String = String(m.generate()["text"])
	_check("edited class name reaches generated script", gen2.contains("class_name Hero"), gen2.substr(0, 120))
	_check("edited base class reaches generated script", gen2.contains("extends Node2D"), gen2.substr(0, 120))

	# ---------------- 3) private variable scopes ----------------
	var ea: int = _id_by_title(c, "Event: a")
	var eb: int = _id_by_title(c, "Event: b")
	var ec: int = _id_by_title(c, "Event: c")
	var p1: int = _id_by_title(c, "var priv1")
	var p2: int = _id_by_title(c, "var priv2")
	var p3: int = _id_by_title(c, "var priv3")
	var inner: int = _id_by_title(c, "var inner")
	var if_id: int = -1
	for id: int in m.nodes:
		if int(m.nodes[id]["kind"]) == Model.Kind.IF:
			if_id = id
	_check("scope fixtures found", ea > 0 and eb > 0 and ec > 0 and p1 > 0 and p2 > 0 and p3 > 0 and inner > 0 and if_id > 0)
	for pair: Array in [[p1, ea], [p2, eb], [p3, ec], [inner, if_id]]:
		var vid: int = int(pair[0])
		var links: Array = m.scope_links_of(vid)
		_check("%s has exactly one scope link" % m.nodes[vid]["title"], links.size() == 1, str(links))
		_check("%s links to its own scope" % m.nodes[vid]["title"],
			links.size() == 1 and int(links[0]["tid"]) == int(pair[1]))
		_check("%s has a visible scope wire" % m.nodes[vid]["title"], _wire_exists(c, vid, int(pair[1])))
	# no wire from a variable to an unrelated scope
	_check("no wire to unrelated scopes",
		not _wire_exists(c, p1, eb) and not _wire_exists(c, p1, ec) and not _wire_exists(c, p2, ea) and not _wire_exists(c, p3, ea))
	var from_scope_pin: bool = false
	for w2: Dictionary in c.get_connection_list():
		if str(w2["from_node"]) == "n%d" % p1 and str(w2["to_node"]) == "n%d" % ea \
				and int(w2["from_port"]) == c.views[p1].data_out_port(1):
			from_scope_pin = true
	_check("scope wire starts on the scope pin, not the value pin", from_scope_pin)
	_check("value output untouched", String(m.nodes[p1]["data_outs"][0]["name"]) == "priv1")
	var gen3: String = String(m.generate()["text"])
	_check("private variables still generate in their functions",
		gen3.contains("func a() -> void:\n\tvar priv1: int = 1") and gen3.contains("func c() -> void:\n\tvar priv3: int = 3"), gen3)
	# multiple variables on the same valid scope
	var extra: int = m.add_node(Model.Kind.VAR_DECL, {})
	c.spawn_node(Model.Kind.VAR_DECL)
	await _settle(2)
	var extra2: int = -1
	for id: int in m.nodes:
		if int(m.nodes[id]["kind"]) == Model.Kind.VAR_DECL and id != extra and not [speed, health, node_a, p1, p2, p3, inner].has(id) and c.views.has(id):
			extra2 = id
	if extra2 >= 0:
		m.set_var_prop(extra2, "scope", "private")
		c._rebuild_view(extra2)
		_connect(c, extra2, 1, ea, _pin_index(c, ea, "add scope"))
		await _settle(2)
		_check("second variable joins the same scope", _wire_exists(c, extra2, ea) and _wire_exists(c, p1, ea))
		# moving it to another scope replaces the wire (single owner)
		_connect(c, extra2, 1, ec, _pin_index(c, ec, "add scope"))
		await _settle(2)
		_check("re-wiring moves the variable to the new scope",
			_wire_exists(c, extra2, ec) and not _wire_exists(c, extra2, ea) and m.scope_links_of(extra2).size() == 1)
	# a public variable cannot connect to a scope; a value pin cannot reach a scope slot
	var before: int = m.scope_links.size()
	_connect(c, health, 0, ea, _pin_index(c, ea, "add scope"))
	await _settle(2)
	_check("public variable cannot connect to a scope", m.scope_links.size() == before)

	# ---------------- reopen: regenerate -> reload ----------------
	var text: String = String(m.generate()["text"])
	c.build_from_text(text)
	await _settle()
	m = c.model
	var cn2: int = _id_by_title(c, "Script Class Name")
	var ex2: int = _id_by_title(c, "Script Extension")
	var header2: int = _id_by_title(c, "Script Header")
	_check("reopened: class name + extension wires survive",
		cn2 > 0 and ex2 > 0 and _wire_exists(c, cn2, header2) and _wire_exists(c, ex2, header2))
	_check("reopened: class name updated", str(m.nodes[cn2]["fields"].get("name", "")) != "" )
	for pair2: Array in [["var priv1", "Event: a"], ["var priv2", "Event: b"], ["var priv3", "Event: c"]]:
		var v2: int = _id_by_title(c, str(pair2[0]))
		var t2: int = _id_by_title(c, str(pair2[1]))
		_check("reopened: %s wired to %s" % pair2, v2 > 0 and t2 > 0 and _wire_exists(c, v2, t2))
	var speed2: int = _id_by_title(c, "var speed")
	_check_stack(c, speed2, "reopened speed")
	_no_overlap(c, "reopened script")
	_check("reopened output is stable", String(m.generate()["text"]) == text)

	# ---------------- live annotation wiring keeps the placement ----------------
	c.build_from_text("extends Node\n\nvar a: int = 1\nvar b: int = 2\n")
	await _settle()
	m = c.model
	var va: int = _id_by_title(c, "var a")
	var vb: int = _id_by_title(c, "var b")
	var ids_before: Array = m.nodes.keys()
	c.spawn_node(Model.Kind.ANNOTATION, {"name": "@export"})
	c.spawn_node(Model.Kind.ANNOTATION, {"name": "@export_range"})
	await _settle()
	var spawned: Array = []
	for id: int in m.nodes:
		if not ids_before.has(id) and int(m.nodes[id]["kind"]) == Model.Kind.ANNOTATION:
			spawned.append(id)
	if spawned.size() == 2:
		_connect(c, int(spawned[0]), 0, va, _pin_index(c, va, "add annotation"))
		await _settle()
		_connect(c, int(spawned[1]), 0, va, _pin_index(c, va, "add annotation"))
		await _settle(8)
		if _anns_of(c, va).size() == 2:
			_check_stack(c, va, "live a")
		else:
			_check("two annotations registered on a", false, str(_anns_of(c, va)))
		# re-wire the second annotation to b: stacks follow, gap closes on a
		_connect(c, int(spawned[1]), 0, vb, _pin_index(c, vb, "add annotation"))
		await _settle(8)
		_check_stack(c, va, "a after a move away")
		_check_stack(c, vb, "b after a move onto it")
		_check("annotation no longer registered on a",
			not (_anns_of(c, va) as Array).has(int(spawned[1])))
	else:
		_check("spawned two annotation nodes", false, str(spawned))


	# ---------------- authoring from scratch: header + class name + extension ----------------
	c.build_from_text("\nfunc f() -> void:\n\tpass\n")
	await _settle()
	m = c.model
	c.spawn_node(Model.Kind.PREAMBLE)
	c.spawn_node(Model.Kind.CLASS_NAME)
	c.spawn_node(Model.Kind.EXTENDS_DECL)
	await _settle(4)
	var h3: int = _id_by_title(c, "Script Header")
	var cn3: int = _id_by_title(c, "Script Class Name")
	var ex3: int = _id_by_title(c, "Script Extension")
	_check("authored header + meta nodes exist", h3 > 0 and cn3 > 0 and ex3 > 0)
	if h3 > 0 and cn3 > 0 and ex3 > 0:
		_connect(c, cn3, 0, h3, _pin_index(c, h3, "class name"))
		_connect(c, ex3, 0, h3, _pin_index(c, h3, "extends"))
		await _settle(2)
		_check("authored class name wire is visible", _wire_exists(c, cn3, h3))
		_check("authored extension wire is visible", _wire_exists(c, ex3, h3))
		m.set_class_name(cn3, "PlayerController")
		m.set_extends_base(ex3, "CharacterBody2D")
		var g4: String = String(m.generate()["text"])
		_check("authored header generates class_name + extends",
			g4.contains("class_name PlayerController") and g4.contains("extends CharacterBody2D"), g4)
		# reload what was generated: wires reconstruct
		c.build_from_text(g4)
		await _settle()
		var h4: int = _id_by_title(c, "Script Header")
		var cn4: int = _id_by_title(c, "Script Class Name")
		var ex4: int = _id_by_title(c, "Script Extension")
		_check("authored header reloads with both wires",
			h4 > 0 and cn4 > 0 and ex4 > 0 and _wire_exists(c, cn4, h4) and _wire_exists(c, ex4, h4))
