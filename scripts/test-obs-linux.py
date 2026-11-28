import ctypes
import os
import socket
import sys
import tempfile
import threading

obs = ctypes.CDLL(sys.argv[1], mode=ctypes.RTLD_GLOBAL)
server = ctypes.CDLL("libwayland-server.so.0")
client = ctypes.CDLL("libwayland-client.so.0")
pointer = ctypes.c_void_p
text = ctypes.c_char_p


def bind(library, name, result, *arguments):
    function = getattr(library, name)
    function.restype = result
    function.argtypes = arguments
    return function


display = bind(server, "wl_display_create", pointer)()
left, right = socket.socketpair()
assert bind(server, "wl_client_create", pointer, pointer, ctypes.c_int)(display, left.detach())
connection = bind(client, "wl_display_connect_to_fd", pointer, ctypes.c_int)(right.detach())
assert connection
worker = threading.Thread(target=bind(server, "wl_display_run", None, pointer), args=(display,), daemon=True)
worker.start()
bind(obs, "obs_set_nix_platform", None, ctypes.c_int)(2)  # OBS_NIX_PLATFORM_WAYLAND
bind(obs, "obs_set_nix_platform_display", None, pointer)(connection)
print("OBS", bind(obs, "obs_get_version_string", text)().decode(), flush=True)

with tempfile.TemporaryDirectory() as data:
    started = bind(obs, "obs_startup", ctypes.c_bool, text, text, pointer)(b"en-US", os.fsencode(data), None)
    assert started
    try:
        module = pointer()
        open_module = bind(obs, "obs_open_module", ctypes.c_int, ctypes.POINTER(pointer), text, text)
        assert open_module(ctypes.byref(module), os.fsencode(sys.argv[2]), os.fsencode(data)) == 0
        assert bind(obs, "obs_init_module", ctypes.c_bool, pointer)(module)
        name = bind(obs, "obs_source_get_display_name", text, text)(b"FaderSyncPlugin/GoXlrChannelSyncFilter")
        assert name == b"Sync volume with GoXLR Channel"
    finally:
        bind(obs, "obs_shutdown", None)()

bind(server, "wl_display_terminate", None, pointer)(display)
bind(client, "wl_display_disconnect", None, pointer)(connection)
worker.join(timeout=1)
if not worker.is_alive():
    bind(server, "wl_display_destroy", None, pointer)(display)
print("OBS loaded Fader Sync and shut down.")
