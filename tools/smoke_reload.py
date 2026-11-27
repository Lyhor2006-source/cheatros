"""Exercise the embedded reload controller without loading the game runtime."""

import ast
from pathlib import Path


source = (Path(__file__).resolve().parents[1] / "payload" / "RosPayload.py").read_text(encoding="utf-8")
tree = ast.parse(source)
function = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "_pb_auto_reload")
code = compile(ast.Module(body=[function], type_ignores=[]), "RosPayload.py", "exec")


class Magazine:
    magazine_capacity = 30
    bullet_count = 5
    ammo_box_bullet_count = 0


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

tick(object(), config)  # Initial weapon selection.
state["switch_until"] = 0.0
tick(object(), config)
assert magazine.bullet_count == 5 and magazine.ammo_box_bullet_count == 150
assert calls == []

magazine.bullet_count = 0
tick(object(), config)
assert calls == ["reload"] and magazine.bullet_count == 0

magazine.bullet_count = 30  # Simulate the game's completed reload.
tick(object(), config)
assert state["state"] == "idle" and magazine.bullet_count == 30

config[44] = 0
config[43] = 1
magazine.ammo_box_bullet_count = 12
magazine.bullet_count = 0
tick(object(), config)
assert calls == ["reload", "reload"] and magazine.ammo_box_bullet_count == 12

print("reload smoke: magazine drains, real reload requested, reserve replenished only for unlimited ammo")
