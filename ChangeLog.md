# encapsule releases

## 0.3 (2026-07-20)
- project renamed from constrained-toolbox
- rename `--persistent` to `--keep`
- add `--list` command to show encapsule containers and images
- add `--no-sudo` to remove sudo from the container
- check toolbox container exists before buildah commit
- support running container images directly (name:tag)
- add `--name` option
- add `--debug` flag for verbose startup output
- use `--name ^...` to reference a full container name explicitly
- export TERM and COLORTERM
- `--delete` and commit image now respect --dryrun
- use shell-monad for installSetup Script
- installScript now respects `--no-sudo` and outputs "installing"
- use xdg-basedir for config file
- error for `--project`/`--home` on HOME
- `--project` now names the container after the project directory too,
  so different projects can run concurrently in separate containers
- add `--podman-opt` to pass options directly to podman

## 0.2.1 (2026-07-17)
- add --delete container command
- handle missing container gracefully in --stop and --remove
- default to ephemeral containers again, use --persistent to keep

## 0.2 (2026-07-16)
- add `--home` option to mount a directory as a writable home
- name the container and exec into it if already running
- add `--unique` option to run a separate container instance
- make home directory writable and workdir by default
- change `--delete` to `--delete-image` standalone command
- add `--ephemeral`, restart stopped containers
- error for unused options when joining running container
- add --stop command

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
