extends SceneTree
## Headless checks for the enum / dictionary form editors (text logic + forms).
##   godot --headless --path <project> -s res://addons/gd_canvas_spikes/collection_tests_cli.gd

const T = preload("res://addons/gd_canvas_spikes/collection_text.gd")
const Ed = preload("res://addons/gd_canvas_spikes/collection_editor.gd")

var _pass: int = 0
var _fail: int = 0


func _check(ok: bool, what: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		print("FAIL: ", what)


func _init() -> void:
	# ---- enums
	var e: Dictionary = T.parse_enum("enum Phase { IDLE, PRIMING, CRITICAL, COOLDOWN }")
	_check(bool(e["ok"]) and e["name"] == "Phase" and (e["members"] as Array).size() == 4, "parse one-line enum")
	var built: String = T.build_enum("Phase", e["members"])
	_check(built == "enum Phase {\n\tIDLE,\n\tPRIMING,\n\tCRITICAL,\n\tCOOLDOWN,\n}", "build multi-line enum")
	var again: Dictionary = T.parse_enum(built)
	_check(bool(again["ok"]) and T.build_enum(again["name"], again["members"]) == built, "enum round trip")
	var ev: Dictionary = T.parse_enum("enum Flags { A = 1, B = 1 << 1, C }")
	_check(bool(ev["ok"]) and ev["members"][1]["value"] == "1 << 1", "enum keeps expression values")
	_check(T.enum_numbers(ev["members"]) == PackedStringArray(["1", "", ""]), "numbers after an expression are unknown")
	_check(T.enum_numbers([{"name": "A", "value": ""}, {"name": "B", "value": "5"}, {"name": "C", "value": ""}]) == PackedStringArray(["0", "5", "6"]), "auto numbering")
	_check(not bool(T.parse_enum("enum P { A, # note\n B }")["ok"]), "enum with comment falls back to code view")
	_check(not bool(T.parse_enum("class Foo:\n\tpass")["ok"]), "non-enum is not parsed")
	_check(bool(T.parse_enum("enum { A, B }")["ok"]), "anonymous enum parses")
	_check(T.member_name("my value") == "MY_VALUE" and T.member_name("myValue") == "MY_VALUE" and T.member_name("IDLE") == "IDLE", "member names")
	_check(T.member_name("3d mode") == "_3D_MODE", "leading digit is made valid")
	_check(T.enum_name("my phase") == "MyPhase", "enum name from words")
	_check(T.unique_name("NewEnum", ["NewEnum", "NewEnum2"]) == "NewEnum3", "unique enum name")
	_check(T.clean_enum_value("1, 2}") == "12", "enum value is cleaned")

	# ---- dictionaries
	_check(T.build_dict([]) == "{}", "empty dict")
	var d: Dictionary = T.parse_dict("{\"name\": \"Bob\", \"hp\": 10, \"alive\": true, \"pos\": Vector2(1, 2)}")
	_check(bool(d["ok"]) and (d["entries"] as Array).size() == 4, "parse mixed dict")
	_check(d["entries"][0]["vt"] == T.T_TEXT and d["entries"][1]["vt"] == T.T_NUM and d["entries"][2]["vt"] == T.T_BOOL and d["entries"][3]["vt"] == T.T_CODE, "value kinds")
	_check(T.build_dict(d["entries"]) == "{\"name\": \"Bob\", \"hp\": 10, \"alive\": true, \"pos\": Vector2(1, 2)}", "dict round trip")
	var lua: Dictionary = T.parse_dict("{ a = 1, b = 2 }")
	_check(bool(lua["ok"]) and T.build_dict(lua["entries"]) == "{\"a\": 1, \"b\": 2}", "lua-style dict")
	_check(not bool(T.parse_dict("my_dict")["ok"]), "variable name is not a literal")
	_check(not bool(T.parse_dict("{\"a\": 1 # c\n}")["ok"]), "comment keeps raw mode")
	_check(T.value_source(T.T_TEXT, "say \"hi\"") == "\"say \\\"hi\\\"\"", "text is escaped")
	var q: Dictionary = T.parse_dict("{\"a\": \"line\\nbreak\"}")
	_check(bool(q["ok"]) and q["entries"][0]["vt"] == T.T_CODE and T.build_dict(q["entries"]) == "{\"a\": \"line\\nbreak\"}", "unknown escapes stay untouched")
	var nest: Dictionary = T.parse_dict("{\"a\": {\"b\": [1, 2]}, Phase.IDLE: 3}")
	_check(bool(nest["ok"]) and T.build_dict(nest["entries"]) == "{\"a\": {\"b\": [1, 2]}, Phase.IDLE: 3}", "nested values and enum keys")
	_check(T.duplicate_keys([{"kt": 0, "k": "a", "vt": 1, "v": "1"}, {"kt": 0, "k": "a", "vt": 1, "v": "2"}]).has("\"a\""), "duplicate key detected")

	# ---- arrays
	_check(T.build_array([]) == "[]", "empty array")
	var ar: Dictionary = T.parse_array("[1, \"two\", true, Vector2(1, 2)]")
	_check(bool(ar["ok"]) and (ar["items"] as Array).size() == 4, "parse mixed array")
	_check(ar["items"][0]["t"] == T.T_NUM and ar["items"][1]["t"] == T.T_TEXT and ar["items"][2]["t"] == T.T_BOOL and ar["items"][3]["t"] == T.T_CODE, "array item kinds")
	_check(T.build_array(ar["items"]) == "[1, \"two\", true, Vector2(1, 2)]", "array round trip")
	_check(bool(T.parse_array("")["ok"]) and bool(T.parse_array("[]")["ok"]), "empty text is an empty array")
	_check(not bool(T.parse_array("my_list")["ok"]), "variable name is not an array literal")
	_check(not bool(T.parse_array("[1, 2][0]")["ok"]), "indexed array is not a plain literal")
	_check(not bool(T.parse_array("[1] + [2]")["ok"]), "joined arrays stay code")
	_check(not bool(T.parse_array("[1, # c\n 2]")["ok"]), "array with a comment stays code")
	_check(not bool(T.parse_array("PackedStringArray([\"a\"])")["ok"]), "packed array constructor stays code")
	var an: Dictionary = T.parse_array("[[1, 2], {\"a\": 3}, \"x, y\"]")
	_check(bool(an["ok"]) and (an["items"] as Array).size() == 3 and T.build_array(an["items"]) == "[[1, 2], {\"a\": 3}, \"x, y\"]", "nested items and commas inside text survive")
	_check(T.build_array(T.parse_array("[1, 2,]")["items"]) == "[1, 2]", "trailing comma is tidied")

	# ---- forms (headless-safe: only builds controls)
	var changes: Array[String] = []
	var ef: Ed.EnumForm = Ed.EnumForm.new()
	ef.setup("enum Phase { IDLE, PRIMING }", ThemeDB.fallback_font, 13, func(b: String) -> void: changes.append(b))
	ef._add_member()
	_check(changes.size() == 1 and changes[0].contains("VALUE_3"), "enum form: add member emits")
	ef._move(2, -1)
	_check(changes.back().find("VALUE_3") < changes.back().find("PRIMING"), "enum form: move up")
	ef._remove(0)
	_check(not changes.back().contains("IDLE"), "enum form: remove")
	ef.free()

	var dchanges: Array[String] = []
	var df: Ed.DictForm = Ed.DictForm.new()
	df.setup("{}", ThemeDB.fallback_font, 13, func(t: String) -> void: dchanges.append(t))
	df._add_entry()
	_check(dchanges.back() == "{\"key1\": \"\"}", "dict form: add entry")
	df._set_text(0, false, "5")
	df._set_kind(0, false, T.T_NUM)
	_check(dchanges.back() == "{\"key1\": 5}", "dict form: switch value to number")
	df._clear()
	_check(dchanges.back() == "{}", "dict form: clear")
	df.free()

	var achanges: Array[String] = []
	var af: Ed.ArrayForm = Ed.ArrayForm.new()
	af.setup("[]", ThemeDB.fallback_font, 13, func(t: String) -> void: achanges.append(t))
	af._add_item()
	_check(achanges.back() == "[\"\"]", "array form: add item")
	af._set_kind(0, T.T_NUM)
	af._add_item()
	_check(achanges.back() == "[0, 0]", "array form: new item copies the last kind")
	af._set_text(1, "7")
	af._move(1, -1)
	_check(achanges.back() == "[7, 0]", "array form: move up")
	af._remove(0)
	_check(achanges.back() == "[0]", "array form: remove")
	af._clear()
	_check(achanges.back() == "[]", "array form: clear")
	af.free()
	var araw: Ed.ArrayForm = Ed.ArrayForm.new()
	araw.setup("get_children()", ThemeDB.fallback_font, 13, func(_t: String) -> void: pass)
	_check(araw._raw_mode, "array form: custom code opens in code mode")
	araw.free()

	print("collection tests: %d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
