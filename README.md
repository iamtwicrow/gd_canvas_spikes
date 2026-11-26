# GD Canvas — node-based visual scripting workspace

A Godot 4.7.x editor plugin that adds a **Visual Script** tab to the top
workspace bar (next to 2D / 3D / Script / Game). The tab hosts a
Blueprint-style node graph that is **derived from real GDScript** and can be
**converted back into valid native GDScript**. The workspace follows the
script currently open in the editor and, on save (Ctrl+S / Save, or any
scene / project save), writes the generated GDScript back to the `.gd` file.
Nothing is persisted beyond that.

**Version 1.0.0 — stable.** Covered by headless tests (526 model checks, 496 UI
checks, plus workspace, diagnostics and benchmark suites), verified against
Godot 4.7.2, in normal and strict-typing projects.

## Install
1. Copy this folder to `res://addons/gd_canvas_spikes/` in a Godot 4.7.x project.
2. Project > Project Settings > Plugins > enable **GD Canvas**.
3. A **Visual Script** tab appears in the top workspace bar. The workspace is
   built the first time the tab is opened; the plugin adds nothing at editor
   start-up and nothing to **Project > Tools**. If the workspace fails to
   compile, the tab shows a message and the `Parse Error` line appears in the
   Output panel.

## The node graph (graph_workspace.gd + graph_canvas.gd + graph_node.gd + graph_model.gd)
**Load** parses the script in the path field through the structural parser and
builds a graph of real nodes:

- **Comparisons** (`==`, `!=`, `<`, `>`, `<=`, `>=`): spawned from the
  **Operators** section as ordinary Operator nodes. A comparison Operator
  always has exactly two operand pins (it never grows a third) and its
  result wires into If / Else If condition pins. Generation builds the
  comparison expression (`health > 0`, `name != "cat"`) from its two
  operands and the operator. Loading a script reconstructs comparison
  Operator nodes: a supported comparison condition (`health > 0`,
  `speed >= max_speed`, `score == 100`, `apple != cat`, …) on an If /
  Else If line becomes its own Operator node wired into that node's
  condition input (the expression is not duplicated inside the If).
  A condition that is one method call on a typed variable (`if mod.is_valid():`,
  loop variable, member variable or argument) becomes a call node wired into the
  condition pin. Boolean combinations (`a and b`), `not …`, other calls and
  chained comparisons are not reconstructed — they stay verbatim on the condition pin.
  Generated comparisons are parenthesized (`if (health > 0):`), which
  reloads identically. Wiring a comparison Operator into an If / Else If by
  hand drops the node's own stored condition text (the comparison becomes
  the only condition), and the If never shows the raw `if …` source line.
- **Annotations (full workflow):** every annotation Godot 4.7 accepts is in
  the registry and spawnable from the node menu (`@export`, `@export_range`,
  `@export_enum`, `@onready`, `@tool`, `@icon`, `@rpc`, `@warning_ignore`, …).
  Each Annotation node carries one argument pin per registry parameter
  (editable, with type-aware defaults) and one lilac annotation output. It
  wires into the "add annotation" slot of Variables, Functions and the Script
  Header; invalid targets are rejected with an explanation, a duplicate
  annotation name on one declaration is rejected, and re-wiring the node to
  another declaration moves it instead of duplicating it. The first
  annotation on a declaration generates inline (`@export var health:
  int = 100`); further annotations generate as an ordered block above the
  declaration. The Script Header carries a **"+ Annotation"** control that
  opens the menu pre-filtered to class-level annotations (Variables and
  Functions get the same affordance for their targets, Variables only while
  public), and dragging from a declaration's "add annotation" slot opens the
  same context list — spawning from it wires and registers the annotation in
  one step. Script-level Annotation nodes, Script Class Name and Script Extension sit in a dedicated column left of the Script Header. Class-level annotations always generate BEFORE
  `extends`/`class_name` (valid placement), and statement-level
  `@warning_ignore` annotations round-trip verbatim.
  **Annotations are nodes, not text fields:** loading a script converts every
  representable parsed annotation into a real Annotation node registered on
  its declaration (order and inline placement preserved; byte-identical
  round-trip) — only annotations that cannot be represented exactly
  (unknown names, argument overflow, exotic spacing) keep an editable row.
  Committing such a row (Enter / focus loss) converts it into a wired
  Annotation node too, and an annotation typed without its leading `@` is
  normalized automatically. An `@export_group` node has exactly ONE output —
  its **group** pin — and cannot be registered on a declaration. Group lines
  that were tight against a variable stay on their own line in the output.
  **Export groups** are wired, not typed: an `@export_group` node exposes a
  dedicated **group output**, every `@export`-family annotation node carries
  an **"add group" input**, and connecting them draws a visible lilac wire —
  one group per export annotation (re-wiring moves it; disconnecting only
  drops the association, never the annotation's own configuration). Multiple
  exports can share one group node; generation emits the group's line before
  the first variable of that group, in variable order, per Godot's actual
  `@export_group` rules (a manually registered group node keeps its manual
  placement instead). Non-`@export_group` nodes are rejected at the group
  pin; `@export_subgroup`/`@export_category` define their own nesting through
  their name fields.
- **Private-variable scopes:** a Variable marked Private gains a dedicated
  amber **scope output** pin (its value output keeps working independently);
  Function, If, Else If, While, For and Match nodes carry an **"add scope"**
  input. Wiring a variable's scope pin into one of those slots draws a
  visible amber wire and assigns the variable to that scope: references are
  allowed inside the assigned scope and its nested flow (everything from the
  block's merge point onward is rejected). GDScript itself has no `private`
  keyword — the declaration still generates inside the scope's function.
  A private variable parsed from a script (a function-local `var`) shows
  its scope pin immediately on load; the pin is never duplicated on
  refresh or reload.
  A `var` declaration **inside a block** (an If / Else If / While / For
  body) parses into the same full Variable node — Scope selector, Variable
  Name, Data Type, Value and annotations all editable — and joins its
  owning block through the visible amber scope wire, never an execution
  wire. Such a declaration generates at the top of its function (the
  reference scope is still enforced); defaults that read loop iterators or
  branch-only names keep the declaration at its flow position instead
  (preserved, never silently rewritten). Dragging from an "add scope" slot
  and dropping creates the variable as private and registers the scope in
  one step.
- **Event (Function)** (one per function): execution output plus a structured
  property editor — labelled **Function Name** and **Return Type** fields
  (square-cornered input boxes; a menu "Static Func" entry spawns the same
  node with `static = true`, titled "Static Func: <name>")
  (editable type selector with common GDScript types; empty return type =
  no arrow). The declaration, the node title and the generated GDScript
  update on every edit. Arguments are managed through the Function's
  **left-side argument pins**: one pin per registered Argument node plus one
  always-available "add argument" slot. Dragging from that slot opens the
  node menu with a "+ Function Argument" action (creates a new separate
  Argument node and registers it); connecting an existing Argument node's
  output to the slot registers it; disconnecting unregisters it. Order and
  types follow the registration.
- **Argument** nodes: every function parameter is its own independent node
  (one per parameter, declaration order) with labelled **Argument Name**,
  **Data Type** and default value fields and exactly two output pins, laid
  out Function-pin-first: a **Function connection** pin at the top of the
  node that draws a white ownership wire into the parent Function's
  argument slot (visible for parsed scripts and registered arguments
  alike; dragging it off unregisters, dragging it into the "add argument"
  slot registers), and a typed **variable value** pin (input/output,
  carrying the argument's real data type) at the bottom that connects to
  any compatible data input. There is no Default input pin: the default is
  edited in the unlabelled default field and emitted into the generated
  declaration. Arguments belong to their parent function, are never embedded
  in the Function node, never create variables, and are reconstructed from
  the real `func` declaration when a script is (re)opened. Renaming updates
  the declaration and references in the function's flow; type changes
  revalidate (and drop incompatible) connections; nodes are deleted with the
  standard Delete/Backspace selection interaction.
- **Statement** nodes: assignments/declarations are structured (`var x: int`,
  `set x`) with a typed data input for the value and a data output for the
  variable; anything else is kept verbatim as an editable statement node.
- **If / Else If** (Blueprint-style Branch): execution in, an editable bool
  condition pin (typed value or a wired comparison node; the raw `if ...`
  source line is not shown), and three execution outs: **True**, **False**
  and **done**. True and False are separate branches that simply end (like a
  loop body); **done** runs after the whole if / elif / else. A node on
  **False** is the `else:` body; an Else If wired to **False** becomes
  `elif`, and a chain's **done** pin lives on the first If. If both branches
  are wired into the same node (a join), it runs after the if. A spawned Else
  If that is not wired to a False pin is a standalone chain head that emits
  `if` (spawned graphs always generate compiling code).
- **For / While**: execution in, `loop body` and `done` execution outs; For
  exposes the loop variable as a data output.
- **Match**: one execution out per branch (labelled with the pattern) plus an
  `after` fall-through out. Spawned with two default branches (`0`, `_`);
  branch patterns are editable right on the node (commit on Enter/focus
  loss), and the node has a **+ branch** grow row and a per-branch remove
  button — rewiring stays correct when branches shift.
- **Return / Break / Continue / Pass / Comment** nodes.
- **Dynamic input pins** (one reusable system, not per-node hacks): a policy
  table (`DYNAMIC_INPUTS` in `graph_model.gd`) declares which node kinds accept
  a variable number of inputs — **Operator** (any operand count; code
  generates a left-associative fold `((a op b) op c)`), **Function Call**
  (argument list) and **Print** (value list). Every dynamic node always keeps
  exactly one empty grow slot: connecting it opens a fresh empty pin,
  disconnecting trims surplus empties, and neither creates duplicates.
  Free-form Function Calls also get per-pin argument actions (move left/right,
  remove). A Call whose target matches a function declared in the script
  mirrors the real declaration instead: one fixed, named, typed pin per
  parameter (prefilled with defaults), no growth beyond it, and it resyncs
  whenever the function or its arguments change; renaming the function
  updates its call sites. Nodes with fixed GDScript semantics (If/While
  conditions, Return, Set Variable, Statement values, ...) never gain pins.
  Reopening a script rebuilds Print nodes with one pin per printed value.
- The **Operators** menu also offers `is` / `as` / `in`, `^`, `<<` and `>>`; a spawned **Statement** can hold a multi-line lambda body and generates with correct relative indentation; a spawned **Script Header** node (Functions section) lets header-less scripts gain `extends` / `class_name` / class-level annotations; the per-node **Static** checkboxes are gone from the UI (static-ness stays a model/generation concern — a "Static Func" menu entry spawns a Function node with `static = true`, variables keep their `is_static` field); verbatim Declaration nodes (enum / inner class) open a small multi-line code editor right on the node; freshly spawned empty statements keep blocks valid by emitting `pass` until filled in.
- **Top-level declarations** are real nodes too (classified by GDScript
  syntax, not indentation): `Script Header` (exactly one node for
  `extends`/`class_name`/annotations, only when directives exist), `var X`
  nodes with a structured property editor (**Variable Name**, **Data Type**
  with type selector, **Value** — the variable's value data input doubles
  as its value/default field (labelled "Value" on the node); the row is
  permanent, clearing
  it only empties the field and a new value or a connected wire restores the
  initializer without recreating the node; untyped variables stay untyped and
  `@export`/`static` prefixes are preserved), `const X`
  nodes (data out), `Signal` nodes, and verbatim `Declaration` nodes for
  `enum`/inner classes/anything the parser does not recognize (never
  dropped, never relocated; original source order is preserved in
  Generate GDScript).
- **Signal** (authorable: editable name and argument list; parsed signals are structured Signal nodes too), **Print**, **Literal** (int/float/String/bool/Vector2/Vector3/Color),
  **Get/Set Variable**, **Operator**, **Function Call** nodes (Add Node menu
  and canvas context menu) for authoring new flow. Spawned statements with a
  body become structured assignment/declaration nodes.

### Opening and saving scripts
- **Title screen**: with no script loaded the workspace shows an entry
  screen (big "Visual Script" title) with **Create New Script** (writes a
  starter template to `res://<name>.gd` and opens it), **Load Script**
  (`.gd` file dialog rooted at `res://`) and **Load Demo**. When the tab is
  opened it automatically loads the script the editor currently has open, so
  the workspace follows the opened script instead of waiting for a manual
  pick; double-clicking a `.gd` file in the FileSystem dock still routes it
  straight into the workspace.
- The workspace shows the full path of the currently open script in the path
  field and marks it as read-only while a script is loaded (changes are made
  on the graph and written back as GDScript).
- When the Visual Script tab is the active workspace, double-clicking a
  `.gd` file in the FileSystem dock (or selecting it) routes the script into
  the Visual Script workspace instead of the Script editor; with another tab
  (2D/3D/Script/…) active, scripts keep opening in the Script editor. The
  workspace also follows the Script editor's active script: opening or
  switching scripts while the tab is open swaps the graph to that script.
- **Ctrl+S anywhere in the Visual Script tab** (or the **Save button**) writes the generated GDScript back to
  the original `.gd` file (updating the editor's in-memory copy too, reloading
  the open Script editors from disk and refreshing the file cache). Every
  graph edit — including disconnecting an execution or data wire — is part of
  the generated source, so a save always reflects the current graph; the save
  is verified against the file on disk before it reports success. The
  title bar shows **● unsaved changes** while the graph has edits.
- Switching scripts or hiding the workspace with unsaved changes opens a
  **Save / Discard / Cancel** prompt; Cancel keeps the current script and its
  changes.
- **Automatic write on save:** every editor save (Ctrl+S, Save All, scene or
  project save, running the game) writes the generated GDScript into the
  `.gd` file when the graph has unsaved edits, even if another main-screen tab
  is showing. Writes are atomic (temp file + verify + rename). Automatic
  saves never show a dialog; if the code does not compile or the file changed
  on disk, the save is skipped, the status line says why and nothing is
  overwritten.
- If the file changed on disk since it was opened, a clean graph reloads it
  when you return to the tab or the editor window; with unsaved graph edits,
  pressing Save asks for confirmation before overwriting the external changes.

- **Drag and drop from the docks:** hold **Ctrl** while dropping a Scene tree
  node to get `@onready var name: Type = $Path`, or **Alt** for
  `@export var name: Type`. Dropping a FileSystem file with **Ctrl** gives
  `const Name = preload("res://...")`, with **Alt** an `@export` variable of
  the file's type preloaded with that file. Multiple selections create
  multiple nodes.

### Interaction (GraphEdit / GraphNode based)
- **Create nodes:** right-click empty canvas opens a Blueprint-style creation
  menu with a search field and categories (Flow Control incl. Match and
  Else If, Actions, Variables, Constants, Operators, Functions). Scrolling the
  menu never zooms the
  canvas — wheel events over the menu belong to the menu, at both scroll
  limits and over the search field; the graph only zooms when the pointer is
  over the canvas itself. Clicking an entry spawns the node at the
  cursor. Dropping a wire drag on empty canvas opens the same menu and wires
  the spawned node to the drag automatically.
- **Connect:** drag from any pin to a compatible pin. White triangles are
  execution pins, colored circles are data pins (every type has its own color,
  and wires take a gradient between the two pin colors). GraphEdit rejects
  incompatible type pairs during the drag; the model additionally rejects exec
  cycles and re-uses of an occupied data input.
- **Disconnect:** drag either end of a wire off its pin (both output and input
  ends detach), or click a wire to select it and press Del/Backspace. Wire
  selection shows as a bright glow and is cleared (with the glow) the moment
  the wire is disconnected — selected or not, exec or data, there is no
  leftover ghost line. The graph model updates immediately and
  the next Generate GDScript reflects the change.
- **Delete nodes:** select nodes (click / box select) and press Del; deleting
  an Event removes its whole flow.
- **Move:** drag nodes freely; wires follow automatically. Node positions are
  **session-only** — the model stores no coordinates, layout is re-derived
  from the graph structure on every rebuild (columns by control-flow depth,
  stacked without overlap; each function's Argument nodes sit to the LEFT of
  its Function node), so the logic is fully independent of the visual
  layout. The auto-layout groups related nodes into **clusters**: global
  variables, signals and constants each form their own band, and every
  function keeps its arguments, local variables and operations in one
  independent band, separated by a clear gap from other clusters. The four
  data-declaration categories — public Variables, Enums, Constants and
  Signals — additionally spread over a balanced grid inside their band (rows
  and columns derived from each category's own node count, private members
  and attached annotations keep the normal stacking below the grid).
- **Generate GDScript:** converts the graph back into GDScript and
  compile-checks it in the dialog. Nodes not reachable from any Event are
  reported (count in the dialog) and skipped.

### Visual style
- The right-click node menu renders on its own canvas layer, always above
  nodes and wires and never clipped by node containers; wheel scrolling over
  it never zooms the graph. It is fully keyboard-navigable: typing filters
  the list and preselects the first match, **Up/Down** move the highlight
  (wrapping, skipping hidden entries, honoring key repeat so holding an
  arrow key navigates continuously), the list auto-scrolls to keep the
  highlighted entry always visible, **Enter** spawns the highlighted (or
  first matching) node, **Escape** closes the menu, and mouse hover/click
  stay in sync with the highlight.
- The selected-wire highlight overlay continuously follows the graph
  geometry: zooming, scrolling and node drags re-sync its endpoints every
  frame, so the selection glow can never detach from (or lag behind) its
  pins, for execution and data wires alike.
- Connection drags are direction-safe: a drag started from an input pin is
  normalized so the model always records output -> input (correct wire
  orientation, no duplicates, type checks and generation unchanged), and
  re-routing a wire by dragging it off an input pin keeps that input as the
  anchor when spawning a replacement from the menu.
- **Undo/Redo**: Function Name, Return Type, Variable Name, Variable Data
  Type and Default Value edits are committed as one undo action per editing
  session (focus lost / Enter / type picked) into the editor's own undo
  history (the plugin's `get_undo_redo()`); inside the graph Ctrl+Z /
  Ctrl+Shift+Z / Ctrl+Y undo and redo them, including restoring connections
  that a type change had dropped. While a text field is focused, Ctrl+Z is
  the field's native text undo.
- Nodes are rectangular with small 45°-cut ("diamond") corners — a custom
  `ChamferStyle` StyleBox in `graph_types.gd` — with colored headers and a
  selection border. The colorful header keeps its two top cuts and meets the
  black body with a clean straight edge; the body keeps its two bottom cuts
  (header: straight bottom edge, angular top; body: angular bottom corners).
- `graph_types.gd` is the single source of truth for the type → color map
  (sampled from the reference: bool periwinkle `#8ca6f0`, String `#6ba6ed`,
  float cyan `#61d9f5`, Color lime `#9eff70`, Dictionary mint `#78edb0`,
  execution white). Input pins, output pins, labels and wires all read from it.
- **Wires** are drawn as a gradient from the output pin's type color to the
  input pin's type color (execution wires are white), 3 px thick, so a
  Dictionary pin feeding a String pin fades mint → blue exactly as in the
  reference. Connection logic is untouched.
- **Data-type icons are Godot's own editor icons** (`type_icons.gd`): the
  glyph next to every pin (`bool`, `int`, `flt`, `Str`, `clr`, `dict`, `any`
  ...), in the type picker chips, the type autocomplete rows and the type
  input fields. Resolution: exact editor icon for builtin Variant types and
  engine classes → a custom `class_name` class's own `@icon` or its base
  class's icon → the nearest native ancestor's icon → no icon (never a wrong
  one). Typed containers (`Array[int]`) use the container's icon.

### What the connections mean
Execution connections are the actual statement flow of the script (sequential
chains, if/elif/else branches incl. else-less fall-through, loop bodies,
match branches, returns). Data connections are real value dependencies:
wiring a Literal into an If condition or an assignment's value pin makes the
generated code use that source expression. There is no separate execution
engine and no custom language — the graph is a view over GDScript, and
`generate()` emits native GDScript (opaque statements are kept verbatim, so
any GDScript survives the round trip; a regenerate-from-generated stability
check runs in the tests).

### Property accessors (setter / getter)
A **Setter** or **Getter** is a function-style node, created the same way as a
Function: open the node menu (Functions) and spawn **Setter** or **Getter**.
The Variable node itself has no setter / getter controls.

    var charge: float = 0.0:
    	set(value):
    		charge = clampf(value, 0.0, MAX_CHARGE)
    	get:
    		return charge

- The node has a **Variable** dropdown: pick which variable it belongs to. A
  new node attaches itself to the first variable that has no such accessor
  yet; with none free it stays unattached and writes nothing to the script.
- A Setter has the new value as its argument pin (`value`) and an execution
  pin; a Getter has just the execution pin. Build the body from ordinary nodes
  (Set, If, Print, Call, Return, ...), exactly like a function.
- A new accessor starts with a ready-made body that behaves like a plain
  variable (`name = value` / `return name`).
- Existing `set(v):` / `get:` blocks load as Setter / Getter nodes whose
  bodies are real node chains; untouched accessors regenerate byte-identically.
- Delete the node to remove the accessor; deleting or renaming the variable is
  followed by its accessors.
- A block with comments between the accessors or one-line bodies
  (`set(v): x = v`) is shown as one code box on the Variable node and is
  written back exactly as typed. A lambda default and function-local
  variables cannot have accessors.

### Variable scope (Public / Private)
The Variable node's property form has a **Scope** selector (Public/Private).
GDScript 4.x has no public/private keywords for locals, so scope is an
addon-level concept: a **public** variable is declared at script level and
usable anywhere; a **private** variable is emitted as a `var` inside its
owner function and its Get/Set references are restricted to that function.
Switching a variable to Private picks the owner from its referencing Get/Set
nodes (or the first function), cleans every out-of-scope reference (Get/Set
nodes reset to empty, their links and flow slots are bypassed/removed, and
generation stays valid GDScript), switching back to Public re-hoists the
declaration to script level. Connect attempts into or out of a private
variable from another function are rejected by `can_connect_data()`/
`is_ref_allowed()`; the add-node menu only offers private variables when the
anchor is inside the owner function. Scope survives save/reopen (parsed
script-level `var` → public, function-local top-level `var` → private).

### Wire selection
Clicking a wire selects exactly the existing connection — the highlight
overlay redraws Godot's own `get_connection_line()` geometry (identical for
all angles, including ≥ 90° where a hand-rolled bezier diverges), and the
selection follows live endpoint transforms through zoom/scroll so it never
detaches from the wire.

### Dynamic data type system (type_registry.gd)
Data types are discovered dynamically from real metadata instead of a fixed
list, through a central registry (`type_registry.gd`): built-in Variant
types from the engine's API dump, every ClassDB class (base class recorded),
GDExtension/C# classes (ClassDB extension API type), custom `class_name`
scripts of the project (including custom resource classes), engine enums
per class with their actual constant values, script `enum` declarations
with their values, and dynamically constructed typed containers
(`Array[T]`, `Dictionary[K, V]`). `refresh()` re-scans so new scripts,
addons and registrations appear without a restart; duplicate exposures are
deduplicated.

Every type field (variable Data Type, Argument Data Type, Function Return
Type) and every pin value field shares one autocomplete component
(`type_suggest.gd`), whose behaviour and look deliberately mirror the
right-click context menu (same panel styling, same CanvasLayer stacking
above graph nodes, same keyboard model): suggestions appear while typing
(case-insensitive partial match, owner/category in the results); Up/Down
navigate with wrap-around and key-repeat support (holding an arrow keeps
moving) while the selection stays highlighted and visible in the list;
Enter picks the highlighted value, Escape closes; mouse hover selects a
row and click picks it; the list scrolls with the wheel normally and the
wheel is only swallowed at the scroll limits so it can never zoom or pan
the graph underneath. The popup is clamped to the visible window (all
four edges, re-clamped when the window resizes while open) and flips
above the input when there is no room below; it renders on the context
menu's CanvasLayer, so it is never clipped by node views. The LineEdit
never loses focus or its caret (rows don't take focus, only suggestion
rows rebuild, and the scroll list has a fixed size so its geometry —
and its scrollbar — always stays inside the panel). The "ˆ" dropdown
button next to type fields opens this shared popup directly instead of
popping an empty native MenuButton menu on top of it. Value fields are
context-aware: an enum-typed pin offers its real constants, other pins
offer declared variable names.

Connections validate against actual Godot assignment rules through full
type identities carried on the pins: inheritance (subclass → base ok,
base → subclass rejected, checked via ClassDB and script chains), enum →
int, int → float, numeric truthiness → bool, and typed containers
(element types must be assignable). Refused connections explain why
(the canvas surfaces the reason) instead of silently dropping; retyping a
variable propagates to its Get/Set references and revalidates connected
wires, keeping compatible ones. Automatic detection fills types wherever
they are derivable — annotations, argument/return types, function
signatures, default values (e.g. `var count = 5` pins as int) — and
explicit annotations are always preserved verbatim in generation;
unresolvable types stay Variant rather than being guessed.

### Universal Function Call system (func_registry.gd)
The Function Call node was rebuilt on top of a discovery registry
(`func_registry.gd`) instead of a hardcoded list. Every callable available
to the running project is discovered from real metadata and grouped by
source: **Language** (global GDScript/utility functions), **Godot Type**
(methods of built-in Variant types: String, Array, Dictionary, Vector2...),
**Godot Class** (ClassDB engine methods, inherited ones flagged), **Project
Script** (funcs declared in project .gd files), **Custom Class** (registered
via `class_name`), **Autoload** (singletons from ProjectSettings), **Addon**
(scripts under res://addons/) and **Extension** (GDExtension/C# classes via
ClassDB's extension API type). Signatures come from the engine's API dump
(`builtin_api.json`, a reduced extension-api extract shipped with the
addon), ClassDB and source parsing — argument names, types, defaults,
optional arguments, return types and static/instance behaviour are read,
never invented. The registry is extensible: `register_entry()` and
`register_provider()` let any addon contribute functions without touching
the call implementation.

The menu's Functions section searches across all sources (owner prefixes
like `Call String.repeat` keep same-named functions distinguishable).
A spawned call node mirrors the real signature: a `target` input for
instance methods, one typed pin per argument prefilled with its default,
an output pin for value-returning functions. Action (void) functions are
statement nodes with execution flow; value-returning ones are expression
nodes — both can be switched per node with the **Call Mode** selector
(void functions stay statement-only, as GDScript requires). Static
class/custom-class calls generate `ClassName.method(...)`, autoloads
`Singleton.method(...)`, other scripts `preload("path").method(...)` for
static functions, and same-script declarations plain `name(...)`.
Reopening a script reconstructs whole-statement calls as Function Call
nodes again when their signature is unambiguously resolvable; anything
ambiguous stays a verbatim statement (meaning preserved, nothing guessed).
When a source function's signature changes, the node's pins are resynced,
existing connections survive on compatible pins, and the change is
reported in the generated-code problems — unresolved functions are flagged
as stale, never silently generated as broken code.

### Class Reference & Member nodes (class_registry.gd)
Classes and their members are nodes too, so calls like
`Test_class.get_health()` are built visually instead of typed. The discovery
registry (`class_registry.gd`) scans real metadata — ClassDB (methods,
properties, signals, integer constants and enums, inherited members
flagged), the project's `class_name` scripts (methods via the function
registry, vars / signals / consts via side-effect-free source parsing),
Autoload singletons and `res://` script paths — never invents a member, and
exposes `register_class()` / `register_member()` / `register_provider()` for
addons.

- **Class Reference** node (indigo header, one typed output pin): names a
  class, an Autoload singleton or a script path. Its **Reference** selector
  chooses what the output is: **Class** (the type itself: statics,
  constants, constructors — `Test_class.describe()`), **Instance** (a
  concrete instance: the node gains an "instance" input pin and a typed
  **Instance Source** field, default `self`; a wired source wins —
  `player.get_health()`), or **Singleton** (an Autoload, callable both
  ways — `Player.get_health()`). The output pin carries the real class
  identity, so wiring it into a member's target is validated by Godot's own
  assignment rules (subclass → base ok, base → subclass rejected).
- **Member nodes** are Function Call nodes bound to one member: **Method**
  (execution flow for void, typed return pin otherwise), **Property** (a
  read pin by default; the Call Mode selector switches it to a write —
  `target.health = 5`), **Signal** (an emit statement with one pin per
  declared argument, `target.emit_signal("died", reason)`; switched to
  Expression it produces the Signal object reference) and **Constant**
  (class-level read, `Test_class.MAX_HEALTH`). Every member node carries a
  **Class** ownership output: wiring it into a Class Reference's **"add
  member"** slot registers the member with that reference (steel-blue
  ownership wire, one slot row per member, re-wiring moves it — the same
  pattern as Argument / Annotation registration).
- **Generation resolves the target from the registration**: a member whose
  target pin is left empty uses its registered Class Reference's output
  (`Test_class.get_health()`); a wired or typed target always wins. An
  instance-level member driven only by a **class-mode** reference is
  reported as a generation problem ("instance-level: set … to instance mode
  or wire an instance target") instead of generating a call that cannot
  run.
- **Round-trip**: a parsed dotted call whose owner resolves to exactly one
  known class reconstructs as a member node plus its Class Reference (a
  static becomes a class reference, an Autoload call a singleton reference)
  and regenerates byte-identically. Property / constant reads and calls
  through variables stay verbatim statements — nothing is guessed.
- **Node menu**: a **Classes** section spawns Class Reference nodes; typing
  searches every known class and member (`Test_class.get_health`). Dragging
  from a Class Reference's "add member" slot opens the menu pre-filtered to
  that class's members, and spawning one wires and registers it in one
  step.
- **Input & stability rules**: the class must be a name (`Node2D`,
  `Outer.Inner`) or a `res://...gd` path - spaces, line breaks, `;` and calls
  are refused; an unknown but well-formed class is applied with a "check the
  spelling" hint; the Instance Source is one balanced expression. A member
  only attaches to a reference of its own class or a subclass, a refused wire
  never unregisters the member already in the slot, and wires that would loop
  (a member feeding its own reference) are refused. Deleting a member removes
  its slot row; retargeting a reference away from a member's class is reported
  when generating. Tests: class_ref_tests_cli.gd (108 checks).

## Lambda (Callable) nodes
Inline `func(...) -> T:` Callable literals are nodes too, so callbacks are
built visually instead of typed: a **Lambda** node (teal header, Functions
section in the node menu) carries typed **parameter rows** (name / type /
default, add / remove buttons), a **Return Type** selector and an editable
**Body** code box. Its single output pin is **Callable** (soft orange,
`PinType.CALLABLE`): it wires wherever a Callable argument is taken —
`Array.append(...)`, a `Callable`-typed parameter or variable — and pin
compatibility keeps a lambda from silently wiring into an untyped int slot
(or a number from standing in for a callback; Variant remains the universal
fallback). Bodies generate as single lines when they were written inline
(`func(x: float) -> float: return x * 1.15`) and as blocks with correct
indentation when they were written multi-line; the layout a script used is
the layout it regenerates with.

- **Parsing**: lambdas anywhere in a script rebuild as nodes —
  `var double := func(x: int) -> int:` with its body (including nested `if`
  blocks, kept relative to the body's base level), lambda defaults stored in
  `Callable`-typed variables, assignment statements whose block opens with a
  lambda (previously kept as opaque verbatim text; they now rebuild
  structured **and** regenerate byte-identically), lambdas inside parsed
  statements that resolve to a known function (`use(func(): pass)` on a
  `Callable` parameter — wired past the target pin) and whole-statement
  calls whose signature is not known but carry a lambda argument
  (`modifiers.append(func(x: float) -> float: ...)`) — the last rebuild as
  free-form Function Call nodes so the lambda is a wired node instead of
  opaque text. Statements with no lambda inside stay opaque; nothing is
  guessed.
- **Variable defaults**: a variable whose default is a lambda shows no
  accessor controls (a Callable default plus `set(v):` would be invalid
  GDScript); the value pin and the variable's output carry the
  **Callable** class, and a wired Lambda node replaces the inline text.
- **Editing**: parameter names are validated and kept unique, types and the
  return type are free text applied on commit, the body is one statement per
  line with `return` producing the value. Renaming a captured variable
  reaches inside lambda bodies (and parameter defaults), and an unwired
  lambda is exempt from the unreachable-node pass like every other data
  source.
- **Round-trip**: every supported form regenerates byte-identically and is
  stable across a second generation; the compile check still reports
  genuine GDScript errors (e.g. a typed lambda whose body never returns).
- **Input safety**: a refused edit keeps the previous value and the status
  bar explains why. Parameter names must be plain identifiers that are not
  GDScript reserved words (`class`, `func`, `if`, ...) and not duplicates;
  types may be typed containers (`Dictionary[String, int]`) but not contain
  stray spaces or `=`; a default is one value (`[1, 2]` fine, `1, 2` refused);
  bodies indented with spaces or a tab/space mix are converted to tab levels.
  Renaming a parameter follows into the body (whole words) and later defaults.
  Tests: lambda_tests_cli.gd (161 checks).

## Error & warning display (graph_diagnostics.gd, diagnostics_logger.gd)
Blueprint-style problem markers on the graph. This is a **display layer only**:
it never edits the graph, never "fixes" code and never changes what is
generated (the generated text is byte-identical with and without it).

- **Errors** (red): a red circle badge with a cross in the node header, a thick
  red outline, a slightly red-tinted body and a one-line message row at the
  bottom of the node (`Error (L12): ...`, `(+N more)` when there are several).
- **Warnings** (amber): amber triangle badge, thinner amber outline, amber
  message row. Warnings: a node that is not connected to any Event flow (it is
  skipped when generating), an unresolved or changed function call.
- **Error / Warning nodes and pins:** a node with problems automatically gets an
  **error** pin (red) and / or a **warning** pin (amber) on its message row, and
  an **Error** / **Warning** node (`graph_diag_node.gd`) is placed next to it,
  wired to that pin, listing every message of that severity with its generated
  line. They are derived from the diagnostics each time: not model nodes, never
  generated or saved, gone as soon as the problem is fixed.
- **Hover** the badge or the message row for the full text of every problem on
  the node (with the generated line number). The toolbar also shows
  `N errors | N warnings`; hover it for the complete list, including problems
  that cannot be tied to one node.
- **Where messages come from:** (1) the graph model's own checks (scope,
  annotation, missing call target/arguments, unreachable nodes, structural
  problems), and (2) the real GDScript parser/analyzer: the generated source is
  compiled in a throw-away script and the engine's messages (syntax, type,
  undeclared identifier, ...) are captured with `OS.add_logger()`. Each message
  carries a generated-line number; `graph_model.gd` records which node emitted
  which line during `generate()` (`line_nodes` in its result) so the message is
  shown on that node. If a line cannot be attributed, the problem is shown in
  the toolbar tooltip instead of being dropped.
- **Live:** the check re-runs ~0.45 s after every edit; indicators of resolved
  problems disappear, new ones appear. Nothing is suppressed - if the compiler
  fails without giving a message, a generic error is still reported.
- **Limits (engine behaviour):** the GDScript parser stops at the *first syntax
  error* (type/analyzer errors are reported in full), and the engine does not
  deliver GDScript *warnings* (unused variable, ...) to scripts, so warnings are
  limited to the graph-level ones above. Scripts that contain `static var` or
  `_static_init` are not compiled automatically (the engine would run that
  code on every edit); **Generate GDScript** compiles them on request.
- Every error compile also appears in the editor's Output panel, as before.
- `graph_diagnostics.gd` / `diagnostics_logger.gd` are loaded lazily: if they
  fail to compile on some engine build, the workspace keeps working without the
  markers.

## Headless tests
Run from the project root:

    godot --headless --path . -s res://addons/gd_canvas_spikes/graph_tests_cli.gd -- --run   # graph model tests (526 checks)
    godot --headless --path . -s res://addons/gd_canvas_spikes/graph_ui_tests_cli.gd        # canvas/UI tests (496 checks)
    godot --headless --path . -s res://addons/gd_canvas_spikes/graph_ws_smoke.gd            # workspace smoke test
    godot --headless --path . -s res://addons/gd_canvas_spikes/graph_diag_tests_cli.gd      # error/warning display tests
    godot --headless --path . -s res://addons/gd_canvas_spikes/class_ref_tests_cli.gd       # class reference / member node tests
    godot --headless --path . -s res://addons/gd_canvas_spikes/lambda_tests_cli.gd          # lambda / Callable node tests
    godot --headless --path . -s res://addons/gd_canvas_spikes/benchmark_cli.gd -- --selftest  # parser self-test

## Static typing
The addon's own code is strictly statically typed (every variable, parameter
and return value has an explicit type; typed arrays/dictionaries wherever the
element type is uniform). This is enforced in the test setup with
`debug/gdscript/warnings/untyped_declaration`, `.../inferred_declaration` and
`untyped_parameter` treated as errors. It applies only to the addon itself:
user scripts are parsed as text and never re-typed — opening and saving a
script with untyped or partially typed declarations preserves them byte for
byte (regression-tested), and no annotation is ever inserted into user code.

## Structural parser (structure_parser.gd)
Tier-1 structural parser: lossless segmentation of GDScript into
BLANK/COMMENT/ANNOTATION/VAR/FUNC/IF/... segments with parent/depth links.
`top_level_blocks()` classifies top-level segments by syntax so the graph
model can map each one to the right node kind; unrecognized top-level code
keeps its own verbatim node. Self-test (`roundtrip_tests.gd`) and benchmark
(`benchmark.gd`). The graph is
built entirely on top of it.

## Archived zoom spike (zoom_spike.gd, spike_canvas.gd, spike_block.gd)
The earlier "zoomed CodeEdit boxes" experiment is kept in the folder for
reference but is no longer referenced by the workspace (switch back by
pointing `plugin.gd`'s `WORKSPACE_SCRIPT` at `zoom_spike.gd`).

## APIs used (checked against Godot 4.7.2)
GraphEdit: `connect_node`/`disconnect_node`, `connection_request`/
`disconnection_request`/`delete_nodes_request` signals, `popup_request`,
`connection_to_empty`/`connection_from_empty`, `get_closest_connection_at_point`,
`set_connection_activity`, `add_valid_connection_type`,
`add_valid_left/right_disconnect_type`, `right_disconnects`,
`connection_lines_curvature/thickness/antialiased`, `_is_node_hover_valid`
override, `type_names`. GraphElement `position_offset` stores graph
coordinates (4.7 keeps `position` as the derived screen position).
GraphNode: `set_slot` with custom exec-triangle icons, `get_input/output_port_slot`-
based port↔pin mapping, per-slot types/colors, `panel(_selected)`/
`titlebar(_selected)` stylebox overrides.
