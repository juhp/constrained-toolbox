# constrained-toolbox releases

## 0.2 (2026-07-16)
- add `--home` option to mount a directory as a writable home
- name the container and exec into it if already running
- add `--unique` option to run a separate container instance
- make home directory writable and workdir by default
- change `--delete` to `--delete-image` standalone command
- add `--ephemeral`, restart stopped containers
- error for unused options when joining running container

## 0.1 (2026-07-03)
- initial release with `--delete` and `--project` options
- defaults to :z shared bind mounts
- `--caps` to list user's defined capabilities
- wayland: fix socket handling in SELinux labeling
- add `security_opts` capability field
- support PATH[:opts] shorthand for same host/container mount path
  (makes config incompatible with toolbox-constrained)
- add `--no-network` option to disable network access
- exit cleanly on shell error instead of throwing an exception
