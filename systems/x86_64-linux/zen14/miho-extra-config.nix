{
  route-exclude-address = [
    "127.0.0.2/32"
    "127.0.0.3/32"
  ];

  dns = {
    listen = "169.254.53.53:53";
    nameserver-policy = {
      "+.svc.cluster.local" = [ "10.96.0.10" ];
      "+.cluster.local" = [ "10.96.0.10" ];
    };
  };
}
