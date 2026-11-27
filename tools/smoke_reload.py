"""Exercise the embedded reload controller without loading the game runtime."""

import ast
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


def probe(_me):
    return (0, 42, 1), magazine.bullet_count, 30, [], [], 42, magazine


env = {
    "_PB_AR_STATE": state,
    "_pb_ar_probe": probe,
    "_pb_ar_install_ws_hooks": lambda: None,
    "_pb_restore_mag_hook": lambda: None,
    "_pb_ar_is_reloading": lambda _me, _objs: False,
    "_pb_ar_trigger_reload": lambda _me, _objs: calls.append("reload") or True,
}
exec(code, env)
tick = env["_pb_auto_reload"]
config = [0] * 45
config[44] = 1

# Initial weapon selection tick
tick(object(), config)
state["switch_until"] = 0.0
# Active tick: magazine tops off to capacity, reserve to capacity*5, dec hooked
tick(object(), config)
assert magazine.bullet_count == 30 and magazine.ammo_box_bullet_count == 150
assert calls == []

# Firing weapon: decBulletFromMagazine returns 0, bullet_count stays 30
ret = magazine.decBulletFromMagazine(1)
assert ret == 0 and magazine.bullet_count == 30
assert calls == []

# No reload requested when unlimited ammo is active
tick(object(), config)
assert state["state"] == "idle" and calls == []

# When unlimited ammo is off, but auto reload is on
config[44] = 0
config[43] = 1
# Hook should be restored when unlim is turned off
tick(object(), config)
assert not getattr(magazine, "_rx_unlim_hooked", False)
magazine.bullet_count = 0
tick(object(), config)
assert calls == ["reload"]

print("reload smoke: unlimited ammo tops off instantly and hooks consumption; normal reload triggers only when unlim is off")
