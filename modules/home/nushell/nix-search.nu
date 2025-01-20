export def "nix registry list" [] {
  ^nix registry list
  | from ssv -n -m 1
  | rename type from to
}

def "nu-complete nix search installable" [] {
  nix registry list
  | get from
  | each { split row ':' | get 1 }
  | uniq
}

export def "nix search" [
  installable: string@"nu-complete nix search installable"
  ...regex: string
] {
  ^nix search --json $installable ...$regex
  | from json
  | default {}
  | transpose name info
  | each { |p| $p.info | insert name $p.name }
  | move description --after version
}

def nix-locate-type [] {
  [
    [value description];
    [r 'Regular file']
    [x 'Executable']
    [d 'Directory']
    [s 'Symlink']
  ]
}

def nix-locate-color [] {
  [always never auto]
}

# Locate the package providing a certain file in nixpkgs.
export def "nix-locate" [
  --db(-d): string  # Directory where the index is stored
  --regex(-r) # Treat PATTERN as regex instead of literal text. Also applies to NAME
  --package(-p): string # Only print matches from package whose name matches PACKAGE
  --hash: string # Only print matches from the package that has the given HASH
  --type(-t): string@nix-locate-type # Only print matches for files that have this type
  --no-group # Disables grouping of paths with the same matching part. By default, a path will only be printed if the pattern matches some part of the last component of the path. For example, the pattern `a/foo` would match all of `a/foo`, `a/foo/some_file` and `a/foo/another_file`, but only the first match will be printed. This option disables that behavior and prints all matches
  --color: string@nix-locate-color # Whether to use color in output. If auto, only use colors if outputting to a terminal
  --whole-name(-w) # Only print matches for files or directories whose basename matches PATTERN exactly. This means that the pattern `bin/foo` will only match a file called `bin/foo` or `xx/bin/foo` but not `bin/foobar`
  --at-root # Treat PATTERN as an absolute file path, so it only matches starting from the root of a package. This means that the pattern `/bin/foo` only matches a file called `/bin/foo` or `/bin/foobar` but not `/libexec/bin/foo`
  pattern: string
] {
  (^nix-locate
    ...(if $db != null { [--db $db] } else { [] })
    ...(if $regex { [--regex] } else { [] })
    ...(if $package != null { [--package $package] } else { [] })
    ...(if $hash != null { [--hash $hash] } else { [] })
    ...(if $type != null { [--type $type] } else { [] })
    ...(if $no_group { [--no-group] } else { [] })
    ...(if $color != null { [--color $color] } else { [] })
    ...(if $at_root { [--at-root] } else { [] })
    ...(if $whole_name { [--whole-name] } else { [] })
    $pattern
  )
  | parse -r '^(?<package>\S+) +(?<size>[0-9,]+) (?<type>.) (?<path>.+)$'
  | upsert size { into filesize }
}
