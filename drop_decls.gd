@tool
extends RefCounted
## Pure helpers for the canvas drag-and-drop shortcuts (Scene tree nodes and
## FileSystem files dropped on the graph): identifier naming, `$Path`
## expressions and file-type choice. No editor state is touched here.

## Resource base classes tried (in order) when choosing the type of an
## exported file variable, so a .png exports as Texture2D, not as the
## importer's CompressedTexture2D.
const EXPORT_BASES: Array[String] = ["Texture2D", "AudioStream", "Mesh", "Material",
	"Shape3D", "Shape2D", "Font", "Animation", "PackedScene"]


## snake_case variable name for a scene node / file ("Player Sprite" ->
## "player_sprite"); always a valid identifier.
static func var_name(raw: String) -> String:
	var s: String = raw.strip_edges().to_snake_case()
	var out: String = ""
	for i: int in s.length():
		var ch: String = s[i]
		var ok: bool = (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "_"
		out += ch if ok else "_"
	if out == "":
		out = "node"
	if out[0] >= "0" and out[0] <= "9":
		out = "_" + out
	return out


## PascalCase constant name for a preloaded file ("player_scene.tscn" ->
## "PlayerScene"), matching what the Script editor generates.
static func const_name(file_name: String) -> String:
	var base: String = file_name.get_file().get_basename()
	var s: String = base.to_pascal_case()
	var out: String = ""
	for i: int in s.length():
		var ch: String = s[i]
		var ok: bool = (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") \
			or (ch >= "0" and ch <= "9") or ch == "_"
		out += ch if ok else "_"
	if out == "":
		out = "Resource"
	if out[0] >= "0" and out[0] <= "9":
		out = "_" + out
	return out


## `name`, or `name2`, `name3`, ... when `name` is already in `taken`.
static func unique(base: String, taken: Array) -> String:
	if not taken.has(base):
		return base
	var i: int = 2
	while taken.has("%s%d" % [base, i]):
		i += 1
	return "%s%d" % [base, i]


## `$Player/Sprite2D`, or `$"Player/My Sprite"` when a segment is not a plain
## identifier (spaces, dashes, ...).
static func node_path_expr(rel_path: String) -> String:
	if rel_path == "" or rel_path == ".":
		return "self"
	var plain: bool = true
	for seg: String in rel_path.split("/"):
		if not seg.is_valid_identifier():
			plain = false
			break
	if plain:
		return "$" + rel_path
	return "$\"%s\"" % rel_path.replace("\"", "\\\"")


## `preload("res://a.png")`
static func preload_expr(path: String) -> String:
	return "preload(\"%s\")" % path.replace("\"", "\\\"")


## Type to use for an `@export` of a file whose editor file type is
## `file_type` ("" when unknown).
static func export_type(file_type: String) -> String:
	if file_type == "":
		return "Resource"
	for base: String in EXPORT_BASES:
		if file_type == base or ClassDB.is_parent_class(file_type, base):
			return base
	if ClassDB.class_exists(file_type):
		return file_type
	return "Resource"
