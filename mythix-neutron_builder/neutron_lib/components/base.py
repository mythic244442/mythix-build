"""The Component hooks."""




# ── Components ───────────────────────────────────────────────────────────────
# Everything optional the launcher wires into a launch (the translation
# layers, Steam, VR, NVIDIA, Sony pads) is one class with the same hooks, so a
# new integration is a class added to COMPONENTS, not edits threaded through
# the overlay, the overrides, the environment and diag. Session builds one of
# each per launch; the core calls the hooks in COMPONENTS order.
class Component:
    """The hooks; each defaults to doing nothing."""

    name = ""    # key in Session.components
    title = ""   # its `neutron diag` section

    def __init__(self, session):
        self.session = session
        self.neutron = session.neutron
        self.compatdata = session.compatdata

    def ld_paths(self):
        """Host dirs for LD_LIBRARY_PATH, after the build's own libs."""
        return []

    def apply_env(self, env):
        """Launch environment. setdefault, so the user's own values win."""

    def overrides(self):
        """WINEDLLOVERRIDES entries, {dll: mode}."""
        return {}

    def install(self, track_file):
        """Files for the prefix. Part of the versioned overlay, so it only
        runs when config_info changes; everything placed goes through
        try_copy(track_file=...) so destroyprefix can take it back out."""

    def stray_files(self):
        """Prefix-relative files another tool left that must not stay; the
        foreign sweep quarantines them every launch."""
        return ()

    def per_launch(self):
        """Cheap wiring redone on every launch, after the overlay."""

    def diag(self, kv):
        """Lines for `neutron diag`, via kv(key, value)."""
