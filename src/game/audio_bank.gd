extends Node
## 音效库 Bank (autoload): 事件名 → 提取的真实音效 / 合成兜底
## 提取音效按特征分类自原作 1613 个音频

var _streams: Dictionary = {}      # name → AudioStream
var _weapon_shots: Dictionary = {} # weapon key → [streams]
var _rng := RandomNumberGenerator.new()

const EXTRACTED := "res://assets/sfx_extracted/"
const SYNTH := "res://assets/sfx/"

# 事件 → 分类桶
const BUCKETS := {
        "shot_rifle": "shot_rifle", "shot_smg": "shot_rifle", "shot_sniper": "shot_rifle",
        "shot_pistol": "shot_rifle", "shot_shotgun": "shot_rifle",
        "explosion": "explosion", "c4_explode": "explosion",
        "step": "step", "ricochet": "ric", "impact": "hit", "hit_body": "hit", "hit_head": "ric",
        "ui": "ui", "ambient": "ambient",
}

func _ready() -> void:
        _rng.randomize()
        _load_all()
        _map_weapons()

func _load_all() -> void:
        var manifest_path := EXTRACTED + "manifest.json"
        if FileAccess.file_exists(manifest_path):
                var f := FileAccess.open(manifest_path, FileAccess.READ)
                var manifest: Dictionary = JSON.parse_string(f.get_as_text())
                for cat in manifest:
                        for i in (manifest[cat] as Array).size():
                                var fn: String = manifest[cat][i]
                                var path := EXTRACTED + fn
                                if FileAccess.file_exists(path):
                                        var st := load(path)
                                        if st != null:
                                                _streams["%s_%d" % [cat, i]] = st
        # 合成兜底
        var dir := DirAccess.open(SYNTH)
        if dir != null:
                for fn in dir.get_files():
                        if fn.ends_with(".wav"):
                                var st2 := load(SYNTH + fn)
                                if st2 != null:
                                        _streams["synth_" + fn.get_basename()] = st2

func _map_weapons() -> void:
        var rifles := _bucket_list("shot_rifle")
        var idx := 0
        for i in DLWeapons.count():
                var wd := DLWeapons.get_weapon(i)
                if wd.kind == DL.WeaponKind.FIREARM or wd.kind == DL.WeaponKind.KNIFE:
                        _weapon_shots[wd.key] = rifles[idx % maxi(1, rifles.size())]
                        idx += 1

func _bucket_list(cat: String) -> Array:
        var out: Array = []
        for k in _streams:
                if k.begins_with(cat + "_"):
                        out.append(k)
        out.sort()
        return out

func _pick(bucket: String) -> String:
        var lst := _bucket_list(bucket)
        if lst.size() == 0:
                return ""
        return lst[_rng.randi_range(0, lst.size() - 1)]

func play_event(event: String, pos: Vector3, world: Node3D) -> void:
        var stream_key := ""
        # 武器枪声: shot_<weapon_key>
        if event.begins_with("shot_"):
                var wkey := event.substr(5)
                if _weapon_shots.has(wkey):
                        stream_key = _weapon_shots[wkey]
                else:
                        stream_key = _pick("shot_rifle")
        if stream_key == "":
                if event.begins_with("reload") or event == "draw" or event == "pin_pull":
                        stream_key = "synth_" + ("reload_bolt" if event == "draw" else "reload_magin")
                        if not _streams.has(stream_key):
                                stream_key = _pick("ui")
                elif event == "step" or event.begins_with("step_"):
                        stream_key = _pick("step")
                elif event == "explosion" or event == "c4_explode" or event == "fire_ignite" or event == "flashbang":
                        stream_key = _pick("explosion")
                elif event.begins_with("hit_"):
                        stream_key = _pick("hit")
                elif event == "bounce":
                        stream_key = "synth_grenade_bounce"
                elif event == "death" or event == "fire_pain" or event == "damage":
                        stream_key = "synth_damage_taken"
                elif event == "empty":
                        stream_key = "synth_empty_click"
                elif event == "zoom" or event == "decoy_shot" or event == "defuse_tick" or event == "throw":
                        stream_key = _pick("ui")
                elif event == "knife_swing":
                        stream_key = _pick("ric")
                elif event == "smoke_pop":
                        stream_key = _pick("ui")
                elif event.begins_with("round_") or event.begins_with("wave_") or event == "win" or event == "lose":
                        stream_key = "synth_" + event
                else:
                        stream_key = _pick("misc")
        if stream_key == "" or not _streams.has(stream_key):
                return
        var player := AudioStreamPlayer3D.new()
        player.stream = _streams[stream_key]
        player.volume_db = _volume_for(event)
        player.max_distance = 120.0
        player.unit_size = 6.0
        player.pitch_scale = _rng.randf_range(0.94, 1.06)
        world.add_child(player)
        player.global_position = pos
        player.finished.connect(player.queue_free)
        player.play()

func _volume_for(event: String) -> float:
        if event.begins_with("shot_") or event == "explosion" or event == "c4_explode":
                return -2.0
        if event.begins_with("step"):
                return -14.0
        return -6.0

func play_ui(event: String) -> void:
        var key := "synth_" + event if _streams.has("synth_" + event) else _pick("ui")
        if key != "" and _streams.has(key):
                var p := AudioStreamPlayer.new()
                p.stream = _streams[key]
                add_child(p)
                p.finished.connect(p.queue_free)
                p.play()
