@tool
extends Control
## Zoom/pan canvas of real CodeEdit blocks built from a .gd file (spike).
## Layout here is a simple masonry grid, NOT the real layout algorithm.
## Nothing is persisted; block positions are session-only.

const Parser = preload("structure_parser.gd")
const Block = preload("spike_block.gd")

signal stats_changed(total: int, live: int, in_view: int)
signal sweep_finished(report: String)

const COL_W: float = 620.0
const GAP: float = 28.0

var world: Control = Control.new()
var zoom: float = 1.0
var virtualize: bool = true
var lod_enabled: bool = true
var lod_threshold: float = 0.35
var crisp: bool = false
var blocks: Array[Block] = []

var _font: Font
var _font_size: int = 14
var _dirty: bool = true
var _settled_zoom: float = 1.0
var _crisp_timer: Timer = Timer.new()
var _bg_pan: bool = false
var _mid_pan: bool = false
var _sweeping: bool = false
var _saved_low_proc: bool = false


func _ready() -> void:
	clip_contents = true
	world.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(world)
	_crisp_timer.one_shot = true
	_crisp_timer.wait_time = 0.2
	_crisp_timer.timeout.connect(apply_crisp_now)
	add_child(_crisp_timer)
	resized.connect(request_refresh)


func _exit_tree() -> void:
	if _sweeping:
		OS.low_processor_usage_mode = _saved_low_proc


# ---- Building ----------------------------------------------------------------
func build(text: String, copies: int) -> void:
	for b: Block in blocks:
		b.queue_free()
	blocks.clear()

	var parser: Parser = Parser.new()
	parser.parse(text)
	var tops: Array = parser.top_level_blocks()
	_font = _code_font()
	_font_size = _code_font_size()
	var line_h: float = _font.get_height(_font_size) + 4.0
	var total: int = tops.size() * copies
	var cols: int = clampi(int(ceil(sqrt(float(maxi(total, 1))))), 3, 40)
	var col_y: Array[float] = []
	for c: int in cols:
		col_y.append(0.0)

	for copy_i: int in copies:
		for t: Dictionary in tops:
			var first: int = t["first"]
			var last: int = t["last"]
			var block_lines: PackedStringArray = parser.lines.slice(first, last + 1)
			var max_w: float = 0.0
			var bars: PackedFloat32Array = PackedFloat32Array()
			for li: int in block_lines.size():
				var ln: String = block_lines[li]
				if li < 200:
					max_w = maxf(max_w, _font.get_string_size(ln.replace("\t", "    "), HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size).x)
				if li < 16:
					bars.append(clampf(float(ln.length()) / 80.0, 0.0, 1.0))
			var cw: float = clampf(max_w + 56.0, 260.0, COL_W - Block.PAD * 2.0)
			var ch: float = clampf(float(block_lines.size()) * line_h + 10.0, 60.0, 520.0)
			var title: String = "%s %s" % [parser.kind_name(int(t["kind"])).to_lower(), str(t["name"])]
			if copies > 1:
				title += "  #%d" % (copy_i + 1)
			var b: Block = Block.new()
			b.setup(title.strip_edges(), parser.text_of(first, last), Vector2(cw, ch), _font, _font_size, bars)
			var col: int = _shortest(col_y)
			b.position = Vector2(float(col) * (COL_W + GAP), col_y[col])
			col_y[col] += b.size.y + GAP
			world.add_child(b)
			blocks.append(b)
	fit()


func _shortest(col_y: Array[float]) -> int:
	var best: int = 0
	for i: int in col_y.size():
		if col_y[i] < col_y[best]:
			best = i
	return best


func _code_font() -> Font:
	if Engine.is_editor_hint():
		var th: Theme = EditorInterface.get_editor_theme()
		if th != null and th.has_font("source", "EditorFonts"):
			return th.get_font("source", "EditorFonts")
	return ThemeDB.fallback_font


func _code_font_size() -> int:
	if Engine.is_editor_hint():
		var th: Theme = EditorInterface.get_editor_theme()
		if th != null and th.has_font_size("source_size", "EditorFonts"):
			return th.get_font_size("source_size", "EditorFonts")
	return 14


# ---- View control ----------------------------------------------------------------
func set_zoom_at(new_zoom: float, anchor: Vector2) -> void:
	new_zoom = clampf(new_zoom, 0.1, 4.0)
	var w: Vector2 = (anchor - world.position) / zoom
	zoom = new_zoom
	world.scale = Vector2(zoom, zoom)
	world.position = anchor - w * zoom
	_view_changed()


func fit() -> void:
	if blocks.is_empty() or size.x < 10.0:
		return
	var bounds: Rect2 = Rect2()
	var first: bool = true
	for b: Block in blocks:
		var r: Rect2 = Rect2(b.position, b.size)
		bounds = r if first else bounds.merge(r)
		first = false
	var z: float = clampf(minf(size.x / bounds.size.x, size.y / bounds.size.y) * 0.95, 0.1, 4.0)
	zoom = z
	world.scale = Vector2(z, z)
	world.position = size * 0.5 - bounds.get_center() * z
	_view_changed()


func request_refresh() -> void:
	_dirty = true
	queue_redraw()


func _view_changed() -> void:
	_dirty = true
	queue_redraw()
	_crisp_timer.start()


func apply_crisp_now() -> void:
	_settled_zoom = zoom
	for b: Block in blocks:
		b.apply_crisp(zoom, crisp)


func _process(_delta: float) -> void:
	if _dirty:
		_dirty = false
		_refresh_detail()


## Realises/frees CodeEdits according to visibility, LOD and the virtualise switch.
func _refresh_detail() -> void:
	var view: Rect2 = Rect2(-world.position / zoom, size / zoom).grow(300.0 / zoom)
	var lod_off: bool = lod_enabled and zoom < lod_threshold
	var live: int = 0
	var in_view: int = 0
	for b: Block in blocks:
		var visible_now: bool = Rect2(b.position, b.size).intersects(view)
		if visible_now:
			in_view += 1
		b.visible = visible_now or not virtualize
		var want: bool = (visible_now or not virtualize) and not lod_off
		var had: bool = b.code != null
		b.set_detail(want)
		if want and not had and crisp:
			b.apply_crisp(_settled_zoom, true)
		if b.code != null:
			live += 1
	stats_changed.emit(blocks.size(), live, in_view)


# ---- Input ----------------------------------------------------------------------------
func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	var inside: bool = Rect2(Vector2.ZERO, size).has_point(get_local_mouse_position())
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			if mb.pressed and inside:
				_mid_pan = true
				get_viewport().set_input_as_handled()
			elif not mb.pressed:
				_mid_pan = false
			return
		var wheel_up: bool = mb.button_index == MOUSE_BUTTON_WHEEL_UP
		var wheel_down: bool = mb.button_index == MOUSE_BUTTON_WHEEL_DOWN
		if inside and mb.pressed and (wheel_up or wheel_down):
			if mb.ctrl_pressed or mb.meta_pressed:
				set_zoom_at(zoom * (1.1 if wheel_up else 1.0 / 1.1), get_local_mouse_position())
				get_viewport().set_input_as_handled()
			else:
				var hovered: Control = get_viewport().gui_get_hovered_control()
				var over_background: bool = hovered == self or (hovered != null and is_ancestor_of(hovered) and not hovered is TextEdit)
				if over_background:
					world.position.y += 90.0 if wheel_up else -90.0
					_view_changed()
					get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _mid_pan:
		world.position += (event as InputEventMouseMotion).relative
		_view_changed()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_bg_pan = (event as InputEventMouseButton).pressed
	elif event is InputEventMouseMotion and _bg_pan:
		world.position += (event as InputEventMouseMotion).relative
		_view_changed()


# ---- Drawing -----------------------------------------------------------------------------
func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("#16171b"))
	var step: float = 40.0 * zoom
	while step < 14.0:
		step *= 2.0
	var ox: float = fposmod(world.position.x, step)
	var oy: float = fposmod(world.position.y, step)
	var x: float = ox
	while x < size.x:
		var y: float = oy
		while y < size.y:
			draw_rect(Rect2(x - 1.0, y - 1.0, 2.0, 2.0), Color(1, 1, 1, 0.07))
			y += step
		x += step


# ---- Automated measurement ---------------------------------------------------------------------
## Steps through zoom levels while panning continuously, recording frame times.
func run_sweep() -> void:
	if _sweeping or blocks.is_empty():
		return
	_sweeping = true
	_saved_low_proc = OS.low_processor_usage_mode
	OS.low_processor_usage_mode = false  # the editor normally only redraws on demand
	fit()
	var rows: PackedStringArray = PackedStringArray()
	rows.append("zoom".lpad(6) + "frames".lpad(8) + "avg ms".lpad(9) + "avg fps".lpad(9) + "p95 ms".lpad(9) + "worst ms".lpad(10) + "live CodeEdit".lpad(15) + "in view".lpad(9))
	var center: Vector2 = size * 0.5
	for z: float in [0.25, 0.5, 1.0, 2.0, 3.0]:
		set_zoom_at(z, center)
		await get_tree().create_timer(0.6).timeout
		var times: Array[float] = []
		var t0: int = Time.get_ticks_usec()
		var last: int = t0
		var phase: float = 0.0
		while Time.get_ticks_usec() - t0 < 1500000:
			await get_tree().process_frame
			var now: int = Time.get_ticks_usec()
			times.append(float(now - last) / 1000.0)
			last = now
			phase += 0.1
			world.position.x += sin(phase) * 6.0  # keep panning so every frame has real work
			_view_changed()
		times.sort()
		var sum: float = 0.0
		for v: float in times:
			sum += v
		var avg: float = sum / float(maxi(times.size(), 1))
		var p95: float = times[mini(times.size() - 1, int(float(times.size()) * 0.95))]
		var live: int = 0
		var in_view: int = 0
		for b: Block in blocks:
			if b.code != null:
				live += 1
			if b.visible:
				in_view += 1
		rows.append(("%d%%" % roundi(z * 100.0)).lpad(6) + str(times.size()).lpad(8) + String.num(avg, 2).lpad(9)
			+ String.num(1000.0 / maxf(avg, 0.001), 0).lpad(9) + String.num(p95, 2).lpad(9)
			+ String.num(times[times.size() - 1], 1).lpad(10) + str(live).lpad(15) + str(in_view).lpad(9))
	OS.low_processor_usage_mode = _saved_low_proc
	_sweeping = false
	var header: PackedStringArray = PackedStringArray()
	header.append("GD Canvas zoom-spike sweep")
	header.append("Godot %s | %s | %s" % [Engine.get_version_info().get("string", "?"), OS.get_name(), RenderingServer.get_video_adapter_name()])
	header.append("blocks=%d virtualize=%s LOD=%s (<%d%%) crisp=%s" % [blocks.size(), str(virtualize), str(lod_enabled), roundi(lod_threshold * 100.0), str(crisp)])
	header.append("")
	var report: String = "\n".join(header) + "\n" + "\n".join(rows)
	print(report)
	sweep_finished.emit(report)
