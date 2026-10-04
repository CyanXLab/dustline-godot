extends CanvasLayer
## HUD: 准星/血量/弹药/命中反馈/击杀播报/计分板/购买菜单/回合横幅/闪光白屏
class_name GameHUD

var root: Control
var crosshair: Control
var hp_label: Label
var armor_label: Label
var ammo_label: Label
var money_label: Label
var mode_label: Label
var banner_label: Label
var killfeed: VBoxContainer
var scoreboard: Panel
var buy_menu: Panel
var flash_rect: ColorRect
var hitmarker: Label
var scoreboard_visible := false
var buy_visible := false
var _banner_tween: Tween

const CROSS_GAP := 6.0

func _ready() -> void:
	root = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	var font := ThemeDB.fallback_font
	# 准星
	crosshair = Control.new()
	crosshair.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(crosshair)
	for i in 4:
		var line := ColorRect.new()
		line.color = Color(0.2, 1.0, 0.4, 0.9)
		line.name = "ch%d" % i
		crosshair.add_child(line)
	# 命中标记
	hitmarker = Label.new()
	hitmarker.text = "✕"
	hitmarker.add_theme_font_size_override("font_size", 28)
	hitmarker.add_theme_color_override("font_color", Color(1, 1, 1, 0))
	hitmarker.set_anchors_preset(Control.PRESET_CENTER)
	root.add_child(hitmarker)
	# 底部状态条
	var bottom := HBoxContainer.new()
	bottom.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	bottom.position = Vector2(24, -80)
	bottom.add_theme_constant_override("separation", 24)
	root.add_child(bottom)
	hp_label = _mk_label(bottom, 30)
	armor_label = _mk_label(bottom, 22)
	ammo_label = _mk_label(bottom, 30)
	money_label = _mk_label(bottom, 22)
	money_label.add_theme_color_override("font_color", Color(0.5, 1, 0.5))
	# 顶部模式信息
	mode_label = _mk_label(root, 20)
	mode_label.position = Vector2(24, 16)
	# 回合横幅
	banner_label = _mk_label(root, 44)
	banner_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	banner_label.position = Vector2(-200, 90)
	banner_label.size = Vector2(400, 60)
	banner_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# 击杀播报
	killfeed = VBoxContainer.new()
	killfeed.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	killfeed.position = Vector2(-360, 60)
	killfeed.size = Vector2(340, 300)
	root.add_child(killfeed)
	# 闪光白屏
	flash_rect = ColorRect.new()
	flash_rect.color = Color(1, 1, 1, 0)
	flash_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(flash_rect)
	# 计分板
	scoreboard = Panel.new()
	scoreboard.set_anchors_preset(Control.PRESET_CENTER)
	scoreboard.position = Vector2(-260, -200)
	scoreboard.size = Vector2(520, 400)
	scoreboard.visible = false
	root.add_child(scoreboard)
	# 购买菜单
	buy_menu = Panel.new()
	buy_menu.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	buy_menu.position = Vector2(80, -240)
	buy_menu.size = Vector2(360, 480)
	buy_menu.visible = false
	root.add_child(buy_menu)

func _mk_label(parent: Node, size: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	l.add_theme_constant_override("outline_size", 6)
	parent.add_child(l)
	return l

func set_crosshair_gap(gap: float) -> void:
	var w := 2.0
	var ln := 9.0
	for i in 4:
		var line := crosshair.get_node("ch%d" % i) as ColorRect
		match i:
			0: line.position = Vector2(-w / 2, -gap - ln); line.size = Vector2(w, ln)
			1: line.position = Vector2(-w / 2, gap); line.size = Vector2(w, ln)
			2: line.position = Vector2(-gap - ln, -w / 2); line.size = Vector2(ln, w)
			3: line.position = Vector2(gap, -w / 2); line.size = Vector2(ln, w)

func show_hitmarker(kill: bool, head: bool) -> void:
	hitmarker.add_theme_color_override("font_color",
		Color(1, 0.25, 0.25) if kill else Color(1, 0.9, 0.3))
	hitmarker.text = "✕" if not head else "☠"
	var tw := create_tween()
	hitmarker.modulate.a = 1.0
	tw.tween_property(hitmarker, "modulate:a", 0.0, 0.45)

func add_kill_entry(text: String, color: Color) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 17)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	l.add_theme_constant_override("outline_size", 5)
	killfeed.add_child(l)
	var tw := create_tween()
	tw.tween_interval(5.0)
	tw.tween_property(l, "modulate:a", 0.0, 0.6)
	tw.tween_callback(l.queue_free)
	while killfeed.get_child_count() > 6:
		killfeed.get_child(0).queue_free()

func show_banner(text: String, color: Color) -> void:
	banner_label.text = text
	banner_label.add_theme_color_override("font_color", color)
	if _banner_tween != null and _banner_tween.is_valid():
		_banner_tween.kill()
	banner_label.modulate.a = 1.0
	_banner_tween = create_tween()
	_banner_tween.tween_interval(2.2)
	_banner_tween.tween_property(banner_label, "modulate:a", 0.0, 0.8)

func set_flash(strength: float) -> void:
	flash_rect.color.a = clampf(strength, 0.0, 1.0)

func toggle_scoreboard() -> void:
	scoreboard_visible = not scoreboard_visible
	scoreboard.visible = scoreboard_visible

func toggle_buy() -> void:
	buy_visible = not buy_visible
	buy_menu.visible = buy_visible
