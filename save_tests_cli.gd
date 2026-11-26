# Runs headless: godot --headless --path <project> -s res://addons/gd_canvas_spikes/save_tests_cli.gd
extends SceneTree
## Headless test of the save system: atomic writes, automatic write on the
## editor's save hooks, skip-instead-of-clobber on external changes, and
## reloading a clean graph when the file changed on disk.

const ScriptIO = preload("res://addons/gd_canvas_spikes/script_io.gd")
const Workspace = preload("res://addons/gd_canvas_spikes/graph_workspace.gd")

var fails: int = 0


func _check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		print("  ok   ", label)
	else:
		fails += 1
		print("  FAIL ", label, "  ", detail)


func _write(path: String, text: String) -> void:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _init() -> void:
	# --- ScriptIO ------------------------------------------------------------
	var p: String = "user://save_io_test.gd"
	_check("write_text creates a file", ScriptIO.write_text(p, "extends Node\n") == OK, "")
	_check("write_text content is exact", ScriptIO.read_text(p) == "extends Node\n", ScriptIO.read_text(p))
	_check("write_text replaces existing content", ScriptIO.write_text(p, "extends Node2D\n\n\tx\n") == OK
		and ScriptIO.read_text(p) == "extends Node2D\n\n\tx\n", "")
	_check("no temp file left behind", not FileAccess.file_exists(p + ScriptIO.TMP_SUFFIX), "")
	_check("write_text reports an unwritable path",
		ScriptIO.write_text("user://no_such_dir_xyz/a.gd", "x") != OK, "")
	_check("read_text of a missing file is empty", ScriptIO.read_text("user://missing_file_xyz.gd") == "", "")
	DirAccess.remove_absolute(p)

	# --- workspace save flow -------------------------------------------------
	var ws: Control = Workspace.new()
	root.add_child(ws)
	await process_frame
	await process_frame
	var path: String = "user://save_flow_test.gd"
	_write(path, "extends Node\n\nfunc f() -> void:\n\tprint(1)\n")
	ws._do_open(path)
	_check("opened clean", ws._loaded_path == path and not ws._dirty, ws._loaded_path)

	# editor save hook with a clean graph: nothing to do, file untouched
	var before: String = ScriptIO.read_text(path)
	ws.save_if_dirty()
	await process_frame
	_check("hook on a clean graph leaves the file alone", ScriptIO.read_text(path) == before, "")

	# an edit, then the editor's save hook writes the .gd automatically
	ws._canvas.spawn_node(ws._canvas.Model.Kind.PRINT, {}, Vector2(500, 50))
	await process_frame
	_check("edit marks dirty", ws._dirty, "")
	ws.save_if_dirty()
	for i: int in 10:
		await process_frame
	_check("hook clears dirty", not ws._dirty, "")
	_check("hook wrote the generated script", ScriptIO.read_text(path) == ws._loaded_text
		and ScriptIO.read_text(path).contains("print(1)"), ScriptIO.read_text(path))
	_check("status reports the save", String(ws._stats.text).begins_with("Saved '"), String(ws._stats.text))

	# external change while dirty: the automatic save must not overwrite it
	ws._dirty = true
	_write(path, "extends Node\n\nvar external_edit := true\n")
	ws.save_if_dirty()
	await process_frame
	_check("automatic save never clobbers an external change",
		ScriptIO.read_text(path).contains("external_edit"), ScriptIO.read_text(path))
	_check("automatic save opens no dialog", _dialogs(ws) == 0, str(_dialogs(ws)))
	_check("skipped save keeps the graph dirty", ws._dirty, "")
	_check("status explains the skip", String(ws._stats.text).contains("Auto-save skipped"), String(ws._stats.text))

	# explicit save asks, and a second request meanwhile does not stack a dialog
	var res: Array = []
	ws._do_save(func(ok: bool) -> void: res.append(ok))
	await process_frame
	ws._do_save(func(ok: bool) -> void: res.append(ok))
	await process_frame
	_check("explicit save asks once", _dialogs(ws) == 1, str(_dialogs(ws)))
	_check("overlapping save is refused", res.size() == 1 and not bool(res[0]), str(res))
	for child: Node in ws.get_children():
		if child is ConfirmationDialog:
			(child as ConfirmationDialog).confirmed.emit()
	for i: int in 10:
		await process_frame
	_check("confirmed overwrite writes the graph", ScriptIO.read_text(path).contains("print(1)")
		and not ScriptIO.read_text(path).contains("external_edit"), ScriptIO.read_text(path))
	_check("confirmed overwrite clears dirty", not ws._dirty, "")

	# clean graph + file changed on disk: sync reloads the new content
	_write(path, "extends Node\n\nfunc g() -> void:\n\tprint(7)\n")
	ws.sync_with_disk()
	await process_frame
	_check("clean graph reloads a changed file", ws._loaded_text.contains("print(7)")
		and String(ws._canvas.model.generate()["text"]).contains("print(7)"), ws._loaded_text)
	_check("reload leaves the graph clean", not ws._dirty, "")

	# dirty graph + file changed on disk: sync keeps the edits
	ws._dirty = true
	var kept: String = ws._loaded_text
	_write(path, "extends Node\n\nfunc h() -> void:\n\tprint(8)\n")
	ws.sync_with_disk()
	_check("dirty graph keeps its edits on sync", ws._dirty and ws._loaded_text == kept, "")

	DirAccess.remove_absolute(path)
	ws.queue_free()
	await process_frame
	print("save tests: %s" % ("PASS" if fails == 0 else "FAIL (%d)" % fails))
	quit(0 if fails == 0 else 1)


func _dialogs(ws: Node) -> int:
	var n: int = 0
	for child: Node in ws.get_children():
		if child is ConfirmationDialog:
			n += 1
	return n
