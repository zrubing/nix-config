{
  tun = {
    route-exclude-address = [
      # Kubernetes ServiceCIDR / PodCIDR must bypass mihomo TUN on build nodes.
      # Host processes such as containerd need direct access to kube-dns and Zot.
      "10.96.0.0/12"
      "10.244.0.0/16"
      # EasyTier / cluster overlay addresses.
      "10.144.0.0/16"
    ];
  };

  dns = {
    nameserver-policy = {
      "+.svc.cluster.local" = [ "10.96.0.10" ];
      "+.cluster.local" = [ "10.96.0.10" ];
    };
  };
}
