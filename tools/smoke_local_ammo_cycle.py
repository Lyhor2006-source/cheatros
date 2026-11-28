"""Exercise depleted magazines and native-driven full/per-shell transfers."""
import ast
from pathlib import Path
from types import SimpleNamespace as Obj

source = Path(__file__).resolve().parents[1] / 'payload' / 'RosPayload.py'
tree = ast.parse(source.read_text())
names = {'_pb_ar_restore_local_ammo', '_pb_ar_local_ammo', '_pb_auto_reload'}
functions = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in names]


class Magazine:
    def __init__(self, capacity):
        self.magazine_capacity = capacity
        self.bullet_count = capacity
        self.ammo_box_bullet_count = 0
        self.real_consumption = 0

    def decBulletFromMagazine(self):
        self.real_consumption += 1
        self.bullet_count -= 1
        return self.bullet_count

    def addBulletToMagazine(self, count=None):
        raise AssertionError('Real inventory transfer must not run')

    def getCountOfBulletToReload(self):
        return min(self.ammo_box_bullet_count, self.magazine_capacity - self.bullet_count)

    def isAmmoBoxEmpty(self):
        return self.ammo_box_bullet_count == 0


for capacity in (30, 5, 1):
    state = dict(key=None, state='idle')
    loading = [False]
    calls = []
    mag = Magazine(capacity)
    player = Obj(dtsWeaponMagazineBullets=[capacity, 77])
    selected = [mag]

    def probe(me):
        m = selected[0]
        return (0, 1003, 20003), m.bullet_count, m.magazine_capacity, [], [], 1003, m

    def request(*args):
        calls.append('reload')
        loading[0] = True
        return True

    env = dict(_PB_AR_STATE=state, _pb_ar_probe=probe,
               _pb_ar_install_ws_hooks=lambda: None,
               _pb_ar_is_reloading=lambda *args: loading[0],
               _pb_ar_trigger_reload=request)
    exec(compile(ast.Module(body=functions, type_ignores=[]), str(source), 'exec'), env)
    tick = env['_pb_auto_reload']
    config = [0] * 45
    config[44] = 1
    tick(player, config)
    state['switch_until'] = 0
    for cycle in range(3):
        for expected in range(capacity - 1, -1, -1):
            assert mag.decBulletFromMagazine() == 0
            assert mag.bullet_count == expected
            assert player.dtsWeaponMagazineBullets == [expected, 77]
        tick(player, config)
        assert len(calls) == cycle + 1 and loading[0]
        for _ in range(50):
            tick(player, config)
        assert mag.bullet_count == 0  # No timer or polling fill.
        assert mag.getCountOfBulletToReload() == capacity
        # Native reload owns each transfer event; shell-fed guns load singly.
        if capacity == 5:
            for expected in range(1, capacity + 1):
                assert mag.addBulletToMagazine(1) == expected
                tick(player, config)
                assert mag.bullet_count == expected and loading[0]
        else:
            assert mag.addBulletToMagazine() == capacity
        assert mag.addBulletToMagazine(999) == capacity
        loading[0] = False
        tick(player, config)
        assert state['state'] == 'idle' and mag.real_consumption == 0
    # Ownership switch: old magazine delegates to its real original method.
    selected[0] = Magazine(capacity)
    mag.decBulletFromMagazine()
    assert mag.real_consumption == 1
    selected[0] = mag
    # Disabling restores the native bindings and initial reserve.
    config[44] = 0
    tick(player, config)
    assert not state.get('local_ammo') and mag.ammo_box_bullet_count == 0
    assert all(n not in vars(mag) for n in ('decBulletFromMagazine', 'addBulletToMagazine',
                                          'getCountOfBulletToReload', 'isAmmoBoxEmpty'))
    print('Local ammo cycle passed: capacity', capacity)
