def maybe-null [content, default?] {
  if ($content | is-empty) {
    $default
  } else {
    $content.0.content
  }
}

def parse-xplist-item [item] {
  if $item.tag == "string" {
    maybe-null $item.content ""
  } else if $item.tag == "real" {
    $item.content.0.content | into float
  } else if $item.tag == "integer" {
    $item.content.0.content | into int
  } else if $item.tag == "true" {
    true
  } else if $item.tag == "false" {
    false
  } else if $item.tag == "date" {
    $item.content.0.content | into datetime
  } else if $item.tag == "data" {
    if ($item.content | is-empty) {
      bytes build
    } else {
      $item.content.0.content
      | str replace --all --regex '[\t\r\n ]' ''
      | decode base64
    }
  } else if $item.tag == "array" {
    parse-xplist-array $item
  } else if $item.tag == "dict" {
    parse-xplist-dict $item
  } else {
    error make { msg: $"invalid xplist tag: ($item.tag)" }
  }
}

def parse-xplist-array [array] {
  $array.content | each { |item| parse-xplist-item $item }
}

def parse-xplist-dict [dict] {
  if ($dict.content | is-empty) {
    return {}
  }

  $dict.content
  | window 2 --stride 2
  | reduce --fold {} { |pair, acc|
    let key = maybe-null $pair.0.content ""
    if $key in $acc {
      error make { msg: $"duplicate key in dict: ($key)" }
    }

    let value = parse-xplist-item $pair.1

    $acc | merge { ($key): $value }
  }
}

# Parse text as XML .plist and create record.
export def "from xplist" [] {
  from xml | get content.0 | parse-xplist-dict $in
}

export def "defaults domains" [] {
  ^defaults domains | split row ", "
}

export def "defaults read nu" [domain?: string] {
  if $domain == null {
    defaults domains
    | reduce --fold {} { |domain, acc|
      let v = defaults export $domain - | from xplist
      $acc | merge { ($domain): $v }
    }
  } else {
    defaults export $domain - | from xplist
  }
}
