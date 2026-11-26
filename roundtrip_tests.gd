@tool
extends RefCounted
## Parser self-test. Returns a human-readable report; the last line says PASS or FAIL.

const Parser = preload("structure_parser.gd")


static func _cases() -> Array:
	return [
		{
			"name": "basic structure",
			"text": "extends Node\nclass_name Foo\n\nsignal hit(n)\nconst A = 1\nvar x := 2\n\nfunc _ready() -> void:\n\tif x > 1:\n\t\tprint(\"a\")\n\telse:\n\t\tpass\n\treturn\n",
			"kinds": ["EXTENDS", "CLASS_NAME", "BLANK", "SIGNAL", "CONST", "VAR", "BLANK", "FUNC", "IF", "STATEMENT", "ELSE", "PASS", "RETURN", "BLANK"],
			"parents": [-1, -1, -1, -1, -1, -1, -1, -1, 7, 8, 7, 10, 7, -1],
		},
		{
			"name": "brackets, strings, '#' in strings, fake func inside a triple string",
			"text": "var d = {\n\t\"a\": 1,   # not a header\n\t\"b\": \"x # y\",\n}\nvar s = \"\"\"\nfunc fake():\n\"\"\"\nfunc real():\n\tpass",
			"kinds": ["VAR", "VAR", "FUNC", "PASS"],
			"parents": [-1, -1, -1, 2],
		},
		{
			"name": "CRLF line endings",
			"text": "extends Node\r\nfunc f():\r\n\tpass\r\n",
			"kinds": ["EXTENDS", "FUNC", "PASS", "BLANK"],
			"parents": [-1, -1, 1, -1],
		},
		{
			"name": "match with branches",
			"text": "func f(v):\n\tmatch v:\n\t\t1:\n\t\t\tprint(\"one\")\n\t\t_:\n\t\t\tpass",
			"kinds": ["FUNC", "MATCH", "MATCH_BRANCH", "STATEMENT", "MATCH_BRANCH", "PASS"],
			"parents": [-1, 0, 1, 2, 1, 4],
		},
		{
			"name": "comment and blank attachment",
			"text": "func f():\n\tvar a = 1\n\n\t# inner comment\n\ta += 1\n# top comment\n\nfunc g():\n\tpass\n",
			"kinds": ["FUNC", "VAR", "BLANK", "COMMENT", "STATEMENT", "COMMENT", "BLANK", "FUNC", "PASS", "BLANK"],
			"parents": [-1, 0, 0, 0, 0, -1, -1, -1, 7, -1],
		},
		{
			"name": "annotations and backslash continuation",
			"text": "@tool\n@export var speed: float = 1.0\n@export_group(\"A\")\nvar total = 1 + \\\n\t2",
			"kinds": ["ANNOTATION", "VAR", "ANNOTATION", "VAR"],
			"parents": [-1, -1, -1, -1],
		},
		{
			"name": "unbalanced bracket resynchronises",
			"text": "var a = (1 +\nfunc b():\n\tpass",
			"kinds": ["VAR", "FUNC", "PASS"],
			"parents": [-1, -1, 1],
			"diagnostics": 1,
		},
		{
			"name": "multi-line lambda inside a call",
			"text": "func f():\n\tconnect(func():\n\t\tprint(1)\n\t)\n",
			"kinds": ["FUNC", "STATEMENT", "BLANK"],
			"parents": [-1, 0, -1],
		},
		{"name": "empty file", "text": "", "kinds": ["BLANK"], "parents": [-1]},
		{"name": "single newline", "text": "\n", "kinds": ["BLANK"], "parents": [-1]},
		{"name": "escapes and raw strings (round-trip only)", "text": "var a = \"x\\\"y\" # c\nvar b = r\"C:\\\\\"\nvar c = 'it\\'s'\n"},
		{"name": "unicode and mixed indentation (round-trip only)", "text": "func \u00fc():\n    pass\n\t# c\n"},
	]


static func run(fuzz_iterations: int = 300) -> String:
	var out: PackedStringArray = PackedStringArray()
	var failures: int = 0
	var total: int = 0
	var parser: Parser = Parser.new()
	var corpus: PackedStringArray = PackedStringArray()

	for c: Dictionary in _cases():
		total += 1
		var text: String = c["text"]
		corpus.append(text)
		parser.parse(text)
		var problems: PackedStringArray = PackedStringArray()
		if parser.reassemble() != text:
			problems.append("round-trip mismatch")
		problems.append_array(parser.validate())
		if c.has("kinds"):
			var got_kinds: Array = []
			var got_parents: Array = []
			for s: int in parser.segment_count():
				got_kinds.append(parser.kind_name(parser.kind[s]))
				got_parents.append(parser.parent[s])
			if str(got_kinds) != str(c["kinds"]):
				problems.append("kinds: got %s, expected %s" % [str(got_kinds), str(c["kinds"])])
			if str(got_parents) != str(c["parents"]):
				problems.append("parents: got %s, expected %s" % [str(got_parents), str(c["parents"])])
		if c.has("diagnostics") and parser.diagnostics.size() != int(c["diagnostics"]):
			problems.append("diagnostics: got %d, expected %d" % [parser.diagnostics.size(), int(c["diagnostics"])])
		if problems.is_empty():
			out.append("  ok    %s" % c["name"])
		else:
			failures += 1
			out.append("  FAIL  %s" % c["name"])
			for p: String in problems:
				out.append("        - %s" % p)

	# Mutation fuzzing: the parser must never break the round-trip or its invariants.
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 20260101
	var noise: String = "\"'()[]{}#\\:\t \n@\r"
	var fuzz_failures: int = 0
	for it: int in fuzz_iterations:
		var text: String = corpus[rng.randi() % corpus.size()]
		for m: int in rng.randi_range(1, 6):
			var r: int = rng.randi() % 3
			if r == 0 and text.length() > 0:
				var at: int = rng.randi() % text.length()
				text = text.substr(0, at) + text.substr(at + 1)
			elif r == 1:
				var at2: int = rng.randi() % (text.length() + 1)
				text = text.substr(0, at2) + noise[rng.randi() % noise.length()] + text.substr(at2)
			else:
				var ls: PackedStringArray = text.split("\n")
				var li: int = rng.randi() % ls.size()
				ls.insert(li, ls[li])
				text = "\n".join(ls)
		parser.parse(text)
		var errs: PackedStringArray = parser.validate()
		if parser.reassemble() != text or not errs.is_empty():
			fuzz_failures += 1
			if fuzz_failures <= 3:
				out.append("  FAIL  fuzz iteration %d: %s" % [it, text.c_escape()])
				for e: String in errs:
					out.append("        - %s" % e)
	total += 1
	if fuzz_failures > 0:
		failures += 1
	else:
		out.append("  ok    fuzz (%d mutated inputs)" % fuzz_iterations)

	out.append("")
	out.append("%d/%d checks passed -> %s" % [total - failures, total, "PASS" if failures == 0 else "FAIL"])
	return "\n".join(out)
