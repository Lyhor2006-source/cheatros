"""Exercise the embedded reload controller without loading the game runtime."""

import ast
import time
from pathlib import Path
from types import SimpleNamespace


source = (Path(__file__).resolve().parents[1] / "payload" / "RosPayload.py").read_text(encoding="utf-8")
tree = ast.parse(source)
functions = [node for node in tree.body if isinstance(node, ast.FunctionDef) and
             node.name == "_pb_auto_reload"]
code = compile(ast.Module(body=functions, type_ignores=[]), "RosPayload.py", "exec")


class Magazine:
    def __init__(self):
        self.magazine_capacity = 30
        self.bullet_count = 5
        self.ammo_box_bullet_count = 0

    def decBulletFromMagazine(self, count=1):
        self.bullet_count -= count
        return self.bullet_count


magazine = Magazine()
magazine.ammo_box_bullet_count = 100
player = SimpleNamespace(dtsCurWeapon=0, dtsCurRailID=1)
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
tick(player, config)
state["switch_until"] = 0.0

# Active tick: reserve is topped off to 150, but magazine bullet_count remains 5 (natural depletion)
tick(player, config)
assert magazine.bullet_count == 5 and magazine.ammo_box_bullet_count == 150
assert state['native_reserve_available'][(0, 42, 1)] is True
assert calls == []

# Reserve spent by a native reload returns to the observed high-water value.
magazine.ammo_box_bullet_count = 120
tick(player, config)
assert magazine.ammo_box_bullet_count == 150

# Firing weapon decreases magazine rounds naturally
magazine.decBulletFromMagazine(5)
assert magazine.bullet_count == 0

# When empty, trigger reload once
tick(player, config)
assert calls == ["reload"]
assert state["state"] == "reloading"

# Native reload animation is now playing in-game (is_reloading_flag is True)
is_reloading_flag[0] = True
tick(player, config)
# MUST NOT trigger reload again (no reload spam or cancellation of animation!)
assert calls == ["reload"]
state["reload_start"] = time.time() - 4.0
tick(player, config)
assert magazine.bullet_count == 0 and state["state"] == "reloading"
state["reload_start"] = time.time()

# Even if is_reloading_flag ends early, retry timeout protects animation for 3.5s
is_reloading_flag[0] = False
tick(player, config)
assert calls == ["reload"]

# Real game completes reload (fills 30 rounds into magazine from reserve)
magazine.bullet_count = 30
is_reloading_flag[0] = False
tick(player, config)
assert state["state"] == "idle"
assert magazine.ammo_box_bullet_count == 150
assert calls == ["reload"]

print("reload smoke: natural depletion, one native reload request, local reserve restored")

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
tick(player, config)
assert magazine.bullet_count == 30 and hud_magazines[0] == 30
assert state["state"] == "idle"
print("reload mirror smoke: read-only mirror does not block HUD magazine refill")

# Some guns fill the live magazine before WeaponReload.onLeave fires.
magazine.bullet_count = 7
hud_magazines[0] = 0
state["state"] = "reloading"
state["reload_start"] = time.time()
is_reloading_flag[0] = True
tick(player, config)
assert state["state"] == "reloading" and hud_magazines[0] == 0
is_reloading_flag[0] = False
tick(player, config)
assert state["state"] == "idle" and magazine.bullet_count == 30 and hud_magazines[0] == 30
print("reload timing smoke: partial native fill completes after reload exit")

# Shell-fed weapon: do not fill during the animation; complete to its own capacity.
magazine.magazine_capacity = 5
magazine.bullet_count = 1
hud_magazines[0] = 1
state["state"] = "reloading"
is_reloading_flag[0] = True
tick(player, config)
assert magazine.bullet_count == 1 and hud_magazines[0] == 1
is_reloading_flag[0] = False
tick(player, config)
assert magazine.bullet_count == 5 and hud_magazines[0] == 5
assert state["state"] == "idle"
magazine.magazine_capacity = 30
print("shotgun reload smoke: partial shell load completes after animation")

# A rejected native reload cannot leave an empty gun in a repeated reload loop.
magazine.bullet_count = 0
hud_magazines[0] = 0
state["state"] = "idle"
before_calls = len(calls)
tick(player, config)
assert state["state"] == "reloading" and len(calls) == before_calls + 1
state["reload_start"] = time.time() - 2.3
tick(player, config)
assert state["state"] == "idle" and magazine.bullet_count == 30 and hud_magazines[0] == 30
assert len(calls) == before_calls + 1
print("reload fallback smoke: one request then a full local magazine")

class StuckMagazine:
    magazine_capacity = 5
    ammo_box_bullet_count = 70

    @property
    def bullet_count(self):
        return 0


stuck = StuckMagazine()
env["_pb_ar_probe"] = lambda _me: ((0, 43, 2), 0, 5,
                                  [(hud_magazines, None, 0)], [], 43, stuck)
hud_magazines[0] = 0
state["key"] = (0, 43, 2)
state["state"] = "reloading"
state["reload_start"] = time.time() - 4.0
is_reloading_flag[0] = False
before_calls = len(calls)
tick(player, config)
tick(player, config)
assert state["state"] == "failed" and len(calls) == before_calls
assert hud_magazines[0] == 0
print("reload retry smoke: failed refill does not request a second reload")

# An empty real reserve may make the game retry its reload indefinitely. Complete
# one local reload without waiting for a native state that cannot finish.
zero_mag = Magazine()
zero_mag.magazine_capacity = 5
env["_pb_ar_probe"] = lambda _me: ((0, 44, 3), zero_mag.bullet_count, 5,
                                  [], [], 44, zero_mag)
player.dtsCurRailID = 3
is_reloading_flag[0] = False
tick(player, config)
state["switch_until"] = 0.0
tick(player, config)
assert zero_mag.ammo_box_bullet_count == 25
assert state['native_reserve_available'][(0, 44, 3)] is False
zero_mag.decBulletFromMagazine(5)
before_calls = len(calls)
tick(player, config)
assert len(calls) == before_calls + 1 and state["state"] == "reloading"
is_reloading_flag[0] = True
state["reload_start"] = time.time() - 1.8
tick(player, config)
assert zero_mag.bullet_count == 5 and state["state"] == "idle"
assert len(calls) == before_calls + 1
print("zero reserve smoke: single reload attempt then local refill")
