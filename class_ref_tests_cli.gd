# Runs headless: godot --headless --path <project> -s res://addons/gd_canvas_spikes/class_ref_tests_cli.gd
extends SceneTree
## Headless tests for the Class Reference & Member node system:
## class/member discovery (class_registry.gd), Class Reference nodes, member
## call nodes (methods / properties / signals / constants), registration
## wires, generation and the parsed dotted-call round-trip.

const Model = preload("res://addons/gd_canvas_spikes/graph_model.gd")
const Types = preload("res://addons/gd_canvas_spikes/graph_types.gd")
const ClassReg = preload("res://addons/gd_canvas_spikes/class_registry.gd")
const FuncReg = preload("res://addons/gd_canvas_spikes/func_registry.gd")
const TypeReg = preload("res://addons/gd_canvas_spikes/type_registry.gd")

var fails: int = 0
var checks: int = 0


func _check(label: String, ok: bool, detail: String = "") -> void:
	checks += 1
	if ok:
		print("  ok   ", label)
	else:
		fails += 1
		print("  FAIL ", label, "  ", detail)


func _write(path: String, text: String) -> void:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


const FIXTURE_DIR: String = "res://crt_fixtures"

const TEST_CLASS_SRC: String = """class_name Test_class
extends Node

const MAX_HEALTH := 100

var health: int = 100

signal died(reason: String)

static func describe() -> String:
	return "Test_class"

func get_health() -> int:
	return health
"""

const OTHER_SRC: String = """extends RefCounted

const VERSION := 7

static func help() -> void:
	pass
"""

const USER_SRC: String = """extends Node

func run() -> void:
\tTest_class.describe()
"""


func _init() -> void:
	# --- fixtures ------------------------------------------------------------
	DirAccess.make_dir_recursive_absolute(FIXTURE_DIR)
	_write(FIXTURE_DIR + "/test_class.gd", TEST_CLASS_SRC)
	_write(FIXTURE_DIR + "/other.gd", OTHER_SRC)
	_write(FIXTURE_DIR + "/user.gd", USER_SRC)
	ClassReg.get_registry().refresh()
	FuncReg.get_registry().refresh()
	TypeReg.get_registry().refresh()

	_test_registry()
	_test_class_ref_node()
	_test_registration()
	_test_generation_static()
	_test_generation_instance()
	_test_generation_members()
	_test_compatibility()
	_test_roundtrip()
	_test_path_ref()
	_test_hardening()

	# --- UI smoke (views, wiring, mode switch) ---------------------------------
	print("-- UI smoke")
	var Workspace: GDScript = load("res://addons/gd_canvas_spikes/graph_workspace.gd")
	var ws: Control = Workspace.new()
	root.add_child(ws)
	await process_frame
	await process_frame
	var c: Control = ws._canvas
	var rid: int = c.spawn_node(Model.Kind.CLASS_REF,
		{"target": "Test_class", "ref": "class"}, Vector2(100, 100))
	await process_frame
	_check("class ref view created", c.views.has(rid) and is_instance_valid(c.views[rid]), "")
	var cid: int = c.spawn_node(Model.Kind.CALL, _member_fields("get_health",
		FuncReg.CAT_CUSTOM, "Test_class", "method", "int", true, "Test_class"),
		Vector2(500, 100))
	await process_frame
	_check("member view created", c.views.has(cid) and is_instance_valid(c.views[cid]), "")
	var slot: int = c.model.register_member(rid, cid)
	c._sync_connections()
	await process_frame
	_check("slot wire ports exist", c.views[rid].data_in_port(slot) >= 0
		and c.views[cid].data_out_port(0) >= 0, "%d" % slot)
	# mode switch through the model rebuilds the view without errors
	c.model.set_class_ref_prop(rid, "ref", "instance")
	c._maybe_rebuild_pins(c.views.get(rid))
	await process_frame
	_check("mode switch rebuilds with the instance pin",
		c.views.has(rid) and c.views[rid].data_in_count() == 3, str(c.views[rid].data_in_count()))
	# the registered member generates through the instance source
	var eid: int = c.model.add_node(Model.Kind.ENTRY, {"name": "run"})
	var ret: int = c.model.add_node(Model.Kind.RETURN)
	c.model.connect_exec(eid, 0, ret)
	c.model.connect_data(cid, 1, ret, 0)
	var gen: Dictionary = c.model.generate()
	_check("instance source reaches generation",
		String(gen["text"]).contains("return self.get_health()"), String(gen["text"]))
	ws.queue_free()
	await process_frame

	# --- cleanup --------------------------------------------------------------
	DirAccess.remove_absolute(FIXTURE_DIR + "/test_class.gd")
	DirAccess.remove_absolute(FIXTURE_DIR + "/other.gd")
	DirAccess.remove_absolute(FIXTURE_DIR + "/user.gd")
	DirAccess.remove_absolute(FIXTURE_DIR)

	print("\n%d checks, %d failures -> %s" % [checks, fails, "PASS" if fails == 0 else "FAIL"])
	quit(1 if fails > 0 else 0)


# ---- Registry ----------------------------------------------------------------
func _member_of(members: Array, mname: String, mtype: String) -> Dictionary:
	for m: Dictionary in members:
		if str(m["name"]) == mname and str(m["mtype"]) == mtype:
			return m
	return {}


func _test_registry() -> void:
	print("-- class registry")
	var rec: Dictionary = ClassReg.get_registry().find_class("Test_class")
	_check("custom class discovered", not rec.is_empty() and str(rec["kind"]) == ClassReg.KIND_CUSTOM, str(rec))
	_check("custom class path recorded", str(rec.get("path", "")).ends_with("test_class.gd"), str(rec.get("path", "")))
	_check("unknown class resolves empty", ClassReg.get_registry().find_class("NoSuchClass_XYZ").is_empty(), "")
	var engine_rec: Dictionary = ClassReg.get_registry().find_class("Node")
	_check("engine class discovered", str(engine_rec.get("kind", "")) == ClassReg.KIND_ENGINE, str(engine_rec))

	var members: Array = ClassReg.get_registry().members_of("Test_class")
	var describe: Dictionary = _member_of(members, "describe", ClassReg.MT_METHOD)
	_check("static method discovered", not describe.is_empty() and bool(describe["static"]), str(describe))
	_check("static method needs no target", not describe.is_empty() and not bool(describe["needs_target"]), "")
	var geth: Dictionary = _member_of(members, "get_health", ClassReg.MT_METHOD)
	_check("instance method discovered", not geth.is_empty() and not bool(geth["static"]) and bool(geth["needs_target"]), str(geth))
	_check("instance method target type", not geth.is_empty() and str(geth["target_type"]) == "Test_class", str(geth))
	var hp: Dictionary = _member_of(members, "health", ClassReg.MT_PROPERTY)
	_check("script var discovered as property", not hp.is_empty() and str(hp["ret"]) == "int", str(hp))
	var maxhp: Dictionary = _member_of(members, "MAX_HEALTH", ClassReg.MT_CONSTANT)
	_check("const discovered (inferred int)", not maxhp.is_empty() and str(maxhp["ret"]) == "int", str(maxhp))
	_check("const is class-level", not maxhp.is_empty() and bool(maxhp["static"]) and not bool(maxhp["needs_target"]), "")
	var died: Dictionary = _member_of(members, "died", ClassReg.MT_SIGNAL)
	_check("signal discovered with args", not died.is_empty() and (died["args"] as Array).size() == 1
		and str((died["args"] as Array)[0]["name"]) == "reason", str(died))

	var node_members: Array = ClassReg.get_registry().members_of("Node")
	var gid: Dictionary = _member_of(node_members, "get_instance_id", ClassReg.MT_METHOD)
	_check("inherited engine method listed", not gid.is_empty() and bool(gid["inherited"]), str(gid))
	var notif: Dictionary = _member_of(node_members, "NOTIFICATION_READY", ClassReg.MT_CONSTANT)
	_check("engine constant listed", not notif.is_empty(), str(notif))
	var node_prop: Dictionary = _member_of(node_members, "name", ClassReg.MT_PROPERTY)
	_check("engine property listed with type", not node_prop.is_empty() and str(node_prop["ret"]) == "StringName", str(node_prop))

	# singleton registration (extension point used by tests / addons)
	var before: int = ClassReg.get_registry().classes().size()
	ClassReg.get_registry().register_class({"name": "CRT_Singleton", "kind": ClassReg.KIND_AUTOLOAD,
		"path": FIXTURE_DIR + "/test_class.gd", "singleton": true, "cls": "", "menu": true})
	_check("registered class appears", ClassReg.get_registry().classes().size() == before + 1, "")
	var srec: Dictionary = ClassReg.get_registry().find_class("CRT_Singleton")
	_check("singleton expr is the singleton name",
		ClassReg.get_registry().class_expr(srec) == "CRT_Singleton", ClassReg.get_registry().class_expr(srec))
	var smembers: Array = ClassReg.get_registry().members_of("CRT_Singleton")
	_check("singleton members include script methods", not _member_of(smembers, "describe", ClassReg.MT_METHOD).is_empty(), "")


# ---- Class Reference node -----------------------------------------------------
func _test_class_ref_node() -> void:
	print("-- Class Reference node")
	var m: Model = Model.new()
	var rid: int = m.add_node(Model.Kind.CLASS_REF, {"target": "Test_class", "ref": "class"})
	_check("class ref spawns", rid > 0, str(rid))
	var n: Dictionary = m.nodes[rid]
	_check("class mode title", String(n["title"]) == "Class Test_class", String(n["title"]))
	_check("typed output pin", n["data_outs"].size() == 1 and int(n["data_outs"][0]["type"]) == Types.PinType.OBJECT
		and String(n["data_outs"][0]["type_text"]) == "Test_class", str(n["data_outs"]))
	_check("add member slot present", n["data_ins"].size() == 1
		and String(n["data_ins"][0]["name"]) == "add member"
		and int(n["data_ins"][0]["type"]) == Types.PinType.MEMBER, str(n["data_ins"]))
	_check("class expr is the class name", m._class_ref_expr(rid, 0) == "Test_class", m._class_ref_expr(rid, 0))
	_check("no exec pins", not bool(n["exec_in"]) and n["exec_outs"].is_empty(), "")

	var iid: int = m.add_node(Model.Kind.CLASS_REF, {"target": "Test_class", "ref": "instance", "source": "player"})
	var inn: Dictionary = m.nodes[iid]
	_check("instance mode adds instance input", inn["data_ins"].size() == 2
		and String(inn["data_ins"][0]["name"]) == "instance", str(inn["data_ins"]))
	_check("instance source prefilled", String(inn["data_ins"][0]["value"]) == "player", String(inn["data_ins"][0]["value"]))
	_check("instance title", String(inn["title"]) == "Instance Test_class", String(inn["title"]))
	_check("instance expr is the source", m._class_ref_expr(iid, 0) == "player", m._class_ref_expr(iid, 0))
	_check("retarget keeps identity on pins",
		(m.set_class_ref_prop(iid, "target", "Node") and String(m.nodes[iid]["data_outs"][0]["type_text"]) == "Node"),
		str(m.nodes[iid]["data_outs"]))
	_check("invalid mode rejected", not m.set_class_ref_prop(iid, "ref", "bogus"), "")
	_check("mode switch back to class drops instance input",
		m.set_class_ref_prop(iid, "ref", "class") and m.nodes[iid]["data_ins"].size() == 1, str(m.nodes[iid]["data_ins"]))


# ---- Registration wires ---------------------------------------------------------
func _member_fields(call_name: String, cat: String, owner: String, member: String,
		ret: String, needs_target: bool, target_type: String, args: Array = [],
		mode: String = "pure", is_static: bool = false) -> Dictionary:
	return {
		"call": call_name, "cat": cat, "owner": owner, "ret": ret,
		"static": is_static, "needs_target": needs_target, "target_type": target_type,
		"vararg": false, "args": args, "member": member, "mode": mode, "declared": true,
	}


func _test_registration() -> void:
	print("-- member registration")
	var m: Model = Model.new()
	var rid: int = m.add_node(Model.Kind.CLASS_REF, {"target": "Test_class", "ref": "class"})
	var cid: int = m.add_node(Model.Kind.CALL, _member_fields("get_health", FuncReg.CAT_CUSTOM,
		"Test_class", "method", "int", true, "Test_class"))
	var slot: int = m.register_member(rid, cid)
	_check("register returns a slot", slot >= 0, str(slot))
	_check("member pin row added", m.nodes[rid]["data_ins"].size() == 2
		and String(m.nodes[rid]["data_ins"][0]["name"]) == "get_health"
		and String(m.nodes[rid]["data_ins"][1]["name"]) == "add member", str(m.nodes[rid]["data_ins"]))
	_check("member_owner resolves", m.member_owner(cid) == rid, str(m.member_owner(cid)))
	_check("Class ownership output on member", m.nodes[cid]["data_outs"].size() >= 1
		and int(m.nodes[cid]["data_outs"][0]["type"]) == Types.PinType.MEMBER
		and String(m.nodes[cid]["data_outs"][0]["name"]) == "Class", str(m.nodes[cid]["data_outs"]))
	# registration wires are not data_links (annotation-style ownership)
	var data_wires: int = 0
	for l: Dictionary in m.data_links:
		if int(l["to_id"]) == rid:
			data_wires += 1
	_check("registration wire is not value flow", data_wires == 0, str(data_wires))
	# re-registering moves the member
	# Test_class extends Node, so Node members and Test_class members both fit it
	var rid2: int = m.add_node(Model.Kind.CLASS_REF, {"target": "Test_class", "ref": "class"})
	var slot2: int = m.register_member(rid2, cid)
	_check("re-registering moves the member", slot2 >= 0 and m.member_owner(cid) == rid2
		and m.nodes[rid]["data_ins"].size() == 1 and m.nodes[rid2]["data_ins"].size() == 2, "")
	_check("slot label follows the member", String(m.nodes[rid2]["data_ins"][0]["name"]) == "get_health",
		str(m.nodes[rid2]["data_ins"]))
	# a second member appends
	var cid2: int = m.add_node(Model.Kind.CALL, _member_fields("set_position", FuncReg.CAT_GODOT_CLASS,
		"Node", "method", "void", true, "Node", [], "exec"))
	m.register_member(rid2, cid2)
	_check("second member appends", m.nodes[rid2]["data_ins"].size() == 3
		and String(m.nodes[rid2]["data_ins"][1]["name"]) == "set_position", str(m.nodes[rid2]["data_ins"]))
	# slot-targeted registration: slot 1 with one member = append at slot 1
	var slot3: int = m.register_member(rid2, cid, 1)
	_check("slot-targeted registration appends", slot3 == 1
		and m._member_pin_slot(rid2, cid2) == 0, "%d / %d" % [slot3, m._member_pin_slot(rid2, cid2)])
	# wiring into an occupied slot row replaces that member at its position
	# (the connect_data intercept unregisters the occupant first; the direct
	# API mirrors that)
	m.unregister_member(rid2, cid2)
	var cid3: int = m.add_node(Model.Kind.CALL, _member_fields("set_health", FuncReg.CAT_CUSTOM,
		"Test_class", "method", "void", true, "Test_class", [], "exec"))
	var slot4: int = m.register_member(rid2, cid3, 0)
	_check("occupied slot replace keeps positions", slot4 == 0 and m.member_owner(cid2) == -1
		and m._member_pin_slot(rid2, cid) == 1, "%d" % slot4)
	# registration through connect_data (the wire path the canvas uses)
	var cid4: int = m.add_node(Model.Kind.CALL, _member_fields("describe", FuncReg.CAT_CUSTOM,
		"Test_class", "method", "String", false, "", [], "exec", true))
	var slot5: int = m.nodes[rid2]["data_ins"].size() - 1   # the trailing "add member" row
	var conn: Dictionary = m.connect_data(cid4, 0, rid2, slot5)
	_check("connect_data registers through the add-member slot",
		not conn.has("_rejected") and m.member_owner(cid4) == rid2, m.last_reject_reason)
	_check("connect_data member wire is not value flow", conn.is_empty(), str(conn))
	# unregister
	m.unregister_member(rid2, cid)
	var has_row: bool = false
	for pr: Dictionary in m.nodes[rid2]["data_ins"]:
		if String(pr["name"]) == "get_health":
			has_row = true
	_check("unregister removes pin row", m.member_owner(cid) == -1 and not has_row,
		str(m.nodes[rid2]["data_ins"]))
	# deletion cleans both sides
	var rid3: int = m.add_node(Model.Kind.CLASS_REF, {"target": "Test_class", "ref": "class"})
	m.register_member(rid3, cid)
	m.remove_node(rid3)
	_check("deleting the reference unregisters members", m.member_owner(cid) == -1, "")
	m.register_member(rid2, cid)
	m.remove_node(cid)
	var orphaned: bool = true
	for ml: Dictionary in m.member_links:
		if int(ml["cid"]) == cid:
			orphaned = false
	_check("deleting the member cleans its registration", orphaned, str(m.member_links))


# ---- Generation: static / class-level --------------------------------------------
func _entry_with(m: Model, flow: int = -1) -> int:
	var eid: int = m.add_node(Model.Kind.ENTRY, {"name": "run"})
	if flow >= 0:
		m.connect_exec(eid, 0, flow)
	return eid


func _test_generation_static() -> void:
	print("-- generation: class-level members")
	# static method through a class-mode reference
	var m: Model = Model.new()
	var rid: int = m.add_node(Model.Kind.CLASS_REF, {"target": "Test_class", "ref": "class"})
	var cid: int = m.add_node(Model.Kind.CALL, _member_fields("describe", FuncReg.CAT_CUSTOM,
		"Test_class", "method", "String", false, "", [], "exec", true))
	var slot: int = m.register_member(rid, cid)
	var eid: int = _entry_with(m, cid)
	_check("static member registered", slot >= 0 and eid > 0, "")
	var out: Dictionary = m.generate()
	_check("static call generates on the class name",
		String(out["text"]).contains("Test_class.describe()"), String(out["text"]))
	_check("static call has no problems", (out["problems"] as PackedStringArray).is_empty(),
		str(out["problems"]))
	# class constant through the owner (no reference needed at all)
	var m2: Model = Model.new()
	var cid2: int = m2.add_node(Model.Kind.CALL, _member_fields("MAX_HEALTH", FuncReg.CAT_CUSTOM,
		"Test_class", "property", "int", false, "", [], "pure", true))
	var eid2: int = m2.add_node(Model.Kind.ENTRY, {"name": "run"})
	var ret2: int = m2.add_node(Model.Kind.RETURN)
	m2.connect_exec(eid2, 0, ret2)
	m2.connect_data(cid2, 1, ret2, 0)
	var out2: Dictionary = m2.generate()
	_check("constant member reads through the class",
		String(out2["text"]).contains("return Test_class.MAX_HEALTH"), String(out2["text"]))


# ---- Generation: instance members -------------------------------------------------
func _inst_ref_model() -> Array:
	var m: Model = Model.new()
	var rid: int = m.add_node(Model.Kind.CLASS_REF, {"target": "Test_class", "ref": "instance", "source": "player"})
	var cid: int = m.add_node(Model.Kind.CALL, _member_fields("get_health", FuncReg.CAT_CUSTOM,
		"Test_class", "method", "int", true, "Test_class"))
	m.register_member(rid, cid)
	return [m, rid, cid]


func _test_generation_instance() -> void:
	print("-- generation: instance members")
	var trio: Array = _inst_ref_model()
	var m: Model = trio[0]
	var cid: int = trio[2]
	var eid: int = m.add_node(Model.Kind.ENTRY, {"name": "run"})
	var ret: int = m.add_node(Model.Kind.RETURN)
	m.connect_exec(eid, 0, ret)
	m.connect_data(cid, 1, ret, 0)
	var out: Dictionary = m.generate()
	_check("instance member uses the instance source",
		String(out["text"]).contains("return player.get_health()"), String(out["text"]))
	_check("instance member has no problems", (out["problems"] as PackedStringArray).is_empty(),
		str(out["problems"]))

	# the same instance member against a CLASS-mode reference is reported
	var m3: Model = Model.new()
	var rid3: int = m3.add_node(Model.Kind.CLASS_REF, {"target": "Test_class", "ref": "class"})
	var cid3: int = m3.add_node(Model.Kind.CALL, _member_fields("get_health", FuncReg.CAT_CUSTOM,
		"Test_class", "method", "int", true, "Test_class"))
	m3.register_member(rid3, cid3)
	var eid3: int = m3.add_node(Model.Kind.ENTRY, {"name": "run"})
	var ret3: int = m3.add_node(Model.Kind.RETURN)
	m3.connect_exec(eid3, 0, ret3)
	m3.connect_data(cid3, 1, ret3, 0)
	var out3: Dictionary = m3.generate()
	var pmsgs: PackedStringArray = out3["problems"] as PackedStringArray
	var said_instance: bool = false
	for pm: String in pmsgs:
		if pm.to_lower().contains("instance"):
			said_instance = true
	_check("instance member on a class reference is reported", said_instance, str(pmsgs))

	# an explicit target wire wins over the registration
	var m4: Model = Model.new()
	var rid4: int = m4.add_node(Model.Kind.CLASS_REF, {"target": "Test_class", "ref": "class"})
	var cid4: int = m4.add_node(Model.Kind.CALL, _member_fields("get_health", FuncReg.CAT_CUSTOM,
		"Test_class", "method", "int", true, "Test_class"))
	m4.register_member(rid4, cid4)
	var tgt: int = m4.add_node(Model.Kind.LITERAL, {"type": Types.PinType.OBJECT, "value": "self"})
	m4.connect_data(tgt, 0, cid4, 0)
	var eid4: int = m4.add_node(Model.Kind.ENTRY, {"name": "run"})
	var ret4: int = m4.add_node(Model.Kind.RETURN)
	m4.connect_exec(eid4, 0, ret4)
	m4.connect_data(cid4, 1, ret4, 0)
	var out4: Dictionary = m4.generate()
	_check("wired target wins over the class reference",
		String(out4["text"]).contains("return self.get_health()"), String(out4["text"]))


# ---- Generation: properties / signals ----------------------------------------------
func _test_generation_members() -> void:
	print("-- generation: properties and signals")
	# property read (expression)
	var m: Model = Model.new()
	var rid: int = m.add_node(Model.Kind.CLASS_REF, {"target": "Test_class", "ref": "instance", "source": "player"})
	var cid: int = m.add_node(Model.Kind.CALL, _member_fields("health", FuncReg.CAT_CUSTOM,
		"Test_class", "property", "int", true, "Test_class"))
	m.register_member(rid, cid)
	var eid: int = m.add_node(Model.Kind.ENTRY, {"name": "run"})
	var ret: int = m.add_node(Model.Kind.RETURN)
	m.connect_exec(eid, 0, ret)
	m.connect_data(cid, 1, ret, 0)
	var out: Dictionary = m.generate()
	_check("property read generates", String(out["text"]).contains("return player.health"), String(out["text"]))
	_check("property out pin keeps the property type",
		String(m.nodes[cid]["data_outs"][1]["name"]) == "health"
		and String(m.nodes[cid]["data_outs"][1]["type_text"]) == "int", str(m.nodes[cid]["data_outs"]))

	# property write (statement): flip the member to exec
	m.nodes[cid]["fields"]["mode"] = "exec"
	m._apply_call_meta(cid)
	var eid2: int = m.add_node(Model.Kind.ENTRY, {"name": "run"})
	m.connect_exec(eid2, 0, cid)
	var out2: Dictionary = m.generate()
	_check("property write generates", String(out2["text"]).contains("player.health = 0"), String(out2["text"]))

	# signal emit with an argument
	var m3: Model = Model.new()
	var rid3: int = m3.add_node(Model.Kind.CLASS_REF, {"target": "Test_class", "ref": "instance", "source": "player"})
	var cid3: int = m3.add_node(Model.Kind.CALL, _member_fields("died", FuncReg.CAT_CUSTOM,
		"Test_class", "signal", "Signal", true, "Test_class",
		[{"name": "reason", "type": "String", "default": "", "required": true}], "exec"))
	m3.register_member(rid3, cid3)
	m3.nodes[cid3]["data_ins"][1]["value"] = "\"boom\""
	var eid3: int = m3.add_node(Model.Kind.ENTRY, {"name": "run"})
	m3.connect_exec(eid3, 0, cid3)
	var out3: Dictionary = m3.generate()
	_check("signal emit generates with args",
		String(out3["text"]).contains("player.emit_signal(\"died\", \"boom\")"), String(out3["text"]))
	# pure signal use: the Signal object reference
	m3.nodes[cid3]["fields"]["mode"] = "pure"
	m3._apply_call_meta(cid3)
	var eid3b: int = m3.add_node(Model.Kind.ENTRY, {"name": "run"})
	var ret3: int = m3.add_node(Model.Kind.RETURN)
	m3.connect_exec(eid3b, 0, ret3)
	m3.connect_data(cid3, 1, ret3, 0)
	var out3b: Dictionary = m3.generate()
	_check("signal reference (pure) generates", String(out3b["text"]).contains("return player.died"),
		String(out3b["text"]))


# ---- Compatibility -----------------------------------------------------------------
func _test_compatibility() -> void:
	print("-- pin compatibility")
	var m: Model = Model.new()
	# a Sprite2D member: target typed Sprite2D
	var cid: int = m.add_node(Model.Kind.CALL, _member_fields("position", FuncReg.CAT_GODOT_CLASS,
		"Sprite2D", "property", "Vector2", true, "Sprite2D"))
	# a Node class reference: Node is NOT a Sprite2D
	var node_ref: int = m.add_node(Model.Kind.CLASS_REF, {"target": "Node", "ref": "class"})
	_check("base class ref into subclass member rejected",
		m.can_connect_data(node_ref, 0, cid, 0) == false, m.last_reject_reason)
	# a Sprite2D reference into the same member: subclass -> base is fine
	var spr_ref: int = m.add_node(Model.Kind.CLASS_REF, {"target": "Sprite2D", "ref": "class"})
	_check("subclass ref into base member accepted",
		not m.connect_data(spr_ref, 0, cid, 0).has("_rejected"), m.last_reject_reason)
	# member pins never accept arbitrary values
	var lit: int = m.add_node(Model.Kind.LITERAL, {"type": Types.PinType.OBJECT, "value": "null"})
	_check("value pin cannot feed the Class ownership input",
		m.can_connect_data(lit, 0, node_ref, 0) == false, m.last_reject_reason)
	# the registered reference still resolves the target (property read)
	var eid: int = m.add_node(Model.Kind.ENTRY, {"name": "run"})
	var ret: int = m.add_node(Model.Kind.RETURN)
	m.connect_exec(eid, 0, ret)
	m.connect_data(cid, 1, ret, 0)
	var out: Dictionary = m.generate()
	_check("reference-driven property read",
		String(out["text"]).contains("return Sprite2D.position"), String(out["text"]))


# ---- Round-trip ---------------------------------------------------------------------
func _test_roundtrip() -> void:
	print("-- parsed dotted calls round-trip")
	var src: String = FileAccess.open(FIXTURE_DIR + "/user.gd", FileAccess.READ).get_as_text()
	var m: Model = Model.new()
	var diags: PackedStringArray = m.build(src)
	_check("parses without diagnostics", diags.is_empty(), str(diags))
	var class_refs: Array[int] = []
	var member_calls: Array[int] = []
	for id: int in m.nodes:
		if int(m.nodes[id]["kind"]) == Model.Kind.CLASS_REF:
			class_refs.append(id)
		if int(m.nodes[id]["kind"]) == Model.Kind.CALL \
				and str(m.nodes[id]["fields"].get("member", "")) != "":
			member_calls.append(id)
	_check("dotted call reconstructs a Class Reference", class_refs.size() == 1, str(class_refs.size()))
	_check("dotted call reconstructs a member call", member_calls.size() == 1, str(member_calls.size()))
	if class_refs.size() == 1 and member_calls.size() == 1:
		_check("member registered on the reference",
			m.member_owner(member_calls[0]) == class_refs[0], "")
		_check("reference resolved the custom class",
			String(m.nodes[class_refs[0]]["fields"].get("target", "")) == "Test_class", "")
	var out: Dictionary = m.generate()
	_check("round-trip is byte-identical", String(out["text"]) == src,
		"gen: " + String(out["text"]) + " vs src: " + src)
	_check("round-trip has no problems", (out["problems"] as PackedStringArray).is_empty(),
		str(out["problems"]))


# ---- Script-path references ----------------------------------------------------------
func _test_path_ref() -> void:
	print("-- script-path references")
	var m: Model = Model.new()
	var rid: int = m.add_node(Model.Kind.CLASS_REF,
		{"target": FIXTURE_DIR + "/other.gd", "ref": "class"})
	_check("script path resolves to preload", m._class_ref_expr(rid, 0)
		== "preload(\"%s/other.gd\")" % FIXTURE_DIR, m._class_ref_expr(rid, 0))
	var members: Array = ClassReg.get_registry().members_of(FIXTURE_DIR + "/other.gd")
	_check("path members are statics and consts only",
		not _member_of(members, "help", ClassReg.MT_METHOD).is_empty()
		and not _member_of(members, "VERSION", ClassReg.MT_CONSTANT).is_empty()
		, str(members))
	var help: Dictionary = _member_of(members, "help", ClassReg.MT_METHOD)
	_check("path static method needs no target", bool(help["static"]) and not bool(help["needs_target"]), "")
	# static member generation through the preloaded path owner
	var cid: int = m.add_node(Model.Kind.CALL, _member_fields("help", FuncReg.CAT_PROJECT,
		FIXTURE_DIR + "/other.gd", "method", "void", false, "", [], "exec", true))
	var slot: int = m.register_member(rid, cid)
	var eid: int = _entry_with(m, cid)
	_check("path static member registered", slot >= 0 and eid > 0, "")
	var out: Dictionary = m.generate()
	_check("path static call preloads the script",
		String(out["text"]).contains("preload(\"%s/other.gd\").help()" % FIXTURE_DIR), String(out["text"]))

# ---- Stability / input hardening -------------------------------------------------
func _engine_member(m: Model, cls: String, mname: String) -> int:
	var reg: RefCounted = ClassReg.get_registry()
	var rm: Dictionary = reg.find_member(cls, mname)
	if rm.is_empty():
		return -1
	return m.add_node(Model.Kind.CALL, _member_fields(mname, FuncReg.CAT_GODOT_CLASS, cls,
		str(rm["mtype"]), str(rm["ret"]), bool(rm["needs_target"]), str(rm["target_type"]),
		(rm["args"] as Array).duplicate(true), "exec" if str(rm["ret"]) == "void" else "pure",
		bool(rm["static"])))


func _pin_names(m: Model, id: int) -> Array:
	return (m.nodes[id]["data_ins"] as Array).map(func(p: Dictionary) -> String: return String(p["name"]))


func _test_hardening() -> void:
	print("-- hardening: deletion, class fit, input validation, loops")
	# deleting a member removes its slot row on the reference
	var m: Model = Model.new()
	m.build("extends Node\n\nfunc run() -> void:\n\tpass\n")
	var rid: int = m.add_node(Model.Kind.CLASS_REF, {"target": "Node", "ref": "instance", "source": "self"})
	var cid: int = _engine_member(m, "Node", "get_child_count")
	m.register_member(rid, cid)
	_check("member row present", _pin_names(m, rid).has("get_child_count"), str(_pin_names(m, rid)))
	m.remove_node(cid)
	_check("deleting a member drops its slot row", not _pin_names(m, rid).has("get_child_count")
		and _pin_names(m, rid).has("add member"), str(_pin_names(m, rid)))
	# class fit: a Node2D member does not attach to a Control reference
	var ctl: int = m.add_node(Model.Kind.CLASS_REF, {"target": "Control", "ref": "instance", "source": "self"})
	var n2d: int = _engine_member(m, "Node2D", "rotate")
	_check("class-mismatched member is refused", m.register_member(ctl, n2d) == -1, "")
	_check("refusal explains itself in plain words", m.last_reject_reason.contains("Node2D")
		and m.last_reject_reason.contains("Control"), m.last_reject_reason)
	_check("refused member stays unregistered", m.member_owner(n2d) == -1, "")
	# a base-class member fits a subclass reference
	var r2d: int = m.add_node(Model.Kind.CLASS_REF, {"target": "Node2D", "ref": "instance", "source": "self"})
	var nm: int = _engine_member(m, "Node", "get_child_count")
	_check("base member fits a subclass reference", m.register_member(r2d, nm) >= 0, m.last_reject_reason)
	# a refused wire must not unregister the member that sits in the slot
	var other: int = _engine_member(m, "Control", "grab_focus")
	var occupied_slot: int = m._member_pin_slot(r2d, nm) + (0)
	var wr: Dictionary = m.connect_data(other, 0, r2d, occupied_slot)
	_check("mismatched wire into an occupied slot is rejected", wr.has("_rejected"), str(wr))
	_check("occupant survives a refused wire", m.member_owner(nm) == r2d, "")
	# retargeting a reference after registration is reported at generation
	var e: int = -1
	for id: int in m.nodes:
		if int(m.nodes[id]["kind"]) == Model.Kind.ENTRY:
			e = id
	var rot: int = _engine_member(m, "Node2D", "rotate")
	m.register_member(r2d, rot)
	m.connect_exec(e, 0, rot)
	m.set_class_ref_prop(r2d, "target", "Control")
	var probs: PackedStringArray = m.generate()["problems"] as PackedStringArray
	var said: bool = false
	for pm: String in probs:
		if pm.contains("belongs to Node2D"):
			said = true
	_check("retargeting away from a member's class is reported", said, str(probs))

	# target validation
	var t: int = m.add_node(Model.Kind.CLASS_REF, {"target": "Node", "ref": "class"})
	for bad: String in ["Not A Class", "Foo\nbar()", "a;b", "123abc", "Node.free()", "res://x.txt"]:
		_check("target %s refused" % JSON.stringify(bad), not m.set_class_ref_prop(t, "target", bad)
			and m.last_reject_reason != "", m.last_reject_reason)
	_check("refused target keeps the previous one", String(m.nodes[t]["fields"]["target"]) == "Node", "")
	_check("valid class name accepted", m.set_class_ref_prop(t, "target", "Node2D") and m.last_reject_reason == "", m.last_reject_reason)
	_check("inner class path accepted", m.set_class_ref_prop(t, "target", "Outer.Inner"), m.last_reject_reason)
	_check("unknown class is applied with a hint", m.last_reject_reason.contains("not a class"), m.last_reject_reason)
	_check("script path accepted", m.set_class_ref_prop(t, "target", "res://player.gd"), m.last_reject_reason)
	# instance source validation
	m.set_class_ref_prop(t, "target", "Node")
	m.set_class_ref_prop(t, "ref", "instance")
	_check("multi-line source refused", not m.set_class_ref_prop(t, "source", "x\nOS.kill(1)"), "")
	_check("statement-chaining source refused", not m.set_class_ref_prop(t, "source", "a; b"), "")
	_check("unbalanced source refused", not m.set_class_ref_prop(t, "source", "foo(1"), "")
	_check("normal source accepted", m.set_class_ref_prop(t, "source", "get_node(\"Player\")"), m.last_reject_reason)

	# loops: a member feeding its own reference's instance input
	var rl: int = m.add_node(Model.Kind.CLASS_REF, {"target": "Node", "ref": "instance", "source": "self"})
	var gp: int = _engine_member(m, "Node", "get_parent")
	m.register_member(rl, gp)
	var loop: Dictionary = m.connect_data(gp, 1, rl, 0)
	_check("member -> own reference instance is a refused loop", loop.has("_rejected")
		and m.last_reject_reason.contains("loop"), m.last_reject_reason)
	# registering a member the reference already depends on is refused
	var rl2: int = m.add_node(Model.Kind.CLASS_REF, {"target": "Node", "ref": "instance", "source": "self"})
	var gp2: int = _engine_member(m, "Node", "get_parent")
	_check("wire member -> other ref is fine", not m.connect_data(gp2, 1, rl2, 0).has("_rejected"), m.last_reject_reason)
	_check("registering the member the reference depends on is refused", m.register_member(rl2, gp2) == -1
		and m.last_reject_reason.contains("loop"), m.last_reject_reason)
	# plain function calls cannot be registered as members
	var plain: int = m.add_node(Model.Kind.CALL, {"call": "my_func"})
	_check("plain call is not a member", m.register_member(rl, plain) == -1, "")
