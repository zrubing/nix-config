def "nu-complete gcloud output" [] {
  [table full]
}

# List Google Cloud CLI properties for the currently active configuration
export def "gcloud config list" [] {
  ^gcloud config list --format json | from json
}

def upsert-timestamps [
  ...columns: string
] {
  let items = $in

  $columns | reduce --fold $items { |column acc|
    $acc | upsert $column { |i| $i | get $column | into datetime }
  }
}

# List projects accessible by the active account
export def "gcloud projects list" [
  --format(-f): string@"nu-complete gcloud output"
] {
  let projects = ^gcloud projects list --format json
    | from json

  if $format == "full" {
    return ($projects | upsert-timestamps createTime)
  }

  $projects | each { |p|
    {
      id: $p.projectId
      name: $p.name
      number: $p.projectNumber
    }
  }
}

export def "nu-complete gcloud projects list" [] {
  nu-complete cache --expire 1day {
    ^gcloud projects list --format json
    | from json
    | each { |p|
      {
        value: $p.projectId,
        description: $p.name
      }
    }
  }
}

# List all Artifact Registry supported locations
export def "gcloud artifacts locations list" [] {
  ^gcloud artifacts locations list --format json | from json | get name
}

def "nu-complete artifacts locations" [] {
  nu-complete cache --expire 1day {
    gcloud artifacts locations list | prepend "all"
  }
}

# List all Artifact Registry repositories in the specified project
export def "gcloud artifacts repositories list" [
  --format(-f): string@"nu-complete gcloud output"
  --location: string@"nu-complete artifacts locations" = "all"
] {
  let output = do {
    (^gcloud artifacts repositories list
      --location $location
      --format json)
  } | complete

  if $output.exit_code != 0 {
    print -e $output.stderr
    exit $output.exit_code
  }

  $output.stdout | from json | each { |r|
    let info = $r.name
      | parse "projects/{project}/locations/{location}/repositories/{name}"
      | get 0

    let r = $r
      | upsert-timestamps createTime updateTime
      | upsert size { |r| $r.sizeBytes | into filesize }
      | upsert labels { |r| $r.labels? | default {} }
      | upsert project $info.project
      | upsert location $info.location
      | upsert name $info.name
      | upsert description $r.description?

    if $format == "full" {
      return $r
    }

    if $location == "all" {
      $r | select name format location createTime updateTime size description
    } else {
      $r | select name format createTime updateTime size description
    }
  }
}

def "nu-complete gcr hostname" [] {
  [gcr.io eu.gcr.io asia.gcr.io us.gcr.io]
}

def "nu-complete gcr repository" [] {
  let projects = nu-complete cache --expire 1day {
    gcloud projects list
  }

  $projects | each { |p|
    nu-complete gcr hostname | each { |h|
      $"($h)/($p.id)"
    }
  } | flatten
}

# List existing images
export def "gcloud container images list" [
  --repository: string@"nu-complete gcr repository" = "default"
] {
  (^gcloud container images list
    --format json
    ...(if $repository != default { [--repository $repository] } else { [] })
  )
  | from json
  | get name
}

# List tags for an image
export def "gcloud container images list-tags" [
  image: string
  --format(-f): string@"nu-complete gcloud output"
] {
  ^gcloud container images list-tags $image --format json
  | from json
  | each { |i|
    let digest = if $format == full {
      $i.digest
    } else {
      $i.digest | str substring 7..(11 + 7)
    }

    {
      digest: $digest
      tags: $i.tags
      timestamp: ($i.timestamp.datetime | into datetime)
    }
  }
}

# List Google Compute Engine regions
export def "gcloud compute regions list" [
  --format(-f): string@"nu-complete gcloud output"
] {
  if $format == "full" {
    ^gcloud compute regions list --format json
    | from json
    | upsert-timestamps creationTimestamp
  } else {
    ^gcloud compute regions list --format "get(name)" | lines
  }
}

# List Google Compute Engine zones
export def "gcloud compute zones list" [
  --format(-f): string@"nu-complete gcloud output"
] {
  let zones = ^gcloud compute zones list --format json
    | from json

  if $format == full {
    $zones | upsert-timestamps creationTimestamp
  } else {
    $zones | each { |z|
      {
        name: $z.name
        region: ($z.region | split row "/" | last)
        status: $z.status
      }
    }
  }
}

def "nu-complete compute locations" [] {
  nu-complete cache --expire 1day {
    let regions = ^gcloud compute regions list --format "get(name)" | lines
    let zones = ^gcloud compute zones list --format "get(name)" | lines

    $regions ++ $zones
  }
}

# List existing clusters for running containers
export def "gcloud container clusters list" [
  --format(-f): string@"nu-complete gcloud output"
  --project: string@"nu-complete gcloud projects list"
  --location: string@"nu-complete compute locations" = "all"
] {
  let clusters = (^gcloud container clusters list 
      --format json
      ...(if $location != "all" { [--location $location] } else { [] })
      ...(if $project != null { [--project $project] } else { [] })
    )
    | from json

  if $format == all {
    return $clusters
  }

  $clusters | each { |c|
    {
      name: $c.name
      location: $c.location
      master_version: $c.currentMasterVersion
      master_ip: $c.endpoint
      machine_type: $c.nodeConfig.machineType
      status: $c.status
    }
  }
}

# Read log entries
export def "gcloud logging read" [
  --project: string@"nu-complete gcloud projects list"
  query: string
] {
  (^gcloud logging read
    --format json
    ...(if $project != null { [--project $project] } else { [] })
  )
  | from json
  | upsert-timestamps timestamp receiveTimestamp
}
