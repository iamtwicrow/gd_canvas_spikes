@tool
extends RefCounted
## Parser benchmark. Parses real .gd files repeatedly and reports timing.

const Parser = preload("structure_parser.gd")


static func collect_gd_files(dir_path: String, out: PackedStringArray, exclude: String = "") -> void:
	var da: DirAccess = DirAccess.open(dir_path)
	if da == null:
		return
	da.list_dir_begin()
	var entry: String = da.get_next()
	while entry != "":
		if not entry.begins_with("."):
			var full: String = dir_path.path_join(entry)
			if da.current_is_dir():
				if exclude.is_empty() or not full.begins_with(exclude):
					collect_gd_files(full, out, exclude)
			elif entry.ends_with(".gd"):
				out.append(full)
		entry = da.get_next()
	da.list_dir_end()


## Returns the path of the file with the most characters (or "" if none).
static func largest_file(paths: PackedStringArray) -> String:
	var best: String = ""
	var best_len: int = -1
	for p: String in paths:
		var l: int = FileAccess.get_file_as_string(p).length()
		if l > best_len:
			best_len = l
			best = p
	return best


## `repeat`: timed parses per file (after one warm-up).
## `scale`: concatenate each file this many times to simulate huge scripts.
static func run(paths: PackedStringArray, repeat: int = 5, scale: int = 1) -> String:
	var out: PackedStringArray = PackedStringArray()
	out.append("GD Canvas parser benchmark")
	out.append("Godot %s | %s | GPU/OS: %s | repeat=%d scale=x%d" % [
		Engine.get_version_info().get("string", "?"), OS.get_name(),
		RenderingServer.get_video_adapter_name() if not DisplayServer.get_name() == "headless" else "headless",
		repeat, scale])
	out.append("")
	out.append("file".rpad(34) + "lines".lpad(8) + "segs".lpad(8) + "median ms".lpad(11) + "ms/1k lines".lpad(13) + "  checks")

	var parser: Parser = Parser.new()
	var total_lines: int = 0
	var total_ms: float = 0.0
	var bad: PackedStringArray = PackedStringArray()
	var files: int = 0

	for path: String in paths:
		var text: String = FileAccess.get_file_as_string(path)
		if text.is_empty():
			continue
		if scale > 1:
			if not text.ends_with("\n"):
				text += "\n"
			text = text.repeat(scale)
		parser.parse(text)  # warm-up
		var times: Array[float] = []
		for r: int in repeat:
			var t0: int = Time.get_ticks_usec()
			parser.parse(text)
			times.append((Time.get_ticks_usec() - t0) / 1000.0)
		times.sort()
		var med: float = times[times.size() >> 1]
		var n_lines: int = parser.lines.size()
		var checks: String = "ok"
		if parser.reassemble() != text:
			checks = "ROUND-TRIP MISMATCH"
			bad.append(path)
		var errs: PackedStringArray = parser.validate()
		if not errs.is_empty():
			checks = "INVARIANT: " + errs[0]
			bad.append(path)
		var per_k: float = med / (float(n_lines) / 1000.0) if n_lines > 0 else 0.0
		out.append(path.get_file().rpad(34) + str(n_lines).lpad(8) + str(parser.segment_count()).lpad(8)
			+ String.num(med, 2).lpad(11) + String.num(per_k, 2).lpad(13) + "  " + checks)
		if not parser.diagnostics.is_empty():
			out.append("    diagnostics: " + "; ".join(parser.diagnostics.slice(0, 2)))
		total_lines += n_lines
		total_ms += med
		files += 1

	out.append("")
	out.append("files: %d | total lines: %d | total median parse time: %s ms" % [files, total_lines, String.num(total_ms, 1)])
	if total_ms > 0.0:
		out.append("overall throughput: %s lines/ms" % String.num(float(total_lines) / total_ms, 1))
	out.append("round-trip / invariant failures: %d" % bad.size())
	return "\n".join(out)
