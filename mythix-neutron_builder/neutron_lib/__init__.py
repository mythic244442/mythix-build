"""The Neutron launcher, behind the `neutron` entry script.

  common      logging, file/env helpers, reflink copies, PE probes, locks
  version     prefix schema version + per-build profiles
  dist        the Neutron distribution (Wine build, template, layer manifest)
  prefix      CompatData: the prefix, its overlay, the foreign sweep
  components  optional integrations, one module each (see components/base.py)
  session     launch environment + process execution
  main        verb dispatch
"""
