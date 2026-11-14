"""Screen sizes (portrait, pixels) for common e-readers. Pick with --device or set --width/--height."""

DEVICES = {
    "kindle-pw5": (1236, 1648),        # Paperwhite 5 / Signature (2021)
    "kindle-pw6": (1264, 1680),        # Paperwhite 7" (2024)
    "kindle-pw4": (1072, 1448),        # Paperwhite 4
    "kindle-basic": (1072, 1448),      # Kindle (2022, 2024)
    "kindle-oasis": (1264, 1680),
    "kindle-scribe": (1860, 2480),
    "kobo-clara": (1072, 1448),        # Clara HD / 2E / BW / Colour
    "kobo-libra": (1264, 1680),        # Libra 2 / Colour
    "kobo-sage": (1440, 1920),
    "kobo-elipsa": (1404, 1872),
    "pocketbook-era": (1264, 1680),
    "remarkable-2": (1404, 1872),
}

DEFAULT_DEVICE = "kindle-pw5"


def resolve(device=None, width=None, height=None):
    """Return (width, height) from explicit sizes or a device preset."""
    if width and height:
        return int(width), int(height)
    name = device or DEFAULT_DEVICE
    if name not in DEVICES:
        raise SystemExit(f"unknown device {name!r}; try one of: {', '.join(sorted(DEVICES))} "
                         f"(or pass --width and --height)")
    return DEVICES[name]
