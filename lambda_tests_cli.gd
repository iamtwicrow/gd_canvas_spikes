# Runs headless: godot --headless --path <project> -s res://addons/gd_canvas_spikes/lambda_tests_cli.gd
extends SceneTree
## Headless tests for the Lambda (Callable) node system: lambda parsing into
## Lambda nodes, single-line / multi-line generation, the parsed round trip
## (byte-identical), pin compatibility of the Callable output, parameter
## editing and the node-menu entry.

const Model = preload("res://addons/gd_canvas_spikes/graph_model.gd")
const Types = preload("res://addons/gd_canvas_spikes/graph_types.gd")
const TypeReg = preload("res://addons/gd_canvas_spikes/type_registry.gd")
const FuncReg = preload("res://addons/gd_canvas_spikes/func_registry.gd")

var fails: int = 0
var checks: int = 0


func _check(label: String, ok: bool, detail: String = "") -> void:
	checks += 1
	if ok:
		print("  ok   ", label)
	else:
		fails += 1
		print("  FAIL ", label, "  ", detail)


func _compiles(code: String) -> bool:
	return Types.compile_source(code) == OK


## Builds a graph from `src`, generates, and reports {identical, stable,
## text, model, problems}.
func _roundtrip(src: String) -> Dictionary:
	var m: Model = Model.new()
	m.build(src)
	var r: Dictionary = m.generate()
	var text: String = str(r["text"])
	var m2: Model = Model.new()
	m2.build(text)
	var r2: Dictionary = m2.generate()
	return {
		"identical": text == src,
		"stable": str(r2["text"]) == text,
		"text": text,
		"model": m,
		"problems": r["problems"],
		"regen": r2,
	}


func _init() -> void:
	TypeReg.get_registry().refresh()
	FuncReg.get_registry().refresh()
	_test_types()
	_test_parse_static()
	_test_parse_multiline()
	_test_parse_freeform_call()
	_test_condition_call()
	_test_variable_reads()
	_test_parse_call_arg()
	_test_parse_assignment()
	_test_authored_lambda()
	_test_editing()
	_test_compatibility()
	_test_rename_and_flow()
	_test_hardening()
	await _test_ui()
	await _test_ui_feedback()
	print("%d checks, %d failures -> %s" % [checks, fails, "PASS" if fails == 0 else "FAIL"])
	quit(1 if fails > 0 else 0)


# ---- Pin type ----------------------------------------------------------------
func _test_types() -> void:
	print("-- Callable pin type")
	_check("pin type exists", Types.PinType.CALLABLE == Types.CALLABLE, "")
	_check("named Callable", Types.type_name(Types.CALLABLE) == "Callable", "")
	_check("colored", Types.color_of(Types.CALLABLE) != Color(), "")
	_check("tag", Types.type_tag(Types.CALLABLE) != "", "")
	_check("type_from_name Callable", Types.type_from_name("Callable") == Types.CALLABLE, "")
	_check("compat Callable->Callable", Types.compatible(Types.CALLABLE, Types.CALLABLE), "")
	_check("int does not feed Callable", not Types.compatible(Types.INT, Types.CALLABLE), "")
	_check("Callable does not feed int", not Types.compatible(Types.CALLABLE, Types.INT), "")
	_check("Callable feeds Variant", Types.compatible(Types.CALLABLE, Types.VARIANT), "")
	_check("Variant feeds Callable", Types.compatible(Types.VARIANT, Types.CALLABLE), "")
	_check("float does not feed Callable", not Types.compatible(Types.FLOAT, Types.CALLABLE), "")
	var pairs: Array = Types.valid_pairs()
	var found: bool = false
	for p: Array in pairs:
		if int(p[0]) == Types.CALLABLE and int(p[1]) == Types.CALLABLE:
			found = true
	_check("Callable registered in valid_pairs", found, "")
	_check("default value compiles", _compiles("extends Node\n\nfunc f() -> void:\n\tvar c: Callable = Callable()\n"), "")


# ---- Static single-line lambda ------------------------------------------------
func _test_parse_static() -> void:
	print("-- parsed single-line lambda")
	var src: String = """extends Node

var modifiers: Array = []

func apply(v: float) -> void:
	modifiers.append(func(x: float) -> float: return x * 1.15)
"""
	var r: Dictionary = _roundtrip(src)
	var m: Model = r["model"]
	_check("roundtrip byte-identical", bool(r["identical"]), str(r["text"]))
	_check("stable across two generations", bool(r["stable"]), "")
	var lam: int = -1
	var call: int = -1
	for id: int in m.nodes:
		if int(m.nodes[id]["kind"]) == Model.Kind.LAMBDA:
			lam = id
		elif int(m.nodes[id]["kind"]) == Model.Kind.CALL:
			call = id
	_check("Lambda node created", lam >= 0, "")
	_check("free-form Call node created", call >= 0, "")
	if lam < 0 or call < 0:
		return
	var lf: Dictionary = m.nodes[lam]["fields"]
	_check("param parsed", (lf["params"] as Array).size() == 1
		and String((lf["params"] as Array)[0]["name"]) == "x"
		and String((lf["params"] as Array)[0]["type"]) == "float", JSON.stringify(lf))
	_check("return type parsed", String(lf["ret"]) == "float", String(lf["ret"]))
	_check("body parsed", String(lf["body"]) == "return x * 1.15", String(lf["body"]))
	_check("inline layout kept", not bool(lf.get("block", true)), str(lf.get("block")))
	_check("title shows signature", String(m.nodes[lam]["title"]) == "func(x: float) -> float",
		String(m.nodes[lam]["title"]))
	_check("output pin is Callable", int(m.nodes[lam]["data_outs"][0]["type"]) == Types.CALLABLE, "")
	var wlink: Dictionary = m.connected_data_input(call, 0)
	_check("wired into the call pin", not wlink.is_empty()
		and int(wlink["from_id"]) == lam, JSON.stringify(m.data_links))
	_check("arg pin typed Callable", int(m.nodes[call]["data_ins"][0]["type"]) == Types.CALLABLE, "")
	_check("no generation problems", (r["problems"] as PackedStringArray).is_empty(),
		str(r["problems"]))
	_check("generated code compiles", _compiles(str(r["text"])), str(r["text"]))


# ---- Multi-line lambda bodies --------------------------------------------------
func _test_parse_multiline() -> void:
	print("-- parsed multi-line lambda bodies")
	# var declaration with a multi-line lambda body (the classic tail case)
	var src: String = """extends Node

func f() -> void:
	var double := func(x: int) -> int:
		return x * 2
	print(double.call(4))
"""
	var r: Dictionary = _roundtrip(src)
	_check("var lambda roundtrip byte-identical", bool(r["identical"]), str(r["text"]))
	_check("var lambda stable", bool(r["stable"]), "")
	var m: Model = r["model"]
	var lam: int = _lambda_of(m)
	_check("var lambda node created", lam >= 0, "")
	if lam >= 0:
		var lf: Dictionary = m.nodes[lam]["fields"]
		_check("var lambda body", String(lf["body"]) == "return x * 2", String(lf["body"]))
		_check("var lambda block layout", bool(lf.get("block", false)), str(lf.get("block")))
		_check("var pin typed Callable", int(m.nodes[_var_of(m, "double")]["data_ins"][0]["type"])
			== Types.CALLABLE, "")
	_check("var lambda compiles", _compiles(str(r["text"])), str(r["text"]))
	# nested body: an inner if inside the lambda keeps relative indentation
	var src2: String = """extends Node

func f() -> void:
	var g := func(x: int) -> int:
		if x > 0:
			return x
		return -x
	print(g.call(3))
"""
	var r2: Dictionary = _roundtrip(src2)
	_check("nested lambda roundtrip byte-identical", bool(r2["identical"]), str(r2["text"]))
	_check("nested lambda stable", bool(r2["stable"]), "")
	_check("nested lambda compiles", _compiles(str(r2["text"])), str(r2["text"]))
	var m2: Model = r2["model"]
	var lam2: int = _lambda_of(m2)
	_check("nested body kept", lam2 >= 0
		and String(m2.nodes[lam2]["fields"]["body"]) == "if x > 0:\n\treturn x\nreturn -x",
		String(m2.nodes[lam2]["fields"]["body"]) if lam2 >= 0 else "")
	# assignment statement whose block opens with a lambda (used to stay opaque)
	var src3: String = """extends Node

func f() -> void:
	var h := func():
		return 1
	h = func():
		return 2
	print(h.call())
"""
	var r3: Dictionary = _roundtrip(src3)
	_check("assignment lambda roundtrip byte-identical", bool(r3["identical"]), str(r3["text"]))
	_check("assignment lambda stable", bool(r3["stable"]), "")
	var m3: Model = r3["model"]
	var count: int = 0
	for id: int in m3.nodes:
		if int(m3.nodes[id]["kind"]) == Model.Kind.LAMBDA:
			count += 1
	_check("both lambdas became nodes", count == 2, str(count))
	_check("assignment lambda compiles", _compiles(str(r3["text"])), str(r3["text"]))
	# untyped lambda without a return type (missing return type edge case)
	var src4: String = """extends Node

func f() -> void:
	var u := func():
		pass
	print(u.is_valid())
"""
	var r4: Dictionary = _roundtrip(src4)
	_check("untyped lambda roundtrip byte-identical", bool(r4["identical"]), str(r4["text"]))
	var m4: Model = r4["model"]
	var lam4: int = _lambda_of(m4)
	_check("untyped lambda parsed", lam4 >= 0 and String(m4.nodes[lam4]["fields"]["ret"]) == "",
		"" if lam4 < 0 else String(m4.nodes[lam4]["fields"]["ret"]))
	_check("untyped lambda title", lam4 >= 0 and String(m4.nodes[lam4]["title"]) == "func()",
		"" if lam4 < 0 else String(m4.nodes[lam4]["title"]))
	_check("untyped lambda compiles", _compiles(str(r4["text"])), str(r4["text"]))


# ---- If condition that is a method call ---------------------------------------
## `if mod.is_valid():` (mod: Callable) must load as a call node wired into the
## If's condition pin - not as raw text on the pin - and regenerate unchanged.
func _test_condition_call() -> void:
	print("-- if condition = method call on a typed loop variable")
	var src: String = """extends Node

var modifiers: Array[Callable] = []
var charge: float = 0.0

func tick(delta: float) -> void:
	var step: float = delta
	for mod: Callable in modifiers:
		if mod.is_valid():
			step = mod.call(step)
	charge += maxf(step, 0.0)
"""
	var r: Dictionary = _roundtrip(src)
	_check("method-call condition roundtrip byte-identical", bool(r["identical"]), str(r["text"]))
	_check("method-call condition stable", bool(r["stable"]), "")
	_check("method-call condition compiles", _compiles(str(r["text"])), str(r["text"]))
	var m: Model = r["model"]
	var if_id: int = -1
	var call_id: int = -1
	for id: int in m.nodes:
		var k: int = int(m.nodes[id]["kind"])
		if k == Model.Kind.IF:
			if_id = id
		elif k == Model.Kind.CALL and String(m.nodes[id]["fields"].get("call", "")) == "is_valid":
			call_id = id
	_check("is_valid became a call node", call_id >= 0, "")
	_check("call node is a value (pure) call", call_id >= 0 \
		and String(m.nodes[call_id]["fields"].get("mode", "")) == "pure", "")
	var wired: bool = false
	for l: Dictionary in m.data_links:
		if int(l["from_id"]) == call_id and int(l["to_id"]) == if_id and int(l["to_in"]) == 0:
			wired = true
	_check("call node is wired into the If condition", wired, "")
	_check("If keeps no duplicated condition text", if_id >= 0 \
		and String(m.nodes[if_id]["data_ins"][0]["value"]) == "", "")
	# typed member variables, typed arguments and while loops resolve too
	var src4: String = """extends Node

var cb: Callable

func h(other: Callable) -> void:
	if cb.is_valid():
		print(1)
	while other.is_valid():
		break
"""
	var r4: Dictionary = _roundtrip(src4)
	_check("member / argument / while call conditions roundtrip", bool(r4["identical"]), str(r4["text"]))
	var n4: int = 0
	for id4: int in (r4["model"] as Model).nodes:
		if String((r4["model"] as Model).nodes[id4]["fields"].get("call", "")) == "is_valid":
			n4 += 1
	_check("both is_valid conditions became call nodes", n4 == 2, str(n4))
	# an untyped iterator cannot be resolved: the condition stays verbatim
	var src2: String = """extends Node

var items: Array = []

func f() -> void:
	for it in items:
		if it.is_valid():
			print(it)
"""
	var r2: Dictionary = _roundtrip(src2)
	_check("untyped iterator condition roundtrip byte-identical", bool(r2["identical"]), str(r2["text"]))
	var calls: int = 0
	for id2: int in (r2["model"] as Model).nodes:
		if String((r2["model"] as Model).nodes[id2]["fields"].get("call", "")) == "is_valid":
			calls += 1
	_check("untyped iterator condition is not guessed", calls == 0, str(calls))


# ---- Comparison result type and Get Variable nodes -----------------------------
## A comparison Operator outputs a bool, and a variable used as an operand is
## fed by a Get Variable node instead of sitting on the pin as text.
func _test_variable_reads() -> void:
	print("-- comparison result is bool; variables are Get nodes")
	var src: String = """extends Node

enum Phase { IDLE, COOLDOWN }

var phase: Phase = Phase.IDLE
var ratio: float = 0.0

func f() -> void:
	if (ratio >= 0.85):
		print("high")
	elif (phase != Phase.COOLDOWN):
		print("not cooling")
"""
	var r: Dictionary = _roundtrip(src)
	_check("variable reads roundtrip byte-identical", bool(r["identical"]), str(r["text"]))
	_check("variable reads stable", bool(r["stable"]), "")
	_check("variable reads compile", _compiles(str(r["text"])), str(r["text"]))
	var m: Model = r["model"]
	var cmp_count: int = 0
	var all_bool: bool = true
	var gets: Dictionary = {}
	for id: int in m.nodes:
		var n: Dictionary = m.nodes[id]
		if int(n["kind"]) == Model.Kind.OPERATOR and Model._op_is_comparison(String(n["fields"].get("op", ""))):
			cmp_count += 1
			if int(n["data_outs"][0]["type"]) != Types.PinType.BOOL:
				all_bool = false
		if int(n["kind"]) == Model.Kind.VARIABLE_GET:
			gets[String(n["fields"].get("name", ""))] = id
	_check("two comparisons were built", cmp_count == 2, str(cmp_count))
	_check("comparison result pin is bool", all_bool, "")
	_check("ratio is read through a Get node", gets.has("ratio"), str(gets.keys()))
	_check("phase is read through a Get node", gets.has("phase"), str(gets.keys()))
	_check("enum member stays text (not a variable)", not gets.has("Phase.COOLDOWN"), str(gets.keys()))
	for name: String in ["ratio", "phase"]:
		var wired: bool = false
		if gets.has(name):
			for l: Dictionary in m.data_links:
				if int(l["from_id"]) == int(gets[name]) \
						and int(m.nodes[int(l["to_id"])]["kind"]) == Model.Kind.OPERATOR:
					wired = true
		_check("Get %s is wired into an operator operand" % name, wired, "")
	# return / print / while read variables through Get nodes as well
	var src3: String = """extends Node

var score: int = 0
var running: bool = true

func g() -> int:
	while running:
		print(score)
		break
	return score
"""
	var r3: Dictionary = _roundtrip(src3)
	_check("return/print/while reads roundtrip byte-identical", bool(r3["identical"]), str(r3["text"]))
	var g3: int = 0
	for id3: int in (r3["model"] as Model).nodes:
		if int((r3["model"] as Model).nodes[id3]["kind"]) == Model.Kind.VARIABLE_GET:
			g3 += 1
	_check("while, print and return each got a Get node", g3 == 3, str(g3))
	# loop variables are wired from the For node; call arguments and assignment
	# values read variables through Get nodes
	var src5: String = """extends Node

var score: int = 0
var total: int = 0

func use(v: int) -> void:
	pass

func k() -> void:
	for i in range(3):
		if i > 1:
			total = score
			use(score)
"""
	var r5: Dictionary = _roundtrip(src5)
	_check("loop/call/assignment reads roundtrip byte-identical", bool(r5["identical"]), str(r5["text"]))
	_check("loop/call/assignment reads compile", _compiles(str(r5["text"])), str(r5["text"]))
	var m5: Model = r5["model"]
	var from_for: int = 0
	var score_gets: int = 0
	for l5: Dictionary in m5.data_links:
		if int(m5.nodes[int(l5["from_id"])]["kind"]) == Model.Kind.FOR:
			from_for += 1
	for id5: int in m5.nodes:
		if int(m5.nodes[id5]["kind"]) == Model.Kind.VARIABLE_GET \
				and String(m5.nodes[id5]["fields"].get("name", "")) == "score":
			score_gets += 1
	_check("loop variable i is wired from the For node", from_for == 1, str(from_for))
	_check("score is read through Get nodes (assignment + call argument)", score_gets == 2, str(score_gets))
	# switching an operator to / from a comparison retypes its result pin
	var op: int = m.add_node(Model.Kind.OPERATOR, {"op": "+"})
	_check("arithmetic operator result stays any", int(m.nodes[op]["data_outs"][0]["type"]) == Types.VARIANT, "")
	m.set_field(op, "op", "==")
	_check("switching to == makes the result bool", int(m.nodes[op]["data_outs"][0]["type"]) == Types.PinType.BOOL, "")
	m.set_field(op, "op", "+")
	_check("switching back makes the result any again", int(m.nodes[op]["data_outs"][0]["type"]) == Types.VARIANT, "")


# ---- Free-form call with a lambda ----------------------------------------------
func _test_parse_freeform_call() -> void:
	print("-- free-form call carrying a lambda")
	var src: String = """extends Node

var modifiers: Array = []

func setup() -> void:
	modifiers.map(func(v: float) -> float:
		return v + 1.0)
"""
	var r: Dictionary = _roundtrip(src)
	var m: Model = r["model"]
	_check("multi-line arg roundtrip byte-identical", bool(r["identical"]), str(r["text"]))
	_check("multi-line arg stable", bool(r["stable"]), "")
	var lam: int = _lambda_of(m)
	_check("multi-line arg lambda node", lam >= 0, "")
	if lam >= 0:
		_check("multi-line arg body dedented",
			String(m.nodes[lam]["fields"]["body"]) == "return v + 1.0",
			String(m.nodes[lam]["fields"]["body"]))
	_check("multi-line arg compiles", _compiles(str(r["text"])), str(r["text"]))
	# a statement that only LOOKS call-like stays opaque (no lambda inside)
	var src2: String = "extends Node\n\nfunc f() -> void:\n\tnot_a_call(1, 2)\n"
	var r2: Dictionary = _roundtrip(src2)
	_check("unknown call stays statement", bool(r2["identical"]), str(r2["text"]))
	var m2: Model = r2["model"]
	var lamcount: int = 0
	for id: int in m2.nodes:
		if int(m2.nodes[id]["kind"]) == Model.Kind.LAMBDA:
			lamcount += 1
	_check("no lambda node for plain statements", lamcount == 0, str(lamcount))


# ---- Registry-backed call taking a Callable ------------------------------------
func _test_parse_call_arg() -> void:
	print("-- lambda into a resolvable Callable parameter")
	var src: String = """extends Node

func use(cb: Callable) -> void:
	cb.call()

func f() -> void:
	use(func(): pass)
"""
	var r: Dictionary = _roundtrip(src)
	var m: Model = r["model"]
	_check("callable param roundtrip byte-identical", bool(r["identical"]), str(r["text"]))
	_check("callable param stable", bool(r["stable"]), "")
	var lam: int = _lambda_of(m)
	_check("lambda node in resolved call", lam >= 0, "")
	var call_id: int = -1
	for id: int in m.nodes:
		if int(m.nodes[id]["kind"]) == Model.Kind.CALL and String(m.nodes[id]["fields"].get("call", "")) == "use":
			call_id = id
	_check("resolved call kept", call_id >= 0, "")
	if call_id >= 0 and lam >= 0:
		var cbw: Dictionary = m.connected_data_input(call_id, 0)
		_check("lambda wired into the cb pin", not cbw.is_empty()
			and int(cbw["from_id"]) == lam, JSON.stringify(m.data_links))
		_check("arg pin typed Callable",
			int(m.nodes[call_id]["data_ins"][0]["type"]) == Types.CALLABLE, "")
	_check("callable param compiles", _compiles(str(r["text"])), str(r["text"]))


# ---- Assignment into a Callable-typed variable ----------------------------------
func _test_parse_assignment() -> void:
	print("-- lambda stored in a Callable variable")
	var src: String = """extends Node

var cb: Callable = func():
	pass

func f() -> void:
	cb = func(x: int) -> void:
		print(x)
	cb.call(2)
"""
	var r: Dictionary = _roundtrip(src)
	var m: Model = r["model"]
	_check("callable var roundtrip byte-identical", bool(r["identical"]), str(r["text"]))
	_check("callable var stable", bool(r["stable"]), "")
	var count: int = 0
	for id: int in m.nodes:
		if int(m.nodes[id]["kind"]) == Model.Kind.LAMBDA:
			count += 1
	_check("both assignment lambdas became nodes", count == 2, str(count))
	_check("callable var compiles", _compiles(str(r["text"])), str(r["text"]))
	var var_id: int = _var_of(m, "cb")
	if var_id >= 0:
		_check("Callable var output type", int(m.nodes[var_id]["data_outs"][0]["type"]) == Types.CALLABLE, "")
		_check("no accessors offered on lambda var", not m.var_supports_accessors(var_id), "")


# ---- Authored (spawned) lambda --------------------------------------------------
func _test_authored_lambda() -> void:
	print("-- authored Lambda node")
	var m: Model = Model.new()
	m.build("extends Node\n\nvar modifiers: Array = []\n\nfunc apply(v: float) -> void:\n\tpass\n")
	var entry: int = -1
	for id: int in m.nodes:
		if int(m.nodes[id]["kind"]) == Model.Kind.ENTRY:
			entry = id
	var lam: int = m.add_node(Model.Kind.LAMBDA, {})
	_check("spawned with a starter param", (m.nodes[lam]["fields"]["params"] as Array).size() == 1, "")
	_check("spawned title", String(m.nodes[lam]["title"]) == "func(x: float)", String(m.nodes[lam]["title"]))
	_check("spawned body", String(m.nodes[lam]["fields"]["body"]) == "pass", String(m.nodes[lam]["fields"]["body"]))
	_check("spawned out pin Callable", int(m.nodes[lam]["data_outs"][0]["type"]) == Types.CALLABLE, "")
	# the doc example: x: float -> float, body return x * 1.15
	_check("set ret", m.set_lambda_prop(lam, "ret", "float"), "")
	_check("set body", m.set_lambda_prop(lam, "body", "return x * 1.15"), "")
	_check("authored expr", m._lambda_expr(lam) == "func(x: float) -> float: return x * 1.15",
		m._lambda_expr(lam))
	_check("authored compiles standalone",
		_compiles("extends Node\n\nfunc f() -> void:\n\tvar cb: Callable = %s\n" % m._lambda_expr(lam)), m._lambda_expr(lam))
	# wire it into a free-form Function Call inside apply's exec chain
	var st: int = m.add_node(Model.Kind.CALL, {"call": "modifiers.append"})
	_check("free-form call spawned", st >= 0 and int(m.nodes[st]["kind"]) == Model.Kind.CALL, "")
	_check("call set to exec mode", m.set_call_mode(st, "exec"), "")
	m.connect_exec(entry, 0, st)
	var okd: Dictionary = m.connect_data(lam, 0, st, 0)
	_check("lambda wires into call arg", not okd.has("_rejected"), JSON.stringify(okd))
	var r: Dictionary = m.generate()
	_check("authored generation compiles", _compiles(str(r["text"])), str(r["text"]))
	_check("authored call emitted", str(r["text"]).contains("modifiers.append(func(x: float) -> float: return x * 1.15)"),
		str(r["text"]))
	_check("authored no unreachable warning", (r["problems"] as PackedStringArray).is_empty(), str(r["problems"]))
	# wiring a lambda into an int pin is rejected by pin compatibility
	var lit: int = m.add_node(Model.Kind.LITERAL, {"type": Types.PinType.INT, "value": "5"})
	_check("lambda cannot wire into int pin", (m.connect_data(lam, 0, lit, 0) as Dictionary).has("_rejected"), "")
	# a Callable-typed variable Get accepts the lambda output
	var cv: int = m.add_node(Model.Kind.VAR_DECL, {"name": "handler", "type": "Callable", "default": ""})
	_check("lambda wires into Callable var", not (m.connect_data(lam, 0, cv, 0) as Dictionary).has("_rejected"), "")


# ---- Parameter editing ----------------------------------------------------------
func _test_editing() -> void:
	print("-- parameter editing")
	var m: Model = Model.new()
	m.build("extends Node\n\nfunc f() -> void:\n\tpass\n")
	var lam: int = m.add_node(Model.Kind.LAMBDA, {})
	_check("add param", m.add_lambda_param(lam, "y"), "")
	_check("params grew", (m.nodes[lam]["fields"]["params"] as Array).size() == 2, "")
	_check("unique naming", String((m.nodes[lam]["fields"]["params"] as Array)[1]["name"]) == "y", "")
	_check("add duplicate renamed", m.add_lambda_param(lam, "x")
		and String((m.nodes[lam]["fields"]["params"] as Array)[2]["name"]) == "x2", "")
	_check("remove param", m.remove_lambda_param(lam, 1), "")
	_check("params shrank", (m.nodes[lam]["fields"]["params"] as Array).size() == 2, "")
	_check("rename param", m.set_lambda_prop(lam, "param:0:name", "amount"), "")
	_check("retype param", m.set_lambda_prop(lam, "param:0:type", "int"), "")
	_check("param default", m.set_lambda_prop(lam, "param:1:default", "3"), "")
	_check("edited title", String(m.nodes[lam]["title"]) == "func(amount: int, x2)",
		String(m.nodes[lam]["title"]))
	_check("edited expr", m._lambda_expr(lam) == "func(amount: int, x2 = 3): pass",
		m._lambda_expr(lam))
	_check("edited expr compiles",
		_compiles("extends Node\n\nfunc f() -> void:\n\tvar cb: Callable = %s\n" % m._lambda_expr(lam)),
		m._lambda_expr(lam))
	_check("rejects bad name", not m.set_lambda_prop(lam, "param:0:name", "2bad"), "")
	_check("rejects duplicate name", not m.set_lambda_prop(lam, "param:0:name", "x2"), "")
	_check("rejects spaced type", not m.set_lambda_prop(lam, "param:0:type", "int float"), "")
	_check("rejects spaced ret", not m.set_lambda_prop(lam, "ret", "int float"), "")
	_check("typed ret expr", m.set_lambda_prop(lam, "ret", "bool")
		and m._lambda_expr(lam).begins_with("func(amount: int, x2 = 3) -> bool:"), m._lambda_expr(lam))
	# parameter edits survive the round trip
	var src: String = "extends Node\n\nvar mods: Array = []\n\nfunc f() -> void:\n\tmods.append(func(amount: int, x2 = 3) -> bool: true)\n"
	var r: Dictionary = _roundtrip(src)
	_check("edited params roundtrip byte-identical", bool(r["identical"]), str(r["text"]))


# ---- Compatibility helpers -------------------------------------------------------
func _test_compatibility() -> void:
	print("-- graph compatibility")
	var m: Model = Model.new()
	m.build("extends Node\n\nfunc f() -> void:\n\tvar n: int = 1\n\tpass\n")
	var vget: int = _var_of(m, "n")
	_check("int Get pin", int(m.nodes[vget]["data_outs"][0]["type"]) == Types.INT, "")
	_check("int out vs Callable pin rejected", not Types.compatible(Types.INT, Types.CALLABLE), "")
	# Callable out vs int pin rejected
	_check("Callable out vs int pin rejected", not Types.compatible(Types.CALLABLE, Types.INT), "")


func _test_rename_and_flow() -> void:
	print("-- rename reach & generation order")
	# renaming a variable reaches inside a lambda body that captures it
	var src: String = """extends Node

var factor := 2.0

func f() -> void:
	var scale := func(x: float) -> float:
		return x * factor
	print(scale.call(1.0))
"""
	var r: Dictionary = _roundtrip(src)
	var m: Model = r["model"]
	var lam: int = _lambda_of(m)
	_check("rename source valid", bool(r["identical"]), str(r["text"]))
	if lam >= 0:
		m.set_var_prop(_var_of(m, "factor"), "name", "multiplier")
		_check("rename reached lambda body", String(m.nodes[lam]["fields"]["body"]).contains("multiplier"),
			String(m.nodes[lam]["fields"]["body"]))
		var r2: Dictionary = m.generate()
		_check("renamed generation compiles", _compiles(str(r2["text"])), str(r2["text"]))
	# lambda is exempt from the unreachable-node pass
	var m3: Model = Model.new()
	m3.build("extends Node\n\nfunc f() -> void:\n\tpass\n")
	var l3: int = m3.add_node(Model.Kind.LAMBDA, {})
	_check("lambda spawned", l3 >= 0, "")
	var r3: Dictionary = m3.generate()
	var unreachable_hit: bool = false
	for p: String in (r3["problems"] as PackedStringArray):
		if p.contains("not connected"):
			unreachable_hit = true
	_check("unwired lambda not flagged unreachable", not unreachable_hit, str(r3["problems"]))


# ---- UI smoke (views, form wiring, parameter actions) ---------------------------
func _test_ui() -> void:
	print("-- UI smoke")
	var Workspace: GDScript = load("res://addons/gd_canvas_spikes/graph_workspace.gd")
	var ws: Control = Workspace.new()
	root.add_child(ws)
	await process_frame
	await process_frame
	var c: Control = ws._canvas
	# the menu carries the Lambda entry
	var cat_idx: int = -1
	for i: int in c._catalog.size():
		if String(c._catalog[i]["name"]) == "Lambda":
			cat_idx = i
	_check("menu catalog contains Lambda", cat_idx >= 0, str(cat_idx))
	# spawn through the canvas: view with parameter rows / ret / body editors
	var lid: int = c.spawn_node(Model.Kind.LAMBDA, {}, Vector2(100, 100))
	await process_frame
	_check("lambda view created", c.views.has(lid) and is_instance_valid(c.views[lid]), "")
	var v: Control = c.views[lid]
	_check("param row editors exist", v._lambda_edits.has("param:0:name")
		and v._lambda_edits.has("param:0:type") and v._lambda_edits.has("param:0:default")
		and v._lambda_edits.has("ret") and v._lambda_edits.has("body"),
		str(v._lambda_edits.keys()))
	_check("out port exists", v.data_out_port(0) >= 0, "")
	# typing in the name editor reaches the model live
	var name_ed: LineEdit = v._lambda_edits["param:0:name"]
	name_ed.text = "amount"
	v.field_changed.emit(lid, "param:0:name", "amount")
	await process_frame
	_check("live name edit reaches model",
		String(c.model.nodes[lid]["fields"]["params"][0]["name"]) == "amount", "")
	_check("title follows the signature", String(c.model.nodes[lid]["title"]) == "func(amount: float)",
		String(c.model.nodes[lid]["title"]))
	# return type through the form
	var ret_sel: Control = v._lambda_selects["ret"]
	ret_sel.edit.text = "float"
	v.field_changed.emit(lid, "ret", "float")
	await process_frame
	_check("live ret edit reaches model", String(c.model.nodes[lid]["fields"]["ret"]) == "float", "")
	# body through the code editor, then the whole node generates
	v._lambda_edits["body"].text = "return amount * 1.15"
	v.field_changed.emit(lid, "body", "return amount * 1.15")
	await process_frame
	_check("live body edit reaches model",
		String(c.model.nodes[lid]["fields"]["body"]) == "return amount * 1.15", "")
	# parameter add / remove through the node's buttons rebuild the view
	v.lambda_action.emit(lid, "add_param", -1)
	await process_frame
	_check("add param rebuilds view", c.views.has(lid) and is_instance_valid(c.views[lid])
		and (c.model.nodes[lid]["fields"]["params"] as Array).size() == 2, "")
	_check("added row editor exists", c.views[lid]._lambda_edits.has("param:1:name"), "")
	c.views[lid].lambda_action.emit(lid, "remove_param", 1)
	await process_frame
	_check("remove param rebuilds view", (c.model.nodes[lid]["fields"]["params"] as Array).size() == 1, "")
	# wiring the lambda into a free-form call keeps generation working
	var cid2: int = c.spawn_node(Model.Kind.CALL, {"call": "modifiers.append"}, Vector2(500, 100))
	c.model.set_call_mode(cid2, "exec")
	c._on_connection_request(c.views[lid].name, c.views[lid].data_out_port(0),
		c.views[cid2].name, c.views[cid2].data_in_port(0))
	await process_frame
	_check("canvas wiring reaches the model", c.model.connected_data_input(cid2, 0).size() > 0
		and int(c.model.connected_data_input(cid2, 0)["from_id"]) == lid, "")
	c._sync_connections()
	var gen: Dictionary = c.model.generate()
	_check("canvas generation compiles", _compiles(
		"extends Node\n\nvar modifiers: Array = []\n\nfunc apply(v: float) -> void:\n\t"
		+ c.model._call_expr(cid2, 0) + "\n"),
		c.model._call_expr(cid2, 0))
	_check("canvas call expression", c.model._call_expr(cid2, 0)
		== "modifiers.append(func(amount: float) -> float: return amount * 1.15)",
		c.model._call_expr(cid2, 0))
	ws.queue_free()
	await process_frame


# ---- helpers --------------------------------------------------------------------
func _lambda_of(m: Model) -> int:
	for id: int in m.nodes:
		if int(m.nodes[id]["kind"]) == Model.Kind.LAMBDA:
			return id
	return -1


func _var_of(m: Model, vname: String) -> int:
	for id: int in m.nodes:
		if int(m.nodes[id]["kind"]) == Model.Kind.VAR_DECL \
				and String(m.nodes[id]["fields"].get("name", "")) == vname:
			return id
	return -1


# ---- Stability / input hardening -------------------------------------------------
func _test_hardening() -> void:
	print("-- hardening: names, types, defaults, indentation")
	var m: Model = Model.new()
	m.build("extends Node\n\nvar modifiers: Array = []\n\nfunc apply() -> void:\n\tpass\n")
	var lam: int = m.add_node(Model.Kind.LAMBDA, {})
	for kw: String in ["class", "func", "if", "return", "var", "null"]:
		_check("reserved word %s refused" % kw, not m.set_lambda_prop(lam, "param:0:name", kw)
			and m.last_reject_reason.contains("reserved"), m.last_reject_reason)
	_check("bad name refused with reason", not m.set_lambda_prop(lam, "param:0:name", "1x")
		and m.last_reject_reason != "", m.last_reject_reason)
	_check("name with space refused", not m.set_lambda_prop(lam, "param:0:name", "a b"), "")
	_check("refused name keeps the previous one", String((m.nodes[lam]["fields"]["params"] as Array)[0]["name"]) == "x", "")
	m.add_lambda_param(lam, "y")
	_check("duplicate name refused with reason", not m.set_lambda_prop(lam, "param:1:name", "x")
		and m.last_reject_reason.contains("already"), m.last_reject_reason)
	_check("good edit clears the reason", m.set_lambda_prop(lam, "param:1:name", "z") and m.last_reject_reason == "", m.last_reject_reason)
	# types
	_check("typed container accepted", m.set_lambda_prop(lam, "param:0:type", "Dictionary[String, int]"), m.last_reject_reason)
	_check("typed array accepted", m.set_lambda_prop(lam, "param:0:type", "Array[int]"), m.last_reject_reason)
	_check("type with stray space refused", not m.set_lambda_prop(lam, "param:0:type", "int float"), "")
	_check("type with assignment refused", not m.set_lambda_prop(lam, "param:0:type", "int = 5"), "")
	_check("return type with stray space refused", not m.set_lambda_prop(lam, "ret", "int float"), "")
	_check("typed return accepted", m.set_lambda_prop(lam, "ret", "Dictionary[String, int]"), m.last_reject_reason)
	_check("empty types are allowed", m.set_lambda_prop(lam, "ret", "") and m.set_lambda_prop(lam, "param:0:type", ""), "")
	# defaults
	_check("two-value default refused", not m.set_lambda_prop(lam, "param:0:default", "1, 2")
		and m.last_reject_reason.contains("two values"), m.last_reject_reason)
	_check("multi-line default refused", not m.set_lambda_prop(lam, "param:0:default", "1\nfoo()"), "")
	_check("unclosed default refused", not m.set_lambda_prop(lam, "param:0:default", "[1, 2"), "")
	_check("semicolon default refused", not m.set_lambda_prop(lam, "param:0:default", "1; foo()"), "")
	_check("list default accepted", m.set_lambda_prop(lam, "param:0:default", "[1, 2]"), m.last_reject_reason)
	_check("string default with comma accepted", m.set_lambda_prop(lam, "param:0:default", "\"a, b\""), m.last_reject_reason)
	m.set_lambda_prop(lam, "param:0:default", "")
	# indentation: spaces become tabs so the body compiles
	m.set_lambda_prop(lam, "param:0:type", "int")
	m.set_lambda_prop(lam, "ret", "int")
	m.set_lambda_prop(lam, "body", "if x > 0:\n    return 1\nreturn 2")
	var expr: String = m._lambda_expr(lam)
	_check("space-indented body is converted to tabs", expr.contains("\n\t\treturn 1") and not expr.contains("    "), expr.replace("\n", "\\n"))
	var entry0: int = -1
	for id0: int in m.nodes:
		if int(m.nodes[id0]["kind"]) == Model.Kind.ENTRY:
			entry0 = id0
	var call0: int = m.add_node(Model.Kind.CALL, {"call": "modifiers.append"})
	m.set_call_mode(call0, "exec")
	m.connect_exec(entry0, 0, call0)
	m.connect_data(lam, 0, call0, 0)
	var gen0: String = str(m.generate()["text"])
	_check("converted lambda generates compilable code", _compiles(gen0), gen0)
	m.set_lambda_prop(lam, "body", "if x > 0:\n  return 1\n  \treturn 3\nreturn 2")
	_check("mixed tab/space body is normalized", not m._lambda_expr(lam).contains("  "), m._lambda_expr(lam).replace("\n", "\\n"))
	m.set_lambda_prop(lam, "body", "return 1")
	m.remove_node(call0)
	# renaming a parameter follows into the body and later defaults
	var l2: int = m.add_node(Model.Kind.LAMBDA, {})
	m.add_lambda_param(l2, "y")
	m.set_lambda_prop(l2, "param:1:default", "x")
	m.set_lambda_prop(l2, "body", "return x + y + max_x")
	_check("rename accepted", m.set_lambda_prop(l2, "param:0:name", "amount"), m.last_reject_reason)
	var e2: String = m._lambda_expr(l2)
	_check("rename follows into the body (whole words only)", e2.contains("return amount + y + max_x"), e2)
	_check("rename follows into later defaults", e2.contains("y = amount") or e2.contains("y: = amount") or e2.contains("= amount"), e2)
	# deleting a wired lambda leaves no dangling link and no stale lambda text
	var entry: int = -1
	for id: int in m.nodes:
		if int(m.nodes[id]["kind"]) == Model.Kind.ENTRY:
			entry = id
	var call: int = m.add_node(Model.Kind.CALL, {"call": "modifiers.append"})
	m.set_call_mode(call, "exec")
	m.connect_exec(entry, 0, call)
	m.connect_data(lam, 0, call, 0)
	m.remove_node(lam)
	var gen: String = str(m.generate()["text"])
	_check("deleted lambda leaves no code behind", not gen.contains("func("), gen)
	_check("deleted lambda leaves no dangling link", m.data_links.filter(func(l: Dictionary) -> bool: return int(l["from_id"]) == lam).is_empty(), "")
	_check("call pin is usable again after the lambda is gone", int(m.nodes[call]["data_ins"][0]["type"]) != Types.CALLABLE
		or String(m.nodes[call]["data_ins"][0]["value"]) == "", str(m.nodes[call]["data_ins"][0]))


# ---- Refused edits: the person is told why and the box shows the real value ----
func _test_ui_feedback() -> void:
	print("-- UI feedback for refused edits")
	var Workspace: GDScript = load("res://addons/gd_canvas_spikes/graph_workspace.gd")
	var ws: Control = Workspace.new()
	root.add_child(ws)
	await process_frame
	await process_frame
	var c: Control = ws._canvas
	var said: Array[String] = []
	c.status_changed.connect(func(t: String) -> void: said.append(t))
	var lid: int = c.spawn_node(Model.Kind.LAMBDA, {}, Vector2(100, 100))
	await process_frame
	var v: Control = c.views[lid]
	v._lambda_edits["param:0:name"].text = "class"
	v.field_changed.emit(lid, "param:0:name", "class")
	await process_frame
	_check("refused lambda name says why", said.any(func(t: String) -> bool: return t.contains("reserved") and t.contains("previous value kept")), str(said))
	_check("model keeps the old name", String(c.model.nodes[lid]["fields"]["params"][0]["name"]) == "x", "")
	v.field_committed.emit(lid, "param:0:name", "x")
	await process_frame
	await process_frame
	_check("committing a refused edit restores the visible value", c.views.has(lid)
		and String(c.views[lid]._lambda_edits["param:0:name"].text) == "x", "")
	# class reference: bad class name is refused, unknown-but-valid is applied with a hint
	said.clear()
	var rid: int = c.spawn_node(Model.Kind.CLASS_REF, {"target": "Node", "ref": "class"}, Vector2(400, 100))
	await process_frame
	var rv: Control = c.views[rid]
	rv.field_changed.emit(rid, "target", "Not A Class")
	await process_frame
	_check("refused class name says why", said.any(func(t: String) -> bool: return t.contains("not a valid class name")), str(said))
	_check("class reference keeps the old target", String(c.model.nodes[rid]["fields"]["target"]) == "Node", "")
	said.clear()
	rv.field_changed.emit(rid, "target", "Plyer")
	await process_frame
	_check("unknown class is applied with a spelling hint", said.any(func(t: String) -> bool: return t.contains("check the spelling"))
		and String(c.model.nodes[rid]["fields"]["target"]) == "Plyer", str(said))
	ws.queue_free()
	await process_frame
