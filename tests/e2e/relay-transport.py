#!/usr/bin/python3
import os
import pathlib
import subprocess
import sys

binary = "/usr/local/bin/devsy-e2e-original"
if sys.argv[1:5] != ["internal", "agent", "container", "credentials-server"]:
    os.execv(binary, [binary, *sys.argv[1:]])

blocked = pathlib.Path("/tmp/orca-e2e-rpc-block")
blocked.unlink(missing_ok=True)
child = subprocess.Popen([binary, *sys.argv[1:]], stdin=subprocess.PIPE)
try:
    while data := os.read(0, 65536):
        if not blocked.exists():
            child.stdin.write(data)
            child.stdin.flush()
except BrokenPipeError:
    pass
finally:
    child.stdin.close()
    if child.poll() is None:
        child.terminate()
    try:
        child.wait(timeout=3)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait()
sys.exit(child.returncode)
