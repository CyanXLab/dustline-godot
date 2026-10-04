extends SceneTree
## 战斗管线探针 v4: 用地图射线找无遮挡视线, 验证 开火→命中→伤害→击杀

func _init() -> void:
        var m := DLMatch.new(DLMatch.Mode.TDM, 2)
        for t in 64 * 8:
                m.step()
        var p0 = m.players[0]
        var p1 = m.players[1]
        print("phase=%d p0.gun=%d ammo=%d" % [m.phase, p0.gun, p0.ammo[p0.gun]])
        # 在 p0 出生点周围 8 个方向找一条 >=80u 的无遮挡视线
        var eye: Vector3 = p0.eye()
        var feet_off: Vector3 = eye - p0.position
        var best_yaw: float = p0.yaw
        var best_dist := 0.0
        for a in 16:
                var yaw: float = p0.yaw + a * 22.5
                var dir := DL.aim(yaw, 0.0)
                var r: Dictionary = m.map.ray_cast(eye, dir, 400.0)
                var d: float = r["dist"] if r["hit"] else 400.0
                if d > best_dist:
                        best_dist = d
                        best_yaw = yaw
        print("最佳视线 yaw=%.1f 无墙距离=%.0fu" % [best_yaw, best_dist])
        var dt := minf(80.0, best_dist * 0.5)
        p1.position = eye + DL.aim(best_yaw, 0.0) * dt - feet_off
        p1.health = 100
        print("p1 放置: pos=%s 距离=%.0fu" % [str(p1.position), dt])
        var kill_events := 0
        m.event_kill.connect(func(_k, _v, _w, _hs, _pen): kill_events += 1)
        var hit_events := 0
        m.event_sound.connect(func(name, _pos, _pid):
                if String(name) == "hit_flesh":
                        hit_events += 1)
        for t in 64 * 6:
                m.set_command(0, {"x": 0.0, "z": 0.0, "yaw": best_yaw, "pitch": 0.0,
                        "buttons": DL.B_FIRE, "weapon": p0.gun, "buy": 0})
                m.set_command(1, {"x": 0.0, "z": 0.0, "yaw": best_yaw + 180.0, "pitch": 0.0,
                        "buttons": 0, "weapon": p1.gun, "buy": 0})
                m.step()
                if t == 64 * 3:
                        print("3s: p1.hp=%d p0.shots=%d hit事件=%d" % [p1.health, p0.shots, hit_events])
        print("6s结果: p1.hp=%d hit事件=%d kill事件=%d p0.kills=%d" % [p1.health, hit_events, kill_events, p0.kills])
        if p1.health < 100 or p0.kills > 0 or kill_events > 0:
                print("COMBAT_PIPELINE_OK")
        else:
                print("COMBAT_PIPELINE_FAIL")
        quit(0)
