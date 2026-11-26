@tool
extends Logger
## Captures the script errors/warnings the engine raises while a throw-away
## GDScript is compiled (GDScript.reload() only returns an error code; the
## actual message and line go to the engine's error stream).
##
## Kept in its own file and loaded lazily by graph_diagnostics.gd: if this
## class cannot be compiled on some engine build, the Visual Script workspace
## keeps working and only the engine-side messages are unavailable.
## Registered with OS.add_logger() only for the duration of one compile check;
## `active` additionally gates what is recorded.

## (ERROR_TYPE_WARNING / ERROR_TYPE_SCRIPT are inherited from Logger itself.)
const PREFIXES: Array[String] = ["Parse Error: ", "Compile Error: ", "Parser Error: "]

var active: bool = false
var _items: Array[Dictionary] = []
var _mutex: Mutex = Mutex.new()


func _log_error(function: String, _file: String, line: int, code: String, rationale: String,
		_editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
	if not active:
		return
	# only GDScript compiler output; unrelated engine errors are ignored
	if error_type != ERROR_TYPE_SCRIPT and not function.begins_with("GDScript"):
		return
	var msg: String = rationale.strip_edges()
	if msg == "":
		msg = code.strip_edges()
	if msg == "":
		return
	for prefix: String in PREFIXES:
		if msg.begins_with(prefix):
			msg = msg.substr(prefix.length()).strip_edges()
			break
	_mutex.lock()
	_items.append({
		"line": line,
		"severity": "warning" if error_type == ERROR_TYPE_WARNING else "error",
		"message": msg,
	})
	_mutex.unlock()


## Returns everything captured so far and clears the buffer.
func take_items() -> Array[Dictionary]:
	_mutex.lock()
	var out: Array[Dictionary] = _items.duplicate()
	_items.clear()
	_mutex.unlock()
	return out
