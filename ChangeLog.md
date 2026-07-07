# constrained-toolbox releases

## 0.1 (2026-07-03)
- initial release with `--delete` and `--project` options
- defaults to :z shared bind mounts
- `--caps` to list user's defined capabilities
- wayland: fix socket handling in SELinux labeling
- add `security_opts` capability field
- support PATH[:opts] shorthand for same host/container mount path
  (makes config incompatible with toolbox-constrained)
