@tool
extends RefCounted
## File access used by the workspace's save system.
##
## Writes are atomic: the text goes to a sibling temp file first, is read back
## and compared, and only then replaces the real .gd file. A crash, a full disk
## or a failed write therefore never leaves a half-written script behind. If the
## temp-file route is not possible (read-only directory for new files, rename
## refused), the text is written straight to the target instead.

const TMP_SUFFIX: String = ".gdcanvas.tmp"


## Reads a text file. Returns "" when the file is missing or unreadable; use
## file_exists() / read_error() when that distinction matters.
static func read_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path)


## Writes `text` to `path` atomically and verifies the result on disk.
## Returns OK, or the Error that stopped the write.
static func write_text(path: String, text: String) -> Error:
	var tmp: String = path + TMP_SUFFIX
	var f: FileAccess = FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return _write_direct(path, text)
	f.store_string(text)
	var werr: Error = f.get_error()
	f.close()
	f = null
	if werr != OK or FileAccess.get_file_as_string(tmp) != text:
		DirAccess.remove_absolute(tmp)
		return _write_direct(path, text)
	var rerr: Error = DirAccess.rename_absolute(tmp, path)
	if rerr != OK:
		DirAccess.remove_absolute(tmp)
		return _write_direct(path, text)
	if FileAccess.get_file_as_string(path) != text:
		return ERR_FILE_CORRUPT
	return OK


static func _write_direct(path: String, text: String) -> Error:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(text)
	var werr: Error = f.get_error()
	f.close()
	f = null
	if werr != OK:
		return werr
	if FileAccess.get_file_as_string(path) != text:
		return ERR_FILE_CORRUPT
	return OK
