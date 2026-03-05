{ ... }:
{
  xdg.configFile."containers/registries.conf".text = ''
    [registries.insecure]
    registries = ['localhost:5000', 'zot.zot.svc.cluster.local:5000', '10.144.144.4:30000']

    [registries.search]
    registries = ['docker.io']
  '';
}
