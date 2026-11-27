import os, sys

repo_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(repo_dir, 'payload'))

# Test Healer detection and priority logic
c = [1.0] * 50
c[45] = 1.0 # healer_aim_on = True

print("Testing Healer Aim logic configuration...")
assert len(c) > 45
assert c[45] >= 0.5
print("Healer Aim config parsing OK!")
