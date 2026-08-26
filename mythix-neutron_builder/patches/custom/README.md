# Custom Patches

Drop `.patch` files into this directory and neutron-builder will auto-discover
and apply them during the build.

## How it works

`neutron-patcher.sh` scans every subdirectory under `patches/` that contains at
least one `.patch` file. Each subdirectory is treated as a **patch group**.

## Patch file format

- Standard unified diff (the output of `git diff` or `git format-patch`).
- Files must have a `.patch` extension.
- Naming convention: prefix with a numeric sequence to control application order
  (e.g. `0001-fix-something.patch`, `0002-add-feature.patch`).
- Without a `series` file, patches are applied in sorted filename order.

## series file (optional)

Create a file called `series` (no extension) listing one patch filename per
line in the order they should be applied:

```
0002-add-feature.patch
0001-fix-something.patch
```

This overrides the default sorted-filename order.

## group.conf fields

Each patch group directory may contain a `group.conf` with the following fields:

| Field         | Description                                                        |
|---------------|--------------------------------------------------------------------|
| `description` | Human-readable summary shown in the interactive picker             |
| `priority`    | Integer controlling group application order (lower = earlier)      |
| `sources`     | Comma-separated Wine sources this group is compatible with (empty = all) |
| `conflicts`   | Comma-separated group names that conflict with this group          |
| `requires`    | Comma-separated group names that must be applied before this one   |

### Example group.conf

```ini
description="My game-specific workarounds"
priority=50
sources=proton-wine,kron4ek-tkg
conflicts=
requires=
```

## Usage

```bash
neutron-builder --patches all                 # apply all discovered groups
neutron-builder --patches custom              # apply only this group
neutron-builder --patches custom,other-group  # apply specific groups
neutron-builder --patches none                # skip patching entirely
neutron-builder                               # interactive fzf multi-picker
```

## Adding more groups

Create additional subdirectories alongside `custom/` — each one with at least
one `.patch` file — and the patcher will pick them up automatically.
