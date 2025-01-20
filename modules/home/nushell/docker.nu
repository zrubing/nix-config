def "nu-complete docker containers" [] {
  ^docker ps --all --format "{{.ID}} {{.Names}} ({{.State}})"
  | lines
  | parse "{value} {description}"
}

def "nu-complete docker running-containers" [] {
  ^docker ps --format "{{.ID}} {{.Names}}"
  | lines
  | parse "{value} {description}"
}

def "nu-complete docker stopped-containers" [] {
  ^docker ps --all --format "{{.ID}} {{.State}} {{.Names}}"
  | lines
  | parse "{value} {status} {description}"
  | where status in [paused, exited, dead]
  | reject status
}

def "nu-complete docker images" [] {
  ^docker image ls --format "{{.ID}} {{.Repository}}:{{.Tag}}"
  | lines
  | parse "{value} {description}"
}

def "nu-complete docker networks" [] {
  ^docker network ls --format "{{.ID}} {{.Name}}"
  | lines
  | parse "{value} {description}"
}

def "nu-complete docker pull-policy" [] {
  [always, missing, never]
}

def "nu-complete docker attach" [] {
  [STDIN, STDOUT, STDERR]
}

def "nu-complete docker run cgroupns" [] {
  [
    [value, description];
    [host, "Run the container in the Docker hosts's cgroup namespace"]
    [private, "Run the container in its own private cgroup namespace"]
    ["''", "Use the cgroup namespace as configured by the defaults-cgroupsns-mode option on the daemon (default)"]
  ]
}

#
# Global commands
#

# Return low-level information on Docker objects
export def "docker inspect" [
  --size(-s)        # Display total file sizes if the type is container
  ...object: string # Docker object names or IDs
] {
  if ($object | length) == 0 {
    []
  } else {
    (^docker inspect
      ...(if $size { ["--size"] } else { [] })
      ...$object
    )
    | from json
    | default []
  }
}

#
# Container commands
#

# Attach local standard input, output, and error streams to a running container
export extern "docker container attach" [
  --detach-keys: string # Override the key sequence for detaching a container
  --no-stdin            # Do not attach STDIN
  --sig-proxy           # Proxy all received signals to the process
  container: string@"nu-complete docker running-containers"
]

# Attach local standard input, output, and error streams to a running container
export alias "docker attach" = docker container attach

# Create a new image from a container's changes
export extern "docker container commit" [
  --author(-a): string  # Author (e.g., "John Hannibal Smith <hannibal@a-team.com>")
  --change(-c): string  # Apply Dockerfile instruction to the created image
  --message(-m): string # Commit message
  --pause(-p)           # Pause container during commit (default true)
  container: string@"nu-complete docker containers"
  repo_tag?: string
]

# Create a new image from a container's changes
export alias "docker commit" = docker container commit

# Copy files/folders between a container and the local filesystem
export extern "docker container cp" [
  --archive(-a)     # Archive mode (copy all uid/gid information)
  --follow-link(-L) # Always follow symbol links in SRC_PATH
  --quiet(-q)       # Suppress progress output during copy. Progress output is automatically suppressed if no terminal is attached.
  src_path: string@"nu-complete docker containers"
  dest_path: string@"nu-complete docker containers"
]

# Copy files/folders between a container and the local filesystem
export alias "docker cp" = docker container cp

# Inspect changes to files or directories on a container's filesystem
export def "docker container diff" [
  container: string@"nu-complete docker containers"
] {
  ^docker container diff $container
  | parse "{type} {path}"
  | upsert type { |c|
    match $c.type {
      "C" => "changed"
      "A" => "added"
      "D" => "deleted"
    }
  }
}

# Inspect changes to files or directories on a container's filesystem
export alias "docker diff" = docker container diff

# Execute a command in a running container
export extern "docker container exec" [
  --detach(-d)          # Detached mode: run command in the background
  --detach-keys: string # Override the key sequence for detaching a container
  --env(-e): string     # Set environment variables
  --env-file: string    # Read in a file of environment variables
  --interactive(-i)     # Keep STDIN open even if not attached
  --tty(-t)             # Allocate a pseudo-tty
  --user(-u): string    # Username or UID (format: "<name|uid>[:<group|gid>]")
  --workdir(-w): string # Working directory inside the container
  container: string@"nu-complete docker containers"
  command: string
  ...arg: string
]

# Execute a command in a running container
export alias "docker exec" = docker container exec

# Export a container's filesystem as a tar archive
export extern "docker container export" [
  --output(-o): string # Write to a file, instead of STDOUT
  container: string@"nu-complete docker containers"
]

# Export a container's filesystem as a tar archive
export alias "docker export" = docker container export

# Display detailed information on one or more containers
export def "docker container inspect" [
  --size(-s) # Display total file sizes
  ...container: string@"nu-complete docker containers"
] {
  (^docker container inspect
    --format json
    ...(if $size { ["--size"] } else { [] })
    ...$container
  )
  | from json
}

# Kill one or more running containers
export extern "docker container kill" [
  --signal(-s): string # Signal to send to the container
  ...container: string@"nu-complete docker containers"
]

# Kill one or more running containers
export alias "docker kill" = docker container kill

# Fetch the logs of a container
export extern "docker container logs" [
  --details        # Show extra details provided to logs
  --follow(-f)     # Follow log output
  --tail(-n)       # Number of lines to show from the end of the logs (default "all")
  --timestamps(-t) # Show timestamps
  --since: string  # Show logs since timestamp (e.g. "2013-01-02T13:23:37Z") or relative (e.g. "42m" for 42 minutes)
  --until: string  # Show logs before a timestamp (e.g. "2013-01-02T13:23:37Z") or relative (e.g. "42m" for 42 minutes)
  container: string@"nu-complete docker containers"
]

# Fetch the logs of a container
export alias "docker logs" = docker container logs

# List containers
export def "docker container ls" [
  --all(-a)  # Show all containers (default shows just running)
  --long(-l) # Show more info
] {
  (^docker container ls
    --quiet
    --no-trunc
    ...(if $all { ["--all"] } else { [] })
  )
  | lines
  | docker inspect ...$in
  | each { |c|
    let column = {
      id: ($c.Id | str substring 0..16)
      project: ($c.Config.Labels | get -i "com.docker.compose.project")
      name: $c.Name
      image: $c.Config.Image
      started: (if $c.State.Running { ($c.State.StartedAt | into datetime) } else { null })
    }

    let column = if ($all or $long) {
      $column
      | upsert status $c.State.Status
      | upsert created ($c.Created | into datetime)
      | move status created --before started
    } else {
      $column
    }

    let column = if $long {
      $column
      | upsert id $c.Id
      | upsert service ($c.Config.Labels | get -i "com.docker.compose.service")
      | move service --after project
      | upsert exposed_ports $c.Config.ExposedPorts
      | upsert port_bindings $c.HostConfig.PortBindings
    } else {
      $column
    }

    $column
  }
}

# List containers
export alias "docker container list" = docker container ls
# List containers
export alias "docker container ps" = docker container ls
# List containers
export alias "docker ps" = docker container ls

# Pause all processes within one or more containers
export extern "docker container pause" [
  ...container: string@"nu-complete docker containers"
]

# Pause all processes within one or more containers
export alias "docker pause" = docker container pause

# List port mappings or a specific mapping for the container
export extern "docker container port" [
  container: string@"nu-complete docker containers"
]

# List port mappings or a specific mapping for the container
export alias "docker port" = docker container port

# Remove all stopped containers
export extern "docker container prune" [
  --filter: string # Provide filter values (e.g. "until=<timestamp>")
  --force(-f)      # Do not prompt for confirmation
]

# Rename a container
export extern "docker container rename" [
  container: string@"nu-complete docker containers"
  new_name: string
]

# Rename a container
export alias "docker rename" = docker container rename

# Restart one or more containers
export extern "docker container restart" [
  --signal(-s): string # Signal to send to the container
  --time(-t): int      # Seconds to wait before killing the container
  ...container: string@"nu-complete docker containers"
]

# Restart one or more containers
export alias "docker restart" = docker container restart

# Remove one or more containers
export extern "docker container remove" [
  --force(-f)   # Force the removal of a running container (uses SIGKILL)
  --link(-l)    # Remove the specified link
  --volumes(-v) # Remove anonymous volumes associated with the container
  ...container: string@"nu-complete docker containers"
]

# Remove one or more containers
export alias "docker remove" = docker container remove
# Remove one or more containers
export alias "docker container rm" = docker container remove
# Remove one or more containers
export alias "docker rm" = docker container remove

# Create and run a new container from an image
export extern "docker container run" [
  --add-host: string                                     # Add a custom host-to-IP mapping (host:ip)
  --annotation: string                                   # Add an annotation to the container (passed through to the OCI runtime) (default map[])
  --attach(-a): string@"nu-complete docker attach"       # Attach to STDIN, STDOUT or STDERR
  --blkio-weight: int                                    # Block IO (relative weight), between 10 and 1000, or 0 to disable (default 0)
  --blkio-weight-device: string                          # Block IO weight (relative device weight) (default [])
  --cap-add: string                                      # Add Linux capabilities
  --cap-drop: string                                     # Drop Linux capabilities
  --cgroup-parent: string                                # Optional parent cgroup for the container
  --cgroupns: string@"nu-complete docker run cgroupns"   # Cgroup namespace to use
  --cidfile: string                                      # Write the container ID to the file
  --cpu-period: int                                      # Limit CPU CFS (Completely Fair Scheduler) period
  --cpu-quota: int                                       # Limit CPU CFS (Completely Fair Scheduler) quota
  --cpu-rt-period: int                                   # Limit CPU real-time period in microseconds
  --cpu-rt-runtime: int                                  # Limit CPU real-time runtime in microseconds
  --cpu-shares(-c): int                                  # CPU shares (relative weight)
  --cpus: int                                            # Number of CPUs
  --cpuset-cpus: string                                  # CPUs in which to allow execution (0-3, 0,1)
  --cpuset-mems: string                                  # MEMs in which to allow execution (0-3, 0,1)
  --detach(-d)                                           # Run container in background and print container ID
  --detach-keys: string                                  # Override the key sequence for detaching a container
  --device: string                                       # Add a host device to the container
  --device-cgroup-rule: string                           # Add a rule to the cgroup allowed devices list
  --device-read-bps: string                              # Limit read rate (bytes per second) from a device (default [])
  --device-read-iops: string                             # Limit read rate (IO per second) from a device (default [])
  --device-write-bps: string                             # Limit write rate (bytes per second) to a device (default [])
  --device-write-iops: string                            # Limit write rate (IO per second) to a device (default [])
  --disable-content-trust                                # Skip image verification (default true)
  --dns: string                                          # Set custom DNS servers
  --dns-option: string                                   # Set DNS options
  --dns-search: string                                   # Set custom DNS search domains
  --domainname: string                                   # Container NIS domain name
  --entrypoint: string                                   # Overwrite the default ENTRYPOINT of the image
  --env(-e): string                                      # Set environment variables
  --env-file: string                                     # Read in a file of environment variables
  --expose: string                                       # Expose a port or a range of ports
  --gpus: string                                         # GPU devices to add to the container ('all' to pass all GPUs)
  --group-add: string                                    # Add additional groups to join
  --health-cmd: string                                   # Command to run to check health
  --health-interval: string                              # Time between running the check (ms|s|m|h) (default 0s)
  --health-retries: int                                  # Consecutive failures needed to report unhealthy
  --health-start-period: string                          # Start period for the container to initialize before starting health-retries countdown (ms|s|m|h) (default 0s)
  --health-timeout: string                               # Maximum time to allow one check to run (ms|s|m|h) (default 0s)
  --hostname(-h): string                                 # Container host name
  --init                                                 # Run an init inside the container that forwards signals and reaps processes
  --interactive(-i)                                      # Keep STDIN open even if not attached
  --ip: string                                           # IPv4 address (e.g., 172.30.100.104)
  --ip6: string                                          # IPv6 address (e.g., 2001:db8::33)
  --ipc: string                                          # IPC mode to use
  --isolation: string                                    # Container isolation technology
  --kernel-memory: string                                # Kernel memory limit
  --label(-l): string                                    # Set meta data on a container
  --label-file: string                                   # Read in a line delimited file of labels
  --link: string                                         # Add link to another container
  --link-local-ip: string                                # Container IPv4/IPv6 link-local addresses
  --log-driver: string                                   # Logging driver for the container
  --log-opt: string                                      # Log driver options
  --mac-address: string                                  # Container MAC address (e.g., 92:d0:c6:0a:29:33)
  --memory(-m): string                                   # Memory limit
  --memory-reservation: string                           # Memory soft limit
  --memory-swap: string                                  # Swap limit equal to memory plus swap: '-1' to enable unlimited swap
  --memory-swappiness: int                               # Tune container memory swappiness (0 to 100) (default -1)
  --mount: string                                        # Attach a filesystem mount to the container
  --name: string                                         # Assign a name to the container
  --network: string@"nu-complete docker networks"        # Connect a container to a network
  --network-alias: string                                # Add network-scoped alias for the container
  --no-healthcheck                                       # Disable any container-specified HEALTHCHECK
  --oom-kill-disable                                     # Disable OOM Killer
  --oom-score-adj: int                                   # Tune host's OOM preferences (-1000 to 1000)
  --pid: string                                          # PID namespace to use
  --pids-limit: int                                      # Tune container pids limit (set -1 for unlimited)
  --platform: string                                     # Set platform if server is multi-platform capable
  --privileged                                           # Give extended privileges to this container
  --publish(-p): string                                  # Publish a container's port(s) to the host
  --publish-all(-P)                                      # Publish all exposed ports to random ports
  --pull: string@"nu-complete docker pull-policy"        # Pull image before running (default "missing")
  --quiet(-q)                                            # Suppress the pull output
  --read-only                                            # Mount the container's root filesystem as read only
  --restart: string                                      # Restart policy to apply when a container exits (default "no")
  --rm                                                   # Automatically remove the container when it exits
  --runtime: string                                      # Runtime to use for this container
  --security-opt: string                                 # Security Options
  --shm-size: string                                     # Size of /dev/shm
  --sig-proxy                                            # Proxy received signals to the process (default true)
  --stop-signal: string                                  # Signal to stop the container
  --stop-timeout: int                                    # Timeout (in seconds) to stop a container
  --storage-opt: string                                  # Storage driver options for the container
  --sysctl: string                                       # Sysctl options (default map[])
  --tmpfs: string                                        # Mount a tmpfs directory
  --tty(-t)                                              # Allocate a pseudo-TTY
  --ulimit: string                                       # Ulimit options (default [])
  --user(-u): string                                     # Username or UID (format: <name|uid>[:<group|gid>])
  --userns: string                                       # User namespace to use
  --uts: string                                          # UTS namespace to use
  --volume(-v): string                                   # Bind mount a volume
  --volume-driver: string                                # Optional volume driver for the container
  --volumes-from: string@"nu-complete docker containers" # Mount volumes from the specified container(s)
  --workdir(-w): string                                  # Working directory inside the container
  image: string@"nu-complete docker images"
  command?: string
  ...arg: string
]

# Create and run a new container from an image
export alias "docker run" = docker container run

# Start one or more stopped containers
export extern "docker container start" [
  --attach(-a)          # Attach STDOUT/STDERR and forward signals
  --detach-keys: string # Override the key sequence for detaching a container
  --interactive(-i)     # Attach container's STDIN
  ...container: string@"nu-complete docker stopped-containers"
]

# Start one or more stopped containers
export alias "docker start" = docker container start

# Stop one or more running containers
export extern "docker container stop" [
  --signal: string # Signal to send to the container
  --time(-t): int  # Seconds to wait before killing the container
  ...container: string@"nu-complete docker running-containers"
]

# Stop one or more running containers
export alias "docker stop" = docker container stop

# Display a live stream of container(s) resource usage statistics
export extern "docker container stats" [
  --all(-a)        # Show all containers (default shows just running)
  --format: string # Format output using a custom template
  --no-stream      # Disable streaming stats and only pull the first result
  --no-trunc       # Do not truncate output
  ...container: string@"nu-complete docker containers"
]

# Display a live stream of container(s) resource usage statistics
export alias "docker stats" = docker container stats

# Display the running processes of a container
export def "docker container top" [
  container: string@"nu-complete docker running-containers"
] {
  ^docker container top $container
  | from ssv
  | rename uid pid ppid cpu start_time tty cpu_time cmd
  | upsert start_time { into datetime }
  | upsert tty { if $in == "?" { null } else { $in } }
}

# Display the running processes of a container
export alias "docker top" = docker container top

# Unpause all processes within one or more containers
export extern "docker container unpause" [
  ...container: string@"nu-complete docker running-containers"
]

# Unpause all processes within one or more containers
export alias "docker unpause" = docker container unpause

# Update configuration of one or more containers
export extern "docker container update" [
  --blkio-weight: int          # Block IO (relative weight), between 10 and 1000, or 0 to disable (default 0)
  --cpu-period: int            # Limit CPU CFS (Completely Fair Scheduler) period
  --cpu-quota: int             # Limit CPU CFS (Completely Fair Scheduler) quota
  --cpu-rt-period: int         # Limit the CPU real-time period in microseconds
  --cpu-rt-runtime: int        # Limit the CPU real-time runtime in microseconds
  --cpu-shares(-c): int        # CPU shares (relative weight)
  --cpus: int                  # Number of CPUs
  --cpuset-cpus: string        # CPUs in which to allow execution (0-3, 0,1)
  --cpuset-mems: string        # MEMs in which to allow execution (0-3, 0,1)
  --memory(-m): string         # Memory limit
  --memory-reservation: string # Memory soft limit
  --memory-swap: string        # Swap limit equal to memory plus swap: -1 to enable unlimited swap
  --pids-limit: int            # Tune container pids limit (set -1 for unlimited)
  --restart: string            # Restart policy to apply when a container exits
  ...container: string@"nu-complete docker containers"
]

# Update configuration of one or more containers
export alias "docker update" = docker container update

# Block until one or more containers stop, then print their exit codes
export extern "docker container wait" [
  ...container: string@"nu-complete docker running-containers"
]

# Block until one or more containers stop, then print their exit codes
export alias "docker wait" = docker container wait

#
# System commands
#

# Show docker disk usage
export def "docker system df" [
  --verbose(-v) # Show detailed information on disk usage
] {
  if $verbose {
    ^docker system df -v --format json | from json
  } else {
    ^docker system df --format json
    | from json --objects
    | select Type TotalCount Active Size Reclaimable
    | rename type total_count active size reclaimable
    | upsert size { into filesize }
    | upsert reclaimable { split row " " | get 0 | into filesize }
  }
}

# Get real time events from the server
export extern "docker system events" [
  --filter(-f): string # Filter output based on conditions provided
  --format: string     # Format output using a custom template
  --since: string      # Show all events created since timestamp
  --until: string      # Stream events until this timestamp
]

# Get real time events from the server
export alias "docker events" = docker system events

# Display system-wide information
export def "docker system info" [] {
  ^docker system info --format json
  | from json
}

# Display system-wide information
export alias "docker info" = docker system info

# Remove unused data
export extern "docker system prune" [
  --all(-a)        # Remove all unused images, not just dangling ones
  --filter: string # Provide filter values (e.g. "label=<key>=<value>")
  --force(-f)      # Do not prompt for confirmation
  --volumes        # Prune anonymous volumes
]

#
# Image commands
#

# Show the history of an image
export def "docker image history" [
  image: string@"nu-complete docker images"
] {
  (^docker image history $image
    --format json
    --no-trunc
  )
  | from json --objects
  | select ID CreatedAt CreatedBy Size Comment
  | rename id created created_by size comment
  | upsert created { into datetime }
  | upsert size { into filesize }
  | upsert id { if $in == "<missing>" { null } else { $in } }
}

# Show the history of an image
export alias "docker history" = docker image history

# Download an image from a registry
export extern "docker image pull" [
  --all-tags(-a)          # Download all tagged images in the repository
  --disable-content-trust # Skip image verification (default true)
  --platform string       # Set platform if server is multi-platform capable
  --quiet(-q)             # Suppress verbose output
  image: string
]

# Download an image from a registry
export alias "docker pull" = docker image pull

# List images
export def "docker image ls" [
  --all(-a)  # Show all images (default hides intermediate images)
  --long(-l) # Display more info
] {
  (^docker image ls
    --quiet
    --no-trunc
    ...(if $all { ["--all"] } else { [] })
  )
  | lines
  | docker inspect ...$in
  | each { |c|
    let repo_tags = $c.RepoTags | each { parse '{repository}:{tag}' | get 0 }

    let id = $c.Id | parse "{hash}:{checksum}" | get 0.checksum

    let base = {
      project: ($c.Config.Labels | get -i "com.docker.compose.project")
      service: ($c.Config.Labels | get -i "com.docker.compose.service")
      created: ($c.Created | into datetime)
      size: ($c.Size | into filesize)
    }

    let column = if $long {
      {
        id: $id,
        project: $base.project
        service: $base.service
        repositories: $repo_tags.repository
        tags: $repo_tags.tag
        created: $base.created
        size: $base.size
      }
    } else {
      {
        id: ($id | str substring 0..16)
        project: $base.project
        service: $base.service
        repository: $repo_tags.0.repository
        tag: $repo_tags.0.tag
        created: $base.created
        size: $base.size
      }
    }

    $column
  }
}

# List networks
export def "docker network ls" [
  --long(-l) # Show more info
] {
  (^docker network ls
    --quiet
    --no-trunc
  )
  | lines
  | docker inspect ...$in
  | each { |c|
    let column = {
      id: (if $long { $c.Id } else { $c.Id | str substring 0..16 })
      name: $c.Name
      driver: $c.Driver
      scope: $c.Scope
      project: ($c.Labels | get -i "com.docker.compose.project")
      created: ($c.Created | into datetime)
    }

    $column
  }
}

# List volumes
export def "docker volume ls" [] {
  (^docker volume ls
    --quiet
  )
  | lines
  | docker inspect ...$in
  | each { |c|
    let column = {
      name: $c.Name
      driver: $c.Driver
      scope: $c.Scope
      project: ($c.Labels | get -i "com.docker.compose.project")
    }

    $column
  }
}

# List compose projects
export def "docker compose ls" [
  --all(-a) # Show all stopped Compose projects
] {
  (^docker compose ls
    --format json
    ...(if $all { ["--all"] } else { [] })
  )
  | from json
  | each { |c|
    {
      name: $c.Name
      status: $c.Status
      config_files: ($c.ConfigFiles | split row ",")
    }
  }
}
