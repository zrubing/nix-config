def "nu-complete protontricks appid" [] {
  ^protontricks --list
  | lines
  | drop 5
  | skip 1
  | str join "\n"
  | parse "{description} ({value})"
}

export extern "protontricks-launch" [
  --no-term # Program was launched from desktop and no user-visible terminal is available. Error will be shown in a dialog instead of being printed.
  --verbose(-v) # Increase log verbosity. Can be supplied twice for maximum verbosity.
  --no-runtime # Disable Steam Runtime
  --no-bwrap # Disable bwrap containerization when using Steam Runtime
  --background-wineserver # Launch a background wineserver process to improve Wine command startup time. Disabled by default, as it can cause problems with some graphical applications.
  --no-background-wineserver # Do not launch a background wineserver process to improve Wine command startup time.
  --appid: string@"nu-complete protontricks appid"
  executable: path
]
