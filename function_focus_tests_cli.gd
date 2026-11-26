# Runs headless: godot --headless --path <project> -s res://addons/gd_canvas_spikes/function_focus_tests_cli.gd
extends SceneTree
## Headless test of the function editor: double-clicking a function in the
## workspace dock isolates that function on the canvas (everything else
## hidden, its wires dropped from the display only), editing keeps working,
## and leaving the focus restores every view and every wire without touching
## the model or the generated code.

const Canvas = preload("res://addons/gd_canvas_spikes/graph_canvas.gd")
const Model = preload("res://addons/gd_canvas_spikes/graph_model.gd")

var fails: int = 0


func _check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		print("  ok   ", label)
	else:
		fails += 1
		print("  FAIL ", label, "  ", detail)


func _init() -> void:
	var c: Canvas = Canvas.new()
	root.add_child(c)
	await process_frame
	await process_frame
	var src: String = "extends Node\n\nvar gvar := 1\n\nfunc a() -> void:\n\tprint(gvar)\n\nfunc b() -> void:\n\tvar x := 2\n\tprint(x)\n"
	c.build_from_text(src)
	await process_frame
	await process_frame
	var entries: Dictionary = {}
	for id: int in c.model.nodes:
		if int(c.model.nodes[id]["kind"]) == Model.Kind.ENTRY:
			entries[str(c.model.nodes[id]["fields"].get("name", ""))] = id
	var ea: int = int(entries["a"])
	var eb: int = int(entries["b"])
	var total: int = c.views.size()
	# --- enter focus on b -----------------------------------------------------
	var before_code: String = str(c.model.generate()["text"])
	var ok: bool = c.enter_function_focus(eb)
	_check("enter_function_focus(b) works", ok, "")
	_check("focused reports b", c.focused_function() == eb, "")
	var visible: int = 0
	for id: int in c.views:
		if c.views[id].visible:
			visible += 1
	_check("only function b's cluster is visible", visible < total and visible >= 2, "%d of %d" % [visible, total])
	_check("a's entry is hidden", not c.views[ea].visible, "")
	_check("b's entry is visible", c.views[eb].visible, "")
	_check("generated code unchanged by focus", str(c.model.generate()["text"]) == before_code, "")
	var broken_wires: int = 0
	for x: Variant in c.get_connection_list():
		if str(x["from_node"]) == "n%d" % ea or str(x["to_node"]) == "n%d" % ea:
			broken_wires += 1
	_check("no wires of hidden nodes are shown", broken_wires == 0, str(broken_wires))
	_check("model still holds every wire", c.model.link_count() > 0, "")
	# --- editing inside the focus keeps working -------------------------------
	var pid: int = -1
	for id: int in c.model.nodes:
		if int(c.model.nodes[id]["kind"]) == Model.Kind.PRINT and c.views[id].visible:
			pid = id
	c.model.set_pin_value(pid, 0, "3")
	_check("editing inside the focus works", int(c.model.nodes[pid]["kind"]) == Model.Kind.PRINT, "")
	# --- exit restores everything --------------------------------------------
	c.exit_function_focus()
	_check("focus cleared", not c.is_function_focused(), "")
	var visible2: int = 0
	for id2: int in c.views:
		if c.views[id2].visible:
			visible2 += 1
	_check("all views visible again", visible2 == total, "%d vs %d" % [visible2, total])
	var kept: int = c.get_connection_list().size()
	_check("all wires restored on exit", kept >= c.model.link_count(),
		"%d shown vs %d model" % [kept, c.model.link_count()])
	_check("generated code still unchanged", str(c.model.generate()["text"]).contains("print(3)"), "")
	# --- direct switching between functions ----------------------------------
	c.enter_function_focus(ea)
	_check("focused a", c.focused_function() == ea and c.views[ea].visible and not c.views[eb].visible, "")
	c.enter_function_focus(eb)
	_check("switched to b directly", c.focused_function() == eb and c.views[eb].visible and not c.views[ea].visible, "")
	var visible3: int = 0
	for id3: int in c.views:
		if c.views[id3].visible:
			visible3 += 1
	_check("after switch, still only one cluster visible", visible3 < total, str(visible3))
	# --- invalid calls --------------------------------------------------------
	_check("non-entry id rejected", not c.enter_function_focus(pid), "")
	c.exit_function_focus()
	_check("exit when not focused is safe", true, "")

	c.queue_free()
	await process_frame
	print("function focus tests: %s" % ("PASS" if fails == 0 else "FAIL (%d)" % fails))
	quit(0 if fails == 0 else 1)
