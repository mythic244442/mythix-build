"""DualShock 4 / DualSense."""



from .base import Component


# — DualShock 4 / DualSense —
class Sony(Component):
    name = "sony"
    title = "sony controllers"

    def __init__(self, session):
        super().__init__(session)
        self.mode = "build default"   # set by apply_env

    def apply_env(self, env):
        """Builds whose xinput carries GE's Sony stack: by default a Sony pad is
        also an XInput controller (PROTON_SONY_AUTO_XINPUT=1, GE-Proton's own
        default) that steps aside when a game reads it natively or Steam Input
        owns it. MYTHIX_DS4_GLYPHS=1 is native PlayStation mode: the pad stays
        out of XInputGetState, so PlayStation-aware games read it over HID
        (PS glyphs), while XInputSetState still rumbles it."""
        feats = self.neutron.xinput_features()
        native = env.get("MYTHIX_DS4_GLYPHS", "")[:1] == "1"
        if not feats["sony_auto"]:
            self.mode = ("native PlayStation (MYTHIX_DS4_GLYPHS=1)"
                         if native and feats["glyphs"] else "build default")
            return
        if "PROTON_SONY_AUTO_XINPUT" in env:
            self.mode = ("PROTON_SONY_AUTO_XINPUT="
                         f"{env['PROTON_SONY_AUTO_XINPUT']} (set by you)")
        elif native:
            self.mode = ("native PlayStation (MYTHIX_DS4_GLYPHS=1): "
                         "input + glyphs over HID, rumble via XInput")
            if not feats["glyphs"]:
                self.mode += " (this xinput lacks the Mythix patch)"
        else:
            env["PROTON_SONY_AUTO_XINPUT"] = "1"
            self.mode = ("XInput fallback (PROTON_SONY_AUTO_XINPUT=1), "
                         "native takeover")

    def diag(self, kv):
        xi = self.neutron.xinput_features()
        kv("mode", self.mode)
        kv("xinput", ", ".join(
            [name for name, on in (("GE Sony stack", xi["sony_auto"]),
                                   ("Mythix native mode", xi["glyphs"])) if on]
            ) or "stock (no Sony handling)")
