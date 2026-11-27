"""Exercise the embedded reload controller without loading the game runtime."""

import ast
import time
from pathlib import Path
from types import SimpleNamespace


source = (Path(__file__).resolve().parents[1] / "payload" / "RosPayload.py").read_text(encoding="utf-8")
tree = ast.parse(source)
functions = [node for node in tree.body if isinstance(node, ast.FunctionDef) and
             node.name in ("_pb_auto_reload", "_pb_ar_add_bag_reserve")]
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
class WeaponBag:
    def __init__(self):
        self.calls = []
        self._idx2weapon_map = {0: SimpleNamespace(
            _dtsItemID=7042, _curRail=SimpleNamespace(
                railData=SimpleNamespace(BULLET_ID=77)))}

    def addBulletToGunItem(self, gun_id, bullet_id, amount):
        self.calls.append((gun_id, bullet_id, amount))
        magazine.ammo_box_bullet_count += amount

bag = WeaponBag()
player = SimpleNamespace(weapon_bag=SimpleNamespace(), dtsCurWeapon=0, dtsCurRailID=1)
state = {"ar_on": False, "unlim_on": False, "valid_gun": False, "state": "idle",
         "key": None, "switch_until": 0.0, "reload_start": 0.0}
calls = []
is_reloading_flag = [False]


def probe(_me):
    return (0, 42, 1), magazine.bullet_count, 30, [], [], 42, magazine


env = {
    "_PB_AR_STATE": state,
    "_pb_ar_probe": probe,
    "_pb_ar_active_slot": lambda me: me.dtsCurWeapon,
    "_pb_ar_read": lambda obj, name: getattr(obj, name, None),
    "_pb_logic_objs": lambda me: [bag],
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
assert bag.calls == [(7042, 77, 150)]
assert calls == []
wrong, detail = env['_pb_ar_add_bag_reserve'](player, 1, 99, 10)
assert not wrong and detail == 'bag slot changed' and bag.calls == [(7042, 77, 150)]

# Reserve spent by a native reload returns to the observed high-water value.
magazine.ammo_box_bullet_count = 120
state['bag_attempts'][(42, 1)] = 0.0
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
assert state["state"] == "idle" and magazine.bullet_count == 7 and hud_magazines[0] == 7
print("reload timing smoke: early magazine fill synchronizes HUD after reload exit")

class StuckMagazine:
    magazine_capacity = 5
    ammo_box_bullet_count = 70

    @property
    def bullet_count(self):
        return 0


stuck = StuckMagazine()
env["_pb_ar_probe"] = lambda _me: ((0, 43, 2), 0, 5, [], [], 43, stuck)
state["key"] = (0, 43, 2)
state["state"] = "reloading"
state["reload_start"] = time.time() - 4.0
is_reloading_flag[0] = False
before_calls = len(calls)
tick(player, config)
tick(player, config)
assert state["state"] == "failed" and len(calls) == before_calls
print("reload retry smoke: failed refill does not request a second reload")
