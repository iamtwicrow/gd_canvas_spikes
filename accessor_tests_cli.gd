extends SceneTree
## Headless checks for property accessor (`set(value):` / `get:`) support on
## member variables: text logic, model parsing / editing / generation.
##   godot --headless --path <project> -s res://addons/gd_canvas_spikes/accessor_tests_cli.gd

const Acc = preload("res://addons/gd_canvas_spikes/accessor_text.gd")
const Model = preload("res://addons/gd_canvas_spikes/graph_model.gd")
const Types = preload("res://addons/gd_canvas_spikes/graph_types.gd")
const Canvas = preload("res://addons/gd_canvas_spikes/graph_canvas.gd")
const NodeView = preload("res://addons/gd_canvas_spikes/graph_node.gd")

const USER_SRC: String = "extends Node\n\nconst MAX_CHARGE: float = 10.0\n\nvar charge: float = 0.0:\n\tset(val):\n\t\tvar prev := charge\n\t\tcharge = clampf(val, 0.0, MAX_CHARGE)\n\t\tif not is_equal_approx(prev, charge):\n\t\t\t_evaluate_phase()\n\nfunc _evaluate_phase() -> void:\n\tpass\n"

var _pass: int = 0
var _fail: int = 0


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		print("FAIL: ", what, ("  [%s]" % detail) if detail != "" else "")


func _compiles(code: String) -> bool:
	return Types.compile_source(code) == OK


func _init() -> void:
	# the text / model checks below cover the verbatim accessor block (the
	# fallback for blocks the node form cannot represent)
	Model._skip_accessor_nodes = true
	_test_text()
	_test_model()
	Model._skip_accessor_nodes = false
	_test_nodes()
	await _test_ui()
	print("accessor tests: %d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _test_text() -> void:
	var tail: String = "set(val):\n\tvar prev := charge\n\tcharge = clampf(val, 0.0, MAX)\n\tif prev != charge:\n\t\t_evaluate_phase()"
	var d: Dictionary = Acc.parse(tail)
	_check(bool(d["ok"]) and bool(d["has_setter"]) and not bool(d["has_getter"]), "parse: setter only")
	_check(d["setter_arg"] == "val", "parse: setter argument name")
	_check(String(d["setter_body"]).split("\n").size() == 4 and String(d["setter_body"]).contains("\n\t_evaluate_phase()"),
		"parse: body keeps its inner indentation", String(d["setter_body"]))
	_check(Acc.compose(d) == tail, "compose: setter round trip")

	var both: String = "get:\n\treturn hp\nset(value):\n\thp = value"
	var db: Dictionary = Acc.parse(both)
	_check(bool(db["ok"]) and bool(db["has_getter"]) and bool(db["has_setter"]) and bool(db["get_first"]), "parse: getter then setter")
	_check(Acc.compose(db) == both, "compose: keeps accessor order")
	var both2: String = "set(value):\n\thp = value\nget():\n\treturn hp"
	var db2: Dictionary = Acc.parse(both2)
	_check(bool(db2["ok"]) and bool(db2["getter_paren"]) and not bool(db2["get_first"]), "parse: setter then get()")
	_check(Acc.compose(db2) == both2, "compose: keeps get() form")

	var spaced: String = "set(v):\n    x = v\n    if x:\n        pass"
	var ds: Dictionary = Acc.parse(spaced)
	_check(bool(ds["ok"]) and ds["unit"] == "    " and Acc.compose(ds) == spaced, "space indentation round trip")

	var typed: Dictionary = Acc.parse(spaced)
	typed["setter_body"] = "x = v\nif x:\n\tpass"
	_check(Acc.compose(typed) == spaced, "tabs typed in the editor follow a space-indented script")

	var blank_in_body: String = "set(v):\n\ta = v\n\n\tprint(a)"
	_check(Acc.compose(Acc.parse(blank_in_body)) == blank_in_body, "blank line inside a body survives")

	_check(not bool(Acc.parse("# note\nset(v):\n\tx = v")["ok"]), "comment between accessors is not structured")
	_check(not bool(Acc.parse("set(v): x = v")["ok"]), "one-line body is not structured")
	_check(not bool(Acc.parse("set(v):\n\tx = v\nset(w):\n\tx = w")["ok"]), "duplicate accessor is not structured")
	_check(not bool(Acc.parse("return x * 2")["ok"]), "lambda body is not structured")
	_check(not bool(Acc.parse("set(v):")["ok"]), "empty body is not structured")
	_check(not bool(Acc.parse("set(v):\n\tx = v\n\nget:\n\treturn x")["ok"]), "blank gap between accessors keeps verbatim")
	_check(bool(Acc.parse("")["ok"]) and Acc.compose(Acc.parse("")) == "", "empty tail = no accessors")

	_check(Acc.compose({"has_setter": true, "setter_arg": "", "setter_body": ""}) == "set(value):\n\tpass", "defaults: empty arg and body")
	_check(Acc.compose({"has_getter": true, "getter_body": "return 1"}) == "get:\n\treturn 1", "compose: getter only")
	_check(Acc.compose({"has_getter": true, "has_setter": true, "get_first": true, "getter_body": "return 1", "setter_body": "x = value"}) \
		== "get:\n\treturn 1\nset(value):\n\tx = value", "compose: get_first order")
	_check(Acc.default_setter_body("hp", "v") == "hp = v" and Acc.default_getter_body("hp") == "return hp", "starter bodies")


func _test_model() -> void:
	# ---- the reported case: loads structured, round-trips byte for byte
	var m: Model = Model.new()
	m.build(USER_SRC)
	var vid: int = _var_named(m, "charge")
	_check(vid >= 0, "model: variable found")
	var f: Dictionary = m.nodes[vid]["fields"]
	_check(String(f["acc_mode"]) == "struct" and bool(f["has_setter"]) and not bool(f["has_getter"]), "model: setter detected")
	_check(f["setter_arg"] == "val" and String(f["setter_body"]).begins_with("var prev := charge"), "model: setter fields")
	_check(m.var_supports_accessors(vid), "model: accessors supported")
	var gen: String = String(m.generate()["text"])
	_check(gen == USER_SRC, "model: untouched round trip is byte-identical", gen)

	# ---- edit the setter body
	_check(m.set_var_prop(vid, "setter", "var prev := charge\ncharge = clampf(val, 0.0, MAX_CHARGE)\nprint(prev)"), "edit: setter body accepted")
	gen = String(m.generate()["text"])
	_check(gen.contains("\tset(val):\n\t\tvar prev := charge\n\t\tcharge = clampf(val, 0.0, MAX_CHARGE)\n\t\tprint(prev)\n"), "edit: setter body generated", gen)
	_check(_compiles(gen), "edit: result compiles", gen)
	_check(m.generate()["problems"].is_empty(), "edit: no problems")

	# ---- rename the setter argument: body follows
	_check(m.set_var_prop(vid, "setter_arg", "v"), "arg: rename accepted")
	gen = String(m.generate()["text"])
	_check(gen.contains("set(v):") and gen.contains("clampf(v, 0.0, MAX_CHARGE)") and not gen.contains("clampf(val"), "arg: body follows the rename", gen)
	_check(not m.set_var_prop(vid, "setter_arg", "1bad"), "arg: invalid identifier rejected")
	_check(_compiles(gen), "arg: result compiles")

	# ---- add a getter, then remove the setter
	_check(m.set_var_prop(vid, "has_getter", "true"), "getter: enable")
	gen = String(m.generate()["text"])
	_check(gen.contains("\tget:\n\t\treturn charge\n"), "getter: starter body generated", gen)
	_check(gen.find("set(v):") < gen.find("get:"), "getter: placed after the setter")
	_check(_compiles(gen), "getter: result compiles", gen)
	_check(m.set_var_prop(vid, "getter", "return charge * 2.0"), "getter: body edit")
	_check(String(m.generate()["text"]).contains("return charge * 2.0"), "getter: body generated")
	_check(m.set_var_prop(vid, "has_setter", "false"), "setter: disable")
	gen = String(m.generate()["text"])
	_check(not gen.contains("set(") and gen.contains("get:") and _compiles(gen), "setter: removed, getter stays", gen)

	# ---- remove everything: back to a plain declaration (no dangling ':')
	_check(m.set_var_prop(vid, "has_getter", "false"), "getter: disable")
	gen = String(m.generate()["text"])
	_check(gen.contains("var charge: float = 0.0\n") and not gen.contains("0.0:"), "none: plain declaration again", gen)
	_check(_compiles(gen), "none: result compiles")
	# and back on
	_check(m.set_var_prop(vid, "has_setter", "true"), "setter: re-enable")
	gen = String(m.generate()["text"])
	_check(gen.contains("var charge: float = 0.0:\n\tset(v):\n\t\tvar prev := charge\n"), "setter: re-enabling restores the previous body", gen)
	_check(_compiles(gen), "setter: re-enabled result compiles", gen)

	# ---- rename the variable: its own accessors and other variables' follow
	m.clear()
	m.build("extends Node\n\nvar hp: int = 10:\n\tset(v):\n\t\thp = maxi(v, 0)\n\tget:\n\t\treturn hp\n\nvar shield: int = 0:\n\tset(v):\n\t\tshield = mini(v, hp)\n\nfunc _ready() -> void:\n\tpass\n")
	var hp: int = _var_named(m, "hp")
	_check(m.set_var_prop(hp, "name", "health"), "rename: accepted")
	gen = String(m.generate()["text"])
	_check(gen.contains("health = maxi(v, 0)") and gen.contains("return health") and gen.contains("mini(v, health)"),
		"rename: accessors of both variables follow", gen)
	_check(not gen.contains("hp"), "rename: nothing left behind", gen)
	_check(_compiles(gen), "rename: result compiles", gen)

	# ---- a variable that had no accessors can get one
	m.clear()
	m.build("extends Node\n\nvar score := 1\n\nfunc _ready() -> void:\n\tpass\n")
	var sc: int = _var_named(m, "score")
	_check(m.var_supports_accessors(sc), "plain: accessors supported")
	_check(m.set_var_prop(sc, "has_getter", "true") and m.set_var_prop(sc, "has_setter", "true"), "plain: both enabled")
	gen = String(m.generate()["text"])
	_check(gen.contains("var score := 1:\n\tset(value):\n\t\tscore = value\n\tget:\n\t\treturn score\n") or gen.contains("get:"), "plain: generated", gen)
	_check(_compiles(gen), "plain: result compiles", gen)

	# ---- a hand-built variable (never parsed) works too
	m.clear()
	m.build("extends Node\n\nfunc _ready() -> void:\n\tpass\n")
	var nid: int = m.add_node(Model.Kind.VAR_DECL, {"name": "ammo", "raw_type": "int", "default": "3"})
	_check(nid >= 0 and m.var_supports_accessors(nid), "new variable: accessors supported")
	_check(m.set_var_prop(nid, "has_setter", "true"), "new variable: setter enabled")
	gen = String(m.generate()["text"])
	_check(gen.contains("var ammo: int = 3:\n\tset(value):\n\t\tammo = value\n"), "new variable: generated", gen)
	_check(_compiles(gen), "new variable: compiles", gen)

	# ---- raw accessor blocks stay verbatim and are edited as one block
	var raw_src: String = "extends Node\n\nvar hp: int = 1:\n\t# keep it positive\n\tset(v):\n\t\thp = maxi(v, 0)\n\nfunc _ready() -> void:\n\tpass\n"
	m.clear()
	m.build(raw_src)
	var rv: int = _var_named(m, "hp")
	_check(String(m.nodes[rv]["fields"]["acc_mode"]) == "raw", "raw: block with a comment is raw")
	_check(String(m.generate()["text"]) == raw_src, "raw: untouched round trip is byte-identical")
	_check(not m.set_var_prop(rv, "has_getter", "true"), "raw: form toggles are refused")
	_check(m.set_var_prop(rv, "tail", "set(v):\n\thp = v\nget:\n\treturn hp"), "raw: block edit accepted")
	_check(String(m.nodes[rv]["fields"]["acc_mode"]) == "raw", "raw: stays raw while edited (editor is not swapped under the caret)")
	_check(_compiles(String(m.generate()["text"])), "raw: edited result compiles")
	# reloading the generated text analyses it again: now fully structured
	var reloaded: Model = Model.new()
	reloaded.build(String(m.generate()["text"]))
	var rl: int = _var_named(reloaded, "hp")
	_check(String(reloaded.nodes[rl]["fields"]["acc_mode"]) == "struct" and bool(reloaded.nodes[rl]["fields"]["has_getter"]),
		"raw: reload turns the edited block into the form")
	var one_line: String = "extends Node\n\nvar hp: int = 1:\n\tset(v): hp = v\n\nfunc _ready() -> void:\n\tpass\n"
	m.clear()
	m.build(one_line)
	_check(String(m.nodes[_var_named(m, "hp")]["fields"]["acc_mode"]) == "raw" and String(m.generate()["text"]) == one_line,
		"raw: one-line accessor body kept verbatim")

	# ---- lambda defaults are not accessor blocks
	var lam: String = "extends Node\n\nvar double := func(x: int) -> int:\n\treturn x * 2\n\nfunc _ready() -> void:\n\tpass\n"
	m.clear()
	m.build(lam)
	var lv: int = _var_named(m, "double")
	_check(lv >= 0 and not m.var_supports_accessors(lv), "lambda: no accessor editing offered")
	_check(String(m.generate()["text"]) == lam, "lambda: untouched round trip is byte-identical")
	_check(not m.set_var_prop(lv, "has_setter", "true"), "lambda: accessor toggle refused")

	# ---- annotated + static variables
	var ann: String = "extends Node\n\n@export var energy: float = 1.0:\n\tset(v):\n\t\tenergy = v\n\t\tprint(v)\n\nvar other := 1\n\nfunc _ready() -> void:\n\tpass\n"
	m.clear()
	m.build(ann)
	_check(String(m.generate()["text"]) == ann, "annotated: untouched round trip is byte-identical")
	var ev: int = _var_named(m, "energy")
	_check(m.set_var_prop(ev, "has_getter", "true"), "annotated: getter added")
	gen = String(m.generate()["text"])
	_check(gen.contains("@export var energy: float = 1.0:\n\tset(v):") and _compiles(gen), "annotated: still valid", gen)

	# ---- the other 538 round-trip suites keep covering plain variables;
	# here: a function-local variable never offers accessors
	m.clear()
	m.build("extends Node\n\nfunc f() -> void:\n\tvar local := 1\n\tprint(local)\n")
	var loc: int = _var_named(m, "local")
	_check(loc >= 0 and not m.var_supports_accessors(loc), "local variable: no accessors")
	m.clear()


func _var_named(m: Model, name: String) -> int:
	for id: int in m.nodes:
		if int(m.nodes[id]["kind"]) == Model.Kind.VAR_DECL and String(m.nodes[id]["fields"].get("name", "")) == name:
			return id
	return -1


## Setter / Getter nodes: loading, generation, creating and removing them.
func _test_nodes() -> void:
	var m: Model = Model.new()
	m.build(USER_SRC)
	var vid: int = _var_named(m, "charge")
	var acc: Dictionary = m.accessor_entries_of(vid)
	_check(acc.has("set") and not acc.has("get"), "nodes: setter loaded as a node")
	_check(String(m.nodes[vid]["fields"].get("tail", "")) == "", "nodes: no verbatim tail left")
	_check(not m.var_supports_accessors(vid), "nodes: the text accessor form is off")
	var gen: String = String(m.generate()["text"])
	_check(gen == USER_SRC, "nodes: untouched round trip is byte-identical", gen)

	# a Setter is not a function
	_check(m.is_accessor_entry(int(acc["set"])), "nodes: flagged as accessor entry")

	# fresh variable: add, generate, compile, remove
	var m2: Model = Model.new()
	m2.build("extends Node\n\nvar hp: int = 10\n")
	var hid: int = _var_named(m2, "hp")
	_check(m2.accessor_nodes_allowed(hid), "add: allowed on a plain variable")
	var sid: int = m2.add_accessor(hid, "set")
	_check(sid >= 0, "add: setter created")
	_check(m2.add_accessor(hid, "set") < 0, "add: a second setter is refused")
	var gid: int = m2.add_accessor(hid, "get")
	_check(gid >= 0, "add: getter created")
	gen = String(m2.generate()["text"])
	_check(gen.contains("var hp: int = 10:\n\tget:\n\t\treturn hp\n\tset(value):\n\t\thp = value\n") \
		or gen.contains("var hp: int = 10:\n\tset(value):\n\t\thp = value\n\tget:\n\t\treturn hp\n"),
		"add: both accessors generated", gen)
	_check(_compiles(gen), "add: result compiles", gen)
	_check(m2.generate()["problems"].is_empty(), "add: no problems")
	# a body of nodes: set(value) -> if value < 0 ... is built by the person; here
	# just check the renamed variable keeps the titles and bodies in step
	_check(m2.set_var_prop(hid, "name", "health"), "rename: accepted")
	_check(String(m2.nodes[sid]["title"]) == "Setter: health", "rename: setter title follows")
	gen = String(m2.generate()["text"])
	_check(gen.contains("health = value") and _compiles(gen), "rename: body follows", gen)
	_check(m2.remove_accessor(hid, "set") and not m2.nodes.has(sid), "remove: setter and its body are gone")
	gen = String(m2.generate()["text"])
	_check(not gen.contains("set(value)") and gen.contains("get:") and _compiles(gen), "remove: getter stays", gen)
	m2.remove_node(hid)
	_check(m2.accessor_entries_of(hid).is_empty() and not m2.nodes.has(gid), "delete variable: accessors go with it")

	# a variable called `value` gets another argument name
	var m3: Model = Model.new()
	m3.build("extends Node\n\nvar value: int = 0\n")
	var v3: int = _var_named(m3, "value")
	m3.add_accessor(v3, "set")
	gen = String(m3.generate()["text"])
	_check(gen.contains("set(new_value):") and gen.contains("value = new_value") and _compiles(gen), "add: argument avoids the variable's own name", gen)

	# node-menu route: free-standing Setter / Getter + variable picker
	var mf: Model = Model.new()
	mf.build("extends Node\n\nvar a: int = 1\nvar b: int = 2\n")
	var fa: int = _var_named(mf, "a")
	var fb: int = _var_named(mf, "b")
	var e1: int = mf.add_accessor_free("set")
	_check(int(mf.nodes[e1]["fields"]["owner_var"]) == fa, "free: first setter takes the first free variable")
	var e2: int = mf.add_accessor_free("set")
	_check(int(mf.nodes[e2]["fields"]["owner_var"]) == fb, "free: second setter takes the next free variable")
	var e3: int = mf.add_accessor_free("set")
	_check(int(mf.nodes[e3]["fields"]["owner_var"]) == -1 and String(mf.nodes[e3]["title"]) == "Setter", "free: no variable left -> unattached")
	_check(not mf.set_accessor_owner(e3, fa) and mf.last_reject_reason != "", "free: a variable cannot get a second setter")
	_check(mf.accessor_owner_candidates(e3).is_empty(), "free: no candidates left for a third setter")
	var eg: int = mf.add_accessor_free("get")
	_check(int(mf.nodes[eg]["fields"]["owner_var"]) == fa, "free: getters are independent of setters")
	_check(mf.set_accessor_owner(e2, -1) and String(mf.nodes[e2]["title"]) == "Setter", "free: detach")
	_check(mf.set_accessor_owner(e3, fb) and String(mf.nodes[e3]["title"]) == "Setter: b", "free: attach after the variable became free")
	var gf: String = String(mf.generate()["text"])
	_check(gf.contains("set(value):\n\t\ta = value") and gf.contains("b = value") and _compiles(gf), "free: generated accessors compile", gf)

	# the text block with a comment stays verbatim (no nodes)
	var m4: Model = Model.new()
	m4.build("extends Node\n\nvar x := 0:\n\t# note\n\tset(v):\n\t\tx = v\n")
	var v4: int = _var_named(m4, "x")
	_check(m4.accessor_entries_of(v4).is_empty() and String(m4.nodes[v4]["fields"].get("tail", "")) != "", "verbatim: block with a comment stays text")
	_check(m4.add_accessor(v4, "get") < 0, "verbatim: no node accessor next to a text block")
	_check(String(m4.generate()["text"]).contains("# note"), "verbatim: comment survives")


## Setter / Getter are created from the node menu like a Function; the Variable
## node has no Add / Remove buttons; the Setter node has no name / return-type
## fields but a Variable picker.
func _test_ui() -> void:
	var c: Canvas = Canvas.new()
	c.custom_minimum_size = Vector2(1400, 900)
	c.size = Vector2(1400, 900)
	root.add_child(c)
	await process_frame
	c.build_from_text("extends Node\n\nvar hp: int = 10\n")
	await process_frame
	var hid: int = _var_named(c.model, "hp")
	_check(c.views.has(hid), "ui: variable view exists")
	_check(not c.views[hid].has_signal("accessor_action"), "ui: the variable node has no Add Setter / Getter button signal")
	var has_btn: bool = false
	for ch: Node in c.views[hid].get_children():
		if ch is HBoxContainer:
			for ch2: Node in ch.get_children():
				if ch2 is Button and (ch2 as Button).text.contains("Setter"):
					has_btn = true
	_check(not has_btn, "ui: no Setter / Getter button on the variable node")
	# the menu lists both
	var names: PackedStringArray = PackedStringArray()
	for e: Dictionary in c.menu_items():
		names.append(String(e["name"]))
	_check(names.has("Setter") and names.has("Getter"), "ui: node menu offers Setter and Getter")
	# spawn like a function
	var seid: int = c.spawn_node(Model.Kind.ENTRY, {"accessor": "set"}, Vector2(300, 300))
	await process_frame
	var acc: Dictionary = c.model.accessor_entries_of(hid)
	_check(seid >= 0 and acc.has("set") and int(acc["set"]) == seid and c.views.has(seid), "ui: spawned Setter attaches to the free variable")
	var sv: NodeView = c.views[seid]
	_check(not sv._form_fields.has("name") and not sv._form_fields.has("ret_type"), "ui: setter has no function name / return type fields")
	_check(String(c.model.nodes[seid]["title"]) == "Setter: hp", "ui: setter title")
	var gen: String = String(c.model.generate()["text"])
	_check(gen.contains("\tset(value):\n\t\thp = value"), "ui: generated setter", gen)
	# a second Setter has no free variable: it starts unattached and writes nothing
	var s2: int = c.spawn_node(Model.Kind.ENTRY, {"accessor": "set"}, Vector2(300, 600))
	await process_frame
	_check(s2 >= 0 and int(c.model.nodes[s2]["fields"]["owner_var"]) == -1 and String(c.model.nodes[s2]["title"]) == "Setter", "ui: second setter starts unattached")
	_check(String(c.model.generate()["text"]).count("set(") == 1, "ui: unattached setter is not written")
	# a new variable can be picked on the node
	c.spawn_node(Model.Kind.VAR_DECL, {"name": "mp", "raw_type": "int", "default": "5"}, Vector2(100, 700))
	await process_frame
	var mid: int = _var_named(c.model, "mp")
	c._on_accessor_owner_picked(s2, mid)
	await process_frame
	_check(int(c.model.nodes[s2]["fields"]["owner_var"]) == mid and String(c.model.nodes[s2]["title"]) == "Setter: mp", "ui: picking a variable attaches the setter")
	_check(String(c.model.generate()["text"]).contains("mp = value"), "ui: picked setter gets the ready-made body")
	# picking a variable that already has a setter is refused
	c._on_accessor_owner_picked(s2, hid)
	await process_frame
	_check(int(c.model.nodes[s2]["fields"]["owner_var"]) == mid, "ui: a variable cannot have two setters")
	# deleting the node removes the accessor
	c.model.remove_node(seid)
	_check(c.model.accessor_entries_of(hid).is_empty(), "ui: removing the setter node frees the variable")
	c.queue_free()
