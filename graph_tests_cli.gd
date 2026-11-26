extends SceneTree
## Headless test runner for the node graph.
##   godot --headless --path <project> -s res://addons/gd_canvas_spikes/graph_tests_cli.gd -- --run

const GraphTests = preload("res://addons/gd_canvas_spikes/graph_tests.gd")
const ParserTests = preload("res://addons/gd_canvas_spikes/roundtrip_tests.gd")


func _init() -> void:
	var run_graph: bool = false
	for a: String in OS.get_cmdline_user_args():
		if a == "--run":
			run_graph = true
		elif a == "--all":
			run_graph = true
	var exit_code: int = 0
	if run_graph:
		var report: String = GraphTests.run()
		print(report)
		if report.ends_with("FAIL"):
			exit_code = 1
	else:
		print("Usage: ... graph_tests_cli.gd -- --run")
	quit(exit_code)
