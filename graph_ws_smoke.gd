# Headless smoke test: godot --headless --path <project> -s res://addons/gd_canvas_spikes/graph_ws_smoke.gd
extends SceneTree
const WS = preload("res://addons/gd_canvas_spikes/graph_workspace.gd")
const Canvas = preload("res://addons/gd_canvas_spikes/graph_canvas.gd")


func _init() -> void:
	var ws: WS = WS.new()
	root.add_child(ws)
	await process_frame
	await process_frame
	await process_frame
	var canvas: Canvas = ws._canvas
	# First show offers the title screen; nothing is auto-loaded.
	print("title screen visible: ", ws.title_screen_visible())
	print("nodes before open (no auto-load): ", canvas.model.node_count())
	ws._do_open(ws._default_script_path())
	print("stats: ", ws._stats.text)
	print("nodes: ", canvas.model.node_count(), " links: ", canvas.model.link_count(), " views: ", canvas.views.size())
	# generate from the loaded default script (structure_parser.gd itself)
	var gen: Dictionary = canvas.generate_code()
	print("generate ok: ", gen["ok"], " unreachable: ", gen["unreachable"], " len: ", gen["code"].length())
	if not gen["ok"]:
		print(gen["code"].left(800))
	# demo script
	ws._load_demo()
	await process_frame
	print("demo nodes: ", canvas.model.node_count(), " links: ", canvas.model.link_count())
	var gen2: Dictionary = canvas.generate_code()
	print("demo generate ok: ", gen2["ok"], " unreachable: ", gen2["unreachable"])
	if not gen2["ok"]:
		print(gen2["code"])
	# add each node kind through the menu path
	for i: int in ws.NODE_MENU.size():
		ws._on_add_node(i)
	print("after add-all nodes: ", canvas.model.node_count())
	var gen3: Dictionary = canvas.generate_code()
	print("post-add generate ok: ", gen3["ok"])
	quit()
