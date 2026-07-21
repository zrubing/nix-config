{
  tun = {
    route-exclude-address = [
      "127.0.0.2/32"
      "127.0.0.3/32"
      # Kubernetes ServiceCIDR / PodCIDR must bypass mihomo TUN on build nodes.
      # Host processes such as containerd need direct access to kube-dns and Zot.
      "10.96.0.0/12"
      "10.244.0.0/16"
      # EasyTier / cluster overlay addresses.
      "10.144.0.0/16"
      # Telepresence VIF subnet must bypass mihomo TUN.
      # Telepresence uses this range for tunnel endpoints;
      # mihomo table 2022 would otherwise hijack return traffic.
      "10.245.0.0/24"
    ];
  };

  dns = {
    fake-ip-filter = [
      "+.svc.cluster.local"
      "+.cluster.local"
    ];
    nameserver-policy = {
      # .cluster.local queries handled by system resolver (telepresence when connected).
      # Must NOT be forwarded to 10.96.0.10 — that bypasses telepresence DNS and
      # causes intermittent resolution failures.
      "+.cluster.local" = [ "system" ];
    };
  };
}
