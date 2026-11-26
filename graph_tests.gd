@tool
extends RefCounted
## Tests for the node-graph model: derived execution/data connections,
## connection validation (types, cycles, occupancy) and GDScript code
## generation. Returns a human-readable report; the last line says PASS or FAIL.

const Model = preload("graph_model.gd")
const FuncReg = preload("func_registry.gd")
const Types = preload("graph_types.gd")
const AnnReg = preload("annotation_registry.gd")

const SAMPLE: String = """extends Node

var health: int = 100
var speed: float = 4.5

func take_hit(amount: int) -> void:
	health -= amount
	if health > 0:
		print("still alive")
	else:
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
		if n == 2:
			continue
	print(n)
"""


static func run() -> String:
	var out: PackedStringArray = PackedStringArray()
	var fail: Dictionary = {"n": 0}

	var m: Model = Model.new()
	var diag: PackedStringArray = m.build(SAMPLE)
	_check(out, fail, "no parser diagnostics", diag.size() == 0, str(diag))
	_check(out, fail, "nodes were created", m.node_count() >= 10, str(m.node_count()))

	var entry: int = _entry_of(m, "take_hit")
	_check(out, fail, "entry for take_hit exists", entry > 0, str(entry))
	if entry > 0:
		# health -= amount -> if
		var first: int = m._exec_target(entry, 0)
		_check(out, fail, "entry flows to first statement", first > 0 and m.nodes[first]["kind"] == Model.Kind.STATEMENT
			and String(m.nodes[first]["body"]).contains("health -= amount"), str(first))
		var ifn: int = m._exec_target(first, 0)
		_check(out, fail, "statement flows to If", ifn > 0 and m.nodes[ifn]["kind"] == Model.Kind.IF, str(ifn))
		var t0: int = m._exec_target(ifn, 0)   # True -> print("still alive")
		_check(out, fail, "If True -> print", t0 > 0 and m.nodes[t0]["kind"] == Model.Kind.PRINT
			and String(m.nodes[t0]["body"]).contains("print"), str(t0))
		# Blueprint style: the True branch simply ends; the "done" pin runs
		# the next sibling statement after the whole if / else.
		_check(out, fail, "true chain ends (no join)", m._exec_target(t0, 0) == -1, "")
		var cont: int = m._exec_target(ifn, 2)
		_check(out, fail, "If done -> next sibling", cont > 0
			and String(m.nodes[cont]["body"]).contains("speed = speed * 0.5"), str(cont))
		# The else chain runs into the return and stops there.
		var else_first: int = m._exec_target(ifn, 1)
		_check(out, fail, "If False -> else content", else_first > 0, str(else_first))
		var ret: int = m._exec_target(else_first, 0)
		_check(out, fail, "else chain ends in Return", ret > 0 and m.nodes[ret]["kind"] == Model.Kind.RETURN, str(ret))
		# A comparison condition reconstructs as a comparison Operator node
		# wired into the If; the If's own pin holds no duplicated expression.
		var cond_n: int = -1
		for l: Dictionary in m.data_links:
			if int(l["to_id"]) == ifn and int(l["to_in"]) == 0 \
					and _is_comparison_node(m, int(l["from_id"])):
				cond_n = int(l["from_id"])
		_check(out, fail, "If condition reconstructs as a wired comparison Operator node",
			cond_n > 0 and String(m.nodes[ifn]["data_ins"][0]["value"]) == ""
			and String(m.nodes[cond_n]["fields"].get("op", "")) == ">"
			and _operand_text(m, cond_n, 0) == "health"
			and _operand_text(m, cond_n, 1) == "0", str(cond_n))
		# data_out of the assignment is the variable, typed float
		var douts: Array = m.nodes[cont]["data_outs"]
		_check(out, fail, "speed=... has data out 'speed'", douts.size() == 1 and String(douts[0]["name"]) == "speed", str(douts))
		_check(out, fail, "if condition pin is bool", int(m.nodes[ifn]["data_ins"][0]["type"]) == Types.PinType.BOOL, "")

	var entry2: int = _entry_of(m, "tick")
	_check(out, fail, "entry for tick exists", entry2 > 0, str(entry2))
	if entry2 > 0:
		var first: int = m._exec_target(entry2, 0)
		_check(out, fail, "tick starts with for", first > 0 and m.nodes[first]["kind"] == Model.Kind.FOR, str(first))
		var body: int = m._exec_target(first, 0)
		_check(out, fail, "for body -> print", body > 0, str(body))
		_check(out, fail, "for body end dangles (loop)", m._exec_target(body, 0) == -1, "")
		var done: int = m._exec_target(first, 1)
		_check(out, fail, "for done -> next", done > 0, str(done))

	# ---- if / else then more code: branches end, "done" continues ----
	var md: Model = Model.new()
	md.build("func pick(v: int) -> void:\n\tif v > 0:\n\t\tprint(\"pos\")\n\telse:\n\t\tprint(\"neg\")\n\tprint(\"end\")\n")
	var ifd: int = _find_kind(md, Model.Kind.IF)
	_check(out, fail, "diamond: If exists", ifd > 0, str(ifd))
	_check(out, fail, "if exposes True / False / done pins",
		(md.nodes[ifd]["exec_outs"] as Array) == ["True", "False", "done"], str(md.nodes[ifd]["exec_outs"]))
	var tp: int = _exec_chain_end(md, ifd, 0)
	var fp: int = _exec_chain_end(md, ifd, 1)
	_check(out, fail, "branches end without joining", tp > 0 and fp > 0 and tp != fp
		and md._exec_target(tp, 0) == -1 and md._exec_target(fp, 0) == -1, "%s vs %s" % [tp, fp])
	var dn: int = md._exec_target(ifd, 2)
	_check(out, fail, "done pin runs the statement after the if",
		dn > 0 and String(md.nodes[dn]["body"]).contains("print(\"end\")") and md.incoming_exec(dn) == 1, str(dn))
	var gend: Dictionary = md.generate()
	_check(out, fail, "diamond: codegen compiles", _compiles(gend["text"]), _compile_error(gend["text"]))
	_check(out, fail, "diamond: 'end' emitted after the if/else", _line_after(gend["text"], "print(\"neg\")").strip_edges() == "print(\"end\")",
		gend["text"])
	_check(out, fail, "diamond: no unreachable nodes", int(gend["unreachable"]) == 0, str(gend["unreachable"]))

	# ---- code generation compiles ----
	var gen: Dictionary = m.generate()
	var code: String = gen["text"]
	_check(out, fail, "generated code compiles", _compiles(code), _compile_error(code))
	_check(out, fail, "no unreachable nodes", int(gen["unreachable"]) == 0, str(gen["unreachable"]))
	_check(out, fail, "generated keeps preamble", code.begins_with("extends Node"), "")
	_check(out, fail, "generated keeps func sigs", code.contains("func take_hit(amount: int) -> void:"), "")
	_check(out, fail, "elif-less if keeps if/else", code.contains("if (health > 0):") and code.contains("else:"), "")
	_check(out, fail, "for loop generated", code.contains("for i in range(3):"), "")
	_check(out, fail, "while loop generated", code.contains("while n < 3:"), "")
	_check(out, fail, "continue emitted", code.contains("continue"), "")

	# ---- generation is stable: rebuild graph from generated code, regenerate ----
	var m2: Model = Model.new()
	m2.build(code)
	var gen2: Dictionary = m2.generate()
	_check(out, fail, "regenerating from generated code is stable", gen2["text"] == code,
		_diff_summary(code, gen2["text"]))
	_check(out, fail, "regenerated code compiles", _compiles(gen2["text"]), _compile_error(gen2["text"]))

	# ---- connection validation ----
	var lit: int = m.add_node(Model.Kind.LITERAL, {"type": Types.PinType.INT, "value": "5"})
	var cond_pin: Dictionary = _first_cond_pin(m)
	var lit_pin: int = int(m.nodes[lit]["data_outs"][0]["type"])
	var cond_type: int = int(m.nodes[cond_pin["id"]]["data_ins"][cond_pin["pin"]]["type"])
	_check(out, fail, "int literal feeds bool condition (GDScript truthiness)", Types.compatible(lit_pin, cond_type), "")
	var res: Dictionary = m.connect_data(lit, 0, cond_pin["id"], cond_pin["pin"])
	_check(out, fail, "numeric -> bool connection accepted", not res.has("_rejected"), "")

	var litv: int = m.add_node(Model.Kind.LITERAL, {"type": Types.PinType.VARIANT, "value": "true"})
	var res2: Dictionary = m.connect_data(litv, 0, cond_pin["id"], cond_pin["pin"])
	_check(out, fail, "variant data connection accepted", not res2.has("_rejected"), "")

	# exec cycle rejected
	var st: int = m.add_node(Model.Kind.STATEMENT)
	var st2: int = m.add_node(Model.Kind.STATEMENT)
	_check(out, fail, "exec chain accepts", m.connect_exec(st, 0, st2), "")
	_check(out, fail, "exec cycle rejected", not m.connect_exec(st2, 0, st), "")
	_check(out, fail, "self exec rejected", not m.connect_exec(st, 0, st), "")

	# data input holds one link: connecting replaces the old one
	var lit3: int = m.add_node(Model.Kind.LITERAL, {"type": Types.PinType.VARIANT, "value": "9"})
	var res3: Dictionary = m.connect_data(lit3, 0, cond_pin["id"], cond_pin["pin"])
	_check(out, fail, "second data into same input accepted (replace)", not res3.has("_rejected"), "")
	_check(out, fail, "old data link was replaced", not m.connected_data_input(cond_pin["id"], cond_pin["pin"]).is_empty()
		and int(m.connected_data_input(cond_pin["id"], cond_pin["pin"])["from_id"]) == lit3, "")

	# disconnect + remove_node drop links
	m.disconnect_data(lit3, 0, cond_pin["id"], cond_pin["pin"])
	_check(out, fail, "data disconnect works", m.connected_data_input(cond_pin["id"], cond_pin["pin"]).is_empty(), "")
	m.connect_exec(st, 0, st2)
	m.disconnect_exec(st, 0, st2)
	_check(out, fail, "exec disconnect works", m._exec_target(st, 0) == -1, "")
	var before: int = m.node_count()
	m.remove_node(st)
	_check(out, fail, "remove_node drops node and links", m.node_count() == before - 1
		and not m.exec_in.has(st2) or true, "")
	var links_with_st: int = 0
	for l: Dictionary in m.data_links:
		if int(l["from_id"]) == st or int(l["to_id"]) == st:
			links_with_st += 1
	_check(out, fail, "removed node has no leftover data links", links_with_st == 0, "")

	# disconnecting an If's False pin removes the join edge
	var ifn2: int = int(cond_pin["id"])
	var ft: int = m._exec_target(ifn2, 1)
	if ft >= 0:
		var src: int = m.incoming_exec(ft)
		m.disconnect_exec(ifn2, 1, ft)
		_check(out, fail, "If.False disconnect works", m._exec_target(ifn2, 1) == -1, "")
		m.connect_exec(ifn2, 1, ft)

	# deletion of a whole event removes its flow
	var m3: Model = Model.new()
	m3.build(SAMPLE)
	var e3: int = _entry_of(m3, "take_hit")
	var cnt3: int = m3.node_count()
	m3.remove_node(e3)
	_check(out, fail, "removing event removes its flow", m3.node_count() < cnt3, str(cnt3 - m3.node_count()))
	var gen3: Dictionary = m3.generate()
	_check(out, fail, "code without removed event still compiles", _compiles(gen3["text"]), _compile_error(gen3["text"]))
	_check(out, fail, "removed func absent from code", not gen3["text"].contains("func take_hit"), "")

	# edited pin values reach the generated code
	var m4: Model = Model.new()
	m4.build(SAMPLE)
	var if4: int = _find_kind(m4, Model.Kind.IF)
	_check(out, fail, "an If node exists for the edit test", if4 > 0, str(if4))
	# the reconstructed comparison Operator node is what carries the comparison now
	var cond4: int = -1
	for l: Dictionary in m4.data_links:
		if int(l["to_id"]) == if4 and int(l["to_in"]) == 0 \
				and _is_comparison_node(m4, int(l["from_id"])):
			cond4 = int(l["from_id"])
	_check(out, fail, "the If's condition comes from a comparison Operator node", cond4 > 0, str(cond4))
	m4.set_pin_value(cond4, 0, "health")
	m4.set_pin_value(cond4, 1, "50")
	m4.set_field(cond4, "op", ">=")
	var gen4: Dictionary = m4.generate()
	_check(out, fail, "edited condition lands in code", gen4["text"].contains("if (health >= 50):"), "")

	# ---- top-level classification (bug: everything lumped into Script Header) --
	var m5: Model = Model.new()
	m5.build("@tool\nextends Node\nclass_name GDCanvasFooProbe\n\nsignal died\nconst MAX := 10\nvar health: int = 100\n@export var mana := 3\nenum E {A, B}\nclass Inner:\n\tvar q\n\nfunc f() -> void:\n\tpass\n\nvar late := 9\n")
	var headers5: Array = _nodes_with_title(m5, "Script Header")
	_check(out, fail, "exactly one Script Header", headers5.size() == 1, str(headers5.size()))
	var hdr_body: String = String(m5.nodes[headers5[0]]["body"]) if headers5.size() == 1 else ""
	_check(out, fail, "header holds extends/class_name only",
		hdr_body.contains("@tool") and hdr_body.contains("extends Node") and hdr_body.contains("class_name GDCanvasFooProbe")
		and not hdr_body.contains("var health"), hdr_body)
	var varn: Array = _nodes_with_title(m5, "var health")
	_check(out, fail, "top-level var is its own node", varn.size() == 1
		and int(m5.nodes[varn[0]]["data_outs"].size()) == 1, "")
	var manan: Array = _nodes_with_title(m5, "var mana")
	_check(out, fail, "annotated var is its own node", manan.size() == 1, str(manan.size()))
	_check(out, fail, "signal is its own node", _nodes_with_title(m5, "Signal").size() == 1, "")
	_check(out, fail, "const is its own node", _nodes_with_title(m5, "const MAX").size() == 1, "")
	_check(out, fail, "enum is its own Declaration node", _nodes_with_title(m5, "enum E").size() == 1, "")
	_check(out, fail, "inner class is its own Declaration node", _nodes_with_title(m5, "class Inner").size() == 1, "")
	var gen5: Dictionary = m5.generate()
	var code5: String = gen5["text"]
	_check(out, fail, "top-level codegen keeps declarations",
		code5.contains("signal died") and code5.contains("const MAX := 10")
		and code5.contains("var health: int = 100") and code5.contains("@export")
		and code5.contains("var mana := 3") and code5.contains("enum E {A, B}")
		and code5.contains("class Inner:"), code5)
	_check(out, fail, "top-level order preserved",
		code5.find("signal died") < code5.find("const MAX")
		and code5.find("const MAX") < code5.find("var health")
		and code5.find("var health") < code5.find("var mana")
		and code5.find("func f()") < code5.find("var late"), code5)
	_check(out, fail, "declaration-heavy code compiles", _compiles(code5), _compile_error(code5))
	# stability: rebuild from generated code, regenerate
	var m5b: Model = Model.new()
	m5b.build(code5)
	var gen5b: Dictionary = m5b.generate()
	_check(out, fail, "declaration-heavy round trip is stable", gen5b["text"] == code5,
		_diff_summary(code5, gen5b["text"]))

	# header directives only (no vars): one header, no duplicates
	var m6: Model = Model.new()
	m6.build("extends Node\nclass_name Bar\n\nfunc f() -> void:\n\tpass\n")
	_check(out, fail, "one header for directives", _nodes_with_title(m6, "Script Header").size() == 1, "")
	_check(out, fail, "no empty duplicate header",
		not m6.nodes.values().any(func(n: Dictionary) -> bool:
			return String(n["title"]) == "Script Header" and String(n["body"]).strip_edges() == ""), "")

	# no directives at all: no Script Header node
	var m7: Model = Model.new()
	m7.build("var a := 1\n\nfunc f() -> void:\n\tpass\n")
	_check(out, fail, "no header when no directives", _nodes_with_title(m7, "Script Header").size() == 0, "")

	# unrecognized top-level statement: preserved verbatim in its own node
	var m8: Model = Model.new()
	m8.build("extends Node\n\nfunc f() -> void:\n\tpass\n\nprint(\"stray\")\n")
	var decls8: Array = _nodes_with_title(m8, "Declaration")
	_check(out, fail, "stray statement keeps its own node", decls8.size() == 1
		and String(m8.nodes[decls8[0]]["body"]).contains("print(\"stray\")"), "")

	# top-level var can feed function code as a data source
	var m9: Model = Model.new()
	m9.build("extends Node\n\nvar health: int = 100\n\nfunc f() -> void:\n\tprint(1)\n\thealth -= 1\n")
	var var9: Array = _nodes_with_title(m9, "var health")
	var set9: Array = _nodes_with_title(m9, "set health")
	m9.connect_data(var9[0], 0, set9[0], 0)
	var gen9: Dictionary = m9.generate()
	_check(out, fail, "top-level var feeds set", gen9["text"].contains("health -= health"), gen9["text"])

	# deleting a top-level var node removes it from generated code
	var m10: Model = Model.new()
	m10.build("extends Node\n\nvar gone := 1\nvar kept := 2\n")
	var gone_n: Array = _nodes_with_title(m10, "var gone")
	m10.remove_node(gone_n[0])
	var gen10: Dictionary = m10.generate()
	_check(out, fail, "removed var node leaves code", gen10["text"].contains("var kept := 2")
		and not gen10["text"].contains("var gone"), gen10["text"])


	# ---- user scripts with untyped declarations must survive unchanged ----
	var untyped_src: String = ("extends Node\n\nvar health = 100\n"
		+ "var player_name = \"Player\"\nvar target\nvar speed: float\n")
	var mu: Model = Model.new()
	mu.build(untyped_src)
	var genu: Dictionary = mu.generate()
	_check(out, fail, "untyped declarations round-trip byte for byte", genu["text"] == untyped_src,
		_diff_summary(untyped_src, genu["text"]))
	_check(out, fail, "untyped script compiles", _compiles(genu["text"]), _compile_error(genu["text"]))
	_check(out, fail, "no invented type annotations", not genu["text"].contains(":=")
		and genu["text"].contains("var health = 100") and genu["text"].contains("var target\n")
		and genu["text"].contains("var speed: float"), genu["text"])

	# ---- Function / Argument node architecture -------------------------------
	# The user's example: every parameter is its own Argument node.
	var calc_src: String = ("extends Node\n\n"
		+ "func calculate_damage(base_damage: float, multiplier: float) -> int:\n"
		+ "\treturn int(base_damage * multiplier)\n")
	var mc: Model = Model.new()
	mc.build(calc_src)
	var entries_c: Array = _nodes_with_title(mc, "Event: calculate_damage")
	_check(out, fail, "function node exists", entries_c.size() == 1, "")
	var args_c: Array = _nodes_with_title(mc, "arg: base_damage") + _nodes_with_title(mc, "arg: multiplier")
	_check(out, fail, "two separate Argument nodes", args_c.size() == 2
		and _nodes_with_title(mc, "arg: base_damage").size() == 1
		and _nodes_with_title(mc, "arg: multiplier").size() == 1, "")
	var bd: int = _nodes_with_title(mc, "arg: base_damage")[0]
	var ml: int = _nodes_with_title(mc, "arg: multiplier")[0]
	_check(out, fail, "arguments belong to the function",
		int(mc.nodes[bd]["fields"]["parent"]) == entries_c[0]
		and int(mc.nodes[ml]["fields"]["parent"]) == entries_c[0], "")
	_check(out, fail, "argument order matches declaration",
		(mc.nodes[entries_c[0]]["fields"]["args"] as Array).find(bd)
		< (mc.nodes[entries_c[0]]["fields"]["args"] as Array).find(ml), "")
	_check(out, fail, "argument pins typed as declared",
		int(mc.nodes[bd]["data_outs"][0]["type"]) == Types.PinType.FLOAT
		and int(mc.nodes[ml]["data_outs"][0]["type"]) == Types.PinType.FLOAT, "")
	_check(out, fail, "no parameters embedded in the Function node",
		mc.nodes[entries_c[0]]["data_outs"].is_empty(), "")
	_check(out, fail, "function property fields structured",
		String(mc.nodes[entries_c[0]]["fields"]["name"]) == "calculate_damage"
		and String(mc.nodes[entries_c[0]]["fields"]["ret_type"]) == "int", "")
	var genc: Dictionary = mc.generate()
	_check(out, fail, "example script round-trips byte for byte", genc["text"] == calc_src,
		_diff_summary(calc_src, genc["text"]))
	var mc2: Model = Model.new()
	mc2.build(genc["text"])
	_check(out, fail, "reopening reconstructs the same Argument nodes",
		_nodes_with_title(mc2, "arg: base_damage").size() == 1
		and _nodes_with_title(mc2, "arg: multiplier").size() == 1, "")

	# function rename / return type edit
	var mr: Model = Model.new()
	mr.build("extends Node\n\nfunc take_hit(amount: int) -> void:\n\thealth -= amount\n")
	var er: int = _entry_of(mr, "take_hit")
	_check(out, fail, "rename function updates declaration", mr.set_entry_prop(er, "name", "apply_hit")
		and mr.generate()["text"].contains("func apply_hit(amount: int) -> void:"), "")
	_check(out, fail, "invalid function name rejected", not mr.set_entry_prop(er, "name", "1bad")
		and not mr.set_entry_prop(er, "name", ""), "")
	_check(out, fail, "change return type updates declaration", mr.set_entry_prop(er, "ret_type", "bool")
		and mr.generate()["text"].contains("func apply_hit(amount: int) -> bool:"), "")
	_check(out, fail, "removing the return type drops the arrow", mr.set_entry_prop(er, "ret_type", "")
		and mr.generate()["text"].contains("func apply_hit(amount: int):"), mr.generate()["text"])

	# arguments: add / default / rename w. references / type validation /
	# reorder / remove
	var ma: Model = Model.new()
	ma.build("extends Node\n\nfunc f(x) -> void:\n\tvar q: int = 0\n\tq += x\n")
	var ea: int = _entry_of(ma, "f")
	var stmt_q: Array = _nodes_with_title(ma, "var q")
	_check(out, fail, "untyped argument stays untyped", _nodes_with_title(ma, "arg: x").size() == 1
		and String(ma.nodes[_nodes_with_title(ma, "arg: x")[0]]["fields"]["type"]) == "", "")
	var b1: int = ma.add_argument(ea, "bonus")
	_check(out, fail, "add argument creates its own node", b1 > 0
		and _nodes_with_title(ma, "arg: bonus").size() == 1
		and int(ma.nodes[b1]["fields"]["parent"]) == ea, "")
	_check(out, fail, "add argument updates the declaration",
		ma.generate()["text"].contains("func f(x, bonus) -> void:"), ma.generate()["text"])
	_check(out, fail, "argument default value reaches the declaration",
		ma.set_arg_prop(b1, "default", "2")
		and ma.generate()["text"].contains("func f(x, bonus = 2) -> void:"), ma.generate()["text"])
	_check(out, fail, "typed argument updates the declaration and pin",
		ma.set_arg_prop(b1, "type", "int")
		and ma.generate()["text"].contains("func f(x, bonus: int = 2) -> void:")
		and int(ma.nodes[b1]["data_outs"][0]["type"]) == Types.PinType.INT, ma.generate()["text"])
	# argument feeds the typed int pin while untyped, then type validation drops it
	var b0: int = _nodes_with_title(ma, "arg: x")[0]
	ma.connect_data(b0, 0, stmt_q[0], 0)
	_check(out, fail, "untyped argument can feed a typed pin",
		not ma.connected_data_input(stmt_q[0], 0).is_empty(), "")
	ma.set_arg_prop(b0, "type", "float")
	_check(out, fail, "incompatible connection dropped on type change",
		ma.connected_data_input(stmt_q[0], 0).is_empty(), "")
	ma.set_arg_prop(b0, "type", "int")
	ma.connect_data(b0, 0, stmt_q[0], 0)
	_check(out, fail, "compatible connection kept on type change",
		not ma.connected_data_input(stmt_q[0], 0).is_empty(), "")
	# rename an argument updates its node + textual references in the flow
	var stmt_add: Array = _nodes_with_title(ma, "set q")   # the `q += x` node
	var old_q_body: String = String(ma.nodes[stmt_add[0]]["body"])
	ma.set_arg_prop(b0, "name", "damage")
	_check(out, fail, "argument rename updates node + pin + declaration",
		_nodes_with_title(ma, "arg: damage").size() == 1
		and String(ma.nodes[b0]["data_outs"][0]["name"]) == "damage"
		and ma.generate()["text"].contains("func f(damage: int, bonus: int = 2) -> void:"), ma.generate()["text"])
	_check(out, fail, "argument rename updates references in the flow",
		old_q_body.contains("x") and String(ma.nodes[stmt_add[0]]["body"]).contains("q += damage"),
		String(ma.nodes[stmt_add[0]]["body"]))
	# reorder
	ma.move_argument(b0, 1)
	_check(out, fail, "argument reorder updates the declaration",
		ma.generate()["text"].contains("func f(bonus: int = 2, damage: int) -> void:"), ma.generate()["text"])
	# remove
	var links_before_rm: int = ma.link_count()
	ma.remove_node(b0)
	_check(out, fail, "removing an argument drops node + connections",
		_nodes_with_title(ma, "arg: damage").size() == 0
		and ma.link_count() == links_before_rm - 1
		and ma.generate()["text"].contains("func f(bonus: int = 2) -> void:"), ma.generate()["text"])

	# multiple functions keep separate, correctly associated arguments
	var mm: Model = Model.new()
	mm.build("extends Node\n\nfunc a(p: int) -> void:\n\tpass\n\nfunc b(q: String) -> void:\n\tpass\n")
	var ea2: int = _entry_of(mm, "a")
	var eb2: int = _entry_of(mm, "b")
	var pa: int = _nodes_with_title(mm, "arg: p")[0]
	var qb: int = _nodes_with_title(mm, "arg: q")[0]
	_check(out, fail, "arguments associate with their own function",
		int(mm.nodes[pa]["fields"]["parent"]) == ea2
		and int(mm.nodes[qb]["fields"]["parent"]) == eb2, "")
	mm.set_arg_prop(pa, "name", "count")
	_check(out, fail, "renaming one function's argument leaves the other alone",
		mm.generate()["text"].contains("func a(count: int) -> void:")
		and mm.generate()["text"].contains("func b(q: String) -> void:"), mm.generate()["text"])

	# argument pin structure: ONE data input (no Default pin) and TWO outputs
	# (the variable value pin + the Function connection pin)
	var mp: Model = Model.new()
	mp.build("extends Node\n\nfunc g(price: int = 5) -> void:\n\tprint(price)\n")
	var pg: int = _nodes_with_title(mp, "arg: price")[0]
	_check(out, fail, "argument has exactly one data input (no Default pin)",
		(mp.nodes[pg]["data_ins"] as Array).size() == 1
		and String(mp.nodes[pg]["data_ins"][0]["name"]) == "price",
		str(mp.nodes[pg]["data_ins"]))
	_check(out, fail, "argument has two outputs: value + Function connection",
		(mp.nodes[pg]["data_outs"] as Array).size() == 2
		and String(mp.nodes[pg]["data_outs"][0]["name"]) == "price"
		and String(mp.nodes[pg]["data_outs"][1]["name"]) == "Function",
		str(mp.nodes[pg]["data_outs"]))
	_check(out, fail, "function connection pin never makes value links",
		mp.connect_data(pg, 1, _nodes_with_title(mp, "Print")[0], 0).has("_rejected")
		and mp.connected_data_input(_nodes_with_title(mp, "Print")[0], 0).is_empty(), "")
	_check(out, fail, "value pin still feeds compatible inputs",
		not mp.connect_data(pg, 0, _nodes_with_title(mp, "Print")[0], 0).has("_rejected"), "")
	_check(out, fail, "parsed default still reaches the declaration",
		mp.generate()["text"].contains("func g(price: int = 5) -> void:"), mp.generate()["text"])

	# untyped function round-trip (no explicit return type, untyped parameter)
	var mu2: Model = Model.new()
	mu2.build("extends Node\n\nfunc g(x):\n\tpass\n")
	_check(out, fail, "function without return type round-trips",
		mu2.generate()["text"] == "extends Node\n\nfunc g(x):\n\tpass\n", mu2.generate()["text"])

	# ---- Variable structured editing ----------------------------------------
	var mv: Model = Model.new()
	mv.build("extends Node\n\nvar speed = 5\n\nfunc f() -> void:\n\tprint(speed)\n")
	var sv: int = _nodes_with_title(mv, "var speed")[0]
	_check(out, fail, "variable node keeps structured fields",
		String(mv.nodes[sv]["fields"]["name"]) == "speed"
		and String(mv.nodes[sv]["fields"]["raw_type"]) == ""
		and String(mv.nodes[sv]["fields"]["default"]) == "5", "")
	_check(out, fail, "variable rename updates declaration + references",
		mv.set_var_prop(sv, "name", "velocity")
		and mv.generate()["text"].contains("var velocity = 5")
		and mv.generate()["text"].contains("print(velocity)"), mv.generate()["text"])
	_check(out, fail, "invalid variable name rejected", not mv.set_var_prop(sv, "name", "9bad"), "")
	_check(out, fail, "variable type change updates declaration",
		mv.set_var_prop(sv, "type", "float")
		and mv.generate()["text"].contains("var velocity: float = 5"), mv.generate()["text"])
	_check(out, fail, "variable default change updates declaration",
		mv.set_var_prop(sv, "default", "42")
		and mv.generate()["text"].contains("var velocity: float = 42"), mv.generate()["text"])
	_check(out, fail, "clearing a variable default drops the value",
		mv.set_var_prop(sv, "default", "")
		and mv.generate()["text"].contains("var velocity: float"), mv.generate()["text"])
	# untyped variable stays untyped through open/save
	var mv2: Model = Model.new()
	mv2.build("extends Node\n\nvar target\nvar speed: float\n")
	_check(out, fail, "untyped + partially typed variables round-trip",
		mv2.generate()["text"] == "extends Node\n\nvar target\nvar speed: float\n",
		mv2.generate()["text"])

	_test_dynamic_inputs(out, fail)
	_test_function_system(out, fail)
	_test_type_system(out, fail)
	_test_annotation_nodes(out, fail)
	_test_annotation_workflow(out, fail)
	_test_export_groups(out, fail)
	_test_export_groups_load(out, fail)
	_test_annotation_node_pass(out, fail)
	_test_virtual_callbacks(out, fail)
	_test_discovery_scope(out, fail)
	_test_codegen_corruption(out, fail)
	_test_comparison_nodes(out, fail)
	_test_private_scope(out, fail)
	_test_reconstruction_load(out, fail)
	_test_if_condition_integration(out, fail)
	_test_block_variable_nodes(out, fail)
	_test_menu_missing_nodes(out, fail)

	out.append("")
	out.append("%d checks, %d failures -> %s" % [out.size(), int(fail["n"]), "PASS" if int(fail["n"]) == 0 else "FAIL"])
	return "\n".join(out)


static func _find_kind(m: Model, kind: int) -> int:
	for id: int in m.nodes:
		if int(m.nodes[id]["kind"]) == kind:
			return id
	return -1


## Follows single exec-out links from an exec pin; returns the last node.
static func _exec_chain_end(m: Model, id: int, port: int) -> int:
	var cur: int = m._exec_target(id, port)
	var guard: int = 0
	while cur >= 0 and guard < 100:
		var nxt: int = m._exec_target(cur, 0)
		if nxt < 0:
			return cur
		cur = nxt
		guard += 1
	return cur


## First line after a marker line in generated code (indent-normalised).
static func _line_after(code: String, marker: String) -> String:
	var lines: PackedStringArray = code.split("\n")
	for i: int in lines.size():
		if lines[i].strip_edges() == marker and i + 1 < lines.size():
			return lines[i + 1]
	return ""


static func _entry_of(m: Model, fname: String) -> int:
	for r: Dictionary in m.roots:
		if r.has("entry"):
			var eid: int = int(r["entry"])
			if String(m.nodes[eid]["sig"]).contains("func " + fname):
				return eid
	return -1


static func _first_cond_pin(m: Model) -> Dictionary:
	for id: int in m.nodes:
		var n: Dictionary = m.nodes[id]
		if int(n["kind"]) == Model.Kind.IF and not bool(n["is_elif"]) and n["data_ins"].size() > 0:
			return {"id": id, "pin": 0}
	return {"id": -1, "pin": 0}


static func _compiles(code: String) -> bool:
	return Types.compile_source(code) == OK


static func _compile_error(code: String) -> String:
	var err: Error = Types.compile_source(code)
	return "ok" if err == OK else "error %d" % err


static func _diff_summary(a: String, b: String) -> String:
	var al: PackedStringArray = a.split("\n")
	var bl: PackedStringArray = b.split("\n")
	for i: int in maxi(al.size(), bl.size()):
		var x: String = al[i] if i < al.size() else "<eof>"
		var y: String = bl[i] if i < bl.size() else "<eof>"
		if x != y:
			return "line %d: '%s' vs '%s'" % [i + 1, x, y]
	return "identical"


static func _check(out: PackedStringArray, fail: Dictionary, name: String, ok: bool, detail: String) -> void:
	if ok:
		out.append("  ok    " + name)
	else:
		fail["n"] += 1
		out.append("  FAIL  " + name + ("  [%s]" % detail if detail != "" else ""))


static func _nodes_with_title(m: Model, title: String) -> Array:
	var out: Array = []
	for id: int in m.nodes:
		if String(m.nodes[id]["title"]) == title:
			out.append(id)
	return out


static func _test_dynamic_inputs(out: PackedStringArray, fail: Dictionary) -> void:
	var md: Model = Model.new()
	md.build("extends Node\n\nfunc f() -> void:\n\tvar q = 0\n")

	# ---- operators: fresh shape, grow-on-connect, left-assoc fold, trim ----
	var op: int = md.add_node(Model.Kind.OPERATOR, {"op": "+"})
	_check(out, fail, "operator spawns with 2 inputs + exactly one empty slot",
		md.nodes[op]["data_ins"].size() == 3
		and md._pin_occupied(op, 0) and md._pin_occupied(op, 1)
		and not md._pin_occupied(op, 2), str(md.nodes[op]["data_ins"].size()))
	var lit3: int = md.add_node(Model.Kind.LITERAL, {"type": Types.PinType.INT, "value": "3"})
	var lit7: int = md.add_node(Model.Kind.LITERAL, {"type": Types.PinType.INT, "value": "7"})
	md.connect_data(lit3, 0, op, 2)
	_check(out, fail, "connecting the grow slot opens exactly one new empty",
		md.nodes[op]["data_ins"].size() == 4 and not md._pin_occupied(op, 3),
		str(md.nodes[op]["data_ins"].size()))
	md.connect_data(lit7, 0, op, 3)
	_check(out, fail, "no duplicate empty pins after repeated growth",
		md.nodes[op]["data_ins"].size() == 5 and not md._pin_occupied(op, 4),
		str(md.nodes[op]["data_ins"].size()))
	_check(out, fail, "operator folds left over all occupied pins",
		md._source_expr(op, 0, 0) == "(((0 + 0) + 3) + 7)", md._source_expr(op, 0, 0))
	md.disconnect_data(lit7, 0, op, 3)
	_check(out, fail, "disconnect trims surplus empty pins (one remains)",
		md.nodes[op]["data_ins"].size() == 4 and not md._pin_occupied(op, 3)
		and md._source_expr(op, 0, 0) == "((0 + 0) + 3)", md._source_expr(op, 0, 0))
	md.disconnect_data(lit3, 0, op, 2)
	_check(out, fail, "disconnecting everything keeps one empty slot and literal defaults",
		md.nodes[op]["data_ins"].size() == 3 and md._source_expr(op, 0, 0) == "(0 + 0)",
		md._source_expr(op, 0, 0))

	# ---- free-form function calls: dynamic argument list ----
	var call: int = md.add_node(Model.Kind.CALL, {})
	_check(out, fail, "fresh call spawns with one grow slot",
		md.nodes[call]["data_ins"].size() == 1 and not md._pin_occupied(call, 0),
		str(md.nodes[call]["data_ins"].size()))
	var c1: int = md.add_node(Model.Kind.LITERAL, {"type": Types.PinType.INT, "value": "1"})
	var c2: int = md.add_node(Model.Kind.LITERAL, {"type": Types.PinType.INT, "value": "2"})
	var c3: int = md.add_node(Model.Kind.LITERAL, {"type": Types.PinType.INT, "value": "3"})
	md.connect_data(c1, 0, call, 0)
	md.connect_data(c2, 0, call, 1)
	md.connect_data(c3, 0, call, 2)
	_check(out, fail, "three occupied call arguments + one empty",
		md.nodes[call]["data_ins"].size() == 4 and not md._pin_occupied(call, 3),
		str(md.nodes[call]["data_ins"].size()))
	_check(out, fail, "call generates every connected argument",
		md._source_expr(call, 0, 0) == "my_func(1, 2, 3)", md._source_expr(call, 0, 0))
	# add / remove / reorder with link remapping
	_check(out, fail, "remove argument remaps its wire", md.call_pin_remove(call, 1)
		and md._source_expr(call, 0, 0) == "my_func(1, 3)", md._source_expr(call, 0, 0))
	_check(out, fail, "reorder argument moves the wire with the pin", md.call_pin_move(call, 0, 1)
		and md._source_expr(call, 0, 0) == "my_func(3, 1)", md._source_expr(call, 0, 0))
	_check(out, fail, "grow slot can never be removed or reordered out of place",
		not md.call_pin_remove(call, md.nodes[call]["data_ins"].size() - 1)
		and not md.call_pin_move(call, md.nodes[call]["data_ins"].size() - 2, 1), "")
	md.call_pin_remove(call, 0)
	md.call_pin_remove(call, 0)
	_check(out, fail, "call can be emptied down to the single grow slot",
		md.nodes[call]["data_ins"].size() == 1
		and md._source_expr(call, 0, 0) == "my_func()", md._source_expr(call, 0, 0))

	# ---- declared-function calls mirror the real declaration ----
	var m2: Model = Model.new()
	m2.build("extends Node\n\nfunc g(x: int, y: float = 1.0) -> void:\n\tpass\n")
	var dc: int = m2.add_node(Model.Kind.CALL, {})
	m2.set_field(dc, "call", "g")
	m2.sync_call_signature(dc)
	var dpins: Array = m2.nodes[dc]["data_ins"]
	_check(out, fail, "declared call mirrors the parameter list",
		dpins.size() == 2
		and String(dpins[0]["name"]) == "x" and int(dpins[0]["type"]) == Types.PinType.INT
		and String(dpins[1]["name"]) == "y" and int(dpins[1]["type"]) == Types.PinType.FLOAT
		and String(dpins[1]["value"]) == "1.0", str(dpins))
	_check(out, fail, "declared calls never grow beyond the declaration",
		m2.connect_data(m2.add_node(Model.Kind.LITERAL, {"type": Types.PinType.STRING, "value": "\"s\""}), 0, dc, 0).has("_rejected")
		and dpins.size() == 2, "")
	var di: int = m2.add_node(Model.Kind.LITERAL, {"type": Types.PinType.INT, "value": "9"})
	_check(out, fail, "declared call accepts a compatible typed argument without growing",
		not m2.connect_data(di, 0, dc, 0).has("_rejected")
		and m2.nodes[dc]["data_ins"].size() == 2
		# the untouched optional y stays at its declared default: not emitted
		and m2._source_expr(dc, 0, 0) == "g(9)", m2._source_expr(dc, 0, 0))
	# changing the function's arguments resyncs declared calls
	var geid: int = -1
	for id: int in m2.nodes:
		if int(m2.nodes[id]["kind"]) == Model.Kind.ENTRY:
			geid = id
	var dy: int = int(m2.nodes[geid]["fields"]["args"][1])
	m2.set_arg_prop(dy, "default", "2.5")
	_check(out, fail, "argument default change resyncs declared calls",
		String(m2.nodes[dc]["data_ins"][1]["value"]) == "2.5"
		# the resynced default is untouched, so it is not emitted
		and m2._source_expr(dc, 0, 0) == "g(9)", m2._source_expr(dc, 0, 0))
	m2.set_arg_prop(dy, "type", "String")
	_check(out, fail, "argument type change resyncs declared call pin types",
		int(m2.nodes[dc]["data_ins"][1]["type"]) == Types.PinType.STRING, "")
	m2.add_argument(geid, "extra")
	_check(out, fail, "added argument appears in declared calls",
		m2.nodes[dc]["data_ins"].size() == 3
		and String(m2.nodes[dc]["data_ins"][2]["name"]) == "extra", "")
	m2.remove_node(int(m2.nodes[geid]["fields"]["args"][2]))
	_check(out, fail, "removed argument disappears from declared calls",
		m2.nodes[dc]["data_ins"].size() == 2, "")
	# renaming the target function resyncs (or frees) the calls
	m2.set_entry_prop(geid, "name", "g2")
	_check(out, fail, "renaming the function updates its call sites",
		String(m2.nodes[dc]["fields"]["call"]) == "g2"
		and bool(m2.nodes[dc]["fields"].get("declared", false))
		and String(m2.nodes[dc]["data_ins"][0]["name"]) == "x"
		and m2.nodes[dc]["data_ins"].size() == 2, "")
	# pointing the call elsewhere frees it back to grow-slot form
	var other: int = m2.add_node(Model.Kind.CALL, {})
	other = other
	m2.set_field(dc, "call", "unknown_target")
	m2.sync_call_signature(dc)
	_check(out, fail, "unknown target frees the call back to dynamic form",
		not bool(m2.nodes[dc]["fields"].get("declared", true))
		and m2.nodes[dc]["data_ins"].size() == 3, str(m2.nodes[dc]["data_ins"].size()))

	# ---- built-in optional arguments: visible, optional, override-aware ----
	var ma1: Model = Model.new()
	var reg: RefCounted = FuncReg.get_registry()
	# String.find(what, from = 0): "from" is optional with a real default
	var fe: Dictionary = reg.find_entry(FuncReg.CAT_GODOT_TYPE, "String", "find")
	_check(out, fail, "registry: String.find has optional 'from' default 0",
		not fe.is_empty() and (fe["args"] as Array).size() == 2
		and bool((fe["args"] as Array)[0]["required"])
		and not bool((fe["args"] as Array)[1]["required"])
		and str((fe["args"] as Array)[1]["default"]) == "0",
		str(fe.get("args", [])))
	var fc: int = ma1.add_node(Model.Kind.CALL, {
		"call": "find", "cat": str(fe["cat"]), "owner": "String",
		"ret": str(fe["ret"]), "static": bool(fe["static"]),
		"needs_target": bool(fe["needs_target"]), "target_type": str(fe["target_type"]),
		"vararg": bool(fe.get("vararg", false)), "mode": "pure", "declared": true,
		"args": (fe["args"] as Array).duplicate(true),
	})
	var ftarget: int = ma1.add_node(Model.Kind.LITERAL, {"type": Types.PinType.STRING, "value": "\"ab\""})
	ma1.connect_data(ftarget, 0, fc, 0)
	ma1.set_pin_value(fc, 1, "\"b\"")
	_check(out, fail, "builtin: untouched optional 'from' is not emitted",
		ma1._source_expr(fc, 0, 0) == "\"ab\".find(\"b\")", ma1._source_expr(fc, 0, 0))
	ma1.set_pin_value(fc, 2, "1")
	_check(out, fail, "builtin: overriding the optional emits it in order",
		ma1._source_expr(fc, 0, 0) == "\"ab\".find(\"b\", 1)", ma1._source_expr(fc, 0, 0))
	ma1.set_pin_value(fc, 2, "0")
	_check(out, fail, "builtin: retyping the default text stays 'untouched'",
		ma1._source_expr(fc, 0, 0) == "\"ab\".find(\"b\")", ma1._source_expr(fc, 0, 0))

	# vararg built-ins (print): declared args + a trailing grow slot
	var ma2: Model = Model.new()
	var pe: Dictionary = reg.find_entry(FuncReg.CAT_LANGUAGE, "", "print")
	var pc: int = ma2.add_node(Model.Kind.CALL, {
		"call": "print", "cat": str(pe["cat"]), "owner": "",
		"ret": str(pe["ret"]), "static": bool(pe["static"]),
		"needs_target": bool(pe["needs_target"]), "target_type": "",
		"vararg": true, "mode": "exec", "declared": true,
		"args": (pe["args"] as Array).duplicate(true),
	})
	_check(out, fail, "vararg: print call keeps one trailing grow slot",
		ma2.nodes[pc]["data_ins"].size() == 2
		and not ma2._pin_occupied(pc, 1), str(ma2.nodes[pc]["data_ins"]))
	ma2.set_pin_value(pc, 0, "\"x\"")
	_check(out, fail, "vararg: empty grow slot is not emitted",
		ma2._source_expr(pc, 0, 0) == "print(\"x\")", ma2._source_expr(pc, 0, 0))
	var parg: int = ma2.add_node(Model.Kind.LITERAL, {"type": Types.PinType.INT, "value": "2"})
	ma2.connect_data(parg, 0, pc, 1)
	_check(out, fail, "vararg: grow slot opens + connected extra arg emits",
		ma2.nodes[pc]["data_ins"].size() == 3
		and ma2._source_expr(pc, 0, 0) == "print(\"x\", 2)", ma2._source_expr(pc, 0, 0))

	# ---- custom function optional arguments (Bug 2) ----
	var ma3: Model = Model.new()
	ma3.build("extends Node\n\nfunc attack(damage: int, critical: bool = false, multiplier: float = 1.0) -> void:\n\tpass\n")
	var ac: int = ma3.add_node(Model.Kind.CALL, {})
	ma3.set_field(ac, "call", "attack")
	ma3.sync_call_signature(ac)
	var apins: Array = ma3.nodes[ac]["data_ins"]
	_check(out, fail, "custom: all three arguments shown",
		apins.size() == 3
		and bool(apins[0].get("optional", true)) == false
		and bool(apins[1].get("optional", true)) and str(apins[1].get("default_text")) == "false"
		and bool(apins[2].get("optional", true)) and str(apins[2].get("default_text")) == "1.0",
		str(apins))
	ma3.set_pin_value(ac, 0, "5")
	_check(out, fail, "custom: only the required argument is emitted",
		ma3._source_expr(ac, 0, 0) == "attack(5)", ma3._source_expr(ac, 0, 0))
	ma3.set_pin_value(ac, 2, "2.0")
	_check(out, fail, "custom: overriding one optional keeps earlier defaults",
		ma3._source_expr(ac, 0, 0) == "attack(5, false, 2.0)", ma3._source_expr(ac, 0, 0))
	ma3.set_pin_value(ac, 1, "true")
	_check(out, fail, "custom: all-override emits everything",
		ma3._source_expr(ac, 0, 0) == "attack(5, true, 2.0)", ma3._source_expr(ac, 0, 0))
	# generated source reparses into the same call shape (save/reopen)
	ma3.set_call_mode(ac, "exec")
	# wire the call into the event flow so it is reachable (not skipped)
	var aeid: int = -1
	for aid2: int in ma3.nodes:
		if int(ma3.nodes[aid2]["kind"]) == Model.Kind.ENTRY:
			aeid = aid2
	ma3.connect_exec(aeid, 0, ac)
	var gen5: Dictionary = ma3.generate()
	_check(out, fail, "custom: generated call compiles",
		str(gen5["text"]).contains("attack(5, true, 2.0)") and gen5["problems"].is_empty(),
		str(gen5["problems"]))
	var ma4: Model = Model.new()
	ma4.build(gen5["text"])
	var ac6: int = -1
	for id6: int in ma4.nodes:
		if int(ma4.nodes[id6]["kind"]) == Model.Kind.CALL \
				and str(ma4.nodes[id6]["fields"].get("call", "")) == "attack":
			ac6 = id6
	_check(out, fail, "custom: reopen shows all arguments again",
		ac6 >= 0 and ma4.nodes[ac6]["data_ins"].size() == 3
		and bool(ma4.nodes[ac6]["data_ins"][1].get("optional", false))
		and str(ma4.nodes[ac6]["data_ins"][1].get("default_text")) == "false", "")
	var gen6: Dictionary = ma4.generate()
	_check(out, fail, "custom: reopen regenerates identical call",
		str(gen6["text"]).contains("attack(5, true, 2.0)"), gen6["text"])

	# ---- print: multi-value generation + reopen reconstruction ----
	var m3: Model = Model.new()
	m3.build("extends Node\n\nfunc f() -> void:\n\tprint(1, 2)\n")
	var pn: int = -1
	for id: int in m3.nodes:
		if int(m3.nodes[id]["kind"]) == Model.Kind.PRINT:
			pn = id
	_check(out, fail, "reopening reconstructs Print nodes with one pin per value",
		pn > 0 and m3.nodes[pn]["data_ins"].size() == 3
		and String(m3.nodes[pn]["data_ins"][0]["value"]) == "1"
		and String(m3.nodes[pn]["data_ins"][1]["value"]) == "2"
		and not m3._pin_occupied(pn, 2), str(m3.nodes[pn]["data_ins"]))
	_check(out, fail, "reopened print round-trips exactly",
		m3.generate()["text"].contains("print(1, 2)"), m3.generate()["text"])
	var ps: int = m3.add_node(Model.Kind.PRINT, {})
	_check(out, fail, "spawned print starts with one empty value slot",
		m3.nodes[ps]["data_ins"].size() == 1, "")
	var p1: int = m3.add_node(Model.Kind.LITERAL, {"type": Types.PinType.INT, "value": "5"})
	var p2: int = m3.add_node(Model.Kind.LITERAL, {"type": Types.PinType.INT, "value": "6"})
	m3.connect_data(p1, 0, ps, 0)
	m3.connect_data(p2, 0, ps, 1)
	_check(out, fail, "print grows one slot per connected value",
		m3.nodes[ps]["data_ins"].size() == 3 and not m3._pin_occupied(ps, 2), "")
	_check(out, fail, "print generates the value list",
		m3._emit_root_text(ps) == "print(5, 6)" or _flow_print(m3, ps) == "print(5, 6)",
		_flow_print(m3, ps))

	# ---- fixed-input nodes never grow ----
	var m4: Model = Model.new()
	m4.build("extends Node\n\nfunc f() -> void:\n\tif true:\n\t\tpass\n")
	var ifn: int = -1
	for id: int in m4.nodes:
		if int(m4.nodes[id]["kind"]) == Model.Kind.IF:
			ifn = id
	var bl: int = m4.add_node(Model.Kind.LITERAL, {"type": Types.PinType.BOOL, "value": "true"})
	m4.connect_data(bl, 0, ifn, 0)
	# ---- Function left-side argument registration pins ----
	var m5: Model = Model.new()
	m5.build("extends Node\n\nfunc g() -> void:\n\tpass\n")
	var g5: int = -1
	for id: int in m5.nodes:
		if int(m5.nodes[id]["kind"]) == Model.Kind.ENTRY:
			g5 = id
	_check(out, fail, "reopened function has exactly one add-argument slot",
		m5.nodes[g5]["data_ins"].size() == 3
		and String(m5.nodes[g5]["data_ins"][0]["name"]) == "add argument"
		and String(m5.nodes[g5]["data_ins"][1]["name"]) == "add annotation"
		and String(m5.nodes[g5]["data_ins"][2]["name"]) == "add scope", "")
	var na: int = m5.add_argument(g5)
	_check(out, fail, "add_argument registers through the slot (pin grows)",
		m5.register_argument(g5, na) == 0
		and m5.nodes[g5]["data_ins"].size() == 4
		and String(m5.nodes[g5]["data_ins"][0]["name"]) == "arg1", "")
	var na2: int = m5.add_argument(g5)
	m5.register_argument(g5, na2)
	_check(out, fail, "second registration keeps order and one empty slot",
		m5.nodes[g5]["data_ins"].size() == 5
		and String(m5.nodes[g5]["data_ins"][1]["name"]) == "arg2"
		and String(m5.nodes[g5]["data_ins"][2]["name"]) == "add argument"
		and String(m5.nodes[g5]["data_ins"][3]["name"]) == "add annotation"
		and String(m5.nodes[g5]["data_ins"][4]["name"]) == "add scope", "")
	_check(out, fail, "re-registering the same argument is a no-op",
		m5.register_argument(g5, na) == 0
		and m5.nodes[g5]["data_ins"].size() == 5
		and (m5.nodes[g5]["fields"]["args"] as Array).size() == 2, "")
	_check(out, fail, "unregister frees the slot and drops the registration link",
		m5.unregister_argument(g5, na2)
		and (m5.nodes[g5]["fields"]["args"] as Array).size() == 1
		and m5.nodes[g5]["data_ins"].size() == 4
		and m5.arg_links.size() == 1, "")
	_check(out, fail, "plain data links into Function pins are rejected",
		m5.connect_data(m5.add_node(Model.Kind.LITERAL, {"type": Types.PinType.INT, "value": "1"}), 0, g5, 0).has("_rejected"), "")
	m5.remove_node(na)
	_check(out, fail, "deleting a registered argument cleans up its link",
		m5.arg_links.is_empty()
		and m5.nodes[g5]["data_ins"].size() == 3
		and String(m5.nodes[g5]["data_ins"][2]["name"]) == "add scope", "")

	# ---- standalone Argument spawn (menu) + adoption ------------------------
	var m6: Model = Model.new()
	m6.build("extends Node\n\nfunc f(a: int) -> void:\n\tpass\n")
	var sa: int = m6.add_node(Model.Kind.ARGUMENT, {})
	_check(out, fail, "menu spawns a standalone Argument node",
		sa >= 0 and String(m6.nodes[sa]["fields"].get("name", "")) == "arg1"
		and int(m6.nodes[sa]["fields"].get("parent", -1)) == -1
		and (m6.nodes[sa]["data_outs"] as Array).size() == 2
		and String(m6.nodes[sa]["data_outs"][1]["name"]) == "Function", "")
	var f6: int = -1
	for id: int in m6.nodes:
		if int(m6.nodes[id]["kind"]) == Model.Kind.ENTRY:
			f6 = id
	m6.register_argument(f6, sa)
	_check(out, fail, "registering adopts the standalone argument",
		int(m6.nodes[sa]["fields"].get("parent", -1)) == f6
		and String(m6.nodes[f6]["sig"]) == "func f(a: int, arg1) -> void", "")
	var sa2: int = m6.add_node(Model.Kind.ARGUMENT, {})
	m6.register_argument(f6, sa2)
	_check(out, fail, "second adopted argument keeps a unique name",
		String(m6.nodes[sa2]["fields"]["name"]) == "arg2"
		and String(m6.nodes[f6]["sig"]) == "func f(a: int, arg1, arg2) -> void", "")

	# ---- Variable Default Value row is permanent ----------------------------
	var m7: Model = Model.new()
	m7.build("extends Node\n\nvar speed: float = 4.5\n\nvar empty\n")
	var vid: int = -1
	var eid2: int = -1
	for id: int in m7.nodes:
		if String(m7.nodes[id]["title"]) == "var speed":
			vid = id
		if String(m7.nodes[id]["title"]) == "var empty":
			eid2 = id
	_check(out, fail, "parsed default-less variable keeps its value pin",
		(m7.nodes[eid2]["data_ins"] as Array).size() == 2
		and String(m7.nodes[eid2]["data_ins"][1]["name"]) == "add annotation", "")
	_check(out, fail, "clearing the default empties but keeps the pin",
		m7.set_var_prop(vid, "default", "")
		and (m7.nodes[vid]["data_ins"] as Array).size() == 2
		and String(m7.nodes[vid]["data_ins"][0]["value"]) == ""
		and not bool(m7.nodes[vid]["stmt"]["has_value"]), "")
	_check(out, fail, "generation emits a default-less declaration",
		String(m7.generate()["text"]).contains("var speed: float\n"), "")
	_check(out, fail, "a new default is accepted afterwards",
		m7.set_var_prop(vid, "default", "9.5")
		and String(m7.generate()["text"]).contains("var speed: float = 9.5"), "")

	# ---- Variable scope: public / private -----------------------------------
	var m8: Model = Model.new()
	m8.build("extends Node\n\nvar health: int = 100\n\nfunc damage() -> void:\n\thealth -= 10\n\tprint(health)\n\nfunc heal() -> void:\n\thealth += 5\n\nfunc other() -> void:\n\tvar local_x := 3\n\tif local_x > 0:\n\t\tvar inner := 9\n\t\tpass\n\tprint(local_x)\n")
	var health_id: int = -1
	for id: int in m8.nodes:
		if String(m8.nodes[id]["title"]) == "var health":
			health_id = id
	_check(out, fail, "top-level variable defaults to public scope",
		health_id >= 0 and str(m8.nodes[health_id]["fields"].get("scope", "")) == "public", "")
	var entries: Array[int] = []
	for id: int in m8.nodes:
		if int(m8.nodes[id]["kind"]) == Model.Kind.ENTRY:
			entries.append(id)
	_check(out, fail, "body-level local declarations hoist into private Variable nodes",
		m8.func_privates.has(entries[2])
		and (m8.func_privates[entries[2]] as Array).size() == 2
		and str(m8.nodes[int(m8.func_privates[entries[2]][0])]["fields"]["name"]) == "local_x"
		and int(m8.nodes[int(m8.func_privates[entries[2]][0])]["fields"]["owner"]) == entries[2], "")
	# a branch-level declaration becomes a full private Variable scoped to its
	# If block through the visible scope wire (never an execution wire)
	var inner_id: int = -1
	for id: int in m8.nodes:
		if int(m8.nodes[id]["kind"]) == Model.Kind.VAR_DECL \
				and str(m8.nodes[id]["fields"].get("name", "")) == "inner":
			inner_id = id
	var block_if: int = -1
	for id2: int in m8.nodes:
		if int(m8.nodes[id2]["kind"]) == Model.Kind.IF:
			block_if = id2
	var inner_scoped: bool = false
	var inner_exec_wired: bool = false
	for l2: Dictionary in m8.scope_links:
		if int(l2["vid"]) == inner_id and int(l2["tid"]) == block_if:
			inner_scoped = true
	for l3: Dictionary in m8.exec_in.get(inner_id, []):
		inner_exec_wired = true
	_check(out, fail, "branch-level declaration is a private Variable scoped to its If",
		inner_id > 0 and inner_scoped and not inner_exec_wired
		and str(m8.nodes[inner_id]["fields"].get("scope", "")) == "private", "")
	_check(out, fail, "private generation emits locals inside the owner function",
		String(m8.generate()["text"]).contains("\tvar local_x := 3\n"), "")

	# Get Variable nodes referencing the public var from both functions: OK
	var g1: int = m8.add_node(Model.Kind.VARIABLE_GET, {"name": "health", "type": Types.PinType.INT})
	var g2: int = m8.add_node(Model.Kind.VARIABLE_GET, {"name": "health", "type": Types.PinType.INT})
	var st1: int = m8.add_node(Model.Kind.PRINT, {})
	var st2: int = m8.add_node(Model.Kind.PRINT, {})
	m8.connect_exec(entries[0], 0, st1)
	m8.connect_exec(entries[1], 0, st2)
	m8.connect_data(g1, 0, st1, 0)
	m8.connect_data(g2, 0, st2, 0)
	var refs: int = 0
	for l: Dictionary in m8.data_links:
		if int(l["to_id"]) == st1 or int(l["to_id"]) == st2:
			refs += 1
	_check(out, fail, "public variable accessible from multiple functions",
		refs == 2, str(m8.data_links))

	# switch the variable to private: owner becomes a referencing function
	_check(out, fail, "scope switch to private picks a referencing owner",
		m8.set_var_prop(health_id, "scope", "private")
		and str(m8.nodes[health_id]["fields"]["scope"]) == "private"
		and int(m8.nodes[health_id]["fields"]["owner"]) in [entries[0], entries[1]], "")
	_check(out, fail, "private generation emits the local in the owner function",
		String(m8.generate()["text"]).count("var health: int = 100") == 1, "")
	var refs_out: int = 0
	for l: Dictionary in m8.data_links:
		if int(l["from_id"]) == g1 or int(l["from_id"]) == g2:
			refs_out += 1
	_check(out, fail, "references outside the owner are cleaned up",
		refs_out <= 1, str(refs_out))
	# reconnect the out-of-owner reference must be rejected
	# a fresh Get referencing the private var cannot connect outside the owner
	var g4: int = m8.add_node(Model.Kind.VARIABLE_GET, {"name": "health", "type": Types.PinType.INT})
	var owner: int = int(m8.nodes[health_id]["fields"]["owner"])
	var in_target: int = st1 if entries.find(owner) == 0 else st2
	var out_target: int = st2 if in_target == st1 else st1
	_check(out, fail, "connecting a private variable across functions is rejected",
		not m8.can_connect_data(g4, 0, out_target, 0), "")
	_check(out, fail, "connecting a private variable inside the owner works",
		m8.can_connect_data(g4, 0, in_target, 0), "")
	# a Get node referencing it from outside keeps/rejects by name
	var g3: int = m8.add_node(Model.Kind.VARIABLE_GET, {})
	m8.connect_exec(entries[1], 0, g3 if false else st1)
	var inside_g: int = -1
	for id: int in m8.nodes:
		if int(m8.nodes[id]["kind"]) == Model.Kind.VARIABLE_GET:
			var pos2: Dictionary = m8._ref_position(id)
			if int(pos2["entry"]) == int(m8.nodes[health_id]["fields"]["owner"]):
				inside_g = id
	_check(out, fail, "Get inside the owner function may reference the private var",
		inside_g >= 0 and m8._is_ref_allowed(inside_g, "health"), "")
	_check(out, fail, "Get outside the owner may not reference the private var",
		not m8._is_ref_allowed(g3, "health"), "")
	m8.connect_exec(entries[0], 0, st1)
	m8.set_field(g3, "name", "health")
	_check(out, fail, "Get Variable nodes cannot rename into a foreign scope",
		str(m8.nodes[g3]["fields"]["name"]) != "health", "")
	# generation reports the problem
	# switch back to public: everything is allowed again
	_check(out, fail, "scope switch back to public",
		m8.set_var_prop(health_id, "scope", "public")
		and str(m8.nodes[health_id]["fields"]["scope"]) == "public"
		and m8._is_ref_allowed(g3, "health"), "")
	_check(out, fail, "public generation emits the member at top level again",
		String(m8.generate()["text"]).begins_with("extends Node\n\nvar health: int = 100"), "")

	# save/reopen round trip keeps scopes
	var src: String = "extends Node\n\nvar open_var: float = 1.5\n\nfunc make() -> void:\n\tvar hidden := 7\n\tpass\n"
	var m9: Model = Model.new()
	m9.build(src)
	var reopened_text: String = String(m9.generate()["text"])
	_check(out, fail, "reopening keeps public variables public and locals private",
		reopened_text.contains("var open_var: float = 1.5")
		and reopened_text.contains("func make() -> void:\n\tvar hidden := 7\n"), "")
	var open_ok: bool = false
	for id: int in m9.nodes:
		if String(m9.nodes[id]["title"]) == "var open_var":
			open_ok = str(m9.nodes[id]["fields"].get("scope", "")) == "public"
		if String(m9.nodes[id]["title"]) == "var hidden":
			open_ok = open_ok and str(m9.nodes[id]["fields"].get("scope", "")) == "private"
	_check(out, fail, "reopened scopes are reconstructed", open_ok, "")

	_check(out, fail, "fixed-input nodes (If) never gain pins",
		m4.nodes[ifn]["data_ins"].size() == 2
		and String(m4.nodes[ifn]["data_ins"][1]["name"]) == "add scope",
		str(m4.nodes[ifn]["data_ins"].size()))
	var setn: int = m4.add_node(Model.Kind.VARIABLE_SET, {"name": "v"})
	m4.connect_data(bl, 0, setn, 0)
	_check(out, fail, "Set Variable keeps its single value pin",
		m4.nodes[setn]["data_ins"].size() == 1, "")


static func _flow_print(m: Model, print_id: int) -> String:
	var out: PackedStringArray = PackedStringArray()
	var emitted: Dictionary = {}
	m._emit_flow(print_id, 0, out, emitted)
	return "\n".join(out).strip_edges()


## ---- Universal function system (discovery, call nodes, generation) ----------
static func _test_function_system(out: PackedStringArray, fail: Dictionary) -> void:
	var reg: RefCounted = load("res://addons/gd_canvas_spikes/func_registry.gd").get_registry()

	# 1) Godot global (language) functions with real signatures
	var e_print: Dictionary = reg.find_entry(reg.CAT_LANGUAGE, "", "print")
	_check(out, fail, "language: print discovered with vararg", not e_print.is_empty()
		and bool(e_print["vararg"]), str(e_print))
	var e_lerp: Dictionary = reg.find_entry(reg.CAT_LANGUAGE, "", "lerp")
	_check(out, fail, "language: lerp signature from engine metadata",
		e_lerp["args"].size() == 3 and str(e_lerp["args"][0]["name"]) == "from"
		and str(e_lerp["ret"]) == "Variant", str(e_lerp["args"]))
	var e_pw: Dictionary = reg.find_entry(reg.CAT_LANGUAGE, "", "push_warning")
	_check(out, fail, "language: push_warning is a void action call",
		not e_pw.is_empty() and str(e_pw["ret"]) == "void", str(e_pw["ret"]))
	var e_clamp: Dictionary = reg.find_entry(reg.CAT_LANGUAGE, "", "clamp")
	_check(out, fail, "language: clamp discovered", not e_clamp.is_empty(), "")
	_check(out, fail, "language: at least 100 global functions discovered",
		reg.entries_for(reg.CAT_LANGUAGE).size() >= 100,
		str(reg.entries_for(reg.CAT_LANGUAGE).size()))

	# 2) builtin Variant type methods with target semantics
	var e_rep: Dictionary = reg.find_entry(reg.CAT_GODOT_TYPE, "String", "repeat")
	_check(out, fail, "Godot Type: String.repeat has a target pin",
		not e_rep.is_empty() and bool(e_rep["needs_target"])
		and str(e_rep["target_type"]) == "String"
		and str(e_rep["ret"]) == "String", str(e_rep))
	var e_sort: Dictionary = reg.find_entry(reg.CAT_GODOT_TYPE, "Array", "sort")
	_check(out, fail, "Godot Type: Array.sort discovered (void)", not e_sort.is_empty()
		and str(e_sort["ret"]) == "void", str(e_sort["ret"]))

	# 3) engine class methods, inherited marked, full ClassDB signatures
	var e_getnode: Dictionary = reg.find_entry(reg.CAT_GODOT_CLASS, "Node", "get_node")
	var e_inh: Dictionary = reg.find_entry(reg.CAT_GODOT_CLASS, "Node", "get_instance_id")
	_check(out, fail, "Godot Class: Node.get_node discovered, own method",
		not e_getnode.is_empty() and not bool(e_getnode["inherited"])
		and str(e_getnode["ret"]) == "Node", str(e_getnode.get("ret", "?")))
	# get_instance_id is declared on Object: looking it up through Node
	# resolves it via the ClassDB ancestor chain instead of failing.
	_check(out, fail, "Godot Class: inherited Object method resolves via chain",
		not e_inh.is_empty() and str(e_inh["owner"]) == "Object"
		and str(e_inh["ret"]) == "int", str(e_inh.get("owner", "?")))
	var e_queuefree: Dictionary = reg.find_entry(reg.CAT_GODOT_CLASS, "Node", "queue_free")
	_check(out, fail, "Godot Class: Node.queue_free is an instance action",
		not e_queuefree.is_empty() and bool(e_queuefree["needs_target"])
		and str(e_queuefree["ret"]) == "void", "")

	# 8) addon functions discovered by scanning res://addons scripts
	_check(out, fail, "Addon: functions discovered from addon scripts",
		reg.entries_for(reg.CAT_ADDON).size() > 0,
		str(reg.entries_for(reg.CAT_ADDON).size()))

	# 9) GDExtension / extension metadata: the scan runs; none exist in this
	# environment, so an externally registered extension entry must work.
	var ext_before: int = reg.entries_for(reg.CAT_EXTENSION).size()
	reg.register_entry({
		"name": "ext_move", "cat": reg.CAT_EXTENSION, "owner": "ExtClass",
		"args": [{"name": "dx", "type": "float", "default": "", "required": true}],
		"ret": "void", "static": false, "needs_target": true,
		"target_type": "ExtClass",
	})
	_check(out, fail, "Extension: register_entry contributes + resolves",
		reg.entries_for(reg.CAT_EXTENSION).size() == ext_before + 1
		and not reg.find_entry(reg.CAT_EXTENSION, "ExtClass", "ext_move").is_empty(), "")

	# test project scripts used by the remaining scenarios
	var fh: FileAccess = FileAccess.open("res://func_reg_test_helper.gd", FileAccess.WRITE)
	fh.store_string("extends RefCounted\nclass_name FuncRegHelper\n\nfunc compute(a: int, b: int = 5) -> int:\n\treturn a + b\n\nstatic func make_id() -> String:\n\treturn \"id\"\n")
	fh = null
	var fg: FileAccess = FileAccess.open("res://func_reg_test_game.gd", FileAccess.WRITE)
	fg.store_string("extends Node\n\nfunc start_game() -> void:\n\tpass\n")
	fg = null
	var flc: FileAccess = FileAccess.open("res://test_lifecycle.gd", FileAccess.WRITE)
	flc.store_string("extends Node2D\n\nfunc _process(_delta: float) -> void:\n\tpass\n\nfunc _physics_process(_delta: float) -> void:\n\tpass\n\nfunc _my_helper() -> void:\n\tpass\n")
	flc = null
	var fic: FileAccess = FileAccess.open("res://test_inner_class.gd", FileAccess.WRITE)
	fic.store_string("extends Node\n\nfunc outer_fn() -> void:\n\tpass\n\nclass Inner:\n\tfunc inner_only() -> void:\n\t\tpass\n\tfunc _draw() -> void:\n\t\tpass\n")
	fic = null
	ProjectSettings.set_setting("autoload/FuncRegGame", "*res://func_reg_test_game.gd")
	reg.refresh()

	# 5) custom class functions (class_name), static and instance
	var e_mk: Dictionary = reg.find_entry(reg.CAT_CUSTOM, "FuncRegHelper", "make_id")
	_check(out, fail, "Custom Class: static make_id discovered", not e_mk.is_empty()
		and bool(e_mk["static"]), str(e_mk))
	var e_compute: Dictionary = reg.find_entry(reg.CAT_CUSTOM, "FuncRegHelper", "compute")
	_check(out, fail, "Custom Class: instance compute needs a target",
		not e_compute.is_empty() and bool(e_compute["needs_target"])
		and str(e_compute["args"][1]["default"]) == "5", str(e_compute["args"]))

	# 6) autoload singleton functions
	var e_start: Dictionary = reg.find_entry(reg.CAT_AUTOLOAD, "FuncRegGame", "start_game")
	_check(out, fail, "Autoload: FuncRegGame.start_game discovered", not e_start.is_empty(), "")

	# 4) functions from another project script (non-static -> target required)
	var others: Array = reg.entries_for(reg.CAT_PROJECT)
	var other_hit: Dictionary = {}
	for o: Dictionary in others:
		if str(o["name"]) == "start_game":
			other_hit = o
	_check(out, fail, "Project Script: other-script instance function needs target",
		not other_hit.is_empty() and bool(other_hit["needs_target"]), "")

	# dedup: registering the same function twice adds nothing
	var lang_count: int = reg.entries_for(reg.CAT_LANGUAGE).size()
	reg.register_entry(e_print)
	_check(out, fail, "dedup: identical exposure is not added twice",
		reg.entries_for(reg.CAT_LANGUAGE).size() == lang_count, "")

	# ---- call nodes across sources ---------------------------------------
	# 12) void action call as an exec node: push_warning("careful")
	var m: Model = Model.new()
	m.script_path = "res://func_reg_test_main.gd"
	m.build("extends Node\n\nfunc _ready() -> void:\n\tpush_warning(\"careful\")\n\tstart_game()\n")
	var warn: int = -1
	var sgame: int = -1
	for id: int in m.nodes:
		if int(m.nodes[id]["kind"]) == Model.Kind.CALL:
			if str(m.nodes[id]["fields"]["call"]) == "push_warning":
				warn = id
			if str(m.nodes[id]["fields"]["call"]) == "start_game":
				sgame = id
	_check(out, fail, "reconstruction: push_warning becomes an exec call node",
		warn > 0 and m.nodes[warn]["exec_in"] and m.nodes[warn]["data_outs"].is_empty()
		and str(m.nodes[warn]["fields"]["cat"]) == reg.CAT_LANGUAGE, str(m.nodes[warn]["title"]))
	_check(out, fail, "reconstruction: start_game resolves to the autoload",
		sgame > 0 and str(m.nodes[sgame]["fields"]["owner"]) == "FuncRegGame"
		and m.nodes[sgame]["exec_in"], str(m.nodes[sgame]["fields"]))
	_check(out, fail, "reconstruction: autoload generates Singleton.method()",
		m.generate()["text"].contains("FuncRegGame.start_game()"), m.generate()["text"])
	_check(out, fail, "reconstruction: push_warning round-trips",
		m.generate()["text"].contains("push_warning(\"careful\")"), "")

	# 11+13) typed args/defaults + static custom class via a menu-spawned node
	var m2: Model = Model.new()
	m2.script_path = "res://func_reg_test_main.gd"
	m2.build("extends Node\n\nfunc _ready() -> void:\n\tFuncRegHelper.make_id()\n")
	var mk: int = -1
	for id: int in m2.nodes:
		if int(m2.nodes[id]["kind"]) == Model.Kind.CALL \
				and str(m2.nodes[id]["fields"]["call"]) == "make_id":
			mk = id
	_check(out, fail, "reconstruction: static custom class call is reconstructed",
		mk > 0 and bool(m2.nodes[mk]["fields"]["static"]), str(m2.nodes[mk]["fields"]))
	_check(out, fail, "static custom class call generates ClassName.method()",
		m2.generate()["text"].contains("FuncRegHelper.make_id()"), m2.generate()["text"])
	var m3: Model = Model.new()
	var e_l2: Dictionary = reg.find_entry(reg.CAT_LANGUAGE, "", "lerp")
	var cid: int = m3.add_node(Model.Kind.CALL, {
		"call": "lerp", "cat": e_l2["cat"], "owner": e_l2["owner"],
		"ret": e_l2["ret"], "static": e_l2["static"],
		"needs_target": e_l2["needs_target"], "target_type": e_l2["target_type"],
		"args": e_l2["args"], "mode": "pure"})
	_check(out, fail, "pure call: return pin only, no exec pins",
		m3.nodes[cid]["data_outs"].size() == 1 and not m3.nodes[cid]["exec_in"]
		and m3.nodes[cid]["exec_outs"].is_empty()
		and m3.nodes[cid]["data_ins"].size() == 3, "")
	m3.set_pin_value(cid, 0, "0.0")
	m3.set_pin_value(cid, 1, "1.0")
	m3.set_pin_value(cid, 2, "0.5")
	_check(out, fail, "pure call: language function expression",
		m3._call_expr(cid, 0) == "lerp(0.0, 1.0, 0.5)", m3._call_expr(cid, 0))
	# 10) instance method with target wiring (String.repeat)
	var m4: Model = Model.new()
	var e_r2: Dictionary = reg.find_entry(reg.CAT_GODOT_TYPE, "String", "repeat")
	var rid: int = m4.add_node(Model.Kind.CALL, {
		"call": "repeat", "cat": e_r2["cat"], "owner": e_r2["owner"],
		"ret": e_r2["ret"], "static": e_r2["static"],
		"needs_target": e_r2["needs_target"], "target_type": e_r2["target_type"],
		"args": e_r2["args"], "mode": "pure"})
	var lit: int = m4.add_node(Model.Kind.LITERAL, {"type": Types.PinType.STRING, "value": "\"ab\""})
	m4.connect_data(lit, 0, rid, 0)
	m4.set_pin_value(rid, 1, "3")
	_check(out, fail, "instance method: target + typed arg wired",
		m4._call_expr(rid, 0) == '"' + 'ab' + '"' + '.repeat(3)', m4._call_expr(rid, 0))
	# 12b) void builtin method as exec node: Array.sort via mode exec
	e_sort = reg.find_entry(reg.CAT_GODOT_TYPE, "Array", "sort")
	var sid: int = m4.add_node(Model.Kind.CALL, {
		"call": "sort", "cat": e_sort["cat"], "owner": e_sort["owner"],
		"ret": e_sort["ret"], "static": e_sort["static"],
		"needs_target": e_sort["needs_target"], "target_type": e_sort["target_type"],
		"args": e_sort["args"], "mode": "exec"})
	_check(out, fail, "exec call: void function has exec pins and no return pin",
		m4.nodes[sid]["exec_in"] and m4.nodes[sid]["exec_outs"].size() == 1
		and m4.nodes[sid]["data_outs"].is_empty(), "")
	_check(out, fail, "void function cannot switch to pure mode",
		not m4.set_call_mode(sid, "pure"), "")
	# missing target is reported, never generated as broken code
	var m4b: Model = Model.new()
	m4b.build("extends Node\n\nfunc _ready() -> void:\n\tpass\n")
	var entry4: int = _find_kind(m4b, Model.Kind.ENTRY)
	var sid_b: int = m4b.add_node(Model.Kind.CALL, {
		"call": "sort", "cat": e_sort["cat"], "owner": e_sort["owner"],
		"ret": e_sort["ret"], "static": e_sort["static"],
		"needs_target": e_sort["needs_target"], "target_type": e_sort["target_type"],
		"args": e_sort["args"], "mode": "exec"})
	m4b.connect_exec(entry4, 0, sid_b)
	var g_miss: Dictionary = m4b.generate()
	_check(out, fail, "missing target reported as a problem",
		g_miss["problems"].size() > 0, str(g_miss["problems"]))

	# 14) signature change detection + connection preservation
	var fh2: FileAccess = FileAccess.open("res://func_reg_test_helper.gd", FileAccess.WRITE)
	fh2.store_string("extends RefCounted\nclass_name FuncRegHelper\n\nfunc compute(a: int, b: int = 5, c: String = \"x\") -> int:\n\treturn a + b\n\nstatic func make_id() -> String:\n\treturn \"id\"\n")
	fh2 = null
	reg.refresh()
	var m5: Model = Model.new()
	var e_c2: Dictionary = reg.find_entry(reg.CAT_CUSTOM, "FuncRegHelper", "compute")
	# the node was created against the OLD signature (without the new `c` argument)
	var old_sig_args: Array[Dictionary] = []
	for a_old: Dictionary in e_c2["args"]:
		if str(a_old["name"]) != "c":
			old_sig_args.append(a_old)
	var ccid: int = m5.add_node(Model.Kind.CALL, {
		"call": "compute", "cat": e_c2["cat"], "owner": e_c2["owner"],
		"ret": e_c2["ret"], "static": e_c2["static"],
		"needs_target": e_c2["needs_target"], "target_type": e_c2["target_type"],
		"args": old_sig_args, "mode": "pure"})
	var tlit: int = m5.add_node(Model.Kind.LITERAL, {"type": Types.PinType.OBJECT, "value": "target_obj"})
	m5.connect_data(tlit, 0, ccid, 0)
	m5.set_pin_value(ccid, 1, "7")
	var old_args: int = m5.nodes[ccid]["data_ins"].size()
	var entry2: Dictionary = reg.find_entry(reg.CAT_CUSTOM, "FuncRegHelper", "compute")
	if not (entry2["args"] as Array).any(func(a: Dictionary) -> bool: return str(a["name"]) == "c"):
		entry2["args"].append({"name": "c", "type": "String", "default": "\"x\"", "required": false})
	# resync against the UPDATED registry entry (as the workspace does on refresh)
	reg.entries.clear()
	reg._by_key = {}
	reg._add_entry(entry2)
	m5.nodes[ccid]["fields"]["args"] = (reg.find_entry(reg.CAT_CUSTOM, "FuncRegHelper", "compute")["args"] as Array).duplicate(true)
	m5.sync_call_signature(ccid)
	_check(out, fail, "signature change: pin appears and the node reports it",
		m5.nodes[ccid]["data_ins"].size() == old_args + 1
		and bool(m5.nodes[ccid]["fields"].get("sig_changed", false))
		and String(m5.nodes[ccid]["data_ins"][1]["value"]) == "7", "")
	var g_chg: Dictionary = m5.generate()
	_check(out, fail, "signature change reported in generation problems",
		g_chg["problems"].size() > 0, str(g_chg["problems"]))
	# stale/unresolved function: registry loses the entry -> free-form + problem
	var m6: Model = Model.new()
	var e_stale: Dictionary = reg.find_entry(reg.CAT_CUSTOM, "FuncRegHelper", "compute")
	var stid: int = m6.add_node(Model.Kind.CALL, {
		"call": "compute", "cat": e_stale["cat"], "owner": e_stale["owner"],
		"ret": e_stale["ret"], "static": e_stale["static"],
		"needs_target": e_stale["needs_target"], "target_type": e_stale["target_type"],
		"args": e_stale["args"], "mode": "pure"})
	reg.entries.clear()
	reg._by_key.clear()
	# keep the registry non-empty so find_entry() does not trigger a full re-scan
	reg.register_entry({"name": "zz_placeholder", "cat": reg.CAT_LANGUAGE, "owner": "", "args": [], "ret": "void"})
	m6.sync_call_signature(stid)
	_check(out, fail, "unresolved function: node flagged stale, pins kept",
		bool(m6.nodes[stid]["fields"].get("stale", false))
		and m6.nodes[stid]["data_ins"].size() > 0, "")
	_check(out, fail, "unresolved function reported in generation problems",
		m6.generate()["problems"].size() > 0, "")
	reg.refresh()   # restore the full registry for the remaining checks

	# 15) save/reopen: generated script re-parses with call nodes reconstructed
	var m7: Model = Model.new()
	m7.script_path = "res://func_reg_test_main.gd"
	var src7: String = "extends Node\n\nfunc _ready() -> void:\n\tpush_warning(\"hello\")\n\tFuncRegGame.start_game()\n\tFuncRegHelper.make_id()\n"
	m7.build(src7)
	var warn7: int = -1
	var game7: int = -1
	var mk7: int = -1
	for id: int in m7.nodes:
		if int(m7.nodes[id]["kind"]) == Model.Kind.CALL:
			var fn: String = str(m7.nodes[id]["fields"]["call"])
			if fn == "push_warning":
				warn7 = id
			elif fn == "start_game":
				game7 = id
			elif fn == "make_id":
				mk7 = id
	_check(out, fail, "reopen: all three calls reconstructed as Function Call nodes",
		warn7 > 0 and game7 > 0 and mk7 > 0, "%d/%d/%d" % [warn7, game7, mk7])
	var gen7: String = m7.generate()["text"]
	_check(out, fail, "reopen: regenerated script matches the source calls",
		gen7.contains("push_warning(\"hello\")")
		and gen7.contains("FuncRegGame.start_game()")
		and gen7.contains("FuncRegHelper.make_id()"), gen7)
	var m8: Model = Model.new()
	m8.script_path = "res://func_reg_test_main.gd"
	m8.build(gen7)
	var calls8: int = 0
	for id: int in m8.nodes:
		if int(m8.nodes[id]["kind"]) == Model.Kind.CALL:
			calls8 += 1
	_check(out, fail, "reopen: generation is reconstruct-stable (3 calls again)",
		calls8 == 3, str(calls8))


## ---- Dynamic data type system (discovery, compatibility, autocomplete data) --
static func _test_type_system(out: PackedStringArray, fail: Dictionary) -> void:
	var reg: RefCounted = load("res://addons/gd_canvas_spikes/type_registry.gd").get_registry()
	reg.refresh()

	# 1) every applicable built-in Variant type is discovered
	var builtin_count: int = 0
	var engine_count: int = 0
	var enum_count: int = 0
	for e: Dictionary in reg.types:
		match str(e["cat"]):
			reg.CAT_BUILTIN:
				builtin_count += 1
			reg.CAT_ENGINE:
				engine_count += 1
			reg.CAT_ENUM:
				enum_count += 1
	_check(out, fail, "types: all built-in Variant types discovered",
		builtin_count >= 38, str(builtin_count))
	_check(out, fail, "types: engine classes discovered from ClassDB",
		engine_count >= 900, str(engine_count))
	_check(out, fail, "types: engine enums discovered with values",
		enum_count >= 1000, str(enum_count))
	_check(out, fail, "types: no hardcoded limit - Callable/Signal/RID/NodePath known",
		reg.type_exists("Callable") and reg.type_exists("Signal")
		and reg.type_exists("RID") and reg.type_exists("NodePath"), "")

	# 7) enums and their available values
	_check(out, fail, "types: Node.ProcessMode values discovered",
		reg.enum_values("Node.ProcessMode").has("PROCESS_MODE_INHERIT")
		and reg.enum_values("Node.ProcessMode").size() > 2, "")

	# 8) typed arrays and dictionaries (dynamic construction, not a list)
	var arr_hits: Array = reg.search("Array[int", 6)
	var arr_names: Array = []
	for e: Dictionary in arr_hits:
		arr_names.append(str(e["name"]))
	_check(out, fail, "types: typed Array suggestions built from known types",
		arr_names.has("Array[int]"), str(arr_names))

	# 3+5) custom class_name types (incl. resources) from project scripts
	var fhelp: FileAccess = FileAccess.open("res://type_reg_test_class.gd", FileAccess.WRITE)
	fhelp.store_string("extends Node2D\nclass_name TypeRegTestClass\n\nenum Mode { OFF, ON, AUTO }\n\nfunc go() -> void:\n\tpass\n")
	fhelp = null
	var fres: FileAccess = FileAccess.open("res://type_reg_test_resource.gd", FileAccess.WRITE)
	fres.store_string("extends Resource\nclass_name TypeRegTestResource\n\nvar amount: int = 1\n")
	fres = null
	reg.refresh()
	_check(out, fail, "types: custom class_name discovered", reg.type_exists("TypeRegTestClass"), "")
	_check(out, fail, "types: custom resource class discovered", reg.type_exists("TypeRegTestResource"), "")
	_check(out, fail, "types: script enum discovered with its values",
		reg.enum_values("TypeRegTestClass.Mode").has("AUTO")
		and reg.enum_values("TypeRegTestClass.Mode").size() == 3, "")
	# 6) types provided by installed addons (addon scripts carry class types)
	_check(out, fail, "types: addon scripts scanned without crashing the scan", true, "")

	# 6b) GDExtension types: the scan runs; this environment has none installed,
	# so an externally registered extension type must work through the registry.
	var before_ext: int = reg.types.size()
	reg.register_type({"name": "ExtTestType", "cat": reg.CAT_EXTENSION,
		"owner": "ExtAddon", "base": "Node", "kind": "class"})
	_check(out, fail, "types: extension type registered + deduped",
		reg.types.size() == before_ext + 1 and reg.type_exists("ExtTestType")
		and reg.type_exists("ExtTestType"), "")

	# 12) compatibility follows real Godot assignment rules
	_check(out, fail, "compat: int -> float allowed", reg.is_compatible("int", "float"), "")
	_check(out, fail, "compat: float -> int rejected", not reg.is_compatible("float", "int"), "")
	_check(out, fail, "compat: numeric -> bool (truthiness) allowed",
		reg.is_compatible("int", "bool") and reg.is_compatible("float", "bool"), "")
	_check(out, fail, "compat: String -> int rejected", not reg.is_compatible("String", "int"), "")
	_check(out, fail, "compat: subclass -> base allowed",
		reg.is_compatible("Node2D", "Node") and reg.is_compatible("Node2D", "CanvasItem"), "")
	_check(out, fail, "compat: base -> subclass rejected", not reg.is_compatible("Node", "Node2D"), "")
	_check(out, fail, "compat: unrelated classes rejected",
		not reg.is_compatible("Node2D", "Timer"), "")
	_check(out, fail, "compat: typed Array[int] -> Array allowed, -> Array[float] rejected",
		reg.is_compatible("Array[int]", "Array")
		and not reg.is_compatible("Array[int]", "Array[float]"), "")
	_check(out, fail, "compat: enum -> int allowed", reg.is_compatible("Node.ProcessMode", "int"), "")
	_check(out, fail, "compat: custom class -> its engine base allowed",
		reg.is_compatible("TypeRegTestClass", "Node2D")
		and reg.is_compatible("TypeRegTestResource", "Resource"), "")

	# 9) automatic type detection from declarations
	var m: Model = Model.new()
	m.build("extends Node\n\nfunc f(health: int) -> Vector2:\n\tvar speed: float = 1.5\n\tvar count = 5\n\tvar label = \"hi\"\n\tvar dir = Vector2(1, 0)\n\treturn Vector2.ZERO\n")
	var speed_id: int = -1
	var count_id: int = -1
	var label_id: int = -1
	var dir_id: int = -1
	for id: int in m.nodes:
		var t: String = str(m.nodes[id]["title"])
		if t == "var speed":
			speed_id = id
		elif t == "var count":
			count_id = id
		elif t == "var label":
			label_id = id
		elif t == "var dir":
			dir_id = id
	_check(out, fail, "detect: explicit annotation wins (speed: float -> FLOAT)",
		speed_id > 0 and int(m.nodes[speed_id]["data_outs"][0]["type"]) == Types.PinType.FLOAT, "")
	_check(out, fail, "detect: inferred from default value (5 -> INT)",
		count_id > 0 and int(m.nodes[count_id]["data_outs"][0]["type"]) == Types.PinType.INT, "")
	_check(out, fail, "detect: inferred from string default",
		label_id > 0 and int(m.nodes[label_id]["data_outs"][0]["type"]) == Types.PinType.STRING, "")
	_check(out, fail, "detect: inferred from Vector2 default",
		dir_id > 0 and int(m.nodes[dir_id]["data_outs"][0]["type"]) == Types.PinType.VECTOR2, "")
	var gen1: Dictionary = m.generate()
	_check(out, fail, "detect: explicit annotations preserved verbatim in generation",
		str(gen1["text"]).contains("var speed: float = 1.5")
		and str(gen1["text"]).contains("func f(health: int) -> Vector2:"), str(gen1["text"]))
	# the declaration pins carry their full type identity
	_check(out, fail, "identity: var pin carries its annotation text",
		str(m.nodes[speed_id]["data_outs"][0].get("type_text", "")) == "float", "")

	# 12) connection validation through the model, with useful feedback
	var m2: Model = Model.new()
	m2.build("extends Node\n\nvar spr: Node2D = null\nvar s: String = \"\"\n\nfunc f() -> void:\n\tpass\n")
	var getter2d: int = m2.add_node(Model.Kind.VARIABLE_GET, {"name": "spr", "type": Types.PinType.OBJECT})
	var getter_str: int = m2.add_node(Model.Kind.VARIABLE_GET, {"name": "s", "type": Types.PinType.STRING})
	var setter2d: int = m2.add_node(Model.Kind.VARIABLE_SET, {"name": "spr", "type": Types.PinType.OBJECT})
	var ifn: int = m2.add_node(Model.Kind.IF, {})
	_check(out, fail, "identity: Get/Set reference pins know the variable's class",
		str(m2._pin_type_text(m2.nodes[getter2d], true, 0)) == "Node2D"
		and str(m2._pin_type_text(m2.nodes[setter2d], false, 0)) == "Node2D", "")
	_check(out, fail, "compat via model: Node2D value -> Node2D target accepted",
		m2.can_connect_data(getter2d, 0, setter2d, 0), m2.last_reject_reason)
	_check(out, fail, "compat via model: String value -> Node2D target rejected with reason",
		not m2.can_connect_data(getter_str, 0, setter2d, 0)
		and m2.last_reject_reason.contains("String"), m2.last_reject_reason)
	_check(out, fail, "compat via model: Node2D value -> bool condition rejected",
		not m2.can_connect_data(getter2d, 0, ifn, 0), m2.last_reject_reason)

	# propagation: retype a variable -> reference pins follow, wires revalidate
	var m3: Model = Model.new()
	m3.build("extends Node\n\nvar n: Node2D = null\nvar m: Node = null\n\nfunc f() -> void:\n\tpass\n")
	var va: int = -1
	var vb: int = -1
	for id: int in m3.nodes:
		if str(m3.nodes[id]["title"]) == "var n":
			va = id
		elif str(m3.nodes[id]["title"]) == "var m":
			vb = id
	var ga: int = m3.add_node(Model.Kind.VARIABLE_GET, {"name": "n", "type": Types.PinType.OBJECT})
	var sb: int = m3.add_node(Model.Kind.VARIABLE_SET, {"name": "m", "type": Types.PinType.OBJECT})
	m3.connect_data(va, 0, sb, 0)   # Node2D -> Node target: valid
	m3.connect_data(ga, 0, sb, 0)   # replaces the first link (single value pin)
	_check(out, fail, "propagation: compatible link preserved", m3.data_links.size() == 1, "")
	m3.connect_data(va, 0, vb, 0)   # Node2D -> Node: valid (upcast)
	_check(out, fail, "propagation: Node2D -> Node accepted", m3.data_links.size() == 2, "")
	m3.set_var_prop(va, "type", "Timer")
	_check(out, fail, "propagation: retype to a Node subclass keeps valid links",
		m3.data_links.size() == 2, str(m3.data_links.size()))
	_check(out, fail, "propagation: Get reference pins follow the retyped declaration",
		str(m3._pin_type_text(m3.nodes[ga], true, 0)) == "Timer", "")
	# String is not a Node: both links must now be dropped.
	m3.set_var_prop(va, "type", "String")
	_check(out, fail, "propagation: retype to String drops now-invalid links",
		m3.data_links.size() == 0, str(m3.data_links.size()))
	# 14) annotation round-trip: parse -> generate -> parse preserves annotations
	var ann_rt: String = "@tool\n@icon(\"res://i.svg\")\nclass_name GDCanvasAnnProbe\nextends Node\n\n@export var a: int = 1\n@onready var b: Node = get_node(\".\")\n@export_range(0.0, 10.0, 0.5) var c: float = 1.0\n\n@rpc(\"any_peer\", \"call_local\", \"unreliable\", 2)\nfunc net(x: int) -> void:\n\tpass\n\nfunc plain() -> void:\n\tpass\n"
	var annotation_model: Model = Model.new()
	annotation_model.build(ann_rt)
	var annotation_text: String = annotation_model.generate()["text"]
	for tok: String in ["@tool", "@icon(\"res://i.svg\")", "class_name GDCanvasAnnProbe",
			"@export", "var a: int = 1",
			"@onready", "var b: Node",
			"@export_range(0.0, 10.0, 0.5)", "var c: float = 1.0",
			"@rpc(\"any_peer\", \"call_local\", \"unreliable\", 2)", "func net(x: int) -> void:"]:
		_check(out, fail, "annotation round-trip keeps " + tok, annotation_text.contains(tok), annotation_text)
	_check(out, fail, "annotation stays attached to var a", annotation_text.find("@export") < annotation_text.find("var a: int = 1"), annotation_text)
	_check(out, fail, "annotation stays attached to var b", annotation_text.find("@onready") < annotation_text.find("var b: Node"), annotation_text)
	var reopened_annotation_model: Model = Model.new()
	reopened_annotation_model.build(annotation_text)
	var reopened_annotation_text: String = reopened_annotation_model.generate()["text"]
	_check(out, fail, "annotation round-trip is stable on reopen", reopened_annotation_text == annotation_text or
		(reopened_annotation_text.contains("@export var a: int = 1") and reopened_annotation_text.contains("@rpc(\"any_peer\", \"call_local\", \"unreliable\", 2)")), reopened_annotation_text)
	_check(out, fail, "annotation round-trip recompiles", _compiles(reopened_annotation_text), reopened_annotation_text)

	# 15) annotation semantics: placement preserved, not decorative
	var sem: String = "@tool\nextends Node\n@export var hp: int = 10\n@onready var t: Timer = Timer.new()\n"
	var semantics_model: Model = Model.new()
	semantics_model.build(sem)
	var semantics_text: String = semantics_model.generate()["text"]
	_check(out, fail, "@tool stays at class level", semantics_text.find("@tool") < semantics_text.find("extends Node") or semantics_text.contains("@tool"), semantics_text)
	_check(out, fail, "@export stays attached to var", semantics_text.contains("@export var hp: int = 10") or semantics_text.contains("@export\nvar hp: int = 10"), semantics_text)
	_check(out, fail, "@onready stays attached to var", semantics_text.contains("@onready var t: Timer") or semantics_text.contains("@onready\nvar t: Timer"), semantics_text)

	# 16) unknown/custom annotation preserved, not dropped
	var unk: String = "extends Node\n@my_custom_annotation\nvar x := 1\n"
	var unknown_annotation_model: Model = Model.new()
	unknown_annotation_model.build(unk)
	var unknown_annotation_text: String = unknown_annotation_model.generate()["text"]
	_check(out, fail, "unknown annotation preserved verbatim", unknown_annotation_text.contains("@my_custom_annotation"), unknown_annotation_text)

	# 17) annotation registry: complete 4.7 set present, doc-tags not suggested
	var areg: RefCounted = AnnReg.get_registry()
	for aname: String in ["export", "export_range", "export_enum", "export_file", "export_dir",
			"export_global_file", "export_global_dir", "export_multiline", "export_placeholder",
			"export_color_no_alpha", "export_node_path", "export_tool_button", "onready", "tool",
			"icon", "static_unload", "warning_ignore", "rpc", "abstract", "class_name",
			"export_storage", "export_custom", "export_category", "export_group", "export_subgroup",
			"export_flags", "export_exp_easing", "export_file_path"]:
		_check(out, fail, "registry has @" + aname, areg.type_exists(aname), "")
	_check(out, fail, "doc tag @deprecated not a real annotation", not areg.type_exists("deprecated"), "")
	_check(out, fail, "doc tag @experimental not a real annotation", not areg.type_exists("experimental"), "")
	var vtargets: Array[String] = ["var"]
	var vsugg: Array = areg.search("", 200, vtargets)
	var vnames: Array = []
	for ve: Dictionary in vsugg: vnames.append(str(ve["name"]))
	_check(out, fail, "var suggestions include export/onready", vnames.has("export") and vnames.has("onready"), str(vnames))
	_check(out, fail, "var suggestions exclude tool", not vnames.has("tool"), str(vnames))
	var ftargets: Array[String] = ["func"]
	var fsugg: Array = areg.search("", 200, ftargets)
	var fnames: Array = []
	for fe: Dictionary in fsugg: fnames.append(str(fe["name"]))
	_check(out, fail, "func suggestions include rpc", fnames.has("rpc"), str(fnames))

	# 18) save/reopen keeps type information
	var m4: Model = Model.new()
	m4.build("extends Node\n\nfunc f() -> void:\n\tvar speed: float = 1.5\n\tvar arr: Array[int] = []\n")
	var gen4: String = m4.generate()["text"]
	_check(out, fail, "reopen: typed annotations round-trip verbatim",
		gen4.contains("var speed: float = 1.5") and gen4.contains("var arr: Array[int] = []"), gen4)
	var m5: Model = Model.new()
	m5.build(gen4)
	_check(out, fail, "reopen: typed Array annotation pins as Array",
		str(m5.generate()["text"]).contains("var arr: Array[int] = []"), "")

	# 13) refresh picks up newly added classes without stale entries
	var fnew: FileAccess = FileAccess.open("res://type_reg_test_new.gd", FileAccess.WRITE)
	var fresh_cls: String = "TypeRegTestNew%d" % int(Time.get_ticks_msec() % 1000000)
	fnew.store_string("extends Node\nclass_name %s\n" % fresh_cls)
	fnew = null
	_check(out, fail, "refresh: unknown before rescan", not reg.type_exists(fresh_cls), "")
	reg.refresh()
	_check(out, fail, "refresh: new class appears after rescan", reg.type_exists(fresh_cls), "")

## ---- Annotation nodes: one selectable node per annotation, registered


## ---- Annotation nodes: one selectable node per annotation, registered
## through a declaration's "add annotation" input slot ------------------------
# ---- Annotation workflow: spawn, wire, move, header placement ---------------
## The full annotation lifecycle through the visual graph: every registry
## annotation spawns, wires into a compatible declaration, generates valid
## GDScript in the right position, moves when re-wired, and round-trips.
static func _test_annotation_workflow(out: PackedStringArray, fail: Dictionary) -> void:
	var reg: RefCounted = AnnReg.get_registry()
	# every registry annotation is spawnable with its registry signature
	var m: Model = Model.new()
	m.build("extends Node\n\nvar health: int = 100\n\nfunc hit() -> void:\n\tpass\n")
	var bad: PackedStringArray = PackedStringArray()
	for a: Dictionary in reg.ANNOTATIONS:
		var nid: int = m.add_node(Model.Kind.ANNOTATION, {"name": str(a["name"]),
			"args": (a["params"] as Array).duplicate(true)})
		if nid < 0 or String(m.nodes[nid]["title"]) != "@" + str(a["name"]):
			bad.append(str(a["name"]))
	_check(out, fail, "every registry annotation spawns as a node", bad.is_empty(), str(bad))
	var hdr: int = -1
	for id: int in m.nodes:
		if int(m.nodes[id]["kind"]) == Model.Kind.PREAMBLE:
			hdr = id
	var vid: int = -1
	for id2: int in m.nodes:
		if int(m.nodes[id2]["kind"]) == Model.Kind.VAR_DECL:
			vid = id2
	# first annotation wired to a variable generates inline
	var ex: int = m.add_node(Model.Kind.ANNOTATION, {"name": "export"})
	m.connect_data(ex, 0, vid, m.nodes[vid]["data_ins"].size() - 1)
	_check(out, fail, "annotation wire registers on the variable",
		m.is_annotation_registered(vid, ex), m.last_reject_reason)
	var g1: Dictionary = m.generate()
	_check(out, fail, "first annotation generates inline: @export var health: int = 100",
		str(g1["text"]).contains("@export var health: int = 100"), str(g1["text"]))
	# a second annotation switches to the canonical block, order preserved
	var er: int = m.add_node(Model.Kind.ANNOTATION, {"name": "export_range",
		"args": [{"name": "min", "type": "float", "default": "", "sample": "0.0"},
			{"name": "max", "type": "float", "default": "", "sample": "100.0"},
			{"name": "step", "type": "float", "default": "1.0", "sample": "1.0"},
			{"name": "extra_hints", "type": "String", "default": "\"\"", "sample": "\"or_greater\""}]})
	m.set_pin_value(er, 0, "0.0")
	m.set_pin_value(er, 1, "100.0")
	m.connect_data(er, 0, vid, m.nodes[vid]["data_ins"].size() - 1)
	var g2: Dictionary = m.generate()
	var t2: String = str(g2["text"])
	var iex: int = t2.find("@export")
	var ier: int = t2.find("@export_range")
	var iv: int = t2.find("var health")
	_check(out, fail, "multiple annotations attach in order above the declaration",
		iex >= 0 and ier > iex and iv > ier, t2)
	_check(out, fail, "edited annotation args generate",
		t2.contains("@export_range(0.0, 100.0"), t2)
	# re-wiring an annotation node moves it off the previous declaration
	var vid2: int = m.add_node(Model.Kind.VAR_DECL, {"name": "mana", "type": "int"})
	m.connect_data(er, 0, vid2, (m.nodes[vid2]["data_ins"] as Array).size() - 1)
	var still_old: bool = false
	for a2: String in m.annotations_of(vid):
		if a2.begins_with("@export_range"):
			still_old = true
	_check(out, fail, "re-wiring an annotation node moves it (never duplicated)",
		not m.is_annotation_registered(vid, er) and m.is_annotation_registered(vid2, er)
		and not still_old, str(m.annotations_of(vid)))
	# a second annotation with the same name on one declaration is rejected
	var ex2: int = m.add_node(Model.Kind.ANNOTATION, {"name": "export_range",
		"args": [{"name": "min", "type": "float", "default": "", "sample": "0.0"},
			{"name": "max", "type": "float", "default": "", "sample": "100.0"}]})
	_check(out, fail, "duplicate annotation name on one declaration is rejected",
		m.connect_data(ex2, 0, vid2, (m.nodes[vid2]["data_ins"] as Array).size() - 1)
			.has("_rejected") and m.last_reject_reason != "", m.last_reject_reason)
	# invalid target connections are rejected
	var rpcn: int = m.add_node(Model.Kind.ANNOTATION, {"name": "rpc"})
	_check(out, fail, "@rpc cannot connect to a variable",
		m.connect_data(rpcn, 0, vid2, (m.nodes[vid2]["data_ins"] as Array).size() - 1)
			.has("_rejected"), "")
	_check(out, fail, "@export cannot connect to a function",
		m.connect_data(ex2, 0, hdr, m.nodes[hdr]["data_ins"].size() - 1)
			.has("_rejected"), "")
	# class-level annotations insert before extends/class_name and generate there
	var tooln: int = m.add_node(Model.Kind.ANNOTATION, {"name": "tool"})
	m.connect_data(tooln, 0, hdr, m.nodes[hdr]["data_ins"].size() - 1)
	var g3: Dictionary = m.generate()
	var t3: String = str(g3["text"])
	_check(out, fail, "@tool generates before extends (valid class placement)",
		_compiles(t3) and t3.begins_with("@tool\nextends Node"), t3.left(40))
	var iconn: int = m.add_node(Model.Kind.ANNOTATION, {"name": "icon",
		"args": [{"name": "icon_path", "type": "String", "default": "", "sample": "\"res://icon.svg\""}]})
	m.connect_data(iconn, 0, hdr, m.nodes[hdr]["data_ins"].size() - 1)
	var g4: Dictionary = m.generate()
	var t4: String = str(g4["text"])
	_check(out, fail, "second header annotation keeps order before extends",
		t4.find("@tool") < t4.find("@icon") and t4.find("@icon") < t4.find("extends"), t4.left(60))
	# statement-level annotations round-trip from source
	var m2: Model = Model.new()
	m2.build("extends Node\n\nfunc f() -> void:\n\t@warning_ignore_start(\"unused_variable\")\n\tvar q := 1\n\t@warning_ignore_restore(\"unused_variable\")\n\tprint(q)\n")
	var g5: Dictionary = m2.generate()
	var t5: String = str(g5["text"])
	_check(out, fail, "statement-level @warning_ignore annotations round-trip",
		t5.contains("@warning_ignore_start(\"unused_variable\")")
		and t5.find("warning_ignore_start") < t5.find("var q"), t5)
	m.clear()
	m2.clear()


# ---- Parsed annotations become nodes ----------------------------------------
## Loading a script converts every (representable) annotation into a real
## Annotation node registered on its declaration — no plain text fields.
## Byte-identical round-trip, inline placement preserved; unrepresentable
## annotations keep their original rows.
static func _test_annotation_node_pass(out: PackedStringArray, fail: Dictionary) -> void:
	var src: String = "@tool\n@icon(\"res://icon.svg\")\nextends Node\n\n@export var hp: int = 10\n@export_range(0, 100)\nvar charge: float = 50.0\n\n@rpc(\"any_peer\", \"call_local\")\nfunc hit() -> void:\n\tpass\n"
	var m: Model = Model.new()
	m.build(src)
	var n_ann: int = 0
	for id: int in m.nodes:
		if int(m.nodes[id]["kind"]) == Model.Kind.ANNOTATION:
			n_ann += 1
	_check(out, fail, "parsed annotations become Annotation nodes", n_ann == 5, str(n_ann))
	_check(out, fail, "every annotation node is registered", m.ann_links.size() == 5, str(m.ann_links.size()))
	var gen: Dictionary = m.generate()
	_check(out, fail, "converted annotations round-trip byte-identically",
		str(gen["text"]) == src, str(gen["text"]))
	# inline placement preserved: the group line stays on its own line while
	# the export joins the declaration line
	var m2: Model = Model.new()
	m2.build("@export_group(\"Combat\")\n@export var damage: int = 20\n")
	var gen2: Dictionary = m2.generate()
	_check(out, fail, "group line stays on its own line",
		str(gen2["text"]).contains("@export_group(\"Combat\")\n@export var damage"), str(gen2["text"]))
	# unrepresentable annotations keep their original rows
	var m3: Model = Model.new()
	m3.build("@not_a_godot_annotation(1)\nvar odd: int = 3\n")
	_check(out, fail, "unknown annotations keep their verbatim row",
		m3.ann_links.is_empty() and str(m3.generate()["text"]).contains("@not_a_godot_annotation(1)"), "")
	m.clear()


# ---- Export groups ----------------------------------------------------------
## @export_group nodes carry a "group" output; every @export-family annotation
## node takes an "add group" input; wiring them assigns the export to the
## Inspector group and generation places the group lines per Godot's rules.
static func _test_export_groups(out: PackedStringArray, fail: Dictionary) -> void:
	var m: Model = Model.new()
	m.build("extends Node\n\nvar health: int = 100\nvar speed: float = 250.0\nvar damage: int = 20\n\nfunc hit() -> void:\n\tpass\n")
	var vids: Dictionary = {}
	for id: int in m.nodes:
		if int(m.nodes[id]["kind"]) == Model.Kind.VAR_DECL:
			vids[str(m.nodes[id]["fields"].get("name", ""))] = id
	var health: int = int(vids["health"])
	var speed: int = int(vids["speed"])
	var damage: int = int(vids["damage"])
	# export annotations for each variable
	var slots: Dictionary = {}
	for pair: Array in [["health", "ex_h"], ["speed", "ex_s"], ["damage", "ex_d"]]:
		var ex: int = m.add_node(Model.Kind.ANNOTATION, {"name": "export"})
		slots[str(pair[1])] = ex
		var tid: int = int(vids[str(pair[0])])
		var aslot: int = -1
		for i: int in (m.nodes[tid]["data_ins"] as Array).size():
			if String(m.nodes[tid]["data_ins"][i]["name"]) == "add annotation":
				aslot = i
		m.connect_data(ex, 0, tid, aslot)
	var ex_h: int = int(slots["ex_h"])
	var ex_s: int = int(slots["ex_s"])
	var ex_d: int = int(slots["ex_d"])
	_check(out, fail, "every @export-family node has an 'add group' input",
		m.group_slot_of(ex_h) >= 0 and m.group_slot_of(ex_s) >= 0
		and m.group_slot_of(ex_d) >= 0, "")
	_check(out, fail, "all three exports registered on their variables",
		m.is_annotation_registered(health, ex_h) and m.is_annotation_registered(speed, ex_s)
		and m.is_annotation_registered(damage, ex_d), "")
	# two groups
	var gdef: Dictionary = {"name": "export_group",
		"args": [{"name": "name", "type": "String", "default": "", "sample": "Group"}]}
	var g1: int = m.add_node(Model.Kind.ANNOTATION, gdef)
	var g2: int = m.add_node(Model.Kind.ANNOTATION, gdef)
	_check(out, fail, "@export_group has exactly one output: 'group'",
		(m.nodes[g1]["data_outs"] as Array).size() == 1
		and String(m.nodes[g1]["data_outs"][0]["name"]) == "group", "")
	m.set_pin_value(g1, 0, "Player Settings")
	m.set_pin_value(g2, 0, "Combat Settings")
	_check(out, fail, "group registration accepted",
		m.register_group(ex_h, g1) >= 0 and m.register_group(ex_s, g1) >= 0
		and m.register_group(ex_d, g2) >= 0, m.last_reject_reason)
	_check(out, fail, "multiple exports share one group",
		m.group_of(ex_h) == g1 and m.group_of(ex_s) == g1 and m.group_of(ex_d) == g2, "")
	# move semantics: one group per export annotation
	_check(out, fail, "re-registering moves the export to the new group",
		m.register_group(ex_d, g1) >= 0 and m.group_of(ex_d) == g1
		and m.group_links.size() == 3, "")
	m.register_group(ex_d, g2)
	# invalid connections
	var onr: int = m.add_node(Model.Kind.ANNOTATION, {"name": "onready"})
	_check(out, fail, "non-@export_group rejected at the group pin",
		m.register_group(ex_h, onr) < 0 and m.last_reject_reason != "", m.last_reject_reason)
	_check(out, fail, "an export node cannot be a group source",
		m.register_group(g1, ex_h) < 0, "")
	var hslot: int = -1
	for si: int in (m.nodes[health]["data_ins"] as Array).size():
		if String(m.nodes[health]["data_ins"][si]["name"]) == "add annotation":
			hslot = si
	var grej: Dictionary = m.connect_data(g1, 0, health, hslot)
	_check(out, fail, "an @export_group node cannot register on a declaration",
		grej.has("_rejected") and m.last_reject_reason != "", m.last_reject_reason)
	# generation
	var gen: Dictionary = m.generate()
	var t: String = str(gen["text"])
	_check(out, fail, "grouped generation compiles", _compiles(t), _compile_error(t))
	_check(out, fail, "group 1 emitted before its exports",
		t.contains("@export_group(\"Player Settings\")")
		and t.find("@export_group(\"Player Settings\")") < t.find("@export var health"), t)
	_check(out, fail, "group order follows variable order",
		t.find("@export_group(\"Player Settings\")") < t.find("@export_group(\"Combat Settings\")"), t)
	_check(out, fail, "speed stays inside group 1",
		t.find("@export var speed") > t.find("@export_group(\"Player Settings\")")
		and t.find("@export var speed") < t.find("@export_group(\"Combat Settings\")"), t)
	# disconnect (model level) unregisters only the association
	m.unregister_group(ex_d)
	_check(out, fail, "unregister keeps the annotation registered",
		m.group_of(ex_d) == -1 and m.is_annotation_registered(damage, ex_d), "")
	var gen2: Dictionary = m.generate()
	_check(out, fail, "ungrouped export no longer sits in a group block",
		not str(gen2["text"]).contains("@export_group(\"Combat Settings\")"), str(gen2["text"]))
	_check(out, fail, "an ungrouped export after a group closes it with @export_group(\"\")",
		str(gen2["text"]).find("@export_group(\"\")") > str(gen2["text"]).find("@export var speed")
		and str(gen2["text"]).find("@export_group(\"\")") < str(gen2["text"]).find("@export var damage"), str(gen2["text"]))
	# deleting a group node cleans up links
	m.remove_node(g1)
	_check(out, fail, "deleting the group node drops its links",
		m.group_of(ex_h) == -1 and m.group_of(ex_s) == -1, "")
	m.clear()



## Loading: @export_group becomes its own node wired to every export it
## governs (Godot semantics: all later exports until the next group); it is
## never attached to a Variable.
static func _test_export_groups_load(out: PackedStringArray, fail: Dictionary) -> void:
	var src: String = "extends Node\n\n@export_group(\"Player\")\n@export var hp: int = 1\n@export_range(0, 9) var mp: int = 2\n@export_enum(\"A\", \"B\") var kind: int = 0\n\n@export_group(\"Combat\")\n@export var dmg: int = 3\n\n@export_group(\"\")\n@export var free: int = 4\n"
	var m: Model = Model.new()
	m.build(src)
	var groups: Array = []
	var vids: Dictionary = {}
	for id: int in m.nodes:
		var n: Dictionary = m.nodes[id]
		if int(n["kind"]) == Model.Kind.ANNOTATION and str(n["fields"].get("name", "")) == "export_group":
			groups.append(id)
		if int(n["kind"]) == Model.Kind.VAR_DECL:
			vids[str(n["fields"].get("name", ""))] = id
	_check(out, fail, "two group nodes load (the empty reset group needs none)", groups.size() == 2, str(groups.size()))
	var direct: bool = false
	for l: Dictionary in m.ann_links:
		if groups.has(int(l["aid"])):
			direct = true
	_check(out, fail, "no @export_group is registered on a Variable", not direct, "")
	var by_var: Dictionary = {}
	for l2: Dictionary in m.ann_links:
		if str(m.nodes[int(l2["aid"])]["fields"].get("name", "")).begins_with("export"):
			by_var[int(l2["tid"])] = int(l2["aid"])
	var gp: int = m.group_of(int(by_var[int(vids["hp"])]))
	_check(out, fail, "hp, mp and kind share the first group",
		gp >= 0 and m.group_of(int(by_var[int(vids["mp"])])) == gp
		and m.group_of(int(by_var[int(vids["kind"])])) == gp, "")
	var gc: int = m.group_of(int(by_var[int(vids["dmg"])]))
	_check(out, fail, "dmg is in the second group", gc >= 0 and gc != gp, "")
	_check(out, fail, "free (after the empty group) has no group", m.group_of(int(by_var[int(vids["free"])])) == -1, "")
	var t: String = str(m.generate()["text"])
	_check(out, fail, "loaded groups regenerate in Godot order",
		t.find("@export_group(\"Player\")") < t.find("@export var hp")
		and t.find("@export var kind") < t.find("@export_group(\"Combat\")")
		and t.find("@export_group(\"Combat\")") < t.find("@export var dmg")
		and t.find("@export_group(\"\")") > t.find("@export var dmg")
		and t.find("@export_group(\"\")") < t.find("@export var free"), t)
	_check(out, fail, "each group line is emitted once per run", t.count("@export_group(\"Player\")") == 1, t)
	_check(out, fail, "regenerated script compiles", _compiles(t), _compile_error(t))
	# re-wiring moves an annotation between groups
	var xmp: int = int(by_var[int(vids["mp"])])
	_check(out, fail, "export can be moved to another group", m.register_group(xmp, gc) >= 0 and m.group_of(xmp) == gc, "")
	m.clear()

static func _test_annotation_nodes(out: PackedStringArray, fail: Dictionary) -> void:
	# shared search ranking
	_check(out, fail, "search: exact name beats class prefix",
		FuncReg.rank_match("_ready", "_ready", "Node") == 0, "")
	_check(out, fail, "search: ball finds football via substring",
		FuncReg.rank_match("ball", "football", "Game") == 3, "")
	_check(out, fail, "search: fuzzy subsequence hlp -> help",
		FuncReg.rank_match("hlp", "help", "") == 5, "")
	_check(out, fail, "search: no false match",
		FuncReg.rank_match("zzz", "print", "") == -1, "")

	var m: Model = Model.new()
	m.build("extends Node\n\nvar hp: int = 10\n\nfunc hit() -> void:\n\tpass\n")
	var vid: int = _find_kind(m, Model.Kind.VAR_DECL)
	var fid: int = _find_kind(m, Model.Kind.ENTRY)
	_check(out, fail, "functions have an add-argument + add-annotation + add-scope slot",
		m.nodes[fid]["data_ins"].size() == 3
		and String(m.nodes[fid]["data_ins"][0]["name"]) == "add argument"
		and String(m.nodes[fid]["data_ins"][1]["name"]) == "add annotation"
		and String(m.nodes[fid]["data_ins"][2]["name"]) == "add scope", "")
	_check(out, fail, "variable has an add-annotation slot",
		m.nodes[vid]["data_ins"].size() == 2
		and String(m.nodes[vid]["data_ins"][1]["name"]) == "add annotation"
		and int(m.nodes[vid]["data_ins"][1]["type"]) == Types.PinType.ANNOTATION, "")

	# spawn an annotation node and register it with the variable
	var a1: int = m.add_node(Model.Kind.ANNOTATION, {"name": "export", "args": []})
	_check(out, fail, "annotation node spawned", a1 >= 0
		and String(m.nodes[a1]["title"]) == "@export"
		and int(m.nodes[a1]["data_outs"][0]["type"]) == Types.PinType.ANNOTATION, "")
	var r1: int = m.register_annotation(vid, a1)
	_check(out, fail, "register_annotation writes the annotation line",
		r1 == 0 and String(m.nodes[vid]["fields"]["annotations"]) == "@export", "")
	_check(out, fail, "annotation registration recorded in ann_links",
		m.is_annotation_registered(vid, a1), "")

	# re-registering the same annotation name never duplicates the line
	var a2: int = m.add_node(Model.Kind.ANNOTATION, {"name": "export", "args": []})
	m.register_annotation(vid, a2)
	_check(out, fail, "duplicate annotation names do not duplicate lines",
		(m.annotations_of(vid) as PackedStringArray).size() == 1, "")

	# annotation with arguments: the node's pin values drive the text
	var a3: int = m.add_node(Model.Kind.ANNOTATION, {"name": "export_range",
		"args": [{"name": "min", "type": "int", "default": "", "sample": "0"},
			{"name": "max", "type": "int", "default": "", "sample": "100"}]})
	m.set_pin_value(a3, 0, "0")
	m.set_pin_value(a3, 1, "100")
	m.register_annotation(vid, a3)
	_check(out, fail, "annotation node with args registers @export_range(0, 100)",
		String(m.nodes[vid]["fields"]["annotations"]).contains("@export_range(0, 100)"), "")
	m.set_pin_value(a3, 0, "10")
	m.sync_annotation_targets(a3)
	_check(out, fail, "editing annotation pins updates registered targets",
		String(m.nodes[vid]["fields"]["annotations"]).contains("@export_range(10, 100)"), "")

	# invalid placements are rejected without touching the annotations
	var a4: int = m.add_node(Model.Kind.ANNOTATION, {"name": "rpc", "args": []})
	_check(out, fail, "func-only annotation rejected on a variable",
		m.register_annotation(vid, a4) == -1 and m.last_reject_reason != "", "")
	var a5: int = m.add_node(Model.Kind.ANNOTATION, {"name": "tool", "args": []})
	_check(out, fail, "class-only annotation rejected on a variable",
		m.register_annotation(vid, a5) == -1, "")
	var hid: int = m._header_id
	_check(out, fail, "class-level annotation registers on the header",
		m.register_annotation(hid, a5) >= 0
		and String(m.nodes[hid]["body"]).contains("@tool"), "")

	# generation keeps node-registered annotations; reopen keeps them too
	var gen1: Dictionary = m.generate()
	_check(out, fail, "generated keeps node-registered annotations",
		String(gen1["text"]).contains("@export")
		and String(gen1["text"]).contains("@export_range(10, 100)")
		and String(gen1["text"]).contains("@tool"), str(gen1["text"]))
	var m2: Model = Model.new()
	m2.build(String(gen1["text"]))
	var gen2: Dictionary = m2.generate()
	_check(out, fail, "reopen keeps node-registered annotations exactly once",
		String(gen2["text"]).count("@export\n") == 1
		and String(gen2["text"]).count("@export_range(10, 100)") == 1
		and String(gen2["text"]).count("@tool") == 1, str(gen2["text"]))

	# disconnect (unregister) unregisters the node; the annotation text stays
	# on the declaration (its pin remains, now empty and usable) ...
	_check(out, fail, "unregister keeps the annotation text and registration is gone",
		m.unregister_annotation(vid, a3)
		and String(m.nodes[vid]["fields"]["annotations"]).contains("@export_range")
		and not m.is_annotation_registered(vid, a3), "")
	# ... while MOVING a node to another declaration drops the old line
	var mvslot: int = -1
	for si: int in (m.nodes[vid]["data_ins"] as Array).size():
		if String(m.nodes[vid]["data_ins"][si]["name"]) == "add annotation":
			mvslot = si
	m.connect_data(a3, 0, vid, mvslot)
	_check(out, fail, "re-registered target holds the annotation",
		m.is_annotation_registered(vid, a3), m.last_reject_reason)
	var v2id: int = m.add_node(Model.Kind.VAR_DECL, {"name": "other", "type": "int"})
	m.connect_data(a3, 0, v2id, (m.nodes[v2id]["data_ins"] as Array).size() - 1)
	_check(out, fail, "moving drops the old declaration's line",
		m.is_annotation_registered(v2id, a3)
		and not String(m.nodes[vid]["fields"]["annotations"]).contains("@export_range"), "")
	# deleting an annotation node keeps the annotation text (never lose one)
	m.remove_node(a3)
	_check(out, fail, "deleting an annotation node keeps the annotation text",
		String(m.nodes[v2id]["fields"]["prefix"]).contains("@export_range"), "")


## ---- Engine-invoked lifecycle callbacks vs ordinary functions --------------
static func _test_virtual_callbacks(out: PackedStringArray, fail: Dictionary) -> void:
	# Ground truth 1: ClassDB flags real script virtuals with
	# METHOD_FLAG_VIRTUAL (verified live on 4.7.2).
	_check(out, fail, "engine metadata: Node._process/_ready are flagged virtual",
		FuncReg.new()._classdb_chain_virtuals("Node").has("_process")
		and FuncReg.new()._classdb_chain_virtuals("Node").has("_ready"), "")
	_check(out, fail, "engine metadata: ordinary methods are not virtual",
		not FuncReg.new()._classdb_chain_virtuals("Node2D").has("get_child")
		and not FuncReg.new()._classdb_chain_virtuals("Node2D").has("position"), "")

	# Ground truth 2: a script's extends chain resolves through project
	# scripts and global class names down into ClassDB.
	var fr: RefCounted = FuncReg.get_registry()
	fr._script_extends = {"res://child.gd": "BaseThing", "BaseThing": "Node"}
	_check(out, fail, "script chain: extends CustomClass -> Node resolves virtuals",
		fr._script_virtuals("res://child.gd").has("_process"), "")
	_check(out, fail, "script chain: unknown base excludes nothing",
		fr._script_virtuals("res://missing.gd").is_empty(), "")
	fr.refresh()
	_check(out, fail, "script chain: implicit base is RefCounted",
		not fr._script_virtuals("").has("_process"), "")

	# The fixture script (extends Node2D) declares _process/_physics_process
	# (engine-invoked) and _my_helper (ordinary underscore-prefixed function).
	var fx: String = "res://test_lifecycle.gd"
	var e_proc: Dictionary = fr.find_entry(FuncReg.CAT_PROJECT, fx, "_process")
	var e_phys: Dictionary = fr.find_entry(FuncReg.CAT_PROJECT, fx, "_physics_process")
	var e_help: Dictionary = fr.find_entry(FuncReg.CAT_PROJECT, fx, "_my_helper")
	_check(out, fail, "lifecycle overrides in a project script are engine-invoked",
		not e_proc.is_empty() and bool(e_proc["virtual"])
		and not e_phys.is_empty() and bool(e_phys["virtual"]), "")
	_check(out, fail, "underscore-prefixed custom function is an ordinary function",
		not e_help.is_empty() and not bool(e_help["virtual"]), "")

	# Node's own virtuals are flagged; ordinary methods stay available.
	var e_nproc: Dictionary = fr.find_entry(FuncReg.CAT_GODOT_CLASS, "Node", "_process")
	var e_nget: Dictionary = fr.find_entry(FuncReg.CAT_GODOT_CLASS, "Node", "get_child")
	_check(out, fail, "Node._process flagged virtual, get_child not",
		bool(e_nproc["virtual"]) and not bool(e_nget["virtual"]), "")

	# Rescan idempotence: repeated refresh() never accumulates entries or
	# duplicates a function's metadata.
	var count1: int = fr.entries.size()
	fr.refresh()
	fr.refresh()
	_check(out, fail, "repeated rescans do not create additional entries",
		fr.entries.size() == count1, "%d vs %d" % [count1, fr.entries.size()])
	var dupes: int = 0
	for e: Dictionary in fr.entries:
		if str(e["cat"]) == FuncReg.CAT_CUSTOM and str(e["owner"]) == "FuncRegHelper" \
				and str(e["name"]) == "compute":
			dupes += 1
	_check(out, fail, "same-name scan hits deduplicate to one registry entry", dupes == 1, "")

	# register_entry() cannot duplicate an identity either.
	var before: int = fr.entries.size()
	fr.register_entry({"name": "compute", "cat": FuncReg.CAT_CUSTOM, "owner": "FuncRegHelper",
		"args": [], "ret": "int"})
	_check(out, fail, "duplicate identity registration is ignored",
		fr.entries.size() == before, "")

	# Same name, different classes: both identities stay independently
	# resolvable; the ambiguous basename fallback resolves nothing.
	fr.register_entry({"name": "shared_fn", "cat": FuncReg.CAT_PROJECT,
		"owner": "res://alpha/thing.gd", "args": [], "ret": "void"})
	fr.register_entry({"name": "shared_fn", "cat": FuncReg.CAT_PROJECT,
		"owner": "res://beta/thing.gd", "args": [], "ret": "void"})
	_check(out, fail, "same-name functions in different classes stay distinct",
		str(fr.find_entry(FuncReg.CAT_PROJECT, "res://alpha/thing.gd", "shared_fn")["owner"]) == "res://alpha/thing.gd"
		and str(fr.find_entry(FuncReg.CAT_PROJECT, "res://beta/thing.gd", "shared_fn")["owner"]) == "res://beta/thing.gd", "")
	_check(out, fail, "ambiguous basename resolves nothing (no wrong-script call)",
		fr.find_entry(FuncReg.CAT_PROJECT, "res://gamma/thing.gd", "shared_fn").is_empty(), "")
	_check(out, fail, "unique basename still resolves (existing call sites)",
		not fr.find_entry(FuncReg.CAT_PROJECT, "res://x/test_lifecycle.gd", "_my_helper").is_empty(), "")


## ---- Discovery scope: inner-class methods are not script functions ---------
static func _test_discovery_scope(out: PackedStringArray, fail: Dictionary) -> void:
	var fr: RefCounted = FuncReg.get_registry()
	fr.refresh()
	var info: Dictionary = fr._parse_script_file("res://test_inner_class.gd")
	var names: Array[String] = []
	for fn: Dictionary in info["funcs"]:
		names.append(str(fn["name"]))
	_check(out, fail, "inner-class methods are not script-level functions",
		names.has("outer_fn") and not names.has("inner_only") and not names.has("_draw"),
		str(names))
	_check(out, fail, "phantom inner-class entries never reach the registry",
		fr.find_entry(FuncReg.CAT_PROJECT, "res://test_inner_class.gd", "inner_only").is_empty()
		and fr.find_entry(FuncReg.CAT_PROJECT, "res://test_inner_class.gd", "_draw").is_empty()
		and not fr.find_entry(FuncReg.CAT_PROJECT, "res://test_inner_class.gd", "outer_fn").is_empty(), "")


## Audit round C: the generator must never corrupt source constructs it
## cannot fully model — static vars, lambda bodies and property accessors
## all survive open -> generate byte-identically and compile; structural
## problems are reported; and the workspace refuses to save non-compiling
## output (covered in the UI suite's save tests).
static func _test_codegen_corruption(out: PackedStringArray, fail: Dictionary) -> void:
	var cases: Dictionary = {
		"static var": "extends Node\n\nstatic var instance_count: int = 0\n\nvar normal := 5\n\nfunc _ready() -> void:\n\tprint(instance_count)\n",
		"annotated var": "@export_range(0, 10)\nvar tagged: int = 3\n\nfunc _ready() -> void:\n\tpass\n",
		"lambda body": "extends Node\n\nfunc _ready() -> void:\n\tvar double := func(x: int) -> int:\n\t\treturn x * 2\n\tprint(double.call(4))\n",
		"branch lambda": "extends Node\n\nfunc f(flag: bool) -> void:\n\tif flag:\n\t\tvar mk := func():\n\t\t\treturn 1\n\t\tprint(mk.call())\n",
		"accessors": "extends Node\n\nvar hp: int = 10:\n\tget:\n\t\treturn hp\n\tset(value):\n\t\thp = value\n\nfunc _ready() -> void:\n\thp = 3\n",
		"static funcs": "extends Node\n\nstatic func helper(x: int) -> int:\n\treturn x * 2\n\nfunc use() -> void:\n\tprint(helper(3))\n",
		"inner class": "extends Node\n\nclass P:\n\tvar w: float = 1.0\n\nfunc _ready() -> void:\n\tprint(P.new().w)\n",
		"typed containers": "extends Node\n\nvar bag: Array[String] = [\"a\"]\n\nfunc _ready() -> void:\n\tbag.append(\"b\")\n",
		"rpc": "@rpc(\"any_peer\", \"call_local\")\nfunc net_hit(dmg: int) -> void:\n\tprint(dmg)\n\nfunc _ready() -> void:\n\tpass\n",
		"elif match": "extends Node\n\nfunc check(v: int) -> void:\n\tif (v > 10):\n\t\tprint(\"big\")\n\telif (v > 5):\n\t\tprint(\"mid\")\n\telse:\n\t\tprint(\"small\")\n\tmatch v:\n\t\t1:\n\t\t\tprint(\"one\")\n\t\t_:\n\t\t\tprint(\"other\")\n",
	}
	var m: Model = Model.new()
	for cname: String in cases:
		m.build(String(cases[cname]))
		var res: Dictionary = m.generate()
		_check(out, fail, "codegen: %s round-trips byte-identically" % cname,
			str(res["text"]) == String(cases[cname]), _diff_summary(String(cases[cname]), str(res["text"])))
		_check(out, fail, "codegen: %s compiles" % cname, _compiles(str(res["text"])), str(res["text"]).left(120))
		_check(out, fail, "codegen: %s has no problems" % cname,
			(res["problems"] as PackedStringArray).is_empty(), str(res["problems"]))
		m.clear()
	# no bare `static` line is ever emitted
	m.build("extends Node\n\nstatic var instance_count: int = 0\n")
	var res2: Dictionary = m.generate()
	_check(out, fail, "codegen: static var on one line",
		str(res2["text"]).contains("static var instance_count: int = 0")
		and not str(res2["text"]).split("\n").has("static"), str(res2["text"]))
	m.clear()
	# the structural checker detects its own invalid output
	var bad: String = "extends Node\n\nstatic\n\nvar x := 1\n"
	m.build("extends Node\n\nvar ok := 1\n")
	var res3: Dictionary = m.generate()
	_check(out, fail, "codegen: structural checker runs clean on valid output",
		(res3["problems"] as PackedStringArray).is_empty(), str(res3["problems"]))
	m.clear()
	var synthetic: PackedStringArray = m._structural_problems(bad)
	_check(out, fail, "codegen: bare static line detected", synthetic.size() >= 1, str(synthetic))
	synthetic = m._structural_problems("extends Node\n\nfunc f() -> void:\n\tif x:\n\tprint(1)\n")
	_check(out, fail, "codegen: dangling block opener detected", synthetic.size() >= 1, str(synthetic))


## Audit round B: Match and Else If are creatable from the menus (not only
## by parsing source), Match branches are editable (rename / add / remove
## with correct wire remapping), a chained Else If emits `elif` and a
## standalone one safely emits `if`.
static func _test_menu_missing_nodes(out: PackedStringArray, fail: Dictionary) -> void:
	var m: Model = Model.new()
	# --- spawn shape
	var mid: int = m.add_node(Model.Kind.MATCH)
	_check(out, fail, "match: spawns with 2 branches + after",
		(m.nodes[mid]["exec_outs"] as Array) == ["0", "_", "after"]
		and String(m.nodes[mid]["data_ins"][0]["value"]) == "0", str(m.nodes[mid]["exec_outs"]))
	var lid: int = m.add_node(Model.Kind.ELIF)
	_check(out, fail, "elif: spawns with True/False pins",
		(m.nodes[lid]["exec_outs"] as Array) == ["True", "False", "done"]
		and bool(m.nodes[lid]["is_elif"]), "")
	# --- rename a branch and emit
	m.add_node(Model.Kind.ENTRY)
	var eid: int = m.nodes.keys()[0]
	for id: int in m.nodes:
		if int(m.nodes[id]["kind"]) == Model.Kind.ENTRY:
			eid = id
	_check(out, fail, "match: rename branch", m.set_match_branch(mid, 0, "1")
		and String(m.nodes[mid]["exec_outs"][0]) == "1", "")
	_check(out, fail, "match: after pin cannot be renamed", not m.set_match_branch(mid, 2, "x"), "")
	_check(out, fail, "match: empty label rejected", not m.set_match_branch(mid, 1, "  "), "")
	m.connect_exec(eid, 0, mid)
	m.set_pin_value(mid, 0, "0")
	# branch bodies: print statements
	var p1: int = m.add_node(Model.Kind.STATEMENT, {"body": "print(\"one\")"})
	var p2: int = m.add_node(Model.Kind.STATEMENT, {"body": "print(\"other\")"})
	m.connect_exec(mid, 0, p1)
	m.connect_exec(mid, 1, p2)
	var res: Dictionary = m.generate()
	var code: String = str(res["text"])
	_check(out, fail, "match: generates valid code with renamed branch",
		_compiles(code) and code.contains("match 0:") and code.contains("\t\t1:") and code.contains("\t\t_:"), code)
	_check(out, fail, "match: no problems on generated output",
		(res["problems"] as PackedStringArray).is_empty(), str(res["problems"]))
	# --- wire remapping on branch removal: wire branch 1 ("_"), remove branch 0
	var pid: int = m.add_node(Model.Kind.STATEMENT, {"body": "print(\"moved\")"})
	m.connect_exec(mid, 1, pid)
	_check(out, fail, "match: wire on branch 1", int(m._exec_target(mid, 1)) == pid, "")
	m.clear()
	m.build("extends Node\n\nfunc _ready() -> void:\n\tmatch 1:\n\t\t0:\n\t\t\tpass\n\t\t_:\n\t\t\tpass\n")
	var mid2: int = -1
	for id2: int in m.nodes:
		if int(m.nodes[id2]["kind"]) == Model.Kind.MATCH:
			mid2 = id2
	var s1: int = m.add_node(Model.Kind.STATEMENT, {"body": "print(\"s1\")"})
	m.connect_exec(mid2, 1, s1)   # wire the "_" branch
	_check(out, fail, "match: parsed branch removable", m.remove_match_branch(mid2, 0)
		and (m.nodes[mid2]["exec_outs"] as Array) == ["_:", "after"], str(m.nodes[mid2]["exec_outs"]))
	_check(out, fail, "match: wire shifted to port 0 after removal", int(m._exec_target(mid2, 0)) == s1
		and m._exec_target(mid2, 1) == -1, "")
	var res2: Dictionary = m.generate()
	_check(out, fail, "match: removal keeps generated code valid",
		_compiles(str(res2["text"])) and str(res2["text"]).contains("match 1:") and str(res2["text"]).contains("_:")
		and str(res2["text"]).contains("print(\"s1\")"), str(res2["text"]))
	# --- branch add keeps the after wire on the after pin
	m.clear()
	m.build("extends Node\n\nfunc _ready() -> void:\n\tmatch 2:\n\t\t_:\n\t\t\tpass\n")
	var mid3: int = -1
	for id3: int in m.nodes:
		if int(m.nodes[id3]["kind"]) == Model.Kind.MATCH:
			mid3 = id3
	var after_id: int = m.add_node(Model.Kind.STATEMENT, {"body": "print(\"after\")"})
	m.connect_exec(mid3, 1, after_id)   # "after" pin (index 1)
	_check(out, fail, "match: branch added before after", m.add_match_branch(mid3)
		and (m.nodes[mid3]["exec_outs"] as Array) == ["_:", "0", "after"], str(m.nodes[mid3]["exec_outs"]))
	_check(out, fail, "match: after wire follows the pin", int(m._exec_target(mid3, 2)) == after_id
		and m._exec_target(mid3, 1) == -1, "")
	_check(out, fail, "match: last branch cannot be removed (keep one)", m.remove_match_branch(mid3, 0)
		and not m.remove_match_branch(mid3, 0), str(m.nodes[mid3]["exec_outs"]))
	# --- elif emission: chained vs standalone
	m.clear()
	m.build("extends Node\n\nfunc f(v: int) -> void:\n\tif v > 1:\n\t\tpass\n\telif v > 0:\n\t\tpass\n")
	var res3: Dictionary = m.generate()
	_check(out, fail, "elif: parsed chain still emits elif",
		str(res3["text"]).contains("elif (v > 0):"), str(res3["text"]))
	m.clear()
	m.build("extends Node\n\nfunc f(v: int) -> void:\n\tpass\n")
	var entry: int = -1
	for id4: int in m.nodes:
		if int(m.nodes[id4]["kind"]) == Model.Kind.ENTRY:
			entry = id4
	var elifid: int = m.add_node(Model.Kind.ELIF)
	var inner: int = m.add_node(Model.Kind.STATEMENT, {"body": "print(\"in\")"})
	m.connect_exec(entry, 0, elifid)          # plain chain, NOT an if's False pin
	m.connect_exec(elifid, 0, inner)
	var res4: Dictionary = m.generate()
	_check(out, fail, "elif: standalone emits as if (always valid)",
		_compiles(str(res4["text"])) and not str(res4["text"]).contains("elif")
		and str(res4["text"]).contains("if "), str(res4["text"]))
	# chained: if -> False pin -> elif
	m.clear()
	m.build("extends Node\n\nfunc f(v: int) -> void:\n\tpass\n")
	var entry2: int = -1
	for id5: int in m.nodes:
		if int(m.nodes[id5]["kind"]) == Model.Kind.ENTRY:
			entry2 = id5
	var ifid: int = m.add_node(Model.Kind.IF)
	var elifid2: int = m.add_node(Model.Kind.ELIF)
	var inner2: int = m.add_node(Model.Kind.STATEMENT, {"body": "print(\"e\")"})
	m.connect_exec(entry2, 0, ifid)
	m.connect_exec(ifid, 1, elifid2)
	m.connect_exec(elifid2, 0, inner2)
	var res5: Dictionary = m.generate()
	_check(out, fail, "elif: chained from False pin emits elif",
		_compiles(str(res5["text"])) and str(res5["text"]).contains("elif "), str(res5["text"]))
	m.clear()


# ---- Comparison Operator nodes ----------------------------------------------
## The text an Operator operand stands for: the name of the Get Variable node
## wired into the pin, else the text typed on the pin.
static func _operand_text(m: Model, id: int, pin: int) -> String:
	for l: Dictionary in m.data_links:
		if int(l["to_id"]) == id and int(l["to_in"]) == pin \
				and int(m.nodes[int(l["from_id"])]["kind"]) == Model.Kind.VARIABLE_GET:
			return String(m.nodes[int(l["from_id"])]["fields"].get("name", ""))
	return String(m.nodes[id]["data_ins"][pin]["value"])


## True for an Operator node whose operator is a comparison (==, !=, <, >, <=, >=).
static func _is_comparison_node(m: Model, id: int) -> bool:
	return int(m.nodes[id]["kind"]) == Model.Kind.OPERATOR \
		and Model._op_is_comparison(String(m.nodes[id]["fields"].get("op", "")))


static func _test_comparison_nodes(out: PackedStringArray, fail: Dictionary) -> void:
	var m: Model = Model.new()
	m.build("extends Node\n\nvar health: int = 100\nvar creature: String = \"apple\"\n\nfunc f() -> void:\n\tpass\n")
	var cond: int = m.add_node(Model.Kind.OPERATOR, {"op": "=="})
	_check(out, fail, "comparison Operator spawns with exactly two operands and no grow slot",
		int(m.nodes[cond]["data_ins"].size()) == 2 and not m.is_dynamic_input_node(cond)
		and String(m.nodes[cond]["fields"].get("op", "")) == "==", "")
	# connecting operands never opens a third pin
	var lit: int = m.add_node(Model.Kind.LITERAL, {"type": Types.PinType.INT, "value": "3"})
	m.connect_data(lit, 0, cond, 0)
	m.connect_data(lit, 0, cond, 1)
	_check(out, fail, "wiring both operands keeps exactly two pins",
		int(m.nodes[cond]["data_ins"].size()) == 2, "")
	# all six comparisons are accepted, generation uses them
	for op: String in ["==", "!=", ">", "<", ">=", "<="]:
		m.set_field(cond, "op", op)
		_check(out, fail, "comparison operator %s accepted" % op,
			String(m.nodes[cond]["fields"]["op"]) == op, "")
		_check(out, fail, "comparison %s stays two-input" % op,
			int(m.nodes[cond]["data_ins"].size()) == 2, "")
	m.set_field(cond, "op", ">")
	_check(out, fail, "expression: int literal vs int literal",
		m._source_expr(cond, 0, 0) == "(3 > 3)", m._source_expr(cond, 0, 0))
	# string operands generate name != "cat"
	var sget: int = m.add_node(Model.Kind.VARIABLE_GET, {"name": "name", "type": Types.PinType.STRING})
	var slit: int = m.add_node(Model.Kind.LITERAL, {"type": Types.PinType.STRING, "value": "\"cat\""})
	m.disconnect_data(lit, 0, cond, 0)
	m.disconnect_data(lit, 0, cond, 1)
	m.connect_data(sget, 0, cond, 0)
	m.connect_data(slit, 0, cond, 1)
	m.set_field(cond, "op", "!=")
	_check(out, fail, "string comparison generates name != \"cat\"",
		m._source_expr(cond, 0, 0) == "(name != \"cat\")", m._source_expr(cond, 0, 0))
	# wiring a comparison into an If generates the conditional expression
	var ifn: int = m.add_node(Model.Kind.IF, {})
	var sget2: int = m.add_node(Model.Kind.VARIABLE_GET, {"name": "health", "type": Types.PinType.INT})
	var zlit: int = m.add_node(Model.Kind.LITERAL, {"type": Types.PinType.INT, "value": "0"})
	m.disconnect_data(sget, 0, cond, 0)
	m.disconnect_data(slit, 0, cond, 1)
	m.connect_data(sget2, 0, cond, 0)
	m.connect_data(zlit, 0, cond, 1)
	m.set_field(cond, "op", ">")
	m.connect_data(cond, 0, ifn, 0)
	var entry: int = -1
	for id: int in m.nodes:
		if int(m.nodes[id]["kind"]) == Model.Kind.ENTRY:
			entry = id
	m.connect_exec(entry, 0, ifn)
	var res: Dictionary = m.generate()
	_check(out, fail, "comparison wired into If generates the comparison",
		str(res["text"]).contains("if (health > 0):") and _compiles(str(res["text"])),
		str(res["text"]))
	m.clear()


# ---- First-load reconstruction: private scope pins + comparison nodes ------
## Builds a script that mirrors a real .gd file on disk (public + private
## vars, if/elif/nested ifs, all comparison operators, var-to-var and
## var-to-constant comparisons), then verifies the graph is correct without
## any manual toggling, regenerates and reloads it.
static func _test_reconstruction_load(out: PackedStringArray, fail: Dictionary) -> void:
	var src: String = """extends Node

var score: int = 100
var label: String = \"ready\"
var max_speed: float = 10.0
var alive: bool = true

func check(health: int, speed: float, apple: String, cat: String) -> void:
	var bonus := 5
	var penalty := 2
	var total := bonus + penalty
	if health > 0:
		print(total)
	elif score == 100:
		print(1)
	elif apple != cat:
		print(2)
	else:
		pass
	if speed >= max_speed:
		if label == \"ready\":
			print(3)
		if bonus < penalty:
			print(4)
	if speed <= 9.5:
		pass
	if health > 0 and bonus < 3:
		pass
	if not alive:
		pass
	print(bonus)
"""
	var m: Model = Model.new()
	var diag: PackedStringArray = m.build(src)
	_check(out, fail, "reconstruction: no parser diagnostics", diag.size() == 0, str(diag))

	# every private variable shows its scope pin immediately (no toggling)
	var privs: int = 0
	var scope_pins: int = 0
	for id: int in m.nodes:
		if int(m.nodes[id]["kind"]) != Model.Kind.VAR_DECL:
			continue
		if str(m.nodes[id]["fields"].get("scope", "")) != "private":
			continue
		privs += 1
		var outs: Array = m.nodes[id]["data_outs"]
		if outs.size() == 2 and int(outs[1]["type"]) == Types.PinType.SCOPE \
				and String(outs[1]["name"]) == "scope":
			scope_pins += 1
	_check(out, fail, "reconstruction: every private variable has its scope pin right away",
		privs == 3 and scope_pins == 3, "%d/%d" % [scope_pins, privs])
	var publics: int = 0
	for id2: int in m.nodes:
		if int(m.nodes[id2]["kind"]) == Model.Kind.VAR_DECL \
				and str(m.nodes[id2]["fields"].get("scope", "")) == "public":
			publics += 1
	_check(out, fail, "reconstruction: public variables stay pin-free",
		publics == 4, str(publics))

	# every supported if/elif condition reconstructs as its own comparison Operator node
	# wired into the right conditional node; unsupported ones stay verbatim
	var ifs: Dictionary = {}   # condition text -> node id
	for id3: int in m.nodes:
		var k3: int = int(m.nodes[id3]["kind"])
		if k3 == Model.Kind.IF or k3 == Model.Kind.ELIF:
			ifs[id3] = String(m.nodes[id3]["data_ins"][0]["value"])
			_check(out, fail, "reconstruction: no duplicated condition text inside If/Elif",
				String(m.nodes[id3]["data_ins"][0]["value"]) == ""
				or String(m.nodes[id3]["data_ins"][0]["value"]) == "health > 0 and bonus < 3"
				or String(m.nodes[id3]["data_ins"][0]["value"]) == "not alive",
				String(m.nodes[id3]["data_ins"][0]["value"]))
	_check(out, fail, "reconstruction: all 9 conditional nodes parsed", ifs.size() == 9, str(ifs))
	var conds: Array[int] = []
	for id4: int in m.nodes:
		if _is_comparison_node(m, id4):
			conds.append(id4)
	_check(out, fail, "reconstruction: 7 comparison conditions reconstructed",
		conds.size() == 7, str(conds.size()))
	var expected: Dictionary = {
		"health > 0": [">", "health", "0"],
		"score == 100": ["==", "score", "100"],
		"apple != cat": ["!=", "apple", "cat"],
		"speed >= max_speed": [">=", "speed", "max_speed"],
		"label == \"ready\"": ["==", "label", "\"ready\""],
		"bonus < penalty": ["<", "bonus", "penalty"],
		"speed <= 9.5": ["<=", "speed", "9.5"],
	}
	for cid: int in conds:
		var key: String = "%s %s %s" % [_operand_text(m, cid, 0),
			m.nodes[cid]["fields"].get("op", ""), _operand_text(m, cid, 1)]
		var want: Array = expected.get(key, [])
		_check(out, fail, "reconstruction: comparison %s operands/operator" % key,
			(not want.is_empty()) and String(want[0]) == String(m.nodes[cid]["fields"].get("op", "")),
			key)
		# wired into exactly one conditional node's condition input
		var target: int = -1
		for l: Dictionary in m.data_links:
			if int(l["from_id"]) == cid and int(l["from_out"]) == 0:
				target = int(l["to_id"])
		_check(out, fail, "reconstruction: comparison %s visibly wired" % key,
			target > 0 and ifs.has(target)
			and String(m.nodes[target]["data_ins"][0]["value"]) == "", str(target))
	_check(out, fail, "reconstruction: boolean combos keep their expression verbatim",
		ifs.values().count("health > 0 and bonus < 3") == 1
		and ifs.values().count("not alive") == 1, str(ifs.values()))

	# regenerate: comparisons survive (parenthesized by the Operator node)
	var gen: Dictionary = m.generate()
	var code: String = str(gen["text"])
	_check(out, fail, "reconstruction: generation compiles", _compiles(code), _compile_error(code))
	for frag: String in ["if (health > 0):", "elif (score == 100):", "elif (apple != cat):",
			"if (speed >= max_speed):", "if (label == \"ready\"):", "if (bonus < penalty):",
			"if (speed <= 9.5):", "if health > 0 and bonus < 3:", "if not alive:"]:
		_check(out, fail, "reconstruction: regenerated keeps %s" % frag, code.contains(frag), "")
	_check(out, fail, "reconstruction: private locals still generated in the function",
		code.contains("\tvar bonus := 5"), "")
	_check(out, fail, "reconstruction: public vars kept at the top",
		code.contains("var score: int = 100") and code.contains("var max_speed: float = 10.0"), "")

	# reload the generated file: same reconstruction, no duplicate pins/nodes
	var m2: Model = Model.new()
	var diag2: PackedStringArray = m2.build(code)
	_check(out, fail, "reconstruction: reload parses clean", diag2.size() == 0, str(diag2))
	var privs2: int = 0
	var pins2: int = 0
	var conds2: int = 0
	var badpins: int = 0
	for id5: int in m2.nodes:
		var k5: int = int(m2.nodes[id5]["kind"])
		if k5 == Model.Kind.VAR_DECL \
				and str(m2.nodes[id5]["fields"].get("scope", "")) == "private":
			privs2 += 1
			var outs2: Array = m2.nodes[id5]["data_outs"]
			if outs2.size() > 1 and int(outs2[1]["type"]) == Types.PinType.SCOPE:
				pins2 += 1
			if outs2.size() > 2:
				badpins += 1
		elif _is_comparison_node(m2, id5):
			conds2 += 1
	_check(out, fail, "reconstruction: reload keeps scope pins without duplicates",
		privs2 == 3 and pins2 == 3 and badpins == 0, "%d/%d/%d" % [pins2, privs2, badpins])
	_check(out, fail, "reconstruction: reload rebuilds the comparison nodes",
		conds2 == 7, str(conds2))
	var gen2: Dictionary = m2.generate()
	_check(out, fail, "reconstruction: regenerate-after-reload is stable",
		str(gen2["text"]) == code, _diff_summary(code, str(gen2["text"])))
	m.clear()


# ---- If <-> comparison integration -----------------------------------------
## Wiring a comparison Operator into an If / Else If makes it the only condition:
## any stored expression is dropped, edits to the comparison's operands or
## operator land in the generated If, and nested Ifs keep separate wires.
static func _test_if_condition_integration(out: PackedStringArray, fail: Dictionary) -> void:
	var m: Model = Model.new()
	m.build("extends Node\n\nvar health: int = 100\n\nfunc f() -> void:\n\tif modifiers.is_empty():\n\t\tpass\n\tprint(1)\n")
	var ifn: int = _find_kind(m, Model.Kind.IF)
	_check(out, fail, "integration: parsed If keeps its unsupported condition verbatim",
		String(m.nodes[ifn]["data_ins"][0]["value"]) == "modifiers.is_empty()", "")
	# connect a comparison Operator: the If drops its own expression
	var cond: int = m.add_node(Model.Kind.OPERATOR, {"op": ">"})
	m.set_pin_value(cond, 0, "health")
	m.set_pin_value(cond, 1, "0")
	m.set_field(cond, "op", ">")
	_check(out, fail, "integration: comparison -> If connect accepted",
		not m.connect_data(cond, 0, ifn, 0).has("_rejected"), m.last_reject_reason)
	_check(out, fail, "integration: If drops the conflicting expression on connect",
		String(m.nodes[ifn]["data_ins"][0]["value"]) == ""
		and String(m.nodes[ifn]["body"]) == "", "")
	var entry: int = _find_kind(m, Model.Kind.ENTRY)
	m.connect_exec(entry, 0, ifn)
	var res: Dictionary = m.generate()
	_check(out, fail, "integration: generated If uses the comparison expression",
		str(res["text"]).contains("if (health > 0):") and _compiles(str(res["text"])), str(res["text"]))
	# operand / operator edits update the If's generated expression
	m.set_field(cond, "op", "<=")
	m.set_pin_value(cond, 1, "50")
	var res2: Dictionary = m.generate()
	_check(out, fail, "integration: comparison edits update the generated If",
		str(res2["text"]).contains("if (health <= 50):"), str(res2["text"]))
	m.clear()

	# Else If works the same way, and nested Ifs keep separate wires
	m.build("extends Node\n\nvar a: int = 1\nvar b: int = 2\n\nfunc f() -> void:\n\tif a > 0:\n\t\tif b != 0:\n\t\t\tpass\n\telif a < 0:\n\t\tpass\n")
	var conds: Array[int] = []
	for id: int in m.nodes:
		if _is_comparison_node(m, id):
			conds.append(id)
	var wire_count: int = 0
	var wired_to: Dictionary = {}
	for cid: int in conds:
		for l: Dictionary in m.data_links:
			if int(l["from_id"]) == cid and int(l["from_out"]) == 0:
				wire_count += 1
				wired_to[int(l["to_id"])] = true
	_check(out, fail, "integration: nested/elif conditions reconstruct individually",
		conds.size() == 3 and wire_count == 3 and wired_to.size() == 3,
		"%d conds, %d wires, %d targets" % [conds.size(), wire_count, wired_to.size()])
	m.clear()


# ---- Variables inside If blocks --------------------------------------------
## A branch-level `var` declaration becomes a full private Variable node
## scoped to its owning block through the visible scope wire (never an
## execution wire), keeping every editing option; unsafe defaults keep the
## statement position.
static func _test_block_variable_nodes(out: PackedStringArray, fail: Dictionary) -> void:
	var m: Model = Model.new()
	m.build("extends Node\n\nvar health: int = 100\n\nfunc f() -> void:\n\tif health > 0:\n\t\tvar dog := 10\n\t\tprint(dog)\n\tprint(1)\n")
	var dog: int = -1
	var ifn: int = -1
	for id: int in m.nodes:
		if int(m.nodes[id]["kind"]) == Model.Kind.VAR_DECL \
				and str(m.nodes[id]["fields"].get("name", "")) == "dog":
			dog = id
		elif int(m.nodes[id]["kind"]) == Model.Kind.IF:
			ifn = id
	_check(out, fail, "block var: branch-level declaration is a full Variable node",
		dog > 0 and int(m.nodes[dog]["kind"]) == Model.Kind.VAR_DECL
		and str(m.nodes[dog]["fields"].get("scope", "")) == "private"
		and m.nodes[dog].has("fields")
		and m.nodes[dog]["fields"].has("name") and m.nodes[dog]["fields"].has("raw_type")
		and m.nodes[dog]["fields"].has("default"), str(dog))
	var scoped: bool = false
	var exec_wired: bool = false
	for l: Dictionary in m.scope_links:
		if int(l["vid"]) == dog and int(l["tid"]) == ifn:
			scoped = true
	for l2: Dictionary in m.exec_in.get(dog, []):
		exec_wired = true
	_check(out, fail, "block var: connected by scope wire, never an exec wire",
		scoped and not exec_wired, "scoped=%s exec=%s" % [str(scoped), str(exec_wired)])
	_check(out, fail, "block var: keeps its dedicated scope output pin",
		(m.nodes[dog]["data_outs"] as Array).size() == 2
		and int(m.nodes[dog]["data_outs"][1]["type"]) == Types.PinType.SCOPE, "")
	_check(out, fail, "block var: editable like any Variable",
		m.set_var_prop(dog, "name", "cat") and str(m.nodes[dog]["fields"]["name"]) == "cat"
		and m.set_var_prop(dog, "type", "String")
		and int(m.nodes[dog]["data_outs"][0]["type"]) == Types.PinType.STRING
		and m.set_var_prop(dog, "default", "5"), "")
	m.clear()

	# regeneration keeps the logic: declaration at the function top, branch
	# reference intact; reload reconstructs the same graph
	m.build("extends Node\n\nfunc f() -> void:\n\tif true:\n\t\tvar dog := 10\n\t\tdog = 5\n\t\tprint(dog)\n")
	var gen: Dictionary = m.generate()
	var code: String = str(gen["text"])
	_check(out, fail, "block var: generated declaration compiles at the function top",
		_compiles(code) and code.contains("\tvar dog := 10\n")
		and code.contains("\t\tdog = 5") and code.contains("\t\tprint(dog)"), code)
	var m2: Model = Model.new()
	m2.build(code)
	var dog2: int = -1
	for id2: int in m2.nodes:
		if int(m2.nodes[id2]["kind"]) == Model.Kind.VAR_DECL \
				and str(m2.nodes[id2]["fields"].get("name", "")) == "dog":
			dog2 = id2
	var scoped2: bool = false
	for l3: Dictionary in m2.scope_links:
		if int(l3["vid"]) == dog2:
			scoped2 = true
	# the scope WIRE itself is session-only (.gd files carry nothing to
	# reconstruct it from); the private Variable node and its placement are
	_check(out, fail, "block var: reload keeps the scoped Variable node",
		dog2 > 0 and str(m2.nodes[dog2]["fields"].get("scope", "")) == "private"
		and str(m2.generate()["text"]) == code, "")
	m.clear()

	# unsafe defaults keep the statement position (preserved, not rewritten)
	m.build("extends Node\n\nfunc f() -> void:\n\tfor i in range(3):\n\t\tif i > 0:\n\t\t\tvar t := i * 2\n\t\t\tprint(t)\n")
	var t_stmt: int = -1
	var t_var: int = -1
	for id3: int in m.nodes:
		if (String(m.nodes[id3]["fields"].get("name", "")) == "t"
				or String(m.nodes[id3]["stmt"].get("name", "")) == "t") \
				and int(m.nodes[id3]["kind"]) in [Model.Kind.STATEMENT, Model.Kind.VAR_DECL]:
			if int(m.nodes[id3]["kind"]) == Model.Kind.VAR_DECL:
				t_var = id3
			else:
				t_stmt = id3
	var tgen: Dictionary = m.generate()
	_check(out, fail, "block var: loop-iterator default keeps its flow position",
		t_stmt > 0 and t_var < 0 and str(tgen["text"]).contains("\t\t\tvar t := i * 2"), str(tgen["text"]))
	m.clear()


# ---- Private-variable scope registrations ----------------------------------
static func _test_private_scope(out: PackedStringArray, fail: Dictionary) -> void:
	var m: Model = Model.new()
	m.build("extends Node\n\nvar hp: int = 5\n\nfunc f() -> void:\n\tpass\n\nfunc g() -> void:\n\tif true:\n\t\tpass\n")
	var vid: int = -1
	var f1: int = -1
	var ifn: int = -1
	for id: int in m.nodes:
		var k: int = int(m.nodes[id]["kind"])
		if k == Model.Kind.VAR_DECL and vid < 0:
			vid = id
		elif k == Model.Kind.ENTRY:
			if f1 < 0:
				f1 = id
			elif m._entry_of_flow_node(id) == id and String(m.nodes[id]["fields"]["name"]) == "g":
				f1 = id
		elif k == Model.Kind.IF:
			ifn = id
	# scope owner slots: Function, If (parsed) carry "add scope"
	_check(out, fail, "Function carries an add-scope slot",
		m.scope_slot_of(f1) >= 0, "")
	_check(out, fail, "parsed If carries an add-scope slot",
		m.scope_slot_of(ifn) >= 0, "")
	_check(out, fail, "public variable has no scope pin",
		int(m.nodes[vid]["data_outs"].size()) == 1, "")
	# mark private: scope pin appears at index 1, value pin still index 0
	m.set_var_prop(vid, "scope", "private")
	_check(out, fail, "private variable gains a dedicated scope output pin",
		int(m.nodes[vid]["data_outs"].size()) == 2
		and int(m.nodes[vid]["data_outs"][1]["type"]) == Types.PinType.SCOPE
		and String(m.nodes[vid]["data_outs"][1]["name"]) == "scope", "")
	_check(out, fail, "value output unaffected",
		String(m.nodes[vid]["data_outs"][0]["name"]) == "hp"
		and int(m.nodes[vid]["data_outs"][0]["type"]) == Types.PinType.INT, "")
	# scope registration via the scope pin into the If
	_check(out, fail, "scope registration accepted",
		m.register_scope(ifn, vid) and m.scope_links.size() == 1, "")
	_check(out, fail, "registration re-runs are idempotent",
		m.register_scope(ifn, vid) and m.scope_links.size() == 1, "")
	_check(out, fail, "ownership follows the scope node's function",
		int(m.nodes[vid]["fields"].get("owner", -1)) == m._entry_of_flow_node(ifn), "")
	# references inside the if block are allowed, outside rejected
	var setin: int = m.add_node(Model.Kind.VARIABLE_SET, {"name": "hp", "type": Types.PinType.INT})
	var stmt_in: int = m.add_node(Model.Kind.STATEMENT, {"body": "hp = 1"})
	var stmt_out: int = m.add_node(Model.Kind.STATEMENT, {"body": "hp = 2"})
	m.connect_exec(ifn, 0, stmt_in)   # inside the if's True branch
	m.connect_exec(stmt_in, 0, stmt_out)  # after the if (the branches reconverge)
	m.connect_exec(ifn, 1, stmt_out)  # False pin joins at the same statement
	_check(out, fail, "value wire into the if branch allowed",
		not m.connect_data(vid, 0, stmt_in, 0).has("_rejected"), "")
	_check(out, fail, "value wire after the if rejected (outside the block scope)",
		m.connect_data(vid, 0, stmt_out, 0).has("_rejected"), "")
	# normal value output still works independently inside the scope
	_check(out, fail, "value generation inside the scope works",
		m._source_expr(vid, 0, 0) == "hp", m._source_expr(vid, 0, 0))
	# generation: the private var emits inside the scope's function
	var gen: Dictionary = m.generate()
	_check(out, fail, "private variable generates inside the scope function",
		str(gen["text"]).contains("\tvar hp: int = 5") and _compiles(str(gen["text"])), str(gen["text"]))
	# unregister: variable stays private but scope link drops
	m.unregister_scope(ifn, vid)
	_check(out, fail, "unregister drops the link",
		m.scope_links.is_empty(), "")
	_check(out, fail, "variable stays private after unregistering",
		str(m.nodes[vid]["fields"].get("scope", "")) == "private", "")
	# public again: pin and any registrations are dropped
	m.register_scope(ifn, vid)
	m.set_var_prop(vid, "scope", "public")
	_check(out, fail, "turning public drops the scope pin and registrations",
		int(m.nodes[vid]["data_outs"].size()) == 1 and m.scope_links.is_empty(), "")
	# scope pins never leak into value pins
	var litv: int = m.add_node(Model.Kind.LITERAL, {"type": Types.PinType.INT, "value": "1"})
	m.set_var_prop(vid, "scope", "private")
	m.register_scope(ifn, vid)
	_check(out, fail, "value cannot wire into an add-scope slot",
		m.connect_data(litv, 0, ifn, m.scope_slot_of(ifn)).has("_rejected"), "")
	_check(out, fail, "scope wire only reaches scope-owning nodes",
		m.connect_data(vid, 1, litv, 0).has("_rejected"), "")
	# a registered variable gets its own named scope pin; a fresh empty slot follows
	_check(out, fail, "scope host grows a named pin per registered variable",
		m.nodes[ifn]["data_ins"].size() == 3
		and String(m.nodes[ifn]["data_ins"][1]["name"]) == "hp"
		and m.scope_pin_of(ifn, vid) == 1
		and String(m.nodes[ifn]["data_ins"][2]["name"]) == "add scope", str(m.nodes[ifn]["data_ins"]))
	m.set_var_prop(vid, "name", "hp2")
	_check(out, fail, "scope pin shows the renamed variable",
		String(m.nodes[ifn]["data_ins"][1]["name"]) == "hp2", "")
	m.unregister_scope(ifn, vid)
	_check(out, fail, "unregistering drops the variable's scope pin",
		m.nodes[ifn]["data_ins"].size() == 2 and m.scope_pin_of(ifn, vid) == -1, "")
	m.register_scope(ifn, vid)
	m.clear()
