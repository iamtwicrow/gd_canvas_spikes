@tool
extends RefCounted
## Blueprint-style diagnostics for the Visual Script graph (display only).
##
## Collects everything that is wrong with the graph's current GDScript and ties
## it to the node that produced it:
##   * graph-level problems found by the model while generating code
##     (unreachable nodes, scope/annotation/call problems, structural problems),
##   * real GDScript parser / analyzer errors (syntax, type, undeclared names...)
##     captured from a compile check of the generated source and mapped back to
##     a node through the model's generated-line -> node table.
## Nothing here edits the graph or the code: it only reports.
##
## graph_canvas.gd loads this file lazily; a failure here can never break the
## workspace itself.
##
## Analyzer WARNING capture: the engine never sends GDScript warnings to
## Logger (they only go to the debugger, which is not active while editing),
## so warning_check() temporarily promotes the project's warning levels to
## ERROR for one compile; the parser then emits them as parse errors the
## logger records, tagged " (Warning treated as error.)". analyze() is
## therefore a coroutine (it awaits), and callers must await it.

const TypesScript = preload("graph_types.gd")
const SEV_ERROR: String = "error"
const SEV_WARNING: String = "warning"
## How many lines above a reported line are searched when that exact line has
## no owner (blank line between functions, end-of-file errors...).
const LOOKBACK_LINES: int = 3
## The compile check evaluates `static var` initializers and `_static_init()`,
## i.e. runs user code. That is acceptable when the person asks for Generate /
## Save, but not silently on every edit, so the live check skips such scripts.
const STATIC_MARKERS: Array[String] = ["static var", "_static_init"]

var _logger_script: GDScript = null
var _logger_tried: bool = false
var _cache_code: String = ""
var _cache_valid: bool = false
var _cache_result: Dictionary = {}
var _warn_cache_code: String = ""
var _warn_cache_valid: bool = false
var _warn_cache_result: Dictionary = {}
## Guards against two warning passes running at once (their project-setting
## promotion / restore sequences must never interleave).
var _warn_pass_running: bool = false

## Engine tag on a warning the parser was made to emit as a parse error.
const PROMOTED_SUFFIX: String = " (Warning treated as error.)"
const WARN_IGNORED: int = 0
const WARN_ERROR: int = 2


## Main entry. `gen` is the dictionary returned by the model's generate();
## `force_engine` runs the compile check even for scripts with static
## initializers; `valid_ids` is a set of existing node ids.
## Coroutine: awaits the analyzer-warning pass, so always `await analyze(...)`.
## Returns {by_node: {id: [{severity, message, line, source}]}, global: [...],
## errors: int, warnings: int, note: String}.
func analyze(gen: Dictionary, force_engine: bool, valid_ids: Dictionary) -> Dictionary:
	var code: String = String(gen.get("text", ""))
	var line_nodes: PackedInt32Array = gen.get("line_nodes", PackedInt32Array()) as PackedInt32Array
	var by_node: Dictionary = {}
	var global_items: Array[Dictionary] = []
	var note: String = ""

	# 1) problems the graph model found itself
	for v: Variant in (gen.get("diagnostics", []) as Array):
		var d: Dictionary = v as Dictionary
		var nid: int = int(d.get("node", -1))
		_place(by_node, global_items, valid_ids, nid, {
			"severity": str(d.get("severity", SEV_ERROR)),
			"message": str(d.get("message", "")),
			"line": int(d.get("line", -1)),
			"source": "graph",
		})

	# 2) what the GDScript compiler says about the generated code
	if code.strip_edges() != "":
		if force_engine or not _runs_user_code(code):
			var cc: Dictionary = _cached_compile(code, force_engine)
			var engine_items: Array = cc.get("items", []) as Array
			for v: Variant in engine_items:
				var d2: Dictionary = v as Dictionary
				var ln: int = int(d2.get("line", -1))
				var nid2: int = _node_for_line(ln, line_nodes)
				_place(by_node, global_items, valid_ids, nid2, {
					"severity": str(d2.get("severity", SEV_ERROR)),
					"message": str(d2.get("message", "")),
					"line": ln,
					"source": "compiler",
				})
			if not bool(cc.get("ok", true)) and not _has_error(engine_items):
				# the compile failed but no message could be captured: still
				# report it (never hide a failure)
				global_items.append({
					"severity": SEV_ERROR,
					"message": "The generated GDScript does not compile (the engine did not report details; see the Output panel).",
					"line": -1,
					"source": "compiler",
				})
			if bool(cc.get("ok", true)):
				# otherwise-clean code only: a script that does not compile shows
				# its errors first, its warnings once it is fixed
				var wc: Dictionary = await _cached_warning_check(code)
				if bool(wc.get("promoted", false)):
					for v3: Variant in (wc.get("items", []) as Array):
						var d3: Dictionary = v3 as Dictionary
						var ln3: int = int(d3.get("line", -1))
						var nid3: int = _node_for_line(ln3, line_nodes)
						_place(by_node, global_items, valid_ids, nid3, {
							"severity": SEV_WARNING,
							"message": str(d3.get("message", "")),
							"line": ln3,
							"source": "compiler",
						})
		else:
			note = "Live compiler check paused: this script has static variables / _static_init, which would run script code on every edit. Use Save (Ctrl+S) to compile-check it."

	var errors: int = 0
	var warnings: int = 0
	for id: Variant in by_node:
		var arr: Array = by_node[id] as Array
		arr.sort_custom(_severity_first)
		for it: Variant in arr:
			if str((it as Dictionary)["severity"]) == SEV_ERROR:
				errors += 1
			else:
				warnings += 1
	for g: Dictionary in global_items:
		if str(g["severity"]) == SEV_ERROR:
			errors += 1
		else:
			warnings += 1
	return {"by_node": by_node, "global": global_items, "errors": errors,
		"warnings": warnings, "note": note}


## Compiles `code` in a throw-away GDScript while capturing the engine's
## messages. Returns {ok: bool, items: Array[Dictionary], captured: bool}.
func compile_check(code: String) -> Dictionary:
	var items: Array[Dictionary] = []
	var cc: Dictionary = _compile_capture(code, TypesScript.relax_prefix(), items)
	return {"ok": bool(cc["ok"]), "items": items, "captured": bool(cc["captured"])}


## One throw-away compile with a Logger attached (a throw-away GDScript
## reload() only returns an error code; the message and line go to the
## engine's error stream). `prefix` is prepended to the source. Appends every
## captured item to `items`. Returns {ok: bool, captured: bool}.
func _compile_capture(code: String, prefix: String, items: Array[Dictionary]) -> Dictionary:
	var captured: bool = false
	var shift: int = 1 if prefix != "" else 0
	var ls: GDScript = _load_logger_script()
	var logger: RefCounted = null
	if ls != null and OS.has_method("add_logger") and OS.has_method("remove_logger"):
		logger = ls.new() as RefCounted
	if logger != null:
		logger.set("active", true)
		OS.call("add_logger", logger)
		captured = true
	var g: GDScript = GDScript.new()
	g.source_code = prefix + code
	var err: Error = g.reload()
	if logger != null:
		OS.call("remove_logger", logger)
		logger.set("active", false)
		var got: Array = logger.call("take_items") as Array
		for v: Variant in got:
			var item: Dictionary = v as Dictionary
			if shift > 0 and int(item.get("line", -1)) > 0:
				item["line"] = maxi(int(item["line"]) - shift, 1)
			items.append(item)
	return {"ok": err == OK, "captured": captured}


## The GDScript analyzer's warnings (unused variable, integer division,
## shadowing, ...) never reach Logger: the engine sends them to the debugger
## only, and the debugger is not active while editing. The one scriptable way
## to capture them is to temporarily promote every warning level the project
## reports ("debug/gdscript/warnings/*", level WARN) to ERROR for the duration
## of one compile: the parser then emits each warning as a parse error the
## logger records, tagged " (Warning treated as error.)". Levels are restored
## immediately afterwards; nothing is written to disk. A warning the user
## disabled (level IGNORE) stays disabled.
## Coroutine (awaits the engine's deferred settings refresh): `await` this.
## Returns {items: [{severity: "warning", message, line}], promoted: bool,
## busy: bool}.
func warning_check(code: String) -> Dictionary:
	if _warn_pass_running:
		return {"items": [], "promoted": false, "busy": true}
	_warn_pass_running = true
	var saved: Dictionary = {}
	var touched: PackedStringArray = PackedStringArray()
	for wname: String in TypesScript.WARNING_NAMES:
		var path: String = "debug/gdscript/warnings/%s" % wname
		if not ProjectSettings.has_setting(path):
			continue
		var level: int = int(ProjectSettings.get_setting(path))
		if level == WARN_IGNORED:
			continue   # a warning the user disabled stays disabled
		saved[path] = level
		if level != WARN_ERROR:
			ProjectSettings.set_setting(path, WARN_ERROR)
			touched.append(path)
	var out: Array[Dictionary] = []
	var promoted: bool = touched.size() > 0
	if promoted:
		# the engine applies new warning levels through a deferred refresh of
		# its parser caches: give it two frames before the compile
		await _idle_frames(2)
		var items: Array[Dictionary] = []
		# no relax prefix here: @warning_ignore would suppress the warnings
		# this pass is meant to surface (reported lines need no shift)
		var cc: Dictionary = _compile_capture(code, "", items)
		for p: String in touched:
			ProjectSettings.set_setting(p, int(saved[p]))
		await _idle_frames(2)   # same deferred refresh for the restore
		for v: Variant in items:
			var d: Dictionary = v as Dictionary
			var msg: String = str(d.get("message", ""))
			if not msg.ends_with(PROMOTED_SUFFIX):
				continue   # a real error: the normal pass already reports it
			out.append({
				"severity": SEV_WARNING,
				"message": msg.substr(0, msg.length() - PROMOTED_SUFFIX.length()).strip_edges(),
				"line": int(d.get("line", -1)),
			})
	_warn_pass_running = false
	return {"items": out, "promoted": promoted, "busy": false}


## Identical generated code produces identical warnings: reuse the last
## result instead of re-running the promote / compile / restore cycle.
func _cached_warning_check(code: String) -> Dictionary:
	if _warn_cache_valid and _warn_cache_code == code:
		return _warn_cache_result
	var res: Dictionary = await warning_check(code)
	if not bool(res.get("busy", false)):
		_warn_cache_code = code
		_warn_cache_result = res
		_warn_cache_valid = true
	return res


func _idle_frames(n: int) -> void:
	var ml: SceneTree = Engine.get_main_loop() as SceneTree
	for i: int in n:
		if ml == null:
			return
		await ml.process_frame


# ---- internals ----------------------------------------------------------------
## Re-checking identical code would only repeat the same engine messages in
## the Output panel, so the last result is reused unless a fresh check is asked
## for (a fresh compile check, e.g. through Save / Ctrl+S).
func _cached_compile(code: String, fresh: bool) -> Dictionary:
	if not fresh and _cache_valid and _cache_code == code:
		return _cache_result
	var res: Dictionary = compile_check(code)
	# Godot 4.7's GDScript::reload() prints only the FIRST syntax (parse) error
	# per compile, so a broken Code pin surfaces its errors one at a time. When
	# exactly one error was captured, repeat the compile with each reported
	# line temporarily swapped for `pass` to reveal the next one, and so on,
	# so every problem shows at once. The original code is never modified and
	# every revealed error keeps its original line number.
	if not bool(res["ok"]):
		var items: Array = res.get("items", []) as Array
		if items.size() == 1:
			res["items"] = _reveal_parse_errors(code, items)
	_cache_code = code
	_cache_result = res
	_cache_valid = true
	return res


## How many reveal rounds (one throw-away compile each) are run at most.
const REVEAL_MAX_ROUNDS: int = 8


## Repeatedly compiles a scratch copy of `code` with the lines that reported
## an error swapped for `pass`, collecting every further error until the
## scratch parses (then the analyzer's errors are collected too), nothing new
## appears or the round cap is hit. `first_items` (already-reported errors)
## are part of the result, deduplicated by line + message.
func _reveal_parse_errors(code: String, first_items: Array) -> Array:
	var working: PackedStringArray = code.split("\n")
	var all_items: Array = first_items.duplicate(true)
	var seen: Dictionary = {}
	for it: Variant in all_items:
		seen[_item_key(it as Dictionary)] = true
	# neutralize the already-known errors' lines first, so the first round
	# compiles past them and reports the NEXT ones
	for it2: Variant in first_items:
		_neutralize_line(working, it2 as Dictionary)
	for r: int in REVEAL_MAX_ROUNDS:
		var cc: Dictionary = compile_check("\n".join(working))
		var added: bool = false
		var to_clear: PackedInt32Array = PackedInt32Array()
		for v: Variant in (cc.get("items", []) as Array):
			var d: Dictionary = v as Dictionary
			var key: String = _item_key(d)
			if seen.has(key):
				continue
			seen[key] = true
			all_items.append(d)
			added = true
			to_clear.append_array(_neutralize_line(working, d))
		# the scratch parses now: the analyzer has reported everything it can
		# (it never holds messages back), so stop here
		if bool(cc.get("ok", true)) or not added or to_clear.is_empty():
			break
	return all_items


## Swaps one statement line of the scratch copy for `pass` (keeping the
## indentation) so its reported error stops masking the following ones.
## Returns the scratch index that was swapped ([] when nothing was swapped).
func _neutralize_line(working: PackedStringArray, d: Dictionary) -> PackedInt32Array:
	var ln: int = int(d.get("line", -1))
	if ln <= 0 or ln > working.size():
		return PackedInt32Array()
	var line: String = working[ln - 1]
	if line.strip_edges() == "" or line.strip_edges() == "pass":
		return PackedInt32Array()
	var indent: String = line.substr(0, line.length() - line.strip_edges(true, false).length())
	working[ln - 1] = indent + "pass"
	return PackedInt32Array([ln - 1])


func _item_key(d: Dictionary) -> String:
	return "%d|%s" % [int(d.get("line", -1)), str(d.get("message", ""))]


func _runs_user_code(code: String) -> bool:
	for marker: String in STATIC_MARKERS:
		if code.contains(marker):
			return true
	return false


func _has_error(items: Array) -> bool:
	for v: Variant in items:
		if str((v as Dictionary).get("severity", SEV_ERROR)) == SEV_ERROR:
			return true
	return false


func _load_logger_script() -> GDScript:
	if _logger_tried:
		return _logger_script
	_logger_tried = true
	var me: Script = get_script() as Script
	if me == null or me.resource_path == "":
		return null
	var path: String = me.resource_path.get_base_dir().path_join("diagnostics_logger.gd")
	var gs: GDScript = ResourceLoader.load(path) as GDScript
	if gs != null and gs.can_instantiate():
		_logger_script = gs
	return _logger_script


## Owner node of a generated line (1-based); -1 when unknown. A line without an
## owner (blank separator, end of file) falls back to the closest owned line
## just above it.
func _node_for_line(line: int, line_nodes: PackedInt32Array) -> int:
	if line <= 0 or line_nodes.is_empty():
		return -1
	var idx: int = mini(line, line_nodes.size()) - 1
	if line > line_nodes.size() + LOOKBACK_LINES:
		return -1
	for step: int in LOOKBACK_LINES + 1:
		var i: int = idx - step
		if i < 0:
			break
		if line_nodes[i] >= 0:
			return line_nodes[i]
	return -1


func _place(by_node: Dictionary, global_items: Array[Dictionary], valid_ids: Dictionary,
		node_id: int, item: Dictionary) -> void:
	if node_id >= 0 and valid_ids.has(node_id):
		if not by_node.has(node_id):
			by_node[node_id] = []
		var arr: Array = by_node[node_id] as Array
		for e: Variant in arr:
			var ed: Dictionary = e as Dictionary
			if str(ed["message"]) == str(item["message"]) and int(ed["line"]) == int(item["line"]):
				return
		arr.append(item)
	else:
		global_items.append(item)


func _severity_first(a: Variant, b: Variant) -> bool:
	var ae: bool = str((a as Dictionary)["severity"]) == SEV_ERROR
	var be: bool = str((b as Dictionary)["severity"]) == SEV_ERROR
	return ae and not be
