def "nu-complete kubectl output" [] {
  [table full]
}

# List all namespaces.
export def "kubectl get namespaces" [
  --output(-o): string@"nu-complete kubectl output" = "table"
] {
  let items = ^kubectl get namespaces -o json
    | from json
    | get items

  if $output == "full" {
    return $items
  }
  
  $items | each { |n|
    {
      name: $n.metadata.name
      status: $n.status.phase
      age: ($n.metadata.creationTimestamp | into datetime)
    }
  }
}

# Show merged kubeconfig settings.
export def "kubectl config view" [
  --raw(-r) # Display raw byte data and sensitive data
  --flatten # Flatten the resulting kubeconfig file into self-contained output
  --merge = true # Merge the full hierarchy of kubeconfig files
  --minify # Remove all information not used by current-context from the output
] {
  (^kubectl config view
    $"--raw=($raw)"
    $"--flatten=($flatten)"
    $"--merge=($merge)"
    $"--minify=($minify)"
  )
  | from yaml
}

# List all pods.
export def "kubectl get pods" [
  --output(-o): string@"nu-complete kubectl output" = "table"
] {
  let items = ^kubectl get pods -o json
    | from json
    | get items

  if $output == "full" {
    return $items
  }

  $items | each { |p|
    let statuses = $p.status | get -i containerStatuses | default []
    let ready = $statuses | where ready == true | length
    let restarts = if ($statuses | length) > 0 {
      $statuses.restartCount | math sum
    } else {
      0
    }

    let last_restart = if $restarts > 0 {
      let r = $statuses
        | get -i lastState.terminated.finishedAt
        | compact
        | each { into datetime }

      match ($r | length) {
        0 => null
        1 => $r.0
        _ => ($r | math max)
      }
    }

    {
      name: $p.metadata.name
      ready: $"($ready)/($statuses | length)"
      status: $p.status.phase
      restarts: $restarts
      last_restart: $last_restart
      age: ($p.status.startTime | into datetime)
    }
  }
  | sort-by name
}

# List all services.
export def "kubectl get services" [
  --output(-o): string@"nu-complete kubectl output" = "table"
] {
  let items = ^kubectl get services -o json
    | from json
    | get items

  if $output == "full" {
    return $items
  }
    
  $items | each { |s|
    let ports = $s.spec.ports | each { |p|
      $"($p.port)/($p.protocol)"
    }

    {
      name: $s.metadata.name
      type: $s.spec.type
      cluster_ip: (if $s.spec.clusterIP? != "None" {
        $s.spec.clusterIP?
      })
      external_ip: $s.spec.loadBalancerIP? # This shold have more cases
      ports: $ports
      age: ($s.metadata.creationTimestamp | into datetime)
    }
  }
}

# List all services.
export alias "kubectl get svc" = kubectl get services

def "nu-complete kubectl services" [] {
  ^kubectl get services -o name
  | parse "service/{value}"
}

# List a single service with specified name.
export def "kubectl get service" [
  name: string@"nu-complete kubectl services"
] {
  ^kubectl get service $name -o json
  | from json
}
