"""Exercise the embedded reload controller without loading the game runtime."""

import ast
import time
from pathlib import Path


source = (Path(__file__).resolve().parents[1] / "payload" / "RosPayload.py").read_text(encoding="utf-8")
tree = ast.parse(source)
function = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "_pb_auto_reload")
code = compile(ast.Module(body=[function], type_ignores=[]), "RosPayload.py", "exec")


class Magazine:
    def __init__(self):
        self.magazine_capacity = 30
        self.bullet_count = 5
        self.ammo_box_bullet_count = 0

    def decBulletFromMagazine(self, count=1):
        self.bullet_count -= count
        return self.bullet_count


magazine = Magazine()
state = {"ar_on": False, "unlim_on": False, "valid_gun": False, "state": "idle",
         "key": None, "switch_until": 0.0, "reload_start": 0.0}
calls = []
is_reloading_flag = [False]


def probe(_me):
    return (0, 42, 1), magazine.bullet_count, 30, [], [], 42, magazine


env = {
    "_PB_AR_STATE": state,
    "_pb_ar_probe": probe,
    "_pb_ar_install_ws_hooks": lambda: None,
    "_pb_restore_mag_hook": lambda: None,
    "_pb_ar_is_reloading": lambda _me, _objs: is_reloading_flag[0],
    "_pb_ar_trigger_reload": lambda _me, _objs: calls.append("reload") or True,
}
exec(code, env)
tick = env["_pb_auto_reload"]
config = [0] * 45
config[44] = 1

# Initial weapon selection tick
tick(object(), config)
state["switch_until"] = 0.0

# Active tick: reserve is topped off to 150, but magazine bullet_count remains 5 (natural depletion)
tick(object(), config)
assert magazine.bullet_count == 5 and magazine.ammo_box_bullet_count == 150
assert calls == []

# Reserve spent by a native reload returns to the observed high-water value.
magazine.ammo_box_bullet_count = 120
tick(object(), config)
assert magazine.ammo_box_bullet_count == 150

# Firing weapon decreases magazine rounds naturally
magazine.decBulletFromMagazine(5)
assert magazine.bullet_count == 0

# When empty, trigger reload once
tick(object(), config)
assert calls == ["reload"]
assert state["state"] == "reloading"

# Native reload animation is now playing in-game (is_reloading_flag is True)
is_reloading_flag[0] = True
tick(object(), config)
# MUST NOT trigger reload again (no reload spam or cancellation of animation!)
assert calls == ["reload"]
state["reload_start"] = time.time() - 4.0
tick(object(), config)
assert magazine.bullet_count == 0 and state["state"] == "reloading"
state["reload_start"] = time.time()

# Even if is_reloading_flag ends early, retry timeout protects animation for 3.5s
is_reloading_flag[0] = False
tick(object(), config)
assert calls == ["reload"]

# Real game completes reload (fills 30 rounds into magazine from reserve)
magazine.bullet_count = 30
is_reloading_flag[0] = False
tick(object(), config)
assert state["state"] == "idle"
assert magazine.ammo_box_bullet_count == 150
assert calls == ["reload"]

print("reload smoke: Option A validated: natural magazine depletion, real reload animation uninterrupted, infinite reserve replenished")

# A read-only weapon mirror used to stop the old all-or-nothing assignment loop.
class ReadOnlyMirror:
    @property
    def curAmmo(self):
        return 0


hud_magazines = [0]
mirror = ReadOnlyMirror()
env["_pb_ar_probe"] = lambda _me: ((0, 42, 1), magazine.bullet_count, 30,
                                  [(mirror, "curAmmo", None), (hud_magazines, None, 0)],
                                  [], 42, magazine)
magazine.bullet_count = 0
hud_magazines[0] = 0
state["state"] = "reloading"
state["reload_start"] = time.time() - 4.0
tick(object(), config)
assert magazine.bullet_count == 30 and hud_magazines[0] == 30
assert state["state"] == "idle"
print("reload mirror smoke: read-only mirror does not block HUD magazine refill")

# Some guns fill the live magazine before WeaponReload.onLeave fires.
magazine.bullet_count = 7
hud_magazines[0] = 0
state["state"] = "reloading"
state["reload_start"] = time.time()
is_reloading_flag[0] = True
tick(object(), config)
assert state["state"] == "reloading" and hud_magazines[0] == 0
is_reloading_flag[0] = False
tick(object(), config)
assert state["state"] == "idle" and magazine.bullet_count == 7 and hud_magazines[0] == 7
print("reload timing smoke: early magazine fill synchronizes HUD after reload exit")
