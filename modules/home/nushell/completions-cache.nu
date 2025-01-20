def init [] {
  try {
    stor open | query db "SELECT 1 FROM nu_complete"
  } catch {
    (stor create
      --table-name "nu_complete" 
      --columns {
        name: str
        value: str
        timestamp: datetime
      }
    )
  }
}

export def "nu-complete cache" [
  --expire: duration
  cmd: any
] {
  init

  let name = view source $cmd

  let saved = stor open
    | (query db
        "SELECT value, timestamp FROM nu_complete WHERE name = :name"
        -p { name: $name })
    | get -i 0

  if $saved != null and (($saved.timestamp | into datetime) + $expire > (date now)) {
    return ($saved.value | from nuon)
  }

  let output = do $cmd

  if $saved == null {
    {
      name: $name,
      value: ($output | to nuon -r),
      timestamp: (date now)
    } | stor insert -t "nu_complete"
  } else {
    stor open
    | query db "UPDATE nu_complete SET value = :value, timestamp = :timestamp WHERE name = :name" -p {
      value: ($output | to nuon -r),
      timestamp: (date now),
      name: $name
    }
  }

  $output
}
