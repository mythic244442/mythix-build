"""Optional integrations, one Component subclass per module.

Adding one: subclass base.Component in a new module here, implement the hooks
it needs and list the class in COMPONENTS. Session builds one of each per
launch and the core calls the hooks in this order.
"""

from .addons import WineAddons
from .base import Component
from .layers import TranslationLayers
from .nvidia import Nvidia
from .sony import Sony
from .steam import Steam
from .vr import VR

# install runs layers → steam → vr → nvidia, as in the single-file launcher
COMPONENTS = (TranslationLayers, Steam, VR, Nvidia, Sony, WineAddons)

__all__ = ["Component", "COMPONENTS"]
