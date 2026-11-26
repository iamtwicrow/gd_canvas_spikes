# Runs headless: godot --headless --path <project> -s res://addons/gd_canvas_spikes/drop_tests_cli.gd
extends SceneTree
## Drag-and-drop shortcuts: naming helpers, and the declarations the canvas
## creates for dropped nodes / files (@onready, @export, const preload).

const Canvas = preload("res://addons/gd_canvas_spikes/graph_canvas.gd")
const DropDecls = preload("res://addons/gd_canvas_spikes/drop_decls.gd")

var fails: int = 0


func _check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		print("  ok   ", label)
	else:
		fails += 1
		print("  FAIL ", label, "  ", detail)


func _init() -> void:
	_check("var_name snake_cases", DropDecls.var_name("PlayerSprite") == "player_sprite", DropDecls.var_name("PlayerSprite"))
	_check("var_name fixes invalid chars", DropDecls.var_name("My Node-1") .is_valid_identifier(), DropDecls.var_name("My Node-1"))
	_check("var_name fixes leading digit", DropDecls.var_name("2D").is_valid_identifier(), DropDecls.var_name("2D"))
	_check("const_name is PascalCase", DropDecls.const_name("res://a/player_scene.tscn") == "PlayerScene", DropDecls.const_name("res://a/player_scene.tscn"))
	_check("unique appends a number", DropDecls.unique("a", ["a", "a2"]) == "a3", "")
	_check("plain path uses $Path", DropDecls.node_path_expr("Player/Sprite2D") == "$Player/Sprite2D", "")
	_check("odd path is quoted", DropDecls.node_path_expr("My Node") == "$\"My Node\"", DropDecls.node_path_expr("My Node"))
	_check("preload expr", DropDecls.preload_expr("res://a.png") == "preload(\"res://a.png\")", "")
	_check("unknown file type exports Resource", DropDecls.export_type("") == "Resource", "")
	_check("importer texture exports Texture2D", DropDecls.export_type("CompressedTexture2D") == "Texture2D", DropDecls.export_type("CompressedTexture2D"))

	var c: Canvas = Canvas.new()
	root.add_child(c)
	await process_frame
	await process_frame
	c.build_from_text("extends Node\n")
	await process_frame

	c._spawn_annotated_var("sprite", "Sprite2D", "$Sprite2D", "@onready", Vector2(100, 100))
	c._spawn_annotated_var("marker", "Marker2D", "", "@export", Vector2(100, 200))
	var cid: int = c.spawn_node(c.Model.Kind.CONST_DECL, {"name": "Bullet", "value": DropDecls.preload_expr("res://bullet.tscn")}, Vector2(100, 300))
	await process_frame
	_check("const node created", cid >= 0, "")
	var text: String = String(c.model.generate()["text"])
	_check("@onready var generated", text.contains("@onready var sprite: Sprite2D = $Sprite2D"), text)
	_check("@export var generated", text.contains("@export var marker: Marker2D"), text)
	_check("const preload generated", text.contains("const Bullet = preload(\"res://bullet.tscn\")"), text)
	var ann_nodes: int = 0
	for aid: int in c.model.nodes:
		if int(c.model.nodes[aid]["kind"]) == c.Model.Kind.ANNOTATION:
			ann_nodes += 1
	_check("annotations are wired Annotation nodes, not text rows", ann_nodes == 2 and c.model.ann_links.size() == 2,
		"%d nodes, %d links" % [ann_nodes, c.model.ann_links.size()])
	_check("taken names include new declarations", c._taken_decl_names().has("sprite") and c._taken_decl_names().has("Bullet"),
		str(c._taken_decl_names()))
	_check("canvas accepts node and file drops", c._can_drop_data(Vector2.ZERO, {"type": "nodes"})
		and c._can_drop_data(Vector2.ZERO, {"type": "files"}) and not c._can_drop_data(Vector2.ZERO, {"type": "x"}), "")

	c.queue_free()
	await process_frame
	print("drop tests: %s" % ("PASS" if fails == 0 else "FAIL (%d)" % fails))
	quit(0 if fails == 0 else 1)
