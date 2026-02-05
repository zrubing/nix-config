{ config, ... }:
{

  home.file."${config.xdg.configHome}/kube/.kubie.yaml" = {
    source = ./kubie.yaml;
  };

}
