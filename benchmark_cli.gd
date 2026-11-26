extends SceneTree
## Headless runner.
##   godot --headless --path <project> -s res://addons/gd_canvas_spikes/benchmark_cli.gd -- [options] [files...]
## Options:
##   --selftest        run the parser self-test
##   --repeat N        timed parses per file (default 5)
##   --scale N         concatenate each file N times (stress test, default 1)
##   --largest         only benchmark the largest script in res://
## With no files, every .gd under res:// is used (this addon is excluded).

const Benchmark = preload("benchmark.gd")
const Tests = preload("roundtrip_tests.gd")


func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var repeat: int = 5
	var scale: int = 1
	var selftest: bool = false
	var largest: bool = false
	var paths: PackedStringArray = PackedStringArray()
	var i: int = 0
	while i < args.size():
		var a: String = args[i]
		if a == "--selftest":
			selftest = true
		elif a == "--largest":
			largest = true
		elif a == "--repeat" and i + 1 < args.size():
			i += 1
			repeat = maxi(1, int(args[i]))
		elif a == "--scale" and i + 1 < args.size():
			i += 1
			scale = maxi(1, int(args[i]))
		else:
			paths.append(a)
		i += 1

	var exit_code: int = 0
	if selftest:
		var report: String = Tests.run()
		print(report)
		if report.ends_with("FAIL"):
			exit_code = 1
	if not selftest or not paths.is_empty() or largest:
		if paths.is_empty():
			Benchmark.collect_gd_files("res://", paths, "res://addons/gd_canvas_spikes")
		if largest and not paths.is_empty():
			paths = PackedStringArray([Benchmark.largest_file(paths)])
		print(Benchmark.run(paths, repeat, scale))
	quit(exit_code)
