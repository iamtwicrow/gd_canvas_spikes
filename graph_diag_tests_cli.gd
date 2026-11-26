# Runs headless: godot --headless --path <project> -s res://addons/gd_canvas_spikes/graph_diag_tests_cli.gd
extends SceneTree
## Headless test of the Blueprint-style error / warning display: compiler errors
## are mapped to the node that produced the line, indicators appear on that node
## (badge, message row, full text in the tooltips), they disappear once the error
## is resolved, and nothing about the generated code changes.

const Canvas = preload("res://addons/gd_canvas_spikes/graph_canvas.gd")
const NodeView = preload("res://addons/gd_canvas_spikes/graph_node.gd")
const Model = preload("res://addons/gd_canvas_spikes/graph_model.gd")

var fails: int = 0


func _check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		print("  ok   ", label)
	else:
		fails += 1
		print("  FAIL ", label, "  ", detail)


func _find_kind(c: Canvas, kind: int) -> int:
	for id: int in c.model.nodes:
		if int(c.model.nodes[id]["kind"]) == kind:
			return id
	return -1


func _refresh(c: Canvas, force: bool = true) -> void:
	c.refresh_diagnostics(force)
	# analyze() awaits a few frames (the analyzer-warning pass promotes and
	# restores the project's warning levels through the engine's deferred
	# settings refresh): give it room to finish before the assertions
	for i: int in 6:
		await process_frame


func _init() -> void:
	var c: Canvas = Canvas.new()
	root.add_child(c)
	await process_frame
	await process_frame

	# --- clean script: nothing is flagged ------------------------------------
	c.build_from_text("extends Node\n\nfunc f() -> void:\n\tprint(1)\n")
	await process_frame
	await _refresh(c)
	_check("clean script: no errors", c.diag_errors == 0, c.diag_details)
	_check("clean script: no warnings", c.diag_warnings == 0, c.diag_details)

	# --- the generated-line -> node table lines up with the text --------------
	var gen: Dictionary = c.model.generate()
	var text: String = str(gen["text"])
	var line_nodes: PackedInt32Array = gen["line_nodes"] as PackedInt32Array
	_check("line table covers every generated line",
		line_nodes.size() == text.split("\n").size() - 1, "%d vs %d" % [line_nodes.size(), text.split("\n").size() - 1])
	var entry_id: int = _find_kind(c, Model.Kind.ENTRY)
	var func_line: int = -1
	var lines: PackedStringArray = text.split("\n")
	for i: int in lines.size():
		if lines[i].begins_with("func f"):
			func_line = i
	_check("'func f' line belongs to the Function node",
		func_line >= 0 and line_nodes[func_line] == entry_id, str(func_line))

	# --- an analyzer error lands on the node that emitted the line -------------
	c.build_from_text("extends Node\n\nfunc f() -> void:\n\tprint(undefined_name)\n")
	await process_frame
	var pid: int = _find_kind(c, Model.Kind.PRINT)
	_check("print node exists", pid >= 0, "")
	var before: String = str(c.model.generate()["text"])
	await _refresh(c)
	_check("error counted", c.diag_errors >= 1, c.diag_details)
	var items: Array = c.diagnostics_for(pid)
	_check("error is attached to the print node", not items.is_empty(), c.diag_details)
	if not items.is_empty():
		var d: Dictionary = items[0] as Dictionary
		_check("severity is error", str(d["severity"]) == "error", str(d))
		_check("message names the problem", str(d["message"]).contains("undefined_name"), str(d["message"]))
		_check("source line is known", int(d["line"]) > 0, str(d["line"]))
	var v: NodeView = c.views[pid]
	_check("node shows indicators", v.has_diagnostics(), "")
	var badge: Node = v.get_titlebar_hbox().get_node_or_null("DiagBadge")
	_check("header badge exists", badge != null, "")
	if badge != null:
		_check("badge tooltip holds the full message",
			(badge as Control).tooltip_text.contains("undefined_name"), (badge as Control).tooltip_text)
	var row: Node = v.get_node_or_null("DiagRow")
	_check("message row exists", row != null, "")

	# --- the node grows an "error" pin wired to an Error node -----------------
	var eport: int = v.diag_out_port("error")
	_check("node has an error pin", eport >= 0, str(eport))
	_check("node has no warning pin", v.diag_out_port("warning") == -1, "")
	var enode: GraphNode = c.diag_node_for(pid, "error")
	_check("Error node exists", enode != null, "")
	_check("no Warning node for an error-only node", c.diag_node_for(pid, "warning") == null, "")
	if enode != null:
		var msg: Label = enode.get_node_or_null("Message") as Label
		_check("Error node shows the message", msg != null and msg.text.contains("undefined_name"),
			msg.text if msg != null else "no label")
		_check("error pin is wired to the Error node",
			c.is_node_connected("n%d" % pid, eport, str(enode.name), 0), "")
	_check("Error node is not a model node",
		c.views.size() == c.model.nodes.size() and not c.views.has(-1), "")
	var wires_before: int = c.get_connection_list().size()
	_check("display is non-destructive: generated code unchanged",
		str(c.model.generate()["text"]) == before, "")
	_check("the engine still reports the code as not compiling", not bool(c.generate_code()["ok"]), "")

	# --- fixing the code clears the indicators -------------------------------
	c.model.set_pin_value(pid, 0, "1")
	await _refresh(c)
	_check("fixed: no errors left", c.diag_errors == 0, c.diag_details)
	_check("fixed: indicators removed from the node", not c.views[pid].has_diagnostics(), "")
	_check("fixed: badge removed", c.views[pid].get_titlebar_hbox().get_node_or_null("DiagBadge") == null, "")
	_check("fixed: error pin removed", c.views[pid].diag_out_port("error") == -1, "")
	_check("fixed: Error node removed", c.diag_node_for(pid, "error") == null, "")
	var left_over: int = 0
	for conn: Dictionary in c.get_connection_list():
		if str(conn["to_node"]).begins_with("dg_"):
			left_over += 1
	_check("fixed: no Error / Warning wires left", left_over == 0, str(left_over))
	_check("fixed: wires fell back to the model's own", c.get_connection_list().size() <= wires_before, "")

	# --- warnings use a different style and clear once the node is wired ------
	var wid: int = c.spawn_node(Model.Kind.PRINT, {})
	await process_frame
	await _refresh(c)
	var witems: Array = c.diagnostics_for(wid)
	_check("unconnected node gets a warning", not witems.is_empty() and str((witems[0] as Dictionary)["severity"]) == "warning",
		str(witems))
	_check("warnings are not counted as errors", c.diag_warnings >= 1 and c.diag_errors == 0, c.diag_details)
	var wv: NodeView = c.views[wid]
	_check("warning node: warning pin, no error pin",
		wv.diag_out_port("warning") >= 0 and wv.diag_out_port("error") == -1, "")
	var wnode: GraphNode = c.diag_node_for(wid, "warning")
	_check("Warning node exists", wnode != null, "")
	if wnode != null:
		_check("warning pin is wired to the Warning node",
			c.is_node_connected("n%d" % wid, wv.diag_out_port("warning"), str(wnode.name), 0), "")
	_check("no Error node for a warning-only node", c.diag_node_for(wid, "error") == null, "")
	var eid: int = c.spawn_node(Model.Kind.ENTRY, {"name": "_ready"})
	await process_frame
	c.model.connect_exec(eid, 0, wid)
	c.refresh_diagnostics(true)
	for i: int in 6:
		await process_frame
	_check("warning cleared once the node is part of a flow", c.diagnostics_for(wid).is_empty(), str(c.diagnostics_for(wid)))
	_check("Warning node removed with the warning", c.diag_node_for(wid, "warning") == null, "")

	# --- a node with BOTH kinds gets both pins (error first) ------------------
	var bv: NodeView = c.views[wid]
	bv.set_diagnostics([
		{"severity": "warning", "message": "w1", "line": 3},
		{"severity": "error", "message": "e1", "line": 4}])
	var bp_e: int = bv.diag_out_port("error")
	var bp_w: int = bv.diag_out_port("warning")
	_check("both pins exist", bp_e >= 0 and bp_w >= 0, "%d %d" % [bp_e, bp_w])
	_check("error pin comes before the warning pin", bp_e < bp_w, "%d %d" % [bp_e, bp_w])
	_check("second message row exists", bv.get_node_or_null("DiagRowWarn") != null, "")
	_check("diagnostic pins never shadow model pins",
		bv.data_out_port(0) != bp_e and bv.data_out_port(0) != bp_w, "")
	bv.set_diagnostics([])
	_check("pins removed again", bv.diag_out_port("error") == -1 and bv.diag_out_port("warning") == -1, "")

	# --- all syntax errors at once (Godot 4.7 prints only the first per
	# compile; the reveal pass swaps reported lines for `pass` and repeats) ---
	var dm: RefCounted = c._get_diag_module()
	var cc2: Dictionary = dm.call("_cached_compile",
		"extends Node\n\nfunc f() -> void:\n\tvar x := (\n\tvar y := 1 +\n", false)
	var n_err: int = (cc2.get("items", []) as Array).size()
	_check("both syntax errors revealed at once", n_err >= 2, str(cc2.get("items", [])))
	var seen_lines: Dictionary = {}
	for it3: Variant in (cc2.get("items", []) as Array):
		seen_lines[int((it3 as Dictionary).get("line", -1))] = true
	_check("revealed errors are on different lines", seen_lines.size() == n_err, str(seen_lines))
	var cc3: Dictionary = dm.call("_cached_compile", "extends Node\n\nfunc f() -> void:\n\tprint(nope)\n", false)
	_check("a genuine single error stays single",
		(cc3.get("items", []) as Array).size() == 1, str(cc3.get("items", [])))
	_check("failing code is still reported as not compiling", not bool(cc2["ok"]), "")

	c.queue_free()
	await process_frame
	print("graph diagnostics tests: %s" % ("PASS" if fails == 0 else "FAIL (%d)" % fails))
	quit(0 if fails == 0 else 1)
